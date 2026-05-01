(ns voice-code.server-protocol-version-test
  "Tests for the hello handshake protocol-version guard (AC7 in the
   append-only-message-stream design). The backend must reject clients
   announcing `protocol_version < 0.4.0` with the exact error envelope
   required by the iOS client, and the check must be gated on the
   :message-stream-version config flag so flipping to :v0.3.0 disables
   it cleanly."
  (:require [clojure.test :refer :all]
            [voice-code.server :as server]))

(def ^:private test-api-key "voice-code-a1b2c3d4e5f678901234567890abcdef")

(defn- with-test-api-key
  "Pin an API key for the duration of each test so connect can progress past
   the protocol-version guard into authentication where relevant."
  [f]
  (let [original @server/api-key]
    (reset! server/api-key test-api-key)
    (try (f)
         (finally (reset! server/api-key original)))))

(defn- with-stream-version-atom
  "Restore the :message-stream-version atom after every test; individual
   tests `reset!` it to drive enforce vs. lax mode."
  [f]
  (let [original @server/message-stream-version]
    (try (f)
         (finally (reset! server/message-stream-version original)))))

(use-fixtures :each with-test-api-key with-stream-version-atom)

;; ---------------------------------------------------------------------------
;; parse-protocol-version

(deftest parse-protocol-version-test
  (testing "parses three-part semver"
    (is (= [0 3 0] (server/parse-protocol-version "0.3.0")))
    (is (= [0 4 0] (server/parse-protocol-version "0.4.0")))
    (is (= [1 2 3] (server/parse-protocol-version "1.2.3"))))

  (testing "strips pre-release and build suffixes"
    (is (= [0 3 0] (server/parse-protocol-version "0.3.0-rc1")))
    (is (= [0 4 1] (server/parse-protocol-version "0.4.1+build.5"))))

  (testing "returns nil for unparseable input"
    (is (nil? (server/parse-protocol-version nil)))
    (is (nil? (server/parse-protocol-version "")))
    (is (nil? (server/parse-protocol-version "0.3")))        ;; only two parts
    (is (nil? (server/parse-protocol-version "0.3.0.1")))    ;; four parts
    (is (nil? (server/parse-protocol-version "zero.3.0")))
    (is (nil? (server/parse-protocol-version :0.4.0)))))     ;; non-string

;; ---------------------------------------------------------------------------
;; client-protocol-too-old?

(deftest client-protocol-too-old?-test
  (testing "true only when announced version is explicitly below 0.4.0"
    (is (true?  (server/client-protocol-too-old? {:protocol-version "0.3.0"})))
    (is (true?  (server/client-protocol-too-old? {:protocol-version "0.3.9"})))
    (is (true?  (server/client-protocol-too-old? {:protocol-version "0.2.0"}))))

  (testing "false for the cutoff and any newer version"
    (is (not (server/client-protocol-too-old? {:protocol-version "0.4.0"})))
    (is (not (server/client-protocol-too-old? {:protocol-version "0.4.1"})))
    (is (not (server/client-protocol-too-old? {:protocol-version "1.0.0"}))))

  (testing "missing or unparseable version is treated as 'unknown, not old'"
    ;; Current v0.4.0 clients do not announce a version; they must pass.
    (is (not (server/client-protocol-too-old? {})))
    (is (not (server/client-protocol-too-old? {:protocol-version nil})))
    (is (not (server/client-protocol-too-old? {:protocol-version "garbage"})))))

;; ---------------------------------------------------------------------------
;; enforce-protocol-version! — exact-shape rejection, socket close, gating

(defn- capture-send-and-close
  "Run body with send!/close rebound so the test can inspect what was sent
   and whether the channel was closed. Returns {:sent [..] :closed? bool}."
  [body-fn]
  (let [sent   (atom [])
        closed (atom false)]
    (with-redefs [org.httpkit.server/send! (fn [_ msg] (swap! sent conj msg))
                  org.httpkit.server/close (fn [_] (reset! closed true))]
      (body-fn))
    {:sent @sent :closed? @closed}))

