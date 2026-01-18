(ns voice-code.log-manager
  "Log manager for capturing and displaying debug logs.
   Provides a circular buffer that stores recent log entries up to a size limit.
   Integrates with console.log/warn/error for automatic capture."
  (:require [reagent.core :as r]
            [re-frame.core :as rf]))

;; Configuration
(def ^:private max-log-size-bytes 15000) ; 15KB limit as per iOS parity
(def ^:private max-entries 500) ; Max entries to prevent memory issues

;; Log storage - use ratom for reactivity
(defonce log-entries (r/atom []))
(defonce current-size (r/atom 0))

;; Original console functions (saved before override)
(defonce ^:private original-console-log (atom nil))
(defonce ^:private original-console-warn (atom nil))
(defonce ^:private original-console-error (atom nil))
(defonce ^:private installed? (atom false))

(defn- format-timestamp
  "Format current time as HH:MM:SS.mmm"
  []
  (let [now (js/Date.)
        pad2 #(if (< % 10) (str "0" %) (str %))
        pad3 #(cond (< % 10) (str "00" %)
                    (< % 100) (str "0" %)
                    :else (str %))]
    (str (pad2 (.getHours now)) ":"
         (pad2 (.getMinutes now)) ":"
         (pad2 (.getSeconds now)) "."
         (pad3 (.getMilliseconds now)))))

(defn- entry-size
  "Calculate byte size of a log entry."
  [entry]
  (+ (count (:timestamp entry))
     (count (:level entry))
     (count (:message entry))
     10)) ; overhead for structure

(defn- trim-logs-if-needed!
  "Remove oldest entries if we exceed size limit."
  []
  (while (and (> @current-size max-log-size-bytes)
              (seq @log-entries))
    (let [oldest (first @log-entries)
          size (entry-size oldest)]
      (swap! log-entries subvec 1)
      (swap! current-size - size))))

(defn add-log!
  "Add a log entry to the buffer."
  [level & args]
  (let [message (apply str (interpose " " (map str args)))
        entry {:timestamp (format-timestamp)
               :level level
               :message message
               :id (str (random-uuid))}
        size (entry-size entry)]
    ;; Add entry
    (swap! log-entries conj entry)
    (swap! current-size + size)
    ;; Trim if over max entries
    (when (> (count @log-entries) max-entries)
      (let [oldest (first @log-entries)
            oldest-size (entry-size oldest)]
        (swap! log-entries subvec 1)
        (swap! current-size - oldest-size)))
    ;; Trim if over size limit
    (trim-logs-if-needed!)))

(defn- wrap-console-fn
  "Wrap a console function to capture logs while preserving original behavior."
  [original-fn level]
  (fn [& args]
    (apply add-log! level args)
    (when original-fn
      (apply original-fn args))))

(defn install-console-capture!
  "Install console.log/warn/error capture.
   Should be called once at app startup."
  []
  (when-not @installed?
    ;; Save originals
    (reset! original-console-log js/console.log)
    (reset! original-console-warn js/console.warn)
    (reset! original-console-error js/console.error)
    ;; Install wrappers
    (set! js/console.log (wrap-console-fn @original-console-log "log"))
    (set! js/console.warn (wrap-console-fn @original-console-warn "warn"))
    (set! js/console.error (wrap-console-fn @original-console-error "error"))
    (reset! installed? true)
    (add-log! "info" "Log capture installed")))

(defn uninstall-console-capture!
  "Restore original console functions."
  []
  (when @installed?
    (when @original-console-log
      (set! js/console.log @original-console-log))
    (when @original-console-warn
      (set! js/console.warn @original-console-warn))
    (when @original-console-error
      (set! js/console.error @original-console-error))
    (reset! installed? false)))

(defn get-logs
  "Get all current log entries."
  []
  @log-entries)

(defn get-logs-as-text
  "Get all logs formatted as text for clipboard."
  []
  (->> @log-entries
       (map (fn [{:keys [timestamp level message]}]
              (str "[" timestamp "] [" level "] " message)))
       (clojure.string/join "\n")))

(defn clear-logs!
  "Clear all log entries."
  []
  (reset! log-entries [])
  (reset! current-size 0))

(defn log-count
  "Get number of log entries."
  []
  (count @log-entries))

(defn log-size-bytes
  "Get current log size in bytes."
  []
  @current-size)

;; Re-frame subscriptions for UI reactivity
(rf/reg-sub
 :logs/entries
 (fn [_ _]
   @log-entries))

(rf/reg-sub
 :logs/count
 (fn [_ _]
   (count @log-entries)))

(rf/reg-sub
 :logs/size-bytes
 (fn [_ _]
   @current-size))

;; Re-frame events for log management
(rf/reg-event-fx
 :logs/clear
 (fn [_ _]
   (clear-logs!)
   {}))

(rf/reg-event-fx
 :logs/add
 (fn [_ [_ level message]]
   (add-log! level message)
   {}))
