// SpeechSynthesizerRouterTests.swift
// The router that lets Kokoro read an utterance in AVSpeechSynthesizer's place.
// Design: docs/design/kokoro-neural-voice.md

import XCTest
import AVFoundation
@testable import VoiceCode

private final class FakePlayback: NeuralSpeechPlayback {
    var paused = 0, resumed = 0, cancelled = 0
    func pause() { paused += 1 }
    func resume() { resumed += 1 }
    func cancel() { cancelled += 1 }
}

private final class FakeNeuralEngine: NeuralSpeechEngine {
    var isReadyToSpeak = true
    var texts: [String] = []
    var rates: [Float] = []
    var playbacks: [FakePlayback] = []
    var sinks: [(NeuralSpeechEvent) -> Void] = []

    func startSpeaking(_ text: String, rate: Float, events: @escaping (NeuralSpeechEvent) -> Void) -> NeuralSpeechPlayback {
        texts.append(text)
        rates.append(rate)
        sinks.append(events)
        let playback = FakePlayback()
        playbacks.append(playback)
        return playback
    }

    /// Deliver an event for the most recent read, as the real engine does: on the main queue.
    func emit(_ event: NeuralSpeechEvent, read index: Int? = nil) {
        sinks[index ?? sinks.count - 1](event)
    }
}

/// Apple's synthesizer, minus the audio: records what it is asked to speak, and the test drives
/// its callbacks. (A fresh simulator may have no voices, and then real speech "finishes" at once.)
private final class FakeAppleSynthesizer: AVSpeechSynthesizer {
    var spoken: [AVSpeechUtterance] = []
    var stops = 0
    private var current: AVSpeechUtterance?

    override func speak(_ utterance: AVSpeechUtterance) {
        spoken.append(utterance)
        current = utterance
    }

    override func stopSpeaking(at boundary: AVSpeechBoundary) -> Bool {
        stops += 1
        guard let utterance = current else { return false }
        current = nil
        delegate?.speechSynthesizer?(self, didCancel: utterance)
        return true
    }

    override var isSpeaking: Bool { current != nil }

    func reportStart() { delegate?.speechSynthesizer?(self, didStart: current!) }

    func reportFinish() {
        let utterance = current!
        current = nil
        delegate?.speechSynthesizer?(self, didFinish: utterance)
    }
}

private final class RecordingDelegate: NSObject, AVSpeechSynthesizerDelegate {
    enum Kind: Equatable { case start, finish, cancel }
    var events: [(Kind, AVSpeechUtterance)] = []
    var onEvent: ((Kind, AVSpeechUtterance) -> Void)?

    private func record(_ kind: Kind, _ utterance: AVSpeechUtterance) {
        // AVSpeechSynthesizer's callback thread is not documented; record on main.
        let work = { self.events.append((kind, utterance)); self.onEvent?(kind, utterance) }
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }

    func speechSynthesizer(_ s: AVSpeechSynthesizer, didStart u: AVSpeechUtterance) { record(.start, u) }
    func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) { record(.finish, u) }
    func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) { record(.cancel, u) }

    func kinds(for utterance: AVSpeechUtterance) -> [Kind] {
        events.filter { $0.1 === utterance }.map(\.0)
    }
}

final class SpeechSynthesizerRouterTests: XCTestCase {
    private var engine: FakeNeuralEngine!
    private var apple: FakeAppleSynthesizer!
    private var delegate: RecordingDelegate!
    private var router: SpeechSynthesizerRouter!

    override func setUp() {
        super.setUp()
        engine = FakeNeuralEngine()
        apple = FakeAppleSynthesizer()
        delegate = RecordingDelegate()
        router = SpeechSynthesizerRouter(neuralEngine: engine, appleSynthesizer: apple)
        router.delegate = delegate
    }

    override func tearDown() {
        router.stopSpeaking(at: .immediate)
        router = nil
        delegate = nil
        apple = nil
        engine = nil
        super.tearDown()
    }

    private func drainMain() {
        let exp = expectation(description: "main queue drained")
        DispatchQueue.main.async { exp.fulfill() }
        wait(for: [exp], timeout: 1)
    }

