(ns voice-code.views.voice-picker
  "Voice picker modal for selecting TTS voice.
   Displays available English voices with quality indicators."
  (:require [reagent.core :as r]
            [re-frame.core :as rf]
            ["react-native" :as rn]
            [voice-code.voice :as voice]))

(def ^:private quality-labels
  "Map quality values to human-readable labels.
   Higher numbers = better quality."
  {500 "Premium"
   400 "Enhanced"
   300 "High Quality"
   200 "Standard"
   100 "Compact"})

(defn- quality-badge
  "Display a quality badge for a voice."
  [quality]
  (let [label (or (quality-labels quality)
                  (when (>= (or quality 0) 400) "Enhanced")
                  (when (>= (or quality 0) 300) "High Quality")
                  "Standard")
        color (cond
                (>= (or quality 0) 500) "#34C759"
                (>= (or quality 0) 400) "#007AFF"
                (>= (or quality 0) 300) "#5856D6"
                :else "#8E8E93")]
    [:> rn/View {:style {:background-color color
                         :padding-horizontal 8
                         :padding-vertical 2
                         :border-radius 4}}
     [:> rn/Text {:style {:font-size 10
                          :font-weight "600"
                          :color "#FFFFFF"}}
      label]]))

(defn- voice-item
  "A single voice item in the list with preview button."
  [{:keys [voice selected? on-select previewing?]}]
  (let [{:keys [id name language quality]} voice
        display-name (or name id)]
    [:> rn/View
     {:style {:flex-direction "row"
              :align-items "center"
              :padding-vertical 12
              :padding-horizontal 16
              :background-color (if selected? "#F2F2F7" "#FFFFFF")
              :border-bottom-width 1
              :border-bottom-color "#F0F0F0"}}
     ;; Preview button
     [:> rn/TouchableOpacity
      {:style {:padding 8
               :margin-right 8}
       :on-press #(if previewing?
                    (rf/dispatch [:voice/stop-preview])
                    (rf/dispatch [:voice/preview id]))}
      [:> rn/Text {:style {:font-size 20
                           :color (if previewing? "#FF3B30" "#007AFF")}}
       (if previewing? "⏹" "▶️")]]
     ;; Main content - tappable to select
     [:> rn/TouchableOpacity
      {:style {:flex 1}
       :on-press #(on-select id)}
      [:> rn/View {:style {:flex-direction "row"
                           :align-items "center"}}
       [:> rn/Text {:style {:font-size 16
                            :font-weight (if selected? "600" "400")
                            :color "#000000"}}
        display-name]
       (when quality
         [:> rn/View {:style {:margin-left 8}}
          [quality-badge quality]])]
      [:> rn/Text {:style {:font-size 12
                           :color "#8E8E93"
                           :margin-top 2}}
       language]]
     (when selected?
       [:> rn/Text {:style {:font-size 20 :color "#007AFF"}} "✓"])]))

