# Design: WebSocket Connectivity Resilience

This document details the design for high-priority connectivity improvements identified in @websocket-recommendations.md.

## Overview

### Problem Statement

The current WebSocket implementation lacks network awareness and proper lifecycle handling, leading to:

1. **Wasted battery and CPU**: Reconnection timer fires regardless of network availability
2. **Poor UX on network transitions**: WiFi↔Cellular handoffs cause connection failures instead of proactive reconnection
3. **Zombie connections**: No mechanism to detect half-open connections from the client side
4. **Resource leaks**: WebSocket left open when app backgrounds, dies when iOS suspends
5. **Lost in-flight work**: No background task to complete operations before suspension

### Goals

1. Implement network reachability monitoring using `NWPathMonitor`
2. Proactively handle WiFi↔Cellular transitions
3. Add server-initiated heartbeats for half-open connection detection
4. Clean disconnect on app background with background task for cleanup
5. Maintain backward compatibility with existing protocol

### Non-Goals

1. Offline message queueing (separate Medium Priority item)
2. Message acknowledgment system (separate Medium Priority item)
3. Full offline-first architecture
4. Push notification integration for background wake

## Background & Context

### Current State

**iOS Client (`VoiceCodeClient.swift`)**:
- Uses `URLSessionWebSocketTask` for WebSocket connection
- Implements exponential backoff reconnection (1s → 30s max, ±25% jitter)
- Sends client-initiated ping every 30 seconds
- Observes `willEnterForegroundNotification` to trigger reconnection
- `handleAppEnteredBackground()` only logs, does not disconnect

**Backend (`server.clj`)**:
- Responds to client `ping` with `pong`
- No server-initiated heartbeats
- Connection state tracked in `connected-clients` atom
- No awareness of client network state

### Why Now

The @websocket-recommendations.md review identified these as High Priority items with significant impact on:
- Battery life (reconnection attempts when network unavailable)
- User experience (delays after network transitions)
- Connection reliability (undetected zombie connections)

### Related Work

- @websocket-best-practices.md - Best practices reference
- @STANDARDS.md - WebSocket protocol specification
- Existing ping/pong implementation in `VoiceCodeClient.swift:439-466`

## Detailed Design

### Feature 1: Network Reachability Monitoring (Item 2)

#### Data Model

New state to add to `VoiceCodeClient` class (not extension - Swift extensions cannot have stored properties):

```swift
import Network

// Add to VoiceCodeClient class declaration:
class VoiceCodeClient: ObservableObject {
    // ... existing properties ...

    // Network monitoring state (Feature 1)
    private var pathMonitor: NWPathMonitor?
    private var currentNetworkPath: NWPath?
    private var isNetworkAvailable: Bool = true
    @Published var networkStatus: NetworkStatus = .unknown

    // Heartbeat monitoring state (Feature 3)
    private var lastHeartbeatReceived: Date?
    private var heartbeatTimeoutTimer: DispatchSourceTimer?
    private static let expectedHeartbeatInterval: TimeInterval = 45.0
    private static let heartbeatTimeout: TimeInterval = 90.0  // 2x interval

    #if os(iOS)
    // Background task state (Feature 4)
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    #endif
}

enum NetworkStatus {
    case unknown
    case available
    case unavailable
    case constrained  // e.g., Low Data Mode
}
```

#### Component Design

Methods can be organized in extensions for clarity, but all stored properties must be in the main class:

