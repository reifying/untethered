(ns voice-code.db
  "re-frame app-db schema and initialization.
   Mirrors iOS CoreData schema with idiomatic Clojure structures.")

(def default-db
  "Initial application state."
  {:connection {:status :disconnected ; :disconnected | :connecting | :connected
                :authenticated? false
                :error nil
                :reconnect-attempts 0}

   ;; Sessions indexed by session-id
   ;; Each session: {:id :backend-name :custom-name :working-directory
   ;;                :last-modified :message-count :preview :queue-position
   ;;                :priority :priority-order :is-user-deleted}
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

   ;; Command execution state
   :commands {:available {} ; working-dir -> command tree
              :running {} ; command-session-id -> command state
              :history []} ; Recent command executions

   ;; Resource/file upload state
   :resources {:list [] ; Uploaded files
               :pending-uploads 0}

   ;; Recipe orchestration state
   :recipes {:available [] ; Recipe definitions
             :active {}} ; session-id -> active recipe

   ;; Application settings
   :settings {:server-url "localhost"
              :server-port 3000
              :voice-identifier nil
              :recent-sessions-limit 10
              :max-message-size-kb 200}

   ;; UI state
   :ui {:loading? false
        :current-error nil
        :drafts {}}}) ; session-id -> draft text

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
