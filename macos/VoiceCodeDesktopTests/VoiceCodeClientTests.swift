// VoiceCodeClientTests.swift
// Tests for macOS VoiceCodeClient lifecycle observers

import XCTest
import AppKit
import VoiceCodeShared
@testable import VoiceCodeDesktop

/// Tests for macOS VoiceCodeClient, focusing on lifecycle observers
@MainActor
final class VoiceCodeClientTests: XCTestCase {

    // MARK: - Initialization Tests

    func testVoiceCodeClientInitialization() async {
        let client = VoiceCodeClient(
            serverURL: "ws://localhost:8080",
            setupObservers: false  // Don't set up observers to avoid side effects in tests
        )

        // Initial state should be disconnected
        XCTAssertFalse(client.isConnected)
        XCTAssertEqual(client.connectionState, .disconnected)
        XCTAssertNil(client.currentError)
    }

    func testVoiceCodeClientWithAppSettings() async {
        let appSettings = AppSettings()
        appSettings.serverURL = "localhost"
        appSettings.serverPort = "3000"

        let client = VoiceCodeClient(
            serverURL: appSettings.fullServerURL,
            appSettings: appSettings,
            setupObservers: false
        )

        XCTAssertFalse(client.isConnected)
    }

    func testVoiceCodeClientWithVoiceOutputManager() async {
        let voiceManager = VoiceOutputManager()

        let client = VoiceCodeClient(
            serverURL: "ws://localhost:8080",
            voiceOutputManager: voiceManager,
            setupObservers: false
        )

        XCTAssertFalse(client.isConnected)
    }

    // MARK: - Lifecycle Observer Setup Tests

    func testLifecycleObserversAreSetUp() async {
        // Create client with observers enabled
        let client = VoiceCodeClient(
            serverURL: "ws://localhost:8080",
            setupObservers: true
        )

        // Verify that lifecycle observers were registered
        // Note: We can't directly test NotificationCenter observers,
        // but we can verify the client was created without errors
        XCTAssertNotNil(client)
        XCTAssertFalse(client.isConnected)
    }

    // MARK: - Connection State Tests

    func testInitialConnectionState() async {
        let client = VoiceCodeClient(
            serverURL: "ws://localhost:8080",
            setupObservers: false
        )

        XCTAssertEqual(client.connectionState, .disconnected)
        XCTAssertFalse(client.isConnected)
    }

    func testLockedSessionsInitiallyEmpty() async {
        let client = VoiceCodeClient(
            serverURL: "ws://localhost:8080",
            setupObservers: false
        )

        XCTAssertTrue(client.lockedSessions.isEmpty)
    }

    // MARK: - Deallocation Tests

    func testClientDeallocatesCleanly() async {
        weak var weakClient: VoiceCodeClient?

        autoreleasepool {
            let client = VoiceCodeClient(
                serverURL: "ws://localhost:8080",
                setupObservers: true
            )
            weakClient = client

            XCTAssertNotNil(weakClient)
        }

        // Give time for deallocation
        try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds

        XCTAssertNil(weakClient, "VoiceCodeClient should deallocate when no longer referenced")
    }

    // MARK: - SessionSyncManager Tests

    func testSessionSyncManagerIsCreated() async {
        let client = VoiceCodeClient(
            serverURL: "ws://localhost:8080",
            setupObservers: false
        )

        // SessionSyncManager should be accessible
        XCTAssertNotNil(client.sessionSyncManager)
    }

    func testSessionSyncManagerWithCustomPersistence() async {
        let persistence = PersistenceController(inMemory: true)
        let syncManager = SessionSyncManager(persistenceController: persistence)

        let client = VoiceCodeClient(
            serverURL: "ws://localhost:8080",
            sessionSyncManager: syncManager,
            setupObservers: false
        )

        // The client should use our provided SessionSyncManager
        XCTAssertTrue(client.sessionSyncManager === syncManager)
    }
}

// MARK: - Lifecycle Notification Tests

@MainActor
final class VoiceCodeClientLifecycleTests: XCTestCase {

    /// Test that the client properly handles lifecycle events
    /// These tests use mock notifications to simulate app lifecycle changes
    func testHandlesDidBecomeActiveNotification() async {
        // Create client that tracks connect calls
        let client = VoiceCodeClient(
            serverURL: "ws://localhost:8080",
            setupObservers: true
        )

        // The client should have registered for notifications
        // When the app becomes active and is not connected, it should attempt reconnection
        XCTAssertFalse(client.isConnected)

        // Post notification (this simulates the app becoming active)
        // Note: This tests the observer registration, not the actual reconnection behavior
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)

        // Give time for notification to be processed
        try? await Task.sleep(nanoseconds: 50_000_000) // 0.05 seconds