```swift
// MARK: - Network Monitoring (Feature 1)
extension VoiceCodeClient {

    /// Start monitoring network path changes
    private func startNetworkMonitoring() {
        let monitor = NWPathMonitor()

        monitor.pathUpdateHandler = { [weak self] path in
            self?.handleNetworkPathUpdate(path)
        }

        // Use dedicated queue to avoid main thread blocking
        let queue = DispatchQueue(label: "dev.910labs.voice-code.network-monitor")
        monitor.start(queue: queue)

        pathMonitor = monitor
    }

    /// Handle network path changes
    private func handleNetworkPathUpdate(_ path: NWPath) {
        let wasAvailable = isNetworkAvailable
        let previousPath = currentNetworkPath

        currentNetworkPath = path
        isNetworkAvailable = (path.status == .satisfied)

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            // Update published status
            self.networkStatus = self.mapPathToStatus(path)

            if !wasAvailable && self.isNetworkAvailable {
                // Network became available - immediate reconnection
                self.handleNetworkBecameAvailable()
            } else if wasAvailable && !self.isNetworkAvailable {
                // Network became unavailable - pause reconnection
                self.handleNetworkBecameUnavailable()
            } else if self.isNetworkAvailable && self.didInterfaceChange(from: previousPath, to: path) {
                // Interface changed (WiFi ↔ Cellular) - proactive reconnection
                self.handleNetworkInterfaceChange(from: previousPath, to: path)
            }
        }
    }

    private func mapPathToStatus(_ path: NWPath) -> NetworkStatus {
        switch path.status {
        case .satisfied:
            return path.isConstrained ? .constrained : .available
        case .unsatisfied:
            return .unavailable
        case .requiresConnection:
            return .unknown
        @unknown default:
            return .unknown
        }
    }

    private func didInterfaceChange(from oldPath: NWPath?, to newPath: NWPath) -> Bool {
        guard let oldPath = oldPath else { return false }

        let oldUsesWiFi = oldPath.usesInterfaceType(.wifi)
        let newUsesWiFi = newPath.usesInterfaceType(.wifi)
        let oldUsesCellular = oldPath.usesInterfaceType(.cellular)
        let newUsesCellular = newPath.usesInterfaceType(.cellular)

        return (oldUsesWiFi != newUsesWiFi) || (oldUsesCellular != newUsesCellular)
    }

    /// Network became available after being unavailable
    private func handleNetworkBecameAvailable() {
        logger.info("📶 [VoiceCodeClient] Network became available, attempting immediate reconnection")

        // Reset backoff for immediate attempt
        reconnectionAttempts = 0

        // Cancel any pending reconnection timer
        reconnectionTimer?.cancel()
        reconnectionTimer = nil

        // Attempt immediate reconnection if not already connected
        if !isConnected && !requiresReauthentication {
            connect(sessionId: sessionId)
        }
    }

    /// Network became unavailable
    private func handleNetworkBecameUnavailable() {
        logger.info("📶 [VoiceCodeClient] Network unavailable, pausing reconnection attempts")

        // Stop reconnection timer to save battery
        reconnectionTimer?.cancel()
        reconnectionTimer = nil

        // Note: Don't disconnect - let existing connection fail naturally
        // This handles transient network blips
    }

    /// Stop network monitoring
    private func stopNetworkMonitoring() {
        pathMonitor?.cancel()
        pathMonitor = nil
    }
}
```

#### Integration Points

**Start network monitoring in init():**

```swift
init(serverURL: String, voiceOutputManager: VoiceOutputManager? = nil,
     sessionSyncManager: SessionSyncManager? = nil, appSettings: AppSettings? = nil,
     setupObservers: Bool = true) {
    // ... existing init code ...

    if setupObservers {
        setupLifecycleObservers()
        startNetworkMonitoring()  // NEW: Start monitoring network changes
    }
}
```

**Modify `setupReconnection()` to check network availability:**

```swift
private func setupReconnection() {
    guard reconnectionAttempts < maxReconnectionAttempts else {
        // ... existing max attempts handling
        return
    }

    // NEW: Don't schedule reconnection if network unavailable
    guard isNetworkAvailable else {
        logger.info("📶 [VoiceCodeClient] Network unavailable, skipping reconnection scheduling")
        return
    }

    // ... existing backoff logic
}
```

### Feature 2: WiFi to Cellular Handoff (Item 29)

This builds on Feature 1's `NWPathMonitor` integration.

#### Component Design

```swift
extension VoiceCodeClient {

    /// Handle network interface change (WiFi ↔ Cellular)
    private func handleNetworkInterfaceChange(from oldPath: NWPath?, to newPath: NWPath) {
        let fromInterface = describeInterface(oldPath)
        let toInterface = describeInterface(newPath)

        logger.info("📶 [VoiceCodeClient] Network interface changed: \(fromInterface) → \(toInterface)")

        // Proactive reconnection on interface change
        // Don't wait for connection to fail - disconnect and reconnect immediately

        if isConnected {
            // Disconnect cleanly
            disconnect()

            // Immediate reconnection attempt
            reconnectionAttempts = 0
            connect(sessionId: sessionId)
        }
    }

    private func describeInterface(_ path: NWPath?) -> String {
        guard let path = path else { return "none" }

        if path.usesInterfaceType(.wifi) { return "WiFi" }
        if path.usesInterfaceType(.cellular) { return "Cellular" }
        if path.usesInterfaceType(.wiredEthernet) { return "Ethernet" }
        return "other"
    }
}
```

