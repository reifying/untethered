(ns voice-code.tmux-test
  "Unit tests for pure helpers in voice-code.tmux.
   No tmux server required — all tested functions are pure or use rebindable state."
  (:require [clojure.test :refer [deftest is testing]]
            [voice-code.tmux :as tmux]))

;; ============================================================================
;; sanitize-session-name
;; ============================================================================

(deftest sanitize-session-name-test
  (testing "basename of an absolute path"
    (is (= "voice-code-tmux-untethered"
           (tmux/sanitize-session-name "/Users/x/code/voice-code-tmux-untethered"))))

  (testing "trailing slash stripped before basename extraction"
    (is (= "voice-code-tmux-untethered"
           (tmux/sanitize-session-name "/Users/x/code/voice-code-tmux-untethered/"))))

  (testing "spaces and punctuation are collapsed to dashes"
    (is (= "my-project"
           (tmux/sanitize-session-name "/tmp/My Project"))))

  (testing "colons and dots replaced with dashes"
    (is (= "my-project"
           (tmux/sanitize-session-name "/tmp/my.project")))
    (is (= "my-project"
           (tmux/sanitize-session-name "/tmp/my:project"))))

  (testing "non-alphanumeric characters (other than spaces/colons/dots) stripped without dash"
    (is (= "helloworld"
           (tmux/sanitize-session-name "/tmp/hello!@#$%world"))))

  (testing "consecutive dashes collapsed"
    (is (= "foo-bar"
           (tmux/sanitize-session-name "/tmp/foo---bar"))))

  (testing "leading and trailing dashes stripped"
    (is (= "foo"
           (tmux/sanitize-session-name "/tmp/-foo-"))))

  (testing "blank slug falls back to 'session'"
    (is (= "session" (tmux/sanitize-session-name "/...")))
    (is (= "session" (tmux/sanitize-session-name "/!!!")))
    (is (= "session" (tmux/sanitize-session-name "/"))))

  (testing "uppercase letters are lowercased"
    (is (= "myproject"
           (tmux/sanitize-session-name "/tmp/MyProject"))))

  (testing "nil input returns 'session' fallback"
    (is (= "session" (tmux/sanitize-session-name nil)))))

;; ============================================================================
;; window-name
;; ============================================================================

(deftest window-name-test
  (testing "includes 6-character UUID prefix as suffix"
    (let [uuid "f8e22197-1234-5678-abcd-ef0123456789"
          name (tmux/window-name "Refactor auth middleware" uuid)]
      (is (clojure.string/ends-with? name "-f8e221"))
      (is (= "refactor-auth-middleware-f8e221" name))))

  (testing "nil session name uses 'session' fallback"
    (let [uuid "f8e22197-1234-5678-abcd-ef0123456789"
          name (tmux/window-name nil uuid)]
      (is (= "session-f8e221" name))))

  (testing "slug capped at 30 chars before UUID suffix"
    (let [uuid "abcdef12-0000-0000-0000-000000000000"
          long-name (apply str (repeat 50 "x"))
          name (tmux/window-name long-name uuid)]
      (is (= "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxx-abcdef" name))
      (is (= 37 (count name)))))

  (testing "non-alphanumeric chars in name become dashes"
    (let [uuid "abc12300-0000-0000-0000-000000000000"
          name (tmux/window-name "Hello World! Foo" uuid)]
      (is (= "hello-world-foo-abc123" name))))

  (testing "blank session name after slugification falls back to 'session'"
    (let [uuid "aabbcc00-0000-0000-0000-000000000000"
          name (tmux/window-name "!!!---!!!" uuid)]
      (is (= "session-aabbcc" name)))))

;; ============================================================================
;; env-suffix
;; ============================================================================

(deftest env-suffix-test
  (testing "dashes converted to underscores"
    (is (= "refactor_auth_middleware_f8e221"
           (tmux/env-suffix "refactor-auth-middleware-f8e221"))))

  (testing "single dash converted"
    (is (= "session_abc123"
           (tmux/env-suffix "session-abc123"))))

  (testing "string with no dashes passes through unchanged"
    (is (= "abc123"
           (tmux/env-suffix "abc123")))))

;; ============================================================================
;; readiness-predicate
;; ============================================================================

