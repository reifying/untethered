# Untethered — macOS Desktop App — Design Brief

> **Purpose of this package.** Input for a full visual/UX **overhaul** of the
> Untethered **Mac desktop app**. It is written for designers (human or AI) who
> have **not** seen the code. Everything here is derived from the current source
> (commit on branch `design/macos-blueparrott-corebluetooth`, version 1.0 build
> 128). Scope is the **Mac app only** — not the iOS app, not the backend.
>
> Companion files in this folder:
> - `screen-inventory.md` — every window/pane with wireframes, states, source files
> - `user-flows.md` — the main end-to-end task flows
> - `screenshots/` — current-state PNGs (see note: capture is pending; reasons in that folder's README)

---

## 1. What it is

**Untethered is a voice-first remote control for AI coding agents.** A Clojure
backend runs Claude Code (and other agent CLIs) on your dev machine. The
Untethered apps connect to that backend over a WebSocket (port 8080) and let you
**speak prompts, watch the agent's streamed replies, and hear them read aloud** —
without touching the keyboard.

```
┌─────────────┐     WebSocket      ┌─────────────┐     CLI      ┌─────────────┐
│  Mac app    │◄──────────────────►│   Backend   │◄────────────►│ Claude Code │
│  (SwiftUI)  │     Port 8080      │  (Clojure)  │              │  / agents   │
└─────────────┘                    └─────────────┘              └─────────────┘
```

The Mac app is one of three clients (iOS, macOS, an Android/RN frontend exists in
the tree). The **iOS app is the flagship**; the **Mac app was built by sharing
~95% of the iOS SwiftUI code** and adapting it with `#if os(macOS)` branches. A
prior redesign (`docs/design/macos-desktop-redesign.md`,
`docs/design/desktop-ux-improvements.md`) gave it desktop *structure* — a
persistent sidebar, a command palette, a Settings window, a menu-bar extra,
keyboard shortcuts. **What it has never had is a deliberate visual design.** That
is the gap this overhaul addresses.

### The product tagline
> *"Speak commands to Claude from your iPhone or Mac while Claude works in your
> codebase. You speak, Claude codes, you review — all without touching your
> keyboard."*

---

## 2. Who it's for & why (value prop)

- **Primary user:** a developer who already runs Claude Code / coding agents and
  wants to **drive multiple long-running agent sessions hands-free** — e.g. while
  pacing, cooking, or **literally driving a car** (a large share of recent
  engineering went into Bluetooth-headset hands-free reliability for the
  in-car use case). The phone/Mac is across the room; voice is the interface.
- **Core value:** *untether the developer from the keyboard.* Kick off work by
  voice, let agents run, get spoken summaries back, intervene only when needed.
- **The Mac app's specific role:** a **desktop command center** for the same
  system. Where iOS is "remote in your pocket," the Mac app is the
  "always-open companion on the same machine the agent runs on" — bigger screen,
  multiple sessions visible at once, keyboard-driven, plus a menu-bar quick-capture
  for one-off prompts without opening the full window.

### Primary use cases (confirmed from code)
1. **Start a new agent session** in a chosen working directory (optionally a fresh
   git worktree), pick a provider (Claude / Copilot / Cursor / OpenCode), and send
   a first prompt.
2. **Resume / monitor existing sessions** — the sidebar lists Recent sessions and
   sessions grouped by project directory, with unread-message badges.
3. **Send a prompt** by **voice** (mic button / push-to-talk / Bluetooth headset
   button) or by **text** (Return to send).
4. **Read the streamed conversation** and **hear replies read aloud** (TTS, with
   selectable system/premium voices); stop/mute speech from the toolbar or menu.
5. **Manage a running session** — refresh history, compact (summarize) history,
   stop the current prompt, view session info, rename, export the transcript,
   share app logs with the agent.
6. **Run "recipes"** — structured multi-step agent workflows (e.g. implement →
   review → fix loops).
7. **Quick one-off capture** from the **menu-bar popover** without opening the main
   window.

---

## 3. Information architecture & windowing model

The Mac app is a SwiftUI `App` with **three scenes** plus a menu-bar command set.

```
VoiceCodeApp (@main)
│
├── WindowGroup  ──────────────────────────  MAIN WINDOW
│   └── RootView → NavigationSplitView (.balanced, two columns)
│        ├── Sidebar:  SessionSidebarView      (min 200 / ideal 250 / max 350 pt)
│        │     • "Recent"   section (collapsible) — last 10 sessions
│        │     • "Projects" section (collapsible) — sessions grouped by directory
│        │     • "Commands" section (collapsible) — top-5 MRU project commands
│        │     • toolbar: ＋ New Session, ⚙︎ Settings
│        └── Detail:
│              • EmptyDetailView                (when nothing selected)
│              • ConversationView               (the heart of the app)
│        + Overlay: CommandPaletteOverlay       (⌘K — dimmed scrim + floating panel)
│
├── Settings scene  ───────────────────────  SETTINGS WINDOW  (⌘,)
│   └── MacSettingsView → TabView (500 × 450 pt)
│        General · Connection · Voice · Advanced · Headset
│
└── MenuBarExtra (.window)  ──────────────── MENU-BAR POPOVER
    └── MenuBarContentView (width 300)
         directory picker · big mic button · transcription · recent sessions · footer
```

**Modal sheets** (presented over the main window, all wrapped in a shared
`NavigationController` that sets a min frame and a NavigationStack):
- **New Session** (450 × 350) — name, working directory, "create git worktree" toggle
- **Rename Session** (400 × 200)
- **Session Info** (500 × 500) — metadata, priority-queue, recipe, export
- **Recipe Menu** (450 × 400) — pick a recipe, choose provider / new-session
- **View Full / Message Detail** (500 × 400) — full message text + Copy / Read Aloud / Infer Name

**Native macOS menu bar** (defined in `VoiceCodeApp.commands`):
- **Edit:** Stop Speaking ⌘., Mute/Unmute Voice ⇧⌘M, Command Palette ⌘K, Reclaim Headset ⇧⌘H
- **View:** Toggle Sidebar ⌘0, Focus Sidebar ⌘1, Focus Conversation ⌘2
- **Session:** New ⌘N, Refresh ⌘R, Compact ⇧⌘C, Session Info ⌘I, Previous ⌘[, Next ⌘]

> **Notable IA fact:** the Mac app deliberately routes *only* to the
> sidebar + conversation. Many shared views that exist in the codebase
> (Directory list, per-directory session list, Resources upload, Command
> menu/execution/history, Debug-logs viewer, Auth-required gate, QR scanner) are
> the **iOS navigation stack** and are **not reachable in the Mac UI.** The Mac
> surface is therefore smaller and more focused than the file count suggests.
> The API-key entry that iOS handles via a dedicated screen, the Mac app folds
> into the **Connection** settings tab.

---

## 4. Tech stack & constraints

| Area | Detail |
|------|--------|
| UI framework | SwiftUI (AppKit bridged via `NSApplication`, `NSOpenPanel`, `NSColor`) |
| Deployment target | **macOS 15.0** (so SwiftUI `onKeyPress`, `Settings` scene, `MenuBarExtra`, `NavigationSplitView` are all available) |
| Language | Swift, `camelCase`; shares source with iOS; platform diffs via `#if os(macOS)` |
| Persistence | Core Data (`CDBackendSession`, `CDUserSession`, `CDMessage`) — local cache of sessions/messages |
| Networking | Single WebSocket to backend (`VoiceCodeClient`); JSON `snake_case` on the wire |
| Voice in | `Speech` framework (on-device recognition) via `VoiceInputManager` |
| Voice out | `AVSpeechSynthesizer` (system + premium voices) via `VoiceOutputManager` |
| Bluetooth | CoreBluetooth (BlueParrott headset button) — Mac-specific manager set |
| Build | XcodeGen (`ios/project.yml`) → `make build-mac` / `run-mac`; scheme `VoiceCodeMac` |
| Distribution | Signed + notarized, **app-sandboxed**, hardened runtime |
| Sandbox entitlements | network client, audio input, bluetooth, user-selected files R/W |
| Brand asset | App icon = a snapping rope ("untethered") on an **orange** field |

**Design constraints / what's feasible:**
- **Native SwiftUI controls are the norm.** Forms use `.formStyle(.grouped)`,
  lists use `.listStyle(.sidebar)`/`.plain`, settings is a `TabView`. A visual
  overhaul should expect to live within (or thoughtfully restyle) SwiftUI's
  control vocabulary, not a fully custom-drawn canvas.
- **macOS HIG conventions are already partly adopted** (Settings scene, menu-bar
  extra, ⌘-shortcuts, `.help()` tooltips, swipe-to-back). The overhaul can lean
  into these further rather than fight them.
- **Sandboxed** → working-directory selection goes through `NSOpenPanel`
  (security-scoped); no arbitrary filesystem browsing UI.
- **Light & Dark mode** must both work — the app uses system semantic colors, so
  it currently adapts automatically. Any custom palette must define both.
- **No custom typeface is bundled** — everything is the system font (SF). A
  custom font would be a net-new dependency.
- Electron / web rebuild was explicitly **rejected** in prior design; stay native.

---

## 5. Current visual language (exact values)

> **Headline:** there is **no design system.** The look is "default SwiftUI with
> ad-hoc, hard-coded semantic colors." Color choices are scattered literals
> (`.blue`, `.green`, `.red`, `Color.blue.opacity(0.1)`) rather than tokens.
> There is a brand identity (orange rope) that **the UI does not use at all.**

### 5.1 Color
- **Accent color:** `AccentColor.colorset` is **empty** → the app inherits the
  user's **macOS system accent (default Blue, ~`#007AFF`).** Used for: New-Session
  ＋, unread badges in the sidebar, command-palette selection highlight.
- **Brand vs. UI mismatch (key finding):** the app **icon is orange** (rope on
  `~#E8521E`/`#F26B3A` gradient, golden-brown rope) but **no orange appears
  anywhere in the UI.** The product has no in-app brand color.
- **Message bubbles:** user = `Color(.systemBlue).opacity(0.1)` fill; assistant =
  `Color(.systemGreen).opacity(0.1)` fill; corner radius 12, padding 12. Role
  icons: user `person.circle.fill` in `.blue`; assistant `cpu` in `.green`.
- **Voice/Text mode toggle pill:** `Color.blue.opacity(0.1)` bg, radius 8.
- **Mic button (in-conversation):** idle = `mic` glyph in `.blue` inside a
  100×100 circle filled `Color.blue.opacity(0.1)`; recording = `mic.fill` in
  `.red` inside `Color.red.opacity(0.1)`. (Menu-bar mic uses `.accentColor` /
  `.red`, 48 pt.)
- **Connection status:** 8×8 filled `Circle` — green connected / red disconnected.
- **Unread badges:** sidebar = `Color.accentColor` capsule, white text; some rows
  = `Color.red` capsule.
- **Errors:** red text on `Color.red.opacity(0.1)`, radius 8, tap-to-copy.
- **Toasts (copy/compaction confirm):** white text on `Color.green.opacity(0.9)`,
  radius 8, slides in from top.
- **Banners:** "messages too large to load" = `Color.yellow.opacity(0.12)` with a
  yellow hairline; "earlier messages unavailable" = `Color.orange.opacity(0.12)`.
- **Ghost-task toggle:** `.purple` tint + `theatermasks` glyph.
- **Command palette:** panel = `NSColor.windowBackgroundColor`, search bar =
  `NSColor.controlBackgroundColor`, selected row = `Color.accentColor.opacity(0.2)`;
  panel radius 12, drop shadow black @ 0.3, radius 20.
- **Surfaces:** `Color.systemBackground` → `NSColor.windowBackgroundColor`;
  secondary → `NSColor.controlBackgroundColor`. Light/Dark adapt automatically.

### 5.2 Typography
- **System font only (SF Pro / SF Mono).** No bundled typeface.
- Sizing via SwiftUI semantic styles: `.title2`, `.title3`, `.headline`,
  `.subheadline`, `.body`, `.caption`, `.caption2`, `.footnote`.
- **Desktop density overrides** (`DesktopDensity.swift`): body = `system 13`,
  caption = `system 11`, message = `system 13` (vs larger iOS defaults). Applied
  to sidebar rows via `.desktopDensity()`.
- **Monospaced** for: API-key mask (`.footnote` monospaced), push-to-talk key chip
  (`.body` monospaced).
- Message body text renders at `.body`; **no Markdown / syntax highlighting** —
  agent output (code, lists, diffs) is shown as **plain text.**

### 5.3 Spacing, sizing, shape
- Density constants: list-row vertical 4, horizontal 8; section spacing 8; min row
  height 28; icon size 14.
- Sidebar column width: **min 200 / ideal 250 / max 350 pt.**
- Message rows: insets top 6 / leading 16 / bottom 6 / trailing 16; bubble pad 12.
- Input area: VStack spacing 12, vertical pad 12, on `systemBackground`.
- **Corner radii in use:** 3, 4, 6, 8 (most chrome), 12 (bubbles, palette window),
  50 (mic circle). Inconsistent — no radius scale.
- Window/sheet sizes: Settings 500×450 · Command Palette 500×400 · Menu-bar 300 ·
  New Session 450×350 · Rename 400×200 · Session Info 500×500 · Recipe 450×400 ·
  Message Detail 500×400.

### 5.4 Iconography
- **SF Symbols throughout**, multicolor by tint. Heavy, dense use in the
  conversation toolbar (see §6). Key glyphs: `waveform.circle(.fill)` (menu-bar
  status), `mic`/`mic.fill`, `cpu` (assistant), `person.circle.fill` (user),
  `folder`/`folder.badge.gearshape`, `clock`, `terminal`, `info.circle`,
  `arrow.clockwise`, `arrow.down.circle(.fill)` (autoscroll),
  `rectangle.compress.vertical` (compact), `xmark.circle.fill` (stop),
  `list.bullet.clipboard(.fill)` (recipe), `doc.text.magnifyingglass` (share logs),
  `theatermasks` (ghost), `speaker.wave.2.fill`/`speaker.slash.fill`,
  `bubble.left.and.bubble.right` (empty state).

### 5.5 Window chrome
- Standard macOS title bar; main window uses default `NavigationSplitView` chrome.
  Sidebar `navigationTitle("Sessions")`. No custom toolbar background, no unified
  toolbar styling, no large-title treatment. Sheets use a plain NavigationStack
  with Cancel/Confirm or Done in the toolbar.

---

## 6. Pain points & overhaul drivers (prioritized, evidence-grounded)

Ranked by impact on the overhaul. Each names the evidence.

### P1 — No visual identity; brand and UI are disconnected *(highest)*
The icon is a bold orange "untethered rope," but the app is generic system-blue
SwiftUI. There is no brand color, no signature component, no memorable surface.
Nothing on screen says "Untethered." **Evidence:** empty `AccentColor.colorset`;
icon at `Assets.xcassets/AppIcon.appiconset/icon-1024.png`; color literals
scattered across views. **Driver:** the overhaul's biggest opportunity is to give
the app an identity (carry the orange/rope energy inward) and a real token system.

### P2 — Ad-hoc, inconsistent color & shape semantics
Blue means "user," "voice mode," "info," "links," *and* "accent." Green means
"assistant," "connected," *and* "success toast." Red means "error," "stop," *and*
"unread." Corner radii range 3–50 with no scale. **Evidence:** `CDMessageView`,
`ConversationView` input area, `SessionsView` badges, `DesktopDensity`. **Driver:**
define a semantic palette + radius/spacing scale; disambiguate meaning.

### P3 — The conversation is plain text — no Markdown, code, or structure
Agent replies (which are full of code blocks, file paths, lists, diffs) render as
a single `.body` Text in a tinted bubble, truncated past 2000 chars with a "View
Full" button. There is **no syntax highlighting, no monospace for code, no
collapsible tool calls.** **Evidence:** `CDMessageView.displayText`,
`messageTruncationThreshold = 2000`. **Driver:** the core reading experience is
weak for a *coding* agent; richer message rendering is a top win.

### P4 — Conversation toolbar is an overcrowded row of mono-color glyphs
The detail toolbar packs up to **8 icon buttons** (stop-speech, stop-prompt,
recipe, info, autoscroll, compact, refresh, share-logs, sometimes queue-remove),
all similar size/weight, several only conditionally present, distinguished mostly
by SF Symbol. Discoverability rests entirely on hover tooltips. **Evidence:**
`ConversationView` macOS toolbar (`#else` branch, ~lines 533–663). **Driver:**
prioritize, group, label, or relocate actions; reduce glyph soup.

### P5 — Two stacked, redundant "mode" controls above every composer
Every conversation shows a **Voice/Text mode toggle pill** *and* a **connection
status pill** on one row, then either a 100 pt circular mic or a text field — plus,
for new sessions, a **segmented provider picker**, plus (for resumed Claude
sessions) a **Ghost-task toggle**. The composer area is busy and shifts between
states. **Evidence:** `ConversationView` body input section (~lines 324–419).
**Driver:** unify into one adaptive composer.

### P6 — Empty / first-run states are minimal and unbranded
`EmptyDetailView` is an SF Symbol + two gray lines ("Select a session or create a
new one"). No onboarding, no connection guidance, no brand. A first-run user with
no API key sees a disconnected app with an empty sidebar and **no in-app prompt to
go configure Connection** (unlike iOS, which has a dedicated auth screen).
**Evidence:** `EmptyDetailView`, absence of an auth gate in the Mac nav tree.
**Driver:** design real empty/first-run/disconnected states.

### P7 — Connectivity & sync are fragile and surfaced as raw warnings
Recent history is full of connection/refresh/sync fixes; the UI exposes the seams:
a clickable connection dot ("click to reconnect"), "messages too large to load"
and "earlier messages unavailable" banners, manual refresh/compact buttons, copy-
the-error-to-clipboard affordances. **Evidence:** `docs/design/refresh-session-list-fix.md`,
`conversation-refresh-and-prune-fix.md`, `session-open-refresh-fix.md`,
`view-full-dialog-dismiss-fix.md`; `StalledChainBanner`, `PrunedGapBanner`,
forceReconnect button. **Driver:** the overhaul should make connection state
*calm and legible* (clear status, graceful degradation) instead of a row of
warnings and manual recovery buttons.

### P8 — "iOS app on a Mac" residue
The structural redesign fixed navigation, but interaction texture still reads
mobile: "Tap to Speak" / "Tap to Stop" labels on a Mac; sheets for things that
could be inspectors/popovers; haptic-style toast banners; large touch-sized mic
target. **Evidence:** `ConversationVoiceInputView` labels; sheet-based Session
Info/Rename/Recipe; `ClipboardUtility.triggerSuccessHaptic()` calls. **Driver:**
re-evaluate which modals should become sidebars/inspectors/popovers, and rewrite
mobile copy.

### P9 — Density & hierarchy not tuned for desktop
Despite `DesktopDensity`, the conversation uses generous bubble padding and a
single-column message list that wastes the wide detail pane; the sidebar mixes
three section types with differing row designs (Recent rows show relative time;
Project rows show unread counts; Command rows are plain). **Driver:** a coherent
density and a layout that uses desktop width (e.g., reading column, optional
inspector).

### Secondary observations
- **Menu-bar popover** is a useful quick-capture but visually plain and uses
  iOS-ish blue/green tinted text blocks; ripe for a polished mini-surface.
- **Settings** is clean and native (5 tabs) but unbranded; "Headset" tab exposes
  deep technical state (reducer state, "Now Playing claimed") that reads as debug.
- **No multi-window support** (listed as a deferred stretch goal originally).
- **Accessibility:** some identifiers exist, but color-only signaling
  (green/red dot, colored glyphs) needs non-color reinforcement.

---

## 7. What to preserve (do not lose in the overhaul)
- **Voice-first identity.** Voice/headset is the primary modality; the mic and
  spoken-reply loop must stay front-and-center, not buried behind text chat.
- **Hands-free / eyes-free affordances** (push-to-talk ⌥Space, headset button,
  audible cues, auto-send). The in-car use case depends on these.
- **Keyboard-driven desktop flow** — the full ⌘-shortcut set, command palette,
  ⌘[/] session switching, Return-to-send. Power users rely on these.
- **Persistent sidebar + multi-session at a glance** with unread badges.
- **The management toolset** (refresh, compact, stop, session info, recipes,
  export, share-logs) — keep the capabilities; redesign their presentation.

---

## 8. Open direction questions (for Phase 3 — asked one at a time)
A short list lives at the bottom of `user-flows.md`; these will be raised with the
product owner individually, not answered here. Topics: target aesthetic (carry the
orange/rope brand inward vs. neutral pro tool), how far to push message rendering
(full Markdown/code vs. light structure), modal-to-inspector conversion, whether
to add multi-window, and how prominent voice should be vs. a more chat-like layout.
