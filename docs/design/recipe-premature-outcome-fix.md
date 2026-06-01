# Recipe Premature-Outcome Fix

> Code locations cited here (line numbers) are snapshots at authoring time; treat
> them as hints. Stable anchors are the function names:
> `find-json-block`/`extract-orchestration-outcome` in
> @backend/src/voice_code/orchestration.clj and `process-orchestration-response`
> in @backend/src/voice_code/server.clj.

## Overview

### Problem Statement

When an agent runs a recipe step, the orchestrator demands a JSON outcome block
(`{"outcome": "..."}`) at the end of the step. Two defects make it fire that
demand **prematurely** and even **abort the recipe** while the agent is still
legitimately working:

1. **The outcome is checked on a turn that isn't the final one.** A non-trivial
   step spans several agent turns (run tools → think → continue → emit outcome
   last). `process-orchestration-response` parses the outcome from the captured
   turn text; if there's no JSON it reminds on the first miss and **exits the
   recipe with `"orchestration-error"` on the second** — so two "still working"
   turns kill the run.
2. **The JSON detector is too narrow.** `find-json-block` scans only the **last
   5 lines** and requires a whole-line `{...}`. A turn that *did* emit the
   outcome is reported as "No JSON block found" if the JSON isn't among the final
   5 lines (trailing prose/blank lines) or is fenced / pretty-printed.

Observed live: every reminder during the design-doc recipe fired on a turn where
the agent had just run tools (edits, greps, `make build`) and had not yet written
the final JSON line.

### Goals

1. A turn in which the agent is still working (no outcome yet) does **not** abort
   the recipe and does not consume a hard failure.
2. The outcome is reliably detected wherever it appears in the response (anywhere
   in the text, fenced or bare, single- or multi-line).
3. The recipe still terminates deterministically on genuine, repeated failure to
   produce a valid outcome — never an infinite loop.
4. Existing valid responses continue to parse unchanged (no regressions).

### Non-goals

- Redesigning the recipe state machine or the step/transition model.
- Changing the recipe prompt format or the set of valid outcomes.
- The `AGENTS.md` `bd → br` cleanup (separate doc:
  @docs/design/agents-md-br-reference-cleanup.md).

## Background & Context

### Current State

The relevant code, all confirmed:

- `find-json-block` (@backend/src/voice_code/orchestration.clj:15) —
  `(take-last 5 lines)`, then returns the first trimmed line that both
  `starts-with "{"` and `ends-with "}"`, else `nil`.
- `extract-orchestration-outcome` (orchestration.clj:64) — `nil` block →
  `{:success false :error "No JSON block found in response"}`.
- `get-outcome-reminder-prompt` (orchestration.clj:97) — builds the
  "did not include the required JSON outcome block" reminder.
- `process-orchestration-response` (@backend/src/voice_code/server.clj:1029) —
  calls `extract-orchestration-outcome` on the turn's `response-text`. On
  failure: if `retry-count` is `0` → `:retry` with the reminder
  (server.clj:1097); otherwise → `exit-recipe-for-session ... "orchestration-error"`
  (server.clj:1111). So the effective budget is **one** reminder, then abort.
- `should-exit-recipe?` (orchestration.clj:167) — already bounds the run via
  `max-step-visits` (default 10) and `max-total-steps` (default 50).

The recipe driver in `server.clj` extracts the turn's text from the agent
transcript and calls `process-orchestration-response` (server.clj:~1289), once
per agent turn. The driver already reads the transcript filtered by role
(`(filter #(= "assistant" (:role %)) messages)`, server.clj:1141), so per-turn
metadata such as "did this turn contain tool calls" is available to it — which
makes the optional `:tool-use?` enhancement below feasible. (The exact end-of-turn
trigger wiring should still be confirmed against the running code during
implementation; the core fix does not depend on it.)

### Why Now

The premature reminders and recipe aborts were hit repeatedly while exercising
the design recipe. Diagnosis recorded in the conversation that produced this doc.

### Related Work

- @backend/test/voice_code/orchestration_test.clj — existing unit tests for
  `find-json-block` / `extract-orchestration-outcome` (cover only complete,
  well-formed single responses; they do not cover the 5-line-window miss).
- @backend/test/voice_code/orchestration_server_test.clj — server-level
  orchestration tests.

## Detailed Design

The fix has two independent parts plus one optional enhancement.

### Data Model

Orchestration state (`create-orchestration-state`, orchestration.clj:158) already
carries `:step-retry-counts {step -> n}`. No schema change is required; the retry
counter is simply compared against a higher, configurable cap instead of the
hard-coded `0`. Optionally, recipes may set:

```clojure
;; per-recipe config (optional; defaults applied when absent)
{:max-outcome-reminders 3   ; gentle reminders before declaring genuine failure
 ...}
```

No persisted/JSONL schema is affected (this is in-memory orchestration state).

### API Design

No external/HTTP API changes. Internal function contracts:

