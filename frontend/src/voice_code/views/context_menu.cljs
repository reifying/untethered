(ns voice-code.views.context-menu
  "Native context menu wrapper using react-native-context-menu-view.

   On iOS: Uses UIMenu (iOS 13+) with SF Symbol icons and haptic feedback.
   On Android: Uses native ContextMenu with Material Design styling.

   Replaces Alert.alert() for long-press context menus with platform-native menus
   that match what iOS (SwiftUI .contextMenu) and Android provide natively.

   Uses r/create-element instead of [:>] because ContextMenu requires JS object
   props (actions array, onPress handler). Reagent's [:> Component props] checks
   (map? props) which fails for JS objects, treating them as children instead.
   See MEMORY.md: 'Reagent [:>] Interop + JS Objects (Critical)'.

   Usage:
     [context-menu
      {:title \"Session actions\"
       :actions [{:title \"Copy Session ID\"
                  :system-icon \"doc.on.clipboard\"
                  :on-press #(copy-to-clipboard! id \"Copied\")}
                 {:title \"Delete\"
                  :destructive? true
                  :system-icon \"trash\"
                  :on-press #(delete! id)}]}
      [session-item-content ...]]"
  (:require [reagent.core :as r]
            ["react-native-context-menu-view" :default ContextMenu]))

(defn- actions->js
  "Convert ClojureScript action maps to the JS format expected by ContextMenu.

   Input:  [{:title \"Copy\" :system-icon \"doc.on.clipboard\" :destructive? true}]
   Output: #js [#js {:title \"Copy\" :systemIcon \"doc.on.clipboard\" :destructive true}]"
  [actions]
  (clj->js
   (mapv (fn [{:keys [title system-icon destructive? disabled?]}]
           (cond-> {:title title}
             system-icon  (assoc :systemIcon system-icon)
             destructive? (assoc :destructive true)
             disabled?    (assoc :disabled true)))
         actions)))

(defn context-menu
  "Render a native context menu that wraps its children.

   Long-press (or right-click on iPad/Mac Catalyst) shows a native menu.

   Props:
   - :title       - Optional header text above menu items
   - :actions     - Vector of action maps:
       :title       - Action label (required)
       :system-icon - SF Symbol name for iOS (e.g. \"doc.on.clipboard\")
       :destructive? - Render in red (default false)
       :disabled?   - Gray out action (default false)
       :on-press    - Callback when action is selected
   - :on-cancel   - Optional callback when menu dismissed without selection
   - :disabled    - Disable the context menu entirely (default false)

   Children are rendered inside the ContextMenu wrapper."
  [{:keys [title actions on-cancel disabled]} & children]
  (let [js-actions (actions->js actions)
        on-press-handler (fn [^js e]
                           (let [idx (.. e -nativeEvent -index)]
                             (when-let [action (nth actions idx nil)]
                               (when-let [handler (:on-press action)]
                                 (handler)))))
        ;; Build JS props object manually to avoid [:>] map? check issue
        js-props (doto #js {}
                   (unchecked-set "actions" js-actions)
                   (unchecked-set "onPress" on-press-handler))
        _ (when title (unchecked-set js-props "title" title))
        _ (when on-cancel (unchecked-set js-props "onCancel" on-cancel))
        _ (when disabled (unchecked-set js-props "disabled" true))]
    (apply r/create-element ContextMenu js-props
           (map r/as-element children))))
