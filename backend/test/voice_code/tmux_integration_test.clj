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
