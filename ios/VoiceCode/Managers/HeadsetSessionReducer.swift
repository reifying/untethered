// HeadsetSessionReducer.swift
// Pure interaction state machine for the hands-free loop: record → finalize →
// await response → speak → idle. Replaces the implicit `HeadsetState` guards
// scattered across `HeadsetRemoteCommandManager` and the retired
// `BlueParrottPTTArbitrator`. The whole transition table lives here in one
// greppable, exhaustively unit-testable `reduce`; an executor (in
// `HeadsetRemoteCommandManager`) applies the returned effects to the real
// `VoiceInput`/`VoiceOutput`/`VoiceCodeClient` plumbing and feeds resulting
// events back in.
//
// Platform-agnostic and I/O-free (only `Foundation`), so it compiles into BOTH
// the iOS and macOS targets and its tests run under `make test` and
// `make test-mac-unit`. See
// @docs/design/macos-headset-loop-state-machine.md §Interaction (session) machine.
//
// Key invariant — NO STRANDING: every non-idle state has a fallback / timeout /
// interrupt edge back to `idle`:
//   • F4: `awaitingResponse —awaitTimedOut/backendUnavailable→ idle` (the old
//     `.sending` "Processing" could sit forever; here it can't), WITHOUT
//     cancelling the in-flight prompt — a late response still speaks via
//     `idle —ttsStarted→ speaking`.
//   • F5/barge-in: a tap/double dismisses `speaking`/`awaitingResponse`; a hold
//     interrupts and starts a fresh recording turn in one gesture.
//   • F3: a first capture that produces zero audio within the grace window
//     restarts once.
//   • Goal #2: capture ending with no `up` (recognizer silence / engine failure
//     / forced on BLE disconnect) finalizes instead of stranding `.recording`.

import Foundation

/// Drives recording / sending / speaking. Replaces the implicit `HeadsetState`.
/// `awaitingResponse` is the old `.sending` ("Processing") with explicit exits.
enum SessionState: Equatable {
    case idle                  // was .ready
    case recording
    case finalizing            // reading the final transcription (one run-loop hop)
    case awaitingResponse      // prompt sent; waiting for spoken response
    case speaking              // TTS playing the response
}

/// Semantic, de-bracketed gestures (see `BlueParrottGestureRecognizer`) + system events.
enum SessionEvent: Equatable {
    case holdStarted           // button held past holdThreshold
    case holdEnded             // release after a hold
    case tap                   // quick press-release
    case doubleTap             // (no `longPress` — a hold is PTT; the raw `04` code is dropped)
    case captureProducedAudio  // first non-silent buffer arrived (F3 readiness)
    case captureStalled        // grace elapsed with zero buffers (F3)
    case captureEnded          // capture stopped with NO `up` gesture: recognizer silence
                               // auto-finalize, engine failure, or forced on BLE disconnect.
                               // Safety net so `.recording` can't strand (preserves the
                               // existing voiceInput.$isRecording→false transition).
    case transcription(String?)// nil/empty ⇒ nothing recognized
    case ttsStarted            // voiceOutput.isSpeaking → true
    case ttsEnded              // voiceOutput.isSpeaking → false
    case awaitTimedOut         // awaitingResponse fallback fired (F4)
    case backendUnavailable    // client disconnected mid-await
}

/// A short, language-neutral audio cue for a hands-free state change, played through the
/// headset HFP route so the user hears it without looking at the screen. `Hashable` (not
/// just `Equatable`) because `HeadsetEarconPlayer` (macOS executor, task .3) keys a
/// `[Earcon: AVAudioPlayer]` cache by it; `Hashable` refines `Equatable`, so the
/// `SessionEffect` Equatable synthesis below still holds.
/// See @docs/design/macos-headset-audible-feedback.md §3.
enum Earcon: Hashable {
    case listening   // recording began — "mic is live, talk now"
    case sent        // prompt dispatched — "got it" (executor-only; never a reducer effect)
    case error       // nothing recognized / no response / not connected — "that didn't work"
    case cancelled   // TTS dismissed without recording (optional; not emitted yet)
}

enum SessionEffect: Equatable {
    case startCapture
    case restartCapture        // F3 recovery
    case stopCapture
    case sendPrompt(String)
    case interruptTTS
    case suspendKeepAlive      // BLE path only (F2)
    case resumeKeepAlive
    case armTimer(SessionTimer)
    case cancelTimer(SessionTimer)
    case updateNowPlaying
    case playEarcon(Earcon)    // declare intent to play an audible cue (executor does the I/O)
    case log(String)
}

