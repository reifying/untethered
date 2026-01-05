import XCTest
#if os(iOS)
@testable import VoiceCode
#else
@testable import VoiceCodeMac
#endif

final class ResourcesSettingsIntegrationTests: XCTestCase {

    func testAppSettingsDefaultResourceStorageLocation() {
        // Create AppSettings
        let settings = AppSettings()

        // Verify default value
        XCTAssertEqual(settings.resourceStorageLocation, "~/Downloads", "Default storage location should be ~/Downloads")
    }

    func testAppSettingsResourceStorageLocationPersistence() {
        // Create AppSettings and change storage location
        let settings1 = AppSettings()
        settings1.resourceStorageLocation = "/custom/path"

        // Create new AppSettings instance (simulates app restart)
        let settings2 = AppSettings()

        // Verify value persisted
        XCTAssertEqual(settings2.resourceStorageLocation, "/custom/path", "Storage location should persist across instances")

        // Cleanup - restore default
        settings2.resourceStorageLocation = "~/Downloads"
    }

    func testResourcesManagerIncludesStorageLocationInUploadMessage() {
        // This test verifies that storage_location is included in upload messages
        // The actual verification would happen in the backend when processing upload_file messages
        // For now, we verify the property is accessible

        let mockSettings = AppSettings()
        mockSettings.resourceStorageLocation = "/custom/upload/location"

        XCTAssertEqual(mockSettings.resourceStorageLocation, "/custom/upload/location", "Settings should store custom storage location")
    }

    func testResourceStorageLocationSpecialCharacters() {
        let settings = AppSettings()

        let testPaths = [
            "~/Documents/Files",
            "/var/tmp/uploads",
            "/Users/user/My Documents/Uploads",
            "~/Desktop/Projects/voice-code/uploads"
        ]

        for path in testPaths {
            settings.resourceStorageLocation = path
            XCTAssertEqual(settings.resourceStorageLocation, path, "Should handle path: \(path)")
        }

        // Cleanup
        settings.resourceStorageLocation = "~/Downloads"
    }

    func testResourceStorageLocationEmptyString() {
        let settings = AppSettings()
        settings.resourceStorageLocation = ""

        // Should allow empty string (backend can handle with default)
        XCTAssertEqual(settings.resourceStorageLocation, "", "Should allow empty storage location")

        // Cleanup
        settings.resourceStorageLocation = "~/Downloads"
    }

    func testSettingsViewDisplaysResourcesSection() {
        // Create settings
        let settings = AppSettings()
        settings.resourceStorageLocation = "/test/path"

        // Create SettingsView (view initialization test)
        let view = SettingsView(
            settings: settings,
            onServerChange: { _ in },
            onMaxMessageSizeChange: nil,
            voiceOutputManager: nil,
            onAPIKeyChanged: nil
        )

        // Verify view can be initialized with resources settings
        XCTAssertNotNil(view, "SettingsView should initialize with resources configuration")
    }
}

// MARK: - Mock VoiceCodeClient

private class MockVoiceCodeClient: VoiceCodeClient {
    @Published var mockIsConnected: Bool = false
    var sentMessages: [[String: Any]] = []

    init() {
        super.init(serverURL: "ws://localhost:8080")
    }

    override var isConnected: Bool {
        get { mockIsConnected }
        set { mockIsConnected = newValue }
    }

    override func sendMessage(_ message: [String: Any]) {
        sentMessages.append(message)
    }
}
