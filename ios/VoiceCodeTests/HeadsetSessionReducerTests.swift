// HeadsetSessionReducerTests.swift
// Table tests for the pure interaction reducer. `SessionReducer.reduce` carries no
// I/O, so coverage is exhaustive and hardware-free — every (state, event) pair,
// with emphasis on the new safety edges (F4 strand exit, barge-in, capture
// readiness, keep-alive gating). See
// @docs/design/macos-headset-loop-state-machine.md §Interaction (session) machine.
//
// The reducer is platform-agnostic, so this file is unguarded and runs under both
// `make test` (iOS) and `make test-mac-unit` (macOS) — no project.yml exclude.

import XCTest
@testable import VoiceCode

final class HeadsetSessionReducerTests: XCTestCase {

    /// True if `fx` carries any `.sendPrompt(_)` (the associated value makes
    /// `contains(_:)` awkward; this matches regardless of the prompt text).
    private func containsSendPrompt(_ fx: [SessionEffect]) -> Bool {
        fx.contains { if case .sendPrompt = $0 { return true }; return false }
    }

    /// Pulls the prompt text out of the first `.sendPrompt(_)`, or nil if none.
    private func sentPrompt(_ fx: [SessionEffect]) -> String? {
        for case let .sendPrompt(text) in fx { return text }
        return nil
    }

    /// True if `fx` carries any `.playEarcon(_)` (regardless of which earcon).
    private func containsAnyEarcon(_ fx: [SessionEffect]) -> Bool {
        fx.contains { if case .playEarcon = $0 { return true }; return false }
    }

    // MARK: - Start recording from idle (PTT + toggle)

    func testIdle_holdStarted_startsRecording_BLEsuspendsKeepAlive() {
        let (state, fx) = SessionReducer.reduce(.idle, .holdStarted, source: .blueParrottBLE)
        XCTAssertEqual(state, .recording)
        XCTAssertEqual(fx, [.suspendKeepAlive, .startCapture, .playEarcon(.listening),
                            .armTimer(.captureGrace), .updateNowPlaying])
    }

    func testIdle_tap_startsRecording() {
        let (state, fx) = SessionReducer.reduce(.idle, .tap, source: .blueParrottBLE)
        XCTAssertEqual(state, .recording)
        XCTAssertTrue(fx.contains(.startCapture))
        XCTAssertTrue(fx.contains(.armTimer(.captureGrace)))
    }

    /// suspendKeepAlive is emitted ONLY for the BLE source (F2/F7); the media-key
    /// path keeps the keep-alive so a stem press can still stop recording.
    func testKeepAliveSuspend_isGatedToBLESource() {
        let (_, ble) = SessionReducer.reduce(.idle, .holdStarted, source: .blueParrottBLE)
        let (_, media) = SessionReducer.reduce(.idle, .holdStarted, source: .mediaKey)
        let (_, sdk) = SessionReducer.reduce(.idle, .tap, source: .iosSDK)
        XCTAssertTrue(ble.contains(.suspendKeepAlive))
        XCTAssertFalse(media.contains(.suspendKeepAlive), "media-key path keeps the keep-alive for stem-press stop")
        XCTAssertFalse(sdk.contains(.suspendKeepAlive), "only the BLE path owns the keep-alive output")
    }

    // MARK: - Recording → finalizing (stop, and the no-strand safety net)

    func testRecording_holdEnded_finalizes() {
        let (state, fx) = SessionReducer.reduce(.recording, .holdEnded, source: .blueParrottBLE)
        XCTAssertEqual(state, .finalizing)
        XCTAssertEqual(fx, [.stopCapture, .playEarcon(.stopped), .resumeKeepAlive,
                            .cancelTimer(.captureGrace)])
    }

    func testRecording_tap_finalizes() {
        let (state, fx) = SessionReducer.reduce(.recording, .tap, source: .blueParrottBLE)
        XCTAssertEqual(state, .finalizing)
        XCTAssertTrue(fx.contains(.stopCapture))
    }

    /// Goal #2 — recognizer silence / engine failure / forced on BLE disconnect:
    /// capture ends with no `up`, so `.recording` must NOT strand.
    func testRecording_captureEnded_finalizes_noStrand() {
        let (state, fx) = SessionReducer.reduce(.recording, .captureEnded, source: .blueParrottBLE)
        XCTAssertEqual(state, .finalizing)
        XCTAssertTrue(fx.contains(.stopCapture))
        XCTAssertTrue(fx.contains(.resumeKeepAlive))
    }

