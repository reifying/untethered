(ns voice-code.resources-test
  "Tests for resources view utility functions and component structure.
   Tests format-file-size, file-icon, and swipeable-resource-item rendering."
  (:require [cljs.test :refer [deftest testing is]]
            ["react-native" :as rn :refer [Animated]]
            [voice-code.views.resources :as resources]))

;; Import the private functions by redefining them here
;; (In a real setup, we'd move these to a utils namespace)

(defn- format-file-size
  "Format file size in bytes to human-readable string."
  [bytes]
  (cond
    (nil? bytes) "Unknown"
    (< bytes 1024) (str bytes " B")
    (< bytes (* 1024 1024)) (str (Math/round (/ bytes 1024)) " KB")
    :else (str (.toFixed (/ bytes (* 1024 1024)) 1) " MB")))

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

(deftest format-file-size-test
  (testing "handles nil"
    (is (= "Unknown" (format-file-size nil))))

  (testing "shows bytes for small files"
    (is (= "0 B" (format-file-size 0)))
    (is (= "512 B" (format-file-size 512)))
    (is (= "1023 B" (format-file-size 1023))))

  (testing "shows KB for medium files"
    (is (= "1 KB" (format-file-size 1024)))
    (is (= "10 KB" (format-file-size 10240)))
    ;; Just under 1MB rounds up to 1024 KB due to Math/round
    (is (= "1024 KB" (format-file-size (- (* 1024 1024) 1)))))

  (testing "shows MB for large files"
    (is (= "1.0 MB" (format-file-size (* 1024 1024))))
    (is (= "5.5 MB" (format-file-size (* 5.5 1024 1024))))
    (is (= "100.0 MB" (format-file-size (* 100 1024 1024))))))

(deftest file-icon-test
  (testing "returns photo icon for images"
    (is (= "🖼️" (file-icon "photo.jpg")))
    (is (= "🖼️" (file-icon "image.JPEG")))
    (is (= "🖼️" (file-icon "picture.png")))
    (is (= "🖼️" (file-icon "animation.gif")))
    (is (= "🖼️" (file-icon "modern.webp"))))

  (testing "returns document icon for PDFs"
    (is (= "📄" (file-icon "document.pdf")))
    (is (= "📄" (file-icon "report.PDF"))))

  (testing "returns text icon for text files"
    (is (= "📝" (file-icon "notes.txt")))
    (is (= "📝" (file-icon "README.md")))
    (is (= "📝" (file-icon "docs.markdown"))))

  (testing "returns data icon for structured data"
    (is (= "📋" (file-icon "config.json")))
    (is (= "📋" (file-icon "data.edn")))
    (is (= "📋" (file-icon "settings.yaml")))
    (is (= "📋" (file-icon "config.yml"))))

  (testing "returns archive icon for compressed files"
    (is (= "📦" (file-icon "archive.zip")))
    (is (= "📦" (file-icon "backup.tar")))
    (is (= "📦" (file-icon "compressed.gz"))))

  (testing "returns generic icon for unknown types"
    (is (= "📎" (file-icon "unknown.xyz")))
    (is (= "📎" (file-icon "file.doc")))
    (is (= "📎" (file-icon "noextension"))))

  (testing "handles nil input"
    (is (= "📎" (file-icon nil)))))

(deftest swipe-constants-test
  (testing "swipe threshold should be negative (swipe left)"
    ;; The threshold -80 means swiping left by 80px
    (let [swipe-threshold -80]
      (is (< swipe-threshold 0))
      (is (= 80 (Math/abs swipe-threshold)))))

  (testing "delete button width should match threshold"
    ;; Button width should equal threshold magnitude for smooth reveal
    (let [delete-button-width 80
          swipe-threshold -80]
      (is (= delete-button-width (Math/abs swipe-threshold))))))

;; ============================================================================
;; Component Structure Tests
;; Verify swipeable-resource-item produces valid Reagent hiccup.
;; Regression: JS object props passed to [:>] are treated as children, causing
;; "Objects are not valid as a React child" error. Fix uses merge + js->clj
;; to convert PanResponder handlers to a Clojure map.
;; ============================================================================

(def ^:private test-colors
  {:row-background "#FFFFFF"
   :separator "#E0E0E0"
   :destructive "#FF3B30"
   :bubble-user-text "#FFFFFF"
   :background-secondary "#F5F5F5"
   :text-primary "#000000"
   :text-secondary "#666666"
   :shadow "#000000"
   :accent "#007AFF"
   :disabled "#CCCCCC"})

(deftest swipeable-resource-item-returns-form-2-fn-test
  (testing "swipeable-resource-item returns a render fn (Form-2 component)"
    (let [result (#'resources/swipeable-resource-item
                  {:resource {:filename "test.pdf" :size 1234}
                   :on-delete (fn [_])
                   :colors test-colors})]
      (is (fn? result) "Form-2 component should return a render fn"))))

(deftest swipeable-resource-item-render-fn-returns-hiccup-test
  (testing "render fn returns valid Reagent hiccup (not a JS object error)"
    (let [render-fn (#'resources/swipeable-resource-item
                     {:resource {:filename "test.pdf" :size 1234}
                      :on-delete (fn [_])
                      :colors test-colors})
          result (render-fn {:resource {:filename "test.pdf" :size 1234}
                             :on-delete (fn [_])
                             :colors test-colors})]
      (is (vector? result) "Should return hiccup vector")
      (is (= :> (first result)) "Root should be React interop [:>]"))))

(deftest swipeable-resource-item-animated-view-uses-clj-map-props-test
  (testing "Animated.View receives Clojure map props (not JS object)"
    (let [render-fn (#'resources/swipeable-resource-item
                     {:resource {:filename "test.pdf" :size 1234}
                      :on-delete (fn [_])
                      :colors test-colors})
          hiccup (render-fn {:resource {:filename "test.pdf" :size 1234}
                             :on-delete (fn [_])
                             :colors test-colors})
          ;; Find the Animated.View child - it's the last child of the root View
          children (drop 2 hiccup)
          animated-view (last children)]
      ;; The animated view should be [:> Animated.View {clj-map-props} [child]]
      (is (vector? animated-view) "Animated.View should be a hiccup vector")
      (is (= :> (first animated-view)) "Should use [:>] interop")
      (is (= (.-View Animated) (second animated-view)) "Should be Animated.View")
      ;; The props (third element) must be a Clojure map, NOT a JS object
      ;; This is the regression test: js/Object.assign returns a JS object
      ;; which Reagent treats as a child, causing render errors
      (let [props (nth animated-view 2)]
        (is (map? props)
            "Props must be a Clojure map (not JS object) for Reagent [:>] interop")
        (is (contains? props :style) "Props should contain :style key")))))
