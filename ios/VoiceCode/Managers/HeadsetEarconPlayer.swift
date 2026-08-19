// HeadsetEarconPlayer.swift
// The macOS playback seam for hands-free audible cues (earcons). Synthesizes one short,
// distinct tone per `Earcon` to a temp file ONCE at init and `prepareToPlay()`s an
// `AVAudioPlayer` for each, so `play()` is low-latency. This mirrors the keep-alive silent
// player (`HeadsetRemoteCommandManager.setupKeepAlive`): synthesize PCM → temp CAF →
// `AVAudioPlayer(contentsOf:)` → `prepareToPlay()`.
//
// Routing note: macOS has NO `AVAudioSession`, so there is no `.playAndRecord` /
// `.allowBluetoothA2DP` to set (those are the iOS precedent named in the design doc).
// On macOS `AVAudioPlayer` plays to the system default OUTPUT device, whatever that is at
// the moment `play()` is called — this class never chooses a route.
//
// On macOS that route is usually the BUILT-IN SPEAKERS, not the headset, and that is
// deliberate. The BlueParrott cannot do A2DP output and HFP mic at once, so
// `MacAudioOutputRouter` parks the system output on the built-in device before capture and
// LEAVES it there; output returns to the headset only while TTS is actually speaking. See
// `HeadsetRemoteCommandManager.rerouteOutputForCaptureIfNeeded` and
// @docs/design/macos-headset-loop-findings.md. Consequences for the cues:
//   • `.listening` / `.stopped` — the reducer emits `.startCapture` before the cue, and
//     output stays parked after capture, so both play through the Mac speakers.
//   • `.cancelled` — fires while TTS still owns the route (the park-back runs on a later
//     main-queue hop), so the interrupt cue plays in-ear.
//   • `.sent` / `.error` — follow whatever the route is when they land.
// `play()` logs the resolved CoreAudio default output device so the actual destination is
// always in the log, mirroring `setupKeepAlive`'s `outputs=[…]` logging.
//
// Cross-platform: the tone synthesis is pure AVFoundation. macOS plays cues through the
// system default output (CoreAudio); iOS plays through the active AVAudioSession route —
// the Bluetooth HFP headset while a recording session is up.
// See @docs/design/macos-headset-audible-feedback.md §3, §6.

import Foundation
import AVFoundation
#if os(macOS)
import CoreAudio
#endif

/// Log to the in-app LogManager so messages appear in the in-app debug log viewer
/// (mirrors `HeadsetRemoteCommandManager`'s `hLog`). See ios/CLAUDE.md.
private func eLog(_ msg: String) {
    LogManager.shared.log(msg, category: "HeadsetEarcon")
}

private func eLogError(_ msg: String) {
    LogManager.shared.log("❌ \(msg)", category: "HeadsetEarcon")
}

/// Plays an earcon. Injected into the macOS executor; the real impl routes to the headset
/// default-output device, tests inject a spy.
protocol EarconPlaying {
    func play(_ earcon: Earcon)
}

/// Synthesizes the earcon tones ONCE at init to temp files and `prepareToPlay()`s them so
/// `play()` is immediate (Risk 6: no first-play latency). A short one-shot tone coexists
/// with the silent looping keep-alive player (both follow the system default output).
final class HeadsetEarconPlayer: EarconPlaying {
    /// Errors from tone synthesis. `init` catches these per-earcon (logs and moves on) so
    /// one bad earcon doesn't sink the others; `preparedEarcons` then reveals which succeeded.
    enum SynthesisError: Error {
        case formatUnavailable
        case bufferUnavailable(frames: Int)
    }

    private var players: [Earcon: AVAudioPlayer] = [:]

    init() {
        let allEarcons: [Earcon] = [.listening, .stopped, .sent, .error, .cancelled]
        for earcon in allEarcons {
            do {
                players[earcon] = try Self.makePlayer(for: earcon)
            } catch {
                eLogError("Earcon: failed to prepare \(earcon): \(error)")
            }
        }
        eLog("Earcon: player ready — prepared=\(preparedEarcons.count)/\(allEarcons.count)")
    }

    func play(_ earcon: Earcon) {
        guard let player = players[earcon] else {
            eLogError("Earcon: no prepared player for \(earcon) — skipping")
            return
        }
        player.currentTime = 0
        let started = player.play()
        eLog("Earcon: played \(earcon) — started=\(started), output=[\(Self.outputRouteDescription())]")
    }

    /// Resolved output route at play time, logged so the cue's actual destination is always
    /// recoverable from the log. On macOS the expected destination is the BUILT-IN device
    /// for the recording cues (output is parked off the headset to free the HFP mic — see
    /// the routing note above), so "Mac speakers" here is correct, not a mis-route. macOS
    /// reads the CoreAudio default-output device; iOS reads the active AVAudioSession route
    /// (the HFP headset while recording).
    static func outputRouteDescription() -> String {
        #if os(macOS)
        return defaultOutputDeviceDescription()
        #else
        let outs = AVAudioSession.sharedInstance().currentRoute.outputs
            .map { "\($0.portName) [\($0.portType.rawValue)]" }
        return outs.isEmpty ? "none" : outs.joined(separator: ", ")
        #endif
    }

