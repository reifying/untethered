// SwipeNavigationModifier.swift
// Reusable swipe-to-back modifier for macOS

import SwiftUI

#if os(macOS)
struct SwipeToBackModifier: ViewModifier {
    @Environment(\.dismiss) private var dismiss
    var customAction: (() -> Void)?

    func body(content: Content) -> some View {
        content
            .gesture(
                DragGesture(minimumDistance: 50)
                    .onEnded { value in
                        // Two-finger swipe left detection
                        // Horizontal movement, leftward direction
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
