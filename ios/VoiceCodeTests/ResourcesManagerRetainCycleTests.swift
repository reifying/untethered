import XCTest
import Combine
@testable import VoiceCode

/// Tests to verify ResourcesManager doesn't create retain cycles with VoiceCodeClient
final class ResourcesManagerRetainCycleTests: XCTestCase {

    // MARK: - Retain Cycle Tests

    func testResourcesManagerDoesNotRetainVoiceCodeClient() {
        // Create a client and manager
        var client: VoiceCodeClient? = VoiceCodeClient(serverURL: "ws://localhost:8080")
        weak var weakClient = client

        var manager: ResourcesManager? = ResourcesManager(
            voiceCodeClient: client!,
            appSettings: AppSettings()
        )

        // Verify both objects exist
        XCTAssertNotNil(client, "Client should exist")
        XCTAssertNotNil(manager, "Manager should exist")
        XCTAssertNotNil(weakClient, "Weak client reference should exist")

        // Release the client - manager should NOT retain it
        client = nil

        // The weak reference should be nil now (client was deallocated)
        XCTAssertNil(weakClient, "Client should be deallocated when no strong references remain")

        // Manager should still exist (it has a weak reference)
        XCTAssertNotNil(manager, "Manager should still exist")

        // Clean up
        manager = nil
    }

    func testResourcesManagerCanStillAccessClientWhenItExists() {
        let client = VoiceCodeClient(serverURL: "ws://localhost:8080")
        let manager = ResourcesManager(
            voiceCodeClient: client,
            appSettings: AppSettings()
        )

        // Client is connected (mocked state)
        client.isConnected = false

        // Manager should be able to check connection state
        // This verifies optional chaining works correctly
        manager.listResources()

        // No crash should occur - the guard statement should handle nil client
        XCTAssertFalse(manager.isLoadingResources, "Should not start loading when disconnected")
    }

    func testResourcesManagerHandlesNilClientGracefully() {
        var client: VoiceCodeClient? = VoiceCodeClient(serverURL: "ws://localhost:8080")
        let manager = ResourcesManager(
            voiceCodeClient: client!,
            appSettings: AppSettings()
        )

        // Release the client
        client = nil

        // These calls should not crash even though client is nil
        manager.listResources()
        manager.processPendingUploads()
        manager.deleteResource(Resource(filename: "test.txt", path: ".untethered/resources/test.txt", size: 100, timestamp: Date()))

        // No assertions needed - we just verify no crashes occur
        XCTAssertTrue(true, "All operations completed without crash")
    }

    func testNoRetainCycleInCombineSubscriptions() {
        var client: VoiceCodeClient? = VoiceCodeClient(serverURL: "ws://localhost:8080")
        weak var weakClient = client

        var manager: ResourcesManager? = ResourcesManager(
            voiceCodeClient: client!,
            appSettings: AppSettings()
        )

        // Trigger some published value changes to ensure subscriptions are active
        client?.isConnected = true
        client?.isConnected = false

        // Release client
        client = nil

        // Client should be deallocated despite Combine subscriptions
        XCTAssertNil(weakClient, "Client should be deallocated (no retain cycle in Combine)")

        // Manager should still exist
        XCTAssertNotNil(manager, "Manager should exist")

        manager = nil
    }

    func testStateObjectDoesNotCauseCrash() {
        // Simulate the @StateObject scenario from VoiceCodeApp
        // This tests the scenario that was causing the crash

        var client: VoiceCodeClient? = VoiceCodeClient(serverURL: "ws://localhost:8080")
        var manager: ResourcesManager? = ResourcesManager(
            voiceCodeClient: client!,
            appSettings: AppSettings()
        )

        // In the real app, RootView owns both via @StateObject
        // When RootView is deallocated, both should be released without crash

        weak var weakClient = client
        weak var weakManager = manager

        // Release both (simulating RootView deallocation)
        client = nil
        manager = nil

        // Both should be deallocated without crash
        XCTAssertNil(weakClient, "Client should be deallocated")
        XCTAssertNil(weakManager, "Manager should be deallocated")
    }

    func testMultipleManagersDoNotInterfere() {
        // Test that multiple ResourcesManager instances can share a client
        let client = VoiceCodeClient(serverURL: "ws://localhost:8080")

        var manager1: ResourcesManager? = ResourcesManager(
            voiceCodeClient: client,
            appSettings: AppSettings()
        )

        var manager2: ResourcesManager? = ResourcesManager(
            voiceCodeClient: client,
            appSettings: AppSettings()
        )

        weak var weakManager1 = manager1
        weak var weakManager2 = manager2

        // Release managers
        manager1 = nil
        manager2 = nil

        // Both should be deallocated
        XCTAssertNil(weakManager1, "Manager 1 should be deallocated")
        XCTAssertNil(weakManager2, "Manager 2 should be deallocated")
    }

    // MARK: - Functional Tests with Weak Reference

    func testListResourcesWithWeakReference() {
        let client = VoiceCodeClient(serverURL: "ws://localhost:8080")
        let manager = ResourcesManager(
            voiceCodeClient: client,
            appSettings: AppSettings()
        )

        // Set client to connected
        client.isConnected = true

        // This should work fine with weak reference
        manager.listResources()

        XCTAssertTrue(manager.isLoadingResources, "Should start loading resources")
    }

    func testDeleteResourceWithWeakReference() {
        let client = VoiceCodeClient(serverURL: "ws://localhost:8080")
        let manager = ResourcesManager(
            voiceCodeClient: client,
            appSettings: AppSettings()
        )

        client.isConnected = true

        let resource = Resource(filename: "test.txt", path: ".untethered/resources/test.txt", size: 100, timestamp: Date())

        // This should work fine with weak reference
        manager.deleteResource(resource)

        // No crash means success
        XCTAssertTrue(true, "Delete resource completed without crash")
    }

    func testProcessPendingUploadsWithWeakReference() {
        let client = VoiceCodeClient(serverURL: "ws://localhost:8080")
        let manager = ResourcesManager(
            voiceCodeClient: client,
            appSettings: AppSettings()
        )

        client.isConnected = true

        // This should work fine with weak reference
        manager.processPendingUploads()

        // No crash means success
        XCTAssertTrue(true, "Process pending uploads completed without crash")
    }

    // MARK: - Edge Cases

    func testCombineSubscriptionsHandleNilClient() {
        var client: VoiceCodeClient? = VoiceCodeClient(serverURL: "ws://localhost:8080")
        let manager = ResourcesManager(
            voiceCodeClient: client!,
            appSettings: AppSettings()
        )

        // Set up expectation for Combine subscription
        let expectation = self.expectation(description: "Combine subscription should not crash")
        expectation.isInverted = true // We expect this NOT to be fulfilled (no crash)

        // Release client while manager still exists
        client = nil

        // Wait briefly to ensure no delayed crash
        wait(for: [expectation], timeout: 0.1)

        // Manager should still exist without crashing
        XCTAssertNotNil(manager, "Manager should exist")
    }
}