    /// Test accessor (reachable via `@testable import`, unlike the `private` cache): which
    /// earcons got a prepared player at init. Lets the isolation test verify construction
    /// without a live audio route or any `private` access.
    var preparedEarcons: Set<Earcon> { Set(players.keys) }

    // MARK: - Tone synthesis

    /// One earcon's tone: a sequence of pure-sine notes played back-to-back. Distinct
    /// CONTOUR + REGISTER per earcon keeps them non-confusable eyes-free:
    ///   • `.listening` — rising 2-note (E5→A5): "go / talk now"
    ///   • `.stopped`   — falling 2-note (A5→E5): "mic closed" — the exact inverse of
    ///     `.listening`, because rising-vs-falling is the contrast that survives being
    ///     heard once, in a car, while not looking at the screen. Same register as
    ///     `.listening` so the pair reads as one open/close gesture; `.error` is also
    ///     falling but sits a register lower (G4→C4), so the two don't collide.
    ///   • `.sent`      — single bright high blip: "got it" (short)
    ///   • `.error`     — falling 2-note in a low register: "that didn't work"
    ///   • `.cancelled` — single neutral mid blip: "dismissed" — no contour at all, so it
    ///     can't be mistaken for either end of the recording pair.
    /// Amplitude is modest (Risk 1: keep cue energy low so it doesn't bleed into capture).
    private struct ToneSpec {
        let notes: [(frequency: Double, duration: Double)]
        let amplitude: Float
        let fileLabel: String
    }

    private static func spec(for earcon: Earcon) -> ToneSpec {
        switch earcon {
        case .listening:
            return ToneSpec(notes: [(659.25, 0.10), (880.00, 0.13)], amplitude: 0.22, fileLabel: "listening")
        case .stopped:
            return ToneSpec(notes: [(880.00, 0.10), (659.25, 0.13)], amplitude: 0.22, fileLabel: "stopped")
        case .sent:
            return ToneSpec(notes: [(1046.50, 0.08)], amplitude: 0.22, fileLabel: "sent")
        case .error:
            return ToneSpec(notes: [(392.00, 0.11), (261.63, 0.15)], amplitude: 0.22, fileLabel: "error")
        case .cancelled:
            return ToneSpec(notes: [(523.25, 0.09)], amplitude: 0.20, fileLabel: "cancelled")
        }
    }

    /// Synthesizes a 1-channel PCM tone for `earcon` to a temp CAF and returns a prepared
    /// `AVAudioPlayer`, mirroring `setupKeepAlive`'s temp-file approach.
    private static func makePlayer(for earcon: Earcon) throws -> AVAudioPlayer {
        let spec = spec(for: earcon)
        let sampleRate = 44100.0
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
            throw SynthesisError.formatUnavailable
        }
        let noteFrameCounts = spec.notes.map { Int(($0.duration * sampleRate).rounded()) }
        let totalFrames = noteFrameCounts.reduce(0, +)
        guard totalFrames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(totalFrames)),
              let channel = buffer.floatChannelData?[0] else {
            throw SynthesisError.bufferUnavailable(frames: totalFrames)
        }
        buffer.frameLength = AVAudioFrameCount(totalFrames)

        // ~6ms raised-cosine fade at each note boundary so note starts/ends don't click.
        let fadeFrames = max(1, Int(0.006 * sampleRate))
        var offset = 0
        for (note, noteFrames) in zip(spec.notes, noteFrameCounts) {
            for i in 0..<noteFrames {
                let phase = 2.0 * Double.pi * note.frequency * Double(i) / sampleRate
                var sample = Float(sin(phase)) * spec.amplitude
                if i < fadeFrames {
                    sample *= Float(0.5 * (1 - cos(Double.pi * Double(i) / Double(fadeFrames))))
                } else if i >= noteFrames - fadeFrames {
                    let remaining = noteFrames - i
                    sample *= Float(0.5 * (1 - cos(Double.pi * Double(remaining) / Double(fadeFrames))))
                }
                channel[offset + i] = sample
            }
            offset += noteFrames
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("headset_earcon_\(spec.fileLabel).caf")
        // Write+close in a nested scope so the file is flushed before the player reads it.
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        }
        let player = try AVAudioPlayer(contentsOf: url)
        player.prepareToPlay()
        return player
    }

    // MARK: - Route diagnostics (macOS CoreAudio)

    #if os(macOS)
    /// Name + UID of the system default OUTPUT device (CoreAudio). On macOS `AVAudioPlayer`
    /// plays to this device, so logging it at play time records where each cue actually
    /// went — the built-in device for the recording cues, the headset while TTS holds the
    /// route (see the routing note at the top). Mirrors
    /// `VoiceInputManager.defaultInputDeviceDescription()` for the input side.
    static func defaultOutputDeviceDescription() -> String {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        )
        guard status == noErr, deviceID != AudioDeviceID(0) else {
            return "unknown (default-output status \(status))"
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
    #endif
}