(deftest enforce-protocol-version!-rejects-old-client-with-exact-payload
  (testing "announcing 0.3.0 with enforcement on sends the canonical error and closes"
    (reset! server/message-stream-version :v0.4.0)
    (let [fake-channel (Object.)
          result (atom nil)
          {:keys [sent closed?]}
          (capture-send-and-close
           #(reset! result
                    (server/enforce-protocol-version!
                     fake-channel {:protocol-version "0.3.0"})))]
      (is (false? @result) "returns false so the caller halts authentication")
      (is closed? "socket must be closed immediately after the error send")
      (is (= 1 (count sent)) "exactly one error envelope is written")
      (let [payload (server/parse-json (first sent))]
        ;; Exact keys + values required by AC7 / the iOS client test fixture.
        (is (= "error"                        (:type payload)))
        (is (= "unsupported_protocol_version" (:code payload)))
        (is (= "0.4.0"                        (:required payload)))
        (is (= "0.3.0"                        (:received payload)))
        (is (= "Client is too old; upgrade required" (:message payload)))
        ;; No extra top-level keys may leak onto the wire; iOS fixtures pin
        ;; this shape, so additions here would require coordinated updates.
        (is (= #{:type :code :required :received :message}
               (set (keys payload))))))))

(deftest enforce-protocol-version!-passes-through-valid-or-absent-version
  (reset! server/message-stream-version :v0.4.0)
  (testing "no :protocol-version field — the common iOS 0.4.0 path — is accepted"
    (let [fake-channel (Object.)
          result (atom nil)
          {:keys [sent closed?]}
          (capture-send-and-close
           #(reset! result (server/enforce-protocol-version! fake-channel {})))]
      (is (true? @result))
      (is (empty? sent) "no error payload should be emitted")
      (is (false? closed?) "socket must stay open")))

  (testing "announcing 0.4.0 exactly is accepted (the cutoff is >=, not >)"
    (let [fake-channel (Object.)
          result (atom nil)
          {:keys [sent closed?]}
          (capture-send-and-close
           #(reset! result
                    (server/enforce-protocol-version!
                     fake-channel {:protocol-version "0.4.0"})))]
      (is (true? @result))
      (is (empty? sent))
      (is (false? closed?))))

  (testing "announcing a newer version is accepted"
    (let [fake-channel (Object.)
          result (atom nil)
          {:keys [sent closed?]}
          (capture-send-and-close
           #(reset! result
                    (server/enforce-protocol-version!
                     fake-channel {:protocol-version "0.5.2"})))]
      (is (true? @result))
      (is (empty? sent))
      (is (false? closed?)))))

(deftest enforce-protocol-version!-lax-mode-accepts-old-clients
  ;; Rollback: flipping :message-stream-version to :v0.3.0 must disable the
  ;; guard so existing v0.3.0 clients keep working while we recover.
  (reset! server/message-stream-version :v0.3.0)
  (testing "announcing 0.3.0 is accepted when enforcement is off"
    (let [fake-channel (Object.)
          result (atom nil)
          {:keys [sent closed?]}
          (capture-send-and-close
           #(reset! result
                    (server/enforce-protocol-version!
                     fake-channel {:protocol-version "0.3.0"})))]
      (is (true? @result) "lax mode returns true even for pre-0.4.0 clients")
      (is (empty? sent) "no rejection payload in lax mode")
      (is (false? closed?) "socket must stay open in lax mode"))))

;; ---------------------------------------------------------------------------
;; Integration: handle-message "connect" with the guard enabled vs. disabled

(deftest connect-message-rejects-old-client-in-enforce-mode
  (testing "handle-message short-circuits auth and emits the canonical error"
    (reset! server/message-stream-version :v0.4.0)
    (let [fake-channel (Object.)
          sent (atom [])
          closed (atom false)]
      (with-redefs [org.httpkit.server/send! (fn [_ m] (swap! sent conj m))
                    org.httpkit.server/close (fn [_] (reset! closed true))]
        (server/handle-message
         fake-channel
         (server/generate-json {:type "connect"
                                :api-key test-api-key
                                :protocol-version "0.3.0"})))
      (is @closed "guard must close the socket before the auth branch runs")
      (is (not (server/channel-authenticated? fake-channel))
          "no authentication should be recorded for a rejected client")
      (is (= 1 (count @sent)) "only the rejection envelope is written")
      (let [payload (server/parse-json (first @sent))]
        (is (= "error"                        (:type payload)))
        (is (= "unsupported_protocol_version" (:code payload)))
        (is (= "0.4.0"                        (:required payload)))
        (is (= "0.3.0"                        (:received payload)))))))

