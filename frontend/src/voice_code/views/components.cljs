(ns voice-code.views.components
  "Shared UI components for voice-code views."
  (:require [reagent.core :as r]
            ["react-native" :as rn]
            [voice-code.utils :as utils]))

;; Timer interval for relative time updates (60 seconds)
(def ^:private update-interval-ms 60000)

;; Re-export format functions for backward compatibility
(def format-relative-time utils/format-relative-time)
(def format-relative-time-short utils/format-relative-time-short)

(defn relative-time-text
  "Auto-updating relative time display component.
   
   Updates every 60 seconds to keep the displayed time accurate.
   Uses Reagent Form-3 component with local state and timer cleanup.
   
   Props:
   - timestamp: Date object or parseable date string
   - style: Optional style map for the Text component
   - short?: If true, use short format (2h ago vs 2 hours ago)
   
   Example:
   [relative-time-text {:timestamp (:last-modified session)
                        :style {:font-size 12 :color \"#999\"}}]"
  [{:keys [timestamp style short?]}]
  (let [;; Local state to trigger re-renders
        tick (r/atom 0)
        timer-id (atom nil)]
    (r/create-class
     {:display-name "relative-time-text"

      :component-did-mount
      (fn [_this]
        ;; Set up interval timer to increment tick every 60 seconds
        (reset! timer-id
                (js/setInterval
                 (fn [] (swap! tick inc))
                 update-interval-ms)))

      :component-will-unmount
      (fn [_this]
        ;; Clean up timer on unmount
        (when @timer-id
          (js/clearInterval @timer-id)
          (reset! timer-id nil)))

      :reagent-render
      (fn [{:keys [timestamp style short?]}]
        ;; Deref tick to ensure re-render when it changes
        (let [_ @tick
              format-fn (if short? utils/format-relative-time-short utils/format-relative-time)]
          [:> rn/Text {:style (or style {})}
           (format-fn timestamp)]))})))
