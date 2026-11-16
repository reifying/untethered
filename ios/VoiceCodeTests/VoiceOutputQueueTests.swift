// VoiceOutputQueueTests.swift
// Replies that arrive while a session is open are read one after another, in
// full, through VoiceOutputManager.enqueue. See
// docs/design/tool-filter-speech-queue-links.md §2.

import XCTest
import AVFoundation
import Combine
@testable import VoiceCode

final class VoiceOutputQueueTests: XCTestCase {

    private var manager: VoiceOutputManager!
    private var settings: AppSettings!
    private var activeSession: ActiveSessionManager!
    private var cancellables: Set<AnyCancellable> = []

    override func setUp() {
        super.setUp()
        settings = AppSettings()
        activeSession = ActiveSessionManager()
        manager = VoiceOutputManager(appSettings: settings, activeSession: activeSession)
    }

    override func tearDown() {
        manager?.stop()
        manager = nil
        activeSession = nil
        settings = nil
        cancellables.removeAll()
        super.tearDown()
    }

    /// Run the main queue long enough for the delegate's async hop to land.
    private func drainMain(_ seconds: TimeInterval = 0.1) {
        let done = expectation(description: "main queue drained")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { done.fulfill() }
        wait(for: [done], timeout: seconds + 2)
    }

    private let longText = "This is a longer reply that keeps the synthesizer busy for a good few seconds while the test runs."

    // MARK: - Queueing

    func testEnqueueWhenIdleStartsImmediately() {
        manager.enqueue("First reply")

        XCTAssertEqual(manager.currentUtterance?.speechString, "First reply")
        XCTAssertEqual(manager.pendingSpeechCount, 0)
    }

    func testEnqueueWhileReadingWaitsItsTurn() {
        manager.enqueue(longText)
        manager.enqueue("Second reply")
        manager.enqueue("Third reply")

        XCTAssertEqual(manager.currentUtterance?.speechString, longText,
                       "the reply being read must not be interrupted")
        XCTAssertEqual(manager.pendingSpeechCount, 2)
    }

    /// The in-flight check must not depend on `synthesizer.isSpeaking`, which reads
    /// false for tens of milliseconds after speak() returns. Two replies arriving
    /// in the same main-queue turn — the normal shape of a batch — must queue.
    func testBackToBackEnqueueInOneTurnQueuesTheSecond() {
        manager.enqueue("One")
        manager.enqueue("Two")
        XCTAssertEqual(manager.currentUtterance?.speechString, "One")
        XCTAssertEqual(manager.pendingSpeechCount, 1)
    }

    func testFinishingAReplyStartsTheNextInOrder() throws {
        manager.enqueue(longText)
        manager.enqueue("Second reply")
        manager.enqueue("Third reply")
        let first = try XCTUnwrap(manager.currentUtterance)

        manager.speechSynthesizer(AVSpeechSynthesizer(), didFinish: first)
        drainMain()

        XCTAssertEqual(manager.currentUtterance?.speechString, "Second reply")
        XCTAssertEqual(manager.pendingSpeechCount, 1)
        XCTAssertEqual(manager.utterancesFinished, 1)

        let second = try XCTUnwrap(manager.currentUtterance)
        manager.speechSynthesizer(AVSpeechSynthesizer(), didFinish: second)
        drainMain()

        XCTAssertEqual(manager.currentUtterance?.speechString, "Third reply")
        XCTAssertEqual(manager.pendingSpeechCount, 0)
    }

    /// A callback for an utterance that is no longer current (a Read Aloud
    /// replaced it, and its didCancel lands late) must not touch the queue.
    func testStaleCallbackDoesNotAdvanceOrClearTheQueue() throws {
        manager.enqueue(longText)
        manager.enqueue("Second reply")
        manager.enqueue("Third reply")
        let first = try XCTUnwrap(manager.currentUtterance)
        manager.speechSynthesizer(AVSpeechSynthesizer(), didFinish: first)
        drainMain()
        XCTAssertEqual(manager.currentUtterance?.speechString, "Second reply")

        manager.speechSynthesizer(AVSpeechSynthesizer(), didFinish: first)
        manager.speechSynthesizer(AVSpeechSynthesizer(), didCancel: first)
        drainMain()

        XCTAssertEqual(manager.currentUtterance?.speechString, "Second reply")
        XCTAssertEqual(manager.pendingSpeechCount, 1, "stale callbacks leave the queue alone")
    }

