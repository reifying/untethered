(ns voice-code.core
  "Ultra-minimal hello world - registers app directly."
  (:require ["react" :as react]
            ["react-native" :as rn :refer [AppRegistry]]))

(defn hello-world
  "Simple hello world component."
  []
  (react/createElement
   rn/View
   #js {:style #js {:flex 1
                    :justifyContent "center"
                    :alignItems "center"
                    :backgroundColor "#ffffff"}}
   (react/createElement
    rn/Text
    #js {:style #js {:fontSize 24
                     :fontWeight "bold"
                     :color "#333333"}}
    "Hello from ClojureScript!")))

(defn ^:export init
  "Initialize the application - registers the app directly."
  []
  (js/console.log "voice-code init called")
  (.registerComponent AppRegistry
                      "VoiceCodeMobile"
                      (fn [] hello-world)))