- `find-json-block` — unchanged signature `[text] -> string|nil`; broader matching.
- `process-orchestration-response` — unchanged primary signature
  `[session-id orch-state recipe response-text channel]`; the failure branch
  becomes "remind up to N, then exit" instead of "remind once, then exit".
  Optional enhancement adds a keyword arg `:tool-use?` (see below) and a new
  return `{:action :wait}` that the caller treats as "await the agent's next
  turn" (no prompt, no state change).

### Code Examples

**Part 1 — robust outcome detection (`orchestration.clj`).** Scan the whole
response, last-match-wins, tolerate fenced and bare JSON:

```clojure
(defn find-json-block
  "Find the outcome JSON object anywhere in an agent response (last match wins):
   1. the last ```json fenced block, else
   2. the last whole-line {...} object across ALL lines (not just the last 5).
   Returns the JSON string, or nil if none found."
  [text]
  (or
   ;; 1. last fenced ```json { ... } ``` block
   (some-> (re-seq #"(?s)```json\s*(\{.*?\})\s*```" text) last second)
   ;; 2. last single-line {...} anywhere in the response
   (->> (str/split-lines text)
        (map str/trim)
        (filter #(and (str/starts-with? % "{")
                      (str/ends-with? % "}")))
        last)))
```

Happy path: `"...prose...\n{\"outcome\": \"complete\"}"` → returns the object.
Edge case (JSON not in last 5 lines): `"{\"outcome\":\"complete\"}\n\n\n\n\n\nx"`
→ still found via strategy 2. Fenced: handled by strategy 1.

**Part 2 — forgiving failure policy (`process-orchestration-response`,
`server.clj`).** Replace the `(if (zero? retry-count) remind exit)` with a capped
reminder loop bounded by the existing global guardrails:

```clojure
;; failure branch (no valid outcome parsed)
(let [retry-count (get-in orch-state [:step-retry-counts current-step] 0)
      max-reminders (get recipe :max-outcome-reminders 3)
      error-msg (:error outcome-result)]
  (if (< retry-count max-reminders)
    ;; still within reminder budget -> nudge, do NOT abort
    (do
      (orch/log-orchestration-event "outcome-parse-retry" session-id
                                    (:recipe-id orch-state) current-step
                                    {:error error-msg :retry-attempt (inc retry-count)})
      (swap! session-orchestration-state
             update-in [session-id :step-retry-counts current-step] (fnil inc 0))
      (send-to-client! channel {:type :orchestration-retry
                                :session-id session-id
                                :step current-step
                                :error error-msg})
      {:action :retry
       :prompt (orch/get-outcome-reminder-prompt current-step expected-outcomes error-msg)})
    ;; exhausted reminders -> genuine failure, exit
    (do
      (orch/log-orchestration-event "outcome-parse-error" session-id
                                    (:recipe-id orch-state) current-step
                                    {:error error-msg :retry-attempts (inc retry-count)})
      (exit-recipe-for-session session-id "orchestration-error")
      (send-to-client! channel {:type :recipe-exited
                                :session-id session-id
                                :reason "orchestration-error"
                                :error (str "No valid JSON outcome after "
                                            max-reminders " reminders. " error-msg)})
      {:action :exit :reason "orchestration-error"})))
```

Runaway is impossible: `should-exit-recipe?` still caps `max-step-visits` /
`max-total-steps`, and the per-step reminder counter caps at `max-outcome-reminders`.

**Optional enhancement — don't even nudge a still-working turn.** If the driver
can tell the captured turn used tools, treat it as in-progress:

```clojure
(defn process-orchestration-response
  [session-id orch-state recipe response-text channel & {:keys [tool-use?]}]
  (if (and tool-use?
           (not (:success (orch/extract-orchestration-outcome
                            response-text (:outcomes (orch/get-current-step recipe (:current-step orch-state)))))))
    ;; agent ran tools and produced no outcome -> still working; just wait
    {:action :wait}
    ;; ... existing success/failure handling ...
    ))
```

This requires the caller to derive `:tool-use?` from the turn's transcript blocks
(the driver already reads the transcript by role at server.clj:1141, so the
`tool_use` blocks are reachable) and to handle `{:action :wait}` as a no-op. It is
listed as a follow-up only because it adds caller plumbing and a new action the
caller must route; the core fix lands without it.

### Component Interactions

```
agent turn ends ──► recipe driver (server.clj) captures response-text
                         │
                         ▼
          process-orchestration-response
                         │
        ┌────────────────┼─────────────────────────────┐
        ▼                ▼                              ▼
  outcome parsed    no outcome,                   no outcome,
  (success)         retry-count < cap             retry-count >= cap
        │                │                              │
   next-step/exit   :retry (reminder)              :exit "orchestration-error"
                    [+ optional :wait if the turn used tools]
```

Integration points: only `orchestration.clj` (`find-json-block`) and
`server.clj` (`process-orchestration-response`). No client protocol change
(reuses existing `:orchestration-retry` / `:recipe-exited` messages); the
optional `:wait` action is internal.

## Verification Strategy

### Testing Approach

- **Unit (`find-json-block`):** outcome detected when it is (a) the last line,
  (b) followed by >4 trailing lines, (c) in a ```json fence, (d) preceded by
  unrelated `{...}`-looking prose (last wins); returns nil when truly absent.