    // MARK: - Capture readiness (F3)

    /// A single stall restarts capture and re-arms the grace window. NOTE: the reducer is
    /// stateless about retry count — it restarts on EVERY stall (asserted below), so the
    /// "restart once" guarantee (Risk 7) lives in the executor, not here. This test does
    /// not (and cannot) verify the one-shot at this layer.
    func testRecording_captureStalled_restartsCapture_rearmsGrace() {
        let (state, fx) = SessionReducer.reduce(.recording, .captureStalled, source: .blueParrottBLE)
        XCTAssertEqual(state, .recording)
        XCTAssertTrue(fx.contains(.restartCapture))
        XCTAssertTrue(fx.contains(.armTimer(.captureGrace)), "the retry re-arms the grace window")

        // Documents the stateless behavior the executor must guard against: a SECOND stall
        // emits another restartCapture (the once-guard is downstream, not in the reducer).
        let (state2, fx2) = SessionReducer.reduce(state, .captureStalled, source: .blueParrottBLE)
        XCTAssertEqual(state2, .recording)
        XCTAssertTrue(fx2.contains(.restartCapture),
                      "the reducer restarts on every stall — the executor owns the one-shot guard")
    }

    func testRecording_captureProducedAudio_cancelsGrace_staysRecording() {
        let (state, fx) = SessionReducer.reduce(.recording, .captureProducedAudio, source: .blueParrottBLE)
        XCTAssertEqual(state, .recording)
        XCTAssertEqual(fx, [.cancelTimer(.captureGrace)])
    }

    // MARK: - Finalizing → awaitingResponse / idle

    func testFinalizing_transcriptionWithText_sendsAndAwaits() {
        let (state, fx) = SessionReducer.reduce(.finalizing, .transcription("hello world"), source: .blueParrottBLE)
        XCTAssertEqual(state, .awaitingResponse)
        XCTAssertEqual(sentPrompt(fx), "hello world")
        XCTAssertTrue(fx.contains(.armTimer(.awaitResponse)))
    }

    func testFinalizing_transcriptionNil_returnsToIdle_noSend() {
        let (state, fx) = SessionReducer.reduce(.finalizing, .transcription(nil), source: .blueParrottBLE)
        XCTAssertEqual(state, .idle)
        XCTAssertFalse(containsSendPrompt(fx), "nothing recognized → no prompt")
    }

    func testFinalizing_transcriptionWhitespaceOnly_returnsToIdle_noSend() {
        let (state, fx) = SessionReducer.reduce(.finalizing, .transcription("   \n\t "), source: .blueParrottBLE)
        XCTAssertEqual(state, .idle)
        XCTAssertFalse(containsSendPrompt(fx), "whitespace-only transcription is empty → no prompt")
    }

    func testFinalizing_transcriptionEmptyString_returnsToIdle_noSend() {
        let (state, fx) = SessionReducer.reduce(.finalizing, .transcription(""), source: .blueParrottBLE)
        XCTAssertEqual(state, .idle)
        XCTAssertFalse(containsSendPrompt(fx), "empty (non-nil) transcription → no prompt")
    }

    // MARK: - awaitingResponse exits (F4 strand fix)

    func testAwaitingResponse_timeout_returnsToIdle_withoutCancellingPrompt() {
        let (state, fx) = SessionReducer.reduce(.awaitingResponse, .awaitTimedOut, source: .blueParrottBLE)
        XCTAssertEqual(state, .idle)
        XCTAssertTrue(fx.contains(.cancelTimer(.awaitResponse)))
        XCTAssertFalse(containsSendPrompt(fx), "timeout must not cancel/resend the in-flight prompt")
    }

    func testAwaitingResponse_backendUnavailable_returnsToIdle_withoutCancellingPrompt() {
        let (state, fx) = SessionReducer.reduce(.awaitingResponse, .backendUnavailable, source: .blueParrottBLE)
        XCTAssertEqual(state, .idle)
        XCTAssertTrue(fx.contains(.cancelTimer(.awaitResponse)))
        XCTAssertFalse(containsSendPrompt(fx))
    }

