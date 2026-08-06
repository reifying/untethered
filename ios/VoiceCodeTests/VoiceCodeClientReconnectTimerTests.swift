// VoiceCodeClientReconnectTimerTests.swift
//
// Pins the reconnection timer's lifecycle invariant: **it exists only while
// the socket is down.**
//
// The defect these tests close: the timer was created `repeating:` and was
// never cancelled when the connection came up, so it kept firing for the
// whole life of a healthy session — once every ~1.2s on the shipped build,
// waking the device and writing a "Reconnection timer fired" line each time
// that did no work. In a real 6-minute phone log those lines were 37% of
// every line captured, which crowds real signal out of the 5000-line buffer.
//
// A repeating timer also froze its interval at whatever the attempt count
// was when it was created, so the exponential backoff never advanced on any
// retry path that did not route all the way through `connect()`.
//
// Cancelling on connect is only safe if something arms the timer again when
// the socket dies, so `testSocketFailureRearmsReconnection` is as
// load-bearing here as the silence tests.

import XCTest
@testable import VoiceCode

final class VoiceCodeClientReconnectTimerTests: XCTestCase {
    var client: VoiceCodeClient!

    /// A URL that fails `connect()`'s "is this server usable?" guard (no
    /// port), so a retry tick runs its whole decision path without opening a
    /// real socket to a port the test host may or may not have something
    /// listening on. This is also the exact shape that used to leave the
    /// backoff frozen: `connect()` returns before it can arm anything.
    private let unusableServerURL = "ws://localhost"

    override func setUpWithError() throws {
        LogManager.shared.clearLogs()
        client = VoiceCodeClient(serverURL: unusableServerURL, setupObservers: false)
    }

    override func tearDownWithError() throws {
        client?.disconnect()
        client = nil
        LogManager.shared.clearLogs()
    }

    // MARK: - Helpers

