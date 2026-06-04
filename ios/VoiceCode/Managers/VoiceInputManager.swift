// VoiceInputManager.swift
// Speech-to-text using Apple Speech Framework

import Foundation
import Speech
import AVFoundation
#if os(macOS)
import CoreAudio
#endif

class VoiceInputManager: NSObject, ObservableObject {
    @Published var isRecording = false
    @Published var transcribedText = ""
    @Published var authorizationStatus: SFSpeechRecognizerAuthorizationStatus = .notDetermined

    private var audioEngine: AVAudioEngine?
    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    /// Per-buffer capture diagnostics for the current recording, fed one sample per
    /// audio buffer from the engine tap. Two jobs: (1) snapshotted and logged on stop
    /// as the `capture summary firstAudio=…` line; (2) exposes a LIVE buffer count
    /// (`capturedBufferCount`) so the session executor's `captureGrace` timer can tell
    /// a dead input route (zero buffers) from a live one, and fires
    /// `onCaptureProducedAudio` the instant the first non-silent buffer arrives. These
    /// are the capture-readiness signals the headset session machine consumes (F3,
    /// `captureProducedAudio` / `captureStalled`). Internal (not private) so the live
    /// signals can be exercised in tests by seeding a monitor directly.
    var captureMonitor: AudioCaptureMonitor?

    /// Fired (on the main queue, at most once per capture) when the tap delivers its
    /// first non-silent buffer — the input route is live and producing audio. The
    /// session executor wires this to feed the reducer's `captureProducedAudio` event
    /// (F3 readiness), which cancels the capture-grace watchdog. The restart/grace
    /// DECISION lives in the session reducer, not here; this manager only emits the
    /// raw signal.
    var onCaptureProducedAudio: (() -> Void)?

    /// Live count of audio buffers the tap has delivered for the current capture (0
    /// when no capture is active). The session executor's `captureGrace` timer reads
    /// this: still zero when the grace window elapses ⇒ a dead route ⇒ it feeds the
    /// reducer's `captureStalled` event (→ `restartCapture`). A silent-but-present
    /// buffer still counts — that is the F2 warm-up dead zone (a live route), not the
    /// F3 zero-buffer dead route.
    var capturedBufferCount: Int { captureMonitor?.bufferCount ?? 0 }

    /// Reference to voice output manager for muting TTS during recording
    private weak var voiceOutputManager: VoiceOutputManager?

    /// True while THIS instance holds the recording-active gate raised on the
    /// shared VoiceOutputManager. Multiple VoiceInputManagers share one
    /// VoiceOutputManager (one per ConversationView, plus the macOS menu-bar
    /// instance), so deinit must release ONLY the gate this instance owns —
    /// clearing unconditionally would let a non-recording manager's deallocation
    /// wipe the gate another manager raised while actively recording, re-opening
    /// the TTS-into-open-mic feedback loop. Tracked in lockstep with
    /// `voiceOutputManager.isRecordingActive`. Internal (not private) so the
    /// ownership invariant can be exercised in tests, mirroring `isRecordingActive`.
    var didRaiseRecordingGate = false

    var onTranscriptionComplete: ((String) -> Void)?

    init(voiceOutputManager: VoiceOutputManager? = nil) {
        self.voiceOutputManager = voiceOutputManager
        super.init()
        speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        authorizationStatus = SFSpeechRecognizer.authorizationStatus()
    }

    private func log(_ message: String) {
        LogManager.shared.log(message, category: "VoiceInput")
    }

    // MARK: - Authorization

