# Untethered macOS — Screen / Window / Pane Inventory

Every distinct surface in the **Mac app**, with purpose, key elements, states,
source file, and an ASCII wireframe. Sizes are the actual values from source.
Screenshot filenames refer to `screenshots/` (capture currently **pending** — see
that folder's README). Source paths are relative to `ios/VoiceCode/`.

> **Reachability note.** The Mac app's navigation only ever shows: the main
> split-view window, the Settings window, the menu-bar popover, the command-
> palette overlay, and five modal sheets. iOS-only screens that exist in the
> codebase (DirectoryListView, SessionsForDirectoryView, ResourcesView,
> ResourceShareView, CommandMenuView, CommandExecutionView, CommandHistoryView,
> CommandOutputDetailView, APIKeyManagementView, AuthenticationRequiredView,
> QRScannerView, DebugLogsView, SettingsView) are **not reachable on Mac** and are
> omitted here.

---

## 0. Map of surfaces

| # | Surface | Type | Source | Screenshot |
|---|---------|------|--------|------------|
| 1 | Main window — split view shell | Window | `VoiceCodeApp.swift` (`RootView`) | `01-main-window.png` |
| 2 | Session sidebar | Pane | `Views/SessionSidebarView.swift` | `02-sidebar.png` |
| 3 | Empty detail (no selection) | Pane state | `Views/SessionSidebarView.swift` (`EmptyDetailView`) | `03-empty-detail.png` |
| 4 | Conversation (detail) | Pane | `Views/ConversationView.swift` | `04-conversation.png` |
| 4a | Conversation — voice composer | Sub-state | `ConversationView.swift` (`ConversationVoiceInputView`) | `04a-composer-voice.png` |
| 4b | Conversation — text composer | Sub-state | `ConversationView.swift` (`ConversationTextInputView`) | `04b-composer-text.png` |
| 4c | Conversation — new-session header | Sub-state | `ConversationView.swift` body | `04c-new-session-header.png` |
| 4d | Conversation — warning banners | Sub-state | `ConversationView.swift` (`StalledChainBanner`/`PrunedGapBanner`) | `04d-banners.png` |
| 5 | New Session sheet | Sheet | `Views/SessionsView.swift` (`NewSessionView`) | `05-new-session.png` |
| 6 | Rename Session sheet | Sheet | `Views/ConversationView.swift` (`RenameSessionView`) | `06-rename.png` |
| 7 | Session Info sheet | Sheet | `Views/SessionInfoView.swift` | `07-session-info.png` |
| 8 | Recipe Menu sheet | Sheet | `Views/RecipeMenuView.swift` | `08-recipe-menu.png` |
| 9 | View Full / Message Detail sheet | Sheet | `Views/ConversationView.swift` (`MessageDetailView`) | `09-message-detail.png` |
| 10 | Command Palette overlay (⌘K) | Overlay | `Views/CommandPaletteView.swift` | `10-command-palette.png` |
| 11 | Settings window (⌘,) | Window | `Views/MacSettingsView.swift` | `11-settings-*.png` |
| 12 | Menu-bar popover | Popover | `MenuBarExtra.swift` | `12-menubar.png` |
| 13 | Native menu bar (Edit/View/Session) | Menus | `VoiceCodeApp.swift` `.commands` | `13-menus.png` |

---

## 1. Main window — split-view shell
**Source:** `VoiceCodeApp.swift` → `RootView.navigationContent` (macOS branch).
**Purpose:** the app's home; a two-column `NavigationSplitView` (`.balanced`).
**Key elements:** Sidebar (#2) + Detail (#3/#4); ⌘K command-palette overlay;
deep-link handling (`voicecode://session/{uuid}`).
**States:** sidebar visible / hidden (⌘0); detail empty vs. session loaded;
command palette open/closed.

```
┌──────────────────────────────────────────────────────────────────────┐
│ ●●●   Sessions                                       [main title bar]   │
├───────────────────────┬────────────────────────────────────────────────┤
│  SIDEBAR (200–350pt)   │  DETAIL                                         │
│  (surface #2)          │  (surface #3 empty  OR  surface #4 conversation)│
│                        │                                                 │
└───────────────────────┴────────────────────────────────────────────────┘
                ⌘K → dimmed scrim + floating Command Palette (#10)
```

---

## 2. Session sidebar
**Source:** `Views/SessionSidebarView.swift`. **Purpose:** browse/select sessions;
create new; quick command access. `List(selection:)` with `.listStyle(.sidebar)`.
**Key elements:** three collapsible sections; toolbar ＋ (New Session) and ⚙︎
(Settings).
**States:** Recent section hidden when empty; Commands section only when the
backend has sent available commands; per-row unread badges; per-directory unread
roll-up; DisclosureGroups expanded/collapsed.

```
┌──────────────────────────────┐
│ Sessions              ＋  ⚙︎  │  ← toolbar: New Session, Settings
├──────────────────────────────┤
│ ▾ 🕐 Recent                   │  (last 10, by lastModified)
│    Fix auth bug        2m ago │  ← name (13pt) + dir tail / relative time
│    Refactor parser    15m ago │
│ ▾ 📁 Projects                 │
│    ▾ voice-code          ③    │  ← folder tail + unread roll-up (accent capsule)
│        Fix auth bug          ②│  ← session row: name, dir tail, unread badge
│        Add tests             │
│    ▸ hunt910                  │
│ ▸ ⌥ Commands                  │  (top-5 MRU project commands; collapsed by default)
│        ▶ make build          │
│        ▶ make test           │
└──────────────────────────────┘
```
**Row anatomy:** Recent rows = name + last-path-component + `RelativeTimeText`.
Project rows (`SessionSidebarRow`) = name (+ provider chip if not Claude) +
last-2-path-components + accent unread capsule. Density: `.desktopDensity()`
(13pt) + `.desktopListRow()` (4/8 pt padding).

---

## 3. Empty detail (no session selected)
**Source:** `EmptyDetailView` in `SessionSidebarView.swift`. **Purpose:** detail
placeholder. **State:** shown whenever `selectedSessionId == nil`.

```
            ┌────────────────────────────────┐
            │                                │
            │        💬  (48pt, gray)        │
            │  Select a session or create    │
            │         a new one              │
            │     ⌘N to create new session   │  (tertiary)
            │                                │
            └────────────────────────────────┘
```
Also a sibling **"Session Not Found"** state (`SessionLookupView`, orange
`exclamationmark.triangle`) if a selected session was deleted, with right-click
"Copy Session ID."

---

## 4. Conversation (detail) — the heart of the app
**Source:** `Views/ConversationView.swift` (via `SessionLookupView`). **Purpose:**
read the streamed conversation; send prompts; manage the session.
**Layout (top→bottom):** optional warning banners → message list → divider →
composer block. Plus a dense toolbar.

```
┌──────────────────────────────────────────────────────────────────────────┐
│ [⚠ banner: earlier messages unavailable]                          (opt.)   │
├──────────────────────────────────────────────────────────────────────────┤
│  TOOLBAR (top-right):  🔇  ⊗  ▤recipe  ⓘ  ⤓autoscroll  ▭compact  ↻  🔎logs │
├──────────────────────────────────────────────────────────────────────────┤
│  MESSAGE LIST  (List, .plain, scroll-to-bottom anchor)                      │
│                                                                            │
│   👤 User                                              10:42 AM            │
│   ┌────────────────────────────────────────────────────────────────┐     │
│   │ refactor the parser to handle nested quotes        (blue 10%)    │     │
│   │ ⤡ View Full / ⋯ Actions                                         │     │
│   └────────────────────────────────────────────────────────────────┘     │
│   🖥 Assistant                                         10:42 AM            │
│   ┌────────────────────────────────────────────────────────────────┐     │
│   │ I'll update parseQuotes()… (PLAIN TEXT, green 10%, no markdown)  │     │
│   │ ⤡ View Full                                                     │     │
│   └────────────────────────────────────────────────────────────────┘     │
│ ────────────────────────────────────────────────────────────────────────  │
│  COMPOSER                                                                   │
│   [🎙 Voice Mode]                              ● Connected                  │
│                 ╭─────────╮                                                 │
│                 │   🎙    │   "Tap to Speak"   (100pt circle, blue 10%)     │
│                 ╰─────────╯                                                 │
└──────────────────────────────────────────────────────────────────────────┘
```

**Toolbar buttons (macOS, conditionally shown), left→right:**
`speaker.slash.fill` Stop speaking (⌘., only while speaking) · `xmark.circle.fill`
Stop prompt (⌘K) · recipe (`list.bullet.clipboard`, or active-recipe menu) ·
`info.circle` Session Info (⌘I) · `arrow.down.circle(.fill)` autoscroll toggle ·
`rectangle.compress.vertical` Compact · `arrow.clockwise` Refresh (⌘R) ·
`doc.text.magnifyingglass` Share logs with agent · `xmark.circle.fill` Remove
from queue (only if queued). Each has a `.help()` tooltip.

**Message-list states:** loading spinner ("Loading conversation…") · empty ("No
messages yet" + `message` glyph) · populated · backgrounded (blank placeholder).
**Alerts:** Stop Session?, Compact Session?, Session Already Compacted.
**Toast overlay:** green "copied/compacted" banner slides from top.

### 4a. Voice composer (`ConversationVoiceInputView`)
Big circular button: idle `mic` (blue) "Tap to Speak"; recording `mic.fill` (red,
red-10% fill) "Tap to Stop"; live transcription appears below in secondary text.
On macOS the button is wired through the shared headset/session reducer so a
headset tap and the on-screen button are one state machine. `⌥Space` push-to-talk
is attached to the whole view.

### 4b. Text composer (`ConversationTextInputView`)
Rounded-border `TextField` (1–5 lines, vertical) + circular `arrow.up.circle.fill`
send (gray when empty, blue when typed). **Return sends; Shift+Return = newline.**
Placeholder switches to "Describe a task for the agent…" in ghost mode.

### 4c. New-session composer header
Before the first prompt (`messageCount == 0`): a **segmented provider picker**
(Claude / Copilot / Cursor / OpenCode). For resumed Claude sessions: a
**Ghost-task toggle** (purple `theatermasks`, switch style) that turns the input
into a task description the agent expands into a real prompt.

### 4d. Warning banners
`StalledChainBanner` (yellow 12%, "Some earlier messages could not load") and
`PrunedGapBanner` (orange 12%, "Earlier messages unavailable"), each dismissible.

---

## 5. New Session sheet
**Source:** `NewSessionView` in `Views/SessionsView.swift`. **Size:** 450×350.
**Purpose:** create a session. Grouped `Form`.
**Key elements:** Session Name field; Working Directory field (toggles label to
"Parent Repository Path" when worktree on); Examples section; **Create Git
Worktree** toggle (with footer explainer). Toolbar Cancel / Create (Create
disabled until valid).

```
┌──────────── New Session ────────────┐
│ Session Details                      │
│   Session Name        [__________]   │
│   Working Directory   [__________]   │
│ Examples                             │
│   /Users/you/projects/myapp …        │
│ Git Worktree                         │
│   Create Git Worktree         (○ ▶)  │
│   "Creates a new git worktree…"      │
│                    [Cancel] [Create] │
└──────────────────────────────────────┘
```

---

## 6. Rename Session sheet
**Source:** `RenameSessionView` (`ConversationView.swift`). **Size:** 400×200.
Grouped form, one text field (with clear-X), Cancel / Save.

---

## 7. Session Info sheet
**Source:** `Views/SessionInfoView.swift`. **Size:** 500×500. `List` of sections.
**Purpose:** inspect & act on a session. **Sections:** Session Information (Name,
Working Directory, Git Branch [async], Session ID — each tap-to-copy) · Priority
Queue (segmented High/Med/Low, order, queued-time, add/remove — only if priority
queue enabled) · Recipe Orchestration (active recipe info + Exit, or Start Recipe)
· Actions (Export Conversation → clipboard). Toolbar Done; swipe-to-back; green
copy toasts.

```
┌──────────── Session Info ───────────┐
│ Session Information   (tap to copy)  │
│   Name            Fix auth bug   ⧉   │
│   Working Dir     ~/code/voice-code  │
│   Git Branch      design/macos…  ⧉   │
│   Session ID      8f3c…           ⧉  │
│ Priority Queue    [High][Med][Low]   │
│ Recipe Orchestration   ▶ Start Recipe│
│ Actions           ⬆ Export Conversation│
│                              [Done]  │
└──────────────────────────────────────┘
```

---

## 8. Recipe Menu sheet
**Source:** `Views/RecipeMenuView.swift`. **Size:** 450×400.
**Purpose:** pick a structured multi-step workflow to run.
**Key elements:** top toggle "Start in new session" + segmented Provider picker;
"Recipes" list (each = label + 2-line description). **States:** loading / error
(retry) / empty ("No recipes available") / list. Confirmation alert when started
in a new session. Toolbar Cancel; swipe-to-back.

---

## 9. View Full / Message Detail sheet
**Source:** `MessageDetailView` (`ConversationView.swift`). **Size:** 500×400.
**Purpose:** read a full (untruncated) message + act on it. Scrollable
`SelectableText`; bottom action row: **Copy**, **Read Aloud / Stop**, **Infer
Name** (asks the agent to name the session from this text). Title "Full Message";
Done. Lifted to the parent so list recycling can't dismiss it mid-stream.

```
┌──────────── Full Message ───────────┐
│ (scrollable, selectable full text)   │
│  …                                   │
│ ──────────────────────────────────── │
│   ⧉ Copy   🔊 Read Aloud   ✨ Infer  │
│                              [Done]  │
└──────────────────────────────────────┘
```

---

## 10. Command Palette overlay (⌘K)
**Source:** `Views/CommandPaletteView.swift` (`CommandPaletteOverlay`).
**Size:** 500×400 floating panel, radius 12, big shadow, over a 30%-black scrim.
**Purpose:** Spotlight-style keyboard access to actions. **Key elements:** search
field (`magnifyingglass`, autofocus); grouped results (Sessions / Project Commands
/ Voice) with per-row shortcut chips; ↑/↓ to move, Return to run, Esc / click-out
to dismiss; selected row = accent 20%. Empty state "No matching commands."

```
┌─────────────────────────────────────────────┐
│ 🔎  Type a command…                          │
├─────────────────────────────────────────────┤
│ Sessions                                     │
│  ＋ New session                       ⌘N     │
│  ↻ Refresh current session            ⌘R     │
│  ▭ Compact session history            ⌘⇧C    │
│  ⓘ Session info                       ⌘I     │
│ Project Commands                             │
│  ▶ make build                                │
│ Voice                                        │
│  🔇 Stop speaking                     ⌘.     │
│  🔊 Mute voice                        ⌘⇧M    │
└─────────────────────────────────────────────┘
```

---

## 11. Settings window (⌘,)
**Source:** `Views/MacSettingsView.swift`. **Size:** 500×450. SwiftUI `Settings`
scene → `TabView`, five tabs, each a grouped `Form`.

- **General** (`gear`): recent-sessions count stepper; Queue toggles (session,
  priority); Default Provider picker; Resources storage location.
- **Connection** (`network`): Server address + Port (+ Apply when changed);
  Authentication — masked key + Delete, *or* "API Key Required" + SecureField +
  Save (validates `untethered-…`, 43 chars); Test Connection (spinner + ✓/✗).
- **Voice** (`waveform`): Voice picker (System Default / All Premium / individual)
  + quality/language info + Preview; Push-to-talk shows "Option + Space"; Mute
  toggle.
- **Advanced** (`slider.horizontal.3`): Max message size stepper (50–250 KB);
  System Prompt `TextEditor`.
- **Headset** (`headphones`): Enable headset control; BlueParrott (CoreBluetooth)
  toggle; Auto-send on stop; Audible cues; + when enabled: mute warning, **Status**
  (reducer state, Now-Playing claimed/not), Reclaim slot button.

```
┌──────────────── Settings ───────────────┐
│ [General][Connection][Voice][Advanced][Headset] │
│  Server                                  │
│    Server address  [_____________]       │
│    Port            [____]                 │
│    URL: ws://…:8080            [Apply]    │
│  Authentication                          │
│    ✅ API Key Configured   untd…cdef [Delete]│
│  Test                                    │
│    [Test Connection]  ✅ Connected       │
└──────────────────────────────────────────┘
```
Suggested screenshots: `11-settings-general.png` … `11-settings-headset.png`.

---

## 12. Menu-bar popover
**Source:** `MenuBarExtra.swift`. **Width 300.** Menu-bar icon =
`waveform.circle(.fill)` (green connected / red disconnected).
**Purpose:** quick one-off voice capture without the main window.
**Sections:** directory picker (recent + Browse…) · big mic button (48pt,
`.accentColor`/`.red`, Space to toggle) · transcription/response area (blue-10%
transcript, green-10% response, Send/Cancel) · Recent Sessions (top 3, name +
relative time) · footer (Open VoiceCode / Settings… / Quit).

```
┌──────────────────────────────┐
│ 📁 voice-code/backend     ▾   │
├──────────────────────────────┤
│            🎙 (48pt)          │
│      Click or press Space     │
├──────────────────────────────┤
│ (transcription) [Send][Cancel]│
├──────────────────────────────┤
│ Recent Sessions               │
│   Fix auth bug         2m ago │
├──────────────────────────────┤
│ Open VoiceCode                │
│ Settings…                     │
│ Quit                          │
└──────────────────────────────┘
```

---

## 13. Native menu bar (Edit / View / Session)
**Source:** `VoiceCodeApp.swift` `.commands`. Adds: **Edit** → Stop Speaking ⌘.,
Mute/Unmute ⇧⌘M, Command Palette ⌘K, Reclaim Headset ⇧⌘H. **View** → Toggle
Sidebar ⌘0, Focus Sidebar ⌘1, Focus Conversation ⌘2. **Session** → New ⌘N,
Refresh ⌘R, Compact ⇧⌘C, Session Info ⌘I, Previous ⌘[, Next ⌘]. (Plus the
standard App/File/Window/Help menus from SwiftUI.)

---

## Appendix — full keyboard-shortcut map
| Shortcut | Action |
|----------|--------|
| ⌥Space (hold) | Push-to-talk |
| Return | Send prompt (text composer) |
| ⇧Return | Newline |
| ⌘K | Command palette / Stop prompt (in conversation toolbar) |
| ⌘N | New session |
| ⌘R | Refresh session |
| ⌘⇧C | Compact session |
| ⌘I | Session info |
| ⌘. | Stop speaking |
| ⌘⇧M | Mute / unmute voice |
| ⌘⇧H | Reclaim headset Now-Playing slot |
| ⌘0 / ⌘1 / ⌘2 | Toggle / focus sidebar / focus conversation |
| ⌘[ / ⌘] | Previous / next session |
| ⌘, | Settings |
| Esc | Dismiss palette / cancel |
