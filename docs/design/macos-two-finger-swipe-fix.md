# macOS Two-Finger Swipe Navigation Fix

## Overview

### Problem Statement

The current `SwipeNavigationModifier` implementation uses SwiftUI's `DragGesture` to detect swipe-to-back gestures on macOS. However, `DragGesture` detects **click-and-drag** motions (mouse button held while moving), not **two-finger trackpad swipes** which are the standard macOS navigation gesture.

On macOS, two-finger horizontal swipes are reported as scroll wheel events (`NSEvent.scrollWheel`), not drag events. This is why the implemented swipe navigation doesn't work during manual testing—users are performing two-finger swipes but the app is listening for drag events.

### Goals

1. Detect two-finger horizontal swipe gestures on macOS trackpad
2. Trigger navigation back (dismiss/pop) on swipe left gesture
3. Match native macOS app behavior (Safari, Finder, etc.)
4. Maintain no-op behavior on iOS (existing code already handles this)

### Non-goals

- Adding swipe-right navigation (forward)
- Supporting Magic Mouse swipe gestures (different event handling)
- Adding visual feedback during swipe (page curl animation)
- Customizing swipe sensitivity per-view

## Background & Context

### Current State

The existing implementation in `ios/VoiceCode/Utils/SwipeNavigationModifier.swift`:

```swift
#if os(macOS)
struct SwipeToBackModifier: ViewModifier {
    @Environment(\.dismiss) private var dismiss
    var customAction: (() -> Void)?

    func body(content: Content) -> some View {
        content
            .gesture(
                DragGesture(minimumDistance: 50)
                    .onEnded { value in
                        if value.translation.width < -50 &&
                           abs(value.translation.height) < abs(value.translation.width) {
                            if let action = customAction {
                                action()
                            } else {
                                dismiss()
                            }
                        }
                    }
            )
    }
}
#endif
```

**Why this doesn't work:**

| Gesture Type | Event Mechanism | `DragGesture` Detects? |
|--------------|-----------------|------------------------|
| Click and drag | `NSEvent.leftMouseDragged` | Yes |
| Two-finger swipe | `NSEvent.scrollWheel` with `phase` | No |
| Three-finger swipe | System gesture (app switching) | No |

Native macOS apps like Safari detect two-finger swipes by monitoring scroll wheel events with specific `phase` values that indicate gesture start/end and `scrollingDeltaX` for horizontal movement.

### Why Now

Issue voice-code-desktop3-375.11 failed manual testing because the swipe navigation feature was implemented but doesn't respond to the expected two-finger trackpad gesture.

### Related Work

- @docs/design/desktop-ux-improvements.md - Original design that proposed `DragGesture` with fallback to `NSGestureRecognizer`
- Issue voice-code-desktop3-375.2 - Created the `SwipeNavigationModifier` (now closed)
- Issue voice-code-desktop3-375.11 - Apply swipe navigation to views (failing manual test)

## Detailed Design

### Approach: NSEvent Local Monitor

Use `NSEvent.addLocalMonitorForEvents(matching: .scrollWheel)` to intercept scroll wheel events and detect horizontal swipe gestures based on scroll phase and delta values.

This approach:
- Works with SwiftUI's view modifier pattern
- Doesn't require wrapping every view in `NSViewRepresentable`
- Matches how native macOS apps handle trackpad navigation

### Code Implementation

Replace the contents of `ios/VoiceCode/Utils/SwipeNavigationModifier.swift`:

