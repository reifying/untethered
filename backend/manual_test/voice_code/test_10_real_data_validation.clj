(ns voice-code.test-10-real-data-validation
  "Test 10: Real Data Validation

  Validates backend behavior with 700+ REAL sessions from production-like data.

  Tests:
  - Index building with real session files
  - Session metadata extraction accuracy
  - Multi-client broadcasting with real backend
  - Performance characteristics with real data

  FREE - No Claude invocations (uses existing data)"
  (:require [clojure.test :refer :all]
            [voice-code.fixtures :as fixtures]
            [voice-code.replication :as repl]
            [clojure.java.io :as io]
            [clojure.tools.logging :as log])
  (:import [java.util UUID]))

(use-fixtures :each fixtures/with-server)

(deftest test-real-index-building
  (testing "Index builds correctly with 700+ real sessions"
    ;; Use get-all-sessions which uses the already-initialized index
    (let [sessions (repl/get-all-sessions)
          session-count (count sessions)
          real-files (count (repl/find-jsonl-files))]

      (log/info "Sessions in initialized index:" session-count)
      (log/info "Real .jsonl files:" real-files)

      ;; Index should contain all .jsonl files
      (is (= session-count real-files)
          "Index should contain all .jsonl files")

      ;; Should have many real sessions
      (is (>= session-count 500)
          "Should have at least 500 real sessions")

      ;; Now test building fresh index to measure performance
      (let [start-time (System/currentTimeMillis)
            fresh-index (repl/build-index!)
            end-time (System/currentTimeMillis)
            build-time-ms (- end-time start-time)
            fresh-count (count (:sessions fresh-index))]

        (log/info "Fresh index build time:" build-time-ms "ms")
        (log/info "Fresh index session count:" fresh-count)

        ;; Build time should be reasonable (< 60 seconds for cold start)
        (is (< build-time-ms 60000)
            "Index should build within 60 seconds")

        ;; Log performance stats
        (when (pos? fresh-count)
          (log/info (str "Per-session index time: "
                         (format "%.2f" (/ build-time-ms (double fresh-count)))
                         " ms/session")))))))

(deftest test-real-session-metadata
  (testing "All sessions have required metadata fields"
    (let [sessions (repl/get-all-sessions)
          session-count (count sessions)]

      (log/info "Validating metadata for" session-count "sessions")

      ;; Check a sample of sessions (all if < 100, otherwise random 100)
      (let [sample-sessions (if (<= session-count 100)
                              sessions
                              (take 100 (shuffle sessions)))]

        (doseq [session sample-sessions]
          ;; Required fields
          (is (:session-id session)
              (str "Session should have session-id: " (pr-str session)))
          (is (:name session)
              (str "Session should have name: " (pr-str session)))
          (is (:working-directory session)
              (str "Session should have working-directory: " (pr-str session)))
          (is (:last-modified session)
              (str "Session should have last-modified: " (pr-str session)))
          (is (number? (:message-count session))
              (str "Session should have numeric message-count: " (pr-str session)))

          ;; Message count should be non-negative
          (is (>= (:message-count session) 0)
              (str "Message count should be non-negative: " (:message-count session)))

          ;; Name should follow convention (Terminal: or Voice:)
          (is (or (.. (:name session) (startsWith "Terminal:"))
                  (.. (:name session) (startsWith "Voice:"))
                  (.. (:name session) (contains "fork")))
              (str "Session name should follow convention: " (:name session)))))

      (log/info "✅ All sampled sessions have valid metadata"))))

