// ActiveSessionManagerThreadSafetyTests.swift
// Tests for ActiveSessionManager thread safety. Covers tmux-untethered-2kp:
// isActive() must be safe to call from background threads while setActiveSession
// / clearActiveSession are called from the main thread.

import XCTest
@testable import VoiceCode

final class ActiveSessionManagerThreadSafetyTests: XCTestCase {

    override func tearDown() {
        ActiveSessionManager.shared.clearActiveSession()
        super.tearDown()
    }

    // MARK: - Functional correctness

    func testSetActiveSessionMakesIsActiveReturnTrue() {
        let id = UUID()
        ActiveSessionManager.shared.setActiveSession(id)
        XCTAssertTrue(ActiveSessionManager.shared.isActive(id))
    }

    func testClearActiveSessionMakesIsActiveReturnFalse() {
        let id = UUID()
        ActiveSessionManager.shared.setActiveSession(id)
        ActiveSessionManager.shared.clearActiveSession()
        XCTAssertFalse(ActiveSessionManager.shared.isActive(id))
    }

    func testIsActiveReturnsFalseForDifferentSession() {
        let id1 = UUID()
        let id2 = UUID()
        ActiveSessionManager.shared.setActiveSession(id1)
        XCTAssertFalse(ActiveSessionManager.shared.isActive(id2))
    }

    func testIsActiveReturnsFalseWhenNoneSet() {
        ActiveSessionManager.shared.clearActiveSession()
        XCTAssertFalse(ActiveSessionManager.shared.isActive(UUID()))
    }

    // MARK: - Thread safety

    // Verify that concurrent reads from background threads do not crash or
    // produce incorrect results while the main thread writes. This is the
    // regression test for tmux-untethered-2kp: the prior implementation read
    // activeSessionId from background queues without synchronization.
    func testConcurrentReadsDontCrash() {
        let sessionId = UUID()
        ActiveSessionManager.shared.setActiveSession(sessionId)

        let iterations = 500
        let expectation = XCTestExpectation(description: "all concurrent reads complete")
        expectation.expectedFulfillmentCount = iterations

        for _ in 0..<iterations {
            DispatchQueue.global().async {
                _ = ActiveSessionManager.shared.isActive(sessionId)
                expectation.fulfill()
            }
        }

        wait(for: [expectation], timeout: 5.0)
    }

    // Interleave main-thread writes with background reads; assert no crash.
    func testConcurrentReadsAndWritesDontCrash() {
        let sessionId = UUID()
        let iterations = 300
        let readExpectation = XCTestExpectation(description: "reads")
        readExpectation.expectedFulfillmentCount = iterations
        let writeExpectation = XCTestExpectation(description: "writes")
        writeExpectation.expectedFulfillmentCount = iterations

        for i in 0..<iterations {
            // Write from main thread (mirrors real usage pattern)
            DispatchQueue.main.async {
                if i % 2 == 0 {
                    ActiveSessionManager.shared.setActiveSession(sessionId)
                } else {
                    ActiveSessionManager.shared.clearActiveSession()
                }
                writeExpectation.fulfill()
            }
            // Read from background thread (mirrors SessionSyncManager usage)
            DispatchQueue.global().async {
                _ = ActiveSessionManager.shared.isActive(sessionId)
                readExpectation.fulfill()
            }
        }

        wait(for: [readExpectation, writeExpectation], timeout: 10.0)
    }

    // Verify that setActiveSession with nil clears isActive for any session.
    func testSetActiveSessionNilClearsActive() {
        let id = UUID()
        ActiveSessionManager.shared.setActiveSession(id)
        XCTAssertTrue(ActiveSessionManager.shared.isActive(id))
        ActiveSessionManager.shared.setActiveSession(nil)
        XCTAssertFalse(ActiveSessionManager.shared.isActive(id))
    }
}