    func testAwaitingResponse_ttsStarted_speaks_cancelsAwaitTimer() {
        let (state, fx) = SessionReducer.reduce(.awaitingResponse, .ttsStarted, source: .blueParrottBLE)
        XCTAssertEqual(state, .speaking)
        XCTAssertTrue(fx.contains(.cancelTimer(.awaitResponse)))
    }

    // MARK: - Dismiss a busy state (F5)

    func testAwaitingResponse_tap_dismissesToIdle() {
        let (state, fx) = SessionReducer.reduce(.awaitingResponse, .tap, source: .blueParrottBLE)
        XCTAssertEqual(state, .idle, "a tap during Processing must free the button (matches the edge table)")
        XCTAssertTrue(fx.contains(.cancelTimer(.awaitResponse)))
        XCTAssertFalse(containsSendPrompt(fx))
    }

    func testAwaitingResponse_doubleTap_dismissesToIdle() {
        let (state, _) = SessionReducer.reduce(.awaitingResponse, .doubleTap, source: .blueParrottBLE)
        XCTAssertEqual(state, .idle)
    }

    func testSpeaking_tap_dismissesToIdle_interruptsTTS() {
        let (state, fx) = SessionReducer.reduce(.speaking, .tap, source: .blueParrottBLE)
        XCTAssertEqual(state, .idle)
        XCTAssertTrue(fx.contains(.interruptTTS))
    }

    func testSpeaking_doubleTap_dismissesToIdle_interruptsTTS() {
        let (state, fx) = SessionReducer.reduce(.speaking, .doubleTap, source: .blueParrottBLE)
        XCTAssertEqual(state, .idle)
        XCTAssertTrue(fx.contains(.interruptTTS))
    }

    // MARK: - Barge-in by hold (F4/F5)

    func testSpeaking_hold_bargesInAndRecords() {
        let (state, fx) = SessionReducer.reduce(.speaking, .holdStarted, source: .blueParrottBLE)
        XCTAssertEqual(state, .recording, "a hold during speaking must interrupt and start a new turn")
        XCTAssertTrue(fx.contains(.interruptTTS))
        XCTAssertTrue(fx.contains(.startCapture))
        XCTAssertTrue(fx.contains(.suspendKeepAlive))
        // The interrupt must precede the fresh capture so TTS stops before the mic opens.
        XCTAssertEqual(fx.first, .interruptTTS)
    }

    func testAwaitingResponse_hold_bargesInAndRecords_cancelsAwaitTimer() {
        let (state, fx) = SessionReducer.reduce(.awaitingResponse, .holdStarted, source: .blueParrottBLE)
        XCTAssertEqual(state, .recording)
        XCTAssertTrue(fx.contains(.startCapture))
        XCTAssertTrue(fx.contains(.cancelTimer(.awaitResponse)))
        XCTAssertFalse(containsSendPrompt(fx), "barge-in must not cancel the prior prompt server-side")
    }

    // MARK: - Late response after a timeout (idle → speaking)

    func testIdle_ttsStarted_speaks() {
        let (state, fx) = SessionReducer.reduce(.idle, .ttsStarted, source: .blueParrottBLE)
        XCTAssertEqual(state, .speaking, "a late response after a timeout still speaks")
        XCTAssertTrue(fx.contains(.updateNowPlaying))
    }

    func testSpeaking_ttsEnded_returnsToIdle() {
        let (state, fx) = SessionReducer.reduce(.speaking, .ttsEnded, source: .blueParrottBLE)
        XCTAssertEqual(state, .idle)
        XCTAssertTrue(fx.contains(.updateNowPlaying))
    }

    // MARK: - No-op / strand-proofing of irrelevant events (Risk 10 + defaults)

    /// Risk 10: an `up` already moved the machine to `.finalizing`; the executor may
    /// still feed `captureEnded` from `voiceInput.isRecording → false`. That pair must
    /// be a no-op (no double-finalize), proven by the state guard, not bookkeeping.
    func testFinalizing_captureEnded_isNoOp() {
        let (state, fx) = SessionReducer.reduce(.finalizing, .captureEnded, source: .blueParrottBLE)
        XCTAssertEqual(state, .finalizing)
        XCTAssertTrue(fx.isEmpty)
    }

    func testIdle_ttsEnded_isNoOp() {
        let (state, fx) = SessionReducer.reduce(.idle, .ttsEnded, source: .blueParrottBLE)
        XCTAssertEqual(state, .idle)
        XCTAssertTrue(fx.isEmpty)
    }

