(ns voice-code.theme
  "Theme support for light and dark mode.
   
   Provides semantic color tokens that automatically adapt to the system
   color scheme. Mirrors iOS system colors (Color.systemBackground, etc.)
   for feature parity with the native iOS app.
   
   Usage:
     (def colors (use-theme-colors))
     [:> rn/View {:style {:background-color (:background colors)}}]
   
   Or with the hook directly:
     (let [dark? (use-dark-mode?)]
       ...)"
  (:require ["react" :as react]
            ["react-native" :refer [useColorScheme]]
            [clojure.string :as str]))

;; =============================================================================
;; Color Palettes
;; =============================================================================

(def light-colors
  "Light mode color palette matching iOS system colors."
  {;; Backgrounds
   :background "#FFFFFF" ; Color.systemBackground
   :background-secondary "#F2F2F7" ; Color.secondarySystemBackground
   :background-tertiary "#FFFFFF" ; Color.tertiarySystemBackground
   :grouped-background "#F2F2F7" ; Color.systemGroupedBackground

   ;; Text
   :text-primary "#000000" ; Color.primary (label)
   :text-secondary "#3C3C43" ; Color.secondary (60% opacity)
   :text-tertiary "#3C3C4399" ; Color.tertiary
   :text-placeholder "#C7C7CC" ; Placeholder text

   ;; Separators
   :separator "#C6C6C8" ; Color.separator
   :separator-opaque "#E5E5EA" ; Opaque separator

   ;; Fills
   :fill-primary "#78788033" ; Color.fill
   :fill-secondary "#78788028" ; Secondary fill
   :fill-tertiary "#7676801E" ; Tertiary fill

   ;; System colors (semantic)
   :accent "#007AFF" ; Color.accentColor / tintColor
   :destructive "#FF3B30" ; Color.red (destructive actions)
   :success "#34C759" ; Color.green
   :warning "#FF9500" ; Color.orange
   :info "#007AFF" ; Color.blue

   ;; Semantic background tints (for active states)
   :accent-background "#E8F4FD" ; Light blue tint for accent active states
   :success-background "#E8F8E8" ; Light green tint for success active states
   :warning-background "#FFF3CD" ; Light yellow/orange tint for warnings
   :destructive-background "#FFE5E5" ; Light red tint for destructive states

   ;; Additional semantic colors
   :link "#007AFF" ; Links
   :disabled "#C7C7CC" ; Disabled states

   ;; Message bubbles
   :bubble-user "#007AFF" ; User message background
   :bubble-user-text "#FFFFFF" ; User message text
   :bubble-assistant "#E9E9EB" ; Assistant message background
   :bubble-assistant-text "#000000" ; Assistant message text

   ;; Input
   :input-background "#FFFFFF"
   :input-border "#E5E5E5"
   :input-placeholder "#C7C7CC"

   ;; Cards/Rows
   :card-background "#FFFFFF"
   :row-background "#FFFFFF"

   ;; Navigation
   :nav-background "#F8F8F8"
   :nav-border "#E5E5E5"

   ;; Status indicators
   :status-connected "#34C759"
   :status-disconnected "#FF3B30"
   :status-connecting "#FF9500"

   ;; Shadows
   :shadow "#000000"})

