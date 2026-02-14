(ns voice-code.icons
  "Platform-adaptive icon component.

   Uses Ionicons on iOS (matches SF Symbols aesthetic) and MaterialIcons on
   Android (matches Material Design conventions). Provides a single `icon`
   component with a semantic name that resolves to the appropriate platform
   icon.

   Usage:
     [icon {:name :mic :size 24 :color \"#007AFF\"}]

   The :name keyword maps to platform-specific icon names via `icon-map`."
  (:require ["react-native" :as rn]
            ["@react-native-vector-icons/ionicons" :default Ionicons]
            ["@react-native-vector-icons/material-icons" :default MaterialIcons]))

(def ^:private ios? (= "ios" (.-OS rn/Platform)))

;; Mapping from semantic icon names to platform-specific icon names.
;; iOS uses Ionicons (visually close to SF Symbols).
;; Android uses MaterialIcons (native Material Design).
;;
;; Each entry: :semantic-name {:ios "ionicons-name" :android "material-name"}
(def icon-map
  {:mic                  {:ios "mic"               :android "mic"}
   :mic-fill             {:ios "mic"               :android "mic"}
   :stop                 {:ios "stop"              :android "stop"}
   :stop-fill            {:ios "stop"              :android "stop"}
   :speaker              {:ios "volume-high"       :android "volume-up"}
   :speaker-slash        {:ios "volume-mute"       :android "volume-off"}
   :keyboard             {:ios "keypad"            :android "keyboard"}
   :gear                 {:ios "settings"          :android "settings"}
   :trash                {:ios "trash"             :android "delete"}
   :folder               {:ios "folder"            :android "folder"}
   :folder-fill          {:ios "folder"            :android "folder"}
   :play                 {:ios "play"              :android "play-arrow"}
   :pause                {:ios "pause"             :android "pause"}
   :clipboard            {:ios "clipboard"         :android "content-paste"}
   :clipboard-fill       {:ios "clipboard"         :android "content-paste"}
   :checkmark            {:ios "checkmark"         :android "check"}
   :checkmark-circle     {:ios "checkmark-circle"  :android "check-circle"}
   :close                {:ios "close"             :android "close"}
   :close-circle         {:ios "close-circle"      :android "cancel"}
   :warning              {:ios "warning"           :android "warning"}
   :info-circle          {:ios "information-circle" :android "info"}
   :refresh              {:ios "refresh"           :android "refresh"}
   :send                 {:ios "arrow-up"          :android "send"}
   :person               {:ios "person"            :android "person"}
   :robot                {:ios "hardware-chip"     :android "smart-toy"}
   :wrench               {:ios "build"             :android "build"}
   :document             {:ios "document-text"     :android "description"}
   :help                 {:ios "help-circle"       :android "help"}
   :sparkles             {:ios "sparkles"          :android "auto-awesome"}
   :arrow-down-circle    {:ios "arrow-down-circle" :android "arrow-circle-down"}
   :compress             {:ios "contract"          :android "compress"}
   :paper-clip           {:ios "attach"            :android "attach-file"}
   :upload               {:ios "cloud-upload"      :android "cloud-upload"}
   :image                {:ios "image"             :android "image"}
   :code                 {:ios "code-slash"        :android "code"}
   :data                 {:ios "analytics"         :android "data-object"}
   :file                 {:ios "document"          :android "insert-drive-file"}
   :terminal             {:ios "terminal"          :android "terminal"}
   :navigate-forward     {:ios "chevron-forward"   :android "chevron-right"}
   :navigate-back        {:ios "chevron-back"      :android "chevron-left"}
   :expand               {:ios "chevron-down"      :android "expand-more"}
   :collapse             {:ios "chevron-up"        :android "expand-less"}
   :edit                 {:ios "create"            :android "edit"}
   :ellipsis             {:ios "ellipsis-horizontal" :android "more-horiz"}
   :qr-code              {:ios "qr-code"           :android "qr-code-2"}
   :shield-check         {:ios "shield-checkmark"  :android "verified-user"}
   :key                  {:ios "key"               :android "vpn-key"}
   :bug                  {:ios "bug"               :android "bug-report"}
   :chart                {:ios "bar-chart"         :android "bar-chart"}
   :copy                 {:ios "copy"              :android "content-copy"}
   :notifications        {:ios "notifications"     :android "notifications"}
   :lock                 {:ios "lock-closed"       :android "lock"}
   :unlock               {:ios "lock-open"         :android "lock-open"}
   :recipe               {:ios "list"              :android "list-alt"}
   :recipe-active        {:ios "list"              :android "playlist-play"}
   :exit                 {:ios "exit"              :android "logout"}
   :add                  {:ios "add"               :android "add"}
   :remove               {:ios "remove"            :android "remove"}
   :search               {:ios "search"            :android "search"}
   :clock                {:ios "time"              :android "schedule"}
   :history              {:ios "time"              :android "history"}
   :share                {:ios "share"             :android "share"}
   :arrow-up             {:ios "arrow-up"          :android "arrow-upward"}})

(defn icon
  "Render a platform-appropriate vector icon.

   Props:
   - :name     - Keyword from icon-map (e.g., :mic, :stop, :speaker)
   - :size     - Icon size in points (default 24)
   - :color    - Icon color string (default \"#000000\")
   - :style    - Optional additional style map"
  [{:keys [name size color style]}]
  (let [size (or size 24)
        color (or color "#000000")
        platform-key (if ios? :ios :android)
        icon-entry (get icon-map name)
        icon-name (when icon-entry (get icon-entry platform-key))
        Component (if ios? Ionicons MaterialIcons)]
    (when icon-name
      [:> Component (cond-> {:name icon-name
                             :size size
                             :color color}
                      style (assoc :style style))])))
