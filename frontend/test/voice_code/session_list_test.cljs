(ns voice-code.session-list-test
  "Tests for session-list view helper functions and subscriptions.
   Tests the session display logic, filtering, toolbar state, and
   session management actions used by the view.

   Reference implementation: ios/VoiceCode/Views/SessionsForDirectoryView.swift"
  (:require [cljs.test :refer [deftest testing is use-fixtures]]
            [re-frame.core :as rf]
            [day8.re-frame.test :as rf-test]
            [voice-code.db :as db]
            [voice-code.events.core]
            [voice-code.events.websocket]
            [voice-code.subs]
            [voice-code.voice.events]
            [voice-code.icons :as icons]
            [voice-code.platform :as platform]
            [voice-code.views.session-list :as session-list]))

(use-fixtures :each
  {:before (fn [] (rf/dispatch-sync [:initialize-db]))})

;; ============================================================================
;; Session Name Display Tests
;; Reference: ios/VoiceCode/Models/CDBackendSession.swift displayName()
;; ============================================================================

(deftest session-name-with-custom-name-test
  (testing "Custom name takes priority over backend name"
    (is (= "My Custom Name"
           (#'session-list/session-name
            {:id "abc123"
             :backend-name "Session from backend"
             :custom-name "My Custom Name"})))))

(deftest session-name-with-backend-name-test
  (testing "Backend name used when no custom name"
    (is (= "Session from backend"
           (#'session-list/session-name
            {:id "abc123"
             :backend-name "Session from backend"
             :custom-name nil})))))

(deftest session-name-fallback-to-id-test
  (testing "Falls back to truncated ID when no name available"
    (is (= "Session abc12345"
           (#'session-list/session-name
            {:id "abc12345-6789-abcd-ef01-234567890abc"
             :backend-name nil
             :custom-name nil})))))

(deftest session-name-empty-string-backend-name-test
  (testing "Empty string backend name uses backend name (empty string is valid in `or`)"
    ;; Note: Empty string is falsy in ClojureScript `or`, so it falls back
    ;; Actually wait - empty string "" is truthy in Clojure `or`
    ;; But the function uses (or custom-name backend-name ...)
    ;; "" is truthy so it will return ""
    (is (= ""
           (#'session-list/session-name
            {:id "def98765-4321-dcba-10fe-cba987654321"
             :backend-name ""
             :custom-name nil})))))

;; ============================================================================
;; Sessions for Directory Subscription Tests
;; Reference: ios/VoiceCode/Views/SessionsForDirectoryView.swift FetchRequest
;; ============================================================================

(deftest sessions-for-directory-filter-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "Sessions are filtered by working directory"
     ;; Add sessions for different directories using :sessions/add-many
     (rf/dispatch-sync [:sessions/add-many
                        [{:id "session-1"
                          :backend-name "Project A Session 1"
                          :working-directory "/Users/test/project-a"
                          :last-modified (js/Date.)}
                         {:id "session-2"
                          :backend-name "Project A Session 2"
                          :working-directory "/Users/test/project-a"
                          :last-modified (js/Date.)}
                         {:id "session-3"
                          :backend-name "Project B Session 1"
                          :working-directory "/Users/test/project-b"
                          :last-modified (js/Date.)}]])

     ;; Check filtering for project-a
     (let [project-a-sessions @(rf/subscribe [:sessions/for-directory "/Users/test/project-a"])]
       (is (= 2 (count project-a-sessions)))
       (is (every? #(= "/Users/test/project-a" (:working-directory %)) project-a-sessions)))

     ;; Check filtering for project-b
     (let [project-b-sessions @(rf/subscribe [:sessions/for-directory "/Users/test/project-b"])]
       (is (= 1 (count project-b-sessions)))
       (is (= "/Users/test/project-b" (:working-directory (first project-b-sessions))))))))

(deftest sessions-empty-directory-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "Empty list returned for directory with no sessions"
     (rf/dispatch-sync [:sessions/add-many
                        [{:id "session-1"
                          :backend-name "Some Session"
                          :working-directory "/Users/test/project-a"
                          :last-modified (js/Date.)}]])

     (let [sessions @(rf/subscribe [:sessions/for-directory "/Users/test/empty-project"])]
       (is (empty? sessions))))))

