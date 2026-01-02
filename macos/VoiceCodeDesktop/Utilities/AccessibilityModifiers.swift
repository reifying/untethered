// AccessibilityModifiers.swift
// VoiceOver accessibility support and Reduce Motion per Section 14.4

import SwiftUI

// MARK: - Reduce Motion Support

/// Environment key for accessing system Reduce Motion preference
struct ReduceMotionKey: EnvironmentKey {
    static let defaultValue: Bool = false
}

extension EnvironmentValues {
    /// Whether the user has enabled "Reduce Motion" in System Settings
    var reduceMotion: Bool {
        get { self[ReduceMotionKey.self] }
        set { self[ReduceMotionKey.self] = newValue }
    }
}

/// View modifier that conditionally applies animation based on Reduce Motion setting
struct ReduceMotionModifier<A: Equatable>: ViewModifier {
    let animation: Animation?
    let value: A
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : animation, value: value)
    }
}

extension View {
    /// Applies animation only when Reduce Motion is not enabled
    /// - Parameters:
    ///   - animation: The animation to apply
    ///   - value: Value to observe for changes
    func accessibleAnimation<V: Equatable>(_ animation: Animation?, value: V) -> some View {
        modifier(ReduceMotionModifier(animation: animation, value: value))
    }

    /// Conditionally applies animation based on Reduce Motion setting
    /// Falls back to instant transitions when Reduce Motion is enabled
    @ViewBuilder
    func reduceMotionAnimation<V: Equatable>(_ animation: Animation?, value: V) -> some View {
        modifier(ReduceMotionModifier(animation: animation, value: value))
    }
}

// MARK: - VoiceOver Accessibility Extensions

extension View {
    /// Adds accessibility label and hint for VoiceOver users
    /// - Parameters:
    ///   - label: The primary accessibility label
    ///   - hint: Optional hint describing what happens when activated
    func accessibilityLabeled(_ label: String, hint: String? = nil) -> some View {
        self
            .accessibilityLabel(label)
            .accessibilityHint(hint ?? "")
    }

    /// Makes a view accessible as a button with proper traits
    func accessibilityButton(label: String, hint: String? = nil) -> some View {
        self
            .accessibilityLabel(label)
            .accessibilityHint(hint ?? "")
            .accessibilityAddTraits(.isButton)
    }

    /// Makes a view accessible as a header for navigation
    func accessibilityHeader(_ label: String) -> some View {
        self
            .accessibilityLabel(label)
            .accessibilityAddTraits(.isHeader)
    }

    /// Adds state information for expandable/collapsible elements
    func accessibilityExpandable(isExpanded: Bool, label: String) -> some View {
        self
            .accessibilityLabel("\(label), \(isExpanded ? "expanded" : "collapsed")")
            .accessibilityHint("Double-tap to \(isExpanded ? "collapse" : "expand")")
    }

    /// Adds accessibility value for elements with state (like toggles, progress)
    func accessibilityProgressValue(_ progress: Double, label: String) -> some View {
        self
            .accessibilityLabel(label)
            .accessibilityValue("\(Int(progress * 100)) percent")
    }

    /// Groups related elements and provides a combined label
    func accessibilityGroup(label: String) -> some View {
        self
            .accessibilityElement(children: .combine)
            .accessibilityLabel(label)
    }

    /// Hides decorative elements from VoiceOver
    func accessibilityDecorative() -> some View {
        self.accessibilityHidden(true)
    }
}

// MARK: - Session Row Accessibility

/// Provides accessibility information for session rows
struct SessionAccessibility {
    let displayName: String
    let workingDirectory: String
    let messageCount: Int32
    let unreadCount: Int32
    let isLocked: Bool
    let isInDetachedWindow: Bool

    /// Generates a comprehensive accessibility label for the session
    var accessibilityLabel: String {
        var components = [displayName]

        // Add directory info
        let directoryName = (workingDirectory as NSString).lastPathComponent
        components.append("in \(directoryName)")

        // Add message count
        if messageCount > 0 {
            components.append("\(messageCount) message\(messageCount == 1 ? "" : "s")")
        }

        // Add unread count
        if unreadCount > 0 {
            components.append("\(unreadCount) unread")
        }

        // Add status
        if isLocked {
            components.append("processing")
        }

        if isInDetachedWindow {
            components.append("open in another window")
        }

        return components.joined(separator: ", ")
    }
}

// MARK: - Message Accessibility

/// Provides accessibility information for message rows
struct MessageAccessibility {
    let role: String
    let timestamp: Date
    let isTruncated: Bool
    let status: String?

    /// Generates an accessibility label for the message
    var accessibilityLabel: String {
        let roleLabel = role == "user" ? "Your message" : "Claude's response"
        let timeLabel = "sent \(timestamp.formatted(date: .abbreviated, time: .shortened))"

        var label = "\(roleLabel), \(timeLabel)"

        if let status = status {
            label += ", \(status)"
        }

        if isTruncated {
            label += ", truncated"
        }

        return label
    }
}

// MARK: - Connection Status Accessibility

/// Provides consistent accessibility strings for connection states
struct ConnectionAccessibility {
    static func label(for state: String) -> String {
        switch state {
        case "connected":
            return "Connected to server"
        case "connecting":
            return "Connecting to server"
        case "authenticating":
            return "Authenticating with server"
        case "reconnecting":
            return "Reconnecting to server"
        case "disconnected":
            return "Disconnected from server"
        case "failed":
            return "Connection failed"
        default:
            return "Connection status unknown"
        }
    }

    static func hint(for state: String) -> String {
        switch state {
        case "connected":
            return "The app is connected and ready"
        case "failed", "disconnected":
            return "Double-tap the retry button to reconnect"
        default:
            return ""
        }
    }
}

// MARK: - Dynamic Type Support

/// Returns a scaled font that respects Dynamic Type settings
/// While macOS has less Dynamic Type adoption than iOS, we support the
/// accessibility text size preferences that macOS does provide
extension Font {
    /// Creates a font that scales with accessibility text size settings
    static func accessibleBody() -> Font {
        .body
    }

    /// Creates a headline font that scales with accessibility settings
    static func accessibleHeadline() -> Font {
        .headline
    }

    /// Creates a caption font that scales with accessibility settings
    static func accessibleCaption() -> Font {
        .caption
    }
}

// MARK: - Focus Management

/// View modifier for keyboard focus navigation support
struct FocusableModifier: ViewModifier {
    @FocusState private var isFocused: Bool
    let identifier: String

    func body(content: Content) -> some View {
        content
            .focused($isFocused)
            .id(identifier)
    }
}

extension View {
    /// Makes a view focusable for keyboard navigation
    func keyboardFocusable(identifier: String) -> some View {
        modifier(FocusableModifier(identifier: identifier))
    }
}
