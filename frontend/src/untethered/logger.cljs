(ns untethered.logger
  "Console logging utilities.")

(defn info [& args]
  (apply js/console.log args))

(defn warn [& args]
  (apply js/console.warn args))

(defn error [& args]
  (apply js/console.error args))

(defn debug [& args]
  (when ^boolean js/goog.DEBUG
    (apply js/console.log args)))
