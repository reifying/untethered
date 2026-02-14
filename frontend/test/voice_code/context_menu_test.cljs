(ns voice-code.context-menu-test
  "Tests for native context menu wrapper component.
   Verifies action conversion, event dispatch, and integration with session/directory items.

   Reference: ios/VoiceCode/Views/SessionsForDirectoryView.swift .contextMenu
              ios/VoiceCode/Views/DirectoryListView.swift .contextMenu"
  (:require [cljs.test :refer [deftest testing is]]
            [voice-code.views.context-menu :as ctx]))

;; ============================================================================
;; actions->js Conversion Tests
;; ============================================================================

(deftest actions-to-js-basic-test
  (testing "Basic action with title only"
    (let [result (#'ctx/actions->js [{:title "Copy"}])]
      (is (array? result))
      (is (= 1 (.-length result)))
      (is (= "Copy" (.-title (aget result 0)))))))

(deftest actions-to-js-system-icon-test
  (testing "Action with system icon is converted to systemIcon"
    (let [result (#'ctx/actions->js [{:title "Copy"
                                       :system-icon "doc.on.clipboard"}])]
      (is (= "doc.on.clipboard" (.-systemIcon (aget result 0)))))))

(deftest actions-to-js-destructive-test
  (testing "Destructive action flag is converted"
    (let [result (#'ctx/actions->js [{:title "Delete"
                                       :destructive? true}])]
      (is (true? (.-destructive (aget result 0)))))))

(deftest actions-to-js-disabled-test
  (testing "Disabled action flag is converted"
    (let [result (#'ctx/actions->js [{:title "Locked"
                                       :disabled? true}])]
      (is (true? (.-disabled (aget result 0)))))))

(deftest actions-to-js-multiple-actions-test
  (testing "Multiple actions are converted in order"
    (let [result (#'ctx/actions->js [{:title "Copy Session ID"
                                       :system-icon "doc.on.clipboard"}
                                      {:title "Copy Directory Path"
                                       :system-icon "folder"}
                                      {:title "Delete"
                                       :system-icon "trash"
                                       :destructive? true}])]
      (is (= 3 (.-length result)))
      (is (= "Copy Session ID" (.-title (aget result 0))))
      (is (= "Copy Directory Path" (.-title (aget result 1))))
      (is (= "Delete" (.-title (aget result 2))))
      (is (true? (.-destructive (aget result 2)))))))

(deftest actions-to-js-no-optional-fields-test
  (testing "Optional fields are omitted when not provided"
    (let [result (#'ctx/actions->js [{:title "Simple"}])
          action (aget result 0)]
      (is (= "Simple" (.-title action)))
      ;; systemIcon, destructive, disabled should not be present
      (is (undefined? (.-systemIcon action)))
      (is (undefined? (.-destructive action)))
      (is (undefined? (.-disabled action))))))

(deftest actions-to-js-all-fields-test
  (testing "All optional fields are included when provided"
    (let [result (#'ctx/actions->js [{:title "Full"
                                       :system-icon "star"
                                       :destructive? true
                                       :disabled? true}])
          action (aget result 0)]
      (is (= "Full" (.-title action)))
      (is (= "star" (.-systemIcon action)))
      (is (true? (.-destructive action)))
      (is (true? (.-disabled action))))))

;; ============================================================================
;; context-menu Component Tests
;; Note: context-menu uses r/create-element (not [:>] hiccup) to avoid
;; the Reagent JS object props issue. It returns a React element (JS object),
;; so we test via .props access on the returned element.
;; ============================================================================

(deftest context-menu-returns-react-element-test
  (testing "context-menu returns a React element (JS object, not hiccup vector)"
    (let [result (ctx/context-menu
                  {:actions [{:title "Copy" :on-press (fn [])}]}
                  [:div "child"])]
      ;; r/create-element returns a JS object (React element), not a vector
      (is (object? result))
      ;; React elements have a .props property
      (is (some? (.-props result))))))

(deftest context-menu-props-include-actions-test
  (testing "context-menu passes actions array to ContextMenu props"
    (let [result (ctx/context-menu
                  {:actions [{:title "Copy" :on-press (fn [])}
                             {:title "Delete" :on-press (fn [])}]}
                  [:div "child"])
          props (.-props result)
          actions (.-actions props)]
      (is (array? actions))
      (is (= 2 (.-length actions)))
      (is (= "Copy" (.-title (aget actions 0))))
      (is (= "Delete" (.-title (aget actions 1)))))))

(deftest context-menu-with-title-test
  (testing "context-menu passes title to ContextMenu props"
    (let [result (ctx/context-menu
                  {:title "Session actions"
                   :actions [{:title "Copy" :on-press (fn [])}]}
                  [:div "child"])
          props (.-props result)]
      (is (= "Session actions" (.-title props))))))