(deftest readiness-predicate-test
  (testing "claude ready after 'bypass permissions' appears"
    (let [ready? (tmux/readiness-predicate :claude)]
      (is (true? (ready? "> prompt\n? for shortcuts · bypass permissions")))
      (is (false? (ready? "starting up...")))
      (is (false? (ready? "")))))

  (testing "copilot ready after 'Type @ to mention' appears"
    (let [ready? (tmux/readiness-predicate :copilot)]
      (is (true? (ready? "Welcome to Copilot CLI\nType @ to mention a file")))
      (is (false? (ready? "Loading...")))))

  (testing "cursor ready after 'Press any key' appears"
    (let [ready? (tmux/readiness-predicate :cursor)]
      (is (true? (ready? "Cursor Agent\nPress any key to continue")))
      (is (false? (ready? "Initializing")))))

  (testing "opencode ready after 'Ask anything' appears"
    (let [ready? (tmux/readiness-predicate :opencode)]
      (is (true? (ready? "OpenCode AI\nAsk anything about your code")))
      (is (false? (ready? "Loading model..."))))))

;; ============================================================================
;; build-provider-command
;; ============================================================================

(deftest build-provider-command-test
  (testing "claude new session includes --session-id, not --resume"
    (with-redefs [voice-code.providers/cli-path (constantly "/usr/local/bin/claude")]
      (let [cmd (tmux/build-provider-command :claude {:session-uuid "abc123" :resume? false})]
        (is (clojure.string/includes? cmd "--session-id abc123"))
        (is (not (clojure.string/includes? cmd "--resume")))
        (is (clojure.string/includes? cmd "--dangerously-skip-permissions"))
        (is (clojure.string/includes? cmd "unset CLAUDECODE CLAUDE_CODE_ENTRYPOINT"))
        (is (not (clojure.string/includes? cmd "--print"))))))

  (testing "claude resume session includes --resume, not --session-id"
    (with-redefs [voice-code.providers/cli-path (constantly "/usr/local/bin/claude")]
      (let [cmd (tmux/build-provider-command :claude {:session-uuid "abc123" :resume? true})]
        (is (clojure.string/includes? cmd "--resume abc123"))
        (is (not (clojure.string/includes? cmd "--session-id"))))))

  (testing "copilot new session has no --resume"
    (with-redefs [voice-code.providers/cli-path (constantly "/usr/local/bin/copilot")]
      (let [cmd (tmux/build-provider-command :copilot {:session-uuid "abc123" :resume? false})]
        (is (not (clojure.string/includes? cmd "--resume")))
        (is (clojure.string/includes? cmd "--no-color"))
        (is (not (clojure.string/includes? cmd "--print"))))))

  (testing "copilot resume includes --resume"
    (with-redefs [voice-code.providers/cli-path (constantly "/usr/local/bin/copilot")]
      (let [cmd (tmux/build-provider-command :copilot {:session-uuid "abc123" :resume? true})]
        (is (clojure.string/includes? cmd "--resume abc123")))))

  (testing "cursor new session has --force, no --resume"
    (with-redefs [voice-code.providers/cli-path (constantly "/usr/local/bin/cursor")]
      (let [cmd (tmux/build-provider-command :cursor {:session-uuid "abc123" :resume? false})]
        (is (clojure.string/includes? cmd "--force"))
        (is (not (clojure.string/includes? cmd "--resume")))
        (is (not (clojure.string/includes? cmd "--print"))))))

  (testing "cursor resume includes --resume"
    (with-redefs [voice-code.providers/cli-path (constantly "/usr/local/bin/cursor")]
      (let [cmd (tmux/build-provider-command :cursor {:session-uuid "abc123" :resume? true})]
        (is (clojure.string/includes? cmd "--resume abc123")))))

  (testing "opencode new session has no --session flag"
    (with-redefs [voice-code.providers/cli-path (constantly "/usr/local/bin/opencode")]
      (let [cmd (tmux/build-provider-command :opencode {:session-uuid "abc123" :resume? false})]
        (is (not (clojure.string/includes? cmd "--session")))
        (is (not (clojure.string/includes? cmd "--print"))))))

  (testing "opencode resume includes --session"
    (with-redefs [voice-code.providers/cli-path (constantly "/usr/local/bin/opencode")]
      (let [cmd (tmux/build-provider-command :opencode {:session-uuid "abc123" :resume? true})]
        (is (clojure.string/includes? cmd "--session abc123"))))))

;; ============================================================================
;; choose-victim
;; ============================================================================

