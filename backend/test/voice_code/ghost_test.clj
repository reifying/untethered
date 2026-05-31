(ns voice-code.ghost-test
  "Tests for voice-code.ghost. The pure helpers (gen-nonce, markers,
   build-meta-prompt, extract-prompt) need no tmux server or filesystem. The
   one-shot-fork! lifecycle tests mock tmux (start-ephemeral-window!,
   kill-window!) and the fork-file resolution so no real fork is spawned, and
   use a temp .jsonl to prove the fork transcript is left intact (AC8)."
  (:require [clojure.test :refer [deftest is testing]]
            [clojure.java.io :as io]
            [clojure.string :as str]
            [cheshire.core :as json]
            [voice-code.ghost :as ghost]
            [voice-code.replication :as repl]
            [voice-code.tmux :as tmux]))

;; ============================================================================
;; gen-nonce
;; ============================================================================

(deftest gen-nonce-test
  (testing "format is \"gp-\" + 12 lowercase hex digits"
    (dotimes [_ 50]
      (let [n (ghost/gen-nonce)]
        (is (re-matches #"gp-[0-9a-f]{12}" n)
            (str "nonce did not match gp-<12 hex>: " n)))))
  (testing "nonces are unique across many invocations"
    (let [nonces (repeatedly 1000 ghost/gen-nonce)]
      (is (= 1000 (count (distinct nonces)))))))

;; ============================================================================
;; begin-marker / end-marker
;; ============================================================================

(deftest marker-test
  (testing "sentinels embed the nonce in the documented ASCII shape"
    (let [n "gp-abc123abc123"]
      (is (= "===GHOST-BEGIN:gp-abc123abc123===" (ghost/begin-marker n)))
      (is (= "===GHOST-END:gp-abc123abc123===" (ghost/end-marker n)))))
  (testing "begin and end markers are distinct"
    (let [n (ghost/gen-nonce)]
      (is (not= (ghost/begin-marker n) (ghost/end-marker n))))))

;; ============================================================================
;; build-meta-prompt
;; ============================================================================

(deftest build-meta-prompt-test
  (testing "carries marker, nonce, task, and both sentinels on one line"
    (let [n "gp-deadbeef0001"
          p (ghost/build-meta-prompt "add a /healthz endpoint" n)]
      (is (str/includes? p repl/ghost-fork-marker))
      (is (str/includes? p n))
      (is (str/includes? p "add a /healthz endpoint"))
      (is (str/includes? p (ghost/begin-marker n)))
      (is (str/includes? p (ghost/end-marker n)))
      (is (not (str/includes? p "\n"))
          "meta-prompt must be a single physical line for nudge delivery")))
  (testing "a multi-line / whitespace-laden task is collapsed to a single line"
    (let [n "gp-deadbeef0001"
          p (ghost/build-meta-prompt "line one\nline two\tindented   spaced" n)]
      (is (not (str/includes? p "\n"))
          "newlines in the task must not survive into the meta-prompt")
      (is (not (str/includes? p "\t")))
      (is (str/includes? p "line one line two indented spaced")
          "internal whitespace runs collapse to single spaces")))
  (testing "a nil task does not throw and yields a single line"
    (let [n "gp-deadbeef0001"
          p (ghost/build-meta-prompt nil n)]
      (is (string? p))
      (is (not (str/includes? p "\n"))))))

;; ============================================================================
;; extract-prompt
;; ============================================================================

(deftest extract-prompt-test
  (testing "extracts between sentinels and strips preamble"
    (let [n "gp-abc123abc123"
          txt (str "Let me write a prompt.\n"
                   "===GHOST-BEGIN:" n "===\n"
                   "Add a /healthz endpoint that returns 200.\n"
                   "===GHOST-END:" n "===")]
      (is (= "Add a /healthz endpoint that returns 200."
             (ghost/extract-prompt txt n)))))
  (testing "preserves multi-line prompt body between the sentinels"
    (let [n "gp-abc123abc123"
          txt (str (ghost/begin-marker n) "\n"
                   "Line one.\nLine two.\n"
                   (ghost/end-marker n))]
      (is (= "Line one.\nLine two." (ghost/extract-prompt txt n)))))
  (testing "uses the first BEGIN and the first END after it"
    (let [n "gp-abc123abc123"
          txt (str (ghost/begin-marker n) "\n"
                   "keep this\n"
                   (ghost/end-marker n) "\n"
                   "and ignore the second block\n"
                   (ghost/begin-marker n) "\n"
                   "discard\n"
                   (ghost/end-marker n))]
      (is (= "keep this" (ghost/extract-prompt txt n)))))
  (testing "missing closing sentinel -> nil"
    (let [n "gp-abc123abc123"]
      (is (nil? (ghost/extract-prompt (str "===GHOST-BEGIN:" n "===\nhalf") n)))))
  (testing "missing opening sentinel -> nil"
    (let [n "gp-abc123abc123"]
      (is (nil? (ghost/extract-prompt (str "no markers here\n===GHOST-END:" n "===") n)))))
  (testing "blank body -> nil"
    (let [n "gp-abc123abc123"]
      (is (nil? (ghost/extract-prompt
                 (str "===GHOST-BEGIN:" n "===\n   \n===GHOST-END:" n "===") n)))))
  (testing "nil assistant-text -> nil (no throw)"
    (is (nil? (ghost/extract-prompt nil "gp-abc123abc123"))))
  (testing "extracting build-meta-prompt's own nonce against the model's wrapped reply"
    (let [n (ghost/gen-nonce)
          reply (str "Sure, here it is.\n"
                     (ghost/begin-marker n) "\n"
                     "Refactor the auth module.\n"
                     (ghost/end-marker n))]
      (is (= "Refactor the auth module." (ghost/extract-prompt reply n))))))

;; ============================================================================
;; find-fork-file (private — newest-first content-addressed resolution)
;; ============================================================================

(deftest find-fork-file-test
  (testing "returns the NEWEST .jsonl whose contents include the nonce, skipping non-matching files"
    (let [n "gp-findforknonce"
          dir (java.io.File/createTempFile "ghost-find" "")
          _ (.delete dir)
          _ (.mkdirs dir)
          older (io/file dir "older.jsonl")
          newer (io/file dir "newer.jsonl")
          other (io/file dir "other.jsonl")]
      (try
        (spit older (str "contains " n "\n"))
        (spit newer (str "also contains " n "\n"))
        (spit other "no nonce in this one\n")
        ;; `other` is the newest, but carries no nonce; it must be scanned and skipped.
        (.setLastModified older 1000000)
        (.setLastModified newer 2000000)
        (.setLastModified other 3000000)
        (with-redefs [repl/find-jsonl-files (fn [] [older newer other])]
          (is (= (.getPath newer) (.getPath (#'ghost/find-fork-file n)))
              "newest file containing the nonce wins (non-matching newer file skipped)")
          (is (nil? (#'ghost/find-fork-file "gp-absent000000"))
              "nil when no transcript carries the nonce"))
        (finally
          (.delete older) (.delete newer) (.delete other) (.delete dir))))))

;; ============================================================================
;; one-shot-fork! — fork lifecycle (mocked tmux + temp fs)
;; ============================================================================

(defn- write-fork-transcript!
  "Write a minimal Claude fork .jsonl: a normal first user line, the marked
   meta-prompt as a later human line, and the assistant's reply wrapping the
   generated prompt in the nonce sentinels. Returns the temp File."
  [nonce]
  (let [f (java.io.File/createTempFile "ghost-fork" ".jsonl")
        lines [(json/generate-string {:type "user" :message {:content "hi there"}})
               (json/generate-string {:type "user"
                                      :message {:content (ghost/build-meta-prompt "do X" nonce)}})
               (json/generate-string {:type "assistant"
                                      :message {:content [{:type "text"
                                                           :text (str "Sure, here it is.\n"
                                                                      (ghost/begin-marker nonce) "\n"
                                                                      "Refactor the auth module.\n"
                                                                      (ghost/end-marker nonce))}]}})]]
    (spit f (str (str/join "\n" lines) "\n"))
    f))

(deftest one-shot-fork!-success-leaves-jsonl-intact-test
  (testing "extracts P via the real claude-assistant-text path and leaves the .jsonl intact (AC8)"
    (let [n "gp-deadbeef0001"
          f (write-fork-transcript! n)
          size-before (.length f)]
      (try
        (with-redefs [ghost/poll-interval-ms 1
                      ghost/gen-nonce (constantly n)
                      tmux/start-ephemeral-window!
                      (fn [_] {:tmux-session "vc-ghost" :tmux-window (str "ghost-" n)})
                      tmux/kill-window! (fn [_ _] nil)
                      ghost/find-fork-file (constantly f)]
          (let [r (ghost/one-shot-fork! "S-1" "do X" :workdir "/repo" :timeout-ms 5000)]
            (is (true? (:ok r)))
            (is (= "Refactor the auth module." (:text r)))
            (is (= n (:nonce r)))
            (is (.exists f) "fork transcript still exists after teardown (window killed, file untouched)")
            (is (= size-before (.length f)) "fork transcript bytes unchanged — no mutation (AC8)")))
        (finally (.delete f))))))

(deftest one-shot-fork!-resolves-file-once-then-polls-test
  (testing "fork file resolved exactly once; only that file is re-polled until the sentinel appears"
    (let [n "gp-resolveonce1"
          fork-calls (atom 0)
          text-calls (atom 0)
          file (io/file "/tmp/ghost-resolved.jsonl")]
      (with-redefs [ghost/poll-interval-ms 1
                    ghost/gen-nonce (constantly n)
                    tmux/start-ephemeral-window!
                    (fn [_] {:tmux-session "vc-ghost" :tmux-window (str "ghost-" n)})
                    tmux/kill-window! (fn [_ _] nil)
                    ghost/find-fork-file (fn [_] (swap! fork-calls inc) file)
                    repl/claude-assistant-text
                    (fn [_]
                      (swap! text-calls inc)
                      ;; sentinel only appears on the third poll
                      (when (>= @text-calls 3)
                        (str (ghost/begin-marker n) "\nDo X.\n" (ghost/end-marker n))))]
        (let [r (ghost/one-shot-fork! "S-1" "do X" :workdir "/repo" :timeout-ms 5000)]
          (is (true? (:ok r)))
          (is (= "Do X." (:text r)))
          (is (= 1 @fork-calls) "fork file resolved exactly once (no per-tick dir re-scan)")
          (is (= 3 @text-calls) "only the resolved file is re-polled until the sentinel appears"))))))

(deftest one-shot-fork!-tears-down-window-on-timeout-test
  (testing "window is killed even when the fork transcript never appears (timeout)"
    (let [killed (atom [])]
      (with-redefs [ghost/poll-interval-ms 1
                    tmux/start-ephemeral-window!
                    (fn [_] {:tmux-session "vc-ghost" :tmux-window "ghost-x"})
                    tmux/kill-window! (fn [s w] (swap! killed conj [s w]))
                    ghost/find-fork-file (constantly nil)]
        (let [r (ghost/one-shot-fork! "S-1" "do X" :workdir "/repo" :timeout-ms 5)]
          (is (false? (:ok r)))
          (is (= :timeout (:reason r)))
          (is (= 1 (count @killed)) "ephemeral window killed in finally on timeout")
          (is (= "vc-ghost" (ffirst @killed)) "killed under the dedicated ghost tmux session"))))))

(deftest one-shot-fork!-timeout-when-sentinel-never-appears-test
  (testing "resolved file but closing sentinel never appears -> :timeout, window killed"
    (let [killed (atom [])]
      (with-redefs [ghost/poll-interval-ms 1
                    tmux/start-ephemeral-window!
                    (fn [_] {:tmux-session "vc-ghost" :tmux-window "ghost-x"})
                    tmux/kill-window! (fn [s w] (swap! killed conj [s w]))
                    ghost/find-fork-file (constantly (io/file "/tmp/ghost-no-sentinel.jsonl"))
                    repl/claude-assistant-text (constantly "preamble but no closing sentinel")]
        (let [r (ghost/one-shot-fork! "S-1" "do X" :workdir "/repo" :timeout-ms 5)]
          (is (= :timeout (:reason r)))
          (is (= 1 (count @killed))))))))

(deftest one-shot-fork!-tears-down-window-on-throw-test
  (testing "window killed and guard cleared even when start-ephemeral-window! throws"
    (reset! repl/ghost-fork-guard {})
    (let [killed (atom [])]
      (with-redefs [tmux/start-ephemeral-window! (fn [_] (throw (ex-info "boom" {})))
                    tmux/kill-window! (fn [s w] (swap! killed conj [s w]))
                    ghost/find-fork-file (constantly nil)]
        (let [r (ghost/one-shot-fork! "S-1" "do X" :workdir "/repo" :timeout-ms 5)]
          (is (false? (:ok r)))
          (is (= :error (:reason r)))
          (is (= 1 (count @killed)) "window killed in finally despite the throw")
          (is (not (repl/ghost-guarded? "/repo")) "guard cleared despite the throw"))))))

(deftest one-shot-fork!-registers-guard-before-launch-and-clears-after-test
  (testing "workdir guard is registered BEFORE launch and cleared in finally"
    (reset! repl/ghost-fork-guard {})
    (let [guarded-at-launch (atom nil)]
      (with-redefs [ghost/poll-interval-ms 1
                    tmux/start-ephemeral-window!
                    (fn [_]
                      (reset! guarded-at-launch (repl/ghost-guarded? "/repo"))
                      {:tmux-session "vc-ghost" :tmux-window "ghost-x"})
                    tmux/kill-window! (fn [_ _] nil)
                    ghost/find-fork-file (constantly nil)]
        (ghost/one-shot-fork! "S-1" "do X" :workdir "/repo" :timeout-ms 5)
        (is (true? @guarded-at-launch) "guard already registered when start-ephemeral-window! runs")
        (is (not (repl/ghost-guarded? "/repo")) "guard cleared after one-shot-fork! returns")))))

;; ============================================================================
;; ghost-prompt! — end-to-end orchestration (mocked one-shot-fork! + deliver!)
;; ============================================================================
;; one-shot-fork! is exercised on its own above; here it is redefed so the
;; orchestration logic (provider gate, deliver-on-success, retry-once,
;; deliver-nothing-on-failure, metrics) is tested in isolation.

(deftest ghost-prompt!-unknown-session-test
  (testing "nil session metadata -> :unknown-session, nothing delivered, no metric"
    (let [delivered (atom :NOT-CALLED)
          metrics (atom [])]
      (with-redefs [repl/get-session-metadata (constantly nil)
                    ghost/one-shot-fork! (fn [& _] (throw (ex-info "fork must not run" {})))
                    tmux/deliver! (fn [s t] (reset! delivered [s t]))
                    repl/emit-metric! (fn [t n d] (swap! metrics conj [t n d]))]
        (let [r (ghost/ghost-prompt! "S-unknown" "do X")]
          (is (= {:ok false :reason :unknown-session} r))
          (is (= :NOT-CALLED @delivered) "no prompt delivered for an unknown session")
          (is (empty? @metrics) "no metric emitted on the unknown-session gate"))))))

(deftest ghost-prompt!-unsupported-provider-test
  (testing "non-claude resumed session -> :unsupported-provider, nothing delivered"
    (let [delivered (atom :NOT-CALLED)
          metrics (atom [])]
      (with-redefs [repl/get-session-metadata
                    (constantly {:provider :copilot :working-directory "/repo"})
                    ghost/one-shot-fork! (fn [& _] (throw (ex-info "fork must not run" {})))
                    tmux/deliver! (fn [s t] (reset! delivered [s t]))
                    repl/emit-metric! (fn [t n d] (swap! metrics conj [t n d]))]
        (let [r (ghost/ghost-prompt! "S-cop" "do X")]
          (is (= {:ok false :reason :unsupported-provider} r))
          (is (= :NOT-CALLED @delivered) "no prompt delivered for a non-claude provider")
          (is (empty? @metrics) "no metric emitted on the provider gate"))))))

(deftest ghost-prompt!-success-delivers-P-and-success-metric-test
  (testing "fork ok -> deliver! called with P into the SOURCE session + :ghost.success metric"
    (let [fork-calls (atom 0)
          delivered (atom nil)
          metrics (atom [])]
      (with-redefs [repl/get-session-metadata
                    (constantly {:provider :claude :working-directory "/repo"})
                    ghost/one-shot-fork!
                    (fn [source-id task & {:keys [workdir]}]
                      (swap! fork-calls inc)
                      (is (= "S-ok" source-id) "fork runs against the source session")
                      (is (= "do X" task))
                      (is (= "/repo" workdir) "fork launched in the session's working directory")
                      {:ok true :text "Refactor the auth module." :nonce "gp-ok"})
                    tmux/deliver! (fn [sid txt] (reset! delivered [sid txt]))
                    repl/emit-metric! (fn [t n d] (swap! metrics conj [t n d]))]
        (let [r (ghost/ghost-prompt! "S-ok" "do X")]
          (is (= {:ok true :text "Refactor the auth module."} r))
          (is (= 1 @fork-calls) "no retry on first success")
          (is (= ["S-ok" "Refactor the auth module."] @delivered)
              "extracted P delivered into the ORIGINAL session")
          (is (= [[:counter :ghost.success {:session-id "S-ok"}]] @metrics)
              "exactly the success counter, no failed counter"))))))

(deftest ghost-prompt!-retries-once-then-succeeds-test
  (testing "first fork fails, retry succeeds -> deliver P, success metric, no failed metric"
    (let [fork-calls (atom 0)
          delivered (atom nil)
          metrics (atom [])]
      (with-redefs [repl/get-session-metadata
                    (constantly {:provider :claude :working-directory "/repo"})
                    ghost/one-shot-fork!
                    (fn [& _]
                      (if (= 1 (swap! fork-calls inc))
                        {:ok false :reason :timeout :nonce "gp-1"}
                        {:ok true :text "P-on-retry" :nonce "gp-2"}))
                    tmux/deliver! (fn [sid txt] (reset! delivered [sid txt]))
                    repl/emit-metric! (fn [t n d] (swap! metrics conj [t n d]))]
        (let [r (ghost/ghost-prompt! "S-retry" "do X")]
          (is (= {:ok true :text "P-on-retry"} r))
          (is (= 2 @fork-calls) "forked twice: initial failure + one retry")
          (is (= ["S-retry" "P-on-retry"] @delivered) "P from the successful retry delivered")
          (is (= [[:counter :ghost.success {:session-id "S-retry"}]] @metrics)
              "transient first failure that recovers on retry is NOT counted as failed"))))))

(deftest ghost-prompt!-both-attempts-fail-delivers-nothing-test
  (testing "both fork attempts fail -> NO deliver!, single :ghost.failed metric with reason (AC3)"
    (let [fork-calls (atom 0)
          delivered (atom :NOT-CALLED)
          metrics (atom [])]
      (with-redefs [repl/get-session-metadata
                    (constantly {:provider :claude :working-directory "/repo"})
                    ghost/one-shot-fork!
                    (fn [& _]
                      (swap! fork-calls inc)
                      {:ok false :reason :timeout :nonce "gp-f"})
                    tmux/deliver! (fn [sid txt] (reset! delivered [sid txt]))
                    repl/emit-metric! (fn [t n d] (swap! metrics conj [t n d]))]
        (let [r (ghost/ghost-prompt! "S-fail" "do X")]
          (is (= {:ok false :reason :timeout} r))
          (is (= 2 @fork-calls) "exactly two attempts (initial + one retry)")
          (is (= :NOT-CALLED @delivered) "NOTHING delivered to the source session on failure")
          (is (= [[:counter :ghost.failed {:session-id "S-fail" :reason :timeout}]] @metrics)
              "single failed counter carrying the fork failure reason"))))))

(deftest ghost-prompt!-error-reason-propagates-test
  (testing "fork :error reason (e.g. a throw inside one-shot-fork!) propagates and emits :ghost.failed"
    (let [metrics (atom [])
          delivered (atom :NOT-CALLED)]
      (with-redefs [repl/get-session-metadata
                    (constantly {:provider :claude :working-directory "/repo"})
                    ghost/one-shot-fork! (fn [& _] {:ok false :reason :error :nonce "gp-e"})
                    tmux/deliver! (fn [sid txt] (reset! delivered [sid txt]))
                    repl/emit-metric! (fn [t n d] (swap! metrics conj [t n d]))]
        (let [r (ghost/ghost-prompt! "S-err" "do X")]
          (is (= {:ok false :reason :error} r))
          (is (= :NOT-CALLED @delivered))
          (is (= [[:counter :ghost.failed {:session-id "S-err" :reason :error}]] @metrics)))))))