(def dark-colors
  "Dark mode color palette matching iOS system dark mode colors."
  {;; Backgrounds
   :background "#000000" ; Color.systemBackground (dark)
   :background-secondary "#1C1C1E" ; Color.secondarySystemBackground (dark)
   :background-tertiary "#2C2C2E" ; Color.tertiarySystemBackground (dark)
   :grouped-background "#000000" ; Color.systemGroupedBackground (dark)

   ;; Text
   :text-primary "#FFFFFF" ; Color.primary (dark)
   :text-secondary "#EBEBF599" ; Color.secondary (dark, 60% opacity)
   :text-tertiary "#EBEBF54D" ; Color.tertiary (dark)
   :text-placeholder "#636366" ; Placeholder text (dark)

   ;; Separators
   :separator "#38383A" ; Color.separator (dark)
   :separator-opaque "#3D3D41" ; Opaque separator (dark)

   ;; Fills
   :fill-primary "#7878805C" ; Color.fill (dark)
   :fill-secondary "#78788052" ; Secondary fill (dark)
   :fill-tertiary "#7676803D" ; Tertiary fill (dark)

   ;; System colors (semantic) - same in dark mode but may have slight adjustments
   :accent "#0A84FF" ; Color.accentColor (dark)
   :destructive "#FF453A" ; Color.red (dark)
   :success "#30D158" ; Color.green (dark)
   :warning "#FF9F0A" ; Color.orange (dark)
   :info "#0A84FF" ; Color.blue (dark)

   ;; Semantic background tints (for active states - darker versions)
   :accent-background "#0A84FF1A" ; Dark blue tint for accent active states
   :success-background "#30D1581A" ; Dark green tint for success active states
   :warning-background "#FF9F0A1A" ; Dark orange tint for warnings
   :destructive-background "#FF453A1A" ; Dark red tint for destructive states

   ;; Additional semantic colors
   :link "#0A84FF" ; Links (dark)
   :disabled "#636366" ; Disabled states (dark)

   ;; Message bubbles
   :bubble-user "#0A84FF" ; User message background (dark)
   :bubble-user-text "#FFFFFF" ; User message text
   :bubble-assistant "#2C2C2E" ; Assistant message background (dark)
   :bubble-assistant-text "#FFFFFF" ; Assistant message text (dark)

   ;; Input
   :input-background "#1C1C1E"
   :input-border "#3D3D41"
   :input-placeholder "#636366"

   ;; Cards/Rows
   :card-background "#1C1C1E"
   :row-background "#1C1C1E"

   ;; Navigation
   :nav-background "#1C1C1E"
   :nav-border "#3D3D41"

   ;; Status indicators
   :status-connected "#30D158"
   :status-disconnected "#FF453A"
   :status-connecting "#FF9F0A"

   ;; Shadows (less visible in dark mode)
   :shadow "#000000"})

;; =============================================================================
;; Hooks
;; =============================================================================

(defn use-color-scheme
  "Hook to get current color scheme ('light' or 'dark').
   Returns 'light' as default if scheme is nil."
  []
  (let [scheme (useColorScheme)]
    (or scheme "light")))

(defn use-dark-mode?
  "Hook to check if dark mode is active.
   Returns true if system is in dark mode, false otherwise."
  []
  (= "dark" (use-color-scheme)))

(defn use-theme-colors
  "Hook to get the current theme colors map.
   Returns light-colors or dark-colors based on system setting."
  []
  (if (use-dark-mode?)
    dark-colors
    light-colors))

;; =============================================================================
;; Navigation Theme
;; =============================================================================

(defn navigation-theme-for-scheme
  "Create React Navigation theme object for the given color scheme.
   
   Arguments:
     dark? - boolean, true for dark mode theme
   
   Returns:
     JavaScript object suitable for NavigationContainer :theme prop"
  [dark?]
  (let [colors (if dark? dark-colors light-colors)]
    #js {:dark dark?
         :colors #js {:primary (:accent colors)
                      :background (:background colors)
                      :card (:card-background colors)
                      :text (:text-primary colors)
                      :border (:separator colors)
                      :notification (:destructive colors)}
         :fonts #js {:regular #js {:fontFamily "System" :fontWeight "400"}
                     :medium #js {:fontFamily "System" :fontWeight "500"}
                     :bold #js {:fontFamily "System" :fontWeight "700"}
                     :heavy #js {:fontFamily "System" :fontWeight "900"}}}))

;; =============================================================================
;; Utility Functions
;; =============================================================================

(defn get-colors
  "Get colors for a specific color scheme (for non-hook contexts).
   
   Arguments:
     scheme - 'light' or 'dark' (defaults to 'light' if nil)
   
   Returns:
     Color map for the specified scheme"
  [scheme]
  (if (= "dark" scheme)
    dark-colors
    light-colors))

(defn opacity
  "Add opacity to a hex color.
   
   Arguments:
     color - hex color string (e.g., '#FF0000')
     alpha - opacity value 0.0 to 1.0
   
   Returns:
     RGBA color string"
  [color alpha]
  (let [hex (if (str/starts-with? color "#")
              (subs color 1)
              color)
        r (js/parseInt (subs hex 0 2) 16)
        g (js/parseInt (subs hex 2 4) 16)
        b (js/parseInt (subs hex 4 6) 16)]
    (str "rgba(" r "," g "," b "," alpha ")")))
