(ns voice-code.views.command-output-detail
  "Command output detail view showing full output from a command execution.
   Displays complete stdout/stderr with metadata."
  (:require [reagent.core :as r]
            [re-frame.core :as rf]
            ["react-native" :refer [Share] :as rn]
            [voice-code.haptic :as haptic]
            [voice-code.icons :as icons]
            [voice-code.platform :as platform]
            [voice-code.theme :as theme]
            [voice-code.views.components :refer [copy-to-clipboard!]]
            [voice-code.views.touchable :refer [touchable]]))

;; ============================================================================
;; Helper Functions
;; ============================================================================

(defn format-duration
  "Format duration in milliseconds to human-readable string."
  [ms]
  (when ms
    (cond
      (< ms 1000) (str ms "ms")
      (< ms 60000) (str (/ (Math/round (/ ms 100)) 10) "s")
      :else (let [minutes (quot ms 60000)
                  seconds (quot (mod ms 60000) 1000)]
              (str minutes "m " seconds "s")))))

(defn format-timestamp
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

(defn build-share-text
  "Build formatted text for sharing command output with metadata.
   Matches iOS shareText format from CommandOutputDetailView.swift."
  [{:keys [shell-command working-directory exit-code duration-ms timestamp output]}]
  (str "Command: " (or shell-command "Unknown") "\n"
       "Directory: " (or working-directory "Unknown") "\n"
       "Exit Code: " (if (some? exit-code) exit-code "N/A") "\n"
       "Duration: " (or (format-duration duration-ms) "N/A") "\n"
       "Started: " (or (format-timestamp timestamp) "N/A") "\n\n"
       "Output:\n" (or output "(no output)")))

;; ============================================================================
;; Components
;; ============================================================================

(defn- metadata-header
  "Header showing command metadata."
  [{:keys [shell-command exit-code timestamp duration-ms working-directory colors]}]
  [:> rn/View {:style {:padding 16
                       :background-color (:grouped-background colors)
                       :border-bottom-width 1
                       :border-bottom-color (:separator colors)}}
   ;; Command
   [:> rn/Text {:style {:font-size 13
                        :color (:text-secondary colors)
                        :margin-bottom 4}}
    "Command"]
   [:> rn/Text {:style {:font-size 16
                        :font-weight "600"
                        :font-family platform/monospace-font
                        :color (:text-primary colors)
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
                            :background-color (if (= exit-code 0) (:success colors) (:destructive colors))
                            :margin-right 6}}]
       [:> rn/Text {:style {:font-size 13
                            :color (if (= exit-code 0) (:success colors) (:destructive colors))
                            :font-weight "500"}}
        (if (= exit-code 0) "Success" (str "Exit " exit-code))]])

    ;; Duration
    (when duration-ms
      [:> rn/View {:style {:flex-direction "row"
                           :align-items "center"
                           :margin-right 16
                           :margin-bottom 4}}
       [icons/icon {:name :clock
                    :size 13
                    :color (:text-secondary colors)
                    :style {:margin-right 4}}]
       [:> rn/Text {:style {:font-size 13 :color (:text-secondary colors)}}
        (format-duration duration-ms)]])

    ;; Timestamp
    (when timestamp
      [:> rn/View {:style {:flex-direction "row"
                           :align-items "center"
                           :margin-bottom 4}}
       [:> rn/Text {:style {:font-size 13 :color (:text-secondary colors)}}
        (format-timestamp timestamp)]])]

   ;; Working directory
   (when working-directory
     [:> rn/View {:style {:margin-top 8
                          :flex-direction "row"
                          :align-items "center"}}
      [icons/icon {:name :folder
                   :size 12
                   :color (:text-secondary colors)
                   :style {:margin-right 4}}]
      [:> rn/Text {:style {:font-size 12 :color (:text-secondary colors)}}
       working-directory]])])

(defn- output-view
  "Scrollable output display."
  [{:keys [output colors]}]
  [:> rn/ScrollView {:style {:flex 1
                             :background-color (:background-secondary colors)}
                     :content-container-style {:padding 12}}
   (if (and output (seq output))
     [:> rn/Text {:style {:font-family platform/monospace-font
                          :font-size 13
                          :line-height 20
                          :color (:text-primary colors)}
                  :selectable true}
      output]
     [:> rn/Text {:style {:font-family platform/monospace-font
                          :font-size 13
                          :color (:text-secondary colors)
                          :font-style "italic"}}
      "No output"])])

(defn- loading-state
  "Shown while loading output."
  [colors]
  [:> rn/View {:style {:flex 1
                       :justify-content "center"
                       :align-items "center"
                       :background-color (:background-secondary colors)}}
   [:> rn/ActivityIndicator {:size "large" :color (:accent colors)}]
   [:> rn/Text {:style {:margin-top 12
                        :font-size 14
                        :color (:text-primary colors)}}
    "Loading output..."]])

(defn- action-button
  "Individual action button component."
  [{:keys [icon label on-press colors]}]
  [touchable
   {:style {:flex-direction "row"
            :align-items "center"
            :padding-horizontal 12
            :padding-vertical 8
            :background-color (:overlay colors)
            :border-radius 6}
    :on-press on-press}
   [icons/icon {:name icon :size 14 :color (:text-primary colors) :style {:margin-right 6}}]
   [:> rn/Text {:style {:font-size 14 :color (:text-primary colors)}}
    label]])

(defn- action-buttons
  "Action buttons for copy and share functionality.
   Matches iOS CommandOutputDetailView toolbar menu options."
  [{:keys [output share-data colors]}]
  [:> rn/View {:style {:position "absolute"
                       :top 8
                       :right 8
                       :flex-direction "row"
                       :gap 8}}
   ;; Share button
   [action-button
    {:icon :share
     :label "Share"
     :colors colors
     :on-press (fn []
                 (let [share-text (build-share-text share-data)]
                   (-> (Share.share #js {:message share-text})
                       (.then (fn [result]
                                (when (= (.-action result) (.-sharedAction Share))
                                  (haptic/success!))))
                       (.catch (fn [_error]
                                 ;; User cancelled or error - no action needed
                                 nil)))))}]
   ;; Copy button
   [action-button
    {:icon :clipboard
     :label "Copy"
     :colors colors
     :on-press #(copy-to-clipboard! output nil)}]])

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
      [:f>
       (fn []
         (let [colors (theme/use-theme-colors)
               ;; Try to get from running commands first, then from output detail
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
        [:> rn/SafeAreaView {:style {:flex 1 :background-color (:background-secondary colors)}}
         ;; Metadata header
         [metadata-header {:shell-command (or (:shell-command cmd-data) shell-command)
                           :exit-code exit-code
                           :timestamp timestamp
                           :duration-ms duration-ms
                           :working-directory working-directory
                           :colors colors}]

         ;; Output
         [:> rn/View {:style {:flex 1}}
          (if loading?
            [loading-state colors]
            [output-view {:output output :colors colors}])

          ;; Action buttons (copy and share)
          (when (and output (seq output))
            [action-buttons {:output output
                             :share-data {:shell-command (or (:shell-command cmd-data) shell-command)
                                          :working-directory working-directory
                                          :exit-code exit-code
                                          :duration-ms duration-ms
                                          :timestamp timestamp
                                          :output output}
                             :colors colors}])]]))])))
