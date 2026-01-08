// InputModifiers.swift
// iOS-specific input configuration extensions

import SwiftUI

// MARK: - Input Configuration Extensions

extension View {
    /// Configure text field for URL input
    /// - iOS: No autocapitalization, URL keyboard, no autocorrection
    /// - macOS: No-op (uses default behavior)
    func urlInputConfiguration() -> some View {
        #if os(iOS)
        self
            .autocapitalization(.none)
            .keyboardType(.URL)
            .disableAutocorrection(true)
        #else
        self
        #endif
    }

    /// Configure text field for file path input
    /// - iOS: No autocapitalization, no autocorrection
    /// - macOS: No-op (uses default behavior)
    func pathInputConfiguration() -> some View {
        #if os(iOS)
        self
            .autocapitalization(.none)
            .disableAutocorrection(true)
        #else
        self
        #endif
    }

    /// Configure text field for numeric input
    /// - iOS: Number pad keyboard
    /// - macOS: No-op (uses default behavior)
    func numericInputConfiguration() -> some View {
        #if os(iOS)
        self
            .keyboardType(.numberPad)
        #else
        self
        #endif
    }

    /// Configure text field for API key / secret input
    /// - iOS: No autocapitalization, no autocorrection
    /// - macOS: No autocorrection
    func secretInputConfiguration() -> some View {
        #if os(iOS)
        self
            .autocapitalization(.none)
            .autocorrectionDisabled()
        #else
        self
            .autocorrectionDisabled()
        #endif
    }

    /// Configure text field for natural language input (sentences)
    /// - iOS: Sentence autocapitalization
    /// - macOS: No-op (uses default behavior)
    func textInputConfiguration() -> some View {
        #if os(iOS)
        self
            .autocapitalization(.sentences)
        #else
        self
        #endif
    }
}
