# Untethered macOS — User Flows

The main end-to-end task flows in the **Mac app**, as implemented today. Each is
written so a designer can see where friction lives and what the redesign must
preserve. Surface numbers (#N) reference `screen-inventory.md`.

---

## Flow 0 — First run / connect (the cold-start gap)
**Goal:** a brand-new user gets the app talking to their backend.

1. Launch app → main window (#1). Sidebar is **empty**; detail = Empty state (#3);
   menu-bar icon is **red** (disconnected).
2. There is **no in-app nudge to configure the connection.** The user must know to
   open **Settings (⌘, )** → **Connection** tab (#11).
3. Enter Server address + Port → **Apply**. Enter the API key (`untethered-…`,
   43 chars) → **Save**. Optionally **Test Connection** (✓/✗).
4. App reconnects; on success the sidebar populates with Recent / Projects and the
   menu-bar icon turns **green**.

> **Friction:** the cold-start path is undiscoverable (iOS has a dedicated
> auth-required screen; Mac does not). No QR-scan on Mac (that's iOS-only). A
> first-run user can stare at an empty, silent, disconnected window. **A real
> first-run / connect experience is a priority for the overhaul (P6).**

---

## Flow 1 — Start a new session and send the first prompt
**Goal:** kick off agent work in a project.

1. Sidebar toolbar **＋** (or ⌘N, or Command Palette → "New session", or
   menu-bar → Open VoiceCode). → **New Session sheet (#5)**.
2. Type a name; set Working Directory (or toggle **Create Git Worktree** and give a
   parent repo path); **Create**.
3. The session is created locally and **auto-selected**; detail shows the
   Conversation (#4) with **no messages yet** and the **new-session header (#4c)**:
   a segmented **provider picker** (Claude/Copilot/Cursor/OpenCode).
4. Send the first prompt:
   - **Voice:** click the big mic (#4a) → speak → click to stop → (auto-)send; or
   - **Text:** toggle to Text Mode → type → **Return**.
5. The prompt appears as a user bubble; the agent's reply streams into a green
   assistant bubble; auto-scroll follows; if TTS is on, the reply is read aloud.

> **Friction:** the composer stacks several controls (mode pill + connection pill +
> provider picker + sometimes ghost toggle) before the user even speaks (P5).

---

## Flow 2 — Resume / switch between sessions
**Goal:** jump back into ongoing work; monitor several sessions.

1. Sidebar (#2): **Recent** (last 10, with relative times) or **Projects**
   (grouped by directory, with unread badges and per-folder unread roll-ups).
2. Click a session → detail loads that Conversation; the view re-subscribes and
   pulls latest history (the same view instance is reused across switches).
3. Or keyboard: **⌘[ / ⌘]** for previous/next; **⌘0** to hide the sidebar for
   focus; **⌘1/⌘2** to move focus.
4. Unread badges clear as messages are read.

> **Preserve:** at-a-glance multi-session overview + keyboard switching (these are
> the desktop app's reason to exist). **Refine:** the three sidebar section/row
> styles are inconsistent (P9).

---

## Flow 3 — Hands-free / eyes-free voice loop (the signature flow)
**Goal:** drive an agent without looking at or touching the Mac (e.g. while pacing
or driving with a Bluetooth headset).

1. Enable in **Settings → Headset (#11):** headset control and/or **BlueParrott**
   button; optionally **Auto-send on stop** and **Audible cues**.
2. **Press-and-hold** the headset button (or ⌥Space, or hold the on-screen mic) →
   recording starts (audible cue) → speak → **release** → transcription finalizes
   → prompt **auto-sends** (audible cue). The on-screen mic and the headset share
   one state machine, so either can start/stop.
3. The agent's reply is **read aloud** automatically. ⌘. (or a headset action)
   stops speech; ⌘⇧M mutes.
4. If another app grabs the system "Now Playing" slot, **Reclaim Headset (⌘⇧H)**
   or the Settings button re-registers Untethered.

> **Preserve at all costs:** this is the product's identity and the focus of the
> most recent engineering. The overhaul must keep voice/headset primary and
> eyes-free, not subordinate it to a text-chat layout (P-preserve / §7 of brief).

---

## Flow 4 — Read a long reply / act on a message
**Goal:** read full agent output and take an action on it.

1. In the message list, long messages are **truncated past ~2000 chars** with a
   **View Full** button (short ones show an **Actions** affordance instead).
2. Click → **Message Detail sheet (#9):** full, selectable, **plain-text** body.
3. Actions: **Copy** · **Read Aloud / Stop** · **Infer Name** (agent names the
   session from this message).

> **Friction:** code-heavy agent output is plain text — no monospace, syntax
> highlighting, or collapsible tool calls (P3). Reading is the core loop and is
> under-served.

---

## Flow 5 — Manage a running session
**Goal:** control and inspect an in-progress session.

From the conversation **toolbar** (#4) or **Command Palette** (#10):
- **Refresh (⌘R)** — re-pull history.
- **Compact (⇧⌘C)** — summarize history to save tokens (confirm dialog; "already
  compacted" guard).
- **Stop prompt (⌘K)** — terminate the current agent run (confirm dialog).
- **Stop speaking (⌘.)** — halt TTS.
- **Autoscroll toggle** — follow vs. pin scroll.
- **Session Info (⌘I)** → sheet (#7): copy metadata, set priority, start/exit
  recipe, **Export Conversation** to clipboard.
- **Share logs with agent** — upload app logs and ask the agent to review them.
- **Rename** (via sheet #6).

> **Friction:** up to 8 same-weight icon buttons in one toolbar row; meaning
> carried by SF Symbol + hover tooltip only (P4).

---

## Flow 6 — Run a recipe (structured workflow)
**Goal:** run a multi-step agent workflow (e.g. implement → review → fix).

1. Conversation toolbar recipe button (or Session Info → **Start Recipe**). →
   **Recipe Menu sheet (#8)**.
2. Choose **Start in new session** (or current), pick a **Provider**, select a
   **recipe** from the list (label + description).
3. Recipe starts; an active-recipe indicator appears (toolbar menu shows
   "Step N / current step", with **Exit Recipe**). If started in a new session, a
   confirmation points the user to find it in the sidebar.

---

## Flow 7 — Quick capture from the menu bar
**Goal:** fire a one-off prompt without opening the main window.

1. Click the menu-bar **waveform** icon → popover (#12).
2. Pick a directory (recent or Browse…); click the mic (or Space); speak; stop.
3. Review the transcription → **Send**; the response appears inline in the popover.
4. Or jump to the full app (**Open VoiceCode**) / **Settings…** / **Quit**.

---

## Cross-cutting: connection state
The connection surfaces in several places, mostly as raw seams: the menu-bar icon
color; an inline **clickable connection dot** ("Connected/Disconnected — click to
reconnect") above the composer; **refresh/compact** buttons; and **warning
banners** when history can't fully load. Recovery is manual.

> **Driver:** make connection state calm and legible; degrade gracefully instead
> of exposing reconnect buttons and warning banners (P7).

---

## Open direction questions (Phase 3 — to raise ONE AT A TIME)
Draft list; these are *direction* questions for the product owner, not answered
here:
1. **Aesthetic target** — carry the orange/snapping-rope brand *into* the UI
   (warm, distinctive) vs. a neutral "pro developer tool" look? How bold?
2. **Message rendering depth** — full Markdown + syntax-highlighted code +
   collapsible tool calls, or lighter structure? (Biggest reading-experience lever.)
3. **Voice prominence vs. chat layout** — keep the large mic/voice-first composer
   center stage, or shift toward a chat-app layout with voice as an input mode?
4. **Modals → inspectors?** — convert Session Info / Rename / (parts of) Recipe
   from sheets into a right-hand inspector or popovers?
5. **Connection/first-run** — add a real first-run/connect experience and a calm
   persistent status, replacing the banner+button recovery model?
6. **Scope** — is multi-window (deferred originally) in scope? Is the menu-bar
   quick-capture a first-class surface to invest in?
7. **Density & layout** — should the wide detail pane gain a reading column /
   optional inspector, or stay single-column?