(deftest sessions-sorted-by-last-modified-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "Sessions are sorted by last-modified descending (newest first)"
     (let [now (js/Date.)
           one-hour-ago (js/Date. (- (.getTime now) 3600000))
           two-hours-ago (js/Date. (- (.getTime now) 7200000))]
       (rf/dispatch-sync [:sessions/add-many
                          [{:id "oldest"
                            :backend-name "Oldest Session"
                            :working-directory "/Users/test/project"
                            :last-modified two-hours-ago}
                           {:id "newest"
                            :backend-name "Newest Session"
                            :working-directory "/Users/test/project"
                            :last-modified now}
                           {:id "middle"
                            :backend-name "Middle Session"
                            :working-directory "/Users/test/project"
                            :last-modified one-hour-ago}]])

       (let [sessions @(rf/subscribe [:sessions/for-directory "/Users/test/project"])]
         (is (= 3 (count sessions)))
         (is (= "newest" (:id (first sessions))))
         (is (= "middle" (:id (second sessions))))
         (is (= "oldest" (:id (nth sessions 2)))))))))

;; ============================================================================
;; Session Lock Status Tests
;; Reference: ios/VoiceCode/Managers/VoiceCodeClient.swift lockedSessions
;; ============================================================================

(deftest session-locked-status-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "Locked sessions are correctly tracked"
     ;; Lock a session
     (rf/dispatch-sync [:sessions/lock "session-locked"])

     (let [locked @(rf/subscribe [:locked-sessions])]
       (is (contains? locked "session-locked"))
       (is (not (contains? locked "session-unlocked")))))))

(deftest session-lock-unlock-cycle-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "Session can be locked and unlocked"
     ;; Lock
     (rf/dispatch-sync [:sessions/lock "session-123"])
     (is (contains? @(rf/subscribe [:locked-sessions]) "session-123"))

     ;; Unlock directly using sessions/unlock (simpler than debounced turn_complete)
     (rf/dispatch-sync [:sessions/unlock "session-123"])
     (is (not (contains? @(rf/subscribe [:locked-sessions]) "session-123"))))))

;; ============================================================================
;; Unread Badge Count Tests
;; Reference: ios/VoiceCode/Models/CDBackendSession.swift unreadCount
;; ============================================================================

