(ns voice-code.persistence
  "Persistence layer for voice-code app.
   Provides SQLite storage for sessions/messages and Keychain for API key."
  (:require [re-frame.core :as rf]
            [voice-code.db :as db]))

;; ============================================================================
;; SQLite Database (stub implementation for Node.js testing)
;; Real implementation requires react-native-sqlite-storage
;; ============================================================================

(defonce ^:private db-atom (atom nil))

(def ^:private create-sessions-sql
  "CREATE TABLE IF NOT EXISTS sessions (
     id TEXT PRIMARY KEY,
     backend_name TEXT,
     custom_name TEXT,
     working_directory TEXT,
     last_modified TEXT,
     message_count INTEGER DEFAULT 0,
     preview TEXT,
     queue_position INTEGER,
     priority INTEGER DEFAULT 10,
     priority_order REAL DEFAULT 1.0,
     is_user_deleted INTEGER DEFAULT 0
   )")

(def ^:private create-messages-sql
  "CREATE TABLE IF NOT EXISTS messages (
     id TEXT PRIMARY KEY,
     session_id TEXT,
     role TEXT,
     text TEXT,
     timestamp TEXT,
     status TEXT,
     FOREIGN KEY (session_id) REFERENCES sessions(id)
   )")

(def ^:private create-settings-sql
  "CREATE TABLE IF NOT EXISTS settings (
     key TEXT PRIMARY KEY,
     value TEXT
   )")

;; ============================================================================
;; Database Initialization
;; ============================================================================

(defn- execute-sql!
  "Execute SQL on the database. Stub implementation stores in memory."
  [db sql params]
  ;; In real implementation, this would call:
  ;; (.executeSql db sql (clj->js params))
  ;; For now, we just log and track state
  (js/console.log "SQL:" sql))

