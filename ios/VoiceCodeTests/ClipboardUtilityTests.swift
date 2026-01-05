// ClipboardUtilityTests.swift
// Unit tests for ClipboardUtility

import XCTest
#if os(iOS)
@testable import VoiceCode
#else
@testable import VoiceCodeMac
#endif

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

final class ClipboardUtilityTests: XCTestCase {

    // MARK: - Copy Tests

    func testCopyEmptyString() {
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

    func testCopySimpleText() {
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

    func testCopyMultilineText() {
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

    func testCopyUnicodeText() {
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

    func testCopyOverwritesPreviousContent() {
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