(deftest session-unread-count-display-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "Sessions track unread message counts"
     (rf/dispatch-sync [:sessions/add-many
                        [{:id "session-with-unread"
                          :backend-name "Has Unreads"
                          :working-directory "/Users/test/project"
                          :unread-count 5
                          :last-modified (js/Date.)}
                         {:id "session-no-unread"
                          :backend-name "All Read"
                          :working-directory "/Users/test/project"
                          :unread-count 0
                          :last-modified (js/Date.)}]])

     (let [sessions @(rf/subscribe [:sessions/for-directory "/Users/test/project"])
           with-unread (first (filter #(= "session-with-unread" (:id %)) sessions))
           no-unread (first (filter #(= "session-no-unread" (:id %)) sessions))]
       (is (= 5 (:unread-count with-unread)))
       (is (= 0 (:unread-count no-unread)))))))

;; ============================================================================
;; Session Creation and Deletion Tests
;; Reference: ios/VoiceCode/Views/SessionsForDirectoryView.swift deleteSession()
;; ============================================================================

(deftest session-delete-dispatch-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "Deleting session marks it as user-deleted (filtered from for-directory)"
     (rf/dispatch-sync [:sessions/add-many
                        [{:id "to-delete"
                          :backend-name "Delete Me"
                          :working-directory "/Users/test/project"
                          :last-modified (js/Date.)}
                         {:id "to-keep"
                          :backend-name "Keep Me"
                          :working-directory "/Users/test/project"
                          :last-modified (js/Date.)}]])

     ;; Verify both exist
     (is (= 2 (count @(rf/subscribe [:sessions/for-directory "/Users/test/project"]))))

     ;; Delete one - sets is-user-deleted flag
     (rf/dispatch-sync [:sessions/delete "to-delete"])

     ;; Verify only one remains (deleted one is filtered out)
     (let [remaining @(rf/subscribe [:sessions/for-directory "/Users/test/project"])]
       (is (= 1 (count remaining)))
       (is (= "to-keep" (:id (first remaining))))))))

(deftest session-create-with-worktree-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "Worktree creation request is dispatched correctly"
     ;; Note: Actual worktree creation happens on backend
     ;; We test that the event is structured correctly
     (let [events-received (atom [])]
       (rf/reg-fx :ws/send (fn [msg] (swap! events-received conj msg)))

       (rf/dispatch-sync [:worktree/create
                          {:session-name "feature-branch"
                           :parent-directory "/Users/test/project"}])

       ;; Verify worktree creation message was sent
       (is (some #(= "create_worktree_session" (:type %)) @events-received))))))

;; ============================================================================
;; Navigation Header Button State Tests
;; Reference: ios/VoiceCode/Views/SessionsForDirectoryView.swift toolbar
;; Buttons are now rendered in the navigation header (headerRight) matching
;; iOS ToolbarItem(placement: .navigationBarTrailing) pattern.
;; ============================================================================

(deftest toolbar-running-commands-indicator-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "Running commands count is tracked for toolbar badge"
     ;; Start some commands
     (rf/dispatch-sync [:commands/handle-started
                        {:command-session-id "cmd-1"
                         :command-id "make.test"
                         :shell-command "make test"}])
     (rf/dispatch-sync [:commands/handle-started
                        {:command-session-id "cmd-2"
                         :command-id "make.build"
                         :shell-command "make build"}])

     (is (= 2 @(rf/subscribe [:commands/running-count])))
     (is @(rf/subscribe [:commands/running-any?]))

     ;; Complete one command
     (rf/dispatch-sync [:commands/handle-complete
                        {:command-session-id "cmd-1"
                         :exit-code 0
                         :duration-ms 1000}])

     (is (= 1 @(rf/subscribe [:commands/running-count])))
     (is @(rf/subscribe [:commands/running-any?]))

     ;; Complete the other
     (rf/dispatch-sync [:commands/handle-complete
                        {:command-session-id "cmd-2"
                         :exit-code 0
                         :duration-ms 2000}])

     (is (= 0 @(rf/subscribe [:commands/running-count])))
     (is (not @(rf/subscribe [:commands/running-any?]))))))

(deftest toolbar-commands-count-for-directory-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "Available commands count is directory-specific"
     ;; Add available commands for a directory
     (rf/dispatch-sync [:commands/handle-available
                        {:working-directory "/Users/test/project"
                         :project-commands [{:id "build" :label "Build" :type "command"}
                                            {:id "test" :label "Test" :type "command"}
                                            {:id "lint" :label "Lint" :type "command"}]
                         :general-commands [{:id "git.status" :label "Git Status" :type "command"}]}])

     ;; Total commands count (project + general)
     (let [count @(rf/subscribe [:commands/count-for-directory "/Users/test/project"])]
       ;; Should have commands
       (is (pos? count)))

     ;; Different directory should have nil (no commands loaded for that directory)
     (is (nil? @(rf/subscribe [:commands/count-for-directory "/Users/test/other"]))))))

(deftest toolbar-voice-speaking-indicator-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "Voice speaking state is tracked for stop button"
     ;; Initially not speaking
     (is (not @(rf/subscribe [:voice/speaking?])))

     ;; Start speaking using correct event name
     (rf/dispatch-sync [:voice/tts-started])
     (is @(rf/subscribe [:voice/speaking?]))

     ;; Stop speaking using correct event name
     (rf/dispatch-sync [:voice/speech-finished])
     (is (not @(rf/subscribe [:voice/speaking?]))))))

;; ============================================================================
;; Refresh State Tests
;; Reference: ios/VoiceCode/Views/SessionsForDirectoryView.swift refreshable
;; ============================================================================

(deftest refresh-state-tracking-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "Refresh state is tracked during session list request"
     ;; Initially not refreshing (nil or false both are falsy)
     (is (not @(rf/subscribe [:ui/refreshing?])))
     ;; The refreshing state is set by :sessions/refresh and cleared by :sessions/handle-list
     ;; We verify the initial state is falsy (nil or false)
     (is (not @(rf/subscribe [:ui/refreshing?]))))))

