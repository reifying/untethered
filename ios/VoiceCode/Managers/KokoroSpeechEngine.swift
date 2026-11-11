// KokoroSpeechEngine.swift
// Kokoro-82M (voice af_heart) on the iPhone, through FluidAudio's Core ML pipeline.
// Design: docs/design/kokoro-neural-voice.md

#if os(iOS) && canImport(FluidAudio)
import Foundation
import AVFoundation
import Network
import UIKit
import FluidAudio

/// Owns the Kokoro model: downloads it once (over Wi-Fi unless asked), loads and warms it,
/// unloads it on a memory warning, and reads text for `SpeechSynthesizerRouter`.
///
/// Main-queue class, like `VoiceOutputManager`; model calls run on FluidAudio's actor.
final class KokoroSpeechEngine: ObservableObject, NeuralSpeechEngine {
    static let shared = KokoroSpeechEngine()

    /// Voice E of the listening test.
    static let voice = "af_heart"

    enum State: Equatable {
        /// Not loaded: Apple's voice is selected, or the model was unloaded.
        case idle
        /// The model has never been downloaded and the network is cellular or constrained.
        case waitingForWiFi
        case downloading
        case loading
        case ready
        case failed(String)
        /// The app died mid-synthesis twice in a row (see `NeuralVoiceCrashGuard`).
        case turnedOffAfterCrashes
    }

    @Published private(set) var state: State = .idle

    let crashGuard = NeuralVoiceCrashGuard()

    /// The loaded model, while `state == .ready`.
    private(set) var manager: KokoroAneManager?
    private var loadGeneration = 0
    private var started = false
    private var activeReads = 0
    private var observers: [NSObjectProtocol] = []
    private var pathMonitor: NWPathMonitor?
    /// Unknown until the first path update, and treated as expensive until then.
    private var networkIsExpensive = true

    /// Set when a read failed or timed out while the app was in the background (the Neural
    /// Engine needs an entitlement there on iOS 27). Until the app is next active, Apple's voice
    /// reads, rather than every reply waiting out a timeout first.
    private var unavailableInBackground = false

    /// Seconds the last load and warm-up took, for logs and the self-test.
    private(set) var lastLoadSeconds: Double?
    private(set) var lastWarmUpSeconds: Double?

    private static let downloadedKey = "kokoroModelDownloaded"
    private var modelDownloaded: Bool {
        get { UserDefaults.standard.bool(forKey: Self.downloadedKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.downloadedKey) }
    }

    var isReadyToSpeak: Bool {
        guard state == .ready, manager != nil, NeuralVoiceSettings.isKokoroSelected() else { return false }
        if unavailableInBackground, UIApplication.shared.applicationState != .active { return false }
        return true
    }

    // MARK: - Lifecycle

