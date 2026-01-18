(ns voice-code.qr-scanner
  "QR code scanner for authentication.
   Uses react-native-vision-camera for camera access and code scanning."
  (:require [reagent.core :as r]
            [re-frame.core :as rf]
            ["react-native" :as rn]))

;; ============================================================================
;; Module Loading
;; ============================================================================

(def ^:private use-real-camera?
  "Feature flag for real camera access.
   Only true in actual React Native environment."
  (and (exists? js/navigator)
       (not= "node" (.-product js/navigator))))

(defonce ^:private vision-camera-module
  (when use-real-camera?
    (try
      (js/require "react-native-vision-camera")
      (catch :default e
        (js/console.warn "react-native-vision-camera not available:" e)
        nil))))

;; Extract components from module
(def ^:private Camera
  (when vision-camera-module
    (.-Camera vision-camera-module)))

(def ^:private useCameraDevice
  (when vision-camera-module
    (.-useCameraDevice vision-camera-module)))

(def ^:private useCameraPermission
  (when vision-camera-module
    (.-useCameraPermission vision-camera-module)))

(def ^:private useCodeScanner
  (when vision-camera-module
    (.-useCodeScanner vision-camera-module)))

;; ============================================================================
;; QR Code Parsing
;; ============================================================================

(defn parse-qr-code
  "Parse a QR code value for voice-code authentication.
   Expected format: voice-code://connect?server=<host>&port=<port>&key=<api-key>
   Returns {:server-url <string> :server-port <int> :api-key <string>} or nil."
  [value]
  (when (string? value)
    (try
      (let [url (js/URL. value)]
        (when (and (= "voice-code:" (.-protocol url))
                   (= "connect" (.-hostname url)))
          (let [params (.-searchParams url)
                server (.get params "server")
                port (.get params "port")
                key (.get params "key")]
            (when (and server port key)
              {:server-url server
               :server-port (js/parseInt port 10)
               :api-key key}))))
      (catch :default _e
        nil))))

;; ============================================================================
;; Re-frame Events
;; ============================================================================

(rf/reg-event-db
 :qr/set-scanning
 (fn [db [_ scanning?]]
   (assoc-in db [:qr :scanning?] scanning?)))

(rf/reg-event-db
 :qr/set-error
 (fn [db [_ error]]
   (assoc-in db [:qr :error] error)))

(rf/reg-event-fx
 :qr/code-scanned
 (fn [{:keys [db]} [_ qr-value]]
   (if-let [auth-data (parse-qr-code qr-value)]
     ;; Valid QR code - update settings and connect
     {:db (-> db
              (assoc-in [:qr :scanning?] false)
              (assoc-in [:settings :server-url] (:server-url auth-data))
              (assoc-in [:settings :server-port] (:server-port auth-data)))
      :dispatch-n [[:settings/save]
                   [:auth/connect (:api-key auth-data)]]}
     ;; Invalid QR code
     {:db (assoc-in db [:qr :error] "Invalid QR code. Expected voice-code authentication code.")})))

(rf/reg-event-db
 :qr/clear-error
 (fn [db _]
   (update db :qr dissoc :error)))

(rf/reg-event-db
 :qr/cancel-scan
 (fn [db _]
   (assoc-in db [:qr :scanning?] false)))

;; ============================================================================
;; Subscriptions
;; ============================================================================

(rf/reg-sub
 :qr/scanning?
 (fn [db _]
   (get-in db [:qr :scanning?] false)))

(rf/reg-sub
 :qr/error
 (fn [db _]
   (get-in db [:qr :error])))

;; ============================================================================
;; Camera Scanner Component
;; ============================================================================

(defn- scanner-camera
  "Camera component with QR code scanning.
   Uses hooks via :f> for functional component."
  []
  (let [device (useCameraDevice "back")
        permission (useCameraPermission)
        has-permission (.-hasPermission permission)
        request-permission (.-requestPermission permission)
        on-codes-scanned (fn [codes]
                           (when (and codes (> (.-length codes) 0))
                             (let [code (aget codes 0)
                                   value (.-value code)]
                               (when value
                                 (rf/dispatch [:qr/code-scanned value])))))
        code-scanner (useCodeScanner
                      #js {:codeTypes #js ["qr"]
                           :onCodeScanned on-codes-scanned})]
    (cond
      ;; Permission not yet determined
      (nil? has-permission)
      [:> rn/View {:style {:flex 1 :justify-content "center" :align-items "center"}}
       [:> rn/ActivityIndicator {:size "large" :color "#007AFF"}]]

      ;; Permission denied
      (not has-permission)
      [:> rn/View {:style {:flex 1 :justify-content "center" :align-items "center" :padding 24}}
       [:> rn/Text {:style {:font-size 18 :text-align "center" :margin-bottom 16}}
        "Camera permission is required to scan QR codes"]
       [:> rn/TouchableOpacity
        {:style {:background-color "#007AFF"
                 :padding-horizontal 24
                 :padding-vertical 12
                 :border-radius 8}
         :on-press request-permission}
        [:> rn/Text {:style {:color "#FFFFFF" :font-size 16}}
         "Grant Permission"]]]

      ;; No camera device
      (nil? device)
      [:> rn/View {:style {:flex 1 :justify-content "center" :align-items "center"}}
       [:> rn/Text {:style {:font-size 18 :color "#FF3B30"}}
        "No camera device found"]]

      ;; Camera ready
      :else
      [:> Camera
       {:style {:flex 1}
        :device device
        :isActive true
        :codeScanner code-scanner}])))

