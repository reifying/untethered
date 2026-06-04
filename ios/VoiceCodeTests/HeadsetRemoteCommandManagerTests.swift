// HeadsetRemoteCommandManagerTests.swift
// Unit tests for HeadsetRemoteCommandManager state machine and auto-send logic.
// Included in both VoiceCodeTests (iOS) and VoiceCodeMacTests targets.
// PTT-specific tests are guarded by #if os(macOS) because PTT monitoring is macOS-only.

import XCTest
@testable import VoiceCode
#if os(macOS)
import CoreBluetooth
#endif

// MARK: - Mock Dependencies

#if os(macOS)
/// Minimal `BLECentral` so a real `BlueParrottBLEManager` can be driven through
/// the HeadsetRemoteCommandManager delegate path without standing up a real
/// `CBCentralManager`. The manager wires `centralDelegate = self` in its init, so
/// tests drive events via `central.centralDelegate?`.
private final class FakeBLECentralForHRCM: BLECentral {
    var managerState: CBManagerState = .poweredOn
    weak var centralDelegate: BLECentralEvents?
    var connectedPeripheralIdentifier: UUID?
    func scanForButtonService() {}
    func stopScan() {}
    func resolveKnownPeripheral(_ id: UUID) {}
    func connectAdvertised() {}
    func connectKnown() {}
    func reconnectHeld() {}
    func cancelConnection() {}
    func subscribeToButtonEvents() {}
    func writeAppModeEnable(_ payload: Data) {}
}

/// Records `BlueParrottButtonDelegate` calls in order, for arbitrator unit tests.
private final class ButtonDelegateSpy: BlueParrottButtonDelegate {
    private(set) var calls: [String] = []
    func blueParrottButtonDown() { calls.append("down") }
    func blueParrottButtonUp() { calls.append("up") }
    func blueParrottTap() { calls.append("tap") }
    func blueParrottDoubleTap() { calls.append("doubleTap") }
    func blueParrottLongPress() { calls.append("longPress") }
}
#endif

class MockVoiceInputForHeadset: VoiceInputManager {
    var startRecordingCalled = false
    var stopRecordingCalled = false

    override func startRecording(onSessionReady: (() -> Void)? = nil) {
        startRecordingCalled = true
        onSessionReady?()
        DispatchQueue.main.async { self.isRecording = true }
    }

    override func stopRecording() {
        stopRecordingCalled = true
        DispatchQueue.main.async { self.isRecording = false }
    }
}

class MockVoiceOutputForHeadset: VoiceOutputManager {
    var stopCalled = false

    override func stop() {
        stopCalled = true
        DispatchQueue.main.async { self.isSpeaking = false }
    }
}

class MockVoiceCodeClientForHeadset: VoiceCodeClient {
    var lastSentMessage: [String: Any]?

    override func sendMessage(_ message: [String: Any]) {
        lastSentMessage = message
    }
}

struct HeadsetMockDependencies {
    let voiceInput = MockVoiceInputForHeadset()
    let voiceOutput: MockVoiceOutputForHeadset
    let client: MockVoiceCodeClientForHeadset
    let settings = AppSettings()

    init() {
        let output = MockVoiceOutputForHeadset()
        self.voiceOutput = output
        // Use an in-memory store so createOptimisticMessage doesn't touch the
        // real on-disk SQLite database during test runs.
        let syncManager = SessionSyncManager(
            persistenceController: PersistenceController(inMemory: true),
            voiceOutputManager: output
        )
        self.client = MockVoiceCodeClientForHeadset(
            serverURL: "ws://localhost:8080",
            voiceOutputManager: output,
            sessionSyncManager: syncManager,
            appSettings: settings,
            setupObservers: false
        )
        client.isConnected = true
    }
}

// MARK: - Tests