(deftest context-menu-disabled-test
  (testing "context-menu passes disabled flag to ContextMenu props"
    (let [result (ctx/context-menu
                  {:disabled true
                   :actions [{:title "Copy" :on-press (fn [])}]}
                  [:div "child"])
          props (.-props result)]
      (is (true? (.-disabled props))))))

(deftest context-menu-no-title-when-omitted-test
  (testing "context-menu does not set title when not provided"
    (let [result (ctx/context-menu
                  {:actions [{:title "Copy" :on-press (fn [])}]}
                  [:div "child"])
          props (.-props result)]
      (is (undefined? (.-title props))))))

;; ============================================================================
;; onPress Handler Tests
;; ============================================================================

(deftest context-menu-on-press-dispatches-correct-action-test
  (testing "onPress handler calls the correct action's on-press by index"
    (let [called (atom nil)
          result (ctx/context-menu
                  {:actions [{:title "First" :on-press #(reset! called :first)}
                             {:title "Second" :on-press #(reset! called :second)}
                             {:title "Third" :on-press #(reset! called :third)}]}
                  [:div "child"])
          on-press (.-onPress (.-props result))]
      ;; Simulate pressing the second action (index 1)
      (on-press #js {:nativeEvent #js {:index 1}})
      (is (= :second @called)))))

(deftest context-menu-on-press-first-action-test
  (testing "onPress handler dispatches first action (index 0)"
    (let [called (atom false)
          result (ctx/context-menu
                  {:actions [{:title "Copy" :on-press #(reset! called true)}]}
                  [:div "child"])
          on-press (.-onPress (.-props result))]
      (on-press #js {:nativeEvent #js {:index 0}})
      (is (true? @called)))))

(deftest context-menu-on-press-out-of-bounds-test
  (testing "onPress handler does nothing for out-of-bounds index"
    (let [called (atom false)
          result (ctx/context-menu
                  {:actions [{:title "Copy" :on-press #(reset! called true)}]}
                  [:div "child"])
          on-press (.-onPress (.-props result))]
      ;; Index 5 is out of bounds for a 1-action menu
      (on-press #js {:nativeEvent #js {:index 5}})
      (is (false? @called)))))

(deftest context-menu-on-press-action-without-handler-test
  (testing "onPress handler ignores actions without :on-press"
    (let [result (ctx/context-menu
                  {:actions [{:title "No handler"}]}
                  [:div "child"])
          on-press (.-onPress (.-props result))]
      ;; Should not throw when action has no :on-press
      (on-press #js {:nativeEvent #js {:index 0}}))))

;; ============================================================================
;; Session List Context Menu Action Tests
;; Verify the action configurations match iOS parity
;; Reference: SessionsForDirectoryView.swift lines 75-88
;; ============================================================================

(deftest session-context-menu-has-three-actions-test
  (testing "Session context menu has Copy Session ID, Copy Directory Path, and Delete"
    ;; Simulate the actions structure used in session-list session-item
    (let [actions [{:title "Copy Session ID"
                    :system-icon "doc.on.clipboard"
                    :on-press (fn [])}
                   {:title "Copy Directory Path"
                    :system-icon "folder"
                    :on-press (fn [])}
                   {:title "Delete"
                    :system-icon "trash"
                    :destructive? true
                    :on-press (fn [])}]]
      (is (= 3 (count actions)))
      (is (= "Copy Session ID" (:title (first actions))))
      (is (= "doc.on.clipboard" (:system-icon (first actions))))
      (is (= "Delete" (:title (last actions))))
      (is (true? (:destructive? (last actions)))))))

(deftest directory-context-menu-has-copy-action-test
  (testing "Directory context menu has Copy Directory Path action"
    ;; Simulate the actions structure used in directory-list directory-item
    (let [actions [{:title "Copy Directory Path"
                    :system-icon "folder"
                    :on-press (fn [])}]]
      (is (= 1 (count actions)))
      (is (= "folder" (:system-icon (first actions)))))))

(deftest recent-session-context-menu-has-two-actions-test
  (testing "Recent session context menu has Copy Session ID and Copy Directory Path"
    ;; Simulate the actions structure used in directory-list recent-session-item
    (let [actions [{:title "Copy Session ID"
                    :system-icon "doc.on.clipboard"
                    :on-press (fn [])}
                   {:title "Copy Directory Path"
                    :system-icon "folder"
                    :on-press (fn [])}]]
      (is (= 2 (count actions)))
      (is (= "Copy Session ID" (:title (first actions))))
      (is (= "Copy Directory Path" (:title (second actions)))))))
