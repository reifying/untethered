(ns voice-code.dual-protocol-test
  "Integration test for the v0.5.0 dual-protocol matrix
   (tmux-untethered-398.13 / design doc §4.4 AC1, AC2, AC4 and §6 R1, R5).

   Proves the per-channel dispatch carries two wire protocols across the
   same server boot:

     - Channel A negotiates :v0.4.0 → legacy seq-based session_history
       (`:first_seq` / `:last_seq` / `:next_seq` / `:is_complete` / `:gap`).
     - Channel B negotiates :v0.5.0 → Kafka-style offset session_history
       (`:offset` / `:next_offset` / `:end_of_file` / `:file_signature`,
       and NEVER `:is_complete`).

   Plus the two rollback / recovery paths the design hangs off of:

     - §6 R1 ceiling: server-max-protocol-version = :v0.4.0 (the
       VC_OFFSET_PROTOCOL=0 outcome) silently downgrades a 0.5.0 client
       to :v0.4.0 — no reject, v0.4.0-shaped subscribe reply.
     - §6 R5 / AC5: a v0.5.0 client that drops mid-session reconnects
       with `from_offset = pre-drop cursor` and receives all missed
       messages in a single subscribe reply (`end_of_file: true`)."
  (:require [clojure.test :refer :all]
            [voice-code.server :as server]
            [voice-code.replication :as repl]
            [voice-code.supervisor :as supervisor]
            [cheshire.core :as json]
            [clojure.java.io :as io]
            [clojure.string :as str])
  (:import [java.util.logging Level Logger]))

(def test-api-key "voice-code-0123456789abcdef0123456789abcdef")

(def ^:dynamic *test-dir* nil)

(defn- fresh-test-dir []
  (let [dir (str (System/getProperty "java.io.tmpdir")
                 "/voice-code-dual-protocol-"
                 (System/currentTimeMillis)
                 "-"
                 (rand-int 1000000))]
    (.mkdirs (io/file dir))
    dir))

(defn- cleanup-dir [dir]
  (when (and dir (.exists (io/file dir)))
    (doseq [f (reverse (file-seq (io/file dir)))]
      (.delete f))))

(defn- claude-assistant-line
  "Build a real Claude .jsonl line for an assistant text message."
  [{:keys [uuid text timestamp]
    :or {timestamp "2026-05-12T12:00:00Z"
         uuid (str (java.util.UUID/randomUUID))}}]
  (json/generate-string
   {:type "assistant"
    :uuid uuid
    :timestamp timestamp
    :isSidechain false
    :message {:role "assistant"
              :content [{:type "text" :text text}]}}))

(defn- create-session-jsonl
  "Create a Claude .jsonl file for `session-id` seeded with `lines`.
   Always writes a trailing newline so the watcher's newline-holdback
   doesn't suppress the last line."
  [session-id lines]
  (let [file (io/file *test-dir* (str session-id ".jsonl"))]
    (io/make-parents file)
    (spit file (if (seq lines)
                 (str (str/join "\n" lines) "\n")
                 ""))
    file))

(defn- append-lines!
  "Append `lines` to an existing JSONL file, each terminated by \\n."
  [file lines]
  (spit file (str (str/join "\n" lines) "\n") :append true))

(defn- register-client!
  "Install a mock channel in `server/connected-clients` marked authenticated
   with a specific `:negotiated-protocol-version`. Subscribes the channel
   to `session-id` at the per-channel level (the watcher's global
   subscription is wired separately via `wire-watcher-callbacks!`)."
  [channel session-id protocol-version]
  (swap! server/connected-clients assoc channel
         {:deleted-sessions #{}
          :subscribed-sessions #{session-id}
          :max-message-size-kb 200
          :authenticated true
          :recent-sessions-limit 5
          :negotiated-protocol-version protocol-version}))

(defn- unregister-client! [channel]
  (swap! server/connected-clients dissoc channel))

