(ns voice-code.registry-test
  "Tests for the session registry."
  (:require [clojure.test :refer :all]
            [voice-code.registry :as registry]
            [clojure.java.io :as io]
            [clojure.edn :as edn])
  (:import [java.time Instant]
           [java.time.temporal ChronoUnit]))

(defn- with-temp-registry [f]
  (let [tmp-dir (str (System/getProperty "java.io.tmpdir")
                     "/registry-test-" (System/nanoTime))]
    (.mkdirs (io/file tmp-dir))
    (try
      (binding [registry/*registry-dir* tmp-dir]
        (registry/reset-registry!)
        (f))
      (finally
        ;; Cleanup
        (doseq [file (.listFiles (io/file tmp-dir))]
          (.delete file))
        (.delete (io/file tmp-dir))))))

(use-fixtures :each with-temp-registry)

(deftest test-create-and-get-session
  (testing "Creates a session with defaults and retrieves it"
    (let [entry (registry/create-session-entry "session-1"
                  {:name "test session"
                   :working-directory "/tmp/project"})]
      (is (= "session-1" (:claude-session-id entry)))
      (is (= "test session" (:name entry)))
      (is (= :ongoing (:lifecycle entry)))
      (is (= :active (:attention entry)))
      (is (= :medium (:priority entry)))
      (is (false? (:running? entry)))
      (is (some? (:created-at entry)))

      ;; Retrieve
      (let [retrieved (registry/get-session "session-1")]
        (is (= entry retrieved)))))

  (testing "Creates session with custom fields"
    (let [entry (registry/create-session-entry "session-2"
                  {:name "brainstorm"
                   :lifecycle :brainstorm
                   :attention :active
                   :priority :high})]
      (is (= :brainstorm (:lifecycle entry)))
      (is (= :high (:priority entry))))))

(deftest test-create-session-validation
  (testing "Rejects invalid lifecycle"
    (is (thrown-with-msg? clojure.lang.ExceptionInfo
                          #"Invalid lifecycle"
                          (registry/create-session-entry "bad-1"
                            {:lifecycle :invalid}))))

  (testing "Rejects invalid attention"
    (is (thrown-with-msg? clojure.lang.ExceptionInfo
                          #"Invalid attention"
                          (registry/create-session-entry "bad-2"
                            {:attention :bogus})))))

(deftest test-update-session
  (testing "Updates existing session fields"
    (registry/create-session-entry "session-u1" {:name "original"})
    (let [updated (registry/update-session! "session-u1"
                    {:name "renamed"
                     :priority :high
                     :context-note "Left off at tests"})]
      (is (= "renamed" (:name updated)))
      (is (= :high (:priority updated)))
      (is (= "Left off at tests" (:context-note updated)))
      ;; last-interaction updated
      (is (some? (:last-interaction updated)))))

  (testing "Throws on updating nonexistent session"
    (is (thrown-with-msg? clojure.lang.ExceptionInfo
                          #"Session not found"
                          (registry/update-session! "nonexistent" {:name "x"}))))

  (testing "Rejects invalid fields on update"
    (registry/create-session-entry "session-u2" {:name "test"})
    (is (thrown-with-msg? clojure.lang.ExceptionInfo
                          #"Invalid priority"
                          (registry/update-session! "session-u2"
                            {:priority :ultra})))))

(deftest test-remove-session
  (testing "Removes a session"
    (registry/create-session-entry "session-r1" {:name "to delete"})
    (is (some? (registry/get-session "session-r1")))
    (registry/remove-session "session-r1")
    (is (nil? (registry/get-session "session-r1")))))

(deftest test-filter-sessions
  (testing "Filters by attention"
    (registry/create-session-entry "s1" {:attention :active})
    (registry/create-session-entry "s2" {:attention :waiting-for-me})
    (registry/create-session-entry "s3" {:attention :done})
    (registry/create-session-entry "s4" {:attention :active})

    (let [active (registry/filter-sessions :attention :active)]
      (is (= 2 (count active)))
      (is (every? #(= :active (:attention %)) active))))

  (testing "Filters by lifecycle"
    (registry/create-session-entry "s5" {:lifecycle :one-shot})
    (let [one-shots (registry/filter-sessions :lifecycle :one-shot)]
      (is (= 1 (count one-shots)))))

  (testing "Filters with set of values"
    (let [active-or-waiting (registry/filter-sessions
                              :attention #{:active :waiting-for-me})]
      ;; s1 (:active), s2 (:waiting-for-me), s4 (:active), s5 (default :active)
      (is (= 4 (count active-or-waiting)))))

  (testing "Filters with multiple criteria"
    (registry/create-session-entry "s6"
      {:attention :active :priority :high})
    (let [active-high (registry/filter-sessions
                        :attention :active
                        :priority :high)]
      (is (= 1 (count active-high)))
      (is (= "s6" (:claude-session-id (first active-high)))))))

(deftest test-filter-active-sessions
  (testing "Excludes archived sessions"
    (registry/create-session-entry "a1" {:attention :active})
    (registry/create-session-entry "a2" {:attention :archived})
    (registry/create-session-entry "a3" {:attention :waiting-for-me})
    (let [active (registry/filter-active-sessions)]
      (is (= 2 (count active)))
      (is (not (some #(= :archived (:attention %)) active))))))

(deftest test-persistence-roundtrip
  (testing "Data survives save and load"
    (registry/create-session-entry "p1"
      {:name "persistent session"
       :lifecycle :ongoing
       :priority :high})
    ;; Reset in-memory state and reload
    (registry/reset-registry!)
    (is (nil? (registry/get-session "p1")))
    (registry/load-registry)
    (let [loaded (registry/get-session "p1")]
      (is (some? loaded))
      (is (= "persistent session" (:name loaded)))
      (is (= :high (:priority loaded))))))

(deftest test-prune-archived
  (testing "Prunes old archived sessions"
    ;; Create a session and manually make it old + archived
    (registry/create-session-entry "old-1"
      {:attention :archived
       :last-interaction (str (.minus (Instant/now) 60 ChronoUnit/DAYS))})
    (registry/create-session-entry "new-1"
      {:attention :archived
       :last-interaction (str (Instant/now))})
    (registry/create-session-entry "active-1"
      {:attention :active})

    (let [pruned-count (registry/prune-archived! 30)]
      (is (= 1 pruned-count))
      (is (nil? (registry/get-session "old-1")))
      (is (some? (registry/get-session "new-1")))
      (is (some? (registry/get-session "active-1")))

      ;; Archive file should exist with the pruned session
      (let [archive (edn/read-string
                      (slurp (str registry/*registry-dir*
                                  "/session-registry-archive.edn")))]
        (is (contains? archive "old-1"))))))

(deftest test-all-sessions
  (testing "Returns all sessions"
    (registry/create-session-entry "all-1" {:name "first"})
    (registry/create-session-entry "all-2" {:name "second"})
    (let [all (registry/all-sessions)]
      (is (= 2 (count all)))
      (is (contains? all "all-1"))
      (is (contains? all "all-2")))))