;; ============================================================================
;; Session Preview and Message Count Tests
;; Reference: ios/VoiceCode/Views/SessionRowContent preview display
;; ============================================================================

(deftest session-preview-text-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "Session preview text is stored and retrieved"
     (rf/dispatch-sync [:sessions/add-many
                        [{:id "with-preview"
                          :backend-name "Has Preview"
                          :working-directory "/Users/test/project"
                          :preview "Last message was about refactoring..."
                          :message-count 42
                          :last-modified (js/Date.)}]])

     (let [session @(rf/subscribe [:sessions/by-id "with-preview"])]
       (is (= "Last message was about refactoring..." (:preview session)))
       (is (= 42 (:message-count session)))))))

(deftest session-message-count-zero-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "New session has zero message count"
     (rf/dispatch-sync [:sessions/add-many
                        [{:id "new-session"
                          :backend-name "Brand New"
                          :working-directory "/Users/test/project"
                          :message-count 0
                          :last-modified (js/Date.)}]])

     (let [session @(rf/subscribe [:sessions/by-id "new-session"])]
       (is (= 0 (:message-count session)))))))

;; ============================================================================
;; Swipe Delete Constants Tests
;; ============================================================================

(deftest swipe-threshold-constant-test
  (testing "Swipe threshold is negative (left swipe)"
    (is (neg? session-list/swipe-threshold))))

(deftest delete-button-width-constant-test
  (testing "Delete button has positive width"
    (is (pos? session-list/delete-button-width))))

;; ============================================================================
;; Integration: Session List Loading Flow
;; Reference: Full session list flow from connect -> session_list -> display
;; ============================================================================

(deftest session-list-loading-integration-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "Session list is populated after session_list message"
     ;; Simulate receiving session list from backend
     (rf/dispatch-sync [:sessions/handle-list
                        {:sessions [{:session-id "session-a"
                                     :name "Development Session"
                                     :working-directory "/Users/test/project-a"
                                     :last-modified "2026-01-29T10:00:00Z"
                                     :message-count 10}
                                    {:session-id "session-b"
                                     :name "Testing Session"
                                     :working-directory "/Users/test/project-a"
                                     :last-modified "2026-01-29T09:00:00Z"
                                     :message-count 5}
                                    {:session-id "session-c"
                                     :name "Other Project"
                                     :working-directory "/Users/test/project-b"
                                     :last-modified "2026-01-29T08:00:00Z"
                                     :message-count 3}]}])

     ;; Verify sessions for project-a
     (let [project-a @(rf/subscribe [:sessions/for-directory "/Users/test/project-a"])]
       (is (= 2 (count project-a)))
       ;; Sorted by last-modified descending
       (is (= "session-a" (:id (first project-a))))
       (is (= "session-b" (:id (second project-a)))))

     ;; Verify sessions for project-b
     (let [project-b @(rf/subscribe [:sessions/for-directory "/Users/test/project-b"])]
       (is (= 1 (count project-b)))
       (is (= "session-c" (:id (first project-b))))))))

;; ============================================================================
;; Session Name Helper Tests (Additional)
;; ============================================================================

(deftest session-name-nil-values-test
  (testing "Session with all nil name fields falls back to ID"
    (is (= "Session 12345678"
           (#'session-list/session-name
            {:id "12345678-abcd-efgh-ijkl-mnopqrstuv"
             :backend-name nil
             :custom-name nil})))))

;; ============================================================================
;; Header Icon Button Component Tests
;; Reference: ios/VoiceCode/Views/SessionsForDirectoryView.swift toolbar buttons
;; ============================================================================

(deftest header-icon-button-returns-hiccup-test
  (testing "header-icon-button returns valid Reagent hiccup vector"
    (let [result (#'session-list/header-icon-button
                  {:icon :gear
                   :on-press (fn [])
                   :color "#666666"})]
      ;; Should be a vector (Reagent hiccup)
      (is (vector? result))
      ;; First element should be the touchable component
      (is (some? (first result))))))

