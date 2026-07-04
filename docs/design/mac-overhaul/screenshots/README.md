# Screenshots — current state (CAPTURE PENDING)

**Status: no screenshots captured yet.** They could not be produced from the
automated agent environment. The written package (`../DESIGN-BRIEF.md`,
`../screen-inventory.md`, `../user-flows.md`) carries detailed ASCII wireframes,
exact colors/fonts/sizes, and per-screen states to compensate until real PNGs
are dropped here.

## Why they're pending (so this isn't re-attempted blindly)
The Mac app **builds and runs** fine (`make build-mac` succeeds) and the backend
**is up on :8080**, so this is purely a capture-permission/tooling gap in the
headless session — not a build or runtime problem:

1. **`screencapture` is blocked** — returns *"could not create image from
   display"* because the automation host lacks macOS **Screen Recording**
   permission (System Settings → Privacy & Security → Screen Recording).
2. **`xcode-cli preview` route unavailable** — the Xcode MCP bridge wasn't
   running (`ECONNREFUSED`), and the Mac-reachable SwiftUI views
   (`SessionSidebarView`, `ConversationView`, `CommandPaletteView`,
   `MacSettingsView`, `MenuBarExtra`) have **no `#Preview` macros**. Adding them
   would mean editing app source, which this workstream is told not to do.
3. The repo's `screenshots-combined.png` (root) is **iOS** App Store imagery, not
   the Mac app.

## How to capture them (fast path — a few minutes on Travis's machine)
The build already exists. Run the app and screenshot each window.

```bash
# 1. Launch the already-built Mac app (talks to the live backend on :8080)
make run-mac
#    …or open the built bundle directly:
open ~/Library/Developer/Xcode/DerivedData/VoiceCode-*/Build/Products/Debug/VoiceCodeMac.app
```

Then, for each surface, bring it frontmost and grab it:
- **Window/sheet capture (cleanest):** `⌘⇧4` then press **Space** → click the
  window. Or CLI per-window: `screencapture -o -w screenshots/<name>.png`.
- **Menu-bar popover:** click the waveform menu-bar icon, then `⌘⇧4`+drag the
  region.
- **Command palette:** press **⌘K** in the main window, then capture the window.

Capture both **Light and Dark** appearance if possible (the app uses system
semantic colors and adapts automatically).

## Filenames to use (referenced by `../screen-inventory.md`)
| File | Surface |
|------|---------|
| `01-main-window.png` | Main split-view window (sidebar + conversation) |
| `02-sidebar.png` | Session sidebar (Recent / Projects / Commands) |
| `03-empty-detail.png` | Empty detail state |
| `04-conversation.png` | Conversation with messages + toolbar |
| `04a-composer-voice.png` | Voice composer (idle + recording) |
| `04b-composer-text.png` | Text composer |
| `04c-new-session-header.png` | New-session provider picker / ghost toggle |
| `04d-banners.png` | Stalled / pruned-gap warning banners |
| `05-new-session.png` | New Session sheet |
| `06-rename.png` | Rename Session sheet |
| `07-session-info.png` | Session Info sheet |
| `08-recipe-menu.png` | Recipe Menu sheet |
| `09-message-detail.png` | View Full / Message Detail sheet |
| `10-command-palette.png` | Command Palette overlay (⌘K) |
| `11-settings-general.png` … `11-settings-headset.png` | Settings tabs |
| `12-menubar.png` | Menu-bar popover |
| `13-menus.png` | Native Edit/View/Session menus |
| `00-app-icon.png` | App icon (brand reference — the orange snapping rope) |

> Tip: the app icon (brand reference) is already in-repo at
> `ios/VoiceCode/Assets.xcassets/AppIcon.appiconset/icon-1024.png` — copy it here
> as `00-app-icon.png` for the designer.