    private func waitFor(_ kind: RecordingDelegate.Kind, of utterance: AVSpeechUtterance, timeout: TimeInterval = 15) {
        if delegate.kinds(for: utterance).contains(kind) { return }
        let exp = expectation(description: "\(kind)")
        delegate.onEvent = { k, u in if k == kind, u === utterance { exp.fulfill() } }
        wait(for: [exp], timeout: timeout)
        delegate.onEvent = nil
    }

    // MARK: - Choosing the engine

    func testNeuralEngineReadsWhenReady() {
        let utterance = AVSpeechUtterance(string: "Hello there.")
        utterance.rate = 0.5
        router.speak(utterance)

        XCTAssertEqual(engine.texts, ["Hello there."])
        XCTAssertEqual(engine.rates, [0.5])
        XCTAssertTrue(router.isSpeaking, "a neural read counts as speaking the instant speak returns")
        XCTAssertTrue(router.isReadingWithNeuralVoice)
    }

    func testAppleReadsWhenNeuralNotReady() {
        engine.isReadyToSpeak = false
        let utterance = AVSpeechUtterance(string: "Hi.")
        router.speak(utterance)

        XCTAssertTrue(engine.texts.isEmpty)
        XCTAssertFalse(router.isReadingWithNeuralVoice)
        XCTAssertTrue(apple.spoken.last === utterance, "Apple gets the caller's own utterance")
        apple.reportStart()
        apple.reportFinish()
        XCTAssertEqual(delegate.kinds(for: utterance), [.start, .finish])
    }

    func testNeuralReadStopsAnAppleUtteranceStillStarting() {
        engine.isReadyToSpeak = false
        let apple1 = AVSpeechUtterance(string: "Apple.")
        router.speak(apple1)
        engine.isReadyToSpeak = true
        let neural = AVSpeechUtterance(string: "Kokoro.")
        router.speak(neural)

        XCTAssertEqual(delegate.kinds(for: apple1), [.cancel], "the two voices must never overlap")
        XCTAssertEqual(engine.texts, ["Kokoro."])
    }

    func testForceAppleBypassesNeuralForOneUtteranceOnly() {
        router.forceAppleVoiceForNextUtterance = true
        let preview = AVSpeechUtterance(string: "Hi.")
        router.speak(preview)
        XCTAssertTrue(engine.texts.isEmpty, "the Apple voice preview must not be read by Kokoro")
        XCTAssertFalse(router.forceAppleVoiceForNextUtterance, "the override applies to one utterance")

        router.stopSpeaking(at: .immediate)
        let reply = AVSpeechUtterance(string: "Next.")
        router.speak(reply)
        XCTAssertEqual(engine.texts, ["Next."])
    }

    // MARK: - Callbacks report the original utterance

    func testNeuralEventsAreReportedForTheOriginalUtterance() {
        let utterance = AVSpeechUtterance(string: "One. Two.")
        router.speak(utterance)
        engine.emit(.started)
        engine.emit(.started) // a duplicate start is not reported twice
        engine.emit(.finished)

        XCTAssertEqual(delegate.kinds(for: utterance), [.start, .finish])
        XCTAssertFalse(router.isSpeaking)
    }

    func testStopCancelsNeuralReadAndReportsCancelLater() {
        let utterance = AVSpeechUtterance(string: "Long reply.")
        router.speak(utterance)
        engine.emit(.started)

        XCTAssertTrue(router.stopSpeaking(at: .immediate))
        XCTAssertEqual(engine.playbacks[0].cancelled, 1)
        XCTAssertFalse(router.isSpeaking)
        XCTAssertEqual(delegate.kinds(for: utterance), [.start], "didCancel arrives on a later main-queue turn, as with AVSpeechSynthesizer")

        drainMain()
        XCTAssertEqual(delegate.kinds(for: utterance), [.start, .cancel])
    }

    func testEventsAfterCancelAreIgnored() {
        let utterance = AVSpeechUtterance(string: "Reply.")
        router.speak(utterance)
        router.stopSpeaking(at: .immediate)
        engine.emit(.finished)
        drainMain()
        XCTAssertEqual(delegate.kinds(for: utterance), [.cancel])
    }