    func testRecording_holdStarted_isNoOp() {
        // Already recording; a spurious holdStarted (no intervening release) is ignored.
        let (state, fx) = SessionReducer.reduce(.recording, .holdStarted, source: .blueParrottBLE)
        XCTAssertEqual(state, .recording)
        XCTAssertTrue(fx.isEmpty)
    }

    func testIdle_awaitTimedOut_isNoOp() {
        let (state, fx) = SessionReducer.reduce(.idle, .awaitTimedOut, source: .blueParrottBLE)
        XCTAssertEqual(state, .idle)
        XCTAssertTrue(fx.isEmpty)
    }

    /// `holdEnded` only finalizes from `.recording`; in any other state (no recording to
    /// end — e.g. a stray release after a dismiss) it is ignored, not a strand.
    func testHoldEnded_outsideRecording_isNoOp() {
        for s in [SessionState.idle, .finalizing, .awaitingResponse, .speaking] {
            let (state, fx) = SessionReducer.reduce(s, .holdEnded, source: .blueParrottBLE)
            XCTAssertEqual(state, s, "holdEnded must not change state outside .recording (was \(s))")
            XCTAssertTrue(fx.isEmpty, "holdEnded must emit no effects outside .recording (was \(s))")
        }
    }

    // MARK: - F4 regression: timeout then a fresh press records again

    /// After the await timeout returns to idle, the next press starts a new recording —
    /// the core of acceptance #1 (the button is usable again, no permanent strand).
    func testTimeoutThenPress_recordsAgain() {
        let (afterTimeout, _) = SessionReducer.reduce(.awaitingResponse, .awaitTimedOut, source: .blueParrottBLE)
        XCTAssertEqual(afterTimeout, .idle)
        let (recording, fx) = SessionReducer.reduce(afterTimeout, .holdStarted, source: .blueParrottBLE)
        XCTAssertEqual(recording, .recording)
        XCTAssertTrue(fx.contains(.startCapture))
    }

    // MARK: - F3 capture-readiness: the cold-SCO "1 buffer = live" false-positive fix

    /// THE BUG (logs-20260604-191349): a cold Bluetooth SCO route delivered exactly ONE
    /// silent buffer, which the old `>= 1 ⇒ live` check called live → no restart → the
    /// whole 14 s hold was lost. One buffer must be treated as cold, not live.
    func testGrace_oneBuffer_isColdNotLive_restarts() {
        XCTAssertEqual(CaptureReadiness.graceOutcome(bufferCount: 1, restartCount: 0), .restart,
                       "a single priming buffer is a cold SCO route, not a live one")
        XCTAssertEqual(CaptureReadiness.graceOutcome(bufferCount: 0, restartCount: 0), .restart)
    }

    /// A live route streams ~10 buffers per grace window — comfortably above the bar.
    func testGrace_manyBuffers_isLive() {
        XCTAssertEqual(CaptureReadiness.graceOutcome(bufferCount: 2, restartCount: 0), .live)
        XCTAssertEqual(CaptureReadiness.graceOutcome(bufferCount: 10, restartCount: 1), .live)
    }

    /// Restarts are bounded (Risk 7): after `maxRestarts` cold windows, finalize rather
    /// than loop forever rebuilding the engine.
    func testGrace_coldPastMaxRestarts_finalizes_noLoop() {
        XCTAssertEqual(CaptureReadiness.graceOutcome(bufferCount: 1, restartCount: CaptureReadiness.maxRestarts), .finalize)
        XCTAssertEqual(CaptureReadiness.graceOutcome(bufferCount: 0, restartCount: CaptureReadiness.maxRestarts), .finalize)
        // Still cold but budget remains → keep trying (more warm-up attempts than the old single restart).
        XCTAssertEqual(CaptureReadiness.graceOutcome(bufferCount: 1, restartCount: CaptureReadiness.maxRestarts - 1), .restart)
    }

    func testGrace_allowsMoreThanOneWarmupRestart() {
        XCTAssertGreaterThan(CaptureReadiness.maxRestarts, 1, "one restart was not enough for a slow SCO link")
    }

    // MARK: - UI source: mic button shares the reducer (cross-source fix)

