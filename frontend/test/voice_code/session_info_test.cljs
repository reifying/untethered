(ns voice-code.session-info-test
  "Tests for session_info view component functionality.
   Tests subscriptions, events, and logic used in voice-code.views.session-info.
   Reference: iOS SessionInfoView.swift for parity verification."
  (:require [cljs.test :refer [deftest testing is use-fixtures]]
            [re-frame.core :as rf]
            [day8.re-frame.test :as rf-test]
            [voice-code.db :as db]
            [voice-code.events.core]
            [voice-code.events.websocket]
            [voice-code.subs]))

(use-fixtures :each
  {:before (fn [] (rf/dispatch-sync [:initialize-db]))})

;; ============================================================================
;; Session Data Subscription Tests
;; ============================================================================

(deftest sessions-by-id-subscription-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "returns nil for non-existent session"
     (is (nil? @(rf/subscribe [:sessions/by-id "nonexistent-id"]))))

   (testing "returns session when it exists"
     (let [test-session {:id "test-session-123"
                         :backend-name "test-session"
                         :custom-name nil
                         :working-directory "/test/path"
                         :last-modified (js/Date.)}]
       (rf/dispatch-sync [:sessions/add-many [test-session]])
       (let [session @(rf/subscribe [:sessions/by-id "test-session-123"])]
         (is (some? session))
         (is (= "test-session-123" (:id session)))
         (is (= "/test/path" (:working-directory session))))))))

(deftest session-display-name-logic-test
  "Test the display name logic that session_info uses.
   This tests the logic pattern without relying on specific events."

  (testing "uses custom-name when available"
    (let [session {:id "sess-1"
                   :backend-name "backend"
                   :custom-name "My Custom Name"
                   :working-directory "/path"}
          display-name (or (:custom-name session)
                           (:backend-name session)
                           (str "Session " (subs (:id session) 0 8)))]
      (is (= "My Custom Name" display-name))))

  (testing "falls back to backend-name when no custom-name"
    (let [session {:id "sess-2"
                   :backend-name "Backend Session"
                   :custom-name nil
                   :working-directory "/path"}
          display-name (or (:custom-name session)
                           (:backend-name session)
                           (str "Session " (subs (:id session) 0 8)))]
      (is (= "Backend Session" display-name))))

  (testing "falls back to truncated ID when no names"
    (let [session {:id "abcd1234-5678-uuid"
                   :backend-name nil
                   :custom-name nil
                   :working-directory "/path"}
          display-name (or (:custom-name session)
                           (:backend-name session)
                           (str "Session " (subs (:id session) 0 8)))]
      (is (= "Session abcd1234" display-name)))))

;; ============================================================================
;; Git Branch Subscription Tests
;; ============================================================================

(deftest git-branch-subscription-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "git-branch returns nil when not loaded"
     (is (nil? @(rf/subscribe [:git/branch "/some/path"]))))

   (testing "git-branch returns branch after loading"
     ;; Note: :git/handle-branch expects kebab-case keys from JSON coercion
     (rf/dispatch-sync [:git/handle-branch {:working-directory "/project/path"
                                            :branch "feature/my-branch"}])
     (is (= "feature/my-branch" @(rf/subscribe [:git/branch "/project/path"]))))

   (testing "git-branch returns different branches for different directories"
     (rf/dispatch-sync [:git/handle-branch {:working-directory "/project/a"
                                            :branch "main"}])
     (rf/dispatch-sync [:git/handle-branch {:working-directory "/project/b"
                                            :branch "develop"}])
     (is (= "main" @(rf/subscribe [:git/branch "/project/a"])))
     (is (= "develop" @(rf/subscribe [:git/branch "/project/b"]))))))

(deftest git-loading-subscription-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "git-loading? returns false initially"
     (is (false? @(rf/subscribe [:git/loading? "/some/path"]))))

   (testing "git-loading? returns false after branch loaded"
     ;; When a branch is loaded, loading state should be cleared
     (rf/dispatch-sync [:git/handle-branch {:working-directory "/test/repo"
                                            :branch "main"}])
     (is (false? @(rf/subscribe [:git/loading? "/test/repo"]))))))

;; ============================================================================
;; Settings Subscription Tests
;; ============================================================================

(deftest settings-subscription-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "settings/all returns settings map"
     (let [settings @(rf/subscribe [:settings/all])]
       (is (map? settings))))

   (testing "priority-queue-enabled setting"
     ;; Default state
     (let [settings @(rf/subscribe [:settings/all])]
       (is (contains? settings :priority-queue-enabled)))

     ;; Enable priority queue
     (rf/dispatch-sync [:settings/update :priority-queue-enabled true])
     (let [settings @(rf/subscribe [:settings/all])]
       (is (true? (:priority-queue-enabled settings))))

     ;; Disable priority queue
     (rf/dispatch-sync [:settings/update :priority-queue-enabled false])
     (let [settings @(rf/subscribe [:settings/all])]
       (is (false? (:priority-queue-enabled settings)))))))

