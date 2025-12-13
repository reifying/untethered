import XCTest
import Combine
@testable import VoiceCodeShared

@MainActor
final class ActiveSessionManagerTests: XCTestCase {

    // MARK: - Initialization Tests

    func testInitialStateIsNil() {
        let manager = ActiveSessionManager()
        XCTAssertNil(manager.activeSessionId)
    }

    // MARK: - Set Active Session Tests

    func testSetActiveSession() {
        let manager = ActiveSessionManager()
        let sessionId = UUID()

        manager.setActiveSession(sessionId)

        XCTAssertEqual(manager.activeSessionId, sessionId)
    }

    func testSetActiveSessionToNil() {
        let manager = ActiveSessionManager()
        let sessionId = UUID()

        manager.setActiveSession(sessionId)
        manager.setActiveSession(nil)

        XCTAssertNil(manager.activeSessionId)
    }

    func testSetActiveSessionReplacesExisting() {
        let manager = ActiveSessionManager()
        let sessionId1 = UUID()
        let sessionId2 = UUID()

        manager.setActiveSession(sessionId1)
        manager.setActiveSession(sessionId2)

        XCTAssertEqual(manager.activeSessionId, sessionId2)
        XCTAssertNotEqual(manager.activeSessionId, sessionId1)
    }

    // MARK: - Is Active Tests

    func testIsActiveReturnsTrue() {
        let manager = ActiveSessionManager()
        let sessionId = UUID()

        manager.setActiveSession(sessionId)

        XCTAssertTrue(manager.isActive(sessionId))
    }

    func testIsActiveReturnsFalseForDifferentSession() {
        let manager = ActiveSessionManager()
        let sessionId1 = UUID()
        let sessionId2 = UUID()

        manager.setActiveSession(sessionId1)

        XCTAssertFalse(manager.isActive(sessionId2))
    }

    func testIsActiveReturnsFalseWhenNoActiveSession() {
        let manager = ActiveSessionManager()
        let sessionId = UUID()

        XCTAssertFalse(manager.isActive(sessionId))
    }

    // MARK: - Clear Active Session Tests

    func testClearActiveSession() {
        let manager = ActiveSessionManager()
        let sessionId = UUID()

        manager.setActiveSession(sessionId)
        manager.clearActiveSession()

        XCTAssertNil(manager.activeSessionId)
    }

    func testClearActiveSessionWhenAlreadyNil() {
        let manager = ActiveSessionManager()

        manager.clearActiveSession()

        XCTAssertNil(manager.activeSessionId)
    }

    // MARK: - Published Property Tests

    func testActiveSessionIdPublished() async {
        let manager = ActiveSessionManager()
        let sessionId = UUID()
        var receivedValues: [UUID?] = []

        let cancellable = manager.$activeSessionId
            .sink { value in
                receivedValues.append(value)
            }

        manager.setActiveSession(sessionId)
        manager.clearActiveSession()

        // Allow time for publishers to emit
        try? await Task.sleep(nanoseconds: 10_000_000) // 10ms

        cancellable.cancel()

        XCTAssertEqual(receivedValues.count, 3)
        XCTAssertNil(receivedValues[0]) // Initial value
        XCTAssertEqual(receivedValues[1], sessionId) // After setActiveSession
        XCTAssertNil(receivedValues[2]) // After clearActiveSession
    }

    // MARK: - Configuration Tests

    func testActiveSessionConfigSubsystem() {
        let originalSubsystem = ActiveSessionConfig.subsystem
        ActiveSessionConfig.subsystem = "com.test.voicecode"
        XCTAssertEqual(ActiveSessionConfig.subsystem, "com.test.voicecode")
        ActiveSessionConfig.subsystem = originalSubsystem
    }
}
