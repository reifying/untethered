(ns voice-code.document-picker
  "Document picker integration for file uploads.
   Provides cross-platform file selection using react-native-document-picker.

   Usage:
     (pick-file! {:on-success (fn [file] ...) :on-cancel (fn [] ...) :on-error (fn [err] ...)})

   The file map contains:
     :uri - File URI for reading
     :name - Original filename
     :size - File size in bytes
     :type - MIME type

   Reference: ios/VoiceCode/Views/ResourceShareView.swift"
  (:require ["react-native-document-picker" :as DocumentPicker]
            ["react-native-fs" :as RNFS]
            [re-frame.core :as rf]))

;; =============================================================================
;; File Type Constants
;; =============================================================================

(def all-types
  "All file types that can be selected."
  (when DocumentPicker
    (some-> DocumentPicker .-types .-allFiles)))

;; =============================================================================
;; Core API
;; =============================================================================

(defn pick-file!
  "Open the document picker to select a file.

   Options:
     :on-success - Called with file map {:uri :name :size :type} on selection
     :on-cancel  - Called when user cancels picker (optional)
     :on-error   - Called with error on failure (optional)
     :type       - File type filter (default: all files)
     :copy-to    - 'documentDirectory' to copy to app sandbox (optional)

   Returns nil. Results are delivered via callbacks."
  [{:keys [on-success on-cancel on-error type copy-to]}]
  (let [picker-fn (or (.-pick DocumentPicker)
                      (.-default DocumentPicker))]
    (when picker-fn
      (-> (picker-fn (clj->js (cond-> {:type (or type all-types)}
                                copy-to (assoc :copyTo copy-to))))
          (.then (fn [results]
                   ;; Results is an array (multi-select possible)
                   ;; We only support single file for now
                   (when-let [result (first (js->clj results :keywordize-keys true))]
                     (when on-success
                       (on-success {:uri (:uri result)
                                    :name (:name result)
                                    :size (:size result)
                                    :type (:type result)})))))
          (.catch (fn [err]
                    (cond
                      ;; User cancelled - not an error
                      (and DocumentPicker
                           (.-isCancel DocumentPicker)
                           ((.isCancel DocumentPicker) err))
                      (when on-cancel (on-cancel))

                      ;; Actual error
                      :else
                      (do
                        (js/console.error "Document picker error:" err)
                        (when on-error (on-error err))))))))))

(defn read-file-as-base64
  "Read a file URI and return its contents as base64.

   Arguments:
     uri - File URI from document picker
     on-success - Called with base64 string on success
     on-error - Called with error on failure"
  [uri on-success on-error]
  (when RNFS
    (-> (.readFile RNFS uri "base64")
        (.then (fn [base64]
                 (when on-success (on-success base64))))
        (.catch (fn [err]
                  (js/console.error "Failed to read file:" err)
                  (when on-error (on-error err)))))))

(defn pick-and-read-file!
  "Convenience function to pick a file and read it as base64.

   Options:
     :on-success - Called with {:name :size :type :content} where content is base64
     :on-cancel  - Called when user cancels (optional)
     :on-error   - Called with error on failure (optional)

   This is the main API for upload workflows."
  [{:keys [on-success on-cancel on-error]}]
  (pick-file!
   {:on-success
    (fn [{:keys [uri name size type]}]
      (read-file-as-base64
       uri
       (fn [base64]
         (when on-success
           (on-success {:name name
                        :size size
                        :type type
                        :content base64})))
       on-error))
    :on-cancel on-cancel
    :on-error on-error}))

;; =============================================================================
;; Re-frame Effect
;; =============================================================================

(rf/reg-fx
 :document-picker/pick-file
 (fn [{:keys [on-success on-error on-cancel]}]
   (pick-and-read-file!
    {:on-success (fn [file-data]
                   (when on-success
                     (rf/dispatch (conj on-success file-data))))
     :on-error (fn [error]
                 (when on-error
                   (rf/dispatch (conj on-error error))))
     :on-cancel (fn []
                  (when on-cancel
                    (rf/dispatch on-cancel)))})))
