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

;; ============================================================================
;; nudge!
;; ============================================================================

(deftest nudge-test
  (testing "succeeds on first try: send-keys(-l), send-keys(Escape), send-keys(Enter) all exit 0"
    (let [calls (atom [])
          invoker (fn [& args]
                    (swap! calls conj (vec args))
                    {:exit 0 :out "" :err ""})]
      (binding [tmux/*tmux-invoker* invoker]
        (is (= :ok (tmux/nudge! "my-session" "my-window" "hello"))))
      (let [recorded @calls]
        ;; literal send-keys with -l flag
        (is (some #(and (= "tmux" (first %))
                        (= "send-keys" (second %))
                        (some #{"hello"} %)) recorded))
        ;; Escape keystroke
        (is (some #(and (= "tmux" (first %))
                        (= "send-keys" (second %))
                        (some #{"Escape"} %)) recorded))
        ;; Enter keystroke
        (is (some #(and (= "tmux" (first %))
                        (= "send-keys" (second %))
                        (some #{"Enter"} %)) recorded)))))

  (testing "retries Enter up to 3 times on failure, then returns :failed"
    (let [calls (atom [])
          ;; Every send-keys call fails
          invoker (fn [& args]
                    (swap! calls conj (vec args))
                    {:exit 1 :out "" :err ""})]
      (binding [tmux/*tmux-invoker* invoker]
        (is (= :failed (tmux/nudge! "my-session" "my-window" "hello"))))
      ;; Exactly 3 Enter attempts were made (all failed)
      (let [enter-calls (filter #(some #{"Enter"} %) @calls)]
        (is (= 3 (count enter-calls))))))

  (testing "succeeds on second Enter attempt after first fails"
    (let [enter-count (atom 0)
          invoker (fn [& args]
                    (if (some #{"Enter"} args)
                      (do (swap! enter-count inc)
                          (if (= 1 @enter-count)
                            {:exit 1 :out "" :err ""}
                            {:exit 0 :out "" :err ""}))
                      {:exit 0 :out "" :err ""}))]
      (binding [tmux/*tmux-invoker* invoker]
        (is (= :ok (tmux/nudge! "my-session" "my-window" "hello"))))
      (is (= 2 @enter-count))))

  (testing "target pane address uses correct format"
    (let [targets (atom [])
          invoker (fn [& args]
                    (let [t-idx (.indexOf (vec args) "-t")]
                      (when (>= t-idx 0)
                        (swap! targets conj (nth args (inc t-idx)))))
                    {:exit 0 :out "" :err ""})]
      (binding [tmux/*tmux-invoker* invoker]
        (tmux/nudge! "proj-session" "work-window" "test"))
      (is (seq @targets) "expected at least one -t argument to be recorded")
      (is (every? #(= "=proj-session:=work-window.0" %) @targets)))))

;; ============================================================================
;; processing? (via window-last-activity-ms)
;; ============================================================================

(deftest processing?-test
  (testing "returns true when session has recent activity (within 15 min)"
    (let [recent-ms (- (System/currentTimeMillis) (* 5 60 1000))]
      (with-redefs [voice-code.providers/session-metadata
                    (constantly {:last-modified-ms recent-ms})]
        (is (true? (#'tmux/processing? "some-uuid"))))))

  (testing "returns false when session has no recent activity (older than 15 min)"
    (let [old-ms (- (System/currentTimeMillis) (* 20 60 1000))]
      (with-redefs [voice-code.providers/session-metadata
                    (constantly {:last-modified-ms old-ms})]
        (is (false? (#'tmux/processing? "some-uuid"))))))

  (testing "returns false when session-metadata returns nil (missing session)"
    (with-redefs [voice-code.providers/session-metadata (constantly nil)]
      (is (false? (#'tmux/processing? "missing-uuid"))))))

;; ============================================================================
;; start-window!
;; ============================================================================

(deftest start-window!-test
  (testing "returns descriptor and updates live-windows"
    (let [uuid "abc123de-0000-0000-0000-000000000000"
          invoker (fn [& args]
                    (cond
                      ;; has-session: session already exists
                      (some #{"has-session"} args) {:exit 0 :out "" :err ""}
                      ;; list-windows: no agent windows yet (for evict-if-needed!)
                      (some #{"list-windows"} args) {:exit 0 :out "_holder\n" :err ""}
                      ;; show-environment: empty
                      (some #{"show-environment"} args) {:exit 0 :out "" :err ""}
                      ;; capture-pane: return readiness string for claude
                      (some #{"capture-pane"} args) {:exit 0 :out "bypass permissions" :err ""}
                      :else {:exit 0 :out "" :err ""}))]
      (binding [tmux/*tmux-invoker* invoker]
        (reset! tmux/live-windows {})
        (with-redefs [voice-code.providers/cli-path (constantly "/usr/local/bin/claude")
                      voice-code.providers/session-metadata (constantly nil)]
          (let [result (tmux/start-window! {:session-uuid uuid
                                            :session-name "Test Session"
                                            :provider :claude
                                            :workdir "/tmp/test-workdir"
                                            :initial-prompt nil})]
            (is (map? result))
            (is (= :claude (:provider result)))
            (is (= "/tmp/test-workdir" (:workdir result)))
            (is (= "test-workdir" (:tmux-session result)))
            (is (contains? @tmux/live-windows uuid))
            (let [stored (get @tmux/live-windows uuid)]
              (is (= :claude (:provider stored)))
              (is (= "/tmp/test-workdir" (:workdir stored)))))))))

  (testing "calls new-window with provider command"
    (let [uuid "def45600-0000-0000-0000-000000000000"
          new-window-calls (atom [])
          invoker (fn [& args]
                    (when (some #{"new-window"} args)
                      (swap! new-window-calls conj (vec args)))
                    (cond
                      (some #{"has-session"} args) {:exit 0 :out "" :err ""}
                      (some #{"list-windows"} args) {:exit 0 :out "_holder\n" :err ""}
                      (some #{"show-environment"} args) {:exit 0 :out "" :err ""}
                      (some #{"capture-pane"} args) {:exit 0 :out "bypass permissions" :err ""}
                      :else {:exit 0 :out "" :err ""}))]
      (binding [tmux/*tmux-invoker* invoker]
        (reset! tmux/live-windows {})
        (with-redefs [voice-code.providers/cli-path (constantly "/usr/bin/claude")
                      voice-code.providers/session-metadata (constantly nil)]
          (tmux/start-window! {:session-uuid uuid
                               :session-name nil
                               :provider :claude
                               :workdir "/tmp/proj"}))
        (is (seq @new-window-calls))
        (let [args (first @new-window-calls)]
          (is (some #{"new-window"} args))
          ;; command should contain session uuid
          (is (some #(clojure.string/includes? (str %) uuid) args))))))

  (testing "nudges initial-prompt when window becomes ready"
    (let [uuid "aabbccdd-0000-0000-0000-000000000000"
          send-keys-calls (atom [])
          invoker (fn [& args]
                    (when (some #{"send-keys"} args)
                      (swap! send-keys-calls conj (vec args)))
                    (cond
                      (some #{"has-session"} args) {:exit 0 :out "" :err ""}
                      (some #{"list-windows"} args) {:exit 0 :out "_holder\n" :err ""}
                      (some #{"show-environment"} args) {:exit 0 :out "" :err ""}
                      (some #{"capture-pane"} args) {:exit 0 :out "bypass permissions" :err ""}
                      :else {:exit 0 :out "" :err ""}))]
      (binding [tmux/*tmux-invoker* invoker]
        (reset! tmux/live-windows {})
        (with-redefs [voice-code.providers/cli-path (constantly "/usr/bin/claude")
                      voice-code.providers/session-metadata (constantly nil)]
          (tmux/start-window! {:session-uuid uuid
                               :session-name "My Session"
                               :provider :claude
                               :workdir "/tmp/proj"
                               :initial-prompt "Do the thing"}))
        ;; Should have literal send-keys with the prompt text
        (is (some #(some #{"Do the thing"} %) @send-keys-calls)
            "expected initial-prompt to be sent via send-keys"))))

  (testing "does not nudge when no initial-prompt"
    (let [uuid "11223344-0000-0000-0000-000000000000"
          send-keys-calls (atom [])
          invoker (fn [& args]
                    (when (and (some #{"send-keys"} args) (some #{"-l"} args))
                      (swap! send-keys-calls conj (vec args)))
                    (cond
                      (some #{"has-session"} args) {:exit 0 :out "" :err ""}
                      (some #{"list-windows"} args) {:exit 0 :out "_holder\n" :err ""}
                      (some #{"show-environment"} args) {:exit 0 :out "" :err ""}
                      (some #{"capture-pane"} args) {:exit 0 :out "bypass permissions" :err ""}
                      :else {:exit 0 :out "" :err ""}))]
      (binding [tmux/*tmux-invoker* invoker]
        (reset! tmux/live-windows {})
        (with-redefs [voice-code.providers/cli-path (constantly "/usr/bin/claude")
                      voice-code.providers/session-metadata (constantly nil)]
          (tmux/start-window! {:session-uuid uuid
                               :session-name nil
                               :provider :claude
                               :workdir "/tmp/proj"
                               :initial-prompt nil}))
        ;; No literal send-keys with -l (no prompt nudge)
        (is (empty? @send-keys-calls)
            "expected no nudge when initial-prompt is nil"))))

  (testing "start-window! with resume? true passes --resume to provider command"
    (let [uuid "55667788-0000-0000-0000-000000000000"
          new-window-args (atom nil)
          invoker (fn [& args]
                    (when (some #{"new-window"} args)
                      (reset! new-window-args (vec args)))
                    (cond
                      (some #{"has-session"} args) {:exit 0 :out "" :err ""}
                      (some #{"list-windows"} args) {:exit 0 :out "_holder\n" :err ""}
                      (some #{"show-environment"} args) {:exit 0 :out "" :err ""}
                      (some #{"capture-pane"} args) {:exit 0 :out "bypass permissions" :err ""}
                      :else {:exit 0 :out "" :err ""}))]
      (binding [tmux/*tmux-invoker* invoker]
        (reset! tmux/live-windows {})
        (with-redefs [voice-code.providers/cli-path (constantly "/usr/bin/claude")
                      voice-code.providers/session-metadata (constantly nil)]
          (tmux/start-window! {:session-uuid uuid
                               :session-name nil
                               :provider :claude
                               :workdir "/tmp/proj"
                               :resume? true}))
        (is (some? @new-window-args))
        (is (some #(clojure.string/includes? (str %) "--resume") @new-window-args)
            "expected --resume in new-window command when resume? is true"))))

  (testing "evicts one idle window when at cap before creating new window"
    (let [uuid "99aabbcc-0000-0000-0000-000000000000"
          victim-uuid "victim-uuid-0000-0000-0000-000000000000"
          kill-window-calls (atom [])
          old-ms (- (System/currentTimeMillis) (* 30 60 1000)) ; 30 min ago = idle
          invoker (fn [& args]
                    (when (some #{"kill-window"} args)
                      (swap! kill-window-calls conj (vec args)))
                    (cond
                      (some #{"has-session"} args) {:exit 0 :out "" :err ""}
                      (some #{"list-windows"} args)
                      {:exit 0
                       :out (str "win-a\nwin-b\nwin-c\nwin-d\n")
                       :err ""}
                      (some #{"show-environment"} args)
                      {:exit 0
                       :out (str "VC_SESSION_UUID_win_a=" victim-uuid "\n"
                                 "VC_SESSION_UUID_win_b=uuid-b\n"
                                 "VC_SESSION_UUID_win_c=uuid-c\n"
                                 "VC_SESSION_UUID_win_d=uuid-d\n")
                       :err ""}
                      (some #{"capture-pane"} args) {:exit 0 :out "bypass permissions" :err ""}
                      :else {:exit 0 :out "" :err ""}))]
      (binding [tmux/*tmux-invoker* invoker]
        (reset! tmux/live-windows {})
        (with-redefs [voice-code.providers/cli-path (constantly "/usr/bin/claude")
                      voice-code.providers/session-metadata
                      (fn [sid]
                        {:last-modified-ms (if (= sid victim-uuid) old-ms
                                               (- (System/currentTimeMillis) (* 2 60 1000)))})]
          (tmux/start-window! {:session-uuid uuid
                               :session-name nil
                               :provider :claude
                               :workdir "/tmp/proj"}))
        (is (seq @kill-window-calls) "expected kill-window to be called for evicted window")))))

;; ============================================================================
;; sweep!
;; ============================================================================

(deftest sweep!-test
  (testing "kills windows older than sweeper-max-age-days and removes from live-windows"
    (let [old-uuid "oldstale-0000-0000-0000-000000000000"
          recent-uuid "recent00-0000-0000-0000-000000000000"
          old-ms (- (System/currentTimeMillis) (* 3 24 60 60 1000))
          recent-ms (- (System/currentTimeMillis) (* 1 60 60 1000))
          kill-calls (atom [])
          invoker (fn [& args]
                    (when (some #{"kill-window"} args)
                      (swap! kill-calls conj (vec args)))
                    {:exit 0 :out "" :err ""})]
      (binding [tmux/*tmux-invoker* invoker]
        (reset! tmux/live-windows
                {old-uuid    {:tmux-session "proj" :tmux-window "old-win"    :provider :claude :workdir "/tmp"}
                 recent-uuid {:tmux-session "proj" :tmux-window "recent-win" :provider :claude :workdir "/tmp"}})
        (with-redefs [voice-code.providers/session-metadata
                      (fn [uuid]
                        (cond
                          (= uuid old-uuid)    {:last-modified-ms old-ms}
                          (= uuid recent-uuid) {:last-modified-ms recent-ms}))]
          (tmux/sweep!)))
      (is (seq @kill-calls) "expected kill-window for stale window")
      (is (some (fn [call] (some (fn [arg] (and (string? arg) (clojure.string/includes? arg "old-win"))) call))
               @kill-calls)
          "expected old-win to be killed")
      (is (not (contains? @tmux/live-windows old-uuid)) "expected old-uuid removed")
      (is (contains? @tmux/live-windows recent-uuid) "expected recent-uuid still present")))

  (testing "does not kill windows within sweeper-max-age-days"
    (let [uuid "active00-0000-0000-0000-000000000000"
          recent-ms (- (System/currentTimeMillis) (* 1 60 60 1000))
          kill-calls (atom [])
          invoker (fn [& args]
                    (when (some #{"kill-window"} args)
                      (swap! kill-calls conj (vec args)))
                    {:exit 0 :out "" :err ""})]
      (binding [tmux/*tmux-invoker* invoker]
        (reset! tmux/live-windows
                {uuid {:tmux-session "proj" :tmux-window "active-win" :provider :claude :workdir "/tmp"}})
        (with-redefs [voice-code.providers/session-metadata
                      (constantly {:last-modified-ms recent-ms})]
          (tmux/sweep!)))
      (is (empty? @kill-calls) "expected no kill-window for active window")
      (is (contains? @tmux/live-windows uuid) "expected active-uuid still present")))

  (testing "handles empty live-windows without errors"
    (let [kill-calls (atom [])
          invoker (fn [& args]
                    (when (some #{"kill-window"} args)
                      (swap! kill-calls conj (vec args)))
                    {:exit 0 :out "" :err ""})]
      (binding [tmux/*tmux-invoker* invoker]
        (reset! tmux/live-windows {})
        (tmux/sweep!))
      (is (empty? @kill-calls)))))

;; ============================================================================
;; scan-existing-windows!
;; ============================================================================

(deftest scan-existing-windows!-test
  (testing "populates live-windows from tmux env vars"
    ;; window name "session-aabbcc" → env-suffix "session_aabbcc"
    (let [uuid "aabbcc00-0000-0000-0000-000000000000"
          invoker (fn [& args]
                    (cond
                      (some #{"list-sessions"} args)
                      {:exit 0 :out "my-project\n" :err ""}
                      (some #{"list-windows"} args)
                      {:exit 0 :out "session-aabbcc\n" :err ""}
                      (some #{"show-environment"} args)
                      {:exit 0
                       :out (str "VC_SESSION_UUID_session_aabbcc=" uuid "\n"
                                 "VC_WORKDIR_session_aabbcc=/home/user/proj\n"
                                 "VC_PROVIDER_session_aabbcc=claude\n"
                                 "VC_STARTED_AT_session_aabbcc=2026-01-01T00:00:00Z\n")
                       :err ""}
                      :else {:exit 0 :out "" :err ""}))]
      (binding [tmux/*tmux-invoker* invoker]
        (reset! tmux/live-windows {})
        (tmux/scan-existing-windows!))
      (is (contains? @tmux/live-windows uuid))
      (let [entry (get @tmux/live-windows uuid)]
        (is (= "my-project" (:tmux-session entry)))
        (is (= "session-aabbcc" (:tmux-window entry)))
        (is (= :claude (:provider entry)))
        (is (= "/home/user/proj" (:workdir entry)))
        (is (= "2026-01-01T00:00:00Z" (:started-at entry))))))

  (testing "skips _holder and tile windows"
    (let [invoker (fn [& args]
                    (cond
                      (some #{"list-sessions"} args)
                      {:exit 0 :out "my-project\n" :err ""}
                      (some #{"list-windows"} args)
                      {:exit 0 :out "_holder\ntile\n" :err ""}
                      (some #{"show-environment"} args)
                      {:exit 0 :out "" :err ""}
                      :else {:exit 0 :out "" :err ""}))]
      (binding [tmux/*tmux-invoker* invoker]
        (reset! tmux/live-windows {})
        (tmux/scan-existing-windows!))
      (is (empty? @tmux/live-windows) "expected no entries for _holder/tile")))

  (testing "skips windows without VC_SESSION_UUID env var"
    (let [invoker (fn [& args]
                    (cond
                      (some #{"list-sessions"} args)
                      {:exit 0 :out "my-project\n" :err ""}
                      (some #{"list-windows"} args)
                      {:exit 0 :out "some-window-abc123\n" :err ""}
                      (some #{"show-environment"} args)
                      {:exit 0 :out "OTHER_KEY=value\n" :err ""}
                      :else {:exit 0 :out "" :err ""}))]
      (binding [tmux/*tmux-invoker* invoker]
        (reset! tmux/live-windows {})
        (tmux/scan-existing-windows!))
      (is (empty? @tmux/live-windows) "expected no entries when VC_SESSION_UUID missing")))

  (testing "handles empty list-sessions"
    (let [invoker (fn [& args]
                    (cond
                      (some #{"list-sessions"} args)
                      {:exit 0 :out "" :err ""}
                      :else {:exit 0 :out "" :err ""}))]
      (binding [tmux/*tmux-invoker* invoker]
        (reset! tmux/live-windows {})
        (tmux/scan-existing-windows!))
      (is (empty? @tmux/live-windows))))

  (testing "populates multiple sessions"
    (let [uuid1 "aabbcc00-1111-0000-0000-000000000000"
          uuid2 "ddeeff00-2222-0000-0000-000000000000"
          ;; window1: "session-aabbcc", env-suffix "session_aabbcc"
          ;; window2: "session-ddeeff", env-suffix "session_ddeeff"
          invoker (fn [& args]
                    (cond
                      (some #{"list-sessions"} args)
                      {:exit 0 :out "proj-a\nproj-b\n" :err ""}
                      (and (some #{"list-windows"} args)
                           (some #{"=proj-a"} args))
                      {:exit 0 :out "session-aabbcc\n" :err ""}
                      (and (some #{"list-windows"} args)
                           (some #{"=proj-b"} args))
                      {:exit 0 :out "session-ddeeff\n" :err ""}
                      (and (some #{"show-environment"} args)
                           (some #{"=proj-a"} args))
                      {:exit 0
                       :out (str "VC_SESSION_UUID_session_aabbcc=" uuid1 "\n"
                                 "VC_WORKDIR_session_aabbcc=/home/a\n"
                                 "VC_PROVIDER_session_aabbcc=claude\n")
                       :err ""}
                      (and (some #{"show-environment"} args)
                           (some #{"=proj-b"} args))
                      {:exit 0
                       :out (str "VC_SESSION_UUID_session_ddeeff=" uuid2 "\n"
                                 "VC_WORKDIR_session_ddeeff=/home/b\n"
                                 "VC_PROVIDER_session_ddeeff=copilot\n")
                       :err ""}
                      :else {:exit 0 :out "" :err ""}))]
      (binding [tmux/*tmux-invoker* invoker]
        (reset! tmux/live-windows {})
        (tmux/scan-existing-windows!))
      (is (contains? @tmux/live-windows uuid1))
      (is (contains? @tmux/live-windows uuid2))
      (is (= :claude (:provider (get @tmux/live-windows uuid1))))
      (is (= :copilot (:provider (get @tmux/live-windows uuid2))))
      (is (= "proj-a" (:tmux-session (get @tmux/live-windows uuid1))))
      (is (= "proj-b" (:tmux-session (get @tmux/live-windows uuid2))))))

  (testing "is idempotent — re-running overwrites with same data"
    (let [uuid "aabbcc00-0000-0000-0000-111111111111"
          invoker (fn [& args]
                    (cond
                      (some #{"list-sessions"} args)
                      {:exit 0 :out "my-project\n" :err ""}
                      (some #{"list-windows"} args)
                      {:exit 0 :out "session-aabbcc\n" :err ""}
                      (some #{"show-environment"} args)
                      {:exit 0
                       :out (str "VC_SESSION_UUID_session_aabbcc=" uuid "\n"
                                 "VC_WORKDIR_session_aabbcc=/home/user/proj\n"
                                 "VC_PROVIDER_session_aabbcc=claude\n")
                       :err ""}
                      :else {:exit 0 :out "" :err ""}))]
      (binding [tmux/*tmux-invoker* invoker]
        (reset! tmux/live-windows {})
        (tmux/scan-existing-windows!)
        (tmux/scan-existing-windows!))
      (is (= 1 (count @tmux/live-windows)) "expected exactly one entry after two scans")
      (is (contains? @tmux/live-windows uuid)))))

;; ============================================================================
;; deliver!
;; ============================================================================

(deftest deliver!-test
  (testing "nudges existing window when UUID is in live-windows"
    (let [uuid "live-uuid-0000-0000-0000-000000000000"
          send-keys-calls (atom [])
          invoker (fn [& args]
                    (swap! send-keys-calls conj (vec args))
                    {:exit 0 :out "" :err ""})]
      (binding [tmux/*tmux-invoker* invoker]
        (reset! tmux/live-windows
                {uuid {:tmux-session "my-session"
                       :tmux-window "my-window"
                       :provider :claude
                       :workdir "/tmp"}})
        (tmux/deliver! uuid "follow-up prompt"))
      ;; literal send-keys with the prompt text
      (is (some #(some #{"follow-up prompt"} %) @send-keys-calls)
          "expected nudge to be called on existing window")))

  (testing "respawns via start-window! with --resume when UUID not in live-windows"
    (let [uuid "evicted-uuid-0000-0000-0000-000000000000"
          new-window-args (atom nil)
          invoker (fn [& args]
                    (when (some #{"new-window"} args)
                      (reset! new-window-args (vec args)))
                    (cond
                      (some #{"has-session"} args) {:exit 0 :out "" :err ""}
                      (some #{"list-windows"} args) {:exit 0 :out "_holder\n" :err ""}
                      (some #{"show-environment"} args) {:exit 0 :out "" :err ""}
                      (some #{"capture-pane"} args) {:exit 0 :out "bypass permissions" :err ""}
                      :else {:exit 0 :out "" :err ""}))]
      (binding [tmux/*tmux-invoker* invoker]
        (reset! tmux/live-windows {})
        (with-redefs [voice-code.providers/cli-path (constantly "/usr/bin/claude")
                      voice-code.providers/session-metadata
                      (constantly {:provider :claude
                                   :working-directory "/tmp/proj"
                                   :name "My Evicted Session"})]
          (tmux/deliver! uuid "my follow-up")))
      (is (some? @new-window-args) "expected new-window to be called (respawn)")
      (is (some #(clojure.string/includes? (str %) "--resume") @new-window-args)
          "expected --resume flag in respawned window command")))

  (testing "respawn uses workdir from session metadata"
    (let [uuid "evicted-uuid-1111-0000-0000-000000000000"
          new-window-args (atom nil)
          invoker (fn [& args]
                    (when (some #{"new-window"} args)
                      (reset! new-window-args (vec args)))
                    (cond
                      (some #{"has-session"} args) {:exit 0 :out "" :err ""}
                      (some #{"list-windows"} args) {:exit 0 :out "_holder\n" :err ""}
                      (some #{"show-environment"} args) {:exit 0 :out "" :err ""}
                      (some #{"capture-pane"} args) {:exit 0 :out "bypass permissions" :err ""}
                      :else {:exit 0 :out "" :err ""}))]
      (binding [tmux/*tmux-invoker* invoker]
        (reset! tmux/live-windows {})
        (with-redefs [voice-code.providers/cli-path (constantly "/usr/bin/claude")
                      voice-code.providers/session-metadata
                      (constantly {:provider :claude
                                   :working-directory "/tmp/special-dir"
                                   :name "Session"})]
          (tmux/deliver! uuid "prompt text")))
      (is (some? @new-window-args))
      ;; working directory should appear in the new-window -c argument
      (is (some #(= "/tmp/special-dir" %) @new-window-args)
          "expected working directory from metadata to be used in new-window"))))
