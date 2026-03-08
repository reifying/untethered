(ns untethered.db
  "re-frame app-db schema and initialization.
   Defines the canonical app state for the Untethered supervisor app.")

;; Maximum messages to retain per session to limit memory usage
(def max-messages-per-session
  "Maximum number of messages to keep per session.
   Oldest messages are pruned first to keep newest."
  50)

;; Stable session UUID for backend registration, persists across hot reloads.
;; Generated once per app process lifecycle.
;; Per STANDARDS.md, must be lowercase (random-uuid already produces lowercase).
(defonce ios-session-id (str (random-uuid)))

(def default-db
  "Initial application state."
  {:connection {:status :disconnected ; :disconnected | :connecting | :connected
                :authenticated? false
                :requires-reauthentication? false
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
   :ios-session-id ios-session-id

   ;; Set of session IDs currently processing prompts
   :locked-sessions #{}

   ;; Set of session IDs that have been subscribed in this view cycle
   :subscribed-sessions #{}

   ;; Set of session IDs currently loading history
   :loading-sessions #{}

   ;; Tracks pending delta sync requests
   :pending-delta-syncs #{}

   ;; Command execution state
   :commands {:available {}
              :running {}
              :history []
              :mru {}}

   ;; Resource/file upload state
   :resources {:list []
               :pending-uploads 0}

   ;; Recipe orchestration state
   :recipes {:available []
             :active {}}

   ;; Application settings
   :settings {:server-url "localhost"
              :server-port 8080
              :voice-identifier nil
              :voice-speech-rate 0.5
              :recent-sessions-limit 10
              :max-message-size-kb 200
              :system-prompt ""
              :respect-silent-mode true
              :continue-playback-when-locked true
              :auto-speak-responses false
              :queue-enabled false
              :priority-queue-enabled false
              :resource-storage-location "~/Downloads"}

   ;; UI state
   :ui {:loading? false
        :current-error nil
        :drafts {}
        :auto-scroll? true
        :input-mode :voice
        :testing-connection? false
        :connection-test-result nil
        :previewing-voice? false
        :compacting-sessions #{}
        :compaction-timestamps {}
        :compaction-success nil
        :voice-listening? false
        :voice-speaking? false
        :voice-paused? false
        :voice-partial nil
        :voice-error nil}})

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
   Matches by (session-id, role, text) for user messages with :sending status."
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
        result (reduce
                (fn [msgs new-msg]
                  (if (contains? existing-ids (:id new-msg))
                    msgs
                    (if-let [optimistic-idx (reconcile-optimistic-message msgs new-msg)]
                      (update msgs optimistic-idx
                              (fn [existing]
                                (cond-> (-> existing
                                            (assoc :id (:id new-msg))
                                            (assoc :status :confirmed))
                                  (:timestamp new-msg)
                                  (assoc :timestamp (:timestamp new-msg)))))
                      (conj msgs new-msg))))
                (vec existing-messages)
                new-messages)]
    (prune-messages result)))