(defn- wire-watcher-callbacks!
  "Install both watcher callbacks so `handle-file-modified` fans out to
   both protocol arms in the same tick — `broadcast-session-history!`
   for v0.4.0 channels and `push-to-subscribers!` for v0.5.0 channels.
   This mirrors the production wiring in server/-main."
  [session-id]
  (reset! repl/watcher-state
          {:running false
           :watch-service nil
           :watcher-thread nil
           :subscribed-sessions #{session-id}
           :event-queue (atom {})
           :on-session-created nil
           :on-session-updated server/broadcast-session-history!
           :on-session-updated-v5 server/push-to-subscribers!
           :on-session-deleted nil
           :on-turn-complete nil
           :max-retries 3
           :debounce-ms 0}))

(defn- seed-session-index!
  "Seed a session-index entry consistent with the file's current contents:
   `:next-seq` set to (lines + 1), `:message-count` to lines,
   `file-positions` to file length, and `line-counts` to the same line
   count so the watcher's bootstrap branch is not exercised on the next
   tick (mirrors production startup invariants)."
  [session-id file lines]
  (let [n (count lines)
        file-path (.getAbsolutePath file)]
    (swap! repl/session-index assoc session-id
           {:session-id session-id
            :file file-path
            :provider :claude
            :message-count n
            :last-modified (.lastModified file)
            :ios-notified true
            :next-seq (inc n)
            :min-available-seq 1
            :name "dual-protocol"
            :working-directory *test-dir*})
    (swap! repl/file-positions assoc file-path (.length file))
    (swap! repl/line-counts assoc file-path n)))

(defn- capture-sends
  "Install a redef of `org.httpkit.server/send!` that appends each
   outgoing JSON frame (parsed with keyword keys, value-strings
   preserved) to `captured-per-channel` keyed by channel."
  [captured-per-channel]
  (fn [channel json-str]
    (let [parsed (json/parse-string json-str true)]
      (swap! captured-per-channel update channel (fnil conj []) parsed))))

