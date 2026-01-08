// SystemColors.swift
// Cross-platform system color extensions

import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Extension providing cross-platform system colors.
///
/// # Usage
/// Instead of:
/// ```swift
/// #if os(iOS)
/// .background(Color(UIColor.systemBackground))
/// #elseif os(macOS)
/// .background(Color(NSColor.windowBackgroundColor))
/// #endif
/// ```
///
/// Use:
/// ```swift
/// .background(Color.systemBackground)
/// ```
extension Color {
    /// The primary system background color.
    /// - iOS: `UIColor.systemBackground`
    /// - macOS: `NSColor.windowBackgroundColor`
    static var systemBackground: Color {
        #if os(iOS)
        Color(UIColor.systemBackground)
        #else
        Color(NSColor.windowBackgroundColor)
        #endif
    }

    /// The secondary system background color.
    /// - iOS: `UIColor.secondarySystemBackground`
    /// - macOS: `NSColor.controlBackgroundColor`
    static var secondarySystemBackground: Color {
        #if os(iOS)
        Color(UIColor.secondarySystemBackground)
        #else
        Color(NSColor.controlBackgroundColor)
        #endif
    }

    /// The grouped system background color (used in grouped table views).
    /// - iOS: `UIColor.systemGroupedBackground`
    /// - macOS: `NSColor.windowBackgroundColor`
    static var systemGroupedBackground: Color {
        #if os(iOS)
        Color(UIColor.systemGroupedBackground)
        #else
        Color(NSColor.windowBackgroundColor)
        #endif
    }
}