### Feature 3: Server Heartbeat for Half-Open Detection (Item 24)

#### Protocol Extension

Add new message type to WebSocket protocol:

**Backend → Client: Server Heartbeat**
```json
{
  "type": "heartbeat",
  "timestamp": "<ISO-8601-timestamp>"
}
```

No client acknowledgment required - this is for connection liveness detection.

#### Backend Implementation

```clojure
(ns voice-code.server
  ;; ... existing requires
  )

;; Heartbeat configuration
(def heartbeat-interval-ms 45000)  ;; 45 seconds (longer than client ping)

(defonce heartbeat-executor (atom nil))

(defn send-heartbeat!
  "Send heartbeat to a specific client channel."
  [channel]
  (when (contains? @connected-clients channel)
    (try
      (http/send! channel
                  (generate-json {:type :heartbeat
                                  :timestamp (java.time.Instant/now)}))
      (catch Exception e
        (log/warn e "Failed to send heartbeat, removing stale channel")
        (unregister-channel! channel)))))

(defn broadcast-heartbeat!
  "Send heartbeat to all connected clients."
  []
  (doseq [channel (keys @connected-clients)]
    (send-heartbeat! channel)))

(defn start-heartbeat-scheduler!
  "Start the heartbeat scheduler."
  []
  (let [executor (java.util.concurrent.Executors/newSingleThreadScheduledExecutor)
        ;; Wrap Clojure fn in Runnable for Java interop
        heartbeat-task (reify Runnable
                         (run [_] (broadcast-heartbeat!)))]
    (reset! heartbeat-executor executor)
    (.scheduleAtFixedRate executor
                          heartbeat-task
                          heartbeat-interval-ms
                          heartbeat-interval-ms
                          java.util.concurrent.TimeUnit/MILLISECONDS)
    (log/info "Heartbeat scheduler started" {:interval-ms heartbeat-interval-ms})))

(defn stop-heartbeat-scheduler!
  "Stop the heartbeat scheduler."
  []
  (when-let [executor @heartbeat-executor]
    (.shutdown executor)
    (reset! heartbeat-executor nil)
    (log/info "Heartbeat scheduler stopped")))
```

Update `-main` to start/stop heartbeat scheduler:

```clojure
(defn -main [& args]
  ;; ... existing startup code
  (start-heartbeat-scheduler!)

  ;; Add shutdown hook
  (.addShutdownHook (Runtime/getRuntime)
                    (Thread. #(do
                                (stop-heartbeat-scheduler!)
                                ;; ... other cleanup
                                ))))
```

#### iOS Client Implementation

Note: Stored properties are declared in the Data Model section above. Methods are shown here:

```swift
// MARK: - Heartbeat Monitoring (Feature 3)
extension VoiceCodeClient {

    /// Start monitoring for server heartbeats
    /// Call this after receiving "connected" message in handleMessage()
    private func startHeartbeatMonitoring() {
        // Cancel existing timer
        heartbeatTimeoutTimer?.cancel()

        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
        timer.schedule(deadline: .now() + Self.heartbeatTimeout,
                       repeating: Self.heartbeatTimeout)

        timer.setEventHandler { [weak self] in
            self?.checkHeartbeatTimeout()
        }

        timer.resume()
        heartbeatTimeoutTimer = timer
        lastHeartbeatReceived = Date()

        logger.info("💓 [VoiceCodeClient] Heartbeat monitoring started")
    }

    /// Stop heartbeat monitoring
    private func stopHeartbeatMonitoring() {
        heartbeatTimeoutTimer?.cancel()
        heartbeatTimeoutTimer = nil
        lastHeartbeatReceived = nil
    }

    /// Check if heartbeat has timed out
    private func checkHeartbeatTimeout() {
        guard isConnected, isAuthenticated else { return }

        guard let lastHeartbeat = lastHeartbeatReceived else {
            // No heartbeat ever received - server may not support it yet
            return
        }

        let timeSinceLastHeartbeat = Date().timeIntervalSince(lastHeartbeat)

        if timeSinceLastHeartbeat > Self.heartbeatTimeout {
            logger.warning("💓 [VoiceCodeClient] Heartbeat timeout (\(timeSinceLastHeartbeat)s), connection may be dead")

            // Trigger reconnection
            handleZombieConnection()
        }
    }

    /// Handle detected zombie connection
    private func handleZombieConnection() {
        logger.info("🧟 [VoiceCodeClient] Zombie connection detected, forcing reconnection")

        // Force disconnect and reconnect
        disconnect()
        reconnectionAttempts = 0

        if isNetworkAvailable && !requiresReauthentication {
            connect(sessionId: sessionId)
        }
    }

    /// Handle received heartbeat message
    private func handleHeartbeat(_ json: [String: Any]) {
        lastHeartbeatReceived = Date()
        logger.debug("💓 [VoiceCodeClient] Heartbeat received")
    }
}
```

