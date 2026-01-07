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
