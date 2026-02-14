(ns voice-code.views.command-history
  "Command history view showing previously executed commands with output details.
   Provides list of recent commands with exit codes, duration, and output preview."
  (:require [reagent.core :as r]
            [re-frame.core :as rf]
            ["react-native" :as rn :refer [RefreshControl]]
            [voice-code.icons :as icons]
            [voice-code.theme :as theme]))

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
  [exit-code colors]
  (let [success? (= exit-code 0)
        color (cond
                (nil? exit-code) (:text-secondary colors)
                success? (:success colors)
                :else (:destructive colors))]
    [:> rn/View {:style {:width 8
                         :height 8
                         :border-radius 4
                         :background-color color
                         :margin-right 12}}]))

(defn- history-item
  "Single command history item in the list."
  [{:keys [command on-press colors]}]
  (let [{:keys [command-session-id command-id shell-command working-directory
                timestamp exit-code duration-ms output-preview]} command]
    [:> rn/TouchableOpacity
     {:style {:padding-horizontal 16
              :padding-vertical 14
              :background-color (:row-background colors)
              :border-bottom-width 1
              :border-bottom-color (:separator colors)}
      :on-press #(on-press command)}
     [:> rn/View {:style {:flex-direction "row"
                          :align-items "flex-start"}}
      ;; Exit code indicator
      [:> rn/View {:style {:padding-top 6}}
       [exit-code-indicator exit-code colors]]

      ;; Command info
      [:> rn/View {:style {:flex 1}}
       ;; Shell command
       [:> rn/Text {:style {:font-size 15
                            :font-weight "600"
                            :font-family "monospace"
                            :color (:text-primary colors)
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
                               :color (:text-secondary colors)}}
           (format-timestamp timestamp)])
        ;; Duration
        (when duration-ms
          [:> rn/Text {:style {:font-size 12
                               :color (:text-secondary colors)
                               :margin-left 12}}
           [:> rn/View {:style {:flex-direction "row" :align-items "center"}}
            [icons/icon {:name :clock :size 12 :color (:text-secondary colors) :style {:margin-right 4}}]
            [:> rn/Text {:style {:font-size 12 :color (:text-secondary colors)}}
             (format-duration duration-ms)]]])
        ;; Exit code
        (when (some? exit-code)
          [:> rn/Text {:style {:font-size 12
                               :color (if (= exit-code 0) (:success colors) (:destructive colors))
                               :margin-left 12
                               :font-weight "500"}}
           [:> rn/View {:style {:flex-direction "row" :align-items "center"}}
            [icons/icon {:name (if (= exit-code 0) :checkmark :close)
                         :size 12
                         :color (if (= exit-code 0) (:success colors) (:destructive colors))
                         :style {:margin-right 4}}]
            (if (= exit-code 0) "Success" (str "Exit " exit-code))]])]

       ;; Output preview
       (when (and output-preview (seq output-preview))
         [:> rn/Text {:style {:font-size 13
                              :color (:text-secondary colors)
                              :font-family "monospace"
                              :background-color (:background-secondary colors)
                              :padding 8
                              :border-radius 6
                              :overflow "hidden"}
                      :number-of-lines 2}
          (truncate-preview output-preview 150)])]]]))

(defn- empty-state
  "Shown when there is no command history."
  [colors]
  [:> rn/View {:style {:flex 1
                       :justify-content "center"
                       :align-items "center"
                       :padding 40}}
   [:> rn/View {:style {:margin-bottom 16}}
    [icons/icon {:name :history :size 48 :color (:text-secondary colors)}]]
   [:> rn/Text {:style {:font-size 18
                        :font-weight "600"
                        :color (:text-primary colors)
                        :text-align "center"}}
    "No Command History"]
   [:> rn/Text {:style {:font-size 14
                        :color (:text-secondary colors)
                        :text-align "center"
                        :margin-top 8}}
    "Previously executed commands will appear here."]])

(defn- loading-state
  "Shown while fetching history."
  [colors]
  [:> rn/View {:style {:flex 1
                       :justify-content "center"
                       :align-items "center"}}
   [:> rn/ActivityIndicator {:size "large" :color (:accent colors)}]
   [:> rn/Text {:style {:margin-top 12
                        :font-size 14
                        :color (:text-secondary colors)}}
    "Loading history..."]])

;; ============================================================================
;; Main View
;; ============================================================================

(defn command-history-view
  "Main command history screen showing list of executed commands.
   Uses Form-2 component pattern for proper Reagent reactivity."
  [props]
  (let [^js route (:route props)
        navigation (:navigation props)
        working-directory (when route (some-> route .-params .-workingDirectory))]
    ;; Fetch history on mount
    (r/create-class
     {:component-did-mount
      (fn [_]
        (rf/dispatch [:commands/get-history working-directory]))

      :reagent-render
      (fn [_props]
        [:f>
         (fn []
           (let [colors (theme/use-theme-colors)
                 history @(rf/subscribe [:commands/history])
                 refreshing? @(rf/subscribe [:ui/refreshing-command-history?])
                 loading? false] ; Could track loading state if needed
             [:> rn/SafeAreaView {:style {:flex 1 :background-color (:grouped-background colors)}}
           (cond
             loading?
             [loading-state colors]

             (empty? history)
             [empty-state colors]

             :else
             [:> rn/FlatList
              {:data (clj->js history)
               :key-extractor (fn [item idx]
                                ;; clj->js converts :command-session-id to "command-session-id"
                                (or (aget item "command-session-id")
                                    (str "cmd-" idx)))
               :render-item
               (fn [^js obj]
                 (let [item (.-item obj)
                       ;; clj->js converts kebab-case keywords to hyphenated strings
                       ;; e.g., :shell-command becomes "shell-command"
                       cmd {:command-session-id (aget item "command-session-id")
                            :command-id (aget item "command-id")
                            :shell-command (aget item "shell-command")
                            :working-directory (aget item "working-directory")
                            :timestamp (aget item "timestamp")
                            :exit-code (aget item "exit-code")
                            :duration-ms (aget item "duration-ms")
                            :output-preview (aget item "output-preview")}]
                   (r/as-element
                    [history-item
                     {:command cmd
                      :colors colors
                      :on-press (fn [c]
                                  (rf/dispatch [:commands/get-output (:command-session-id c)])
                                  (when navigation
                                    (.navigate navigation "CommandOutputDetail"
                                               #js {:commandSessionId (:command-session-id c)
                                                    :shellCommand (:shell-command c)})))}])))
               :refresh-control
               (r/as-element
                [:> RefreshControl
                 {:refreshing (boolean refreshing?)
                  :on-refresh #(rf/dispatch [:commands/refresh-history working-directory])
                  :tint-color (:accent colors)
                  :colors #js [(:accent colors)]}])
               :content-container-style {:padding-vertical 8}}])]))])})))