    /// Call once at launch. Does nothing under unit or UI tests and in previews.
    func start() {
        guard !started else { return }
        guard !TestingEnvironment.isUnitTesting, !TestingEnvironment.isUITesting, !TestingEnvironment.isPreview else { return }
        started = true
        if crashGuard.recordLaunch() {
            log("⚠️ The previous run quit during Kokoro synthesis (\(crashGuard.consecutiveCrashes) in a row, \(crashGuard.totalCrashes) in all)")
        }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.unavailableInBackground = false
            self?.prepareIfNeeded()
        })
        observers.append(center.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [weak self] _ in
            self?.unloadIfIdle(reason: "memory warning")
        })
        startNetworkMonitor()
        prepareIfNeeded()
        KokoroSelfTest.runIfRequested(engine: self)
    }

    /// The Settings choice changed.
    func selectionChanged() {
        if NeuralVoiceSettings.isKokoroSelected() {
            prepareIfNeeded()
        } else {
            unload(reason: "Apple voice selected")
            state = .idle
        }
    }

    /// "Download now" or "Retry" in Settings: download even on cellular.
    func downloadNow() {
        prepareIfNeeded(userInitiated: true)
    }

    /// "Turn back on" in Settings, after the crash guard turned Kokoro off.
    func turnBackOn() {
        crashGuard.reset()
        state = .idle
        prepareIfNeeded(userInitiated: true)
    }

    func prepareIfNeeded(userInitiated: Bool = false) {
        guard started else { return }
        guard NeuralVoiceSettings.isKokoroSelected() else { state = .idle; return }
        switch state {
        case .ready, .downloading, .loading:
            return
        case .idle, .waitingForWiFi, .failed, .turnedOffAfterCrashes:
            break
        }
        if crashGuard.isTrippedOff {
            state = .turnedOffAfterCrashes
            return
        }
        let downloading = !modelDownloaded
        if downloading, networkIsExpensive, !userInitiated {
            state = .waitingForWiFi
            return
        }
        state = downloading ? .downloading : .loading
        loadGeneration += 1
        let generation = loadGeneration
        log(downloading ? "Downloading and loading the Kokoro model" : "Loading the Kokoro model")
        Task.detached(priority: .utility) { [weak self] in
            await self?.load(generation: generation, downloading: downloading)
        }
    }

    private func load(generation: Int, downloading: Bool) async {
        let began = Date()
        let manager = KokoroAneManager(defaultVoice: Self.voice)
        // Loading from the cache runs the model graphs; a first download mostly waits on the network.
        var guarding = !downloading
        if guarding { crashGuard.synthesisWillStart() }
        do {
            try await manager.initialize(preloadVoices: [Self.voice])
            if guarding { crashGuard.synthesisDidEnd(succeeded: true) }
            let loaded = Date()
            await MainActor.run { self.modelDownloaded = true }
            Self.excludeModelsFromBackup()

            // The first prediction specializes the graphs for the Neural Engine (about a second).
            // Pay it now, not on the first reply.
            guarding = true
            crashGuard.synthesisWillStart()
            _ = try await manager.synthesizeDetailed(text: "Ready.", voice: Self.voice, speed: 1)
            crashGuard.synthesisDidEnd(succeeded: true)
            guarding = false
            let warmed = Date()

            let kept: Bool = await MainActor.run {
                guard generation == self.loadGeneration else { return false }
                self.manager = manager
                self.lastLoadSeconds = loaded.timeIntervalSince(began)
                self.lastWarmUpSeconds = warmed.timeIntervalSince(loaded)
                self.state = .ready
                self.log(String(format: "Kokoro ready: load %.1fs, warm-up %.2fs, footprint %.0f MB",
                                loaded.timeIntervalSince(began), warmed.timeIntervalSince(loaded), Self.memoryFootprintMB()))
                return true
            }
            if !kept { await manager.cleanup() }
        } catch {
            if guarding { crashGuard.synthesisDidEnd(succeeded: false) }
            await MainActor.run {
                guard generation == self.loadGeneration else { return }
                self.state = .failed(error.localizedDescription)
                self.log("❌ Kokoro failed to load: \(error.localizedDescription)")
            }
        }
    }

    private func unload(reason: String) {
        loadGeneration += 1
        guard let manager = manager else { return }
        self.manager = nil
        log("Unloading the Kokoro model (\(reason))")
        Task.detached { await manager.cleanup() }
    }

    private func unloadIfIdle(reason: String) {
        guard activeReads == 0, manager != nil else { return }
        unload(reason: reason)
        state = .idle
    }

    private func startNetworkMonitor() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let expensive = path.status != .satisfied || path.isExpensive || path.isConstrained
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.networkIsExpensive = expensive
                if !expensive, self.state == .waitingForWiFi { self.prepareIfNeeded() }
            }
        }
        monitor.start(queue: DispatchQueue(label: "dev.910labs.voice-code.kokoro.network"))
        pathMonitor = monitor
    }

    /// FluidAudio's cache folders under Application Support (`fluidaudio` for TTS models,
    /// `FluidAudio` for others), matched without regard to case.
    static func modelDirectories() -> [URL] {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
              let entries = try? FileManager.default.contentsOfDirectory(at: support, includingPropertiesForKeys: nil) else { return [] }
        return entries.filter { $0.lastPathComponent.lowercased() == "fluidaudio" }
    }

    /// Application Support is backed up to iCloud by default; the model is re-downloadable.
    private static func excludeModelsFromBackup() {
        for var url in modelDirectories() {
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? url.setResourceValues(values)
        }
    }

    // MARK: - NeuralSpeechEngine

    func startSpeaking(_ text: String, rate: Float, events: @escaping (NeuralSpeechEvent) -> Void) -> NeuralSpeechPlayback {
        let chunks = NeuralSpeechText.chunks(NeuralSpeechText.cleanMarkdown(text))
        activeReads += 1
        let playback = KokoroPlayback(
            manager: manager,
            voice: Self.voice,
            chunks: chunks,
            speed: NeuralSpeechText.speed(forRate: rate),
            crashGuard: crashGuard,
            events: events
        ) { [weak self] outcome in
            guard let self = self else { return }
            self.activeReads -= 1
            if case .failed = outcome, UIApplication.shared.applicationState != .active {
                self.unavailableInBackground = true
                self.log("Kokoro unavailable in the background; Apple's voice reads until the app is active")
            }
        }
        playback.start()
        return playback
    }

    // MARK: - Helpers

    fileprivate func log(_ message: String) {
        LogManager.shared.log(message, category: "Kokoro")
    }

    /// The memory the system charges this app for (what jetsam limits), in MB.
    static func memoryFootprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }
}

