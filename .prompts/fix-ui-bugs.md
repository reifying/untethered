# Fix All UI Bugs - Agent Prompt

You are a senior engineer fixing UI bugs in a React Native + ClojureScript app. Your job is to fix ALL open UI bugs, verify each fix via REPL testing, and not stop until every bug is resolved.

## Your Bugs to Fix

Run `bd list --status=open` to get the current list. As of now, these are the P0-P2 bugs:

| ID | Priority | Title |
|----|----------|-------|
| VCMOB-1i4 | P0 | Navigation crash - Cannot read property 'navigate' of undefined |
| VCMOB-i3u | P0 | App shows blank white screen after restart |
| VCMOB-lu0 | P0 | DirectoryList session count not displayed - clj->js key conversion |
| VCMOB-46u | P1 | Unsafe navigation calls - missing nil checks (ROOT CAUSE of 1i4) |
| VCMOB-r0q | P1 | Voice buttons not visible on Conversation screen |
| VCMOB-ada | P2 | Connection error displays as [object Object] |
| VCMOB-3hr | P2 | Persistent REPL exception toast errors |

## Strategy

1. **Start with root causes** - Fix VCMOB-46u first (unsafe navigation) since it causes VCMOB-1i4
2. **Fix in priority order** - P0 → P1 → P2
3. **Verify each fix via REPL** before marking closed
4. **Run ui-test-agent skill** after all fixes to verify no regressions

## Tools Available

- **ClojureScript REPL** (`clojurescript_eval`) - Test fixes live
- **Clojure editing tools** (`clojure_edit`, `clojure_edit_replace_sexp`) - Modify .cljs files
- **Screenshots** (`make rn-screenshot`) - Visual verification
- **Beads** (`bd show`, `bd close`) - Track bug status

## Fixing Process for Each Bug

```
1. bd show <bug-id>           # Understand the bug
2. Read relevant source files  # Find the code causing it
3. Write the fix               # Edit the ClojureScript
4. Reload namespace in REPL    # (require '[ns] :reload)
5. Test the fix via REPL       # Verify behavior changed
6. Take screenshot if visual   # Confirm UI looks right
7. bd close <bug-id>           # Mark as fixed
```

## Bug-Specific Guidance

### VCMOB-46u: Unsafe navigation calls (FIX FIRST)
**Files:** `directory_list.cljs`, `session_list.cljs`, `command_menu.cljs`
**Fix:** Wrap all `.navigate` calls with nil check:
```clojure
;; BEFORE
(.navigate navigation "Settings")

;; AFTER
(when navigation
  (.navigate navigation "Settings"))
```

### VCMOB-lu0: Session count not displayed
**File:** `directory_list.cljs`
**Issue:** `clj->js` converts `:session-count` to `sessionCount`, but code reads `.-session-count`
**Fix:** Use `.-sessionCount` (camelCase) when reading from JS object

### VCMOB-r0q: Voice buttons not visible
**File:** `conversation.cljs`
**Issue:** Voice FABs may be conditionally hidden or not rendered
**Fix:** Check render conditions, ensure FABs are always shown

### VCMOB-ada: Error shows [object Object]
**File:** Likely in `events/websocket.cljs` or `subs.cljs`
**Issue:** JS error object converted to string without extracting message
**Fix:** Use `(.-message error)` or `(str (.-message error))` when storing error

### VCMOB-3hr: REPL exception toasts
**Issue:** Errors from REPL evaluation bubbling to UI toast system
**Fix:** Either suppress REPL errors from toast or fix the underlying protocol error

### VCMOB-i3u: Blank screen after restart
**Issue:** May be related to navigation initialization or bundle loading
**Fix:** Investigate after fixing navigation issues - may resolve itself

## Verification

After fixing all bugs, run the ui-test-agent skill to verify:
```
/ui-test-agent
```

This will systematically test all screens and interactions.

## Completion Criteria

You are DONE when:
1. `bd list --status=open --type=bug` returns no UI bugs
2. ui-test-agent completes without finding new bugs
3. All screens render correctly
4. No error toasts appear during normal usage

## Rules

- **Do not stop** until all bugs are fixed
- **Test every fix** via REPL before closing
- **Create new bugs** if you discover issues while fixing
- **Use up to 1000 tool calls** - thoroughness over speed
- **Hot reload** after each fix: `(require '[namespace] :reload)`

## Start Now

1. Run `bd list --status=open --type=bug` to see current bugs
2. Run `bd show VCMOB-46u` to start with root cause
3. Begin fixing
