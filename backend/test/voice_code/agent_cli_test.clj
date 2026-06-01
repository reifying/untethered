(ns voice-code.agent-cli-test
  "Tests for pure helper functions in voice-code.agent-cli.
   Functions that call clj -X entry points (init!, start, etc.) are not tested
   here because they exercise tmux live I/O and the full JVM startup path.
   We focus on the pure helpers that are testable without a real tmux server."
  (:require [clojure.test :refer [deftest is testing]]
            [voice-code.agent-cli :as cli]
            [voice-code.replication :as repl]
            [voice-code.tmux :as tmux]))

;; ============================================================================
;; uuid-str?
;; ============================================================================

(deftest uuid-str?-test
  (testing "returns true for valid UUID string"
    (is (true? (#'cli/uuid-str? "f8e22197-1234-5678-abcd-ef0123456789"))))

  (testing "returns true for another valid UUID"
    (is (true? (#'cli/uuid-str? "00000000-0000-0000-0000-000000000000"))))

  (testing "returns false for non-UUID strings"
    (is (false? (#'cli/uuid-str? "my-agent")))
    (is (false? (#'cli/uuid-str? "not-a-uuid")))
    (is (false? (#'cli/uuid-str? "")))
    (is (false? (#'cli/uuid-str? "f8e22197-1234-5678-abcd-ef012345678"))) ; too short
    (is (false? (#'cli/uuid-str? "f8e22197-1234-5678-abcd-ef01234567890")))) ; too long

  (testing "returns false for nil"
    (is (false? (#'cli/uuid-str? nil))))

  (testing "returns false for non-string types"
    (is (false? (#'cli/uuid-str? 42)))
    (is (false? (#'cli/uuid-str? :keyword)))))

;; ============================================================================
;; resolve-uuid-from-tmux-env
;; ============================================================================

(deftest resolve-uuid-from-tmux-env-test
  (testing "returns nil when no sessions exist"
    (let [invoker (fn [& _] {:exit 0 :out "" :err ""})]
      (binding [tmux/*tmux-invoker* invoker]
        (is (nil? (#'cli/resolve-uuid-from-tmux-env "my-agent"))))))

  (testing "finds UUID by exact slug match"
    (let [uuid "aabbccdd-1111-0000-0000-000000000000"
          invoker (fn [& args]
                    (cond
                      (some #{"list-sessions"} args)
                      {:exit 0 :out "my-project\n" :err ""}
                      (some #{"show-environment"} args)
                      {:exit 0
                       :out (str "VC_SESSION_UUID_my_agent=" uuid "\n"
                                 "VC_WORKDIR_my_agent=/tmp/proj\n"
                                 "VC_PROVIDER_my_agent=claude\n")
                       :err ""}
                      :else {:exit 0 :out "" :err ""}))]
      (binding [tmux/*tmux-invoker* invoker]
        (let [result (#'cli/resolve-uuid-from-tmux-env "my-agent")]
          (is (= uuid (:uuid result)))
          (is (= "/tmp/proj" (:workdir result)))
          (is (= :claude (:provider result)))))))

  (testing "returns nil when agent name not found"
    (let [invoker (fn [& args]
                    (cond
                      (some #{"list-sessions"} args)
                      {:exit 0 :out "my-project\n" :err ""}
                      (some #{"show-environment"} args)
                      {:exit 0
                       :out "VC_SESSION_UUID_other_agent=some-uuid\n"
                       :err ""}
                      :else {:exit 0 :out "" :err ""}))]
      (binding [tmux/*tmux-invoker* invoker]
        (is (nil? (#'cli/resolve-uuid-from-tmux-env "my-agent")))))))

;; ============================================================================
;; recover-workdir-from-tmux-env
;; ============================================================================

(deftest recover-workdir-from-tmux-env-test
  (testing "returns workdir when UUID found in tmux env"
    (let [uuid "ccddaabb-0000-0000-0000-000000000000"
          invoker (fn [& args]
                    (cond
                      (some #{"list-sessions"} args)
                      {:exit 0 :out "sess\n" :err ""}
                      (some #{"show-environment"} args)
                      {:exit 0
                       :out (str "VC_SESSION_UUID_some_window=" uuid "\n"
                                 "VC_WORKDIR_some_window=/home/user/code\n")
                       :err ""}
                      :else {:exit 0 :out "" :err ""}))]
      (binding [tmux/*tmux-invoker* invoker]
        (is (= "/home/user/code"
               (#'cli/recover-workdir-from-tmux-env uuid))))))

  (testing "returns nil when UUID not found in any session"
    (let [invoker (fn [& args]
                    (cond
                      (some #{"list-sessions"} args)
                      {:exit 0 :out "sess\n" :err ""}
                      (some #{"show-environment"} args)
                      {:exit 0 :out "VC_SESSION_UUID_win=different-uuid\n" :err ""}
                      :else {:exit 0 :out "" :err ""}))]
      (binding [tmux/*tmux-invoker* invoker]
        (is (nil? (#'cli/recover-workdir-from-tmux-env "not-present-uuid")))))))

;; ============================================================================
;; recover-provider-from-tmux-env
;; ============================================================================

(deftest recover-provider-from-tmux-env-test
  (testing "returns provider keyword when UUID found in tmux env"
    (let [uuid "eeff0011-0000-0000-0000-000000000000"
          invoker (fn [& args]
                    (cond
                      (some #{"list-sessions"} args)
                      {:exit 0 :out "sess\n" :err ""}
                      (some #{"show-environment"} args)
                      {:exit 0
                       :out (str "VC_SESSION_UUID_some_window=" uuid "\n"
                                 "VC_PROVIDER_some_window=copilot\n")
                       :err ""}
                      :else {:exit 0 :out "" :err ""}))]
      (binding [tmux/*tmux-invoker* invoker]
        (is (= :copilot
               (#'cli/recover-provider-from-tmux-env uuid))))))

  (testing "returns nil when UUID not found"
    (let [invoker (fn [& args]
                    (cond
                      (some #{"list-sessions"} args)
                      {:exit 0 :out "sess\n" :err ""}
                      (some #{"show-environment"} args)
                      {:exit 0 :out "" :err ""}
                      :else {:exit 0 :out "" :err ""}))]
      (binding [tmux/*tmux-invoker* invoker]
        (is (nil? (#'cli/recover-provider-from-tmux-env "missing-uuid")))))))

;; ============================================================================
;; recover-session-name-from-tmux-env
;; ============================================================================

(deftest recover-session-name-from-tmux-env-test
  (testing "returns session name when UUID found in tmux env"
    (let [uuid "aabb1122-0000-0000-0000-000000000000"
          invoker (fn [& args]
                    (cond
                      (some #{"list-sessions"} args)
                      {:exit 0 :out "sess\n" :err ""}
                      (some #{"show-environment"} args)
                      {:exit 0
                       :out (str "VC_SESSION_UUID_my_agent=" uuid "\n"
                                 "VC_SESSION_NAME_my_agent=my-feature-work\n")
                       :err ""}
                      :else {:exit 0 :out "" :err ""}))]
      (binding [tmux/*tmux-invoker* invoker]
        (is (= "my-feature-work"
               (#'cli/recover-session-name-from-tmux-env uuid))))))

  (testing "returns nil when UUID not found"
    (let [invoker (fn [& args]
                    (cond
                      (some #{"list-sessions"} args)
                      {:exit 0 :out "sess\n" :err ""}
                      (some #{"show-environment"} args)
                      {:exit 0 :out "VC_SESSION_UUID_win=different-uuid\n" :err ""}
                      :else {:exit 0 :out "" :err ""}))]
      (binding [tmux/*tmux-invoker* invoker]
        (is (nil? (#'cli/recover-session-name-from-tmux-env "not-present"))))))

  (testing "returns nil when VC_SESSION_NAME is empty string"
    (let [uuid "ccdd3344-0000-0000-0000-000000000000"
          invoker (fn [& args]
                    (cond
                      (some #{"list-sessions"} args)
                      {:exit 0 :out "sess\n" :err ""}
                      (some #{"show-environment"} args)
                      {:exit 0
                       :out (str "VC_SESSION_UUID_win=" uuid "\n"
                                 "VC_SESSION_NAME_win=\n")
                       :err ""}
                      :else {:exit 0 :out "" :err ""}))]
      (binding [tmux/*tmux-invoker* invoker]
        (is (nil? (#'cli/recover-session-name-from-tmux-env uuid)))))))

;; ============================================================================
;; resolve-session-uuid — workdir fallback excludes ghost sessions
;; ============================================================================

(deftest resolve-session-uuid-workdir-fallback-excludes-ghost-test
  (testing "workdir fallback skips :ghost-tagged index entries"
    ;; No tmux env match forces the session-index workdir fallback. The ghost
    ;; entry is the most recently modified in the workdir, so without the
    ;; (remove :ghost) filter it would win the sort-by and resolve as the resume
    ;; target. The fix must instead pick the user's real session.
    (let [no-tmux (fn [& _] {:exit 0 :out "" :err ""})]
      (binding [tmux/*tmux-invoker* no-tmux]
        (with-redefs [repl/session-index
                      (atom {"ghost-uuid" {:session-id "ghost-uuid"
                                           :working-directory "/tmp/proj"
                                           :last-modified-ms 2000
                                           :ghost true}
                             "real-uuid" {:session-id "real-uuid"
                                          :working-directory "/tmp/proj"
                                          :last-modified-ms 1000}})]
          (is (= "real-uuid"
                 (#'cli/resolve-session-uuid "some-name" "/tmp/proj"))
              "must resolve the real session, not the more-recent ghost fork")))))

  (testing "throws when the only workdir match is a ghost session"
    ;; If every candidate in the workdir is a ghost fork, there is no legitimate
    ;; session to resume and resolution must fail rather than return a ghost id.
    (let [no-tmux (fn [& _] {:exit 0 :out "" :err ""})]
      (binding [tmux/*tmux-invoker* no-tmux]
        (with-redefs [repl/session-index
                      (atom {"ghost-uuid" {:session-id "ghost-uuid"
                                           :working-directory "/tmp/proj"
                                           :last-modified-ms 2000
                                           :ghost true}})]
          (is (thrown-with-msg? clojure.lang.ExceptionInfo
                                #"Cannot find session to resume"
                                (#'cli/resolve-session-uuid "some-name" "/tmp/proj"))))))))

;; ============================================================================
;; resume idempotency
;; ============================================================================

(deftest resume-idempotency-test
  (testing "prints 'Already running' and skips start-window! when window is live"
    ;; After init! -> scan-existing-windows!, live-windows is populated. When the
    ;; window already exists, resume should report it without creating a duplicate.
    (let [uuid "aaaabbbb-cccc-0000-0000-000000000000"
          start-window-called (atom false)
          output (java.io.StringWriter.)]
      (reset! tmux/live-windows
              {uuid {:tmux-session "my-proj"
                     :tmux-window "my-agent-aaaabb"
                     :provider :claude
                     :workdir "/tmp/proj"}})
      (with-redefs [voice-code.agent-cli/init! (fn [] nil)
                    tmux/start-window! (fn [_] (reset! start-window-called true) {})]
        (binding [*out* output]
          (cli/resume {:id uuid :workdir nil :provider nil})))
      (is (false? @start-window-called)
          "start-window! must not be called when window is already live")
      (is (clojure.string/includes? (str output) "Already running")
          "should print 'Already running' message"))))
