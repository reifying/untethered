(ns voice-code.ghost-e2e-test
  "End-to-end integration test for the ghost-prompt feature against a REAL
   Claude CLI (tmux-untethered-5hw.11, design §4 end-to-end).

   Unlike ghost_test.clj (pure helpers + mocked one-shot-fork! lifecycle), this
   test SPAWNS A REAL `claude` process: it seeds a live session, forks it, runs a
   meta-prompt turn on the fork, and delivers the generated prompt back into the
   original session. It therefore costs money and needs a working tmux plus a
   `claude` binary on PATH.

   It is CLI-gated: the test body is a no-op unless the GHOST_E2E env var is set
   (non-blank), so the normal `make backend-test` run skips it. Run it explicitly:

     GHOST_E2E=1 clojure -M:test -n voice-code.ghost-e2e-test

   The env var is read once at namespace load, so an nREPL run (where you can't
   set the var after the JVM started) overrides the gate via with-redefs instead:

     (with-redefs [voice-code.ghost-e2e-test/e2e-enabled? true]
       (clojure.test/run-tests 'voice-code.ghost-e2e-test))

   What it proves (epic AC1, AC5, AC8):
   - A ghost prompt against a real seeded session forks it, has the fork author
     the prompt P, and delivers P to the ORIGINAL session (AC1).
   - The throwaway fork transcript never surfaces in get-all-sessions (AC5).
   - The fork's .jsonl is left intact on disk (AC8)."
  (:require [clojure.test :refer [deftest is testing use-fixtures]]
            [clojure.java.io :as io]
            [clojure.java.shell :as shell]
            [clojure.string :as str]
            [voice-code.ghost :as ghost]
            [voice-code.providers :as providers]
            [voice-code.replication :as repl]
            [voice-code.tmux :as tmux]))

(def e2e-enabled?
  "True when the GHOST_E2E env var is set (non-blank). Gates this money-/CLI-bound
   end-to-end test so the default `make backend-test` run skips it; set GHOST_E2E=1
   to run it for real."
  (boolean (some-> (System/getenv "GHOST_E2E") str/trim not-empty)))

;; ---------------------------------------------------------------------------
;; Helpers (only exercised when e2e-enabled?)
;; ---------------------------------------------------------------------------

(defn- claude-available?
  "True when a `claude` executable resolves; cli-path throws when none is found."
  []
  (try (boolean (providers/cli-path :claude)) (catch Exception _ false)))

(defn- jsonl-for-session
  "Newest .jsonl File on disk whose filename is `session-id`, or nil."
  ^java.io.File [session-id]
  (->> (repl/find-jsonl-files)
       (filter #(= session-id (repl/extract-session-id-from-path %)))
       (sort-by #(- (.lastModified ^java.io.File %)))
       first))

(defn- wait-for
  "Poll thunk `f` every `poll-ms` until it returns truthy or `timeout-ms` elapses.
   Returns the truthy value, or nil on timeout."
  [timeout-ms poll-ms f]
  (let [deadline (+ (System/currentTimeMillis) timeout-ms)]
    (loop []
      (or (f)
          (when (< (System/currentTimeMillis) deadline)
            (Thread/sleep poll-ms)
            (recur))))))

(defn- human-prompt-texts
  "Every human-typed prompt string recorded in the .jsonl at `path`."
  [path]
  (->> (repl/parse-jsonl-file path)
       (filter repl/claude-human-prompt?)
       (map (fn [m]
              (let [c (get-in m [:message :content])]
                (cond
                  (string? c) c
                  (sequential? c) (->> c
                                       (filter #(= "text" (:type %)))
                                       (map :text)
                                       (str/join " "))
                  :else ""))))))

(defn- norm
  "Lowercase + collapse whitespace, for resilient substring matching against text
   that may have been reflowed on its way through the tmux nudge."
  [s]
  (-> (or s "") str/lower-case (str/replace #"\s+" " ") str/trim))

(defn- first-line-fragment
  "A distinctive, normalized fragment of the first non-blank line of `p` (<= 40
   chars). Matching on the first line is robust whether the nudge submitted P as
   one multi-line message or split it at the first newline."
  [p]
  (let [line (or (first (remove str/blank? (str/split-lines (or p "")))) "")]
    (norm (subs line 0 (min 40 (count line))))))

;; ---------------------------------------------------------------------------
;; Fixture: snapshot & restore the global atoms this test mutates so a real run
;; never pollutes the index / live-windows / guard for the rest of the JVM.
;; ---------------------------------------------------------------------------

(defn- with-clean-globals [t]
  (let [idx @repl/session-index
        lw @tmux/live-windows
        guard @repl/ghost-fork-guard]
    (try
      (t)
      (finally
        (reset! repl/session-index idx)
        (reset! tmux/live-windows lw)
        (reset! repl/ghost-fork-guard guard)))))

(use-fixtures :each with-clean-globals)

;; ---------------------------------------------------------------------------
;; The end-to-end test
;; ---------------------------------------------------------------------------

(deftest ^:integration ghost-prompt-end-to-end-test
  (if-not e2e-enabled?
    (println "[ghost-e2e] SKIP — set GHOST_E2E=1 to run (spawns a real claude; costs money).")
    (let [claude? (claude-available?)]
      (is claude? "GHOST_E2E is set but no `claude` binary resolved on PATH")
      (when claude?
        (let [secret (str "ZEBRA-" (subs (str (random-uuid)) 0 8))
              s-uuid (str/lower-case (str (random-uuid)))
              workdir (str (System/getProperty "java.io.tmpdir") "/vc-ghost-e2e-" s-uuid)
              _ (.mkdirs (io/file workdir))
              ;; Snapshot the transcript set before the run so we can isolate the
              ;; fork file this test produces from any pre-existing ghost forks.
              pre-files (set (map #(.getAbsolutePath ^java.io.File %) (repl/find-jsonl-files)))]
          (try
            ;; 1) Seed a real Claude session S with a distinctive fact in context.
            (tmux/start-window!
             {:session-uuid s-uuid
              :session-name "Ghost E2E Source"
              :provider :claude
              :workdir workdir
              :initial-prompt (str "Remember this fact for later: the project's magic password is "
                                   secret ". Reply with just OK.")})

            ;; Wait until S's seeding turn lands on disk (an assistant reply exists).
            (let [s-file (wait-for 90000 1000
                                   (fn []
                                     (when-let [^java.io.File f (jsonl-for-session s-uuid)]
                                       (when (seq (str/trim (repl/claude-assistant-text (.getPath f))))
                                         f))))]
              (is s-file "S transcript with an assistant reply should appear on disk")
              (when s-file
                ;; Seed the index so ghost-prompt! (provider/workdir lookup) and
                ;; deliver! (respawn fallback) can resolve S the way the server would.
                (swap! repl/session-index assoc s-uuid (repl/build-session-metadata s-file))
                (let [s-path (.getPath ^java.io.File s-file)
                      prompts-before (count (human-prompt-texts s-path))
                      ;; 2) Fire the end-to-end ghost prompt.
                      result (ghost/ghost-prompt!
                              s-uuid
                              (str "ask the developer to state the project's magic password "
                                   "that was mentioned earlier in this conversation"))]
                  (testing "ghost-prompt! succeeds and returns a generated prompt P"
                    (is (:ok result) (str "ghost-prompt! failed: " (pr-str result)))
                    (is (string? (:text result)))
                    (is (not (str/blank? (:text result)))))

                  (when (:ok result)
                    (let [p (:text result)
                          frag (first-line-fragment p)]
                      (testing "P is delivered into the ORIGINAL session S (AC1)"
                        ;; The JSONL is append-only, so prompts delivered after the
                        ;; baseline are the tail past prompts-before; match the
                        ;; fragment against only those so an old prompt can't satisfy it.
                        (let [delivered
                              (wait-for 60000 1000
                                        (fn []
                                          (let [new-texts (drop prompts-before (human-prompt-texts s-path))]
                                            (when (some #(str/includes? (norm %) frag) new-texts)
                                              true))))]
                          (is delivered
                              (str "expected a new human prompt in S containing P's first line.\n"
                                   "fragment=" (pr-str frag) "\n"
                                   "new S prompts=" (pr-str (drop prompts-before (human-prompt-texts s-path)))))))

                      (testing "the throwaway fork is hidden from get-all-sessions (AC5)"
                        (let [new-files (->> (repl/find-jsonl-files)
                                             (remove #(pre-files (.getAbsolutePath ^java.io.File %))))
                              fork-file (->> new-files
                                             (filter repl/ghost-session?)
                                             (sort-by #(- (.lastModified ^java.io.File %)))
                                             first)]
                          (is fork-file "a new ghost-marked fork transcript should exist on disk")
                          (when fork-file
                            (let [fork-id (repl/extract-session-id-from-path fork-file)]
                              (is (true? (repl/ghost-session? fork-file))
                                  "the fork transcript is recognized as a ghost session")
                              (is (false? (repl/ghost-session? s-file))
                                  "the real source session is NOT a ghost")
                              ;; Build the real index the way the server does at startup and
                              ;; confirm the fork is excluded while the source stays visible.
                              (reset! repl/session-index (repl/build-index!))
                              (let [visible (set (map :session-id (repl/get-all-sessions)))]
                                (is (not (contains? visible fork-id))
                                    "fork session must be absent from get-all-sessions")
                                (is (contains? visible s-uuid)
                                    "the original source session must remain visible"))
                              (testing "the fork transcript is left intact on disk (AC8)"
                                (is (.exists ^java.io.File fork-file)
                                    "ghost-prompt! must not delete or mutate the fork transcript")))))))))))
            (finally
              ;; Teardown: kill S's window and the dedicated ghost tmux session.
              ;; Read live-windows BEFORE the fixture restores it (fixture finally
              ;; runs after this one). Transcripts are intentionally left on disk.
              (when-let [{:keys [tmux-session tmux-window]} (get @tmux/live-windows s-uuid)]
                (tmux/kill-window! tmux-session tmux-window))
              (shell/sh "tmux" "kill-session" "-t" (str "=" tmux/ghost-tmux-session))
              ;; Remove the temp workdir (children-first). Session transcripts live
              ;; under ~/.claude/projects and are intentionally left intact (AC8).
              (doseq [^java.io.File f (reverse (file-seq (io/file workdir)))]
                (.delete f)))))))))
