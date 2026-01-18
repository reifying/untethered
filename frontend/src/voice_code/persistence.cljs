(ns voice-code.persistence
  "Persistence layer for voice-code app.
   Provides SQLite storage for sessions/messages and Keychain for API key."
  (:require [re-frame.core :as rf]
            [voice-code.db :as db]
            [clojure.edn :as edn]))

;; ============================================================================
;; SQLite Database (stub implementation for Node.js testing)
;; Real implementation requires react-native-sqlite-storage
;; ============================================================================

(defonce ^:private db-atom (atom nil))

;; Feature flag for using real SQLite vs stub (disabled in Node.js tests)
(def ^:private use-real-sqlite?
  (and (exists? js/navigator)
       (not= "node" (.-product js/navigator))))

;; Dynamically loaded SQLite module (only in React Native environment)
(defonce ^:private sqlite-module
  (when use-real-sqlite?
    (try
      (let [sqlite (js/require "react-native-sqlite-storage")]
        ;; Enable debug mode for development
        (when ^boolean goog.DEBUG
          (.DEBUG sqlite true))
        sqlite)
      (catch :default e
        (js/console.warn "react-native-sqlite-storage not available:" e)
        nil))))

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
  "Execute SQL on the database. Returns a promise.
   In real mode, executes against SQLite.
   In stub mode, logs and returns resolved promise."
  ([db sql]
   (execute-sql! db sql []))
  ([db sql params]
   (js/Promise.
    (fn [resolve reject]
      (if (and use-real-sqlite? sqlite-module db)
        ;; Real SQLite execution
        (.transaction db
                      (fn [tx]
                        (.executeSql tx sql (clj->js params)
                                     (fn [_tx results]
                                       (resolve results))
                                     (fn [_tx error]
                                       (js/console.error "SQL error:" error)
                                       (reject error)))))
        ;; Stub mode - just log
        (do
          (when ^boolean goog.DEBUG
            (js/console.log "SQL (stub):" sql))
          (resolve nil)))))))

(defn init-db!
  "Initialize SQLite database with schema.
   Returns a promise that resolves when complete."
  []
  (js/Promise.
   (fn [resolve reject]
     (if (and use-real-sqlite? sqlite-module)
       ;; Real SQLite implementation
       (try
         (let [db (.openDatabase sqlite-module #js {:name "voicecode.db"
                                                    :location "default"})]
           (reset! db-atom db)
           (-> (execute-sql! db create-sessions-sql)
               (.then #(execute-sql! db create-messages-sql))
               (.then #(execute-sql! db create-settings-sql))
               (.then (fn [_]
                        (js/console.log "SQLite initialized successfully")
                        (resolve db)))
               (.catch (fn [error]
                         (js/console.error "SQLite schema creation failed:" error)
                         (reject error)))))
         (catch :default e
           (js/console.error "SQLite open failed:" e)
           (reject e)))
       ;; Stub: use in-memory storage
       (do
         (reset! db-atom {:sessions {} :messages {} :settings {}})
         (js/console.log "SQLite initialized (stub mode)")
         (resolve @db-atom))))))

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
  "Save a session to SQLite. Returns a promise."
  [session]
  (if-let [db @db-atom]
    (if (and use-real-sqlite? sqlite-module)
      ;; Real SQLite
      (let [{:keys [id backend_name custom_name working_directory last_modified
                    message_count preview queue_position priority priority_order
                    is_user_deleted]} (session->row session)]
        (execute-sql! db
                      "INSERT OR REPLACE INTO sessions 
                       (id, backend_name, custom_name, working_directory, last_modified,
                        message_count, preview, queue_position, priority, priority_order, is_user_deleted)
                       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
                      [id backend_name custom_name working_directory last_modified
                       message_count preview queue_position priority priority_order is_user_deleted]))
      ;; Stub mode
      (do
        (swap! db-atom assoc-in [:sessions (:id session)] session)
        (js/console.log "Saved session (stub):" (:id session))
        (js/Promise.resolve nil)))
    (js/Promise.resolve nil)))

(defn load-sessions!
  "Load all sessions from SQLite.
   Returns a promise resolving to vector of sessions."
  []
  (js/Promise.
   (fn [resolve reject]
     (if-let [db @db-atom]
       (if (and use-real-sqlite? sqlite-module)
         ;; Real SQLite
         (-> (execute-sql! db "SELECT * FROM sessions WHERE is_user_deleted = 0")
             (.then (fn [results]
                      (let [rows (-> results .-rows)
                            len (.-length rows)
                            sessions (for [i (range len)]
                                       (-> (.item rows i)
                                           (js->clj :keywordize-keys true)
                                           row->session))]
                        (resolve (vec sessions)))))
             (.catch (fn [error]
                       (js/console.error "Failed to load sessions:" error)
                       (reject error))))
         ;; Stub mode
         (let [sessions (vals (:sessions db))]
           (resolve (vec sessions))))
       (resolve [])))))

