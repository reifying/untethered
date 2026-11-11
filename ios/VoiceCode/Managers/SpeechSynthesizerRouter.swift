// SpeechSynthesizerRouter.swift
// Stands in for AVSpeechSynthesizer inside VoiceOutputManager, so a neural voice
// (Kokoro, on iOS) can read an utterance, with Apple's voice as the fallback.
// Design: docs/design/kokoro-neural-voice.md

import Foundation
import AVFoundation

/// What a neural engine reports about one text it is reading. Always delivered on the
/// main queue, never synchronously from inside `startSpeaking`.
enum NeuralSpeechEvent: Equatable {
    /// The first audio began playing.
    case started
    /// Every chunk was played to the end.
    case finished
    /// The engine gave up. `remainingText` is what it had not finished playing (the whole
    /// text if nothing played); the router reads it with Apple's voice.
    case failed(remainingText: String, reason: String)
}

/// One text being read by a neural engine.
protocol NeuralSpeechPlayback: AnyObject {
    func pause()
    func resume()
    /// Stop now. No event is delivered after this returns.
    func cancel()
}

/// An engine that can read text in place of AVSpeechSynthesizer.
protocol NeuralSpeechEngine: AnyObject {
    /// Whether this engine should read the next utterance: selected in Settings, loaded,
    /// and not turned off. Read on the main queue.
    var isReadyToSpeak: Bool { get }

    /// Start reading `text`. `events` runs on the main queue until `.finished` or
    /// `.failed`, and never after `cancel()`.
    func startSpeaking(_ text: String, rate: Float, events: @escaping (NeuralSpeechEvent) -> Void) -> NeuralSpeechPlayback
}

/// The subset of `AVSpeechSynthesizer` that `VoiceOutputManager` uses, routed per utterance
/// to a neural engine or to Apple's synthesizer.
///
/// Whichever engine reads it, the delegate hears `didStart`, `didFinish` and `didCancel` for
/// the **same `AVSpeechUtterance` object** it passed to `speak`. `VoiceOutputManager` keys its
/// queue, generation tags and session tags on that identity, so none of that logic needs to
/// know which voice spoke. When the neural engine fails partway, the router reads the unread
/// remainder with Apple's voice (a stand-in utterance with the original's voice and rate) and
/// still reports it as the original: one start, then one finish or cancel.
///
/// All calls are made on the main queue, as `VoiceOutputManager` already does.
final class SpeechSynthesizerRouter: NSObject, AVSpeechSynthesizerDelegate {
    weak var delegate: AVSpeechSynthesizerDelegate?

    /// When true, the next `speak` uses Apple's voice whatever the setting. That `speak`
    /// clears it. Used by the Apple voice preview in Settings.
    var forceAppleVoiceForNextUtterance = false

    private let apple: AVSpeechSynthesizer
    private let neuralEngine: NeuralSpeechEngine?

    private struct NeuralRead {
        let utterance: AVSpeechUtterance
        let playback: NeuralSpeechPlayback
        var startReported: Bool
    }

    /// The utterance the neural engine is reading, if any. Main queue only.
    private var neuralRead: NeuralRead?

    private struct StandIn {
        let original: AVSpeechUtterance
        var startReported: Bool
    }

    /// Apple utterances reading the remainder of a neural one, keyed by the stand-in.
    /// Guarded by `lock` because AVSpeechSynthesizer's delegate thread is not documented.
    private var standIns: [ObjectIdentifier: StandIn] = [:]
    private let lock = NSLock()

    /// How many utterances the neural engine started reading, and how many it handed to
    /// Apple's voice after failing. For tests and logs.
    private(set) var neuralReadsStarted = 0
    private(set) var neuralFallbacks = 0

    init(neuralEngine: NeuralSpeechEngine? = SpeechSynthesizerRouter.defaultNeuralEngine,
         appleSynthesizer: AVSpeechSynthesizer = AVSpeechSynthesizer()) {
        self.neuralEngine = neuralEngine
        self.apple = appleSynthesizer
        super.init()
        apple.delegate = self
    }

    /// Kokoro on iOS; none on macOS, where the app keeps Apple's voice.
    static var defaultNeuralEngine: NeuralSpeechEngine? {
        #if os(iOS) && canImport(FluidAudio)
        return KokoroSpeechEngine.shared
        #else
        return nil
        #endif
    }

    /// True while the neural engine holds an utterance (accurate the instant `speak`
    /// returns), or while Apple's synthesizer reports speaking (which lags `speak`).
    var isSpeaking: Bool { neuralRead != nil || apple.isSpeaking }

    /// True while the neural engine holds an utterance.
    var isReadingWithNeuralVoice: Bool { neuralRead != nil }

    // MARK: - AVSpeechSynthesizer surface

