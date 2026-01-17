(ns voice-code.views.directory-list
  "Directory list view showing sessions grouped by working directory."
  (:require [reagent.core :as r]
            [re-frame.core :as rf]
            ["react-native" :as rn]
            [clojure.string :as str]))

(defn- format-relative-time
  "Format a timestamp as relative time (e.g., '2 hours ago')."
  [timestamp]
  (when timestamp
    (let [now (js/Date.)
          diff (- (.getTime now) (.getTime (js/Date. timestamp)))
          minutes (Math/floor (/ diff 60000))
          hours (Math/floor (/ minutes 60))
          days (Math/floor (/ hours 24))]
      (cond
        (< minutes 1) "Just now"
        (< minutes 60) (str minutes " min ago")
        (< hours 24) (str hours " hour" (when (not= hours 1) "s") " ago")
        (< days 7) (str days " day" (when (not= days 1) "s") " ago")
        :else (.toLocaleDateString (js/Date. timestamp))))))

(defn- directory-name
  "Extract the directory name from a path."
  [path]
  (when path
    (or (last (str/split path #"/")) path)))

(defn- directory-item
  "Single directory item in the list."
  [{:keys [directory session-count last-modified on-press]}]
  [:> rn/TouchableOpacity
   {:style {:padding-horizontal 16
            :padding-vertical 14
            :border-bottom-width 1
            :border-bottom-color "#F0F0F0"
            :background-color "#FFFFFF"}
    :on-press on-press
    :active-opacity 0.7}
   [:> rn/View {:style {:flex-direction "row"
                        :justify-content "space-between"
                        :align-items "flex-start"}}
    [:> rn/View {:style {:flex 1 :margin-right 12}}
     ;; Directory name
     [:> rn/Text {:style {:font-size 17
                          :font-weight "600"
                          :color "#000"
                          :margin-bottom 4}}
      (directory-name directory)]
     ;; Full path
     [:> rn/Text {:style {:font-size 13
                          :color "#666"
                          :margin-bottom 2}
                  :number-of-lines 1}
      directory]
     ;; Session count
     [:> rn/Text {:style {:font-size 12 :color "#999"}}
      (str session-count " session" (when (not= session-count 1) "s"))]]

    ;; Last modified time
    [:> rn/Text {:style {:font-size 12
                         :color "#999"}}
     (format-relative-time last-modified)]]])

(defn- empty-state
  "Shown when there are no directories/sessions."
  []
  [:> rn/View {:style {:flex 1
                       :justify-content "center"
                       :align-items "center"
                       :padding 40}}
   [:> rn/Text {:style {:font-size 18
                        :font-weight "600"
                        :color "#333"
                        :margin-bottom 8}}
    "No Projects Yet"]
   [:> rn/Text {:style {:font-size 14
                        :color "#666"
                        :text-align "center"}}
    "Sessions will appear here grouped by their working directory."]])

(defn- settings-button
  "Settings button for the header."
  [navigation]
  [:> rn/TouchableOpacity
   {:style {:padding 8}
    :on-press #(.navigate navigation "Settings")}
   [:> rn/Text {:style {:font-size 22}} "⚙️"]])

(defn directory-list-view
  "Main directory list screen."
  [^js props]
  (let [navigation (.-navigation props)
        directories @(rf/subscribe [:sessions/directories])
        loading? @(rf/subscribe [:ui/loading?])]

    ;; Set up header right button
    (r/create-class
     {:component-did-mount
      (fn [_]
        (.setOptions navigation
                     #js {:headerRight #(r/as-element [settings-button navigation])}))

      :reagent-render
      (fn [_]
        [:> rn/View {:style {:flex 1 :background-color "#F5F5F5"}}
         (if loading?
           ;; Loading state
           [:> rn/View {:style {:flex 1
                                :justify-content "center"
                                :align-items "center"}}
            [:> rn/ActivityIndicator {:size "large" :color "#007AFF"}]]

           ;; Directory list
           (if (empty? directories)
             [empty-state]
             [:> rn/FlatList
              {:data (clj->js directories)
               :key-extractor (fn [item _idx]
                                (or (.-directory item) (str (random-uuid))))
               :render-item
               (fn [^js obj]
                 (let [item (.-item obj)
                       dir-data {:directory (.-directory item)
                                 :session-count (.-sessionCount item)
                                 :last-modified (.-lastModified item)}]
                   (r/as-element
                    [directory-item
                     (assoc dir-data
                            :on-press #(.navigate navigation "SessionList"
                                                  #js {:directory (.-directory item)
                                                       :directoryName (directory-name (.-directory item))}))])))
               :content-container-style {:padding-vertical 8}}]))])})))
