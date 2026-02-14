@AGENTS.md

This is January 2026 or later

## Clojure MCP Setup (MANDATORY — Do Not Skip)

**DO NOT edit any Clojure (.clj) or ClojureScript (.cljs) files until the clojure-mcp tools are confirmed working.** This is a hard requirement, not a suggestion. Without a working REPL connection, you cannot evaluate code, run tests properly, or verify your changes. Editing Clojure/ClojureScript blind leads to broken code that wastes everyone's time.

**Before touching ANY .clj or .cljs file:**
1. Verify MCP tools are available (try calling a clojure-mcp tool)
2. If tools are not available, set them up using the steps below
3. If setup fails, STOP and ask the user for help — do not proceed with edits

If MCP tools are not available, set them up:

**1. Start nREPL:**
```bash
cd backend && clojure -M:nrepl &
```
Creates `backend/.nrepl-port` with port number.

**2. Add MCP config to `~/.claude.json`:**
```bash
PROJECT_PATH=$(pwd)
jq --arg path "$PROJECT_PATH" '.projects[$path].mcpServers["clojure-mcp"] = {
  "type": "stdio",
  "command": "/bin/sh",
  "args": ["-c", "PORT=$(cat backend/.nrepl-port); cd backend && clojure -X:mcp :port $PORT"],
  "env": {}
}' ~/.claude.json > ~/.claude.json.tmp && mv ~/.claude.json.tmp ~/.claude.json
```

**3. Restart Claude Code** for changes to take effect.

Keep all responses brief and direct. No verbose explanations or unnecessary commentary.

**Voice dictation:** Most prompts are spoken via phone. If a request is unclear, ask for clarification—voice transcription may be inaccurate.

We don't care about work duration estimates. Don't provide estimates in hours, days, weeks, etc. about how long development will take.

Do not write implementation code without also writing tests. We want test development to keep pace with code development. Do not say that work is complete if you haven't written corresponding tests. Do not say that work is complete if you haven't run tests. Running tests and ensuring they all pass is required before completing any development step. By definition, development is not "done" if we do not have tests proving that the code works and meets our intent.

## Running Tests

Run `make test` (or other test targets) directly—never redirect to `/dev/null`. The `wrap-command` script already captures output and shows the last 100 lines. On failure, read the full log from the `OUTPUT_FILE` path printed at the start instead of re-running tests.

Always log the actual invalid values with sufficient context (names, paths) when validation fails so we can diagnose issues from logs alone.

See @STANDARDS.md for coding conventions.

## Test Philosophy

We conform to the test pyramid philosophy for testing.

## Cross-Platform Verification (MANDATORY)

This is a React Native app targeting **both iOS and Android**. Do not treat Android as an afterthought. Every UI change, new screen, or behavioral modification must be verified on both platforms before work is considered complete.

**Core rule:** If you can't verify it on both platforms, say so explicitly — don't silently assume it works.

### Verification Workflow

1. **iOS Simulator** — `make rn-ios`, `make rn-screenshot`, `make rn-restart`
2. **Android Emulator** — `make rn-android`, `make rn-android-screenshot`, `make rn-android-restart`
3. **REPL testing** — `clojurescript_eval` works on whichever platform is running (it connects through the JS runtime, not the native layer)
4. **E2E tests** — Maestro flows should target both platforms when platform-specific behavior is involved

After any UI or layout change, take screenshots on both platforms and compare. Platform rendering differences are real and frequent.

### Native Look and Feel

Do not build a single "cross-platform" UI that looks identical on both platforms. Each platform has distinct conventions that users expect. Violating these makes the app feel foreign.

**Navigation:**
- iOS: Bottom tab bar for top-level navigation. Swipe-from-left-edge to go back.
- Android: Top app bar with optional navigation drawer. Hardware/gesture back button. No swipe-from-edge expectation.

**Typography:**
- iOS: San Francisco font. Hierarchy through font weight variation more than size.
- Android: Roboto font. Hierarchy through contrasting font sizes. Material Design type scale.

**Buttons and Touch Feedback:**
- iOS: Opacity fade on press (`TouchableOpacity` or `Pressable` with opacity).
- Android: Ripple effect on press (`TouchableNativeFeedback` or `Pressable` with `android_ripple`). Never use opacity-fade as the sole touch feedback on Android.

**Alerts and Dialogs:**
- iOS: Centered modal with stacked or side-by-side buttons, divider lines, sentence case.
- Android: Material dialog with right-aligned text buttons, ALL CAPS button labels.

**Icons:**
- iOS: SF Symbols style — thin strokes, line-based.
- Android: Material Icons style — bolder, geometric, filled variants.

**Shadows and Elevation:**
- iOS: `shadowColor`, `shadowOffset`, `shadowOpacity`, `shadowRadius` on Views.
- Android: `elevation` prop only. iOS shadow properties are ignored on Android.

**Safe Areas:**
- iOS: Notch, Dynamic Island, home indicator — use `SafeAreaView` or `useSafeAreaInsets`.
- Android: Status bar, navigation bar (gesture or button), punch-hole cameras — handle separately with `StatusBar.currentHeight` and edge-to-edge considerations.

**Switches and Controls:**
- iOS: Rounded toggle switch (UISwitch style).
- Android: Material Design switch with track and thumb.

### Implementation Strategy

Use `Platform.OS` or `Platform.select` for minor differences. For components with significant platform divergence, use platform-specific file extensions (`.ios.cljs` / `.android.cljs`) rather than littering components with conditionals.

When in doubt about a platform convention, refer to:
- [Apple Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/)
- [Material Design Guidelines](https://m3.material.io/)

### What Requires Dual-Platform Screenshots

- Any new screen or view
- Layout changes (flexbox behaves subtly differently in edge cases)
- Custom styling (shadows, borders, fonts)
- Safe area adjustments
- Keyboard handling (Android `windowSoftInputMode` vs iOS keyboard avoidance)
- Permission dialogs (each platform has its own native dialog)
- Status bar styling