    func speak(_ utterance: AVSpeechUtterance) {
        let forceApple = forceAppleVoiceForNextUtterance
        forceAppleVoiceForNextUtterance = false

        // A neural read never waits behind: whatever replaces it is what the caller wants
        // now. VoiceOutputManager stops before every speak; this covers any caller that doesn't.
        cancelNeuralRead()

        guard !forceApple, let engine = neuralEngine, engine.isReadyToSpeak else {
            apple.speak(utterance)
            return
        }

        // Apple's synthesizer may hold an utterance whose start is still lagging
        // (`isSpeaking` reads false for tens of milliseconds after `speak`). It must not
        // play over this one, so stop it unconditionally; when idle this does nothing.
        apple.stopSpeaking(at: .immediate)

        neuralReadsStarted += 1
        let playback = engine.startSpeaking(utterance.speechString, rate: utterance.rate) { [weak self] event in
            self?.handle(event, for: utterance)
        }
        neuralRead = NeuralRead(utterance: utterance, playback: playback, startReported: false)
        LogManager.shared.log("🔊 Neural voice reading \(utterance.speechString.count) chars", category: "VoiceOutput")
    }

    @discardableResult
    func stopSpeaking(at boundary: AVSpeechBoundary) -> Bool {
        let stoppedNeural = cancelNeuralRead()
        let stoppedApple = apple.stopSpeaking(at: boundary)
        return stoppedNeural || stoppedApple
    }

    @discardableResult
    func pauseSpeaking(at boundary: AVSpeechBoundary) -> Bool {
        if let read = neuralRead {
            read.playback.pause()
            return true
        }
        return apple.pauseSpeaking(at: boundary)
    }

    @discardableResult
    func continueSpeaking() -> Bool {
        if let read = neuralRead {
            read.playback.resume()
            return true
        }
        return apple.continueSpeaking()
    }

    // MARK: - Neural events

    private func handle(_ event: NeuralSpeechEvent, for utterance: AVSpeechUtterance) {
        // Events of a read that was cancelled or replaced are stale.
        guard let read = neuralRead, read.utterance === utterance else { return }
        switch event {
        case .started:
            guard !read.startReported else { return }
            neuralRead?.startReported = true
            delegate?.speechSynthesizer?(apple, didStart: utterance)
        case .finished:
            neuralRead = nil
            delegate?.speechSynthesizer?(apple, didFinish: utterance)
        case .failed(let remainingText, let reason):
            neuralRead = nil
            neuralFallbacks += 1
            let remaining = remainingText.trimmingCharacters(in: .whitespacesAndNewlines)
            LogManager.shared.log("⚠️ Neural voice failed (\(reason)); Apple voice reads the remaining \(remaining.count) chars", category: "VoiceOutput")
            if remaining.isEmpty {
                delegate?.speechSynthesizer?(apple, didFinish: utterance)
            } else {
                readWithApple(remaining, standingInFor: utterance, startReported: read.startReported)
            }
        }
    }

    private func readWithApple(_ text: String, standingInFor original: AVSpeechUtterance, startReported: Bool) {
        let standIn = AVSpeechUtterance(string: text)
        standIn.voice = original.voice
        standIn.rate = original.rate
        standIn.pitchMultiplier = original.pitchMultiplier
        standIn.volume = original.volume
        lock.lock()
        standIns[ObjectIdentifier(standIn)] = StandIn(original: original, startReported: startReported)
        lock.unlock()
        apple.speak(standIn)
    }

    /// Cancel the neural read, if any, and report `didCancel` for it on a later main-queue
    /// turn, as AVSpeechSynthesizer does after `stopSpeaking`.
    @discardableResult
    private func cancelNeuralRead() -> Bool {
        guard let read = neuralRead else { return false }
        neuralRead = nil
        read.playback.cancel()
        let utterance = read.utterance
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.speechSynthesizer?(self.apple, didCancel: utterance)
        }
        return true
    }

    // MARK: - AVSpeechSynthesizerDelegate (Apple's synthesizer)

    /// The utterance to report for an Apple callback: the original for a stand-in,
    /// otherwise the utterance itself.
    private func reported(for utterance: AVSpeechUtterance, removing: Bool) -> AVSpeechUtterance {
        lock.lock()
        defer { lock.unlock() }
        let key = ObjectIdentifier(utterance)
        guard let standIn = standIns[key] else { return utterance }
        if removing { standIns[key] = nil }
        return standIn.original
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        lock.lock()
        let key = ObjectIdentifier(utterance)
        var original: AVSpeechUtterance? = nil
        var alreadyReported = false
        if let standIn = standIns[key] {
            original = standIn.original
            alreadyReported = standIn.startReported
            standIns[key]?.startReported = true
        }
        lock.unlock()
        // The neural engine already reported the start of the utterance this stand-in finishes.
        if alreadyReported { return }
        delegate?.speechSynthesizer?(synthesizer, didStart: original ?? utterance)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        delegate?.speechSynthesizer?(synthesizer, didFinish: reported(for: utterance, removing: true))
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        delegate?.speechSynthesizer?(synthesizer, didCancel: reported(for: utterance, removing: true))
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didPause utterance: AVSpeechUtterance) {
        delegate?.speechSynthesizer?(synthesizer, didPause: reported(for: utterance, removing: false))
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didContinue utterance: AVSpeechUtterance) {
        delegate?.speechSynthesizer?(synthesizer, didContinue: reported(for: utterance, removing: false))
    }
}
