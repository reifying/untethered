// ToolbarBuilder.swift
// Static utility methods for platform-appropriate toolbar button placements

import SwiftUI

/// ToolbarBuilder provides static methods for creating cross-platform toolbar buttons
/// with appropriate placements for iOS and macOS.
///
/// # Usage
/// Instead of:
/// ```swift
/// .toolbar {
///     #if os(iOS)
///     ToolbarItem(placement: .navigationBarLeading) {
///         Button("Cancel", action: onCancel)
///     }
///     #else
///     ToolbarItem(placement: .cancellationAction) {
///         Button("Cancel", action: onCancel)
///     }
///     #endif
/// }
/// ```
///
/// Use:
/// ```swift
/// .toolbar {
///     ToolbarBuilder.cancelButton(action: onCancel)
/// }
/// ```
enum ToolbarBuilder {

    // MARK: - Cancel Button

    /// Creates a cancel button with platform-appropriate placement.
    /// - iOS: `.navigationBarLeading`
    /// - macOS: `.cancellationAction`
    @ToolbarContentBuilder
    static func cancelButton(action: @escaping () -> Void) -> some ToolbarContent {
        #if os(iOS)
        ToolbarItem(placement: .navigationBarLeading) {
            Button("Cancel", action: action)
        }
        #else
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancel", action: action)
        }
        #endif
    }

    // MARK: - Done Button

    /// Creates a done button with platform-appropriate placement.
    /// - iOS: `.navigationBarTrailing`
    /// - macOS: `.confirmationAction`
    @ToolbarContentBuilder
    static func doneButton(action: @escaping () -> Void) -> some ToolbarContent {
        #if os(iOS)
        ToolbarItem(placement: .navigationBarTrailing) {
            Button("Done", action: action)
        }
        #else
        ToolbarItem(placement: .confirmationAction) {
            Button("Done", action: action)
        }
        #endif
    }

    // MARK: - Confirm Button

    /// Creates a confirmation button with custom title and platform-appropriate placement.
    /// - iOS: `.navigationBarTrailing`
    /// - macOS: `.confirmationAction`
    ///
    /// - Parameters:
    ///   - title: The button title (e.g., "Save", "Create")
    ///   - isDisabled: Whether the button should be disabled
    ///   - action: The action to perform when tapped
    @ToolbarContentBuilder
    static func confirmButton(
        _ title: String,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) -> some ToolbarContent {
        #if os(iOS)
        ToolbarItem(placement: .navigationBarTrailing) {
            Button(title, action: action)
                .disabled(isDisabled)
        }
        #else
        ToolbarItem(placement: .confirmationAction) {
            Button(title, action: action)
                .disabled(isDisabled)
        }
        #endif
    }

    // MARK: - Cancel and Confirm Pair

    /// Creates a standard cancel/confirm button pair for modal dialogs.
    /// - iOS: Cancel on left (`.navigationBarLeading`), confirm on right (`.navigationBarTrailing`)
    /// - macOS: Cancel and confirm both using semantic placements
    ///
    /// - Parameters:
    ///   - confirmTitle: The confirm button title (e.g., "Save", "Create")
    ///   - isConfirmDisabled: Whether the confirm button should be disabled
    ///   - onCancel: The cancel action
    ///   - onConfirm: The confirm action
    @ToolbarContentBuilder
    static func cancelAndConfirm(
        confirmTitle: String,
        isConfirmDisabled: Bool = false,
        onCancel: @escaping () -> Void,
        onConfirm: @escaping () -> Void
    ) -> some ToolbarContent {
        cancelButton(action: onCancel)
        confirmButton(confirmTitle, isDisabled: isConfirmDisabled, action: onConfirm)
    }
}
