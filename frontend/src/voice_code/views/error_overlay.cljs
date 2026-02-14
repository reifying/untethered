(ns voice-code.views.error-overlay
  "Development-only error overlay with copy-to-clipboard functionality.
   Provides a simple way to copy error stack traces on device."
  (:require [reagent.core :as r]
            [re-frame.core :as rf]
            ["react-native" :as rn]
            [voice-code.views.components :refer [copy-to-clipboard!]]
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
                                    :backgroundColor (:overlay-background colors)
                                    :zIndex 9999}}
                [:> rn/SafeAreaView {:style {:flex 1}}
                 ;; Header
                 [:> rn/View {:style {:flexDirection "row"
                                      :justifyContent "space-between"
                                      :alignItems "center"
                                      :paddingHorizontal 16
                                      :paddingVertical 12
                                      :backgroundColor (:destructive colors)}}
                  [:> rn/Text {:style {:color (:button-text-on-accent colors)
                                       :fontSize 18
                                       :fontWeight "600"}}
                   "Error (Dev)"]
                  [touchable
                   {:onPress #(rf/dispatch [:dev/clear-error])
                    :style {:padding 8}}
                   [:> rn/Text {:style {:color (:button-text-on-accent colors)
                                        :fontSize 16}}
                    "Dismiss"]]]

                 ;; Error message
                 [:> rn/ScrollView {:style {:flex 1
                                            :padding 16}}
                  [:> rn/Text {:style {:color (:destructive colors)
                                       :fontSize 16
                                       :fontWeight "600"
                                       :marginBottom 8}}
                   "Message:"]
                  [:> rn/Text {:style {:color (:text-primary colors)
                                       :fontSize 14
                                       :marginBottom 16
                                       :fontFamily (if (= (.-OS rn/Platform) "ios")
                                                     "Menlo"
                                                     "monospace")}}
                   (:message error)]

                  [:> rn/Text {:style {:color (:destructive colors)
                                       :fontSize 16
                                       :fontWeight "600"
                                       :marginBottom 8}}
                   "Stack Trace:"]
                  [:> rn/Text {:style {:color (:text-secondary colors)
                                       :fontSize 12
                                       :fontFamily (if (= (.-OS rn/Platform) "ios")
                                                     "Menlo"
                                                     "monospace")
                                       :lineHeight 18}}
                   (:stack error)]]

                 ;; Copy button
                 [:> rn/View {:style {:padding 16
                                      :paddingBottom 32}}
                  [touchable
                   {:onPress (fn []
                               (copy-to-clipboard!
                                (format-error error)
                                (fn []
                                  (reset! copied? true)
                                  (js/setTimeout #(reset! copied? false) 2000))))
                    :style {:backgroundColor (if @copied? (:success colors) (:accent colors))
                            :borderRadius 12
                            :padding 16
                            :alignItems "center"}}
                   [:> rn/Text {:style {:color (:button-text-on-accent colors)
                                        :fontSize 16
                                        :fontWeight "600"}}
                    (if @copied? "Copied!" "Copy to Clipboard")]]]]]))])))))

(defn with-error-overlay
  "Wrap a component with the error overlay (dev-only)."
  [child]
  (if ^boolean js/goog.DEBUG
    [:> rn/View {:style {:flex 1}}
     child
     [error-overlay]]
    child))