    /// The on-screen mic button drives the reducer as `.ui` so the headset and UI share
    /// one recording-state owner. A `.ui` tap from idle records — but must NOT suspend
    /// the keep-alive (that's the BlueParrott BLE warm-up dance only).
    func testUITap_fromIdle_records_withoutSuspendingKeepAlive() {
        let (state, fx) = SessionReducer.reduce(.idle, .tap, source: .ui)
        XCTAssertEqual(state, .recording)
        XCTAssertTrue(fx.contains(.startCapture))
        XCTAssertFalse(fx.contains(.suspendKeepAlive), "keep-alive suspend is gated to the BLE source")
    }

    /// A `.ui` tap while recording finalizes + sends — the same toggle the headset uses,
    /// so a UI-started recording stopped by a headset tap (or vice versa) is sent, not
    /// lost. (Whichever source stops it, `(.recording, .tap) → finalizing`.)
    func testUITap_whileRecording_finalizes() {
        let (state, fx) = SessionReducer.reduce(.recording, .tap, source: .ui)
        XCTAssertEqual(state, .finalizing)
        XCTAssertTrue(fx.contains(.stopCapture))
    }

    /// Cross-source: a BLE start then a UI stop (and the reverse) both finalize — the
    /// reducer doesn't care which source toggles, it just owns the state.
    func testCrossSource_bleStart_uiStop_finalizes() {
        let (rec, _) = SessionReducer.reduce(.idle, .holdStarted, source: .blueParrottBLE)
        XCTAssertEqual(rec, .recording)
        let (fin, fx) = SessionReducer.reduce(rec, .tap, source: .ui)
        XCTAssertEqual(fin, .finalizing)
        XCTAssertTrue(fx.contains(.stopCapture))
    }

    // MARK: - UI source: mic button barges in and records (not a TTS dismisser)

    /// The on-screen mic button taps to RECORD even while TTS is speaking: it barges in
    /// (interrupt TTS + start capture) instead of merely dismissing the TTS and making
    /// the user tap again. This is the "pressed twice, didn't record" fix.
    func testUITap_whileSpeaking_bargesInAndRecords() {
        let (state, fx) = SessionReducer.reduce(.speaking, .tap, source: .ui)
        XCTAssertEqual(state, .recording)
        XCTAssertTrue(fx.contains(.interruptTTS), "must interrupt the TTS it barged into")
        XCTAssertTrue(fx.contains(.startCapture), "must actually start recording, not just dismiss")
        XCTAssertFalse(fx.contains(.suspendKeepAlive), "keep-alive suspend is BLE-only")
    }

    /// A `.ui` tap while awaiting the backend response also barges in and records (cancel
    /// the await timer + start capture) rather than dismissing to idle.
    func testUITap_whileAwaiting_bargesInAndRecords() {
        let (state, fx) = SessionReducer.reduce(.awaitingResponse, .tap, source: .ui)
        XCTAssertEqual(state, .recording)
        XCTAssertTrue(fx.contains(.cancelTimer(.awaitResponse)))
        XCTAssertTrue(fx.contains(.startCapture))
    }

    /// Regression guard: a HEADSET (`.blueParrottBLE`) tap while speaking still only
    /// DISMISSES (F5: tap=dismiss, hold=record-over). The barge-in-on-tap behavior is
    /// exclusive to the `.ui` source, which has no hold gesture.
    func testHeadsetTap_whileSpeaking_stillDismisses_doesNotRecord() {
        let (state, fx) = SessionReducer.reduce(.speaking, .tap, source: .blueParrottBLE)
        XCTAssertEqual(state, .idle)
        XCTAssertTrue(fx.contains(.interruptTTS))
        XCTAssertFalse(fx.contains(.startCapture), "headset tap must not start a recording from speaking")
    }

    /// Regression guard: a headset tap while awaiting still dismisses to idle (no record).
    func testHeadsetTap_whileAwaiting_stillDismisses_doesNotRecord() {
        let (state, fx) = SessionReducer.reduce(.awaitingResponse, .tap, source: .blueParrottBLE)
        XCTAssertEqual(state, .idle)
        XCTAssertFalse(fx.contains(.startCapture))
    }

    // MARK: - Earcons (audible state-change cues)
    // @docs/design/macos-headset-audible-feedback.md §3–§4. The reducer declares cue INTENT
    // via `.playEarcon`; only playback is I/O (executor, task .4). `.sent` is never a reducer
    // effect — the executor plays it on a confirmed send so a failed send can't lie.