#### Integration with handleMessage()

Update `handleMessage()` to start heartbeat monitoring after authentication and process heartbeat messages:

```swift
// In handleMessage(), after receiving "connected" message:
case "connected":
    logger.info("✅ [VoiceCodeClient] Connected and authenticated")
    isAuthenticated = true
    startPingTimer()
    startHeartbeatMonitoring()  // NEW: Start monitoring for server heartbeats
    // ... existing connected handling ...

// Add new case for heartbeat messages:
case "heartbeat":
    handleHeartbeat(json)
```

Also update `disconnect()` to stop heartbeat monitoring:

```swift
func disconnect() {
    // ... existing code ...
    stopPingTimer()
    stopHeartbeatMonitoring()  // NEW: Stop heartbeat monitoring
    stopNetworkMonitoring()    // NEW: Stop network monitoring
    // ... rest of disconnect ...
}
```

### Feature 4: App Lifecycle - Clean Disconnect (Items 9 & 28)

#### Component Design

Note: Stored property `backgroundTaskID` is declared in the Data Model section above. Methods are shown here:

```swift
// MARK: - Background Lifecycle (Feature 4)
extension VoiceCodeClient {

    /// Handle app entering background with proper cleanup
    /// Replace existing empty implementation in setupLifecycleObservers()
    private func handleAppEnteredBackground() {
        logger.info("📱 [VoiceCodeClient] App entering background")

        #if os(iOS)
        // Request background time to complete cleanup
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(
            withName: "VoiceCodeCleanup"
        ) { [weak self] in
            // Expiration handler - system is forcing us to stop
            self?.completeBackgroundTask()
        }

        // Perform cleanup
        performBackgroundCleanup()
        #else
        // macOS: Just disconnect cleanly
        disconnect()
        #endif
    }

    #if os(iOS)
    /// Perform cleanup operations before suspension
    private func performBackgroundCleanup() {
        // Check if there are in-flight operations
        let hasLockedSessions = !lockedSessions.isEmpty
        let hasRunningCommands = !runningCommands.isEmpty

        if hasLockedSessions || hasRunningCommands {
            logger.info("📱 [VoiceCodeClient] In-flight operations detected, waiting...")

            // Wait for operations to complete (with timeout)
            waitForInFlightOperations { [weak self] in
                self?.finalizeBackgroundCleanup()
            }
        } else {
            // No in-flight operations, disconnect immediately
            finalizeBackgroundCleanup()
        }
    }

    /// Wait for in-flight operations with timeout
    private func waitForInFlightOperations(completion: @escaping () -> Void) {
        let timeout: TimeInterval = 25.0  // iOS gives ~30s, leave margin
        let startTime = Date()

        // Poll for completion
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
        timer.schedule(deadline: .now(), repeating: 1.0)

        timer.setEventHandler { [weak self] in
            guard let self = self else {
                timer.cancel()
                return
            }

            let elapsed = Date().timeIntervalSince(startTime)
            let stillBusy = !self.lockedSessions.isEmpty || !self.runningCommands.isEmpty

            if !stillBusy || elapsed >= timeout {
                timer.cancel()

                if stillBusy {
                    logger.warning("📱 [VoiceCodeClient] Timeout waiting for operations, disconnecting anyway")
                } else {
                    logger.info("📱 [VoiceCodeClient] All operations completed")
                }

                completion()
            }
        }

        timer.resume()
    }

    /// Final cleanup and disconnect
    private func finalizeBackgroundCleanup() {
        // Send any pending acks (if we had a message ack queue)
        // flushPendingAcks()

        // Disconnect cleanly
        disconnect()

        // End background task
        completeBackgroundTask()
    }

    /// Complete the background task
    private func completeBackgroundTask() {
        if backgroundTaskID != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTaskID)
            backgroundTaskID = .invalid
            logger.info("📱 [VoiceCodeClient] Background task completed")
        }
    }
    #endif
}
```