enum SessionTimer: Equatable { case captureGrace, awaitResponse }

/// What is driving the button events. Gates BLE-only effects (e.g. keep-alive
/// suspension) and distinguishes the gesture-bearing transports (BLE / iOS SDK)
/// from the media-key path, which has no hold semantics.
enum ButtonSource: Equatable { case blueParrottBLE, mediaKey, iosSDK, ui }

/// The pure interaction reducer: `(state, event, source) → (state, [effect])`,
/// no I/O. Irrelevant `(state, event)` pairs fall through to the `default` and
/// are a no-op (state unchanged, no effects) — e.g. a duplicate `captureEnded`
/// after the machine already left `.recording` (see Risk 10).
enum SessionReducer {
    static func reduce(_ s: SessionState, _ e: SessionEvent,
                       source: ButtonSource) -> (SessionState, [SessionEffect]) {
        switch (s, e) {
        // Start recording: hold (PTT) or tap (toggle) both begin from idle.
        case (.idle, .holdStarted), (.idle, .tap):
            return beginRecording(source: source, interrupting: [])

        // Barge-in (F4/F5): a HOLD from a busy state means "talk now" — interrupt and
        // start a fresh recording turn (the primary PTT gesture must work here too).
        case (.speaking, .holdStarted):
            return beginRecording(source: source, interrupting: [.interruptTTS])
        case (.awaitingResponse, .holdStarted):
            return beginRecording(source: source, interrupting: [.cancelTimer(.awaitResponse)])

        // The on-screen mic button (.ui source) is a record/stop toggle, not a TTS
        // dismisser: a tap from a busy state barges in and records — what a user expects
        // when clicking "record". The headset/SDK has a hold for record-over, so its
        // .tap keeps F5 dismiss semantics (below); the UI button has no hold gesture, so
        // its tap must record. Mirrors the hold barge-in effects above.
        case (.speaking, .tap) where source == .ui:
            return beginRecording(source: source, interrupting: [.interruptTTS])
        case (.awaitingResponse, .tap) where source == .ui:
            return beginRecording(source: source, interrupting: [.cancelTimer(.awaitResponse)])

        // F3: first capture produced no audio within the grace window → restart and
        // re-arm. The reducer is stateless about retry count, so it emits `restartCapture`
        // on EVERY stall; the one-shot guarantee (Risk 7 — a second stall must finalize to
        // idle, not loop) is the executor's responsibility (it stops re-feeding
        // `captureStalled` after one retry). Keep that guard downstream when wiring task .7.
        case (.recording, .captureStalled):
            return (.recording, [.restartCapture, .armTimer(.captureGrace),
                                 .log("capture stalled (0 buffers) — restarting")])
        case (.recording, .captureProducedAudio):
            return (.recording, [.cancelTimer(.captureGrace)])

        // Stop: hold release (PTT), a second tap (toggle), or capture ending on its own
        // (recognizer silence auto-finalize / engine failure / forced on disconnect —
        // the safety net that keeps `.recording` from stranding) → finalize.
        case (.recording, .holdEnded), (.recording, .tap), (.recording, .captureEnded):
            return (.finalizing, [.stopCapture, .resumeKeepAlive, .cancelTimer(.captureGrace)])

        case (.finalizing, .transcription(let text)):
            if let text, !text.trimmed.isEmpty {
                // Success branch: send only. The `.sent` cue is the executor's job (played
                // on a CONFIRMED send) — emitting it here would lie on a failed send (§3).
                return (.awaitingResponse,
                        [.sendPrompt(text), .armTimer(.awaitResponse), .updateNowPlaying])
            }
            // Nothing recognized (nil/empty/whitespace) → idle + "didn't catch that".
            return (.idle, [.playEarcon(.error), .updateNowPlaying])

        // F4: no spoken response in time (or backend dropped) → idle WITHOUT cancelling
        // the prompt (a late response still speaks via `idle —ttsStarted→ speaking`).
        case (.awaitingResponse, .awaitTimedOut), (.awaitingResponse, .backendUnavailable):
            return (.idle, [.cancelTimer(.awaitResponse), .playEarcon(.error), .updateNowPlaying,
                            .log("await ended — re-enabling button (prompt still in flight)")])
        case (.awaitingResponse, .ttsStarted):
            return (.speaking, [.cancelTimer(.awaitResponse), .updateNowPlaying])

        // Dismiss a busy state with a tap or double-tap (no new recording).
        case (.awaitingResponse, .tap), (.awaitingResponse, .doubleTap):
            return (.idle, [.cancelTimer(.awaitResponse), .updateNowPlaying])
        case (.speaking, .tap), (.speaking, .doubleTap):
            return (.idle, [.interruptTTS, .updateNowPlaying])

        // A late response after a timeout still speaks (idle → speaking).
        case (.idle, .ttsStarted):
            return (.speaking, [.updateNowPlaying])
        case (.speaking, .ttsEnded):
            return (.idle, [.updateNowPlaying])

        default:
            return (s, [])   // ignore irrelevant events in the current state
        }
    }

