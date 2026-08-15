# Priority queue — revisit

**Status:** design + partial implementation (see §7 for the split)
**Branch:** `priority-queue-revisit`

## 1. The report, and what the code actually says

Travis built the priority queue, then stopped using it when he moved to tmux for supervising
agents: *"agents I had no intention of interacting with started landing in the queue."* The firm
requirement he stated is **tmux agents must not be added to the priority queue automatically.**

Reading the code changes what that requirement has to mean.

### 1.1 "tmux agent" is not a distinction the client can draw — and it is the wrong filter

Under protocol v0.3.0 ("tmux-untethered provider invocation") **every** session is dispatched
through tmux. The prompt handler in `backend/src/voice_code/server.clj:2888` calls
`tmux/start-window!` for a new session and `tmux/deliver!` for a resume — there is no non-tmux
path. A session Travis drives by voice from his phone lives in a tmux window exactly like one
started by `tmux-agent start`.

Nor does the wire carry an origin marker. The per-window environment
(`backend/src/voice_code/tmux.clj:581`) is `VC_SESSION_UUID`, `VC_WORKDIR`, `VC_PROVIDER`,
`VC_STARTED_AT`, `VC_SESSION_NAME`; `send-recent-sessions!` (`server.clj:890`) ships
`session-id`, `name`, `working-directory`, `last-modified`, `provider`. Nothing says who started
it. `CDBackendSession` has no field for it either.

So "exclude tmux sessions" would exclude everything, and "exclude CLI-started sessions" is not
information the client has. What actually changed when Travis moved to tmux supervision is not
the transport. It is **who the agent is talking to.** That is the distinction the fix has to be
built on.

### 1.2 The current admission rule is "an agent spoke on a session I'm subscribed to"

Auto-add is inlined at three places in `SessionSyncManager`, one per delivery path:

| Site | Path |
|---|---|
| `SessionSyncManager.swift:572` | v0.4.0 `session_history` |
| `SessionSyncManager.swift:911` | v0.5.0 `session_history` |
| `SessionSyncManager.swift:1753` | legacy v0.3.0 `session_updated` |

All three are the same condition: *new live assistant rows landed* **and**
`UserDefaults.bool(forKey: "priorityQueueEnabled")`. Nothing else.

Delivery is gated on subscription — `broadcast-session-history!` (`server.clj:1848`) and
`push-to-subscribers!` filter on the channel's `:subscribed-sessions`. So the effective rule is:

> **Opening a session in the app enrolls it. Every turn it takes thereafter enqueues it.**

That is a fine rule for a world where opening a session means talking to it. Under tmux
supervision it is not: Travis opens an agent's conversation to *watch* it. Watching is now the
common case, and each watched agent emits many assistant turns per task, none of which are
addressed to him.

The enrollment also outlives the look. `ConversationView.onDisappear` unsubscribes, but
`onDisappear` does not fire when the app is backgrounded — and `restoreSubscriptionsAfterReconnect`
(`VoiceCodeClient.swift:1525`) re-arms every tracked subscription on each reconnect. Background the
app while looking at a CLI-launched agent and it stays subscribed, and therefore stays enqueuing,
for the life of the process.

### 1.3 The queue has no drain

`removeFromPriorityQueue` is called from exactly two places, both manual: the swipe action in
`DirectoryListView.swift:198` and the toggle in `SessionInfoView.swift:124`. Nothing removes a
session when it is dealt with. Automatic entry plus manual-only exit is monotonic growth by
construction. Even with a perfect admission rule the queue would silt up; this is the second half
of why it stopped being useful.

### 1.4 A latent bug the new tests surfaced

`CDBackendSession.addToPriorityQueue` commits the context itself. Both
`session_history` paths then did:

```swift
if ctx.hasChanges {
    try ctx.save()
    if newRows > 0 { post(.sessionHistoryDidUpdate) }   // ← nested inside the guard
}
```

