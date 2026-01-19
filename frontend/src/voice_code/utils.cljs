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
