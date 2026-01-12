import XCTest
import SwiftUI
#if os(iOS)
import UIKit
@testable import VoiceCode
#else
@testable import VoiceCode
#endif

/// Tests that VoiceCodeClient remains alive during SwiftUI view updates and copies.
/// This addresses the crash where VoiceCodeClient was being deallocated during RootView assignWithCopy operations.
/// Also tests background lifecycle management (Feature 4: Background Lifecycle Management).
final class VoiceCodeClientLifecycleTests: XCTestCase {

    /// Test that VoiceCodeClient stays alive when owned at the App level
    func testAppLevelOwnershipPreventsPrematureDeallocation() throws {
        // Track deallocation via weak reference
        weak var weakClient: VoiceCodeClient?
        weak var weakResourcesManager: ResourcesManager?

        autoreleasepool {
            // Create dependencies in correct order
            let settings = AppSettings()
            settings.serverURL = "localhost:3000"

            let voiceManager = VoiceOutputManager(appSettings: settings)
            let client = VoiceCodeClient(
                serverURL: settings.fullServerURL,
                voiceOutputManager: voiceManager,
                appSettings: settings
            )
            let resourcesManager = ResourcesManager(voiceCodeClient: client, appSettings: settings)

            // Store weak references
            weakClient = client
            weakResourcesManager = resourcesManager

            // Verify instances are alive while in scope
            XCTAssertNotNil(weakClient, "VoiceCodeClient should be alive while in scope")
            XCTAssertNotNil(weakResourcesManager, "ResourcesManager should be alive while in scope")

            // Don't create RootView in tests - it connects to backend and starts timers
            // Just verify that instances can coexist without premature deallocation
        }

        // Give autoreleasepool a moment to drain
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))

        // After scope ends, weak references should become nil (normal deallocation)
        XCTAssertNil(weakClient, "VoiceCodeClient should deallocate when no longer referenced")
        XCTAssertNil(weakResourcesManager, "ResourcesManager should deallocate when no longer referenced")
    }

    /// Test that ResourcesManager can use VoiceCodeClient after initialization
    func testResourcesManagerUsesVoiceCodeClient() throws {
        let settings = AppSettings()
        settings.serverURL = "localhost:3000"
        let voiceManager = VoiceOutputManager(appSettings: settings)
        let client = VoiceCodeClient(
            serverURL: settings.fullServerURL,
            voiceOutputManager: voiceManager,
            appSettings: settings
        )
        let resourcesManager = ResourcesManager(voiceCodeClient: client, appSettings: settings)

        // ResourcesManager should be able to check connection status
        // This verifies that the voiceCodeClient reference is accessible (not weak/nil)
        let expectation = XCTestExpectation(description: "ResourcesManager should access VoiceCodeClient")

        DispatchQueue.main.async {
            // This will fail if voiceCodeClient is weak and has been deallocated
            resourcesManager.listResources()
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 1.0)
    }

    // MARK: - Background Lifecycle Tests (Feature 4)

    #if os(iOS)

    /// Test that app entering background triggers disconnect when no in-flight operations
    func testAppEnteredBackground_NoInFlightOps_DisconnectsImmediately() {
        // Given: A client with no locked sessions or running commands
        let client = VoiceCodeClient(serverURL: "ws://localhost:8080", setupObservers: false)
        client.testableSetConnected(true)
        // Ensure no locked sessions or running commands (default state)

        // When: App enters background
        let expectation = XCTestExpectation(description: "Client should disconnect")

        // Trigger background handling
        client.testableHandleAppEnteredBackground()

        // Then: Client should disconnect
        // Wait briefly for cleanup to complete
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            XCTAssertFalse(client.isConnected, "Client should be disconnected after background")
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 2.0)
    }

    /// Test that finalize cleanup disconnects the client
    func testFinalizeBackgroundCleanup_Disconnects() {
        // Given: A connected client
        let client = VoiceCodeClient(serverURL: "ws://localhost:8080", setupObservers: false)
        client.testableSetConnected(true)

        let expectation = XCTestExpectation(description: "Client should disconnect")

        // When: Finalize cleanup is called
        client.testableFinalizeBgCleanup()

        // Then: Client should be disconnected (wait for main queue to process)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertFalse(client.isConnected, "Client should be disconnected after finalize cleanup")
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 1.0)
    }

    /// Test that complete background task handles invalid task ID gracefully
    func testCompleteBackgroundTask_InvalidTaskID_NoOp() {
        // Given: A client with invalid background task ID (default state)
        let client = VoiceCodeClient(serverURL: "ws://localhost:8080", setupObservers: false)

        // Verify initial state
        XCTAssertEqual(client.testableBackgroundTaskID, .invalid, "Background task ID should start as invalid")

        // When: Complete background task is called
        client.testableCompleteBackgroundTask()

        // Then: No crash, task ID remains invalid
        XCTAssertEqual(client.testableBackgroundTaskID, .invalid, "Background task ID should remain invalid")
    }

    /// Test that locked sessions indicate in-flight operations
    func testPerformBackgroundCleanup_WithLockedSessions_WaitsBeforeDisconnect() {
        // Given: A client with locked sessions
        let client = VoiceCodeClient(serverURL: "ws://localhost:8080", setupObservers: false)
        client.testableSetConnected(true)
        client.testableSetLockedSessions(["session-123"])

        let expectation = XCTestExpectation(description: "Client should wait for operations")

        // When: Perform cleanup is called
        client.testablePerformBackgroundCleanup()

        // Then: Client should still be connected initially (waiting for ops)
        XCTAssertTrue(client.isConnected, "Client should still be connected while waiting")

        // Simulate operation completion by clearing locked sessions
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            client.testableSetLockedSessions(Set<String>())
        }

        // Wait for cleanup to complete (after operations finish)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            XCTAssertFalse(client.isConnected, "Client should disconnect after operations complete")
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 5.0)
    }

    /// Test that running commands indicate in-flight operations
    func testPerformBackgroundCleanup_WithRunningCommands_WaitsBeforeDisconnect() {
        // Given: A client with running commands
        let client = VoiceCodeClient(serverURL: "ws://localhost:8080", setupObservers: false)
        client.testableSetConnected(true)
        let command = CommandExecution(id: "cmd-123", commandId: "build", shellCommand: "make build")
        client.testableSetRunningCommands(["cmd-123": command])

        let expectation = XCTestExpectation(description: "Client should wait for operations")

        // When: Perform cleanup is called
        client.testablePerformBackgroundCleanup()

        // Then: Client should still be connected initially (waiting for ops)
        XCTAssertTrue(client.isConnected, "Client should still be connected while waiting")

        // Simulate command completion by clearing running commands
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            client.testableSetRunningCommands([:])
        }

        // Wait for cleanup to complete (after operations finish)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            XCTAssertFalse(client.isConnected, "Client should disconnect after operations complete")
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 5.0)
    }

    /// Test that foreground with network available attempts reconnection
    func testAppBecameActive_NetworkAvailable_AttemptsReconnect() {
        // Given: Client is disconnected and network is available
        let client = VoiceCodeClient(serverURL: "ws://localhost:8080", setupObservers: false)
        client.testableSetConnected(false)
        client.testableSetNetworkAvailable(true)
        client.testableSetReconnectionAttempts(3)

        // When: App becomes active
        client.testableHandleAppBecameActive()

        // Then: Backoff should be reset (indicating reconnection was attempted)
        XCTAssertEqual(client.testableReconnectionAttempts, 0, "Reconnection attempts should reset to 0")
    }

    /// Test that foreground with network unavailable does not attempt reconnection
    func testAppBecameActive_NetworkUnavailable_DoesNotReconnect() {
        // Given: Client is disconnected and network is unavailable
        let client = VoiceCodeClient(serverURL: "ws://localhost:8080", setupObservers: false)
        client.testableSetConnected(false)
        client.testableSetNetworkAvailable(false)
        client.testableSetReconnectionAttempts(3)

        // When: App becomes active
        client.testableHandleAppBecameActive()

        // Then: Backoff should NOT be reset (no reconnection attempt)
        XCTAssertEqual(client.testableReconnectionAttempts, 3, "Reconnection attempts should not change")
    }

    #endif
}
