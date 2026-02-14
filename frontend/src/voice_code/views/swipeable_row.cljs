(ns voice-code.views.swipeable-row
  "Reusable iOS swipe-to-reveal-action component.

   Provides a platform-appropriate swipe gesture that reveals an action
   button (Delete, Remove, etc.) on the trailing edge of a list row.
   iOS only — Android uses context menus per Material Design convention.

   iOS parity: UIKit .swipeActions(edge: .trailing, allowsFullSwipe: true)
   with spring animations and haptic feedback.

   Usage:
     [swipeable-row {:action-label \"Delete\"
                     :on-action #(delete-item!)
                     :colors colors
                     :confirm? true
                     :confirm-title \"Delete Session\"
                     :confirm-message \"Are you sure?\"
                     :render-content (fn [override-on-press]
                                      [my-row {:on-press override-on-press}])}]"
  (:require [reagent.core :as r]
            ["react-native" :as rn :refer [Animated PanResponder]]
            [voice-code.haptic :as haptic]
            [voice-code.platform :as platform]
            [voice-code.views.touchable :refer [touchable]]))

(def action-button-width
  "Width of the action button revealed on swipe."
  80)

(def swipe-threshold
  "Minimum swipe distance to trigger action reveal."
  -80)

(defn swipeable-row
  "iOS swipe-to-reveal-action row wrapper.

   Wraps row content with a swipe gesture that reveals an action button
   on the trailing edge. Supports optional confirmation alert.

   Props:
   - :action-label     - Text on the revealed button (\"Delete\", \"Remove\")
   - :on-action        - Callback when the action is confirmed/tapped
   - :on-press         - Normal tap handler for the row content
   - :colors           - Theme colors map (required)
   - :confirm?         - If true, shows alert before executing on-action
   - :confirm-title    - Alert title (required when confirm? is true)
   - :confirm-message  - Alert body (required when confirm? is true)
   - :render-content   - fn of (on-press) that renders the row content;
                          on-press is overridden to close swipe when open
   - :content-style    - Optional style for the Animated.View container"
  [{:keys [_action-label _on-action _on-press _colors _confirm?
           _confirm-title _confirm-message _render-content _content-style]}]
  (let [translate-x (Animated.Value. 0)
        is-open (r/atom false)

        pan-responder
        (.create PanResponder
                 #js {:onStartShouldSetPanResponder (fn [] false)
                      :onMoveShouldSetPanResponder
                      (fn [_ gesture-state]
                        (and (> (js/Math.abs (.-dx gesture-state)) 10)
                             (> (js/Math.abs (.-dx gesture-state))
                                (js/Math.abs (.-dy gesture-state)))))

                      :onPanResponderGrant
                      (fn [_ _]
                        (.setOffset translate-x (.-_value translate-x))
                        (.setValue translate-x 0))

                      :onPanResponderMove
                      (fn [_ gesture-state]
                        (let [dx (.-dx gesture-state)
                              current-offset (.-_offset translate-x)
                              new-value (+ current-offset dx)
                              clamped (max (- action-button-width) (min 0 new-value))]
                          (.setValue translate-x (- clamped current-offset))))

                      :onPanResponderRelease
                      (fn [_ gesture-state]
                        (.flattenOffset translate-x)
                        (let [current-value (.-_value translate-x)
                              velocity-x (.-vx gesture-state)]
                          (cond
                            (or (< velocity-x -0.5) (< current-value swipe-threshold))
                            (do
                              (reset! is-open true)
                              (haptic/impact! :medium)
                              (.start
                               (Animated.spring translate-x
                                                #js {:toValue (- action-button-width)
                                                     :useNativeDriver true
                                                     :friction 8})))

                            :else
                            (do
                              (reset! is-open false)
                              (.start
                               (Animated.spring translate-x
                                                #js {:toValue 0
                                                     :useNativeDriver true
                                                     :friction 8}))))))

                      :onPanResponderTerminate
                      (fn [_ _]
                        (.flattenOffset translate-x)
                        (reset! is-open false)
                        (.start
                         (Animated.spring translate-x
                                          #js {:toValue 0
                                               :useNativeDriver true
                                               :friction 8})))})

        close-swipe
        (fn []
          (when @is-open
            (reset! is-open false)
            (.start
             (Animated.spring translate-x
                              #js {:toValue 0
                                   :useNativeDriver true
                                   :friction 8}))))

        animate-out-then-act
        (fn [action-fn]
          (.start
           (Animated.timing translate-x
                            #js {:toValue -500
                                 :duration 200
                                 :useNativeDriver true})
           action-fn))]

    (fn [{:keys [action-label on-action on-press colors confirm?
                 confirm-title confirm-message render-content content-style]}]
      (let [handle-action
            (if confirm?
              (fn []
                (haptic/warning!)
                (platform/show-alert!
                 confirm-title
                 confirm-message
                 [{:text "Cancel"
                   :style "cancel"
                   :onPress close-swipe}
                  {:text action-label
                   :style "destructive"
                   :onPress #(animate-out-then-act on-action)}]))
              (fn []
                (haptic/success!)
                (animate-out-then-act on-action)))

            ;; Override on-press: close swipe if open, otherwise normal press
            effective-on-press
            (fn []
              (if @is-open
                (close-swipe)
                (when on-press (on-press))))]

        [:> rn/View {:style {:overflow "hidden"}}
         ;; Action button background (revealed on swipe)
         [:> rn/View {:style {:position "absolute"
                              :right 0
                              :top 0
                              :bottom 0
                              :width action-button-width
                              :background-color (:destructive colors)
                              :justify-content "center"
                              :align-items "center"}}
          [touchable
           {:style {:flex 1
                    :width "100%"
                    :justify-content "center"
                    :align-items "center"}
            :on-press handle-action}
           [:> rn/Text {:style {:color (:button-text-on-accent colors)
                                :font-size 14
                                :font-weight "600"}}
            action-label]]]

         ;; Animated row content
         [:> (.-View Animated)
          (merge
           {:style (let [base #js {:transform #js [#js {:translateX translate-x}]}]
                     (when content-style
                       (doseq [[k v] content-style]
                         (unchecked-set base (name k) v)))
                     base)}
           (js->clj (.-panHandlers pan-responder)))
          (render-content effective-on-press)]]))))
