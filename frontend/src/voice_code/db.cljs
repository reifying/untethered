(ns voice-code.db
  "re-frame app-db schema and initialization.
   Mirrors iOS CoreData schema with idiomatic Clojure structures.")

;; Maximum messages to retain per session to limit memory usage
(def max-messages-per-session
  "Maximum number of messages to keep per session.
   Oldest messages are pruned first to keep newest."
  50)

(def default-db
  "Initial application state."
  {:connection {:status :disconnected ; :disconnected | :connecting | :connected
                :authenticated? false
                :requires-reauthentication? false ; true when auth_error received (vs initial state)
                :error nil
                :reconnect-attempts 0}

   ;; Sessions indexed by session-id
   ;; Each session: {:id :backend-name :custom-name :working-directory
   ;;                :last-modified :message-count :preview :queue-position
   ;;                :priority :priority-order :is-user-deleted :unread-count}
   :sessions {}

   ;; Messages indexed by session-id -> [message-vec]
   ;; Each message: {:id :session-id :role :text :timestamp :status}
   :messages {}

   ;; Currently active session
   :active-session-id nil

   ;; iOS session UUID for backend registration
   :ios-session-id nil

   ;; Set of session IDs currently processing prompts
   :locked-sessions #{}

   ;; Set of session IDs that have been subscribed in this view cycle
   ;; Guards against duplicate subscribe requests (matches iOS hasSubscribedThisAppear pattern)
   ;; Cleared when session becomes inactive or on reconnection
   :subscribed-sessions #{}

   ;; Set of session IDs currently loading history (waiting for session_history response)
   ;; Used to show loading indicator in conversation view
   ;; Matches iOS isLoading state with 5-second timeout fallback
   :loading-sessions #{}

   ;; Tracks pending delta sync requests (session-id -> true when delta sync in progress)
   ;; Used to determine whether to merge or replace messages on history response
   :pending-delta-syncs #{}

   ;; Command execution state
   :commands {:available {} ; working-dir -> command tree
              :running {} ; command-session-id -> command state
              :history [] ; Recent command executions
              :mru {}} ; command-id -> timestamp (ms) for MRU sorting

   ;; Resource/file upload state
   :resources {:list [] ; Uploaded files
               :pending-uploads 0}

   ;; Recipe orchestration state
   :recipes {:available [] ; Recipe definitions
             :active {}} ; session-id -> active recipe

   ;; Application settings
   :settings {:server-url "localhost"
              :server-port 8080
              :voice-identifier nil ; Selected voice for TTS
              :voice-speech-rate 0.5 ; TTS speech rate (0.0-1.0, default 0.5)
              :recent-sessions-limit 10
              :max-message-size-kb 200
              :system-prompt "" ; Custom system prompt appended to Claude
              :respect-silent-mode true ; iOS: silence when phone is on vibrate
              :continue-playback-when-locked true ; Continue audio when screen locked
              :auto-speak-responses false ; Auto-speak Claude responses via TTS
              :queue-enabled false ; Show threads in queue
              :priority-queue-enabled false ; Priority-based session ordering
              :resource-storage-location "~/Downloads"} ; Upload destination

   ;; UI state
   :ui {:loading? false
        :current-error nil
        :drafts {} ; session-id -> draft text
        :auto-scroll? true
        :input-mode :voice
        :testing-connection? false
        :connection-test-result nil
        :previewing-voice? false
        :compacting-sessions #{} ; Set of session IDs currently being compacted
        :compaction-timestamps {} ; session-id -> timestamp of last compaction
        :compaction-success nil}}) ; Temporary success message

(defn session-locked?
  "Check if a session is currently locked (processing a prompt)."
  [db session-id]
  (contains? (:locked-sessions db) session-id))

(defn get-messages-for-session
  "Get all messages for a session in chronological order."
  [db session-id]
  (get-in db [:messages session-id] []))

(defn get-session
  "Get session by ID."
  [db session-id]
  (get-in db [:sessions session-id]))

(defn active-session
  "Get the currently active session."
  [db]
  (when-let [id (:active-session-id db)]
    (get-session db id)))

(defn prune-messages
  "Prune messages to max-messages-per-session, keeping newest.
   Returns the pruned message vector."
  [messages]
  (if (> (count messages) max-messages-per-session)
    (vec (take-last max-messages-per-session messages))
    messages))

(defn- reconcile-optimistic-message
  "Check if a new message matches an existing optimistic message by content.
   Returns the existing message index if found, nil otherwise.
   Matches by (session-id, role, text) for user messages with :sending status.
   Reference: ios/VoiceCode/Managers/SessionSyncManager.swift:296-312"
  [existing-messages new-msg]
  (when (= :user (:role new-msg))
    (->> existing-messages
         (map-indexed vector)
         (some (fn [[idx existing]]
                 (when (and (= :sending (:status existing))
                            (= :user (:role existing))
                            (= (:text existing) (:text new-msg)))
                   idx))))))

(defn merge-messages
  "Merge new messages with existing messages, deduplicating by ID.
   Also reconciles optimistic messages by matching (session-id, role, text)
   when a server message arrives for a locally-created :sending message.
   New messages are appended, maintaining chronological order.
   Returns the merged and pruned message vector."
  [existing-messages new-messages]
  (let [existing-ids (into #{} (map :id existing-messages))
        ;; Process each new message - either reconcile with existing or add new
        result (reduce
                (fn [msgs new-msg]
                  ;; Skip if we already have this exact ID
                  (if (contains? existing-ids (:id new-msg))
                    msgs
                    ;; Check for optimistic message to reconcile
                    (if-let [optimistic-idx (reconcile-optimistic-message msgs new-msg)]
                      ;; Update the optimistic message with confirmed status and server ID
                      (update msgs optimistic-idx
                              (fn [existing]
                                (-> existing
                                    (assoc :id (:id new-msg))
                                    (assoc :status :confirmed)
                                    ;; Update timestamp if server provides one
                                    (cond-> (:timestamp new-msg)
                                      (assoc :timestamp (:timestamp new-msg))))))
                      ;; No match - add as new message
                      (conj msgs new-msg))))
                (vec existing-messages)
                new-messages)]
    (prune-messages result)))
