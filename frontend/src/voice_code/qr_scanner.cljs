(ns voice-code.qr-scanner
  "QR code scanner for authentication.
   Uses react-native-vision-camera for camera access and code scanning."
  (:require [reagent.core :as r]
            [re-frame.core :as rf]
            ["react-native" :as rn]
            [voice-code.haptic :as haptic]
            [voice-code.utils :refer [parse-qr-code]]
            [voice-code.views.touchable :refer [touchable]]))

;; ============================================================================
;; Module Loading
;; ============================================================================

(def ^:private use-real-camera?
  "Feature flag for real camera access.
   Only true in actual React Native environment.
   In Node.js, navigator.product is undefined (not 'node'), so we check for
   a truthy product value that isn't 'node' - this ensures stub mode in tests."
  (and (exists? js/navigator)
       (some? (.-product js/navigator))
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
;; Re-frame Events
;; ============================================================================
;; Note: parse-qr-code is imported from voice-code.utils

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
   (if-let [api-key (parse-qr-code qr-value)]
     ;; Valid QR code - stop scanning, navigate back, and connect with the API key
     ;; Server URL and port are already configured in settings
     ;; Haptic feedback matches iOS QRScannerView.swift:386-387
     ;; Navigate back immediately like iOS dismisses the sheet on success
     (do
       (haptic/success!)
       {:db (assoc-in db [:qr :scanning?] false)
        :dispatch [:auth/connect api-key]
        :nav/go-back true})
     ;; Invalid QR code - error haptic matches iOS QRScannerView.swift:394-396
     (do
       (haptic/error!)
       {:db (assoc-in db [:qr :error] "Invalid QR code. Expected API key starting with 'untethered-'.")}))))

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

(defn- open-settings!
  "Open app settings so user can enable camera permission."
  []
  (let [Linking (.-Linking rn)]
    (.openSettings Linking)))

;; Track permission request state globally since the scanner hook resets on unmount
(defonce ^:private permission-requested? (r/atom false))

;; Track camera ready state for overlay visibility
;; Overlay should only show when camera is active (has permission + device available)
(defonce ^:private camera-ready? (r/atom false))

(defn- scanner-camera
  "Camera component with QR code scanning.
   Uses hooks via :f> for functional component."
  []
  (let [device (useCameraDevice "back")
        ^js permission (useCameraPermission)
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
                           :onCodeScanned on-codes-scanned})
        ;; Camera is ready when we have permission and a device
        is-camera-ready (and has-permission device)]
    ;; Update shared state for overlay visibility
    (reset! camera-ready? is-camera-ready)
    (cond
      ;; Permission not yet determined (loading)
      (nil? has-permission)
      [:> rn/View {:style {:flex 1 :justify-content "center" :align-items "center"}}
       [:> rn/ActivityIndicator {:size "large" :color "#007AFF"}]]

      ;; Permission denied
      (not has-permission)
      [:> rn/View {:style {:flex 1 :justify-content "center" :align-items "center" :padding 24}}
       [:> rn/Text {:style {:font-size 18 :text-align "center" :margin-bottom 16 :color "#FFFFFF"}}
        "Camera permission is required to scan QR codes"]
       ;; Show "Grant Permission" button first time, then "Open Settings" if already requested
       (if @permission-requested?
         ;; User already tried granting - permission was denied, need to go to Settings
         [:> rn/View {:style {:align-items "center"}}
          [:> rn/Text {:style {:font-size 14 :text-align "center" :color "#AAAAAA" :margin-bottom 16}}
           "Camera access was denied. Please enable it in Settings."]
          [touchable
           {:style {:background-color "#007AFF"
                    :padding-horizontal 24
                    :padding-vertical 12
                    :border-radius 8}
            :on-press open-settings!}
           [:> rn/Text {:style {:color "#FFFFFF" :font-size 16}}
            "Open Settings"]]]
         ;; First attempt - request permission
         [touchable
          {:style {:background-color "#007AFF"
                   :padding-horizontal 24
                   :padding-vertical 12
                   :border-radius 8}
           :on-press (fn []
                       (reset! permission-requested? true)
                       (request-permission))}
          [:> rn/Text {:style {:color "#FFFFFF" :font-size 16}}
           "Grant Permission"]])]

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

(defn- scanner-overlay-with-nav
  "Overlay with scan frame and cancel button.
   go-back is a callback function that handles navigation back."
  [{:keys [go-back]}]
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
    [touchable
     {:style {:background-color "rgba(255,255,255,0.2)"
              :padding-horizontal 32
              :padding-vertical 14
              :border-radius 8
              :border-width 1
              :border-color "#FFFFFF"}
      :on-press go-back}
     [:> rn/Text {:style {:color "#FFFFFF"
                          :font-size 16
                          :font-weight "600"}}
      "Cancel"]]]])

(defn- scanner-overlay
  "Overlay with scan frame and cancel button.
   This version dispatches :qr/cancel-scan event only."
  []
  [scanner-overlay-with-nav {:go-back #(rf/dispatch [:qr/cancel-scan])}])

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
       [touchable
        {:style {:position "absolute"
                 :top 8
                 :right 8}
         :on-press #(rf/dispatch [:qr/clear-error])}
        [:> rn/Text {:style {:color "#FFFFFF"
                             :font-size 18}}
         "×"]]])))

(defn qr-scanner-view
  "Full-screen QR scanner view as a navigation screen.
   Shows camera with scanning overlay when QR scanning is active.
   Overlay only renders when camera has permission and device is available,
   preventing overlay from blocking permission request UI.

   When used as a navigation screen (with props from React Navigation),
   the cancel button will navigate back. Success is handled by the
   :qr/code-scanned event which calls :auth/connect."
  [^js props]
  ;; Reset camera-ready? on mount to prevent stale state from a previous scanner session
  ;; from showing the overlay for one frame before scanner-camera updates the atom.
  ;; This fixes un-6l6: overlay must not render until camera permission is confirmed.
  (reset! camera-ready? false)
  (let [navigation (when props (.-navigation props))
        go-back! (fn []
                   (when (and navigation (.canGoBack navigation))
                     (.goBack navigation)))]
    (if (and use-real-camera? Camera)
      [:> rn/View {:style {:flex 1 :background-color "#000000"}}
       [:f> scanner-camera]
       ;; Only show overlay when camera is ready (has permission + device)
       ;; This prevents the overlay from blocking the "Grant Permission" button
       (when @camera-ready?
         [scanner-overlay-with-nav {:go-back go-back!}])
       [error-banner]]
      ;; Stub for non-camera environments (tests, etc.)
      [:> rn/View {:style {:flex 1
                           :justify-content "center"
                           :align-items "center"
                           :background-color "#F5F5F5"}}
       [:> rn/Text {:style {:font-size 18 :color "#666"}}
        "Camera not available"]
       [touchable
        {:style {:margin-top 24
                 :padding-horizontal 24
                 :padding-vertical 12
                 :background-color "#007AFF"
                 :border-radius 8}
         :on-press go-back!}
        [:> rn/Text {:style {:color "#FFFFFF" :font-size 16}}
         "Cancel"]]])))