    func testCancellingTheCurrentReplyEndsTheQueue() throws {
        manager.enqueue(longText)
        manager.enqueue("Second reply")
        let first = try XCTUnwrap(manager.currentUtterance)

        manager.speechSynthesizer(AVSpeechSynthesizer(), didCancel: first)
        drainMain()

        XCTAssertNil(manager.currentUtterance)
        XCTAssertEqual(manager.pendingSpeechCount, 0,
                       "a cancelled read means stop reading, not skip to the next reply")
    }

    // MARK: - Replay and skip

    func testReplayCutsInAndKeepsTheRepliesStillWaiting() {
        manager.enqueue(longText)
        manager.enqueue("Second reply")
        manager.enqueue("Third reply")

        XCTAssertTrue(manager.replay("An earlier reply, asked for again"))

        XCTAssertEqual(manager.currentUtterance?.speechString, "An earlier reply, asked for again",
                       "a replay is read now, not after the queue")
        XCTAssertEqual(manager.pendingSpeechCount, 2,
                       "asking to hear one reply again must not lose replies not yet heard")
    }

    func testReplayedReplyIsFollowedByTheWaitingOnes() throws {
        manager.enqueue(longText)
        manager.enqueue("Second reply")
        manager.replay("Replayed")
        let replayed = try XCTUnwrap(manager.currentUtterance)

        manager.speechSynthesizer(AVSpeechSynthesizer(), didFinish: replayed)
        drainMain()

        XCTAssertEqual(manager.currentUtterance?.speechString, "Second reply")
        XCTAssertEqual(manager.pendingSpeechCount, 0)
    }

    func testBlankReplayStartsNothingAndKeepsWhatIsBeingRead() {
        manager.enqueue(longText)
        manager.enqueue("Second reply")

        XCTAssertFalse(manager.replay("   \n"))

        XCTAssertEqual(manager.currentUtterance?.speechString, longText)
        XCTAssertEqual(manager.pendingSpeechCount, 1)
    }

    func testReplayWhileRecordingStartsNothing() {
        manager.isRecordingActive = true
        XCTAssertFalse(manager.replay("Not now"))
        XCTAssertNil(manager.currentUtterance)
    }

    func testSkipGoesStraightToTheNextReply() {
        manager.enqueue(longText)
        manager.enqueue("Second reply")
        manager.enqueue("Third reply")

        manager.skipCurrent()

        XCTAssertEqual(manager.currentUtterance?.speechString, "Second reply")
        XCTAssertEqual(manager.pendingSpeechCount, 1, "only the reply being read is skipped")
    }

    /// The skipped reply's cancel callback arrives after the next reply has started.
    /// It must not end the queue or report that speech stopped.
    func testSkippedReplysLateCancelDoesNotEndTheQueue() throws {
        manager.enqueue(longText)
        let skipped = try XCTUnwrap(manager.currentUtterance)
        manager.enqueue("Second reply")
        manager.enqueue("Third reply")
        manager.skipCurrent()
        drainMain()
        var sawSilence = false
        manager.$isSpeaking.dropFirst().sink { if !$0 { sawSilence = true } }.store(in: &cancellables)

        manager.speechSynthesizer(AVSpeechSynthesizer(), didCancel: skipped)
        drainMain()

        XCTAssertEqual(manager.currentUtterance?.speechString, "Second reply")
        XCTAssertEqual(manager.pendingSpeechCount, 1)
        XCTAssertFalse(sawSilence, "isSpeaking must stay true across a skip to the next reply")
    }

    func testSkipWithNothingWaitingStopsReading() {
        manager.enqueue(longText)

        manager.skipCurrent()
        drainMain()

        XCTAssertNil(manager.currentUtterance)
        XCTAssertFalse(manager.isSpeaking)
    }

    func testBlankReplyIsNotQueued() {
        manager.enqueue(longText)
        manager.enqueue("  \n ")
        XCTAssertEqual(manager.pendingSpeechCount, 0)
        XCTAssertEqual(manager.currentUtterance?.speechString, longText)
    }

    // MARK: - What still interrupts