- **Unit (`process-orchestration-response` failure policy):** N consecutive
  missing-outcome turns produce `:retry` (not `:exit`) until the cap, then
  `:exit "orchestration-error"`; a valid outcome at any point clears the counter
  and transitions.
- **Integration:** a simulated step that emits work-only turns then a final
  outcome turn completes without aborting.
- **Regression:** every existing case in
  @backend/test/voice_code/orchestration_test.clj still passes.

### Test Examples

```clojure
(deftest find-json-block-whole-response-test
  (testing "outcome found even when not in the last 5 lines"
    (is (= "{\"outcome\": \"complete\"}"
           (orch/find-json-block "{\"outcome\": \"complete\"}\na\nb\nc\nd\ne\nf"))))
  (testing "last whole-line object wins"
    (is (= "{\"outcome\": \"issues-found\"}"
           (orch/find-json-block "{\"outcome\": \"x\"}\ntext\n{\"outcome\": \"issues-found\"}"))))
  (testing "fenced json block"
    (is (= "{\"outcome\": \"complete\"}"
           (orch/find-json-block "```json\n{\"outcome\": \"complete\"}\n```"))))
  (testing "absent -> nil"
    (is (nil? (orch/find-json-block "no json here\njust prose")))))

(deftest forgiving-retry-policy-test
  (testing "missing outcome reminds up to the cap, then exits"
    ;; with :max-outcome-reminders 2, retry-counts 0 and 1 -> :retry; 2 -> :exit
    (is (= :retry (:action (process-with-retry-count 0))))
    (is (= :retry (:action (process-with-retry-count 1))))
    (is (= :exit  (:action (process-with-retry-count 2))))))
```

### Acceptance Criteria

1. `find-json-block` returns the outcome object when it appears anywhere in the
   response, including beyond the last 5 lines and inside a ```json fence.
2. `find-json-block` returns `nil` only when no `{...}` outcome object exists.
3. A missing outcome no longer aborts the recipe on the second occurrence; the
   recipe exits with `"orchestration-error"` only after `max-outcome-reminders`
   (default ≥ 2) consecutive failures.
4. A valid outcome on any turn clears `:step-retry-counts` for the step and
   transitions normally.
5. `should-exit-recipe?` guardrails still bound the run (no infinite loop).
6. All pre-existing `orchestration_test.clj` / `orchestration_server_test.clj`
   tests pass.
7. New tests cover the 5-line-window miss, fenced/multi-line JSON, and the capped
   retry policy.
8. `on-turn-complete` fires the recipe callback only on a genuine end-of-turn
   assistant message, not on intermediate/spurious transcript writes. (This is the
   root-cause trigger fix; the `:tool-use?` / `:wait` work described under "Optional
   enhancement" above is the concrete vehicle for it and is promoted from optional
   to required by this criterion.)

## Alternatives Considered

- **Debounce / idle-gate the outcome check** (wait N seconds of quiet after a
  turn before checking). Rejected — timing-based completion is exactly the kind of
  fragile heuristic that misfires on long tool runs (`make build` takes minutes);
  it would reintroduce the premature behavior under load.
- **Explicit `in-progress` outcome the agent emits between turns.** Considered;
  adds prompt surface and relies on the agent remembering to emit it. The
  forgiving-retry policy achieves the same robustness without new agent contract.
- **Just raise `idle`/retry constants.** Band-aid; a sufficiently long step still
  trips it. Rejected as a standalone fix.
- **Chosen:** broaden detection (eliminates false negatives) + forgiving capped
  retry (eliminates premature abort), with the tool-use `:wait` enhancement as an
  optional follow-up once the caller's turn metadata is confirmed. Trade-off: a
  truly stuck agent now takes up to `max-outcome-reminders` turns to fail instead
  of 2 — acceptable given the global guardrails.

## Risks & Mitigations

- **Risk: broadened `find-json-block` matches a stray `{...}` line that isn't the
  outcome.** Mitigation: `extract-orchestration-outcome` still validates the
  parsed object against `expected-outcomes`, so a non-outcome object fails
  validation (and `validate-outcome-json` rejects it) rather than being accepted.
  Detection: AC#1/#2 unit tests including the "unrelated `{...}` prose" case.
- **Risk: forgiving retry masks an agent that never produces an outcome.**
  Mitigation: capped by `max-outcome-reminders` and the existing
  `max-step-visits`/`max-total-steps` guardrails; logged via
  `outcome-parse-retry` events for observability.
- **Risk: the optional `:tool-use?` path requires caller changes not yet
  verified.** Mitigation: it is explicitly optional; the core fix works without
  it. Gate its implementation on confirming the driver can supply turn metadata.
- **Rollback:** both changes are localized to two functions; revert the two
  commits to restore prior behavior. No data/schema migration to unwind.
