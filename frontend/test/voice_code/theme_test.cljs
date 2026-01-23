(ns voice-code.theme-test
  "Tests for theme namespace - dark mode and semantic colors.
   
   NOTE: This test file only tests pure functions from the theme namespace.
   The React hooks (use-dark-mode?, use-theme-colors, use-color-scheme) require
   a React Native runtime and are tested via integration/E2E tests instead."
  (:require [cljs.test :refer [deftest testing is]]
            [voice-code.theme :as theme]))

;; =============================================================================
;; Color Palette Tests
;; =============================================================================

(deftest light-colors-completeness-test
  (testing "light colors has all required keys"
    (let [required-keys #{:background :background-secondary :background-tertiary :grouped-background
                          :text-primary :text-secondary :text-tertiary :text-placeholder
                          :separator :separator-opaque
                          :fill-primary :fill-secondary :fill-tertiary
                          :accent :destructive :success :warning :info
                          :accent-background :success-background :warning-background :destructive-background
                          :link :disabled
                          :bubble-user :bubble-user-text :bubble-assistant :bubble-assistant-text
                          :input-background :input-border :input-placeholder
                          :card-background :row-background
                          :nav-background :nav-border
                          :status-connected :status-disconnected :status-connecting
                          :shadow}]
      (doseq [k required-keys]
        (is (contains? theme/light-colors k) (str "Missing key in light-colors: " k))))))

(deftest dark-colors-completeness-test
  (testing "dark colors has all required keys"
    (let [required-keys #{:background :background-secondary :background-tertiary :grouped-background
                          :text-primary :text-secondary :text-tertiary :text-placeholder
                          :separator :separator-opaque
                          :fill-primary :fill-secondary :fill-tertiary
                          :accent :destructive :success :warning :info
                          :accent-background :success-background :warning-background :destructive-background
                          :link :disabled
                          :bubble-user :bubble-user-text :bubble-assistant :bubble-assistant-text
                          :input-background :input-border :input-placeholder
                          :card-background :row-background
                          :nav-background :nav-border
                          :status-connected :status-disconnected :status-connecting
                          :shadow}]
      (doseq [k required-keys]
        (is (contains? theme/dark-colors k) (str "Missing key in dark-colors: " k))))))

(deftest color-palettes-same-keys-test
  (testing "light and dark palettes have identical keys"
    (is (= (set (keys theme/light-colors))
           (set (keys theme/dark-colors))))))

(deftest colors-are-valid-hex-test
  (testing "all color values are valid hex or rgba format"
    (let [valid-color? (fn [color]
                         (or (re-matches #"#[0-9A-Fa-f]{6}" color)
                             (re-matches #"#[0-9A-Fa-f]{8}" color)
                             (re-matches #"rgba?\(.*\)" color)))]
      (doseq [[k v] theme/light-colors]
        (is (valid-color? v) (str "Invalid color format for light " k ": " v)))
      (doseq [[k v] theme/dark-colors]
        (is (valid-color? v) (str "Invalid color format for dark " k ": " v))))))

;; =============================================================================
;; Get Colors Tests
;; =============================================================================

(deftest get-colors-light-test
  (testing "get-colors returns light colors for 'light' scheme"
    (is (= theme/light-colors (theme/get-colors "light")))))

(deftest get-colors-dark-test
  (testing "get-colors returns dark colors for 'dark' scheme"
    (is (= theme/dark-colors (theme/get-colors "dark")))))

(deftest get-colors-nil-defaults-to-light-test
  (testing "get-colors defaults to light colors when nil"
    (is (= theme/light-colors (theme/get-colors nil)))))

(deftest get-colors-unknown-defaults-to-light-test
  (testing "get-colors defaults to light colors for unknown schemes"
    (is (= theme/light-colors (theme/get-colors "unknown")))))

;; =============================================================================
;; Navigation Theme Tests
;; =============================================================================

(deftest navigation-theme-light-test
  (testing "navigation theme for light mode has correct structure"
    (let [nav-theme (theme/navigation-theme-for-scheme false)
          colors (.-colors nav-theme)]
      (is (false? (.-dark nav-theme)))
      (is (some? (.-primary colors)))
      (is (some? (.-background colors)))
      (is (some? (.-card colors)))
      (is (some? (.-text colors)))
      (is (some? (.-border colors)))
      (is (some? (.-notification colors))))))

(deftest navigation-theme-dark-test
  (testing "navigation theme for dark mode has correct structure"
    (let [nav-theme (theme/navigation-theme-for-scheme true)
          colors (.-colors nav-theme)]
      (is (true? (.-dark nav-theme)))
      (is (some? (.-primary colors)))
      (is (some? (.-background colors)))
      (is (some? (.-card colors)))
      (is (some? (.-text colors)))
      (is (some? (.-border colors)))
      (is (some? (.-notification colors))))))

(deftest navigation-theme-fonts-test
  (testing "navigation theme has font configuration"
    (let [nav-theme (theme/navigation-theme-for-scheme false)
          fonts (.-fonts nav-theme)]
      (is (some? (.-regular fonts)))
      (is (some? (.-medium fonts)))
      (is (some? (.-bold fonts)))
      (is (some? (.-heavy fonts))))))

;; =============================================================================
;; Opacity Utility Tests
;; =============================================================================

(deftest opacity-basic-test
  (testing "opacity converts hex to rgba"
    (is (= "rgba(255,0,0,0.5)" (theme/opacity "#FF0000" 0.5)))))

(deftest opacity-with-hash-test
  (testing "opacity handles color with hash prefix"
    (is (= "rgba(0,128,255,0.75)" (theme/opacity "#0080FF" 0.75)))))

(deftest opacity-full-alpha-test
  (testing "opacity with alpha 1.0"
    (is (= "rgba(255,255,255,1)" (theme/opacity "#FFFFFF" 1)))))

(deftest opacity-zero-alpha-test
  (testing "opacity with alpha 0"
    (is (= "rgba(0,0,0,0)" (theme/opacity "#000000" 0)))))

;; =============================================================================
;; Semantic Color Consistency Tests
;; =============================================================================

(deftest light-dark-contrast-test
  (testing "light and dark themes have appropriate contrast"
    ;; Light mode: light background, dark text
    (is (= "#FFFFFF" (:background theme/light-colors)))
    (is (= "#000000" (:text-primary theme/light-colors)))
    ;; Dark mode: dark background, light text
    (is (= "#000000" (:background theme/dark-colors)))
    (is (= "#FFFFFF" (:text-primary theme/dark-colors)))))

(deftest status-colors-present-test
  (testing "status indicator colors are defined"
    (doseq [colors [theme/light-colors theme/dark-colors]]
      (is (some? (:status-connected colors)))
      (is (some? (:status-disconnected colors)))
      (is (some? (:status-connecting colors))))))

(deftest bubble-colors-contrast-test
  (testing "message bubble colors have proper text contrast"
    ;; User bubble: colored background, white text
    (is (= "#FFFFFF" (:bubble-user-text theme/light-colors)))
    (is (= "#FFFFFF" (:bubble-user-text theme/dark-colors)))
    ;; Assistant bubble in dark mode should have light text
    (is (= "#000000" (:bubble-assistant-text theme/light-colors)))
    (is (= "#FFFFFF" (:bubble-assistant-text theme/dark-colors)))))
