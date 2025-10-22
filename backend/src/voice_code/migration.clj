(ns voice-code.migration
  "One-time migration scripts for voice-code sessions."
  (:require [voice-code.replication :as repl]
            [clojure.tools.logging :as log]))

(defn migrate-unnotified-sessions
  "Fix sessions with messages but never notified to iOS.
  
  This migration handles sessions that were created with only sidechain messages
  and got stuck at :ios-notified false even though they now have real messages.
  
  Estimated impact: ~241 sessions (27% of all sessions as of 2025-10-22)"
  []
  (let [index (repl/load-index)
        unnotified-sessions (->> index
                                 vals
                                 (filter #(and (pos? (:message-count %))
                                               (not (:ios-notified % false)))))
        total-count (count unnotified-sessions)]

    (log/info "Starting migration for unnotified sessions"
              {:total-sessions (count index)
               :unnotified-count total-count})

    (doseq [session unnotified-sessions]
      (let [session-id (:session-id session)]
        (log/info "Migrating session"
                  {:session-id session-id
                   :message-count (:message-count session)
                   :name (:name session)})

        ;; Send session_created notification to connected iOS clients
        (when-let [callback (:on-session-created @repl/watcher-state)]
          (callback session))

        ;; Mark as notified in index
        (swap! repl/session-index assoc-in [session-id :ios-notified] true)
        (swap! repl/session-index assoc-in [session-id :first-notification]
               (System/currentTimeMillis))))

    ;; Save updated index
    (repl/save-index! @repl/session-index)

    (log/info "Migration complete" {:migrated-count total-count})

    {:migrated total-count
     :session-ids (mapv :session-id unnotified-sessions)}))

(defn migrate-unnotified-sessions-dry-run
  "Report what would be migrated without making changes."
  []
  (let [index (repl/load-index)
        unnotified-sessions (->> index
                                 vals
                                 (filter #(and (pos? (:message-count %))
                                               (not (:ios-notified % false)))))]

    (log/info "Dry run: unnotified sessions that would be migrated"
              {:total-sessions (count index)
               :unnotified-count (count unnotified-sessions)})

    (doseq [session unnotified-sessions]
      (log/info "Would migrate:"
                {:session-id (:session-id session)
                 :message-count (:message-count session)
                 :name (:name session)
                 :created-at (:created-at session)}))

    {:would-migrate (count unnotified-sessions)
     :session-ids (mapv :session-id unnotified-sessions)}))

(comment
  ;; Usage examples:

  ;; 1. Dry run to see what would be migrated
  (require '[voice-code.migration :as mig])
  (mig/migrate-unnotified-sessions-dry-run)

  ;; 2. Run actual migration (requires backend running with connected iOS clients)
  (mig/migrate-unnotified-sessions)

  ;; 3. Verify migration results
  (->> (repl/load-index)
       vals
       (filter #(and (pos? (:message-count %))
                     (not (:ios-notified % false))))
       count)
  ;; Should be 0 after migration
  )
