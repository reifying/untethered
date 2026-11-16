// TestRunDefaultsGuardTests.swift
// The Mac unit tests share the real app's settings. The guard saves them before
// a test run and puts them back at the next normal launch. Exercised here on a
// private settings domain, never the app's own.

#if os(macOS)
import XCTest
@testable import VoiceCode

final class TestRunDefaultsGuardTests: XCTestCase {

    private var domain: String!
    private var defaults: UserDefaults!
    private var snapshot: URL!

    override func setUp() {
        super.setUp()
        domain = "dev.910labs.voice-code.guard-tests.\(UUID().uuidString.lowercased())"
        defaults = UserDefaults(suiteName: domain)
        snapshot = FileManager.default.temporaryDirectory
            .appendingPathComponent("guard-tests-\(UUID().uuidString.lowercased())")
            .appendingPathComponent(TestRunDefaultsGuard.snapshotFileName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: domain)
        try? FileManager.default.removeItem(at: snapshot.deletingLastPathComponent())
        super.tearDown()
    }

    func testSettingsChangedByATestRunArePutBack() {
        defaults.set(true, forKey: "blueParrottEnabled")
        defaults.set("11111111-2222-3333-4444-555555555555", forKey: "blueParrottPeripheralID")
        defaults.set("10.0.0.5", forKey: "serverURL")

        XCTAssertTrue(TestRunDefaultsGuard.saveIfAbsent(domain: domain, to: snapshot, defaults: defaults))
        // What the tests do to the settings:
        defaults.removeObject(forKey: "blueParrottEnabled")
        defaults.removeObject(forKey: "blueParrottPeripheralID")
        defaults.set("192.168.1.100", forKey: "serverURL")
        defaults.set(true, forKey: "voiceOutputMuted")

        XCTAssertTrue(TestRunDefaultsGuard.restoreIfPresent(domain: domain, from: snapshot, defaults: defaults))

        XCTAssertTrue(defaults.bool(forKey: "blueParrottEnabled"), "a removed key comes back")
        XCTAssertEqual(defaults.string(forKey: "blueParrottPeripheralID"), "11111111-2222-3333-4444-555555555555")
        XCTAssertEqual(defaults.string(forKey: "serverURL"), "10.0.0.5", "a changed key is reverted")
        XCTAssertNil(defaults.object(forKey: "voiceOutputMuted"), "a key the tests added is gone")
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshot.path), "the snapshot is used once")
    }

    /// The test host is launched many times in one run (once per crash, before the
    /// crashes were fixed). Only the first launch sees the settings as the user left them.
    func testOnlyTheFirstLaunchOfATestRunSavesTheSettings() {
        defaults.set("as the user left it", forKey: "serverURL")
        XCTAssertTrue(TestRunDefaultsGuard.saveIfAbsent(domain: domain, to: snapshot, defaults: defaults))

        defaults.set("changed by a test", forKey: "serverURL")
        XCTAssertFalse(TestRunDefaultsGuard.saveIfAbsent(domain: domain, to: snapshot, defaults: defaults))

        TestRunDefaultsGuard.restoreIfPresent(domain: domain, from: snapshot, defaults: defaults)
        XCTAssertEqual(defaults.string(forKey: "serverURL"), "as the user left it")
    }

    func testANormalLaunchWithNoSnapshotChangesNothing() {
        defaults.set("untouched", forKey: "serverURL")

        XCTAssertFalse(TestRunDefaultsGuard.restoreIfPresent(domain: domain, from: snapshot, defaults: defaults))

        XCTAssertEqual(defaults.string(forKey: "serverURL"), "untouched")
    }

    func testAnUnreadableSnapshotIsDiscardedWithoutTouchingTheSettings() throws {
        defaults.set("untouched", forKey: "serverURL")
        try FileManager.default.createDirectory(at: snapshot.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not a property list".utf8).write(to: snapshot)

        XCTAssertFalse(TestRunDefaultsGuard.restoreIfPresent(domain: domain, from: snapshot, defaults: defaults))

        XCTAssertEqual(defaults.string(forKey: "serverURL"), "untouched")
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshot.path))
    }

    /// This very test run is inside the guard: the host app saved the real settings
    /// when it launched.
    func testThisTestRunSavedTheRealSettings() throws {
        let url = try XCTUnwrap(TestRunDefaultsGuard.defaultSnapshotURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                      "the test host did not snapshot the app's settings at launch")
    }
}
#endif