(defn init-db!
  "Initialize SQLite database with schema.
   Returns a promise that resolves when complete."
  []
  (js/Promise.
   (fn [resolve _reject]
     ;; In real implementation:
     ;; (let [db (sqlite/openDatabase #js {:name "voicecode.db"})]
     ;;   (execute-sql! db create-sessions-sql [])
     ;;   (execute-sql! db create-messages-sql [])
     ;;   (execute-sql! db create-settings-sql [])
     ;;   (reset! db-atom db)
     ;;   (resolve db))

     ;; Stub: use in-memory storage
     (reset! db-atom {:sessions {} :messages {} :settings {}})
     (js/console.log "SQLite initialized (stub mode)")
     (resolve @db-atom))))

;; ============================================================================
;; Session Persistence
;; ============================================================================

(defn- session->row
  "Convert session map to database row format."
  [{:keys [id backend-name custom-name working-directory last-modified
           message-count preview queue-position priority priority-order
           is-user-deleted]}]
  {:id id
   :backend_name backend-name
   :custom_name custom-name
   :working_directory working-directory
   :last_modified (when last-modified (.toISOString last-modified))
   :message_count (or message-count 0)
   :preview preview
   :queue_position queue-position
   :priority (or priority 10)
   :priority_order (or priority-order 1.0)
   :is_user_deleted (if is-user-deleted 1 0)})

(defn- row->session
  "Convert database row to session map."
  [{:keys [id backend_name custom_name working_directory last_modified
           message_count preview queue_position priority priority_order
           is_user_deleted]}]
  {:id id
   :backend-name backend_name
   :custom-name custom_name
   :working-directory working_directory
   :last-modified (when last_modified (js/Date. last_modified))
   :message-count message_count
   :preview preview
   :queue-position queue_position
   :priority priority
   :priority-order priority_order
   :is-user-deleted (= is_user_deleted 1)})

(defn save-session!
  "Save a session to SQLite."
  [session]
  (when-let [db @db-atom]
    ;; In real implementation:
    ;; (let [row (session->row session)]
    ;;   (execute-sql! db
    ;;     "INSERT OR REPLACE INTO sessions (...) VALUES (...)"
    ;;     (vals row)))

    ;; Stub: store in memory
    (swap! db-atom assoc-in [:sessions (:id session)] session)
    (js/console.log "Saved session:" (:id session))))

(defn load-sessions!
  "Load all sessions from SQLite.
   Returns a promise resolving to vector of sessions."
  []
  (js/Promise.
   (fn [resolve _reject]
     (if-let [db @db-atom]
       ;; In real implementation:
       ;; (execute-sql! db "SELECT * FROM sessions WHERE is_user_deleted = 0" []
       ;;   (fn [_tx results]
       ;;     (let [rows (-> results .-rows .-_array js->clj)
       ;;           sessions (mapv row->session rows)]
       ;;       (resolve sessions))))

       ;; Stub: return from memory
       (let [sessions (vals (:sessions db))]
         (resolve (vec sessions)))

       (resolve [])))))

(defn delete-session!
  "Mark a session as deleted (soft delete)."
  [session-id]
  (when-let [db @db-atom]
    ;; In real implementation:
    ;; (execute-sql! db
    ;;   "UPDATE sessions SET is_user_deleted = 1 WHERE id = ?"
    ;;   [session-id])

    ;; Stub: remove from memory
    (swap! db-atom update :sessions dissoc session-id)
    (js/console.log "Deleted session:" session-id)))

;; ============================================================================
;; Message Persistence
;; ============================================================================

(defn- message->row
  "Convert message map to database row format."
  [{:keys [id session-id role text timestamp status]}]
  {:id (str id)
   :session_id session-id
   :role (name role)
   :text text
   :timestamp (when timestamp (.toISOString timestamp))
   :status (name (or status :confirmed))})

(defn- row->message
  "Convert database row to message map."
  [{:keys [id session_id role text timestamp status]}]
  {:id id
   :session-id session_id
   :role (keyword role)
   :text text
   :timestamp (when timestamp (js/Date. timestamp))
   :status (keyword status)})

(defn save-message!
  "Save a message to SQLite."
  [message]
  (when-let [db @db-atom]
    ;; In real implementation:
    ;; (let [row (message->row message)]
    ;;   (execute-sql! db
    ;;     "INSERT OR REPLACE INTO messages (...) VALUES (...)"
    ;;     (vals row)))

    ;; Stub: store in memory
    (let [session-id (:session-id message)]
      (swap! db-atom update-in [:messages session-id]
             (fnil conj []) message))
    (js/console.log "Saved message:" (:id message))))

(defn save-messages!
  "Save multiple messages to SQLite."
  [session-id messages]
  (doseq [msg messages]
    (save-message! (assoc msg :session-id session-id))))

(defn load-messages!
  "Load messages for a session from SQLite.
   Returns a promise resolving to vector of messages."
  [session-id]
  (js/Promise.
   (fn [resolve _reject]
     (if-let [db @db-atom]
       ;; In real implementation:
       ;; (execute-sql! db
       ;;   "SELECT * FROM messages WHERE session_id = ? ORDER BY timestamp"
       ;;   [session-id]
       ;;   (fn [_tx results]
       ;;     (let [rows (-> results .-rows .-_array js->clj)
       ;;           messages (mapv row->message rows)]
       ;;       (resolve messages))))

       ;; Stub: return from memory
       (let [messages (get-in db [:messages session-id] [])]
         (resolve (vec messages)))

       (resolve [])))))

(defn clear-messages!
  "Delete all messages for a session."
  [session-id]
  (when-let [db @db-atom]
    ;; In real implementation:
    ;; (execute-sql! db
    ;;   "DELETE FROM messages WHERE session_id = ?"
    ;;   [session-id])

    ;; Stub: clear from memory
    (swap! db-atom update :messages dissoc session-id)
    (js/console.log "Cleared messages for session:" session-id)))

;; ============================================================================
;; Settings Persistence
;; ============================================================================

(defn save-setting!
  "Save a setting to SQLite."
  [key value]
  (when-let [db @db-atom]
    ;; In real implementation:
    ;; (execute-sql! db
    ;;   "INSERT OR REPLACE INTO settings (key, value) VALUES (?, ?)"
    ;;   [(name key) (pr-str value)])

    ;; Stub: store in memory
    (swap! db-atom assoc-in [:settings key] value)
    (js/console.log "Saved setting:" key)))

(defn load-setting!
  "Load a setting from SQLite.
   Returns a promise resolving to the value or nil."
  [key]
  (js/Promise.
   (fn [resolve _reject]
     (if-let [db @db-atom]
       ;; In real implementation:
       ;; (execute-sql! db
       ;;   "SELECT value FROM settings WHERE key = ?"
       ;;   [(name key)]
       ;;   (fn [_tx results]
       ;;     (if (> (-> results .-rows .-length) 0)
       ;;       (resolve (-> results .-rows .-_array first .-value cljs.reader/read-string))
       ;;       (resolve nil))))

       ;; Stub: return from memory
       (resolve (get-in db [:settings key]))

       (resolve nil)))))

(defn load-all-settings!
  "Load all settings from SQLite.
   Returns a promise resolving to a map of settings."
  []
  (js/Promise.
   (fn [resolve _reject]
     (if-let [db @db-atom]
       ;; Stub: return from memory
       (resolve (:settings db {}))
       (resolve {})))))

;; ============================================================================
;; Keychain Storage (API Key)
;; ============================================================================

(defonce ^:private keychain-atom (atom nil))

(defn store-api-key!
  "Store API key securely in Keychain.
   Returns a promise."
  [api-key]
  (js/Promise.
   (fn [resolve reject]
     ;; In real implementation:
     ;; (.setGenericPassword keychain "voicecode" api-key)

     ;; Stub: store in memory
     (reset! keychain-atom api-key)
     (js/console.log "API key stored (stub mode)")
     (resolve true))))

(defn retrieve-api-key!
  "Retrieve API key from Keychain.
   Returns a promise resolving to the API key or nil."
  []
  (js/Promise.
   (fn [resolve _reject]
     ;; In real implementation:
     ;; (-> (.getGenericPassword keychain)
     ;;     (.then #(if % (.-password %) nil))
     ;;     (.then resolve)
     ;;     (.catch #(resolve nil)))

     ;; Stub: return from memory
     (resolve @keychain-atom))))

(defn delete-api-key!
  "Delete API key from Keychain.
   Returns a promise."
  []
  (js/Promise.
   (fn [resolve _reject]
     ;; In real implementation:
     ;; (.resetGenericPassword keychain)

     ;; Stub: clear from memory
     (reset! keychain-atom nil)
     (js/console.log "API key deleted (stub mode)")
     (resolve true))))

;; ============================================================================
;; re-frame Effect Handlers
;; ============================================================================

(rf/reg-fx
 :persistence/init-db
 (fn [_]
   (-> (init-db!)
       (.then #(rf/dispatch [:persistence/db-initialized])))))

(rf/reg-fx
 :persistence/save-session
 (fn [session]
   (save-session! session)))

(rf/reg-fx
 :persistence/save-message
 (fn [{:keys [session-id message]}]
   (save-message! (assoc message :session-id session-id))))

(rf/reg-fx
 :persistence/load-sessions
 (fn [_]
   (-> (load-sessions!)
       (.then #(rf/dispatch [:sessions/add-many %])))))

(rf/reg-fx
 :persistence/load-messages
 (fn [session-id]
   (-> (load-messages! session-id)
       (.then #(rf/dispatch [:messages/add-many session-id %])))))

(rf/reg-fx
 :persistence/save-setting
 (fn [[key value]]
   (save-setting! key value)))

(rf/reg-fx
 :persistence/load-settings
 (fn [_]
   (-> (load-all-settings!)
       (.then #(doseq [[k v] %]
                 (rf/dispatch [:settings/update k v]))))))

(rf/reg-fx
 :persistence/store-api-key
 (fn [api-key]
   (-> (store-api-key! api-key)
       (.then #(rf/dispatch [:persistence/api-key-stored])))))

(rf/reg-fx
 :persistence/load-api-key
 (fn [_]
   (-> (retrieve-api-key!)
       (.then #(when %
                 (rf/dispatch [:persistence/api-key-loaded %]))))))

(rf/reg-fx
 :persistence/delete-api-key
 (fn [_]
   (-> (delete-api-key!)
       (.then #(rf/dispatch [:persistence/api-key-deleted])))))

;; ============================================================================
;; re-frame Event Handlers
;; ============================================================================

(rf/reg-event-db
 :persistence/db-initialized
 (fn [db _]
   (js/console.log "Database initialized")
   db))

(rf/reg-event-db
 :persistence/api-key-stored
 (fn [db _]
   (js/console.log "API key stored successfully")
   db))

(rf/reg-event-fx
 :persistence/api-key-loaded
 (fn [{:keys [db]} [_ api-key]]
   {:db (assoc db :api-key api-key)}))

(rf/reg-event-db
 :persistence/api-key-deleted
 (fn [db _]
   (assoc db :api-key nil)))

(rf/reg-event-fx
 :persistence/save-api-key
 (fn [_ [_ api-key]]
   {:persistence/store-api-key api-key}))

;; Placeholder events referenced in events/core.cljs
(rf/reg-event-fx
 :persistence/load-api-key
 (fn [_ _]
   {:persistence/load-api-key nil}))

(rf/reg-event-fx
 :persistence/load-settings
 (fn [_ _]
   {:persistence/load-settings nil}))

(rf/reg-event-fx
 :persistence/save-setting
 (fn [_ [_ key value]]
   {:persistence/save-setting [key value]}))

(rf/reg-event-fx
 :persistence/save-message
 (fn [{:keys [db]} [_ session-id]]
   (let [messages (get-in db [:messages session-id])
         last-msg (last messages)]
     (when last-msg
       {:persistence/save-message {:session-id session-id
                                   :message last-msg}}))))
