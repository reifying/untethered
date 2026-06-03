(ns voice-code.tmux-test
  "Unit tests for pure helpers in voice-code.tmux.
   No tmux server required — all tested functions are pure or use rebindable state."
  (:require [clojure.string :as str]
            [clojure.test :refer [deftest is testing]]
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
    (is (= "session" (tmux/sanitize-session-name nil))))

  (testing "no collision when existing-workdirs is nil"
    (is (= "proj" (tmux/sanitize-session-name "/a/proj" nil))))

  (testing "no collision when existing-workdirs is empty"
    (is (= "proj" (tmux/sanitize-session-name "/a/proj" []))))

  (testing "no collision when other paths have different slugs"
    (is (= "proj" (tmux/sanitize-session-name "/b/proj" ["/a/other-project"]))))

  (testing "collision: two paths with the same basename get different session names"
    (let [name-a (tmux/sanitize-session-name "/a/proj" nil)
          name-b (tmux/sanitize-session-name "/b/proj" ["/a/proj"])]
      (is (= "proj" name-a))
      (is (clojure.string/starts-with? name-b "proj-"))
      (is (not= name-a name-b))
      ;; suffix is exactly 6 hex chars
      (is (re-matches #"proj-[0-9a-f]{6}" name-b))))

  (testing "collision hash is deterministic: same path always produces same suffix"
    (let [name1 (tmux/sanitize-session-name "/b/proj" ["/a/proj"])
          name2 (tmux/sanitize-session-name "/b/proj" ["/a/proj"])]
      (is (= name1 name2))))

  (testing "no self-collision: path not appended when only matching path is itself"
    (is (= "proj" (tmux/sanitize-session-name "/a/proj" ["/a/proj"])))))

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

  (testing "copilot ready on the v1.0.57 '/ commands · ? help' footer + chevron"
    (let [ready? (tmux/readiness-predicate :copilot)
          ;; Exact ready-state pane captured from Copilot v1.0.57 (the TUI that
          ;; broke the old 'Type @ to mention' needle and timed out recipe
          ;; launches; see readiness-predicate docstring / :wait-for-ready-timeout).
          v1057-ready (str "  ╭─╮╭─╮\n  ╰─╯╰─╯  Copilot v1.0.57 uses AI.\n"
                           "● No copilot-instructions.md found. Run /init to generate.\n\n"
                           " ~/code/mck/x [⎇ main]                         AI Credits: 0\n"
                           "──────────\n❯\n──────────\n"
                           " / commands · ? help                          Claude Sonnet 4.6\n")]
      (is (true? (ready? v1057-ready)))
      ;; The fix must not depend on the now-absent legacy hint.
      (is (false? (str/includes? v1057-ready "Type @ to mention")))
      ;; Footer hint alone is sufficient (chevron may be off-screen in a short capture).
      (is (true? (ready? "blah\n / commands · ? help")))
      ;; Banner-only boot state is NOT ready (no input box / footer yet).
      (is (false? (ready? "  ╭─╮╭─╮  Copilot v1.0.57 uses AI.\nLoading...")))
      (is (false? (ready? "Loading...")))
      ;; nil content must not throw.
      (is (false? (ready? nil)))))

  (testing "cursor ready after 'Press any key' appears"
    (let [ready? (tmux/readiness-predicate :cursor)]
      (is (true? (ready? "Cursor Agent\nPress any key to continue")))
      (is (false? (ready? "Initializing")))))

  (testing "opencode ready after 'Ask anything' appears"
    (let [ready? (tmux/readiness-predicate :opencode)]
      (is (true? (ready? "OpenCode AI\nAsk anything about your code")))
      (is (false? (ready? "Loading model..."))))))

;; ============================================================================
;; wait-for-ready: --resume confirmation dialog handshake
;; ============================================================================

(def ^:private resume-dialog-pane
  "This session is 4d old and 118.8k tokens.\n\n❯ 1. Resume from summary (recommended)\n  2. Resume full session as-is\n  3. Don't ask me again")

(def ^:private trust-dialog-pane
  "Accessing workspace:\n\n /Users/travisbrown\n\n Quick safety check: Is this a project you created or one you trust?\n\n ❯ 1. Yes, I trust this folder\n   2. No, exit\n\n Enter to confirm · Esc to cancel")

(deftest wait-for-ready-dismisses-claude-trust-dialog
  (testing "dismisses the trust-folder dialog with Enter, then reaches ready"
    (let [call-log (atom [])
          state (atom :dialog)
          invoker (fn [& args]
                    (swap! call-log conj (vec args))
                    (cond
                      (some #{"capture-pane"} args)
                      (case @state
                        :dialog {:exit 0 :out trust-dialog-pane :err ""}
                        :loading {:exit 0 :out "Loading..." :err ""}
                        :ready {:exit 0 :out "> prompt\n? for shortcuts · bypass permissions" :err ""})
                      (and (some #{"send-keys"} args) (some #{"Enter"} args))
                      (do (reset! state :ready) {:exit 0 :out "" :err ""})
                      :else {:exit 0 :out "" :err ""}))]
      (binding [tmux/*tmux-invoker* invoker]
        (is (= :ready (tmux/wait-for-ready "sess" "win" :claude
                                           :timeout-ms 3000 :poll-ms 1))))
      (let [send-keys-calls (filter #(some #{"send-keys"} %) @call-log)
            enters (filter #(some #{"Enter"} %) send-keys-calls)
            literal-3 (filter #(and (some #{"-l"} %) (some #{"3"} %)) send-keys-calls)]
        (is (= 1 (count enters)) "exactly one Enter should be sent")
        (is (= 0 (count literal-3)) "must not send literal '3' for trust dialog"))))

  (testing "does NOT dismiss trust dialog for non-claude providers"
    (let [dismissed? (atom false)
          invoker (fn [& args]
                    (cond
                      (some #{"capture-pane"} args)
                      {:exit 0 :out trust-dialog-pane :err ""}
                      (and (some #{"send-keys"} args) (some #{"Enter"} args))
                      (do (reset! dismissed? true) {:exit 0 :out "" :err ""})
                      :else {:exit 0 :out "" :err ""}))]
      (binding [tmux/*tmux-invoker* invoker]
        (is (= :timeout (tmux/wait-for-ready "sess" "win" :copilot
                                             :timeout-ms 50 :poll-ms 1))))
      (is (false? @dismissed?) "copilot must never send Enter for claude's trust dialog")))

  (testing "trust dialog is dismissed at most once even if it persists"
    (let [enter-calls (atom 0)
          invoker (fn [& args]
                    (cond
                      (some #{"capture-pane"} args)
                      {:exit 0 :out trust-dialog-pane :err ""}
                      (and (some #{"send-keys"} args) (some #{"Enter"} args))
                      (do (swap! enter-calls inc) {:exit 0 :out "" :err ""})
                      :else {:exit 0 :out "" :err ""}))]
      (binding [tmux/*tmux-invoker* invoker]
        (is (= :timeout (tmux/wait-for-ready "sess" "win" :claude
                                             :timeout-ms 50 :poll-ms 1))))
      (is (= 1 @enter-calls) "must only dismiss once even if dialog text persists")))

  (testing "handles trust dialog followed by resume dialog in sequence"
    (let [call-log (atom [])
          state (atom :trust)
          invoker (fn [& args]
                    (swap! call-log conj (vec args))
                    (cond
                      (some #{"capture-pane"} args)
                      (case @state
                        :trust {:exit 0 :out trust-dialog-pane :err ""}
                        :resume {:exit 0 :out resume-dialog-pane :err ""}
                        :ready {:exit 0 :out "bypass permissions" :err ""})
                      (and (some #{"send-keys"} args) (some #{"Enter"} args)
                           (not (some #{"-l"} args)))
                      (do (when (= @state :trust) (reset! state :resume))
                          {:exit 0 :out "" :err ""})
                      (and (some #{"send-keys"} args) (some #{"-l"} args) (some #{"3"} args))
                      (do (reset! state :ready) {:exit 0 :out "" :err ""})
                      :else {:exit 0 :out "" :err ""}))]
      (binding [tmux/*tmux-invoker* invoker]
        (is (= :ready (tmux/wait-for-ready "sess" "win" :claude
                                           :timeout-ms 3000 :poll-ms 1))))
      (let [send-keys-calls (filter #(some #{"send-keys"} %) @call-log)
            literal-3 (filter #(and (some #{"-l"} %) (some #{"3"} %)) send-keys-calls)
            enters (filter #(and (some #{"Enter"} %) (not (some #{"-l"} %))) send-keys-calls)]
        (is (= 1 (count literal-3)) "resume dialog dismissed with literal 3")
        ;; Resume dismissal sends "-l 3" then a bare Enter; trust dismissal sends one bare Enter
        (is (= 2 (count enters)) "both dialogs each contribute one bare Enter")))))

(deftest wait-for-ready-dismisses-claude-resume-dialog
  (testing "dismisses the --resume dialog with 3+Enter, then reaches ready"
    (let [call-log (atom [])
          state (atom :dialog)
          invoker (fn [& args]
                    (swap! call-log conj (vec args))
                    (cond
                      (some #{"capture-pane"} args)
                      (case @state
                        :dialog {:exit 0 :out resume-dialog-pane :err ""}
                        :loading {:exit 0 :out "Loading..." :err ""}
                        :ready {:exit 0 :out "> prompt\n? for shortcuts · bypass permissions" :err ""})
                      (and (some #{"send-keys"} args)
                           (some #{"-l"} args)
                           (some #{"3"} args))
                      (do (reset! state :loading) {:exit 0 :out "" :err ""})
                      (and (some #{"send-keys"} args) (some #{"Enter"} args))
                      (do (reset! state :ready) {:exit 0 :out "" :err ""})
                      :else {:exit 0 :out "" :err ""}))]
      (binding [tmux/*tmux-invoker* invoker]
        (is (= :ready (tmux/wait-for-ready "sess" "win" :claude
                                           :timeout-ms 3000 :poll-ms 1))))
      (let [send-keys-calls (filter #(some #{"send-keys"} %) @call-log)
            literal-3 (filter #(and (some #{"-l"} %) (some #{"3"} %)) send-keys-calls)
            enters (filter #(some #{"Enter"} %) send-keys-calls)]
        (is (= 1 (count literal-3))
            "exactly one literal '3' should be sent")
        (is (= 1 (count enters))
            "exactly one Enter should be sent"))))

  (testing "does NOT dismiss dialog for non-claude providers"
    (let [dismissed? (atom false)
          polls (atom 0)
          invoker (fn [& args]
                    (cond
                      (some #{"capture-pane"} args)
                      (do (swap! polls inc)
                          {:exit 0 :out resume-dialog-pane :err ""})
                      (and (some #{"send-keys"} args) (some #{"-l"} args) (some #{"3"} args))
                      (do (reset! dismissed? true) {:exit 0 :out "" :err ""})
                      :else {:exit 0 :out "" :err ""}))]
      (binding [tmux/*tmux-invoker* invoker]
        (is (= :timeout (tmux/wait-for-ready "sess" "win" :copilot
                                             :timeout-ms 50 :poll-ms 1))))
      (is (false? @dismissed?)
          "copilot must never send '3' in response to claude's dialog text")
      (is (pos? @polls))))

  (testing "dialog is dismissed at most once even if it persists"
    (let [send-3-calls (atom 0)
          invoker (fn [& args]
                    (cond
                      (some #{"capture-pane"} args)
                      {:exit 0 :out resume-dialog-pane :err ""}
                      (and (some #{"send-keys"} args) (some #{"-l"} args) (some #{"3"} args))
                      (do (swap! send-3-calls inc) {:exit 0 :out "" :err ""})
                      :else {:exit 0 :out "" :err ""}))]
      (binding [tmux/*tmux-invoker* invoker]
        (is (= :timeout (tmux/wait-for-ready "sess" "win" :claude
                                             :timeout-ms 50 :poll-ms 1))))
      (is (= 1 @send-3-calls)
          "even if dialog-like text persists, we must only dismiss once"))))

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
        (is (clojure.string/includes? cmd "--session abc123")))))

  (testing "claude new session appends --append-system-prompt when system-prompt set"
    (with-redefs [voice-code.providers/cli-path (constantly "/usr/local/bin/claude")]
      (let [cmd (tmux/build-provider-command :claude {:session-uuid "abc123"
                                                      :resume? false
                                                      :system-prompt "Be concise"})]
        (is (clojure.string/includes? cmd "--append-system-prompt 'Be concise'")))))

  (testing "claude resume session does NOT append --append-system-prompt (startup-only flag)"
    (with-redefs [voice-code.providers/cli-path (constantly "/usr/local/bin/claude")]
      (let [cmd (tmux/build-provider-command :claude {:session-uuid "abc123"
                                                      :resume? true
                                                      :system-prompt "Be concise"})]
        (is (not (clojure.string/includes? cmd "--append-system-prompt"))))))

  (testing "claude trims whitespace from system-prompt"
    (with-redefs [voice-code.providers/cli-path (constantly "/usr/local/bin/claude")]
      (let [cmd (tmux/build-provider-command :claude {:session-uuid "abc123"
                                                      :resume? false
                                                      :system-prompt "  Be concise  \n"})]
        (is (clojure.string/includes? cmd "--append-system-prompt 'Be concise'")))))

  (testing "claude ignores blank or whitespace-only system-prompt"
    (with-redefs [voice-code.providers/cli-path (constantly "/usr/local/bin/claude")]
      (doseq [blank ["" "   " "\t\n  "]]
        (let [cmd (tmux/build-provider-command :claude {:session-uuid "abc123"
                                                        :resume? false
                                                        :system-prompt blank})]
          (is (not (clojure.string/includes? cmd "--append-system-prompt"))
              (str "blank system-prompt " (pr-str blank) " should be dropped"))))))

  (testing "claude shell-escapes single quotes in system-prompt"
    (with-redefs [voice-code.providers/cli-path (constantly "/usr/local/bin/claude")]
      (let [cmd (tmux/build-provider-command :claude {:session-uuid "abc123"
                                                      :resume? false
                                                      :system-prompt "don't do it"})]
        ;; Embedded single quote closed with ', escaped as \', then reopened with '
        (is (clojure.string/includes? cmd "--append-system-prompt 'don'\\''t do it'")))))

  (testing "non-claude providers silently drop system-prompt (CLI does not support it)"
    (doseq [provider [:copilot :cursor :opencode]]
      (with-redefs [voice-code.providers/cli-path (constantly (str "/usr/local/bin/" (name provider)))]
        (let [cmd (tmux/build-provider-command provider {:session-uuid "abc123"
                                                         :resume? false
                                                         :system-prompt "Be concise"})]
          (is (not (clojure.string/includes? cmd "--append-system-prompt"))
              (str provider " should not include --append-system-prompt")))))))

(deftest build-provider-command-fork-test
  (testing "claude fork? emits --resume <src> --fork-session, never --session-id"
    (with-redefs [voice-code.providers/cli-path (constantly "/usr/local/bin/claude")]
      (let [cmd (tmux/build-provider-command :claude {:session-uuid "S-123" :fork? true})]
        (is (clojure.string/includes? cmd "--resume S-123 --fork-session"))
        (is (not (clojure.string/includes? cmd "--session-id"))))))

  (testing "claude fork? does not append --append-system-prompt (a fork is a resume)"
    (with-redefs [voice-code.providers/cli-path (constantly "/usr/local/bin/claude")]
      (let [cmd (tmux/build-provider-command :claude {:session-uuid "S-123"
                                                      :fork? true
                                                      :system-prompt "Be terse."})]
        (is (not (clojure.string/includes? cmd "--append-system-prompt"))))))

  (testing "fork? takes precedence over resume?"
    (with-redefs [voice-code.providers/cli-path (constantly "/usr/local/bin/claude")]
      (let [cmd (tmux/build-provider-command :claude {:session-uuid "S-123"
                                                      :fork? true
                                                      :resume? true})]
        (is (clojure.string/includes? cmd "--resume S-123 --fork-session"))
        (is (not (clojure.string/includes? cmd "--session-id")))))))

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
  (testing "succeeds on first try: send literal text then Enter"
    (let [calls (atom [])
          invoker (fn [& args]
                    (swap! calls conj (vec args))
                    {:exit 0 :out "" :err ""})]
      (binding [tmux/*tmux-invoker* invoker]
        (is (= :ok (tmux/nudge! "my-session" "my-window" "hello"))))
      (let [recorded @calls]
        (is (some #(and (= "tmux" (first %))
                        (= "send-keys" (second %))
                        (some #{"hello"} %)) recorded)
            "literal text must be sent with -l")
        (is (some #(and (= "tmux" (first %))
                        (= "send-keys" (second %))
                        (some #{"Enter"} %)) recorded)
            "Enter must be sent")
        (is (not (some #(some #{"Escape"} %) recorded))
            "Escape must not be sent"))))

  (testing "retries Enter up to 3 times on failure, then returns :failed"
    (let [calls (atom [])
          invoker (fn [& args]
                    (swap! calls conj (vec args))
                    {:exit 1 :out "" :err ""})]
      (binding [tmux/*tmux-invoker* invoker]
        (is (= :failed (tmux/nudge! "my-session" "my-window" "hello"))))
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
              (is (= "/tmp/test-workdir" (:workdir stored)))
              (is (string? (:started-at stored))
                  "started-at must be an ISO-8601 string to match scan-existing-windows!"))
            (is (string? (:started-at result))
                "returned descriptor's started-at must be an ISO-8601 string"))))))

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
;; start-window! idempotency
;; ============================================================================

(deftest start-window!-idempotent-live-windows-test
  (testing "returns existing descriptor from live-windows without creating a new window"
    (let [uuid "idem-live-0000-0000-0000-000000000000"
          existing-desc {:tmux-session "assist"
                         :tmux-window "hi-agent-idemli"
                         :provider :claude
                         :workdir "/home/user/assist"
                         :started-at "2026-01-01T00:00:00Z"}
          new-window-calls (atom [])
          send-keys-calls (atom [])
          invoker (fn [& args]
                    (when (some #{"new-window"} args)
                      (swap! new-window-calls conj (vec args)))
                    (when (some #{"send-keys"} args)
                      (swap! send-keys-calls conj (vec args)))
                    {:exit 0 :out "" :err ""})]
      (binding [tmux/*tmux-invoker* invoker]
        (reset! tmux/live-windows {uuid existing-desc})
        (with-redefs [voice-code.providers/cli-path (constantly "/usr/bin/claude")
                      voice-code.providers/session-metadata (constantly nil)]
          (let [result (tmux/start-window! {:session-uuid uuid
                                            :session-name "different-name"
                                            :provider :claude
                                            :workdir "/tmp/other"
                                            :initial-prompt nil})]
            (is (= existing-desc result)
                "must return the pre-existing descriptor unchanged")
            (is (empty? @new-window-calls)
                "must not spawn a new tmux window")
            (is (empty? @send-keys-calls)
                "must not nudge when no initial-prompt"))))))

  (testing "reuses existing live-windows entry and delivers initial-prompt via nudge"
    (let [uuid "idem-nudge-0000-0000-0000-000000000000"
          existing-desc {:tmux-session "assist"
                         :tmux-window "hi-agent-idemnud"
                         :provider :claude
                         :workdir "/home/user/assist"
                         :started-at "2026-01-01T00:00:00Z"}
          new-window-calls (atom [])
          send-keys-calls (atom [])
          invoker (fn [& args]
                    (when (some #{"new-window"} args)
                      (swap! new-window-calls conj (vec args)))
                    (when (some #{"send-keys"} args)
                      (swap! send-keys-calls conj (vec args)))
                    {:exit 0 :out "" :err ""})]
      (binding [tmux/*tmux-invoker* invoker]
        (reset! tmux/live-windows {uuid existing-desc})
        (with-redefs [voice-code.providers/cli-path (constantly "/usr/bin/claude")
                      voice-code.providers/session-metadata (constantly nil)]
          (tmux/start-window! {:session-uuid uuid
                               :session-name "hi-agent"
                               :provider :claude
                               :workdir "/home/user/assist"
                               :initial-prompt "hello from iOS"}))
        (is (empty? @new-window-calls)
            "must not spawn a new window when one exists")
        (is (some #(some #{"hello from iOS"} %) @send-keys-calls)
            "must nudge initial-prompt to the existing window")))))

(deftest start-window!-idempotent-tmux-scan-test
  (testing "discovers CLI-created window via scan and reuses it without spawning a duplicate"
    ;; Simulates the fluid-switching bug: tmux-agent created the window so live-windows
    ;; is empty, but scan-window-for-uuid! finds it in tmux. start-window! must reuse
    ;; the window instead of calling new-window.
    (let [uuid "idem-scan-0000-0000-0000-000000000000"
          new-window-calls (atom [])
          send-keys-calls (atom [])
          invoker (fn [& args]
                    (when (some #{"new-window"} args)
                      (swap! new-window-calls conj (vec args)))
                    (when (some #{"send-keys"} args)
                      (swap! send-keys-calls conj (vec args)))
                    (cond
                      (some #{"list-sessions"} args) {:exit 0 :out "assist\n" :err ""}
                      (some #{"list-windows"} args) {:exit 0 :out "hi-agent-idemsc\n" :err ""}
                      (some #{"show-environment"} args)
                      {:exit 0
                       :out (str "VC_SESSION_UUID_hi_agent_idemsc=" uuid "\n"
                                 "VC_PROVIDER_hi_agent_idemsc=claude\n"
                                 "VC_WORKDIR_hi_agent_idemsc=/home/user/assist\n"
                                 "VC_STARTED_AT_hi_agent_idemsc=2026-01-01T00:00:00Z\n")
                       :err ""}
                      :else {:exit 0 :out "" :err ""}))]
      (binding [tmux/*tmux-invoker* invoker]
        (reset! tmux/live-windows {})
        (with-redefs [voice-code.providers/cli-path (constantly "/usr/bin/claude")
                      voice-code.providers/session-metadata (constantly nil)]
          (let [result (tmux/start-window! {:session-uuid uuid
                                            :session-name "hi-agent"
                                            :provider :claude
                                            :workdir "/home/user/assist"
                                            :initial-prompt "hello from iOS"})]
            (is (empty? @new-window-calls)
                "must not spawn a new tmux window when CLI-created window exists")
            (is (= "hi-agent-idemsc" (:tmux-window result))
                "must return the CLI-created window name, not compute a new one")
            (is (= "assist" (:tmux-session result)))
            (is (some #(some #{"hello from iOS"} %) @send-keys-calls)
                "must nudge initial-prompt to the discovered window")
            (is (contains? @tmux/live-windows uuid)
                "must backfill live-windows after scan discovery"))))))

  (testing "still creates new window when scan finds nothing"
    (let [uuid "idem-new-00000-0000-0000-000000000000"
          new-window-calls (atom [])
          invoker (fn [& args]
                    (when (some #{"new-window"} args)
                      (swap! new-window-calls conj (vec args)))
                    (cond
                      (some #{"has-session"} args) {:exit 0 :out "" :err ""}
                      (some #{"list-sessions"} args) {:exit 0 :out "" :err ""}
                      (some #{"list-windows"} args) {:exit 0 :out "_holder\n" :err ""}
                      (some #{"show-environment"} args) {:exit 0 :out "" :err ""}
                      (some #{"capture-pane"} args) {:exit 0 :out "bypass permissions" :err ""}
                      :else {:exit 0 :out "" :err ""}))]
      (binding [tmux/*tmux-invoker* invoker]
        (reset! tmux/live-windows {})
        (with-redefs [voice-code.providers/cli-path (constantly "/usr/bin/claude")
                      voice-code.providers/session-metadata (constantly nil)]
          (tmux/start-window! {:session-uuid uuid
                               :session-name "fresh"
                               :provider :claude
                               :workdir "/tmp/fresh"}))
        (is (seq @new-window-calls)
            "must create a new window when no existing window is found")))))

(deftest start-window!-timeout-test
  (testing "throws ex-info when wait-for-ready times out, and does not nudge"
    (let [uuid "ffffffff-0000-0000-0000-000000000000"
          nudge-send-keys (atom [])
          invoker (fn [& args]
                    ;; Track literal send-keys (prompt nudges) specifically
                    (when (and (some #{"send-keys"} args) (some #{"-l"} args))
                      (swap! nudge-send-keys conj (vec args)))
                    (cond
                      (some #{"has-session"} args) {:exit 0 :out "" :err ""}
                      (some #{"list-windows"} args) {:exit 0 :out "_holder\n" :err ""}
                      (some #{"show-environment"} args) {:exit 0 :out "" :err ""}
                      ;; capture-pane: never shows readiness string — always blank
                      (some #{"capture-pane"} args) {:exit 0 :out "" :err ""}
                      :else {:exit 0 :out "" :err ""}))]
      (binding [tmux/*tmux-invoker* invoker]
        (reset! tmux/live-windows {})
        (with-redefs [voice-code.providers/cli-path (constantly "/usr/bin/claude")
                      voice-code.providers/session-metadata (constantly nil)
                      ;; Short-circuit the 20s production default so tests
                      ;; exercise the timeout path quickly.
                      tmux/wait-for-ready (fn [& _] :timeout)]
          (let [thrown (try
                         (tmux/start-window! {:session-uuid uuid
                                              :session-name "Test"
                                              :provider :claude
                                              :workdir "/tmp/proj"
                                              :initial-prompt "Do the thing"})
                         nil
                         (catch clojure.lang.ExceptionInfo e e))]
            (is (some? thrown) "expected start-window! to throw on readiness timeout")
            (is (= :wait-for-ready-timeout (:kind (ex-data thrown)))
                "ex-info should be tagged with :kind :wait-for-ready-timeout")
            (is (= uuid (:session-uuid (ex-data thrown))))
            (is (= :claude (:provider (ex-data thrown)))))
          (is (empty? @nudge-send-keys)
              "initial-prompt must not be nudged when TUI readiness times out"))))))

;; ============================================================================
;; start-ephemeral-window! (ghost forks)
;; ============================================================================

(deftest ghost-tmux-session-test
  (testing "the ghost fork session constant is vc-ghost"
    (is (= "vc-ghost" tmux/ghost-tmux-session))))

(deftest start-ephemeral-window!-test
  (testing "creates new-window in the vc-ghost session, nudges prompt, returns descriptor"
    (let [calls (atom [])
          invoker (fn [& args]
                    (swap! calls conj (vec args))
                    (cond
                      (some #{"has-session"} args) {:exit 0 :out "" :err ""}
                      ;; capture-pane: readiness string present immediately
                      (some #{"capture-pane"} args) {:exit 0 :out "bypass permissions" :err ""}
                      :else {:exit 0 :out "" :err ""}))]
      (binding [tmux/*tmux-invoker* invoker]
        (reset! tmux/live-windows {})
        (let [result (tmux/start-ephemeral-window!
                      {:window "ghost-gp-abc123abc123"
                       :provider :claude
                       :workdir "/tmp/proj"
                       :cmd "claude --resume S-1 --fork-session"
                       :prompt "META PROMPT"})
              recorded @calls
              new-window-call (first (filter #(some #{"new-window"} %) recorded))]
          (is (= {:tmux-session "vc-ghost" :tmux-window "ghost-gp-abc123abc123"} result))
          (is (some? new-window-call) "expected a new-window call")
          (is (some #{"=vc-ghost:"} new-window-call)
              "new-window must target the vc-ghost session")
          (is (some #{"ghost-gp-abc123abc123"} new-window-call)
              "new-window must use the supplied window name")
          (is (some #{"/tmp/proj"} new-window-call)
              "new-window must set the workdir with -c")
          (is (some #{"claude --resume S-1 --fork-session"} new-window-call)
              "new-window must launch the supplied cmd")
          (is (some #(and (some #{"send-keys"} %) (some #{"META PROMPT"} %)) recorded)
              "prompt must be nudged when the TUI becomes ready")))))

  (testing "registers NO live-windows entry"
    (let [invoker (fn [& args]
                    (cond
                      (some #{"has-session"} args) {:exit 0 :out "" :err ""}
                      (some #{"capture-pane"} args) {:exit 0 :out "bypass permissions" :err ""}
                      :else {:exit 0 :out "" :err ""}))]
      (binding [tmux/*tmux-invoker* invoker]
        (reset! tmux/live-windows {})
        (tmux/start-ephemeral-window!
         {:window "ghost-gp-deadbeef0001"
          :provider :claude
          :workdir "/tmp/proj"
          :cmd "claude --resume S-2 --fork-session"
          :prompt "META PROMPT"})
        (is (empty? @tmux/live-windows)
            "ephemeral fork window must not be registered in live-windows"))))

  (testing "sets NO VC_ env (no set-environment) so the fork is invisible to eviction"
    (let [calls (atom [])
          invoker (fn [& args]
                    (swap! calls conj (vec args))
                    (cond
                      (some #{"has-session"} args) {:exit 0 :out "" :err ""}
                      (some #{"capture-pane"} args) {:exit 0 :out "bypass permissions" :err ""}
                      :else {:exit 0 :out "" :err ""}))]
      (binding [tmux/*tmux-invoker* invoker]
        (reset! tmux/live-windows {})
        (tmux/start-ephemeral-window!
         {:window "ghost-gp-cafef00d0002"
          :provider :claude
          :workdir "/tmp/proj"
          :cmd "claude --resume S-3 --fork-session"
          :prompt "META PROMPT"})
        (is (not (some #(some #{"set-environment"} %) @calls))
            "no VC_ env may be written for an ephemeral fork window"))))

  (testing "does not nudge when no prompt supplied"
    (let [nudge-send-keys (atom [])
          invoker (fn [& args]
                    (when (and (some #{"send-keys"} args) (some #{"-l"} args))
                      (swap! nudge-send-keys conj (vec args)))
                    (cond
                      (some #{"has-session"} args) {:exit 0 :out "" :err ""}
                      (some #{"capture-pane"} args) {:exit 0 :out "bypass permissions" :err ""}
                      :else {:exit 0 :out "" :err ""}))]
      (binding [tmux/*tmux-invoker* invoker]
        (reset! tmux/live-windows {})
        (tmux/start-ephemeral-window!
         {:window "ghost-gp-0badf00d0003"
          :provider :claude
          :workdir "/tmp/proj"
          :cmd "claude --resume S-4 --fork-session"
          :prompt nil})
        (is (empty? @nudge-send-keys)
            "no nudge when prompt is nil"))))

  (testing "on readiness timeout: kills the window and throws :wait-for-ready-timeout, without nudging"
    (let [kill-calls (atom [])
          nudge-send-keys (atom [])
          invoker (fn [& args]
                    (when (some #{"kill-window"} args)
                      (swap! kill-calls conj (vec args)))
                    (when (and (some #{"send-keys"} args) (some #{"-l"} args))
                      (swap! nudge-send-keys conj (vec args)))
                    (cond
                      (some #{"has-session"} args) {:exit 0 :out "" :err ""}
                      :else {:exit 0 :out "" :err ""}))]
      (binding [tmux/*tmux-invoker* invoker]
        (reset! tmux/live-windows {})
        ;; Short-circuit the 20s production default so the timeout path runs fast.
        (with-redefs [tmux/wait-for-ready (fn [& _] :timeout)]
          (let [thrown (try
                         (tmux/start-ephemeral-window!
                          {:window "ghost-gp-feedface0004"
                           :provider :claude
                           :workdir "/tmp/proj"
                           :cmd "claude --resume S-5 --fork-session"
                           :prompt "META PROMPT"})
                         nil
                         (catch clojure.lang.ExceptionInfo e e))]
            (is (some? thrown) "expected throw on readiness timeout")
            (is (= :wait-for-ready-timeout (:kind (ex-data thrown))))
            (is (= "ghost-gp-feedface0004" (:window (ex-data thrown))))
            (is (= "vc-ghost" (:tmux-session (ex-data thrown))))
            (is (= :claude (:provider (ex-data thrown))))
            (let [kill-call (first @kill-calls)]
              (is (some? kill-call) "the window must be killed on timeout")
              (is (some #{"=vc-ghost:=ghost-gp-feedface0004"} kill-call)
                  "kill-window must target the ghost fork window"))
            (is (empty? @nudge-send-keys)
                "prompt must not be nudged when readiness times out")
            (is (empty? @tmux/live-windows)
                "no live-windows entry even on the timeout path")))))))

(deftest wait-for-ready-default-timeout-test
  (testing "default :timeout-ms is the 20s production constant, not 3s"
    ;; Regression guard for tmux-untethered-8vb: a 3s default silently dropped
    ;; the initial prompt when Claude's MCP/config resolution ran long.
    (is (= 20000 tmux/wait-for-ready-default-timeout-ms)
        "production default must stay generous; lowering it re-opens the hang bug")))

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
                {old-uuid {:tmux-session "proj" :tmux-window "old-win" :provider :claude :workdir "/tmp"}
                 recent-uuid {:tmux-session "proj" :tmux-window "recent-win" :provider :claude :workdir "/tmp"}})
        (with-redefs [voice-code.providers/session-metadata
                      (fn [uuid]
                        (cond
                          (= uuid old-uuid) {:last-modified-ms old-ms}
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
;; scan-window-for-uuid!
;; ============================================================================

(deftest scan-window-for-uuid!-test
  (testing "finds window and backfills live-windows when UUID exists in a live window"
    (let [uuid "scanuuid-1111-0000-0000-000000000000"
          invoker (fn [& args]
                    (cond
                      (some #{"list-sessions"} args) {:exit 0 :out "my-session\n" :err ""}
                      (some #{"show-environment"} args)
                      {:exit 0
                       :out (str "VC_SESSION_UUID_my_agent=" uuid "\n"
                                 "VC_PROVIDER_my_agent=claude\n"
                                 "VC_WORKDIR_my_agent=/tmp/proj\n"
                                 "VC_STARTED_AT_my_agent=2026-01-01T00:00:00Z\n")
                       :err ""}
                      (some #{"list-windows"} args) {:exit 0 :out "my-agent\n" :err ""}
                      :else {:exit 0 :out "" :err ""}))]
      (binding [tmux/*tmux-invoker* invoker]
        (reset! tmux/live-windows {})
        (let [desc (#'tmux/scan-window-for-uuid! uuid)]
          (is (some? desc) "should return descriptor when window found")
          (is (= "my-session" (:tmux-session desc)))
          (is (= "my-agent" (:tmux-window desc)))
          (is (= :claude (:provider desc)))
          (is (= "/tmp/proj" (:workdir desc)))
          (is (contains? @tmux/live-windows uuid) "should backfill live-windows")))))

  (testing "returns nil when window does not actually exist (stale env var)"
    (let [uuid "scanuuid-2222-0000-0000-000000000000"
          invoker (fn [& args]
                    (cond
                      (some #{"list-sessions"} args) {:exit 0 :out "my-session\n" :err ""}
                      (some #{"show-environment"} args)
                      {:exit 0
                       :out (str "VC_SESSION_UUID_dead_window=" uuid "\n")
                       :err ""}
                      ;; list-windows returns _holder only — dead_window is gone
                      (some #{"list-windows"} args) {:exit 0 :out "_holder\n" :err ""}
                      :else {:exit 0 :out "" :err ""}))]
      (binding [tmux/*tmux-invoker* invoker]
        (reset! tmux/live-windows {})
        (is (nil? (#'tmux/scan-window-for-uuid! uuid))
            "should return nil when env var exists but window is gone"))))

  (testing "returns nil when UUID not found in any session"
    (let [invoker (fn [& args]
                    (cond
                      (some #{"list-sessions"} args) {:exit 0 :out "my-session\n" :err ""}
                      (some #{"show-environment"} args)
                      {:exit 0 :out "VC_SESSION_UUID_other=different-uuid\n" :err ""}
                      (some #{"list-windows"} args) {:exit 0 :out "other\n" :err ""}
                      :else {:exit 0 :out "" :err ""}))]
      (binding [tmux/*tmux-invoker* invoker]
        (reset! tmux/live-windows {})
        (is (nil? (#'tmux/scan-window-for-uuid! "missing-uuid-000-000-000-000000000000")))))))

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
      (is (some #(= "/tmp/special-dir" %) @new-window-args)
          "expected working directory from metadata to be used in new-window")))

  (testing "stale live-windows entry: nudge failure triggers eviction and respawn"
    (let [uuid "stale-uuid-0000-0000-0000-000000000000"
          new-window-args (atom nil)
          invoker (fn [& args]
                    (when (some #{"new-window"} args)
                      (reset! new-window-args (vec args)))
                    (cond
                      ;; send-keys to the dead window all fail
                      (some #{"send-keys"} args) {:exit 1 :out "" :err "can't find window"}
                      (some #{"has-session"} args) {:exit 0 :out "" :err ""}
                      (some #{"list-windows"} args) {:exit 0 :out "_holder\n" :err ""}
                      (some #{"show-environment"} args) {:exit 0 :out "" :err ""}
                      (some #{"capture-pane"} args) {:exit 0 :out "bypass permissions" :err ""}
                      :else {:exit 0 :out "" :err ""}))]
      (binding [tmux/*tmux-invoker* invoker]
        (reset! tmux/live-windows
                {uuid {:tmux-session "dead-session"
                       :tmux-window "dead-window"
                       :provider :claude
                       :workdir "/tmp/stale"}})
        (with-redefs [voice-code.providers/cli-path (constantly "/usr/bin/claude")
                      voice-code.providers/session-metadata
                      (constantly {:provider :claude
                                   :working-directory "/tmp/stale"
                                   :name "Stale Session"})]
          (tmux/deliver! uuid "recover me")))
      (is (not= "dead-window" (:tmux-window (get @tmux/live-windows uuid)))
          "stale window name must be replaced after nudge failure and respawn")
      (is (some? @new-window-args)
          "respawn must be attempted after nudge failure")
      (is (some #(clojure.string/includes? (str %) "--resume") @new-window-args)
          "respawn must use --resume")))

  (testing "lazy-backfill: nudges CLI-created window found via tmux scan when not in live-windows"
    ;; Simulates the fluid-switching scenario: a window was created by tmux-agent CLI
    ;; after the server started, so it is not in the server's live-windows. deliver!
    ;; should discover it via scan-window-for-uuid! and nudge it rather than respawning.
    (let [uuid "cli-created-0000-0000-0000-000000000000"
          send-keys-calls (atom [])
          new-window-calls (atom [])
          invoker (fn [& args]
                    (when (some #{"send-keys"} args) (swap! send-keys-calls conj (vec args)))
                    (when (some #{"new-window"} args) (swap! new-window-calls conj (vec args)))
                    (cond
                      (some #{"list-sessions"} args) {:exit 0 :out "my-session\n" :err ""}
                      (some #{"show-environment"} args)
                      {:exit 0
                       :out (str "VC_SESSION_UUID_cli_agent=" uuid "\n"
                                 "VC_PROVIDER_cli_agent=claude\n"
                                 "VC_WORKDIR_cli_agent=/tmp/cli\n"
                                 "VC_STARTED_AT_cli_agent=2026-01-01T00:00:00Z\n")
                       :err ""}
                      (some #{"list-windows"} args) {:exit 0 :out "cli-agent\n" :err ""}
                      :else {:exit 0 :out "" :err ""}))]
      (binding [tmux/*tmux-invoker* invoker]
        (reset! tmux/live-windows {})
        (tmux/deliver! uuid "hello from server"))
      (is (empty? @new-window-calls) "should NOT spawn a new window")
      (is (some #(some #{"hello from server"} %) @send-keys-calls)
          "should nudge the existing CLI-created window"))))

;; ============================================================================
;; capture-pane
;; ============================================================================

(deftest capture-pane-test
  (testing "returns output when pane exists (exit 0)"
    (let [invoker (fn [& args]
                    (if (some #{"capture-pane"} args)
                      {:exit 0 :out "some pane output\n" :err ""}
                      {:exit 0 :out "" :err ""}))]
      (binding [tmux/*tmux-invoker* invoker]
        (is (= "some pane output\n"
               (tmux/capture-pane "my-session" "my-window"))))))

  (testing "returns nil when pane doesn't exist (non-zero exit)"
    (let [invoker (fn [& _args]
                    {:exit 1 :out "" :err "can't find window"})]
      (binding [tmux/*tmux-invoker* invoker]
        (is (nil? (tmux/capture-pane "no-session" "no-window"))))))

  (testing "passes -S with negated lines count"
    (let [captured-args (atom nil)
          invoker (fn [& args]
                    (when (some #{"capture-pane"} args)
                      (reset! captured-args (vec args)))
                    {:exit 0 :out "" :err ""})]
      (binding [tmux/*tmux-invoker* invoker]
        (tmux/capture-pane "sess" "win" :lines 100))
      (is (some #(= "-100" %) @captured-args)
          "expected -S -100 in args")))

  (testing "uses correct target format"
    (let [captured-args (atom nil)
          invoker (fn [& args]
                    (when (some #{"capture-pane"} args)
                      (reset! captured-args (vec args)))
                    {:exit 0 :out "" :err ""})]
      (binding [tmux/*tmux-invoker* invoker]
        (tmux/capture-pane "my-session" "my-window"))
      (is (some #(= "=my-session:=my-window.0" %) @captured-args)
          "expected correct target address"))))

;; ============================================================================
;; pane-command
;; ============================================================================

(deftest pane-command-test
  (testing "returns trimmed command name when pane exists"
    (let [invoker (fn [& _args]
                    {:exit 0 :out "node\n" :err ""})]
      (binding [tmux/*tmux-invoker* invoker]
        (is (= "node" (tmux/pane-command "sess" "win"))))))

  (testing "returns nil when display-message fails (non-zero exit)"
    (let [invoker (fn [& _args]
                    {:exit 1 :out "" :err "no such window"})]
      (binding [tmux/*tmux-invoker* invoker]
        (is (nil? (tmux/pane-command "sess" "win"))))))

  (testing "trims whitespace from output"
    (let [invoker (fn [& _args]
                    {:exit 0 :out "  bash  \n" :err ""})]
      (binding [tmux/*tmux-invoker* invoker]
        (is (= "bash" (tmux/pane-command "sess" "win")))))))

;; ============================================================================
;; agent-status
;; ============================================================================

(deftest agent-status-test
  (testing "returns :running when pane command is 'node'"
    (let [invoker (fn [& _args] {:exit 0 :out "node\n" :err ""})]
      (binding [tmux/*tmux-invoker* invoker]
        (is (= :running (tmux/agent-status "sess" "win"))))))

  (testing "returns :running when pane command is 'claude'"
    (let [invoker (fn [& _args] {:exit 0 :out "claude\n" :err ""})]
      (binding [tmux/*tmux-invoker* invoker]
        (is (= :running (tmux/agent-status "sess" "win"))))))

  (testing "returns :running when pane command matches semver pattern"
    (let [invoker (fn [& _args] {:exit 0 :out "1.2.3\n" :err ""})]
      (binding [tmux/*tmux-invoker* invoker]
        (is (= :running (tmux/agent-status "sess" "win"))))))

  (testing "returns :idle when pane command is 'bash'"
    (let [invoker (fn [& _args] {:exit 0 :out "bash\n" :err ""})]
      (binding [tmux/*tmux-invoker* invoker]
        (is (= :idle (tmux/agent-status "sess" "win"))))))

  (testing "returns :dead when display-message fails"
    (let [invoker (fn [& _args] {:exit 1 :out "" :err "no such window"})]
      (binding [tmux/*tmux-invoker* invoker]
        (is (= :dead (tmux/agent-status "sess" "win")))))))

;; ============================================================================
;; resolve-agent
;; ============================================================================

(deftest resolve-agent-test
  (testing "finds by exact session-uuid"
    (let [uuid "aaaaaaaa-0000-0000-0000-000000000000"
          desc {:tmux-session "sess" :tmux-window "myagent-aaaaaa" :provider :claude}]
      (reset! tmux/live-windows {uuid desc})
      (is (= [uuid desc] (tmux/resolve-agent uuid)))))

  (testing "finds by exact window name"
    (let [uuid "bbbbbbbb-0000-0000-0000-000000000000"
          desc {:tmux-session "sess" :tmux-window "myagent-bbbbbb" :provider :claude}]
      (reset! tmux/live-windows {uuid desc})
      (is (= [uuid desc] (tmux/resolve-agent "myagent-bbbbbb")))))

  (testing "finds by window-name prefix (name without UUID suffix)"
    (let [uuid "cccccccc-0000-0000-0000-000000000000"
          desc {:tmux-session "sess" :tmux-window "myagent-cccccc" :provider :claude}]
      (reset! tmux/live-windows {uuid desc})
      ;; "myagent" is a prefix of "myagent-cccccc"
      (is (= [uuid desc] (tmux/resolve-agent "myagent")))))

  (testing "returns nil when no match found"
    (reset! tmux/live-windows {})
    (is (nil? (tmux/resolve-agent "nonexistent"))))

  (testing "throws ex-info with :kind :ambiguous when prefix matches multiple windows"
    (let [uuid1 "dddddddd-0000-0000-0000-000000000000"
          uuid2 "eeeeeeee-0000-0000-0000-000000000000"
          desc1 {:tmux-session "sess" :tmux-window "proj-ddd111" :provider :claude}
          desc2 {:tmux-session "sess" :tmux-window "proj-eee222" :provider :claude}]
      (reset! tmux/live-windows {uuid1 desc1 uuid2 desc2})
      (let [thrown (try
                     (tmux/resolve-agent "proj")
                     nil
                     (catch clojure.lang.ExceptionInfo e e))]
        (is (some? thrown))
        (is (= :ambiguous (:kind (ex-data thrown)))))))

  (testing "session-uuid lookup takes priority over window-name lookup"
    (let [uuid "ffffffff-0000-0000-0000-000000000000"
          desc {:tmux-session "sess" :tmux-window "some-window-ffffff" :provider :claude}]
      (reset! tmux/live-windows {uuid desc})
      (is (= [uuid desc] (tmux/resolve-agent uuid)))))

  (testing "finds by UUID prefix"
    (let [uuid "1a2b3c4d-5e6f-0000-0000-000000000000"
          desc {:tmux-session "sess" :tmux-window "myagent-1a2b3c" :provider :claude}]
      (reset! tmux/live-windows {uuid desc})
      (is (= [uuid desc] (tmux/resolve-agent "1a2b3c4d")))
      (is (= [uuid desc] (tmux/resolve-agent "1a2b3c4d-5e6f")))))

  (testing "throws :ambiguous when UUID prefix matches multiple sessions"
    (let [uuid1 "aabbccdd-1111-0000-0000-000000000000"
          uuid2 "aabbccdd-2222-0000-0000-000000000000"
          desc1 {:tmux-session "sess" :tmux-window "proj1-aabbcc" :provider :claude}
          desc2 {:tmux-session "sess" :tmux-window "proj2-aabbcc" :provider :claude}]
      (reset! tmux/live-windows {uuid1 desc1 uuid2 desc2})
      (let [thrown (try
                     (tmux/resolve-agent "aabbccdd")
                     nil
                     (catch clojure.lang.ExceptionInfo e e))]
        (is (some? thrown))
        (is (= :ambiguous (:kind (ex-data thrown)))))))

  (testing "UUID prefix does not match unrelated UUIDs"
    (let [uuid "11223344-0000-0000-0000-000000000000"
          desc {:tmux-session "sess" :tmux-window "agent-112233" :provider :claude}]
      (reset! tmux/live-windows {uuid desc})
      (is (nil? (tmux/resolve-agent "99887766"))))))

;; ============================================================================
;; build-provider-command with :model
;; ============================================================================

(deftest build-provider-command-model-test
  (testing "claude includes --model flag when model is provided"
    (with-redefs [voice-code.providers/cli-path (constantly "/usr/local/bin/claude")]
      (let [cmd (tmux/build-provider-command :claude {:session-uuid "abc123"
                                                       :resume? false
                                                       :model "claude-opus-4-5"})]
        (is (clojure.string/includes? cmd "--model claude-opus-4-5")))))

  (testing "claude omits --model when model is nil"
    (with-redefs [voice-code.providers/cli-path (constantly "/usr/local/bin/claude")]
      (let [cmd (tmux/build-provider-command :claude {:session-uuid "abc123"
                                                       :resume? false
                                                       :model nil})]
        (is (not (clojure.string/includes? cmd "--model"))))))

  (testing "claude --model appears after other flags"
    (with-redefs [voice-code.providers/cli-path (constantly "/usr/local/bin/claude")]
      (let [cmd (tmux/build-provider-command :claude {:session-uuid "abc123"
                                                       :resume? false
                                                       :system-prompt "Be concise"
                                                       :model "claude-haiku-4-5"})]
        (is (clojure.string/includes? cmd "--append-system-prompt"))
        (is (clojure.string/includes? cmd "--model claude-haiku-4-5")))))

  (testing "claude resume also includes --model when provided"
    (with-redefs [voice-code.providers/cli-path (constantly "/usr/local/bin/claude")]
      (let [cmd (tmux/build-provider-command :claude {:session-uuid "abc123"
                                                       :resume? true
                                                       :model "claude-sonnet-4-5"})]
        (is (clojure.string/includes? cmd "--resume abc123"))
        (is (clojure.string/includes? cmd "--model claude-sonnet-4-5"))))))