```swift
// SwipeNavigationModifier.swift
// Reusable swipe-to-back modifier for macOS

import SwiftUI

#if os(macOS)
import AppKit

/// Manages swipe gesture state for event monitor callbacks
/// Uses a class to avoid struct copy issues with NSEvent monitor closures
/// Conforms to ObservableObject for @StateObject compatibility
final class SwipeGestureState: ObservableObject {
    var accumulatedScrollX: CGFloat = 0
    var accumulatedScrollY: CGFloat = 0
    var isTracking = false

    func reset() {
        accumulatedScrollX = 0
        accumulatedScrollY = 0
        isTracking = false
    }
}

/// Detects two-finger horizontal swipe gestures on macOS trackpad
/// Uses NSEvent scroll wheel monitoring since two-finger swipes are reported as scroll events
struct SwipeToBackModifier: ViewModifier {
    @Environment(\.dismiss) private var dismiss
    var customAction: (() -> Void)?

    // Use StateObject to ensure stable reference across view updates
    @StateObject private var gestureState = SwipeGestureState()
    @State private var eventMonitor: Any?

    // Threshold for triggering navigation (in scroll units)
    private let swipeThreshold: CGFloat = 50

    func body(content: Content) -> some View {
        content
            .onAppear {
                setupEventMonitor()
            }
            .onDisappear {
                removeEventMonitor()
            }
    }

    private func setupEventMonitor() {
        // Avoid duplicate monitors
        guard eventMonitor == nil else { return }

        // Capture references needed by the closure
        let state = gestureState
        let threshold = swipeThreshold
        let dismissAction = dismiss
        let custom = customAction

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            // Only handle trackpad scrolls (not mouse wheel)
            guard event.hasPreciseScrollingDeltas else { return event }

            switch event.phase {
            case .began:
                // Start of new gesture
                state.accumulatedScrollX = 0
                state.accumulatedScrollY = 0
                state.isTracking = true

            case .changed:
                guard state.isTracking else { break }
                // Accumulate scroll deltas (negative X = swipe left)
                state.accumulatedScrollX += event.scrollingDeltaX
                state.accumulatedScrollY += event.scrollingDeltaY

            case .ended:
                guard state.isTracking else { break }
                state.isTracking = false

                // Check if swipe was predominantly horizontal and leftward
                // Must be more horizontal than vertical to avoid triggering on diagonal scrolls
                let isHorizontal = abs(state.accumulatedScrollX) > abs(state.accumulatedScrollY)
                let isLeftward = state.accumulatedScrollX < -threshold

                if isHorizontal && isLeftward {
                    if let action = custom {
                        action()
                    } else {
                        dismissAction()
                    }
                }
                state.reset()

            case .cancelled:
                state.reset()

            default:
                break
            }

            return event // Pass through to system
        }
    }

    private func removeEventMonitor() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
        gestureState.reset()
    }
}
#endif

// Extension available on both platforms (no-op on iOS)
extension View {
    /// Add swipe-to-back gesture on macOS
    /// - Parameter action: Optional custom action. If nil, uses Environment dismiss.
    /// - Returns: Modified view with swipe gesture on macOS, unchanged on iOS
    func swipeToBack(action: (() -> Void)? = nil) -> some View {
        #if os(macOS)
        modifier(SwipeToBackModifier(customAction: action))
        #else
        self // No-op on iOS
        #endif
    }
}
```

### Key Design Decisions

#### 1. Class-Based State Management

Using a `SwipeGestureState` class instead of `@State` variables:
- NSEvent monitor closures capture their environment at setup time
- With `@State` in a struct, the closure would capture a copy of the state projection
- A class reference ensures all closures share the same mutable state
- `@StateObject` ensures the class instance persists across view updates

#### 2. Local Monitor vs Global Monitor

Using `addLocalMonitorForEvents` (not `addGlobalMonitorForEvents`):
- Only receives events when app is active and focused
- No need for accessibility permissions
- Appropriate scope for navigation gestures

#### 3. Event Pass-Through

Returning the event from the monitor allows normal scroll behavior to continue. This prevents breaking scroll views that may exist in the view hierarchy.

#### 4. Phase-Based Detection

Using `NSEvent.phase` to track gesture lifecycle:
- `.began` - Two fingers touched trackpad
- `.changed` - Fingers moving
- `.ended` - Fingers lifted
- `.cancelled` - Gesture interrupted

This provides more reliable detection than single-event thresholds.

#### 5. Precise Scrolling Delta Check

`event.hasPreciseScrollingDeltas` distinguishes trackpad gestures from mouse scroll wheels, preventing false triggers from mouse scrolling.

#### 6. Horizontal-vs-Vertical Check

The gesture must be predominantly horizontal (`abs(deltaX) > abs(deltaY)`) to trigger navigation. This prevents accidental triggers when users scroll diagonally, matching the behavior of the original `DragGesture` implementation which checked:
```swift
abs(value.translation.height) < abs(value.translation.width)
```

#### 7. Synchronous Navigation Trigger

Navigation is triggered synchronously from the event monitor callback (no `DispatchQueue.main.async`). This is safe because:
- `addLocalMonitorForEvents` callbacks already run on the main thread
- SwiftUI's `dismiss()` action is main-thread safe
- Synchronous execution simplifies the control flow

#### 8. Threshold Value

The 50-unit threshold matches the original `DragGesture` implementation and provides a comfortable swipe distance that avoids accidental triggers during normal scrolling.

### Component Interactions