    func testNewUtterancePreemptsNeuralRead() {
        let first = AVSpeechUtterance(string: "First.")
        let second = AVSpeechUtterance(string: "Second.")
        router.speak(first)
        engine.emit(.started)
        router.speak(second)

        XCTAssertEqual(engine.playbacks[0].cancelled, 1)
        XCTAssertEqual(engine.texts, ["First.", "Second."])
        engine.emit(.finished, read: 0) // stale: belongs to the cancelled read
        drainMain()
        XCTAssertEqual(delegate.kinds(for: first), [.start, .cancel])
        XCTAssertEqual(delegate.kinds(for: second), [])
    }

    func testPauseAndResumeGoToTheNeuralRead() {
        router.speak(AVSpeechUtterance(string: "Reply."))
        XCTAssertTrue(router.pauseSpeaking(at: .word))
        XCTAssertTrue(router.continueSpeaking())
        XCTAssertEqual(engine.playbacks[0].paused, 1)
        XCTAssertEqual(engine.playbacks[0].resumed, 1)
    }

    // MARK: - Fallback to Apple's voice

    func testFailureBeforeAudioFallsBackToAppleForTheWholeText() {
        let utterance = AVSpeechUtterance(string: "Hi.")
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = 0.45
        router.speak(utterance)
        engine.emit(.failed(remainingText: "Hi.", reason: "first audio not ready"))

        XCTAssertEqual(router.neuralFallbacks, 1)
        let standIn = try! XCTUnwrap(apple.spoken.last)
        XCTAssertEqual(standIn.speechString, "Hi.")
        XCTAssertEqual(standIn.voice?.identifier, utterance.voice?.identifier, "the resolved Apple voice is kept")
        XCTAssertEqual(standIn.rate, 0.45)
        apple.reportStart()
        apple.reportFinish()
        XCTAssertEqual(delegate.kinds(for: utterance), [.start, .finish],
                       "Apple's stand-in is reported as the original utterance")
        XCTAssertTrue(delegate.kinds(for: standIn).isEmpty)
    }

    func testFailureMidwayReadsTheRemainderWithoutASecondStart() {
        let utterance = AVSpeechUtterance(string: "First part. Rest.")
        router.speak(utterance)
        engine.emit(.started)
        engine.emit(.failed(remainingText: "Rest.", reason: "synthesis failed"))

        XCTAssertEqual(apple.spoken.last?.speechString, "Rest.")
        apple.reportStart()
        apple.reportFinish()
        XCTAssertEqual(delegate.kinds(for: utterance), [.start, .finish])
    }

    func testFailureWithNothingLeftFinishes() {
        let utterance = AVSpeechUtterance(string: "Done.")
        router.speak(utterance)
        engine.emit(.started)
        engine.emit(.failed(remainingText: "  \n", reason: "player error"))
        XCTAssertEqual(delegate.kinds(for: utterance), [.start, .finish])
        XCTAssertTrue(apple.spoken.isEmpty)
    }

    func testStopDuringFallbackCancelsTheOriginal() {
        let utterance = AVSpeechUtterance(string: "Reply.")
        router.speak(utterance)
        engine.emit(.failed(remainingText: "Reply.", reason: "synthesis failed"))
        apple.reportStart()

        XCTAssertTrue(router.isSpeaking)
        XCTAssertTrue(router.stopSpeaking(at: .immediate))
        XCTAssertEqual(delegate.kinds(for: utterance), [.start, .cancel])
    }

    // MARK: - Real synthesizer

    /// The router with Apple's real synthesizer, end to end.
    func testRealAppleSynthesizerReportsTheCallersUtterance() {
        let real = SpeechSynthesizerRouter(neuralEngine: nil)
        real.delegate = delegate
        let utterance = AVSpeechUtterance(string: "Hi.")
        real.speak(utterance)
        waitFor(.finish, of: utterance)
        XCTAssertEqual(delegate.kinds(for: utterance), [.start, .finish])
    }
}
