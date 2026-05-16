// VoiceCodeClientLiveBackendTests.swift
//
// End-to-end round-trip test: real VoiceCodeClient → real backend at localhost:9998.
// Covers the lifecycle that was broken by the v0.5.0 hello check:
//   hello(ver=0.5.0) → connect(protocol_version=0.5.0) → connected(negotiated=0.5.0)
//   → subscribe(from_offset=0) → session_history(v0.5.0 shape) → CoreData merge
//
// Skips automatically when no backend is listening on localhost:9998.

import XCTest
import CoreData
import Combine
import Network
@testable import VoiceCode

final class VoiceCodeClientLiveBackendTests: XCTestCase {

    private static let backendURL  = "ws://localhost:9998"
    private static let backendPort: UInt16 = 9998

    private var persistenceController: PersistenceController!
    private var context: NSManagedObjectContext!
    private var client: VoiceCodeClient!
    private var cancellables: Set<AnyCancellable>!

    override func setUpWithError() throws {
        try super.setUpWithError()
        try requireBackendReachable()
        try KeychainManager.shared.saveAPIKey(apiKeyFromBackend())

        persistenceController = PersistenceController(inMemory: true)
        context = persistenceController.container.viewContext
        cancellables = []

        let syncManager = SessionSyncManager(persistenceController: persistenceController)
        client = VoiceCodeClient(
            serverURL: Self.backendURL,
            sessionSyncManager: syncManager,
            setupObservers: false
        )
    }

    override func tearDownWithError() throws {
        client?.disconnect()
        client = nil
        cancellables = nil
        persistenceController = nil
        context = nil
        try? KeychainManager.shared.deleteAPIKey()
        try super.tearDownWithError()
    }

    // MARK: - Round-trip test

    /// Full lifecycle: connect → v0.5.0 negotiation → subscribe → CoreData merge.
    ///
    /// Asserts:
    ///  1. isAuthenticated = true (handshake completes)
    ///  2. negotiatedProtocolVersion = .v0_5_0 (hello floor-check fix + connect protocol_version)
    ///  3. requiresUpgrade = false (hello(ver=0.5.0) must not block)
    ///  4. CDBackendSession.lastOffsetMerged > 0 after subscribe (v0.5.0 cursor written)
    ///  5. CDBackendSession.lastFileSignature set (file_signature round-tripped)
    ///  6. CDMessage rows exist with .offset field populated
    func testFullRoundTripV050() throws {
        // --- Phase 1: connect, wait for authentication ---
        let authenticated = XCTestExpectation(description: "client authenticated")
        client.$isAuthenticated
            .filter { $0 }
            .first()
            .sink { _ in authenticated.fulfill() }
            .store(in: &cancellables)

        client.connect()
        wait(for: [authenticated], timeout: 10)

        // --- Phase 2: negotiation checks ---
        XCTAssertEqual(client.negotiatedProtocolVersion, .v0_5_0,
                       "Server advertises 0.5.0; client must negotiate to v0.5.0")
        XCTAssertFalse(client.requiresUpgrade,
                       "hello(ver=0.5.0) must not flip requiresUpgrade after the floor-check fix")

        // --- Phase 3: pick a session from the server's list ---
        let sessionsArrived = XCTestExpectation(description: "parsedRecentSessions populated")
        client.$parsedRecentSessions
            .filter { !$0.isEmpty }
            .first()
            .sink { _ in sessionsArrived.fulfill() }
            .store(in: &cancellables)

        wait(for: [sessionsArrived], timeout: 5)

        let recentSessions = client.parsedRecentSessions
        XCTAssertFalse(recentSessions.isEmpty, "Backend must return at least one recent session")

        // Use the most-recent session (first in the list from server).
        let target = recentSessions[0]
        let sid = target.sessionId
        print("📋 [RoundTripTest] Subscribing to \(sid)")

        // --- Phase 4: subscribe, wait for CoreData merge ---
        let merged = XCTestExpectation(description: "session_history v0.5.0 merged into CoreData")

        // Poll every 0.1 s for lastOffsetMerged > 0 on the subscribed session.
        let timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            guard let uuid = UUID(uuidString: sid) else { return }
            let sessions = (try? self.context.fetch(CDBackendSession.fetchBackendSession(id: uuid))) ?? []
            if let s = sessions.first, s.lastOffsetMerged > 0 {
                merged.fulfill()
            }
        }

        client.subscribe(sessionId: sid, context: context)
        wait(for: [merged], timeout: 15)
        timer.invalidate()

        // --- Phase 5: CoreData assertions ---
        guard let uuid = UUID(uuidString: sid) else {
            XCTFail("session id \(sid) is not a valid UUID"); return
        }

        let sessions = try context.fetch(CDBackendSession.fetchBackendSession(id: uuid))
        let session  = try XCTUnwrap(sessions.first,
                                     "CDBackendSession must exist after v0.5.0 subscribe")

        XCTAssertGreaterThan(session.lastOffsetMerged, 0,
                             "lastOffsetMerged must advance after session_history v0.5.0 merge")

        XCTAssertNotNil(session.lastFileSignature,
                        "lastFileSignature must be set from session_history.file_signature")
        XCTAssertTrue(session.lastFileSignature?.contains(":") == true,
                      "file_signature must be '{length}:{uuid}', got: \(session.lastFileSignature ?? "<nil>")")

        context.refreshAllObjects()
        let msgReq: NSFetchRequest<CDMessage> = CDMessage.fetchRequest()
        msgReq.predicate = NSPredicate(format: "sessionId == %@", uuid as CVarArg)
        let messages = try context.fetch(msgReq)

        XCTAssertFalse(messages.isEmpty,
                       "CDMessage rows must exist after session_history merge")

        for msg in messages {
            XCTAssertGreaterThanOrEqual(msg.offset, 0,
                                        "CDMessage.offset must be populated (v0.5.0); seq cursor must not be used")
        }

        print("✅ [RoundTripTest] PASS — negotiated=\(client.negotiatedProtocolVersion.rawValue) lastOffsetMerged=\(session.lastOffsetMerged) messages=\(messages.count) sig=\(session.lastFileSignature ?? "-")")
    }

    // MARK: - Helpers

    /// Throws XCTSkip when no TCP listener is on localhost:9998.
    private func requireBackendReachable() throws {
        var reachable = false
        let sem = DispatchSemaphore(value: 0)
        let conn = NWConnection(
            host: "localhost",
            port: NWEndpoint.Port(rawValue: Self.backendPort)!,
            using: .tcp
        )
        conn.stateUpdateHandler = { state in
            switch state {
            case .ready:
                reachable = true
                conn.cancel()
                sem.signal()
            case .failed, .cancelled, .waiting:
                conn.cancel()
                sem.signal()
            default: break
            }
        }
        conn.start(queue: .global())
        _ = sem.wait(timeout: .now() + 3)
        if !reachable {
            throw XCTSkip("Backend not reachable at localhost:\(Self.backendPort) — skipping live round-trip test")
        }
    }

    /// Read the API key from the file the backend writes on startup.
    /// Uses SIMULATOR_HOST_HOME so the path resolves to the real home directory
    /// rather than the simulator sandbox's ~.
    private func apiKeyFromBackend() throws -> String {
        let home = ProcessInfo.processInfo.environment["SIMULATOR_HOST_HOME"]
            ?? ProcessInfo.processInfo.environment["HOME"]
            ?? NSHomeDirectory()
        let path = (home as NSString).appendingPathComponent(".untethered/api-key")
        guard let raw = try? String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8) else {
            throw XCTSkip("Cannot read backend API key from \(path) — skipping live round-trip test")
        }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
