// ClipboardUtilityTests.swift
// Unit tests for ClipboardUtility

import XCTest
#if os(iOS)
@testable import VoiceCode
#else
@testable import VoiceCode
#endif

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

final class ClipboardUtilityTests: XCTestCase {

    // MARK: - Pasteboard Access Helper

    /// Read pasteboard string, returning nil if unauthorized (iOS 16+ privacy).
    /// On iOS 16+, UIPasteboard.general.string triggers a system paste authorization
    /// dialog in the simulator, causing tests to hang. This helper detects that case.
    private func readPasteboard() -> String? {
        #if os(iOS)
        return UIPasteboard.general.string
        #elseif os(macOS)
        return NSPasteboard.general.string(forType: .string)
        #endif
    }

    /// Skip test if pasteboard read access is blocked (iOS 16+ simulator).
    private func skipIfPasteboardUnavailable() throws {
        #if os(iOS)
        // Write a known sentinel, then try to read it back.
        // If read returns nil, pasteboard access is blocked.
        let sentinel = "clipboard-test-sentinel-\(UUID().uuidString)"
        UIPasteboard.general.string = sentinel
        let result = UIPasteboard.general.string
        if result != sentinel {
            throw XCTSkip("Pasteboard access unauthorized in this environment (iOS 16+ privacy)")
        }
        #endif
    }

    // MARK: - Copy Tests

    func testCopyEmptyString() throws {
        try skipIfPasteboardUnavailable()

        // Given
        let text = ""

        // When
        ClipboardUtility.copy(text)

        // Then
        #if os(iOS)
        XCTAssertEqual(UIPasteboard.general.string, "")
        #elseif os(macOS)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "")
        #endif
    }

    func testCopySimpleText() throws {
        try skipIfPasteboardUnavailable()

        // Given
        let text = "Hello, World!"

        // When
        ClipboardUtility.copy(text)

        // Then
        #if os(iOS)
        XCTAssertEqual(UIPasteboard.general.string, text)
        #elseif os(macOS)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), text)
        #endif
    }

    func testCopyMultilineText() throws {
        try skipIfPasteboardUnavailable()

        // Given
        let text = "Line 1\nLine 2\nLine 3"

        // When
        ClipboardUtility.copy(text)

        // Then
        #if os(iOS)
        XCTAssertEqual(UIPasteboard.general.string, text)
        #elseif os(macOS)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), text)
        #endif
    }

    func testCopyUnicodeText() throws {
        try skipIfPasteboardUnavailable()

        // Given
        let text = "こんにちは 🌍 مرحبا"

        // When
        ClipboardUtility.copy(text)

        // Then
        #if os(iOS)
        XCTAssertEqual(UIPasteboard.general.string, text)
        #elseif os(macOS)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), text)
        #endif
    }

    func testCopyOverwritesPreviousContent() throws {
        try skipIfPasteboardUnavailable()

        // Given
        ClipboardUtility.copy("First text")

        // When
        ClipboardUtility.copy("Second text")

        // Then
        #if os(iOS)
        XCTAssertEqual(UIPasteboard.general.string, "Second text")
        #elseif os(macOS)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "Second text")
        #endif
    }

    // MARK: - Haptic Feedback Tests

    func testTriggerSuccessHapticDoesNotCrash() {
        // Haptic feedback is iOS-only, but calling should not crash on any platform
        // This test verifies the method can be called without throwing
        ClipboardUtility.triggerSuccessHaptic()
        // If we reach here, the test passes
        XCTAssert(true, "triggerSuccessHaptic should not crash")
    }
}
