// LogManagerPersistenceTests.swift
// The log written to disk, so that a crash leaves something behind.

import XCTest
@testable import VoiceCode

final class LogManagerPersistenceTests: XCTestCase {

    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("log-persistence-tests-\(UUID().uuidString.lowercased())", isDirectory: true)
    }

    override func tearDown() {
        LogManager.shared.stopPersisting()
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private var current: URL { directory.appendingPathComponent(LogManager.logFileName) }

    private func fileLines(_ name: String) -> [String] {
        LogManager.tail(of: directory.appendingPathComponent(name), lines: 10_000) ?? []
    }

    /// Everything LogManager does is queued; reading the log back waits for it.
    private func flush() { _ = LogManager.shared.getRecentLogs(maxBytes: 1) }

    func testLinesAreWrittenToTheFileAsTheyAreLogged() {
        LogManager.shared.startPersisting(in: directory)
        LogManager.shared.log("hello from the test", category: "PersistTest")
        flush()

        let lines = fileLines(LogManager.logFileName)
        XCTAssertTrue(lines.first?.hasPrefix("=== launch ") == true, "each file starts by saying which launch it is")
        XCTAssertTrue(lines.contains { $0.hasSuffix("[PersistTest] hello from the test") })
    }

    func testEachLaunchStartsANewFileAndKeepsTheTwoBefore() {
        for run in 1...4 {
            LogManager.shared.startPersisting(in: directory)
            LogManager.shared.log("run \(run)", category: "PersistTest")
            LogManager.shared.stopPersisting()
        }

        XCTAssertTrue(fileLines(LogManager.logFileName).contains { $0.hasSuffix("run 4") })
        XCTAssertTrue(fileLines("untethered.1.log").contains { $0.hasSuffix("run 3") })
        XCTAssertTrue(fileLines("untethered.2.log").contains { $0.hasSuffix("run 2") })
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        XCTAssertEqual(files.sorted(), ["untethered.1.log", "untethered.2.log", "untethered.log"],
                       "the oldest run is dropped")
    }

    /// The case this exists for: the app died, and the next launch can say what it
    /// was doing, in the in-app log and so in Share Logs.
    func testAfterACrashTheNextLaunchCarriesThePreviousRunsLastLines() {
        LogManager.shared.startPersisting(in: directory)
        LogManager.shared.log("the last thing before the crash", category: "PersistTest")
        LogManager.shared.stopPersisting()        // no clean-exit marker: the process just went

        LogManager.shared.startPersisting(in: directory)
        flush()

        let memory = LogManager.shared.getAllLogs()
        XCTAssertTrue(memory.contains("the previous run did not exit cleanly"))
        XCTAssertTrue(memory.contains("  | ") && memory.contains("the last thing before the crash"))
    }

    func testAfterACleanExitNothingIsCarriedOver() {
        let marker = "unique-\(UUID().uuidString.lowercased())"
        LogManager.shared.startPersisting(in: directory)
        LogManager.shared.log(marker, category: "PersistTest")
        LogManager.shared.markCleanExit()
        LogManager.shared.stopPersisting()
        LogManager.shared.clearLogs()

        LogManager.shared.startPersisting(in: directory)
        flush()

        XCTAssertFalse(LogManager.shared.getAllLogs().contains(marker))
        XCTAssertEqual(fileLines("untethered.1.log").last, LogManager.cleanExitMarker)
    }

    func testTailReturnsTheLastLinesOrNilWithNoFile() throws {
        XCTAssertNil(LogManager.tail(of: current, lines: 5))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "a\nb\nc\nd\n".write(to: current, atomically: true, encoding: .utf8)
        XCTAssertEqual(LogManager.tail(of: current, lines: 2), ["c", "d"])
        XCTAssertEqual(LogManager.tail(of: current, lines: 50), ["a", "b", "c", "d"])
    }

    func testTestRunsDoNotWriteToTheRealLogFolder() {
        LogManager.shared.startPersisting()       // no folder given, inside a test run

        XCTAssertFalse(LogManager.shared.isPersisting,
                       "running the tests must not rotate away the log of a real session")
    }

    func testIsPersistingFollowsStartAndStop() {
        LogManager.shared.startPersisting(in: directory)
        XCTAssertTrue(LogManager.shared.isPersisting)
        LogManager.shared.stopPersisting()
        XCTAssertFalse(LogManager.shared.isPersisting)
    }
}
