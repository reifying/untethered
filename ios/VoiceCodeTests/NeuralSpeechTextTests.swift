// NeuralSpeechTextTests.swift
// Text cleanup, chunking and audio packaging for the Kokoro voice, and its crash guard.
// Design: docs/design/kokoro-neural-voice.md

import XCTest
@testable import VoiceCode

final class NeuralSpeechTextTests: XCTestCase {

    // MARK: - Markdown cleanup

    func testLinkKeepsTextDropsURL() {
        XCTAssertEqual(NeuralSpeechText.cleanMarkdown("See [the docs](https://example.com/docs) now."), "See the docs now.")
    }

    func testBareURLIsReadAsItsHost() {
        XCTAssertEqual(NeuralSpeechText.cleanMarkdown("Opened https://www.github.com/a/b/pull/3."), "Opened github.com.")
    }

    func testBoldHeadingsAndBulletsRemoved() {
        let input = "## Summary\n**Done.** All good.\n- first item\n* second item\n• third"
        XCTAssertEqual(NeuralSpeechText.cleanMarkdown(input), "Summary\nDone. All good.\nfirst item\nsecond item\nthird")
    }

    func testSingleAsteriskEmphasisRemovedButArithmeticKept() {
        XCTAssertEqual(NeuralSpeechText.cleanMarkdown("This is *really* it, and 2*3*4 stays."), "This is really it, and 2*3*4 stays.")
    }

    // MARK: - Chunking

    func testFirstSentenceIsItsOwnChunk() {
        let chunks = NeuralSpeechText.chunks("Done. The tests pass. The branch is pushed.")
        XCTAssertEqual(chunks.map(\.text), ["Done.", "The tests pass. The branch is pushed."])
        XCTAssertEqual(chunks.map(\.pauseAfter), [NeuralSpeechText.pauseAfterSentence, NeuralSpeechText.pauseAfterLine])
    }

    func testEachLineIsAChunkWithALinePause() {
        let chunks = NeuralSpeechText.chunks("First line.\n\nSecond line. Still second.\nThird.")
        XCTAssertEqual(chunks.map(\.text), ["First line.", "Second line. Still second.", "Third."])
        XCTAssertTrue(chunks.allSatisfy { $0.pauseAfter == NeuralSpeechText.pauseAfterLine })
    }

    func testLongLineSplitsAtSentenceEndsWithinTheLimit() {
        let sentence = "This sentence is about fifty characters in length."
        let line = Array(repeating: sentence, count: 12).joined(separator: " ")
        let chunks = NeuralSpeechText.chunks("Intro.\n" + line)
        XCTAssertEqual(chunks.first?.text, "Intro.")
        let body = chunks.dropFirst()
        XCTAssertGreaterThan(body.count, 1)
        XCTAssertTrue(body.allSatisfy { $0.text.count <= NeuralSpeechText.maxChunkLength })
        XCTAssertEqual(body.map(\.text).joined(separator: " "), line, "no text is lost or reordered")
        XCTAssertEqual(body.last?.pauseAfter, NeuralSpeechText.pauseAfterLine)
    }

    func testAbbreviationsDoNotEndSentences() {
        XCTAssertEqual(NeuralSpeechText.splitSentences("Use a tool, e.g. ripgrep. Then stop."),
                       ["Use a tool, e.g. ripgrep.", "Then stop."])
    }

    func testDecimalsAndPathsDoNotSplit() {
        XCTAssertEqual(NeuralSpeechText.splitSentences("Version 0.18.3 is in ios/project.yml now."),
                       ["Version 0.18.3 is in ios/project.yml now."])
    }

    func testLinesWithNothingToPronounceAreSkipped() {
        XCTAssertEqual(NeuralSpeechText.chunks("Before.\n---\n—\nAfter.").map(\.text), ["Before.", "After."])
        XCTAssertTrue(NeuralSpeechText.chunks("  \n---\n").isEmpty)
    }

    func testDefaultRateIsSpeedOne() {
        XCTAssertEqual(NeuralSpeechText.speed(forRate: 0.5), 1.0)
        XCTAssertEqual(NeuralSpeechText.speed(forRate: 0.1), 0.5)
        XCTAssertEqual(NeuralSpeechText.speed(forRate: 1.0), 2.0)
    }

    // MARK: - Audio