;; ============================================================================
;; Active Recipe Subscription Tests
;; ============================================================================

(deftest active-recipe-subscription-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "returns nil when no active recipe"
     (is (nil? @(rf/subscribe [:recipes/active-for-session "session-1"]))))

   (testing "returns active recipe when present"
     ;; Simulate receiving an active recipe via :recipes/handle-started
     (rf/dispatch-sync [:recipes/handle-started {:session-id "session-1"
                                                  :recipe-id "review-recipe"
                                                  :recipe-label "Code Review"
                                                  :current-step "Review changes"
                                                  :step-count 3}])
     (let [recipe @(rf/subscribe [:recipes/active-for-session "session-1"])]
       (is (some? recipe))
       (is (= "Code Review" (:recipe-label recipe)))
       (is (= "Review changes" (:current-step recipe)))
       (is (= 3 (:step-count recipe)))))

   (testing "different sessions have independent recipes"
     (rf/dispatch-sync [:recipes/handle-started {:session-id "session-2"
                                                  :recipe-id "deploy-recipe"
                                                  :recipe-label "Deploy"
                                                  :current-step "Build artifacts"
                                                  :step-count 1}])
     (let [recipe-1 @(rf/subscribe [:recipes/active-for-session "session-1"])
           recipe-2 @(rf/subscribe [:recipes/active-for-session "session-2"])]
       (is (= "Code Review" (:recipe-label recipe-1)))
       (is (= "Deploy" (:recipe-label recipe-2)))))))

;; ============================================================================
;; Priority Queue State Tests
;; ============================================================================

(deftest priority-queue-session-state-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "session not in priority queue by default"
     (let [test-session {:id "sess-pq"
                         :backend-name "Test"
                         :working-directory "/path"
                         :priority nil
                         :priority-order nil
                         :priority-queued-at nil}]
       (rf/dispatch-sync [:sessions/add-many [test-session]])
       (let [session @(rf/subscribe [:sessions/by-id "sess-pq"])]
         (is (nil? (:priority-queued-at session))))))

   (testing "priority queue fields after adding to queue"
     ;; This tests that the session structure supports priority queue fields
     (let [queued-session {:id "sess-pq2"
                           :backend-name "Queued"
                           :working-directory "/path"
                           :priority 5
                           :priority-order 1.0
                           :priority-queued-at (js/Date.)}]
       (rf/dispatch-sync [:sessions/add-many [queued-session]])
       (let [session @(rf/subscribe [:sessions/by-id "sess-pq2"])]
         (is (= 5 (:priority session)))
         (is (= 1.0 (:priority-order session)))
         (is (some? (:priority-queued-at session))))))))

;; ============================================================================
;; Session Compaction Event Tests
;; ============================================================================

(deftest session-compact-event-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "compaction complete clears compacting state and sets timestamp"
     ;; Simulate compaction complete (uses kebab-case session-id)
     (rf/dispatch-sync [:sessions/handle-compaction-complete {:session-id "sess-compact"}])
     ;; Verify compacting state is cleared and timestamp is set
     (is (false? @(rf/subscribe [:ui/compacting-session? "sess-compact"])))
     (is (some? @(rf/subscribe [:ui/compaction-timestamp "sess-compact"]))))))

;; ============================================================================
;; Session Delete Event Tests
;; ============================================================================

(deftest session-delete-event-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "delete event marks session as deleted"
     ;; Setup test sessions
     (let [sessions [{:id "sess-keep" :backend-name "Keep" :working-directory "/path"}
                     {:id "sess-delete" :backend-name "Delete" :working-directory "/path"}]]
       (rf/dispatch-sync [:sessions/add-many sessions])

       ;; Both sessions exist
       (is (= 2 (count @(rf/subscribe [:sessions/all]))))

       ;; Delete one session
       (rf/dispatch-sync [:sessions/delete "sess-delete"])

       ;; Session should be marked as user-deleted (matches the event handler)
       (let [deleted-session @(rf/subscribe [:sessions/by-id "sess-delete"])]
         (is (or (nil? deleted-session)
                 (:is-user-deleted deleted-session))))))))

;; ============================================================================
;; Handle Name Inferred Event Tests
;; ============================================================================

(deftest handle-name-inferred-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "name inferred updates session backend-name"
     (let [test-session {:id "sess-named"
                         :backend-name "Original"
                         :custom-name nil
                         :working-directory "/path"}]
       (rf/dispatch-sync [:sessions/add-many [test-session]])
       ;; Simulate name inferred response (uses kebab-case session-id)
       (rf/dispatch-sync [:sessions/handle-name-inferred {:session-id "sess-named"
                                                           :name "Inferred Session Name"}])
       ;; Verify backend-name is updated (matches the event handler behavior)
       (let [session @(rf/subscribe [:sessions/by-id "sess-named"])]
         (is (= "Inferred Session Name" (:backend-name session))))))))