(defn- system-default-item
  "The system default option."
  [{:keys [selected? on-select]}]
  [:> rn/TouchableOpacity
   {:style {:flex-direction "row"
            :align-items "center"
            :padding-vertical 12
            :padding-horizontal 16
            :background-color (if selected? "#F2F2F7" "#FFFFFF")
            :border-bottom-width 1
            :border-bottom-color "#F0F0F0"}
    :on-press #(on-select nil)}
   [:> rn/View {:style {:flex 1}}
    [:> rn/Text {:style {:font-size 16
                         :font-weight (if selected? "600" "400")
                         :color "#000000"}}
     "System Default"]
    [:> rn/Text {:style {:font-size 12
                         :color "#8E8E93"
                         :margin-top 2}}
     "Uses device's default voice"]]
   (when selected?
     [:> rn/Text {:style {:font-size 20 :color "#007AFF"}} "✓"])])

(defn- all-premium-voices-item
  "The 'All Premium Voices' rotation option.
   When selected, rotates through premium voices based on working directory."
  [{:keys [selected? on-select premium-count]}]
  [:> rn/TouchableOpacity
   {:style {:flex-direction "row"
            :align-items "center"
            :padding-vertical 12
            :padding-horizontal 16
            :background-color (if selected? "#F2F2F7" "#FFFFFF")
            :border-bottom-width 1
            :border-bottom-color "#F0F0F0"}
    :on-press #(on-select voice/all-premium-voices-identifier)}
   [:> rn/View {:style {:flex 1}}
    [:> rn/View {:style {:flex-direction "row" :align-items "center"}}
     [:> rn/Text {:style {:font-size 16
                          :font-weight (if selected? "600" "400")
                          :color "#000000"}}
      "All Premium Voices"]
     [:> rn/View {:style {:margin-left 8
                          :background-color "#34C759"
                          :padding-horizontal 8
                          :padding-vertical 2
                          :border-radius 4}}
      [:> rn/Text {:style {:font-size 10
                           :font-weight "600"
                           :color "#FFFFFF"}}
       "Rotation"]]]
    [:> rn/Text {:style {:font-size 12
                         :color "#8E8E93"
                         :margin-top 2}}
     (str "Rotates between " premium-count " premium voices per project")]]
   (when selected?
     [:> rn/Text {:style {:font-size 20 :color "#007AFF"}} "✓"])])

(defn- loading-indicator
  "Loading spinner while fetching voices."
  []
  [:> rn/View {:style {:flex 1
                       :justify-content "center"
                       :align-items "center"
                       :padding 40}}
   [:> rn/ActivityIndicator {:size "large" :color "#007AFF"}]
   [:> rn/Text {:style {:margin-top 12
                        :font-size 14
                        :color "#8E8E93"}}
    "Loading available voices..."]])

(defn- empty-voices
  "Display when no voices are available."
  []
  [:> rn/View {:style {:flex 1
                       :justify-content "center"
                       :align-items "center"
                       :padding 40}}
   [:> rn/Text {:style {:font-size 16
                        :color "#8E8E93"
                        :text-align "center"}}
    "No English voices available.\n\nInstall voices in Settings → Accessibility → Spoken Content → Voices"]])

(defn voice-picker-modal
  "Modal for selecting a TTS voice.
   Props:
   - visible: boolean, whether modal is shown
   - on-close: callback when modal should close"
  [{:keys [visible on-close]}]
  (let [voices @(rf/subscribe [:voice/available-voices])
        loading? @(rf/subscribe [:voice/loading-voices?])
        current-voice @(rf/subscribe [:settings/voice-identifier])
        previewing-voice @(rf/subscribe [:voice/previewing-voice])
        premium-voices @(rf/subscribe [:voice/premium-voices])
        handle-select (fn [voice-id]
                        (rf/dispatch [:voice/select-voice voice-id])
                        (when on-close (on-close)))]
    ;; Load voices when modal becomes visible
    (r/create-class
     {:component-did-update
      (fn [this [_ prev-props]]
        (when (and visible (not (:visible prev-props)))
          (rf/dispatch [:voice/load-available-voices])))

      :component-did-mount
      (fn [_]
        (when visible
          (rf/dispatch [:voice/load-available-voices])))

      :reagent-render
      (fn [{:keys [visible on-close]}]
        (let [previewing-voice @(rf/subscribe [:voice/previewing-voice])
              premium-voices @(rf/subscribe [:voice/premium-voices])]
          [:> rn/Modal
           {:visible visible
            :animation-type "slide"
            :presentation-style "pageSheet"
            :on-request-close on-close}
           [:> rn/SafeAreaView {:style {:flex 1 :background-color "#FFFFFF"}}
            ;; Header
            [:> rn/View {:style {:flex-direction "row"
                                 :align-items "center"
                                 :justify-content "space-between"
                                 :padding-horizontal 16
                                 :padding-vertical 12
                                 :border-bottom-width 1
                                 :border-bottom-color "#E5E5EA"}}
             [:> rn/View {:style {:width 60}}]
             [:> rn/Text {:style {:font-size 17
                                  :font-weight "600"
                                  :color "#000000"}}
              "Select Voice"]
             [:> rn/TouchableOpacity
              {:style {:width 60 :align-items "flex-end"}
               :on-press on-close}
              [:> rn/Text {:style {:font-size 17
                                   :color "#007AFF"
                                   :font-weight "500"}}
               "Done"]]]

            ;; Content
            (cond
              loading?
              [loading-indicator]

              (empty? voices)
              [empty-voices]

              :else
              [:> rn/ScrollView {:style {:flex 1}}
               ;; System Default option
               [system-default-item {:selected? (nil? current-voice)
                                     :on-select handle-select}]
               ;; All Premium Voices option (only show if we have premium voices)
               (when (seq premium-voices)
                 [all-premium-voices-item
                  {:selected? (= current-voice voice/all-premium-voices-identifier)
                   :on-select handle-select
                   :premium-count (count premium-voices)}])
               ;; Individual voices
               (for [v voices]
                 ^{:key (:id v)}
                 [voice-item {:voice v
                              :selected? (= (:id v) current-voice)
                              :previewing? (= (:id v) previewing-voice)
                              :on-select handle-select}])])]]))})))
