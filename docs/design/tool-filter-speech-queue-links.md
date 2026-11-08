# Tool calls filtered on the server, replies read in turn, tappable links

Three changes to the transcript and to speech, shipped together on 2026-11-08.

1. **Tool calls and thinking are filtered on the backend.** No tool call, tool result or thinking
   step reaches a client. (Thinking was added on 2026-11-08 as a follow-up; see §1a.)
2. **New replies don't interrupt the one being read.** Replies that arrive while a session is open are queued and each is read in full, in order.
3. **Links are tappable**, in the conversation list and in the full-message view.

## 1. Tool calls filtered on the backend

### Before

`providers/parse-message` summarized every tool block into the message `text`: `tool_use` became
`[Tool: Read file_path=...]`, `tool_result` became `[Tool Result]\n<output>`, and Copilot `toolRequests`
became `[Tool: rg pattern=...]`. Claude Code writes one JSONL line per content block, so most of these
arrived as messages of their own, and the transcript showed them as bubbles. The iOS client then
stripped them from the speech copy only (`TextProcessor.removeToolAnnouncements`, commit 019f11e2).

What the client did with tool-call messages, found by tracing every consumer of a live message:

| Consumer | Effect of a tool-call message | After this change |
|---|---|---|
| Transcript (`CDMessageView`) | A `[Tool: ...]` / `[Tool Result]` bubble | Gone (the point of the change) |
| Auto-speak | Stripped to empty, then dropped by the blank guard | Never arrives |
| Notification for a background session | Body could be tool text | Only prose notifies |
| Unread count | Each tool message counted | Only conversation counts |
| Session preview | Could show `[Tool: Bash ...]` | Shows the last prose |
| Priority queue admission | The first assistant message after a prompt claims the pending reply, and a tool call counted | Claimed by the first prose reply, or by `agent_replied` at turn end |
| Auto-scroll | Scrolled on each tool message | Scrolls on prose |

No status indicator, lock or timer depends on them: the processing lock is driven by `turn_complete`,
and the headset await-timeout by TTS start. Nothing that is still needed is lost. The one visible loss
is mid-turn activity: during a long tool-heavy turn the transcript stays still until the agent
writes prose or the turn completes.

### Design

The filter lives in `parse-message`, because it already *is* the canonical wire transform: every
client path (v0.5.0 push `stamp-offsets`, v0.5.0 subscribe and backfill `read-from-offset`, the v0.4.0
broadcast and subscribe, the Copilot push) goes through it.

- `providers/tool-block?` recognizes a tool block by type: `tool_use`, `tool_result`, and the server and
  MCP variants (`server_tool_use`, `mcp_tool_use`, `web_search_tool_result`, `mcp_tool_result`, ...).
- Claude: tool blocks are dropped from `text`. Text blocks are kept, so a mixed record keeps its prose.
  (Thinking blocks are dropped too since §1a.) A record with no readable text left returns `nil`.
- Copilot: `toolRequests` are no longer summarized. An `assistant.message` with no content or reasoning
  text returns `nil`.
- OpenCode is unchanged. Its text has always been the message's text parts only.

Returning `nil` is safe for the offset protocol: under v0.5.0 an offset is the raw-line index, and
filtered lines (sidechain, summary, system) already left gaps. `next_offset` advances past them, and a
tick of nothing but tool activity still pushes the advanced cursor to caught-up subscribers.

Other consumers of `parse-message`, checked:

- `last-assistant-turn` (the recipe trigger gate) reads the raw record for `end-of-turn?` and
  `tool-use?`. It now takes the watermark uuid from the raw record when the canonical form is `nil`,
  so a dispatch that lands mid-turn still records which write it saw.
- Prompt-origin detection (`user_prompt` for a prompt typed into the pane) now partitions the raw
  filtered messages directly, so it does not depend on what the wire format shows.
- The Claude index `message-count` is computed from raw lines and is unchanged. Copilot's count is
  computed from canonical messages and now excludes tool-only events.

### Client

`TextProcessor.prepareForSpeech` no longer strips tool markers. With nothing to strip, the old regex
had only false positives left: prose that mentions `[Tool Result]` was cut off at that point when read
aloud. The blank-text guard in `speakWithVoice` stays. A message that is only a code block still
processes to `[code block]`, and an empty string still must not preempt speech.

The Android client keeps its own copy of the old filter (`TextProcessor.removeToolAnnouncements`). It is
now a no-op against this backend and was left alone.

### Known limits

- **Rows already cached on a device stay.** Tool-call rows already in a phone's CoreData remain in
  those conversations' history until they age out of the local window. New ones stop arriving.
- **Deploy order.** The client no longer filters, so a new client talking to an old backend would read
  tool calls aloud, one after another (see §2). Restart the backend first.
- **v0.4.0 seq counters.** In the v0.4.0 rollback path, the persisted `:next-seq` of a session that
  predates this change counted tool messages, while a fresh subscribe recounts without them. Current
  iOS and macOS clients use v0.5.0 offsets, which are unaffected.

## 1a. Thinking filtered the same way

Thinking is a working step too, so it now follows the same path as tool calls. Claude `thinking` and
`redacted_thinking` blocks are dropped from `text` (`providers/thinking-block?`); before, they were
sent as `[Thinking: <first 50 chars>...]`. Copilot's `reasoningText` is no longer used as a fallback
when `content` is empty. A record with nothing left returns `nil`, exactly as a tool-only record
does. OpenCode is unchanged, because its text was already the text parts only and its reasoning parts
were never included.