(defn- scanner-overlay
  "Overlay with scan frame and cancel button."
  []
  [:> rn/View {:style {:position "absolute"
                       :top 0
                       :left 0
                       :right 0
                       :bottom 0}}
   ;; Semi-transparent overlay with transparent center
   [:> rn/View {:style {:flex 1 :background-color "rgba(0,0,0,0.5)"}}]
   [:> rn/View {:style {:flex-direction "row"}}
    [:> rn/View {:style {:flex 1 :background-color "rgba(0,0,0,0.5)"}}]
    [:> rn/View {:style {:width 250
                         :height 250
                         :border-width 2
                         :border-color "#FFFFFF"
                         :border-radius 12}}]
    [:> rn/View {:style {:flex 1 :background-color "rgba(0,0,0,0.5)"}}]]
   [:> rn/View {:style {:flex 1 :background-color "rgba(0,0,0,0.5)"}}]

   ;; Instructions
   [:> rn/View {:style {:position "absolute"
                        :top 60
                        :left 0
                        :right 0
                        :align-items "center"}}
    [:> rn/Text {:style {:color "#FFFFFF"
                         :font-size 18
                         :font-weight "600"}}
     "Scan QR Code"]
    [:> rn/Text {:style {:color "#FFFFFF"
                         :font-size 14
                         :margin-top 8
                         :opacity 0.8}}
     "Point camera at authentication QR code"]]

   ;; Cancel button
   [:> rn/View {:style {:position "absolute"
                        :bottom 40
                        :left 0
                        :right 0
                        :align-items "center"}}
    [:> rn/TouchableOpacity
     {:style {:background-color "rgba(255,255,255,0.2)"
              :padding-horizontal 32
              :padding-vertical 14
              :border-radius 8
              :border-width 1
              :border-color "#FFFFFF"}
      :on-press #(rf/dispatch [:qr/cancel-scan])}
     [:> rn/Text {:style {:color "#FFFFFF"
                          :font-size 16
                          :font-weight "600"}}
      "Cancel"]]]])

(defn- error-banner
  "Shows error message when QR code is invalid."
  []
  (let [error @(rf/subscribe [:qr/error])]
    (when error
      [:> rn/View {:style {:position "absolute"
                           :top 120
                           :left 24
                           :right 24
                           :background-color "#FF3B30"
                           :padding 16
                           :border-radius 8}}
       [:> rn/Text {:style {:color "#FFFFFF"
                            :font-size 14
                            :text-align "center"}}
        error]
       [:> rn/TouchableOpacity
        {:style {:position "absolute"
                 :top 8
                 :right 8}
         :on-press #(rf/dispatch [:qr/clear-error])}
        [:> rn/Text {:style {:color "#FFFFFF"
                             :font-size 18}}
         "×"]]])))

(defn qr-scanner-view
  "Full-screen QR scanner view.
   Shows camera with scanning overlay when QR scanning is active."
  []
  (if (and use-real-camera? Camera)
    [:> rn/View {:style {:flex 1 :background-color "#000000"}}
     [:f> scanner-camera]
     [scanner-overlay]
     [error-banner]]
    ;; Stub for non-camera environments (tests, etc.)
    [:> rn/View {:style {:flex 1
                         :justify-content "center"
                         :align-items "center"
                         :background-color "#F5F5F5"}}
     [:> rn/Text {:style {:font-size 18 :color "#666"}}
      "Camera not available"]
     [:> rn/TouchableOpacity
      {:style {:margin-top 24
               :padding-horizontal 24
               :padding-vertical 12
               :background-color "#007AFF"
               :border-radius 8}
       :on-press #(rf/dispatch [:qr/cancel-scan])}
      [:> rn/Text {:style {:color "#FFFFFF" :font-size 16}}
       "Cancel"]]]))
