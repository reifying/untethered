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

    /// Returns true when running unit tests (XCTest but not UI tests)
    static var isUnitTesting: Bool {
        NSClassFromString("XCTestCase") != nil && !isUITesting
    }
}