    /// `.listening` ("mic is live, talk now") on the idle-start recording transition.
    func testRecordingStart_fromIdle_emitsListeningEarcon() {
        let (state, fx) = SessionReducer.reduce(.idle, .tap, source: .ui)
        XCTAssertEqual(state, .recording)
        XCTAssertTrue(fx.contains(.playEarcon(.listening)))
    }

    /// Barge-in is also a recording-start, so it ALSO cues `.listening` — the UI mic button
    /// tapped while TTS is speaking interrupts and records, and the user hears "talk now".
    func testRecordingStart_uiBargeInWhileSpeaking_emitsListeningEarcon() {
        let (state, fx) = SessionReducer.reduce(.speaking, .tap, source: .ui)
        XCTAssertEqual(state, .recording)
        XCTAssertTrue(fx.contains(.playEarcon(.listening)))
        XCTAssertTrue(fx.contains(.interruptTTS))
    }

    /// A hold barge-in from awaitingResponse (headset PTT "talk now") also cues `.listening`.
    func testRecordingStart_holdBargeInWhileAwaiting_emitsListeningEarcon() {
        let (state, fx) = SessionReducer.reduce(.awaitingResponse, .holdStarted, source: .blueParrottBLE)
        XCTAssertEqual(state, .recording)
        XCTAssertTrue(fx.contains(.playEarcon(.listening)))
    }

    /// Negative: the SUCCESS branch emits `.sendPrompt` but NO earcon — the `.sent` cue is the
    /// executor's job (confirmed-send only), asserted in the executor tests, not here.
    func testNonEmptyTranscription_emitsSend_butNoReducerEarcon() {
        let (state, fx) = SessionReducer.reduce(.finalizing, .transcription("hello"), source: .blueParrottBLE)
        XCTAssertEqual(state, .awaitingResponse)
        XCTAssertTrue(fx.contains(.sendPrompt("hello")))
        XCTAssertFalse(containsAnyEarcon(fx), "the reducer must NOT emit .sent on send — that is executor-only")
    }

    /// `.error` ("didn't catch that") on a nil transcription (nothing recognized).
    func testEmptyTranscription_nil_emitsErrorEarcon() {
        let (state, fx) = SessionReducer.reduce(.finalizing, .transcription(nil), source: .blueParrottBLE)
        XCTAssertEqual(state, .idle)
        XCTAssertTrue(fx.contains(.playEarcon(.error)))
    }

    /// `.error` also covers empty/whitespace-only transcriptions — same "nothing recognized".
    func testEmptyTranscription_whitespace_emitsErrorEarcon() {
        let (state, fx) = SessionReducer.reduce(.finalizing, .transcription("   \n\t "), source: .blueParrottBLE)
        XCTAssertEqual(state, .idle)
        XCTAssertTrue(fx.contains(.playEarcon(.error)))
    }

    /// `.error` on the F4 await-timeout strand exit (no spoken response in time).
    func testAwaitTimeout_emitsErrorEarcon() {
        let (state, fx) = SessionReducer.reduce(.awaitingResponse, .awaitTimedOut, source: .blueParrottBLE)
        XCTAssertEqual(state, .idle)
        XCTAssertTrue(fx.contains(.playEarcon(.error)))
    }

    /// `.error` on the F4 backend-dropped strand exit (client disconnected mid-await).
    func testBackendUnavailable_emitsErrorEarcon() {
        let (state, fx) = SessionReducer.reduce(.awaitingResponse, .backendUnavailable, source: .blueParrottBLE)
        XCTAssertEqual(state, .idle)
        XCTAssertTrue(fx.contains(.playEarcon(.error)))
    }

    /// Negative: a silent transition (TTS finished playing) stays silent — no earcon.
    func testSpeakingState_noEarconOnTtsEnd() {
        let (_, fx) = SessionReducer.reduce(.speaking, .ttsEnded, source: .blueParrottBLE)
        XCTAssertFalse(containsAnyEarcon(fx))
    }

    /// `.cancelled` on a headset tap dismissing TTS (F5) — interrupting the assistant is one
    /// of the three button outcomes the user must be able to tell apart eyes-free, and it is
    /// the one that starts NO recording.
    func testHeadsetDismissSpeaking_emitsCancelledEarcon() {
        let (state, fx) = SessionReducer.reduce(.speaking, .tap, source: .blueParrottBLE)
        XCTAssertEqual(state, .idle)
        XCTAssertTrue(fx.contains(.interruptTTS))
        XCTAssertTrue(fx.contains(.playEarcon(.cancelled)))
        XCTAssertFalse(fx.contains(.playEarcon(.listening)),
                       "a dismiss must not sound like a recording start")
    }

