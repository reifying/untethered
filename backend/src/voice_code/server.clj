(ns voice-code.server
  "Main entry point and WebSocket server for voice-code backend."
  (:require [org.httpkit.server :as http]
            [clojure.core.async :as async]
            [cheshire.core :as json]
            [clojure.tools.logging :as log]
            [clojure.edn :as edn]
            [clojure.java.io :as io]
            [clojure.string :as str]
            [voice-code.claude :as claude]
            [voice-code.replication :as repl]
            [voice-code.worktree :as worktree]
            [voice-code.commands :as commands]
            [voice-code.commands-history :as cmd-history]
            [voice-code.resources :as resources]
            [voice-code.recipes :as recipes]
            [voice-code.orchestration :as orch])
  (:gen-class))

;; JSON key conversion utilities
;; Following STANDARDS.md: JSON uses snake_case, Clojure uses kebab-case

(defn snake->kebab
  "Convert snake_case string to kebab-case keyword"
  [s]
  (keyword (str/replace s #"_" "-")))

(defn kebab->snake
  "Convert kebab-case keyword to snake_case string"
  [k]
  (str/replace (name k) #"-" "_"))

(defn convert-keywords
  "Recursively convert keyword values to snake_case strings"
  [data]
  (cond
    (keyword? data) (kebab->snake data)
    (map? data) (into {} (map (fn [[k v]] [k (convert-keywords v)]) data))
    (coll? data) (map convert-keywords data)
    :else data))

(defn parse-json
  "Parse JSON string, converting snake_case keys to kebab-case keywords"
  [s]
  (json/parse-string s snake->kebab))

(defn generate-json
  "Generate JSON string, converting kebab-case keywords to snake_case keys and values"
  [data]
  (json/generate-string (convert-keywords data) {:key-fn kebab->snake}))

(defonce server-state (atom nil))

(defn ensure-config-file
  "Ensure config.edn exists, creating with defaults if needed.
  Only works in development (not when running from JAR).
  
  Accepts optional config-path for testing purposes."
  ([]
   (ensure-config-file "resources/config.edn"))
  ([config-path]
   (let [config-file (io/file config-path)]
     (when-not (.exists config-file)
       (log/info "Creating default config.edn at" config-path)
       (io/make-parents config-file)
       (spit config-file
             (str "{:server {:port 8080\n"
                  "          :host \"0.0.0.0\"}\n\n"
                  " :claude {:cli-path \"claude\"\n"
                  "          :default-timeout 86400000}  ; 24 hours in milliseconds\n\n"
                  " :logging {:level :info}}\n"))))))

(defn load-config
  "Load configuration from resources/config.edn, creating with defaults if needed"
  []
  (ensure-config-file)
  (if-let [config-resource (io/resource "config.edn")]
    (-> config-resource
        slurp
        edn/read-string)
    ;; Fallback to defaults if resource not found (e.g., in JAR)
    (do
      (log/warn "config.edn not found on classpath, using defaults")
      {:server {:port 8080
                :host "0.0.0.0"}
       :claude {:cli-path "claude"
                :default-timeout 86400000}
       :logging {:level :info}})))

;; Ephemeral mapping: WebSocket channel -> client state
;; This is just for routing messages during an active connection
;; Persistent session data comes from the replication system (filesystem-based)

(defonce connected-clients
  ;; Track all connected WebSocket clients: channel -> {:deleted-sessions #{} :recent-sessions-limit 5 :max-message-size-kb 200}
  (atom {}))

;; Default max message size in KB (conservative default well below iOS 256KB limit)
;; Lower default ensures older clients without set_max_message_size still work
(def default-max-message-size-kb 100)

;; Per-message max size in bytes for delta sync truncation
;; Messages larger than this are truncated individually, smaller messages are preserved intact
(def per-message-max-bytes (* 20 1024)) ;; 20KB per message max

(defn truncate-text-middle
  "Truncate text to fit within max-bytes by keeping first and last portions.
   Inserts a marker showing how much was truncated.
   Returns the original text if it fits within the limit."
  [text max-bytes]
  (let [text-bytes (.getBytes text "UTF-8")
        text-size (count text-bytes)]
    (if (<= text-size max-bytes)
      text
      ;; Need to truncate
      (let [marker-template "\n\n... [truncated ~%d KB] ...\n\n"
            ;; Estimate marker size (will recalculate)
            truncated-kb (int (/ (- text-size max-bytes) 1024))
            marker (format marker-template truncated-kb)
            marker-bytes (count (.getBytes marker "UTF-8"))
            ;; Available space for content (half for each side)
            available-bytes (- max-bytes marker-bytes)
            half-bytes (int (/ available-bytes 2))
            ;; We need to be careful with UTF-8 multi-byte characters
            ;; Take characters until we exceed byte limit
            first-part (loop [chars (seq text)
                              result []
                              bytes 0]
                         (if (or (empty? chars) (>= bytes half-bytes))
                           (apply str result)
                           (let [ch (first chars)
                                 ch-bytes (count (.getBytes (str ch) "UTF-8"))
                                 new-bytes (+ bytes ch-bytes)]
                             (if (> new-bytes half-bytes)
                               (apply str result)
                               (recur (rest chars) (conj result ch) new-bytes)))))
            ;; Take from end
            last-part (loop [chars (reverse (seq text))
                             result []
                             bytes 0]
                        (if (or (empty? chars) (>= bytes half-bytes))
                          (apply str (reverse result))
                          (let [ch (first chars)
                                ch-bytes (count (.getBytes (str ch) "UTF-8"))
                                new-bytes (+ bytes ch-bytes)]
                            (if (> new-bytes half-bytes)
                              (apply str (reverse result))
                              (recur (rest chars) (conj result ch) new-bytes)))))]
        (str first-part marker last-part)))))

(defn get-client-max-message-size-bytes
  "Get the max message size in bytes for a client channel."
  [channel]
  (let [client-info (get @connected-clients channel)
        size-kb (or (:max-message-size-kb client-info) default-max-message-size-kb)]
    (* size-kb 1024)))

(defn truncate-content-block
  "Truncate a single content block (text, tool_result, etc.) if it exceeds max bytes."
  [block max-text-bytes]
  (cond
    ;; Text block: {:type "text", :text "..."}
    (and (map? block)
         (= "text" (:type block))
         (string? (:text block)))
    (let [text (:text block)
          text-bytes (count (.getBytes text "UTF-8"))]
      (if (<= text-bytes max-text-bytes)
        block
        (assoc block :text (truncate-text-middle text max-text-bytes))))

    ;; Tool result with string content: {:type "tool_result", :content "..."}
    (and (map? block)
         (= "tool_result" (:type block))
         (string? (:content block)))
    (let [content (:content block)
          content-bytes (count (.getBytes content "UTF-8"))]
      (if (<= content-bytes max-text-bytes)
        block
        (assoc block :content (truncate-text-middle content max-text-bytes))))

    ;; Tool result with array content: {:type "tool_result", :content [{:type "text", :text "..."}]}
    (and (map? block)
         (= "tool_result" (:type block))
         (sequential? (:content block)))
    (update block :content #(mapv (fn [inner] (truncate-content-block inner max-text-bytes)) %))

    :else block))

(defn truncate-message-text
  "Truncate text content within a single message object (from :messages array).
   Handles both simple {:text ...} and complex nested structures with :message {:content [...]}."
  [msg max-text-bytes]
  (let [;; First truncate :toolUseResult if present (top-level field in JSONL)
        msg (if (and (contains? msg :toolUseResult)
                     (sequential? (:toolUseResult msg)))
              (update msg :toolUseResult #(mapv (fn [block] (truncate-content-block block max-text-bytes)) %))
              msg)]
    (cond
      ;; Simple text field
      (and (contains? msg :text) (string? (:text msg)))
      (let [text (:text msg)
            text-bytes (count (.getBytes text "UTF-8"))]
        (if (<= text-bytes max-text-bytes)
          msg
          (assoc msg :text (truncate-text-middle text max-text-bytes))))

      ;; Content array directly on message (Claude message format)
      (and (contains? msg :content) (sequential? (:content msg)))
      (update msg :content #(mapv (fn [block] (truncate-content-block block max-text-bytes)) %))

      ;; Nested :message with :content (JSONL format from Claude sessions)
      (and (contains? msg :message)
           (map? (:message msg))
           (contains? (:message msg) :content)
           (sequential? (get-in msg [:message :content])))
      (update-in msg [:message :content] #(mapv (fn [block] (truncate-content-block block max-text-bytes)) %))

      :else msg)))

(defn truncate-messages-array
  "Truncate text within messages array to fit within size budget.
   Uses iterative approach, halving per-message budget until under limit."
  [messages max-total-bytes]
  (let [json-str (generate-json messages)
        current-bytes (count (.getBytes json-str "UTF-8"))]
    (if (<= current-bytes max-total-bytes)
      messages
      ;; Need to truncate - iterate with decreasing budget until we fit
      (let [msg-count (max 1 (count messages))]
        (loop [max-text-per-msg (int (/ max-total-bytes msg-count 2)) ;; Start with half of equal split
               iteration 0]
          (if (< iteration 10) ;; Max 10 iterations to prevent infinite loop
            (let [truncated (mapv #(truncate-message-text % max-text-per-msg) messages)
                  truncated-json (generate-json truncated)
                  truncated-bytes (count (.getBytes truncated-json "UTF-8"))]
              (if (<= truncated-bytes max-total-bytes)
                (do
                  (log/info "Truncated messages array"
                            {:message-count msg-count
                             :original-bytes current-bytes
                             :final-bytes truncated-bytes
                             :max-bytes max-total-bytes
                             :max-text-per-msg max-text-per-msg
                             :iterations (inc iteration)})
                  truncated)
                ;; Still too big, halve the budget and try again
                (recur (max 500 (int (/ max-text-per-msg 2))) (inc iteration))))
            ;; Hit max iterations, return what we have
            (do
              (log/warn "Max truncation iterations reached"
                        {:message-count msg-count
                         :original-bytes current-bytes
                         :max-bytes max-total-bytes})
              (mapv #(truncate-message-text % 500) messages))))))))

(defn build-session-history-response
  "Build session-history response with delta sync and smart truncation.

   Algorithm:
   1. Find messages newer than last-message-id (or all if not provided/found)
   2. Start from newest, work backwards
   3. Add messages until budget exhausted or all messages included
   4. Truncate only messages exceeding per-message-max-bytes
   5. Reverse to chronological order

   Parameters:
   - messages: vector of message maps (must have :uuid field)
   - last-message-id: optional UUID string of the most recent message iOS has
   - max-total-bytes: maximum bytes for the response JSON

   Returns map with:
   - :messages - vector of processed messages in chronological order
   - :is-complete - true if all requested messages fit
   - :oldest-message-id - UUID of oldest included message
   - :newest-message-id - UUID of newest included message"
  [messages last-message-id max-total-bytes]
  (if (empty? messages)
    {:messages []
     :is-complete true
     :oldest-message-id nil
     :newest-message-id nil}
    (let [;; Find index of last known message
          last-idx (when last-message-id
                     (some (fn [[idx msg]]
                             (when (= (:uuid msg) last-message-id) idx))
                           (map-indexed vector messages)))

          ;; Get messages newer than last known (or all if not found)
          new-messages (if last-idx
                         (vec (drop (inc last-idx) messages))
                         messages)

          ;; If no new messages after last-message-id, return empty
          _ (when (and last-idx (empty? new-messages))
              (log/debug "No new messages since last-message-id"
                         {:last-message-id last-message-id}))

          ;; Work backwards from newest, building up result
          reversed-msgs (reverse new-messages)
          overhead-estimate 200 ;; JSON structure overhead

          result (loop [remaining reversed-msgs
                        accumulated []
                        used-bytes overhead-estimate]
                   (if (empty? remaining)
                     {:messages (vec (reverse accumulated))
                      :is-complete true}
                     (let [msg (first remaining)
                           ;; Truncate individual large messages
                           processed-msg (truncate-message-text msg per-message-max-bytes)
                           msg-json (generate-json processed-msg)
                           msg-bytes (count (.getBytes msg-json "UTF-8"))
                           new-total (+ used-bytes msg-bytes 1)] ;; +1 for comma
                       (if (> new-total max-total-bytes)
                         ;; Budget exhausted
                         {:messages (vec (reverse accumulated))
                          :is-complete false}
                         ;; Add message and continue
                         (recur (rest remaining)
                                (conj accumulated processed-msg)
                                new-total)))))]

      (assoc result
             :oldest-message-id (-> result :messages first :uuid)
             :newest-message-id (-> result :messages last :uuid)))))

(defn truncate-response-text
  "Truncate the :text field of a response message if the total JSON would exceed max size.
   Also handles :messages arrays (for session-updated messages).
   Returns the modified message data with truncated content if needed."
  [message-data max-bytes]
  (let [;; First, generate JSON to see actual size
        json-str (generate-json message-data)
        json-bytes (count (.getBytes json-str "UTF-8"))]
    (if (<= json-bytes max-bytes)
      message-data
      ;; Need to truncate - determine which field to truncate
      (cond
        ;; Direct :text field (response messages)
        (and (contains? message-data :text) (string? (:text message-data)))
        (let [text (:text message-data)
              overhead (- json-bytes (count (.getBytes text "UTF-8")))
              max-text-bytes (- max-bytes overhead 100)
              truncated-text (truncate-text-middle text max-text-bytes)
              original-kb (int (/ (count (.getBytes text "UTF-8")) 1024))
              session-id (or (:session-id message-data) "unknown")]
          (log/info "Truncating large response text"
                    {:session-id session-id
                     :original-size-kb original-kb
                     :max-size-kb (int (/ max-bytes 1024))})
          (assoc message-data :text truncated-text))

        ;; :messages array (session-updated messages)
        (and (contains? message-data :messages) (sequential? (:messages message-data)))
        (let [messages (:messages message-data)
              overhead (- json-bytes (count (.getBytes (generate-json messages) "UTF-8")))
              max-messages-bytes (- max-bytes overhead 100)
              session-id (or (:session-id message-data) "unknown")]
          (log/info "Truncating large messages array"
                    {:session-id session-id
                     :message-count (count messages)
                     :original-size-kb (int (/ json-bytes 1024))
                     :max-size-kb (int (/ max-bytes 1024))})
          (assoc message-data :messages (truncate-messages-array messages max-messages-bytes)))

        ;; No known truncatable field
        :else message-data))))

(defonce pending-new-sessions
  ;; Track new sessions awaiting creation: session-id -> channel
  ;; Used to send session_ready to the correct client when file is detected
  (atom {}))

(defonce session-orchestration-state
  ;; Track orchestration state per Claude session: session-id -> {:recipe-id :step :step-count :step-visit-counts ...}
  ;; Maps Claude session IDs to their active orchestration recipe state.
  ;; Safe for concurrent WebSocket connections: each connection operates on independent session state.
  ;; State is isolated per Claude session (not per iOS session), preventing conflicts.
  ;; Cleanup via exit-recipe-for-session when recipe completes or user cancels.
  (atom {}))

(defn unregister-channel!
  "Remove WebSocket channel from connected clients"
  [channel]
  (swap! connected-clients dissoc channel))

(defn generate-message-id
  "Generate a UUID v4 for message tracking"
  []
  (str (java.util.UUID/randomUUID)))

(defn broadcast-to-all-clients!
  "Broadcast a message to all connected clients"
  [message-data]
  (doseq [[channel _client-info] @connected-clients]
    (try
      (http/send! channel (generate-json message-data))
      (catch Exception e
        (log/warn e "Failed to broadcast to client")))))

(defn send-to-client!
  "Send message to a specific channel if it's connected.
   Applies truncation for messages with :text or :messages fields if needed."
  [channel message-data]
  (if (contains? @connected-clients channel)
    (do
      (log/info "Sending message to client" {:type (:type message-data)})
      (let [;; Apply truncation for messages that might have large content
            max-bytes (get-client-max-message-size-bytes channel)
            final-data (truncate-response-text message-data max-bytes)
            json-str (generate-json final-data)]
        (log/debug "JSON payload" {:size (count json-str)})
        (try
          (http/send! channel json-str)
          (log/info "Message sent successfully" {:type (:type message-data)})
          (catch Exception e
            (log/warn e "Failed to send to client")))))
    (log/warn "Channel not in connected-clients, skipping send" {:type (:type message-data)})))

(defn send-recent-sessions!
  "Send the recent sessions list to a connected client.
  Uses the new recent_sessions message type (distinct from session-list).
  Converts :last-modified from milliseconds to ISO-8601 string for JSON.
  Sends session-id, name, working-directory, last-modified."
  [channel limit]
  (let [sessions (repl/get-recent-sessions limit)
        ;; Convert to format with ISO-8601 timestamp
        ;; Include name field (generated from Claude summary or fallback to dir-timestamp)
        sessions-minimal (mapv
                          (fn [session]
                            {:session-id (:session-id session)
                             :name (:name session)
                             :working-directory (:working-directory session)
                             :last-modified (.format (java.time.format.DateTimeFormatter/ISO_INSTANT)
                                                     (java.time.Instant/ofEpochMilli (:last-modified session)))})
                          sessions)]
    (log/info "Sending recent sessions" {:count (count sessions-minimal) :limit limit})
    (send-to-client! channel
                     {:type :recent-sessions
                      :sessions sessions-minimal
                      :limit limit})))

(defn send-session-locked!
  "Send session_locked message to client indicating session is processing a prompt."
  [channel session-id]
  (log/info "Sending session_locked message" {:session-id session-id})
  (send-to-client! channel
                   {:type :session-locked
                    :message "Session is currently processing a prompt. Please wait."
                    :session-id session-id}))

(defn is-session-deleted-for-client?
  "Check if a client has deleted a session locally"
  [channel session-id]
  (let [client-info (get @connected-clients channel)]
    (contains? (:deleted-sessions client-info) session-id)))

(defn mark-session-deleted-for-client!
  "Mark a session as deleted for a specific client"
  [channel session-id]
  (swap! connected-clients update-in [channel :deleted-sessions] (fnil conj #{}) session-id)
  (log/debug "Marked session as deleted for client" {:session-id session-id}))

;; Orchestration helper functions

(defn get-session-recipe-state
  "Get the current orchestration state for a session, or nil if not in recipe"
  [session-id]
  (get @session-orchestration-state session-id))

(defn session-exists?
  "Check if a Claude session file exists for the given session ID.
   Returns true if session metadata exists (implying .jsonl file exists)."
  [session-id]
  (some? (repl/get-session-metadata session-id)))

(defn start-recipe-for-session
  "Initialize orchestration state for a session.
   is-new-session? indicates whether this is a brand new session with no Claude history."
  [session-id recipe-id is-new-session?]
  (if-let [state (orch/create-orchestration-state recipe-id)]
    (let [state-with-session-flag (assoc state :session-created? (not is-new-session?))]
      (swap! session-orchestration-state assoc session-id state-with-session-flag)
      (orch/log-orchestration-event "recipe-started" session-id recipe-id
                                    (:current-step state)
                                    {:is-new-session is-new-session?})
      state-with-session-flag)
    (do
      (log/error "Recipe not found" {:recipe-id recipe-id :session-id session-id})
      nil)))

(defn exit-recipe-for-session
  "Exit orchestration for a session"
  [session-id reason]
  (when-let [state (get-session-recipe-state session-id)]
    (orch/log-orchestration-event "recipe-exited" session-id (:recipe-id state) (:current-step state) {:reason reason})
    (swap! session-orchestration-state dissoc session-id)))

(defn get-next-step-prompt
  "Get the prompt for the next step in an active recipe"
  [session-id orch-state recipe]
  (let [current-step (:current-step orch-state)
        step (orch/get-current-step recipe current-step)]
    (if step
      (let [expected-outcomes (:outcomes step)
            base-prompt (:prompt step)]
        (orch/append-outcome-requirements base-prompt current-step expected-outcomes))
      nil)))

(defn get-step-model
  "Get model for a step. Resolution order: step :model > recipe :model > nil"
  [recipe step-name]
  (or (get-in recipe [:steps step-name :model])
      (:model recipe)))

(defn get-available-recipes-list
  "Get list of available recipes with metadata for client.
   Dynamically reads from recipes/all-recipes."
  []
  (->> recipes/all-recipes
       vals
       (map (fn [recipe]
              {:id (name (:id recipe))
               :label (:label recipe)
               :description (:description recipe)}))
       (sort-by :label)
       vec))

(defn process-orchestration-response
  "Process Claude response when in an orchestration recipe.
   Parses JSON outcome, validates against expected outcomes, and determines next action.
   Handles guardrails (max-step-visits, max-total-steps) and sends client state updates.
   
   Returns one of:
   - {:action :next-step :step-name keyword} - transition to next step
   - {:action :exit :reason string} - exit recipe
   - {:action :retry :prompt string} - retry with reminder prompt (first failure only)"
  [session-id orch-state recipe response-text channel]
  (let [current-step (:current-step orch-state)
        step (orch/get-current-step recipe current-step)
        expected-outcomes (:outcomes step)
        outcome-result (orch/extract-orchestration-outcome response-text expected-outcomes)]
    (if (:success outcome-result)
      ;; Success - clear any retry count for this step and process outcome
      (let [outcome (:outcome outcome-result)
            next-action (orch/determine-next-action step outcome)]
        ;; Clear retry count on success
        (swap! session-orchestration-state update-in [session-id :step-retry-counts] dissoc current-step)
        (orch/log-orchestration-event "outcome-received" session-id (:recipe-id orch-state) current-step outcome)
        (case (:action next-action)
          :next-step
          (let [new-step (:step-name next-action)
                ;; Check guardrails BEFORE transitioning
                exit-reason (orch/should-exit-recipe? orch-state recipe new-step)]
            (if exit-reason
              (do
                (orch/log-orchestration-event "recipe-exited" session-id (:recipe-id orch-state) current-step
                                              {:reason exit-reason})
                (exit-recipe-for-session session-id exit-reason)
                (send-to-client! channel
                                 {:type :recipe-exited
                                  :session-id session-id
                                  :reason exit-reason})
                {:action :exit :reason exit-reason})
              ;; Update state with new step and increment counters
              ;; IMPORTANT: Use swap! with update function to preserve fields set by other code
              ;; (like :session-created? set by execute-recipe-step)
              (do
                (swap! session-orchestration-state update session-id
                       (fn [current-state]
                         (-> current-state
                             (assoc :current-step new-step)
                             (update :step-count inc)
                             (update-in [:step-visit-counts new-step] (fnil inc 0)))))
                (send-to-client! channel
                                 {:type :recipe-step-transition
                                  :session-id session-id
                                  :from-step current-step
                                  :to-step new-step})
                {:action :next-step :step-name new-step})))

          :exit
          (do
            (exit-recipe-for-session session-id (:reason next-action))
            (send-to-client! channel
                             {:type :recipe-exited
                              :session-id session-id
                              :reason (:reason next-action)})
            next-action)))
      ;; Failed to parse outcome - check if we should retry or exit
      (let [retry-count (get-in orch-state [:step-retry-counts current-step] 0)
            error-msg (:error outcome-result)]
        (if (zero? retry-count)
          ;; First failure - retry with reminder prompt
          (do
            (orch/log-orchestration-event "outcome-parse-retry" session-id (:recipe-id orch-state) current-step
                                          {:error error-msg :retry-attempt 1})
            ;; Increment retry count in state
            (swap! session-orchestration-state update-in [session-id :step-retry-counts current-step] (fnil inc 0))
            (send-to-client! channel
                             {:type :orchestration-retry
                              :session-id session-id
                              :step current-step
                              :error error-msg})
            {:action :retry
             :prompt (orch/get-outcome-reminder-prompt current-step expected-outcomes error-msg)})
          ;; Already retried - exit recipe
          (do
            (orch/log-orchestration-event "outcome-parse-error" session-id (:recipe-id orch-state) current-step
                                          {:error error-msg :retry-attempts (inc retry-count)})
            (exit-recipe-for-session session-id "orchestration-error")
            (send-to-client! channel
                             {:type :recipe-exited
                              :session-id session-id
                              :reason "orchestration-error"
                              :error (str "Agent failed to produce valid JSON outcome after retry. " error-msg)})
            {:action :exit :reason "orchestration-error"}))))))

(declare execute-recipe-step)

(defn execute-recipe-step
  "Execute a single step of a recipe and handle the response.
   This function handles the full orchestration loop:
   1. Send the step prompt to Claude
   2. Parse the outcome from the response
   3. If next step: update state and recursively continue
   4. If retry: send reminder prompt and try again (once per step)
   5. If exit: send recipe_exited message and release lock
   
   Lock management: The session lock is acquired BEFORE the first call to this function.
   The lock is only released when the recipe exits (success, error, or guardrail).
   Recursive calls (:next-step, :retry) keep the lock held.
   
   Parameters:
   - channel: WebSocket channel to send messages to
   - session-id: Claude session ID
   - working-dir: Working directory for Claude
   - orch-state: Current orchestration state
   - recipe: Recipe definition
   - prompt-override: Optional prompt to use instead of step prompt (for retries)"
  ([channel session-id working-dir orch-state recipe]
   (execute-recipe-step channel session-id working-dir orch-state recipe nil))
  ([channel session-id working-dir orch-state recipe prompt-override]
   (let [step-prompt (or prompt-override (get-next-step-prompt session-id orch-state recipe))
         current-step (:current-step orch-state)
         session-created? (:session-created? orch-state)]
     (if step-prompt
       (do
         (log/info "Executing recipe step"
                   {:session-id session-id
                    :recipe-id (:recipe-id orch-state)
                    :step current-step
                    :model (get-step-model recipe current-step)
                    :step-count (:step-count orch-state)
                    :session-created? session-created?
                    :is-retry (some? prompt-override)})

         ;; Send step transition notification (only for non-retry)
         (when-not prompt-override
           (send-to-client! channel
                            {:type :recipe-step-started
                             :session-id session-id
                             :step current-step
                             :step-count (:step-count orch-state)}))

         (claude/invoke-claude-async
          step-prompt
          (fn [response]
            (try
              (if (:success response)
                (let [response-text (:result response)
                      ;; Get fresh state in case retry count was updated or user exited
                      current-orch-state (get-session-recipe-state session-id)]
                  ;; Mark session as created after first successful invocation
                  (when (and current-orch-state (not session-created?))
                    (log/info "Marking session as created after first successful invocation"
                              {:session-id session-id})
                    (swap! session-orchestration-state
                           update session-id
                           assoc :session-created? true))
                  ;; Check if recipe was exited by user while we were waiting for Claude
                  (if (nil? current-orch-state)
                    (do
                      (log/info "Recipe was exited while waiting for Claude response"
                                {:session-id session-id})
                      ;; Recipe already exited, just release lock and send turn_complete
                      (repl/release-session-lock! session-id)
                      (send-to-client! channel
                                       {:type :turn-complete
                                        :session-id session-id}))
                    ;; Process the orchestration response normally
                    (let [result (process-orchestration-response
                                  session-id current-orch-state recipe response-text channel)]
                      (log/info "Recipe step response processed"
                                {:session-id session-id
                                 :step current-step
                                 :action (:action result)
                                 :next-step (:step-name result)
                                 :reason (:reason result)})

                      (case (:action result)
                        :next-step
                        ;; Continue to next step - get updated state and continue loop
                        ;; Lock remains held for the recursive call
                        (let [updated-orch-state (get-session-recipe-state session-id)
                              updated-recipe (recipes/get-recipe (:recipe-id updated-orch-state))]
                          (if updated-orch-state
                            ;; Recursively execute the next step (lock stays held)
                            (execute-recipe-step channel session-id working-dir
                                                 updated-orch-state updated-recipe)
                            ;; State was cleared (user exited), release lock and exit
                            (do
                              (log/warn "Orchestration state missing after step transition"
                                        {:session-id session-id})
                              (repl/release-session-lock! session-id)
                              (send-to-client! channel
                                               {:type :turn-complete
                                                :session-id session-id}))))

                        :retry
                        ;; Retry with reminder prompt - lock remains held for the recursive call
                        (let [updated-orch-state (get-session-recipe-state session-id)]
                          (if updated-orch-state
                            (do
                              (log/info "Retrying step with reminder prompt"
                                        {:session-id session-id
                                         :step current-step})
                              ;; Recursively call with the retry prompt (lock stays held)
                              (execute-recipe-step channel session-id working-dir
                                                   updated-orch-state recipe (:prompt result)))
                            ;; State was cleared (user exited), release lock and exit
                            (do
                              (log/warn "Orchestration state missing before retry"
                                        {:session-id session-id})
                              (repl/release-session-lock! session-id)
                              (send-to-client! channel
                                               {:type :turn-complete
                                                :session-id session-id}))))

                        :exit
                        ;; Recipe finished - release lock and send turn_complete
                        (do
                          (log/info "Recipe exited"
                                    {:session-id session-id
                                     :reason (:reason result)})
                          (repl/release-session-lock! session-id)
                          (send-to-client! channel
                                           {:type :turn-complete
                                            :session-id session-id}))

                        ;; Default - unexpected action, release lock and exit
                        (do
                          (log/error "Unexpected orchestration action"
                                     {:action (:action result)})
                          (repl/release-session-lock! session-id)
                          (send-to-client! channel
                                           {:type :turn-complete
                                            :session-id session-id}))))))

                ;; Claude invocation failed - release lock and exit
                (do
                  (log/error "Recipe step failed"
                             {:error (:error response) :session-id session-id})
                  (exit-recipe-for-session session-id "error")
                  (repl/release-session-lock! session-id)
                  (send-to-client! channel
                                   {:type :recipe-exited
                                    :session-id session-id
                                    :reason "error"
                                    :error (:error response)})
                  (send-to-client! channel
                                   {:type :error
                                    :message (:error response)
                                    :session-id session-id})))
              (catch Exception e
                ;; Catch any exception to ensure lock is always released
                (log/error e "Unexpected error in recipe step callback"
                           {:session-id session-id :step current-step})
                (exit-recipe-for-session session-id "internal-error")
                (repl/release-session-lock! session-id)
                (send-to-client! channel
                                 {:type :recipe-exited
                                  :session-id session-id
                                  :reason "internal-error"
                                  :error (str "Internal error: " (ex-message e))})
                (send-to-client! channel
                                 {:type :error
                                  :message (str "Internal error: " (ex-message e))
                                  :session-id session-id}))))
          ;; Conditionally use new-session-id or resume-session-id based on session-created?
          ;; For new sessions (session-created? = false), use :new-session-id (--session-id flag)
          ;; For existing sessions (session-created? = true), use :resume-session-id (--resume flag)
          (if session-created? :resume-session-id :new-session-id) session-id
          :working-directory working-dir
          :model (get-step-model recipe current-step)
          :timeout-ms 86400000))
       ;; No step prompt available - this shouldn't happen in normal operation
       ;; but we must release the lock if it does
       (do
         (log/error "No step prompt available for recipe step"
                    {:session-id session-id
                     :recipe-id (:recipe-id orch-state)
                     :step current-step})
         (exit-recipe-for-session session-id "no-prompt")
         (repl/release-session-lock! session-id)
         (send-to-client! channel
                          {:type :recipe-exited
                           :session-id session-id
                           :reason "no-prompt"
                           :error "No step prompt available"})
         (send-to-client! channel
                          {:type :turn-complete
                           :session-id session-id}))))))

;; Filesystem watcher callbacks

;; Removed duplicate comment here

(defn on-session-created
  "Called when a new session file is detected"
  [session-metadata]
  (let [session-id (:session-id session-metadata)
        client-count (count @connected-clients)
        eligible-clients (filter (fn [[channel _]]
                                   (not (is-session-deleted-for-client? channel session-id)))
                                 @connected-clients)
        eligible-count (count eligible-clients)]

    (log/info "Session created callback invoked"
              {:session-id session-id
               :name (:name session-metadata)
               :message-count (:message-count session-metadata)
               :total-clients client-count
               :eligible-clients eligible-count
               :has-preview (boolean (seq (:preview session-metadata)))})

    ;; Check if this is a pending new session and send session_ready first
    (when-let [pending-channel (get @pending-new-sessions session-id)]
      (log/info "Sending session_ready for pending new session"
                {:session-id session-id})
      (send-to-client! pending-channel
                       {:type :session-ready
                        :session-id session-id
                        :message "Session is ready for subscription"})
      ;; Remove from pending map
      (swap! pending-new-sessions dissoc session-id))

    ;; Broadcast to clients who haven't deleted this session
    (doseq [[channel client-info] eligible-clients]
      (log/debug "Sending session-created to client"
                 {:session-id session-id
                  :client-session-id (:session-id client-info)
                  :channel-id (str channel)})
      (send-to-client! channel
                       {:type :session-created
                        :session-id session-id
                        :name (:name session-metadata)
                        :working-directory (:working-directory session-metadata)
                        :last-modified (:last-modified session-metadata)
                        :message-count (:message-count session-metadata)
                        :preview (:preview session-metadata)})

      ;; Send updated recent sessions list to each client
      (let [limit (get client-info :recent-sessions-limit 5)]
        (send-recent-sessions! channel limit)))

    ;; Also send messages if client is subscribed (handles new session race condition)
    (when (repl/is-subscribed? session-id)
      (let [file-path (:file session-metadata)
            all-messages (repl/parse-jsonl-file file-path)
            messages (repl/filter-internal-messages all-messages)]
        (if (seq messages)
          (do
            (log/info "Sending initial messages for new subscribed session"
                      {:session-id session-id
                       :message-count (count messages)
                       :client-count eligible-count})
            (doseq [[channel client-info] eligible-clients]
              (send-to-client! channel
                               {:type :session-updated
                                :session-id session-id
                                :messages messages})))
          (log/debug "No messages to send for new subscribed session"
                     {:session-id session-id}))))))

(defn on-session-updated
  "Called when a subscribed session has new messages"
  [session-id new-messages]
  (let [client-count (count @connected-clients)
        eligible-clients (filter (fn [[channel _]]
                                   (not (is-session-deleted-for-client? channel session-id)))
                                 @connected-clients)
        eligible-count (count eligible-clients)]

    (log/info "Session updated callback invoked"
              {:session-id session-id
               :new-message-count (count new-messages)
               :total-clients client-count
               :eligible-clients eligible-count})

    ;; Send to all clients subscribed to this session (and haven't deleted it)
    (doseq [[channel client-info] eligible-clients]
      (log/debug "Sending session-updated to client"
                 {:session-id session-id
                  :client-session-id (:session-id client-info)
                  :new-messages (count new-messages)
                  :channel-id (str channel)})
      (send-to-client! channel
                       {:type :session-updated
                        :session-id session-id
                        :messages new-messages})

      ;; Send updated recent sessions list to each client
      (let [limit (get client-info :recent-sessions-limit 5)]
        (send-recent-sessions! channel limit)))))

(defn on-session-deleted
  "Called when a session file is deleted from filesystem"
  [session-id]
  (log/info "Session deleted from filesystem" {:session-id session-id}))
  ;; This is informational - we don't broadcast deletes since it's just local cleanup

;; Message handling
(defn handle-message
  "Handle incoming WebSocket message"
  [channel msg]
  (try
    (let [data (parse-json msg)]
      (let [msg-type (:type data)]
        (log/info "=== Received message ===" {:type msg-type :type-class (class msg-type) :type-bytes (mapv int msg-type)})

        (case msg-type
          "ping"
          (do
            (log/debug "Handling ping")
            (http/send! channel (generate-json {:type :pong})))

          "connect"
        ;; New protocol: no session-id needed, just send session list
          (do
            (log/info "Client connected")

          ;; Register client (no session-id needed in new architecture)
            (let [limit (or (:recent-sessions-limit data) 5)]
              (swap! connected-clients assoc channel {:deleted-sessions #{}
                                                      :recent-sessions-limit limit}))

          ;; Send session list (limit to 50 most recent, lightweight fields only)
            (let [all-sessions (repl/get-all-sessions)
                ;; Filter out sessions with 0 messages (after internal message filtering)
                ;; Sort by last-modified descending, take 50
                  recent-sessions (->> all-sessions
                                       (filter #(pos? (or (:message-count %) 0)))
                                       (sort-by :last-modified >)
                                       (take 50)
                                     ;; Remove heavy fields to reduce payload size
                                       (mapv #(select-keys % [:session-id :name :working-directory
                                                              :last-modified :message-count])))
                  total-non-empty (count (filter #(pos? (or (:message-count %) 0)) all-sessions))
                ;; Log any sessions with placeholder working directories
                  placeholder-sessions (filter #(str/starts-with? (or (:working-directory %) "") "[from project:") recent-sessions)]
              (when (seq placeholder-sessions)
                (log/warn "Sessions with placeholder working directories being sent to iOS"
                          {:count (count placeholder-sessions)
                           :sessions (mapv #(select-keys % [:session-id :name :working-directory]) placeholder-sessions)}))
              (log/info "Sending session list" {:count (count recent-sessions) :total total-non-empty :total-all (count all-sessions)})
              (http/send! channel
                          (generate-json
                           {:type :session-list
                            :sessions recent-sessions
                            :total-count total-non-empty}))
            ;; Send recent sessions list (separate message type for Recent section)
            ;; Use limit from client if provided, otherwise default to 5
              (let [limit (or (:recent-sessions-limit data) 5)]
                (send-recent-sessions! channel limit))
            ;; Send available commands (no working directory yet, so no project commands)
              (send-to-client! channel
                               {:type :available-commands
                                :working-directory nil
                                :project-commands []
                                :general-commands [{:id "git.status"
                                                    :label "Git Status"
                                                    :description "Show git working tree status"
                                                    :type :command}
                                                   {:id "git.push"
                                                    :label "Git Push"
                                                    :description "Push commits to remote repository"
                                                    :type :command}
                                                   {:id "git.worktree.list"
                                                    :label "Git Worktree List"
                                                    :description "List all git worktrees"
                                                    :type :command}
                                                   {:id "bd.ready"
                                                    :label "Beads Ready"
                                                    :description "Show tasks ready to work on"
                                                    :type :command}
                                                   {:id "bd.list"
                                                    :label "Beads List"
                                                    :description "List all beads tasks"
                                                    :type :command}]})))

          "subscribe"
        ;; Client requests session history with optional delta sync
          (let [session-id (:session-id data)
                last-message-id (:last-message-id data)] ;; Delta sync: UUID of newest message iOS has
            (if-not session-id
              (http/send! channel
                          (generate-json
                           {:type :error
                            :message "session_id required in subscribe message"}))
              (do
                (log/info "Client subscribing to session"
                          {:session-id session-id
                           :last-message-id last-message-id
                           :has-delta-sync (some? last-message-id)})

              ;; Subscribe in replication system
                (repl/subscribe-to-session! session-id)

              ;; Get session metadata
                (if-let [metadata (repl/get-session-metadata session-id)]
                  (let [file-path (:file metadata)
                      ;; Get current file size to update position BEFORE reading
                        file (io/file file-path)
                        current-size (.length file)
                        all-messages (repl/parse-jsonl-file file-path)
                      ;; Filter internal messages (sidechain, summary, system)
                        filtered (vec (repl/filter-internal-messages all-messages))
                      ;; Get client's max message size setting
                        max-bytes (get-client-max-message-size-bytes channel)
                      ;; Use delta sync algorithm for smart truncation
                        {:keys [messages is-complete oldest-message-id newest-message-id]}
                        (build-session-history-response filtered last-message-id max-bytes)]
                  ;; Update file position to current size so incremental parsing starts fresh
                  ;; This ensures we only get NEW messages after this subscription
                    (repl/reset-file-position! file-path)
                    (swap! repl/file-positions assoc file-path current-size)
                    (log/info "Sending session history"
                              {:session-id session-id
                               :message-count (count messages)
                               :total (count filtered)
                               :is-complete is-complete
                               :has-delta-sync (some? last-message-id)
                               :file-position current-size})
                  ;; Send session history with new delta sync fields
                  ;; Note: we bypass send-to-client! truncation since build-session-history-response
                  ;; already handled truncation with per-message limits
                    (http/send! channel
                                (generate-json
                                 {:type :session-history
                                  :session-id session-id
                                  :messages messages
                                  :total-count (count filtered)
                                  :oldest-message-id oldest-message-id
                                  :newest-message-id newest-message-id
                                  :is-complete is-complete})))
                  (do
                    (log/warn "Session not found" {:session-id session-id})
                    (http/send! channel
                                (generate-json
                                 {:type :error
                                  :message (str "Session not found: " session-id)})))))))

          "unsubscribe"
        ;; Client stops watching a session
          (let [session-id (:session-id data)]
            (when session-id
              (log/info "Client unsubscribing from session" {:session-id session-id})
              (repl/unsubscribe-from-session! session-id)))

          "session_deleted"
        ;; Client marks session as deleted locally
          (let [session-id (:session-id data)]
            (when session-id
              (log/info "Client deleted session locally" {:session-id session-id})
              (mark-session-deleted-for-client! channel session-id)
              (repl/unsubscribe-from-session! session-id)))

          "prompt"
        ;; Updated to use new_session_id vs resume_session_id
        ;; In new architecture: NO direct response - rely on filesystem watcher + subscription
          (let [new-session-id (:new-session-id data)
                resume-session-id (:resume-session-id data)
                prompt-text (:text data)
                ios-working-dir (:working-directory data)
                system-prompt (:system-prompt data)
                _ (log/info "🔍 System prompt received from iOS" {:value system-prompt :has-value? (some? system-prompt)})
              ;; Determine actual working directory to use:
              ;; - For resumed sessions: Use stored working dir from session metadata (extracted from .jsonl cwd)
              ;; - For new sessions: Use iOS-provided dir, with fallback if placeholder
                working-dir (if resume-session-id
                              (let [session-metadata (repl/get-session-metadata resume-session-id)]
                                (if session-metadata
                                  (do
                                    (log/info "Using stored working directory for resumed session"
                                              {:session-id resume-session-id
                                               :stored-dir (:working-directory session-metadata)
                                               :ios-sent-dir ios-working-dir})
                                    (:working-directory session-metadata))
                                  (do
                                    (log/warn "Session not found in metadata, using iOS working dir"
                                              {:session-id resume-session-id})
                                    ios-working-dir)))
                            ;; New session: use iOS dir, apply fallback if placeholder
                              (if (and ios-working-dir (str/starts-with? ios-working-dir "[from project:"))
                                (let [project-name (second (re-find #"\[from project: ([^\]]+)\]" ios-working-dir))]
                                  (log/info "Converting placeholder to real path for new session"
                                            {:placeholder ios-working-dir
                                             :project-name project-name})
                                  (repl/project-name->working-dir project-name))
                                ios-working-dir))]

            (cond
            ;; Check if client has connected first
              (not (contains? @connected-clients channel))
              (http/send! channel
                          (generate-json
                           {:type :error
                            :message "Must send connect message first"}))

              (not prompt-text)
              (http/send! channel
                          (generate-json
                           {:type :error
                            :message "text required in prompt message"}))

              (and new-session-id resume-session-id)
              (http/send! channel
                          (generate-json
                           {:type :error
                            :message "Cannot specify both new_session_id and resume_session_id"}))

              :else
              (let [claude-session-id (or resume-session-id new-session-id)
                    orch-state (get-session-recipe-state claude-session-id)
                    final-prompt-text (if orch-state
                                        (if-let [recipe (recipes/get-recipe (:recipe-id orch-state))]
                                          (or (get-next-step-prompt claude-session-id orch-state recipe) prompt-text)
                                          prompt-text)
                                        prompt-text)]
              ;; Try to acquire lock for this session
                (if (repl/acquire-session-lock! claude-session-id)
                  (do
                    (log/info "Received prompt"
                              {:text (subs prompt-text 0 (min 50 (count prompt-text)))
                               :new-session-id new-session-id
                               :resume-session-id resume-session-id
                               :working-directory working-dir
                               :in-recipe (some? orch-state)
                               :session-locked false})

                  ;; Send immediate acknowledgment
                    (http/send! channel
                                (generate-json
                                 {:type :ack
                                  :message "Processing prompt..."}))

;; For new sessions: register channel so we can send session_ready when file is created
                  ;; Filesystem watcher will send session_ready once Claude CLI creates the file
                    (when new-session-id
                      (log/info "New session detected, registering for session_ready" {:session-id new-session-id})
                      (swap! pending-new-sessions assoc new-session-id channel))

                  ;; Invoke Claude asynchronously
                  ;; NEW ARCHITECTURE: Don't send response directly
                  ;; Filesystem watcher will detect changes and send session_updated
                    (claude/invoke-claude-async
                     final-prompt-text
                     (fn [response]
                     ;; Always release lock when done (success or failure)
                       (try
                       ;; Just log completion - let filesystem watcher handle updates
                         (if (:success response)
                           (do
                             (log/info "Prompt completed successfully"
                                       {:session-id (:session-id response)})
                           ;; Send turn_complete message so iOS can unlock
                             (send-to-client! channel
                                              {:type :turn-complete
                                               :session-id claude-session-id}))
                           (do
                             (log/error "Prompt failed" {:error (:error response) :session-id claude-session-id})
                           ;; Still send error responses directly - include session-id so iOS can unlock
                             (send-to-client! channel
                                              {:type :error
                                               :message (:error response)
                                               :session-id claude-session-id})))
                         (finally
                           (repl/release-session-lock! claude-session-id))))
                     :new-session-id new-session-id
                     :resume-session-id resume-session-id
                     :working-directory working-dir
                     :timeout-ms 86400000
                     :system-prompt system-prompt))
                  (do
                  ;; Session is locked, send session_locked message
                    (log/info "Session locked, rejecting prompt"
                              {:session-id claude-session-id
                               :text (subs prompt-text 0 (min 50 (count prompt-text)))})
                    (send-session-locked! channel claude-session-id))))))

          "set_directory"
          (let [path (:path data)]
            (if-not path
              (http/send! channel
                          (generate-json
                           {:type :error
                            :message "path required in set_directory message"}))
              (do
                (log/info "Working directory set" {:path path})
              ;; Send acknowledgment
                (send-to-client! channel {:type :ack :message "Directory set"})
              ;; Parse Makefile and send available commands
                (let [project-commands (commands/parse-makefile path)
                      general-commands [{:id "git.status"
                                         :label "Git Status"
                                         :description "Show git working tree status"
                                         :type :command}
                                        {:id "git.push"
                                         :label "Git Push"
                                         :description "Push commits to remote repository"
                                         :type :command}
                                        {:id "git.worktree.list"
                                         :label "Git Worktree List"
                                         :description "List all git worktrees"
                                         :type :command}
                                        {:id "bd.ready"
                                         :label "Beads Ready"
                                         :description "Show tasks ready to work on"
                                         :type :command}
                                        {:id "bd.list"
                                         :label "Beads List"
                                         :description "List all beads tasks"
                                         :type :command}]]
                  (send-to-client! channel
                                   {:type :available-commands
                                    :working-directory path
                                    :project-commands project-commands
                                    :general-commands general-commands})))))

          "set_max_message_size"
          (let [size-kb (:size-kb data)]
            (if-not (and size-kb (pos-int? size-kb))
              (http/send! channel
                          (generate-json
                           {:type :error
                            :message "size_kb (positive integer) required in set_max_message_size message"}))
              (do
                (log/info "Max message size set" {:size-kb size-kb})
                (swap! connected-clients update channel assoc :max-message-size-kb size-kb)
                (send-to-client! channel {:type :ack :message (str "Max message size set to " size-kb " KB")}))))

          "message-ack"
          (let [message-id (:message-id data)]
            (log/debug "Message acknowledged" {:message-id message-id}))

          "compact_session"
          (let [session-id (:session-id data)]
            (if-not session-id
              (http/send! channel
                          (generate-json
                           {:type :error
                            :message "session_id required in compact_session message"}))
            ;; New replication-based architecture: session-id IS the claude-session-id
            ;; Try to acquire lock for this session (from bd2e367)
              (if (repl/acquire-session-lock! session-id)
                (do
                  (log/info "Compacting session" {:session-id session-id})
                ;; Compact asynchronously
                  (async/go
                    (try
                      (let [result (claude/compact-session session-id)]
                        (if (:success result)
                          (do
                            (log/info "Session compaction successful" {:session-id session-id})
                            (send-to-client! channel
                                             {:type :compaction-complete
                                              :session-id session-id}))
                          (do
                            (log/error "Session compaction failed" {:session-id session-id :error (:error result)})
                            (send-to-client! channel
                                             {:type :compaction-error
                                              :session-id session-id
                                              :error (:error result)}))))
                      (catch Exception e
                        (log/error e "Unexpected error during compaction" {:session-id session-id})
                        (send-to-client! channel
                                         {:type :compaction-error
                                          :session-id session-id
                                          :error (str "Compaction failed: " (ex-message e))}))
                      (finally
                        (repl/release-session-lock! session-id)))))
                (do
                ;; Session is locked, send session_locked message
                  (log/info "Session locked, rejecting compaction"
                            {:session-id session-id})
                  (send-session-locked! channel session-id)))))

          "kill_session"
          (let [session-id (:session-id data)]
            (if-not session-id
              (http/send! channel
                          (generate-json
                           {:type :error
                            :message "session_id required in kill_session message"}))
              (do
                (log/info "Kill session requested" {:session-id session-id})
                ;; Attempt to kill the Claude process
                (let [result (claude/kill-claude-session session-id)]
                  (if (:success result)
                    (do
                      ;; Release the session lock
                      (repl/release-session-lock! session-id)
                      (log/info "Session killed successfully" {:session-id session-id})
                      (send-to-client! channel
                                       {:type :session-killed
                                        :session-id session-id
                                        :message "Session process terminated"}))
                    (do
                      (log/error "Failed to kill session" {:session-id session-id :error (:error result)})
                      (send-to-client! channel
                                       {:type :error
                                        :message (str "Failed to kill session: " (:error result))
                                        :session-id session-id})))))))

          "infer_session_name"
          (let [session-id (:session-id data)
                message-text (:message-text data)]

            (cond
              (not session-id)
              (send-to-client! channel
                               {:type :infer-name-error
                                :error "session_id required"})

              (not message-text)
              (send-to-client! channel
                               {:type :infer-name-error
                                :error "message_text required"})

              :else
            ;; Invoke Claude for name inference asynchronously
              (async/go
                (let [result (claude/invoke-claude-for-name-inference message-text)]
                  (if (:success result)
                    (do
                      (log/info "Inferred session name"
                                {:session-id session-id
                                 :name (:name result)})
                      (send-to-client! channel
                                       {:type :session-name-inferred
                                        :session-id session-id
                                        :name (:name result)}))
                    (send-to-client! channel
                                     {:type :infer-name-error
                                      :session-id session-id
                                      :error (:error result)}))))))

          "create_worktree_session"
          (let [session-name (:session-name data)
                parent-directory (:parent-directory data)]

          ;; 1. Validate inputs
            (let [validation (worktree/validate-worktree-creation session-name parent-directory)]
              (if-not (:valid validation)
                (send-to-client! channel
                                 {:type :worktree-session-error
                                  :success false
                                  :error (:error validation)
                                  :error-type (:error-type validation)})

              ;; 2. Compute paths
                (let [paths (worktree/compute-worktree-paths session-name parent-directory)
                      {:keys [sanitized-name branch-name worktree-path]} paths

                    ;; 3. Validate paths
                      path-validation (worktree/validate-worktree-paths paths parent-directory)]

                  (if-not (:valid path-validation)
                    (send-to-client! channel
                                     {:type :worktree-session-error
                                      :success false
                                      :error (:error path-validation)
                                      :error-type (:error-type path-validation)
                                      :details (:details path-validation)})

                  ;; 4. Execute worktree creation sequence
                    (let [session-id (str (java.util.UUID/randomUUID))]
                      (log/info "Creating worktree session"
                                {:session-name session-name
                                 :parent-directory parent-directory
                                 :branch-name branch-name
                                 :worktree-path worktree-path
                                 :session-id session-id})

                    ;; Step 4a: Create git worktree
                      (let [git-result (worktree/create-worktree! parent-directory branch-name worktree-path)]
                        (if-not (:success git-result)
                          (send-to-client! channel
                                           {:type :worktree-session-error
                                            :success false
                                            :error (:error git-result)
                                            :error-type :git-failed
                                            :details {:step "git_worktree_add"
                                                      :stderr (:stderr git-result)}})

                        ;; Step 4b: Initialize Beads
                          (let [bd-result (worktree/init-beads! worktree-path)]
                            (if-not (:success bd-result)
                              (send-to-client! channel
                                               {:type :worktree-session-error
                                                :success false
                                                :error (:error bd-result)
                                                :error-type :beads-failed
                                                :details {:step "bd_init"
                                                          :stderr (:stderr bd-result)}})

                            ;; Step 4c: Invoke Claude Code
                              (let [prompt (worktree/format-worktree-prompt session-name worktree-path
                                                                            parent-directory branch-name)]
                                (claude/invoke-claude-async
                                 prompt
                                 (fn [response]
                                   (if (:success response)
                                     (send-to-client! channel
                                                      {:type :worktree-session-created
                                                       :success true
                                                       :session-id (:session-id response)
                                                       :worktree-path worktree-path
                                                       :branch-name branch-name})
                                     (send-to-client! channel
                                                      {:type :worktree-session-error
                                                       :success false
                                                       :error (:error response)
                                                       :error-type :claude-failed})))
                                 :new-session-id session-id
                                 :model "haiku"
                                 :working-directory worktree-path))))))))))))

          "execute_command"
          (let [command-id (:command-id data)
                working-directory (:working-directory data)]
            (cond
              (not command-id)
              (send-to-client! channel
                               {:type :error
                                :message "command_id required in execute_command message"})

              (not working-directory)
              (send-to-client! channel
                               {:type :error
                                :message "working_directory required in execute_command message"})

              :else
              (let [shell-command (commands/resolve-command-id command-id)
                    command-session-id (commands/generate-command-session-id)]
              ;; Create history entry
                (cmd-history/create-session-entry! command-session-id
                                                   command-id
                                                   shell-command
                                                   working-directory)
              ;; Spawn process with callbacks
                (let [result (commands/spawn-process
                              shell-command
                              working-directory
                              command-session-id
                           ;; Output callback - send each line to client
                              (fn [{:keys [stream text]}]
                                (send-to-client! channel
                                                 {:type :command-output
                                                  :command-session-id command-session-id
                                                  :stream stream
                                                  :text text}))
                           ;; Complete callback - send completion message and update history
                              (fn [{:keys [exit-code duration-ms]}]
                                (cmd-history/complete-session! command-session-id exit-code duration-ms)
                                (send-to-client! channel
                                                 {:type :command-complete
                                                  :command-session-id command-session-id
                                                  :exit-code exit-code
                                                  :duration-ms duration-ms})))]
                  (if (:success result)
                    (send-to-client! channel
                                     {:type :command-started
                                      :command-session-id command-session-id
                                      :command-id command-id
                                      :shell-command shell-command})
                    (send-to-client! channel
                                     {:type :command-error
                                      :command-id command-id
                                      :error (:error result)}))))))

          "get_command_history"
          (let [working-dir (:working-directory data)
                limit (or (:limit data) 50)
                sessions (if working-dir
                           (cmd-history/get-command-history :working-directory working-dir :limit limit)
                           (cmd-history/get-command-history :limit limit))]
            (send-to-client! channel
                             {:type :command-history
                              :sessions sessions
                              :limit limit}))

          "get_command_output"
          (let [command-session-id (:command-session-id data)]
            (if-not command-session-id
              (send-to-client! channel
                               {:type :error
                                :message "command_session_id required in get_command_output message"})
              (if-let [metadata (cmd-history/get-session-metadata command-session-id)]
                (let [output (or (cmd-history/read-output-file command-session-id) "")
                      output-size (count output)
                      max-size (* 10 1024 1024) ; 10MB limit
                      truncated? (> output-size max-size)
                      final-output (if truncated?
                                     (do
                                       (log/warn "Output exceeds 10MB limit, truncating"
                                                 {:command-session-id command-session-id
                                                  :actual-size output-size
                                                  :max-size max-size})
                                       (subs output 0 max-size))
                                     output)]
                  (send-to-client! channel
                                   {:type :command-output-full
                                    :command-session-id command-session-id
                                    :output final-output
                                    :exit-code (:exit-code metadata)
                                    :timestamp (:timestamp metadata)
                                    :duration-ms (:duration-ms metadata)
                                    :command-id (:command-id metadata)
                                    :shell-command (:shell-command metadata)
                                    :working-directory (:working-directory metadata)}))
                (send-to-client! channel
                                 {:type :error
                                  :message (str "Command output not found: " command-session-id)}))))

          "upload_file"
          (let [filename (:filename data)
                content (:content data)
                storage-location (:storage-location data)]
            (if-not (and filename content storage-location)
              (send-to-client! channel
                               {:type :error
                                :message "filename, content, and storage_location required in upload_file message"})
              (try
                (let [result (resources/upload-file! storage-location filename content)]
                  (log/info "File uploaded successfully"
                            {:filename (:filename result)
                             :path (:path result)
                             :size (:size result)})
                  (send-to-client! channel
                                   {:type :file-uploaded
                                    :filename (:filename result)
                                    :path (:path result)
                                    :size (:size result)
                                    :timestamp (:timestamp result)}))
                (catch Exception e
                  (log/error e "Failed to upload file" {:filename filename})
                  (send-to-client! channel
                                   {:type :error
                                    :message (str "Failed to upload file: " (ex-message e))})))))

          "list_resources"
          (let [storage-location (:storage-location data)]
            (if-not storage-location
              (send-to-client! channel
                               {:type :error
                                :message "storage_location required in list_resources message"})
              (try
                (let [resource-list (resources/list-resources storage-location)]
                  (log/info "Listing resources"
                            {:storage-location storage-location
                             :count (count resource-list)})
                  (send-to-client! channel
                                   {:type :resources-list
                                    :resources resource-list
                                    :storage-location storage-location}))
                (catch Exception e
                  (log/error e "Failed to list resources" {:storage-location storage-location})
                  (send-to-client! channel
                                   {:type :error
                                    :message (str "Failed to list resources: " (ex-message e))})))))

          "delete_resource"
          (let [filename (:filename data)
                storage-location (:storage-location data)]
            (if-not (and filename storage-location)
              (send-to-client! channel
                               {:type :error
                                :message "filename and storage_location required in delete_resource message"})
              (try
                (let [result (resources/delete-resource! storage-location filename)]
                  (log/info "Resource deleted successfully"
                            {:filename filename
                             :path (:path result)})
                  (send-to-client! channel
                                   {:type :resource-deleted
                                    :filename filename
                                    :path (:path result)}))
                (catch Exception e
                  (log/error e "Failed to delete resource" {:filename filename})
                  (send-to-client! channel
                                   {:type :error
                                    :message (str "Failed to delete resource: " (ex-message e))})))))

          "start_recipe"
          (let [recipe-id (keyword (:recipe-id data))
                session-id (:session-id data)
                working-directory (:working-directory data)
                is-new-session? (not (session-exists? session-id))]
            (cond
              (not session-id)
              (send-to-client! channel
                               {:type :error
                                :message "session_id required in start_recipe message"})

              (not recipe-id)
              (send-to-client! channel
                               {:type :error
                                :message "recipe_id required in start_recipe message"})

              ;; New validation: working_directory required for new sessions
              (and is-new-session? (str/blank? working-directory))
              (do
                (log/warn "New session recipe start rejected: missing working_directory"
                          {:session-id session-id :recipe-id recipe-id})
                (send-to-client! channel
                                 {:type :error
                                  :message "working_directory required for new session"
                                  :session-id session-id}))

              :else
              (if-let [orch-state (start-recipe-for-session session-id recipe-id is-new-session?)]
                (let [recipe (recipes/get-recipe recipe-id)]
                  (log/info "Recipe started" {:recipe-id recipe-id :session-id session-id})
                  (send-to-client! channel
                                   {:type :recipe-started
                                    :recipe-id recipe-id
                                    :recipe-label (:label recipe)
                                    :session-id session-id
                                    :current-step (:current-step orch-state)
                                    :step-count (:step-count orch-state)})

;; Automatically start the orchestration loop
                  (let [session-metadata (repl/get-session-metadata session-id)
                        working-dir (or working-directory
                                        (:working-directory session-metadata))]
                    (log/info "Starting recipe orchestration loop"
                              {:session-id session-id
                               :recipe-id recipe-id
                               :step (:current-step orch-state)
                               :working-directory working-dir})
                    ;; Try to acquire lock and start orchestration loop
                    (if (repl/acquire-session-lock! session-id)
                      (do
                        (send-to-client! channel
                                         {:type :ack
                                          :message "Starting recipe..."})
                        ;; Execute the first step - this will recursively continue
                        ;; through all steps until recipe exits
                        (execute-recipe-step channel session-id working-dir
                                             orch-state recipe))
                      (do
                        ;; Session is locked, clean up the recipe state we just created
                        (log/warn "Session locked, cannot start recipe"
                                  {:session-id session-id})
                        (exit-recipe-for-session session-id "session-locked")
                        (send-session-locked! channel session-id)))))
                (send-to-client! channel
                                 {:type :error
                                  :message (str "Recipe not found: " recipe-id)}))))

          "exit_recipe"
          (let [session-id (:session-id data)]
            (if-not session-id
              (send-to-client! channel
                               {:type :error
                                :message "session_id required in exit_recipe message"})
              (do
                (exit-recipe-for-session session-id "user-requested")
                (log/info "Recipe exited" {:session-id session-id})
                (send-to-client! channel
                                 {:type :recipe-exited
                                  :session-id session-id
                                  :reason "user-requested"}))))

          "get_available_recipes"
          (do
            (log/info "Sending available recipes")
            (send-to-client! channel
                             {:type :available-recipes
                              :recipes (get-available-recipes-list)}))

        ;; Unknown message type
          (do
            (log/warn "Unknown message type" {:type (:type data)})
            (http/send! channel
                        (generate-json
                         {:type :error
                          :message (str "Unknown message type: " (:type data))}))))))

    (catch Exception e
      (log/error e "Error handling message")
      (http/send! channel
                  (generate-json
                   {:type :error
                    :message (str "Error processing message: " (ex-message e))})))))

;; HTTP Upload handler
(defn handle-http-upload
  "Handle HTTP POST /upload requests for synchronous file uploads from share extension.
  Expects multipart/form-data with fields: filename, content (base64), storage_location"
  [req channel]
  (try
    (let [body (slurp (:body req))
          data (parse-json body)
          filename (:filename data)
          content (:content data)
          storage-location (:storage-location data)]

      (if-not (and filename content storage-location)
        (http/send! channel
                    {:status 400
                     :headers {"Content-Type" "application/json"}
                     :body (generate-json
                            {:success false
                             :error "filename, content, and storage_location are required"})})
        (try
          (let [result (resources/upload-file! storage-location filename content)
                absolute-path (str (resources/expand-path storage-location) "/" (:path result))]
            (log/info "HTTP upload successful"
                      {:filename (:filename result)
                       :size (:size result)
                       :path absolute-path})
            (http/send! channel
                        {:status 200
                         :headers {"Content-Type" "application/json"}
                         :body (generate-json
                                {:success true
                                 :filename (:filename result)
                                 :path absolute-path
                                 :relative-path (:path result)
                                 :size (:size result)
                                 :timestamp (.toString (:timestamp result))})}))
          (catch IllegalArgumentException e
            (log/error "Invalid base64 content in HTTP upload" {:filename filename})
            (http/send! channel
                        {:status 400
                         :headers {"Content-Type" "application/json"}
                         :body (generate-json
                                {:success false
                                 :error "Invalid file content encoding"})}))
          (catch clojure.lang.ExceptionInfo e
            (let [data (ex-data e)]
              (log/error e "HTTP upload failed" data)
              (http/send! channel
                          {:status (if (= "Resource not found" (ex-message e)) 404 400)
                           :headers {"Content-Type" "application/json"}
                           :body (generate-json
                                  {:success false
                                   :error (ex-message e)
                                   :details data})})))
          (catch Exception e
            (log/error e "Unexpected error in HTTP upload" {:filename filename})
            (http/send! channel
                        {:status 500
                         :headers {"Content-Type" "application/json"}
                         :body (generate-json
                                {:success false
                                 :error (str "Failed to upload file: " (ex-message e))})})))))
    (catch Exception e
      (log/error e "Error parsing HTTP upload request")
      (http/send! channel
                  {:status 400
                   :headers {"Content-Type" "application/json"}
                   :body (generate-json
                          {:success false
                           :error (str "Invalid request: " (ex-message e))})}))))

;; WebSocket handler
(defn websocket-handler
  "Handle WebSocket connections and HTTP upload requests"
  [request]
  ;; Check for HTTP POST to /upload BEFORE with-channel
  (if (and (= :post (:request-method request))
           (= "/upload" (:uri request)))
    ;; Handle synchronous HTTP upload
    (let [response (atom nil)]
      (http/with-channel request channel
        (handle-http-upload request channel)
        ;; For synchronous response, we don't keep the channel open
        (http/close channel)))

    ;; Handle WebSocket connections
    (http/with-channel request channel
      (if (http/websocket? channel)
        (do
          (log/info "WebSocket connection established" {:remote-addr (:remote-addr request)})

          ;; Send hello message
          (http/send! channel
                      (generate-json
                       {:type :hello
                        :message "Welcome to voice-code backend"
                        :version "0.2.0"}))

          ;; Handle incoming messages
          (http/on-receive channel
                           (fn [msg]
                             (handle-message channel msg)))

          ;; Handle connection close
          (http/on-close channel
                         (fn [status]
                           (log/info "WebSocket connection closed" {:status status})
                           (unregister-channel! channel))))

        ;; Not a WebSocket request and not /upload
        (http/send! channel
                    {:status 400
                     :headers {"Content-Type" "text/plain"}
                     :body "This endpoint requires WebSocket connection"})))))

(defn -main
  "Start the WebSocket server"
  [& args]
  (let [config (load-config)
        port (get-in config [:server :port] 8080)
        host (get-in config [:server :host] "0.0.0.0")
        default-dir (get-in config [:claude :default-working-directory])]

    ;; Initialize replication system
    (log/info "Initializing session replication system")
    (repl/initialize-index!)

    ;; Start filesystem watcher
    (try
      (repl/start-watcher!
       :on-session-created on-session-created
       :on-session-updated on-session-updated
       :on-session-deleted on-session-deleted)
      (log/info "Filesystem watcher started successfully")
      (catch Exception e
        (log/error e "Failed to start filesystem watcher")))

    (log/info "Starting voice-code server"
              {:port port
               :host host
               :default-working-directory default-dir})

    (let [server (http/run-server websocket-handler {:port port :host host})]
      (reset! server-state server)

      ;; Add graceful shutdown hook
      (.addShutdownHook
       (Runtime/getRuntime)
       (Thread. (fn []
                  (log/info "Shutting down voice-code server gracefully")
                  ;; Stop filesystem watcher
                  (repl/stop-watcher!)
                  ;; Save session index
                  (repl/save-index! @repl/session-index)
                  ;; Stop HTTP server with 100ms timeout
                  (when @server-state
                    (@server-state :timeout 100))
                  (log/info "Server shutdown complete"))))

      (println (format "✓ Voice-code WebSocket server running on ws://%s:%d" host port))
      (when default-dir
        (println (format "  Default working directory: %s" default-dir)))
      (println "  Ready for connections. Press Ctrl+C to stop.")

      ;; Keep main thread alive
      @(promise))))
