(ns voice-code.server
  "Main entry point and WebSocket server for voice-code backend."
  (:require [org.httpkit.server :as http]
            [clojure.core.async :as async]
            [cheshire.core :as json]
            [clojure.tools.logging :as log]
            [clojure.edn :as edn]
            [clojure.java.io :as io]
            [clojure.java.shell :as shell]
            [clojure.string :as str]
            [voice-code.auth :as auth]
            [voice-code.claude :as claude]
            [voice-code.replication :as repl]
            [voice-code.worktree :as worktree]
            [voice-code.commands :as commands]
            [voice-code.commands-history :as cmd-history]
            [voice-code.resources :as resources]
            [voice-code.recipes :as recipes]
            [voice-code.orchestration :as orch]
            [voice-code.supervisor :as supervisor]
            [voice-code.env :as env]
            [voice-code.providers :as providers]
            [voice-code.tmux :as tmux])
  (:import [java.util.concurrent Executors TimeUnit])
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

(defn convert-keywords
  "Recursively convert keyword values to snake_case strings"
  [data]
  (cond
    (keyword? data) (kebab->snake data)
    (map? data) (into {} (map (fn [[k v]] [k (convert-keywords v)]) data))
    (coll? data) (map convert-keywords data)
    :else data))

(defn parse-json
  "Parse JSON string, converting snake_case keys to kebab-case keywords"
  [s]
  (json/parse-string s snake->kebab))

(defn generate-json
  "Generate JSON string, converting kebab-case keywords to snake_case keys and values"
  [data]
  (json/generate-string (convert-keywords data) {:key-fn kebab->snake}))

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
                  " :logging {:level :info}\n\n"
                  " ;; WebSocket protocol version served to clients and used to gate\n"
                  " ;; append-only-stream behavior (seq migration, hello version enforcement).\n"
                  " ;; Flip to :v0.3.0 to roll back to the last_message_id / session_updated paths.\n"
                  " :message-stream-version :v0.4.0}\n"))))))

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
       :logging {:level :info}
       :message-stream-version :v0.4.0})))

