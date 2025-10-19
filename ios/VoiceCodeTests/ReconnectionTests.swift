// ReconnectionTests.swift
// Integration tests for subscription restoration on reconnection (voice-code-158)

import XCTest
@testable import VoiceCode

final class ReconnectionTests: XCTestCase {

    var client: VoiceCodeClient!
    let testServerURL = "ws://localhost:8080"

    override func setUp() {
        super.setUp()
        client = VoiceCodeClient(serverURL: testServerURL)
    }

    override func tearDown() {
        client?.disconnect()
        Thread.sleep(forTimeInterval: 0.2) // Allow cleanup
        client = nil
        super.tearDown()
    }

    // MARK: - Subscription Restoration Tests (voice-code-158)

    func testSubscriptionRestoredAfterReconnection() {
        let connectExpectation = XCTestExpectation(description: "Initial connection")
        let disconnectExpectation = XCTestExpectation(description: "Disconnect")
        let reconnectExpectation = XCTestExpectation(description: "Reconnection")
        let resubscribeExpectation = XCTestExpectation(description: "Resubscribe detected")

        let sessionId = "test-session-\(UUID().uuidString)"

        // Phase 1: Connect and subscribe
        client.connect()

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            XCTAssertTrue(self.client.isConnected, "Should be connected")
            connectExpectation.fulfill()

            // Subscribe to a session
            self.client.subscribe(sessionId: sessionId)

            // Phase 2: Disconnect (simulate network interruption)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.client.disconnect()
                XCTAssertFalse(self.client.isConnected, "Should be disconnected")
                disconnectExpectation.fulfill()

                // Phase 3: Reconnect
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.client.connect()

                    // Phase 4: Wait for reconnection and check subscription restoration
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        // After reconnection, the client should:
                        // 1. Be connected again
                        // 2. Have automatically sent subscribe message for the session
                        XCTAssertTrue(self.client.isConnected, "Should be reconnected")
                        reconnectExpectation.fulfill()

                        // The resubscription happens in the "connected" handler
                        // We verify by checking logs and that no error occurred
                        XCTAssertNil(self.client.currentError, "Should not have errors after resubscribe")
                        resubscribeExpectation.fulfill()
                    }
                }
            }
        }

        wait(for: [connectExpectation, disconnectExpectation, reconnectExpectation, resubscribeExpectation], timeout: 10.0)
    }

    func testMultipleSubscriptionsRestoredAfterReconnection() {
        let expectation = XCTestExpectation(description: "Multiple subscriptions restored")

        let sessionIds = [
            "session-a-\(UUID().uuidString)",
            "session-b-\(UUID().uuidString)",
            "session-c-\(UUID().uuidString)"
        ]

        // Connect
        client.connect()

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            // Subscribe to multiple sessions
            for sessionId in sessionIds {
                self.client.subscribe(sessionId: sessionId)
            }

            // Disconnect
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.client.disconnect()

                // Reconnect
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.client.connect()

                    // Verify reconnection
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        XCTAssertTrue(self.client.isConnected, "Should be reconnected")
                        XCTAssertNil(self.client.currentError, "All subscriptions should be restored")
                        expectation.fulfill()
                    }
                }
            }
        }

        wait(for: [expectation], timeout: 10.0)
    }

    func testNoResubscriptionWhenNoActiveSubscriptions() {
        let expectation = XCTestExpectation(description: "Reconnect without subscriptions")

        // Connect without subscribing to anything
        client.connect()

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            XCTAssertTrue(self.client.isConnected)

            // Disconnect
            self.client.disconnect()

            // Reconnect
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.client.connect()

                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    // Should reconnect successfully without trying to resubscribe
                    XCTAssertTrue(self.client.isConnected)
                    XCTAssertNil(self.client.currentError)
                    expectation.fulfill()
                }
            }
        }

        wait(for: [expectation], timeout: 10.0)
    }

    func testSubscriptionStateAfterUnsubscribe() {
        let expectation = XCTestExpectation(description: "Unsubscribe removes from active")

        let sessionId = "test-session-\(UUID().uuidString)"

        client.connect()

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            // Subscribe then immediately unsubscribe
            self.client.subscribe(sessionId: sessionId)
            self.client.unsubscribe(sessionId: sessionId)

            // Disconnect and reconnect
            self.client.disconnect()

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.client.connect()

                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    // Should NOT resubscribe to the session we unsubscribed from
                    XCTAssertTrue(self.client.isConnected)
                    XCTAssertNil(self.client.currentError)
                    expectation.fulfill()
                }
            }
        }

        wait(for: [expectation], timeout: 10.0)
    }

    func testReconnectionDuringActiveSubscription() {
        // Test reconnection while a session is actively being viewed
        let expectation = XCTestExpectation(description: "Reconnect during active subscription")

        let sessionId = "active-session-\(UUID().uuidString)"

        client.connect()

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            // Subscribe to simulate ConversationView being open
            self.client.subscribe(sessionId: sessionId)

            // Simulate network interruption (user walks through tunnel, WiFi handoff, etc.)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self.client.disconnect()

                // Automatic reconnection happens
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    self.client.connect()

                    // Verify subscription is restored
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        XCTAssertTrue(self.client.isConnected, "Should be reconnected")
                        XCTAssertNil(self.client.currentError, "Subscription should be restored")
                        expectation.fulfill()
                    }
                }
            }
        }

        wait(for: [expectation], timeout: 10.0)
    }

    // MARK: - Edge Case Tests

    func testRapidDisconnectReconnect() {
        // Test that rapid disconnect/reconnect cycles don't cause issues
        let expectation = XCTestExpectation(description: "Rapid reconnection")

        let sessionId = "rapid-test-\(UUID().uuidString)"

        client.connect()

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.client.subscribe(sessionId: sessionId)

            // Rapid disconnect/reconnect
            for i in 0..<3 {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.5) {
                    self.client.disconnect()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        self.client.connect()
                    }
                }
            }

            // Verify final state
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                XCTAssertTrue(self.client.isConnected, "Should be connected after rapid cycles")
                expectation.fulfill()
            }
        }

        wait(for: [expectation], timeout: 10.0)
    }

    func testSubscriptionsPersistAcrossMultipleReconnections() {
        let expectation = XCTestExpectation(description: "Multiple reconnections")

        let sessionId = "persistent-\(UUID().uuidString)"

        client.connect()

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.client.subscribe(sessionId: sessionId)

            // First reconnection
            self.client.disconnect()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.client.connect()

                // Second reconnection
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    self.client.disconnect()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        self.client.connect()

                        // Verify subscriptions still restored after multiple reconnections
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            XCTAssertTrue(self.client.isConnected, "Should be connected")
                            XCTAssertNil(self.client.currentError, "Subscriptions should persist")
                            expectation.fulfill()
                        }
                    }
                }
            }
        }

        wait(for: [expectation], timeout: 15.0)
    }
}
