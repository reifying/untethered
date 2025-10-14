(ns voice-code.server
  "Main entry point and WebSocket server for voice-code backend."
  (:require [org.httpkit.server :as http]
            [clojure.core.async :as async]
            [cheshire.core :as json]
            [clojure.tools.logging :as log]
            [clojure.edn :as edn]
            [clojure.java.io :as io]
            [clojure.string :as str]
            [voice-code.claude :as claude])
  (:gen-class))

;; JSON key conversion utilities
;; Following STANDARDS.md: JSON uses snake_case, Clojure uses kebab-case

(defn snake->kebab
  "Convert snake_case string to kebab-case keyword"
  [s]
  (keyword (str/replace s #"_" "-")))

(defn kebab->snake
  "Convert kebab-case keyword to snake_case string"
  [k]
  (str/replace (name k) #"-" "_"))

(defn parse-json
  "Parse JSON string, converting snake_case keys to kebab-case keywords"
  [s]
  (json/parse-string s snake->kebab))

(defn generate-json
  "Generate JSON string, converting kebab-case keywords to snake_case keys"
  [data]
  (json/generate-string data {:key-fn kebab->snake}))

(defonce server-state (atom nil))

(defn load-config
  "Load configuration from resources/config.edn"
  []
  (-> (io/resource "config.edn")
      slurp
      edn/read-string))

;; Session state management
;; Map of WebSocket channel -> session state
(defonce active-sessions (atom {}))

(defn create-session! [channel]
  (swap! active-sessions assoc channel
         {:created-at (System/currentTimeMillis)
          :last-activity (System/currentTimeMillis)
          :claude-session-id nil
          :working-directory nil}))

(defn update-session! [channel updates]
  (swap! active-sessions update channel merge
         (assoc updates :last-activity (System/currentTimeMillis))))

(defn remove-session! [channel]
  (swap! active-sessions dissoc channel))

;; Message handling
(defn handle-message
  "Handle incoming WebSocket message"
  [channel msg]
  (try
    (let [data (parse-json msg)]
      (log/debug "Received message" {:type (:type data)})

      (case (:type data)
        "ping"
        (do
          (log/debug "Handling ping")
          (http/send! channel (generate-json {:type "pong"})))

        "prompt"
        (let [prompt-text (:text data)
              session (get @active-sessions channel)
              ;; Use session-id from iOS directly - no fallback to cached value
              ;; If iOS sends nil, we want a NEW Claude session, not to reuse the cached one
              raw-session-id (:session-id data)
              websocket-session-id (:claude-session-id session)
              session-id raw-session-id ; Use exactly what iOS sends
              working-dir (:working-directory data (:working-directory session))]

          (log/info "Received prompt"
                    {:text (subs prompt-text 0 (min 50 (count prompt-text)))
                     :ios-session-id raw-session-id
                     :websocket-cached-id websocket-session-id
                     :using-session-id session-id
                     :working-directory working-dir})

          ;; Send immediate acknowledgment
          (http/send! channel
                      (generate-json
                       {:type "ack"
                        :message "Processing prompt..."}))

          ;; Invoke Claude asynchronously
          (claude/invoke-claude-async
           prompt-text
           (fn [response]
             ;; Send response back to client
             (if (:success response)
               (do
                 ;; Update session with new session ID
                 (when (:session-id response)
                   (log/info "Updating websocket session"
                             {:old-session-id websocket-session-id
                              :new-session-id (:session-id response)})
                   (update-session! channel {:claude-session-id (:session-id response)}))

                 (http/send! channel
                             (generate-json
                              {:type "response"
                               :success true
                               :text (:result response)
                               :session-id (:session-id response)
                               :usage (:usage response)
                               :cost (:cost response)})))

               (http/send! channel
                           (generate-json
                            {:type "response"
                             :success false
                             :error (:error response)}))))
           :session-id session-id
           :working-directory working-dir
           :timeout-ms 300000))

        "set-directory"
        (do
          (update-session! channel {:working-directory (:path data)})
          (http/send! channel
                      (generate-json
                       {:type "ack"
                        :message (str "Working directory set to: " (:path data))})))

        ;; Unknown message type
        (do
          (log/warn "Unknown message type" {:type (:type data)})
          (http/send! channel
                      (generate-json
                       {:type "error"
                        :message (str "Unknown message type: " (:type data))})))))

    (catch Exception e
      (log/error e "Error handling message")
      (http/send! channel
                  (generate-json
                   {:type "error"
                    :message (str "Error processing message: " (ex-message e))})))))

;; WebSocket handler
(defn websocket-handler
  "Handle WebSocket connections"
  [request]
  (http/with-channel request channel
    (if (http/websocket? channel)
      (do
        (log/info "WebSocket connection established" {:remote-addr (:remote-addr request)})
        (create-session! channel)

        ;; Send welcome message
        (http/send! channel
                    (generate-json
                     {:type "connected"
                      :message "Welcome to voice-code backend"
                      :version "0.1.0"}))

        ;; Handle incoming messages
        (http/on-receive channel
                         (fn [msg]
                           (handle-message channel msg)))

        ;; Handle connection close
        (http/on-close channel
                       (fn [status]
                         (log/info "WebSocket connection closed" {:status status})
                         (remove-session! channel))))

      ;; Not a WebSocket request
      (http/send! channel
                  {:status 400
                   :headers {"Content-Type" "text/plain"}
                   :body "This endpoint requires WebSocket connection"}))))

(defn -main
  "Start the WebSocket server"
  [& args]
  (let [config (load-config)
        port (get-in config [:server :port] 8080)
        host (get-in config [:server :host] "0.0.0.0")]

    (log/info "Starting voice-code server"
              {:port port :host host})

    (let [server (http/run-server websocket-handler {:port port :host host})]
      (reset! server-state server)
      (println (format "✓ Voice-code WebSocket server running on ws://%s:%d" host port))
      (println "  Ready for connections. Press Ctrl+C to stop.")

      ;; Keep main thread alive
      @(promise))))
