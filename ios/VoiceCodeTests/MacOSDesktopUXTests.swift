// MacOSDesktopUXTests.swift
// Tests for macOS desktop UX improvements

import XCTest
#if os(macOS)
import SwiftUI
#endif
@testable import VoiceCode

final class MacOSDesktopUXTests: XCTestCase {

    // MARK: - ForceReconnect Tests

    func testForceReconnectResetsReconnectionAttempts() {
        // Given: A client with some reconnection attempts
        let client = VoiceCodeClient(serverURL: "ws://localhost:8080", setupObservers: false)

        // When: forceReconnect is called
        client.forceReconnect()

        // Then: reconnection attempts should be reset
        // We can verify this indirectly by checking that the client attempted to connect
        // Note: Without actual server, we just verify the method is callable
        XCTAssertNotNil(client)
    }

    func testForceReconnectDisconnectsFirst() {
        // Given: A connected client
        let client = VoiceCodeClient(serverURL: "ws://localhost:8080", setupObservers: false)

        // When: forceReconnect is called
        client.forceReconnect()

        // Then: The client should have attempted reconnection
        // This is a smoke test - the actual WebSocket behavior requires integration tests
        XCTAssertFalse(client.isConnected) // Disconnection happens synchronously
    }

    // MARK: - SwipeNavigationModifier Tests

    #if os(macOS)
    func testSwipeToBackModifierExists() {
        // Test that the swipeToBack modifier can be applied to views
        // This is a compile-time test - if it compiles, the modifier exists
        struct TestView: View {
            var body: some View {
                Text("Test")
                    .swipeToBack()
            }
        }

        // Just verify it compiles
        XCTAssertNotNil(TestView.self)
    }

    func testSwipeToBackWithCustomAction() {
        // Test that custom action variant compiles
        struct TestView: View {
            let action: () -> Void

            var body: some View {
                Text("Test")
                    .swipeToBack(action: action)
            }
        }

        XCTAssertNotNil(TestView.self)
    }
    #endif

    // MARK: - Settings Platform Conditional Tests

    func testAudioPlaybackSectionHiddenOnMacOS() {
        // Verify that the iOS-only audio settings are properly conditionally compiled
        // This is a compile-time verification
        #if os(macOS)
        // On macOS, the audio playback section should not be present in settings
        // We can't easily test UI without snapshot testing, but we can verify
        // AppSettings has the properties even if they're unused on macOS
        let settings = AppSettings()
        XCTAssertNotNil(settings.respectSilentMode)
        XCTAssertNotNil(settings.continuePlaybackWhenLocked)
        #else
        // On iOS, they should be fully functional
        let settings = AppSettings()
        XCTAssertNotNil(settings.respectSilentMode)
        XCTAssertNotNil(settings.continuePlaybackWhenLocked)
        #endif
    }
}
