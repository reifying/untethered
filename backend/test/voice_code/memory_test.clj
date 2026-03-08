(ns voice-code.memory-test
  "Tests for user memory module."
  (:require [clojure.test :refer :all]
            [voice-code.memory :as memory]
            [clojure.java.io :as io]))

(defn- with-temp-memory [f]
  (let [tmp-dir (str (System/getProperty "java.io.tmpdir")
                     "/memory-test-" (System/nanoTime))]
    (.mkdirs (io/file tmp-dir))
    (try
      (binding [memory/*memory-dir* tmp-dir]
        (f))
      (finally
        (doseq [file (.listFiles (io/file tmp-dir))]
          (.delete file))
        (.delete (io/file tmp-dir))))))

(use-fixtures :each with-temp-memory)

(deftest test-load-memory-default
  (testing "Returns default structure when no file exists"
    (let [mem (memory/load-memory)]
      (is (= {} (:preferences mem)))
      (is (= {} (:context mem)))
      (is (nil? (:updated-at mem))))))

(deftest test-save-and-load-roundtrip
  (testing "Save and load preserves data"
    (let [mem {:preferences {:voice "Samantha" :tts-speed 0.5}
               :context {:dog-name "Leo"
                         :notes ["note 1" "note 2"]}}
          saved (memory/save-memory! mem)]
      (is (some? (:updated-at saved)))
      (let [loaded (memory/load-memory)]
        (is (= "Samantha" (get-in loaded [:preferences :voice])))
        (is (= 0.5 (get-in loaded [:preferences :tts-speed])))
        (is (= "Leo" (get-in loaded [:context :dog-name])))
        (is (= ["note 1" "note 2"] (get-in loaded [:context :notes])))))))

(deftest test-parse-path
  (testing "Parses dot-separated paths"
    (is (= [:context :notes] (memory/parse-path "context.notes")))
    (is (= [:preferences :voice] (memory/parse-path "preferences.voice")))
    (is (= [:single] (memory/parse-path "single")))))

(deftest test-update-memory
  (testing "Updates memory at a top-level path"
    (memory/update-memory! "preferences" {:voice "Alex"})
    (let [loaded (memory/load-memory)]
      (is (= {:voice "Alex"} (:preferences loaded)))))

  (testing "Updates memory at a nested path"
    (memory/update-memory! "context.dog-name" "Rex")
    (let [loaded (memory/load-memory)]
      (is (= "Rex" (get-in loaded [:context :dog-name])))))

  (testing "Sets timestamps on update"
    (memory/update-memory! "preferences.test" true)
    (let [loaded (memory/load-memory)]
      (is (some? (:updated-at loaded))))))

(deftest test-remove-memory
  (testing "Removes a top-level key"
    (memory/save-memory! {:preferences {:voice "Sam"}
                          :context {:notes ["a"]}})
    (memory/remove-memory! "context")
    (let [loaded (memory/load-memory)]
      (is (= {} (:context loaded)))))

  (testing "Removes a nested key"
    (memory/save-memory! {:preferences {:voice "Sam" :speed 0.5}
                          :context {}})
    (memory/remove-memory! "preferences.speed")
    (let [loaded (memory/load-memory)]
      (is (= "Sam" (get-in loaded [:preferences :voice])))
      (is (nil? (get-in loaded [:preferences :speed]))))))

(deftest test-format-memory
  (testing "Formats memory for system prompt"
    (let [mem {:preferences {:tts-speed 0.5 :voice "Samantha"}
               :context {:dog-name "Leo"
                         :notes ["Use summaries" "Mono = backend work"]}}
          formatted (memory/format-memory mem)]
      (is (string? formatted))
      (is (.contains formatted "User Preferences"))
      (is (.contains formatted "voice: Samantha"))
      (is (.contains formatted "tts-speed: 0.5"))
      (is (.contains formatted "User Context"))
      (is (.contains formatted "dog-name: Leo"))
      (is (.contains formatted "Use summaries"))
      (is (.contains formatted "Mono = backend work"))))

  (testing "Handles empty memory gracefully"
    (let [formatted (memory/format-memory {:preferences {} :context {}})]
      (is (= "" formatted)))))