    func requestAuthorization(completion: @escaping (Bool) -> Void) {
        // Skip permission prompts during UI tests to prevent blocking automation
        if TestingEnvironment.isUITesting {
            completion(false)
            return
        }

        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                self.authorizationStatus = status
                completion(status == .authorized)
            }
        }
    }

    // MARK: - Recording

    /// Start recording.
    ///
    /// `onSessionReady` is called (on the main queue) immediately after the iOS
    /// audio session has been switched to `.playAndRecord` — before the audio
    /// engine starts. This lets the caller (e.g. `HeadsetRemoteCommandManager`)
    /// restart any audio-output keep-alive player in the correct session context,
    /// so it doesn't lose the Now Playing slot mid-recording.
    func startRecording(onSessionReady: (() -> Void)? = nil) {
        // Gate up FIRST — blocks any new speech (e.g. WebSocket-delivered
        // assistant messages auto-spoken by SessionSyncManager) from being
        // enqueued during the async window between here and audio session
        // configuration. Cleared in stopRecording() or on any error exit below.
        voiceOutputManager?.isRecordingActive = true
        didRaiseRecordingGate = true

        // Stop TTS first so the mic doesn't pick up speech output AND so the
        // synthesizer fully releases the audio session before we flip it to
        // .record. Without waiting, the first tap of the mic during TTS would
        // configure the session while AVSpeechSynthesizer was still tearing
        // down, and the audio engine would start without producing audio
        // buffers — the user had to tap stop and tap mic again to recover.
        if let voiceOutputManager = voiceOutputManager, voiceOutputManager.isSpeaking {
            voiceOutputManager.stop { [weak self] in
                self?.startRecordingAfterTTSStopped(onSessionReady: onSessionReady)
            }
        } else {
            voiceOutputManager?.stop()
            startRecordingAfterTTSStopped(onSessionReady: onSessionReady)
        }
    }

    private func startRecordingAfterTTSStopped(onSessionReady: (() -> Void)? = nil) {
        // Clear the recording-active gate on any early/error return below; only
        // the successful path keeps it raised. A single defer covers every
        // current and future error path automatically — no per-exit cleanup to
        // forget (a stuck-true flag would suppress all TTS until app relaunch).
        var recordingStarted = false
        defer {
            if !recordingStarted {
                voiceOutputManager?.isRecordingActive = false
                didRaiseRecordingGate = false
            }
        }

        // Check authorization
        guard authorizationStatus == .authorized else {
            log("Speech recognition not authorized")
            return
        }

        // Cancel any ongoing recognition
        if recognitionTask != nil {
            recognitionTask?.cancel()
            recognitionTask = nil
        }

        #if os(iOS)
        // iOS requires explicit audio session configuration.
        // .playAndRecord keeps the app in the Now Playing slot so MPRemoteCommandCenter
        // continues delivering AirPod/headset button events during recording.
        // .record alone loses playback capability and causes the second button press
        // to be routed to another app instead of ours.
        // .allowBluetooth enables the Bluetooth HFP mic (AirPods, headsets) for input.
        let audioSession = AVAudioSession.sharedInstance()
        let prevCategory = audioSession.category.rawValue
        let prevMode = audioSession.mode.rawValue
        do {
            // No .allowBluetooth — that forces AirPods into HFP mode which breaks
            // MPRemoteCommandCenter stem-press delivery. Device mic is used instead,
            // which gives better quality than HFP's 16kHz anyway.
            // No .mixWithOthers — it disqualifies us from being the Now Playing app,
            // which means iOS stops delivering AVRCP commands (AirPod stem clicks)
            // to our MPRemoteCommandCenter handlers.
            // .allowBluetoothA2DP: without this, .playAndRecord routes output to
            // the earpiece [Receiver] rather than AirPods. Our silence keep-alive
            // player must output to AirPods via A2DP or they route stem presses
            // elsewhere. Does NOT activate HFP — AirPods stay in A2DP mode.
            try audioSession.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothA2DP])
            try audioSession.setActive(true)
            log("VoiceInput: audio session → .playAndRecord/.default (was \(prevCategory)/\(prevMode)) route=\(audioSession.currentRoute.inputs.map(\.portName))")
            // Notify caller that session is in .playAndRecord context. Dispatched
            // async on main so it runs after this function returns and after
            // audioEngine.start() — but still in the .playAndRecord session.
            // HeadsetRemoteCommandManager uses this to reconstruct the silence player
            // in the new session context so it actually starts outputting audio.
            DispatchQueue.main.async { onSessionReady?() }
        } catch {
            log("❌ VoiceInput: failed to configure audio session: \(error.localizedDescription) (was \(prevCategory)/\(prevMode))")
            return
        }
        #endif
        // macOS: AVAudioEngine handles audio routing automatically

        // Create recognition request
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest = recognitionRequest else {
            log("Unable to create recognition request")
            return
        }

        recognitionRequest.shouldReportPartialResults = true

        // Build the engine + diagnostic tap + capture monitor and start the input
        // route. Shared with restartCapture() so the F3 recovery path stands up an
        // identical capture.
        guard startCaptureEngine() else { return }

        // Start recognition task
        recognitionTask = speechRecognizer?.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            guard let self = self else { return }

            if let result = result {
                let transcription = result.bestTranscription.formattedString
                DispatchQueue.main.async {
                    self.transcribedText = transcription
                }
            }

            if let error = error {
                self.log("VoiceInput: recognition ended with error: \(error.localizedDescription), isFinal=\(result?.isFinal ?? false)")
                self.stopRecording()
            } else if result?.isFinal == true {
                self.log("VoiceInput: recognition finalized, text='\(result?.bestTranscription.formattedString ?? "")'")
                self.stopRecording()
            }
        }

        recordingStarted = true
        log("VoiceInput: recording started — engine running, route=\(audioEngine?.inputNode.outputFormat(forBus: 0).sampleRate ?? 0)Hz")
        DispatchQueue.main.async {
            self.isRecording = true
            // Keep the gate consistent with isRecording: if stopRecording() ran
            // during the async stop-completion window and cleared the flag,
            // re-raise it so TTS stays suppressed while the mic is actually open.
            self.voiceOutputManager?.isRecordingActive = true
            self.didRaiseRecordingGate = true
            self.transcribedText = ""
        }
    }

    // MARK: - Capture engine

    /// Build a fresh `AVAudioEngine`, install the diagnostic tap, and start the input
    /// route, appending captured buffers to the current `recognitionRequest`. Shared by
    /// the initial start (`startRecordingAfterTTSStopped`) and the F3 restart
    /// (`restartCapture`). Returns false if there is no recognition request or the
    /// engine fails to start. (Re)creates the per-buffer capture monitor — the source of
    /// the live readiness signals (`capturedBufferCount`, `onCaptureProducedAudio`) and
    /// the `capture summary` line — and logs the input device + format so an HFP warm-up
    /// dead zone (silent buffers) can be told apart from a dead route (no buffers).
    @discardableResult
    private func startCaptureEngine() -> Bool {
        guard let recognitionRequest = recognitionRequest else {
            log("VoiceInput: cannot start capture — no recognition request")
            return false
        }

        let engine = AVAudioEngine()
        audioEngine = engine
        let inputNode = engine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        log("VoiceInput: input device=\(currentInputDescription()) format=\(Int(recordingFormat.sampleRate))Hz/\(recordingFormat.channelCount)ch")
        let monitor = AudioCaptureMonitor(startTime: CFAbsoluteTimeGetCurrent()) { [weak self] in
            self?.handleCaptureProducedAudio()
        }
        captureMonitor = monitor

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
            monitor.record(peak: VoiceInputManager.peakAmplitude(of: buffer),
                           frames: Int(buffer.frameLength),
                           at: CFAbsoluteTimeGetCurrent())
            recognitionRequest.append(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
            return true
        } catch {
            log("Failed to start audio engine: \(error)")
            return false
        }
    }

    /// F3 recovery entry point: tear down the (dead) capture engine and stand up a
    /// fresh one mid-recording WITHOUT touching session state — `isRecording`, the
    /// recording gate, and the in-flight `recognitionRequest`/`recognitionTask` are all
    /// left intact, so the restarted input route feeds the same recognition. The
    /// DECISION to call this (a `captureGrace` window that elapsed with zero buffers)
    /// lives in the session executor/reducer; this is just the mechanism.
    ///
    /// Idempotent and order-independent with `stopRecording()`: a no-op when no capture
    /// is active, and the fresh engine it builds is torn down by a later
    /// `stopRecording()` exactly like the original. The real teardown/rebuild is skipped
    /// under unit tests (the headless host has no live audio engine); the
    /// no-session-change contract is what the tests assert, and the hardware path is
    /// exercised by the executor integration task + manual checklist.
    ///
    /// "Capture active" is keyed on `captureMonitor`, NOT `recognitionRequest`:
    /// `stopRecording()` clears the monitor (and the engine stops) but deliberately
    /// leaves `recognitionRequest` in place, so a request-based guard would wrongly
    /// proceed after a recording ends — rebuilding a live engine that feeds an
    /// already-`endAudio()`'d request while not recording.
    func restartCapture() {
        guard captureMonitor != nil else {
            log("VoiceInput: restartCapture ignored — no active capture")
            return
        }
        log("VoiceInput: restartCapture — rebuilding capture engine (F3 recovery)")
        guard !TestingEnvironment.isUnitTesting else { return }
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil
        if !startCaptureEngine() {
            log("VoiceInput: restartCapture failed to start a fresh engine")
        }
    }

    /// Forward the monitor's first-non-silent-buffer signal to `onCaptureProducedAudio`
    /// on the main queue (the monitor fires it on the realtime audio thread; the session
    /// executor runs its reduce→apply on main). Internal so the forwarding contract is
    /// testable without a live audio route.
    func handleCaptureProducedAudio() {
        DispatchQueue.main.async { [weak self] in self?.onCaptureProducedAudio?() }
    }

    func stopRecording() {
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()

        // Observability: report what the mic actually delivered this recording
        // (buffers / silent% / peak / firstAudio). "buffers=0" or a "never"/late
        // firstAudio measures a dead route or a Bluetooth HFP/SCO warm-up dead zone
        // directly. Snapshot-then-clear keeps stopRecording() idempotent — a second
        // call finds no monitor and logs no duplicate summary. See findings F2/F3.
        if let stats = captureMonitor?.snapshot() {
            log("VoiceInput: capture summary — \(stats.summary)")
            captureMonitor = nil
        }

        #if os(iOS)
        // Do NOT deactivate the audio session here. HeadsetRemoteCommandManager re-asserts
        // .playAndRecord immediately after calling stopRecording(), and deactivating first
        // creates a race window where another app can seize the Now Playing slot. For
        // non-headset usage the session staying active in .playAndRecord is harmless.
        log("VoiceInput: stopRecording — session left active, category=\(AVAudioSession.sharedInstance().category.rawValue)")
        #endif

        log("VoiceInput: recording stopped")
        DispatchQueue.main.async {
            self.isRecording = false
            // Gate down — allow TTS to resume now that the mic is closed.
            self.voiceOutputManager?.isRecordingActive = false
            self.didRaiseRecordingGate = false
            // Note: onTranscriptionComplete callback is never set - handled by view layer instead
        }
    }

    // MARK: - Cleanup

    deinit {
        // Release the recording gate ONLY if this instance currently owns it.
        // stopRecording() clears it via an async main-queue hop, but only when
        // isRecording is true; if we are deallocated during the stop-completion
        // window — after startRecording() raised the gate but before isRecording
        // flipped true — neither path runs and the gate would stick true on the
        // (surviving) VoiceOutputManager, suppressing ALL TTS until app relaunch.
        // The ownership check is essential because multiple VoiceInputManagers
        // share one VoiceOutputManager: an unconditional clear here would let a
        // non-recording manager's deallocation wipe the gate another manager
        // raised while actively recording, re-opening the feedback loop.
        if didRaiseRecordingGate {
            voiceOutputManager?.isRecordingActive = false
        }
        if isRecording {
            stopRecording()
        }
    }
}