(deftest choose-victim-test
  (testing "returns nil when under the cap"
    (let [windows [{:window "a" :session-uuid "u1" :last-activity-ms 100 :idle? true}
                   {:window "b" :session-uuid "u2" :last-activity-ms 200 :idle? true}
                   {:window "c" :session-uuid "u3" :last-activity-ms 300 :idle? true}]]
      (is (nil? (tmux/choose-victim windows 4)))))

  (testing "returns nil when count equals cap but no idle windows"
    (let [windows [{:window "a" :last-activity-ms 100 :idle? false}
                   {:window "b" :last-activity-ms 200 :idle? false}
                   {:window "c" :last-activity-ms 300 :idle? false}
                   {:window "d" :last-activity-ms 400 :idle? false}]]
      (is (nil? (tmux/choose-victim windows 4)))))

  (testing "evicts oldest idle when at cap"
    (let [windows [{:window "a" :session-uuid "u1" :last-activity-ms 100 :idle? true}
                   {:window "b" :session-uuid "u2" :last-activity-ms 200 :idle? true}
                   {:window "c" :session-uuid "u3" :last-activity-ms 300 :idle? true}
                   {:window "d" :session-uuid "u4" :last-activity-ms 400 :idle? true}]]
      (is (= "a" (:window (tmux/choose-victim windows 4))))))

  (testing "never evicts a processing window even when at cap"
    (let [windows [{:window "a" :last-activity-ms 100 :idle? false}
                   {:window "b" :last-activity-ms 200 :idle? false}
                   {:window "c" :last-activity-ms 300 :idle? false}
                   {:window "d" :last-activity-ms 400 :idle? false}]]
      (is (nil? (tmux/choose-victim windows 4)))))

  (testing "evicts oldest idle, skips processing windows"
    (let [windows [{:window "a" :session-uuid "u1" :last-activity-ms 100 :idle? false}
                   {:window "b" :session-uuid "u2" :last-activity-ms 200 :idle? true}
                   {:window "c" :session-uuid "u3" :last-activity-ms 300 :idle? true}
                   {:window "d" :session-uuid "u4" :last-activity-ms 400 :idle? true}]]
      (is (= "b" (:window (tmux/choose-victim windows 4))))))

  (testing "evicts when over cap"
    (let [windows [{:window "a" :session-uuid "u1" :last-activity-ms 50 :idle? true}
                   {:window "b" :session-uuid "u2" :last-activity-ms 100 :idle? true}
                   {:window "c" :session-uuid "u3" :last-activity-ms 150 :idle? true}
                   {:window "d" :session-uuid "u4" :last-activity-ms 200 :idle? true}
                   {:window "e" :session-uuid "u5" :last-activity-ms 250 :idle? true}]]
      (is (= "a" (:window (tmux/choose-victim windows 4))))))

  (testing "returns nil when empty"
    (is (nil? (tmux/choose-victim [] 4)))))

;; ============================================================================
;; parse-show-environment
;; ============================================================================

(deftest parse-show-environment-test
  (testing "parses KEY=VALUE lines"
    (is (= {"FOO" "bar" "BAZ" "qux"}
           (tmux/parse-show-environment "FOO=bar\nBAZ=qux"))))

  (testing "lines starting with - are skipped (unset variables)"
    (is (= {"FOO" "bar"}
           (tmux/parse-show-environment "FOO=bar\n-UNSET_VAR"))))

  (testing "blank lines are skipped"
    (is (= {"FOO" "bar"}
           (tmux/parse-show-environment "FOO=bar\n\n"))))

  (testing "keys with empty values parse correctly"
    (is (= {"FOO" "bar" "BAZ" ""}
           (tmux/parse-show-environment "FOO=bar\nBAZ="))))

  (testing "values containing = are preserved"
    (is (= {"URL" "http://example.com?a=1&b=2"}
           (tmux/parse-show-environment "URL=http://example.com?a=1&b=2"))))

  (testing "nil input returns nil"
    (is (nil? (tmux/parse-show-environment nil))))

  (testing "empty string returns empty map"
    (is (= {} (tmux/parse-show-environment ""))))

  (testing "VC_ prefixed keys work correctly"
    (let [result (tmux/parse-show-environment
                  "VC_SESSION_UUID_session_abc123=abc123\nVC_WORKDIR_session_abc123=/home/user/project\nVC_PROVIDER_session_abc123=claude")]
      (is (= "abc123" (get result "VC_SESSION_UUID_session_abc123")))
      (is (= "/home/user/project" (get result "VC_WORKDIR_session_abc123")))
      (is (= "claude" (get result "VC_PROVIDER_session_abc123"))))))