The client has no thinking-specific logic. It displayed the marker, and the speech path deliberately
read it aloud. So nothing on the device needs changing, and the same consumer table as §1 applies:
thinking-only messages no longer create bubbles, get spoken, notify, count as unread, update the
preview, or claim the priority-queue slot.

Risk: if a Copilot model ever puts its final answer only in `reasoningText` with an empty `content`,
that answer is now dropped. The field holds the model's reasoning, and the replies seen in tests
carry their answer in `content`.

## 2. Replies read in turn

### Before

`SessionSyncManager` called `VoiceOutputManager.speak` for every new live assistant reply, and `speak`
preempts: it stops whatever is playing and starts the new text. A reply that arrived mid-reading cut
off the one being read. Within a single push, every reply but the last was cut off. In practice they
sometimes queued in the synthesizer instead, because `synthesizer.isSpeaking` lags `speak()`, and
which of the two happened depended on timing.

### Design

`VoiceOutputManager.enqueue(...)` sits next to `speak(...)`:

- **`enqueue`**: reads the text after everything already being read or waiting. If nothing is in
  flight it starts at once. Otherwise it joins a FIFO and starts when the utterance before it finishes.
  Used for live replies (all three `SessionSyncManager` auto-speak sites).
- **`speak` / `speakWithVoice`**: an explicit request (Read Aloud, a voice preview, the notification's
  Read Aloud action). It still takes over immediately, and it discards the queue.
- **`stop()`**: discards the queue. Stop means stop reading, so the Stop button, a headset barge-in and
  starting a recording all end the queue too.
- **Switching to a different session** drops the replies queued for the session the user left, as it
  already stopped that session's in-flight utterance. A transient `nil` active session (a sheet opening)
  is ignored, as before.
- **A cancelled utterance** ends the queue. Only a natural finish advances it.

The app keeps its own queue and hands the synthesizer one utterance at a time, rather than relying on
`AVSpeechSynthesizer`'s native queue. That way each reply configures the audio session right before it
starts, which the silent-switch handling depends on, and queued items can be dropped by session.

The queue needs an accurate answer to "is something being read?" `synthesizer.isSpeaking` reads false
for tens of milliseconds after `speak()`, and a batch of replies is enqueued in one main-queue turn. So
`currentUtterance` is set synchronously when speech starts, and it is compared by identity in
`didFinish`/`didCancel`, so the late callback of an utterance that was already replaced cannot advance
or clear the queue.

**`isSpeaking` stays true across the whole queue.** When a queued reply follows another, the finish
callback starts the next one and skips the end-of-speech work: no `isSpeaking = false`, no
`onSpeechComplete`, no keep-alive stop and no session deactivation. That matters to observers. On iOS
the headset state machine leaves `.speaking` and re-asserts its session when `isSpeaking` drops. On
macOS the output router parks audio on the built-in output. A drop between replies would do both,
mid-queue.

### Unchanged

Opening a session that already has messages does not read them. The `liveFromOffset` boundary and the
per-UUID spoken-once dedup in `SessionSyncManager` decide which replies are live. This change only
alters how live replies are spoken.

## 3. Tappable links

`LinkDetector` runs `NSDataDetector` and keeps only links written as links: `http://` / `https://` URLs
and `www.` addresses. The detector alone would also link anything shaped like a domain, and agent
replies are full of file names that are valid domains (`README.md`, `main.rs`, `server.py`, `deploy.sh`).
Messages with neither `http` nor `www.` skip detection entirely.

- **Conversation list:** `CDMessageView` renders `CDMessage.displayAttributedText`, which is
  `displayText` with `.link` attributes. It is cached on the same content-hash key as `displayText`,
  so detection runs once per text change, not per layout pass. SwiftUI `Text` opens a link on tap, and
  a tap anywhere else on the row behaves as before.
- **Full-message view:** `SelectableText(detectsLinks: true)` writes attributed text with `.link` runs
  into the non-editable, selectable `UITextView` / `NSTextView`, which open links on tap or click.
  Selection still works. The content is rewritten only when it changes, so the user's selection
  survives unrelated SwiftUI updates. Command output and the debug log view do not opt in.

Markdown is not rendered. In `[label](https://...)` the URL part is the tappable link.

## Testing

- Backend (`providers_test`, `replication_test`, `orchestration_server_test`): tool-only records produce
  no message, and mixed records keep only their prose. Server and MCP tool blocks are dropped too. The
  v0.5.0 push snapshot and subscribe read of a realistic tool-heavy turn carry only the conversation,
  at true raw-line offsets, with the cursor advancing past tool lines. A tool_result is no longer
  forwarded by the v0.4.0 broadcast. The trigger gate keeps the raw uuid for a tool-only write.
- iOS `VoiceOutputQueueTests`: queue order, no interruption, back-to-back enqueues in one turn, stale
  callbacks, cancel, stop, explicit speak, a session switch, a transient nil session, and recording.
  One test uses the real synthesizer: three queued replies each finish, and `isSpeaking` drops exactly
  once, at the end.
- iOS `SmartSpeakingTests.testLiveRepliesAreQueuedInOrderNotInterrupting`: opening a session reads
  nothing, and a push of three live replies hands all three to `enqueue` in order, none to `speak`.
- iOS `LinkDetectorTests`, `CDMessageDisplayTextTests`: what is and is not a link, the boundaries, and
  UTF-16 ranges.
- `LinkTapUITests` (simulator): tapping the URL in the list opens Safari without opening the detail
  sheet, and tapping it in the full-message view opens Safari. Run against a seeded in-memory
  conversation (`-uiTestSeedLinkSession`) with the server pointed at a dead port.

Not covered by automation: real headset and BlueParrott behaviour across a queue of replies, CarPlay
or car audio routing, and the macOS app (built, not run).