#### Reconnection on Foreground

The existing `handleAppBecameActive()` already handles foreground reconnection. Ensure it integrates with network monitoring:

```swift
private func handleAppBecameActive() {
    // Don't reconnect if reauthentication is required
    if requiresReauthentication {
        logger.info("📱 [VoiceCodeClient] App became active, skipping - reauthentication required")
        return
    }

    // Don't reconnect if network unavailable
    guard isNetworkAvailable else {
        logger.info("📱 [VoiceCodeClient] App became active, skipping - network unavailable")
        return
    }

    if !isConnected {
        logger.info("📱 [VoiceCodeClient] App became active, attempting reconnection...")
        reconnectionAttempts = 0
        connect(sessionId: sessionId)
    }
}
```

## Verification Strategy

### Testing Approach

#### Test Infrastructure Required

**MockNWPath**: Since `NWPath` is a final class that cannot be subclassed or directly mocked, we need a protocol-based abstraction:

```swift
// NetworkPathProtocol.swift - Add to test target
protocol NetworkPathProtocol {
    var status: NWPath.Status { get }
    var isConstrained: Bool { get }
    func usesInterfaceType(_ type: NWInterface.InterfaceType) -> Bool
}

// Extend NWPath to conform
extension NWPath: NetworkPathProtocol {}

// Mock for testing
class MockNWPath: NetworkPathProtocol {
    var status: NWPath.Status
    var isConstrained: Bool
    private var usesWiFi: Bool
    private var usesCellular: Bool

    init(status: NWPath.Status = .satisfied, isConstrained: Bool = false,
         usesWiFi: Bool = false, usesCellular: Bool = false) {
        self.status = status
        self.isConstrained = isConstrained
        self.usesWiFi = usesWiFi
        self.usesCellular = usesCellular
    }

    func usesInterfaceType(_ type: NWInterface.InterfaceType) -> Bool {
        switch type {
        case .wifi: return usesWiFi
        case .cellular: return usesCellular
        default: return false
        }
    }
}
```

**Test Helpers**: Add internal test accessors to `VoiceCodeClient` (conditionally compiled for testing):

```swift
// Add to VoiceCodeClient.swift
#if DEBUG
extension VoiceCodeClient {
    // Test accessors for internal state
    var testableReconnectionTimer: DispatchSourceTimer? { reconnectionTimer }
    var testableReconnectionAttempts: Int { reconnectionAttempts }
    var testableLastHeartbeatReceived: Date? { lastHeartbeatReceived }

    // Test mutators for setting up test scenarios
    func testableSetNetworkAvailable(_ available: Bool) { isNetworkAvailable = available }
    func testableSetConnected(_ connected: Bool) { isConnected = connected }
    func testableSetAuthenticated(_ authenticated: Bool) { isAuthenticated = authenticated }
    func testableSetReconnectionAttempts(_ attempts: Int) { reconnectionAttempts = attempts }
    func testableSetLastHeartbeat(_ date: Date?) { lastHeartbeatReceived = date }

    // Test triggers for internal methods
    func testableSetupReconnection() { setupReconnection() }
    func testableHandleNetworkBecameAvailable() { handleNetworkBecameAvailable() }
    func testableHandleAppBecameActive() { handleAppBecameActive() }
    func testableHandleAppEnteredBackground() { handleAppEnteredBackground() }
    func testableCheckHeartbeatTimeout() { checkHeartbeatTimeout() }

    // Protocol-based method for testing (accepts mock)
    func testableMapPathToStatus(_ path: NetworkPathProtocol) -> NetworkStatus {
        switch path.status {
        case .satisfied: return path.isConstrained ? .constrained : .available
        case .unsatisfied: return .unavailable
        case .requiresConnection: return .unknown
        @unknown default: return .unknown
        }
    }

    func testableDidInterfaceChange(from oldPath: NetworkPathProtocol?, to newPath: NetworkPathProtocol) -> Bool {
        guard let oldPath = oldPath else { return false }
        let oldUsesWiFi = oldPath.usesInterfaceType(.wifi)
        let newUsesWiFi = newPath.usesInterfaceType(.wifi)
        let oldUsesCellular = oldPath.usesInterfaceType(.cellular)
        let newUsesCellular = newPath.usesInterfaceType(.cellular)
        return (oldUsesWiFi != newUsesWiFi) || (oldUsesCellular != newUsesCellular)
    }
}
#endif
```