    func testExplicitSpeakTakesOverAndDiscardsTheQueue() {
        manager.enqueue(longText)
        manager.enqueue("Second reply")

        manager.speak("Read Aloud tap")

        XCTAssertEqual(manager.currentUtterance?.speechString, "Read Aloud tap")
        XCTAssertEqual(manager.pendingSpeechCount, 0)
    }

    /// While a Read Aloud is playing, a reply that arrives waits for it.
    func testReplyArrivingDuringReadAloudWaits() {
        manager.speak(longText)
        manager.enqueue("Live reply")
        XCTAssertEqual(manager.currentUtterance?.speechString, longText)
        XCTAssertEqual(manager.pendingSpeechCount, 1)
    }

    func testStopDiscardsTheQueueAndLeavesItUsable() {
        manager.enqueue(longText)
        manager.enqueue("Second reply")

        manager.stop()
        XCTAssertEqual(manager.pendingSpeechCount, 0)
        XCTAssertNil(manager.currentUtterance)

        // Not wedged: the next reply starts straight away, even before the
        // synthesizer has reported the cancel.
        manager.enqueue("After stop")
        XCTAssertEqual(manager.currentUtterance?.speechString, "After stop")
        XCTAssertEqual(manager.pendingSpeechCount, 0)
    }

    func testSwitchingSessionDropsRepliesQueuedForTheOldOne() {
        let sessionA = UUID()
        let sessionB = UUID()
        activeSession.setActiveSession(sessionA)
        drainMain()

        manager.enqueue(longText, sessionId: sessionA)
        manager.enqueue("A second", sessionId: sessionA)
        manager.enqueue("A third", sessionId: sessionA)
        XCTAssertEqual(manager.pendingSpeechCount, 2)

        activeSession.setActiveSession(sessionB)
        drainMain()

        XCTAssertEqual(manager.pendingSpeechCount, 0)
        XCTAssertNil(manager.currentUtterance)
    }

    /// Opening a sheet can briefly clear the active session; that must not
    /// throw away the replies waiting to be read.
    func testTransientNilActiveSessionKeepsTheQueue() {
        let sessionA = UUID()
        activeSession.setActiveSession(sessionA)
        drainMain()

        manager.enqueue(longText, sessionId: sessionA)
        manager.enqueue("A second", sessionId: sessionA)

        activeSession.clearActiveSession()
        drainMain()

        XCTAssertEqual(manager.pendingSpeechCount, 1)
    }

    func testReplyDroppedWhileRecordingDoesNotWedgeTheQueue() {
        manager.isRecordingActive = true
        manager.enqueue("Spoken over the mic")
        XCTAssertNil(manager.currentUtterance, "recording drops the request, as speak does")

        manager.isRecordingActive = false
        manager.enqueue("After recording")
        XCTAssertEqual(manager.currentUtterance?.speechString, "After recording")
    }

    // MARK: - With the real synthesizer

    /// End to end: three replies queued at once are each read to the end, in
    /// order, and `isSpeaking` stays true from the first to the last — no
    /// stop-and-start between replies for the headset state machine or the
    /// macOS output router to react to.
    func testQueuedRepliesAreEachReadInFullWithoutASpeakingGap() {
        var speakingValues: [Bool] = []
        manager.$isSpeaking
            .sink { speakingValues.append($0) }
            .store(in: &cancellables)

        manager.enqueue("One.")
        manager.enqueue("Two.")
        manager.enqueue("Three.")

        let drained = expectation(description: "queue drained")
        var poll: Timer?
        poll = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if self.manager.utterancesFinished == 3 && !self.manager.isSpeaking {
                poll?.invalidate()
                drained.fulfill()
            }
        }
        wait(for: [drained], timeout: 30)

        XCTAssertEqual(manager.utterancesFinished, 3, "each reply finished on its own, none was cut off")
        XCTAssertEqual(manager.pendingSpeechCount, 0)

        let afterFirstStart = speakingValues.drop { !$0 }
        XCTAssertFalse(afterFirstStart.isEmpty, "speech started")
        XCTAssertEqual(afterFirstStart.filter { !$0 }.count, 1,
                       "isSpeaking drops exactly once, after the last reply: \(speakingValues)")
        XCTAssertEqual(afterFirstStart.last, false)
    }
}
