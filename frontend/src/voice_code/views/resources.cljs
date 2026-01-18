(ns voice-code.views.resources
  "Resources view for managing uploaded files.
   Displays list of uploaded resources with delete functionality."
  (:require [reagent.core :as r]
            [re-frame.core :as rf]
            ["react-native" :as rn]))

(defn- format-file-size
  "Format file size in bytes to human-readable string."
  [bytes]
  (cond
    (nil? bytes) "Unknown"
    (< bytes 1024) (str bytes " B")
    (< bytes (* 1024 1024)) (str (Math/round (/ bytes 1024)) " KB")
    :else (str (.toFixed (/ bytes (* 1024 1024)) 1) " MB")))

(defn- format-timestamp
  "Format timestamp for display."
  [timestamp]
  (when timestamp
    (.toLocaleDateString (js/Date. timestamp)
                         "en-US"
                         #js {:month "short"
                              :day "numeric"
                              :hour "numeric"
                              :minute "2-digit"})))

(defn- file-icon
  "Get icon based on file type."
  [filename]
  (let [ext (some-> filename
                    (.toLowerCase)
                    (.split ".")
                    last)]
    (case ext
      ("jpg" "jpeg" "png" "gif" "webp") "🖼️"
      ("pdf") "📄"
      ("txt" "md" "markdown") "📝"
      ("json" "edn" "yaml" "yml") "📋"
      ("zip" "tar" "gz") "📦"
      "📎")))

(defn- resource-item
  "Single resource item in the list."
  [{:keys [resource on-delete]}]
  (let [{:keys [filename path size timestamp]} resource
        confirm-delete? (r/atom false)]
    (fn [{:keys [resource on-delete]}]
      [:> rn/View {:style {:flex-direction "row"
                           :align-items "center"
                           :padding-horizontal 16
                           :padding-vertical 12
                           :background-color "#FFFFFF"
                           :border-bottom-width 1
                           :border-bottom-color "#F0F0F0"}}
       ;; File icon
       [:> rn/View {:style {:width 44
                            :height 44
                            :border-radius 8
                            :background-color "#F5F5F5"
                            :align-items "center"
                            :justify-content "center"
                            :margin-right 12}}
        [:> rn/Text {:style {:font-size 22}}
         (file-icon filename)]]

       ;; File info
       [:> rn/View {:style {:flex 1}}
        [:> rn/Text {:style {:font-size 16
                             :font-weight "500"
                             :color "#000"
                             :margin-bottom 2}
                     :number-of-lines 1}
         filename]
        [:> rn/View {:style {:flex-direction "row"
                             :align-items "center"}}
         [:> rn/Text {:style {:font-size 12
                              :color "#999"}}
          (format-file-size size)]
         (when timestamp
           [:> rn/Text {:style {:font-size 12
                                :color "#999"
                                :margin-left 8}}
            (str "• " (format-timestamp timestamp))])]]

       ;; Delete button
       (if @confirm-delete?
         [:> rn/View {:style {:flex-direction "row"}}
          [:> rn/TouchableOpacity
           {:style {:padding-horizontal 12
                    :padding-vertical 6
                    :background-color "#FF3B30"
                    :border-radius 6
                    :margin-right 8}
            :on-press #(do (on-delete resource)
                           (reset! confirm-delete? false))}
           [:> rn/Text {:style {:color "#FFF"
                                :font-size 14
                                :font-weight "500"}}
            "Delete"]]
          [:> rn/TouchableOpacity
           {:style {:padding-horizontal 12
                    :padding-vertical 6
                    :background-color "#E5E5E5"
                    :border-radius 6}
            :on-press #(reset! confirm-delete? false)}
           [:> rn/Text {:style {:color "#666"
                                :font-size 14}}
            "Cancel"]]]

         [:> rn/TouchableOpacity
          {:style {:padding 8}
           :on-press #(reset! confirm-delete? true)}
          [:> rn/Text {:style {:font-size 20
                               :color "#FF3B30"}}
           "🗑️"]])])))

(defn- pending-uploads-banner
  "Banner showing pending uploads count."
  [count]
  [:> rn/View {:style {:flex-direction "row"
                       :align-items "center"
                       :padding 12
                       :background-color "#FFF3CD"
                       :border-bottom-width 1
                       :border-bottom-color "#FFE69C"}}
   [:> rn/ActivityIndicator {:size "small" :color "#856404"}]
   [:> rn/Text {:style {:margin-left 8
                        :font-size 14
                        :color "#856404"}}
    (str count " upload" (when (> count 1) "s") " in progress...")]])

(defn- empty-state
  "Shown when there are no resources."
  []
  [:> rn/View {:style {:flex 1
                       :justify-content "center"
                       :align-items "center"
                       :padding 40}}
   [:> rn/Text {:style {:font-size 48 :margin-bottom 16}} "📁"]
   [:> rn/Text {:style {:font-size 18
                        :font-weight "600"
                        :color "#333"
                        :text-align "center"}}
    "No Resources"]
   [:> rn/Text {:style {:font-size 14
                        :color "#666"
                        :text-align "center"
                        :margin-top 8}}
    "Uploaded files will appear here. Share files from other apps or use the upload feature."]])

(defn- upload-button
  "FAB for uploading new resources."
  [on-press]
  [:> rn/TouchableOpacity
   {:style {:position "absolute"
            :bottom 24
            :right 24
            :width 56
            :height 56
            :border-radius 28
            :background-color "#007AFF"
            :justify-content "center"
            :align-items "center"
            :shadow-color "#000"
            :shadow-offset #js {:width 0 :height 2}
            :shadow-opacity 0.25
            :shadow-radius 4
            :elevation 5}
    :on-press on-press}
   [:> rn/Text {:style {:font-size 24
                        :color "#FFF"}}
    "📤"]])

(defn resources-view
  "Main resources screen showing uploaded files.
   Uses Form-2 component pattern for proper Reagent reactivity with React Navigation."
  [^js _props]
  ;; Form-2: Return a render function that reads subscriptions
  (fn [^js _props]
    (let [resources @(rf/subscribe [:resources/list])
          pending-uploads @(rf/subscribe [:resources/pending-uploads])]
      [:> rn/SafeAreaView {:style {:flex 1 :background-color "#F5F5F5"}}
       ;; Pending uploads banner
       (when (and pending-uploads (> pending-uploads 0))
         [pending-uploads-banner pending-uploads])

       ;; Resources list
       (if (empty? resources)
         [empty-state]
         [:> rn/FlatList
          {:data (clj->js resources)
           :key-extractor (fn [item _idx]
                            (or (.-filename item)
                                (.-path item)
                                (str (random-uuid))))
           :render-item
           (fn [^js obj]
             (let [item (.-item obj)
                   resource {:filename (.-filename item)
                             :path (.-path item)
                             :size (.-size item)
                             :timestamp (.-timestamp item)}]
               (r/as-element
                [resource-item
                 {:resource resource
                  :on-delete #(rf/dispatch [:resources/delete (:filename %)])}])))
           :content-container-style {:padding-vertical 8}}])

       ;; Upload FAB
       [upload-button #(rf/dispatch [:resources/upload])]])))