    /// A double-tap dismiss of TTS cues `.cancelled` on the same terms as the tap.
    func testHeadsetDoubleTapDismissSpeaking_emitsCancelledEarcon() {
        let (state, fx) = SessionReducer.reduce(.speaking, .doubleTap, source: .blueParrottBLE)
        XCTAssertEqual(state, .idle)
        XCTAssertTrue(fx.contains(.playEarcon(.cancelled)))
    }

    /// Dismissing a pending response is the same user-facing outcome — button pressed,
    /// nothing recording — so it gets the same cue rather than silence.
    func testHeadsetDismissAwaiting_emitsCancelledEarcon() {
        let (state, fx) = SessionReducer.reduce(.awaitingResponse, .tap, source: .blueParrottBLE)
        XCTAssertEqual(state, .idle)
        XCTAssertTrue(fx.contains(.playEarcon(.cancelled)))
        XCTAssertFalse(fx.contains(.startCapture))
    }

    // MARK: - Stop-recording cue

    /// `.stopped` ("mic closed") on a PTT release — the counterpart to `.listening`.
    func testStopRecording_holdEnded_emitsStoppedEarcon() {
        let (state, fx) = SessionReducer.reduce(.recording, .holdEnded, source: .blueParrottBLE)
        XCTAssertEqual(state, .finalizing)
        XCTAssertTrue(fx.contains(.stopCapture))
        XCTAssertTrue(fx.contains(.playEarcon(.stopped)))
    }

    /// `.stopped` on the toggle-off tap (the same button press that started the recording).
    func testStopRecording_tap_emitsStoppedEarcon() {
        let (state, fx) = SessionReducer.reduce(.recording, .tap, source: .blueParrottBLE)
        XCTAssertEqual(state, .finalizing)
        XCTAssertTrue(fx.contains(.playEarcon(.stopped)))
    }

    /// `.stopped` also on the path the user did NOT ask for — recognizer silence, engine
    /// failure, or a forced stop on BLE disconnect. This is the case where an eyes-free cue
    /// matters most: without it, recording ends and nothing tells the user.
    func testStopRecording_captureEnded_emitsStoppedEarcon() {
        let (state, fx) = SessionReducer.reduce(.recording, .captureEnded, source: .blueParrottBLE)
        XCTAssertEqual(state, .finalizing)
        XCTAssertTrue(fx.contains(.playEarcon(.stopped)))
    }

    /// The three cues must never collide on one press. A barge-in interrupts AND starts a
    /// recording; it plays `.listening` ALONE — "recording is starting" is the fact that
    /// matters, and stacking cues would make the press unreadable by ear.
    func testBargeIn_playsListeningOnly_notCancelled() {
        let (state, fx) = SessionReducer.reduce(.speaking, .holdStarted, source: .blueParrottBLE)
        XCTAssertEqual(state, .recording)
        XCTAssertTrue(fx.contains(.interruptTTS))
        XCTAssertTrue(fx.contains(.playEarcon(.listening)))
        XCTAssertFalse(fx.contains(.playEarcon(.cancelled)),
                       "a barge-in must sound like a recording start, not a dismiss")
        XCTAssertEqual(fx.filter { if case .playEarcon = $0 { return true }; return false }.count, 1,
                       "exactly one cue per press")
    }

    /// The UI mic button barging in while speaking is also a recording-start, not a dismiss.
    func testUIBargeIn_playsListeningOnly_notCancelled() {
        let (_, fx) = SessionReducer.reduce(.speaking, .tap, source: .ui)
        XCTAssertTrue(fx.contains(.playEarcon(.listening)))
        XCTAssertFalse(fx.contains(.playEarcon(.cancelled)))
    }

    /// `Earcon` is `Hashable` (it keys the player's `[Earcon: AVAudioPlayer]` cache); guard
    /// that the cases stay distinct so the cache can't collide two cues into one player.
    func testEarcon_isHashable_distinctCases() {
        XCTAssertEqual(Set<Earcon>([.listening, .stopped, .sent, .error, .cancelled]).count, 5)
    }
}
