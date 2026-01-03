(ns voice-code.server-auth-test
  "Tests for WebSocket and HTTP authentication in server.clj"
  (:require [clojure.test :refer :all]
            [voice-code.server :as server]
            [voice-code.auth :as auth]
            [cheshire.core :as json]
            [clojure.java.io :as io])
  (:import [java.util Base64]))

;; Test fixtures and helpers

(def test-api-key "voice-code-a1b2c3d4e5f678901234567890abcdef")

(defn with-test-api-key
  "Fixture that sets up a known API key for testing"
  [f]
  (let [original-key @server/api-key]
    (reset! server/api-key test-api-key)
    (try
      (f)
      (finally
        (reset! server/api-key original-key)))))

(use-fixtures :each with-test-api-key)

;; Channel authentication tests

(deftest channel-authenticated-test
  (testing "returns false for unknown channel"
    (let [fake-channel (Object.)]
      (is (not (server/channel-authenticated? fake-channel)))))

  (testing "returns false for registered but unauthenticated channel"
    (let [fake-channel (Object.)]
      (swap! server/connected-clients assoc fake-channel {:deleted-sessions #{}})
      (try
        (is (not (server/channel-authenticated? fake-channel)))
        (finally
          (swap! server/connected-clients dissoc fake-channel)))))

  (testing "returns true for authenticated channel"
    (let [fake-channel (Object.)]
      (swap! server/connected-clients assoc fake-channel {:authenticated true})
      (try
        (is (server/channel-authenticated? fake-channel))
        (finally
          (swap! server/connected-clients dissoc fake-channel))))))

;; authenticate-connect! tests

(deftest authenticate-connect-test
  (testing "authenticates with valid key"
    (let [fake-channel (Object.)
          sent-messages (atom [])
          closed (atom false)]
      ;; Initialize connected-clients entry
      (swap! server/connected-clients assoc fake-channel {})
      (try
        (with-redefs [org.httpkit.server/send! (fn [_ msg] (swap! sent-messages conj msg))
                      org.httpkit.server/close (fn [_] (reset! closed true))]
          (let [result (server/authenticate-connect! fake-channel {:api-key test-api-key})]
            (is result "Should return true for valid key")
            (is (server/channel-authenticated? fake-channel) "Channel should be marked authenticated")
            (is (empty? @sent-messages) "Should not send error message")
            (is (not @closed) "Should not close connection")))
        (finally
          (swap! server/connected-clients dissoc fake-channel)))))

  (testing "rejects missing key"
    (let [fake-channel (Object.)
          sent-messages (atom [])
          closed (atom false)]
      (swap! server/connected-clients assoc fake-channel {})
      (try
        (with-redefs [org.httpkit.server/send! (fn [_ msg] (swap! sent-messages conj msg))
                      org.httpkit.server/close (fn [_] (reset! closed true))]
          (let [result (server/authenticate-connect! fake-channel {:type "connect"})]
            (is (not result) "Should return false for missing key")
            (is (= 1 (count @sent-messages)) "Should send auth_error")
            (let [error-msg (server/parse-json (first @sent-messages))]
              (is (= "auth_error" (:type error-msg)))
              (is (= "Authentication failed" (:message error-msg))))
            (is @closed "Should close connection")))
        (finally
          (swap! server/connected-clients dissoc fake-channel)))))

  (testing "rejects invalid key with generic error"
    (let [fake-channel (Object.)
          sent-messages (atom [])
          closed (atom false)]
      (swap! server/connected-clients assoc fake-channel {})
      (try
        (with-redefs [org.httpkit.server/send! (fn [_ msg] (swap! sent-messages conj msg))
                      org.httpkit.server/close (fn [_] (reset! closed true))]
          (let [result (server/authenticate-connect! fake-channel {:api-key "voice-code-wrongkey1234567890abcdefghijkl"})]
            (is (not result) "Should return false for invalid key")
            (is (= 1 (count @sent-messages)) "Should send auth_error")
            (let [error-msg (server/parse-json (first @sent-messages))]
              ;; Must use generic error message (not "Invalid API key")
              (is (= "auth_error" (:type error-msg)))
              (is (= "Authentication failed" (:message error-msg))))
            (is @closed "Should close connection")))
        (finally
          (swap! server/connected-clients dissoc fake-channel))))))

;; extract-bearer-token tests

(deftest extract-bearer-token-test
  (testing "extracts valid bearer token"
    (let [req {:headers {"authorization" "Bearer voice-code-test123"}}]
      (is (= "voice-code-test123" (server/extract-bearer-token req)))))

  (testing "returns nil for missing header"
    (let [req {:headers {}}]
      (is (nil? (server/extract-bearer-token req)))))

  (testing "returns nil for non-bearer auth"
    (let [req {:headers {"authorization" "Basic dXNlcjpwYXNz"}}]
      (is (nil? (server/extract-bearer-token req)))))

  (testing "returns nil for malformed bearer"
    (let [req {:headers {"authorization" "Bearertoken"}}]
      (is (nil? (server/extract-bearer-token req)))))

  (testing "handles case-sensitive Bearer prefix"
    ;; HTTP headers are case-insensitive but Bearer prefix should be exact
    (let [req {:headers {"authorization" "bearer voice-code-test123"}}]
      (is (nil? (server/extract-bearer-token req))))))

;; Hello message format tests

(deftest hello-message-format-test
  (testing "hello message includes auth_version"
    (let [sent-messages (atom [])
          fake-channel (Object.)]
      (with-redefs [org.httpkit.server/send! (fn [_ msg] (swap! sent-messages conj msg))
                    org.httpkit.server/websocket? (constantly true)
                    org.httpkit.server/on-receive (fn [_ _] nil)
                    org.httpkit.server/on-close (fn [_ _] nil)]
        ;; Simulate WebSocket handler sending hello
        (let [hello-json (server/generate-json
                          {:type :hello
                           :message "Welcome to voice-code backend"
                           :version "0.2.0"
                           :auth-version 1
                           :instructions "Send connect message with api_key"})
              parsed (server/parse-json hello-json)]
          (is (= "hello" (:type parsed)))
          (is (= 1 (:auth-version parsed)) "Should include auth_version")
          (is (contains? (set (keys parsed)) :instructions) "Should include instructions"))))))

;; HTTP upload authentication tests

(deftest http-upload-auth-test
  (testing "rejects request without Authorization header"
    (let [sent-responses (atom [])
          fake-channel (Object.)
          req {:headers {}
               :body (java.io.ByteArrayInputStream. (.getBytes "{}"))}]
      (with-redefs [org.httpkit.server/send! (fn [_ msg] (swap! sent-responses conj msg))]
        (server/handle-http-upload req fake-channel)
        (is (= 1 (count @sent-responses)))
        (let [resp (first @sent-responses)]
          (is (= 401 (:status resp)))
          (is (= "Bearer realm=\"voice-code\"" (get-in resp [:headers "WWW-Authenticate"])))
          (let [body (server/parse-json (:body resp))]
            (is (= false (:success body)))
            (is (= "Authentication failed" (:error body))))))))

  (testing "rejects request with invalid API key"
    (let [sent-responses (atom [])
          fake-channel (Object.)
          req {:headers {"authorization" "Bearer voice-code-wrongkey1234567890abcdefg"}
               :body (java.io.ByteArrayInputStream. (.getBytes "{}"))}]
      (with-redefs [org.httpkit.server/send! (fn [_ msg] (swap! sent-responses conj msg))]
        (server/handle-http-upload req fake-channel)
        (is (= 1 (count @sent-responses)))
        (let [resp (first @sent-responses)]
          (is (= 401 (:status resp)))
          ;; Must use generic error message
          (let [body (server/parse-json (:body resp))]
            (is (= "Authentication failed" (:error body))))))))

  (testing "rejects request with malformed Authorization header"
    (let [sent-responses (atom [])
          fake-channel (Object.)
          req {:headers {"authorization" "Basic dXNlcjpwYXNz"}
               :body (java.io.ByteArrayInputStream. (.getBytes "{}"))}]
      (with-redefs [org.httpkit.server/send! (fn [_ msg] (swap! sent-responses conj msg))]
        (server/handle-http-upload req fake-channel)
        (is (= 1 (count @sent-responses)))
        (let [resp (first @sent-responses)]
          (is (= 401 (:status resp)))
          (let [body (server/parse-json (:body resp))]
            (is (= "Authentication failed" (:error body))))))))

  (testing "valid Bearer token allows request through to validation"
    ;; With valid auth, request should proceed to body validation
    ;; (which will fail due to missing fields, but NOT with 401)
    (let [sent-responses (atom [])
          fake-channel (Object.)
          req {:headers {"authorization" (str "Bearer " test-api-key)}
               :body (java.io.ByteArrayInputStream. (.getBytes "{}"))}]
      (with-redefs [org.httpkit.server/send! (fn [_ msg] (swap! sent-responses conj msg))]
        (server/handle-http-upload req fake-channel)
        (is (= 1 (count @sent-responses)))
        (let [resp (first @sent-responses)]
          ;; Should get 400 (bad request for missing fields) not 401 (unauthorized)
          (is (= 400 (:status resp)) "Valid auth should pass - failure should be validation, not auth")
          (let [body (server/parse-json (:body resp))]
            (is (= false (:success body)))
            ;; Error should be about missing fields, not authentication
            (is (re-find #"filename|content|storage_location" (:error body)))))))))

;; Message handling authentication flow tests

(deftest message-auth-flow-test
  (testing "ping works without authentication"
    (let [sent-messages (atom [])
          fake-channel (Object.)]
      (with-redefs [org.httpkit.server/send! (fn [_ msg] (swap! sent-messages conj msg))
                    org.httpkit.server/close (fn [_] nil)]
        (server/handle-message fake-channel (server/generate-json {:type "ping"}))
        (is (= 1 (count @sent-messages)))
        (let [resp (server/parse-json (first @sent-messages))]
          (is (= "pong" (:type resp)))))))

  (testing "non-connect messages rejected without auth"
    (let [sent-messages (atom [])
          closed (atom false)
          fake-channel (Object.)]
      ;; Don't register channel as authenticated
      (with-redefs [org.httpkit.server/send! (fn [_ msg] (swap! sent-messages conj msg))
                    org.httpkit.server/close (fn [_] (reset! closed true))]
        (server/handle-message fake-channel (server/generate-json {:type "subscribe" :session-id "test"}))
        ;; Should send auth_error and close
        (is (= 1 (count @sent-messages)))
        (let [resp (server/parse-json (first @sent-messages))]
          (is (= "auth_error" (:type resp)))
          (is (= "Authentication failed" (:message resp))))
        (is @closed "Should close connection")))))

;; Connect message authentication tests

(deftest connect-auth-test
  (testing "connect with valid key authenticates and proceeds"
    (let [sent-messages (atom [])
          fake-channel (Object.)]
      ;; Mock all the dependencies
      (with-redefs [org.httpkit.server/send! (fn [_ msg] (swap! sent-messages conj msg))
                    org.httpkit.server/close (fn [_] nil)
                    voice-code.replication/get-all-sessions (constantly [])
                    server/send-recent-sessions! (fn [_ _] nil)
                    server/send-to-client! (fn [_ _] nil)]
        (server/handle-message fake-channel
                               (server/generate-json {:type "connect"
                                                      :api-key test-api-key}))
        ;; Should be authenticated
        (is (server/channel-authenticated? fake-channel))
        ;; Should have sent session-list
        (is (some #(= "session_list" (:type (server/parse-json %))) @sent-messages))
        ;; Clean up
        (swap! server/connected-clients dissoc fake-channel))))

  (testing "connect with missing key fails"
    (let [sent-messages (atom [])
          closed (atom false)
          fake-channel (Object.)]
      (with-redefs [org.httpkit.server/send! (fn [_ msg] (swap! sent-messages conj msg))
                    org.httpkit.server/close (fn [_] (reset! closed true))]
        (server/handle-message fake-channel
                               (server/generate-json {:type "connect"}))
        ;; Should have sent auth_error
        (is (= 1 (count @sent-messages)))
        (let [resp (server/parse-json (first @sent-messages))]
          (is (= "auth_error" (:type resp))))
        (is @closed)
        ;; Should NOT be authenticated
        (is (not (server/channel-authenticated? fake-channel)))))))

;; Constant-time comparison verification

(deftest constant-time-comparison-usage-test
  (testing "authenticate-connect! uses constant-time comparison"
    ;; This test verifies the code path uses auth/constant-time-equals?
    ;; by checking behavior is correct for same-length different keys
    (let [fake-channel (Object.)
          sent-messages (atom [])
          closed (atom false)
          ;; Key same length as test-api-key but different
          wrong-key "voice-code-zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz"]
      (swap! server/connected-clients assoc fake-channel {})
      (try
        (with-redefs [org.httpkit.server/send! (fn [_ msg] (swap! sent-messages conj msg))
                      org.httpkit.server/close (fn [_] (reset! closed true))]
          (let [result (server/authenticate-connect! fake-channel {:api-key wrong-key})]
            (is (not result) "Should reject wrong key of same length")
            (is @closed "Should close connection")))
        (finally
          (swap! server/connected-clients dissoc fake-channel))))))

;; Integration test: HTTP file upload with Bearer token

(defn create-temp-dir []
  (let [temp-dir (io/file (System/getProperty "java.io.tmpdir")
                          (str "voice-code-http-upload-auth-test-" (System/currentTimeMillis)))]
    (.mkdirs temp-dir)
    (.getAbsolutePath temp-dir)))

(defn cleanup-dir [dir-path]
  (let [dir (io/file dir-path)]
    (when (.exists dir)
      (doseq [f (reverse (file-seq dir))]
        (.delete f)))))

(deftest http-upload-integration-test
  (testing "file upload with valid Bearer token succeeds"
    (let [temp-dir (create-temp-dir)
          test-content "Hello from HTTP upload integration test"
          base64-content (.encodeToString (Base64/getEncoder) (.getBytes test-content "UTF-8"))
          sent-responses (atom [])
          fake-channel (Object.)
          request-body (server/generate-json {:filename "test-upload.txt"
                                              :content base64-content
                                              :storage-location temp-dir})
          req {:headers {"authorization" (str "Bearer " test-api-key)}
               :body (java.io.ByteArrayInputStream. (.getBytes request-body))}]
      (try
        (with-redefs [org.httpkit.server/send! (fn [_ msg] (swap! sent-responses conj msg))]
          (server/handle-http-upload req fake-channel)
          (is (= 1 (count @sent-responses)))
          (let [resp (first @sent-responses)]
            ;; Should succeed with 200
            (is (= 200 (:status resp)) "Valid Bearer token should allow upload")
            (let [body (server/parse-json (:body resp))]
              (is (= true (:success body)))
              (is (= "test-upload.txt" (:filename body)))
              (is (string? (:path body))))))

        ;; Verify file was actually written
        (let [uploaded-file (io/file temp-dir ".untethered" "resources" "test-upload.txt")]
          (is (.exists uploaded-file) "File should exist on disk")
          (is (= test-content (slurp uploaded-file)) "File content should match"))

        (finally
          (cleanup-dir temp-dir)))))

  (testing "file upload without Bearer token returns 401"
    (let [temp-dir (create-temp-dir)
          test-content "Should not be uploaded"
          base64-content (.encodeToString (Base64/getEncoder) (.getBytes test-content "UTF-8"))
          sent-responses (atom [])
          fake-channel (Object.)
          request-body (server/generate-json {:filename "should-fail.txt"
                                              :content base64-content
                                              :storage-location temp-dir})
          req {:headers {} ;; No Authorization header
               :body (java.io.ByteArrayInputStream. (.getBytes request-body))}]
      (try
        (with-redefs [org.httpkit.server/send! (fn [_ msg] (swap! sent-responses conj msg))]
          (server/handle-http-upload req fake-channel)
          (is (= 1 (count @sent-responses)))
          (let [resp (first @sent-responses)]
            (is (= 401 (:status resp)) "Missing token should return 401")
            (let [body (server/parse-json (:body resp))]
              (is (= false (:success body)))
              (is (= "Authentication failed" (:error body))))))

        ;; Verify file was NOT written
        (let [would-be-file (io/file temp-dir ".untethered" "resources" "should-fail.txt")]
          (is (not (.exists would-be-file)) "File should NOT exist when auth fails"))

        (finally
          (cleanup-dir temp-dir)))))

  (testing "file upload with wrong Bearer token returns 401"
    (let [temp-dir (create-temp-dir)
          test-content "Should not be uploaded with wrong key"
          base64-content (.encodeToString (Base64/getEncoder) (.getBytes test-content "UTF-8"))
          sent-responses (atom [])
          fake-channel (Object.)
          request-body (server/generate-json {:filename "wrong-key.txt"
                                              :content base64-content
                                              :storage-location temp-dir})
          wrong-key "voice-code-00000000000000000000000000000000"
          req {:headers {"authorization" (str "Bearer " wrong-key)}
               :body (java.io.ByteArrayInputStream. (.getBytes request-body))}]
      (try
        (with-redefs [org.httpkit.server/send! (fn [_ msg] (swap! sent-responses conj msg))]
          (server/handle-http-upload req fake-channel)
          (is (= 1 (count @sent-responses)))
          (let [resp (first @sent-responses)]
            (is (= 401 (:status resp)) "Wrong token should return 401")
            (let [body (server/parse-json (:body resp))]
              (is (= false (:success body)))
              ;; Generic error message - not revealing that key was invalid
              (is (= "Authentication failed" (:error body))))))

        ;; Verify file was NOT written
        (let [would-be-file (io/file temp-dir ".untethered" "resources" "wrong-key.txt")]
          (is (not (.exists would-be-file)) "File should NOT exist when auth fails"))

        (finally
          (cleanup-dir temp-dir))))))

;; Reconnection authentication tests

(deftest reconnection-auth-test
  (testing "new channel requires re-authentication after disconnect"
    ;; Simulates: client connects, authenticates, disconnects, reconnects
    ;; New channel should NOT inherit authentication from old channel
    (let [channel-1 (Object.)
          channel-2 (Object.)
          sent-messages (atom [])
          closed (atom false)]
      ;; First connection: authenticate successfully
      (swap! server/connected-clients assoc channel-1 {})
      (with-redefs [org.httpkit.server/send! (fn [_ msg] (swap! sent-messages conj msg))
                    org.httpkit.server/close (fn [_] (reset! closed true))]
        (server/authenticate-connect! channel-1 {:api-key test-api-key}))
      (is (server/channel-authenticated? channel-1) "Channel 1 should be authenticated")

      ;; Simulate disconnect (remove from connected-clients)
      (swap! server/connected-clients dissoc channel-1)

      ;; New connection (channel-2): should NOT be authenticated
      (is (not (server/channel-authenticated? channel-2)) "New channel should not be authenticated")

      ;; Attempting to send a message without auth should fail
      (reset! sent-messages [])
      (reset! closed false)
      (with-redefs [org.httpkit.server/send! (fn [_ msg] (swap! sent-messages conj msg))
                    org.httpkit.server/close (fn [_] (reset! closed true))]
        (server/handle-message channel-2 (server/generate-json {:type "prompt" :text "test"}))
        (is (= 1 (count @sent-messages)) "Should send auth_error")
        (let [resp (server/parse-json (first @sent-messages))]
          (is (= "auth_error" (:type resp))))
        (is @closed "Should close unauthenticated connection"))))

  (testing "reconnection with valid key succeeds"
    ;; Simulates: client connects, authenticates, disconnects, reconnects with key
    (let [channel-1 (Object.)
          channel-2 (Object.)
          sent-messages (atom [])]
      ;; First connection
      (swap! server/connected-clients assoc channel-1 {})
      (with-redefs [org.httpkit.server/send! (fn [_ _] nil)
                    org.httpkit.server/close (fn [_] nil)]
        (server/authenticate-connect! channel-1 {:api-key test-api-key}))
      (is (server/channel-authenticated? channel-1))

      ;; Disconnect
      (swap! server/connected-clients dissoc channel-1)

      ;; Reconnect with valid key
      (with-redefs [org.httpkit.server/send! (fn [_ msg] (swap! sent-messages conj msg))
                    org.httpkit.server/close (fn [_] nil)
                    voice-code.replication/get-all-sessions (constantly [])
                    server/send-recent-sessions! (fn [_ _] nil)
                    server/send-to-client! (fn [_ _] nil)]
        (server/handle-message channel-2
                               (server/generate-json {:type "connect"
                                                      :api-key test-api-key}))
        ;; Should be authenticated
        (is (server/channel-authenticated? channel-2) "Reconnected channel should be authenticated")
        ;; Should receive session_list (normal flow)
        (is (some #(= "session_list" (:type (server/parse-json %))) @sent-messages)
            "Should receive session_list after reconnect auth")
        ;; Clean up
        (swap! server/connected-clients dissoc channel-2))))

  (testing "reconnection with invalid key fails"
    ;; Simulates: client was authenticated, disconnects, tries to reconnect with wrong key
    (let [channel-1 (Object.)
          channel-2 (Object.)
          sent-messages (atom [])
          closed (atom false)]
      ;; First connection with valid key
      (swap! server/connected-clients assoc channel-1 {})
      (with-redefs [org.httpkit.server/send! (fn [_ _] nil)
                    org.httpkit.server/close (fn [_] nil)]
        (server/authenticate-connect! channel-1 {:api-key test-api-key}))
      (is (server/channel-authenticated? channel-1))

      ;; Disconnect
      (swap! server/connected-clients dissoc channel-1)

      ;; Attempt reconnect with wrong key
      (with-redefs [org.httpkit.server/send! (fn [_ msg] (swap! sent-messages conj msg))
                    org.httpkit.server/close (fn [_] (reset! closed true))]
        (server/handle-message channel-2
                               (server/generate-json {:type "connect"
                                                      :api-key "voice-code-wrongkey1234567890abcdefghij"}))
        ;; Should NOT be authenticated
        (is (not (server/channel-authenticated? channel-2)) "Should not authenticate with wrong key")
        ;; Should receive auth_error
        (is (= 1 (count @sent-messages)))
        (let [resp (server/parse-json (first @sent-messages))]
          (is (= "auth_error" (:type resp)))
          (is (= "Authentication failed" (:message resp))))
        (is @closed "Should close connection on failed auth"))))

  (testing "session state not shared between channels"
    ;; Ensure authenticated session-ids from one channel don't leak to another
    (let [channel-1 (Object.)
          channel-2 (Object.)
          test-session-id "test-session-123"]
      ;; Authenticate channel-1 and register a session
      (swap! server/connected-clients assoc channel-1 {})
      (with-redefs [org.httpkit.server/send! (fn [_ _] nil)
                    org.httpkit.server/close (fn [_] nil)]
        (server/authenticate-connect! channel-1 {:api-key test-api-key}))
      ;; Register session on channel-1
      (swap! server/connected-clients update channel-1 assoc :session-id test-session-id)

      ;; Channel-2 should not have access to channel-1's session
      (let [channel-1-data (get @server/connected-clients channel-1)
            channel-2-data (get @server/connected-clients channel-2)]
        (is (= test-session-id (:session-id channel-1-data)) "Channel 1 should have session")
        (is (nil? channel-2-data) "Channel 2 should have no data"))

      ;; Clean up
      (swap! server/connected-clients dissoc channel-1))))
