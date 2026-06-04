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

    // MARK: - Start recording from idle (PTT + toggle)

    func testIdle_holdStarted_startsRecording_BLEsuspendsKeepAlive() {
        let (state, fx) = SessionReducer.reduce(.idle, .holdStarted, source: .blueParrottBLE)
        XCTAssertEqual(state, .recording)
        XCTAssertEqual(fx, [.suspendKeepAlive, .startCapture, .armTimer(.captureGrace), .updateNowPlaying])
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
        XCTAssertEqual(fx, [.stopCapture, .resumeKeepAlive, .cancelTimer(.captureGrace)])
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
}
