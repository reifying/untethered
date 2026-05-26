import XCTest
@testable import VoiceCode

#if os(iOS)

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
            resolveActiveSession: { (UUID(), "/test") }
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
            resolveActiveSession: { (UUID(), "/test") }
        )
        drainMainQueue()
        XCTAssertNotNil(manager.blueParrottManager)

        mocks.settings.blueParrottEnabled = false
        drainMainQueue()

        XCTAssertNil(manager.blueParrottManager)
    }

    // MARK: - Helpers

    private func makeManager() -> (HeadsetRemoteCommandManager, HeadsetMockDependencies) {
        let mocks = HeadsetMockDependencies()
        let manager = HeadsetRemoteCommandManager(
            voiceInput: mocks.voiceInput,
            voiceOutput: mocks.voiceOutput,
            client: mocks.client,
            settings: mocks.settings,
            resolveActiveSession: { (UUID(), "/test/working-dir") }
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
