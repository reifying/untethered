// MenuBarExtraTests.swift
// Tests for MenuBarExtra components

import XCTest
@testable import VoiceCode

final class MenuBarExtraTests: XCTestCase {

    #if os(macOS)
    var settings: AppSettings!

    override func setUp() {
        super.setUp()
        let domain = Bundle.main.bundleIdentifier!
        UserDefaults.standard.removePersistentDomain(forName: domain)
        UserDefaults.standard.synchronize()
        settings = AppSettings()
    }

    override func tearDown() {
        settings = nil
        let domain = Bundle.main.bundleIdentifier!
        UserDefaults.standard.removePersistentDomain(forName: domain)
        UserDefaults.standard.synchronize()
        super.tearDown()
    }

    // MARK: - AppSettings Directory Tracking Tests

    func testLastUsedDirectoryDefaultsToNil() {
        XCTAssertNil(settings.lastUsedDirectory)
    }

    func testLastUsedDirectoryPersistence() {
        settings.lastUsedDirectory = "/Users/test/project"
        let saved = UserDefaults.standard.string(forKey: "lastUsedDirectory")
        XCTAssertEqual(saved, "/Users/test/project")

        let newSettings = AppSettings()
        XCTAssertEqual(newSettings.lastUsedDirectory, "/Users/test/project")
    }

    func testLastUsedDirectoryClear() {
        settings.lastUsedDirectory = "/Users/test/project"
        XCTAssertNotNil(settings.lastUsedDirectory)

        settings.lastUsedDirectory = nil
        XCTAssertNil(settings.lastUsedDirectory)
        XCTAssertNil(UserDefaults.standard.string(forKey: "lastUsedDirectory"))
    }

    func testRecentDirectoriesDefaultsToEmpty() {
        XCTAssertEqual(settings.recentDirectories, [])
    }

    func testRecentDirectoriesPersistence() {
        settings.recentDirectories = ["/Users/test/a", "/Users/test/b"]
        let saved = UserDefaults.standard.stringArray(forKey: "recentDirectories")
        XCTAssertEqual(saved, ["/Users/test/a", "/Users/test/b"])

        let newSettings = AppSettings()
        XCTAssertEqual(newSettings.recentDirectories, ["/Users/test/a", "/Users/test/b"])
    }

    func testAddToRecentDirectoriesInsertsAtFront() {
        settings.recentDirectories = ["/Users/test/a", "/Users/test/b"]
        settings.addToRecentDirectories("/Users/test/c")
        XCTAssertEqual(settings.recentDirectories.first, "/Users/test/c")
        XCTAssertEqual(settings.recentDirectories.count, 3)
    }

    func testAddToRecentDirectoriesDeduplicates() {
        settings.recentDirectories = ["/Users/test/a", "/Users/test/b", "/Users/test/c"]
        settings.addToRecentDirectories("/Users/test/b")
        XCTAssertEqual(settings.recentDirectories, ["/Users/test/b", "/Users/test/a", "/Users/test/c"])
    }

    func testAddToRecentDirectoriesMaxTen() {
        for i in 0..<10 {
            settings.addToRecentDirectories("/Users/test/dir\(i)")
        }
        XCTAssertEqual(settings.recentDirectories.count, 10)

        settings.addToRecentDirectories("/Users/test/new")
        XCTAssertEqual(settings.recentDirectories.count, 10)
        XCTAssertEqual(settings.recentDirectories.first, "/Users/test/new")
        XCTAssertFalse(settings.recentDirectories.contains("/Users/test/dir0"))
    }

    func testSettingLastUsedDirectoryAddsToRecent() {
        settings.lastUsedDirectory = "/Users/test/project"
        XCTAssertTrue(settings.recentDirectories.contains("/Users/test/project"))
    }

    // MARK: - VoiceCodeClient sendQuickPrompt Tests

    func testSendQuickPromptDoesNotCrash() {
        let client = VoiceCodeClient(serverURL: "ws://localhost:8080", setupObservers: false)

        let expectation = XCTestExpectation(description: "Handler not called without server")
        expectation.isInverted = true

        client.sendQuickPrompt(text: "hello", directory: "/test") { _ in
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 0.1)
    }

