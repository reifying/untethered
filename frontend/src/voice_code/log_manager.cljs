(ns voice-code.log-manager
  "Log manager for capturing and displaying debug logs.
   Provides a circular buffer that stores recent log entries up to a size limit.
   Integrates with console.log/warn/error/info for automatic capture.
   
   Uses a single atom for log state to ensure atomic updates and avoid
   race conditions between entry count and size tracking."
  (:require [clojure.string :as str]
            [reagent.core :as r]
            [re-frame.core :as rf]))

;; Configuration
(def ^:private max-log-size-bytes 15000) ; 15KB limit as per iOS parity
(def ^:private max-entries 500) ; Max entries to prevent memory issues

;; Log storage - single atom for atomic updates
;; Using a single atom prevents race conditions between entry count and size tracking
(defonce log-state (r/atom {:entries [] :size 0}))

;; Original console functions (saved before override)
(defonce ^:private original-console-log (atom nil))
(defonce ^:private original-console-warn (atom nil))
(defonce ^:private original-console-error (atom nil))
(defonce ^:private original-console-info (atom nil))
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

(defn- trim-state-if-needed
  "Pure function to trim log state if it exceeds limits.
   Returns updated state with oldest entries removed as needed."
  [{:keys [entries size] :as state}]
  (if (or (> size max-log-size-bytes) (> (count entries) max-entries))
    (loop [entries entries
           size size]
      (if (and (seq entries)
               (or (> size max-log-size-bytes)
                   (> (count entries) max-entries)))
        (let [oldest (first entries)
              oldest-size (entry-size oldest)]
          (recur (subvec entries 1) (- size oldest-size)))
        {:entries entries :size size}))
    state))

(defn add-log!
  "Add a log entry to the buffer.
   Uses a single atomic swap! to add entry, update size, and trim if needed."
  [level & args]
  (let [message (apply str (interpose " " (map str args)))
        entry {:timestamp (format-timestamp)
               :level level
               :message message
               :id (str (random-uuid))}
        entry-sz (entry-size entry)]
    (swap! log-state
           (fn [{:keys [entries size]}]
             (-> {:entries (conj entries entry)
                  :size (+ size entry-sz)}
                 trim-state-if-needed)))))

(defn- wrap-console-fn
  "Wrap a console function to capture logs while preserving original behavior."
  [original-fn level]
  (fn [& args]
    (apply add-log! level args)
    (when original-fn
      (apply original-fn args))))

(defn install-console-capture!
  "Install console.log/warn/error/info capture.
   Should be called once at app startup."
  []
  (when-not @installed?
    ;; Save originals
    (reset! original-console-log js/console.log)
    (reset! original-console-warn js/console.warn)
    (reset! original-console-error js/console.error)
    (reset! original-console-info js/console.info)
    ;; Install wrappers
    (set! js/console.log (wrap-console-fn @original-console-log "log"))
    (set! js/console.warn (wrap-console-fn @original-console-warn "warn"))
    (set! js/console.error (wrap-console-fn @original-console-error "error"))
    (set! js/console.info (wrap-console-fn @original-console-info "info"))
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
    (when @original-console-info
      (set! js/console.info @original-console-info))
    (reset! installed? false)))

(defn get-logs
  "Get all current log entries."
  []
  (:entries @log-state))

(defn get-logs-as-text
  "Get all logs formatted as text for clipboard."
  []
  (->> (:entries @log-state)
       (map (fn [{:keys [timestamp level message]}]
              (str "[" timestamp "] [" level "] " message)))
       (str/join "\n")))

(defn clear-logs!
  "Clear all log entries."
  []
  (reset! log-state {:entries [] :size 0}))

(defn log-count
  "Get number of log entries."
  []
  (count (:entries @log-state)))

(defn log-size-bytes
  "Get current log size in bytes."
  []
  (:size @log-state))

;; Re-frame subscriptions for UI reactivity
(rf/reg-sub
 :logs/entries
 (fn [_ _]
   (:entries @log-state)))

(rf/reg-sub
 :logs/count
 (fn [_ _]
   (count (:entries @log-state))))

(rf/reg-sub
 :logs/size-bytes
 (fn [_ _]
   (:size @log-state)))

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
