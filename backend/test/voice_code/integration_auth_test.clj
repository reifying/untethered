(ns voice-code.integration-auth-test
  "End-to-end integration tests for API key authentication.
   
   These tests verify the complete authentication flow from key generation
   through authenticated communication, as specified in:
   @docs/api-key-authentication.md#5-testing-strategy"
  (:require [clojure.test :refer [deftest is testing use-fixtures]]
            [clojure.java.io :as io]
            [voice-code.auth :as auth]
            [voice-code.qr :as qr]
            [voice-code.server :as server]
            [voice-code.session-store :as session-store])
  (:import [java.util Base64]))

;; =============================================================================
;; Test Helpers
;; =============================================================================

(defn create-temp-auth-dir
  "Create a temporary directory for auth testing."
  []
  (let [temp-dir (io/file (System/getProperty "java.io.tmpdir")
                          (str "voice-code-integration-auth-test-" (System/currentTimeMillis)))]
    (.mkdirs temp-dir)
    (.getAbsolutePath temp-dir)))

(defn cleanup-dir
  "Recursively delete a directory."
  [dir-path]
  (let [dir (io/file dir-path)]
    (when (.exists dir)
      (doseq [f (reverse (file-seq dir))]
        (.delete f)))))

;; =============================================================================
;; Test Fixtures
;; =============================================================================

(def ^:dynamic *test-temp-dir* nil)
(def ^:dynamic *test-api-key* nil)

