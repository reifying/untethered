(ns voice-code.anthropic
  "Low-level Anthropic Messages API client.
   Provides both non-streaming (for tool-use conversations) and streaming
   (SSE) request handling for the supervisor agent.
   Uses java.net.http.HttpClient directly (Java 11+)."
  (:require [cheshire.core :as json]
            [clojure.tools.logging :as log]
            [clojure.java.io :as io]
            [clojure.string :as str]
            [clojure.edn :as edn])
  (:import [java.net URI]
           [java.net.http HttpClient HttpRequest HttpRequest$BodyPublishers HttpResponse$BodyHandlers]
           [java.time Duration]))

(def api-base "https://api.anthropic.com/v1")
(def anthropic-version "2023-06-01")

(defn load-config
  "Load anthropic config from config.edn.
   Returns nil if config.edn exists but has no :anthropic section."
  []
  (if-let [resource (io/resource "config.edn")]
    (let [config (:anthropic (edn/read-string (slurp resource)))]
      (or config
          {:api-key-path "~/.voice-code/anthropic-api-key"
           :default-model "claude-opus-4-6"
           :summary-model "claude-sonnet-4-6"}))
    (throw (ex-info "config.edn not found on classpath" {}))))

(defn expand-home
  "Expand ~ to user home directory."
  [path]
  (if (str/starts-with? path "~")
    (str (System/getProperty "user.home") (subs path 1))
    path))

(defn load-api-key
  "Read the Anthropic API key from the configured file path.
   Throws with clear error if file is missing or empty."
  ([]
   (load-api-key (:api-key-path (load-config))))
  ([key-path]
   (let [expanded (expand-home key-path)
         file (io/file expanded)]
     (when-not (.exists file)
       (throw (ex-info (str "Anthropic API key file not found: " expanded
                            ". Create this file with your API key.")
                       {:path expanded})))
     (let [key (str/trim (slurp file))]
       (when (str/blank? key)
         (throw (ex-info (str "Anthropic API key file is empty: " expanded)
                         {:path expanded})))
       key))))

(defn- build-request-body
  "Build the JSON request body for the Messages API."
  [{:keys [model system messages tools max-tokens]}]
  (cond-> {:model model
           :max_tokens (or max-tokens 4096)
           :messages messages}
    system (assoc :system system)
    (seq tools) (assoc :tools tools)))

(defn- build-headers
  "Build HTTP headers for the Anthropic API."
  [api-key]
  {"x-api-key" api-key
   "anthropic-version" anthropic-version
   "content-type" "application/json"})

(def ^:private http-client
  (delay (-> (HttpClient/newBuilder)
             (.connectTimeout (Duration/ofSeconds 30))
             .build)))

(defn- build-http-request
  "Build a java.net.http.HttpRequest for the Anthropic API."
  [api-key body-json]
  (-> (HttpRequest/newBuilder)
      (.uri (URI/create (str api-base "/messages")))
      (.header "x-api-key" api-key)
      (.header "anthropic-version" anthropic-version)
      (.header "content-type" "application/json")
      (.timeout (Duration/ofMinutes 10))
      (.POST (HttpRequest$BodyPublishers/ofString body-json))
      .build))

(defn- handle-error-response
  "Convert non-2xx HTTP responses to ExceptionInfo."
  [status body]
  (throw (ex-info (str "Anthropic API error (HTTP " status "): " body)
                  {:status status
                   :body body})))

(defn create-message
  "Send a non-streaming Messages API request. Returns parsed response body.
   Used for tool-use conversations and sub-agent calls."
  [{:keys [api-key] :as opts}]
  (let [key (or api-key (load-api-key))
        body (build-request-body opts)
        body-json (json/generate-string body)
        request (build-http-request key body-json)
        response (.send @http-client request (HttpResponse$BodyHandlers/ofString))
        status (.statusCode response)
        response-body (.body response)]
    (if (<= 200 status 299)
      (json/parse-string response-body true)
      (handle-error-response status response-body))))

(defn- parse-sse-events
  "Parse an SSE event stream from a string. Calls handlers for each event."
  [body-string {:keys [on-text on-content-block on-message-stop]}]
  (let [accumulated-content (atom [])
        response (atom nil)]
    (doseq [line (str/split-lines body-string)]
      (when (str/starts-with? line "data: ")
        (let [data-str (subs line 6)]
          (when-not (= data-str "[DONE]")
            (let [data (json/parse-string data-str true)]
              (case (:type data)
                "message_start"
                (reset! response (:message data))

                "content_block_start"
                (let [block (:content_block data)]
                  (swap! accumulated-content conj block))

                "content_block_delta"
                (let [delta (:delta data)
                      idx (:index data)]
                  (when (and (= "text_delta" (:type delta)) on-text)
                    (on-text (:text delta)))
                  (when (and idx (< idx (count @accumulated-content)))
                    (swap! accumulated-content update idx
                           (fn [block]
                             (case (:type delta)
                               "text_delta"
                               (update block :text str (:text delta))
                               "input_json_delta"
                               (update block :input str (:partial_json delta))
                               block)))))

                "content_block_stop"
                (let [idx (:index data)
                      block (get @accumulated-content idx)]
                  (when (and block (= "tool_use" (:type block)) (string? (:input block)))
                    (swap! accumulated-content update idx
                           #(update % :input (fn [s] (json/parse-string s true)))))
                  (when on-content-block
                    (on-content-block (get @accumulated-content idx))))

                "message_delta"
                (when-let [delta (:delta data)]
                  (swap! response merge delta)
                  (when-let [usage (:usage data)]
                    (swap! response assoc :usage
                           (merge (:usage @response) usage))))

                "message_stop"
                (when on-message-stop
                  (on-message-stop @response))

                ;; Ignore other event types
                nil))))))
    (assoc @response :content @accumulated-content)))

(defn create-message-streaming
  "Send a streaming Messages API request. Calls on-text for each text delta
   and returns the full accumulated response. Used for supervisor responses
   where we want to start TTS as text arrives."
  [{:keys [api-key on-text] :as opts}]
  (let [key (or api-key (load-api-key))
        body (assoc (build-request-body opts) :stream true)
        body-json (json/generate-string body)
        request (build-http-request key body-json)
        response (.send @http-client request (HttpResponse$BodyHandlers/ofString))
        status (.statusCode response)
        response-body (.body response)]
    (if (<= 200 status 299)
      (parse-sse-events response-body {:on-text on-text})
      (handle-error-response status response-body))))
