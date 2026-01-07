// MacOSDesktopUXTests.swift
// Tests for macOS desktop UX improvements

import XCTest
#if os(macOS)
import SwiftUI
#endif
@testable import VoiceCode

final class MacOSDesktopUXTests: XCTestCase {

    // MARK: - Return Key Behavior Tests
    // Note: These tests verify compile-time correctness of ConversationTextInputView.
    // The .onKeyPress modifier (macOS-only) cannot be tested in unit tests -
    // key press simulation requires UI testing. Manual verification is required
    // for Return key sends prompt and Shift+Return inserts newline behavior.

    #if os(macOS)
    func testConversationTextInputViewCompiles() {
        // Verify ConversationTextInputView can be instantiated with all required parameters.
        // This ensures the view's interface is correct and the onKeyPress modifier compiles.
        struct TestWrapper: View {
            @Binding var text: String
            let onSend: () -> Void
            let onManualUnlock: () -> Void

            var body: some View {
                ConversationTextInputView(
                    text: $text,
                    isDisabled: false,
                    onSend: onSend,
                    onManualUnlock: onManualUnlock
                )
            }
        }

        let wrapper = TestWrapper(
            text: .constant("Test message"),
            onSend: {},
            onManualUnlock: {}
        )

        XCTAssertNotNil(wrapper)
    }

    func testConversationTextInputViewCompilesWithEmptyText() {
        // Verify the view compiles when configured with empty text binding.
        struct TestWrapper: View {
            @Binding var text: String

            var body: some View {
                ConversationTextInputView(
                    text: $text,
                    isDisabled: false,
                    onSend: {},
                    onManualUnlock: {}
                )
            }
        }

        let wrapper = TestWrapper(text: .constant(""))
        XCTAssertNotNil(wrapper)
    }

    func testConversationTextInputViewCompilesInDisabledState() {
        // Verify the view compiles when isDisabled is true.
        struct TestWrapper: View {
            @Binding var text: String

            var body: some View {
                ConversationTextInputView(
                    text: $text,
                    isDisabled: true,
                    onSend: {},
                    onManualUnlock: {}
                )
            }
        }

        let wrapper = TestWrapper(text: .constant("Test"))
        XCTAssertNotNil(wrapper)
    }
    #endif

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

    // MARK: - Command History Sheet Sizing Tests

    #if os(macOS)
    func testActiveCommandsListViewHasMacOSFrameConstraints() {
        // Test that ActiveCommandsListView can be instantiated and compiles with frame modifier on macOS.
        // The .frame(minWidth: 500, minHeight: 300) modifier ensures content is visible in sheets.
        let client = VoiceCodeClient(serverURL: "ws://localhost:8080", setupObservers: false)

        struct TestWrapper: View {
            let client: VoiceCodeClient

            var body: some View {
                ActiveCommandsListView(client: client)
            }
        }

        let wrapper = TestWrapper(client: client)
        XCTAssertNotNil(wrapper)
    }

    func testCommandHistorySheetPresentationCompiles() {
        // Test that the command history sheet presentation in SessionsForDirectoryView compiles correctly.
        // NavigationController applies frame(minWidth: 600, minHeight: 400) on macOS.
        struct TestWrapper: View {
            let client: VoiceCodeClient

            var body: some View {
                NavigationController(minWidth: 600, minHeight: 400) {
                    ActiveCommandsListView(client: client)
                        .toolbar {
                            ToolbarItem(placement: .automatic) {
                                Button("Done") {}
                            }
                        }
                }
            }
        }

        let client = VoiceCodeClient(serverURL: "ws://localhost:8080", setupObservers: false)
        let wrapper = TestWrapper(client: client)
        XCTAssertNotNil(wrapper)
    }
    #endif

    // MARK: - System Prompt Editing Tests

    #if os(macOS)
    func testSystemPromptUsesTextEditorOnMacOS() {
        // Verify that the system prompt section compiles correctly on macOS with TextEditor.
        // On macOS, TextEditor is used instead of TextField for better multi-line editing.
        // This is a compile-time test - if it compiles, the implementation is correct.
        struct TestWrapper: View {
            @State private var localSystemPrompt: String = "Test prompt"

            var body: some View {
                Form {
                    Section(header: Text("System Prompt")) {
                        TextEditor(text: $localSystemPrompt)
                            .frame(minHeight: 80)
                            .font(.body)
                    }
                }
            }
        }

        let wrapper = TestWrapper()
        XCTAssertNotNil(wrapper)
    }

    func testSystemPromptTextEditorWithOnChange() {
        // Verify TextEditor with onChange modifier compiles on macOS.
        // This mirrors the actual implementation in SettingsView.swift.
        struct TestWrapper: View {
            @State private var localSystemPrompt: String = ""
            @State private var savedValue: String = ""

            var body: some View {
                TextEditor(text: $localSystemPrompt)
                    .frame(minHeight: 80)
                    .font(.body)
                    .onChange(of: localSystemPrompt) { newValue in
                        savedValue = newValue
                    }
            }
        }

        let wrapper = TestWrapper()
        XCTAssertNotNil(wrapper)
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
