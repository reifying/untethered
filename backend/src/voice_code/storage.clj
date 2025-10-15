(ns voice-code.storage
  "Persistent session storage using EDN format.
  
  Stores minimal session data:
  - iOS session UUID -> Claude session ID mapping
  - Working directory
  - Creation/activity timestamps
  - Undelivered message queue
  
  Does NOT store conversation history (Claude stores this in ~/.claude/projects/)."
  (:require [clojure.edn :as edn]
            [clojure.java.io :as io]
            [clojure.tools.logging :as log]))

;; Storage file path
(def storage-file "resources/sessions.edn")

;; In-memory cache of sessions
(defonce sessions-atom (atom {:sessions {}}))

(defn ensure-storage-file
  "Ensure sessions.edn exists, creating with empty structure if needed.
  Accepts optional path for testing purposes."
  ([]
   (ensure-storage-file storage-file))
  ([path]
   (let [file (io/file path)]
     (when-not (.exists file)
       (log/info "Creating sessions storage at" path)
       (io/make-parents file)
       (spit file "{:sessions {}}\n")))))

(defn load-sessions
  "Load sessions from EDN file. Returns map with :sessions key.
  Accepts optional path for testing purposes."
  ([]
   (load-sessions storage-file))
  ([path]
   (ensure-storage-file path)
   (try
     (if-let [file (io/file path)]
       (if (.exists file)
         (-> file
             slurp
             edn/read-string)
         (do
           (log/warn "Sessions file not found at" path ", using empty sessions")
           {:sessions {}}))
       {:sessions {}})
     (catch Exception e
       (log/error e "Error loading sessions from" path)
       {:sessions {}}))))

(defn save-sessions!
  "Save sessions to EDN file.
  Accepts optional path for testing purposes."
  ([data]
   (save-sessions! data storage-file))
  ([data path]
   (try
     (ensure-storage-file path)
     (spit path (pr-str data))
     (log/debug "Saved sessions to" path)
     true
     (catch Exception e
       (log/error e "Error saving sessions to" path)
       false))))

(defn initialize!
  "Initialize storage by loading from disk into memory.
  Accepts optional path for testing purposes."
  ([]
   (initialize! storage-file))
  ([path]
   (let [data (load-sessions path)]
     (reset! sessions-atom data)
     (log/info "Initialized storage with" (count (:sessions data)) "sessions"))))

(defn get-session
  "Get session by iOS session UUID. Returns nil if not found."
  [ios-session-id]
  (get-in @sessions-atom [:sessions ios-session-id]))

(defn get-all-sessions
  "Get all sessions as a map of iOS UUID -> session data."
  []
  (:sessions @sessions-atom))

(defn create-session!
  "Create new session with iOS session UUID.
  Returns the created session data."
  [ios-session-id working-directory]
  (let [now (java.util.Date.)
        session {:claude-session-id nil
                 :working-directory working-directory
                 :created-at now
                 :last-active now
                 :undelivered-messages []}]
    (swap! sessions-atom assoc-in [:sessions ios-session-id] session)
    (save-sessions! @sessions-atom)
    (log/info "Created session" {:ios-session-id ios-session-id
                                 :working-directory working-directory})
    session))

(defn update-session!
  "Update session with partial data merge.
  Automatically updates :last-active timestamp.
  Returns the updated session data, or nil if session not found."
  [ios-session-id updates]
  (if (get-session ios-session-id)
    (let [now (java.util.Date.)
          updated-session (swap! sessions-atom
                                 update-in [:sessions ios-session-id]
                                 merge
                                 (assoc updates :last-active now))]
      (save-sessions! updated-session)
      (log/debug "Updated session" {:ios-session-id ios-session-id
                                    :updates updates})
      (get-in updated-session [:sessions ios-session-id]))
    (do
      (log/warn "Attempted to update non-existent session" {:ios-session-id ios-session-id})
      nil)))

(defn delete-session!
  "Delete session by iOS session UUID.
  Returns true if deleted, false if not found."
  [ios-session-id]
  (if (get-session ios-session-id)
    (do
      (swap! sessions-atom update :sessions dissoc ios-session-id)
      (save-sessions! @sessions-atom)
      (log/info "Deleted session" {:ios-session-id ios-session-id})
      true)
    (do
      (log/warn "Attempted to delete non-existent session" {:ios-session-id ios-session-id})
      false)))

(defn add-undelivered-message!
  "Add message to undelivered queue for a session.
  Message should have :id, :role, :text, :timestamp keys.
  Returns updated session or nil if session not found."
  [ios-session-id message]
  (if (get-session ios-session-id)
    (let [message-with-timestamp (assoc message :timestamp (java.util.Date.))]
      (swap! sessions-atom
             update-in [:sessions ios-session-id :undelivered-messages]
             (fnil conj [])
             message-with-timestamp)
      (save-sessions! @sessions-atom)
      (log/debug "Added undelivered message" {:ios-session-id ios-session-id
                                              :message-id (:id message)})
      (get-session ios-session-id))
    (do
      (log/warn "Attempted to add message to non-existent session" {:ios-session-id ios-session-id})
      nil)))

(defn remove-undelivered-message!
  "Remove message from undelivered queue by message ID.
  Returns updated session or nil if session not found."
  [ios-session-id message-id]
  (if (get-session ios-session-id)
    (do
      (swap! sessions-atom
             update-in [:sessions ios-session-id :undelivered-messages]
             (fn [messages]
               (vec (remove #(= (:id %) message-id) messages))))
      (save-sessions! @sessions-atom)
      (log/debug "Removed undelivered message" {:ios-session-id ios-session-id
                                                :message-id message-id})
      (get-session ios-session-id))
    (do
      (log/warn "Attempted to remove message from non-existent session" {:ios-session-id ios-session-id})
      nil)))

(defn get-undelivered-messages
  "Get all undelivered messages for a session.
  Returns vector of messages or empty vector if session not found."
  [ios-session-id]
  (or (get-in @sessions-atom [:sessions ios-session-id :undelivered-messages])
      []))

(defn clear-storage!
  "Clear all sessions from memory and disk. USE WITH CAUTION.
  Primarily for testing purposes.
  Accepts optional path for testing purposes."
  ([]
   (clear-storage! storage-file))
  ([path]
   (reset! sessions-atom {:sessions {}})
   (save-sessions! @sessions-atom path)
   (log/info "Cleared all sessions")))
