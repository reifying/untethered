import XCTest
@testable import VoiceCode

#if os(iOS)

// MARK: - Test doubles for the connect/retry state machine

/// In-memory stand-in for BPHeadset (which is nil off device), so the
/// connect / retry / re-arm logic can be exercised without real hardware.
private final class MockBlueParrottHeadset: BlueParrottHeadsetControlling {
    var connected = false
    var connectCount = 0
    var disconnectCount = 0
    var sdkModeEnabled = false
    var friendlyName: String?
    var firmwareVersion: String?
    var model: String?
    var buttonModeRawValue = 0
    var enableSDKModeCount = 0
    var disableSDKModeCount = 0

    func connect() { connectCount += 1 }
    func disconnect() { disconnectCount += 1 }
    func enableSDKMode(appName: String) { enableSDKModeCount += 1; sdkModeEnabled = true }
    func disableSDKMode() { disableSDKModeCount += 1; sdkModeEnabled = false }
    func addListener(_ listener: AnyObject) {}
    func removeListener(_ listener: AnyObject) {}
}

/// Captures scheduled connect work so tests can fire it synchronously instead
/// of waiting on real GCD timers.
private final class ScheduleRecorder {
    private(set) var scheduled: [(delay: TimeInterval, work: DispatchWorkItem)] = []

    var count: Int { scheduled.count }
    var lastDelay: TimeInterval? { scheduled.last?.delay }

    lazy var schedule: (TimeInterval, DispatchWorkItem) -> Void = { [weak self] delay, work in
        self?.scheduled.append((delay, work))
    }

    func fireLatest() {
        scheduled.last?.work.perform()
    }
}