    func testWavHeaderAndLengthIncludeTrailingSilence() {
        let samples = [Float](repeating: 0.1, count: 2400)
        let wav = NeuralSpeechAudio.wav(samples: samples, sampleRate: 24000, trailingSilence: 0.3)
        let frames = 2400 + 7200
        XCTAssertEqual(wav.count, 44 + frames * 2)
        XCTAssertEqual(String(decoding: wav.prefix(4), as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: wav[8..<16], as: UTF8.self), "WAVEfmt ")
        let rate = wav[24..<28].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        XCTAssertEqual(UInt32(littleEndian: rate), 24000)
        let lastSample = wav.suffix(2).withUnsafeBytes { $0.loadUnaligned(as: Int16.self) }
        XCTAssertEqual(lastSample, 0, "the tail is silence")
    }

    func testSoftLimitNeverClipsAndLeavesQuietSamplesAlone() {
        XCTAssertEqual(NeuralSpeechAudio.softLimit(0.3), 0.3)
        XCTAssertEqual(NeuralSpeechAudio.softLimit(-0.5), -0.5)
        for x: Float in [0.8, 1.0, 1.7, 5, -3] {
            XCTAssertLessThanOrEqual(abs(NeuralSpeechAudio.softLimit(x)), 1.0)
        }
        XCTAssertGreaterThan(NeuralSpeechAudio.softLimit(1.0), NeuralSpeechAudio.softLimit(0.8), "still monotonic above the knee")
        XCTAssertEqual(NeuralSpeechAudio.softLimit(.nan), 0)
    }
}

final class NeuralVoiceCrashGuardTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "NeuralVoiceCrashGuardTests"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        defaults = nil
        super.tearDown()
    }

    func testCleanLaunchIsNotACrash() {
        let guardian = NeuralVoiceCrashGuard(defaults: defaults)
        XCTAssertFalse(guardian.recordLaunch())
        XCTAssertFalse(guardian.isTrippedOff)
    }

    func testDyingMidSynthesisTwiceInARowTurnsItOff() {
        NeuralVoiceCrashGuard(defaults: defaults).synthesisWillStart() // run 1 dies here
        let second = NeuralVoiceCrashGuard(defaults: defaults)
        XCTAssertTrue(second.recordLaunch())
        XCTAssertFalse(second.isTrippedOff, "one crash is not enough")
        second.synthesisWillStart() // run 2 dies here too

        let third = NeuralVoiceCrashGuard(defaults: defaults)
        XCTAssertTrue(third.recordLaunch())
        XCTAssertTrue(third.isTrippedOff)
        XCTAssertEqual(third.totalCrashes, 2)
        XCTAssertNotNil(third.lastCrashDate)

        third.reset()
        XCTAssertFalse(third.isTrippedOff)
        XCTAssertEqual(third.totalCrashes, 2, "the total is kept for diagnosis")
    }

    func testASuccessfulSynthesisResetsTheRun() {
        NeuralVoiceCrashGuard(defaults: defaults).synthesisWillStart()
        let next = NeuralVoiceCrashGuard(defaults: defaults)
        next.recordLaunch()
        next.synthesisWillStart()
        next.synthesisDidEnd(succeeded: true)
        XCTAssertEqual(next.consecutiveCrashes, 0)

        XCTAssertFalse(NeuralVoiceCrashGuard(defaults: defaults).recordLaunch(), "the flag was cleared")
    }

    func testOverlappingCallsKeepTheFlagUntilTheLastEnds() {
        let guardian = NeuralVoiceCrashGuard(defaults: defaults)
        guardian.synthesisWillStart()
        guardian.synthesisWillStart()
        guardian.synthesisDidEnd(succeeded: true)
        // The process dies while the second call is still running.
        XCTAssertTrue(NeuralVoiceCrashGuard(defaults: defaults).recordLaunch())
    }

    func testAFailedCallClearsTheFlagWithoutResettingTheCount() {
        NeuralVoiceCrashGuard(defaults: defaults).synthesisWillStart()
        let next = NeuralVoiceCrashGuard(defaults: defaults)
        next.recordLaunch()
        next.synthesisWillStart()
        next.synthesisDidEnd(succeeded: false)
        XCTAssertEqual(next.consecutiveCrashes, 1)
        XCTAssertFalse(NeuralVoiceCrashGuard(defaults: defaults).recordLaunch())
    }

    func testQuittingMidSynthesisIsNotACrash() {
        let running = NeuralVoiceCrashGuard(defaults: defaults)
        running.synthesisWillStart()
        running.appWillTerminate()

        let next = NeuralVoiceCrashGuard(defaults: defaults)
        XCTAssertFalse(next.recordLaunch(), "an orderly quit clears the in-flight flag")
        XCTAssertEqual(next.consecutiveCrashes, 0)
    }

    func testASynthesisEndingAfterQuitDoesNotGoNegative() {
        let guardian = NeuralVoiceCrashGuard(defaults: defaults)
        guardian.synthesisWillStart()
        guardian.appWillTerminate()
        guardian.synthesisDidEnd(succeeded: false)
        guardian.synthesisWillStart() // would not set the flag if the count had gone to -1
        XCTAssertTrue(NeuralVoiceCrashGuard(defaults: defaults).recordLaunch())
    }
}