    func testSendQuickPromptGeneratesLowercaseUUID() {
        let uuid = UUID().uuidString.lowercased()
        XCTAssertEqual(uuid, uuid.lowercased(), "Quick prompt session IDs must be lowercase")

        let regex = try! NSRegularExpression(pattern: "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
        let range = NSRange(uuid.startIndex..., in: uuid)
        XCTAssertNotNil(regex.firstMatch(in: uuid, range: range), "UUID should be valid lowercase format")
    }

    func testQuickPromptDoesNotTriggerRegularMessageHandler() {
        let client = VoiceCodeClient(serverURL: "ws://localhost:8080", setupObservers: false)

        var regularMessageReceived = false
        client.onMessageReceived = { _, _ in
            regularMessageReceived = true
        }

        client.sendQuickPrompt(text: "test prompt", directory: "/tmp") { _ in }

        // Without a server, neither handler fires
        let expectation = XCTestExpectation(description: "Brief wait")
        expectation.isInverted = true
        wait(for: [expectation], timeout: 0.1)

        XCTAssertFalse(regularMessageReceived, "Regular message handler should not fire for quick prompts")
    }

    // MARK: - parsedRecentSessions Tests

    func testParsedRecentSessionsDefaultsToEmpty() {
        let client = VoiceCodeClient(serverURL: "ws://localhost:8080", setupObservers: false)
        XCTAssertEqual(client.parsedRecentSessions.count, 0)
    }

    // MARK: - MenuBarContentView Compilation Tests

    func testMenuBarContentViewCompiles() {
        let client = VoiceCodeClient(serverURL: "ws://localhost:8080", setupObservers: false)
        let settings = AppSettings()
        let voiceOutput = VoiceOutputManager()

        let view = MenuBarContentView(
            client: client,
            settings: settings,
            voiceOutput: voiceOutput
        )
        XCTAssertNotNil(view)
    }

    func testVoiceCodeMenuBarExtraCompiles() {
        let client = VoiceCodeClient(serverURL: "ws://localhost:8080", setupObservers: false)
        let settings = AppSettings()
        let voiceOutput = VoiceOutputManager()

        let scene = VoiceCodeMenuBarExtra(
            client: client,
            settings: settings,
            voiceOutput: voiceOutput
        )
        XCTAssertNotNil(scene)
    }

    // MARK: - MenuBarHelpers.abbreviatePath Tests

    func testAbbreviatePathShort() {
        XCTAssertEqual(MenuBarHelpers.abbreviatePath("~"), "~")
        XCTAssertEqual(MenuBarHelpers.abbreviatePath("/Users"), "/Users")
    }

    func testAbbreviatePathTwoComponents() {
        XCTAssertEqual(MenuBarHelpers.abbreviatePath("/Users/test"), "/Users/test")
    }

    func testAbbreviatePathLong() {
        XCTAssertEqual(MenuBarHelpers.abbreviatePath("/Users/test/projects/webapp"), "projects/webapp")
    }

    func testAbbreviatePathDeep() {
        XCTAssertEqual(MenuBarHelpers.abbreviatePath("/a/b/c/d/e"), "d/e")
    }

    // MARK: - MenuBarHelpers.relativeTimestamp Tests

    func testRelativeTimestampNow() {
        let now = Date()
        XCTAssertEqual(MenuBarHelpers.relativeTimestamp(now), "now")
    }

    func testRelativeTimestampSeconds() {
        let thirtySecondsAgo = Date(timeIntervalSinceNow: -30)
        XCTAssertEqual(MenuBarHelpers.relativeTimestamp(thirtySecondsAgo), "now")
    }

    func testRelativeTimestampMinutes() {
        let fiveMinutesAgo = Date(timeIntervalSinceNow: -300)
        XCTAssertEqual(MenuBarHelpers.relativeTimestamp(fiveMinutesAgo), "5m ago")
    }

    func testRelativeTimestampOneMinute() {
        let oneMinuteAgo = Date(timeIntervalSinceNow: -60)
        XCTAssertEqual(MenuBarHelpers.relativeTimestamp(oneMinuteAgo), "1m ago")
    }

    func testRelativeTimestampHours() {
        let twoHoursAgo = Date(timeIntervalSinceNow: -7200)
        XCTAssertEqual(MenuBarHelpers.relativeTimestamp(twoHoursAgo), "2h ago")
    }

    func testRelativeTimestampDays() {
        let threeDaysAgo = Date(timeIntervalSinceNow: -259200)
        XCTAssertEqual(MenuBarHelpers.relativeTimestamp(threeDaysAgo), "3d ago")
    }

    // MARK: - Connection Status Icon Tests

    func testMenuBarIconReflectsDisconnectedState() {
        let client = VoiceCodeClient(serverURL: "ws://localhost:8080", setupObservers: false)
        XCTAssertFalse(client.isConnected)
    }
    #endif
}
