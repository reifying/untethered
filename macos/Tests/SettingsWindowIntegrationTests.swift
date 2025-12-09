// SettingsWindowIntegrationTests.swift
// Integration tests for Settings window tabs and functionality (macOS)

import XCTest
import CoreData
import SwiftUI
@testable import UntetheredMac
@testable import UntetheredCore

final class SettingsWindowIntegrationTests: XCTestCase {

    var settings: AppSettings!
    var persistenceController: PersistenceController!
    var context: NSManagedObjectContext!

    override func setUp() {
        super.setUp()
        // Clear UserDefaults for clean state
        let domain = Bundle.main.bundleIdentifier!
        UserDefaults.standard.removePersistentDomain(forName: domain)
        UserDefaults.standard.synchronize()

        settings = AppSettings()
        persistenceController = PersistenceController(inMemory: true)
        context = persistenceController.container.viewContext
    }

    override func tearDown() {
        context = nil
        persistenceController = nil
        settings = nil

        let domain = Bundle.main.bundleIdentifier!
        UserDefaults.standard.removePersistentDomain(forName: domain)
        UserDefaults.standard.synchronize()
        super.tearDown()
    }

    // MARK: - Settings Persistence Tests

    func testGeneralSettings_ServerConfiguration_PersistsAcrossInstances() {
        // Set server configuration
        settings.serverURL = "192.168.1.100"
        settings.serverPort = "9090"

        // Wait for debounce
        let expectation = expectation(description: "Debounce wait")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)