    /// Shared "start a recording turn" effects, optionally preceded by interrupt/cleanup
    /// effects when barging in from a busy state. Keep-alive suspend is BLE-only (F2).
    private static func beginRecording(source: ButtonSource,
                                       interrupting: [SessionEffect]) -> (SessionState, [SessionEffect]) {
        var fx = interrupting
        if source == .blueParrottBLE { fx.append(.suspendKeepAlive) }
        // `.playEarcon(.listening)` fires on EVERY recording-start (idle start AND barge-in,
        // any source) — the eyes-free "mic is live, talk now" cue (executor gates it).
        fx.append(contentsOf: [.startCapture, .playEarcon(.listening),
                               .armTimer(.captureGrace), .updateNowPlaying])
        return (.recording, fx)
    }
}

private extension String { var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) } }

/// Pure F3 capture-readiness decision: given how many audio buffers the route has
/// delivered by the `captureGrace` window and how many warm-up restarts we've already
/// spent, decide whether the route is live, should be restarted (cold), or has failed
/// to warm up and must finalize. Extracted from the executor so it is unit-testable
/// (the executor just reads `voiceInput.capturedBufferCount` and applies the outcome).
///
/// Why `minLiveBufferCount > 1` (the bug this fixes): a cold Bluetooth SCO mic route
/// emits exactly ONE silent priming buffer and then nothing — observed on the B450-XT
/// as `buffers=1, firstAudio=never`, whole utterance lost, every dead capture preceded
/// by `route live (1 buffers)`. A LIVE 16 kHz route streams ~10 buffers/sec
/// (1600 frames/buffer), so by the ~1 s grace window it has delivered many; `restartCapture`
/// rebuilds a fresh engine/monitor so each window's count is independent. The old
/// `>= 1 ⇒ live` check mis-classified the cold route's single buffer as live and never
/// restarted. The non-silent fast path is handled separately by `captureProducedAudio`
/// (which cancels the grace), so this governs only the silent-warm-up branch.
enum CaptureReadiness {
    /// Minimum buffers by the grace window to consider the route live. A cold route
    /// delivers ≤1; a live one ~10 per grace — wide separation, 2 keeps margin against
    /// a slightly-late-but-live route while still catching the 1-buffer cold route.
    static let minLiveBufferCount = 2
    /// Warm-up restarts allowed before finalizing (Risk 7: bounded — never loops).
    static let maxRestarts = 2

    enum Outcome: Equatable { case live, restart, finalize }

    static func graceOutcome(bufferCount: Int, restartCount: Int) -> Outcome {
        if bufferCount >= minLiveBufferCount { return .live }
        return restartCount < maxRestarts ? .restart : .finalize
    }
}

#if os(macOS)
/// Pure policy for the SCO mic pre-warm (the first-word fix) — the testable when/how-long
/// decisions, no I/O. The headset mic only works over HFP/SCO, and bringing that link up
/// from cold (A2DP→HFP switch + SCO establishment) can take seconds — so the FIRST press
/// after a BLE (re)connect talks into a route that isn't live yet (buffers=…, silent=100%,
/// firstAudio=never). On the connect edge we open a brief, discarding pre-warm capture to
/// bring SCO up before the press; a real press adopts the already-live engine.
/// macOS-only: iOS drives the route via AVAudioSession (.allowBluetoothHFP). See
/// @docs/design/macos-headset-sco-prewarm.md.
enum ScoPrewarm {
    /// How long the pre-warm capture is held open with no press before releasing the mic.
    /// Covers "reconnect → user presses" (observed ~1.5s) with margin; short enough not to
    /// sit on the mic (privacy indicator / battery).
    static let holdDuration: TimeInterval = 8.0

    /// Pre-warm only on a fresh connect, while idle, and not already warming/recording.
    static func shouldPrewarm(connected: Bool, isRecording: Bool, isPrewarming: Bool) -> Bool {
        connected && !isRecording && !isPrewarming
    }
}
#endif
