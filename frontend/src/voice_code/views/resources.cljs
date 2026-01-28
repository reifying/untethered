(ns voice-code.views.resources
  "Resources view for managing uploaded files.
   Displays list of uploaded resources with delete functionality.
   Implements swipe-to-delete matching iOS ResourcesView.swift swipe actions."
  (:require [reagent.core :as r]
            [re-frame.core :as rf]
            ["react-native" :as rn :refer [RefreshControl Animated PanResponder]]
            [voice-code.haptic :as haptic]
            [voice-code.theme :as theme]))

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

;; Swipe-to-delete constants
(def ^:private swipe-threshold
  "Distance to swipe before delete action is triggered."
  -80)

(def ^:private delete-button-width
  "Width of the delete button revealed on swipe."
  80)

(defn- resource-item-content
  "The content portion of a resource item (icon, text, metadata).
   Extracted for use in swipeable wrapper."
  [{:keys [filename size timestamp colors]}]
  [:> rn/View {:style {:flex-direction "row"
                       :align-items "center"
                       :padding-horizontal 16
                       :padding-vertical 12
                       :background-color (:row-background colors)}}
   ;; File icon
   [:> rn/View {:style {:width 44
                        :height 44
                        :border-radius 8
                        :background-color (:background-secondary colors)
                        :align-items "center"
                        :justify-content "center"
                        :margin-right 12}}
    [:> rn/Text {:style {:font-size 22}}
     (file-icon filename)]]

   ;; File info
   [:> rn/View {:style {:flex 1}}
    [:> rn/Text {:style {:font-size 16
                         :font-weight "500"
                         :color (:text-primary colors)
                         :margin-bottom 2}
                 :number-of-lines 1}
     filename]
    [:> rn/View {:style {:flex-direction "row"
                         :align-items "center"}}
     [:> rn/Text {:style {:font-size 12
                          :color (:text-secondary colors)}}
      (format-file-size size)]
     (when timestamp
       [:> rn/Text {:style {:font-size 12
                            :color (:text-secondary colors)
                            :margin-left 8}}
        (str "• " (format-timestamp timestamp))])]]])

(defn- swipeable-resource-item
  "Resource item with swipe-to-delete gesture support.
   Matches iOS ResourcesView.swift swipe actions (lines 36-44).
   Uses Animated and PanResponder for smooth gesture handling."
  [{:keys [resource on-delete colors]}]
  (let [;; Animated value for swipe position
        translate-x (Animated.Value. 0)
        ;; Track if item is swiped open
        is-swiped? (r/atom false)
        ;; PanResponder for gesture handling
        pan-responder
        (.create PanResponder
                 #js {:onStartShouldSetPanResponder (fn [] false)
                      :onMoveShouldSetPanResponder
                      (fn [_ gesture-state]
                        ;; Only respond to horizontal swipes
                        (let [dx (.-dx gesture-state)
                              dy (.-dy gesture-state)]
                          (and (< (js/Math.abs dy) 10)
                               (> (js/Math.abs dx) 10))))
                      :onPanResponderGrant
                      (fn [_ _]
                        ;; Set offset to current value to allow continuing swipe
                        (.setOffset translate-x (.-_value translate-x))
                        (.setValue translate-x 0))
                      :onPanResponderMove
                      (fn [_ gesture-state]
                        ;; Only allow swipe left (negative dx), clamp to button width
                        (let [dx (.-dx gesture-state)
                              clamped (max (- delete-button-width) (min 0 dx))]
                          (.setValue translate-x clamped)))
                      :onPanResponderRelease
                      (fn [_ gesture-state]
                        (.flattenOffset translate-x)
                        (let [current-val (.-_value translate-x)]
                          ;; If swiped past threshold, snap open
                          (if (< current-val (/ swipe-threshold 2))
                            (do
                              (reset! is-swiped? true)
                              (-> (.spring Animated translate-x
                                           #js {:toValue swipe-threshold
                                                :useNativeDriver false})
                                  (.start)))
                            ;; Otherwise snap closed
                            (do
                              (reset! is-swiped? false)
                              (-> (.spring Animated translate-x
                                           #js {:toValue 0
                                                :useNativeDriver false})
                                  (.start))))))})]
    (fn [{:keys [resource on-delete colors]}]
      [:> rn/View {:style {:overflow "hidden"
                           :border-bottom-width 1
                           :border-bottom-color (:separator colors)}}
       ;; Delete button behind (revealed on swipe)
       [:> rn/View {:style {:position "absolute"
                            :right 0
                            :top 0
                            :bottom 0
                            :width delete-button-width
                            :background-color (:destructive colors)
                            :justify-content "center"
                            :align-items "center"}}
        [:> rn/TouchableOpacity
         {:style {:flex 1
                  :width "100%"
                  :justify-content "center"
                  :align-items "center"}
          :on-press (fn []
                      ;; Haptic feedback on delete
                      (haptic/trigger! :warning)
                      ;; Animate out then delete
                      (-> (.timing Animated translate-x
                                   #js {:toValue -500
                                        :duration 200
                                        :useNativeDriver false})
                          (.start (fn [_] (on-delete resource)))))}
         [:> rn/Text {:style {:font-size 24}} "🗑️"]
         [:> rn/Text {:style {:color (:bubble-user-text colors)
                              :font-size 12
                              :font-weight "600"
                              :margin-top 2}}
          "Delete"]]]

       ;; Swipeable content - spread panHandlers onto the animated view
       (let [handlers (.-panHandlers pan-responder)]
         [:> (.-View Animated)
          (js/Object.assign
           #js {:style #js {:transform #js [#js {:translateX translate-x}]
                            :backgroundColor (:row-background colors)}}
           handlers)
          [resource-item-content
           {:filename (:filename resource)
            :size (:size resource)
            :timestamp (:timestamp resource)
            :colors colors}]])])))