// MARK: - Capture observability

extension VoiceInputManager {
    /// Peak absolute sample value (0…1) across all channels of a float PCM buffer.
    /// Returns 0 for non-float buffers (the engine tap delivers float32). Used only
    /// for diagnostics, so an unconvertible format degrades to "silent" rather than
    /// failing — the device/format line still records what the route was.
    static func peakAmplitude(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else { return 0 }
        let frameLength = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        var peak: Float = 0
        for channel in 0..<channelCount {
            let samples = channelData[channel]
            for frame in 0..<frameLength {
                peak = max(peak, abs(samples[frame]))
            }
        }
        return peak
    }

    /// Human-readable identity of the mic actually feeding recording. This is the
    /// crux of the headset-capture work: it tells us whether we are on the headset's
    /// HFP mic or the built-in device mic (the latter is useless when the phone is
    /// mounted on a dash while the user wears the headset). Diagnostics only.
    func currentInputDescription() -> String {
        #if os(iOS)
        let inputs = AVAudioSession.sharedInstance().currentRoute.inputs
        let described = inputs.map { "\($0.portName) [\($0.portType.rawValue)]" }
        return described.isEmpty ? "none" : described.joined(separator: ", ")
        #elseif os(macOS)
        return VoiceInputManager.defaultInputDeviceDescription()
        #else
        return "unknown"
        #endif
    }
}