;; Supported values for :message-stream-version. See
;; @docs/design/append-only-message-stream.md §Risks-Mitigations for the
;; rollback semantics. :v0.4.0 enables the append-only monotonic-seq path
;; (post-migration, strict hello enforcement). :v0.3.0 preserves the legacy
;; last_message_id / session_updated paths for rollback without a redeploy.
;; :v0.5.0 introduces the Kafka-style offset protocol layered on the same
;; seq-stamping infrastructure (see voice-code-sync-kafka-redesign-2026-05-10.md §3.2).
(def supported-message-stream-versions #{:v0.3.0 :v0.4.0 :v0.5.0})

(def default-message-stream-version :v0.4.0)

;; Cap on the per-channel protocol negotiation ladder (§3.2). The
;; `:message-stream-version` atom is the floor (lowest accepted protocol;
;; also the default for clients that omit `protocol_version`); this atom is
;; the ceiling. `min(client-version, server-max-protocol-version)` chooses
;; the per-channel value. `VC_OFFSET_PROTOCOL=0` (handled in T8) lowers this
;; cap to :v0.4.0 for an emergency global downgrade without rejecting v0.5.0
;; clients — they are silently negotiated down instead.
(def default-server-max-protocol-version :v0.5.0)

(defn coerce-message-stream-version
  "Coerce a config value to a supported :message-stream-version keyword.
   Accepts the keyword directly or a string like \"v0.4.0\". Returns
   default-message-stream-version on nil / unknown input (with a warn log)."
  [v]
  (let [k (cond
            (keyword? v) v
            (string? v) (keyword (if (str/starts-with? v ":") (subs v 1) v))
            :else nil)]
    (if (contains? supported-message-stream-versions k)
      k
      (do
        (when (some? v)
          (log/warn "Ignoring unknown :message-stream-version; falling back to default"
                    {:received v :default default-message-stream-version}))
        default-message-stream-version))))

;; Backend-wide runtime flag. Populated from config.edn at -main startup and
;; by tests via reset!. Dereferenced by the hello handler (protocol version
;; string emitted), the future hello-rejection path (T09), and the future
;; one-shot seq migration (T04).
(defonce message-stream-version (atom default-message-stream-version))

;; Server-side cap on negotiated protocol version. Set by tests via reset!
;; and by T8 (`VC_OFFSET_PROTOCOL=0` rollback) to :v0.4.0 to silently
;; downgrade v0.5.0 clients. Read by `negotiate-channel-protocol-version`
;; and the hello handler (the advertised "preferred" version).
(defonce server-max-protocol-version (atom default-server-max-protocol-version))

(def ^:dynamic *read-env-var*
  "Reads an environment variable by name. Extracted so tests can rebind it
   without calling System/getenv directly (static Java, not with-redefsable)."
  (fn [name] (System/getenv name)))

(defn compute-startup-server-max
  "Resolve the startup ceiling for the per-channel negotiation ladder. When
   `VC_OFFSET_PROTOCOL` is exactly the string \"0\", return :v0.4.0 — the
   emergency rollback cap that silently downgrades v0.5.0 clients (§6 R5 of
   voice-code-sync-kafka-redesign-2026-05-10). Any other value (including
   unset, empty, \"1\", or arbitrary strings) leaves the cap at
   default-server-max-protocol-version. Reads the env var via *read-env-var*
   so tests can rebind without touching the JVM environment."
  []
  (if (= "0" (*read-env-var* "VC_OFFSET_PROTOCOL"))
    :v0.4.0
    default-server-max-protocol-version))

(defn apply-startup-server-max!
  "Reset! server-max-protocol-version from VC_OFFSET_PROTOCOL and log a
   warn-level banner when the rollback ceiling is active so operators can
   confirm via routine log review that the downgrade took effect. Called
   exactly once from -main; not re-read per connection."
  []
  (let [ceiling (compute-startup-server-max)]
    (reset! server-max-protocol-version ceiling)
    (when (= :v0.4.0 ceiling)
      (log/warn "VC_OFFSET_PROTOCOL=0 set; negotiation ceiling pulled to :v0.4.0"))
    ceiling))

(defn message-stream-version-string
  "Human-facing protocol version (e.g. \"0.4.0\") for the given keyword
   (e.g. :v0.4.0). Used in the hello handler and in rejection error payloads."
  [v]
  (str/replace (name v) #"^v" ""))

(defn seq-migration-enabled?
  "True when the backend should run the one-shot JSONL→seq migration and
   stamp seq on new messages. Gated on :message-stream-version (the floor).
   Fires for any non-rollback floor (v0.4.0+) because v0.5.0 reuses the
   same seq-stamping infrastructure as offsets (offset = seq - 1)."
  ([] (seq-migration-enabled? @message-stream-version))
  ([v] (contains? #{:v0.4.0 :v0.5.0} v)))

(defn hello-enforcement-enabled?
  "True when the hello handshake should reject clients announcing a protocol
   version older than :v0.4.0. Gated on :message-stream-version (the floor).
   The 0.4.0 cutoff is unchanged at v0.5.0 — the cap (server-max-protocol-version)
   governs the upper bound via negotiate-channel-protocol-version, not this
   guard."
  ([] (hello-enforcement-enabled? @message-stream-version))
  ([v] (contains? #{:v0.4.0 :v0.5.0} v)))

(defn parse-protocol-version
  "Parse a semver-like wire string (e.g. \"0.3.0\") into [major minor patch]
   so two announcements can be compared with `compare`. Pre-release / build
   suffixes (\"-rc1\", \"+build\") are stripped before parsing. Returns nil
   for anything that doesn't resolve to exactly three numeric parts."
  [s]
  (when (string? s)
    (let [stripped (str/replace s #"[-+].*$" "")
          parts (str/split stripped #"\.")]
      (when (= 3 (count parts))
        (try
          (mapv #(Integer/parseInt %) parts)
          (catch NumberFormatException _ nil))))))

(defn client-protocol-too-old?
  "True only when the client explicitly announced a protocol version below
   0.4.0 in its hello/connect handshake. A missing or unparseable
   :protocol-version is treated as 'unknown, not too old' so existing
   v0.4.0 clients (which do not announce a version) still pass through."
  [data]
  (when-let [parsed (parse-protocol-version (:protocol-version data))]
    (neg? (compare parsed [0 4 0]))))

(def ^:private protocol-version-keyword-by-vec
  "Lookup from a parse-protocol-version vector to the supported
   :message-stream-version keyword. Used by
   negotiate-channel-protocol-version to round-trip a wire string into
   the canonical keyword (or nil for unrecognized triples)."
  {[0 3 0] :v0.3.0
   [0 4 0] :v0.4.0
   [0 5 0] :v0.5.0})

(defn negotiate-channel-protocol-version
  "Compute the per-channel negotiated protocol version. Implements the
   §3.2 ladder of voice-code-sync-kafka-redesign-2026-05-10:
     1. Client omits or announces an unparseable version → floor.
     2. Client announces a parseable version → min(client, server-max),
        capped at server-max for any client value strictly above it (so a
        future-version client like \"0.6.0\" announced against today's
        :v0.5.0 cap negotiates down to :v0.5.0 instead of being rejected).
        If min(client, server-max) doesn't map to a supported keyword
        (e.g. a client announcing \"0.2.0\" that slips past lax-mode
        enforcement) the result falls back to floor as a safety net.
   The below-floor reject for clients announcing < 0.4.0 in enforce mode
   is handled upstream by enforce-protocol-version! and does not reach
   this function."
  ([client-version-string]
   (negotiate-channel-protocol-version client-version-string
                                       @message-stream-version
                                       @server-max-protocol-version))
  ([client-version-string floor server-max]
   (let [parsed (parse-protocol-version client-version-string)]
     (if (nil? parsed)
       floor
       (let [server-max-vec (parse-protocol-version
                             (message-stream-version-string server-max))
             effective-vec (if (neg? (compare parsed server-max-vec))
                             parsed
                             server-max-vec)]
         (or (protocol-version-keyword-by-vec effective-vec) floor))))))

;; Ephemeral mapping: WebSocket channel -> client state
;; This is just for routing messages during an active connection
;; Persistent session data comes from the replication system (filesystem-based)

(defonce connected-clients
  ;; Track all connected WebSocket clients:
  ;; channel -> {:deleted-sessions #{}
  ;;             :subscribed-sessions #{}  ; Sessions this client is subscribed to
  ;;             :recent-sessions-limit 5
  ;;             :max-message-size-kb 200
  ;;             :negotiated-protocol-version :v0.4.0 | :v0.5.0 | :v0.3.0}
  (atom {}))

(defn channel-protocol
  "Negotiated protocol version for the given channel, or nil if the channel
   has not completed the connect handshake. Set by the connect handler
   immediately after enforce-protocol-version! returns true. This is the
   per-connection replacement for the global (seq-migration-enabled?) gate;
   every per-channel code path that used to dispatch on the atom dispatches
   on this value instead.

   Call-site convention: nil falls through to the v0.4.0+ branch. Both the
   subscribe handler and broadcast-session-history! test specifically for
   `= :v0.3.0`, so a channel that bypassed the connect handshake (e.g.
   fabricated in a unit / loopback test) takes the seq-stamped path. The
   legacy v0.3.0 rollback path requires :negotiated-protocol-version :v0.3.0
   to be explicitly set on the channel."
  [channel]
  (get-in @connected-clients [channel :negotiated-protocol-version]))

;; Default max message size in KB (conservative default well below iOS 256KB limit)
;; Lower default ensures older clients without set_max_message_size still work
(def default-max-message-size-kb 100)

;; Per-message max size in bytes for delta sync truncation
;; Messages larger than this are truncated individually, smaller messages are preserved intact
(def per-message-max-bytes (* 20 1024)) ;; 20KB per message max

(defn- take-prefix-bytes
  "Return the longest prefix of text whose UTF-8 byte length is <= max-bytes.
   Stops on character boundaries to avoid splitting multi-byte sequences."
  [text max-bytes]
  (if (<= max-bytes 0)
    ""
    (loop [chars (seq text)
           result []
           bytes 0]
      (if (empty? chars)
        (apply str result)
        (let [ch (first chars)
              ch-bytes (count (.getBytes (str ch) "UTF-8"))
              new-bytes (+ bytes ch-bytes)]
          (if (> new-bytes max-bytes)
            (apply str result)
            (recur (rest chars) (conj result ch) new-bytes)))))))

(defn- take-suffix-bytes
  "Return the longest suffix of text whose UTF-8 byte length is <= max-bytes."
  [text max-bytes]
  (if (<= max-bytes 0)
    ""
    (loop [chars (reverse (seq text))
           result []
           bytes 0]
      (if (empty? chars)
        (apply str (reverse result))
        (let [ch (first chars)
              ch-bytes (count (.getBytes (str ch) "UTF-8"))
              new-bytes (+ bytes ch-bytes)]
          (if (> new-bytes max-bytes)
            (apply str (reverse result))
            (recur (rest chars) (conj result ch) new-bytes)))))))

(defn truncate-text-middle
  "Truncate text to fit within max-bytes by keeping first and last portions.
   Inserts a marker showing how much was truncated.
   Returns the original text if it fits within the limit.

   The assembled string is verified against max-bytes after construction.
   If it overshoots (e.g. the marker is close to or larger than max-bytes),
   half-bytes is reduced by the overage and the parts are rebuilt. As a
   final safety net the result is byte-truncated to max-bytes."
  [text max-bytes]
  (let [text-bytes (.getBytes text "UTF-8")
        text-size (count text-bytes)]
    (if (<= text-size max-bytes)
      text
      (let [marker-template "\n\n... [truncated ~%d KB] ...\n\n"
            truncated-kb (int (/ (- text-size max-bytes) 1024))
            marker (format marker-template truncated-kb)
            marker-bytes (count (.getBytes marker "UTF-8"))
            available-bytes (- max-bytes marker-bytes)
            half-bytes (int (/ available-bytes 2))
            first-part (take-prefix-bytes text half-bytes)
            last-part (take-suffix-bytes text half-bytes)
            assembled (str first-part marker last-part)
            assembled-bytes (count (.getBytes assembled "UTF-8"))]
        (cond
          (<= assembled-bytes max-bytes)
          assembled

          (>= marker-bytes max-bytes)
          (take-prefix-bytes assembled max-bytes)

          :else
          (let [overage (- assembled-bytes max-bytes)
                shrink (int (Math/ceil (/ overage 2.0)))
                new-half (max 0 (- half-bytes shrink))
                first-part' (take-prefix-bytes text new-half)
                last-part' (take-suffix-bytes text new-half)
                retry (str first-part' marker last-part')
                retry-bytes (count (.getBytes retry "UTF-8"))]
            (if (<= retry-bytes max-bytes)
              retry
              (take-prefix-bytes retry max-bytes))))))))

(defn get-client-max-message-size-bytes
  "Get the max message size in bytes for a client channel."
  [channel]
  (let [client-info (get @connected-clients channel)
        size-kb (or (:max-message-size-kb client-info) default-max-message-size-kb)]
    (* size-kb 1024)))

(defn truncate-content-block
  "Truncate a single content block (text, tool_result, etc.) if it exceeds max bytes."
  [block max-text-bytes]
  (cond
    ;; Text block: {:type "text", :text "..."}
    (and (map? block)
         (= "text" (:type block))
         (string? (:text block)))
    (let [text (:text block)
          text-bytes (count (.getBytes text "UTF-8"))]
      (if (<= text-bytes max-text-bytes)
        block
        (assoc block :text (truncate-text-middle text max-text-bytes))))

    ;; Tool result with string content: {:type "tool_result", :content "..."}
    (and (map? block)
         (= "tool_result" (:type block))
         (string? (:content block)))
    (let [content (:content block)
          content-bytes (count (.getBytes content "UTF-8"))]
      (if (<= content-bytes max-text-bytes)
        block
        (assoc block :content (truncate-text-middle content max-text-bytes))))

    ;; Tool result with array content: {:type "tool_result", :content [{:type "text", :text "..."}]}
    (and (map? block)
         (= "tool_result" (:type block))
         (sequential? (:content block)))
    (update block :content #(mapv (fn [inner] (truncate-content-block inner max-text-bytes)) %))

    :else block))

(defn truncate-message-text
  "Truncate text content within a single message object (from :messages array).
   Handles both simple {:text ...} and complex nested structures with :message {:content [...]}."
  [msg max-text-bytes]
  (let [;; First truncate :toolUseResult if present (top-level field in JSONL)
        msg (if (and (contains? msg :toolUseResult)
                     (sequential? (:toolUseResult msg)))
              (update msg :toolUseResult #(mapv (fn [block] (truncate-content-block block max-text-bytes)) %))
              msg)]
    (cond
      ;; Simple text field
      (and (contains? msg :text) (string? (:text msg)))
      (let [text (:text msg)
            text-bytes (count (.getBytes text "UTF-8"))]
        (if (<= text-bytes max-text-bytes)
          msg
          (assoc msg :text (truncate-text-middle text max-text-bytes))))

      ;; Content array directly on message (Claude message format)
      (and (contains? msg :content) (sequential? (:content msg)))
      (update msg :content #(mapv (fn [block] (truncate-content-block block max-text-bytes)) %))

      ;; Nested :message with :content (JSONL format from Claude sessions)
      (and (contains? msg :message)
           (map? (:message msg))
           (contains? (:message msg) :content)
           (sequential? (get-in msg [:message :content])))
      (update-in msg [:message :content] #(mapv (fn [block] (truncate-content-block block max-text-bytes)) %))

      :else msg)))

(defn truncate-messages-array
  "Truncate text within messages array to fit within size budget.
   Uses iterative approach, halving per-message budget until under limit."
  [messages max-total-bytes]
  (let [json-str (generate-json messages)
        current-bytes (count (.getBytes json-str "UTF-8"))]
    (if (<= current-bytes max-total-bytes)
      messages
      ;; Need to truncate - iterate with decreasing budget until we fit
      (let [msg-count (max 1 (count messages))]
        (loop [max-text-per-msg (int (/ max-total-bytes msg-count 2)) ;; Start with half of equal split
               iteration 0]
          (if (< iteration 10) ;; Max 10 iterations to prevent infinite loop
            (let [truncated (mapv #(truncate-message-text % max-text-per-msg) messages)
                  truncated-json (generate-json truncated)
                  truncated-bytes (count (.getBytes truncated-json "UTF-8"))]
              (if (<= truncated-bytes max-total-bytes)
                (do
                  (log/info "Truncated messages array"
                            {:message-count msg-count
                             :original-bytes current-bytes
                             :final-bytes truncated-bytes
                             :max-bytes max-total-bytes
                             :max-text-per-msg max-text-per-msg
                             :iterations (inc iteration)})
                  truncated)
                ;; Still too big, halve the budget and try again
                (recur (max 500 (int (/ max-text-per-msg 2))) (inc iteration))))
            ;; Hit max iterations, return what we have
            (do
              (log/warn "Max truncation iterations reached"
                        {:message-count msg-count
                         :original-bytes current-bytes
                         :max-bytes max-total-bytes})
              (mapv #(truncate-message-text % 500) messages))))))))

(defn pack-within-budget
  "Walk candidates oldest-first, including each if the running JSON byte
   estimate stays under max-bytes. Returns {:included vec :complete? bool}.

   - envelope-overhead: bytes reserved for the response envelope around the
     :messages array (e.g. :type, :session-id, :first-seq, :last-seq,
     :next-seq, :is-complete, :gap). Callers should measure their actual
     envelope and pass the result; the 2-arg form falls back to a 300-byte
     conservative default that covers the v0.4.0 session_history envelope
     including a populated gap object.
   - per-message-extra: bytes the caller will :assoc onto each message
     after packing (e.g. ~52 bytes for the :session-id field added by the
     subscribe handler and broadcast path before serialization). Reserved
     per included message so the wire response stays under max-bytes
     after the caller's post-processing.

   Each candidate contributes its JSON byte count plus 1 (comma) plus
   per-message-extra. Stops at the first candidate that would push total
   past max-bytes, returning :complete? false. Exhausting the input
   returns :complete? true.

   Pure helper: no I/O, no state, no truncation. Individual over-budget
   messages are handled by the caller (e.g. via truncate-message-text)."
  ([candidates max-bytes]
   (pack-within-budget candidates max-bytes 300 0))
  ([candidates max-bytes envelope-overhead per-message-extra]
   (loop [remaining candidates
          included []
          used envelope-overhead]
     (if (empty? remaining)
       {:included included :complete? true}
       (let [m (first remaining)
             m-json (generate-json m)
             m-sz (+ (count (.getBytes ^String m-json "UTF-8"))
                     1
                     per-message-extra)]
         (if (> (+ used m-sz) max-bytes)
           {:included included :complete? false}
           (recur (rest remaining) (conj included m) (+ used m-sz))))))))

(defn build-session-history-response
  "Unified session-history reply for subscribe and live push (protocol v0.4.0).

   Returns exactly one of four shapes, keyed on the relationship between the
   client's `last-seq` and the server's `min-available-seq` / `next-seq`:

     - Pruned:       client is below `min-available-seq - 1`. Reply carries a
                     `:gap {:reason \"pruned\"}` and no messages.
     - Client-ahead: client is above `next-seq - 1`, i.e. claims a seq the
                     server never assigned. Happens after a backend rollback
                     that discarded messages the client already saw. Reply
                     carries a `:gap {:reason \"client_ahead\"}` and a full
                     resync of `messages` from `min-available-seq` onward so
                     the client can drop local state and reload.
     - Caught up:    client is at exactly `next-seq - 1`. Empty `:messages`,
                     no gap.
     - Packed:       otherwise, filter messages by `:seq > last-seq` and pack
                     them with `pack-within-budget`. `:is-complete` is false
                     when the byte budget truncates the range.

   Parameters:
   - messages:          vector of canonical messages, each carrying `:seq`
   - last-seq:          highest seq the client already has (0 = fresh)
   - max-total-bytes:   response size budget for the packed branch
   - min-available-seq: lowest seq the server still retains
   - next-seq:          seq the server will assign to the next new message

   Returns {:messages :first-seq :last-seq :next-seq :is-complete :gap}."
  [messages last-seq max-total-bytes min-available-seq next-seq]
  (let [pack-and-build
        (fn [filter-fn gap]
          ;; Measure the actual session_history envelope bytes (with the gap
          ;; object baked in) so the wire response stays under
          ;; max-total-bytes after the caller :assoc's :session-id onto each
          ;; message. Used by both the packed and client-ahead branches.
          (let [candidates (filter filter-fn messages)
                envelope-overhead
                (count (.getBytes ^String
                        (generate-json
                         {:type :session-history
                          :session-id "00000000-0000-0000-0000-000000000000"
                          :messages []
                          :first-seq next-seq
                          :last-seq next-seq
                          :next-seq next-seq
                          :is-complete true
                          :gap gap})
                                  "UTF-8"))
                per-message-extra 52
                {:keys [included complete?]}
                (pack-within-budget candidates max-total-bytes
                                    envelope-overhead per-message-extra)]
            (if (empty? included)
              ;; Defensive guard: no candidate fit the byte budget. For the
              ;; packed branch this would otherwise leave the client unable
              ;; to advance its cursor, so we report caught-up. For the
              ;; client-ahead branch we preserve the gap so the client still
              ;; receives the drop-state signal even if the resync itself is
              ;; empty (e.g. server has zero messages).
              (do
                (when (and (nil? gap) (seq candidates))
                  (log/warn "build-session-history-response: no candidate fit byte budget; returning caught-up to break resubscribe loop"
                            {:last-seq last-seq
                             :max-total-bytes max-total-bytes
                             :next-seq next-seq
                             :candidate-count (count candidates)
                             :first-candidate-seq (:seq (first candidates))}))
                {:messages []
                 :first-seq nil
                 :last-seq nil
                 :next-seq next-seq
                 :is-complete true
                 :gap gap})
              {:messages (vec included)
               :first-seq (:seq (first included))
               :last-seq (:seq (last included))
               :next-seq next-seq
               :is-complete complete?
               :gap gap})))]
    (cond
      ;; Pruned: client's cursor is below the server's retained range.
      (< last-seq (dec min-available-seq))
      {:messages []
       :first-seq nil
       :last-seq nil
       :next-seq next-seq
       :is-complete true
       :gap {:requested-last-seq last-seq
             :min-available-seq min-available-seq
             :reason "pruned"}}

      ;; Client ahead: client claims a seq the server never assigned (e.g.
      ;; after a backend rollback that discarded messages). Return a full
      ;; resync from min-available-seq so the client can drop local state
      ;; and reload to the server's truth.
      (> last-seq (dec next-seq))
      (pack-and-build (fn [m] (>= (:seq m) min-available-seq))
                      {:requested-last-seq last-seq
                       :min-available-seq min-available-seq
                       :reason "client_ahead"})

      ;; Caught up: client is at exactly next-seq - 1.
      (= last-seq (dec next-seq))
      {:messages []
       :first-seq nil
       :last-seq nil
       :next-seq next-seq
       :is-complete true
       :gap nil}

      ;; Packed range.
      :else
      (pack-and-build (fn [m] (> (:seq m) last-seq)) nil))))

(defn truncate-response-text
  "Truncate the :text field of a response message if the total JSON would exceed max size.
   Also handles :messages arrays (for session-updated messages).
   Returns the modified message data with truncated content if needed."
  [message-data max-bytes]
  (let [;; First, generate JSON to see actual size
        json-str (generate-json message-data)
        json-bytes (count (.getBytes json-str "UTF-8"))]
    (if (<= json-bytes max-bytes)
      message-data
      ;; Need to truncate - determine which field to truncate
      (cond
        ;; Direct :text field (response messages)
        (and (contains? message-data :text) (string? (:text message-data)))
        (let [text (:text message-data)
              overhead (- json-bytes (count (.getBytes text "UTF-8")))
              max-text-bytes (- max-bytes overhead 100)
              truncated-text (truncate-text-middle text max-text-bytes)
              original-kb (int (/ (count (.getBytes text "UTF-8")) 1024))
              session-id (or (:session-id message-data) "unknown")]
          (log/info "Truncating large response text"
                    {:session-id session-id
                     :original-size-kb original-kb
                     :max-size-kb (int (/ max-bytes 1024))})
          (assoc message-data :text truncated-text))

        ;; :messages array (session-updated messages)
        (and (contains? message-data :messages) (sequential? (:messages message-data)))
        (let [messages (:messages message-data)
              overhead (- json-bytes (count (.getBytes (generate-json messages) "UTF-8")))
              max-messages-bytes (- max-bytes overhead 100)
              session-id (or (:session-id message-data) "unknown")]
          (log/info "Truncating large messages array"
                    {:session-id session-id
                     :message-count (count messages)
                     :original-size-kb (int (/ json-bytes 1024))
                     :max-size-kb (int (/ max-bytes 1024))})
          (assoc message-data :messages (truncate-messages-array messages max-messages-bytes)))

        ;; No known truncatable field
        :else message-data))))

(defonce pending-new-sessions
  ;; Track new sessions awaiting creation: session-id -> channel
  ;; Used to send session_ready to the correct client when file is detected
  (atom {}))

(defonce session-orchestration-state
  ;; Track orchestration state per Claude session: session-id -> {:recipe-id :step :step-count :step-visit-counts ...}
  ;; Maps Claude session IDs to their active orchestration recipe state.
  ;; Safe for concurrent WebSocket connections: each connection operates on independent session state.
  ;; State is isolated per Claude session (not per iOS session), preventing conflicts.
  ;; Cleanup via exit-recipe-for-session when recipe completes or user cancels.
  (atom {}))

;; Stored API key loaded at startup. Used for authenticating all connections.
(defonce api-key (atom nil))

(defn channel-authenticated?
  "Check if a WebSocket channel has been authenticated."
  [channel]
  (get-in @connected-clients [channel :authenticated] false))

(defn send-auth-error!
  "Send auth_error message and close the connection.
   Uses generic error message to prevent information leakage."
  [channel log-reason]
  (log/warn "Authentication failed" {:reason log-reason})
  (http/send! channel
              (generate-json {:type :auth-error
                              :message "Authentication failed"}))
  (http/close channel))

(defn reject-unsupported-protocol-version!
  "Send the canonical unsupported_protocol_version error payload exactly as
   required by the v0.4.0 hello contract and close the socket. The payload
   shape is asserted by tests, so do not reshape it without also updating
   the iOS client and the protocol docs."
  [channel received-version]
  (log/warn "Rejecting client for unsupported protocol version"
            {:received received-version :required "0.4.0"})
  (http/send! channel
              (generate-json
               {:type "error"
                :code "unsupported_protocol_version"
                :required "0.4.0"
                :received received-version
                :message "Client is too old; upgrade required"}))
  (http/close channel))

(defn enforce-protocol-version!
  "Hello-handshake guard: reject clients announcing a protocol version older
   than 0.4.0 when enforcement is on (:message-stream-version = :v0.4.0).
   Returns true when the client may proceed to authentication. Returns false
   and has already sent the error + closed the socket when rejection fires.
   A :v0.3.0 message-stream-version disables the guard so rollback keeps
   legacy clients working."
  [channel data]
  (if (and (hello-enforcement-enabled?)
           (client-protocol-too-old? data))
    (do (reject-unsupported-protocol-version! channel (:protocol-version data))
        false)
    true))

(defn authenticate-connect!
  "Validate API key on connect message and mark channel as authenticated.
   Returns true if authenticated, false otherwise (and sends error + closes channel)."
  [channel data]
  (let [provided-key (:api-key data)
        stored-key @api-key]
    (cond
      (nil? provided-key)
      (do
        (send-auth-error! channel "Missing API key in connect message")
        false)

      (not (auth/constant-time-equals? stored-key provided-key))
      (do
        (send-auth-error! channel "Invalid API key")
        false)

      :else
      (do
        ;; Mark channel as authenticated
        (swap! connected-clients assoc-in [channel :authenticated] true)
        (log/info "Client authenticated successfully")
        true))))

(defn extract-bearer-token
  "Extract Bearer token from Authorization header.
   Returns nil if header is missing or malformed."
  [req]
  (when-let [auth-header (get-in req [:headers "authorization"])]
    (when (str/starts-with? auth-header "Bearer ")
      (subs auth-header 7))))

(defn unregister-channel!
  "Remove WebSocket channel from connected clients and clean up subscriptions.
   Any sessions that are no longer subscribed by any client are unsubscribed globally."
  [channel]
  (let [client-info (get @connected-clients channel)
        client-subscriptions (or (:subscribed-sessions client-info) #{})]
    ;; Remove the channel first
    (swap! connected-clients dissoc channel)
    ;; For each session this client was subscribed to, check if any other client still needs it
    (when (seq client-subscriptions)
      (let [remaining-clients @connected-clients
            ;; Compute all sessions still needed by remaining clients
            all-remaining-subscriptions (reduce
                                         (fn [acc [_ info]]
                                           (into acc (or (:subscribed-sessions info) #{})))
                                         #{}
                                         remaining-clients)
            ;; Sessions to unsubscribe globally
            orphaned-sessions (clojure.set/difference client-subscriptions all-remaining-subscriptions)]
        (when (seq orphaned-sessions)
          (log/info "Cleaning up orphaned subscriptions on disconnect"
                    {:orphaned-count (count orphaned-sessions)
                     :session-ids orphaned-sessions})
          (doseq [session-id orphaned-sessions]
            (repl/unsubscribe-from-session! session-id)))))))

(defn generate-message-id
  "Generate a UUID v4 for message tracking"
  []
  (str (java.util.UUID/randomUUID)))

(defn broadcast-to-all-clients!
  "Broadcast a message to all connected clients.

   On send failure (e.g. dead socket), remove the offending channel from
   `connected-clients` and unsubscribe it from all sessions via
   `unregister-channel!`. Without this cleanup the channel would persist
   as a zombie subscriber, slowing every subsequent broadcast and leaking
   memory (see beads tmux-untethered-rxr)."
  [message-data]
  (doseq [[channel _client-info] @connected-clients]
    (try
      (http/send! channel (generate-json message-data))
      (catch Exception e
        (log/warn e "Failed to broadcast to client; removing dead channel")
        (try
          (unregister-channel! channel)
          (catch Exception cleanup-e
            (log/warn cleanup-e "Failed to clean up dead channel after broadcast failure")))))))

(defn send-to-client!
  "Send message to a specific channel if it's connected.
   Applies truncation for messages with :text or :messages fields if needed.

   On send failure (e.g. dead socket), remove the channel from
   `connected-clients` and unsubscribe it from all sessions via
   `unregister-channel!`. Without this cleanup the channel would persist
   as a zombie subscriber, slowing every subsequent broadcast and leaking
   memory (see beads tmux-untethered-rxr)."
  [channel message-data]
  (if (contains? @connected-clients channel)
    (let [;; Apply truncation for messages that might have large content
          max-bytes (get-client-max-message-size-bytes channel)
          final-data (truncate-response-text message-data max-bytes)
          json-str (generate-json final-data)
          ;; One terse outbound line, with the fields that matter per type.
          ;; A failure path adds a separate `warn` below; absence of the warn
          ;; is the implicit "send succeeded."
          ;; Silence high-frequency types so they don't dominate logs:
          ;; :pong fires every keepalive, :command-output streams per-line.
          msg-type (:type message-data)
          silenced? (contains? #{:pong :command-output} msg-type)
          summary (cond-> {:bytes (count json-str)}
                    (:session-id message-data)  (assoc :sess (subs (str (:session-id message-data)) 0 (min 8 (count (str (:session-id message-data))))))
                    (:first-seq message-data)   (assoc :first (:first-seq message-data))
                    (:last-seq message-data)    (assoc :last (:last-seq message-data))
                    (:next-seq message-data)    (assoc :next (:next-seq message-data))
                    (:is-complete message-data) (assoc :complete? (:is-complete message-data))
                    (:gap message-data)         (assoc :gap (get-in message-data [:gap :reason]))
                    (:messages message-data)    (assoc :msgs (count (:messages message-data)))
                    (:exit-code message-data)   (assoc :exit (:exit-code message-data))
                    (:code message-data)        (assoc :code (:code message-data)))]
      (when-not silenced?
        (log/info (str "→ " msg-type) summary))
      (try
        (http/send! channel json-str)
        (catch Exception e
          (log/warn e "Failed to send to client; removing dead channel"
                    {:type msg-type :bytes (count json-str)})
          (try
            (unregister-channel! channel)
            (catch Exception cleanup-e
              (log/warn cleanup-e "Failed to clean up dead channel after send failure"))))))
    (log/warn "Channel not in connected-clients, skipping send" {:type (:type message-data)})))

(defn send-recent-sessions!
  "Send the recent sessions list to a connected client.
  Uses the new recent_sessions message type (distinct from session-list).
  Converts :last-modified from milliseconds to ISO-8601 string for JSON.
  Sends session-id, name, working-directory, last-modified, provider."
  [channel limit]
  (let [sessions (repl/get-recent-sessions limit)
        ;; Convert to format with ISO-8601 timestamp
        ;; Include name field (generated from Claude summary or fallback to dir-timestamp)
        ;; Include provider field for multi-provider support
        sessions-minimal (mapv
                          (fn [session]
                            {:session-id (:session-id session)
                             :name (:name session)
                             :working-directory (:working-directory session)
                             :last-modified (.format (java.time.format.DateTimeFormatter/ISO_INSTANT)
                                                     (java.time.Instant/ofEpochMilli (:last-modified session)))
                             :provider (or (:provider session) :claude)})
                          sessions)]
    (log/info "Sending recent sessions" {:count (count sessions-minimal) :limit limit})
    (send-to-client! channel
                     {:type :recent-sessions
                      :sessions sessions-minimal
                      :limit limit})))

(def ^:private general-commands
  [{:id "git.status"
    :label "Git Status"
    :description "Show git working tree status"
    :type :command}
   {:id "git.push"
    :label "Git Push"
    :description "Push commits to remote repository"
    :type :command}
   {:id "git.worktree.list"
    :label "Git Worktree List"
    :description "List all git worktrees"
    :type :command}
   {:id "bd.ready"
    :label "Beads Ready"
    :description "Show tasks ready to work on"
    :type :command}
   {:id "bd.list"
    :label "Beads List"
    :description "List all beads tasks"
    :type :command}])

(defn send-available-commands!
  "Send available_commands to a client. Project commands are parsed from the
   given working directory's Makefile when provided; otherwise the payload
   carries only the always-available general commands."
  [channel working-dir]
  (let [project-commands (if (str/blank? working-dir)
                           []
                           (commands/parse-makefile working-dir))]
    (send-to-client! channel
                     {:type :available-commands
                      :working-directory working-dir
                      :project-commands project-commands
                      :general-commands general-commands})))

(defn is-session-deleted-for-client?
  "Check if a client has deleted a session locally"
  [channel session-id]
  (let [client-info (get @connected-clients channel)]
    (contains? (:deleted-sessions client-info) session-id)))

(defn mark-session-deleted-for-client!
  "Mark a session as deleted for a specific client"
  [channel session-id]
  (swap! connected-clients update-in [channel :deleted-sessions] (fnil conj #{}) session-id)
  (log/debug "Marked session as deleted for client" {:session-id session-id}))

;; Orchestration helper functions

(defn get-session-recipe-state
  "Get the current orchestration state for a session, or nil if not in recipe"
  [session-id]
  (get @session-orchestration-state session-id))

(defn session-exists?
  "Check if a Claude session file exists for the given session ID.
   Returns true if session metadata exists (implying .jsonl file exists)."
  [session-id]
  (some? (repl/get-session-metadata session-id)))

(defn start-recipe-for-session
  "Initialize orchestration state for a session.
   is-new-session? indicates whether this is a brand new session with no Claude history.
   Provider defaults to :claude for backward compatibility."
  [session-id recipe-id is-new-session? & {:keys [provider]}]
  (if-let [state (orch/create-orchestration-state recipe-id)]
    (let [state-with-session-flag (assoc state
                                         :session-created? (not is-new-session?)
                                         :provider (or provider :claude))]
      (swap! session-orchestration-state assoc session-id state-with-session-flag)
      (orch/log-orchestration-event "recipe-started" session-id recipe-id
                                    (:current-step state)
                                    {:is-new-session is-new-session? :provider (or provider :claude)})
      state-with-session-flag)
    (do
      (log/error "Recipe not found" {:recipe-id recipe-id :session-id session-id})
      nil)))

(declare recipe-turn-callbacks)

(defn exit-recipe-for-session
  "Exit orchestration for a session"
  [session-id reason]
  (when-let [state (get-session-recipe-state session-id)]
    (orch/log-orchestration-event "recipe-exited" session-id (:recipe-id state) (:current-step state) {:reason reason})
    (swap! session-orchestration-state dissoc session-id))
  ;; Drop any orphaned turn-complete callback so the atom doesn't leak entries
  ;; when a recipe exits mid-flight (e.g., tmux window killed externally,
  ;; restart-new-session handoff).
  (swap! recipe-turn-callbacks dissoc session-id))

(defn get-next-step-prompt
  "Get the prompt for the next step in an active recipe"
  [session-id orch-state recipe]
  (let [current-step (:current-step orch-state)
        step (orch/get-current-step recipe current-step)]
    (if step
      (let [expected-outcomes (:outcomes step)
            base-prompt (:prompt step)]
        (orch/append-outcome-requirements base-prompt current-step expected-outcomes))
      nil)))

(defn get-step-model
  "Get model for a step. Resolution order: step :model > recipe :model > nil"
  [recipe step-name]
  (or (get-in recipe [:steps step-name :model])
      (:model recipe)))

(defn get-available-recipes-list
  "Get list of available recipes with metadata for client.
   Dynamically reads from recipes/all-recipes."
  []
  (->> recipes/all-recipes
       vals
       (map (fn [recipe]
              {:id (name (:id recipe))
               :label (:label recipe)
               :description (:description recipe)}))
       (sort-by :label)
       vec))

(defn process-orchestration-response
  "Process Claude response when in an orchestration recipe.
   Parses JSON outcome, validates against expected outcomes, and determines next action.
   Handles guardrails (max-step-visits, max-total-steps) and sends client state updates.
   
   Returns one of:
   - {:action :next-step :step-name keyword} - transition to next step
   - {:action :exit :reason string} - exit recipe
   - {:action :retry :prompt string} - retry with reminder prompt (first failure only)"
  [session-id orch-state recipe response-text channel]
  (let [current-step (:current-step orch-state)
        step (orch/get-current-step recipe current-step)
        expected-outcomes (:outcomes step)
        outcome-result (orch/extract-orchestration-outcome response-text expected-outcomes)]
    (if (:success outcome-result)
      ;; Success - clear any retry count for this step and process outcome
      (let [outcome (:outcome outcome-result)
            next-action (orch/determine-next-action step outcome)]
        ;; Clear retry count on success
        (swap! session-orchestration-state update-in [session-id :step-retry-counts] dissoc current-step)
        (orch/log-orchestration-event "outcome-received" session-id (:recipe-id orch-state) current-step outcome)
        (case (:action next-action)
          :next-step
          (let [new-step (:step-name next-action)
                ;; Check guardrails BEFORE transitioning
                exit-reason (orch/should-exit-recipe? orch-state recipe new-step)]
            (if exit-reason
              (do
                (orch/log-orchestration-event "recipe-exited" session-id (:recipe-id orch-state) current-step
                                              {:reason exit-reason})
                (exit-recipe-for-session session-id exit-reason)
                (send-to-client! channel
                                 {:type :recipe-exited
                                  :session-id session-id
                                  :reason exit-reason})
                {:action :exit :reason exit-reason})
              ;; Update state with new step and increment counters
              ;; IMPORTANT: Use swap! with update function to preserve fields set by other code
              ;; (like :session-created? set by execute-recipe-step)
              (do
                (swap! session-orchestration-state update session-id
                       (fn [current-state]
                         (-> current-state
                             (assoc :current-step new-step)
                             (update :step-count inc)
                             (update-in [:step-visit-counts new-step] (fnil inc 0)))))
                (send-to-client! channel
                                 {:type :recipe-step-transition
                                  :session-id session-id
                                  :from-step current-step
                                  :to-step new-step})
                {:action :next-step :step-name new-step})))

          :exit
          (do
            (exit-recipe-for-session session-id (:reason next-action))
            (send-to-client! channel
                             {:type :recipe-exited
                              :session-id session-id
                              :reason (:reason next-action)})
            next-action)

          :restart-new-session
          ;; Pass through to execute-recipe-step which handles the restart
          next-action))
      ;; Failed to parse outcome - check if we should retry or exit
      (let [retry-count (get-in orch-state [:step-retry-counts current-step] 0)
            error-msg (:error outcome-result)]
        (if (zero? retry-count)
          ;; First failure - retry with reminder prompt
          (do
            (orch/log-orchestration-event "outcome-parse-retry" session-id (:recipe-id orch-state) current-step
                                          {:error error-msg :retry-attempt 1})
            ;; Increment retry count in state
            (swap! session-orchestration-state update-in [session-id :step-retry-counts current-step] (fnil inc 0))
            (send-to-client! channel
                             {:type :orchestration-retry
                              :session-id session-id
                              :step current-step
                              :error error-msg})
            {:action :retry
             :prompt (orch/get-outcome-reminder-prompt current-step expected-outcomes error-msg)})
          ;; Already retried - exit recipe
          (do
            (orch/log-orchestration-event "outcome-parse-error" session-id (:recipe-id orch-state) current-step
                                          {:error error-msg :retry-attempts (inc retry-count)})
            (exit-recipe-for-session session-id "orchestration-error")
            (send-to-client! channel
                             {:type :recipe-exited
                              :session-id session-id
                              :reason "orchestration-error"
                              :error (str "Agent failed to produce valid JSON outcome after retry. " error-msg)})
            {:action :exit :reason "orchestration-error"}))))))

(defonce ^:private recipe-turn-callbacks
  ;; session-id -> callback fn (one-arg, receives response map).
  ;; Registered by dispatch-recipe-step-via-tmux! before nudging the tmux pane;
  ;; drained by on-turn-complete when the filesystem watcher observes the
  ;; provider's terminal marker.
  (atom {}))

(defn- last-assistant-message
  "Read the session's JSONL via the provider's canonical parser and return the
   last assistant message map (with :uuid and :text). Returns nil if the
   session has no assistant messages or metadata cannot be located."
  [session-id]
  (try
    (when-let [metadata (repl/get-session-metadata session-id)]
      (let [provider (:provider metadata)
            file-path (:file metadata)]
        (when (and provider file-path)
          (let [messages (repl/parse-session-messages provider file-path)
                assistant (filter #(= "assistant" (:role %)) messages)]
            (last assistant)))))
    (catch Exception e
      (log/warn e "Failed to read last assistant message"
                {:session-id session-id})
      nil)))

(defn- read-fresh-assistant-text
  "Return the text of the session's last assistant message only if it is
   strictly newer than since-uuid (the watermark captured at step dispatch).
   Returns nil when there is no newer assistant message, so a spurious
   turn-complete fire (e.g. triggered by a non-assistant JSONL write between
   dispatch and the provider's actual response) does not hand stale text to
   the orchestrator. since-uuid may be nil for the first step of a session."
  [session-id since-uuid]
  (when-let [msg (last-assistant-message session-id)]
    (when (or (nil? since-uuid) (not= since-uuid (:uuid msg)))
      (:text msg))))

(defn dispatch-recipe-step-via-tmux!
  "Dispatch a recipe step prompt through tmux and register a turn-complete
   callback. For the first step of a session (session-created? false), starts
   a new tmux window. For subsequent steps, nudges the live window via
   tmux/deliver!, which transparently respawns with --resume if the window
   was evicted. On the deliver! path the provider is inferred from live-windows
   state, so the :provider argument is only consulted when starting a window.

   The tmux call is serialized against compact_session via
   repl/compaction-dispatch-lock (see tmux-untethered-22g / tmux-untethered-3eh).
   If a compaction is in progress for this session when the lock is acquired,
   the callback fires with {:success false :error ...} and tmux is not invoked;
   the orchestrator's callback exits the recipe with an error whose text tells
   the user to retry once compaction completes.

   The callback is stored keyed on session-id and fired by on-turn-complete
   with {:success true :result <assistant-text> :session-id <id>}. On
   synchronous dispatch failure the callback fires immediately with
   {:success false :error ...} and the registration is cleared."
  [{:keys [provider session-id session-created? prompt-text working-dir]}
   callback-fn]
  ;; Capture the "last assistant message" watermark before dispatch so
  ;; on-turn-complete can distinguish a fresh response from a spurious fire
  ;; caused by non-assistant JSONL writes (interrupt markers, permission-mode
  ;; entries, etc.). See tmux-untethered-uqj.
  (let [since-uuid (:uuid (last-assistant-message session-id))]
    (swap! recipe-turn-callbacks assoc session-id
           {:callback callback-fn :since-uuid since-uuid}))
  (try
    (locking repl/compaction-dispatch-lock
      (if (repl/is-compaction-locked? session-id)
        (do
          (log/info "Recipe step dispatch aborted: compaction in progress"
                    {:session-id session-id :provider provider})
          (swap! recipe-turn-callbacks dissoc session-id)
          (callback-fn {:success false
                        :error "Compaction in progress for this session; retry once it completes"}))
        (if session-created?
          (tmux/deliver! session-id prompt-text)
          (tmux/start-window! {:session-uuid session-id
                               :session-name (:name (repl/get-session-metadata session-id))
                               :provider provider
                               :workdir working-dir
                               :initial-prompt prompt-text
                               :resume? false}))))
    nil
    (catch Throwable e
      (log/error e "Failed to dispatch recipe step via tmux"
                 {:session-id session-id :provider provider})
      (swap! recipe-turn-callbacks dissoc session-id)
      (callback-fn {:success false
                    :error (str "tmux dispatch failed: " (.getMessage e))}))))

(declare execute-recipe-step)

(defn execute-recipe-step
  "Execute a single step of a recipe and handle the response.
   This function handles the full orchestration loop:
   1. Send the step prompt to the provider (Claude, Copilot, etc.)
   2. Parse the outcome from the response
   3. If next step: update state and recursively continue
   4. If retry: send reminder prompt and try again (once per step)
   5. If exit: send recipe_exited message

   Provider is read from orchestration state (:provider field), enabling multi-provider support.

   Parameters:
   - channel: WebSocket channel to send messages to
   - session-id: Claude session ID
   - working-dir: Working directory for the provider
   - orch-state: Current orchestration state (includes :provider field)
   - recipe: Recipe definition
   - prompt-override: Optional prompt to use instead of step prompt (for retries)"
  ([channel session-id working-dir orch-state recipe]
   (execute-recipe-step channel session-id working-dir orch-state recipe nil))
  ([channel session-id working-dir orch-state recipe prompt-override]
   (let [step-prompt (or prompt-override (get-next-step-prompt session-id orch-state recipe))
         current-step (:current-step orch-state)
         session-created? (:session-created? orch-state)
         step-model (get-step-model recipe current-step)]
     (if step-prompt
       (do
         (log/info "Executing recipe step"
                   {:session-id session-id
                    :recipe-id (:recipe-id orch-state)
                    :step current-step
                    :provider (:provider orch-state)
                    :model step-model
                    :step-count (:step-count orch-state)
                    :session-created? session-created?
                    :is-retry (some? prompt-override)})
         (when step-model
           (log/warn "Recipe step requests model override, which is not honored under tmux invocation"
                     {:session-id session-id
                      :recipe-id (:recipe-id orch-state)
                      :step current-step
                      :requested-model step-model}))

         (when-not prompt-override
           (send-to-client! channel
                            {:type :recipe-step-started
                             :session-id session-id
                             :step current-step
                             :step-count (:step-count orch-state)}))

         (dispatch-recipe-step-via-tmux!
          {:provider (:provider orch-state)
           :session-id session-id
           :session-created? session-created?
           :prompt-text step-prompt
           :working-dir working-dir}
          (fn [response]
            (try
              (if (:success response)
                (let [response-text (:result response)
                      current-orch-state (get-session-recipe-state session-id)]
                  (when (and current-orch-state (not session-created?))
                    (log/info "Marking session as created after first successful invocation"
                              {:session-id session-id})
                    (swap! session-orchestration-state
                           update session-id
                           assoc :session-created? true))
                  (if (nil? current-orch-state)
                    (do
                      (log/info "Recipe was exited while waiting for provider response"
                                {:session-id session-id})
                      (send-to-client! channel
                                       {:type :turn-complete
                                        :session-id session-id}))
                    (let [result (process-orchestration-response
                                  session-id current-orch-state recipe response-text channel)]
                      (log/info "Recipe step response processed"
                                {:session-id session-id
                                 :step current-step
                                 :action (:action result)
                                 :next-step (:step-name result)
                                 :reason (:reason result)})
                      (case (:action result)
                        :next-step
                        (let [updated-orch-state (get-session-recipe-state session-id)
                              updated-recipe (recipes/get-recipe (:recipe-id updated-orch-state))]
                          (if updated-orch-state
                            (execute-recipe-step channel session-id working-dir
                                                 updated-orch-state updated-recipe)
                            (do
                              (log/warn "Orchestration state missing after step transition"
                                        {:session-id session-id})
                              (send-to-client! channel
                                               {:type :turn-complete
                                                :session-id session-id}))))

                        :retry
                        (let [updated-orch-state (get-session-recipe-state session-id)]
                          (if updated-orch-state
                            (do
                              (log/info "Retrying step with reminder prompt"
                                        {:session-id session-id
                                         :step current-step})
                              (execute-recipe-step channel session-id working-dir
                                                   updated-orch-state recipe (:prompt result)))
                            (do
                              (log/warn "Orchestration state missing before retry"
                                        {:session-id session-id})
                              (send-to-client! channel
                                               {:type :turn-complete
                                                :session-id session-id}))))

                        :exit
                        (do
                          (log/info "Recipe exited"
                                    {:session-id session-id
                                     :reason (:reason result)})
                          (send-to-client! channel
                                           {:type :turn-complete
                                            :session-id session-id}))

                        :restart-new-session
                        (let [new-session-id (str (java.util.UUID/randomUUID))
                              new-recipe-id (:recipe-id result)
                              old-provider (:provider orch-state)]
                          (log/info "Recipe restarting with new session"
                                    {:old-session-id session-id
                                     :new-session-id new-session-id
                                     :recipe-id new-recipe-id
                                     :old-provider old-provider
                                     :working-directory working-dir})
                          (exit-recipe-for-session session-id "restart-new-session")
                          (send-to-client! channel
                                           {:type :recipe-exited
                                            :session-id session-id
                                            :reason "restart-new-session"})
                          (send-to-client! channel
                                           {:type :turn-complete
                                            :session-id session-id})
                          (if-let [new-orch-state (start-recipe-for-session new-session-id new-recipe-id true :provider old-provider)]
                            (let [new-recipe (recipes/get-recipe new-recipe-id)]
                              (send-to-client! channel
                                               {:type :recipe-started
                                                :recipe-id new-recipe-id
                                                :recipe-label (:label new-recipe)
                                                :session-id new-session-id
                                                :current-step (:current-step new-orch-state)
                                                :step-count (:step-count new-orch-state)})
                              (send-to-client! channel
                                               {:type :ack
                                                :message "Starting recipe in new session..."})
                              (execute-recipe-step channel new-session-id working-dir
                                                   new-orch-state new-recipe))
                            (do
                              (log/error "Failed to create orchestration state for restart"
                                         {:recipe-id new-recipe-id})
                              (send-to-client! channel
                                               {:type :error
                                                :message (str "Recipe not found: " (name new-recipe-id))}))))

                        (do
                          (log/error "Unexpected orchestration action"
                                     {:action (:action result)})
                          (send-to-client! channel
                                           {:type :turn-complete
                                            :session-id session-id}))))))

                (do
                  (log/error "Recipe step failed"
                             {:error (:error response) :session-id session-id})
                  (exit-recipe-for-session session-id "error")
                  (send-to-client! channel
                                   {:type :recipe-exited
                                    :session-id session-id
                                    :reason "error"
                                    :error (:error response)})
                  (send-to-client! channel
                                   {:type :error
                                    :message (:error response)
                                    :session-id session-id})))
              (catch Exception e
                (log/error e "Unexpected error in recipe step callback"
                           {:session-id session-id :step current-step})
                (exit-recipe-for-session session-id "internal-error")
                (send-to-client! channel
                                 {:type :recipe-exited
                                  :session-id session-id
                                  :reason "internal-error"
                                  :error (str "Internal error: " (ex-message e))})
                (send-to-client! channel
                                 {:type :error
                                  :message (str "Internal error: " (ex-message e))
                                  :session-id session-id}))))))
       (do
         (log/error "No step prompt available for recipe step"
                    {:session-id session-id
                     :recipe-id (:recipe-id orch-state)
                     :step current-step})
         (exit-recipe-for-session session-id "no-prompt")
         (send-to-client! channel
                          {:type :recipe-exited
                           :session-id session-id
                           :reason "no-prompt"
                           :error "No step prompt available"})
         (send-to-client! channel
                          {:type :turn-complete
                           :session-id session-id}))))))

;; Filesystem watcher callbacks

;; Removed duplicate comment here

(defn on-session-created
  "Called when a new session file is detected.

   The session-created envelope and recent-sessions side-channel fan out to
   every connected non-deleted client (so any client viewing Projects sees
   the new row). The session-updated push body, however, must be gated by
   per-channel :subscribed-sessions — same shape as broadcast-session-history!
   (tmux-untethered-2yp). Without that gate a connected client that has never
   subscribed to this session can still receive its messages on the new-session
   race path, which is the cross-session leak we're closing."
  [session-metadata]
  (let [session-id (:session-id session-metadata)
        client-count (count @connected-clients)
        eligible-clients (filter (fn [[channel _]]
                                   (not (is-session-deleted-for-client? channel session-id)))
                                 @connected-clients)
        eligible-count (count eligible-clients)]

    (log/info "Session created callback invoked"
              {:session-id session-id
               :name (:name session-metadata)
               :message-count (:message-count session-metadata)
               :total-clients client-count
               :eligible-clients eligible-count
               :has-preview (boolean (seq (:preview session-metadata)))
               :provider (:provider session-metadata)})

    ;; Check if this is a pending new session and send session_ready first
    (when-let [pending-channel (get @pending-new-sessions session-id)]
      (log/info "Sending session_ready for pending new session"
                {:session-id session-id})
      (send-to-client! pending-channel
                       {:type :session-ready
                        :session-id session-id
                        :message "Session is ready for subscription"})
      ;; Remove from pending map
      (swap! pending-new-sessions dissoc session-id))

    ;; Broadcast to clients who haven't deleted this session
    (doseq [[channel client-info] eligible-clients]
      (log/debug "Sending session-created to client"
                 {:session-id session-id
                  :client-session-id (:session-id client-info)
                  :channel-id (str channel)})
      (send-to-client! channel
                       {:type :session-created
                        :session-id session-id
                        :name (:name session-metadata)
                        :working-directory (:working-directory session-metadata)
                        :last-modified (:last-modified session-metadata)
                        :message-count (:message-count session-metadata)
                        :preview (:preview session-metadata)
                        :provider (or (:provider session-metadata) :claude)})

      ;; Send updated recent sessions list to each client
      (let [limit (get client-info :recent-sessions-limit 5)]
        (send-recent-sessions! channel limit)))

    ;; Also send messages if client is subscribed (handles new session race condition).
    ;; Gate by per-channel :subscribed-sessions — repl/is-subscribed? is a
    ;; global session-level flag, not a per-channel filter.
    (when (repl/is-subscribed? session-id)
      (let [file-path (:file session-metadata)
            all-messages (repl/parse-jsonl-file file-path)
            messages (repl/filter-internal-messages all-messages)
            push-clients (filter (fn [[_ client-info]]
                                   (contains? (or (:subscribed-sessions client-info) #{})
                                              session-id))
                                 eligible-clients)]
        (if (seq messages)
          (do
            (log/info "Sending initial messages for new subscribed session"
                      {:session-id session-id
                       :message-count (count messages)
                       :eligible-clients eligible-count
                       :push-clients (count push-clients)})
            (doseq [[channel _] push-clients]
              (send-to-client! channel
                               {:type :session-updated
                                :session-id session-id
                                :messages messages})))
          (log/debug "No messages to send for new subscribed session"
                     {:session-id session-id}))))))

(defn broadcast-session-history!
  "Flat broadcast of newly-parsed messages as a one-message-window
   session_history payload (protocol v0.4.0).

   Every eligible subscriber receives the same payload regardless of their
   own last_seq — the server does NOT tailor per subscriber. Client-side
   gap detection (`first_seq` vs. `local_last_seq`) is responsible for
   reconciling missed windows by re-subscribing with the appropriate cursor
   (see @docs/design/append-only-message-stream.md §Push).

   Push eligibility (session_history / session_updated body): a connected
   client that has explicitly subscribed to this session AND has not
   marked it as locally-deleted. The replication watcher's `is-subscribed?`
   flag is a global session-level set, not a per-channel filter, so
   without per-channel gating here every connected client would receive
   every push for any session any client subscribed to. That leak is the
   root of cross-session TTS bleed (tmux-untethered-2yp): the iOS
   active-session check is the last line of defense, not the first.

   recent_sessions piggybacks on every push and goes to all connected
   non-deleted clients regardless of subscription, so a client viewing
   session B still sees session A move to the top of its Recent list when
   session A is written. Otherwise the Recent panel would freeze for any
   activity outside the currently-subscribed sessions.

   Under v0.3.0 rollback, emits the legacy `session_updated` envelope so
   existing clients keep working without a redeploy. Messages still carry
   `:seq` (assign-seq! stamps every parse regardless of protocol), which
   v0.3.0 clients harmlessly ignore.

   With per-channel protocol negotiation (§3.2), the dispatch is now per
   subscriber: each channel routes on (channel-protocol channel) rather
   than the global atom. v0.5.0 channels are EXCLUDED from this fan-out
   (see the filter below); they receive their tailored per-subscriber
   payload from `push-to-subscribers!` instead. Including a v0.5.0
   channel here would double-deliver each tick AND emit the v0.4.0 wire
   shape (`:first-seq`/`:last-seq`) which the v0.5.0 decoder rejects."
  [session-id new-messages]
  (let [not-deleted-clients (filter (fn [[channel _]]
                                      (not (is-session-deleted-for-client? channel session-id)))
                                    @connected-clients)
        push-clients (->> not-deleted-clients
                          (filter (fn [[_ client-info]]
                                    (contains? (or (:subscribed-sessions client-info) #{})
                                               session-id)))
                          ;; Exclude v0.5.0 channels — they receive their per-
                          ;; subscriber tailored payload from `push-to-subscribers!`
                          ;; (T10). Sending both would double-deliver each tick;
                          ;; the v0.4.0 wire shape (with :first-seq/:last-seq) is
                          ;; also incompatible with the v0.5.0 decoder.
                          (filter (fn [[channel _]]
                                    (not= :v0.5.0 (channel-protocol channel)))))
        push-count (count push-clients)
        protocols (mapv (fn [[ch _]] (channel-protocol ch)) push-clients)]

    (if (zero? push-count)
      ;; Surface the no-subscriber case at INFO so the symptom is visible
      ;; from logs alone. tmux-untethered-9o9 was effectively invisible
      ;; under the prior INFO line because it logged the same way whether
      ;; the broadcast actually fanned out or got dropped on the floor.
      (log/info (str "⚠ session-history fan-out skipped — no subscribers")
                {:session-id session-id
                 :new-message-count (count new-messages)
                 :total-clients (count @connected-clients)
                 :recent-sessions-clients (count not-deleted-clients)
                 :subscriber-protocols (frequencies protocols)})
      (log/info "Broadcasting session history"
                {:session-id session-id
                 :new-message-count (count new-messages)
                 :total-clients (count @connected-clients)
                 :push-clients push-count
                 :recent-sessions-clients (count not-deleted-clients)
                 :subscriber-protocols (frequencies protocols)}))

    ;; v0.4.0/v0.5.0 payload — built once, shared across all seq-stamped
    ;; subscribers. assign-seq!'s (inc last-stamped-seq) is atomic with the
    ;; message vector, so reading session-index here would race a concurrent
    ;; assign-seq! that already pushed the counter past last-seq+1, making
    ;; the payload look like a multi-seq gap and triggering spurious
    ;; resubscribes. Metadata read remains as fallback for empty broadcasts
    ;; where last-seq is nil.
    (let [msgs-vec (vec new-messages)
          first-seq (:seq (first msgs-vec))
          last-seq (:seq (last msgs-vec))
          next-seq (or (when last-seq (inc last-seq))
                       (:next-seq (repl/get-session-metadata session-id))
                       1)
          wire-messages (mapv #(assoc % :session-id session-id) msgs-vec)
          v0-4-plus-payload {:type :session-history
                             :session-id session-id
                             :messages wire-messages
                             :first-seq first-seq
                             :last-seq last-seq
                             :next-seq next-seq
                             :is-complete true
                             :gap nil}]
      (doseq [[channel _] push-clients]
        (if (= :v0.3.0 (channel-protocol channel))
          (do
            (log/debug "Sending session-updated to client (v0.3.0 rollback)"
                       {:session-id session-id
                        :new-messages (count new-messages)
                        :channel-id (str channel)})
            (send-to-client! channel
                             {:type :session-updated
                              :session-id session-id
                              :messages new-messages}))
          (do
            (log/debug "Broadcasting session-history window to subscriber"
                       {:session-id session-id
                        :first-seq first-seq
                        :last-seq last-seq
                        :channel-id (str channel)
                        :protocol (channel-protocol channel)})
            (send-to-client! channel v0-4-plus-payload)))))

    ;; recent_sessions piggybacks for every connected non-deleted client,
    ;; not just per-session subscribers — see docstring.
    (doseq [[channel client-info] not-deleted-clients]
      (let [limit (get client-info :recent-sessions-limit 5)]
        (send-recent-sessions! channel limit)))))

(defn truncate-budget
  "Pack `messages` (vector of canonical messages) within `max-bytes` and
   return just the included prefix vector. Wraps `pack-within-budget`'s
   richer return shape; the v0.5.0 push path derives `:end-of-file` from
   the file's total line count, not from `:complete?`, so the budget
   signal is discarded.

   Before packing, each message is middle-truncated to
   `per-message-max-bytes`. Without this, a single message whose `:text`
   exceeds `max-bytes` would cause `pack-within-budget` to return an
   empty prefix — the v0.5.0 callers then echo `next-offset =
   client-offset` and stall the client until the file signature changes.
   Mirrors the `truncate-message-text` pass the v0.4.0 path runs before
   `build-session-history-response`.

   Known limitation: `truncate-message-text` only truncates text content
   (`:text`, `:content`, `:message.content`, `:toolUseResult`). A
   message dominated by structural fields (e.g. dozens of tool-call
   envelopes) can still exceed `max-bytes` after truncation. The fast-
   path callers will return `next-offset = client-offset` in that case
   and the client stalls until either the file signature changes
   (forcing a §6 R2 resync) or the client manually advances its cursor.
   Callers should not assume a non-empty input always yields a non-empty
   packed result.

   Overhead constants match the v0.5.0 wire payload:
   - envelope (256 bytes): covers `{:type :session-id :next-offset
     :end-of-file :file-signature}` + `:messages` array brackets. The
     realistic wire form (camelCase keys, 36-char session UUID, 64-byte
     signature) totals ~210 bytes; 256 gives margin for protocol
     version growth.
   - per-message-extra (52 bytes): the `:session-id` field that
     `push-to-subscribers!` `assoc`s onto each message AFTER packing."
  [messages max-bytes]
  (let [truncated (mapv #(truncate-message-text % per-message-max-bytes) messages)]
    (:included (pack-within-budget truncated max-bytes 256 52))))

(defn estimate-line-limit
  "Conservative raw-line count derived from `max-bytes`. Bounds the parse
   work `read-from-offset` performs on the backfill path before
   `truncate-budget` applies the precise wire-size cap.

   The 512-byte-per-line assumption is intentionally low for typical
   Claude sessions (short text messages, tool-call envelopes) so the
   limit produces a generous slice; `truncate-budget` will pack within
   `max-bytes` regardless. Floors at 1 so a tiny `max-bytes` still
   advances at least one line."
  [max-bytes]
  (max 1 (int (/ max-bytes 512))))

(defn- v0-5-0-subscriber?
  "Predicate: `[channel client-info]` for `session-id` belongs to the
   v0.5.0 fan-out (authenticated, subscribed, not-deleted-for-client,
   negotiated v0.5.0). Shared by `subscribers-for` and tests.

   Uses the destructured `client-info` for the deletion check instead of
   `is-session-deleted-for-client?` (which re-reads `@connected-clients`)
   to keep the per-tick fan-out to a single atom read."
  [session-id [_channel client-info]]
  (and (:authenticated client-info)
       (contains? (or (:subscribed-sessions client-info) #{}) session-id)
       (not (contains? (:deleted-sessions client-info) session-id))
       (= :v0.5.0 (:negotiated-protocol-version client-info))))

(defn subscribers-for
  "Seq of `[channel client-info]` pairs eligible for v0.5.0 push fan-out
   on `session-id`. Mirrors `broadcast-session-history!`'s filter chain
   with the per-channel protocol gate added — v0.4.0/v0.3.0 channels are
   excluded because they continue to receive from
   `broadcast-session-history!`."
  [session-id]
  (->> @connected-clients
       (filter #(v0-5-0-subscriber? session-id %))))

(defn push-to-subscribers!
  "v0.5.0 tailored fan-out invoked by the watcher pipeline after a tick.

   Inputs:
   - `snapshot`               — vector of canonical messages produced by
                                `stamp-offsets`, each carrying `:offset`
                                (raw-line index in the source file).
                                Empty when every raw line in the tick was
                                filtered out — the empty-snapshot guard
                                below still pushes to caught-up
                                subscribers so they observe the cursor
                                advancing past the filtered tail.
   - `snapshot-from-offset`   — `:offset` of `snapshot[0]` (or, when
                                `snapshot` is empty, the line count
                                before this tick's appended lines).
                                `nil` only on the bootstrap edge cases
                                covered by the backfill branch.
   - `file-end-line-count`    — total raw-line count of the file AFTER
                                this tick. The pass-2 EOF check compares
                                the packed watermark against this value,
                                NOT against `(count snapshot)`, because
                                the snapshot is a partial view.
   - `current-sig`            — `compute-file-signature` evaluated ONCE
                                per tick by the caller and threaded
                                through. Stamped on every emitted
                                payload so iOS keeps `lastFileSignature`
                                fresh between subscribes (§6 R2).

   Per-subscriber dispatch:
     - Fast path (`client-offset >= snapshot-from-offset`): slice the
       snapshot in memory and pack within `max-bytes`. No disk I/O.
     - Backfill path: subscriber is behind `snapshot-from-offset` (flaky
       network, paused app); fall back to `read-from-offset` for the
       gap.

   Client-ahead clamp: when `client-offset > file-end-line-count` (e.g.
   the iOS client survived a backend rollback and holds a cursor past
   the server's view), the fast path produces `sliced = []` and
   `next-offset = file-end-line-count`, which is LESS than the
   subscriber's previous offset. iOS detects `next_offset <
   previous_offset` and resets to 0 (design doc §3.1) — matching the
   `read-from-offset` clamp behavior.

   Idempotency: concurrent push and subscribe writes to
   `[:session-offsets session-id]` resolve via `assoc-in`'s last-write-
   wins; the `(sessionId, offset)` upsert on the iOS side absorbs any
   duplicate delivery, so neither winner corrupts state."
  [session-id provider file-path snapshot snapshot-from-offset file-end-line-count current-sig]
  (doseq [[channel client-info] (subscribers-for session-id)]
    (let [client-offset (get-in client-info [:session-offsets session-id] 0)
          max-bytes (get-client-max-message-size-bytes channel)
          fast-path? (and snapshot-from-offset
                          (>= client-offset snapshot-from-offset))
          {:keys [messages next-offset end-of-file?]}
          (if fast-path?
            (let [sliced (vec (drop-while #(< (:offset %) client-offset) snapshot))
                  budget (truncate-budget sliced max-bytes)
                  next-offset (cond
                                (seq budget)
                                (inc (:offset (peek budget)))
                                ;; Sliced is empty — either the subscriber is
                                ;; caught up to (or past) the snapshot tail, or
                                ;; the snapshot itself was empty because every
                                ;; raw line this tick was filtered out. In both
                                ;; cases advance the cursor past the filtered
                                ;; tail so the subscriber catches up to the
                                ;; file's true line count.
                                (empty? sliced)
                                file-end-line-count
                                ;; Sliced non-empty but byte-budget exhausted
                                ;; before fitting the first message — don't
                                ;; advance, the next push retries from the same
                                ;; offset.
                                :else
                                client-offset)]
              {:messages budget
               :next-offset next-offset
               ;; Pass-2 EOF fix: compares packed watermark against the file's
               ;; total line count, not against `(count snapshot)`. A snapshot
               ;; can be a partial view (watcher debounces multiple appends
               ;; between ticks) so equality with snapshot length is the
               ;; weaker, incorrect condition.
               :end-of-file? (and (= (count budget) (count sliced))
                                  (= next-offset file-end-line-count))})
            (let [limit (estimate-line-limit max-bytes)
                  raw (repl/read-from-offset provider file-path client-offset limit)
                  raw-msgs (:messages raw)
                  budget (truncate-budget raw-msgs max-bytes)
                  next-offset (cond
                                (seq budget)
                                (inc (:offset (peek budget)))
                                (empty? raw-msgs)
                                (:next-offset raw)
                                :else
                                client-offset)]
              {:messages budget
               :next-offset next-offset
               :end-of-file? (and (= (count budget) (count raw-msgs))
                                  (boolean (:end-of-file? raw)))}))
          last-sig (get-in client-info [:last-emitted-sigs session-id])
          sig-changed? (not= current-sig last-sig)]
      ;; Emit when there's something to convey: new messages, OR the file
      ;; signature changed (rare: e.g. the tick observed a length advance
      ;; with all lines filtered out — caught-up subscribers still need
      ;; the refreshed sig and an advanced cursor).
      (when (or (seq messages) sig-changed?)
        (let [wire-msgs (mapv #(assoc % :session-id session-id) messages)]
          (send-to-client! channel
                           {:type :session-history
                            :session-id session-id
                            :messages wire-msgs
                            :next-offset next-offset
                            :end-of-file end-of-file?
                            :file-signature current-sig})
          ;; Last-write-wins update, but ONLY when the channel still
          ;; exists. `send-to-client!` calls `unregister-channel!` on
          ;; socket failure (server.clj:867), which dissociates the
          ;; channel; without the contains? guard, `assoc-in` on a
          ;; missing key would re-insert a partial `{channel {:session-
          ;; offsets {...} :last-emitted-sigs {...}}}` ghost entry that
          ;; leaks until process restart.
          (swap! connected-clients
                 (fn [m]
                   (cond-> m
                     (contains? m channel)
                     (-> (assoc-in [channel :session-offsets session-id] next-offset)
                         (assoc-in [channel :last-emitted-sigs session-id] current-sig))))))))))

(defn on-session-deleted
  "Called when a session file is deleted from filesystem"
  [session-id]
  (log/info "Session deleted from filesystem" {:session-id session-id}))
  ;; This is informational - we don't broadcast deletes since it's just local cleanup

(defn on-turn-complete
  "Handler for turn-complete events.

   Always broadcasts `{:type :turn-complete :session-id X}` to every connected
   client subscribed to the session. Additionally, if a recipe step is waiting
   on this turn, fires its callback with the last assistant message text —
   but only if the text is strictly newer than the watermark captured at
   dispatch. Spurious fires (no fresh assistant message) leave the callback
   registered so a later, legitimate turn-complete can drain it."
  [session-id]
  (log/info "Turn-complete callback invoked" {:session-id session-id})
  (when-let [{:keys [callback since-uuid]} (get @recipe-turn-callbacks session-id)]
    (let [text (read-fresh-assistant-text session-id since-uuid)]
      (if (nil? text)
        (log/info "Turn-complete fire ignored: no fresh assistant message"
                  {:session-id session-id :since-uuid since-uuid})
        (do
          (swap! recipe-turn-callbacks dissoc session-id)
          (try
            (callback {:success true :result text :session-id session-id})
            (catch Throwable e
              (log/error e "Recipe turn-complete callback failed"
                         {:session-id session-id})))))))
  (doseq [[channel client-info] @connected-clients]
    (let [subscribed (or (:subscribed-sessions client-info) #{})]
      (when (and (contains? subscribed session-id)
                 (not (is-session-deleted-for-client? channel session-id)))
        (send-to-client! channel
                         {:type :turn-complete
                          :session-id session-id})))))

(defn- handle-subscribe-v0-4-0
  "Legacy subscribe handler covering v0.4.0 (last_seq cursor) and v0.3.0
   (last_message_id cursor). Body lifted verbatim from the pre-T9 inline
   `(case msg-type \"subscribe\" ...)` branch so the rollback window keeps
   bit-for-bit compatible behavior for non-v0.5.0 channels."
  [channel data]
  (let [session-id (:session-id data)
        last-seq-val (:last-seq data)
        last-message-id (:last-message-id data)
        v0-4? (not= :v0.3.0 (channel-protocol channel))]
    (cond
      (not session-id)
      (http/send! channel
                  (generate-json
                   {:type :error
                    :message "session_id required in subscribe message"}))

      (and v0-4? (some? last-message-id))
      (http/send! channel
                  (generate-json
                   {:type "error"
                    :code "unsupported_subscribe_field"
                    :message (str "last_message_id is not supported in protocol "
                                  "v0.4.0; use last_seq instead")}))

      (and v0-4?
           (some? last-seq-val)
           (or (not (integer? last-seq-val))
               (neg? last-seq-val)))
      (http/send! channel
                  (generate-json
                   {:type "error"
                    :code "invalid_subscribe"
                    :message "last_seq must be a non-negative integer"}))

      :else
      (do
        (log/info "Client subscribing to session"
                  {:session-id session-id
                   :last-seq last-seq-val
                   :last-message-id last-message-id
                   :protocol (if v0-4? :v0.4.0 :v0.3.0)})

        (repl/subscribe-to-session! session-id)
        (swap! connected-clients update-in [channel :subscribed-sessions]
               (fnil conj #{}) session-id)

        (if-let [metadata (repl/get-session-metadata session-id)]
          (let [file-path (:file metadata)
                provider (:provider metadata :claude)
                file (io/file file-path)
                current-size (.length file)
                all-messages (repl/parse-session-messages provider file-path)
                filtered (vec (repl/filter-internal-messages all-messages))
                max-bytes (get-client-max-message-size-bytes channel)
                truncated (mapv #(truncate-message-text % per-message-max-bytes) filtered)
                stamped (vec (map-indexed (fn [i m] (assoc m :seq (inc i))) truncated))
                session-next-seq (inc (count stamped))]
            (repl/reset-file-position! file-path)
            (swap! repl/file-positions assoc file-path current-size)
            (send-available-commands! channel (:working-directory metadata))
            (if v0-4?
              (let [client-last-seq (or last-seq-val 0)
                    {response-msgs :messages
                     is-complete :is-complete
                     first-seq :first-seq
                     last-seq :last-seq
                     next-seq :next-seq
                     gap :gap}
                    (build-session-history-response stamped client-last-seq
                                                    max-bytes
                                                    (or (:min-available-seq metadata) 1)
                                                    session-next-seq)
                    wire-messages (mapv #(assoc % :session-id session-id) response-msgs)]
                (log/info "Sending session history"
                          {:session-id session-id
                           :protocol :v0.4.0
                           :message-count (count wire-messages)
                           :client-last-seq client-last-seq
                           :first-seq first-seq
                           :last-seq last-seq
                           :next-seq next-seq
                           :gap gap
                           :is-complete is-complete
                           :file-position current-size})
                (http/send! channel
                            (generate-json
                             {:type :session-history
                              :session-id session-id
                              :messages wire-messages
                              :first-seq first-seq
                              :last-seq last-seq
                              :next-seq next-seq
                              :is-complete is-complete
                              :gap gap})))
              (let [client-last-seq (or (when last-message-id
                                          (some (fn [m]
                                                  (when (= (:uuid m) last-message-id)
                                                    (:seq m)))
                                                stamped))
                                        0)
                    {response-msgs :messages
                     is-complete :is-complete
                     first-seq :first-seq
                     last-seq :last-seq}
                    (build-session-history-response stamped client-last-seq
                                                    max-bytes
                                                    (or (:min-available-seq metadata) 1)
                                                    session-next-seq)
                    oldest-message-id (when first-seq
                                        (some (fn [m]
                                                (when (= (:seq m) first-seq)
                                                  (:uuid m)))
                                              stamped))
                    newest-message-id (when last-seq
                                        (some (fn [m]
                                                (when (= (:seq m) last-seq)
                                                  (:uuid m)))
                                              stamped))
                    wire-messages (mapv #(dissoc % :seq) response-msgs)]
                (log/info "Sending session history"
                          {:session-id session-id
                           :protocol :v0.3.0
                           :message-count (count wire-messages)
                           :total (count filtered)
                           :is-complete is-complete
                           :has-delta-sync (some? last-message-id)
                           :file-position current-size})
                (http/send! channel
                            (generate-json
                             {:type :session-history
                              :session-id session-id
                              :messages wire-messages
                              :total-count (count filtered)
                              :oldest-message-id oldest-message-id
                              :newest-message-id newest-message-id
                              :is-complete is-complete})))))
          (do
            (log/warn "Session not found" {:session-id session-id})
            (http/send! channel
                        (generate-json
                         {:type :error
                          :message (str "Session not found: " session-id)}))))))))

(defn- handle-subscribe-v0-5-0
  "v0.5.0 subscribe handler — Kafka-style offset protocol (design §3.3).

   Reads `:session-id`, `:from-offset` (defaults to 0), and optional
   `:file-signature-seen` from `data`. On signature mismatch with the
   live file, emits the §6 R2 `file_replaced: true` recovery envelope,
   resets `[:session-offsets session-id]` to 0, and emits the
   `:replication.file-replaced` counter. Otherwise reads from disk via
   `read-from-offset`, packs within the channel's max-bytes budget, and
   seeds `[:session-offsets session-id]` to `next-offset` so
   `push-to-subscribers!` can tailor subsequent live pushes from there.

   `:last-emitted-sigs` is also seeded on both branches so a follow-up
   tick without new content doesn't trigger a duplicate sig-only emit.

   `:file-signature-seen`, when present, must be a string — the server
   produces it as `\"{length}:{first-line-uuid}\"`. A non-string value
   would always mismatch via `not=` and trigger an unwarranted R2 reset
   (with a `:replication.file-replaced` counter bump), so the input is
   rejected up front with `invalid_subscribe`."
  [channel data]
  (let [session-id (:session-id data)
        from-offset (or (:from-offset data) 0)
        sig-seen (:file-signature-seen data)]
    (cond
      (not session-id)
      (http/send! channel
                  (generate-json
                   {:type :error
                    :message "session_id required in subscribe message"}))

      (or (not (integer? from-offset)) (neg? from-offset))
      (http/send! channel
                  (generate-json
                   {:type "error"
                    :code "invalid_subscribe"
                    :message "from_offset must be a non-negative integer"}))

      (and (some? sig-seen) (not (string? sig-seen)))
      (http/send! channel
                  (generate-json
                   {:type "error"
                    :code "invalid_subscribe"
                    :message "file_signature_seen must be a string when provided"}))

      :else
      (do
        (log/info "Client subscribing to session"
                  {:session-id session-id
                   :from-offset from-offset
                   :file-signature-seen sig-seen
                   :protocol :v0.5.0})
        (repl/subscribe-to-session! session-id)
        (swap! connected-clients update-in [channel :subscribed-sessions]
               (fnil conj #{}) session-id)
        (if-let [metadata (repl/get-session-metadata session-id)]
          (let [provider (:provider metadata :claude)
                file-path (:file metadata)
                current-sig (repl/compute-file-signature provider file-path)
                sig-mismatch? (and sig-seen (not= sig-seen current-sig))]
            (send-available-commands! channel (:working-directory metadata))
            (if sig-mismatch?
              (do
                (repl/emit-metric! :counter :replication.file-replaced
                                   {:session-id session-id})
                (log/info "Sending session history"
                          {:session-id session-id
                           :protocol :v0.5.0
                           :file-replaced true
                           :file-signature-seen sig-seen
                           :file-signature current-sig})
                (send-to-client! channel
                                 {:type :session-history
                                  :session-id session-id
                                  :messages []
                                  :next-offset 0
                                  :end-of-file true
                                  :file-replaced true
                                  :file-signature current-sig})
                ;; Guard against `send-to-client!` having dropped the channel
                ;; on send failure (server.clj:867) — without contains?,
                ;; assoc-in would re-insert a ghost entry that leaks forever.
                (swap! connected-clients
                       (fn [m]
                         (cond-> m
                           (contains? m channel)
                           (-> (assoc-in [channel :session-offsets session-id] 0)
                               (assoc-in [channel :last-emitted-sigs session-id] current-sig))))))
              (let [max-bytes (get-client-max-message-size-bytes channel)
                    limit (estimate-line-limit max-bytes)
                    {:keys [messages next-offset end-of-file?]}
                    (repl/read-from-offset provider file-path from-offset limit)
                    budgeted (truncate-budget messages max-bytes)
                    wire-msgs (mapv #(assoc % :session-id session-id) budgeted)
                    packed-next-offset (cond
                                         (= (count budgeted) (count messages))
                                         next-offset
                                         (seq budgeted)
                                         (inc (:offset (peek budgeted)))
                                         :else
                                         from-offset)
                    packed-eof? (and (= (count budgeted) (count messages))
                                     (boolean end-of-file?))]
                (log/info "Sending session history"
                          {:session-id session-id
                           :protocol :v0.5.0
                           :message-count (count wire-msgs)
                           :from-offset from-offset
                           :next-offset packed-next-offset
                           :end-of-file packed-eof?
                           :file-signature current-sig})
                (send-to-client! channel
                                 {:type :session-history
                                  :session-id session-id
                                  :messages wire-msgs
                                  :next-offset packed-next-offset
                                  :end-of-file packed-eof?
                                  :file-signature current-sig})
                ;; See R2 branch above: guard against the channel having
                ;; been dropped by send-to-client! on socket failure.
                (swap! connected-clients
                       (fn [m]
                         (cond-> m
                           (contains? m channel)
                           (-> (assoc-in [channel :session-offsets session-id] packed-next-offset)
                               (assoc-in [channel :last-emitted-sigs session-id] current-sig))))))))
          (do
            (log/warn "Session not found" {:session-id session-id})
            (http/send! channel
                        (generate-json
                         {:type :error
                          :message (str "Session not found: " session-id)}))))))))

;; Message handling
(defn handle-message
  "Handle incoming WebSocket message with session-based authentication.
   
   Authentication flow:
   - ping: Always allowed (health check)
   - connect: Validates api_key and marks channel as authenticated
   - All other messages: Require prior authentication via connect"
  [channel msg]
  (try
    (let [data (parse-json msg)
          msg-type (:type data)
          ;; Concise inbound line, mirroring the outbound formatter in
          ;; `send-to-client!`. Pull the few fields we actually want to
          ;; trace per type. Add new ones here rather than scattering
          ;; per-handler log calls.
          short-sess (when-let [s (:session-id data)]
                       (subs (str s) 0 (min 8 (count (str s)))))
          short-new (when-let [s (:new-session-id data)]
                      (subs (str s) 0 (min 8 (count (str s)))))
          short-resume (when-let [s (:resume-session-id data)]
                         (subs (str s) 0 (min 8 (count (str s)))))
          summary (cond-> {}
                    short-sess              (assoc :sess short-sess)
                    short-new               (assoc :new short-new)
                    short-resume            (assoc :resume short-resume)
                    (:last-seq data)        (assoc :last_seq (:last-seq data))
                    (:provider data)        (assoc :prov (:provider data))
                    (:command-id data)      (assoc :cmd (:command-id data))
                    (:size-kb data)         (assoc :kb (:size-kb data))
                    (:text data)            (assoc :len (count (str (:text data))))
                    (:protocol-version data) (assoc :proto (:protocol-version data)))]
      ;; Mirror send-to-client!'s silencing — ping fires every keepalive.
      (when-not (= msg-type "ping")
        (log/info (str "← " msg-type) summary))

      (cond
        ;; Ping is always allowed (health check, no auth required)
        (= msg-type "ping")
        (do
          (log/debug "Handling ping")
          (http/send! channel (generate-json {:type :pong})))

        ;; Connect requires API key authentication
        (= msg-type "connect")
        (when (and (enforce-protocol-version! channel data)
                   (authenticate-connect! channel data))
          ;; Authentication succeeded, proceed with connect logic
          ;; Compute the per-channel negotiated protocol version per §3.2 of
          ;; voice-code-sync-kafka-redesign-2026-05-10.md. The result is
          ;; recorded on connected-clients[channel] and surfaced to the
          ;; client in the :connected reply so the client knows which wire
          ;; shape to send on subscribe; without this, a VC_OFFSET_PROTOCOL=0
          ;; silent downgrade (T8) would leave iOS sending the v0.5.0 shape
          ;; against a v0.4.0-only server arm.
          (let [negotiated-version (negotiate-channel-protocol-version
                                    (:protocol-version data))
                negotiated-version-str (message-stream-version-string negotiated-version)
                limit (or (:recent-sessions-limit data) 5)]
            (log/info "Client connected and authenticated"
                      {:client-protocol-version (:protocol-version data)
                       :negotiated-protocol-version negotiated-version
                       :floor @message-stream-version
                       :server-max @server-max-protocol-version})

            ;; Register the negotiated version on the channel BEFORE sending
            ;; the :connected reply so any downstream code that reads
            ;; (channel-protocol channel) sees a populated value.
            (swap! connected-clients update channel merge
                   {:deleted-sessions #{}
                    :subscribed-sessions #{}
                    :recent-sessions-limit limit
                    :negotiated-protocol-version negotiated-version})

            ;; Send connected confirmation per STANDARDS.md protocol.
            ;; iOS only sets isAuthenticated=true on receipt of this message;
            ;; without it, subscribe() defers forever and session_history
            ;; pushes never reach the client. The negotiated_protocol_version
            ;; field (option (i) from §3.2 of the redesign — extend the
            ;; existing connect-success reply, not a new frame) tells iOS
            ;; which wire shape to use for subscribe and session_history.
            (http/send! channel
                        (generate-json
                         {:type :connected
                          :message "Session registered"
                          :session-id (:session-id data)
                          :negotiated-protocol-version negotiated-version-str})))

          ;; Send session list (limit to 50 most recent, lightweight fields only)
          (let [all-sessions (repl/get-all-sessions)
                ;; Filter out sessions with 0 messages (after internal message filtering)
                ;; Sort by last-modified descending, take 50
                recent-sessions (->> all-sessions
                                     (filter #(pos? (or (:message-count %) 0)))
                                     (sort-by :last-modified >)
                                     (take 50)
                                     ;; Remove heavy fields to reduce payload size
                                     (mapv #(select-keys % [:session-id :name :working-directory
                                                            :last-modified :message-count :provider])))
                total-non-empty (count (filter #(pos? (or (:message-count %) 0)) all-sessions))
                ;; Log any sessions with placeholder working directories
                placeholder-sessions (filter #(str/starts-with? (or (:working-directory %) "") "[from project:") recent-sessions)]
            (when (seq placeholder-sessions)
              (log/warn "Sessions with placeholder working directories being sent to iOS"
                        {:count (count placeholder-sessions)
                         :sessions (mapv #(select-keys % [:session-id :name :working-directory]) placeholder-sessions)}))
            (log/info "Sending session list" {:count (count recent-sessions) :total total-non-empty :total-all (count all-sessions)})
            (http/send! channel
                        (generate-json
                         {:type :session-list
                          :sessions recent-sessions
                          :total-count total-non-empty}))
            ;; Send recent sessions list (separate message type for Recent section)
            ;; Use limit from client if provided, otherwise default to 5
            (let [limit (or (:recent-sessions-limit data) 5)]
              (send-recent-sessions! channel limit))
            ;; Send available commands (no working directory yet, so no project commands)
            (send-available-commands! channel nil))
          ;; Start supervisor for this client connection
          (try
            (supervisor/start-supervisor! channel)
            (log/info "Supervisor started for client")
            (catch Exception e
              (log/warn e "Failed to start supervisor (non-fatal)"))))

        ;; All other message types require prior authentication
        :else
        (if-not (channel-authenticated? channel)
          ;; Not authenticated - reject with generic error
          (do
            (log/warn "Unauthenticated message rejected" {:type msg-type})
            (send-auth-error! channel (str "Unauthenticated " msg-type " message")))

          ;; Authenticated - process remaining message types
          (case msg-type
            "subscribe"
            ;; Per-channel protocol dispatch (§3.2 / T9). v0.5.0 channels
            ;; run the Kafka-style offset handler; v0.4.0 and v0.3.0
            ;; channels (and any pre-handshake channel with a nil
            ;; negotiated version) take the legacy seq-based handler.
            (case (channel-protocol channel)
              :v0.5.0 (handle-subscribe-v0-5-0 channel data)
              (handle-subscribe-v0-4-0 channel data))

            "unsubscribe"
            ;; Client stops watching a session
            (let [session-id (:session-id data)]
              (when session-id
                (log/info "Client unsubscribing from session" {:session-id session-id})
                ;; Remove from this client's subscribed-sessions
                (swap! connected-clients update-in [channel :subscribed-sessions]
                       (fnil disj #{}) session-id)
                ;; Only unsubscribe globally if no other client needs this session
                (let [other-clients-need-it?
                      (some (fn [[ch info]]
                              (and (not= ch channel)
                                   (contains? (or (:subscribed-sessions info) #{}) session-id)))
                            @connected-clients)]
                  (when-not other-clients-need-it?
                    (repl/unsubscribe-from-session! session-id)))))

            "session_deleted"
            ;; Client marks session as deleted locally
            (let [session-id (:session-id data)]
              (when session-id
                (log/info "Client deleted session locally" {:session-id session-id})
                (mark-session-deleted-for-client! channel session-id)
                ;; Remove from this client's subscribed-sessions
                (swap! connected-clients update-in [channel :subscribed-sessions]
                       (fnil disj #{}) session-id)
                ;; Only unsubscribe globally if no other client needs this session
                (let [other-clients-need-it?
                      (some (fn [[ch info]]
                              (and (not= ch channel)
                                   (contains? (or (:subscribed-sessions info) #{}) session-id)))
                            @connected-clients)]
                  (when-not other-clients-need-it?
                    (repl/unsubscribe-from-session! session-id)))))

            "prompt"
            ;; Updated to use new_session_id vs resume_session_id
            ;; In new architecture: NO direct response - rely on filesystem watcher + subscription
            (let [new-session-id (:new-session-id data)
                  resume-session-id (:resume-session-id data)
                  prompt-text (:text data)
                  ios-working-dir (:working-directory data)
                  system-prompt (:system-prompt data)
                  ;; Extract explicit provider from message (only for new sessions)
                  explicit-provider-str (:provider data)
                  _ (log/info "Prompt message received"
                              {:system-prompt system-prompt
                               :explicit-provider explicit-provider-str
                               :new-session new-session-id
                               :resume-session resume-session-id})
                  ;; Resolve working directory for new sessions only. Resumed
                  ;; sessions route through tmux/deliver!, which uses metadata
                  ;; from the session file rather than a caller-supplied path.
                  working-dir (when-not resume-session-id
                                (if (and ios-working-dir (str/starts-with? ios-working-dir "[from project:"))
                                  (let [project-name (second (re-find #"\[from project: ([^\]]+)\]" ios-working-dir))]
                                    (log/info "Converting placeholder to real path for new session"
                                              {:placeholder ios-working-dir
                                               :project-name project-name})
                                    (repl/project-name->working-dir project-name))
                                  ios-working-dir))]

              (cond
                ;; Check if client has connected first
                (not (contains? @connected-clients channel))
                (http/send! channel
                            (generate-json
                             {:type :error
                              :message "Must send connect message first"}))

                (not prompt-text)
                (http/send! channel
                            (generate-json
                             {:type :error
                              :message "text required in prompt message"}))

                (and new-session-id resume-session-id)
                (http/send! channel
                            (generate-json
                             {:type :error
                              :message "Cannot specify both new_session_id and resume_session_id"}))

                ;; Reject prompts for sessions whose JSONL is being rewritten by
                ;; `claude --compact`. The compaction handler kills the live
                ;; tmux window before compacting, so without this guard a fresh
                ;; respawn would write to the JSONL concurrently with compact.
                (and resume-session-id
                     (repl/is-compaction-locked? resume-session-id))
                (do
                  (log/info "Prompt rejected: compaction in progress"
                            {:session-id resume-session-id})
                  (http/send! channel
                              (generate-json
                               {:type :error
                                :session-id resume-session-id
                                :message "Compaction in progress for this session; retry once it completes"})))

                ;; Validate explicit provider if specified for new session
                (and new-session-id
                     explicit-provider-str
                     (not (contains? providers/known-providers (keyword explicit-provider-str))))
                (do
                  (log/warn "Invalid provider specified"
                            {:provider explicit-provider-str
                             :valid-providers (mapv name providers/known-providers)})
                  (http/send! channel
                              (generate-json
                               {:type :error
                                :message (str "Invalid provider: '" explicit-provider-str
                                              "'. Valid providers: "
                                              (str/join ", " (mapv name providers/known-providers)))})))

                :else
                (let [claude-session-id (or resume-session-id new-session-id)
                      ;; Extract explicit provider only for new sessions
                      ;; For resumed sessions, provider field is silently ignored
                      explicit-provider (when (and new-session-id explicit-provider-str)
                                          (keyword explicit-provider-str))
                      ;; Get session metadata for resumed sessions
                      session-metadata (when resume-session-id
                                         (repl/get-session-metadata resume-session-id))
                      ;; Resolve provider: explicit > session metadata > smart default
                      provider (providers/resolve-provider explicit-provider session-metadata)
                      ;; Validate CLI is available before dispatching to tmux
                      cli-validation-error (providers/validate-cli-available provider)
                      orch-state (get-session-recipe-state claude-session-id)
                      final-prompt-text (if orch-state
                                          (if-let [recipe (recipes/get-recipe (:recipe-id orch-state))]
                                            (or (get-next-step-prompt claude-session-id orch-state recipe) prompt-text)
                                            prompt-text)
                                          prompt-text)]
                  (if cli-validation-error
                    (do
                      (log/warn "CLI not available for provider"
                                {:provider provider
                                 :session-id claude-session-id
                                 :error (:error cli-validation-error)})
                      (http/send! channel
                                  (generate-json
                                   {:type :error
                                    :message (:error cli-validation-error)
                                    :session-id claude-session-id})))
                    (do
                      (log/info "Received prompt"
                                {:text (subs prompt-text 0 (min 50 (count prompt-text)))
                                 :new-session-id new-session-id
                                 :resume-session-id resume-session-id
                                 :working-directory working-dir
                                 :provider provider
                                 :explicit-provider explicit-provider
                                 :in-recipe (some? orch-state)})

                      ;; Send immediate acknowledgment
                      (http/send! channel
                                  (generate-json
                                   {:type :ack
                                    :message "Processing prompt..."}))

                      ;; For new sessions: register channel so we can send session_ready when file is created
                      ;; Filesystem watcher will send session_ready once the provider creates the file
                      (when new-session-id
                        (log/info "New session detected, registering for session_ready" {:session-id new-session-id})
                        (swap! pending-new-sessions assoc new-session-id channel))

                      ;; Send available commands for this session's working directory.
                      ;; New sessions use the caller-supplied working-dir; resumed
                      ;; sessions pull it from the session index.
                      (let [session-workdir (if new-session-id
                                              working-dir
                                              (:working-directory session-metadata))]
                        (send-available-commands! channel session-workdir))

                      ;; Dispatch to tmux. start-window! can block up to the
                      ;; wait-for-ready timeout (20s by default) for TUI readiness,
                      ;; so run off-thread to keep the ack fast and avoid blocking
                      ;; other messages on this channel.
                      ;;
                      ;; The dispatch is serialized against compact_session via
                      ;; repl/compaction-dispatch-lock so a compaction arriving
                      ;; between this handler's is-compaction-locked? check and
                      ;; the tmux call cannot cause the provider to be respawned
                      ;; while `claude --compact` is rewriting the JSONL (see
                      ;; tmux-untethered-22g). The re-check inside the lock is
                      ;; the one that actually matters: by holding the lock we
                      ;; know @compaction-locks cannot flip under us.
                      (future
                        (try
                          (locking repl/compaction-dispatch-lock
                            (if (repl/is-compaction-locked? claude-session-id)
                              (do
                                (log/info "Prompt dispatch aborted: compaction started after ack"
                                          {:session-id claude-session-id})
                                (send-to-client! channel
                                                 {:type :error
                                                  :session-id claude-session-id
                                                  :message "Compaction in progress for this session; retry once it completes"}))
                              (if new-session-id
                                (tmux/start-window!
                                 {:session-uuid new-session-id
                                  :session-name (:name session-metadata)
                                  :provider provider
                                  :workdir working-dir
                                  :initial-prompt final-prompt-text
                                  :resume? false
                                  :system-prompt system-prompt})
                                (tmux/deliver! resume-session-id final-prompt-text))))
                          (catch Exception e
                            (log/error e "Failed to dispatch prompt via tmux"
                                       {:session-id claude-session-id
                                        :provider provider
                                        :new-session? (some? new-session-id)})
                            (send-to-client! channel
                                             {:type :error
                                              :message (str "Failed to dispatch prompt: " (.getMessage e))
                                              :session-id claude-session-id})))))))))

            "set_max_message_size"
            (let [size-kb (:size-kb data)]
              (if-not (and size-kb (pos-int? size-kb))
                (http/send! channel
                            (generate-json
                             {:type :error
                              :message "size_kb (positive integer) required in set_max_message_size message"}))
                (do
                  (log/info "Max message size set" {:size-kb size-kb})
                  (swap! connected-clients update channel assoc :max-message-size-kb size-kb)
                  (send-to-client! channel {:type :ack :message (str "Max message size set to " size-kb " KB")}))))

            "message-ack"
            (let [message-id (:message-id data)]
              (log/debug "Message acknowledged" {:message-id message-id}))

            "compact_session"
            (let [session-id (:session-id data)]
              (if-not session-id
                (http/send! channel
                            (generate-json
                             {:type :error
                              :message "session_id required in compact_session message"}))
                ;; Acquiring the compaction lock, killing the live tmux window,
                ;; and clearing it from live-windows must be atomic w.r.t. the
                ;; prompt-dispatch path — otherwise a prompt's future running
                ;; between the acquire and the kill could respawn the provider
                ;; concurrently with `claude --compact` (tmux-untethered-22g).
                ;; Broadcasting the aborted turn_complete and spawning the
                ;; async compact call happen after the lock is released.
                (let [{:keys [acquired? killed-live-window?]}
                      (locking repl/compaction-dispatch-lock
                        (if-not (repl/acquire-compaction-lock! session-id)
                          {:acquired? false}
                          (let [live-window (get @tmux/live-windows session-id)]
                            (when live-window
                              (log/info "Killing live tmux window before compaction"
                                        {:session-id session-id})
                              (try
                                (tmux/kill-window! (:tmux-session live-window) (:tmux-window live-window))
                                (catch Exception e
                                  (log/warn e "tmux kill-window failed before compaction; proceeding"
                                            {:session-id session-id})))
                              (swap! tmux/live-windows dissoc session-id))
                            {:acquired? true :killed-live-window? (some? live-window)})))]
                  (if-not acquired?
                    (do
                      (log/info "Compaction already in progress" {:session-id session-id})
                      (send-to-client! channel
                                       {:type :compaction-error
                                        :session-id session-id
                                        :error "Compaction already in progress"}))
                    (do
                      ;; `claude --compact` is a one-shot CLI writing to the JSONL,
                      ;; so any live tmux window for this session must be killed
                      ;; first to prevent interleaved writes. Synthesize an aborted
                      ;; turn_complete for subscribers so their processing indicator
                      ;; unlocks (the JSONL watcher won't emit a natural marker).
                      (when killed-live-window?
                        (doseq [[subscriber-channel client-info] @connected-clients]
                          (let [subscribed (or (:subscribed-sessions client-info) #{})]
                            (when (and (contains? subscribed session-id)
                                       (not (is-session-deleted-for-client? subscriber-channel session-id)))
                              (send-to-client! subscriber-channel
                                               {:type :turn-complete
                                                :session-id session-id
                                                :aborted true})))))
                      (log/info "Compacting session" {:session-id session-id})
                      (async/go
                        (try
                          (let [result (claude/compact-session session-id)]
                            (if (:success result)
                              (do
                                (log/info "Session compaction successful" {:session-id session-id})
                                (send-to-client! channel
                                                 {:type :compaction-complete
                                                  :session-id session-id}))
                              (do
                                (log/error "Session compaction failed" {:session-id session-id :error (:error result)})
                                (send-to-client! channel
                                                 {:type :compaction-error
                                                  :session-id session-id
                                                  :error (:error result)}))))
                          (catch Exception e
                            (log/error e "Unexpected error during compaction" {:session-id session-id})
                            (send-to-client! channel
                                             {:type :compaction-error
                                              :session-id session-id
                                              :error (str "Compaction failed: " (ex-message e))}))
                          (finally
                            (repl/release-compaction-lock! session-id)))))))))

            "kill_session"
            (let [session-id (:session-id data)]
              (if-not session-id
                (http/send! channel
                            (generate-json
                             {:type :error
                              :message "session_id required in kill_session message"}))
                ;; Under tmux, provider CLI lifecycle is owned by tmux — we kill the
                ;; window rather than a tracked Process. The JSONL watcher won't see
                ;; a turn-complete marker (the process died mid-turn), so we synthesize
                ;; a turn_complete with aborted:true to unblock the iOS UI.
                (let [live-window (get @tmux/live-windows session-id)]
                  (log/info "Kill session requested"
                            {:session-id session-id
                             :live-window? (boolean live-window)})
                  (when live-window
                    (try
                      (tmux/kill-window! (:tmux-session live-window) (:tmux-window live-window))
                      (catch Exception e
                        (log/warn e "tmux kill-window failed; proceeding with cleanup"
                                  {:session-id session-id})))
                    (swap! tmux/live-windows dissoc session-id)
                    ;; Broadcast aborted turn_complete to every subscriber so their
                    ;; processing-indicator unlocks even though the JSONL watcher
                    ;; will never emit a natural terminal marker for this turn.
                    (doseq [[subscriber-channel client-info] @connected-clients]
                      (let [subscribed (or (:subscribed-sessions client-info) #{})]
                        (when (and (contains? subscribed session-id)
                                   (not (is-session-deleted-for-client? subscriber-channel session-id)))
                          (send-to-client! subscriber-channel
                                           {:type :turn-complete
                                            :session-id session-id
                                            :aborted true})))))
                  (send-to-client! channel
                                   {:type :session-killed
                                    :session-id session-id
                                    :message (if live-window
                                               "Session window killed"
                                               "No live window for session")}))))

            "infer_session_name"
            (let [session-id (:session-id data)
                  message-text (:message-text data)]

              (cond
                (not session-id)
                (send-to-client! channel
                                 {:type :infer-name-error
                                  :error "session_id required"})

                (not message-text)
                (send-to-client! channel
                                 {:type :infer-name-error
                                  :error "message_text required"})

                :else
                ;; Invoke Claude for name inference asynchronously
                (async/go
                  (let [result (claude/invoke-claude-for-name-inference message-text)]
                    (if (:success result)
                      (do
                        (log/info "Inferred session name"
                                  {:session-id session-id
                                   :name (:name result)})
                        (send-to-client! channel
                                         {:type :session-name-inferred
                                          :session-id session-id
                                          :name (:name result)}))
                      (send-to-client! channel
                                       {:type :infer-name-error
                                        :session-id session-id
                                        :error (:error result)}))))))

            "create_worktree_session"
            (let [session-name (:session-name data)
                  parent-directory (:parent-directory data)]

              ;; 1. Validate inputs (also expands ~ in parent-directory)
              (let [validation (worktree/validate-worktree-creation session-name parent-directory)]
                (if-not (:valid validation)
                  (do
                    (log/warn "Worktree creation validation failed"
                              {:session-name session-name
                               :parent-directory parent-directory
                               :error (:error validation)
                               :error-type (:error-type validation)})
                    (send-to-client! channel
                                     {:type :worktree-session-error
                                      :success false
                                      :error (:error validation)
                                      :error-type (:error-type validation)}))

                  ;; Use expanded directory from validation for all subsequent steps
                  (let [expanded-dir (:expanded-directory validation)

                        ;; 2. Compute paths (using expanded directory)
                        paths (worktree/compute-worktree-paths session-name expanded-dir)
                        {:keys [sanitized-name branch-name worktree-path]} paths

                        ;; 3. Validate paths
                        path-validation (worktree/validate-worktree-paths paths expanded-dir)]

                    (if-not (:valid path-validation)
                      (do
                        (log/warn "Worktree path validation failed"
                                  {:session-name session-name
                                   :parent-directory expanded-dir
                                   :error (:error path-validation)
                                   :error-type (:error-type path-validation)
                                   :details (:details path-validation)})
                        (send-to-client! channel
                                         {:type :worktree-session-error
                                          :success false
                                          :error (:error path-validation)
                                          :error-type (:error-type path-validation)
                                          :details (:details path-validation)}))

                      ;; 4. Execute worktree creation sequence
                      (let [session-id (str (java.util.UUID/randomUUID))]
                        (log/info "Creating worktree session"
                                  {:session-name session-name
                                   :parent-directory expanded-dir
                                   :branch-name branch-name
                                   :worktree-path worktree-path
                                   :session-id session-id})

                        ;; Step 4a: Create git worktree
                        (let [git-result (worktree/create-worktree! expanded-dir branch-name worktree-path)]
                          (if-not (:success git-result)
                            (do
                              (log/error "Git worktree creation failed"
                                         {:error (:error git-result)
                                          :stderr (:stderr git-result)})
                              (send-to-client! channel
                                               {:type :worktree-session-error
                                                :success false
                                                :error (:error git-result)
                                                :error-type :git-failed
                                                :details {:step "git_worktree_add"
                                                          :stderr (:stderr git-result)}}))

                            ;; Step 4b: Initialize local Beads database for worktree isolation
                            (let [bd-result (env/ensure-beads-local! worktree-path sanitized-name)]
                              (if-not (:success bd-result)
                                (do
                                  (log/error "Beads initialization failed for worktree"
                                             {:error (:error bd-result)
                                              :worktree-path worktree-path})
                                  (send-to-client! channel
                                                   {:type :worktree-session-error
                                                    :success false
                                                    :error (:error bd-result)
                                                    :error-type :beads-failed
                                                    :details {:step "bd_init_local"}}))

                                ;; Step 4c: Invoke Claude Code
                                (let [prompt (worktree/format-worktree-prompt session-name worktree-path
                                                                              expanded-dir branch-name)]
                                  (claude/invoke-claude-async
                                   prompt
                                   (fn [response]
                                     (if (:success response)
                                       (send-to-client! channel
                                                        {:type :worktree-session-created
                                                         :success true
                                                         :session-id (:session-id response)
                                                         :worktree-path worktree-path
                                                         :branch-name branch-name})
                                       (do
                                         (log/error "Claude invocation failed for worktree session"
                                                    {:error (:error response)})
                                         (send-to-client! channel
                                                          {:type :worktree-session-error
                                                           :success false
                                                           :error (:error response)
                                                           :error-type :claude-failed}))))
                                   :new-session-id session-id
                                   :model "haiku"
                                   :working-directory worktree-path))))))))))))

            "execute_command"
            (let [command-id (:command-id data)
                  working-directory (:working-directory data)]
              (cond
                (not command-id)
                (send-to-client! channel
                                 {:type :error
                                  :message "command_id required in execute_command message"})

                (not working-directory)
                (send-to-client! channel
                                 {:type :error
                                  :message "working_directory required in execute_command message"})

                :else
                (let [shell-command (commands/resolve-command-id command-id)
                      command-session-id (commands/generate-command-session-id)]
                  ;; Create history entry
                  (cmd-history/create-session-entry! command-session-id
                                                     command-id
                                                     shell-command
                                                     working-directory)
                  ;; Spawn process with callbacks
                  (let [result (commands/spawn-process
                                shell-command
                                working-directory
                                command-session-id
                                ;; Output callback - send each line to client
                                (fn [{:keys [stream text]}]
                                  (send-to-client! channel
                                                   {:type :command-output
                                                    :command-session-id command-session-id
                                                    :stream stream
                                                    :text text}))
                                ;; Complete callback - send completion message and update history
                                (fn [{:keys [exit-code duration-ms]}]
                                  (cmd-history/complete-session! command-session-id exit-code duration-ms)
                                  (send-to-client! channel
                                                   {:type :command-complete
                                                    :command-session-id command-session-id
                                                    :exit-code exit-code
                                                    :duration-ms duration-ms})))]
                    (if (:success result)
                      (send-to-client! channel
                                       {:type :command-started
                                        :command-session-id command-session-id
                                        :command-id command-id
                                        :shell-command shell-command})
                      (send-to-client! channel
                                       {:type :command-error
                                        :command-id command-id
                                        :error (:error result)}))))))

            "get_command_history"
            (let [working-dir (:working-directory data)
                  limit (or (:limit data) 50)
                  sessions (if working-dir
                             (cmd-history/get-command-history :working-directory working-dir :limit limit)
                             (cmd-history/get-command-history :limit limit))]
              (send-to-client! channel
                               {:type :command-history
                                :sessions sessions
                                :limit limit}))

            "get_command_output"
            (let [command-session-id (:command-session-id data)]
              (if-not command-session-id
                (send-to-client! channel
                                 {:type :error
                                  :message "command_session_id required in get_command_output message"})
                (if-let [metadata (cmd-history/get-session-metadata command-session-id)]
                  (let [output (or (cmd-history/read-output-file command-session-id) "")
                        output-size (count output)
                        max-size (* 10 1024 1024) ; 10MB limit
                        truncated? (> output-size max-size)
                        final-output (if truncated?
                                       (do
                                         (log/warn "Output exceeds 10MB limit, truncating"
                                                   {:command-session-id command-session-id
                                                    :actual-size output-size
                                                    :max-size max-size})
                                         (subs output 0 max-size))
                                       output)]
                    (send-to-client! channel
                                     {:type :command-output-full
                                      :command-session-id command-session-id
                                      :output final-output
                                      :exit-code (:exit-code metadata)
                                      :timestamp (:timestamp metadata)
                                      :duration-ms (:duration-ms metadata)
                                      :command-id (:command-id metadata)
                                      :shell-command (:shell-command metadata)
                                      :working-directory (:working-directory metadata)}))
                  (send-to-client! channel
                                   {:type :error
                                    :message (str "Command output not found: " command-session-id)}))))

            "upload_file"
            (let [filename (:filename data)
                  content (:content data)
                  storage-location (:storage-location data)]
              (if-not (and filename content storage-location)
                (send-to-client! channel
                                 {:type :error
                                  :message "filename, content, and storage_location required in upload_file message"})
                (try
                  (let [result (resources/upload-file! storage-location filename content)]
                    (log/info "File uploaded successfully"
                              {:filename (:filename result)
                               :path (:path result)
                               :size (:size result)})
                    (send-to-client! channel
                                     {:type :file-uploaded
                                      :filename (:filename result)
                                      :path (:path result)
                                      :size (:size result)
                                      :timestamp (:timestamp result)}))
                  (catch Exception e
                    (log/error e "Failed to upload file" {:filename filename})
                    (send-to-client! channel
                                     {:type :error
                                      :message (str "Failed to upload file: " (ex-message e))})))))

            "list_resources"
            (let [storage-location (:storage-location data)]
              (if-not storage-location
                (send-to-client! channel
                                 {:type :error
                                  :message "storage_location required in list_resources message"})
                (try
                  (let [resource-list (resources/list-resources storage-location)]
                    (log/info "Listing resources"
                              {:storage-location storage-location
                               :count (count resource-list)})
                    (send-to-client! channel
                                     {:type :resources-list
                                      :resources resource-list
                                      :storage-location storage-location}))
                  (catch Exception e
                    (log/error e "Failed to list resources" {:storage-location storage-location})
                    (send-to-client! channel
                                     {:type :error
                                      :message (str "Failed to list resources: " (ex-message e))})))))

            "delete_resource"
            (let [filename (:filename data)
                  storage-location (:storage-location data)]
              (if-not (and filename storage-location)
                (send-to-client! channel
                                 {:type :error
                                  :message "filename and storage_location required in delete_resource message"})
                (try
                  (let [result (resources/delete-resource! storage-location filename)]
                    (log/info "Resource deleted successfully"
                              {:filename filename
                               :path (:path result)})
                    (send-to-client! channel
                                     {:type :resource-deleted
                                      :filename filename
                                      :path (:path result)}))
                  (catch Exception e
                    (log/error e "Failed to delete resource" {:filename filename})
                    (send-to-client! channel
                                     {:type :error
                                      :message (str "Failed to delete resource: " (ex-message e))})))))

            "start_recipe"
            (let [recipe-id (keyword (:recipe-id data))
                  session-id (:session-id data)
                  working-directory (:working-directory data)
                  is-new-session? (not (session-exists? session-id))
                   ;; Extract optional provider field (defaults to session's provider or Claude)
                  message-provider (when-let [p (:provider data)] (keyword p))
                  provider (or message-provider
                               (when-not is-new-session?
                                 (:provider (repl/get-session-metadata session-id)))
                               :claude)]
              (cond
                (not session-id)
                (send-to-client! channel
                                 {:type :error
                                  :message "session_id required in start_recipe message"})

                (not recipe-id)
                (send-to-client! channel
                                 {:type :error
                                  :message "recipe_id required in start_recipe message"})

                ;; New validation: working_directory required for new sessions
                (and is-new-session? (str/blank? working-directory))
                (do
                  (log/warn "New session recipe start rejected: missing working_directory"
                            {:session-id session-id :recipe-id recipe-id})
                  (send-to-client! channel
                                   {:type :error
                                    :message "working_directory required for new session"
                                    :session-id session-id}))

                :else
                (if-let [orch-state (start-recipe-for-session session-id recipe-id is-new-session? :provider provider)]
                  (let [recipe (recipes/get-recipe recipe-id)]
                    (log/info "Recipe started" {:recipe-id recipe-id :session-id session-id})
                    (send-to-client! channel
                                     {:type :recipe-started
                                      :recipe-id recipe-id
                                      :recipe-label (:label recipe)
                                      :session-id session-id
                                      :current-step (:current-step orch-state)
                                      :step-count (:step-count orch-state)})

                    ;; Automatically start the orchestration loop
                    (let [session-metadata (repl/get-session-metadata session-id)
                          working-dir (or working-directory
                                          (:working-directory session-metadata))]
                      (log/info "Starting recipe orchestration loop"
                                {:session-id session-id
                                 :recipe-id recipe-id
                                 :step (:current-step orch-state)
                                 :working-directory working-dir})
                      (send-to-client! channel
                                       {:type :ack
                                        :message "Starting recipe..."})
                      (execute-recipe-step channel session-id working-dir
                                           orch-state recipe)))
                  (send-to-client! channel
                                   {:type :error
                                    :message (str "Recipe not found: " recipe-id)}))))

            "exit_recipe"
            (let [session-id (:session-id data)]
              (if-not session-id
                (send-to-client! channel
                                 {:type :error
                                  :message "session_id required in exit_recipe message"})
                (do
                  (exit-recipe-for-session session-id "user-requested")
                  (log/info "Recipe exited" {:session-id session-id})
                  (send-to-client! channel
                                   {:type :recipe-exited
                                    :session-id session-id
                                    :reason "user-requested"}))))

            "refresh_sessions"
            ;; Client requests updated session list without re-authentication
            (let [limit (or (:recent-sessions-limit data) 5)]
              (log/info "Client requested session list refresh" {:limit limit})
              ;; Send session list (same logic as in connect handler)
              (let [all-sessions (repl/get-all-sessions)
                    recent-sessions (->> all-sessions
                                         (filter #(pos? (or (:message-count %) 0)))
                                         (sort-by :last-modified >)
                                         (take 50)
                                         (mapv #(select-keys % [:session-id :name :working-directory
                                                                :last-modified :message-count :provider])))
                    total-non-empty (count (filter #(pos? (or (:message-count %) 0)) all-sessions))]
                (log/info "Sending refreshed session list" {:count (count recent-sessions) :total total-non-empty})
                (send-to-client! channel
                                 {:type :session-list
                                  :sessions recent-sessions
                                  :total-count total-non-empty}))
              ;; Send recent sessions
              (send-recent-sessions! channel limit))

            "get_available_recipes"
            (do
              (log/info "Sending available recipes")
              (send-to-client! channel
                               {:type :available-recipes
                                :recipes (get-available-recipes-list)}))

            "supervisor_message"
            (let [text (:text data)]
              (if-not text
                (send-to-client! channel
                                 {:type :error
                                  :message "text required in supervisor_message"})
                (do
                  (log/info "Supervisor message received" {:text (subs text 0 (min 80 (count text)))})
                  ;; Run supervisor turn asynchronously to avoid blocking WebSocket handler
                  (async/go
                    (supervisor/handle-supervisor-message
                     text
                     (fn [msg] (send-to-client! channel msg)))))))

            "canvas_action"
            (let [callback-id (:callback-id data)
                  action (:action data)]
              (if-not (and callback-id action)
                (send-to-client! channel
                                 {:type :error
                                  :message "callback_id and action required in canvas_action message"})
                (do
                  (log/info "Canvas action received" {:callback-id callback-id :action action})
                  (let [result-text (supervisor/handle-canvas-action
                                     {:callback-id callback-id :action action})]
                    ;; If a pending action was found, inject context into next supervisor turn
                    (when result-text
                      (async/go
                        (supervisor/handle-supervisor-message
                         result-text
                         (fn [msg] (send-to-client! channel msg)))))))))

            ;; Unknown message type
            (do
              (log/warn "Unknown message type" {:type msg-type})
              (http/send! channel
                          (generate-json
                           {:type :error
                            :message (str "Unknown message type: " msg-type)}))))))) ;; closes inner case, if-not, cond, let

    (catch Exception e
      (log/error e "Error handling message")
      (http/send! channel
                  (generate-json
                   {:type :error
                    :message (str "Error processing message: " (ex-message e))})))))

;; HTTP Upload handler
(defn handle-http-upload
  "Handle HTTP POST /upload requests for synchronous file uploads from share extension.
   Requires Bearer token authentication via Authorization header.
   Expects JSON body with fields: filename, content (base64), storage_location"
  [req channel]
  (let [provided-key (extract-bearer-token req)
        stored-key @api-key]
    ;; Authenticate first
    (cond
      (nil? provided-key)
      (do
        (log/warn "HTTP auth failed" {:reason "Missing Authorization header"})
        (http/send! channel
                    {:status 401
                     :headers {"Content-Type" "application/json"
                               "WWW-Authenticate" "Bearer realm=\"voice-code\""}
                     :body (generate-json
                            {:success false
                             :error "Authentication failed"})}))

      (not (auth/constant-time-equals? stored-key provided-key))
      (do
        (log/warn "HTTP auth failed" {:reason "Invalid API key"})
        (http/send! channel
                    {:status 401
                     :headers {"Content-Type" "application/json"
                               "WWW-Authenticate" "Bearer realm=\"voice-code\""}
                     :body (generate-json
                            {:success false
                             :error "Authentication failed"})}))

      :else
      ;; Authenticated - process the upload
      (try
        (let [body (slurp (:body req))
              data (parse-json body)
              filename (:filename data)
              content (:content data)
              storage-location (:storage-location data)]

          (if-not (and filename content storage-location)
            (http/send! channel
                        {:status 400
                         :headers {"Content-Type" "application/json"}
                         :body (generate-json
                                {:success false
                                 :error "filename, content, and storage_location are required"})})
            (try
              (let [result (resources/upload-file! storage-location filename content)
                    absolute-path (str (resources/expand-path storage-location) "/" (:path result))]
                (log/info "HTTP upload successful"
                          {:filename (:filename result)
                           :size (:size result)
                           :path absolute-path})
                (http/send! channel
                            {:status 200
                             :headers {"Content-Type" "application/json"}
                             :body (generate-json
                                    {:success true
                                     :filename (:filename result)
                                     :path absolute-path
                                     :relative-path (:path result)
                                     :size (:size result)
                                     :timestamp (.toString (:timestamp result))})}))
              (catch IllegalArgumentException e
                (log/error "Invalid base64 content in HTTP upload" {:filename filename})
                (http/send! channel
                            {:status 400
                             :headers {"Content-Type" "application/json"}
                             :body (generate-json
                                    {:success false
                                     :error "Invalid file content encoding"})}))
              (catch clojure.lang.ExceptionInfo e
                (let [data (ex-data e)]
                  (log/error e "HTTP upload failed" data)
                  (http/send! channel
                              {:status (if (= "Resource not found" (ex-message e)) 404 400)
                               :headers {"Content-Type" "application/json"}
                               :body (generate-json
                                      {:success false
                                       :error (ex-message e)
                                       :details data})})))
              (catch Exception e
                (log/error e "Unexpected error in HTTP upload" {:filename filename})
                (http/send! channel
                            {:status 500
                             :headers {"Content-Type" "application/json"}
                             :body (generate-json
                                    {:success false
                                     :error (str "Failed to upload file: " (ex-message e))})})))))
        (catch Exception e
          (log/error e "Error parsing HTTP upload request")
          (http/send! channel
                      {:status 400
                       :headers {"Content-Type" "application/json"}
                       :body (generate-json
                              {:success false
                               :error (str "Invalid request: " (ex-message e))})}))))))

;; WebSocket handler
(defn websocket-handler
  "Handle WebSocket connections and HTTP upload requests"
  [request]
  ;; Check for HTTP POST to /upload BEFORE with-channel
  (if (and (= :post (:request-method request))
           (= "/upload" (:uri request)))
    ;; Handle synchronous HTTP upload
    (http/with-channel request channel
      (handle-http-upload request channel)
      ;; For synchronous response, we don't keep the channel open
      (http/close channel))

    ;; Handle WebSocket connections
    (http/with-channel request channel
      (if (http/websocket? channel)
        (do
          (log/info "WebSocket connection established" {:remote-addr (:remote-addr request)})

          ;; Send hello message with auth_version. The advertised :version is
          ;; the server's *preferred* (max-cap) protocol version per §3.2 of
          ;; voice-code-sync-kafka-redesign-2026-05-10.md — the client may
          ;; still negotiate lower via connect.protocol_version, and the
          ;; resulting per-channel value is echoed back in the :connected
          ;; reply (negotiated_protocol_version).
          (http/send! channel
                      (generate-json
                       {:type :hello
                        :message "Welcome to voice-code backend"
                        :version (message-stream-version-string @server-max-protocol-version)
                        :auth-version 1
                        :instructions "Send connect message with api_key"}))

          ;; Handle incoming messages
          (http/on-receive channel
                           (fn [msg]
                             (handle-message channel msg)))

          ;; Handle connection close
          (http/on-close channel
                         (fn [status]
                           (log/info "WebSocket connection closed" {:status status})
                           (unregister-channel! channel))))

        ;; Not a WebSocket request and not /upload
        (http/send! channel
                    {:status 400
                     :headers {"Content-Type" "text/plain"}
                     :body "This endpoint requires WebSocket connection"})))))

(defn register-supervisor-tool-handlers!
  "Register external tool handlers that bridge supervisor tools to server
   infrastructure (claude.clj, commands.clj, etc.)."
  []
  (supervisor/register-tool-handler!
   "dispatch_prompt"
   (fn [input]
     (let [text (:text input)
           session-id (:session-id input)
           working-dir (:working-directory input)]
       (if-not text
         (pr-str {:status "error" :message "text is required"})
         (let [new-session-id (when-not session-id (str (java.util.UUID/randomUUID)))
               claude-session-id (or session-id new-session-id)]
           (claude/invoke-claude-async
            text
            (fn [response]
              (let [client-channel (:client-channel @supervisor/supervisor-state)]
                (if (:success response)
                  (do
                    (when client-channel
                      (send-to-client! client-channel
                                       {:type :turn-complete
                                        :session-id claude-session-id}))
                    (supervisor/on-worker-complete
                     claude-session-id 0
                     (fn [msg]
                       (when client-channel
                         (send-to-client! client-channel msg)))))
                  (do
                    (when client-channel
                      (send-to-client! client-channel
                                       {:type :error
                                        :message (:error response)
                                        :session-id claude-session-id}))
                    (supervisor/on-worker-complete
                     claude-session-id 1
                     (fn [msg]
                       (when client-channel
                         (send-to-client! client-channel msg))))))))
            :new-session-id new-session-id
            :resume-session-id session-id
            :working-directory working-dir
            :timeout-ms 86400000)
           (pr-str {:status "dispatched"
                    :session-id claude-session-id
                    :message "Prompt dispatched to Claude Code session"}))))))

  (supervisor/register-tool-handler!
   "execute_command"
   (fn [input send-to-client-fn!]
     (let [command-id (:command-id input)
           shell-command (:shell-command input)
           working-dir (:working-directory input)
           resolved-cmd (or shell-command
                            (when command-id (commands/resolve-command-id command-id)))]
       (if-not resolved-cmd
         (pr-str {:status "error" :message "command_id or shell_command required"})
         (let [cmd-session-id (commands/generate-command-session-id)]
           (cmd-history/create-session-entry! cmd-session-id
                                              (or command-id "custom")
                                              resolved-cmd
                                              working-dir)
           (let [result (commands/spawn-process
                         resolved-cmd working-dir cmd-session-id
                         (fn [{:keys [stream text]}]
                           (send-to-client-fn!
                            {:type :command-output
                             :command-session-id cmd-session-id
                             :stream stream
                             :text text}))
                         (fn [{:keys [exit-code duration-ms]}]
                           (cmd-history/complete-session! cmd-session-id exit-code duration-ms)
                           (send-to-client-fn!
                            {:type :command-complete
                             :command-session-id cmd-session-id
                             :exit-code exit-code
                             :duration-ms duration-ms})))]
             (when (:success result)
               (send-to-client-fn!
                {:type :command-started
                 :command-session-id cmd-session-id
                 :command-id (or command-id "custom")
                 :shell-command resolved-cmd}))
             (pr-str {:status (if (:success result) "started" "error")
                      :command-session-id cmd-session-id
                      :shell-command resolved-cmd})))))))

  (supervisor/register-tool-handler!
   "compact_session"
   (fn [input]
     (let [session-id (:session-id input)]
       (if-not session-id
         (pr-str {:status "error" :message "session_id required"})
         (if-not (repl/acquire-compaction-lock! session-id)
           (pr-str {:status "error" :message "Compaction already in progress"})
           (try
             (let [result (claude/compact-session session-id)]
               (if (:success result)
                 (pr-str {:status "compacted" :session-id session-id})
                 (pr-str {:status "error" :message (:error result)})))
             (finally
               (repl/release-compaction-lock! session-id))))))))

  (supervisor/register-tool-handler!
   "run_recipe"
   (fn [input]
     (let [recipe-id (keyword (:recipe-id input))
           session-id (:session-id input)]
       (if-not recipe-id
         (pr-str {:status "error" :message "recipe_id required"})
         (pr-str {:status "error"
                  :message "run_recipe via supervisor not yet implemented"
                  :recipe-id recipe-id
                  :session-id session-id})))))

  (log/info "Supervisor tool handlers registered"))

(defn check-tmux-available!
  "Verify tmux is installed and executable. Returns the version string on success.
   On failure, logs a diagnostic, prints a message, and calls (exit-fn 1).
   In production the default exit-fn is System/exit, which does not return;
   callers should not assume the function returns after a failure."
  ([]
   (check-tmux-available! #(System/exit %)))
  ([exit-fn]
   (let [{:keys [exit out err]} (shell/sh "tmux" "-V")]
     (if (zero? exit)
       (str/trim out)
       (do
         (log/error "tmux is not available; voice-code requires tmux to run provider CLIs"
                    {:exit exit :out out :err err})
         (println "ERROR: tmux not found or not executable. Install tmux and ensure it is on PATH.")
         (exit-fn 1))))))

(defn -main
  "Start the WebSocket server"
  [& args]
  (let [config (load-config)
        port (get-in config [:server :port] 8080)
        host (get-in config [:server :host] "0.0.0.0")
        default-dir (get-in config [:claude :default-working-directory])
        stream-version (coerce-message-stream-version (:message-stream-version config))
        _ (reset! message-stream-version stream-version)
        _ (log/info "Message stream version" {:version stream-version})
        startup-cap (apply-startup-server-max!)
        _ (log/info "Negotiation ceiling" {:server-max startup-cap})
        ;; Daemon thread so the sweeper never prevents JVM exit.
        ;; Captured here (not inside a nested let) so the shutdown hook can
        ;; call .shutdown() for a clean drain.
        sweeper-exec (Executors/newSingleThreadScheduledExecutor
                      (reify java.util.concurrent.ThreadFactory
                        (newThread [_ r]
                          (doto (Thread. r "vc-sweeper")
                            (.setDaemon true)))))]

    ;; Initialize API key authentication
    (log/info "Initializing API key authentication")
    (let [key (auth/ensure-key-file!)]
      (reset! api-key key)
      (log/info "API key loaded successfully")
      (println "✓ API key ready. Run 'make show-key' to display."))

    ;; Register supervisor tool handlers
    (register-supervisor-tool-handlers!)

    ;; Verify tmux is available — exit-on-missing (no fallback path)
    (check-tmux-available!)

    ;; Initialize replication system
    (log/info "Initializing session replication system")
    (repl/initialize-index!)

    ;; One-shot seq migration (gated on :message-stream-version floor —
    ;; fires for :v0.4.0 and :v0.5.0; skipped on :v0.3.0 rollback).
    ;; Idempotent on subsequent boots — skips sessions whose :next-seq has
    ;; already been computed.
    ;;
    ;; NOTE: this call site intentionally STAYS on the global atom rather
    ;; than (channel-protocol channel). It runs inside start-replication-system!
    ;; before any client has connected, so there is no channel to dispatch on.
    ;; The §3.2 per-channel migration applies only to per-connection sites
    ;; (subscribe handler, push fan-out); the startup migration is a
    ;; whole-server pre-flight that backfills :next-seq for the v0.4.0+ arms.
    (when (seq-migration-enabled?)
      (repl/migrate-session-seqs!))

    ;; v0.5.0 offset protocol: seed `line-counts` from on-disk JSONL files so
    ;; the watcher's stamp-offsets tick has a `pre-line-count` for each session
    ;; from the very first firing. Runs unconditionally — the atom is populated
    ;; whether or not any client negotiates the v0.5.0 push path; the data is
    ;; cheap to maintain and unused under v0.4.0 rollback. Idempotent on
    ;; subsequent boots (overwrites with the current on-disk count).
    (repl/populate-line-counts!)

    ;; Rebuild live-windows from any tmux sessions that survived a prior restart
    (log/info "Scanning for existing tmux windows")
    (tmux/scan-existing-windows!)

    ;; Schedule the sweeper to kill windows idle > sweeper-max-age-days
    (let [interval-ms (* tmux/sweeper-interval-minutes 60 1000)]
      (.scheduleAtFixedRate
       sweeper-exec
       (fn []
         (try (tmux/sweep!)
              (catch Exception e
                (log/error e "Sweeper error"))))
       interval-ms
       interval-ms
       TimeUnit/MILLISECONDS))

    ;; Start filesystem watcher
    (try
      (repl/start-watcher!
       :on-session-created on-session-created
       :on-session-updated broadcast-session-history!
       :on-session-updated-v5 push-to-subscribers!
       :on-session-deleted on-session-deleted
       :on-turn-complete on-turn-complete)
      (log/info "Filesystem watcher started successfully")
      (catch Exception e
        (log/error e "Failed to start filesystem watcher")))

    (log/info "Starting voice-code server"
              {:port port
               :host host
               :default-working-directory default-dir})

    (let [server (http/run-server websocket-handler {:port port :ip host})]
      (reset! server-state server)

      ;; Add graceful shutdown hook
      (.addShutdownHook
       (Runtime/getRuntime)
       (Thread. (fn []
                  (log/info "Shutting down voice-code server gracefully")
                  ;; Stop sweeper so no new sweep starts after shutdown
                  (.shutdown sweeper-exec)
                  ;; Stop filesystem watcher
                  (repl/stop-watcher!)
                  ;; Save session index
                  (repl/save-index! @repl/session-index)
                  ;; Stop HTTP server with 100ms timeout
                  (when @server-state
                    (@server-state :timeout 100))
                  (log/info "Server shutdown complete"))))

      (println (format "✓ Voice-code WebSocket server running on ws://%s:%d" host port))
      (println "  Authentication: ENABLED")
      (when default-dir
        (println (format "  Default working directory: %s" default-dir)))
      (println "  Ready for connections. Press Ctrl+C to stop.")

      ;; Keep main thread alive
      @(promise))))