So on any batch that auto-enqueued, the enqueue's own save left `hasChanges == false` and the
`sessionHistoryDidUpdate` notification was **never posted** — `ConversationView` did not get its
refresh for exactly the batches that mattered most. Found because the new end-to-end tests wait
on that notification and timed out only on the enqueue paths. Fixed in both paths by posting on
`newRows > 0` independent of `hasChanges`. (The legacy `session_updated` path already posted
outside the guard.)

### 1.5 The setting does not describe what the setting does

Settings copy (`SettingsView.swift:157`):

> "Track sessions in priority-based queue. **Add sessions manually via toolbar button** and adjust
> priorities to control sort order."

Automatic enrollment is not mentioned. The toggle Travis turned on did something other than what
it said it did, which is why the behavior read as the feature misfiring rather than as a setting
he could reconsider.

## 2. What the queue is for now

**The priority queue is a turn-taking inbox: the sessions where the ball is in Travis's court.**

Not "sessions with recent activity" — the Recent list is already that, and the unread badge
already covers "something happened here." A queue earns its place only if being in it means
*this one is waiting on you*, and leaving it means *dealt with*.

That framing answers the open questions directly:

**What earns a place?** A turn Travis is the addressee of. Concretely: a reply to something this
device asked for. He sent the prompt; the answer is his to read and act on.

**Does an agent that asked a direct question differ from one that merely finished?** Conceptually
yes — but there is no signal for it today, and building on a guess would reintroduce exactly the
noise this is meant to remove. `turn_complete` fires identically for both. `tmux/agent-status`
(`tmux.clj:391`) reads `pane_current_command` and can only say running / idle / dead — it cannot
tell "waiting on a question" from "shell prompt." Text heuristics ("ends in a question mark") are
not trustworthy enough to gate an inbox on. So: **don't infer it — let the agent say it.** §6.

**Is automatic entry the right model at all?** Yes, but only for the conversation Travis is
actually in. There, automatic is right and opt-in would be busywork: he already opted in by
sending the prompt. For every other agent — CLI-launched, recipe-driven, merely watched — entry
should be opt-in, by him (the existing manual add) or by the agent (§6). Under this rule the
firm requirement holds without the client ever needing to know what a tmux agent is: an agent he
did not prompt from the device never enters on its own, whatever launched it.

## 3. The rule

```
ENTER  when a live assistant message lands on a session with an outstanding
       prompt the USER sent (one-shot: the arrival consumes the claim)

LEAVE  when the user sends the next prompt to a queued session
       (the ball is back in the agent's court), or on manual removal
```

"A prompt the user sent" means **any prompt he issued himself, from anywhere** — the iOS or macOS
app, the headset, or typed straight into the agent's tmux pane. It deliberately excludes prompts
issued *on his behalf* by automation: supervisor dispatches, recipe steps, ghost prompts,
`tmux-agent` launches. An agent driven only by the supervisor never enters the queue; the moment he
goes and talks to it himself, it does. See §4.1 for how the pane case is detected.

Two consequences worth stating because they are choices, not fallout:

- **Opening a session does not dequeue it.** Reading is not answering. Travis routinely opens a
  session, reads, and decides to reply later; dequeuing on open would silently drop the thing he
  is trying to keep track of.
- **A session that re-enters keeps the priority he gave it.** Auto-dequeue must not reset
  `priority` to the default the way the manual remove does, or a P1 session would come back as P10
  after every round trip. Manual removal keeps resetting — that is a deliberate "I'm done with
  this" gesture.

The existing move-to-back-of-priority-level behavior in `addToPriorityQueue` is retained and is
correct under the new framing: a session that speaks again is still waiting, and should not jump
the line ahead of things that have been waiting longer.

## 4. Mechanism

Two small pieces, both pure or near-pure and both unit-testable.

**`PendingReplyLedger`** — a durable, one-shot record of "I asked this session something and
haven't seen the answer yet." Keyed by lowercased session id, value is the arm timestamp, backed
by `UserDefaults` so it survives the app being killed while an agent works. Entries expire after
24h (`arm` prunes), so a session whose agent died can't enqueue on some unrelated reply weeks
later. `claim(sessionId:)` returns true and removes the entry; a second claim returns false.

**`PriorityQueueAdmission`** — the policy, in one place instead of three:

