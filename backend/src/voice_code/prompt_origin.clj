(ns voice-code.prompt-origin
  "Attribution for human-role prompts that appear in provider session files.

   Every prompt the backend injects passes through a small, enumerable set of
   choke points — `tmux/deliver!` and `tmux/start-window!` (iOS/macOS sends,
   recipe steps, ghost prompts, `tmux-agent` CLI launches) and
   `claude/invoke-claude` (the supervisor's `dispatch_prompt`). Each records
   the text here just before it lands in the pane.

   A human-role prompt that then shows up in the transcript WITHOUT a matching
   record was typed at the keyboard, by the user, in the pane. That is the only
   way the backend can distinguish `the user went and talked to this agent`
   from `the supervisor drove it`, and it is what the iOS priority queue keys
   its admission on — see docs/design/priority-queue-revisit.md.

   Deliberate bias: on ANY ambiguity we claim the prompt as backend-injected.
   A false `injected` costs one missed queue entry, which the user fixes by
   sending one more prompt. A false `typed by the user` puts an agent nobody is
   waiting on into the queue — the exact failure this mechanism exists to
   prevent — and it does so silently and repeatedly."
  (:require [clojure.string :as str]
            [clojure.tools.logging :as log]))

(def injection-ttl-ms
  "How long an unmatched injection record stays eligible to absorb a human
   prompt. Generous because a nudge can sit in a busy pane for a while before
   the provider writes the turn, but bounded so a prompt that never landed (the
   window died, the CLI rejected it) cannot suppress a genuine keyboard prompt
   for the rest of the process's life."
  (* 10 60 1000))

(def ^:private max-pending-per-session
  "Backstop against unbounded growth if a session's injections are recorded but
   never claimed (a provider that stops writing transcripts, say). Oldest
   records are dropped first."
  32)

(defonce ^:private pending
  ;; session-id -> vector of {:text <normalized> :at <epoch-ms>}, oldest first.
  (atom {}))

(defn normalize
  "Whitespace-insensitive form used for matching. The pane round-trip
   (send-keys → provider → transcript) is not guaranteed to preserve line
   breaks or trailing space exactly, and none of those differences change
   whether the backend authored the prompt."
  [text]
  (-> (or text "")
      str/trim
      (str/replace #"\s+" " ")))

(defn- prune
  "Drop expired records and enforce the per-session cap. Oldest first."
  [records now]
  (let [live (vec (remove #(> (- now (:at %)) injection-ttl-ms) records))]
    (if (> (count live) max-pending-per-session)
      (vec (take-last max-pending-per-session live))
      live)))

(defn record-injected!
  "Note that the backend is about to deliver `text` to `session-id`. Called
   from the injection choke points, before the prompt reaches the pane, so the
   record is always in place by the time the transcript line appears."
  [session-id text]
  (when (and session-id (seq (normalize text)))
    (let [now (System/currentTimeMillis)]
      (swap! pending update session-id
             (fn [records]
               (conj (prune (or records []) now)
                     {:text (normalize text) :at now})))
      (log/debug "Recorded backend-injected prompt"
                 {:session-id session-id
                  :pending (count (get @pending session-id))}))))

(defn claim-injected!
  "True when `text` on `session-id` is attributable to the backend, consuming
   the record that explains it. False means the user typed it in the pane.

   Matching is by normalized text first. If nothing matches but the session
   still has an unexpired record outstanding, the oldest is consumed and the
   prompt is claimed anyway — that is the bias documented on this namespace:
   an injection we failed to text-match is far more likely than the user typing
   during the exact window an injection is in flight."
  [session-id text]
  (let [now (System/currentTimeMillis)
        wanted (normalize text)
        result (atom :typed)]
    (swap! pending update session-id
           (fn [records]
             (let [live (prune (or records []) now)
                   idx (first (keep-indexed (fn [i r] (when (= (:text r) wanted) i)) live))]
               (cond
                 idx
                 (do (reset! result :matched)
                     (vec (concat (subvec live 0 idx) (subvec live (inc idx)))))

                 (seq live)
                 (do (reset! result :absorbed)
                     (vec (rest live)))

                 :else
                 (do (reset! result :typed)
                     live)))))
    (when (= :absorbed @result)
      (log/info "Human prompt did not text-match an outstanding injection; claiming as backend-injected (see prompt-origin bias)"
                {:session-id session-id
                 :prompt-preview (subs wanted 0 (min 60 (count wanted)))
                 :remaining (count (get @pending session-id))}))
    (not= :typed @result)))

(defn pending-count
  "Number of unexpired outstanding injections for `session-id`. Diagnostics."
  [session-id]
  (count (prune (get @pending session-id []) (System/currentTimeMillis))))

(defn clear!
  "Forget every record for `session-id` (session deleted, window killed)."
  [session-id]
  (swap! pending dissoc session-id))

(defn reset-all!
  "Test seam."
  []
  (reset! pending {}))
