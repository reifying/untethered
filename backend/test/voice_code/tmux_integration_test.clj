(ns voice-code.tmux-integration-test
  "Integration tests for voice-code.tmux using a real but disposable tmux server.
   Tests target a per-run socket so they never touch the developer's tmux sessions."
  (:require [clojure.test :refer [deftest is testing use-fixtures]]
            [clojure.java.shell :as shell]
            [clojure.string :as str]
            [voice-code.tmux :as tmux]
            [voice-code.providers :as providers]))

;; ============================================================================
;; Fixture & helpers
;; ============================================================================

(def ^:dynamic *tmux-socket* nil)

(def ^:private mock-provider-script
  "Absolute path to mock-provider.sh; resolved relative to the backend working dir."
  (str (System/getProperty "user.dir") "/test-resources/mock-provider.sh"))

(defn- socket-tmux-invoker
  "Stand-in for shell/sh that injects `-S <socket>` after the leading 'tmux' arg.
   Non-tmux calls pass through unchanged (none expected in tmux.clj, but safe)."
  [& args]
  (let [[program & rest-args] args]
    (if (= program "tmux")
      (apply shell/sh "tmux" "-S" *tmux-socket* rest-args)
      (apply shell/sh args))))

(defn with-tmux-server
  "Each-fixture: start a disposable tmux server on a per-run socket, run t,
   then kill-server unconditionally — even if t throws."
  [t]
  (let [socket (str (System/getProperty "java.io.tmpdir")
                    "/vc-tmux-" (random-uuid) ".sock")]
    (binding [*tmux-socket* socket
              tmux/*tmux-invoker* socket-tmux-invoker]
      (try
        (t)
        (finally
          (shell/sh "tmux" "-S" socket "kill-server"))))))

(defn- tmux-cmd
  "Test-owned tmux calls for fixture setup and assertions.
   Production code goes through tmux/*tmux-invoker*; this helper queries
   the socket directly without going through the production indirection."
  [& args]
  (apply shell/sh "tmux" "-S" *tmux-socket* args))

(use-fixtures :each with-tmux-server)

(defn- mock-build-provider-command
  "Replacement for tmux/build-provider-command that routes to the mock script.
   Passes the provider name as the first argument so the script prints the
   correct readiness string."
  [provider _opts]
  (str mock-provider-script " " (name provider)))

;; ============================================================================
;; start-window! — window creation, env vars, and nudge delivery
;; ============================================================================

(deftest start-window!-creates-window-sets-env-and-nudges-test
  (reset! tmux/live-windows {})
  (let [uuid         (str/lower-case (str (random-uuid)))
        workdir      (System/getProperty "java.io.tmpdir")
        session-name "Integration Test Session"
        tmux-session (tmux/sanitize-session-name workdir)
        win-name     (tmux/window-name session-name uuid)
        prompt       "nudge-marker-xyz"]
    (with-redefs [tmux/build-provider-command mock-build-provider-command
                  providers/session-metadata  (constantly nil)]
      (tmux/start-window! {:session-uuid  uuid
                           :session-name  session-name
                           :provider      :claude
                           :workdir       workdir
                           :initial-prompt prompt}))

    (testing "window is created in tmux"
      (let [wins (:out (tmux-cmd "list-windows" "-t" (str "=" tmux-session)
                                 "-F" "#{window_name}"))]
        (is (str/includes? wins win-name)
            "expected window to exist in tmux session")))

    (testing "VC_* env vars are set in the tmux session"
      (let [raw-env (:out (tmux-cmd "show-environment" "-t" (str "=" tmux-session)))
            env     (tmux/parse-show-environment raw-env)
            suffix  (tmux/env-suffix win-name)]
        (is (= uuid    (get env (str "VC_SESSION_UUID_" suffix))) "VC_SESSION_UUID")
        (is (= workdir (get env (str "VC_WORKDIR_"      suffix))) "VC_WORKDIR")
        (is (= "claude" (get env (str "VC_PROVIDER_"    suffix))) "VC_PROVIDER")))

    (testing "uuid is in live-windows after start"
      (is (contains? @tmux/live-windows uuid)))

    (testing "nudge text arrives in the pane within 1 s"
      (Thread/sleep 1000)
      (let [pane (:out (tmux-cmd "capture-pane"
                                 "-t" (format "=%s:=%s.0" tmux-session win-name)
                                 "-p"))]
        (is (str/includes? pane prompt)
            "expected nudge text to appear in pane content")))))

;; ============================================================================
;; scan-existing-windows! — rebuilds live-windows after reset
;; ============================================================================

(deftest scan-existing-windows!-rebuilds-live-windows-test
  (reset! tmux/live-windows {})
  (let [uuids   (vec (repeatedly 4 #(str/lower-case (str (random-uuid)))))
        workdir (System/getProperty "java.io.tmpdir")]
    ;; Create 4 windows (window-cap = 4, so no eviction during setup)
    (with-redefs [tmux/build-provider-command mock-build-provider-command
                  providers/session-metadata  (constantly nil)]
      (doseq [uuid uuids]
        (tmux/start-window! {:session-uuid  uuid
                             :session-name  (str "Session " (subs uuid 0 8))
                             :provider      :claude
                             :workdir       workdir
                             :initial-prompt nil})))

    (let [pre-scan @tmux/live-windows]
      (testing "precondition: all 4 uuids are in live-windows before reset"
        (doseq [uuid uuids]
          (is (contains? pre-scan uuid))))

      ;; Wipe live-windows and re-scan from tmux env
      (reset! tmux/live-windows {})
      (is (empty? @tmux/live-windows) "precondition: live-windows is empty after reset")

      (tmux/scan-existing-windows!)

      (testing "all 4 uuids are rediscovered"
        (doseq [uuid uuids]
          (is (contains? @tmux/live-windows uuid)
              (str "expected " uuid " to be rediscovered"))))

      (testing "rediscovered descriptors match original session/window/provider/workdir"
        (doseq [uuid uuids]
          (let [actual (get @tmux/live-windows uuid)
                exp    (get pre-scan uuid)]
            (is (= (:tmux-session actual) (:tmux-session exp)) "tmux-session")
            (is (= (:tmux-window  actual) (:tmux-window  exp)) "tmux-window")
            (is (= (:provider     actual) (:provider     exp)) "provider")
            (is (= (:workdir      actual) (:workdir      exp)) "workdir")))))))

;; ============================================================================
;; evict-if-needed! — oldest idle window evicted when at cap
;; ============================================================================

(deftest evict-if-needed!-kills-oldest-idle-window-test
  ;; Strategy: create 4 windows, set up session-metadata so:
  ;;   - window[0] (oldest-uuid): last-modified-ms 30 min ago  → idle (> 15 min cutoff)
  ;;   - windows[1-3]:            last-modified-ms 2-10 min ago → processing (< 15 min)
  ;; Then create a 5th window to trigger eviction inside start-window!.
  (reset! tmux/live-windows {})
  (let [now         (System/currentTimeMillis)
        uuids       (vec (repeatedly 5 #(str/lower-case (str (random-uuid)))))
        oldest-uuid (nth uuids 0)
        activity-ms {oldest-uuid   (- now (* 30 60 1000))
                     (nth uuids 1) (- now (* 10 60 1000))
                     (nth uuids 2) (- now (*  5 60 1000))
                     (nth uuids 3) (- now (*  2 60 1000))
                     (nth uuids 4) (- now (*  1 60 1000))}
        workdir     (System/getProperty "java.io.tmpdir")
        tmux-session (tmux/sanitize-session-name workdir)]
    (with-redefs [tmux/build-provider-command mock-build-provider-command
                  providers/session-metadata
                  (fn [uuid]
                    {:last-modified-ms (get activity-ms uuid
                                           (- now (* 1 60 1000)))})]
      ;; Create first 4 windows (no eviction; cap is 4 and we go up to count=3 before each)
      (doseq [uuid (take 4 uuids)]
        (tmux/start-window! {:session-uuid  uuid
                             :session-name  (str "Session " (subs uuid 0 8))
                             :provider      :claude
                             :workdir       workdir
                             :initial-prompt nil}))

      (testing "precondition: oldest-uuid is in live-windows before 5th window"
        (is (contains? @tmux/live-windows oldest-uuid)))

      ;; Create 5th window — triggers eviction of oldest-uuid (only idle window)
      (tmux/start-window! {:session-uuid  (nth uuids 4)
                           :session-name  "Fifth Session"
                           :provider      :claude
                           :workdir       workdir
                           :initial-prompt nil}))

    (testing "oldest (30-min-idle) window is evicted from live-windows"
      (is (not (contains? @tmux/live-windows oldest-uuid))
          "expected oldest-uuid to be evicted"))

    (testing "other windows survive eviction"
      (doseq [uuid (drop 1 uuids)]
        (is (contains? @tmux/live-windows uuid)
            (str "expected " uuid " to remain"))))

    (testing "evicted window is gone from tmux"
      (let [wins (str/split-lines (str/trim (:out (tmux-cmd "list-windows"
                                                            "-t" (str "=" tmux-session)
                                                            "-F" "#{window_name}"))))
            oldest-win (tmux/window-name (str "Session " (subs oldest-uuid 0 8)) oldest-uuid)]
        (is (not (some #{oldest-win} wins))
            "expected evicted window to be absent from tmux")))))

;; ============================================================================
;; evict-if-needed! — a window with UNKNOWN activity (copilot's virtual uuid)
;; is never the victim, even at cap. Regression for the tmux-purge incident: a
;; busy, seconds-old copilot window was evicted mid-turn because its tmux-env
;; uuid has no transcript (session-metadata nil -> last-activity 0), so the old
;; min-key selected it every time. Eviction must instead fall on a genuinely
;; idle window whose activity is positively known.
;; ============================================================================

(deftest evict-if-needed!-spares-unknown-activity-window-test
  (reset! tmux/live-windows {})
  (let [now           (System/currentTimeMillis)
        copilot-uuid  (str/lower-case (str (random-uuid)))   ; metadata nil -> unknown
        idle-uuid     (str/lower-case (str (random-uuid)))   ; known, 30 min old -> idle
        recent-1      (str/lower-case (str (random-uuid)))   ; known, 5 min old -> processing
        recent-2      (str/lower-case (str (random-uuid)))   ; known, 2 min old -> processing
        fifth-uuid    (str/lower-case (str (random-uuid)))
        activity-ms   {idle-uuid (- now (* 30 60 1000))
                       recent-1  (- now (*  5 60 1000))
                       recent-2  (- now (*  2 60 1000))
                       fifth-uuid (- now (* 1 60 1000))}
        workdir       (System/getProperty "java.io.tmpdir")]
    (with-redefs [tmux/build-provider-command mock-build-provider-command
                  providers/session-metadata
                  (fn [uuid]
                    ;; copilot-uuid intentionally absent -> nil, mirroring a
                    ;; copilot window keyed by its virtual (never-indexed) uuid.
                    (when-let [ms (get activity-ms uuid)]
                      {:last-modified-ms ms}))]
      ;; copilot window first (it is the prime victim under the old logic)
      (tmux/start-window! {:session-uuid copilot-uuid
                           :session-name "Copilot Session"
                           :provider :copilot
                           :workdir workdir
                           :initial-prompt nil})
      (doseq [[uuid nm] [[idle-uuid "Idle"] [recent-1 "Recent One"] [recent-2 "Recent Two"]]]
        (tmux/start-window! {:session-uuid uuid
                             :session-name nm
                             :provider :claude
                             :workdir workdir
                             :initial-prompt nil}))

      (testing "precondition: copilot window is live before the 5th window"
        (is (contains? @tmux/live-windows copilot-uuid)))

      ;; 5th window triggers eviction. The only positively-known idle window is
      ;; idle-uuid; the copilot window's activity is unknown and must be spared.
      (tmux/start-window! {:session-uuid fifth-uuid
                           :session-name "Fifth Session"
                           :provider :claude
                           :workdir workdir
                           :initial-prompt nil}))

    (testing "copilot window (unknown activity) survives eviction"
      (is (contains? @tmux/live-windows copilot-uuid)
          "a window with unknown activity must never be evicted"))

    (testing "the genuinely-idle known window is evicted instead"
      (is (not (contains? @tmux/live-windows idle-uuid))
          "expected the 30-min-idle known window to be the victim"))

    (testing "processing windows survive"
      (is (contains? @tmux/live-windows recent-1))
      (is (contains? @tmux/live-windows recent-2)))))

;; ============================================================================
;; reassign-session-uuid! — FULL FIX: after copilot's real uuid is discovered,
;; re-key the window so eviction/sweep read its REAL activity. A busy copilot
;; window is protected by real activity; a genuinely-idle one is correctly
;; evicted/reaped (no leak). Exercised against a real tmux server.
;; ============================================================================

(deftest reassign-makes-real-activity-visible-test
  ;; Mirrors reconcile-copilot-session-uuid!: a copilot window is created under
  ;; the backend's virtual uuid, then re-keyed onto copilot's real uuid.
  (reset! tmux/live-windows {})
  (let [now          (System/currentTimeMillis)
        virtual-uuid (str/lower-case (str (random-uuid)))
        real-uuid    (str/lower-case (str (random-uuid)))
        recent-ms    (- now (* 2 60 1000))
        workdir      (System/getProperty "java.io.tmpdir")
        tmux-session (tmux/sanitize-session-name workdir)]
    (with-redefs [tmux/build-provider-command mock-build-provider-command
                  providers/session-metadata (constantly nil)]
      (tmux/start-window! {:session-uuid virtual-uuid
                           :session-name "Copilot Session"
                           :provider :copilot
                           :workdir workdir
                           :initial-prompt nil}))

    (testing "before reassign: window keyed by the virtual uuid"
      (is (contains? @tmux/live-windows virtual-uuid)))

    (tmux/reassign-session-uuid! virtual-uuid real-uuid)

    (testing "live-windows re-keyed onto the real uuid"
      (is (not (contains? @tmux/live-windows virtual-uuid)))
      (is (contains? @tmux/live-windows real-uuid)))

    (testing "tmux env VC_SESSION_UUID now holds the real uuid"
      (let [win    (get-in @tmux/live-windows [real-uuid :tmux-window])
            env    (tmux/parse-show-environment
                    (:out (tmux-cmd "show-environment" "-t" (str "=" tmux-session))))
            suffix (tmux/env-suffix win)]
        (is (= real-uuid (get env (str "VC_SESSION_UUID_" suffix))))))

    (testing "list-agent-windows now reports the REAL uuid and its REAL activity"
      (with-redefs [providers/session-metadata
                    (fn [uuid]
                      (when (= uuid real-uuid) {:last-modified-ms recent-ms}))]
        (let [windows (tmux/list-agent-windows tmux-session)
              entry   (first (filter #(= real-uuid (:session-uuid %)) windows))]
          (is (some? entry) "the window is enumerated under its real uuid")
          (is (= recent-ms (:last-activity-ms entry))
              "activity now reflects copilot's real session, not nil->0"))))))

(deftest busy-copilot-protected-by-real-activity-at-cap-test
  ;; A copilot window with RECENT real activity must survive eviction at cap.
  (reset! tmux/live-windows {})
  (let [now           (System/currentTimeMillis)
        cop-virtual   (str/lower-case (str (random-uuid)))
        cop-real      (str/lower-case (str (random-uuid)))
        idle-uuid     (str/lower-case (str (random-uuid)))   ; 30 min old -> idle
        recent-1      (str/lower-case (str (random-uuid)))
        fifth-uuid    (str/lower-case (str (random-uuid)))
        activity-ms   {cop-real  (- now (* 1 60 1000))       ; busy copilot
                       idle-uuid (- now (* 30 60 1000))
                       recent-1  (- now (* 3 60 1000))
                       fifth-uuid (- now (* 1 60 1000))}
        workdir       (System/getProperty "java.io.tmpdir")]
    (with-redefs [tmux/build-provider-command mock-build-provider-command
                  providers/session-metadata
                  (fn [uuid] (when-let [ms (get activity-ms uuid)] {:last-modified-ms ms}))]
      ;; copilot launched under virtual uuid, then reconciled to real
      (tmux/start-window! {:session-uuid cop-virtual :session-name "Copilot"
                           :provider :copilot :workdir workdir :initial-prompt nil})
      (tmux/reassign-session-uuid! cop-virtual cop-real)
      (doseq [[uuid nm] [[idle-uuid "Idle"] [recent-1 "Recent One"]]]
        (tmux/start-window! {:session-uuid uuid :session-name nm
                             :provider :claude :workdir workdir :initial-prompt nil}))

      ;; 4th window puts us at cap; 5th triggers eviction.
      (tmux/start-window! {:session-uuid (str/lower-case (str (random-uuid)))
                           :session-name "Filler" :provider :claude
                           :workdir workdir :initial-prompt nil})
      (tmux/start-window! {:session-uuid fifth-uuid :session-name "Fifth"
                           :provider :claude :workdir workdir :initial-prompt nil}))

    (testing "busy copilot (recent REAL activity) survives, idle known window evicted"
      (is (contains? @tmux/live-windows cop-real)
          "copilot with recent real activity must be protected")
      (is (not (contains? @tmux/live-windows idle-uuid))
          "the 30-min-idle window is the victim"))))

(deftest idle-copilot-evicted-at-cap-via-real-activity-test
  ;; The behavior the fail-safe alone could NOT achieve: a genuinely-idle copilot
  ;; window (old REAL activity) IS evicted at cap — no more leak.
  (reset! tmux/live-windows {})
  (let [now          (System/currentTimeMillis)
        cop-virtual  (str/lower-case (str (random-uuid)))
        cop-real     (str/lower-case (str (random-uuid)))
        recent-1     (str/lower-case (str (random-uuid)))
        recent-2     (str/lower-case (str (random-uuid)))
        recent-3     (str/lower-case (str (random-uuid)))
        fifth-uuid   (str/lower-case (str (random-uuid)))
        activity-ms  {cop-real (- now (* 45 60 1000))        ; idle copilot (45 min)
                      recent-1 (- now (* 2 60 1000))
                      recent-2 (- now (* 3 60 1000))
                      recent-3 (- now (* 4 60 1000))
                      fifth-uuid (- now (* 1 60 1000))}
        workdir      (System/getProperty "java.io.tmpdir")]
    (with-redefs [tmux/build-provider-command mock-build-provider-command
                  providers/session-metadata
                  (fn [uuid] (when-let [ms (get activity-ms uuid)] {:last-modified-ms ms}))]
      (tmux/start-window! {:session-uuid cop-virtual :session-name "Copilot"
                           :provider :copilot :workdir workdir :initial-prompt nil})
      (tmux/reassign-session-uuid! cop-virtual cop-real)
      (doseq [[uuid nm] [[recent-1 "R1"] [recent-2 "R2"] [recent-3 "R3"]]]
        (tmux/start-window! {:session-uuid uuid :session-name nm
                             :provider :claude :workdir workdir :initial-prompt nil}))
      ;; now at cap (copilot + 3 recent); 5th launch triggers eviction
      (tmux/start-window! {:session-uuid fifth-uuid :session-name "Fifth"
                           :provider :claude :workdir workdir :initial-prompt nil}))

    (testing "idle copilot (old REAL activity) is the victim; processing windows survive"
      (is (not (contains? @tmux/live-windows cop-real))
          "an idle copilot window must now be evictable via its real activity")
      (is (contains? @tmux/live-windows recent-1))
      (is (contains? @tmux/live-windows recent-2))
      (is (contains? @tmux/live-windows recent-3)))))

(deftest sweep!-reaps-idle-copilot-keyed-by-real-uuid-test
  (reset! tmux/live-windows {})
  (let [now          (System/currentTimeMillis)
        cop-virtual  (str/lower-case (str (random-uuid)))
        cop-real     (str/lower-case (str (random-uuid)))
        workdir      (System/getProperty "java.io.tmpdir")
        tmux-session (tmux/sanitize-session-name workdir)]
    (with-redefs [tmux/build-provider-command mock-build-provider-command
                  providers/session-metadata (constantly nil)]
      (tmux/start-window! {:session-uuid cop-virtual :session-name "Copilot"
                           :provider :copilot :workdir workdir :initial-prompt nil})
      (tmux/reassign-session-uuid! cop-virtual cop-real))

    (let [win (get-in @tmux/live-windows [cop-real :tmux-window])]
      (with-redefs [providers/session-metadata
                    (fn [uuid]
                      (when (= uuid cop-real)
                        {:last-modified-ms (- now (* 3 24 60 60 1000))}))]  ; 3 days old
        (tmux/sweep!))

      (testing "idle copilot is reaped from live-windows under its real uuid"
        (is (not (contains? @tmux/live-windows cop-real))))

      (testing "the copilot tmux window is actually killed"
        (let [wins (str/split-lines (str/trim (:out (tmux-cmd "list-windows"
                                                              "-t" (str "=" tmux-session)
                                                              "-F" "#{window_name}"))))]
          (is (not (some #{win} wins))
              "expected the swept copilot window to be gone from tmux"))))))

;; ============================================================================
;; close-window-by-uuid! — proactive recipe-window teardown against real tmux
;; ============================================================================

(deftest close-window-by-uuid!-kills-real-window-test
  (reset! tmux/live-windows {})
  (let [uuid         (str/lower-case (str (random-uuid)))
        keep-uuid    (str/lower-case (str (random-uuid)))
        workdir      (System/getProperty "java.io.tmpdir")
        tmux-session (tmux/sanitize-session-name workdir)]
    (with-redefs [tmux/build-provider-command mock-build-provider-command
                  providers/session-metadata (constantly nil)]
      (tmux/start-window! {:session-uuid uuid :session-name "Doomed"
                           :provider :claude :workdir workdir :initial-prompt nil})
      (tmux/start-window! {:session-uuid keep-uuid :session-name "Keeper"
                           :provider :claude :workdir workdir :initial-prompt nil}))
    (let [doomed-win (get-in @tmux/live-windows [uuid :tmux-window])
          keep-win   (get-in @tmux/live-windows [keep-uuid :tmux-window])]

      (is (true? (tmux/close-window-by-uuid! uuid)))

      (testing "closed window removed from live-windows; other remains"
        (is (not (contains? @tmux/live-windows uuid)))
        (is (contains? @tmux/live-windows keep-uuid)))

      (testing "closed tmux window gone; the other still alive"
        (let [wins (str/split-lines (str/trim (:out (tmux-cmd "list-windows"
                                                              "-t" (str "=" tmux-session)
                                                              "-F" "#{window_name}"))))]
          (is (not (some #{doomed-win} wins)) "doomed window killed")
          (is (some #{keep-win} wins) "keeper window survives"))))))

;; ============================================================================
;; sweep! — stale windows killed; fresh windows preserved
;; ============================================================================

(deftest sweep!-kills-windows-older-than-max-age-test
  (reset! tmux/live-windows {})
  (let [now         (System/currentTimeMillis)
        stale-uuid  (str/lower-case (str (random-uuid)))
        fresh-uuid  (str/lower-case (str (random-uuid)))
        workdir     (System/getProperty "java.io.tmpdir")
        tmux-session (tmux/sanitize-session-name workdir)]
    ;; Create both windows
    (with-redefs [tmux/build-provider-command mock-build-provider-command
                  providers/session-metadata  (constantly nil)]
      (tmux/start-window! {:session-uuid  stale-uuid
                           :session-name  "Stale Session"
                           :provider      :claude
                           :workdir       workdir
                           :initial-prompt nil})
      (tmux/start-window! {:session-uuid  fresh-uuid
                           :session-name  "Fresh Session"
                           :provider      :claude
                           :workdir       workdir
                           :initial-prompt nil}))

    ;; Run sweep with stale window older than 2 days, fresh within the hour
    (let [stale-ms (- now (* 3 24 60 60 1000))
          fresh-ms (- now (*  1 60 60 1000))]
      (with-redefs [providers/session-metadata
                    (fn [uuid]
                      (cond (= uuid stale-uuid) {:last-modified-ms stale-ms}
                            (= uuid fresh-uuid) {:last-modified-ms fresh-ms}))]
        (tmux/sweep!)))

    (testing "stale window removed from live-windows"
      (is (not (contains? @tmux/live-windows stale-uuid))))

    (testing "fresh window remains in live-windows"
      (is (contains? @tmux/live-windows fresh-uuid)))

    (testing "stale tmux window is actually killed"
      (let [wins (str/split-lines (str/trim (:out (tmux-cmd "list-windows"
                                                            "-t" (str "=" tmux-session)
                                                            "-F" "#{window_name}"))))
            stale-win (tmux/window-name "Stale Session" stale-uuid)]
        (is (not (some #{stale-win} wins))
            "expected stale window to be absent from tmux")))

    (testing "fresh tmux window is still alive"
      (let [wins (str/split-lines (str/trim (:out (tmux-cmd "list-windows"
                                                            "-t" (str "=" tmux-session)
                                                            "-F" "#{window_name}"))))
            fresh-win (tmux/window-name "Fresh Session" fresh-uuid)]
        (is (some #{fresh-win} wins)
            "expected fresh window to still exist in tmux")))))

;; ============================================================================
;; deliver! / respawn-and-deliver! — evicted session respawns with --resume
;; ============================================================================

(deftest deliver!-respawns-evicted-session-with-resume-test
  (reset! tmux/live-windows {})
  (let [uuid         (str/lower-case (str (random-uuid)))
        workdir      (System/getProperty "java.io.tmpdir")
        session-name "Evicted Session"
        tmux-session (tmux/sanitize-session-name workdir)
        win-name     (tmux/window-name session-name uuid)
        resumed?     (atom false)]

    ;; Create the initial window
    (with-redefs [tmux/build-provider-command mock-build-provider-command
                  providers/session-metadata  (constantly nil)]
      (tmux/start-window! {:session-uuid  uuid
                           :session-name  session-name
                           :provider      :claude
                           :workdir       workdir
                           :initial-prompt nil}))

    (testing "precondition: window exists"
      (is (contains? @tmux/live-windows uuid)))

    ;; Simulate eviction: kill window in tmux and remove from live-windows
    (tmux-cmd "kill-window" "-t" (format "=%s:=%s" tmux-session win-name))
    (swap! tmux/live-windows dissoc uuid)

    (testing "precondition: uuid not in live-windows after simulated eviction"
      (is (not (contains? @tmux/live-windows uuid))))

    ;; deliver! should call respawn-and-deliver! → start-window! with resume? true
    (with-redefs [tmux/build-provider-command
                  (fn [provider {:keys [resume?]}]
                    (when resume? (reset! resumed? true))
                    (str mock-provider-script " " (name provider)))
                  providers/session-metadata
                  (constantly {:provider          :claude
                               :working-directory workdir
                               :name              session-name})]
      (tmux/deliver! uuid "respawn-test-prompt"))

    (testing "build-provider-command was called with resume? true"
      (is @resumed? "expected respawn to use resume? true"))

    (testing "uuid is back in live-windows after respawn"
      (is (contains? @tmux/live-windows uuid)))

    (testing "the respawned agent window exists in tmux by name"
      (let [wins (:out (tmux-cmd "list-windows" "-t" (str "=" tmux-session)
                                 "-F" "#{window_name}"))]
        (is (str/includes? wins win-name)
            "expected respawned agent window to appear in tmux window list")))))
