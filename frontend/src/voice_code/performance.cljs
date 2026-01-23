(ns voice-code.performance
  "Performance monitoring for voice-code React Native app.
   Implements render loop detection to identify infinite re-render bugs.
   
   Matches iOS implementation in ConversationView.swift:
   - 1-second sliding window for render counting
   - Warning at 50 renders/sec threshold
   - Error logging when threshold exceeded at window end
   
   Usage:
   - Call (record-render! component-name) at the start of component render
   - Automatically logs warnings/errors to console and debug logs
   - Use (get-render-stats) to get current metrics for debug UI")

;; Configuration
(def ^:private render-threshold
  "Renders per second threshold that triggers a warning."
  50)

(def ^:private window-size-ms
  "Size of the sliding window in milliseconds."
  1000)

;; State - using atoms for thread-safe access
(defonce ^:private render-state
  (atom {:render-count 0
         :window-start nil
         :component-counts {}
         :last-warning-at nil}))

(defn- current-time-ms
  "Get current time in milliseconds."
  []
  (.now js/Date))

(defn- reset-window!
  "Reset the render counting window."
  [state now]
  (assoc state
         :render-count 1
         :window-start now
         :component-counts {}))

(defn record-render!
  "Record a render event for a component.
   Call this at the start of each component's render function.
   
   Parameters:
   - component-name: String identifying the component (e.g., 'conversation-view')
   
   Returns nil. Side effects: logs warnings if threshold exceeded."
  [component-name]
  (let [now (current-time-ms)]
    (swap! render-state
           (fn [{:keys [render-count window-start component-counts last-warning-at] :as state}]
             (if (or (nil? window-start)
                     (> (- now window-start) window-size-ms))
               ;; Window expired - check for threshold violation and reset
               (do
                 (when (and render-count (> render-count render-threshold))
                   ;; Log error for the completed window
                   ;; Console capture in log-manager will store this
                   (js/console.error "🚨 RENDER LOOP DETECTED:"
                                     render-count "renders in 1 second!"
                                     "Components:" (clj->js component-counts)))
                 ;; Reset window and start fresh count
                 (-> state
                     (reset-window! now)
                     (assoc-in [:component-counts component-name] 1)))

               ;; Within current window - increment count
               (let [new-count (inc render-count)
                     new-component-count (inc (get component-counts component-name 0))]
                 ;; Log warning at threshold multiples
                 (when (and (or (= new-count render-threshold)
                                (= new-count (* 2 render-threshold)))
                            (or (nil? last-warning-at)
                                (> (- now last-warning-at) 1000)))
                   ;; Console capture in log-manager will store this
                   (js/console.warn "⚠️ High render rate:"
                                    new-count "renders in <1s"
                                    "Components:" (clj->js component-counts)))

                 (-> state
                     (assoc :render-count new-count)
                     (assoc-in [:component-counts component-name] new-component-count)
                     (cond-> (or (= new-count render-threshold)
                                 (= new-count (* 2 render-threshold)))
                       (assoc :last-warning-at now))))))))
  nil)

(defn get-render-stats
  "Get current render statistics for display in debug UI.
   
   Returns map with:
   - :render-count - renders in current window
   - :window-start - timestamp when window started
   - :component-counts - map of component -> render count
   - :renders-per-second - estimated renders/sec (nil if window too short)"
  []
  (let [{:keys [render-count window-start component-counts]} @render-state
        now (current-time-ms)
        window-duration-ms (when window-start (- now window-start))]
    {:render-count (or render-count 0)
     :window-start window-start
     :component-counts (or component-counts {})
     :renders-per-second (when (and window-duration-ms (> window-duration-ms 100))
                           (Math/round (* 1000 (/ render-count window-duration-ms))))}))

(defn reset-stats!
  "Reset all render statistics. Useful for testing."
  []
  (reset! render-state {:render-count 0
                        :window-start nil
                        :component-counts {}
                        :last-warning-at nil}))

;; Reagent integration helper
(defn use-render-tracking
  "Create a render tracking side-effect for use in Reagent components.
   
   Usage in a Form-1 component:
   (defn my-component []
     (performance/use-render-tracking \"my-component\")
     [:div ...])
   
   Usage in a Form-2 component (render function):
   (fn []
     (performance/use-render-tracking \"my-component\")
     [:div ...])"
  [component-name]
  (record-render! component-name))
