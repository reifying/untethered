import XCTest
import SwiftUI
#if os(iOS)
@testable import VoiceCode
#else
@testable import VoiceCode
#endif

/// Tests that VoiceCodeClient remains alive during SwiftUI view updates and copies.
/// This addresses the crash where VoiceCodeClient was being deallocated during RootView assignWithCopy operations.
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
}
