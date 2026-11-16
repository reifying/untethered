// VoiceOutputManagerTests.swift
// Unit tests for VoiceOutputManager

import XCTest
import AVFoundation
#if os(iOS)
@testable import VoiceCode
#else
@testable import VoiceCode
#endif

final class VoiceOutputManagerTests: XCTestCase {

    var manager: VoiceOutputManager!
    var settings: AppSettings!

    override func setUp() {
        super.setUp()
        // Clear UserDefaults for testing
        let domain = Bundle.main.bundleIdentifier!
        UserDefaults.standard.removePersistentDomain(forName: domain)
        UserDefaults.standard.synchronize()

        settings = AppSettings()
        manager = VoiceOutputManager(appSettings: settings)
    }

    override func tearDown() {
        manager?.stop()
        manager = nil
        settings = nil
        // Clean up UserDefaults
        let domain = Bundle.main.bundleIdentifier!
        UserDefaults.standard.removePersistentDomain(forName: domain)
        UserDefaults.standard.synchronize()
        super.tearDown()
    }

    // MARK: - Audio Session Configuration Tests

    func testAudioSessionConfigurationWithRespectSilentModeEnabled() {
        // Set respectSilentMode to true (default)
        settings.respectSilentMode = true
        manager.outputIsPrivateListening = { false }

        // Trigger AUTOMATIC speech with respectSilentMode flag (simulates automatic reading)
        manager.speakWithVoice("Test", rate: 0.5, voiceIdentifier: nil, respectSilentMode: true)

        // Verify audio session is configured to respect silent mode
        let audioSession = AVAudioSession.sharedInstance()
        XCTAssertEqual(audioSession.category, .ambient, "Audio session should use .ambient category when respectSilentMode is true")

        // Stop speech to clean up
        manager.stop()
    }

    func testAudioSessionConfigurationWithRespectSilentModeDisabled() {
        // Set respectSilentMode to false
        settings.respectSilentMode = false
        manager.outputIsPrivateListening = { false }

        // Trigger AUTOMATIC speech with respectSilentMode flag
        manager.speakWithVoice("Test", rate: 0.5, voiceIdentifier: nil, respectSilentMode: true)

        // Verify audio session is configured to ignore silent mode (because setting is false)
        let audioSession = AVAudioSession.sharedInstance()
        XCTAssertEqual(audioSession.category, .playback, "Audio session should use .playback category when respectSilentMode setting is false")

        // Stop speech to clean up
        manager.stop()
    }

    func testAudioSessionConfigurationSwitching() {
        // Start with respectSilentMode enabled
        manager.outputIsPrivateListening = { false }
        settings.respectSilentMode = true
        manager.speakWithVoice("Test 1", rate: 0.5, voiceIdentifier: nil, respectSilentMode: true)
        XCTAssertEqual(AVAudioSession.sharedInstance().category, .ambient)
        manager.stop()

        // Switch to respectSilentMode disabled
        settings.respectSilentMode = false
        manager.speakWithVoice("Test 2", rate: 0.5, voiceIdentifier: nil, respectSilentMode: true)
        XCTAssertEqual(AVAudioSession.sharedInstance().category, .playback)
        manager.stop()

        // Switch back to respectSilentMode enabled
        settings.respectSilentMode = true
        manager.speakWithVoice("Test 3", rate: 0.5, voiceIdentifier: nil, respectSilentMode: true)
        XCTAssertEqual(AVAudioSession.sharedInstance().category, .ambient)
        manager.stop()
    }

    // MARK: - Manual vs Automatic Speech Tests

    func testManualSpeechIgnoresSilentMode() {
        // Manual speech (default respectSilentMode=false) should always use .playback
        settings.respectSilentMode = true

        // Call speak() without respectSilentMode flag (manual action)
        manager.speak("Test message")

        let audioSession = AVAudioSession.sharedInstance()
        XCTAssertEqual(audioSession.category, .playback, "Manual speech should ignore silent mode setting")

        manager.stop()
    }

