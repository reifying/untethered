# Manual Test: Recipe Lifecycle (Loading, Start, Steps, Timeout, Error)

**Date:** 2026-02-21
**Beads Task:** VCMOB-434d
**Platform:** iOS Simulator (iPhone 16 Pro, iOS 18.6)
**Tester:** Agent (REPL-driven)

## Summary

Comprehensive manual test of the recipe UI lifecycle. Found and fixed two bugs:
1. **P1 Bug** — `session-id` was always `nil` in `recipes-view` because it used `(.-route props)` (JS property access) instead of `(:route props)` (Clojure keyword access). `r/reactify-component` converts props to a Clojure map, so the active recipe banner never appeared and the session context was completely lost.
2. **P3 Bug** — `handle-step-started` unconditionally overwrote `step-count` with `nil` when the message didn't include it. Fixed with `cond->` to only update when present.
3. **P3 Flaky Test** — `testRapidStartAndExitSameSession` timed out because it expected 2 Combine publishes, but the debounce coalesced them into 1. Fixed to check final state instead of counting updates.

## Test Results

| # | Test | Result | Evidence |
|---|------|--------|----------|
| 1.1 | Recipe list displays (7 recipes, dark mode) | PASS | 01-recipes-list-dark.png |
| 1.2 | Active recipe banner (step info, timer, Stop button) | PASS | 02-active-recipe-banner.png |
| 1.3 | Step progression (step name updates in banner) | PASS | 03-step-progression.png |
| 1.4 | Recipe exit (banner disappears, toggle returns) | PASS | 04-after-exit.png |
| 1.5 | Recipe list light mode | PASS | 05-recipes-list-light.png |
| 1.6 | Active banner light mode (green tint, contrast) | PASS | 06-active-banner-light.png |
| 2.1 | New session toggle hidden when recipe active | PASS | 02-active-recipe-banner.png |
| 2.2 | New session toggle visible when no recipe active | PASS | 04-after-exit.png |
| 3.1 | Active recipe item shows green icon + "Running..." | PASS | 06-active-banner-light.png |
| 3.2 | Active recipe shows red "Stop" button | PASS | 02-active-recipe-banner.png |
| 3.3 | Inactive recipes show blue "Start" buttons | PASS | 01-recipes-list-dark.png |
| 4.1 | Duration timer updates (verified 5s, 6s, 24s) | PASS | Screenshots show increasing durations |
| 4.2 | Step count display ("implement of 3", "review of 3") | PASS | 02, 03 |
| 5.1 | Subscription reactivity (banner appears on state change) | PASS | Verified via REPL dispatch |
| 5.2 | Subscription reactivity (banner disappears on exit) | PASS | 04-after-exit.png |

**15 tests, 15 passed, 0 failed**

## Bugs Found and Fixed

### Bug 1: P1 — session-id always nil in recipes-view (CRITICAL)

**Root cause:** `recipes.cljs` used `(.-route props)` to read the route from React Navigation props. But `r/reactify-component` converts JS props to a Clojure map with keyword keys, so the correct access pattern is `(:route props)`. All other views in the codebase used the correct pattern.

**Impact:** The active recipe banner never showed. Recipe start/stop dispatched with `nil` session-id. The new-session toggle was always visible regardless of active recipe state.

**Fix:** Changed `(.-route props)` → `(:route props)` and `(.-navigation props)` → `(:navigation props)` in `recipes.cljs`.

### Bug 2: P3 — handle-step-started overwrites step-count with nil

**Root cause:** The `handle-step-started` event handler unconditionally wrote `step-count` from the message to the active recipe map. If the message didn't include `step-count`, it was set to `nil`, erasing the value from `recipe_started`.

**Fix:** Changed `assoc-in` to `cond->` so `step-count` is only updated when present in the message.

### Bug 3: P3 — Flaky testRapidStartAndExitSameSession Swift test

**Root cause:** Test expected exactly 2 Combine `@Published` updates, but the `scheduleUpdate` debounce (100ms) coalesced the `recipe_started` and `recipe_exited` updates into a single publish. The test's `updateCount == 2` check never triggered.

**Fix:** Changed test to check final state (`recipes.isEmpty`) instead of counting intermediate publishes.

## Files Changed

- `frontend/src/voice_code/views/recipes.cljs` — Fix props access (`:route` vs `.-route`)
- `frontend/src/voice_code/events/websocket.cljs` — Defensive `step-count` handling
- `frontend/test/voice_code/recipes_test.cljs` — New tests for step-count preservation
- `ios/VoiceCodeTests/VoiceCodeClientRecipeTests.swift` — Fix flaky debounce test

## Test Counts

- ClojureScript tests: 772 tests, 3001 assertions, 0 failures
- Swift tests: 12 executed, 3 skipped, 0 failures

## Test Environment

- iOS Simulator: iPhone 16 Pro, iOS 18.6
- React Native: 0.79
- Dark mode and light mode verified
- Backend connected and authenticated
