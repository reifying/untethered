// TestingEnvironment.swift
// Utilities for detecting test execution context

import Foundation

/// Detects when app is running under different test conditions
enum TestingEnvironment {
    /// Returns true when app is launched by UI tests with --uitesting flag
    /// UI tests should pass this flag to skip permission prompts that block automation
    static var isUITesting: Bool {
        ProcessInfo.processInfo.arguments.contains("--uitesting")
    }

    /// Returns true when running in Xcode previews
    static var isPreview: Bool {
        ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
    }

    /// Returns true when a UI test asks the app to seed a large conversation on
    /// launch via the -uiTestSeedLargeSession launch argument. Drives the
    /// debug-only Core Data seed in PersistenceController so AutoScrollCrashUITests
    /// can exercise the ConversationView auto-scroll path against a large message
    /// backlog without a live backend. See
    /// docs/design/conversation-autoscroll-crash-fix.md (Verification Strategy).
    static var shouldSeedLargeSession: Bool {
        ProcessInfo.processInfo.arguments.contains("-uiTestSeedLargeSession")
    }

    /// Returns true when running unit tests (XCTest but not UI tests)
    static var isUnitTesting: Bool {
        NSClassFromString("XCTestCase") != nil && !isUITesting
    }
}