(defn delete-session!
  "Mark a session as deleted (soft delete). Returns a promise."
  [session-id]
  (if-let [db @db-atom]
    (if (and use-real-sqlite? sqlite-module)
      ;; Real SQLite
      (execute-sql! db
                    "UPDATE sessions SET is_user_deleted = 1 WHERE id = ?"
                    [session-id])
      ;; Stub mode
      (do
        (swap! db-atom update :sessions dissoc session-id)
        (js/console.log "Deleted session (stub):" session-id)
        (js/Promise.resolve nil)))
    (js/Promise.resolve nil)))

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
  "Save a message to SQLite. Returns a promise."
  [message]
  (if-let [db @db-atom]
    (if (and use-real-sqlite? sqlite-module)
      ;; Real SQLite
      (let [{:keys [id session_id role text timestamp status]} (message->row message)]
        (execute-sql! db
                      "INSERT OR REPLACE INTO messages 
                       (id, session_id, role, text, timestamp, status)
                       VALUES (?, ?, ?, ?, ?, ?)"
                      [id session_id role text timestamp status]))
      ;; Stub mode
      (let [session-id (:session-id message)]
        (swap! db-atom update-in [:messages session-id]
               (fnil conj []) message)
        (js/console.log "Saved message (stub):" (:id message))
        (js/Promise.resolve nil)))
    (js/Promise.resolve nil)))