        // Client should still be in disconnected state (no real server)
        // but it should have attempted to reconnect
        XCTAssertFalse(client.isConnected)
    }

    func testHandlesWillTerminateNotification() async {
        let client = VoiceCodeClient(
            serverURL: "ws://localhost:8080",
            setupObservers: true
        )

        // Post termination notification
        NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)

        // Give time for notification to be processed
        try? await Task.sleep(nanoseconds: 50_000_000) // 0.05 seconds

        // Client should disconnect on termination
        XCTAssertFalse(client.isConnected)
    }

    func testHandlesSystemSleepNotification() async {
        let client = VoiceCodeClient(
            serverURL: "ws://localhost:8080",
            setupObservers: true
        )

        // Post sleep notification
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)

        // Give time for notification to be processed
        try? await Task.sleep(nanoseconds: 50_000_000) // 0.05 seconds

        // Client should disconnect on sleep
        XCTAssertFalse(client.isConnected)
    }

    func testHandlesSystemWakeNotification() async {
        let client = VoiceCodeClient(
            serverURL: "ws://localhost:8080",
            setupObservers: true
        )

        // Post wake notification
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)

        // Give time for notification to be processed
        try? await Task.sleep(nanoseconds: 50_000_000) // 0.05 seconds

        // Client should attempt to reconnect on wake (won't succeed without server)
        XCTAssertFalse(client.isConnected)
    }
}

// MARK: - Error Recovery Tests (Appendix Z.4)

@MainActor
final class VoiceCodeClientErrorRecoveryTests: XCTestCase {

    func testRecoverableErrorFromNotConnectedToInternet() {
        let appSettings = AppSettings()
        appSettings.serverURL = "localhost"
        appSettings.serverPort = "8080"

        let client = VoiceCodeClient(
            serverURL: appSettings.fullServerURL,
            appSettings: appSettings,
            setupObservers: false
        )

        let error = URLError(.notConnectedToInternet)
        let recoverable = client.recoverableError(from: error)

        XCTAssertNotNil(recoverable)
        XCTAssertEqual(recoverable?.title, "No Internet Connection")
        XCTAssertEqual(recoverable?.recoveryAction?.label, "Retry")
    }

    func testRecoverableErrorFromCannotFindHost() {
        let appSettings = AppSettings()
        appSettings.serverURL = "test-server"
        appSettings.serverPort = "3000"

        let client = VoiceCodeClient(
            serverURL: appSettings.fullServerURL,
            appSettings: appSettings,
            setupObservers: false
        )

        let error = URLError(.cannotFindHost)
        let recoverable = client.recoverableError(from: error)

        XCTAssertNotNil(recoverable)
        XCTAssertEqual(recoverable?.title, "Server Not Found")
        // Message should contain server URL info
        XCTAssertTrue(recoverable?.message.contains("test-server:3000") ?? false)
        XCTAssertEqual(recoverable?.recoveryAction?.label, "Open Settings")
    }

    func testRecoverableErrorFromSessionLock() {
        let client = VoiceCodeClient(
            serverURL: "ws://localhost:8080",
            setupObservers: false
        )

        let error = SessionLockError(sessionId: "test-session-123")
        let recoverable = client.recoverableError(from: error)

        XCTAssertNotNil(recoverable)
        XCTAssertEqual(recoverable?.title, "Session Busy")
        // Session lock errors don't have a recovery action (auto-clear)
        XCTAssertNil(recoverable?.recoveryAction)
    }

    func testRecoverableErrorFromUnknownError() {
        let client = VoiceCodeClient(
            serverURL: "ws://localhost:8080",
            setupObservers: false
        )

        struct CustomError: Error {}
        let error = CustomError()
        let recoverable = client.recoverableError(from: error)

        // Unknown errors should return nil
        XCTAssertNil(recoverable)
    }

    func testRecoverableErrorWithoutAppSettings() {
        // Create client without appSettings
        let client = VoiceCodeClient(
            serverURL: "ws://localhost:8080",
            appSettings: nil,
            setupObservers: false
        )

        let error = URLError(.cannotFindHost)
        let recoverable = client.recoverableError(from: error)

        XCTAssertNotNil(recoverable)
        XCTAssertEqual(recoverable?.title, "Server Not Found")
        // Without appSettings, server URL info shouldn't be included
        XCTAssertFalse(recoverable?.message.contains("localhost:8080") ?? true)
    }

    func testRecoverableErrorFromConnectionRefused() {
        let appSettings = AppSettings()
        appSettings.serverURL = "localhost"
        appSettings.serverPort = "9999"

        let client = VoiceCodeClient(
            serverURL: appSettings.fullServerURL,
            appSettings: appSettings,
            setupObservers: false
        )

        let error = URLError(.cannotConnectToHost)
        let recoverable = client.recoverableError(from: error)

        XCTAssertNotNil(recoverable)
        XCTAssertEqual(recoverable?.title, "Connection Refused")
        XCTAssertEqual(recoverable?.recoveryAction?.label, "Retry")
    }

    func testRecoverableErrorFromTimeout() {
        let client = VoiceCodeClient(
            serverURL: "ws://localhost:8080",
            setupObservers: false
        )

        let error = URLError(.timedOut)
        let recoverable = client.recoverableError(from: error)

        XCTAssertNotNil(recoverable)
        XCTAssertEqual(recoverable?.title, "Connection Timed Out")
        XCTAssertEqual(recoverable?.recoveryAction?.label, "Retry")
    }
}
