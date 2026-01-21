(ns voice-code.views.error-overlay
  "Development-only error overlay with copy-to-clipboard functionality.
   Provides a simple way to copy error stack traces on device."
  (:require [reagent.core :as r]
            [re-frame.core :as rf]
            ["react-native" :as rn]
            ["@react-native-clipboard/clipboard" :as Clipboard]
            [voice-code.haptic :as haptic]))

(defn- copy-to-clipboard!
  "Copy text to clipboard with haptic feedback."
  [text]
  (let [clipboard (or (.-default Clipboard) Clipboard)]
    (.setString clipboard text)
    (haptic/success!)))

(defn- format-error
  "Format error and stack trace for display/copying."
  [{:keys [message stack]}]
  (str "Error: " message "\n\n" "Stack Trace:\n" stack))

(defn error-overlay
  "Development error overlay with copy functionality.
   Only renders when there's an error in app-db.
   Uses Form-2 component pattern to preserve copied? state across re-renders."
  []
  (let [copied? (r/atom false)]
    (fn []
      (let [error @(rf/subscribe [:dev/global-error])]
        (when error
          [:> rn/View {:style {:position "absolute"
                           :top 0
                           :left 0
                           :right 0
                           :bottom 0
                           :backgroundColor "rgba(0,0,0,0.95)"
                           :zIndex 9999}}
       [:> rn/SafeAreaView {:style {:flex 1}}
        ;; Header
        [:> rn/View {:style {:flexDirection "row"
                             :justifyContent "space-between"
                             :alignItems "center"
                             :paddingHorizontal 16
                             :paddingVertical 12
                             :backgroundColor "#DC3545"}}
         [:> rn/Text {:style {:color "#FFFFFF"
                              :fontSize 18
                              :fontWeight "600"}}
          "Error (Dev)"]
         [:> rn/TouchableOpacity
          {:onPress #(rf/dispatch [:dev/clear-error])
           :style {:padding 8}}
          [:> rn/Text {:style {:color "#FFFFFF"
                               :fontSize 16}}
           "Dismiss"]]]

        ;; Error message
        [:> rn/ScrollView {:style {:flex 1
                                   :padding 16}}
         [:> rn/Text {:style {:color "#FF6B6B"
                              :fontSize 16
                              :fontWeight "600"
                              :marginBottom 8}}
          "Message:"]
         [:> rn/Text {:style {:color "#FFFFFF"
                              :fontSize 14
                              :marginBottom 16
                              :fontFamily (if (= (.-OS rn/Platform) "ios")
                                            "Menlo"
                                            "monospace")}}
          (:message error)]

         [:> rn/Text {:style {:color "#FF6B6B"
                              :fontSize 16
                              :fontWeight "600"
                              :marginBottom 8}}
          "Stack Trace:"]
         [:> rn/Text {:style {:color "#CCCCCC"
                              :fontSize 12
                              :fontFamily (if (= (.-OS rn/Platform) "ios")
                                            "Menlo"
                                            "monospace")
                              :lineHeight 18}}
          (:stack error)]]

        ;; Copy button
        [:> rn/View {:style {:padding 16
                             :paddingBottom 32}}
         [:> rn/TouchableOpacity
          {:onPress (fn []
                      (copy-to-clipboard! (format-error error))
                      (reset! copied? true)
                      (js/setTimeout #(reset! copied? false) 2000))
           :style {:backgroundColor (if @copied? "#28A745" "#007AFF")
                   :borderRadius 12
                   :padding 16
                   :alignItems "center"}}
          [:> rn/Text {:style {:color "#FFFFFF"
                               :fontSize 16
                               :fontWeight "600"}}
           (if @copied? "Copied!" "Copy to Clipboard")]]]]])))))

(defn with-error-overlay
  "Wrap a component with the error overlay (dev-only)."
  [child]
  (if ^boolean js/goog.DEBUG
    [:> rn/View {:style {:flex 1}}
     child
     [error-overlay]]
    child))
