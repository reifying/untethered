(ns voice-code.append-only-loopback-test
  "Backend WebSocket loopback integration tests for the append-only message
   stream (protocol v0.4.0).

   Exercises the full server-side contract without requiring iOS:

     subscribe ── handle-message ───────────────────────▶ session_history
     JSONL write ─ handle-file-modified ─ assign-seq! ─▶ broadcast-session-history!
                                                         (flat session_history push)

   Mock subscribers are plain Clojure objects registered in
   `server/connected-clients`; outbound frames are captured by redefining
   `org.httpkit.server/send!`. This pins the AC3/AC4 server-side contract
   from @docs/design/append-only-message-stream.md without requiring iOS."
  (:require [clojure.test :refer :all]
            [voice-code.server :as server]
            [voice-code.replication :as repl]
            [cheshire.core :as json]
            [clojure.java.io :as io]
            [clojure.string :as str])
  (:import [java.util.logging Level Logger]))

(def test-api-key "voice-code-0123456789abcdef0123456789abcdef")

(def ^:dynamic *test-dir* nil)

(defn- fresh-test-dir []
  (let [dir (str (System/getProperty "java.io.tmpdir")
                 "/voice-code-loopback-"
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
    :or {timestamp "2026-04-21T12:00:00Z"
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
   Always writes a trailing newline so parse-jsonl-incremental's
   newline-holdback doesn't suppress the last line."
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
  "Install a mock channel in `server/connected-clients` marked authenticated.
   Every client also subscribes to `session-id` in both the per-channel
   set AND the global replication subscription so the watcher considers
   it eligible."
  [channel session-id]
  (swap! server/connected-clients assoc channel
         {:deleted-sessions #{}
          :subscribed-sessions #{session-id}
          :max-message-size-kb 200
          :authenticated true
          :recent-sessions-limit 5}))

(defn- unregister-client! [channel]
  (swap! server/connected-clients dissoc channel))

(defn- wire-broadcast-callback!
  "Install broadcast-session-history! as the watcher's on-session-updated
   callback. Preserves subscribed-sessions so the watcher sees the session
   as globally subscribed."
  [session-id]
  (reset! repl/watcher-state
          {:running false
           :watch-service nil
           :watcher-thread nil
           :subscribed-sessions #{session-id}
           :event-queue (atom {})
           :on-session-created nil
           :on-session-updated server/broadcast-session-history!
           :on-session-deleted nil
           :on-turn-complete nil
           :max-retries 3
           :debounce-ms 200}))

(defn- seed-session-index!
  "Seed a session-index entry consistent with the file's current contents:
   :next-seq is set to (lines + 1), :message-count to lines, and
   file-positions is advanced to file length so subsequent
   handle-file-modified calls see only future appends.

   This mirrors the state the watcher would have produced had it already
   processed `lines` messages before the test began — without which
   assign-seq! would restart at 1 and drift away from the subscribe
   shim's in-file order."
  [session-id file lines]
  (let [n (count lines)]
    (swap! repl/session-index assoc session-id
           {:session-id session-id
            :file (.getAbsolutePath file)
            :provider :claude
            :message-count n
            :last-modified (.lastModified file)
            :ios-notified true ;; skip delayed-notification branch
            :next-seq (inc n)
            :min-available-seq 1
            :name "loopback"
            :working-directory *test-dir*})
    (swap! repl/file-positions assoc (.getAbsolutePath file) (.length file))))

(defn- capture-sends
  "Install a redef of org.httpkit.server/send! that appends each outgoing
   JSON frame (parsed) to `captured-per-channel` keyed by channel.
   Returns a thunk that unwraps."
  [captured-per-channel]
  (fn [channel json-str]
    (let [parsed (json/parse-string json-str true)]
      (swap! captured-per-channel update channel (fnil conj []) parsed))))

(defn- history-msgs-for
  "Filter captured frames for a specific channel down to session_history
   payloads with a messages array — drops recent_sessions, connected, etc."
  [captured ch]
  (->> (get captured ch [])
       (filter #(= "session_history" (:type %)))
       (vec)))

(defn- all-seqs-for
  "Aggregate the :seq values from every session_history frame received by `ch`."
  [captured ch]
  (->> (history-msgs-for captured ch)
       (mapcat :messages)
       (map :seq)
       (vec)))

(defn- contiguous-from-1?
  "True when `seqs` strictly increases by 1 from 1 to (count seqs) — i.e.
   dedup is unnecessary and no gap is present."
  [seqs]
  (= seqs (vec (range 1 (inc (count seqs))))))

(defn- dedup-seqs
  "Materialize a client's view by upserting on :seq — the idempotency
   contract client side. Returns the sorted unique seq vector."
  [seqs]
  (->> seqs distinct sort vec))

(use-fixtures :each
  (fn [f]
    (let [root-logger (Logger/getLogger "")
          original-level (.getLevel root-logger)
          dir (fresh-test-dir)]
      (try
        (.setLevel root-logger Level/OFF)
        (reset! server/api-key test-api-key)
        (reset! server/message-stream-version :v0.4.0)
        (reset! server/connected-clients {})
        (reset! repl/session-index {})
        (reset! repl/file-positions {})
        (reset! repl/watcher-state
                {:running false
                 :watch-service nil
                 :watcher-thread nil
                 :subscribed-sessions #{}
                 :event-queue (atom {})
                 :on-session-created nil
                 :on-session-updated nil
                 :on-session-deleted nil
                 :on-turn-complete nil
                 :max-retries 3
                 :debounce-ms 200})
        (binding [*test-dir* dir]
          (f))
        (finally
          (reset! server/api-key nil)
          (reset! server/connected-clients {})
          (reset! repl/session-index {})
          (reset! repl/file-positions {})
          (cleanup-dir dir)
          (.setLevel root-logger original-level))))))

(deftest test-subscribe-push-disconnect-reconnect-caught-up
  (testing "AC4: subscribe → JSONL append → push → disconnect → reconnect
           with advanced last_seq → caught-up empty reply"
    (let [session-id "550e8400-e29b-41d4-a716-446655440701"
          seed-lines [(claude-assistant-line {:uuid "msg-1" :text "one"})]
          file (create-session-jsonl session-id seed-lines)
          captured (atom {})
          ch-a :chan-a]
      (seed-session-index! session-id file seed-lines)
      (wire-broadcast-callback! session-id)
      (register-client! ch-a session-id)

      (with-redefs [org.httpkit.server/send! (capture-sends captured)]
        ;; Initial subscribe from last_seq=0 must deliver the single seeded message.
        (server/handle-message ch-a
                               (json/generate-string
                                {:type "subscribe"
                                 :session_id session-id
                                 :last_seq 0}))

        (let [histories (history-msgs-for @captured ch-a)
              h1 (first histories)]
          (is (= 1 (count histories))
              "subscribe emits exactly one session_history reply")
          (is (= session-id (:session_id h1)))
          (is (= 1 (count (:messages h1))))
          (is (= 1 (:first_seq h1)))
          (is (= 1 (:last_seq h1)))
          (is (= 2 (:next_seq h1)))
          (is (true? (:is_complete h1)))
          (is (nil? (:gap h1))))

        ;; Append a second assistant message and trigger the watcher. The
        ;; broadcast path is wired to send a one-window session_history push.
        (append-lines! file
                       [(claude-assistant-line {:uuid "msg-2" :text "two"})])
        (repl/handle-file-modified file)

        (let [histories (history-msgs-for @captured ch-a)
              push (second histories)]
          (is (= 2 (count histories)) "broadcast added a second session_history frame")
          (is (= 1 (count (:messages push))))
          (is (= 2 (:seq (first (:messages push)))))
          (is (= 2 (:first_seq push)))
          (is (= 2 (:last_seq push)))
          (is (= 3 (:next_seq push)))
          (is (true? (:is_complete push)))
          (is (nil? (:gap push))))

        ;; "Disconnect" — drop the channel and clear captured frames so the
        ;; reconnect reply is easy to isolate.
        (unregister-client! ch-a)
        (swap! captured dissoc ch-a)

        ;; "Reconnect" with advanced last_seq cursor. The server is caught up
        ;; and must return an empty packed range with is_complete=true and
        ;; no gap — this is what exercises the AC4 "no duplicate bubbles,
        ;; no missing messages" path.
        (register-client! ch-a session-id)
        (server/handle-message ch-a
                               (json/generate-string
                                {:type "subscribe"
                                 :session_id session-id
                                 :last_seq 2}))

        (let [reply (first (history-msgs-for @captured ch-a))]
          (is (some? reply) "reconnect subscribe produces a session_history reply")
          (is (= [] (:messages reply)) "caught-up reply carries no messages")
          (is (nil? (:first_seq reply)))
          (is (nil? (:last_seq reply)))
          (is (= 3 (:next_seq reply)) ":next_seq points past the last broadcast")
          (is (true? (:is_complete reply)))
          (is (nil? (:gap reply))))))))

(deftest test-two-subscribers-flat-broadcast-and-backfill
  (testing "AC3: two subscribers at different last_seq receive the same push;
           the lagging one re-subscribes with a stale cursor to backfill"
    (let [session-id "550e8400-e29b-41d4-a716-446655440702"
          seed-lines [(claude-assistant-line {:uuid "m1" :text "one"})
                      (claude-assistant-line {:uuid "m2" :text "two"})
                      (claude-assistant-line {:uuid "m3" :text "three"})]
          file (create-session-jsonl session-id seed-lines)
          captured (atom {})
          ch-a :chan-caught-up
          ch-b :chan-lagging]
      (seed-session-index! session-id file seed-lines)
      (wire-broadcast-callback! session-id)
      (register-client! ch-a session-id)
      (register-client! ch-b session-id)

      (with-redefs [org.httpkit.server/send! (capture-sends captured)]
        ;; A subscribes at last_seq=0, B subscribes at last_seq=2 — they land
        ;; with different local cursors but both view the full session.
        (server/handle-message ch-a
                               (json/generate-string
                                {:type "subscribe"
                                 :session_id session-id
                                 :last_seq 0}))
        (server/handle-message ch-b
                               (json/generate-string
                                {:type "subscribe"
                                 :session_id session-id
                                 :last_seq 2}))

        (let [a-reply (first (history-msgs-for @captured ch-a))
              b-reply (first (history-msgs-for @captured ch-b))]
          (is (= [1 2 3] (mapv :seq (:messages a-reply)))
              "A from last_seq=0 receives the full [1 2 3] range")
          (is (= [3] (mapv :seq (:messages b-reply)))
              "B from last_seq=2 receives only [3]")
          (is (= 4 (:next_seq a-reply)))
          (is (= 4 (:next_seq b-reply))))

        ;; File write adds a fourth message. The flat broadcast must deliver
        ;; an identical session_history window to every subscriber — the
        ;; server does not tailor per-subscriber.
        (append-lines! file
                       [(claude-assistant-line {:uuid "m4" :text "four"})])
        (repl/handle-file-modified file)

        (let [a-pushes (rest (history-msgs-for @captured ch-a))
              b-pushes (rest (history-msgs-for @captured ch-b))
              a-push (first a-pushes)
              b-push (first b-pushes)]
          (is (= 1 (count a-pushes)) "A receives exactly one push")
          (is (= 1 (count b-pushes)) "B receives exactly one push")
          (is (= (dissoc a-push :messages) (dissoc b-push :messages))
              "both subscribers receive the same envelope (flat broadcast)")
          (is (= [4] (mapv :seq (:messages a-push))))
          (is (= [4] (mapv :seq (:messages b-push))))
          (is (= 4 (:first_seq a-push)))
          (is (= 4 (:last_seq a-push)))
          (is (= 5 (:next_seq a-push)))
          (is (true? (:is_complete a-push)))
          (is (nil? (:gap a-push))))

        ;; Simulate B being behind at last_seq=2 (e.g. it dropped the push
        ;; across a brief socket flap). Re-subscribing with the stale cursor
        ;; must deliver the whole [3 4] backfill in one reply.
        (swap! captured dissoc ch-b)
        (server/handle-message ch-b
                               (json/generate-string
                                {:type "subscribe"
                                 :session_id session-id
                                 :last_seq 2}))

        (let [backfill (first (history-msgs-for @captured ch-b))]
          (is (= [3 4] (mapv :seq (:messages backfill)))
              "backfill delivers exactly the seqs the lagging client missed")
          (is (= 3 (:first_seq backfill)))
          (is (= 4 (:last_seq backfill)))
          (is (= 5 (:next_seq backfill)))
          (is (true? (:is_complete backfill)))
          (is (nil? (:gap backfill))))))))

(deftest test-concurrent-subscribe-and-file-write-leaves-no-gap
  (testing "AC3: subscribe and file-write racing in either order leave the
           subscriber with a contiguous [1..N] view after dedup on :seq.

           The wire may carry the same seq twice (push crossing the
           subscribe reply, or backfill overlapping a prior push), but
           dedup on (session_id, seq) always materializes the contiguous
           range."

    (testing "order A: subscribe first, then file-write triggers broadcast"
      (let [session-id "550e8400-e29b-41d4-a716-446655440711"
            seed-lines [(claude-assistant-line {:uuid "a1" :text "one"})
                        (claude-assistant-line {:uuid "a2" :text "two"})]
            file (create-session-jsonl session-id seed-lines)
            captured (atom {})
            ch :chan-order-a]
        (seed-session-index! session-id file seed-lines)
        (wire-broadcast-callback! session-id)
        (register-client! ch session-id)

        (with-redefs [org.httpkit.server/send! (capture-sends captured)]
          (server/handle-message ch
                                 (json/generate-string
                                  {:type "subscribe"
                                   :session_id session-id
                                   :last_seq 0}))
          (append-lines! file
                         [(claude-assistant-line {:uuid "a3" :text "three"})
                          (claude-assistant-line {:uuid "a4" :text "four"})
                          (claude-assistant-line {:uuid "a5" :text "five"})])
          (repl/handle-file-modified file)

          (let [seqs (all-seqs-for @captured ch)
                deduped (dedup-seqs seqs)]
            (is (= [1 2 3 4 5] seqs)
                "subscribe delivers [1 2] then broadcast delivers [3 4 5] — no overlap, no gap")
            (is (= [1 2 3 4 5] deduped))
            (is (contiguous-from-1? deduped)
                "materialized view is the contiguous seq range [1..5]")))))

    (testing "order B: file-write broadcasts first, then late subscribe — overlap dedups cleanly"
      (let [session-id "550e8400-e29b-41d4-a716-446655440712"
            seed-lines [(claude-assistant-line {:uuid "b1" :text "one"})
                        (claude-assistant-line {:uuid "b2" :text "two"})]
            file (create-session-jsonl session-id seed-lines)
            captured (atom {})
            ch :chan-order-b
            ch-bystander :chan-bystander]
        (seed-session-index! session-id file seed-lines)
        (wire-broadcast-callback! session-id)
        ;; A bystander subscribes first so the watcher's broadcast has an
        ;; eligible audience. The late subscriber is `ch` itself.
        (register-client! ch-bystander session-id)
        (register-client! ch session-id)

        (with-redefs [org.httpkit.server/send! (capture-sends captured)]
          (append-lines! file
                         [(claude-assistant-line {:uuid "b3" :text "three"})
                          (claude-assistant-line {:uuid "b4" :text "four"})])
          (repl/handle-file-modified file)

          ;; `ch` has already received the push for seqs [3 4] via flat
          ;; broadcast (every connected client is eligible). It now
          ;; subscribes for the first time — the subscribe reply must
          ;; carry the full [1..4] range even though [3 4] were already
          ;; pushed. The client-side dedup on :seq collapses the overlap.
          (server/handle-message ch
                                 (json/generate-string
                                  {:type "subscribe"
                                   :session_id session-id
                                   :last_seq 0}))

          (let [seqs (all-seqs-for @captured ch)
                deduped (dedup-seqs seqs)]
            (is (some #(= 3 %) seqs) "push carried seq 3")
            (is (some #(= 4 %) seqs) "push carried seq 4")
            ;; Overlap is expected: push delivers [3 4], then subscribe
            ;; re-parses the file and returns [1 2 3 4].
            (is (> (count seqs) (count deduped))
                "wire has at least one duplicate seq (push + subscribe overlap)")
            (is (= [1 2 3 4] deduped)
                "after dedup on :seq, the materialized view is [1..4] contiguous")
            (is (contiguous-from-1? deduped))))))))
