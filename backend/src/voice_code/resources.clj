(ns voice-code.resources
  "Resource file management for voice-code backend.
  Handles file uploads, listings, and deletions in .untethered/resources directory."
  (:require [clojure.java.io :as io]
            [clojure.string :as str]
            [clojure.tools.logging :as log])
  (:import [java.util Base64]
           [java.time Instant]))

(defn ensure-resources-directory!
  "Ensures .untethered/resources directory exists in working directory.
  Creates parent directories if needed."
  [working-directory]
  (let [resources-dir (io/file working-directory ".untethered" "resources")]
    (.mkdirs resources-dir)
    resources-dir))

(defn split-filename
  "Splits filename into [name extension].
  Returns [name nil] if no extension found."
  [filename]
  (let [last-dot (.lastIndexOf filename ".")]
    (if (and (pos? last-dot) (> (.length filename) (inc last-dot)))
      [(.substring filename 0 last-dot)
       (.substring filename (inc last-dot))]
      [filename nil])))

(defn handle-filename-conflict
  "Returns unique filename by appending timestamp if file already exists.
  Format: name-YYYYMMDDHHmmss.ext"
  [working-directory filename]
  (let [target-file (io/file working-directory ".untethered" "resources" filename)]
    (if (.exists target-file)
      (let [timestamp (-> (Instant/now)
                         (.toString)
                         (str/replace #"[:\-.TZ]" "")  ; Remove ISO-8601 separators including T and Z
                         (subs 0 14))  ; YYYYMMDDHHmmss
            [name ext] (split-filename filename)]
        (str name "-" timestamp (when ext (str "." ext))))
      filename)))

(defn upload-file!
  "Writes base64-encoded file to resources directory.
  Returns map with :filename, :path, :size, and :timestamp.
  Handles filename conflicts by appending timestamp."
  [working-directory filename base64-content]
  (try
    (let [resources-dir (ensure-resources-directory! working-directory)
          unique-filename (handle-filename-conflict working-directory filename)
          target-file (io/file resources-dir unique-filename)
          decoded-bytes (.decode (Base64/getDecoder) base64-content)]

      (log/info "Uploading file"
                {:working-directory working-directory
                 :original-filename filename
                 :final-filename unique-filename
                 :size (count decoded-bytes)})

      (with-open [out (io/output-stream target-file)]
        (.write out decoded-bytes))

      {:filename unique-filename
       :path (str ".untethered/resources/" unique-filename)
       :size (.length target-file)
       :timestamp (Instant/now)})
    (catch IllegalArgumentException e
      (log/error "Invalid base64 content" {:filename filename :error (.getMessage e)})
      (throw e))
    (catch Exception e
      (log/error "Failed to upload file"
                 {:filename filename
                  :working-directory working-directory
                  :error (.getMessage e)})
      (throw (ex-info "Failed to upload file"
                     {:filename filename
                      :error (.getMessage e)}
                     e)))))

(defn list-resources
  "Lists all files in resources directory with metadata.
  Returns vector of maps with :filename, :path, :size, :timestamp.
  Sorted by timestamp descending (most recent first).
  Returns empty vector if directory doesn't exist."
  [working-directory]
  (let [resources-dir (io/file working-directory ".untethered" "resources")]
    (if (.exists resources-dir)
      (let [files (filter #(.isFile %) (.listFiles resources-dir))]
        (log/debug "Listing resources"
                   {:working-directory working-directory
                    :count (count files)})
        (->> files
             (map (fn [f]
                    {:filename (.getName f)
                     :path (str ".untethered/resources/" (.getName f))
                     :size (.length f)
                     :timestamp (Instant/ofEpochMilli (.lastModified f))}))
             (sort-by :timestamp #(compare %2 %1))  ; Most recent first
             vec))
      (do
        (log/debug "Resources directory does not exist" {:working-directory working-directory})
        []))))

(defn delete-resource!
  "Deletes a resource file from backend storage.
  Returns map with :deleted true and :path.
  Throws ex-info if file doesn't exist."
  [working-directory filename]
  (let [target-file (io/file working-directory ".untethered" "resources" filename)
        absolute-path (.getAbsolutePath target-file)]
    (if (.exists target-file)
      (do
        (log/info "Deleting resource"
                  {:working-directory working-directory
                   :filename filename
                   :path absolute-path})
        (.delete target-file)
        {:deleted true
         :path absolute-path})
      (do
        (log/warn "Attempted to delete non-existent resource"
                  {:working-directory working-directory
                   :filename filename})
        (throw (ex-info "Resource not found"
                       {:filename filename
                        :working-directory working-directory}))))))