final class BlueParrottButtonManagerTests: XCTestCase {

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "blueParrottEnabled")
        UserDefaults.standard.removeObject(forKey: "headsetModeEnabled")
        UserDefaults.standard.removeObject(forKey: "headsetAutoSend")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "blueParrottEnabled")
        UserDefaults.standard.removeObject(forKey: "headsetModeEnabled")
        UserDefaults.standard.removeObject(forKey: "headsetAutoSend")
        super.tearDown()
    }

    // MARK: - BlueParrott button events via HeadsetRemoteCommandManager delegate

    func testBlueParrottButtonDown_startsRecording_whenReady() {
        let (manager, mocks) = makeManager()
        manager.activate()
        XCTAssertEqual(manager.state, .ready)

        manager.blueParrottButtonDown()

        XCTAssertEqual(manager.state, .recording)
        XCTAssertTrue(mocks.voiceInput.startRecordingCalled)
    }

    func testBlueParrottButtonUp_stopsRecording_whenRecording() {
        let (manager, mocks) = makeManager()
        manager.activate()

        manager.blueParrottButtonDown()
        XCTAssertEqual(manager.state, .recording)

        manager.blueParrottButtonUp()

        XCTAssertTrue(mocks.voiceInput.stopRecordingCalled)
    }

    func testBlueParrottButtonDown_ignored_whenRecording() {
        let (manager, mocks) = makeManager()
        manager.activate()

        manager.blueParrottButtonDown()
        XCTAssertEqual(manager.state, .recording)

        mocks.voiceInput.startRecordingCalled = false
        manager.blueParrottButtonDown()

        XCTAssertFalse(mocks.voiceInput.startRecordingCalled)
    }

    func testBlueParrottButtonUp_ignored_whenReady() {
        let (manager, mocks) = makeManager()
        manager.activate()
        XCTAssertEqual(manager.state, .ready)

        manager.blueParrottButtonUp()

        XCTAssertFalse(mocks.voiceInput.stopRecordingCalled)
    }

    func testBlueParrottTap_startsRecording_whenReady() {
        let (manager, mocks) = makeManager()
        manager.activate()
        XCTAssertEqual(manager.state, .ready)

        manager.blueParrottTap()

        XCTAssertEqual(manager.state, .recording)
        XCTAssertTrue(mocks.voiceInput.startRecordingCalled)
    }

    func testBlueParrottTap_stopsRecording_whenRecording() {
        let (manager, mocks) = makeManager()
        manager.activate()

        manager.blueParrottTap()
        XCTAssertEqual(manager.state, .recording)

        manager.blueParrottTap()

        XCTAssertTrue(mocks.voiceInput.stopRecordingCalled)
    }

    func testBlueParrottTap_interrupts_whenSpeaking() {
        let (manager, mocks) = makeManager()
        drainMainQueue()
        manager.activate()

        manager.blueParrottTap() // ready → recording
        mocks.voiceInput.transcribedText = "trigger send"
        manager.blueParrottTap() // recording → sending

        drainMainQueue()
        XCTAssertEqual(manager.state, .sending)

        mocks.voiceOutput.isSpeaking = true
        drainMainQueue()
        XCTAssertEqual(manager.state, .speaking)

        manager.blueParrottTap()

        XCTAssertTrue(mocks.voiceOutput.stopCalled)
        XCTAssertEqual(manager.state, .ready)
    }

    func testBlueParrottTap_resetsToReady_whenSending() {
        let (manager, _) = makeManager()
        manager.activate()

        manager.blueParrottTap()
        manager.blueParrottTap()
        XCTAssertEqual(manager.state, .sending)

        manager.blueParrottTap()

        XCTAssertEqual(manager.state, .ready)
    }

    func testBlueParrottDoubleTap_interrupts() {
        let (manager, mocks) = makeManager()
        manager.activate()

        manager.blueParrottDoubleTap()

        XCTAssertTrue(mocks.voiceOutput.stopCalled)
        XCTAssertEqual(manager.state, .ready)
    }

    func testBlueParrottLongPress_interrupts() {
        let (manager, mocks) = makeManager()
        manager.activate()

        manager.blueParrottLongPress()

        XCTAssertTrue(mocks.voiceOutput.stopCalled)
        XCTAssertEqual(manager.state, .ready)
    }

    // MARK: - Setting toggle

    func testBlueParrottEnabled_startsManager() {
        let mocks = HeadsetMockDependencies()
        mocks.settings.blueParrottEnabled = false
        let manager = HeadsetRemoteCommandManager(
            voiceInput: mocks.voiceInput,
            voiceOutput: mocks.voiceOutput,
            client: mocks.client,
            settings: mocks.settings,
            resolveActiveSession: { (UUID(), "/test", false, "claude") }
        )
        drainMainQueue()
        XCTAssertNil(manager.blueParrottManager)

        mocks.settings.blueParrottEnabled = true
        drainMainQueue()

        XCTAssertNotNil(manager.blueParrottManager)
    }

    func testBlueParrottDisabled_stopsManager() {
        let mocks = HeadsetMockDependencies()
        mocks.settings.blueParrottEnabled = true
        let manager = HeadsetRemoteCommandManager(
            voiceInput: mocks.voiceInput,
            voiceOutput: mocks.voiceOutput,
            client: mocks.client,
            settings: mocks.settings,
            resolveActiveSession: { (UUID(), "/test", false, "claude") }
        )
        drainMainQueue()
        XCTAssertNotNil(manager.blueParrottManager)

        mocks.settings.blueParrottEnabled = false
        drainMainQueue()

        XCTAssertNil(manager.blueParrottManager)
    }

    // MARK: - Connect retry / re-arm (BlueParrottButtonManager directly)

    func testInitialStart_schedulesFirstConnect() {
        let recorder = ScheduleRecorder()
        let mock = MockBlueParrottHeadset()
        let manager = BlueParrottButtonManager(
            headsetProvider: { mock },
            scheduleWork: recorder.schedule
        )

        manager.start()

        XCTAssertEqual(recorder.count, 1)
        XCTAssertEqual(recorder.lastDelay, BlueParrottButtonManager.initialDelay)
        XCTAssertFalse(manager.testInSlowRetry)

        recorder.fireLatest()
        XCTAssertEqual(mock.connectCount, 1)
    }

    func testRetryExhaustion_switchesToLowFrequencyRetry() {
        let recorder = ScheduleRecorder()
        let mock = MockBlueParrottHeadset()
        let manager = BlueParrottButtonManager(
            headsetProvider: { mock },
            scheduleWork: recorder.schedule
        )

        manager.start()

        // Drive the fast retry cycle to exhaustion: 1 initial attempt + maxRetries.
        let fastAttempts = BlueParrottButtonManager.maxRetries + 1
        for _ in 0..<fastAttempts {
            recorder.fireLatest()
            manager.simulateConnectFailureForTesting()
        }

        XCTAssertEqual(mock.connectCount, fastAttempts)
        XCTAssertTrue(manager.testInSlowRetry, "should switch to low-frequency retry once fast retries are exhausted")
        XCTAssertEqual(recorder.lastDelay, BlueParrottButtonManager.slowRetryDelay,
                       "exhausted retries should schedule the next attempt at the slow interval, not give up")
    }

    func testRetryExhaustion_thenHeadsetPoweredOn_connectsViaSlowRetry() {
        let recorder = ScheduleRecorder()
        let mock = MockBlueParrottHeadset()
        let manager = BlueParrottButtonManager(
            headsetProvider: { mock },
            scheduleWork: recorder.schedule
        )

        manager.start()
        let fastAttempts = BlueParrottButtonManager.maxRetries + 1
        for _ in 0..<fastAttempts {
            recorder.fireLatest()
            manager.simulateConnectFailureForTesting()
        }
        XCTAssertTrue(manager.testInSlowRetry)

        // Headset is powered on now. The next (slow) retry tick fires and succeeds —
        // no manual intervention required.
        recorder.fireLatest()
        XCTAssertEqual(mock.connectCount, fastAttempts + 1)

        mock.connected = true
        manager.simulateConnectedForTesting()

        XCTAssertTrue(manager.isConnected)
        XCTAssertFalse(manager.testInSlowRetry)
        XCTAssertEqual(manager.testRetryCount, 0)
    }

    func testAppForeground_afterExhaustion_reArmsFastRetryAndConnects() {
        let recorder = ScheduleRecorder()
        let mock = MockBlueParrottHeadset()
        let manager = BlueParrottButtonManager(
            headsetProvider: { mock },
            scheduleWork: recorder.schedule
        )

        manager.start()
        let fastAttempts = BlueParrottButtonManager.maxRetries + 1
        for _ in 0..<fastAttempts {
            recorder.fireLatest()
            manager.simulateConnectFailureForTesting()
        }
        XCTAssertTrue(manager.testInSlowRetry)
        let connectsBefore = mock.connectCount
        let schedulesBefore = recorder.count

        // User powered on the headset and brought the app forward.
        manager.simulateAppDidBecomeActiveForTesting()

        XCTAssertFalse(manager.testInSlowRetry, "foreground should re-arm the fast retry cycle")
        XCTAssertEqual(manager.testRetryCount, 0)
        XCTAssertEqual(recorder.count, schedulesBefore + 1)
        XCTAssertEqual(recorder.lastDelay, BlueParrottButtonManager.initialDelay)

        recorder.fireLatest()
        XCTAssertEqual(mock.connectCount, connectsBefore + 1)

        mock.connected = true
        manager.simulateConnectedForTesting()
        XCTAssertTrue(manager.isConnected)
    }

    func testAppForeground_whenConnected_doesNotReconnect() {
        let recorder = ScheduleRecorder()
        let mock = MockBlueParrottHeadset()
        let manager = BlueParrottButtonManager(
            headsetProvider: { mock },
            scheduleWork: recorder.schedule
        )

        manager.start()
        recorder.fireLatest()
        mock.connected = true
        manager.simulateConnectedForTesting()
        XCTAssertTrue(manager.isConnected)

        let schedulesBefore = recorder.count
        manager.simulateAppDidBecomeActiveForTesting()

        XCTAssertEqual(recorder.count, schedulesBefore, "no re-arm should occur while connected")
    }

    func testNonRetryableFailure_doesNotReArm() {
        let recorder = ScheduleRecorder()
        let mock = MockBlueParrottHeadset()
        let manager = BlueParrottButtonManager(
            headsetProvider: { mock },
            scheduleWork: recorder.schedule
        )

        manager.start()
        recorder.fireLatest()
        XCTAssertEqual(mock.connectCount, 1)

        let schedulesBefore = recorder.count
        manager.simulateNonRetryableFailureForTesting()

        XCTAssertEqual(recorder.count, schedulesBefore, "non-retryable failure should not schedule another attempt")
        XCTAssertFalse(manager.testInSlowRetry)
        XCTAssertFalse(manager.isConnecting)
    }

    func testStop_haltsRetries() {
        let recorder = ScheduleRecorder()
        let mock = MockBlueParrottHeadset()
        let manager = BlueParrottButtonManager(
            headsetProvider: { mock },
            scheduleWork: recorder.schedule
        )

        manager.start()
        recorder.fireLatest()
        manager.simulateConnectFailureForTesting()
        XCTAssertEqual(mock.connectCount, 1)

        manager.stop()
        let connectsAfterStop = mock.connectCount

        // Any pending work that fires after stop() must not connect, and a late
        // failure callback must not re-arm.
        recorder.fireLatest()
        manager.simulateConnectFailureForTesting()

        XCTAssertEqual(mock.connectCount, connectsAfterStop, "no connect attempts after stop()")
        XCTAssertFalse(manager.testInSlowRetry)
    }

    // MARK: - Helpers

    private func makeManager() -> (HeadsetRemoteCommandManager, HeadsetMockDependencies) {
        let mocks = HeadsetMockDependencies()
        let manager = HeadsetRemoteCommandManager(
            voiceInput: mocks.voiceInput,
            voiceOutput: mocks.voiceOutput,
            client: mocks.client,
            settings: mocks.settings,
            resolveActiveSession: { (UUID(), "/test/working-dir", false, "claude") }
        )
        return (manager, mocks)
    }

    private func drainMainQueue() {
        let exp = expectation(description: "drain")
        DispatchQueue.main.async { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)
    }
}

#endif