```
┌─────────────────────────────────────────────────────────────────┐
│                        SwiftUI View                             │
│  ┌───────────────────────────────────────────────────────────┐  │
│  │              .swipeToBack() modifier                      │  │
│  │  ┌─────────────────────────────────────────────────────┐  │  │
│  │  │           SwipeToBackModifier                       │  │  │
│  │  │                                                     │  │  │
│  │  │  @StateObject gestureState: SwipeGestureState ──────┼──┼──┐
│  │  │                                                     │  │  │
│  │  │  onAppear:  setupEventMonitor()                     │  │  │
│  │  │  onDisappear: removeEventMonitor()                  │  │  │
│  │  │                                                     │  │  │
│  │  │  NSEvent.addLocalMonitorForEvents(.scrollWheel)     │  │  │
│  │  │       │                                             │  │  │
│  │  │       ▼ (closure captures: state, dismiss, custom)  │  │  │
│  │  │  Event Handler                                      │  │  │
│  │  │       │                                             │  │  │
│  │  │       ├── .began → state.reset(), start tracking    │  │  │
│  │  │       ├── .changed → accumulate deltaX, deltaY      │  │  │
│  │  │       └── .ended → check horizontal & threshold     │  │  │
│  │  │                              │                      │  │  │
│  │  │              ┌───────────────┴───────────────┐      │  │  │
│  │  │              │ isHorizontal && isLeftward    │      │  │  │
│  │  │              ▼                               ▼      │  │  │
│  │  │      customAction?()              dismiss()        │  │  │
│  │  └─────────────────────────────────────────────────────┘  │  │
│  └───────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
                                                               │
┌──────────────────────────────────────────────────────────────┘
│  SwipeGestureState (class)
│  ├── accumulatedScrollX: CGFloat
│  ├── accumulatedScrollY: CGFloat
│  ├── isTracking: Bool
│  └── reset()
└─────────────────────────────────────────────────────────────────
```

### Views Using swipeToBack()

Per the issue requirements, these views already have `.swipeToBack()` applied:

| View | Line | Navigation Type | Action |
|------|------|-----------------|--------|
| ConversationView | 630 | NavigationStack pop | `dismiss()` |
| SessionsForDirectoryView | 334 | NavigationStack pop | `dismiss()` |
| CommandOutputDetailView | 81 | NavigationStack pop | `dismiss()` |
| CommandExecutionView | 117 | NavigationStack pop | `dismiss()` |
| SessionInfoView | 29 | Sheet dismiss | `dismiss()` |
| RecipeMenuView | 26 | Sheet dismiss | `dismiss()` |
| APIKeyManagementView | 40 | Sheet dismiss | `dismiss()` |
| DebugLogsView | 120 | NavigationStack pop | `dismiss()` |

**No changes needed to these view files** - only the modifier implementation needs to change.

### Potential Issue: Multiple Event Monitors

Each view with `.swipeToBack()` installs its own event monitor. This could cause:
1. Multiple triggers for a single swipe
2. Memory overhead from multiple monitors

**Mitigation:** The first monitor to detect the swipe will trigger navigation, which will cause views to disappear and their monitors to be removed. This is acceptable for MVP.

**Future improvement:** Use a singleton event monitor manager that views register/unregister with.

## Verification Strategy

### Testing Approach

#### Unit Tests

The existing tests in `MacOSDesktopUXTests.swift` verify that `.swipeToBack()` is applied to all required views. These tests remain valid—they test modifier application, not gesture detection.

New tests for the gesture detection logic are difficult to write because:
- `NSEvent` cannot be easily mocked in unit tests
- Event monitor behavior requires a running event loop

#### Manual Testing Checklist

| Test Case | Steps | Expected Result |
|-----------|-------|-----------------|
| ConversationView swipe back | 1. Navigate to a conversation<br>2. Two-finger swipe left on trackpad | Navigates back to session list |
| SessionsForDirectoryView swipe back | 1. Navigate to project sessions view<br>2. Two-finger swipe left | Navigates back to directory list |
| Sheet dismiss | 1. Open SessionInfoView sheet<br>2. Two-finger swipe left | Sheet dismisses |
| Scroll view interaction | 1. Navigate to conversation with long history<br>2. Two-finger scroll up/down<br>3. Two-finger swipe left | Scrolling works normally, swipe left navigates back |
| Mouse wheel no-trigger | 1. Navigate to conversation<br>2. Use mouse scroll wheel horizontally | Should NOT trigger navigation |
| Threshold sensitivity | 1. Navigate to conversation<br>2. Very small two-finger swipe left (< 50 units) | Should NOT trigger navigation |
| Diagonal scroll no-trigger | 1. Navigate to conversation<br>2. Two-finger diagonal swipe (mostly down, some left) | Should NOT trigger navigation (vertical > horizontal) |