#### Unit Tests

**Network Reachability Tests** (`VoiceCodeClientNetworkTests.swift`):

```swift
import XCTest
import Network
@testable import VoiceCode

class VoiceCodeClientNetworkTests: XCTestCase {

    var client: VoiceCodeClient!

    override func setUp() {
        super.setUp()
        client = VoiceCodeClient(serverURL: "ws://test", setupObservers: false)
    }

    // MARK: - Network Status Mapping

    func testMapPathToStatus_Satisfied_ReturnsAvailable() {
        // Given: A mock path with satisfied status
        let mockPath = MockNWPath(status: .satisfied, isConstrained: false)

        // When: Mapping to status
        let status = client.testableMapPathToStatus(mockPath)

        // Then: Returns available
        XCTAssertEqual(status, .available)
    }

    func testMapPathToStatus_SatisfiedConstrained_ReturnsConstrained() {
        let mockPath = MockNWPath(status: .satisfied, isConstrained: true)
        let status = client.testableMapPathToStatus(mockPath)
        XCTAssertEqual(status, .constrained)
    }

    func testMapPathToStatus_Unsatisfied_ReturnsUnavailable() {
        let mockPath = MockNWPath(status: .unsatisfied, isConstrained: false)
        let status = client.testableMapPathToStatus(mockPath)
        XCTAssertEqual(status, .unavailable)
    }

    // MARK: - Interface Change Detection

    func testDidInterfaceChange_WiFiToCellular_ReturnsTrue() {
        let oldPath = MockNWPath(usesWiFi: true, usesCellular: false)
        let newPath = MockNWPath(usesWiFi: false, usesCellular: true)

        XCTAssertTrue(client.testableDidInterfaceChange(from: oldPath, to: newPath))
    }

    func testDidInterfaceChange_SameInterface_ReturnsFalse() {
        let oldPath = MockNWPath(usesWiFi: true, usesCellular: false)
        let newPath = MockNWPath(usesWiFi: true, usesCellular: false)

        XCTAssertFalse(client.testableDidInterfaceChange(from: oldPath, to: newPath))
    }

    func testDidInterfaceChange_NilOldPath_ReturnsFalse() {
        let newPath = MockNWPath(usesWiFi: true, usesCellular: false)

        XCTAssertFalse(client.testableDidInterfaceChange(from: nil, to: newPath))
    }

    // MARK: - Reconnection Behavior

    func testSetupReconnection_NetworkUnavailable_DoesNotSchedule() {
        // Given: Network is unavailable
        client.testableSetNetworkAvailable(false)

        // When: Setup reconnection is called
        client.testableSetupReconnection()

        // Then: No timer is scheduled
        XCTAssertNil(client.testableReconnectionTimer)
    }

    func testNetworkBecameAvailable_ResetsBackoffAndConnects() {
        // Given: Client was disconnected with backoff
        client.testableSetReconnectionAttempts(5)
        client.testableSetConnected(false)

        // When: Network becomes available
        client.testableHandleNetworkBecameAvailable()

        // Then: Backoff is reset
        XCTAssertEqual(client.testableReconnectionAttempts, 0)
    }
}
```

**Heartbeat Tests** (`VoiceCodeClientHeartbeatTests.swift`):

