(ns untethered.core
  "Application entry point."
  (:require ["react-native" :refer [AppRegistry]]
            [reagent.core :as r]
            [re-frame.core :as rf]
            [untethered.events.core]
            [untethered.events.websocket]
            [untethered.subs]
            [untethered.websocket]
            [untethered.logger :as log]
            [untethered.views.core :refer [app-root]]))

(defn ^:export init
  "Initialize the application."
  []
  (log/info "untethered init")
  (rf/dispatch-sync [:initialize-db])
  (rf/dispatch [:app/initialize])
  (.registerComponent AppRegistry
                      "UntetheredMobile"
                      (fn [] (r/reactify-component app-root))))
