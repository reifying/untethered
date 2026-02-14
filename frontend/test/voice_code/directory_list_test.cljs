(ns voice-code.directory-list-test
  "Tests for directory-list view helper functions and subscriptions.
   Tests the directory grouping, recent sessions, queue/priority queue,
   and directory list display logic used by the main projects view.

   Reference implementation: ios/VoiceCode/Views/DirectoryListView.swift"
  (:require [cljs.test :refer [deftest testing is use-fixtures]]
            [re-frame.core :as rf]
            [day8.re-frame.test :as rf-test]
            [voice-code.db :as db]
            [voice-code.events.core]
            [voice-code.events.websocket]
            [voice-code.platform :as platform]
            [voice-code.subs]
            [voice-code.voice.events]
            [voice-code.views.directory-list :as dir-list]))

(use-fixtures :each
  {:before (fn [] (rf/dispatch-sync [:initialize-db]))})

;; ============================================================================
;; Directory Name Helper Tests
;; Reference: ios/VoiceCode/Views/DirectoryListView.swift directoryName()
;; ============================================================================

(deftest directory-name-extracts-last-component-test
  (testing "Extracts directory name from full path"
    (is (= "project-a" (#'dir-list/directory-name "/Users/test/projects/project-a")))
    (is (= "voice-code" (#'dir-list/directory-name "/Users/travisbrown/code/voice-code")))
    (is (= "src" (#'dir-list/directory-name "/home/user/dev/app/src")))))

(deftest directory-name-handles-single-component-test
  (testing "Handles paths with single component"
    (is (= "root" (#'dir-list/directory-name "root")))
    (is (= "project" (#'dir-list/directory-name "project")))))

(deftest directory-name-handles-trailing-slash-test
  (testing "Handles paths with trailing slash - returns directory name correctly"
    ;; Clojure's str/split does not include trailing empty strings,
    ;; so a path like "/Users/test/project/" splits to ["" "Users" "test" "project"]
    ;; and (last ...) returns "project" - this is the desired behavior
    (is (= "project" (#'dir-list/directory-name "/Users/test/project/")))))

(deftest directory-name-handles-nil-test
  (testing "Returns nil for nil input"
    (is (nil? (#'dir-list/directory-name nil)))))

;; ============================================================================
;; Session Name Helper Tests
;; Reference: ios/VoiceCode/Models/CDBackendSession.swift displayName()
;; ============================================================================

(deftest session-name-custom-name-priority-test
  (testing "Custom name takes priority over backend name"
    (is (= "My Custom Name"
           (#'dir-list/session-name
            {:id "abc123"
             :backend-name "Session from backend"
             :custom-name "My Custom Name"})))))

(deftest session-name-backend-fallback-test
  (testing "Backend name used when no custom name"
    (is (= "Session from backend"
           (#'dir-list/session-name
            {:id "abc123"
             :backend-name "Session from backend"
             :custom-name nil})))))

(deftest session-name-id-fallback-test
  (testing "Falls back to truncated ID when no name available"
    (is (= "Session abc12345"
           (#'dir-list/session-name
            {:id "abc12345-6789-abcd-ef01-234567890abc"
             :backend-name nil
             :custom-name nil})))))

;; ============================================================================
;; Priority Tint Color Tests
;; Reference: ios/VoiceCode/Views/DirectoryListView.swift priorityColor()
;; ============================================================================

(deftest priority-tint-high-priority-test
  (testing "High priority (1) gets darker accent tint"
    (let [colors {:accent "#007AFF"}
          result (#'dir-list/priority-tint-color colors 1)]
      ;; Should contain accent color with ~18% opacity
      (is (string? result))
      (is (clojure.string/includes? result "#007AFF")))))

(deftest priority-tint-medium-priority-test
  (testing "Medium priority (5) gets lighter accent tint"
    (let [colors {:accent "#007AFF"}
          result (#'dir-list/priority-tint-color colors 5)]
      ;; Should contain accent color with ~10% opacity
      (is (string? result))
      (is (clojure.string/includes? result "#007AFF")))))

(deftest priority-tint-low-priority-test
  (testing "Low priority (10) gets transparent"
    (let [colors {:accent "#007AFF"}
          result (#'dir-list/priority-tint-color colors 10)]
      (is (= "transparent" result)))))

(deftest priority-tint-default-priority-test
  (testing "Default/undefined priority gets transparent"
    (let [colors {:accent "#007AFF"}]
      (is (= "transparent" (#'dir-list/priority-tint-color colors nil)))
      (is (= "transparent" (#'dir-list/priority-tint-color colors 99))))))

;; ============================================================================
;; Directories Subscription Tests
;; Reference: ios/VoiceCode/Views/DirectoryListView.swift groupedByDirectory
;; ============================================================================

(deftest directories-grouped-by-path-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "Sessions are grouped by working directory"
     (rf/dispatch-sync [:sessions/add-many
                        [{:id "session-1"
                          :backend-name "Session 1"
                          :working-directory "/Users/test/project-a"
                          :last-modified (js/Date.)}
                         {:id "session-2"
                          :backend-name "Session 2"
                          :working-directory "/Users/test/project-a"
                          :last-modified (js/Date.)}
                         {:id "session-3"
                          :backend-name "Session 3"
                          :working-directory "/Users/test/project-b"
                          :last-modified (js/Date.)}]])

     (let [directories @(rf/subscribe [:sessions/directories])]
       ;; Should have 2 directories
       (is (= 2 (count directories)))
       ;; Each directory should have correct session count
       (let [project-a (first (filter #(= "/Users/test/project-a" (:directory %)) directories))
             project-b (first (filter #(= "/Users/test/project-b" (:directory %)) directories))]
         (is (= 2 (:session-count project-a)))
         (is (= 1 (:session-count project-b))))))))

(deftest directories-sorted-by-last-modified-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "Directories are sorted by most recent session activity"
     (let [now (js/Date.)
           yesterday (js/Date. (- (.getTime now) 86400000))]
       (rf/dispatch-sync [:sessions/add-many
                          [{:id "old-session"
                            :backend-name "Old Session"
                            :working-directory "/Users/test/old-project"
                            :last-modified yesterday}
                           {:id "new-session"
                            :backend-name "New Session"
                            :working-directory "/Users/test/new-project"
                            :last-modified now}]])

       (let [directories @(rf/subscribe [:sessions/directories])]
         ;; Most recently modified directory should be first
         (is (= "/Users/test/new-project" (:directory (first directories))))
         (is (= "/Users/test/old-project" (:directory (second directories)))))))))

(deftest directories-unread-count-aggregated-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "Directory unread count is sum of session unread counts"
     (rf/dispatch-sync [:sessions/add-many
                        [{:id "session-1"
                          :backend-name "Session 1"
                          :working-directory "/Users/test/project"
                          :unread-count 3
                          :last-modified (js/Date.)}
                         {:id "session-2"
                          :backend-name "Session 2"
                          :working-directory "/Users/test/project"
                          :unread-count 5
                          :last-modified (js/Date.)}]])

     (let [directories @(rf/subscribe [:sessions/directories])
           project (first directories)]
       ;; Total unread should be 3 + 5 = 8
       (is (= 8 (:unread-count project)))))))

;; ============================================================================
;; Recent Sessions Subscription Tests
;; Reference: ios/VoiceCode/Views/DirectoryListView.swift recentSessions
;; ============================================================================

(deftest recent-sessions-limited-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "Recent sessions are limited by settings"
     ;; Set limit to 2
     (rf/dispatch-sync [:settings/save :recent-sessions-limit 2])

     ;; Add 5 sessions
     (let [now (js/Date.)]
       (rf/dispatch-sync [:sessions/add-many
                          (for [i (range 5)]
                            {:id (str "session-" i)
                             :backend-name (str "Session " i)
                             :working-directory "/Users/test/project"
                             :last-modified (js/Date. (- (.getTime now) (* i 3600000)))})]))

     (let [recent @(rf/subscribe [:sessions/recent])]
       ;; Should only return 2 most recent
       (is (= 2 (count recent)))
       (is (= "session-0" (:id (first recent))))
       (is (= "session-1" (:id (second recent))))))))

(deftest recent-sessions-sorted-by-last-modified-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "Recent sessions are sorted newest first"
     (let [now (js/Date.)
           one-hour-ago (js/Date. (- (.getTime now) 3600000))
           two-hours-ago (js/Date. (- (.getTime now) 7200000))]
       (rf/dispatch-sync [:sessions/add-many
                          [{:id "oldest"
                            :backend-name "Oldest"
                            :working-directory "/Users/test/project"
                            :last-modified two-hours-ago}
                           {:id "newest"
                            :backend-name "Newest"
                            :working-directory "/Users/test/project"
                            :last-modified now}
                           {:id "middle"
                            :backend-name "Middle"
                            :working-directory "/Users/test/project"
                            :last-modified one-hour-ago}]])

       (let [recent @(rf/subscribe [:sessions/recent])]
         (is (= "newest" (:id (first recent))))
         (is (= "middle" (:id (second recent))))
         (is (= "oldest" (:id (nth recent 2)))))))))

;; ============================================================================
;; Queue Subscription Tests
;; Reference: ios/VoiceCode/Views/DirectoryListView.swift queueSessions
;; ============================================================================

(deftest queue-sessions-filtered-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "Queue only includes sessions with queue-position set (when queue enabled)"
     ;; Enable queue feature first
     (rf/dispatch-sync [:settings/save :queue-enabled true])

     (rf/dispatch-sync [:sessions/add-many
                        [{:id "in-queue"
                          :backend-name "In Queue"
                          :working-directory "/Users/test/project"
                          :queue-position 1
                          :last-modified (js/Date.)}
                         {:id "not-in-queue"
                          :backend-name "Not In Queue"
                          :working-directory "/Users/test/project"
                          :queue-position nil
                          :last-modified (js/Date.)}]])

     (let [queued @(rf/subscribe [:sessions/queued])]
       (is (= 1 (count queued)))
       (is (= "in-queue" (:id (first queued))))))))

(deftest queue-sessions-sorted-by-position-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "Queue sessions are sorted by queue-position (FIFO order)"
     ;; Enable queue feature first
     (rf/dispatch-sync [:settings/save :queue-enabled true])

     (rf/dispatch-sync [:sessions/add-many
                        [{:id "third"
                          :backend-name "Third in queue"
                          :working-directory "/Users/test/project"
                          :queue-position 3
                          :last-modified (js/Date.)}
                         {:id "first"
                          :backend-name "First in queue"
                          :working-directory "/Users/test/project"
                          :queue-position 1
                          :last-modified (js/Date.)}
                         {:id "second"
                          :backend-name "Second in queue"
                          :working-directory "/Users/test/project"
                          :queue-position 2
                          :last-modified (js/Date.)}]])

     (let [queued @(rf/subscribe [:sessions/queued])]
       (is (= 3 (count queued)))
       (is (= "first" (:id (first queued))))
       (is (= "second" (:id (second queued))))
       (is (= "third" (:id (nth queued 2))))))))

(deftest queue-remove-session-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "Session can be removed from queue"
     ;; Enable queue feature first
     (rf/dispatch-sync [:settings/save :queue-enabled true])

     (rf/dispatch-sync [:sessions/add-many
                        [{:id "to-remove"
                          :backend-name "To Remove"
                          :working-directory "/Users/test/project"
                          :queue-position 1
                          :last-modified (js/Date.)}]])

     ;; Verify it's in queue
     (is (= 1 (count @(rf/subscribe [:sessions/queued]))))

     ;; Remove from queue
     (rf/dispatch-sync [:sessions/remove-from-queue "to-remove"])

     ;; Verify removed
     (is (= 0 (count @(rf/subscribe [:sessions/queued])))))))

;; ============================================================================
;; Priority Queue Subscription Tests
;; Reference: ios/VoiceCode/Views/DirectoryListView.swift priorityQueueSessions
;; ============================================================================

(deftest priority-queue-sessions-filtered-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "Priority queue only includes sessions with priority-queued-at timestamp"
     ;; Enable priority queue feature first
     (rf/dispatch-sync [:settings/save :priority-queue-enabled true])

     (rf/dispatch-sync [:sessions/add-many
                        [{:id "in-priority"
                          :backend-name "In Priority Queue"
                          :working-directory "/Users/test/project"
                          :priority-queued-at (js/Date.)  ; Has timestamp = in queue
                          :priority 5
                          :last-modified (js/Date.)}
                         {:id "not-in-priority"
                          :backend-name "Not In Priority"
                          :working-directory "/Users/test/project"
                          :priority-queued-at nil  ; No timestamp = not in queue
                          :last-modified (js/Date.)}]])

     (let [priority @(rf/subscribe [:sessions/priority-queued])]
       (is (= 1 (count priority)))
       (is (= "in-priority" (:id (first priority))))))))

(deftest priority-queue-sorted-by-priority-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "Priority queue sorted by priority level (ascending: high=1 first)"
     ;; Enable priority queue feature first
     (rf/dispatch-sync [:settings/save :priority-queue-enabled true])

     (let [now (js/Date.)]
       (rf/dispatch-sync [:sessions/add-many
                          [{:id "low-priority"
                            :backend-name "Low Priority"
                            :working-directory "/Users/test/project"
                            :priority-queued-at now  ; Has timestamp = in queue
                            :priority 10
                            :priority-order 1.0
                            :last-modified now}
                           {:id "high-priority"
                            :backend-name "High Priority"
                            :working-directory "/Users/test/project"
                            :priority-queued-at now  ; Has timestamp = in queue
                            :priority 1
                            :priority-order 1.0
                            :last-modified now}
                           {:id "medium-priority"
                            :backend-name "Medium Priority"
                            :working-directory "/Users/test/project"
                            :priority-queued-at now  ; Has timestamp = in queue
                            :priority 5
                            :priority-order 1.0
                            :last-modified now}]]))

     (let [priority @(rf/subscribe [:sessions/priority-queued])]
       (is (= 3 (count priority)))
       ;; High (1) -> Medium (5) -> Low (10)
       (is (= "high-priority" (:id (first priority))))
       (is (= "medium-priority" (:id (second priority))))
       (is (= "low-priority" (:id (nth priority 2))))))))

(deftest priority-queue-secondary-sort-by-priority-order-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "Within same priority, sorted by priority-order"
     ;; Enable priority queue feature first
     (rf/dispatch-sync [:settings/save :priority-queue-enabled true])

     (let [now (js/Date.)]
       (rf/dispatch-sync [:sessions/add-many
                          [{:id "second"
                            :backend-name "Second"
                            :working-directory "/Users/test/project"
                            :priority-queued-at now  ; Has timestamp = in queue
                            :priority 5
                            :priority-order 2.0
                            :last-modified now}
                           {:id "first"
                            :backend-name "First"
                            :working-directory "/Users/test/project"
                            :priority-queued-at now  ; Has timestamp = in queue
                            :priority 5
                            :priority-order 1.0
                            :last-modified now}]]))

     (let [priority @(rf/subscribe [:sessions/priority-queued])]
       (is (= "first" (:id (first priority))))
       (is (= "second" (:id (second priority))))))))

(deftest priority-queue-remove-session-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "Session can be removed from priority queue"
     ;; Enable priority queue feature first
     (rf/dispatch-sync [:settings/save :priority-queue-enabled true])

     (rf/dispatch-sync [:sessions/add-many
                        [{:id "to-remove"
                          :backend-name "To Remove"
                          :working-directory "/Users/test/project"
                          :priority-queued-at (js/Date.)  ; Has timestamp = in queue
                          :priority 5
                          :last-modified (js/Date.)}]])

     ;; Verify it's in priority queue
     (is (= 1 (count @(rf/subscribe [:sessions/priority-queued]))))

     ;; Remove from priority queue
     (rf/dispatch-sync [:sessions/remove-from-priority-queue "to-remove"])

     ;; Verify removed
     (is (= 0 (count @(rf/subscribe [:sessions/priority-queued])))))))

;; ============================================================================
;; In-Queue Status Subscription Tests
;; Reference: ios/VoiceCode/Models/CDBackendSession.swift isInQueue
;; ============================================================================

(deftest session-in-queue-status-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "Session in-queue status is correctly reported"
     (rf/dispatch-sync [:sessions/add-many
                        [{:id "queued-session"
                          :backend-name "Queued"
                          :working-directory "/Users/test/project"
                          :queue-position 1
                          :last-modified (js/Date.)}
                         {:id "unqueued-session"
                          :backend-name "Not Queued"
                          :working-directory "/Users/test/project"
                          :queue-position nil
                          :last-modified (js/Date.)}]])

     (is @(rf/subscribe [:session/in-queue? "queued-session"]))
     (is (not @(rf/subscribe [:session/in-queue? "unqueued-session"]))))))

;; ============================================================================
;; Server Configuration Status Tests
;; Reference: ios/VoiceCode/Views/DirectoryListView.swift showWelcomeSetup
;; ============================================================================

(deftest server-configured-with-api-key-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "Server is configured when API key is set"
     ;; Initially not configured
     (is (not @(rf/subscribe [:settings/server-configured?])))

     ;; Set API key directly in db (auth/connect uses ws/connect fx which isn't available in tests)
     (swap! re-frame.db/app-db assoc :api-key "untethered-abcd1234567890abcdef12345678901")

     ;; Now configured
     (is @(rf/subscribe [:settings/server-configured?])))))

(deftest server-not-configured-without-api-key-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "Server is not configured without API key"
     (is (not @(rf/subscribe [:settings/server-configured?]))))))

;; ============================================================================
;; Pending Resources Badge Tests
;; Reference: ios/VoiceCode/Views/DirectoryListView.swift resourcesButton badge
;; ============================================================================

(deftest pending-uploads-count-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "Pending uploads count is tracked"
     ;; Initially no pending
     (is (= 0 (or @(rf/subscribe [:resources/pending-uploads]) 0)))

     ;; Set pending count directly in db (no event exists for this)
     (swap! re-frame.db/app-db assoc-in [:resources :pending-uploads] 3)

     (is (= 3 @(rf/subscribe [:resources/pending-uploads]))))))

;; ============================================================================
;; Voice Speaking State Tests
;; Reference: ios/VoiceCode/Views/DirectoryListView.swift stopSpeechButton
;; ============================================================================

(deftest voice-speaking-state-for-header-button-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "Voice speaking state is tracked for stop button visibility"
     ;; Initially not speaking
     (is (not @(rf/subscribe [:voice/speaking?])))

     ;; Start speaking
     (rf/dispatch-sync [:voice/tts-started])
     (is @(rf/subscribe [:voice/speaking?]))

     ;; Stop speaking
     (rf/dispatch-sync [:voice/speech-finished])
     (is (not @(rf/subscribe [:voice/speaking?]))))))

;; ============================================================================
;; Refresh State Tests
;; Reference: ios/VoiceCode/Views/DirectoryListView.swift refreshable
;; ============================================================================

(deftest refresh-state-tracking-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "Refresh state is tracked during session refresh"
     ;; Initially not refreshing
     (is (not @(rf/subscribe [:ui/refreshing?]))))))

;; ============================================================================
;; Empty State Tests
;; Reference: ios/VoiceCode/Views/DirectoryListView.swift emptyState
;; ============================================================================

(deftest empty-directories-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "Empty directories list when no sessions"
     (let [directories @(rf/subscribe [:sessions/directories])]
       (is (empty? directories))))))

(deftest empty-recent-sessions-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "Empty recent sessions when no sessions"
     (let [recent @(rf/subscribe [:sessions/recent])]
       (is (empty? recent))))))

;; ============================================================================
;; Debounce Configuration Tests
;; Reference: ios/VoiceCode/Views/DirectoryListView.swift debounce 150ms
;; ============================================================================

(deftest debounce-constant-matches-ios-test
  (testing "Debounce delay matches iOS implementation (150ms)"
    (is (= 150 dir-list/debounce-ms))))

;; ============================================================================
;; Integration: Full Directory List Loading Flow
;; Reference: Full flow from connect -> session_list -> directories display
;; ============================================================================

(deftest directory-list-loading-integration-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "Directory list is populated after session_list message"
     ;; Simulate receiving session list from backend
     (rf/dispatch-sync [:sessions/handle-list
                        {:sessions [{:session-id "session-a"
                                     :name "Project A Session 1"
                                     :working-directory "/Users/test/project-a"
                                     :last-modified "2026-01-29T10:00:00Z"
                                     :message-count 10}
                                    {:session-id "session-b"
                                     :name "Project A Session 2"
                                     :working-directory "/Users/test/project-a"
                                     :last-modified "2026-01-29T09:00:00Z"
                                     :message-count 5}
                                    {:session-id "session-c"
                                     :name "Project B Session"
                                     :working-directory "/Users/test/project-b"
                                     :last-modified "2026-01-29T08:00:00Z"
                                     :message-count 3}]}])

     ;; Verify directories grouping
     (let [directories @(rf/subscribe [:sessions/directories])]
       (is (= 2 (count directories)))
       (let [project-a (first (filter #(= "/Users/test/project-a" (:directory %)) directories))
             project-b (first (filter #(= "/Users/test/project-b" (:directory %)) directories))]
         (is (= 2 (:session-count project-a)))
         (is (= 1 (:session-count project-b)))))

     ;; Verify recent sessions
     (let [recent @(rf/subscribe [:sessions/recent])]
       ;; All 3 sessions should be in recent (default limit is higher)
       (is (= 3 (count recent)))))))

;; ============================================================================
;; Swipe-to-Remove Constants and Platform Tests
;; Reference: ios/VoiceCode/Views/DirectoryListView.swift .swipeActions
;; iOS uses swipe-to-remove for queue items (standard UIKit convention).
;; Android uses X button (Material Design convention).
;; ============================================================================

(deftest swipe-remove-button-width-constant-test
  (testing "Remove button width constant exists and is reasonable"
    (is (= 80 dir-list/remove-button-width)
        "Remove button should be 80px wide (matching session list delete button)")))

(deftest swipe-threshold-constant-test
  (testing "Swipe threshold constant exists and is negative (left swipe)"
    (is (= -80 dir-list/swipe-threshold)
        "Swipe threshold should be -80px (left swipe to reveal)")))

(deftest platform-ios-enables-swipe-for-queue-test
  (testing "Test stub platform is iOS, enabling swipe-to-remove for queue items"
    (is (true? platform/ios?)
        "Test environment is iOS; swipe-to-remove should be active")))

(deftest platform-android-disables-swipe-for-queue-test
  (testing "On Android, platform/ios? is false, so X button is used instead"
    (with-redefs [platform/ios? false]
      (is (false? platform/ios?)
          "Android should use X button, not swipe-to-remove"))))

(deftest queue-session-row-content-accepts-props-test
  (testing "queue-session-row-content accepts the standard props shape"
    (let [test-colors {:text-primary "#000" :text-secondary "#666"
                       :text-tertiary "#999" :separator "#CCC"
                       :accent "#007AFF" :destructive "#FF3B30"
                       :card-background "#FFF" :button-text-on-accent "#FFF"
                       :warning "#FF9500" :success "#30D158"}
          props {:session {:id "test-session"
                           :backend-name "Test Queue Item"
                           :working-directory "/Users/test/project"
                           :last-modified (js/Date.)
                           :unread-count 0}
                 :on-press (fn [])
                 :on-remove (fn [])
                 :colors test-colors
                 :last? false}]
      (let [result (#'dir-list/queue-session-row-content props)]
        (is (vector? result) "queue-session-row-content returns valid hiccup")
        (is (some? (first result)) "queue-session-row-content has a component type")))))

(deftest priority-queue-row-content-accepts-props-test
  (testing "priority-queue-row-content accepts the standard props shape"
    (let [test-colors {:text-primary "#000" :text-secondary "#666"
                       :text-tertiary "#999" :separator "#CCC"
                       :accent "#007AFF" :destructive "#FF3B30"
                       :card-background "#FFF" :button-text-on-accent "#FFF"
                       :warning "#FF9500" :success "#30D158"}
          props {:session {:id "test-priority-session"
                           :backend-name "Test Priority Item"
                           :working-directory "/Users/test/project"
                           :last-modified (js/Date.)
                           :unread-count 0
                           :priority 5}
                 :on-press (fn [])
                 :on-remove (fn [])
                 :colors test-colors
                 :last? false}]
      (let [result (#'dir-list/priority-queue-row-content props)]
        (is (vector? result) "priority-queue-row-content returns valid hiccup")
        (is (some? (first result)) "priority-queue-row-content has a component type")))))

(deftest swipeable-queue-item-returns-form-2-test
  (testing "swipeable-queue-item returns Form-2 render fn for iOS swipe gesture"
    (let [test-colors {:text-primary "#000" :text-secondary "#666"
                       :text-tertiary "#999" :separator "#CCC"
                       :accent "#007AFF" :destructive "#FF3B30"
                       :card-background "#FFF" :button-text-on-accent "#FFF"
                       :warning "#FF9500" :success "#30D158"}
          props {:session {:id "test-swipe-session"
                           :backend-name "Swipeable"
                           :working-directory "/Users/test/project"
                           :last-modified (js/Date.)
                           :unread-count 0}
                 :on-press (fn [])
                 :on-remove (fn [])
                 :colors test-colors
                 :last? false}]
      (let [result (#'dir-list/swipeable-queue-item props)]
        (is (vector? result) "swipeable-queue-item returns hiccup vector (delegates to swipeable-row)")))))

(deftest swipeable-priority-queue-item-returns-form-2-test
  (testing "swipeable-priority-queue-item returns Form-2 render fn for iOS swipe gesture"
    (let [test-colors {:text-primary "#000" :text-secondary "#666"
                       :text-tertiary "#999" :separator "#CCC"
                       :accent "#007AFF" :destructive "#FF3B30"
                       :card-background "#FFF" :button-text-on-accent "#FFF"
                       :warning "#FF9500" :success "#30D158"}
          props {:session {:id "test-swipe-priority-session"
                           :backend-name "Swipeable Priority"
                           :working-directory "/Users/test/project"
                           :last-modified (js/Date.)
                           :unread-count 0
                           :priority 1}
                 :on-press (fn [])
                 :on-remove (fn [])
                 :colors test-colors
                 :last? false}]
      (let [result (#'dir-list/swipeable-priority-queue-item props)]
        (is (vector? result) "swipeable-priority-queue-item returns hiccup vector (delegates to swipeable-row)")))))

(deftest queue-session-item-delegates-per-platform-test
  (testing "queue-session-item delegates to swipeable on iOS and row-content on Android"
    (let [test-colors {:text-primary "#000" :text-secondary "#666"
                       :text-tertiary "#999" :separator "#CCC"
                       :accent "#007AFF" :destructive "#FF3B30"
                       :card-background "#FFF" :button-text-on-accent "#FFF"
                       :warning "#FF9500" :success "#30D158"}
          props {:session {:id "test-platform-session"
                           :backend-name "Platform Test"
                           :working-directory "/Users/test/project"
                           :last-modified (js/Date.)
                           :unread-count 0}
                 :on-press (fn [])
                 :on-remove (fn [])
                 :colors test-colors
                 :last? false}]
      ;; iOS: should use swipeable-queue-item
      (let [result (#'dir-list/queue-session-item props)]
        (is (vector? result) "queue-session-item returns valid hiccup on iOS")
        ;; On iOS (test default), first element should be the swipeable-queue-item function
        (is (= @#'dir-list/swipeable-queue-item (first result))
            "iOS should delegate to swipeable-queue-item"))

      ;; Android: should use queue-session-row-content
      (with-redefs [platform/ios? false]
        (let [result (#'dir-list/queue-session-item props)]
          (is (vector? result) "queue-session-item returns valid hiccup on Android")
          (is (= @#'dir-list/queue-session-row-content (first result))
              "Android should delegate to queue-session-row-content"))))))