// MARK: - Playback

/// Reads one text: synthesizes its chunks in order as fast as the model goes, and plays each
/// with its own `AVAudioPlayer` as soon as the one before it ends.
///
/// `AVAudioPlayer` rather than `AVAudioEngine`: the engine resets and stops its players on route
/// changes, which headset `.playAndRecord` causes all the time. Main queue only.
final class KokoroPlayback: NSObject, NeuralSpeechPlayback, AVAudioPlayerDelegate {
    enum Outcome { case finished, failed, cancelled }

    static let firstAudioTimeout: TimeInterval = 6
    static let stallTimeout: TimeInterval = 10
    /// Player volume. 1 in normal use; the self-test plays silently.
    static var playerVolume: Float = 1

    private let manager: KokoroAneManager?
    private let voice: String
    private let chunks: [NeuralSpeechChunk]
    private let speed: Float
    private let crashGuard: NeuralVoiceCrashGuard
    private let events: (NeuralSpeechEvent) -> Void
    private var onEnd: ((Outcome) -> Void)?

    private var audio: [Int: Data] = [:]
    private var playIndex = 0
    private var player: AVAudioPlayer?
    private var synthesisTask: Task<Void, Never>?
    private var synthesisFailure: (index: Int, reason: String)?
    private var stallTimer: DispatchWorkItem?
    private var ended = false
    private var cancelled = false
    private var paused = false
    private var startReported = false
    private let began = Date()

    init(manager: KokoroAneManager?, voice: String, chunks: [NeuralSpeechChunk], speed: Float,
         crashGuard: NeuralVoiceCrashGuard, events: @escaping (NeuralSpeechEvent) -> Void,
         onEnd: @escaping (Outcome) -> Void) {
        self.manager = manager
        self.voice = voice
        self.chunks = chunks
        self.speed = speed
        self.crashGuard = crashGuard
        self.events = events
        self.onEnd = onEnd
    }

    func start() {
        guard let manager = manager else {
            fail(at: 0, reason: "model not loaded")
            return
        }
        guard !chunks.isEmpty else {
            end(.finished)
            return
        }
        armStallTimer(Self.firstAudioTimeout, reason: "first audio not ready in \(Int(Self.firstAudioTimeout))s")
        let chunks = self.chunks, voice = self.voice, speed = self.speed, crashGuard = self.crashGuard
        synthesisTask = Task.detached(priority: .userInitiated) { [weak self] in
            for (index, chunk) in chunks.enumerated() {
                if Task.isCancelled { return }
                let t0 = Date()
                crashGuard.synthesisWillStart()
                do {
                    let result = try await manager.synthesizeDetailed(text: chunk.text, voice: voice, speed: speed)
                    crashGuard.synthesisDidEnd(succeeded: true)
                    let wav = NeuralSpeechAudio.wav(samples: result.samples, sampleRate: result.sampleRate,
                                                    trailingSilence: chunk.pauseAfter)
                    let seconds = Date().timeIntervalSince(t0)
                    let audioSeconds = Double(result.samples.count) / Double(max(1, result.sampleRate))
                    DispatchQueue.main.async {
                        self?.chunkReady(index, wav, synthesisSeconds: seconds, audioSeconds: audioSeconds)
                    }
                } catch {
                    crashGuard.synthesisDidEnd(succeeded: false)
                    if Task.isCancelled { return }
                    let reason = "synthesis failed: \(error.localizedDescription)"
                    DispatchQueue.main.async { self?.synthesisFailed(at: index, reason: reason) }
                    return
                }
            }
        }
    }