    func testAutomaticSpeechRespectsSilentMode() {
        // Automatic speech (respectSilentMode=true) should respect the setting
        manager.outputIsPrivateListening = { false }
        settings.respectSilentMode = true

        // Call speak() with respectSilentMode=true flag (automatic action)
        manager.speak("Test message", respectSilentMode: true)

        let audioSession = AVAudioSession.sharedInstance()
        XCTAssertEqual(audioSession.category, .ambient, "Automatic speech should respect silent mode when enabled")

        manager.stop()
    }

    // MARK: - Headset Mode vs Silent Switch (vibrate-speech bug, 2026-09-22)

    /// Regression: headset mode used to skip the silent-mode branch outright, so the
    /// session stayed in whatever category it was already in — .playAndRecord under
    /// headset control, which ignores the ringer switch. The simulator's output route
    /// is the built-in speaker, i.e. not private listening, so an automatic response
    /// must still land on .ambient.
    func testHeadsetModeDoesNotBypassSilentModeOnBuiltInOutput() throws {
        settings.respectSilentMode = true
        settings.headsetModeEnabled = true

        // Put the session somewhere the ringer switch is ignored first, so passing
        // the assertion requires the speak call to actually move it.
        try DeviceAudioSessionManager().configureAudioSessionForForcedPlayback()
        XCTAssertEqual(AVAudioSession.sharedInstance().category, .playback)

        manager.speak("Test message", respectSilentMode: true)

        XCTAssertEqual(AVAudioSession.sharedInstance().category, .ambient,
                       "Headset mode must not bypass the silent switch when audio would come out of the phone itself")

        manager.stop()
    }

