(ns voice-code.server-protocol-version-test
  "Tests for protocol-version handshake behavior.

   Two related concerns share this file:

   1. Hello-handshake reject guard (AC7 in the append-only-message-stream
      design). The backend must reject clients announcing
      `protocol_version < 0.4.0` with the exact error envelope required
      by the iOS client, and the check must be gated on the
      :message-stream-version config flag so flipping to :v0.3.0 disables
      it cleanly.

   2. Per-channel `:negotiated-protocol-version` selection on connect
      (§3.2 of voice-code-sync-kafka-redesign-2026-05-10.md). The connect
      handler computes `min(client-version, server-max-protocol-version)`
      and surfaces the result on the channel state AND on the wire
      (`negotiated_protocol_version` field on the :connected reply), so a
      `VC_OFFSET_PROTOCOL=0` silent downgrade leaves the iOS client
      aware of which wire shape to use."
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

(defn- with-server-max-atom
  "Restore the :server-max-protocol-version atom after every test; tests
   reset it to drive the cap (e.g. `VC_OFFSET_PROTOCOL=0` style downgrade)."
  [f]
  (let [original @server/server-max-protocol-version]
    (try (f)
         (finally (reset! server/server-max-protocol-version original)))))

(use-fixtures :each with-test-api-key with-stream-version-atom with-server-max-atom)

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

;; ---------------------------------------------------------------------------
;; v0.5.0 per-channel negotiation (§3.2 of voice-code-sync-kafka-redesign).

(deftest negotiate-channel-protocol-version-test
  (testing "omitted/unparseable client version falls back to floor"
    (is (= :v0.4.0 (server/negotiate-channel-protocol-version nil :v0.4.0 :v0.5.0)))
    (is (= :v0.4.0 (server/negotiate-channel-protocol-version "" :v0.4.0 :v0.5.0)))
    (is (= :v0.4.0 (server/negotiate-channel-protocol-version "garbage" :v0.4.0 :v0.5.0)))
    ;; Rollback to v0.3.0 floor — omitted version follows the floor down.
    (is (= :v0.3.0 (server/negotiate-channel-protocol-version nil :v0.3.0 :v0.5.0))))

  (testing "client at/below server-max is honored exactly"
    (is (= :v0.4.0 (server/negotiate-channel-protocol-version "0.4.0" :v0.4.0 :v0.5.0)))
    (is (= :v0.5.0 (server/negotiate-channel-protocol-version "0.5.0" :v0.4.0 :v0.5.0))))

  (testing "client above server-max is capped at server-max (no rejection)"
    ;; A future v0.6.0 client against a v0.5.0-capped server must still
    ;; negotiate down rather than get rejected, mirroring the
    ;; VC_OFFSET_PROTOCOL=0 silent-downgrade design.
    (is (= :v0.5.0 (server/negotiate-channel-protocol-version "0.6.0" :v0.4.0 :v0.5.0)))
    (is (= :v0.4.0 (server/negotiate-channel-protocol-version "1.2.3" :v0.4.0 :v0.4.0))))

  (testing "VC_OFFSET_PROTOCOL=0 style cap of :v0.4.0 silently downgrades v0.5.0 clients"
    (is (= :v0.4.0 (server/negotiate-channel-protocol-version "0.5.0" :v0.4.0 :v0.4.0))))

  (testing "lax-mode v0.3.0 client falls through to :v0.3.0 (enforce-protocol-version! lets it past)"
    (is (= :v0.3.0 (server/negotiate-channel-protocol-version "0.3.0" :v0.3.0 :v0.5.0))))

  (testing "unsupported parseable triples fall back to floor as a safety net"
    ;; A "0.2.0" client that slipped past lax-mode enforcement maps to
    ;; nothing in protocol-version-keyword-by-vec; the function must not
    ;; return nil — it falls back to floor so downstream dispatch never
    ;; sees an unknown keyword.
    (is (= :v0.4.0 (server/negotiate-channel-protocol-version "0.2.0" :v0.4.0 :v0.5.0))))

  (testing "zero-arg form reads the live atoms"
    (reset! server/message-stream-version :v0.4.0)
    (reset! server/server-max-protocol-version :v0.5.0)
    (is (= :v0.5.0 (server/negotiate-channel-protocol-version "0.5.0")))
    (is (= :v0.4.0 (server/negotiate-channel-protocol-version "0.4.0")))
    (is (= :v0.4.0 (server/negotiate-channel-protocol-version nil)))
    (reset! server/server-max-protocol-version :v0.4.0)
    (is (= :v0.4.0 (server/negotiate-channel-protocol-version "0.5.0"))
        "lowering the cap to v0.4.0 silently downgrades a v0.5.0 client")))

(deftest channel-protocol-test
  (testing "returns the persisted :negotiated-protocol-version for a channel"
    (let [fake-channel (Object.)]
      (try
        (swap! server/connected-clients assoc fake-channel
               {:negotiated-protocol-version :v0.5.0})
        (is (= :v0.5.0 (server/channel-protocol fake-channel)))
        (swap! server/connected-clients assoc-in
               [fake-channel :negotiated-protocol-version] :v0.4.0)
        (is (= :v0.4.0 (server/channel-protocol fake-channel)))
        (finally
          (swap! server/connected-clients dissoc fake-channel)))))

  (testing "returns nil for an unknown channel (no handshake yet)"
    (is (nil? (server/channel-protocol (Object.))))))

(defn- run-connect
  "Run handle-message with a connect frame, stubbing every downstream
   side-effect the handler triggers so the test stays isolated. Returns
   {:sent [..]} (in receive order)."
  [fake-channel msg]
  (let [sent (atom [])
        closed (atom false)]
    (with-redefs [org.httpkit.server/send! (fn [_ m] (swap! sent conj m))
                  org.httpkit.server/close (fn [_] (reset! closed true))
                  voice-code.replication/get-all-sessions (constantly [])
                  server/send-recent-sessions! (fn [_ _] nil)
                  server/send-available-commands! (fn [_ _] nil)
                  voice-code.supervisor/start-supervisor! (fn [_] nil)]
      (server/handle-message fake-channel msg))
    {:sent @sent :closed? @closed}))

(defn- connected-frame
  "Pluck the :connected frame from a captured send sequence. Returns the
   parsed map, or nil if none was emitted."
  [sent]
  (some (fn [m]
          (let [p (server/parse-json m)]
            (when (= "connected" (:type p)) p)))
        sent))

(deftest connect-handler-stores-negotiated-protocol-version-on-channel
  (testing "client announcing 0.5.0 against the default :v0.5.0 cap → channel gets :v0.5.0"
    (reset! server/message-stream-version :v0.4.0)
    (reset! server/server-max-protocol-version :v0.5.0)
    (let [fake-channel (Object.)]
      (try
        (run-connect fake-channel
                     (server/generate-json {:type "connect"
                                            :api-key test-api-key
                                            :protocol-version "0.5.0"}))
        (is (= :v0.5.0 (server/channel-protocol fake-channel)))
        (finally
          (swap! server/connected-clients dissoc fake-channel)))))

  (testing "client announcing 0.4.0 against the default :v0.5.0 cap → channel gets :v0.4.0"
    (reset! server/message-stream-version :v0.4.0)
    (reset! server/server-max-protocol-version :v0.5.0)
    (let [fake-channel (Object.)]
      (try
        (run-connect fake-channel
                     (server/generate-json {:type "connect"
                                            :api-key test-api-key
                                            :protocol-version "0.4.0"}))
        (is (= :v0.4.0 (server/channel-protocol fake-channel)))
        (finally
          (swap! server/connected-clients dissoc fake-channel)))))

  (testing "client omits protocol_version → channel gets the floor (:v0.4.0)"
    (reset! server/message-stream-version :v0.4.0)
    (reset! server/server-max-protocol-version :v0.5.0)
    (let [fake-channel (Object.)]
      (try
        (run-connect fake-channel
                     (server/generate-json {:type "connect"
                                            :api-key test-api-key}))
        (is (= :v0.4.0 (server/channel-protocol fake-channel)))
        (finally
          (swap! server/connected-clients dissoc fake-channel))))))

(deftest connect-handler-emits-negotiated-protocol-version-on-wire
  (testing "connected reply carries negotiated_protocol_version matching channel state"
    (reset! server/message-stream-version :v0.4.0)
    (reset! server/server-max-protocol-version :v0.5.0)
    (let [fake-channel (Object.)]
      (try
        (let [{:keys [sent]} (run-connect fake-channel
                                          (server/generate-json
                                           {:type "connect"
                                            :api-key test-api-key
                                            :protocol-version "0.5.0"}))
              frame (connected-frame sent)]
          (is (some? frame) "a :connected frame must be emitted")
          (is (= "0.5.0" (:negotiated-protocol-version frame))
              "wire value is the string form, not the keyword")
          (is (= :v0.5.0 (server/channel-protocol fake-channel))
              "wire value matches the per-channel persisted value"))
        (finally
          (swap! server/connected-clients dissoc fake-channel)))))

  (testing "VC_OFFSET_PROTOCOL=0 cap → v0.5.0 client is silently downgraded; reply says 0.4.0"
    (reset! server/message-stream-version :v0.4.0)
    (reset! server/server-max-protocol-version :v0.4.0)
    (let [fake-channel (Object.)]
      (try
        (let [{:keys [sent closed?]}
              (run-connect fake-channel
                           (server/generate-json {:type "connect"
                                                  :api-key test-api-key
                                                  :protocol-version "0.5.0"}))
              frame (connected-frame sent)]
          (is (false? closed?) "the socket must not be closed on silent downgrade")
          (is (= "0.4.0" (:negotiated-protocol-version frame))
              "the downgrade is announced via negotiated_protocol_version, not a reject")
          (is (= :v0.4.0 (server/channel-protocol fake-channel))))
        (finally
          (swap! server/connected-clients dissoc fake-channel))))))

(deftest hello-reply-advertises-server-max-protocol-version
  (testing "hello version comes from the cap, not the floor"
    (reset! server/message-stream-version :v0.4.0)
    (reset! server/server-max-protocol-version :v0.5.0)
    (is (= "0.5.0" (server/message-stream-version-string @server/server-max-protocol-version))
        "sanity: cap atom produces the 0.5.0 string the hello handler emits"))

  (testing "rollback cap (VC_OFFSET_PROTOCOL=0) lowers the advertised version to 0.4.0"
    (reset! server/server-max-protocol-version :v0.4.0)
    (is (= "0.4.0" (server/message-stream-version-string @server/server-max-protocol-version)))))

(deftest two-channels-different-versions-each-get-their-own-negotiation
  ;; Half of AC1: per-channel state is genuinely per-channel, not a shared
  ;; global flip. Open two channels in the same server boot with different
  ;; announced versions and assert both the stored value and the wire reply
  ;; differ per channel.
  (testing "v0.4.0 and v0.5.0 channels coexist with their own negotiated values"
    (reset! server/message-stream-version :v0.4.0)
    (reset! server/server-max-protocol-version :v0.5.0)
    (let [ch-a (Object.)
          ch-b (Object.)]
      (try
        (let [{sent-a :sent}
              (run-connect ch-a (server/generate-json
                                 {:type "connect"
                                  :api-key test-api-key
                                  :protocol-version "0.4.0"}))
              {sent-b :sent}
              (run-connect ch-b (server/generate-json
                                 {:type "connect"
                                  :api-key test-api-key
                                  :protocol-version "0.5.0"}))
              frame-a (connected-frame sent-a)
              frame-b (connected-frame sent-b)]
          (is (= :v0.4.0 (server/channel-protocol ch-a)))
          (is (= :v0.5.0 (server/channel-protocol ch-b)))
          (is (= "0.4.0" (:negotiated-protocol-version frame-a)))
          (is (= "0.5.0" (:negotiated-protocol-version frame-b))))
        (finally
          (swap! server/connected-clients dissoc ch-a)
          (swap! server/connected-clients dissoc ch-b))))))