(defn save-messages!
  "Save multiple messages to SQLite. Returns a promise."
  [session-id messages]
  (js/Promise.all
   (clj->js (map #(save-message! (assoc % :session-id session-id)) messages))))

(defn load-messages!
  "Load messages for a session from SQLite.
   Returns a promise resolving to vector of messages."
  [session-id]
  (js/Promise.
   (fn [resolve reject]
     (if-let [db @db-atom]
       (if (and use-real-sqlite? sqlite-module)
         ;; Real SQLite
         (-> (execute-sql! db
                           "SELECT * FROM messages WHERE session_id = ? ORDER BY timestamp"
                           [session-id])
             (.then (fn [results]
                      (let [rows (-> results .-rows)
                            len (.-length rows)
                            messages (for [i (range len)]
                                       (-> (.item rows i)
                                           (js->clj :keywordize-keys true)
                                           row->message))]
                        (resolve (vec messages)))))
             (.catch (fn [error]
                       (js/console.error "Failed to load messages:" error)
                       (reject error))))
         ;; Stub mode
         (let [messages (get-in db [:messages session-id] [])]
           (resolve (vec messages))))
       (resolve [])))))

(defn clear-messages!
  "Delete all messages for a session. Returns a promise."
  [session-id]
  (if-let [db @db-atom]
    (if (and use-real-sqlite? sqlite-module)
      ;; Real SQLite
      (execute-sql! db
                    "DELETE FROM messages WHERE session_id = ?"
                    [session-id])
      ;; Stub mode
      (do
        (swap! db-atom update :messages dissoc session-id)
        (js/console.log "Cleared messages (stub) for session:" session-id)
        (js/Promise.resolve nil)))
    (js/Promise.resolve nil)))

;; ============================================================================
;; Settings Persistence
;; ============================================================================

(defn save-setting!
  "Save a setting to SQLite. Returns a promise."
  [key value]
  (if-let [db @db-atom]
    (if (and use-real-sqlite? sqlite-module)
      ;; Real SQLite - store value as EDN string
      (execute-sql! db
                    "INSERT OR REPLACE INTO settings (key, value) VALUES (?, ?)"
                    [(name key) (pr-str value)])
      ;; Stub mode
      (do
        (swap! db-atom assoc-in [:settings key] value)
        (js/console.log "Saved setting (stub):" key)
        (js/Promise.resolve nil)))
    (js/Promise.resolve nil)))

(defn load-setting!
  "Load a setting from SQLite.
   Returns a promise resolving to the value or nil."
  [key]
  (js/Promise.
   (fn [resolve reject]
     (if-let [db @db-atom]
       (if (and use-real-sqlite? sqlite-module)
         ;; Real SQLite
         (-> (execute-sql! db
                           "SELECT value FROM settings WHERE key = ?"
                           [(name key)])
             (.then (fn [results]
                      (let [rows (-> results .-rows)]
                        (if (> (.-length rows) 0)
                          (let [value-str (.-value (.item rows 0))]
                            (resolve (edn/read-string value-str)))
                          (resolve nil)))))
             (.catch (fn [error]
                       (js/console.error "Failed to load setting:" error)
                       (reject error))))
         ;; Stub mode
         (resolve (get-in db [:settings key])))
       (resolve nil)))))

(defn load-all-settings!
  "Load all settings from SQLite.
   Returns a promise resolving to a map of settings."
  []
  (js/Promise.
   (fn [resolve reject]
     (if-let [db @db-atom]
       (if (and use-real-sqlite? sqlite-module)
         ;; Real SQLite
         (-> (execute-sql! db "SELECT key, value FROM settings")
             (.then (fn [results]
                      (let [rows (-> results .-rows)
                            len (.-length rows)
                            settings (into {}
                                           (for [i (range len)]
                                             (let [row (.item rows i)]
                                               [(keyword (.-key row))
                                                (edn/read-string (.-value row))])))]
                        (resolve settings))))
             (.catch (fn [error]
                       (js/console.error "Failed to load settings:" error)
                       (reject error))))
         ;; Stub mode
         (resolve (:settings db {})))
       (resolve {})))))

;; ============================================================================
;; Keychain Storage (API Key)
;; ============================================================================

;; Keychain atom for fallback/test mode only
(defonce ^:private keychain-atom (atom nil))

;; Feature flag for using real keychain vs stub (disabled in Node.js tests)
(def ^:private use-real-keychain?
  (and (exists? js/navigator)
       (not= "node" (.-product js/navigator))))

;; Dynamically loaded keychain module (only in React Native environment)
(defonce ^:private keychain-module
  (when use-real-keychain?
    (try
      (js/require "react-native-keychain")
      (catch :default e
        (js/console.warn "react-native-keychain not available:" e)
        nil))))

(defn store-api-key!
  "Store API key securely in Keychain.
   Returns a promise."
  [api-key]
  (if (and use-real-keychain? keychain-module)
    ;; Real implementation using react-native-keychain
    (-> (.setGenericPassword keychain-module "voicecode" api-key)
        (.then (fn [result]
                 (js/console.log "API key stored in Keychain")
                 result))
        (.catch (fn [error]
                  (js/console.error "Failed to store API key:" error)
                  ;; Fall back to memory
                  (reset! keychain-atom api-key)
                  true)))
    ;; Stub: store in memory (for Node.js tests)
    (js/Promise.
     (fn [resolve _reject]
       (reset! keychain-atom api-key)
       (js/console.log "API key stored (stub mode)")
       (resolve true)))))

(defn retrieve-api-key!
  "Retrieve API key from Keychain.
   Returns a promise resolving to the API key or nil."
  []
  (if (and use-real-keychain? keychain-module)
    ;; Real implementation using react-native-keychain
    (-> (.getGenericPassword keychain-module)
        (.then (fn [credentials]
                 (if credentials
                   (do
                     (js/console.log "API key retrieved from Keychain")
                     (.-password credentials))
                   (do
                     (js/console.log "No API key found in Keychain")
                     nil))))
        (.catch (fn [error]
                  (js/console.error "Failed to retrieve API key:" error)
                  ;; Fall back to memory
                  @keychain-atom)))
    ;; Stub: return from memory (for Node.js tests)
    (js/Promise.
     (fn [resolve _reject]
       (resolve @keychain-atom)))))

(defn delete-api-key!
  "Delete API key from Keychain.
   Returns a promise."
  []
  (if (and use-real-keychain? keychain-module)
    ;; Real implementation using react-native-keychain
    (-> (.resetGenericPassword keychain-module)
        (.then (fn [result]
                 (js/console.log "API key deleted from Keychain")
                 (reset! keychain-atom nil)
                 result))
        (.catch (fn [error]
                  (js/console.error "Failed to delete API key:" error)
                  (reset! keychain-atom nil)
                  true)))
    ;; Stub: clear from memory (for Node.js tests)
    (js/Promise.
     (fn [resolve _reject]
       (reset! keychain-atom nil)
       (js/console.log "API key deleted (stub mode)")
       (resolve true)))))

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

;; Event handler for :persistence/save-session (dispatched from events/core.cljs)
(rf/reg-event-fx
 :persistence/save-session
 (fn [_ [_ session]]
   {:persistence/save-session session}))

;; Event handler for :persistence/delete-api-key (dispatched from events/core.cljs)
(rf/reg-event-fx
 :persistence/delete-api-key
 (fn [_ _]
   {:persistence/delete-api-key nil}))
