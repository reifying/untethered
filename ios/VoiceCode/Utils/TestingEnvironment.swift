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

    /// Returns true when a UI test passes -uiTestSeedLinkSession: seed a small
    /// conversation whose reply contains a web link, for LinkTapUITests.
    static var shouldSeedLinkSession: Bool {
        ProcessInfo.processInfo.arguments.contains("-uiTestSeedLinkSession")
    }

    /// Returns true when running unit tests (XCTest but not UI tests)
    static var isUnitTesting: Bool {
        NSClassFromString("XCTestCase") != nil && !isUITesting
    }

    /// Environment variables Xcode's test runner sets on the process it runs
    /// tests in. Any one of them is enough.
    static let testRunnerEnvironmentKeys = [
        "XCTestConfigurationFilePath", "XCTestSessionIdentifier", "XCTestBundlePath", "XCInjectBundleInto"
    ]

    /// Returns true when this process was launched by Xcode's test runner to host
    /// unit tests. Unlike `isUnitTesting` this is already true while the app is
    /// starting up: XCTest is loaded into the host only after launch, so during
    /// `App.init` and the first `onAppear` the class lookup above still says no.
    /// Use this for decisions made at launch.
    static var isHostingUnitTests: Bool {
        isHostingUnitTests(environment: ProcessInfo.processInfo.environment)
    }

    static func isHostingUnitTests(environment: [String: String]) -> Bool {
        testRunnerEnvironmentKeys.contains { environment[$0] != nil }
    }

    /// Returns true in any process that exists to run tests: the unit-test host
    /// (from its first instruction) or an app launched by a UI test.
    static var isTestRun: Bool {
        isHostingUnitTests || isUnitTesting || isUITesting
    }
}
