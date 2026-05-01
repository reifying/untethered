(ns voice-code.cli
  "Command-line interface for voice-code utilities.
   
   Provides commands for development workflows like recipe markdown generation.
   
   Usage:
   clojure -M:main -m voice-code.cli sync <output-dir>"
  (:require [voice-code.recipes :as recipes]
            [voice-code.recipe-generator :as gen]
            [clojure.string :as str]
            [clojure.tools.logging :as log]))

(defn sync-recipes-command
  "Regenerate all recipe markdown files.
   
   Args:
   - output-dir: directory where markdown will be written
   
   Exit codes:
   - 0: success
   - 1: invalid arguments
   - 2: sync failed"
  [output-dir]
  (if (not output-dir)
    (do
      (println "Error: output-dir required")
      (println "Usage: voice-code.cli sync <output-dir>")
      (System/exit 1))
    (let [result (gen/sync-recipes recipes/all-recipes output-dir)]
      (gen/print-sync-summary result)
      (if (:success result)
        (System/exit 0)
        (System/exit 2)))))

(defn -main
  "Main CLI entry point."
  [& args]
  (let [;; Filter out -M:main and other clojure args that may be passed
        filtered-args (filter (fn [arg]
                                (and (not (str/starts-with? arg "-M"))
                                     (not (str/starts-with? arg "-m"))
                                     (not (= arg "voice-code.cli"))))
                              args)
        command (first filtered-args)]
    (case command
      "sync"
      (sync-recipes-command (second filtered-args))

      (do
        (when command
          (println "Unknown command: " command))
        (println "Available commands:")
        (println "  sync <output-dir>  - Regenerate recipe markdown files")
        (System/exit (if command 1 0))))))