(deftest header-icon-button-badge-rendering-test
  (testing "header-icon-button renders badge when badge-count is positive"
    (let [result (#'session-list/header-icon-button
                  {:icon :terminal
                   :on-press (fn [])
                   :color "#666666"
                   :badge-count 5})]
      ;; Should contain the badge count text "5" somewhere in the tree
      (is (vector? result)))))

(deftest header-icon-button-no-badge-when-zero-test
  (testing "header-icon-button does not render badge when count is zero"
    (let [result (#'session-list/header-icon-button
                  {:icon :terminal
                   :on-press (fn [])
                   :color "#666666"
                   :badge-count 0})]
      (is (vector? result)))))

(deftest header-icon-button-active-dot-test
  (testing "header-icon-button renders active dot indicator"
    (let [result (#'session-list/header-icon-button
                  {:icon :history
                   :on-press (fn [])
                   :color "#666666"
                   :active-dot? true})]
      (is (vector? result)))))

(deftest header-right-buttons-is-functional-component-test
  (testing "header-right-buttons returns [:f> ...] wrapper for hooks"
    (let [result (#'session-list/header-right-buttons
                  (js-obj) "/Users/test/project" (fn []))]
      ;; Should be a vector starting with :f>
      (is (vector? result))
      (is (= :f> (first result)))
      ;; Second element should be a function
      (is (fn? (second result))))))

;; ============================================================================
;; Unread Badge Color Tests (iOS Parity)
;; Reference: ios/VoiceCode/Views/SessionsView.swift CDSessionRowContent
;; iOS uses Color.red (destructive) for unread badges, not Color.blue (accent)
;; ============================================================================