(defn- resource-item
  "Single resource item in the list with swipe-to-delete.
   Wraps swipeable-resource-item for consistent API."
  [{:keys [resource on-delete colors]}]
  [swipeable-resource-item
   {:resource resource
    :on-delete on-delete
    :colors colors}])

(defn- pending-uploads-banner
  "Banner showing pending uploads count."
  [count colors]
  [:> rn/View {:style {:flex-direction "row"
                       :align-items "center"
                       :padding 12
                       :background-color (:warning-background colors)
                       :border-bottom-width 1
                       :border-bottom-color (:separator colors)}}
   [:> rn/ActivityIndicator {:size "small" :color (:warning colors)}]
   [:> rn/Text {:style {:margin-left 8
                        :font-size 14
                        :color (:warning colors)}}
    (str count " upload" (when (> count 1) "s") " in progress...")]])

(defn- empty-state
  "Shown when there are no resources."
  [colors]
  [:> rn/View {:style {:flex 1
                       :justify-content "center"
                       :align-items "center"
                       :padding 40}}
   [:> rn/Text {:style {:font-size 48 :margin-bottom 16}} "📁"]
   [:> rn/Text {:style {:font-size 18
                        :font-weight "600"
                        :color (:text-primary colors)
                        :text-align "center"}}
    "No Resources"]
   [:> rn/Text {:style {:font-size 14
                        :color (:text-secondary colors)
                        :text-align "center"
                        :margin-top 8}}
    "Uploaded files will appear here. Share files from other apps or use the upload feature."]])

(defn- upload-button
  "FAB for uploading new resources."
  [on-press colors]
  [:> rn/TouchableOpacity
   {:style {:position "absolute"
            :bottom 24
            :right 24
            :width 56
            :height 56
            :border-radius 28
            :background-color (:accent colors)
            :justify-content "center"
            :align-items "center"
            :shadow-color (:shadow colors)
            :shadow-offset #js {:width 0 :height 2}
            :shadow-opacity 0.25
            :shadow-radius 4
            :elevation 5}
    :on-press on-press}
   [:> rn/Text {:style {:font-size 24
                        :color (:bubble-user-text colors)}}
    "📤"]])

(defn resources-view
  "Main resources screen showing uploaded files.
   Uses Form-2 component pattern for proper Reagent reactivity with React Navigation."
  [^js _props]
  ;; Form-2: Return a render function that reads subscriptions
  (fn [^js _props]
    (let [colors (theme/use-theme-colors)
          resources @(rf/subscribe [:resources/list])
          pending-uploads @(rf/subscribe [:resources/pending-uploads])
          refreshing? @(rf/subscribe [:ui/refreshing-resources?])]
      [:> rn/SafeAreaView {:style {:flex 1 :background-color (:grouped-background colors)}}
       ;; Pending uploads banner
       (when (and pending-uploads (> pending-uploads 0))
         [pending-uploads-banner pending-uploads colors])

       ;; Resources list
       (if (empty? resources)
         [empty-state colors]
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
                  :on-delete #(rf/dispatch [:resources/delete (:filename %)])
                  :colors colors}])))
           :refresh-control
           (r/as-element
            [:> RefreshControl
             {:refreshing (boolean refreshing?)
              :on-refresh #(rf/dispatch [:resources/refresh])
              :tint-color (:accent colors)
              :colors #js [(:accent colors)]}])
           :content-container-style {:padding-vertical 8}}])

       ;; Upload FAB
       [upload-button #(rf/dispatch [:resources/upload]) colors]])))