#if os(macOS)
extension VoiceInputManager {
    /// Name + UID of the system default input device (CoreAudio). `AVAudioEngine`
    /// on macOS captures from this device, with no per-app override — so this is the
    /// mic recording will use. Diagnostics only.
    static func defaultInputDeviceDescription() -> String {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        )
        guard status == noErr, deviceID != AudioDeviceID(0) else {
            return "unknown (default-input status \(status))"
        }
        let name = deviceStringProperty(deviceID, kAudioObjectPropertyName) ?? "?"
        let uid = deviceStringProperty(deviceID, kAudioDevicePropertyDeviceUID) ?? "?"
        return "\(name) [uid=\(uid)]"
    }

    private static func deviceStringProperty(
        _ device: AudioDeviceID, _ selector: AudioObjectPropertySelector
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer -> OSStatus in
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, pointer)
        }
        return status == noErr ? (value as String) : nil
    }
}
#endif

/// Pure, testable accumulator for mic-capture diagnostics and readiness. Fed one
/// sample per audio buffer; tracks whether the route is delivering buffers at all
/// (`bufferCount`), how many are silent, and how long until the first non-silent
/// buffer arrived. The "first audio" offset measures a Bluetooth HFP/SCO warm-up
/// dead zone directly; the buffer count distinguishes that live-but-silent dead zone
/// (F2) from a route that delivered NO buffers (F3). See findings F2/F3.
struct AudioCaptureStats: Equatable {
    /// Peak at/below this counts as silence (~ -46 dBFS). Speech peaks ~0.1–1.0;
    /// a true-silent HFP stream is ~0, so this cleanly separates the two.
    static let silenceThreshold: Float = 0.005

