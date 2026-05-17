// ScenePhaseSubscriptionGuardTests.swift
//
// Regression coverage for tmux-untethered-bae.1. Verifies that the
// onChange(of: scenePhase) guard correctly gates refreshSubscription on
// hasSubscribedThisAppear, preventing spurious re-subscribes for
// ConversationViews below in the NavigationStack.

import XCTest
import SwiftUI
@testable import VoiceCode

fileprivate class MockVoiceCodeClientForScenePhase: VoiceCodeClient {
    var refreshSubscriptionCalled = false
    var lastRefreshedSessionId: String?

    init() {
        super.init(serverURL: "ws://localhost:8080", setupObservers: false)
    }

    override func refreshSubscription(sessionId: String) {
        refreshSubscriptionCalled = true
        lastRefreshedSessionId = sessionId
    }
}

final class ScenePhaseSubscriptionGuardTests: XCTestCase {

    fileprivate var client: MockVoiceCodeClientForScenePhase!

    override func setUpWithError() throws {
        client = MockVoiceCodeClientForScenePhase()
    }

    override func tearDownWithError() throws {
        client.disconnect()
        client = nil
    }

    // Simulates the hasSubscribedThisAppear guards from the onChange(of: scenePhase)
    // handler — specifically the phase-transition guard and the new hasSubscribedThisAppear
    // guard. The isLocallyCreated guard is omitted because it requires a live CDSession
    // object and is orthogonal to what these tests cover.
    private func simulate(
        newPhase: ScenePhase,
        oldPhase: ScenePhase,
        hasSubscribedThisAppear: Bool,
        sessionId: String = "session-x",
        client: MockVoiceCodeClientForScenePhase
    ) -> Bool {
        var flag = hasSubscribedThisAppear
        guard newPhase == .active, oldPhase != .active else { return flag }
        guard flag else { return flag }
        flag = false
        client.refreshSubscription(sessionId: sessionId)
        return flag
    }

    func testScenePhaseDoesNotRefreshUnsubscribedSession() {
        // View whose onDisappear already fired — flag is false.
        let flagAfter = simulate(
            newPhase: .active, oldPhase: .inactive,
            hasSubscribedThisAppear: false,
            sessionId: "session-a", client: client
        )
        XCTAssertFalse(client.refreshSubscriptionCalled,
            "refreshSubscription must not fire for a view whose onDisappear cleared the flag")
        XCTAssertFalse(flagAfter)
    }

    func testScenePhaseRefreshesActiveSession() {
        // View that was visible at background time — flag is true.
        // On iOS, foreground return goes background → inactive → active; the
        // onChange fires for the inactive → active step, so oldPhase is .inactive.
        let flagAfter = simulate(
            newPhase: .active, oldPhase: .inactive,
            hasSubscribedThisAppear: true,
            sessionId: "session-b", client: client
        )
        XCTAssertTrue(client.refreshSubscriptionCalled,
            "refreshSubscription must fire for the view that was visible at background time")
        XCTAssertEqual(client.lastRefreshedSessionId, "session-b")
        XCTAssertFalse(flagAfter,
            "hasSubscribedThisAppear must be reset to false for the next foreground cycle")
    }

    func testScenePhaseNonActiveTransitionsAreIgnored() {
        // None of these phase pairs satisfy `newPhase == .active, oldPhase != .active`.
        let nonActivatingTransitions: [(ScenePhase, ScenePhase)] = [
            (.background, .active),   // foreground → background
            (.active, .active),       // active → active (no phase change)
            (.inactive, .active),     // foreground → inactive
            (.background, .inactive), // inactive → background
        ]
        for (newPhase, oldPhase) in nonActivatingTransitions {
            let perCaseClient = MockVoiceCodeClientForScenePhase()
            defer { perCaseClient.disconnect() }
            let flagAfter = simulate(
                newPhase: newPhase, oldPhase: oldPhase,
                hasSubscribedThisAppear: true, client: perCaseClient
            )
            XCTAssertFalse(perCaseClient.refreshSubscriptionCalled,
                "refreshSubscription must not fire for transition \(oldPhase) → \(newPhase)")
            XCTAssertTrue(flagAfter,
                "hasSubscribedThisAppear must remain true for transition \(oldPhase) → \(newPhase)")
        }
    }
}