```swift
class VoiceCodeClientHeartbeatTests: XCTestCase {

    func testHeartbeatReceived_UpdatesLastHeartbeatTime() {
        let client = VoiceCodeClient(serverURL: "ws://test", setupObservers: false)
        let beforeTime = Date()

        client.handleMessage("""
        {"type": "heartbeat", "timestamp": "2025-01-11T12:00:00Z"}
        """)

        let lastHeartbeat = client.testableLastHeartbeatReceived
        XCTAssertNotNil(lastHeartbeat)
        XCTAssertGreaterThanOrEqual(lastHeartbeat!, beforeTime)
    }

    func testHeartbeatTimeout_TriggersReconnection() {
        let client = VoiceCodeClient(serverURL: "ws://test", setupObservers: false)
        client.testableSetConnected(true)
        client.testableSetAuthenticated(true)

        // Set last heartbeat to 100 seconds ago (> 90s timeout)
        client.testableSetLastHeartbeat(Date().addingTimeInterval(-100))

        // Trigger timeout check
        client.testableCheckHeartbeatTimeout()

        // Should have triggered disconnect
        XCTAssertFalse(client.isConnected)
    }
}
```

**Background Lifecycle Tests** (`VoiceCodeClientLifecycleTests.swift`):

```swift
class VoiceCodeClientLifecycleTests: XCTestCase {

    func testAppEnteredBackground_DisconnectsCleanly() {
        let client = VoiceCodeClient(serverURL: "ws://test", setupObservers: false)
        client.testableSetConnected(true)

        // Simulate background
        client.testableHandleAppEnteredBackground()

        // Wait for cleanup
        let expectation = XCTestExpectation(description: "Disconnect completed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            XCTAssertFalse(client.isConnected)
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 5.0)
    }

    func testAppBecameActive_NetworkUnavailable_DoesNotReconnect() {
        let client = VoiceCodeClient(serverURL: "ws://test", setupObservers: false)
        client.testableSetNetworkAvailable(false)
        client.testableSetConnected(false)

        client.testableHandleAppBecameActive()

        // Should not have attempted connection
        XCTAssertFalse(client.isConnected)
    }
}
```

#### Backend Tests

```clojure
(ns voice-code.server-test
  (:require [clojure.test :refer :all]
            [voice-code.server :as server]))

(deftest test-send-heartbeat
  (testing "send-heartbeat! sends to connected client"
    (let [sent-messages (atom [])
          mock-channel (reify Object)]
      ;; Setup mock channel
      (swap! server/connected-clients assoc mock-channel {:authenticated true})

      (with-redefs [org.httpkit.server/send!
                    (fn [ch msg] (swap! sent-messages conj {:channel ch :msg msg}))]
        (server/send-heartbeat! mock-channel)

        (is (= 1 (count @sent-messages)))
        (let [msg (-> @sent-messages first :msg server/parse-json)]
          (is (= "heartbeat" (:type msg)))
          (is (some? (:timestamp msg))))))))

(deftest test-broadcast-heartbeat
  (testing "broadcast-heartbeat! sends to all clients"
    (let [sent-count (atom 0)]
      ;; Setup multiple mock channels
      (reset! server/connected-clients
              {(Object.) {:authenticated true}
               (Object.) {:authenticated true}
               (Object.) {:authenticated true}})

      (with-redefs [org.httpkit.server/send!
                    (fn [_ _] (swap! sent-count inc))]
        (server/broadcast-heartbeat!)

        (is (= 3 @sent-count))))))
```

### Acceptance Criteria

1. **Network Reachability**
   - [ ] `NWPathMonitor` starts on client initialization
   - [ ] Reconnection timer pauses when network becomes unavailable
   - [ ] Immediate reconnection attempt when network becomes available
   - [ ] Backoff resets to 0 when network becomes available
   - [ ] `networkStatus` published property updates on changes

2. **WiFi/Cellular Handoff**
   - [ ] Interface change from WiFi to Cellular triggers proactive reconnection
   - [ ] Interface change from Cellular to WiFi triggers proactive reconnection
   - [ ] Connection is closed cleanly before reconnection
   - [ ] No reconnection if interface type doesn't change

3. **Server Heartbeat**
   - [ ] Backend sends heartbeat every 45 seconds to all connected clients
   - [ ] iOS client tracks last heartbeat received time
   - [ ] Heartbeat timeout (90s) triggers zombie connection handling
   - [ ] Zombie connection triggers disconnect and reconnection
   - [ ] Heartbeat monitoring starts after authentication
   - [ ] Heartbeat monitoring stops on disconnect