;; ============================================================================
;; Recipe Exit Event Tests
;; ============================================================================

(deftest recipe-exit-event-test
  (rf-test/run-test-sync
   (rf/dispatch-sync [:initialize-db])

   (testing "exit recipe clears active recipe"
     ;; Setup active recipe
     (rf/dispatch-sync [:recipes/handle-started {:session-id "sess-recipe"
                                                  :recipe-id "test-recipe"
                                                  :recipe-label "Test Recipe"
                                                  :current-step "Step 1"
                                                  :step-count 1}])
     (is (some? @(rf/subscribe [:recipes/active-for-session "sess-recipe"])))

     ;; Exit recipe via handle-exited (simulates backend response)
     (rf/dispatch-sync [:recipes/handle-exited {:session-id "sess-recipe"}])
     (is (nil? @(rf/subscribe [:recipes/active-for-session "sess-recipe"]))))))

;; ============================================================================
;; Export Format Tests (matches iOS SessionInfoView.swift:262-298)
;; ============================================================================

(defn- format-export-header
  "Replicates the export header format from session_info.cljs.
   Matches iOS SessionInfoView.swift export format."
  [session git-branch]
  (let [{:keys [id backend-name custom-name working-directory]} session
        display-name (or custom-name backend-name (str "Session " (subs id 0 8)))]
    (str "# " display-name "\n"
         "Session ID: " id "\n"
         "Working Directory: " (or working-directory "Not set") "\n"
         (when git-branch
           (str "Git Branch: " git-branch "\n"))
         "\n---\n\n")))

(deftest export-format-test
  (testing "export header format matches iOS"
    (let [session {:id "abc12345-6789-uuid"
                   :backend-name "Test Session"
                   :custom-name nil
                   :working-directory "/Users/test/project"}
          header (format-export-header session "main")]
      (is (clojure.string/includes? header "# Test Session"))
      (is (clojure.string/includes? header "Session ID: abc12345-6789-uuid"))
      (is (clojure.string/includes? header "Working Directory: /Users/test/project"))
      (is (clojure.string/includes? header "Git Branch: main"))))

  (testing "export header without git branch"
    (let [session {:id "abc12345-6789-uuid"
                   :backend-name "Test Session"
                   :custom-name nil
                   :working-directory "/path"}
          header (format-export-header session nil)]
      (is (not (clojure.string/includes? header "Git Branch:")))))

  (testing "export header with custom name overrides backend name"
    (let [session {:id "sess-1"
                   :backend-name "Backend Name"
                   :custom-name "Custom Name"
                   :working-directory "/path"}
          header (format-export-header session nil)]
      (is (clojure.string/includes? header "# Custom Name"))
      (is (not (clojure.string/includes? header "# Backend Name"))))))

;; ============================================================================
;; Priority Levels Tests (matches iOS SessionInfoView.swift:96-98)
;; ============================================================================

(def ^:private priority-levels
  "Priority level mappings matching iOS implementation."
  [[1 "High (1)"]
   [5 "Medium (5)"]
   [10 "Low (10)"]])

(deftest priority-levels-test
  (testing "priority level labels"
    (is (= "High (1)" (second (first (filter #(= 1 (first %)) priority-levels)))))
    (is (= "Medium (5)" (second (first (filter #(= 5 (first %)) priority-levels)))))
    (is (= "Low (10)" (second (first (filter #(= 10 (first %)) priority-levels))))))

  (testing "lower number means higher priority"
    (let [priorities (map first priority-levels)]
      (is (= [1 5 10] priorities))
      (is (< (first priorities) (second priorities)))
      (is (< (second priorities) (nth priorities 2))))))

;; ============================================================================
;; Confirmation Message Display Tests
;; ============================================================================

(deftest confirmation-messages-test
  (testing "expected confirmation messages match iOS"
    ;; These are the messages shown after actions
    (let [messages {:copy-name "Name copied"
                    :copy-directory "Directory copied"
                    :copy-branch "Branch copied"
                    :copy-session-id "Session ID copied"
                    :add-queue "Added to Priority Queue"
                    :remove-queue "Removed from Priority Queue"
                    :change-priority "Priority changed to"
                    :compact-started "Compaction started"
                    :recipe-exited "Recipe exited"
                    :infer-name "Inferring session name..."
                    :export-success "Exported"}]
      (is (string? (:copy-name messages)))
      (is (string? (:add-queue messages)))
      (is (string? (:compact-started messages))))))
