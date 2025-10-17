(ns voice-code.test-08-broadcast
  "Test 8: Multi-Client Broadcast

  Verifies:
  - Multiple WebSocket clients receive same session-created broadcast
  - Messages are identical across clients
  - Broadcast timing is reasonable

  FREE - No Claude invocations (simulates file creation)"
  (:require [clojure.test :refer :all]
            [voice-code.fixtures :as fixtures]
            [clojure.java.io :as io]
            [clojure.tools.logging :as log])
  (:import [java.util UUID]))

(use-fixtures :each fixtures/with-server)

(deftest test-multi-client-broadcast
  (testing "Multiple clients receive session-created broadcast"
    (let [client1 (-> (fixtures/create-ws-client "ws://localhost:18080")
                      fixtures/connect-ws!)
          client2 (-> (fixtures/create-ws-client "ws://localhost:18080")
                      fixtures/connect-ws!)]
      (try
        ;; Consume hello messages
        (fixtures/receive-ws-type client1 :hello)
        (fixtures/receive-ws-type client2 :hello)

        ;; Both clients connect
        (fixtures/send-ws! client1 {:type "connect"})
        (fixtures/send-ws! client2 {:type "connect"})

        ;; Consume session-list messages
        (fixtures/receive-ws-type client1 :session-list)
        (fixtures/receive-ws-type client2 :session-list)

        ;; Create a test session file to trigger broadcast
        (let [session-id (str "test-broadcast-" (UUID/randomUUID))
              ;; Find a project directory to use
              projects-dir (io/file (System/getProperty "user.home") ".claude" "projects")
              project-dirs (->> (.listFiles projects-dir)
                               (filter #(.isDirectory %))
                               (remove #(.. % getName (startsWith "."))))
              project-dir (or (first project-dirs)
                            (throw (ex-info "No project directories found" {})))
              session-file (io/file project-dir (str session-id ".jsonl"))]

          (log/info "Creating test session file:" (.getPath session-file))

          ;; Write test session file
          (spit session-file
                (str "{\"type\":\"prompt\",\"text\":\"test broadcast\",\"timestamp\":\""
                     (java.time.Instant/now) "\"}\n"))

          ;; Both clients should receive session-created broadcast
          (let [msg1 (fixtures/receive-ws-type client1 :session-created 3000)
                msg2 (fixtures/receive-ws-type client2 :session-created 3000)]

            (is (not= msg1 :timeout) "Client 1 should receive session-created")
            (is (not= msg2 :timeout) "Client 2 should receive session-created")

            ;; Verify both messages are about the same session
            (is (= session-id (:session-id msg1)) "Client 1 should get correct session ID")
            (is (= session-id (:session-id msg2)) "Client 2 should get correct session ID")

            ;; Verify messages are identical
            (is (= msg1 msg2) "Both clients should receive identical messages")

            (log/info "Both clients received broadcast for session:" session-id)

            ;; Clean up test file
            (.delete session-file)))
        (finally
          (fixtures/close-ws! client1)
          (fixtures/close-ws! client2))))))

(deftest test-broadcast-excludes-deleted-sessions
  (testing "Clients who deleted a session don't receive its updates"
    (let [client1 (-> (fixtures/create-ws-client "ws://localhost:18080")
                      fixtures/connect-ws!)
          client2 (-> (fixtures/create-ws-client "ws://localhost:18080")
                      fixtures/connect-ws!)]
      (try
        ;; Consume hello messages
        (fixtures/receive-ws-type client1 :hello)
        (fixtures/receive-ws-type client2 :hello)

        ;; Both clients connect
        (fixtures/send-ws! client1 {:type "connect"})
        (fixtures/send-ws! client2 {:type "connect"})

        ;; Consume session-list
        (fixtures/receive-ws-type client1 :session-list)
        (fixtures/receive-ws-type client2 :session-list)

        ;; Create test session
        (let [session-id (str "test-deleted-" (UUID/randomUUID))
              projects-dir (io/file (System/getProperty "user.home") ".claude" "projects")
              project-dirs (->> (.listFiles projects-dir)
                               (filter #(.isDirectory %))
                               (remove #(.. % getName (startsWith "."))))
              project-dir (first project-dirs)
              session-file (io/file project-dir (str session-id ".jsonl"))]

          ;; Client 1 marks session as deleted
          (fixtures/send-ws! client1 {:type "session-deleted" :session-id session-id})
          (Thread/sleep 200)

          ;; Create the session file
          (spit session-file
                (str "{\"type\":\"prompt\",\"text\":\"test\",\"timestamp\":\""
                     (java.time.Instant/now) "\"}\n"))

          ;; Only client 2 should receive the broadcast
          (let [msg2 (fixtures/receive-ws-type client2 :session-created 3000)
                ;; Client 1 should timeout (no message)
                msg1 (fixtures/receive-ws client1 1000)]

            (is (not= msg2 :timeout) "Client 2 should receive broadcast")
            (is (= :timeout msg1) "Client 1 should not receive broadcast (deleted)")

            (log/info "Broadcast correctly excluded client who deleted session")

            ;; Clean up
            (.delete session-file)))
        (finally
          (fixtures/close-ws! client1)
          (fixtures/close-ws! client2))))))
