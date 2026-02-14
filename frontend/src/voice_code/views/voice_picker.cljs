(ns voice-code.views.voice-picker
  "Voice picker modal for selecting TTS voice.
   Displays available English voices with quality indicators."
  (:require [reagent.core :as r]
            [re-frame.core :as rf]
            ["react-native" :as rn]
            [voice-code.icons :as icons]
            [voice-code.theme :as theme]
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
  [quality colors]
  (let [label (or (quality-labels quality)
                  (when (>= (or quality 0) 400) "Enhanced")
                  (when (>= (or quality 0) 300) "High Quality")
                  "Standard")
        ;; Use semantic colors: success for premium, accent for enhanced,
        ;; info (purple-ish via accent) for high quality, secondary text for standard
        badge-color (cond
                      (>= (or quality 0) 500) (:success colors)
                      (>= (or quality 0) 400) (:accent colors)
                      (>= (or quality 0) 300) (:info colors)
                      :else (:text-secondary colors))]
    [:> rn/View {:style {:background-color badge-color
                         :padding-horizontal 8
                         :padding-vertical 2
                         :border-radius 4}}
     [:> rn/Text {:style {:font-size 10
                          :font-weight "600"
                          :color (:bubble-user-text colors)}}
      label]]))

(defn- voice-item
  "A single voice item in the list with preview button."
  [{:keys [voice selected? on-select previewing? colors]}]
  (let [{:keys [id name language quality]} voice
        display-name (or name id)]
    [:> rn/View
     {:style {:flex-direction "row"
              :align-items "center"
              :padding-vertical 12
              :padding-horizontal 16
              :background-color (if selected? (:background-secondary colors) (:background colors))
              :border-bottom-width 1
              :border-bottom-color (:separator colors)}}
     ;; Preview button
     [:> rn/TouchableOpacity
      {:style {:padding 8
               :margin-right 8}
       :on-press #(if previewing?
                    (rf/dispatch [:voice/stop-preview])
                    (rf/dispatch [:voice/preview id]))}
      [icons/icon {:name (if previewing? :stop :play)
                   :size 20
                   :color (if previewing? (:destructive colors) (:accent colors))}]]
     ;; Main content - tappable to select
     [:> rn/TouchableOpacity
      {:style {:flex 1}
       :on-press #(on-select id)}
      [:> rn/View {:style {:flex-direction "row"
                           :align-items "center"}}
       [:> rn/Text {:style {:font-size 16
                            :font-weight (if selected? "600" "400")
                            :color (:text-primary colors)}}
        display-name]
       (when quality
         [:> rn/View {:style {:margin-left 8}}
          [quality-badge quality colors]])]
      [:> rn/Text {:style {:font-size 12
                           :color (:text-secondary colors)
                           :margin-top 2}}
       language]]
     (when selected?
       [icons/icon {:name :checkmark :size 20 :color (:accent colors)}])]))

(defn- system-default-item
  "The system default option."
  [{:keys [selected? on-select colors]}]
  [:> rn/TouchableOpacity
   {:style {:flex-direction "row"
            :align-items "center"
            :padding-vertical 12
            :padding-horizontal 16
            :background-color (if selected? (:background-secondary colors) (:background colors))
            :border-bottom-width 1
            :border-bottom-color (:separator colors)}
    :on-press #(on-select nil)}
   [:> rn/View {:style {:flex 1}}
    [:> rn/Text {:style {:font-size 16
                         :font-weight (if selected? "600" "400")
                         :color (:text-primary colors)}}
     "System Default"]
    [:> rn/Text {:style {:font-size 12
                         :color (:text-secondary colors)
                         :margin-top 2}}
     "Uses device's default voice"]]
   (when selected?
     [icons/icon {:name :checkmark :size 20 :color (:accent colors)}])])

(defn- all-premium-voices-item
  "The 'All Premium Voices' rotation option.
   When selected, rotates through premium voices based on working directory."
  [{:keys [selected? on-select premium-count colors]}]
  [:> rn/TouchableOpacity
   {:style {:flex-direction "row"
            :align-items "center"
            :padding-vertical 12
            :padding-horizontal 16
            :background-color (if selected? (:background-secondary colors) (:background colors))
            :border-bottom-width 1
            :border-bottom-color (:separator colors)}
    :on-press #(on-select voice/all-premium-voices-identifier)}
   [:> rn/View {:style {:flex 1}}
    [:> rn/View {:style {:flex-direction "row" :align-items "center"}}
     [:> rn/Text {:style {:font-size 16
                          :font-weight (if selected? "600" "400")
                          :color (:text-primary colors)}}
      "All Premium Voices"]
     [:> rn/View {:style {:margin-left 8
                          :background-color (:success colors)
                          :padding-horizontal 8
                          :padding-vertical 2
                          :border-radius 4}}
      [:> rn/Text {:style {:font-size 10
                           :font-weight "600"
                           :color (:bubble-user-text colors)}}
       "Rotation"]]]
    [:> rn/Text {:style {:font-size 12
                         :color (:text-secondary colors)
                         :margin-top 2}}
     (str "Rotates between " premium-count " premium voices per project")]]
   (when selected?
     [icons/icon {:name :checkmark :size 20 :color (:accent colors)}])])

(defn- loading-indicator
  "Loading spinner while fetching voices."
  [colors]
  [:> rn/View {:style {:flex 1
                       :justify-content "center"
                       :align-items "center"
                       :padding 40}}
   [:> rn/ActivityIndicator {:size "large" :color (:accent colors)}]
   [:> rn/Text {:style {:margin-top 12
                        :font-size 14
                        :color (:text-secondary colors)}}
    "Loading available voices..."]])

(defn- empty-voices
  "Display when no voices are available."
  [colors]
  [:> rn/View {:style {:flex 1
                       :justify-content "center"
                       :align-items "center"
                       :padding 40}}
   [:> rn/Text {:style {:font-size 16
                        :color (:text-secondary colors)
                        :text-align "center"}}
    "No English voices available.\n\nInstall voices in Settings → Accessibility → Spoken Content → Voices"]])

(defn- voice-picker-content
  "Inner content of the voice picker modal.
   Uses Form-2 pattern so subscriptions and hooks work correctly."
  [{:keys [on-close]}]
  ;; Form-2: Return a render function that reads subscriptions and uses hooks
  (fn [{:keys [on-close]}]
    [:f>
     (fn []
       (let [colors (theme/use-theme-colors)
             voices @(rf/subscribe [:voice/available-voices])
          loading? @(rf/subscribe [:voice/loading-voices?])
          current-voice @(rf/subscribe [:settings/voice-identifier])
          previewing-voice @(rf/subscribe [:voice/previewing-voice])
          premium-voices @(rf/subscribe [:voice/premium-voices])
          handle-select (fn [voice-id]
                          (rf/dispatch [:voice/select-voice voice-id])
                          (when on-close (on-close)))]
      [:> rn/SafeAreaView {:style {:flex 1 :background-color (:background colors)}}
       ;; Header
       [:> rn/View {:style {:flex-direction "row"
                            :align-items "center"
                            :justify-content "space-between"
                            :padding-horizontal 16
                            :padding-vertical 12
                            :border-bottom-width 1
                            :border-bottom-color (:separator-opaque colors)}}
        [:> rn/View {:style {:width 60}}]
        [:> rn/Text {:style {:font-size 17
                             :font-weight "600"
                             :color (:text-primary colors)}}
         "Select Voice"]
        [:> rn/TouchableOpacity
         {:style {:width 60 :align-items "flex-end"}
          :on-press on-close}
         [:> rn/Text {:style {:font-size 17
                              :color (:link colors)
                              :font-weight "500"}}
          "Done"]]]

       ;; Content
       (cond
         loading?
         [loading-indicator colors]

         (empty? voices)
         [empty-voices colors]

         :else
         [:> rn/ScrollView {:style {:flex 1}}
          ;; System Default option
          [system-default-item {:selected? (nil? current-voice)
                                :on-select handle-select
                                :colors colors}]
          ;; All Premium Voices option (only show if we have premium voices)
          (when (seq premium-voices)
            [all-premium-voices-item
             {:selected? (= current-voice voice/all-premium-voices-identifier)
              :on-select handle-select
              :premium-count (count premium-voices)
              :colors colors}])
          ;; Individual voices
          (for [v voices]
            ^{:key (:id v)}
            [voice-item {:voice v
                         :selected? (= (:id v) current-voice)
                         :previewing? (= (:id v) previewing-voice)
                         :on-select handle-select
                         :colors colors}])])]))]))

(defn voice-picker-modal
  "Modal for selecting a TTS voice.
   Props:
   - visible: boolean, whether modal is shown
   - on-close: callback when modal should close

   Uses Form-3 pattern for lifecycle methods with Form-2 inner content
   for proper React hooks usage."
  [{:keys [visible on-close]}]
  ;; Load voices when modal becomes visible
  (r/create-class
   {:component-did-update
    (fn [this [_ prev-props]]
      (let [props (r/props this)]
        (when (and (:visible props) (not (:visible prev-props)))
          (rf/dispatch [:voice/load-available-voices]))))

    :component-did-mount
    (fn [this]
      (let [props (r/props this)]
        (when (:visible props)
          (rf/dispatch [:voice/load-available-voices]))))

    :reagent-render
    (fn [{:keys [visible on-close]}]
      [:> rn/Modal
       {:visible visible
        :animation-type "slide"
        :presentation-style "pageSheet"
        :on-request-close on-close}
       ;; Inner content uses Form-2 so hooks work
       [voice-picker-content {:on-close on-close}]])}))
