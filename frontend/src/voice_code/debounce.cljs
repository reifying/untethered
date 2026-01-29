(ns voice-code.debounce
  "Debouncing mechanism for high-frequency state updates.
   
   Implements batched state updates to prevent UI thrashing from rapid
   WebSocket messages. Matches iOS VoiceCodeClient.swift debouncing pattern.
   
   Key concepts:
   - 100ms debounce delay (configurable)
   - Batches multiple updates into single db transaction
   - Uses re-frame interceptor for transparent integration
   - Supports immediate flush for critical operations
   
   Usage:
   
   ;; Schedule a debounced update
   (rf/dispatch [:debounce/schedule-update :locked-sessions #{\"session-1\"}])
   
   ;; Flush immediately (for critical operations like disconnect)
   (rf/dispatch [:debounce/flush])
   
   ;; In event handlers, use the debounced-db interceptor:
   (rf/reg-event-fx
     :my-event
     [debounce/debounced-db]
     (fn [{:keys [db]} _]
       {:db (assoc db :my-key value)}))
   
   iOS Reference: VoiceCodeClient.swift lines 150-252"
  (:require [clojure.string :as str]
            [re-frame.core :as rf]))

;; ============================================================================
;; Configuration
;; ============================================================================

(def ^:private debounce-delay-ms
  "Debounce delay in milliseconds. Matches iOS VoiceCodeClient.debounceDelay."
  100)

;; ============================================================================
;; State
;; ============================================================================

;; Atom holding pending updates to be applied.
;; Map of path -> value, where path is a vector like [:locked-sessions].
(defonce ^:private pending-updates (atom {}))

;; Atom holding the current debounce timer ID.
(defonce ^:private debounce-timer (atom nil))

;; ============================================================================
;; Core Functions
;; ============================================================================

(defn- apply-pending-updates!
  "Apply all pending updates to app-db atomically.
   Called when debounce timer fires.
   
   Uses dispatch-sync for immediate application, but this means
   this function should NOT be called from within a re-frame event handler.
   Use the :debounce/flush effect instead when inside an event."
  []
  (let [updates @pending-updates]
    (when (seq updates)
      ;; Clear pending updates first
      (reset! pending-updates {})
      ;; Log which keys are being updated (matches iOS logging)
      (let [keys-str (->> (keys updates)
                          (map #(if (vector? %) (last %) %))
                          (map name)
                          sort
                          (str/join ", "))]
        (js/console.log "🔄 [Debounce] Applying updates:" keys-str))
      ;; Apply all updates in a single dispatch-sync for immediate effect
      ;; Note: This cannot be called from within an event handler
      (rf/dispatch-sync [:debounce/apply-updates updates]))))

(defn schedule-update!
  "Schedule a debounced update for a db path.
   
   Parameters:
   - path: Vector path in app-db (e.g., [:locked-sessions] or [:ui :current-error])
   - value: New value to set at path
   
   The update will be applied after debounce-delay-ms unless another update
   is scheduled, which resets the timer."
  [path value]
  ;; Store pending update
  (swap! pending-updates assoc path value)

  ;; Cancel existing timer
  (when-let [timer @debounce-timer]
    (js/clearTimeout timer))

  ;; Schedule new timer
  (reset! debounce-timer
          (js/setTimeout apply-pending-updates! debounce-delay-ms)))

(defn flush!
  "Flush all pending updates immediately.
   Call this for critical operations like disconnect."
  []
  ;; Cancel timer
  (when-let [timer @debounce-timer]
    (js/clearTimeout timer)
    (reset! debounce-timer nil))
  ;; Apply immediately
  (apply-pending-updates!))

(defn get-pending-value
  "Get the pending value for a path, or nil if no pending update.
   Matches iOS getCurrentValue() - checks pending updates before using current value."
  [path]
  (get @pending-updates path))

(defn get-current-value
  "Get the current value for a path, checking pending updates first.
   Matches iOS getCurrentValue(for:current:) method.
   
   Parameters:
   - db: Current app-db
   - path: Vector path in app-db
   
   Returns pending value if exists, otherwise current db value."
  [db path]
  (if-let [pending (get-pending-value path)]
    pending
    (get-in db path)))

;; ============================================================================
;; Re-frame Events
;; ============================================================================

(rf/reg-event-db
 :debounce/apply-updates
 (fn [db [_ updates]]
   ;; Apply all pending updates atomically
   (reduce
    (fn [db [path value]]
      (assoc-in db path value))
    db
    updates)))

(rf/reg-event-fx
 :debounce/schedule-update
 (fn [_ [_ path value]]
   ;; Schedule through the debounce mechanism (side effect)
   (schedule-update! path value)
   ;; No db changes - they'll be applied later
   {}))

(rf/reg-event-fx
 :debounce/flush
 (fn [_ _]
   ;; Flush immediately (side effect)
   (flush!)
   {}))

;; ============================================================================
;; Effect Handlers
;; ============================================================================

(rf/reg-fx
 :debounce/schedule
 (fn [{:keys [path value]}]
   (schedule-update! path value)))

(rf/reg-fx
 :debounce/flush
 (fn [_]
   (flush!)))

;; ============================================================================
;; Testing Support
;; ============================================================================

(defn reset-state!
  "Reset all debounce state. For testing only."
  []
  (when-let [timer @debounce-timer]
    (js/clearTimeout timer))
  (reset! debounce-timer nil)
  (reset! pending-updates {}))

(defn get-pending-updates
  "Get all pending updates. For testing/debugging."
  []
  @pending-updates)