(deftest connect-message-allows-old-client-in-lax-mode
  ;; Same inputs as the rejection test above, but with the rollback flag set:
  ;; the guard must be a no-op and authentication must proceed normally.
  (testing "handle-message continues into the normal connect flow when enforcement is off"
    (reset! server/message-stream-version :v0.3.0)
    (let [fake-channel (Object.)
          sent (atom [])
          closed (atom false)]
      (with-redefs [org.httpkit.server/send! (fn [_ m] (swap! sent conj m))
                    org.httpkit.server/close (fn [_] (reset! closed true))
                    voice-code.replication/get-all-sessions (constantly [])
                    server/send-recent-sessions! (fn [_ _] nil)
                    server/send-available-commands! (fn [_ _] nil)
                    voice-code.supervisor/start-supervisor! (fn [_] nil)]
        (server/handle-message
         fake-channel
         (server/generate-json {:type "connect"
                                :api-key test-api-key
                                :protocol-version "0.3.0"})))
      (is (false? @closed) "lax mode must not close the socket for a 0.3.0 client")
      (is (server/channel-authenticated? fake-channel)
          "lax mode must still complete authentication normally")
      ;; Whatever messages were sent, none of them should be the canonical
      ;; unsupported_protocol_version envelope.
      (is (not-any? (fn [m]
                      (let [p (server/parse-json m)]
                        (and (= "error" (:type p))
                             (= "unsupported_protocol_version" (:code p)))))
                    @sent)
          "no unsupported_protocol_version should be emitted in lax mode")
      ;; Clean up state so we don't leak into other tests.
      (swap! server/connected-clients dissoc fake-channel))))

(deftest connect-message-allows-missing-and-nil-protocol-version-in-enforce-mode
  ;; The hello guard treats two distinct wire shapes as equivalent: a connect
  ;; with no `protocol_version` key (the path every existing v0.4.0 iOS client
  ;; actually walks today) and a connect that explicitly sends
  ;; `protocol_version: null`. `client-protocol-too-old?` already pins the
  ;; pure-function behavior; this test pins the integration: with enforcement
  ;; on, both messages must complete authentication and emit no
  ;; unsupported_protocol_version error.
  (testing "no protocol_version key: connect succeeds without rejection"
    (reset! server/message-stream-version :v0.4.0)
    (let [fake-channel (Object.)
          sent (atom [])
          closed (atom false)
          msg (server/generate-json {:type "connect"
                                     :api-key test-api-key})]
      (is (not (re-find #"protocol_version" msg))
          "sanity: this branch must omit the key on the wire")
      (with-redefs [org.httpkit.server/send! (fn [_ m] (swap! sent conj m))
                    org.httpkit.server/close (fn [_] (reset! closed true))
                    voice-code.replication/get-all-sessions (constantly [])
                    server/send-recent-sessions! (fn [_ _] nil)
                    server/send-available-commands! (fn [_ _] nil)
                    voice-code.supervisor/start-supervisor! (fn [_] nil)]
        (server/handle-message fake-channel msg))
      (is (false? @closed)
          "missing protocol_version must not trip the enforce-mode guard")
      (is (server/channel-authenticated? fake-channel)
          "connection should complete authentication normally")
      (is (not-any? (fn [m]
                      (let [p (server/parse-json m)]
                        (and (= "error" (:type p))
                             (= "unsupported_protocol_version" (:code p)))))
                    @sent)
          "no unsupported_protocol_version envelope should be emitted")
      (swap! server/connected-clients dissoc fake-channel)))

  (testing "explicit protocol_version: null: connect succeeds without rejection"
    (reset! server/message-stream-version :v0.4.0)
    (let [fake-channel (Object.)
          sent (atom [])
          closed (atom false)
          msg (server/generate-json {:type "connect"
                                     :api-key test-api-key
                                     :protocol-version nil})]
      (is (re-find #"\"protocol_version\":null" msg)
          "sanity: this branch must emit an explicit null on the wire")
      (with-redefs [org.httpkit.server/send! (fn [_ m] (swap! sent conj m))
                    org.httpkit.server/close (fn [_] (reset! closed true))
                    voice-code.replication/get-all-sessions (constantly [])
                    server/send-recent-sessions! (fn [_ _] nil)
                    server/send-available-commands! (fn [_ _] nil)
                    voice-code.supervisor/start-supervisor! (fn [_] nil)]
        (server/handle-message fake-channel msg))
      (is (false? @closed)
          "explicit null protocol_version must be treated identically to a missing key")
      (is (server/channel-authenticated? fake-channel)
          "connection should complete authentication normally")
      (is (not-any? (fn [m]
                      (let [p (server/parse-json m)]
                        (and (= "error" (:type p))
                             (= "unsupported_protocol_version" (:code p)))))
                    @sent)
          "no unsupported_protocol_version envelope should be emitted")
      (swap! server/connected-clients dissoc fake-channel))))
