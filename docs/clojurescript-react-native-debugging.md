# ClojureScript React Native Debugging Guide

Lessons learned from debugging Reagent components in React Native with shadow-cljs.

## Critical: Props Access in React Navigation Screens

**The Problem**: `r/reactify-component` (used to wrap Reagent components for React Navigation) converts JavaScript props to a ClojureScript map. This means:

```clojure
;; WRONG - JS property access on CLJS map returns nil
(.-route props)      ;; => nil
(.-navigation props) ;; => nil

;; CORRECT - CLJS map keyword access
(:route props)       ;; => #js {:params #js {...}}
(:navigation props)  ;; => #js {:navigate ...}
```

**Symptoms**:
- "Cannot read property 'params' of undefined"
- Components show empty state despite subscriptions having data
- Navigation calls fail silently

**The Fix**: Use keyword access for the outer props map, then JS property access for nested React objects:

```clojure
(defn my-view [props]
  ;; Props is a CLJS map - use keyword access
  (let [route (:route props)
        navigation (:navigation props)
        ;; route is a JS object - use .- access for its properties
        params (when route (.-params route))
        session-id (when params (.-sessionId params))]
    ...))
```

## Debug Atom Pattern for REPL Inspection

When component state is hard to inspect, add a debug atom to capture recent calls:

```clojure
(defonce debug-state (atom {:calls [] :max-calls 10}))

(defn- record-debug! [label data]
  (swap! debug-state update :calls
         (fn [calls]
           (take (:max-calls @debug-state)
                 (cons {:label label
                        :data data
                        :timestamp (js/Date.now)}
                       calls)))))

;; In your component:
(defn my-view [props]
  (record-debug! :outer-props {:props props
                               :keys (js-keys props)
                               :type (type props)})
  ...)
```

Then inspect via REPL:
```clojure
@voice-code.views.session-list/debug-state
```

**Key insight from this session**: Inspecting `(type props)` and `(js-keys props)` revealed props was a CLJS PersistentArrayMap, not a JS object.

## Reagent Component Patterns with React Navigation

### Form-3 (Recommended for Navigation Screens)

Use `r/create-class` when you need subscriptions to trigger re-renders:

```clojure
(defn session-list-view [props]
  (let [route (:route props)
        directory (some-> route .-params .-directory)]
    (r/create-class
     {:reagent-render
      (fn [_]
        ;; Subscriptions MUST be inside :reagent-render
        (let [sessions @(rf/subscribe [:sessions/for-directory directory])]
          [:> rn/View ...]))})))
```

### Why Not Form-2?

Form-2 (returning a render function) can work but is trickier with React Navigation because:
1. The outer function runs once when the screen mounts
2. Subscriptions in the outer function don't establish reactive context
3. The inner function may not re-run when subscriptions change

## Hot Reload vs Fresh Restart

**When hot reload works**:
- Simple code changes
- Adding/modifying functions
- Style changes

**When you need a fresh restart**:
- Changes to `defonce` atoms (they persist across reloads)
- Changes to component structure (Form-2 vs Form-3)
- Navigation state corruption
- Debug atoms showing stale data

**Fresh restart command**:
```bash
# Kill the app and restart
cd frontend && npm run ios
```

**Hot reload a namespace**:
```clojure
(require '[voice-code.views.session-list] :reload)
```

Note: After reloading core namespaces, you'll need to re-authenticate.

## Checking What's Running

### shadow-cljs Watch

```bash
# Check if shadow-cljs is running
ps aux | grep shadow-cljs

# Check shadow-cljs port (default 9630)
curl -s http://localhost:9630 | head -20

# Start if needed
cd frontend && JAVA_HOME=/opt/homebrew/opt/openjdk/libexec/openjdk.jdk/Contents/Home npx shadow-cljs watch app &
```

### Metro Bundler

```bash
# Check Metro port (default 8081)
curl -s http://localhost:8081/status

# If not running, start via:
cd frontend && npm start
```

### nREPL Connections

```bash
# Find nREPL port files
find . -name ".nrepl-port" 2>/dev/null

# Backend nREPL (clojure-mcp)
cat backend/.nrepl-port

# Frontend nREPL (shadow-cljs)
cat frontend/.shadow-cljs/nrepl.port
```

### iOS Simulator

```bash
# List booted simulators
xcrun simctl list devices | grep Booted

# Take screenshot for debugging
xcrun simctl io booted screenshot /tmp/debug-screenshot.png
```

## REPL-Driven Debugging Workflow

### 1. Authenticate via REPL

```clojure
(do
  (require '[re-frame.core :as rf])
  (rf/dispatch-sync [:settings/update :server-port 8080])
  (swap! re-frame.db/app-db assoc :api-key "untethered-<key>")
  (swap! re-frame.db/app-db assoc :ios-session-id (str (random-uuid)))
  (voice-code.websocket/connect! {:server-url "localhost" :server-port 8080})
  "Connecting...")
```

### 2. Check Connection State

```clojure
{:status @(rf/subscribe [:connection/status])
 :authenticated? @(rf/subscribe [:connection/authenticated?])
 :session-count (count @(rf/subscribe [:sessions/all]))}
```

### 3. Test Subscriptions Directly

```clojure
;; Does the subscription return data?
@(rf/subscribe [:sessions/for-directory "/path/to/project"])

;; Check raw app-db
(get-in @re-frame.db/app-db [:sessions])
```

### 4. Navigate Programmatically

```clojure
(voice-code.views.core/navigate! "SessionList"
  {:directory "/path/to/project" :directoryName "my-project"})
```

### 5. Inspect Debug Atoms

```clojure
;; If you added debug atoms
@voice-code.views.session-list/debug-state

;; Recent calls
(->> @voice-code.views.session-list/debug-state
     :calls
     (take 3))
```

## Common Pitfalls

### 1. "No available JS runtime"

The ClojureScript REPL requires a running React Native app. The shadow-cljs REPL evaluates code in the actual JavaScript runtime.

**Fix**: Start the app with `cd frontend && npm run ios`

### 2. Subscriptions Return Data But Component Shows Empty

Usually means subscriptions are being read outside a reactive context.

**Diagnosis**:
```clojure
;; This works in REPL:
@(rf/subscribe [:sessions/all])  ;; => [{...} {...}]

;; But component shows empty state
```

**Fix**: Move subscriptions inside `:reagent-render` function.

### 3. Navigation State Says X But UI Shows Y

React Navigation state can get out of sync with what's displayed, especially after hot reloads.

**Diagnosis**:
```clojure
(.getState voice-code.views.core/nav-ref)
;; Shows different screen than what's visible
```

**Fix**: Fresh app restart.

### 4. Props Undefined in Nested Functions

When using Form-2 or Form-3, the inner function receives the same props but you should use closure over the outer let bindings:

```clojure
(defn my-view [props]
  (let [nav (:navigation props)]  ;; Capture in outer let
    (r/create-class
     {:reagent-render
      (fn [_]  ;; Don't rely on inner props
        [:> rn/Button {:onPress #(when nav (.navigate nav "Home"))}])})))
```

## Testing After Changes

Always run tests after modifying view components:

```bash
cd frontend && npm test
```

Tests should pass before committing. The test suite catches many reactivity issues.