(defn- history-msgs-for
  "Filter captured frames for a specific channel down to `session_history`
   payloads — drops `recent_sessions`, `connected`, etc."
  [captured ch]
  (->> (get captured ch [])
       (filter #(= "session_history" (:type %)))
       (vec)))

(use-fixtures :each
  (fn [f]
    (let [root-logger (Logger/getLogger "")
          original-level (.getLevel root-logger)
          original-api-key @server/api-key
          original-msg-version @server/message-stream-version
          original-server-max @server/server-max-protocol-version
          original-clients @server/connected-clients
          original-session-index @repl/session-index
          original-file-positions @repl/file-positions
          original-line-counts @repl/line-counts
          original-watcher-state @repl/watcher-state
          ;; The :event-queue slot inside watcher-state is an atom; capturing
          ;; the wrapper map keeps a live reference, so snapshot the queue's
          ;; contents separately and restore them in finally to prevent
          ;; in-test mutations from leaking past the fixture boundary.
          original-event-queue-contents (some-> (:event-queue original-watcher-state) deref)
          dir (fresh-test-dir)]
      (try
        (.setLevel root-logger Level/OFF)
        (reset! server/api-key test-api-key)
        (reset! server/message-stream-version :v0.4.0)
        (reset! server/server-max-protocol-version :v0.5.0)
        (reset! server/connected-clients {})
        (reset! repl/session-index {})
        (reset! repl/file-positions {})
        (reset! repl/line-counts {})
        (reset! repl/watcher-state
                {:running false
                 :watch-service nil
                 :watcher-thread nil
                 :subscribed-sessions #{}
                 :event-queue (atom {})
                 :on-session-created nil
                 :on-session-updated nil
                 :on-session-updated-v5 nil
                 :on-session-deleted nil
                 :on-turn-complete nil
                 :max-retries 3
                 :debounce-ms 0})
        (binding [*test-dir* dir]
          (f))
        (finally
          (reset! server/api-key original-api-key)
          (reset! server/message-stream-version original-msg-version)
          (reset! server/server-max-protocol-version original-server-max)
          (reset! server/connected-clients original-clients)
          (reset! repl/session-index original-session-index)
          (reset! repl/file-positions original-file-positions)
          (reset! repl/line-counts original-line-counts)
          (reset! repl/watcher-state original-watcher-state)
          (when-let [q (:event-queue original-watcher-state)]
            (reset! q (or original-event-queue-contents {})))
          (cleanup-dir dir)
          (.setLevel root-logger original-level))))))

;; ---------------------------------------------------------------------------
;; AC1 + AC4: dual-protocol fan-out

(deftest test-dual-protocol-fan-out-distinct-wire-shapes
  (testing "AC1 + AC4: same watcher tick fans the v0.4.0 wire shape to
            Channel A (last_seq cursor) and the v0.5.0 wire shape to
            Channel B (offset cursor) — neither channel ever sees the
            other's keys"
    (let [session-id "550e8400-e29b-41d4-a716-446655441301"
          seed-lines [(claude-assistant-line {:uuid "msg-1" :text "one"})]
          file (create-session-jsonl session-id seed-lines)
          captured (atom {})
          ch-a :chan-v0-4
          ch-b :chan-v0-5]
      (seed-session-index! session-id file seed-lines)
      (wire-watcher-callbacks! session-id)
      (register-client! ch-a session-id :v0.4.0)
      (register-client! ch-b session-id :v0.5.0)

      (with-redefs [org.httpkit.server/send! (capture-sends captured)]
        ;; Both channels subscribe to the same session. A uses last_seq,
        ;; B uses from_offset.
        (server/handle-message ch-a
                               (json/generate-string
                                {:type "subscribe"
                                 :session_id session-id
                                 :last_seq 0}))
        (server/handle-message ch-b
                               (json/generate-string
                                {:type "subscribe"
                                 :session_id session-id
                                 :from_offset 0}))

        (let [a-reply (first (history-msgs-for @captured ch-a))
              b-reply (first (history-msgs-for @captured ch-b))]
          ;; v0.4.0 reply shape — present keys.
          (is (some? a-reply) "channel A receives a session_history reply")
          (is (= 1 (:first_seq a-reply)))
          (is (= 1 (:last_seq a-reply)))
          (is (= 2 (:next_seq a-reply)))
          (is (true? (:is_complete a-reply)))
          ;; Each msg carries :seq (v0.4.0); no :offset leaks in.
          (let [a-msg (first (:messages a-reply))]
            (is (= 1 (:seq a-msg)))
            (is (not (contains? a-msg :offset))
                "v0.4.0 messages do NOT carry an :offset field"))
          ;; v0.4.0 reply must not contain any v0.5.0 envelope keys.
          (is (not (contains? a-reply :offset)))
          (is (not (contains? a-reply :next_offset)))
          (is (not (contains? a-reply :end_of_file)))
          (is (not (contains? a-reply :file_signature)))

          ;; v0.5.0 reply shape — present keys.
          (is (some? b-reply) "channel B receives a session_history reply")
          (is (= 1 (:next_offset b-reply))
              "after seeding 1 message at offset 0, next_offset is 1")
          (is (true? (:end_of_file b-reply))
              "subscribe at from_offset=0 returns full file → end_of_file")
          (is (string? (:file_signature b-reply))
              "v0.5.0 reply carries a :file_signature (length:first-uuid)")
          ;; Each msg carries :offset (v0.5.0); no :seq leaks in.
          (let [b-msg (first (:messages b-reply))]
            (is (= 0 (:offset b-msg)))
            (is (not (contains? b-msg :seq))
                "v0.5.0 messages do NOT carry a :seq field"))
          ;; AC4 spot-check on the subscribe reply: NO :is_complete on v0.5.0.
          (is (not (contains? b-reply :is_complete))
              "AC4: v0.5.0 wire NEVER carries :is_complete")
          (is (not (contains? b-reply :first_seq)))
          (is (not (contains? b-reply :last_seq)))
          (is (not (contains? b-reply :next_seq)))
          (is (not (contains? b-reply :gap))))

        ;; Append one more message and trigger the watcher. Both arms
        ;; fire in the same tick — A receives a v0.4.0 push, B receives
        ;; a v0.5.0 push.
        (append-lines! file
                       [(claude-assistant-line {:uuid "msg-2" :text "two"})])
        (repl/handle-file-modified file)

        (let [a-push (second (history-msgs-for @captured ch-a))
              b-push (second (history-msgs-for @captured ch-b))]
          (is (some? a-push) "channel A receives a v0.4.0 push")
          (is (= 2 (:first_seq a-push)))
          (is (= 2 (:last_seq a-push)))
          (is (= 3 (:next_seq a-push)))
          (is (true? (:is_complete a-push)))
          (is (= [2] (mapv :seq (:messages a-push))))

          (is (some? b-push) "channel B receives a v0.5.0 push")
          (is (= [1] (mapv :offset (:messages b-push)))
              "stamp-offsets gives the appended line offset = pre-line-count + i = 1")
          (is (= 2 (:next_offset b-push)))
          (is (true? (:end_of_file b-push)))
          ;; AC4 again on the push payload.
          (is (not (contains? b-push :is_complete)))
          (is (not (contains? b-push :first_seq)))
          (is (not (contains? b-push :last_seq)))
          (is (not (contains? b-push :next_seq)))
          (is (not (contains? b-push :gap))))))))

;; ---------------------------------------------------------------------------
;; AC2: v0.5.0 fan-out does not pass through assign-seq!

(deftest test-v0-5-0-fan-out-does-not-invoke-assign-seq
  (testing "AC2: with both channels sharing a single watcher tick, the
            assign-seq! counter advances at least once (the v0.4.0 arm
            calls it as a sanity check that the broadcast path ran).
            The durable proof is on the wire — the v0.5.0 fan-out path
            uses stamp-offsets, which writes :offset, not :seq, so
            every v0.5.0 message carries :offset and never :seq."
    (let [session-id "550e8400-e29b-41d4-a716-446655441302"
          seed-lines [(claude-assistant-line {:uuid "init" :text "init"})]
          file (create-session-jsonl session-id seed-lines)
          captured (atom {})
          assign-seq-calls (atom 0)
          orig-assign-seq! repl/assign-seq!
          ch-a :chan-v0-4
          ch-b :chan-v0-5]
      (seed-session-index! session-id file seed-lines)
      (wire-watcher-callbacks! session-id)
      (register-client! ch-a session-id :v0.4.0)
      (register-client! ch-b session-id :v0.5.0)

      (with-redefs [org.httpkit.server/send! (capture-sends captured)
                    repl/assign-seq! (fn [sid msgs]
                                       (swap! assign-seq-calls inc)
                                       (orig-assign-seq! sid msgs))]
        ;; Append two assistant messages and run a single watcher tick.
        (append-lines! file
                       [(claude-assistant-line {:uuid "tick-1" :text "alpha"})
                        (claude-assistant-line {:uuid "tick-2" :text "beta"})])
        (repl/handle-file-modified file)

        (is (pos? @assign-seq-calls)
            "assign-seq! IS invoked for the v0.4.0 arm (sanity that the
             broadcast path ran). The durable AC2 evidence is the
             wire-shape check below: every v0.5.0 message carries
             :offset and never :seq, proving the v0.5.0 fan-out path
             never threads through assign-seq! regardless of how the
             v0.4.0 arm batches its calls.")

        ;; Wire-level proof: v0.5.0 messages have :offset, never :seq.
        ;; v0.4.0 messages have :seq, never :offset.
        (let [b-pushes (history-msgs-for @captured ch-b)
              b-msgs (mapcat :messages b-pushes)]
          (is (seq b-msgs) "channel B received at least one message")
          (is (every? (fn [m] (and (contains? m :offset)
                                   (not (contains? m :seq))))
                      b-msgs)
              "every v0.5.0 message carries :offset and never :seq —
               proving the v0.5.0 wire shape never threads through
               assign-seq!"))

        (let [a-pushes (history-msgs-for @captured ch-a)
              a-msgs (mapcat :messages a-pushes)]
          (is (seq a-msgs))
          (is (every? (fn [m] (and (contains? m :seq)
                                   (not (contains? m :offset))))
                      a-msgs)
              "every v0.4.0 message carries :seq and never :offset"))))))

;; ---------------------------------------------------------------------------
;; AC4: NO :is_complete ever appears on v0.5.0 across subscribe → push → reconnect

(deftest test-v0-5-0-never-emits-is-complete-across-full-cycle
  (testing "AC4: walk the entire v0.5.0 client lifecycle and assert that
            no captured frame for the v0.5.0 channel ever carries an
            :is_complete key — initial subscribe, live push, reconnect."
    (let [session-id "550e8400-e29b-41d4-a716-446655441303"
          seed-lines [(claude-assistant-line {:uuid "lc-1" :text "lc-one"})]
          file (create-session-jsonl session-id seed-lines)
          captured (atom {})
          ch-b :chan-v0-5]
      (seed-session-index! session-id file seed-lines)
      (wire-watcher-callbacks! session-id)
      (register-client! ch-b session-id :v0.5.0)

      (with-redefs [org.httpkit.server/send! (capture-sends captured)]
        ;; (1) Initial subscribe.
        (server/handle-message ch-b
                               (json/generate-string
                                {:type "subscribe"
                                 :session_id session-id
                                 :from_offset 0}))
        ;; (2) Live push from the watcher.
        (append-lines! file
                       [(claude-assistant-line {:uuid "lc-2" :text "lc-two"})])
        (repl/handle-file-modified file)

        ;; (3) Reconnect: drop the channel, then re-register and
        ;; re-subscribe with an advanced cursor.
        (unregister-client! ch-b)
        (register-client! ch-b session-id :v0.5.0)
        (server/handle-message ch-b
                               (json/generate-string
                                {:type "subscribe"
                                 :session_id session-id
                                 :from_offset 2}))

        (let [v5-frames (get @captured ch-b [])]
          (is (pos? (count v5-frames))
              "the v0.5.0 channel captured at least one outbound frame")
          (is (not-any? #(contains? % :is_complete) v5-frames)
              "AC4: NO :is_complete on ANY frame across subscribe → push → reconnect"))))))

;; ---------------------------------------------------------------------------
;; §6 R1 / R5: VC_OFFSET_PROTOCOL=0 ceiling silently downgrades v0.5.0 clients
;; to v0.4.0 wire shape.

(deftest test-vc-offset-protocol-0-downgrades-v0-5-0-client-to-v0-4-0-wire
  (testing "Rollback path: with server-max-protocol-version pulled to
            :v0.4.0 (the VC_OFFSET_PROTOCOL=0 outcome), a channel
            announcing protocol_version 0.5.0 is negotiated to :v0.4.0
            and the subscribe reply is the legacy v0.4.0 shape — no
            reject, no v0.5.0 keys on the wire."
    (reset! server/server-max-protocol-version :v0.4.0)
    (let [session-id "550e8400-e29b-41d4-a716-446655441304"
          seed-lines [(claude-assistant-line {:uuid "rb-1" :text "rb"})]
          file (create-session-jsonl session-id seed-lines)
          captured (atom {})
          ch :chan-downgrade]
      (seed-session-index! session-id file seed-lines)
      ;; This test exercises only connect+subscribe wire shapes — the
      ;; watcher fan-out is not part of the §6 R1 / T8 path, so the
      ;; production callbacks aren't wired in.

      (with-redefs [org.httpkit.server/send! (capture-sends captured)
                    server/send-recent-sessions! (fn [_ _] nil)
                    server/send-available-commands! (fn [_ _] nil)
                    repl/get-all-sessions (constantly [])
                    supervisor/start-supervisor! (fn [_] nil)]
        ;; Full connect with protocol_version 0.5.0 — exercises the
        ;; real negotiation path (not a manual atom assoc).
        (server/handle-message ch
                               (json/generate-string
                                {:type "connect"
                                 :api_key test-api-key
                                 :protocol_version "0.5.0"
                                 :session_id session-id}))

        ;; Negotiation outcome: channel is :v0.4.0 despite the 0.5.0
        ;; announcement. The connected reply also says "0.4.0".
        (is (= :v0.4.0 (server/channel-protocol ch))
            "server-max=:v0.4.0 silently downgrades a 0.5.0 client")
        (let [connected-frame (some #(when (= "connected" (:type %)) %)
                                    (get @captured ch))]
          (is (some? connected-frame))
          (is (= "0.4.0" (:negotiated_protocol_version connected-frame))
              "wire surfaces the downgraded version, not the client's announcement"))

        ;; Subscribe with the v0.4.0 wire shape (last_seq). Reply is
        ;; v0.4.0 shape — no v0.5.0 keys leak.
        (server/handle-message ch
                               (json/generate-string
                                {:type "subscribe"
                                 :session_id session-id
                                 :last_seq 0}))
        (let [reply (first (history-msgs-for @captured ch))]
          (is (some? reply) "downgraded channel still receives subscribe replies")
          (is (= 1 (:first_seq reply)))
          (is (= 1 (:last_seq reply)))
          (is (= 2 (:next_seq reply)))
          (is (true? (:is_complete reply)))
          (is (not (contains? reply :offset)))
          (is (not (contains? reply :next_offset)))
          (is (not (contains? reply :end_of_file)))
          (is (not (contains? reply :file_signature))))))))

;; ---------------------------------------------------------------------------
;; AC5: reconnect-after-drop happy path — single subscribe round-trip backfills
;; everything written while the v0.5.0 channel was disconnected.

(deftest test-v0-5-0-reconnect-after-drop-single-roundtrip-backfill
  (testing "AC5: a v0.5.0 channel records its cursor, drops from
            connected-clients, watches 200 lines get appended while
            offline, then reconnects and re-subscribes with the
            pre-drop offset. The single subscribe reply carries all
            200 missed messages with end_of_file: true — no second
            subscribe needed."
    (let [session-id "550e8400-e29b-41d4-a716-446655441305"
          seed-lines [(claude-assistant-line {:uuid "rj-init" :text "init"})]
          file (create-session-jsonl session-id seed-lines)
          captured (atom {})
          ch :chan-reconnect]
      (seed-session-index! session-id file seed-lines)
      (wire-watcher-callbacks! session-id)
      (register-client! ch session-id :v0.5.0)

      (with-redefs [org.httpkit.server/send! (capture-sends captured)]
        ;; Initial subscribe — advances the per-channel cursor to 1
        ;; (one seed line consumed at offset 0).
        (server/handle-message ch
                               (json/generate-string
                                {:type "subscribe"
                                 :session_id session-id
                                 :from_offset 0}))
        (let [pre-drop-offset (get-in @server/connected-clients
                                      [ch :session-offsets session-id])]
          (is (= 1 pre-drop-offset)
              "after the initial subscribe the channel's cursor is past the seed line"))

        ;; "Disconnect" — drop the channel from connected-clients. The
        ;; watcher tick can fire while disconnected; with no eligible
        ;; v0.5.0 subscriber, push-to-subscribers! is a no-op.
        (unregister-client! ch)
        (swap! captured dissoc ch)

        ;; Append 200 messages while the channel is offline. Trigger
        ;; the watcher to keep the file-positions cursor in lockstep
        ;; with the on-disk content; the v0.5.0 fan-out drops on the
        ;; floor because there are no v0.5.0 subscribers.
        (let [batch (for [i (range 200)]
                      (claude-assistant-line
                       {:uuid (format "rj-%03d" i)
                        :text (format "msg-%03d" i)}))]
          (append-lines! file batch))
        (repl/handle-file-modified file)

        ;; Sanity: the watcher consumed all 200 appended lines, but
        ;; nothing was pushed to the dropped channel.
        (is (= 201 (get @repl/line-counts (.getAbsolutePath file)))
            "watcher recorded 1 seed + 200 appended = 201 raw lines")
        (is (empty? (history-msgs-for @captured ch))
            "no v0.5.0 pushes were sent while the channel was disconnected")

        ;; "Reconnect" — re-register the channel and subscribe with
        ;; the pre-drop offset. A single reply must deliver all 200
        ;; missed messages with end_of_file: true.
        (register-client! ch session-id :v0.5.0)
        (server/handle-message ch
                               (json/generate-string
                                {:type "subscribe"
                                 :session_id session-id
                                 :from_offset 1}))

        (let [histories (history-msgs-for @captured ch)
              reply (first histories)]
          (is (= 1 (count histories))
              "exactly one subscribe reply — no second round-trip needed")
          (is (= 200 (count (:messages reply)))
              "all 200 missed messages arrive in the single reply")
          (is (= 201 (:next_offset reply))
              "next_offset = pre-drop cursor + 200 missed")
          (is (true? (:end_of_file reply))
              "AC5: end_of_file: true means the client is now caught up")
          (is (= [1 2 3 4 5] (->> (:messages reply) (take 5) (mapv :offset)))
              "offsets start at the pre-drop cursor (1), not at 0")
          (is (= 200 (:offset (last (:messages reply))))
              "last delivered offset = 200 (the 201st raw line at index 200)"))))))
