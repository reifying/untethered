// SwipeNavigationModifier.swift
// Reusable swipe-to-back modifier for macOS

import SwiftUI

#if os(macOS)
import AppKit

/// Singleton coordinator that manages swipe-to-back for the entire app.
/// Uses a stack-based approach where only the topmost registered view responds to swipes.
/// This prevents multiple views from dismissing simultaneously when nested.
final class SwipeNavigationCoordinator {
    static let shared = SwipeNavigationCoordinator()

    private var eventMonitor: Any?
    private var registeredViews: [(id: UUID, action: () -> Void)] = []

    // Gesture state
    private var accumulatedScrollX: CGFloat = 0
    private var accumulatedScrollY: CGFloat = 0
    private var isTracking = false
    private var gestureCommittedAsHorizontal = false
    private let swipeThreshold: CGFloat = 50
    private let commitSampleCount = 3  // Number of samples before committing gesture direction
    private var sampleCount = 0

    private init() {
        setupEventMonitor()
    }

    /// Register a view's dismiss action. Returns an ID for unregistration.
    func register(action: @escaping () -> Void) -> UUID {
        let id = UUID()
        registeredViews.append((id: id, action: action))
        print("[SwipeDebug] Registered view \(id.uuidString.prefix(8)), stack depth: \(registeredViews.count)")
        return id
    }

    /// Unregister a view when it disappears.
    func unregister(id: UUID) {
        registeredViews.removeAll { $0.id == id }
        print("[SwipeDebug] Unregistered view \(id.uuidString.prefix(8)), stack depth: \(registeredViews.count)")
    }

    private func setupEventMonitor() {
        // Use both local and global monitors to catch scroll events
        // Local monitor can consume events (return nil), global cannot but sees all events
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self = self else { return event }
            let shouldConsume = self.handleScrollEvent(event)
            // If this is a horizontal swipe gesture, consume the event to prevent
            // scroll views from also responding to it
            return shouldConsume ? nil : event
        }
    }

    /// Check if the first event of a gesture is predominantly horizontal
    /// This helps us decide early whether to track this as a navigation gesture
    private func isInitiallyHorizontal(_ event: NSEvent) -> Bool {
        // For the first event, check if horizontal component dominates
        return abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) * 1.5
    }

    /// Returns true if the event should be consumed (not passed to other views)
    private func handleScrollEvent(_ event: NSEvent) -> Bool {
        // Only handle trackpad scrolls (not mouse wheel)
        guard event.hasPreciseScrollingDeltas else { return false }

        switch event.phase {
        case .began:
            accumulatedScrollX = event.scrollingDeltaX
            accumulatedScrollY = event.scrollingDeltaY
            sampleCount = 1

            // Immediately check if this looks like a horizontal gesture
            // We need to decide NOW because scroll views will claim the gesture otherwise
            let looksHorizontal = isInitiallyHorizontal(event)
            gestureCommittedAsHorizontal = looksHorizontal
            isTracking = true

            print("[SwipeDebug] Gesture began - deltaX: \(event.scrollingDeltaX), deltaY: \(event.scrollingDeltaY), looksHorizontal: \(looksHorizontal)")

            // Consume immediately if it looks horizontal to prevent scroll view from claiming it
            return looksHorizontal

        case .changed:
            guard isTracking else { return false }
            accumulatedScrollX += event.scrollingDeltaX
            accumulatedScrollY += event.scrollingDeltaY
            sampleCount += 1

            // If we haven't committed yet and have enough samples, make final decision
            if sampleCount == commitSampleCount {
                // Re-evaluate with more data - require 2x horizontal dominance
                let isStronglyHorizontal = abs(accumulatedScrollX) > abs(accumulatedScrollY) * 2
                if gestureCommittedAsHorizontal && !isStronglyHorizontal {
                    // We initially thought it was horizontal but now it's not - abort
                    print("[SwipeDebug] Gesture reclassified as VERTICAL, releasing")
                    gestureCommittedAsHorizontal = false
                } else if isStronglyHorizontal {
                    gestureCommittedAsHorizontal = true
                    print("[SwipeDebug] Gesture confirmed as HORIZONTAL")
                }
            }

            // Consume horizontal swipe events to prevent scroll view interference
            return gestureCommittedAsHorizontal

        case .ended:
            guard isTracking else { return false }
            isTracking = false
            let wasHorizontal = gestureCommittedAsHorizontal

            print("[SwipeDebug] Gesture ended - accumulatedX: \(accumulatedScrollX), accumulatedY: \(accumulatedScrollY), committedHorizontal: \(gestureCommittedAsHorizontal)")

            // Swipe LEFT (fingers move right-to-left) = POSITIVE scrollingDeltaX on macOS
            let isSwipeLeft = accumulatedScrollX > swipeThreshold

            print("[SwipeDebug] isSwipeLeft: \(isSwipeLeft)")

            if gestureCommittedAsHorizontal && isSwipeLeft {
                // Only trigger the topmost (last registered) view's action
                if let topView = registeredViews.last {
                    print("[SwipeDebug] TRIGGERING NAVIGATION for view \(topView.id.uuidString.prefix(8))")
                    topView.action()
                } else {
                    print("[SwipeDebug] No views registered for swipe")
                }
            }

            accumulatedScrollX = 0
            accumulatedScrollY = 0
            gestureCommittedAsHorizontal = false
            sampleCount = 0

            return wasHorizontal  // Consume the end event too if it was a horizontal gesture

        case .cancelled:
            let wasHorizontal = gestureCommittedAsHorizontal
            isTracking = false
            accumulatedScrollX = 0
            accumulatedScrollY = 0
            gestureCommittedAsHorizontal = false
            sampleCount = 0
            print("[SwipeDebug] Gesture cancelled")
            return wasHorizontal

        default:
            return false
        }
    }
}

/// View modifier that registers with the singleton coordinator
struct SwipeToBackModifier: ViewModifier {
    @Environment(\.dismiss) private var dismiss
    var customAction: (() -> Void)?

    @State private var registrationId: UUID?

    func body(content: Content) -> some View {
        content
            .onAppear {
                // Capture dismiss in a closure that can be called later
                let dismissAction = dismiss
                let custom = customAction
                registrationId = SwipeNavigationCoordinator.shared.register {
                    if let action = custom {
                        action()
                    } else {
                        dismissAction()
                    }
                }
            }
            .onDisappear {
                if let id = registrationId {
                    SwipeNavigationCoordinator.shared.unregister(id: id)
                    registrationId = nil
                }
            }
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
