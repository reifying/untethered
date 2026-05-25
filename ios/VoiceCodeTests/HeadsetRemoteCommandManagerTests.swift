// HeadsetRemoteCommandManagerTests.swift
// Unit tests for HeadsetRemoteCommandManager state machine and auto-send logic.
// Included in VoiceCodeMacTests only; excluded from iOS VoiceCodeTests target
// via project.yml. The #if os(macOS) guard is a secondary safeguard.

import XCTest
@testable import VoiceCode

#if os(macOS)

// MARK: - Mock Dependencies

class MockVoiceInputForHeadset: VoiceInputManager {
    var startRecordingCalled = false
    var stopRecordingCalled = false

    override func startRecording() {
        startRecordingCalled = true
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
        UserDefaults.standard.removeObject(forKey: "headsetPTTEnabled")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "headsetModeEnabled")
        UserDefaults.standard.removeObject(forKey: "headsetAutoSend")
        UserDefaults.standard.removeObject(forKey: "headsetPTTEnabled")
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

    // MARK: - PTT Mute Detection

    func testMuteOff_fromReady_startsRecording() {
        let (manager, mocks) = makeManager()
        manager.activate()

        manager.simulateMuteChanged(isMuted: false)

        XCTAssertEqual(manager.state, .recording)
        XCTAssertTrue(mocks.voiceInput.startRecordingCalled)
    }

    func testMuteOn_fromRecording_stopsAndSends() {
        let (manager, mocks) = makeManager()
        manager.activate()
        manager.simulateMuteChanged(isMuted: false) // → .recording
        mocks.voiceInput.transcribedText = "ptt test"

        manager.simulateMuteChanged(isMuted: true) // → .sending

        let expectation = expectation(description: "ptt send")
        DispatchQueue.main.async {
            XCTAssertTrue(mocks.voiceInput.stopRecordingCalled)
            XCTAssertEqual(mocks.client.lastSentMessage?["text"] as? String, "ptt test")
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
    }

    func testMuteOff_fromRecording_isIgnored() {
        let (manager, mocks) = makeManager()
        manager.activate()
        manager.simulateTogglePlayPause() // → .recording

        let callsBefore = mocks.voiceInput.startRecordingCalled
        manager.simulateMuteChanged(isMuted: false) // not in .ready → ignored

        XCTAssertEqual(manager.state, .recording)
        XCTAssertEqual(mocks.voiceInput.startRecordingCalled, callsBefore)
    }

    func testMuteOn_fromReady_isIgnored() {
        let (manager, mocks) = makeManager()
        manager.activate()
        XCTAssertEqual(manager.state, .ready)

        manager.simulateMuteChanged(isMuted: true) // not in .recording → ignored

        XCTAssertEqual(manager.state, .ready)
        XCTAssertFalse(mocks.voiceInput.stopRecordingCalled)
    }

    // MARK: - PTT Settings Integration

    func testActivate_withPTTEnabled_startsPTTMonitoring() {
        let mocks = HeadsetMockDependencies()
        mocks.settings.headsetPTTEnabled = true
        let manager = makeManagerWithDeps(mocks)
        drainMainQueue()

        manager.activate()

        XCTAssertTrue(manager.isPTTMonitoring)
    }

    func testActivate_withPTTDisabled_doesNotStartPTTMonitoring() {
        let (manager, _) = makeManager()
        drainMainQueue()

        manager.activate()

        XCTAssertFalse(manager.isPTTMonitoring)
    }

    func testDeactivate_stopsPTTMonitoring() {
        let mocks = HeadsetMockDependencies()
        mocks.settings.headsetPTTEnabled = true
        let manager = makeManagerWithDeps(mocks)
        drainMainQueue()
        manager.activate()
        XCTAssertTrue(manager.isPTTMonitoring)

        manager.deactivate()

        XCTAssertFalse(manager.isPTTMonitoring)
    }

    func testStartPTTMonitoring_isIdempotent() {
        let mocks = HeadsetMockDependencies()
        mocks.settings.headsetPTTEnabled = true
        let manager = makeManagerWithDeps(mocks)
        drainMainQueue()
        manager.activate()
        XCTAssertTrue(manager.isPTTMonitoring)

        // A second call (e.g. from the $headsetPTTEnabled Combine delivery after activate)
        // must not replace and leak the existing monitor.
        manager.startPTTMonitoring()

        // Still monitoring with the same (first) monitor — no replacement occurred.
        XCTAssertTrue(manager.isPTTMonitoring)
    }

    func testHeadsetPTTEnabledSetting_whenActive_startsPTTMonitoring() {
        let (manager, mocks) = makeManager()
        // Drain initial Combine deliveries (headsetModeEnabled=false, headsetPTTEnabled=false)
        // before activating — same pattern as testHeadsetModeEnabledSetting_activatesManager.
        drainMainQueue()
        manager.activate()
        XCTAssertFalse(manager.isPTTMonitoring)

        mocks.settings.headsetPTTEnabled = true

        let expectation = expectation(description: "PTT monitoring starts from setting")
        DispatchQueue.main.async {
            XCTAssertTrue(manager.isPTTMonitoring)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
    }

    func testHeadsetPTTDisabledSetting_whenActive_stopsPTTMonitoring() {
        let mocks = HeadsetMockDependencies()
        mocks.settings.headsetPTTEnabled = true
        let manager = makeManagerWithDeps(mocks)
        drainMainQueue()
        manager.activate()
        // headsetPTTEnabled is already true, activate() calls startPTTMonitoring() synchronously
        XCTAssertTrue(manager.isPTTMonitoring)

        mocks.settings.headsetPTTEnabled = false

        let expectation = expectation(description: "PTT monitoring stops from setting")
        DispatchQueue.main.async {
            XCTAssertFalse(manager.isPTTMonitoring)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
    }

    func testHeadsetPTTEnabledSetting_whenInactive_doesNotStartPTTMonitoring() {
        let (manager, mocks) = makeManager()
        drainMainQueue()
        XCTAssertFalse(manager.isActive)

        mocks.settings.headsetPTTEnabled = true

        let expectation = expectation(description: "PTT monitoring does not start when inactive")
        DispatchQueue.main.async {
            XCTAssertFalse(manager.isPTTMonitoring)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
    }

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

#endif
