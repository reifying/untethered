(ns voice-code.qr
  "QR code generation for API key display in terminal.
   
   Uses ZXing library to generate QR codes and renders them
   using Unicode block characters for terminal display."
  (:require [voice-code.auth :as auth])
  (:import [com.google.zxing BarcodeFormat]
           [com.google.zxing.qrcode QRCodeWriter]
           [com.google.zxing.common BitMatrix]))

(defn generate-qr-matrix
  "Generate QR code bit matrix for the given text.
   Size determines the width/height in modules."
  ^BitMatrix [^String text size]
  (let [writer (QRCodeWriter.)]
    (.encode writer text BarcodeFormat/QR_CODE size size)))

(defn render-qr-terminal
  "Render QR code to terminal using Unicode block characters.
   
   Uses half-block characters to fit 2 vertical pixels per character:
   - Full block █ (U+2588): both top and bottom are dark
   - Upper half block ▀ (U+2580): only top is dark  
   - Lower half block ▄ (U+2584): only bottom is dark
   - Space: both light
   
   Standard QR codes are black modules on white background.
   This renders dark modules as filled blocks."
  [^BitMatrix matrix]
  (let [width (.getWidth matrix)
        height (.getHeight matrix)
        sb (StringBuilder.)]
    ;; Process 2 rows at a time for half-block rendering
    (doseq [y (range 0 height 2)]
      (doseq [x (range width)]
        (let [top (.get matrix x y)
              bottom (when (< (inc y) height) (.get matrix x (inc y)))]
          (.append sb
                   (cond
                     (and top bottom) "█"
                     top "▀"
                     bottom "▄"
                     :else " "))))
      (.append sb "\n"))
    (str sb)))

(defn display-api-key
  "Display API key with optional QR code in a formatted box.
   
   Parameters:
   - show-qr?: If true, display QR code above the key text"
  [show-qr?]
  (let [key (auth/read-api-key)]
    (if-not key
      (do
        (println)
        (println "ERROR: No API key found.")
        (println "Run the backend server to generate a key automatically.")
        (println))
      (let [key-len (count key)
            ;; Box width = key length + 4 (2 spaces padding each side)
            box-width (+ key-len 4)
            horizontal-line (apply str (repeat box-width "═"))
            empty-line (str "║" (apply str (repeat box-width " ")) "║")
            title "Voice-Code API Key"
            title-padding (quot (- box-width (count title)) 2)
            title-line (str "║"
                            (apply str (repeat title-padding " "))
                            title
                            (apply str (repeat (- box-width title-padding (count title)) " "))
                            "║")]
        (println)
        (println (str "╔" horizontal-line "╗"))
        (println title-line)
        (println (str "╠" horizontal-line "╣"))
        (when show-qr?
          (let [scan-msg "Scan with iOS camera:"
                scan-padding (quot (- box-width (count scan-msg)) 2)
                scan-line (str "║"
                               (apply str (repeat scan-padding " "))
                               scan-msg
                               (apply str (repeat (- box-width scan-padding (count scan-msg)) " "))
                               "║")]
            (println scan-line)
            (println empty-line)
            ;; Generate and display QR code
            (let [matrix (generate-qr-matrix key 25)
                  qr-lines (clojure.string/split-lines (render-qr-terminal matrix))
                  qr-width (count (first qr-lines))]
              ;; Center QR code in the box
              (doseq [line qr-lines]
                (let [line-padding (quot (- box-width qr-width) 2)]
                  (println (str "║"
                                (apply str (repeat line-padding " "))
                                line
                                (apply str (repeat (- box-width line-padding (count line)) " "))
                                "║")))))
            (println empty-line)))
        (println (str "║  " key "  ║"))
        (println (str "╚" horizontal-line "╝"))
        (println)))))

(defn -main
  "Entry point for displaying API key.
   Usage: clojure -M -m voice-code.qr [--qr]"
  [& args]
  (let [show-qr? (some #(= "--qr" %) args)]
    (display-api-key show-qr?)))