(defn with-isolated-auth-env
  "Fixture that creates an isolated auth environment for each test."
  [f]
  (let [temp-dir (create-temp-auth-dir)
        key-path (str temp-dir "/api-key")]
    (binding [auth/*key-file-path* key-path
              *test-temp-dir* temp-dir]
      ;; Generate key in isolated environment
      (let [generated-key (auth/ensure-key-file!)]
        (binding [*test-api-key* generated-key]
          ;; Set up server with the test key
          (let [original-server-key @server/api-key]
            (reset! server/api-key generated-key)
            (try
              (f)
              (finally
                (reset! server/api-key original-server-key)
                (cleanup-dir temp-dir)))))))))

(use-fixtures :each with-isolated-auth-env)

;; =============================================================================
;; E2E Test: Generate Key -> Display QR -> Connect -> Authenticated
;; =============================================================================

(deftest e2e-key-generation-qr-connect-test
  (testing "Complete E2E flow: generate key -> QR generation -> connect -> authenticated"
    ;; Step 1: Key was generated in fixture - verify it's valid
    (is (auth/valid-key-format? *test-api-key*)
        "Generated key should have valid format")

    ;; Step 2: Generate QR code (what user would see on terminal)
    ;; Note: We verify the QR matrix is generated correctly.
    ;; Actual camera-based scanning is an iOS-side concern tested in iOS tests.
    (let [qr-matrix (qr/generate-qr-matrix *test-api-key*)]
      (is (some? qr-matrix) "QR matrix should be generated")
      (is (pos? (.getWidth qr-matrix)) "QR matrix should have positive width")
      (is (pos? (.getHeight qr-matrix)) "QR matrix should have positive height")

      ;; Step 3: Connect with the key (simulating iOS after scanning QR)
      (let [fake-channel (Object.)
            sent-messages (atom [])
            closed (atom false)]
        (swap! server/connected-clients assoc fake-channel {})
        (try
          (with-redefs [org.httpkit.server/send! (fn [_ msg] (swap! sent-messages conj msg))
                        org.httpkit.server/close (fn [_] (reset! closed true))
                        session-store/list-sessions (constantly [])
                        server/send-recent-sessions! (fn [_ _] nil)
                        server/send-to-client! (fn [_ _] nil)]

            ;; Send connect with the key
            (server/handle-message fake-channel
                                   (server/generate-json {:type "connect"
                                                          :api-key *test-api-key*}))

            ;; Step 4: Verify authentication succeeded
            (is (server/channel-authenticated? fake-channel)
                "Channel should be authenticated after connect with valid key")
            (is (not @closed)
                "Connection should remain open")
            (is (some #(= "session_list" (:type (server/parse-json %))) @sent-messages)
                "Should receive session_list after authentication"))
          (finally
            (swap! server/connected-clients dissoc fake-channel)))))))

;; =============================================================================
;; E2E Test: Invalid Key Rejected at WebSocket Connect
;; =============================================================================

(deftest e2e-invalid-key-rejected-test
  (testing "Invalid key is rejected at WebSocket connect"
    (let [fake-channel (Object.)
          sent-messages (atom [])
          closed (atom false)
          invalid-key "voice-code-00000000000000000000000000000000"]

      ;; Ensure invalid key is different from actual key
      (is (not= invalid-key *test-api-key*)
          "Test setup: invalid key should differ from actual key")

      (swap! server/connected-clients assoc fake-channel {})
      (try
        (with-redefs [org.httpkit.server/send! (fn [_ msg] (swap! sent-messages conj msg))
                      org.httpkit.server/close (fn [_] (reset! closed true))]

          (server/handle-message fake-channel
                                 (server/generate-json {:type "connect"
                                                        :api-key invalid-key}))

          ;; Verify rejection
          (is (not (server/channel-authenticated? fake-channel))
              "Channel should NOT be authenticated with invalid key")
          (is @closed
              "Connection should be closed")
          (is (= 1 (count @sent-messages))
              "Should send exactly one error message")
          (let [error-msg (server/parse-json (first @sent-messages))]
            (is (= "auth_error" (:type error-msg))
                "Should send auth_error message")
            (is (= "Authentication failed" (:message error-msg))
                "Error message should be generic (no information leakage)")))
        (finally
          (swap! server/connected-clients dissoc fake-channel))))))

;; =============================================================================
;; E2E Test: Missing Key Rejected at WebSocket Connect
;; =============================================================================

(deftest e2e-missing-key-rejected-test
  (testing "Missing key is rejected at WebSocket connect"
    (let [fake-channel (Object.)
          sent-messages (atom [])
          closed (atom false)]

      (swap! server/connected-clients assoc fake-channel {})
      (try
        (with-redefs [org.httpkit.server/send! (fn [_ msg] (swap! sent-messages conj msg))
                      org.httpkit.server/close (fn [_] (reset! closed true))]

          ;; Connect WITHOUT api_key field
          (server/handle-message fake-channel
                                 (server/generate-json {:type "connect"
                                                        :session-id "test-session"}))

          ;; Verify rejection
          (is (not (server/channel-authenticated? fake-channel))
              "Channel should NOT be authenticated without key")
          (is @closed
              "Connection should be closed")
          (let [error-msg (server/parse-json (first @sent-messages))]
            (is (= "auth_error" (:type error-msg))
                "Should send auth_error for missing key")
            (is (= "Authentication failed" (:message error-msg))
                "Error message should be generic")))
        (finally
          (swap! server/connected-clients dissoc fake-channel))))))

;; =============================================================================
;; E2E Test: HTTP Upload with Valid Bearer Token
;; =============================================================================

(deftest e2e-http-upload-valid-bearer-test
  (testing "HTTP upload with valid Bearer token succeeds"
    (let [upload-dir (str *test-temp-dir* "/uploads")
          _ (.mkdirs (io/file upload-dir))
          test-content "Integration test file content"
          base64-content (.encodeToString (Base64/getEncoder) (.getBytes test-content "UTF-8"))
          sent-responses (atom [])
          fake-channel (Object.)
          request-body (server/generate-json {:filename "integration-test.txt"
                                              :content base64-content
                                              :storage-location upload-dir})
          req {:headers {"authorization" (str "Bearer " *test-api-key*)}
               :body (java.io.ByteArrayInputStream. (.getBytes request-body))}]

      (with-redefs [org.httpkit.server/send! (fn [_ msg] (swap! sent-responses conj msg))]
        (server/handle-http-upload req fake-channel)

        (is (= 1 (count @sent-responses))
            "Should send exactly one response")
        (let [resp (first @sent-responses)]
          (is (= 200 (:status resp))
              "Valid Bearer token should return 200")
          (let [body (server/parse-json (:body resp))]
            (is (= true (:success body))
                "Response should indicate success")
            (is (= "integration-test.txt" (:filename body))
                "Response should include filename"))))

      ;; Verify file was written
      (let [uploaded-file (io/file upload-dir ".untethered" "resources" "integration-test.txt")]
        (is (.exists uploaded-file)
            "File should exist on disk")
        (is (= test-content (slurp uploaded-file))
            "File content should match")))))

;; =============================================================================
;; E2E Test: HTTP Upload with Invalid Bearer Token Returns 401
;; =============================================================================

(deftest e2e-http-upload-invalid-bearer-test
  (testing "HTTP upload with invalid Bearer token returns 401"
    (let [upload-dir (str *test-temp-dir* "/uploads-invalid")
          _ (.mkdirs (io/file upload-dir))
          test-content "Should not be written"
          base64-content (.encodeToString (Base64/getEncoder) (.getBytes test-content "UTF-8"))
          sent-responses (atom [])
          fake-channel (Object.)
          wrong-key "voice-code-ffffffffffffffffffffffffffffffff"
          request-body (server/generate-json {:filename "should-not-exist.txt"
                                              :content base64-content
                                              :storage-location upload-dir})
          req {:headers {"authorization" (str "Bearer " wrong-key)}
               :body (java.io.ByteArrayInputStream. (.getBytes request-body))}]

      ;; Ensure wrong key differs from actual
      (is (not= wrong-key *test-api-key*)
          "Test setup: wrong key should differ from actual key")

      (with-redefs [org.httpkit.server/send! (fn [_ msg] (swap! sent-responses conj msg))]
        (server/handle-http-upload req fake-channel)

        (let [resp (first @sent-responses)]
          (is (= 401 (:status resp))
              "Invalid Bearer token should return 401")
          (is (= "Bearer realm=\"voice-code\"" (get-in resp [:headers "WWW-Authenticate"]))
              "Should include WWW-Authenticate header")
          (let [body (server/parse-json (:body resp))]
            (is (= false (:success body))
                "Response should indicate failure")
            (is (= "Authentication failed" (:error body))
                "Error should be generic"))))

      ;; Verify file was NOT written
      (let [would-be-file (io/file upload-dir ".untethered" "resources" "should-not-exist.txt")]
        (is (not (.exists would-be-file))
            "File should NOT exist when auth fails")))))

(deftest e2e-http-upload-missing-bearer-test
  (testing "HTTP upload without Authorization header returns 401"
    (let [upload-dir (str *test-temp-dir* "/uploads-missing")
          _ (.mkdirs (io/file upload-dir))
          test-content "Should not be written"
          base64-content (.encodeToString (Base64/getEncoder) (.getBytes test-content "UTF-8"))
          sent-responses (atom [])
          fake-channel (Object.)
          request-body (server/generate-json {:filename "no-auth.txt"
                                              :content base64-content
                                              :storage-location upload-dir})
          req {:headers {} ;; No Authorization header
               :body (java.io.ByteArrayInputStream. (.getBytes request-body))}]

      (with-redefs [org.httpkit.server/send! (fn [_ msg] (swap! sent-responses conj msg))]
        (server/handle-http-upload req fake-channel)

        (let [resp (first @sent-responses)]
          (is (= 401 (:status resp))
              "Missing Authorization header should return 401")
          (let [body (server/parse-json (:body resp))]
            (is (= "Authentication failed" (:error body))
                "Error should be generic"))))

      ;; Verify file was NOT written
      (let [would-be-file (io/file upload-dir ".untethered" "resources" "no-auth.txt")]
        (is (not (.exists would-be-file))
            "File should NOT exist without auth")))))

;; =============================================================================
;; E2E Test: Reconnection Maintains Authentication
;; =============================================================================

(deftest e2e-reconnection-authentication-test
  (testing "Reconnection with valid key maintains authenticated session"
    (let [channel-1 (Object.)
          channel-2 (Object.)
          session-id "persistent-session-123"
          sent-messages (atom [])]

      ;; First connection: authenticate
      (swap! server/connected-clients assoc channel-1 {})
      (with-redefs [org.httpkit.server/send! (fn [_ msg] (swap! sent-messages conj msg))
                    org.httpkit.server/close (fn [_] nil)
                    session-store/list-sessions (constantly [])
                    server/send-recent-sessions! (fn [_ _] nil)
                    server/send-to-client! (fn [_ _] nil)]

        (server/handle-message channel-1
                               (server/generate-json {:type "connect"
                                                      :session-id session-id
                                                      :api-key *test-api-key*}))

        (is (server/channel-authenticated? channel-1)
            "First connection should be authenticated"))

      ;; Simulate disconnect
      (swap! server/connected-clients dissoc channel-1)

      ;; Reconnection: new channel, same credentials
      (reset! sent-messages [])
      (swap! server/connected-clients assoc channel-2 {})

      (with-redefs [org.httpkit.server/send! (fn [_ msg] (swap! sent-messages conj msg))
                    org.httpkit.server/close (fn [_] nil)
                    session-store/list-sessions (constantly [])
                    server/send-recent-sessions! (fn [_ _] nil)
                    server/send-to-client! (fn [_ _] nil)]

        (server/handle-message channel-2
                               (server/generate-json {:type "connect"
                                                      :session-id session-id
                                                      :api-key *test-api-key*}))

        ;; Verify reconnection succeeded
        (is (server/channel-authenticated? channel-2)
            "Reconnected channel should be authenticated")
        (is (some #(= "session_list" (:type (server/parse-json %))) @sent-messages)
            "Should receive session_list on reconnection"))

      ;; Cleanup
      (swap! server/connected-clients dissoc channel-2)))

  (testing "Reconnection with invalid key fails (key was changed/regenerated)"
    (let [channel-1 (Object.)
          channel-2 (Object.)
          sent-messages (atom [])
          closed (atom false)]

      ;; First connection: authenticate with valid key
      (swap! server/connected-clients assoc channel-1 {})
      (with-redefs [org.httpkit.server/send! (fn [_ _] nil)
                    org.httpkit.server/close (fn [_] nil)
                    session-store/list-sessions (constantly [])
                    server/send-recent-sessions! (fn [_ _] nil)
                    server/send-to-client! (fn [_ _] nil)]
        (server/handle-message channel-1
                               (server/generate-json {:type "connect"
                                                      :api-key *test-api-key*})))
      (is (server/channel-authenticated? channel-1))

      ;; Disconnect
      (swap! server/connected-clients dissoc channel-1)

      ;; Simulate scenario: iOS has old key, backend has new key
      ;; (e.g., user ran `make regenerate-key` on backend)
      (let [old-key-on-ios "voice-code-oldkey12345678901234567890abcd"]
        (with-redefs [org.httpkit.server/send! (fn [_ msg] (swap! sent-messages conj msg))
                      org.httpkit.server/close (fn [_] (reset! closed true))]

          (server/handle-message channel-2
                                 (server/generate-json {:type "connect"
                                                        :api-key old-key-on-ios}))

          ;; Should fail - iOS needs to re-scan QR code
          (is (not (server/channel-authenticated? channel-2))
              "Should not authenticate with old key")
          (is @closed
              "Connection should be closed")
          (let [error-msg (server/parse-json (first @sent-messages))]
            (is (= "auth_error" (:type error-msg)))))))))

;; =============================================================================
;; E2E Test: Authenticated Session Can Send Messages
;; =============================================================================

(deftest e2e-authenticated-session-workflow-test
  (testing "Authenticated session can send various message types"
    (let [fake-channel (Object.)
          sent-messages (atom [])]

      ;; Connect and authenticate
      (swap! server/connected-clients assoc fake-channel {})
      (with-redefs [org.httpkit.server/send! (fn [_ msg] (swap! sent-messages conj msg))
                    org.httpkit.server/close (fn [_] nil)
                    session-store/list-sessions (constantly [])
                    server/send-recent-sessions! (fn [_ _] nil)
                    server/send-to-client! (fn [_ _] nil)]

        (server/handle-message fake-channel
                               (server/generate-json {:type "connect"
                                                      :api-key *test-api-key*}))
        (is (server/channel-authenticated? fake-channel)))

      ;; Now authenticated - test various message types work
      (reset! sent-messages [])

      ;; Test ping (should work without auth, but also when authenticated)
      (with-redefs [org.httpkit.server/send! (fn [_ msg] (swap! sent-messages conj msg))
                    org.httpkit.server/close (fn [_] nil)]
        (server/handle-message fake-channel
                               (server/generate-json {:type "ping"}))
        (is (= "pong" (:type (server/parse-json (last @sent-messages))))
            "Should receive pong after authenticated"))

      ;; Cleanup
      (swap! server/connected-clients dissoc fake-channel)))

  (testing "Unauthenticated channel cannot send protected messages"
    (let [fake-channel (Object.)
          sent-messages (atom [])
          closed (atom false)]

      ;; Do NOT authenticate
      (with-redefs [org.httpkit.server/send! (fn [_ msg] (swap! sent-messages conj msg))
                    org.httpkit.server/close (fn [_] (reset! closed true))]

        ;; Try to send subscribe without authentication
        (server/handle-message fake-channel
                               (server/generate-json {:type "subscribe"
                                                      :session-id "some-session"}))

        ;; Should be rejected
        (is @closed
            "Unauthenticated channel should be closed")
        (let [error-msg (server/parse-json (first @sent-messages))]
          (is (= "auth_error" (:type error-msg))
              "Should receive auth_error"))))))

;; =============================================================================
;; E2E Test: Key Format Validation (iOS-side simulation)
;; =============================================================================

(deftest e2e-key-format-validation-test
  (testing "Backend rejects keys with invalid format"
    ;; These keys have correct length but invalid content
    (let [fake-channel (Object.)
          sent-messages (atom [])
          closed (atom false)]

      (doseq [invalid-key ["voice-code-ABCDEF12345678901234567890abcdef" ; uppercase
                           "voice-code-ghijklmnopqrstuvwxyz1234567890" ; non-hex g-z
                           "wrong-code-a1b2c3d4e5f678901234567890abcde" ; wrong prefix, correct length
                           ]]
        (reset! sent-messages [])
        (reset! closed false)
        (swap! server/connected-clients assoc fake-channel {})

        (with-redefs [org.httpkit.server/send! (fn [_ msg] (swap! sent-messages conj msg))
                      org.httpkit.server/close (fn [_] (reset! closed true))]

          (server/handle-message fake-channel
                                 (server/generate-json {:type "connect"
                                                        :api-key invalid-key}))

          (is @closed
              (str "Should reject malformed key: " invalid-key))
          (is (= "auth_error" (:type (server/parse-json (first @sent-messages))))
              (str "Should send auth_error for: " invalid-key)))

        (swap! server/connected-clients dissoc fake-channel)))))

;; =============================================================================
;; E2E Test: Concurrent Connections with Same Key
;; =============================================================================

(deftest e2e-concurrent-connections-test
  (testing "Multiple connections can authenticate with same key"
    (let [channels (repeatedly 3 #(Object.))
          auth-results (atom {})]

      ;; Authenticate all channels
      (doseq [ch channels]
        (swap! server/connected-clients assoc ch {}))

      (with-redefs [org.httpkit.server/send! (fn [_ _] nil)
                    org.httpkit.server/close (fn [_] nil)
                    session-store/list-sessions (constantly [])
                    server/send-recent-sessions! (fn [_ _] nil)
                    server/send-to-client! (fn [_ _] nil)]

        (doseq [ch channels]
          (server/handle-message ch
                                 (server/generate-json {:type "connect"
                                                        :api-key *test-api-key*}))
          (swap! auth-results assoc ch (server/channel-authenticated? ch))))

      ;; All should be authenticated
      (doseq [ch channels]
        (is (get @auth-results ch)
            "Each connection should be independently authenticated"))

      ;; Cleanup
      (doseq [ch channels]
        (swap! server/connected-clients dissoc ch)))))

(comment
  ;; Manual E2E test procedure:
  ;;
  ;; 1. Start backend:
  ;;    cd backend && make run
  ;;    - Observe: "✓ API key ready. Run 'make show-key' to display."
  ;;
  ;; 2. Display QR code:
  ;;    make show-key-qr
  ;;    - Observe: QR code renders in terminal
  ;;
  ;; 3. Scan with iOS device:
  ;;    - Open VoiceCode app -> Settings -> Scan QR Code
  ;;    - Verify: Key saved successfully message
  ;;
  ;; 4. Connect:
  ;;    - App should automatically connect
  ;;    - Verify: Session list appears (authenticated)
  ;;
  ;; 5. Test invalid key rejection:
  ;;    - Delete key from iOS Keychain (Settings -> Delete API Key)
  ;;    - Enter fake key manually
  ;;    - Verify: "Authentication Required" screen appears
  ;;
  ;; 6. Test reconnection:
  ;;    - With valid key, kill backend (Ctrl+C)
  ;;    - Restart backend
  ;;    - Verify: iOS auto-reconnects without re-scanning QR
  ;;
  ;; 7. Test HTTP upload:
  ;;    - Share a file to VoiceCode Share Extension
  ;;    - Verify: Upload succeeds (Bearer token sent)
  )