    /// Longest possible attempt-0 retry interval is 1.25s (1s base + 25%
    /// jitter). Waiting past two of those means a repeating timer would have
    /// fired at least twice inside the window.
    private func waitPastTwoRetryIntervals() {
        let quiet = expectation(description: "quiet window")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) { quiet.fulfill() }
        wait(for: [quiet], timeout: 6.0)
    }

    private func drainMainQueue(timeout: TimeInterval = 1.0) {
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { drained.fulfill() }
        wait(for: [drained], timeout: timeout)
    }

    private func loggedLines(containing needle: String) -> [String] {
        // LogManager.log enqueues on a serial queue; getAllLogs reads it with
        // queue.sync, so anything already handed to log() is visible here.
        LogManager.shared.getAllLogs()
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { $0.contains(needle) }
    }

    // MARK: - The connection is up: nothing is scheduled, nothing is logged

    /// The headline contract. With the socket live there is nothing to
    /// reconnect, so arming must be refused outright — not armed-and-ignored.
    /// The 2.6s silence window is the part that fails against the old
    /// repeating timer, which logged a fire roughly every 1.2s forever.
    func testArmingWhileConnectedSchedulesNothing() {
        client.isConnected = true

        client.setupReconnection()

        XCTAssertFalse(client.isReconnectionTimerArmedForTesting,
                       "No retry may be scheduled while the socket is up")

        waitPastTwoRetryIntervals()

        let fires = loggedLines(containing: "Reconnection timer fired")
        XCTAssertTrue(fires.isEmpty,
                      "A healthy connection must produce zero reconnection wakeups; got \(fires.count): \(fires)")
        XCTAssertEqual(client.reconnectionAttemptsForTesting, 0,
                       "A healthy connection must not consume reconnection attempts")
    }

    /// A tick can still be in flight when `hello` lands. That tick must
    /// notice, leave nothing scheduled, and say nothing — a log line per
    /// near-miss would be the same noise in slower motion.
    func testTickThatFindsTheSocketUpDisarmsSilently() {
        client.setupReconnection()
        XCTAssertTrue(client.isReconnectionTimerArmedForTesting,
                      "Test setup: a disconnected client must have a retry scheduled")

        client.isConnected = true
        client.handleReconnectionTick()

        XCTAssertFalse(client.isReconnectionTimerArmedForTesting,
                       "A tick that finds the socket up must not re-arm")
        XCTAssertEqual(client.reconnectionAttemptsForTesting, 0,
                       "A tick that does no work must not consume an attempt")
        XCTAssertTrue(loggedLines(containing: "Reconnection timer fired").isEmpty,
                      "A tick that does no work must not log")
    }

    /// `hello` is the moment the socket is confirmed live, and it is where
    /// production disarms. Driven through `handleMessage` so the wiring —
    /// not just the helper — is covered.
    func testHelloDisarmsTheReconnectionTimer() throws {
        // Without a stored API key the `hello` handler falls through to
        // `sendConnectMessage`, which stops reconnection for its own reason
        // (credentials required) — that would make this test pass without
        // proving anything. Give it a key so the only thing that can disarm
        // us is the connection-established path.
        let previousKey = KeychainManager.shared.retrieveAPIKey()
        try KeychainManager.shared.saveAPIKey("untethered-" + String(repeating: "a", count: 32))
        defer {
            if let previousKey = previousKey {
                try? KeychainManager.shared.saveAPIKey(previousKey)
            } else {
                try? KeychainManager.shared.deleteAPIKey()
            }
        }

        client.setupReconnection()
        XCTAssertTrue(client.isReconnectionTimerArmedForTesting,
                      "Test setup: a disconnected client must have a retry scheduled")

        client.handleMessage(#"{"type":"hello","version":"0.5.0","auth_version":1}"#)
        drainMainQueue()

        XCTAssertTrue(client.isConnected, "Test setup: hello must mark the client connected")
        XCTAssertFalse(client.requiresReauthentication,
                       "Test setup: with a stored key, hello must not enter the credentials-required state")
        XCTAssertFalse(client.isReconnectionTimerArmedForTesting,
                       "A confirmed live socket must leave no retry scheduled")
    }

    // MARK: - The connection is down: a retry is always scheduled

    /// The counterpart to disarming on connect: when the socket dies the
    /// client must schedule its own recovery. Nothing else does — `connect()`
    /// is otherwise only reached from app-foreground — so without this the
    /// app would sit offline until the user backgrounded and reopened it.
    func testSocketFailureRearmsReconnection() {
        client.isConnected = true
        client.isAuthenticated = true
        client.setupReconnection()
        XCTAssertFalse(client.isReconnectionTimerArmedForTesting,
                       "Test setup: a live connection has no retry scheduled")

        client.handleSocketFailure(errorDescription: "simulated socket loss")

        XCTAssertFalse(client.isConnected, "Socket loss must clear isConnected")
        XCTAssertFalse(client.isAuthenticated, "Auth is socket-scoped; socket loss must clear it")
        XCTAssertTrue(client.isReconnectionTimerArmedForTesting,
                      "Socket loss must schedule a reconnection attempt")
    }

    /// A tick that finds the socket down consumes an attempt and schedules
    /// the next one *even when `connect()` bails out early*. The old
    /// repeating timer papered over this by re-firing forever at the
    /// attempt-0 interval, which advanced the attempt counter roughly once a
    /// second and exhausted all 20 attempts in ~23s instead of the ~17
    /// minutes the cap is documented to buy.
    func testTickRetriesAndRearmsEvenWhenConnectBailsOut() {
        XCTAssertEqual(client.reconnectionAttemptsForTesting, 0)

        client.handleReconnectionTick()

        XCTAssertEqual(client.reconnectionAttemptsForTesting, 1,
                       "A tick with the socket down must consume one attempt")
        XCTAssertTrue(client.isReconnectionTimerArmedForTesting,
                      "A retry must be scheduled even though connect() rejected the server URL")
        XCTAssertEqual(loggedLines(containing: "Reconnection timer fired").count, 1,
                       "A tick that does work logs exactly once")

        client.handleReconnectionTick()

        XCTAssertEqual(client.reconnectionAttemptsForTesting, 2,
                       "Successive ticks must keep advancing the attempt count")
        XCTAssertTrue(client.isReconnectionTimerArmedForTesting)
    }

    /// The retry interval is what advances with the attempt count — that is
    /// the whole point of tracking attempts, and a frozen interval is what
    /// the repeating timer produced.
    func testRetryDelayGrowsWithAttemptCount() {
        // Jitter is ±25%, so consecutive attempts can't be compared
        // pointwise; two doublings apart cannot overlap.
        XCTAssertLessThan(client.calculateReconnectionDelay(attempt: 0),
                          client.calculateReconnectionDelay(attempt: 2))
        XCTAssertLessThan(client.calculateReconnectionDelay(attempt: 2),
                          client.calculateReconnectionDelay(attempt: 4))
    }

    // MARK: - Terminal states leave reconnection stopped

    /// A deliberate teardown must not schedule a comeback.
    func testDisconnectLeavesReconnectionStopped() {
        client.setupReconnection()
        XCTAssertTrue(client.isReconnectionTimerArmedForTesting)

        client.disconnect()

        XCTAssertFalse(client.isReconnectionTimerArmedForTesting,
                       "disconnect() is deliberate; it must not leave a retry scheduled")

        waitPastTwoRetryIntervals()
        XCTAssertTrue(loggedLines(containing: "Reconnection timer fired").isEmpty,
                      "A disconnected-on-purpose client must produce no reconnection wakeups")
    }

    /// Attempts exhausted is terminal: surface the error and stop, rather
    /// than keep waking the device.
    func testAttemptsExhaustedStopsRetrying() {
        for _ in 0..<25 {
            client.handleReconnectionTick()
        }
        drainMainQueue()

        XCTAssertFalse(client.isReconnectionTimerArmedForTesting,
                       "Once the attempt cap is reached, nothing further may be scheduled")
        XCTAssertFalse(loggedLines(containing: "Max reconnection attempts").isEmpty,
                       "Giving up must be recorded")
        XCTAssertNotNil(client.currentError,
                        "Giving up must surface an error the UI can show")
    }
}
