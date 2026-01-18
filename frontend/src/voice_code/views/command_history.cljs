(ns voice-code.views.command-history
  "Command history view showing previously executed commands with output details.
   Provides list of recent commands with exit codes, duration, and output preview."
  (:require [reagent.core :as r]
            [re-frame.core :as rf]
            ["react-native" :as rn]))

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
                            :minute "2-digit"}))))

(defn- truncate-preview
  "Truncate output preview to reasonable length."
  [text max-len]
  (when text
    (if (> (count text) max-len)
      (str (subs text 0 max-len) "...")
      text)))

;; ============================================================================
;; Components
;; ============================================================================

(defn- exit-code-indicator
  "Color-coded exit code badge."
  [exit-code]
  (let [success? (= exit-code 0)
        color (cond
                (nil? exit-code) "#999"
                success? "#34C759"
                :else "#FF3B30")]
    [:> rn/View {:style {:width 8
                         :height 8
                         :border-radius 4
                         :background-color color
                         :margin-right 12}}]))

(defn- history-item
  "Single command history item in the list."
  [{:keys [command on-press]}]
  (let [{:keys [command-session-id command-id shell-command working-directory
                timestamp exit-code duration-ms output-preview]} command]
    [:> rn/TouchableOpacity
     {:style {:padding-horizontal 16
              :padding-vertical 14
              :background-color "#FFFFFF"
              :border-bottom-width 1
              :border-bottom-color "#F0F0F0"}
      :on-press #(on-press command)}
     [:> rn/View {:style {:flex-direction "row"
                          :align-items "flex-start"}}
      ;; Exit code indicator
      [:> rn/View {:style {:padding-top 6}}
       [exit-code-indicator exit-code]]

      ;; Command info
      [:> rn/View {:style {:flex 1}}
       ;; Shell command
       [:> rn/Text {:style {:font-size 15
                            :font-weight "600"
                            :font-family "monospace"
                            :color "#000"
                            :margin-bottom 4}
                    :number-of-lines 1}
        (or shell-command command-id "Unknown command")]

       ;; Metadata row
       [:> rn/View {:style {:flex-direction "row"
                            :align-items "center"
                            :margin-bottom 6}}
        ;; Timestamp
        (when timestamp
          [:> rn/Text {:style {:font-size 12
                               :color "#666"}}
           (format-timestamp timestamp)])
        ;; Duration
        (when duration-ms
          [:> rn/Text {:style {:font-size 12
                               :color "#666"
                               :margin-left 12}}
           (str "⏱ " (format-duration duration-ms))])
        ;; Exit code
        (when (some? exit-code)
          [:> rn/Text {:style {:font-size 12
                               :color (if (= exit-code 0) "#34C759" "#FF3B30")
                               :margin-left 12
                               :font-weight "500"}}
           (if (= exit-code 0) "✓ Success" (str "✗ Exit " exit-code))])]

       ;; Output preview
       (when (and output-preview (seq output-preview))
         [:> rn/Text {:style {:font-size 13
                              :color "#666"
                              :font-family "monospace"
                              :background-color "#F8F8F8"
                              :padding 8
                              :border-radius 6
                              :overflow "hidden"}
                      :number-of-lines 2}
          (truncate-preview output-preview 150)])]]]))

(defn- empty-state
  "Shown when there is no command history."
  []
  [:> rn/View {:style {:flex 1
                       :justify-content "center"
                       :align-items "center"
                       :padding 40}}
   [:> rn/Text {:style {:font-size 48 :margin-bottom 16}} "📜"]
   [:> rn/Text {:style {:font-size 18
                        :font-weight "600"
                        :color "#333"
                        :text-align "center"}}
    "No Command History"]
   [:> rn/Text {:style {:font-size 14
                        :color "#666"
                        :text-align "center"
                        :margin-top 8}}
    "Previously executed commands will appear here."]])

(defn- loading-state
  "Shown while fetching history."
  []
  [:> rn/View {:style {:flex 1
                       :justify-content "center"
                       :align-items "center"}}
   [:> rn/ActivityIndicator {:size "large" :color "#007AFF"}]
   [:> rn/Text {:style {:margin-top 12
                        :font-size 14
                        :color "#666"}}
    "Loading history..."]])

;; ============================================================================
;; Main View
;; ============================================================================

(defn command-history-view
  "Main command history screen showing list of executed commands.
   Uses Form-2 component pattern for proper Reagent reactivity."
  [props]
  (let [route (:route props)
        navigation (:navigation props)
        working-directory (when route (some-> route .-params .-workingDirectory))]
    ;; Fetch history on mount
    (r/create-class
     {:component-did-mount
      (fn [_]
        (rf/dispatch [:commands/get-history working-directory]))

      :reagent-render
      (fn [_props]
        (let [history @(rf/subscribe [:commands/history])
              loading? false] ; Could track loading state if needed
          [:> rn/SafeAreaView {:style {:flex 1 :background-color "#F5F5F5"}}
           (cond
             loading?
             [loading-state]

             (empty? history)
             [empty-state]

             :else
             [:> rn/FlatList
              {:data (clj->js history)
               :key-extractor (fn [item _idx]
                                (or (.-command_session_id item)
                                    (.-commandSessionId item)
                                    (str (random-uuid))))
               :render-item
               (fn [^js obj]
                 (let [item (.-item obj)
                       cmd {:command-session-id (or (.-command_session_id item)
                                                    (.-commandSessionId item))
                            :command-id (or (.-command_id item)
                                            (.-commandId item))
                            :shell-command (or (.-shell_command item)
                                               (.-shellCommand item))
                            :working-directory (or (.-working_directory item)
                                                   (.-workingDirectory item))
                            :timestamp (.-timestamp item)
                            :exit-code (or (.-exit_code item)
                                           (.-exitCode item))
                            :duration-ms (or (.-duration_ms item)
                                             (.-durationMs item))
                            :output-preview (or (.-output_preview item)
                                                (.-outputPreview item))}]
                   (r/as-element
                    [history-item
                     {:command cmd
                      :on-press (fn [c]
                                  (rf/dispatch [:commands/get-output (:command-session-id c)])
                                  (when navigation
                                    (.navigate navigation "CommandOutputDetail"
                                               #js {:commandSessionId (:command-session-id c)
                                                    :shellCommand (:shell-command c)})))}])))
               :content-container-style {:padding-vertical 8}}])]))})))
