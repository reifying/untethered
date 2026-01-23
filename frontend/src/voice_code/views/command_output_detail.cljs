(ns voice-code.views.command-output-detail
  "Command output detail view showing full output from a command execution.
   Displays complete stdout/stderr with metadata."
  (:require [reagent.core :as r]
            [re-frame.core :as rf]
            ["react-native" :as rn]
            ["@react-native-clipboard/clipboard" :as Clipboard]
            [voice-code.haptic :as haptic]))

;; ============================================================================
;; Helper Functions
;; ============================================================================

(defn- format-duration
  "Format duration in milliseconds to human-readable string."
  [ms]
  (when ms
    (cond
      (< ms 1000) (str ms "ms")
      (< ms 60000) (str (/ (Math/round (/ ms 100)) 10) "s")
      :else (let [minutes (quot ms 60000)
                  seconds (quot (mod ms 60000) 1000)]
              (str minutes "m " seconds "s")))))

(defn- format-timestamp
  "Format timestamp for display."
  [timestamp]
  (when timestamp
    (let [date (if (instance? js/Date timestamp)
                 timestamp
                 (js/Date. timestamp))]
      (.toLocaleString date "en-US"
                       #js {:month "short"
                            :day "numeric"
                            :hour "numeric"
                            :minute "2-digit"
                            :second "2-digit"}))))

;; ============================================================================
;; Components
;; ============================================================================

(defn- metadata-header
  "Header showing command metadata."
  [{:keys [shell-command exit-code timestamp duration-ms working-directory]}]
  [:> rn/View {:style {:padding 16
                       :background-color "#F8F9FA"
                       :border-bottom-width 1
                       :border-bottom-color "#DEE2E6"}}
   ;; Command
   [:> rn/Text {:style {:font-size 13
                        :color "#6C757D"
                        :margin-bottom 4}}
    "Command"]
   [:> rn/Text {:style {:font-size 16
                        :font-weight "600"
                        :font-family "monospace"
                        :color "#212529"
                        :margin-bottom 12}}
    (or shell-command "Unknown")]

   ;; Metadata row
   [:> rn/View {:style {:flex-direction "row"
                        :flex-wrap "wrap"
                        :margin-top 4}}
    ;; Exit code
    (when (some? exit-code)
      [:> rn/View {:style {:flex-direction "row"
                           :align-items "center"
                           :margin-right 16
                           :margin-bottom 4}}
       [:> rn/View {:style {:width 8
                            :height 8
                            :border-radius 4
                            :background-color (if (= exit-code 0) "#34C759" "#FF3B30")
                            :margin-right 6}}]
       [:> rn/Text {:style {:font-size 13
                            :color (if (= exit-code 0) "#34C759" "#FF3B30")
                            :font-weight "500"}}
        (if (= exit-code 0) "Success" (str "Exit " exit-code))]])

    ;; Duration
    (when duration-ms
      [:> rn/View {:style {:flex-direction "row"
                           :align-items "center"
                           :margin-right 16
                           :margin-bottom 4}}
       [:> rn/Text {:style {:font-size 13 :color "#6C757D"}}
        (str "⏱ " (format-duration duration-ms))]])

    ;; Timestamp
    (when timestamp
      [:> rn/View {:style {:flex-direction "row"
                           :align-items "center"
                           :margin-bottom 4}}
       [:> rn/Text {:style {:font-size 13 :color "#6C757D"}}
        (format-timestamp timestamp)]])]

   ;; Working directory
   (when working-directory
     [:> rn/View {:style {:margin-top 8}}
      [:> rn/Text {:style {:font-size 12 :color "#6C757D"}}
       (str "📁 " working-directory)]])])

(defn- output-view
  "Scrollable output display."
  [{:keys [output]}]
  [:> rn/ScrollView {:style {:flex 1
                             :background-color "#1E1E1E"}
                     :content-container-style {:padding 12}}
   (if (and output (seq output))
     [:> rn/Text {:style {:font-family "monospace"
                          :font-size 13
                          :line-height 20
                          :color "#D4D4D4"}
                  :selectable true}
      output]
     [:> rn/Text {:style {:font-family "monospace"
                          :font-size 13
                          :color "#6C757D"
                          :font-style "italic"}}
      "No output"])])

(defn- loading-state
  "Shown while loading output."
  []
  [:> rn/View {:style {:flex 1
                       :justify-content "center"
                       :align-items "center"
                       :background-color "#1E1E1E"}}
   [:> rn/ActivityIndicator {:size "large" :color "#007AFF"}]
   [:> rn/Text {:style {:margin-top 12
                        :font-size 14
                        :color "#D4D4D4"}}
    "Loading output..."]])

(defn- copy-button
  "Button to copy output to clipboard with haptic feedback."
  [output]
  [:> rn/TouchableOpacity
   {:style {:position "absolute"
            :top 8
            :right 8
            :padding 8
            :background-color "rgba(255,255,255,0.1)"
            :border-radius 6}
    :on-press (fn []
                (let [clipboard (or (.-default Clipboard) Clipboard)]
                  (.setString clipboard output)
                  (haptic/success!)))}
   [:> rn/Text {:style {:font-size 14 :color "#D4D4D4"}}
    "📋 Copy"]])

;; ============================================================================
;; Main View
;; ============================================================================

(defn command-output-detail-view
  "Main command output detail screen showing full command output.
   Uses Form-2 component pattern for proper Reagent reactivity."
  [props]
  (let [^js route (:route props)
        command-session-id (when route (some-> route .-params .-commandSessionId))
        shell-command (when route (some-> route .-params .-shellCommand))]
    (fn [_props]
      (let [;; Try to get from running commands first, then from output detail
            running @(rf/subscribe [:commands/running])
            running-cmd (get running command-session-id)
            output-detail @(rf/subscribe [:commands/output-detail])

            ;; Use running command data if available, else output detail
            cmd-data (or running-cmd output-detail)
            output (or (:output cmd-data)
                       (:output output-detail))
            exit-code (or (:exit-code cmd-data)
                          (:exit-code output-detail))
            timestamp (or (:started-at cmd-data)
                          (:timestamp output-detail))
            duration-ms (or (:duration-ms cmd-data)
                            (:duration-ms output-detail))
            working-directory (or (:working-directory cmd-data)
                                  (:working-directory output-detail))
            loading? (and (nil? output) (nil? running-cmd))]
        [:> rn/SafeAreaView {:style {:flex 1 :background-color "#1E1E1E"}}
         ;; Metadata header
         [metadata-header {:shell-command (or (:shell-command cmd-data) shell-command)
                           :exit-code exit-code
                           :timestamp timestamp
                           :duration-ms duration-ms
                           :working-directory working-directory}]

         ;; Output
         [:> rn/View {:style {:flex 1}}
          (if loading?
            [loading-state]
            [output-view {:output output}])

          ;; Copy button
          (when (and output (seq output))
            [copy-button output])]]))))