    func pause() {
        guard !ended else { return }
        paused = true
        player?.pause()
        cancelStallTimer()
    }

    func resume() {
        guard !ended, paused else { return }
        paused = false
        if let player = player {
            player.play()
            reportStartIfNeeded()
        } else {
            armStallTimer(startReported ? Self.stallTimeout : Self.firstAudioTimeout, reason: "audio not ready after resume")
            playNext()
        }
    }

    func cancel() {
        guard !ended else { return }
        cancelled = true
        finish(.cancelled)
    }

    // MARK: - Internals

    private func chunkReady(_ index: Int, _ wav: Data, synthesisSeconds: Double, audioSeconds: Double) {
        guard !ended else { return }
        if index == 0 {
            LogManager.shared.log(String(format: "Kokoro first audio after %.2fs (%.2fs synthesizing %.1fs of audio, %d chunks)",
                                         Date().timeIntervalSince(began), synthesisSeconds, audioSeconds, chunks.count),
                                  category: "Kokoro")
        }
        audio[index] = wav
        if player == nil, index == playIndex { playNext() }
    }

    private func synthesisFailed(at index: Int, reason: String) {
        guard !ended else { return }
        // Chunks already synthesized still play; Apple's voice takes over from this one.
        synthesisFailure = (index, reason)
        if player == nil, index == playIndex { playNext() }
    }

    private func playNext() {
        guard !ended else { return }
        if playIndex >= chunks.count {
            end(.finished)
            return
        }
        if let failure = synthesisFailure, playIndex >= failure.index {
            fail(at: playIndex, reason: failure.reason)
            return
        }
        guard let wav = audio.removeValue(forKey: playIndex) else {
            // Not synthesized yet; chunkReady plays it. The first-audio timer is already running.
            if startReported, !paused { armStallTimer(Self.stallTimeout, reason: "chunk \(playIndex + 1) not ready in \(Int(Self.stallTimeout))s") }
            return
        }
        cancelStallTimer()
        do {
            let player = try AVAudioPlayer(data: wav, fileTypeHint: AVFileType.wav.rawValue)
            player.delegate = self
            player.volume = Self.playerVolume
            player.prepareToPlay()
            self.player = player
            if paused { return }
            guard player.play() else {
                fail(at: playIndex, reason: "the audio player would not start")
                return
            }
        } catch {
            fail(at: playIndex, reason: "the audio player failed: \(error.localizedDescription)")
            return
        }
        reportStartIfNeeded()
    }

    private func reportStartIfNeeded() {
        guard !startReported else { return }
        startReported = true
        emit(.started)
    }

    func audioPlayerDidFinishPlaying(_ finished: AVAudioPlayer, successfully flag: Bool) {
        onMain {
            guard finished === self.player, !self.ended else { return }
            self.player = nil
            guard flag else {
                self.fail(at: self.playIndex, reason: "playback stopped early")
                return
            }
            self.playIndex += 1
            self.playNext()
        }
    }

    func audioPlayerDecodeErrorDidOccur(_ failed: AVAudioPlayer, error: Error?) {
        onMain {
            guard failed === self.player, !self.ended else { return }
            self.fail(at: self.playIndex, reason: "audio decode error: \(error?.localizedDescription ?? "unknown")")
        }
    }

    private func fail(at index: Int, reason: String) {
        guard !ended else { return }
        let remaining = chunks.indices.contains(index)
            ? chunks[index...].map(\.text).joined(separator: "\n")
            : ""
        finish(.failed)
        emit(.failed(remainingText: remaining, reason: reason))
    }

    private func end(_ outcome: Outcome) {
        guard !ended else { return }
        finish(outcome)
        if outcome == .finished { emit(.finished) }
    }

    private func finish(_ outcome: Outcome) {
        ended = true
        synthesisTask?.cancel()
        synthesisTask = nil
        player?.delegate = nil
        player?.stop()
        player = nil
        cancelStallTimer()
        audio.removeAll()
        onEnd?(outcome)
        onEnd = nil
    }