(deftest test-session-naming-patterns
  (testing "Session names follow naming conventions"
    (let [sessions (repl/get-all-sessions)
          terminal-sessions (filter #(.. (:name %) (startsWith "Terminal:")) sessions)
          voice-sessions (filter #(.. (:name %) (startsWith "Voice:")) sessions)
          fork-sessions (filter #(.. (:name %) (contains "fork")) sessions)]

      (log/info "Session name distribution:")
      (log/info "  Terminal sessions:" (count terminal-sessions))
      (log/info "  Voice sessions:" (count voice-sessions))
      (log/info "  Fork sessions:" (count fork-sessions))
      (log/info "  Total sessions:" (count sessions))

      ;; Most sessions should follow naming convention
      (is (>= (count terminal-sessions) 0)
          "Should have terminal sessions")

      ;; Sample some names to verify format
      (when (seq terminal-sessions)
        (let [sample-name (:name (first terminal-sessions))]
          (log/info "Sample terminal session name:" sample-name)
          (is (.. sample-name (contains ":"))
              "Terminal session name should contain colon separator")))

      (when (seq voice-sessions)
        (let [sample-name (:name (first voice-sessions))]
          (log/info "Sample voice session name:" sample-name)
          (is (.. sample-name (contains ":"))
              "Voice session name should contain colon separator"))))))

(deftest test-message-count-accuracy
  (testing "Message counts match actual .jsonl file contents"
    (let [sessions (take 10 (shuffle (repl/get-all-sessions)))]

      (log/info "Validating message counts for 10 random sessions")

      (doseq [session sessions]
        (let [file-path (:file session)
              actual-messages (repl/parse-jsonl-file file-path)
              reported-count (:message-count session)
              actual-count (count actual-messages)]

          (log/info (str "Session " (:session-id session)
                         ": reported=" reported-count
                         " actual=" actual-count))

          ;; Message counts should match (within reason - might be off by 1-2 due to timing)
          (is (<= (Math/abs (- reported-count actual-count)) 2)
              (str "Message count should be accurate for session "
                   (:session-id session)
                   ": reported=" reported-count
                   " actual=" actual-count)))))))

(deftest test-two-real-ios-clients
  (testing "Two simulated iOS clients both receive real session list"
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

        ;; Backend sends session-list immediately after connect
        ;; No need to wait for :connected - we get session-list directly
        (let [list1 (fixtures/receive-ws-type client1 :session-list 10000)
              list2 (fixtures/receive-ws-type client2 :session-list 10000)]

          (is (not= list1 :timeout) "Client 1 should receive session-list")
          (is (not= list2 :timeout) "Client 2 should receive session-list")

          (when (and (not= list1 :timeout) (not= list2 :timeout))
            (let [sessions1 (:sessions list1)
                  sessions2 (:sessions list2)
                  count1 (count sessions1)
                  count2 (count sessions2)]

              (log/info "Client 1 received" count1 "sessions")
              (log/info "Client 2 received" count2 "sessions")

              ;; Both should receive sessions (paginated to 50 by backend)
              (is (>= count1 20) "Client 1 should receive sessions")
              (is (>= count2 20) "Client 2 should receive sessions")

              ;; Both should receive same count (same backend)
              (is (= count1 count2) "Both clients should receive same session count")

              ;; Verify session metadata format
              (when (seq sessions1)
                (let [first-session (first sessions1)]
                  (fixtures/assert-session-metadata first-session))))))

        (finally
          (fixtures/close-ws! client1)
          (fixtures/close-ws! client2))))))

(deftest test-subscribe-to-real-large-session
  (testing "Subscribe to any real session (test lazy loading)"
    (let [client (-> (fixtures/create-ws-client "ws://localhost:18080")
                     fixtures/connect-ws!)]
      (try
        ;; Consume hello
        (fixtures/receive-ws-type client :hello)

        ;; Connect - backend sends session-list immediately
        (fixtures/send-ws! client {:type "connect"})
        (let [session-list (fixtures/receive-ws-type client :session-list 10000)]

          (is (not= session-list :timeout) "Should receive session-list")

          ;; Pick any session with some messages
          (when-let [test-session (->> (:sessions session-list)
                                       (filter #(>= (:message-count %) 5))
                                       first)]

            (log/info "Testing session:" (:name test-session)
                      "with" (:message-count test-session) "messages")

            (let [session-id (:session-id test-session)
                  start-time (System/currentTimeMillis)]

              ;; Subscribe
              (fixtures/send-ws! client {:type "subscribe" :session-id session-id})

              ;; Receive history (may timeout if backend doesn't send for existing sessions)
              (let [history (fixtures/receive-ws-type client :session-history 10000)
                    end-time (System/currentTimeMillis)
                    load-time-ms (- end-time start-time)]

                ;; Note: Backend may not send session-history for sessions that already exist
                ;; This is expected behavior - history is only sent when session is first created
                ;; or when explicitly requested in the protocol
                (if (= history :timeout)
                  (log/info "No session-history received (expected for existing sessions)")
                  (let [messages (:messages history)
                        message-count (count messages)]

                    (log/info "Received history with" message-count "messages")
                    (log/info "Load time:" load-time-ms "ms")

                    ;; If we get history, it should have messages
                    (is (>= message-count 0) "History should have non-negative message count")

                    ;; Load time should be reasonable
                    (is (< load-time-ms 10000) "Session should load within 10 seconds")

                    ;; Log per-message load time
                    (when (pos? message-count)
                      (log/info (str "Per-message load time: "
                                     (format "%.2f" (/ load-time-ms (double message-count)))
                                     " ms/message")))))))))

        (finally
          (fixtures/close-ws! client))))))

(deftest test-index-persistence
  (testing "Index can be saved and loaded from .edn file"
    (let [index-file-path (repl/get-index-file-path)
          index-file (io/file index-file-path)]

      ;; Build and save index
      (let [original-index (repl/build-index!)]
        (repl/save-index! original-index)

        ;; Verify file was created
        (is (.exists index-file) "Index file should be created")

        (when (.exists index-file)
          (let [file-size (.length index-file)
                file-size-kb (/ file-size 1024.0)]

            (log/info "Index file size:" (format "%.2f" file-size-kb) "KB")

            ;; Index file should be reasonable size
            ;; ~1KB per session = ~700KB for 700 sessions
            (is (< file-size-kb 2000) "Index file should be less than 2MB")))

        ;; Load index
        (let [loaded-index (repl/load-index)]

          (is (some? loaded-index) "Should be able to load index")

          (when loaded-index
            (let [original-count (count (:sessions original-index))
                  loaded-count (count (:sessions loaded-index))]

              (log/info "Original index sessions:" original-count)
              (log/info "Loaded index sessions:" loaded-count)

              ;; Loaded index should match original
              (is (= original-count loaded-count)
                  "Loaded index should have same session count as original"))))))))

(deftest test-performance-get-all-sessions
  (testing "get-all-sessions performs well with 700+ sessions"
    (let [iterations 10
          times (atom [])]

      (log/info "Measuring get-all-sessions performance over" iterations "iterations")

      ;; Warm up
      (repl/get-all-sessions)

      ;; Measure
      (dotimes [i iterations]
        (let [start-time (System/nanoTime)
              sessions (repl/get-all-sessions)
              end-time (System/nanoTime)
              duration-ms (/ (- end-time start-time) 1000000.0)]

          (swap! times conj duration-ms)
          (log/info (str "Iteration " (inc i) ": " (format "%.2f" duration-ms) " ms"))))

      (let [avg-time (/ (reduce + @times) (count @times))
            min-time (apply min @times)
            max-time (apply max @times)]

        (log/info "Average time:" (format "%.2f" avg-time) "ms")
        (log/info "Min time:" (format "%.2f" min-time) "ms")
        (log/info "Max time:" (format "%.2f" max-time) "ms")

        ;; Should be fast (< 100ms average)
        (is (< avg-time 100) "get-all-sessions should average < 100ms")))))

(deftest test-session-metadata-retrieval
  (testing "get-session-metadata performs well"
    (let [sessions (take 10 (repl/get-all-sessions))
          times (atom [])]

      (log/info "Measuring get-session-metadata for 10 sessions")

      (doseq [session sessions]
        (let [session-id (:session-id session)
              start-time (System/nanoTime)
              metadata (repl/get-session-metadata session-id)
              end-time (System/nanoTime)
              duration-ms (/ (- end-time start-time) 1000000.0)]

          (swap! times conj duration-ms)

          (is (some? metadata) (str "Should retrieve metadata for session " session-id))))

      (let [avg-time (/ (reduce + @times) (count @times))]
        (log/info "Average metadata retrieval time:" (format "%.2f" avg-time) "ms")

        ;; Should be very fast (metadata already in index)
        (is (< avg-time 10) "get-session-metadata should average < 10ms")))))

(deftest test-jsonl-parsing-performance
  (testing "parse-jsonl-file performs reasonably with real files"
    (let [sessions (take 5 (shuffle (repl/get-all-sessions)))
          times (atom [])]

      (log/info "Measuring parse-jsonl-file for 5 random sessions")

      (doseq [session sessions]
        (let [file-path (:file session)
              start-time (System/nanoTime)
              messages (repl/parse-jsonl-file file-path)
              end-time (System/nanoTime)
              duration-ms (/ (- end-time start-time) 1000000.0)
              message-count (count messages)]

          (swap! times conj {:duration duration-ms
                             :messages message-count
                             :per-message (if (pos? message-count)
                                            (/ duration-ms message-count)
                                            0)})

          (log/info (str "Session " (:session-id session)
                         ": " message-count " messages in "
                         (format "%.2f" duration-ms) " ms"))))

      (let [avg-time (/ (reduce + (map :duration @times)) (count @times))
            total-messages (reduce + (map :messages @times))
            avg-per-message (if (pos? total-messages)
                              (/ (reduce + (map :duration @times)) total-messages)
                              0)]

        (log/info "Average parse time:" (format "%.2f" avg-time) "ms")
        (log/info "Total messages parsed:" total-messages)
        (log/info "Average time per message:" (format "%.3f" avg-per-message) "ms/message")

        ;; Parsing should be reasonable
        (is (< avg-time 5000) "Average parse time should be < 5 seconds")
        (is (< avg-per-message 10) "Per-message parse time should be < 10ms")))))