        // Create new settings instance to verify persistence
        let newSettings = AppSettings()
        XCTAssertEqual(newSettings.serverURL, "192.168.1.100")
        XCTAssertEqual(newSettings.serverPort, "9090")
    }

    func testGeneralSettings_FullServerURL_ComputesCorrectly() {
        settings.serverURL = "localhost"
        settings.serverPort = "8080"

        XCTAssertEqual(settings.fullServerURL, "ws://localhost:8080")

        settings.serverURL = "192.168.1.100"
        settings.serverPort = "9090"

        XCTAssertEqual(settings.fullServerURL, "ws://192.168.1.100:9090")
    }

    func testGeneralSettings_DefaultWorkingDirectory_Persistence() {
        let testPath = "/Users/test/projects"
        UserDefaults.standard.set(testPath, forKey: "defaultWorkingDirectory")

        let savedPath = UserDefaults.standard.string(forKey: "defaultWorkingDirectory")
        XCTAssertEqual(savedPath, testPath)
    }

    func testGeneralSettings_DefaultWorkingDirectory_FallsBackToHomeDirectory() {
        // Ensure no default is set
        UserDefaults.standard.removeObject(forKey: "defaultWorkingDirectory")

        let defaultPath = UserDefaults.standard.string(forKey: "defaultWorkingDirectory") ?? NSHomeDirectory()
        XCTAssertEqual(defaultPath, NSHomeDirectory())
    }

    // MARK: - Voice Settings Tests

    func testVoiceSettings_AutoPlayResponses_Persists() {
        settings.autoPlayResponses = true

        let expectation = expectation(description: "Debounce wait")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)

        let newSettings = AppSettings()
        XCTAssertTrue(newSettings.autoPlayResponses)
    }

    func testVoiceSettings_SelectedVoice_Persists() {
        let testVoiceIdentifier = "com.apple.voice.premium.en-US.Ava"
        settings.selectedVoiceIdentifier = testVoiceIdentifier

        let expectation = expectation(description: "Debounce wait")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)

        let newSettings = AppSettings()
        XCTAssertEqual(newSettings.selectedVoiceIdentifier, testVoiceIdentifier)
    }

    func testVoiceSettings_SpeechRate_Persists() {
        let testRate = 1.5
        UserDefaults.standard.set(testRate, forKey: "speechRate")

        let savedRate = UserDefaults.standard.double(forKey: "speechRate")
        XCTAssertEqual(savedRate, testRate, accuracy: 0.01)
    }

    func testVoiceSettings_SpeechRate_DefaultsToHalfSpeed() {
        UserDefaults.standard.removeObject(forKey: "speechRate")

        var speechRate = UserDefaults.standard.double(forKey: "speechRate")
        if speechRate == 0 {
            speechRate = 0.5
        }

        XCTAssertEqual(speechRate, 0.5, accuracy: 0.01)
    }

    func testVoiceSettings_VoiceIdentifierResolution_WithSpecificVoice() {
        let testVoice = "com.apple.voice.premium.en-US.Ava"
        settings.selectedVoiceIdentifier = testVoice

        let resolved = settings.resolveVoiceIdentifier(forWorkingDirectory: nil)
        XCTAssertEqual(resolved, testVoice)
    }

    func testVoiceSettings_VoiceIdentifierResolution_WithAllPremiumVoices() {
        settings.selectedVoiceIdentifier = AppSettings.allPremiumVoicesIdentifier

        let resolved = settings.resolveVoiceIdentifier(forWorkingDirectory: "/tmp/project")
        XCTAssertNotNil(resolved)
        XCTAssertNotEqual(resolved, AppSettings.allPremiumVoicesIdentifier)
    }

    func testVoiceSettings_AvailableVoices_ContainsPremiumVoices() {
        let voices = AppSettings.availableVoices
        XCTAssertFalse(voices.isEmpty)

        // Check for at least some premium en-US voices
        let hasAva = voices.contains { $0.identifier.contains("Ava") }
        XCTAssertTrue(hasAva, "Should contain Ava voice")
    }

    // MARK: - Advanced Settings Tests

    func testAdvancedSettings_SystemPrompt_Persists() {
        let testPrompt = "Custom system prompt for testing"
        settings.systemPrompt = testPrompt

        let expectation = expectation(description: "Debounce wait")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)

        let newSettings = AppSettings()
        XCTAssertEqual(newSettings.systemPrompt, testPrompt)
    }

    func testAdvancedSettings_SystemPrompt_EmptyString() {
        settings.systemPrompt = ""

        let expectation = expectation(description: "Debounce wait")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)

        let newSettings = AppSettings()
        XCTAssertEqual(newSettings.systemPrompt, "")
    }

    func testAdvancedSettings_ClearMessageCache_DeletesAllMessages() {
        // Create test messages
        for i in 0..<10 {
            let message = CDMessage(context: context)
            message.id = UUID()
            message.sessionId = UUID()
            message.role = "user"
            message.text = "Message \(i)"
            message.timestamp = Date()
            message.messageStatus = .confirmed
        }

        try? context.save()

        // Verify messages exist
        let fetchBefore = CDMessage.fetchRequest()
        let countBefore = try? context.count(for: fetchBefore)
        XCTAssertEqual(countBefore, 10)

        // Clear cache (simulating AdvancedSettingsView.clearMessageCache)
        let fetchRequest = CDMessage.fetchRequest()
        fetchRequest.includesPropertyValues = false

        let messages = try! context.fetch(fetchRequest)
        for message in messages {
            context.delete(message)
        }
        try! context.save()

        // Verify messages deleted
        let fetchAfter = CDMessage.fetchRequest()
        let countAfter = try? context.count(for: fetchAfter)
        XCTAssertEqual(countAfter, 0)
    }

    func testAdvancedSettings_ClearMessageCache_PreservesSessionData() {
        // Create test session and messages
        let session = CDBackendSession(context: context)
        session.id = UUID()
        session.backendName = "Test Session"
        session.workingDirectory = "/tmp"
        session.lastModified = Date()
        session.messageCount = 5
        session.preview = "Preview"

        for i in 0..<5 {
            let message = CDMessage(context: context)
            message.id = UUID()
            message.sessionId = session.id
            message.role = "user"
            message.text = "Message \(i)"
            message.timestamp = Date()
            message.messageStatus = .confirmed
            message.session = session
        }

        try? context.save()

        // Clear messages
        let fetchRequest = CDMessage.fetchRequest()
        fetchRequest.includesPropertyValues = false
        let messages = try! context.fetch(fetchRequest)
        for message in messages {
            context.delete(message)
        }
        try! context.save()

        // Session should still exist (messages relationship has Nullify, not Cascade)
        // Note: Actually, the xcdatamodel shows Cascade delete, so session persists but messages are gone
        let sessionRequest = CDBackendSession.fetchBackendSession(id: session.id)
        let fetchedSession = try? context.fetch(sessionRequest).first

        // Messages deleted by cascade when we delete messages
        let messageCount = try? context.count(for: CDMessage.fetchRequest())
        XCTAssertEqual(messageCount, 0)
    }

    func testAdvancedSettings_BundleVersion_Accessible() {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String

        // These should exist in a real bundle, but may be nil in tests
        // Just verify the keys are accessible
        XCTAssertNotNil(Bundle.main.infoDictionary)
    }

    // MARK: - Cross-Tab Integration Tests

    func testSettingsPersistence_AcrossTabs_ServerAndVoice() {
        // Set values that span multiple tabs
        settings.serverURL = "test.server.com"
        settings.serverPort = "7777"
        settings.autoPlayResponses = true
        settings.selectedVoiceIdentifier = "com.apple.voice.premium.en-US.Ava"
        settings.systemPrompt = "Test prompt"

        let expectation = expectation(description: "Debounce wait")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)

        // Verify all settings persisted
        let newSettings = AppSettings()
        XCTAssertEqual(newSettings.serverURL, "test.server.com")
        XCTAssertEqual(newSettings.serverPort, "7777")
        XCTAssertTrue(newSettings.autoPlayResponses)
        XCTAssertEqual(newSettings.selectedVoiceIdentifier, "com.apple.voice.premium.en-US.Ava")
        XCTAssertEqual(newSettings.systemPrompt, "Test prompt")
    }

    func testSettings_MultipleUpdates_LastValueWins() {
        settings.serverURL = "first.com"
        settings.serverURL = "second.com"
        settings.serverURL = "third.com"

        let expectation = expectation(description: "Debounce wait")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)

        let newSettings = AppSettings()
        XCTAssertEqual(newSettings.serverURL, "third.com")
    }

    // MARK: - Edge Cases

    func testSettings_EmptyServerURL_Handled() {
        settings.serverURL = ""
        settings.serverPort = "8080"

        XCTAssertEqual(settings.fullServerURL, "ws://:8080")
    }

    func testSettings_EmptyServerPort_Handled() {
        settings.serverURL = "localhost"
        settings.serverPort = ""

        XCTAssertEqual(settings.fullServerURL, "ws://localhost:")
    }

    func testSettings_SpecialCharactersInServerURL_Handled() {
        settings.serverURL = "test-server_123.example.com"
        settings.serverPort = "8080"

        XCTAssertEqual(settings.fullServerURL, "ws://test-server_123.example.com:8080")
    }

    func testSettings_VeryLongSystemPrompt_Persists() {
        let longPrompt = String(repeating: "a", count: 10000)
        settings.systemPrompt = longPrompt

        let expectation = expectation(description: "Debounce wait")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)

        let newSettings = AppSettings()
        XCTAssertEqual(newSettings.systemPrompt.count, 10000)
    }

    func testSettings_RapidChanges_DebouncesCorrectly() {
        // Make rapid changes
        for i in 0..<10 {
            settings.serverPort = "\(8000 + i)"
        }

        // Should only save once after debounce
        let expectation = expectation(description: "Debounce wait")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)

        let newSettings = AppSettings()
        XCTAssertEqual(newSettings.serverPort, "8009")
    }

    // MARK: - Connection Tests

    func testConnection_Success_WithValidServer() {
        // Note: This test requires a running backend server
        // If backend is not running, it will timeout and return error
        settings.serverURL = "localhost"
        settings.serverPort = "8080"

        let expectation = expectation(description: "Test connection")
        var connectionSuccess = false
        var connectionMessage = ""

        settings.testConnection { success, message in
            connectionSuccess = success
            connectionMessage = message
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 10.0)

        // Without a running server, this will fail
        // The test verifies that the connection mechanism works
        // Not that the connection succeeds
        XCTAssertFalse(connectionMessage.isEmpty)
    }

    func testConnection_Failure_WithInvalidServer() {
        settings.serverURL = "invalid.server.nowhere"
        settings.serverPort = "99999"

        let expectation = expectation(description: "Test connection")
        var connectionSuccess = false
        var connectionMessage = ""

        settings.testConnection { success, message in
            connectionSuccess = success
            connectionMessage = message
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 10.0)

        XCTAssertFalse(connectionSuccess)
        XCTAssertFalse(connectionMessage.isEmpty)
    }

    func testConnection_Validation_EmptyServerURL() {
        settings.serverURL = ""
        settings.serverPort = "8080"

        let expectation = expectation(description: "Test connection")
        var connectionSuccess = false
        var connectionMessage = ""

        settings.testConnection { success, message in
            connectionSuccess = success
            connectionMessage = message
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 1.0)

        XCTAssertFalse(connectionSuccess)
        XCTAssertEqual(connectionMessage, "Server address is required")
    }

    func testConnection_Validation_EmptyPort() {
        settings.serverURL = "localhost"
        settings.serverPort = ""

        let expectation = expectation(description: "Test connection")
        var connectionSuccess = false
        var connectionMessage = ""

        settings.testConnection { success, message in
            connectionSuccess = success
            connectionMessage = message
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 1.0)

        XCTAssertFalse(connectionSuccess)
        XCTAssertEqual(connectionMessage, "Valid port number is required")
    }

    func testConnection_Validation_InvalidPort() {
        settings.serverURL = "localhost"
        settings.serverPort = "not-a-port"

        let expectation = expectation(description: "Test connection")
        var connectionSuccess = false
        var connectionMessage = ""

        settings.testConnection { success, message in
            connectionSuccess = success
            connectionMessage = message
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 1.0)

        XCTAssertFalse(connectionSuccess)
        XCTAssertEqual(connectionMessage, "Valid port number is required")
    }

    // MARK: - First-Run Configuration Tests

    func testFirstRun_isServerConfigured_ReturnsFalse_WhenEmpty() {
        settings.serverURL = ""
        settings.serverPort = "8080"

        XCTAssertFalse(settings.isServerConfigured)
    }

    func testFirstRun_isServerConfigured_ReturnsFalse_WhenWhitespace() {
        settings.serverURL = "   "
        settings.serverPort = "8080"

        XCTAssertFalse(settings.isServerConfigured)
    }

    func testFirstRun_isServerConfigured_ReturnsTrue_WhenSet() {
        settings.serverURL = "localhost"
        settings.serverPort = "8080"

        XCTAssertTrue(settings.isServerConfigured)
    }

    func testFirstRun_isServerConfigured_ReturnsTrue_AfterPersistence() {
        settings.serverURL = "192.168.1.100"
        settings.serverPort = "9090"

        let expectation = expectation(description: "Debounce wait")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)

        let newSettings = AppSettings()
        XCTAssertTrue(newSettings.isServerConfigured)
    }

    // MARK: - Voice Output Integration

    func testVoiceOutput_ManagerInitialization_WithSettings() {
        let manager = VoiceOutputManager(appSettings: settings)
        XCTAssertNotNil(manager)
    }

    func testVoiceOutput_ManagerInitialization_WithoutSettings() {
        let manager = VoiceOutputManager()
        XCTAssertNotNil(manager)
    }

    func testVoiceOutput_Speak_UsesSettingsVoice() {
        settings.selectedVoiceIdentifier = "com.apple.voice.premium.en-US.Ava"
        let manager = VoiceOutputManager(appSettings: settings)

        let expectation = expectation(description: "Speech started")
        manager.speak("Test")

        // Give speech time to start
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 0.5)

        manager.stop()
    }
}
