(ns voice-code.ghost
  "Ghost prompts: have a context-rich Claude session generate a prompt on a
   throwaway fork, then inject that prompt into the original session so the agent
   acts on it with no awareness it authored it. Claude-only.

   This namespace currently holds the pure building blocks of the primitive: the
   per-invocation nonce, the extraction sentinels, the one-line meta-prompt
   template, and prompt extraction. The fork lifecycle (one-shot-fork!,
   ghost-prompt!) is layered on top of these in a later step."
  (:require [clojure.string :as str]
            [voice-code.replication :as repl]))

(defn gen-nonce
  "Mint a per-invocation ghost nonce: \"gp-\" followed by 12 hex digits. The
   nonce is the single correlation key across the fork's window name, the fork's
   transcript discovery, and prompt extraction, so it must be unique per call."
  []
  (str "gp-" (subs (str/replace (str (java.util.UUID/randomUUID)) "-" "") 0 12)))

(defn begin-marker
  "Opening extraction sentinel for `nonce` (ASCII, on its own line in output)."
  [nonce]
  (str "===GHOST-BEGIN:" nonce "==="))

(defn end-marker
  "Closing extraction sentinel for `nonce` (ASCII, on its own line in output)."
  [nonce]
  (str "===GHOST-END:" nonce "==="))

(defn build-meta-prompt
  "Wrap the user's task in the ghost meta-prompt (one physical line for nudge
   delivery; the agent still emits multi-line output between the sentinels).
   Carries the durable `repl/ghost-fork-marker`, the per-invocation `nonce`, and
   both extraction sentinels. Internal whitespace in `task` (newlines, tabs) is
   collapsed to single spaces so the result is always a single physical line —
   a multi-line task would otherwise make the tmux nudge submit only its first
   line as the message."
  [task nonce]
  (let [task (str/replace (str/trim (str task)) #"\s+" " ")]
    (str "[" repl/ghost-fork-marker " " nonce "] "
         "Produce a prompt to be handed verbatim to a separate coding agent. "
         "The agent must: " task ". "
         "Output ONLY the prompt text, no preamble or commentary. "
         "Wrap it EXACTLY between these markers, each on its own line: "
         (begin-marker nonce) " (then the prompt on following lines) " (end-marker nonce))))

(defn extract-prompt
  "Return the trimmed prompt between the nonce sentinels in `assistant-text`, or
   nil if `assistant-text` is nil or the closing sentinel is absent. Uses the
   first BEGIN and the first END after it, so any preamble before BEGIN is
   ignored; a blank body yields nil."
  [assistant-text nonce]
  (when assistant-text
    (let [b (begin-marker nonce)
          e (end-marker nonce)
          bi (str/index-of assistant-text b)
          ei (when bi (str/index-of assistant-text e (+ bi (count b))))]
      (when (and bi ei)
        (let [p (str/trim (subs assistant-text (+ bi (count b)) ei))]
          (when-not (str/blank? p) p))))))
