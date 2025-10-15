(ns voice-code.server
  "Main entry point and WebSocket server for voice-code backend."
  (:require [org.httpkit.server :as http]
            [clojure.core.async :as async]
            [cheshire.core :as json]
            [clojure.tools.logging :as log]
            [clojure.edn :as edn]
            [clojure.java.io :as io]
            [clojure.string :as str]
            [voice-code.claude :as claude]
            [voice-code.storage :as storage])
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

(defn ensure-config-file
  "Ensure config.edn exists, creating with defaults if needed.
  Only works in development (not when running from JAR).
  
  Accepts optional config-path for testing purposes."
  ([]
   (ensure-config-file "resources/config.edn"))
  ([config-path]
   (let [config-file (io/file config-path)]
     (when-not (.exists config-file)
       (log/info "Creating default config.edn at" config-path)
       (io/make-parents config-file)
       (spit config-file
             (str "{:server {:port 8080\n"
                  "          :host \"0.0.0.0\"}\n\n"
                  " :claude {:cli-path \"claude\"\n"
                  "          :default-timeout 86400000}  ; 24 hours in milliseconds\n\n"
                  " :logging {:level :info}}\n"))))))

(defn load-config
  "Load configuration from resources/config.edn, creating with defaults if needed"
  []
  (ensure-config-file)
  (if-let [config-resource (io/resource "config.edn")]
    (-> config-resource
        slurp
        edn/read-string)
    ;; Fallback to defaults if resource not found (e.g., in JAR)
    (do
      (log/warn "config.edn not found on classpath, using defaults")
      {:server {:port 8080
                :host "0.0.0.0"}
       :claude {:cli-path "claude"
                :default-timeout 86400000}
       :logging {:level :info}})))

;; Ephemeral mapping: WebSocket channel -> iOS session UUID
;; This is just for routing messages during an active connection
;; Persistent session data is stored via voice-code.storage
(defonce channel-to-session (atom {}))

(defn register-channel!
  "Register WebSocket channel with iOS session UUID.
  Creates persistent session if it doesn't exist.
  Returns the session data."
  [channel ios-session-id]
  (swap! channel-to-session assoc channel ios-session-id)
  (if-let [session (storage/get-session ios-session-id)]
    (do
      (log/info "Reconnected to existing session"
                {:ios-session-id ios-session-id
                 :claude-session-id (:claude-session-id session)})
      session)
    (let [config (load-config)
          default-dir (get-in config [:claude :default-working-directory])]
      (log/info "Creating new persistent session"
                {:ios-session-id ios-session-id
                 :working-directory default-dir})
      (storage/create-session! ios-session-id default-dir))))

(defn update-session!
  "Update persistent session data by iOS session UUID.
  Returns updated session or nil if not found."
  [ios-session-id updates]
  (storage/update-session! ios-session-id updates))

(defn unregister-channel!
  "Remove WebSocket channel mapping.
  Does NOT delete the persistent session - only removes the active connection mapping."
  [channel]
  (swap! channel-to-session dissoc channel))

(defn generate-message-id
  "Generate a UUID v4 for message tracking"
  []
  (str (java.util.UUID/randomUUID)))

(defn buffer-message!
  "Buffer a message in the undelivered queue.
  Returns the message with assigned ID."
  [ios-session-id role text session-id]
  (let [message-id (generate-message-id)
        message {:id message-id
                 :role role
                 :text text
                 :session-id session-id}]
    (storage/add-undelivered-message! ios-session-id message)
    (log/debug "Buffered message" {:ios-session-id ios-session-id
                                   :message-id message-id
                                   :role role})
    message))

(defn send-with-buffer!
  "Send message to channel and buffer it for delivery tracking.
  If send fails (disconnected), message remains in buffer for replay."
  [channel ios-session-id message-data]
  (let [message-id (:message-id message-data)
        json-message (generate-json message-data)]
    (try
      (http/send! channel json-message)
      (log/debug "Sent message" {:ios-session-id ios-session-id
                                 :message-id message-id})
      (catch Exception e
        (log/warn e "Failed to send message, will replay on reconnect"
                  {:ios-session-id ios-session-id
                   :message-id message-id})))))

(defn replay-undelivered-messages!
  "Replay all undelivered messages to reconnected client.
  Sends each buffered message as a 'replay' type message."
  [channel ios-session-id]
  (let [undelivered (storage/get-undelivered-messages ios-session-id)]
    (when (seq undelivered)
      (log/info "Replaying undelivered messages"
                {:ios-session-id ios-session-id
                 :count (count undelivered)})
      (doseq [msg undelivered]
        (let [replay-data {:type "replay"
                           :message-id (:id msg)
                           :message {:role (:role msg)
                                     :text (:text msg)
                                     :session-id (:session-id msg)
                                     :timestamp (str (:timestamp msg))}}]
          (log/debug "Replaying message"
                     {:ios-session-id ios-session-id
                      :message-id (:id msg)})
          (send-with-buffer! channel ios-session-id replay-data))))))

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

        "connect"
        ;; iOS client sends this on connection with its session UUID
        ;; This handles both initial connection and reconnection
        (let [ios-session-id (:session-id data)]
          (if ios-session-id
            (do
              (log/info "Registering iOS session" {:ios-session-id ios-session-id})
              (register-channel! channel ios-session-id)

              ;; Send connected confirmation
              (http/send! channel
                          (generate-json
                           {:type "connected"
                            :message "Session registered"
                            :session-id ios-session-id}))

              ;; Replay any undelivered messages (reconnection scenario)
              (replay-undelivered-messages! channel ios-session-id))
            (do
              (log/warn "Connect message missing session-id")
              (http/send! channel
                          (generate-json
                           {:type "error"
                            :message "session_id required in connect message"})))))

        "prompt"
        (let [ios-session-id (get @channel-to-session channel)]
          (if-not ios-session-id
            (do
              (log/warn "Prompt received before session registration")
              (http/send! channel
                          (generate-json
                           {:type "error"
                            :message "Must send connect message with session_id first"})))

            (let [prompt-text (:text data)
                  session (storage/get-session ios-session-id)
                  ;; Use session-id from iOS for Claude (supports explicit session switching)
                  ;; If nil, Claude will create a new session
                  claude-session-id-from-ios (:session-id data)
                  stored-claude-session-id (:claude-session-id session)
                  claude-session-id claude-session-id-from-ios
                  working-dir (:working-directory data (:working-directory session))]

              (log/info "Received prompt"
                        {:text (subs prompt-text 0 (min 50 (count prompt-text)))
                         :ios-session-id ios-session-id
                         :stored-claude-session-id stored-claude-session-id
                         :using-claude-session-id claude-session-id
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
                     ;; Update persistent session with new Claude session ID
                     (when (:session-id response)
                       (log/info "Updating persistent session"
                                 {:ios-session-id ios-session-id
                                  :old-claude-session-id stored-claude-session-id
                                  :new-claude-session-id (:session-id response)})
                       (update-session! ios-session-id {:claude-session-id (:session-id response)}))

                     ;; Buffer message and send with tracking
                     (let [buffered-msg (buffer-message! ios-session-id
                                                         :assistant
                                                         (:result response)
                                                         (:session-id response))
                           response-data {:type "response"
                                          :message-id (:id buffered-msg)
                                          :success true
                                          :text (:result response)
                                          :session-id (:session-id response)
                                          :usage (:usage response)
                                          :cost (:cost response)}]
                       (send-with-buffer! channel ios-session-id response-data)))

                   (http/send! channel
                               (generate-json
                                {:type "response"
                                 :success false
                                 :error (:error response)}))))
               :session-id claude-session-id
               :working-directory working-dir
               :timeout-ms 86400000))))

        "set-directory"
        (let [ios-session-id (get @channel-to-session channel)]
          (if-not ios-session-id
            (do
              (log/warn "set-directory received before session registration")
              (http/send! channel
                          (generate-json
                           {:type "error"
                            :message "Must send connect message with session_id first"})))
            (do
              (update-session! ios-session-id {:working-directory (:path data)})
              (http/send! channel
                          (generate-json
                           {:type "ack"
                            :message (str "Working directory set to: " (:path data))})))))

        "message-ack"
        (let [ios-session-id (get @channel-to-session channel)
              message-id (:message-id data)]
          (if-not ios-session-id
            (log/warn "message-ack received before session registration"
                      {:message-id message-id})
            (if message-id
              (do
                (log/info "Message acknowledged, removing from queue"
                          {:ios-session-id ios-session-id
                           :message-id message-id})
                (storage/remove-undelivered-message! ios-session-id message-id))
              (log/warn "message-ack missing message-id"
                        {:ios-session-id ios-session-id}))))

        ;; Unknown message type

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

        ;; Send welcome message - client must send "connect" message with session UUID
        (http/send! channel
                    (generate-json
                     {:type "hello"
                      :message "Welcome to voice-code backend"
                      :version "0.1.0"
                      :instructions "Send connect message with session_id"}))

        ;; Handle incoming messages
        (http/on-receive channel
                         (fn [msg]
                           (handle-message channel msg)))

        ;; Handle connection close
        (http/on-close channel
                       (fn [status]
                         (log/info "WebSocket connection closed" {:status status})
                         (unregister-channel! channel))))

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
        host (get-in config [:server :host] "0.0.0.0")
        default-dir (get-in config [:claude :default-working-directory])]

    ;; Initialize persistent storage
    (storage/initialize!)

    (log/info "Starting voice-code server"
              {:port port
               :host host
               :default-working-directory default-dir})

    (let [server (http/run-server websocket-handler {:port port :host host})]
      (reset! server-state server)
      (println (format "✓ Voice-code WebSocket server running on ws://%s:%d" host port))
      (when default-dir
        (println (format "  Default working directory: %s" default-dir)))
      (println "  Ready for connections. Press Ctrl+C to stop.")

      ;; Keep main thread alive
      @(promise))))