```swift
static func promptTarget(ofOutgoing message: [String: Any]) -> String?
static func shouldEnqueue(featureEnabled: Bool,
                          hasLiveAssistantMessages: Bool,
                          claimAwaitedReply: () -> Bool) -> Bool
```

`claimAwaitedReply` is a closure rather than a `Bool` on purpose: the claim is destructive, so it
must not fire when the earlier conditions already rule out enqueuing. The tests assert that.

Wiring:

- `VoiceCodeClient.sendMessage` recognizes an outbound prompt via
  `PriorityQueueAdmission.promptTarget` (`prompt` → `resume_session_id` ?? `new_session_id`;
  `start_recipe` → `session_id`) and calls `SessionSyncManager.recordOutboundPrompt`. One choke
  point covers the typed send, the voice send, the headset send, the menu-bar quick prompt and
  recipe launches — including any send path added later.
- `SessionSyncManager.recordOutboundPrompt` arms the ledger and removes the session from the queue
  preserving its priority.
- The three auto-add sites call `PriorityQueueAdmission.shouldEnqueue`.
- The two "auto-add on session creation" sites (`DirectoryListView.swift:727`,
  `SessionsForDirectoryView.swift:363`) are removed. A freshly created session has no prompt in
  flight and is already on screen; it enters, like everything else, when its first reply lands.

### 4.1 Prompts typed into the pane

The client cannot see these at all: human-role prompts are deliberately filtered out of the message
stream (`claude-human-prompt?` in `replication.clj`, because iOS already renders its own sends
optimistically). So the signal has to come from the backend, which *can* see them — it parses and
seq-stamps every one before dropping it from the broadcast.

The discriminator is **attribution by elimination**. Every prompt the backend injects passes through
a small enumerable set of choke points, and each records the text first:

| Choke point | Covers |
|---|---|
| `tmux/deliver!` (live-window branch) | client sends, recipe steps, ghost prompts to a live pane |
| `tmux/start-window!` (both nudge sites) | new sessions, respawn-after-eviction, `tmux-agent start` |
| `claude/invoke-claude` | the supervisor's `dispatch_prompt` |

Recording sits at the three `nudge!` call sites rather than at the top of `deliver!` precisely
because they are mutually exclusive per delivery — `deliver!` → `respawn-and-deliver!` →
`start-window!` would otherwise record one prompt twice. On a failed nudge the record is withdrawn
(claimed back) before the respawn re-records it.

A human prompt in the transcript with no matching record was typed at the keyboard. The backend
then emits `user_prompt {session_id}` to **every** connected client — not subscriber-gated, since
the whole point is reaching a client that never subscribed to that agent. The client treats it
exactly like one of its own sends: `recordOutboundPrompt`, which dequeues and re-arms.

**The bias is asymmetric on purpose.** When a human prompt cannot be text-matched but an injection
is still outstanding for that session, it is claimed as backend-injected anyway. A false "injected"
costs one missed queue entry, which one more prompt fixes. A false "typed by the user" silently
re-admits an agent nobody is waiting on — the original failure. Records expire after 10 minutes so
a prompt that never landed cannot mute the user indefinitely.

## 5. What this does to the reported symptom

| Situation | Before | After |
|---|---|---|
| CLI/recipe agent Travis peeks at | enqueued on every turn while subscribed | never enqueued |
| Same agent, app backgrounded mid-look | enqueued forever (subscription leak) | never enqueued |
| Supervisor-driven agent, never touched by him | enqueued if subscribed | never enqueued |
| Session Travis prompts from the phone | enqueued | enqueued, once, when the reply lands |
| Agent he prompts by typing in its tmux pane | not enqueued (invisible to client) | enqueued when the reply lands |
| He replies to a queued session | stays queued | leaves; returns when the agent answers |
| CLI agent he *does* want to track | manual add | manual add (unchanged) |
| Session he created but hasn't prompted | enqueued empty | not enqueued |

The subscription leak in §1.2 is not fixed here and does not need to be: with admission keyed on
the ledger rather than on subscription, a leaked subscription costs bandwidth, not queue entries.
It is worth fixing on its own merits, separately.