    /// The opt-out still works with headset mode on: nothing is allowed to switch the
    /// category out from under HeadsetRemoteCommandManager once we've decided to speak.
    /// Starts from .playAndRecord — the state headset mode actually holds — so that
    /// "untouched" is distinguishable from "moved to .ambient" and from "did nothing".
    func testHeadsetSessionIsKeptWhenSilentModeRespectIsOff() throws {
        settings.respectSilentMode = false
        settings.headsetModeEnabled = true

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothA2DP])
        try session.setActive(true)

        manager.speak("Test message", respectSilentMode: true)

        XCTAssertEqual(session.category, .playAndRecord,
                       "Headset mode should leave the session untouched, not force .playback")

        manager.stop()
    }

    /// Headset control on, but the session is NOT .playAndRecord — the launch window, or
    /// right after an .ambient utterance. Leaving it alone would leave us mute in a
    /// silenced category, so the headset session is rebuilt. Regression for the caption
    /// promising "Tapping Read Aloud yourself always speaks."
    func testReadAloudUnderHeadsetModeSpeaksWhenSessionHasDrifted() throws {
        settings.respectSilentMode = true
        settings.headsetModeEnabled = true

        try DeviceAudioSessionManager().configureAudioSessionForSilentMode()
        XCTAssertEqual(AVAudioSession.sharedInstance().category, .ambient)

        // Manual Read Aloud: respectSilentMode defaults to false.
        manager.speak("Test message")

        XCTAssertEqual(AVAudioSession.sharedInstance().category, .playAndRecord,
                       "Read Aloud must not be left mute in a category the switch silences")

        manager.stop()
    }

    /// Headset mode with a headset in the route, but the category has drifted. Falling
    /// through to .playback here would drop the Bluetooth output options and re-trigger
    /// the Now Playing re-evaluation that e4dbb860 exists to avoid.
    func testHeadsetModeOnPrivateRouteRebuildsHeadsetSessionRatherThanPlayback() throws {
        settings.respectSilentMode = true
        settings.headsetModeEnabled = true
        manager.outputIsPrivateListening = { true }

        try DeviceAudioSessionManager().configureAudioSessionForSilentMode()

        manager.speak("Test message", respectSilentMode: true)

        let session = AVAudioSession.sharedInstance()
        XCTAssertEqual(session.category, .playAndRecord)
        XCTAssertTrue(session.categoryOptions.contains(.allowBluetoothA2DP))

        manager.stop()
    }

    // MARK: - Output route drives the decision

    /// Headphones in, ringer on vibrate: the response plays in-ear. This is the case the
    /// whole route rule exists for, and it is unreachable on a simulator without the seam.
    func testPrivateListeningRouteOverrulesSilentSwitch() {
        settings.respectSilentMode = true
        settings.headsetModeEnabled = false
        manager.outputIsPrivateListening = { true }

        manager.speak("Test message", respectSilentMode: true)

        XCTAssertEqual(AVAudioSession.sharedInstance().category, .playback,
                       "A deliberately-connected headset should speak regardless of the switch")

        manager.stop()
    }

    func testBuiltInRouteHonorsSilentSwitch() {
        settings.respectSilentMode = true
        settings.headsetModeEnabled = false
        manager.outputIsPrivateListening = { false }

        manager.speak("Test message", respectSilentMode: true)

        XCTAssertEqual(AVAudioSession.sharedInstance().category, .ambient)

        manager.stop()
    }

    /// Headset mode with the headset actually in the route: the category is never
    /// changed, which is what keeps AVRCP stem presses alive (the property e4dbb860
    /// added), and the headset manager's options survive.
    func testHeadsetSessionWithHeadsetRouteKeepsCategoryAndOptions() throws {
        settings.respectSilentMode = true
        settings.headsetModeEnabled = true
        manager.outputIsPrivateListening = { true }

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default,
                                options: [.allowBluetoothA2DP, .allowBluetoothHFP])
        try session.setActive(true)

        manager.speak("Test message", respectSilentMode: true)

        XCTAssertEqual(session.category, .playAndRecord)
        XCTAssertTrue(session.categoryOptions.contains(.allowBluetoothA2DP),
                      "Options must survive too — the keep-alive player depends on A2DP")
        XCTAssertTrue(session.categoryOptions.contains(.allowBluetoothHFP),
                      "HFP must survive — without it the BlueParrott mic captures nothing")

        manager.stop()
    }

    /// With the seam left nil — the production path — the live route is read and the
    /// simulator's built-in output classifies as "the room".
    func testLiveRouteReaderIsUsedWhenSeamIsNil() throws {
        settings.respectSilentMode = true
        settings.headsetModeEnabled = false
        XCTAssertNil(manager.outputIsPrivateListening, "precondition: production path")

        try DeviceAudioSessionManager().configureAudioSessionForForcedPlayback()
        manager.speak("Test message", respectSilentMode: true)

        XCTAssertEqual(AVAudioSession.sharedInstance().category, .ambient,
                       "The simulator's built-in output is not private listening")
        manager.stop()
    }

    /// No AppSettings retained: the `?? true` defaults must land on the quiet side.
    func testMissingAppSettingsDefaultsToHonoringSilentSwitch() throws {
        let orphan = VoiceOutputManager(appSettings: nil)
        orphan.outputIsPrivateListening = { false }

        try DeviceAudioSessionManager().configureAudioSessionForForcedPlayback()

        orphan.speak("Test message", respectSilentMode: true)

        XCTAssertEqual(AVAudioSession.sharedInstance().category, .ambient,
                       "With no settings to read, automatic speech should default to quiet")

        orphan.stop()
    }

    // MARK: - Speech Control Tests

    func testIsSpeakingState() {
        // Initially not speaking
        XCTAssertFalse(manager.isSpeaking)

        // Start speaking
        manager.speak("Test message")

        // Should be speaking (state updates on main queue)
        let expectation = XCTestExpectation(description: "isSpeaking updates")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertTrue(self.manager.isSpeaking)
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 1.0)

        manager.stop()
    }

    func testStopSpeech() {
        manager.speak("Test message")

        // Wait for speaking to start
        let startExpectation = XCTestExpectation(description: "Speaking starts")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            // Now stop speech
            self.manager.stop()

            // Check that speaking stops
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                XCTAssertFalse(self.manager.isSpeaking, "Should not be speaking after stop")
                startExpectation.fulfill()
            }
        }

        wait(for: [startExpectation], timeout: 2.0)
    }

    // MARK: - Recording-Active Suppression Tests (tmux-untethered-y03)

    /// While recording is active, speak() requests must be dropped — playing TTS
    /// into the open mic creates a feedback loop.
    func testSpeechSuppressedWhenRecordingActive() {
        manager.isRecordingActive = true
        manager.speak("This should be suppressed")

        let expectation = XCTestExpectation(description: "main queue settles")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            XCTAssertFalse(self.manager.isSpeaking,
                           "Should not be speaking when recording is active")
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
    }

    /// Once recording ends, the gate is lifted and subsequent speak() calls play
    /// normally. (Suppressed speech is dropped, not queued, so only the post-record
    /// call is heard.)
    func testSpeechResumesWhenRecordingEnds() {
        manager.isRecordingActive = true
        manager.speak("Suppressed")

        manager.isRecordingActive = false
        manager.speak("This should play")

        let expectation = XCTestExpectation(description: "speech starts")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            XCTAssertTrue(self.manager.isSpeaking,
                          "Should be speaking after recording ends")
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
        manager.stop()
    }

    /// resume() bypasses speakWithVoice(), so it needs its own recording-active
    /// guard: a stray continueSpeaking() would otherwise play into an open mic.
    ///
    /// We assert the guard's effect via onSpeechComplete (didFinish). The
    /// discriminator is whether the paused utterance ever runs to completion:
    /// a suppressed resume() leaves it paused (no completion), while an
    /// un-suppressed resume() lets it finish (completion fires). We keep the
    /// utterance short so the post-resume remainder completes well within the
    /// positive-control timeout, but multi-word so a `.word`-boundary pause on
    /// the first word leaves more left to speak (the pause genuinely holds back
    /// playback rather than the utterance draining on its own).
    func testResumeSuppressedWhenRecordingActive() {
        // Short, multi-word utterance: completes quickly after a real resume,
        // but has enough words that a .word-boundary pause leaves more to speak.
        manager.speak("Testing resume suppression behavior now")

        let started = XCTestExpectation(description: "speech starts")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { started.fulfill() }
        wait(for: [started], timeout: 1.0)
        XCTAssertTrue(manager.isSpeaking, "Precondition: synthesizer should be speaking")

        // Phase 1 — suppressed resume(): with recording active, resume() must be
        // a no-op. The utterance stays paused, so onSpeechComplete must NOT fire
        // and the synthesizer must still report speaking (paused counts as speaking).
        let suppressedCompletion = XCTestExpectation(description: "completion must NOT fire while suppressed")
        suppressedCompletion.isInverted = true
        manager.onSpeechComplete = { suppressedCompletion.fulfill() }

        manager.pause()
        manager.isRecordingActive = true
        manager.resume()  // Should be suppressed by the recording-active guard.

        wait(for: [suppressedCompletion], timeout: 1.5)
        XCTAssertTrue(manager.isSpeaking,
                      "Still paused (not finished): suppressed resume() must not restart playback")

        // Phase 2 — un-suppressed resume(): clear the flag and resume for real.
        // The short utterance now runs to completion, firing onSpeechComplete.
        let realCompletion = XCTestExpectation(description: "completion fires after un-suppressed resume")
        manager.onSpeechComplete = { realCompletion.fulfill() }
        manager.isRecordingActive = false
        manager.resume()

        wait(for: [realCompletion], timeout: 10.0)
    }

    // MARK: - Empty Speech Tests

    /// A message with nothing left to say after speech processing must produce
    /// no utterance at all rather than a silent-but-real one.
    func testBlankTextProducesNoUtterance() {
        manager.speak("  \n\n ")

        let expectation = XCTestExpectation(description: "main queue settles")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            XCTAssertFalse(self.manager.isSpeaking,
                           "blank text must not start an utterance")
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
    }

    /// speak() preempts whatever is playing, so a blank request is not merely
    /// wasteful — it would cut off the prose the listener is mid-way through.
    func testBlankTextDoesNotInterruptOngoingSpeech() {
        manager.speak("This is a longer spoken reply that should keep the synthesizer busy for a while")

        let started = XCTestExpectation(description: "synthesizer starts")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            XCTAssertTrue(self.manager.isSpeaking, "precondition: prose is playing")
            started.fulfill()
        }
        wait(for: [started], timeout: 1.0)

        manager.speak("")

        let stillSpeaking = XCTestExpectation(description: "prose survives")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            XCTAssertTrue(self.manager.isSpeaking,
                          "a blank request must not preempt the prose already playing")
            stillSpeaking.fulfill()
        }
        wait(for: [stillSpeaking], timeout: 1.0)

        manager.stop()
    }

    // MARK: - stop(completion:) Tests

    /// When the synthesizer was not speaking, stop(completion:) should still invoke
    /// the completion (on the main queue) so the caller can proceed unconditionally.
    func testStopCompletionFiresWhenNotSpeaking() {
        XCTAssertFalse(manager.isSpeaking)

        let expectation = XCTestExpectation(description: "completion fires")
        manager.stop {
            XCTAssertTrue(Thread.isMainThread, "completion must run on main queue")
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 1.0)
    }

    /// While speaking, stop(completion:) must defer the completion until the
    /// synthesizer actually releases its audio resources (didCancel/didFinish), so a
    /// downstream caller (VoiceInputManager) can safely flip the audio session to
    /// .record without colliding with mid-utterance teardown.
    func testStopCompletionDeferredUntilSynthesizerStops() {
        manager.speak("This is a longer test utterance that should keep the synthesizer busy")

        // Wait long enough for the synthesizer to actually start.
        let startExpectation = XCTestExpectation(description: "synthesizer starts")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            startExpectation.fulfill()
        }
        wait(for: [startExpectation], timeout: 1.0)

        let stopRequestedAt = Date()
        let completionExpectation = XCTestExpectation(description: "stop completion fires")
        manager.stop {
            XCTAssertTrue(Thread.isMainThread, "completion must run on main queue")
            XCTAssertFalse(self.manager.isSpeaking, "isSpeaking must be false by the time completion fires")
            // 300ms safety timeout means we're guaranteed an upper bound. The
            // synthesizer typically reports didCancel well under that.
            let elapsed = Date().timeIntervalSince(stopRequestedAt)
            XCTAssertLessThan(elapsed, 1.0, "completion should fire within the safety-timeout window")
            completionExpectation.fulfill()
        }

        wait(for: [completionExpectation], timeout: 2.0)
    }

    // MARK: - In-flight Cancellation on Session Focus Change (tmux-untethered-0sz)

    /// `inFlightSessionId` is set synchronously when a session-tagged speak() call is
    /// made, so a focus-change observer racing the speak call sees the new tag.
    func testInFlightSessionIdSetSynchronouslyWhenSpeakingWithSession() {
        let activeSession = ActiveSessionManager()
        let testManager = VoiceOutputManager(appSettings: settings, activeSession: activeSession)
        let sessionId = UUID()

        XCTAssertNil(testManager.inFlightSessionId, "should start nil")

        testManager.speak("Test", sessionId: sessionId)

        XCTAssertEqual(testManager.inFlightSessionId, sessionId,
                       "inFlightSessionId must be set synchronously inside speakWithVoice, before any async work")

        testManager.stop()
    }

    /// AC: with TTS playing in session A, switching focus to session B stops speech
    /// and clears `inFlightSessionId`.
    func testActiveSessionChangeToDifferentUUIDStopsSpeech() {
        let activeSession = ActiveSessionManager()
        let testManager = VoiceOutputManager(appSettings: settings, activeSession: activeSession)
        let sessionA = UUID()
        let sessionB = UUID()

        activeSession.setActiveSession(sessionA)
        testManager.speak("This is a longer test utterance that should keep the synthesizer busy for a moment",
                          sessionId: sessionA)

        // Let the synthesizer actually start so didCancel will fire when we stop it.
        let started = XCTestExpectation(description: "synthesizer starts")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { started.fulfill() }
        wait(for: [started], timeout: 1.0)

        XCTAssertEqual(testManager.inFlightSessionId, sessionA, "tag should be set after speak()")

        // Switch focus to a different session — observer must invoke stopSpeaking,
        // which fires didCancel asynchronously, which clears the tag.
        activeSession.setActiveSession(sessionB)

        let cleared = XCTestExpectation(description: "tag cleared after focus change")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            XCTAssertNil(testManager.inFlightSessionId,
                         "inFlightSessionId should be cleared after didCancel fires from focus-driven stop")
            XCTAssertFalse(testManager.isSpeaking,
                           "isSpeaking should be false after focus-driven stop completes")
            cleared.fulfill()
        }
        wait(for: [cleared], timeout: 2.0)
    }

    /// Conservative behavior: navigation to a nil active session (e.g. spurious
    /// onDisappear during a sheet presentation or partial swipe-back) must NOT
    /// cancel in-flight TTS. Trading AC2 ("nav to home stops TTS") for AC1
    /// reliability — see handleActiveSessionChange comment.
    func testActiveSessionChangeToNilDoesNotStopSpeech() {
        let activeSession = ActiveSessionManager()
        let testManager = VoiceOutputManager(appSettings: settings, activeSession: activeSession)
        let sessionA = UUID()

        activeSession.setActiveSession(sessionA)
        testManager.speak("This is a longer test utterance that should keep the synthesizer busy for a moment",
                          sessionId: sessionA)

        let started = XCTestExpectation(description: "synthesizer starts")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { started.fulfill() }
        wait(for: [started], timeout: 1.0)

        XCTAssertEqual(testManager.inFlightSessionId, sessionA)

        // Simulate spurious clear (e.g., transient onDisappear from a sheet).
        activeSession.clearActiveSession()

        let unchanged = XCTestExpectation(description: "tag unchanged after nil transition")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            XCTAssertEqual(testManager.inFlightSessionId, sessionA,
                           "nil active session must not cancel in-flight TTS (conservative behavior)")
            unchanged.fulfill()
        }
        wait(for: [unchanged], timeout: 1.0)

        testManager.stop()
    }

    /// AC: re-asserting the same active session UUID must NOT cancel in-flight TTS.
    /// Guards against spurious cancellations on view re-renders or duplicate
    /// `setActiveSession` calls during navigation.
    func testActiveSessionChangeToSameUUIDDoesNotStopSpeech() {
        let activeSession = ActiveSessionManager()
        let testManager = VoiceOutputManager(appSettings: settings, activeSession: activeSession)
        let sessionA = UUID()

        activeSession.setActiveSession(sessionA)
        testManager.speak("This is a longer test utterance that should keep the synthesizer busy for a moment",
                          sessionId: sessionA)

        let started = XCTestExpectation(description: "synthesizer starts")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { started.fulfill() }
        wait(for: [started], timeout: 1.0)

        XCTAssertEqual(testManager.inFlightSessionId, sessionA)

        // Re-emit the same UUID through the publisher.
        activeSession.setActiveSession(sessionA)

        // Give the sink time to fire on main; tag must still be A and synthesizer
        // must still be speaking.
        let unchanged = XCTestExpectation(description: "tag unchanged after same-UUID re-emit")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            XCTAssertEqual(testManager.inFlightSessionId, sessionA,
                           "re-asserting the same session must not cancel speech")
            unchanged.fulfill()
        }
        wait(for: [unchanged], timeout: 1.0)

        testManager.stop()
    }
}