4. **Background Lifecycle**
   - [ ] App entering background requests `beginBackgroundTask`
   - [ ] In-flight operations are given time to complete (up to 25s)
   - [ ] WebSocket disconnects cleanly before suspension
   - [ ] Background task ends properly (no leaks)
   - [ ] App returning to foreground triggers reconnection (if network available)

5. **Backward Compatibility**
   - [ ] Existing ping/pong mechanism continues to work
   - [ ] Clients without heartbeat support don't crash on heartbeat message
   - [ ] Protocol version doesn't change

## Alternatives Considered

### Alternative 1: Reachability via SCNetworkReachability

**Approach**: Use the older `SCNetworkReachability` API instead of `NWPathMonitor`.

**Why rejected**:
- `NWPathMonitor` is the modern replacement, recommended by Apple
- `SCNetworkReachability` requires more boilerplate
- `NWPathMonitor` provides better interface type detection
- `SCNetworkReachability` is deprecated for new development

### Alternative 2: Client-only RTT-based detection

**Approach**: Measure round-trip time of existing ping/pong and detect degradation.

**Why rejected**:
- Doesn't detect half-open connections where only server→client path is broken
- Server heartbeat is simple to implement and more reliable
- RTT tracking is still valuable but as a Medium Priority enhancement

### Alternative 3: Keep connection open in background

**Approach**: Don't disconnect when app enters background, rely on iOS to suspend.

**Why rejected**:
- Wastes server resources on connections to suspended clients
- WebSocket in undefined state when iOS suspends mid-operation
- Server can't distinguish disconnected vs suspended clients
- Clean disconnect provides better resource management

## Risks & Mitigations

### Risk 1: NWPathMonitor false positives

**Risk**: Network path changes fire too frequently, causing excessive reconnections.

**Mitigation**:
- Only trigger reconnection on actual interface type changes (WiFi↔Cellular)
- Debounce rapid path updates (not currently implemented, monitor in production)
- Log all network events for debugging

### Risk 2: Background task expiration during critical operation

**Risk**: iOS terminates app before Claude prompt completes.

**Mitigation**:
- 25 second timeout (5s margin before iOS's ~30s limit)
- Clear logging when timeout occurs
- Session lock remains in place; next connection will find session locked
- Future: Consider push notification for completion

### Risk 3: Heartbeat storms under high client count

**Risk**: Many connected clients cause backend CPU spike every 45 seconds.

**Mitigation**:
- 45 second interval is conservative (longer than client ping)
- Current deployment is single-user, not a concern
- Future: Stagger heartbeats or use client-specific intervals

### Risk 4: Backward compatibility with old clients

**Risk**: Old iOS clients crash or misbehave on heartbeat message.

**Mitigation**:
- Heartbeat is a new message type, unknown types are logged and ignored
- Existing `handleMessage()` has default case for unknown types
- No breaking protocol changes

## Implementation Notes

### Suggested Order

1. **Phase 1A**: Network Reachability (Item 2)
   - Add `NWPathMonitor` integration
   - Modify `setupReconnection()` to check network
   - Add `handleNetworkBecameAvailable/Unavailable`

2. **Phase 1B**: WiFi/Cellular Handoff (Item 29)
   - Add interface change detection
   - Implement proactive reconnection on interface change

3. **Phase 1C**: Background Lifecycle (Items 9, 28)
   - Implement `beginBackgroundTask` wrapper
   - Add `performBackgroundCleanup()` with timeout
   - Ensure clean disconnect on background

4. **Phase 2**: Server Heartbeat (Item 24)
   - Add backend heartbeat scheduler
   - Add iOS heartbeat monitoring
   - Add zombie connection detection

### Dependencies

- Items 29, 9, 28 all depend on Item 2 (NWPathMonitor) being implemented first
- Item 24 can be implemented independently on the backend
- iOS heartbeat monitoring should wait until backend is deployed

### Testing Strategy

1. Unit tests for all new methods (mocking NWPath, timers)
2. Integration test with actual network transitions (manual)
3. Backend integration test for heartbeat broadcast
4. End-to-end test: background app, verify clean disconnect via server logs
