(ns voice-code.utils
  "Utility functions for voice-code - pure functions without React Native dependencies.")

(defn format-relative-time
  "Format a timestamp as relative time (e.g., '2 hours ago').
   Can be used standalone or via the auto-updating relative-time-text component."
  [timestamp]
  (when timestamp
    (let [now (js/Date.)
          ts (if (instance? js/Date timestamp)
               timestamp
               (js/Date. timestamp))
          diff (- (.getTime now) (.getTime ts))
          minutes (Math/floor (/ diff 60000))
          hours (Math/floor (/ minutes 60))
          days (Math/floor (/ hours 24))]
      (cond
        (< minutes 1) "Just now"
        (< minutes 60) (str minutes " min ago")
        (< hours 24) (str hours " hour" (when (not= hours 1) "s") " ago")
        (< days 7) (str days " day" (when (not= days 1) "s") " ago")
        :else (.toLocaleDateString ts)))))

(defn format-relative-time-short
  "Format a timestamp as short relative time (e.g., '2h ago').
   Shorter format for more compact displays."
  [timestamp]
  (when timestamp
    (let [now (js/Date.)
          ts (if (instance? js/Date timestamp)
               timestamp
               (js/Date. timestamp))
          diff (- (.getTime now) (.getTime ts))
          minutes (Math/floor (/ diff 60000))
          hours (Math/floor (/ minutes 60))
          days (Math/floor (/ hours 24))]
      (cond
        (< minutes 1) "Just now"
        (< minutes 60) (str minutes "m ago")
        (< hours 24) (str hours "h ago")
        (< days 7) (str days "d ago")
        :else (.toLocaleDateString ts)))))

;; ============================================================================
;; Async Operation Timeout Utilities
;; ============================================================================

;; Registry of active timeout handles, keyed by operation-id.
;; Used to cancel timeouts when operations complete before timeout.
(defonce ^:private timeout-registry (atom {}))

(defn schedule-timeout!
  "Schedule a timeout callback. Returns the timeout handle.
   - operation-id: unique identifier for this timeout (e.g., [:compaction session-id])
   - timeout-ms: milliseconds until timeout fires
   - on-timeout: callback function to invoke on timeout
   
   The timeout is registered so it can be cancelled via cancel-timeout!"
  [operation-id timeout-ms on-timeout]
  (let [handle (js/setTimeout
                (fn []
                  ;; Remove from registry when fired
                  (swap! timeout-registry dissoc operation-id)
                  (on-timeout))
                timeout-ms)]
    (swap! timeout-registry assoc operation-id handle)
    handle))

(defn cancel-timeout!
  "Cancel a scheduled timeout by operation-id.
   Returns true if a timeout was cancelled, false if no timeout was found."
  [operation-id]
  (if-let [handle (get @timeout-registry operation-id)]
    (do
      (js/clearTimeout handle)
      (swap! timeout-registry dissoc operation-id)
      true)
    false))

(defn has-pending-timeout?
  "Check if there's a pending timeout for the given operation-id."
  [operation-id]
  (contains? @timeout-registry operation-id))