final class NeuralVoiceAvailabilityTests: XCTestCase {
    func testNeedsTheModelAndTheSetting() {
        for restricted in [true, false] {
            XCTAssertFalse(NeuralVoiceAvailability.isReadyToSpeak(
                modelLoaded: false, selected: true, failedInBackground: false, appIsActive: true, backgroundRestricted: restricted))
            XCTAssertFalse(NeuralVoiceAvailability.isReadyToSpeak(
                modelLoaded: true, selected: false, failedInBackground: false, appIsActive: true, backgroundRestricted: restricted))
            XCTAssertTrue(NeuralVoiceAvailability.isReadyToSpeak(
                modelLoaded: true, selected: true, failedInBackground: false, appIsActive: true, backgroundRestricted: restricted))
        }
    }

    func testOnTheMacAnAppThatIsNotInFrontStillReads() {
        // Driving mode on the Mac reads replies with another app in front.
        XCTAssertTrue(NeuralVoiceAvailability.isReadyToSpeak(
            modelLoaded: true, selected: true, failedInBackground: false, appIsActive: false, backgroundRestricted: false))
        XCTAssertTrue(NeuralVoiceAvailability.isReadyToSpeak(
            modelLoaded: true, selected: true, failedInBackground: true, appIsActive: false, backgroundRestricted: false))
        XCTAssertFalse(NeuralVoiceAvailability.shouldStandDownAfterFailure(appIsActive: false, backgroundRestricted: false))
    }

    func testOnTheIPhoneABackgroundFailureStandsDownUntilActive() {
        XCTAssertTrue(NeuralVoiceAvailability.shouldStandDownAfterFailure(appIsActive: false, backgroundRestricted: true))
        XCTAssertFalse(NeuralVoiceAvailability.shouldStandDownAfterFailure(appIsActive: true, backgroundRestricted: true))
        XCTAssertFalse(NeuralVoiceAvailability.isReadyToSpeak(
            modelLoaded: true, selected: true, failedInBackground: true, appIsActive: false, backgroundRestricted: true))
        XCTAssertTrue(NeuralVoiceAvailability.isReadyToSpeak(
            modelLoaded: true, selected: true, failedInBackground: true, appIsActive: true, backgroundRestricted: true))
        XCTAssertTrue(NeuralVoiceAvailability.isReadyToSpeak(
            modelLoaded: true, selected: true, failedInBackground: false, appIsActive: false, backgroundRestricted: true))
    }

    func testThePlatformDefault() {
        #if os(macOS)
        XCTAssertFalse(NeuralVoiceAvailability.backgroundSynthesisIsRestricted)
        XCTAssertEqual(NeuralVoiceSettingsText.deviceName, "Mac")
        #else
        XCTAssertTrue(NeuralVoiceAvailability.backgroundSynthesisIsRestricted)
        XCTAssertEqual(NeuralVoiceSettingsText.deviceName, "iPhone")
        #endif
        XCTAssertTrue(NeuralVoiceSettingsText.kokoroFooter(device: "Mac").contains("runs on this Mac."))
    }

    func testBothAppsHaveTheKokoroEngineAndTestsNeverLoadIt() {
        let engine = SpeechSynthesizerRouter.defaultNeuralEngine
        XCTAssertNotNil(engine, "the Mac app has the neural voice too")
        XCTAssertEqual(engine?.isReadyToSpeak, false, "no model is loaded under test, so Apple's voice reads")
    }

    func testKokoroIsTheDefaultEngineUnlessAppleWasChosen() {
        let suite = "NeuralVoiceAvailabilityTests"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertTrue(NeuralVoiceSettings.isKokoroSelected(defaults))
        defaults.set(NeuralVoiceSettings.apple, forKey: NeuralVoiceSettings.engineKey)
        XCTAssertFalse(NeuralVoiceSettings.isKokoroSelected(defaults))
    }
}