## 6. Designed, not implemented: let the agent raise its hand

The honest version of "an agent asked me a direct question" is not inference — it is the agent
saying so. This is the piece that makes automatic entry unnecessary for agents Travis didn't
start, and it is what would make the queue useful for unattended supervision rather than merely
quiet.

Shape:

- `tmux-agent flag <name> [--priority N] [--reason "..."]`, and a Claude Code `Notification` hook
  (which fires precisely when the CLI needs user input) posting the same thing.
- Backend: `POST /agents/:id/flag` in `agent_api.clj` alongside the existing
  `handle-nudge` / `handle-capture`, emitting a new `queue_request` frame —
  `{type, session_id, priority, reason}` — to all connected non-deleted clients. It must be a
  broadcast, not a subscriber push: the whole point is reaching a client that has never subscribed
  to this session.
- Client: `queue_request` enqueues at the requested priority with the reason as the row subtitle.
  A ledger claim is not required; this is the agent's own opt-in.

Deliberately out of scope for this pass — it is a protocol addition with a backend surface, and it
should be designed against real use of §3 rather than speculatively bundled with it.

## 7. Implemented vs. designed

**Implemented on this branch:**

- `PendingReplyLedger` (`ios/VoiceCode/Managers/PendingReplyLedger.swift`)
- `PriorityQueueAdmission` (`ios/VoiceCode/Utils/PriorityQueueAdmission.swift`)
- `SessionSyncManager.recordOutboundPrompt` + the three auto-add sites rewired
- `VoiceCodeClient.sendMessage` hook
- `removeFromPriorityQueue(_:context:resetPriority:)` — priority-preserving auto-dequeue
- Removal of the two auto-add-on-create sites
- Settings copy corrected to describe the actual rule
- `sessionHistoryDidUpdate` post hoisted out of the `hasChanges` guard on both
  `session_history` paths (§1.4)
- Tests: `PriorityQueueAdmissionTests`, `PendingReplyLedgerTests`,
  `PriorityQueueAdmissionSyncTests` (end-to-end through the v0.5.0 payload path)

**Pane-typed prompts (§4.1), added in a second pass:**

- `voice-code.prompt-origin` — injection ledger and attribution
- Recording at the three `nudge!` call sites in `tmux.clj` + `claude/invoke-claude`
- `:on-user-prompt` watcher callback in `replication.clj` (+ `human-prompt-text`)
- `on-user-prompt` broadcast in `server.clj`, new `user_prompt` frame (protocol doc updated)
- Client `user_prompt` handler
- Tests: `voice-code.prompt-origin-test` (12 tests / 22 assertions), plus two client tests

**Test status.** Backend: `prompt-origin-test` passes; `replication-test` (198),
`tmux-test` (30), `claude-test` (29), `server-test` (134), `ghost-test`, `recipes-test` and
`dual-protocol-test` all pass. `orchestration-server-test` has 6 failures in
`recipe-provider-extraction-from-message-test` / `recipe-provider-invalid-provider-test` that
reproduce identically at `HEAD` in a clean worktree — pre-existing, unrelated.
iOS: all three new classes pass, as do the six existing `SessionSyncManager`
suites and the 106-test `PriorityQueueManagementTests`. The full `make test` run has two failing
suites — `BlueParrottButtonManagerTests` (15) and `HeadsetIOSAudioSessionTests` (1) — which fail
identically at `HEAD` in a clean worktree; they are simulator audio-session failures unrelated to
this change. macOS: `make build-mac` succeeds and both pure classes pass on the mac target;
`PriorityQueueAdmissionSyncTests` hangs the macOS test host, exactly as the pre-existing
`SessionSyncManagerOffsetPayloadTests` does (both stall on the first notification-driven test),
so that family is effectively iOS-only today.

**Designed only:**

- §6, agent-initiated queue entry (`queue_request`).
- Subscription-leak fix (§1.2 tail) — unsubscribe on background / prune stale subscriptions.
  Independent of this change now that admission no longer keys on subscription.
