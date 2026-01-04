// ClipboardUtility.swift
// Cross-platform clipboard and haptic feedback utilities

import Foundation
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

enum ClipboardUtility {
    /// Copy text to system clipboard
    static func copy(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }

    /// Trigger success haptic feedback (iOS only, no-op on macOS)
    static func triggerSuccessHaptic() {
        #if os(iOS)
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)
        #endif
        // macOS: No haptic feedback available
    }
}
