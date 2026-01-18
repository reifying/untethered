---
name: reagent-debug
description: This skill should be used when debugging Reagent components, React Navigation issues, "component shows empty state", "subscriptions not updating", "props undefined", or troubleshooting reactivity problems in the React Native app.
version: 0.1.0
---

# Reagent + React Navigation Debugging

Debug guide for Reagent components wrapped with React Navigation.

## Critical: Props Access Pattern

`r/reactify-component` converts JS props to a **CLJS map**:

```clojure
;; WRONG - returns nil
(.-route props)

;; CORRECT - CLJS map access
(:route props)

;; Then JS access for nested React objects
(let [route (:route props)
      params (.-params route)]
  ...)
```

## Debug Atom Pattern

Add to component file for REPL inspection:

```clojure
(defonce debug-state (atom {:calls [] :max-calls 10}))

(defn- record-debug! [label data]
  (swap! debug-state update :calls
         (fn [calls]
           (take 10 (cons {:label label :data data :ts (js/Date.now)} calls)))))

;; In component:
(defn my-view [props]
  (record-debug! :props {:type (type props)
                         :keys (keys props)
                         :route (:route props)})
  ...)
```

Inspect via REPL:
```clojure
@voice-code.views.session-list/debug-state
```

## Form-3 Pattern for Navigation Screens

```clojure
(defn my-screen [props]
  (let [route (:route props)
        param (some-> route .-params .-myParam)]
    (r/create-class
     {:reagent-render
      (fn [_]
        ;; Subscriptions MUST be here for reactivity
        (let [data @(rf/subscribe [:my-subscription param])]
          [:> rn/View ...]))})))
```

## Diagnostic Steps

### 1. Check if subscription has data
```clojure
@(rf/subscribe [:sessions/for-directory "/path"])
```

### 2. Check props type
```clojure
(record-debug! :inspect {:type (type props)
                         :cljs-map? (map? props)
                         :keys (keys props)})
```

### 3. Verify navigation state
```clojure
(.getState voice-code.views.core/nav-ref)
```

### 4. Check what's running
```bash
# shadow-cljs
curl -s http://localhost:9630 | head -5

# Metro
curl -s http://localhost:8081/status

# Simulator
xcrun simctl list devices | grep Booted
```

## Common Fixes

| Symptom | Cause | Fix |
|---------|-------|-----|
| Empty component, subscription has data | Subscriptions outside reactive context | Move to `:reagent-render` |
| "Cannot read property 'params' of undefined" | Using `.-` on CLJS map | Use `(:route props)` |
| UI stuck after hot reload | Stale state | Fresh app restart |
| "No available JS runtime" | App not running | `cd frontend && npm run ios` |

## When to Fresh Restart

- Changed `defonce` atoms
- Changed component structure (Form-2 → Form-3)
- Navigation state corruption
- Debug atoms showing stale data

## Full Documentation

See `@docs/clojurescript-react-native-debugging.md` for complete guide.