### Acceptance Criteria

1. Two-finger swipe left on trackpad navigates back in ConversationView (pops to session list)
2. Two-finger swipe left on trackpad navigates back in SessionsForDirectoryView (pops to directory list)
3. Two-finger swipe left on trackpad dismisses sheet views (SessionInfoView, RecipeMenuView, etc.)
4. Normal vertical scrolling is not affected by swipe gesture detection
5. Mouse scroll wheel does not trigger navigation
6. Diagonal scrolling (predominantly vertical) does not trigger navigation
7. iOS build succeeds with no behavior change (modifier is no-op)
8. macOS build succeeds

## Alternatives Considered

### 1. NSPanGestureRecognizer with numberOfTouchesRequired

**Approach:** Create an `NSViewRepresentable` wrapper that adds `NSPanGestureRecognizer` configured for two-finger gestures.

```swift
struct TwoFingerSwipeView<Content: View>: NSViewRepresentable {
    let content: Content
    let onSwipeLeft: () -> Void

    func makeNSView(context: Context) -> NSHostingView<Content> {
        let view = NSHostingView(rootView: content)
        let pan = NSPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan))
        pan.numberOfTouchesRequired = 2
        view.addGestureRecognizer(pan)
        return view
    }
    // ...
}
```

**Pros:**
- Standard AppKit gesture recognizer pattern
- More explicit gesture detection

**Cons:**
- Requires wrapping content in `NSViewRepresentable`
- More complex integration with SwiftUI view hierarchy
- May conflict with SwiftUI's internal gesture handling

**Decision:** Rejected. Event monitoring is cleaner for SwiftUI integration.

### 2. SwiftUI's onContinuousHover with Custom Tracking

**Approach:** Use continuous hover tracking to detect multi-touch events.

**Cons:**
- `onContinuousHover` doesn't provide touch information
- No access to scroll/swipe events through this API

**Decision:** Rejected. Not feasible with current SwiftUI APIs.

### 3. DragGesture with SimultaneousGesture

**Approach:** Layer multiple gesture recognizers to try to catch the swipe.

**Cons:**
- `DragGesture` fundamentally doesn't receive scroll wheel events
- No amount of gesture composition fixes the underlying issue

**Decision:** Rejected. Doesn't address the root cause.

## Risks & Mitigations

### 1. Event Monitor Memory Leaks

**Risk:** If `onDisappear` isn't called (e.g., due to view lifecycle issues), event monitors could leak.

**Mitigation:**
- Explicit cleanup in `onDisappear`
- Guard against duplicate monitors in `setupEventMonitor()`
- Consider using `weak` references if issues arise

**Detection:** Monitor memory usage during extended testing sessions.

### 2. Gesture Conflicts with Scroll Views

**Risk:** Swipe detection might interfere with horizontal scroll views.

**Mitigation:**
- Events are passed through (not consumed)
- Threshold requires intentional swipe, not incidental scroll
- Can add `scrollingDeltaY` check to ensure swipe is predominantly horizontal

**Detection:** Test with scroll views in conversation history.

### 3. Multiple Triggers

**Risk:** Views with overlapping `.swipeToBack()` modifiers might all receive the event.

**Mitigation:**
- Navigation/dismiss will remove views from hierarchy
- Event is processed synchronously, so first view to trigger wins
- Could add flag to prevent re-triggering within a cooldown period

**Detection:** Test nested views with swipe gesture.

### Rollback Strategy

1. Revert `SwipeNavigationModifier.swift` to the `DragGesture` implementation
2. All view modifications remain unchanged (they just call `.swipeToBack()`)
3. No backend changes involved
4. Can be done in a single commit revert

## Implementation Notes

### File to Modify

| File | Change |
|------|--------|
| `ios/VoiceCode/Utils/SwipeNavigationModifier.swift` | Replace `DragGesture` with `NSEvent` scroll wheel monitoring |

### No Other Files Need Changes

The view files already have `.swipeToBack()` applied correctly. Only the underlying implementation of the modifier needs to change.

### Build Verification

After implementation:
```bash
# Build for macOS
xcodebuild -project ios/VoiceCode.xcodeproj -scheme VoiceCode -destination 'platform=macOS' build

# Build for iOS (verify no regression)
xcodebuild -project ios/VoiceCode.xcodeproj -scheme VoiceCode -destination 'generic/platform=iOS' build
```