    /// Always on a later main-queue turn, and never after `cancel()`.
    private func emit(_ event: NeuralSpeechEvent) {
        DispatchQueue.main.async {
            guard !self.cancelled else { return }
            self.events(event)
        }
    }

    private func armStallTimer(_ seconds: TimeInterval, reason: String) {
        cancelStallTimer()
        let item = DispatchWorkItem { [weak self] in
            guard let self = self, !self.ended else { return }
            self.fail(at: self.playIndex, reason: reason)
        }
        stallTimer = item
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    private func cancelStallTimer() {
        stallTimer?.cancel()
        stallTimer = nil
    }

    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }
}

// MARK: - Self-test

/// Debug measurement on a real device. Launch with `-KokoroSelfTest`. It waits for the model,
/// synthesizes sample replies without playing them, reads one through the real playback path
/// at volume 0, and writes `Documents/kokoro-selftest.json`: load and warm-up time, time to
/// first audio, real-time factor, memory footprint and model size on disk. With
/// `-KokoroSelfTestBackground` it then waits for the app to be backgrounded and records whether
/// synthesis still works there.
enum KokoroSelfTest {
    static func runIfRequested(engine: KokoroSpeechEngine) {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("-KokoroSelfTest") else { return }
        let background = args.contains("-KokoroSelfTestBackground")
        let launchFootprint = KokoroSpeechEngine.memoryFootprintMB()
        Task.detached(priority: .userInitiated) {
            await run(engine: engine, launchFootprint: launchFootprint, background: background)
        }
    }

    private static let samples: [(String, String)] = [
        ("short", "Done. The tests pass and the branch is pushed."),
        ("paragraph", "I traced the failure to the retry loop in the upload client. When the server answers with a 503, the loop waits two seconds, but it never resets the counter after a success, so the fourth transient error in a session aborts the whole upload. I changed it to reset on success and added a test that simulates five intermittent failures."),
        ("reply", """
        Here's where things stand.

        The migration ran cleanly on staging: 14,382 rows moved in about 40 seconds, and the row counts match on both sides. I spot-checked twenty records by hand, including the three with null timestamps that broke the first attempt.

        Two things still need you. First, the production run needs a maintenance window of roughly ten minutes, because the table is locked while the index rebuilds. Second, the old column can't be dropped until the mobile app stops reading it, which means version 4.2 has to reach most users first.

        If you want, I can schedule the production run for Saturday morning and post the checklist in the channel.
        """),
    ]