final class HeadsetRemoteCommandManagerTests: XCTestCase {

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "headsetModeEnabled")
        UserDefaults.standard.removeObject(forKey: "headsetAutoSend")
        UserDefaults.standard.removeObject(forKey: "blueParrottEnabled")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "headsetModeEnabled")
        UserDefaults.standard.removeObject(forKey: "headsetAutoSend")
        UserDefaults.standard.removeObject(forKey: "blueParrottEnabled")
        super.tearDown()
    }

    // MARK: - State Machine: Toggle Play/Pause

    func testTogglePlayPause_fromReady_startsRecording() {
        let (manager, mocks) = makeManager()
        manager.activate()
        XCTAssertEqual(manager.state, .ready)

        manager.simulateTogglePlayPause()

        XCTAssertEqual(manager.state, .recording)
        XCTAssertTrue(mocks.voiceInput.startRecordingCalled)
    }

    func testTogglePlayPause_fromReady_setsIsRecordingOnInjectedInstance() {
        // Verify that the @Published isRecording property is set on the same
        // VoiceInputManager instance the manager received — the shared-instance
        // contract that lets the UI observe headset-triggered recording state.
        let (manager, mocks) = makeManager()
        manager.activate()

        manager.simulateTogglePlayPause()

        let expectation = expectation(description: "isRecording set on injected instance")
        DispatchQueue.main.async {
            XCTAssertTrue(mocks.voiceInput.isRecording)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
    }

    func testTogglePlayPause_fromRecording_stopsAndSends() {
        let (manager, mocks) = makeManager()
        let expectedSessionId = testSessionId.uuidString.lowercased()
        manager.activate()
        manager.simulateTogglePlayPause() // → .recording
        mocks.voiceInput.transcribedText = "test prompt"

        manager.simulateTogglePlayPause() // → .sending

        let expectation = expectation(description: "async send")
        DispatchQueue.main.async {
            XCTAssertTrue(mocks.voiceInput.stopRecordingCalled)
            XCTAssertEqual(mocks.client.lastSentMessage?["text"] as? String, "test prompt")
            XCTAssertEqual(mocks.client.lastSentMessage?["working_directory"] as? String, "/test/working-dir")
            XCTAssertEqual(mocks.client.lastSentMessage?["resume_session_id"] as? String, expectedSessionId)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
    }

    func testTogglePlayPause_fromSending_isIgnored() {
        let (manager, mocks) = makeManager()
        manager.activate()
        manager.simulateTogglePlayPause() // → .recording
        mocks.voiceInput.transcribedText = "trigger send"
        manager.simulateTogglePlayPause() // → .sending (async send block enqueued)
        XCTAssertEqual(manager.state, .sending)

        manager.simulateTogglePlayPause() // no-op: .sending case is a break

        // Still .sending synchronously — the async send block hasn't run yet and
        // the third toggle must not start a new recording or change state.
        XCTAssertEqual(manager.state, .sending)
        // stopRecording was called once by the second toggle, not a second time.
        XCTAssertTrue(mocks.voiceInput.stopRecordingCalled)
    }

    func testTogglePlayPause_fromSpeaking_interrupts() {
        let (manager, mocks) = makeManager()

        // The settings.$headsetModeEnabled observer schedules an async delivery of
        // its initial value (false) during init. Drain it here so it fires as a
        // deactivate() no-op before we activate, preventing it from interfering
        // with isActive checks inside the isSpeaking Combine sink later.
        drainMainQueue()

        manager.activate()
        manager.simulateTogglePlayPause() // ready → recording
        mocks.voiceInput.transcribedText = "trigger send"
        manager.simulateTogglePlayPause() // recording → sending

        // Drain stopRecordingAndSend's async block (reads text, sends to session;
        // state stays at .sending because sendToActiveSession doesn't change state).
        drainMainQueue()
        XCTAssertEqual(manager.state, .sending)

        // Set isSpeaking — Combine delivers to the manager's sink (receive(on: main))
        // which transitions .sending → .speaking.
        mocks.voiceOutput.isSpeaking = true
        drainMainQueue()

        XCTAssertEqual(manager.state, .speaking)

        manager.simulateTogglePlayPause() // speaking → interrupt → ready
        XCTAssertEqual(manager.state, .ready)
        XCTAssertTrue(mocks.voiceOutput.stopCalled)
    }

    // MARK: - State Machine: Play / Pause / Interrupt

    func testPlay_fromReady_startsRecording() {
        let (manager, mocks) = makeManager()
        manager.activate()

        manager.simulatePlay()

        XCTAssertEqual(manager.state, .recording)
        XCTAssertTrue(mocks.voiceInput.startRecordingCalled)
    }

    func testPlay_fromRecording_isIgnored() {
        let (manager, mocks) = makeManager()
        manager.activate()
        manager.simulateTogglePlayPause() // → .recording

        let wasCalledBefore = mocks.voiceInput.startRecordingCalled
        manager.simulatePlay()

        // Still recording — play is a no-op in non-ready states
        XCTAssertEqual(manager.state, .recording)
        XCTAssertEqual(mocks.voiceInput.startRecordingCalled, wasCalledBefore)
    }

    func testPause_fromRecording_stopsAndSends() {
        let (manager, mocks) = makeManager()
        manager.activate()
        manager.simulatePlay() // → .recording
        mocks.voiceInput.transcribedText = "pause test"

        manager.simulatePause() // → .sending

        let expectation = expectation(description: "async send via pause")
        DispatchQueue.main.async {
            XCTAssertTrue(mocks.voiceInput.stopRecordingCalled)
            XCTAssertEqual(mocks.client.lastSentMessage?["text"] as? String, "pause test")
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
    }

    func testInterrupt_stopsVoiceOutput() {
        let (manager, mocks) = makeManager()
        manager.activate()

        manager.simulateInterrupt()

        XCTAssertEqual(manager.state, .ready)
        XCTAssertTrue(mocks.voiceOutput.stopCalled)
    }

    // MARK: - Edge Cases

    func testEmptyTranscription_returnsToReady() {
        let (manager, mocks) = makeManager()
        manager.activate()
        manager.simulateTogglePlayPause() // → .recording
        mocks.voiceInput.transcribedText = "   " // whitespace only

        manager.simulateTogglePlayPause()

        let expectation = expectation(description: "empty text returns to ready")
        DispatchQueue.main.async {
            XCTAssertEqual(manager.state, .ready)
            XCTAssertNil(mocks.client.lastSentMessage)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
    }

    func testDisconnectedClient_doesNotStartRecording() {
        let (manager, mocks) = makeManager()
        mocks.client.isConnected = false
        manager.activate()

        manager.simulateTogglePlayPause()

        XCTAssertEqual(manager.state, .ready)
        XCTAssertFalse(mocks.voiceInput.startRecordingCalled)
    }

    func testNoActiveSession_returnsToReady() {
        let mocks = HeadsetMockDependencies()
        let manager = HeadsetRemoteCommandManager(
            voiceInput: mocks.voiceInput,
            voiceOutput: mocks.voiceOutput,
            client: mocks.client,
            settings: mocks.settings,
            resolveActiveSession: { nil }
        )
        manager.activate()
        manager.simulateTogglePlayPause() // → .recording
        mocks.voiceInput.transcribedText = "orphaned prompt"

        manager.simulateTogglePlayPause() // → .sending → no session → .ready

        let expectation = expectation(description: "no session fallback")
        DispatchQueue.main.async {
            XCTAssertEqual(manager.state, .ready)
            XCTAssertNil(mocks.client.lastSentMessage)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
    }

    func testAutoSendDisabled_doesNotSend() {
        let mocks = HeadsetMockDependencies()
        mocks.settings.headsetAutoSend = false
        let manager = makeManagerWithDeps(mocks)
        manager.activate()
        manager.simulateTogglePlayPause()
        mocks.voiceInput.transcribedText = "should not send"

        manager.simulateTogglePlayPause()

        let expectation = expectation(description: "no send when autoSend=false")
        DispatchQueue.main.async {
            XCTAssertNil(mocks.client.lastSentMessage)
            XCTAssertEqual(manager.state, .ready)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
    }

    // MARK: - Activate / Deactivate

    func testActivate_setsIsActive() {
        let (manager, _) = makeManager()
        XCTAssertFalse(manager.isActive)

        manager.activate()

        XCTAssertTrue(manager.isActive)
    }

    func testDeactivate_clearsIsActive() {
        let (manager, _) = makeManager()
        manager.activate()

        manager.deactivate()

        XCTAssertFalse(manager.isActive)
        XCTAssertEqual(manager.state, .ready)
    }

    func testActivate_isIdempotent() {
        let (manager, _) = makeManager()
        manager.activate()
        manager.activate() // second call is a no-op

        XCTAssertTrue(manager.isActive)
    }

    func testDeactivate_isIdempotent() {
        let (manager, _) = makeManager()
        manager.activate()
        manager.deactivate()
        manager.deactivate() // second call is a no-op

        XCTAssertFalse(manager.isActive)
    }

    func testDeactivate_duringRecording_stopsRecording() {
        let (manager, mocks) = makeManager()
        manager.activate()
        manager.simulateTogglePlayPause() // → .recording
        XCTAssertEqual(manager.state, .recording)

        manager.deactivate()

        XCTAssertFalse(manager.isActive)
        XCTAssertEqual(manager.state, .ready)
        XCTAssertTrue(mocks.voiceInput.stopRecordingCalled)
    }

    func testHeadsetModeEnabledSetting_activatesManager() {
        let mocks = HeadsetMockDependencies()
        let manager = makeManagerWithDeps(mocks)
        // Drain the initial settings delivery before asserting isActive so the
        // baseline is clean and the subsequent explicit enable is the causal trigger.
        drainMainQueue()
        XCTAssertFalse(manager.isActive)

        mocks.settings.headsetModeEnabled = true

        // Settings sink fires on DispatchQueue.main
        let expectation = expectation(description: "auto-activate from setting")
        DispatchQueue.main.async {
            XCTAssertTrue(manager.isActive)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
    }

    func testHeadsetModeDisabledSetting_deactivatesManager() {
        let mocks = HeadsetMockDependencies()
        let manager = makeManagerWithDeps(mocks)
        // Drain initial settings delivery before activating so the initial false
        // delivery fires as a no-op (inactive), not as the deactivation under test.
        drainMainQueue()
        manager.activate()

        mocks.settings.headsetModeEnabled = false

        let expectation = expectation(description: "auto-deactivate from setting")
        DispatchQueue.main.async {
            XCTAssertFalse(manager.isActive)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
    }

    // MARK: - Reclaim Now Playing

    func testReclaimNowPlaying_whenDisabled_doesNothing() {
        let mocks = HeadsetMockDependencies()
        mocks.settings.headsetModeEnabled = false
        let manager = makeManagerWithDeps(mocks)

        // Should not crash or throw
        manager.reclaimNowPlaying()
    }

    // MARK: - BlueParrott BLE (macOS)

    #if os(macOS)
    /// Integration (verification target): a BlueParrottBLEManager-sourced button
    /// DOWN then UP drives the shared delegate mapping through record → stop+send
    /// (acceptance #1, the PTT loop). Exercises the real macOS path
    /// parser → dispatch → PTT arbitrator → BlueParrottButtonDelegate → HeadsetState
    /// machine, wired exactly as `startBlueParrott()` does in production.
    func testBlueParrottBLE_downThenUp_recordsThenStopsAndSends() {
        let (manager, mocks) = makeManager()
        manager.activate()

        let central = FakeBLECentralForHRCM()
        let ble = BlueParrottBLEManager(central: central, scheduleWork: { _, _ in })
        let arbitrator = BlueParrottPTTArbitrator(downstream: manager)
        ble.delegate = arbitrator
        ble.start()
        central.centralDelegate?.bleDidConnect()

        // Button DOWN (opcode 0x01) → start recording.
        central.centralDelegate?.bleDidUpdateButtonValue(Data([0x01]))
        drainMainQueue() // BLE dispatch hops to main before invoking the delegate
        XCTAssertEqual(manager.state, .recording)
        XCTAssertTrue(mocks.voiceInput.startRecordingCalled)

        mocks.voiceInput.transcribedText = "blue parrott ptt"

        // Button UP (opcode 0x00) → stop + send.
        central.centralDelegate?.bleDidUpdateButtonValue(Data([0x00]))
        drainMainQueue() // (1) dispatch hop → blueParrottButtonUp → stopRecordingAndSend
        drainMainQueue() // (2) stopRecordingAndSend's deferred transcription read + send

        XCTAssertTrue(mocks.voiceInput.stopRecordingCalled)
        XCTAssertEqual(manager.state, .sending)
        XCTAssertEqual(mocks.client.lastSentMessage?["text"] as? String, "blue parrott ptt")
    }

    /// Regression for the down/up-vs-gesture double-drive: the raw stream brackets a
    /// hold as `01,04,00`, so the in-bracket long-press must NOT interrupt the PTT
    /// recording — the arbitrator drops it, leaving down→record / up→stop+send intact.
    func testBlueParrottBLE_pttHold_inBracketLongPress_doesNotInterruptRecording() {
        let (manager, mocks) = makeManager()
        manager.activate()

        let central = FakeBLECentralForHRCM()
        let ble = BlueParrottBLEManager(central: central, scheduleWork: { _, _ in })
        let arbitrator = BlueParrottPTTArbitrator(downstream: manager)
        ble.delegate = arbitrator
        ble.start()
        central.centralDelegate?.bleDidConnect()

        central.centralDelegate?.bleDidUpdateButtonValue(Data([0x01])) // down → record
        drainMainQueue()
        XCTAssertEqual(manager.state, .recording)

        central.centralDelegate?.bleDidUpdateButtonValue(Data([0x04])) // in-bracket long-press → dropped
        drainMainQueue()
        XCTAssertEqual(manager.state, .recording, "in-bracket long-press must NOT interrupt the PTT recording")
        XCTAssertFalse(mocks.voiceOutput.stopCalled, "long-press during a PTT hold must not fire performInterrupt")

        mocks.voiceInput.transcribedText = "held utterance"
        central.centralDelegate?.bleDidUpdateButtonValue(Data([0x00])) // up → stop + send
        drainMainQueue()
        drainMainQueue()

        XCTAssertEqual(manager.state, .sending)
        XCTAssertEqual(mocks.client.lastSentMessage?["text"] as? String, "held utterance")
    }

    /// Unit: the PTT arbitrator forwards down/up and drops the in-bracket gesture
    /// codes (tap/double/long) so they never double-drive the state machine.
    func testBlueParrottPTTArbitrator_forwardsDownUp_dropsInBracketGestureCodes() {
        let spy = ButtonDelegateSpy()
        let arbitrator = BlueParrottPTTArbitrator(downstream: spy)

        arbitrator.blueParrottButtonDown()
        arbitrator.blueParrottLongPress()
        arbitrator.blueParrottTap()
        arbitrator.blueParrottDoubleTap()
        arbitrator.blueParrottButtonUp()

        XCTAssertEqual(spy.calls, ["down", "up"],
                       "PTT arbitrator must forward down/up and drop in-bracket gesture codes")
    }

    /// Enabling `blueParrottEnabled` stands up a BlueParrottBLEManager whose delegate
    /// is the PTT arbitrator routing to this manager; disabling tears it down — the
    /// macOS rewire's gating + delegate wiring, mirroring how iOS drives the SDK.
    func testBlueParrottEnabledSetting_startsBLEManagerRoutingToSelf() {
        let mocks = HeadsetMockDependencies()
        let manager = makeManagerWithDeps(mocks)
        let central = FakeBLECentralForHRCM()
        manager.makeBlueParrottBLEManager = {
            BlueParrottBLEManager(central: central, scheduleWork: { _, _ in })
        }
        // Flush the initial blueParrottEnabled=false delivery (stopBlueParrott no-op).
        drainMainQueue()
        XCTAssertNil(manager.blueParrottBLEManager)

        mocks.settings.blueParrottEnabled = true
        drainMainQueue()
        XCTAssertNotNil(manager.blueParrottBLEManager)
        let delegate = manager.blueParrottBLEManager?.delegate
        XCTAssertTrue(delegate is BlueParrottPTTArbitrator, "BLE manager delegate should be the PTT arbitrator")
        XCTAssertTrue((delegate as? BlueParrottPTTArbitrator)?.downstream === manager,
                      "arbitrator must route button events to this manager")

        mocks.settings.blueParrottEnabled = false
        drainMainQueue()
        XCTAssertNil(manager.blueParrottBLEManager)
    }

    /// Regression: with headset control OFF (`isActive == false`) the macOS BlueParrott
    /// PTT loop must still recover from `.sending` after the response's TTS so a SECOND
    /// press records again. Before `stateMachineEngaged`, the `.sending → .ready` reset
    /// was gated on `isActive` (only set by headset mode), so the down/up path jammed in
    /// `.sending` after one utterance (the arbitrator drops the `tap` that would otherwise
    /// reset it). Drives the real BLE → arbitrator → state-machine path, never activating.
    func testBlueParrottBLE_headsetModeOff_recoversAfterTTS_secondPressRecords() {
        let mocks = HeadsetMockDependencies()
        let manager = makeManagerWithDeps(mocks)
        let central = FakeBLECentralForHRCM()
        manager.makeBlueParrottBLEManager = {
            BlueParrottBLEManager(central: central, scheduleWork: { _, _ in })
        }
        // Headset mode stays OFF — never call activate(); the BLE source drives alone.
        mocks.settings.blueParrottEnabled = true
        drainMainQueue()
        XCTAssertFalse(manager.isActive, "headset mode is off — manager must not be active")
        XCTAssertNotNil(manager.blueParrottBLEManager)
        central.centralDelegate?.bleDidConnect()

        // Cycle 1: down → record, up → stop + send. State lands in .sending.
        central.centralDelegate?.bleDidUpdateButtonValue(Data([0x01]))
        drainMainQueue()
        XCTAssertEqual(manager.state, .recording)
        mocks.voiceInput.transcribedText = "first utterance"
        central.centralDelegate?.bleDidUpdateButtonValue(Data([0x00]))
        drainMainQueue() // dispatch hop → buttonUp → stopRecordingAndSend
        drainMainQueue() // deferred transcription read + send
        XCTAssertEqual(manager.state, .sending)
        XCTAssertEqual(mocks.client.lastSentMessage?["text"] as? String, "first utterance")

        // The response speaks then finishes — the state machine must walk
        // .sending → .speaking → .ready even though headset mode is off.
        mocks.voiceOutput.isSpeaking = true
        drainMainQueue()
        XCTAssertEqual(manager.state, .speaking)
        mocks.voiceOutput.isSpeaking = false
        drainMainQueue()
        XCTAssertEqual(manager.state, .ready,
                       "state must recover to .ready after TTS with headset mode off")

        // Cycle 2: a second press must record again — not jam in .sending.
        mocks.voiceInput.startRecordingCalled = false
        central.centralDelegate?.bleDidUpdateButtonValue(Data([0x01]))
        drainMainQueue()
        XCTAssertEqual(manager.state, .recording,
                       "second press must record — the PTT loop must not jam after one utterance")
        XCTAssertTrue(mocks.voiceInput.startRecordingCalled)
    }
    #endif

    // MARK: - Message Shape

    func testSentMessage_containsRequiredFields() {
        let (manager, mocks) = makeManager()
        let expectedSessionId = testSessionId.uuidString.lowercased()
        manager.activate()
        manager.simulateTogglePlayPause()
        mocks.voiceInput.transcribedText = "hello world"

        manager.simulateTogglePlayPause()

        let expectation = expectation(description: "message shape")
        DispatchQueue.main.async {
            guard let msg = mocks.client.lastSentMessage else {
                XCTFail("No message sent")
                expectation.fulfill()
                return
            }
            XCTAssertEqual(msg["type"] as? String, "prompt")
            XCTAssertEqual(msg["text"] as? String, "hello world")
            XCTAssertEqual(msg["resume_session_id"] as? String, expectedSessionId)
            XCTAssertEqual(msg["working_directory"] as? String, "/test/working-dir")
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
    }

    func testSentMessage_includesSystemPrompt_whenNonEmpty() {
        let mocks = HeadsetMockDependencies()
        mocks.settings.systemPrompt = "You are a coding assistant."
        let manager = makeManagerWithDeps(mocks)
        manager.activate()
        manager.simulateTogglePlayPause()
        mocks.voiceInput.transcribedText = "write a test"

        manager.simulateTogglePlayPause()

        let expectation = expectation(description: "system_prompt present")
        DispatchQueue.main.async {
            XCTAssertEqual(
                mocks.client.lastSentMessage?["system_prompt"] as? String,
                "You are a coding assistant."
            )
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
    }

    func testSentMessage_omitsSystemPrompt_whenEmpty() {
        let (manager, mocks) = makeManager()
        // settings.systemPrompt defaults to ""
        manager.activate()
        manager.simulateTogglePlayPause()
        mocks.voiceInput.transcribedText = "write a test"

        manager.simulateTogglePlayPause()

        let expectation = expectation(description: "system_prompt absent")
        DispatchQueue.main.async {
            XCTAssertNil(mocks.client.lastSentMessage?["system_prompt"])
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
    }

    // MARK: - Helpers

    private let testSessionId = UUID()

    /// Lets all currently-enqueued main-queue work items run before returning.
    /// Used to drain Combine deliveries scheduled via receive(on: DispatchQueue.main).
    private func drainMainQueue() {
        let e = expectation(description: "main-queue drain")
        DispatchQueue.main.async { e.fulfill() }
        wait(for: [e], timeout: 1.0)
    }

    private func makeManager() -> (HeadsetRemoteCommandManager, HeadsetMockDependencies) {
        let mocks = HeadsetMockDependencies()
        let manager = makeManagerWithDeps(mocks)
        return (manager, mocks)
    }

    private func makeManagerWithDeps(_ mocks: HeadsetMockDependencies) -> HeadsetRemoteCommandManager {
        let sessionId = testSessionId
        return HeadsetRemoteCommandManager(
            voiceInput: mocks.voiceInput,
            voiceOutput: mocks.voiceOutput,
            client: mocks.client,
            settings: mocks.settings,
            resolveActiveSession: { (sessionId, "/test/working-dir") }
        )
    }
}