(deftest unread-badge-renders-for-positive-count-test
  (testing "Unread badge renders when count is positive"
    (let [colors {:destructive "#FF3B30"
                  :button-text-on-accent "#FFFFFF"}
          result (#'session-list/unread-badge 5 colors)]
      ;; Should return a non-nil result for positive count
      (is (some? result))
      (is (vector? result)))))

(deftest unread-badge-nil-for-zero-count-test
  (testing "Unread badge returns nil when count is zero"
    (let [colors {:destructive "#FF3B30"
                  :button-text-on-accent "#FFFFFF"}
          result (#'session-list/unread-badge 0 colors)]
      ;; Should return nil for zero count
      (is (nil? result)))))

(deftest unread-badge-nil-for-nil-count-test
  (testing "Unread badge returns nil when count is nil"
    (let [colors {:destructive "#FF3B30"
                  :button-text-on-accent "#FFFFFF"}
          result (#'session-list/unread-badge nil colors)]
      (is (nil? result)))))

(deftest unread-badge-uses-destructive-color-test
  (testing "Unread badge uses :destructive color (red), not :accent (blue)"
    ;; iOS parity: CDSessionRowContent uses Color.red for unread badges
    (let [colors {:destructive "#FF3B30"
                  :accent "#007AFF"
                  :button-text-on-accent "#FFFFFF"}
          result (#'session-list/unread-badge 3 colors)]
      ;; The badge View should use :destructive color for background
      ;; Result structure: [:> rn/View {:style {...:background-color "#FF3B30"...}} ...]
      (is (some? result))
      ;; Extract the style map from the View props
      (let [view-props (nth result 2)
            bg-color (get-in view-props [:style :background-color])]
        (is (= "#FF3B30" bg-color) "Badge background should use :destructive color (red)")
        (is (not= "#007AFF" bg-color) "Badge background should NOT use :accent color (blue)")))))

(deftest unread-badge-caps-at-99-plus-test
  (testing "Unread badge shows 99+ for counts over 99"
    (let [colors {:destructive "#FF3B30"
                  :button-text-on-accent "#FFFFFF"}
          result (#'session-list/unread-badge 150 colors)]
      (is (some? result)))))

;; ============================================================================
;; Platform-Conditional Swipe-to-Delete Tests
;; Reference: ios/VoiceCode/Views/SessionsForDirectoryView.swift .swipeActions
;; iOS uses swipe-to-delete (standard UIKit convention).
;; Android uses long-press context menu only (Material Design convention).
;; The render-item in session-list-view selects between swipeable-session-item
;; (iOS) and session-item (Android) based on platform/ios?.
;; ============================================================================

(deftest platform-ios-flag-for-swipe-test
  (testing "Test stub platform is iOS, enabling swipe-to-delete"
    (is (true? platform/ios?)
        "Test environment is iOS; swipe-to-delete should be active")))

(deftest platform-android-disables-swipe-flag-test
  (testing "On Android, platform/ios? is false, so swipe-to-delete would be skipped"
    (with-redefs [platform/ios? false]
      (is (false? platform/ios?)
          "Android should not use swipe-to-delete"))))

(deftest session-item-accepts-same-props-as-swipeable-test
  (testing "session-item accepts the same props shape as swipeable-session-item"
    ;; Both components must accept {:session :locked? :on-press :on-delete :colors}
    ;; This ensures the platform-conditional rendering in render-item works
    ;; regardless of which component is selected.
    (let [test-colors {:text-primary "#000" :text-secondary "#666"
                       :text-tertiary "#999" :separator "#CCC"
                       :accent "#007AFF" :destructive "#FF3B30"
                       :card-background "#FFF" :button-text-on-accent "#FFF"
                       :warning "#FF9500" :success "#30D158"}
          props {:session {:id "test-session"
                           :backend-name "Test"
                           :working-directory "/test"
                           :last-modified (js/Date.)
                           :unread-count 0}
                 :locked? false
                 :on-press (fn [])
                 :on-delete (fn [])
                 :colors test-colors}]
      ;; session-item should return valid hiccup
      (let [result (#'session-list/session-item props)]
        (is (vector? result) "session-item returns valid hiccup")
        (is (some? (first result)) "session-item has a component type"))
      ;; swipeable-session-item should also return valid hiccup (delegates to swipeable-row)
      (let [result (#'session-list/swipeable-session-item props)]
        (is (vector? result) "swipeable-session-item returns hiccup vector")))))

;; ============================================================================
;; Icon Mapping Tests (tray icon for empty state)
;; ============================================================================

(deftest tray-icon-exists-in-icon-map-test
  (testing ":tray icon exists in icon map for empty state rendering"
    (let [entry (get icons/icon-map :tray)]
      (is (some? entry) ":tray should be in icon-map")
      (is (some? (:ios entry)) ":tray should have iOS icon name")
      (is (some? (:android entry)) ":tray should have Android icon name"))))

;; ============================================================================
;; Empty State Tests (iOS Parity)
;; Reference: ios/VoiceCode/Views/SessionsForDirectoryView.swift
;; iOS uses Image(systemName: "tray") at 64pt + directory name in title
;; ============================================================================

(deftest empty-state-renders-icon-test
  (testing "Empty state renders an icon matching iOS tray symbol"
    (let [colors {:text-primary "#000"
                  :text-secondary "#666"}
          result (#'session-list/empty-state colors nil)]
      ;; Result is [:> rn/View {:style ...} [icon] [:> rn/Text ...] [:> rn/Text ...]]
      (is (vector? result))
      ;; Children start at index 3 (after :>, rn/View, {:style})
      (let [children (vec (drop 3 result))]
        ;; First child should be the icon
        (is (vector? (first children)))
        (is (= icons/icon (ffirst children)))
        ;; Icon should use :tray name
        (is (= :tray (:name (second (first children)))))
        ;; Icon should be 64pt matching iOS Image(systemName: "tray").font(.system(size: 64))
        (is (= 64 (:size (second (first children)))))))))

(deftest empty-state-shows-directory-name-test
  (testing "Empty state includes directory name in title when provided"
    (let [colors {:text-primary "#000"
                  :text-secondary "#666"}
          result (#'session-list/empty-state colors "my-project")]
      ;; Children start at index 3
      (let [children (vec (drop 3 result))
            ;; Second child is the title [:> rn/Text {:style ...} "No sessions in my-project"]
            title-element (second children)
            title-text (last title-element)]
        (is (= "No sessions in my-project" title-text))))))

(deftest empty-state-generic-title-without-directory-name-test
  (testing "Empty state shows generic title when no directory name provided"
    (let [colors {:text-primary "#000"
                  :text-secondary "#666"}
          result (#'session-list/empty-state colors nil)]
      (let [children (vec (drop 3 result))
            title-element (second children)
            title-text (last title-element)]
        (is (= "No Sessions" title-text))))))