    private static func run(engine: KokoroSpeechEngine, launchFootprint: Double, background: Bool) async {
        var report: [String: Any] = [
            "os": UIDevice.current.systemVersion,
            "device": deviceModel(),
            "footprint_at_launch_mb": round1(launchFootprint),
        ]
        let waitStart = Date()
        var manager: KokoroAneManager?
        var lastState = ""
        while Date().timeIntervalSince(waitStart) < 1200 {
            let (state, loaded): (KokoroSpeechEngine.State, KokoroAneManager?) = await MainActor.run { (engine.state, engine.manager) }
            lastState = "\(state)"
            if state == .ready, let loaded = loaded { manager = loaded; break }
            if case .failed = state { break }
            if state == .turnedOffAfterCrashes || state == .waitingForWiFi { break }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        report["wait_for_ready_s"] = round2(Date().timeIntervalSince(waitStart))
        report["engine_state"] = lastState
        guard let manager = manager else {
            write(report)
            return
        }
        let (load, warm) = await MainActor.run { (engine.lastLoadSeconds, engine.lastWarmUpSeconds) }
        report["load_s"] = load.map(round2)
        report["warm_up_s"] = warm.map(round2)
        report["footprint_ready_mb"] = round1(KokoroSpeechEngine.memoryFootprintMB())
        report["models_on_disk_mb"] = round1(KokoroSpeechEngine.modelDirectories().map(directorySizeMB).reduce(0, +))
        var peak = KokoroSpeechEngine.memoryFootprintMB()
        var results: [[String: Any]] = []
        for (name, text) in samples {
            let chunks = NeuralSpeechText.chunks(NeuralSpeechText.cleanMarkdown(text))
            let t0 = Date()
            var first: Double?
            var audio = 0.0
            var error: String?
            for chunk in chunks {
                do {
                    let r = try await manager.synthesizeDetailed(text: chunk.text, voice: KokoroSpeechEngine.voice, speed: 1)
                    if first == nil { first = Date().timeIntervalSince(t0) }
                    audio += Double(r.samples.count) / Double(r.sampleRate)
                } catch let e {
                    error = e.localizedDescription
                    break
                }
                peak = max(peak, KokoroSpeechEngine.memoryFootprintMB())
            }
            let total = Date().timeIntervalSince(t0)
            var row: [String: Any] = ["name": name, "chars": text.count, "chunks": chunks.count,
                                      "first_audio_s": first.map(round2) ?? -1, "total_s": round2(total),
                                      "audio_s": round1(audio), "rtf": audio > 0 ? round3(total / audio) : -1]
            if let error = error { row["error"] = error }
            results.append(row)
        }
        report["foreground"] = results
        report["playback"] = await playbackCheck(engine: engine, text: samples[2].1)
        report["footprint_peak_mb"] = round1(peak)
        report["footprint_after_mb"] = round1(KokoroSpeechEngine.memoryFootprintMB())
        report["available_memory_mb"] = round1(Double(os_proc_available_memory()) / 1_048_576)
        write(report)

        guard background else { return }
        let bgWait = Date()
        var inBackground = false
        while Date().timeIntervalSince(bgWait) < 180 {
            inBackground = await MainActor.run { UIApplication.shared.applicationState == .background }
            if inBackground { break }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        report["background_reached"] = inBackground
        if inBackground {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            let t0 = Date()
            do {
                let r = try await withTimeout(seconds: 20) {
                    try await manager.synthesizeDetailed(text: "This sentence was synthesized in the background.", voice: KokoroSpeechEngine.voice, speed: 1)
                }
                report["background_synthesis"] = ["ok": true, "s": round2(Date().timeIntervalSince(t0)),
                                                  "audio_s": round1(Double(r.samples.count) / Double(r.sampleRate))]
            } catch {
                report["background_synthesis"] = ["ok": false, "s": round2(Date().timeIntervalSince(t0)), "error": "\(error)"]
            }
        }
        write(report)
    }

    /// Read `text` through `KokoroPlayback` exactly as a reply is read, but silently, and
    /// record when each event arrived.
    private static func playbackCheck(engine: KokoroSpeechEngine, text: String) async -> [String: Any] {
        await withCheckedContinuation { (continuation: CheckedContinuation<[String: Any], Never>) in
            DispatchQueue.main.async {
                KokoroPlayback.playerVolume = 0
                let began = Date()
                var events: [String] = []
                var playback: NeuralSpeechPlayback?
                var done = false
                func complete() {
                    guard !done else { return }
                    done = true
                    KokoroPlayback.playerVolume = 1
                    _ = playback
                    continuation.resume(returning: ["events": events, "s": round2(Date().timeIntervalSince(began))])
                }
                playback = engine.startSpeaking(text, rate: 0.5) { event in
                    events.append(String(format: "%@ at %.2fs", "\(event)", Date().timeIntervalSince(began)))
                    switch event {
                    case .finished, .failed: complete()
                    case .started: break
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 180) {
                    events.append("timed out")
                    playback?.cancel()
                    complete()
                }
            }
        }
    }

    private struct Timeout: Error {}

    private static func withTimeout<T>(seconds: Double, _ work: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw Timeout()
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
    }

    private static func write(_ report: [String: Any]) {
        guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
              let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: dir.appendingPathComponent("kokoro-selftest.json"))
        LogManager.shared.log("Kokoro self-test: \(String(data: data, encoding: .utf8) ?? "")", category: "Kokoro")
    }

    private static func directorySizeMB(_ root: URL) -> Double {
        guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) else { return 0 }
        var bytes = 0
        for case let url as URL in files {
            bytes += (try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0
        }
        return Double(bytes) / 1_048_576
    }

    private static func deviceModel() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }

    private static func round1(_ x: Double) -> Double { (x * 10).rounded() / 10 }
    private static func round2(_ x: Double) -> Double { (x * 100).rounded() / 100 }
    private static func round3(_ x: Double) -> Double { (x * 1000).rounded() / 1000 }
}
#endif
