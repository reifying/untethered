(ns voice-code.views.error-overlay
  "Development-only error overlay with copy-to-clipboard functionality.
   Provides a simple way to copy error stack traces on device."
  (:require [reagent.core :as r]
            [re-frame.core :as rf]
            ["react-native" :as rn]
            [voice-code.views.components :refer [copy-to-clipboard!]]
            [voice-code.platform :as platform]
            [voice-code.theme :as theme]
            [voice-code.views.touchable :refer [touchable]]))

(defn- format-error
  "Format error and stack trace for display/copying."
  [{:keys [message stack]}]
  (str "Error: " message "\n\n" "Stack Trace:\n" stack))

(defn error-overlay
  "Development error overlay with copy functionality.
   Only renders when there's an error in app-db.
   Uses Form-2 component pattern to preserve copied? state across re-renders.

   Note: Wraps content in [:f> ...] to enable React hooks for theme colors.
   The Form-2 outer let is needed for local state, but the inner fn cannot
   use hooks directly. The [:f> ...] wrapper provides a functional component context."
  []
  (let [copied? (r/atom false)]
    (fn []
      (let [error @(rf/subscribe [:dev/global-error])]
        (when error
          ;; Wrap in [:f> ...] to enable React hooks for theme colors
          [:f>
           (fn []
             (let [colors (theme/use-theme-colors)]
               [:> rn/View {:style {:position "absolute"
                                    :top 0
                                    :left 0
                                    :right 0
                                    :bottom 0
                                    :background-color (:overlay-background colors)
                                    :z-index 9999}}
                [:> rn/SafeAreaView {:style {:flex 1}}
                 ;; Header
                 [:> rn/View {:style {:flex-direction "row"
                                      :justify-content "space-between"
                                      :align-items "center"
                                      :padding-horizontal 16
                                      :padding-vertical 12
                                      :background-color (:destructive colors)}}
                  [:> rn/Text {:style {:color (:button-text-on-accent colors)
                                       :font-size 18
                                       :font-weight "600"}}
                   "Error (Dev)"]
                  [touchable
                   {:on-press #(rf/dispatch [:dev/clear-error])
                    :style {:padding 8}}
                   [:> rn/Text {:style {:color (:button-text-on-accent colors)
                                        :font-size 16}}
                    "Dismiss"]]]

                 ;; Error message
                 [:> rn/ScrollView {:style {:flex 1
                                            :padding 16}}
                  [:> rn/Text {:style {:color (:destructive colors)
                                       :font-size 16
                                       :font-weight "600"
                                       :margin-bottom 8}}
                   "Message:"]
                  [:> rn/Text {:style {:color (:text-primary colors)
                                       :font-size 14
                                       :margin-bottom 16
                                       :font-family platform/monospace-font}}
                   (:message error)]

                  [:> rn/Text {:style {:color (:destructive colors)
                                       :font-size 16
                                       :font-weight "600"
                                       :margin-bottom 8}}
                   "Stack Trace:"]
                  [:> rn/Text {:style {:color (:text-secondary colors)
                                       :font-size 12
                                       :font-family platform/monospace-font
                                       :line-height 18}}
                   (:stack error)]]

                 ;; Copy button
                 [:> rn/View {:style {:padding 16
                                      :padding-bottom 32}}
                  [touchable
                   {:on-press (fn []
                                (copy-to-clipboard!
                                 (format-error error)
                                 (fn []
                                   (reset! copied? true)
                                   (js/setTimeout #(reset! copied? false) 2000))))
                    :style {:background-color (if @copied? (:success colors) (:accent colors))
                            :border-radius 12
                            :padding 16
                            :align-items "center"}}
                   [:> rn/Text {:style {:color (:button-text-on-accent colors)
                                        :font-size 16
                                        :font-weight "600"}}
                    (if @copied? "Copied!" "Copy to Clipboard")]]]]]))])))))

(defn with-error-overlay
  "Wrap a component with the error overlay (dev-only)."
  [child]
  (if ^boolean js/goog.DEBUG
    [:> rn/View {:style {:flex 1}}
     child
     [error-overlay]]
    child))
