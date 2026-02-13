(ns voice-code.logger
  "Production-safe logging module.

   Provides debug-conditional logging that respects goog.DEBUG flag.
   In development (goog.DEBUG = true): All log calls execute normally.
   In production (goog.DEBUG = false): debug/info/trace are no-ops.

   Usage:
     (require '[voice-code.logger :as log])
     (log/debug \"Debug message\" {:data 123})
     (log/info \"Info message\")
     (log/warn \"Warning message\")
     (log/error \"Error message\" error-obj)

   For component-specific logging with prefixes:
     (def logger (log/with-prefix \"WebSocket\"))
     ((:debug logger) \"Connected\")  ; => [WebSocket] Connected

   Log levels (all execute in dev, warn/error only in prod):
     - trace: Detailed tracing, dev only
     - debug: Debug info, dev only
     - info: Informational, dev only
     - warn: Warnings, always logs
     - error: Errors, always logs")

(defn debug-enabled?
  "Returns true if debug logging is enabled (goog.DEBUG is true).
   In production builds, goog.DEBUG is false and debug/info/trace become no-ops."
  []
  goog.DEBUG)

(defn- format-args
  "Format log arguments into a single string."
  [args]
  (apply str (interpose " " (map str args))))

(defn- format-with-prefix
  "Format log arguments with a prefix."
  [prefix args]
  (str "[" prefix "] " (format-args args)))

;; ============================================================================
;; Core Log Functions
;; ============================================================================

(defn trace
  "Trace-level logging. Only executes in development mode.
   Use for detailed execution tracing."
  [& args]
  (when goog.DEBUG
    (apply js/console.log args))
  nil)

(defn debug
  "Debug-level logging. Only executes in development mode.
   Use for debugging information during development."
  [& args]
  (when goog.DEBUG
    (apply js/console.log args))
  nil)

(defn info
  "Info-level logging. Only executes in development mode.
   Use for general informational messages."
  [& args]
  (when goog.DEBUG
    (apply js/console.log args))
  nil)

(defn warn
  "Warning-level logging. Always executes.
   Use for warning conditions that should be noticed."
  [& args]
  (apply js/console.warn args)
  nil)

(defn error
  "Error-level logging. Always executes.
   Use for error conditions."
  [& args]
  (apply js/console.error args)
  nil)

;; ============================================================================
;; Prefixed Logger Factory
;; ============================================================================

(defn with-prefix
  "Create a logger with a prefix added to all messages.
   Returns a map of log functions that prepend the prefix.

   Example:
     (def ws-log (with-prefix \"WebSocket\"))
     ((:debug ws-log) \"Connected\")  ; logs: [WebSocket] Connected"
  [prefix]
  {:trace (fn [& args] (trace (format-with-prefix prefix args)))
   :debug (fn [& args] (debug (format-with-prefix prefix args)))
   :info  (fn [& args] (info (format-with-prefix prefix args)))
   :warn  (fn [& args] (warn (format-with-prefix prefix args)))
   :error (fn [& args] (error (format-with-prefix prefix args)))})