    private(set) var bufferCount = 0
    private(set) var silentBufferCount = 0
    private(set) var totalFrames = 0
    private(set) var peak: Float = 0
    /// Seconds from recording start to the first non-silent buffer; nil if none.
    private(set) var firstAudioOffset: TimeInterval?

    /// Accumulate one buffer. Returns true EXACTLY ONCE — on the buffer that is the
    /// first non-silent one — so a caller (the monitor) can emit a one-shot
    /// first-audio readiness signal without tracking the edge itself.
    @discardableResult
    mutating func record(peak bufferPeak: Float, frames: Int, offset: TimeInterval) -> Bool {
        bufferCount += 1
        totalFrames += frames
        peak = max(peak, bufferPeak)
        if bufferPeak <= Self.silenceThreshold {
            silentBufferCount += 1
            return false
        }
        if firstAudioOffset == nil {
            firstAudioOffset = offset
            return true
        }
        return false
    }

    var summary: String {
        let pct = bufferCount == 0 ? 0 : Int((Double(silentBufferCount) / Double(bufferCount)) * 100)
        let firstAudio = firstAudioOffset.map { String(format: "%.2fs", $0) } ?? "never"
        let peakStr = String(format: "%.4f", peak)
        return "buffers=\(bufferCount) frames=\(totalFrames) silent=\(pct)% peak=\(peakStr) firstAudio=\(firstAudio)"
    }
}

/// Thread-safe wrapper around `AudioCaptureStats`, fed from the realtime audio tap
/// and read both live (the executor's `captureGrace` timer checks `bufferCount`) and
/// at stop (`snapshot()` for the summary). The lock is held only for the trivial
/// accumulate/read, acceptable on the audio thread. `onFirstAudio` fires at most once,
/// the instant the first non-silent buffer arrives — the live readiness signal.
final class AudioCaptureMonitor {
    private let lock = NSLock()
    private var stats = AudioCaptureStats()
    private let startTime: TimeInterval
    /// Called once, on the first non-silent buffer, on the realtime audio thread
    /// (outside the lock). The owner hops to the main queue before acting.
    private let onFirstAudio: (() -> Void)?

    init(startTime: TimeInterval, onFirstAudio: (() -> Void)? = nil) {
        self.startTime = startTime
        self.onFirstAudio = onFirstAudio
    }

    func record(peak: Float, frames: Int, at now: TimeInterval) {
        lock.lock()
        let wasFirstAudio = stats.record(peak: peak, frames: frames, offset: now - startTime)
        lock.unlock()
        // Fire outside the lock: the callback may hop queues / touch the manager.
        if wasFirstAudio { onFirstAudio?() }
    }

    /// Live count of buffers delivered so far (the dead-route signal for F3).
    var bufferCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return stats.bufferCount
    }

    func snapshot() -> AudioCaptureStats {
        lock.lock()
        defer { lock.unlock() }
        return stats
    }
}
