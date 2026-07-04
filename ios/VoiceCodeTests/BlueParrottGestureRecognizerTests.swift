// BlueParrottGestureRecognizerTests.swift
// Unit tests for the pure raw→semantic de-bracketer. The recognizer reads no
// wall-clock — the hold timer runs on an injected scheduler (`ManualScheduler`)
// that captures pending closures so tests fire (or withhold) the hold timer
// deterministically. See @docs/design/macos-headset-loop-state-machine.md
// §Gesture recognizer.
//
// The recognizer is platform-agnostic, so this file is unguarded and runs under
// both `make test` (iOS) and `make test-mac-unit` (macOS) — no project.yml exclude.

import XCTest
@testable import VoiceCode

final class BlueParrottGestureRecognizerTests: XCTestCase {

    /// Captures hold-timer closures instead of dispatching on real time, so tests
    /// decide exactly when (or whether) the timer fires.
    private final class ManualScheduler {
        private(set) var scheduledDelays: [TimeInterval] = []
        private var pending: [() -> Void] = []

        func scheduleAfter(_ delay: TimeInterval, _ work: @escaping () -> Void) {
            scheduledDelays.append(delay)
            pending.append(work)
        }

        /// Fire every closure scheduled so far (in order) and clear the queue.
        /// Closures scheduled *during* firing are not run by this call.
        func fireAll() {
            let toRun = pending
            pending.removeAll()
            toRun.forEach { $0() }
        }
    }

    /// Builds a recognizer wired to a fresh scheduler; `gestures` accumulates emissions.
    private func makeRecognizer() -> (BlueParrottGestureRecognizer, ManualScheduler, () -> [HeadsetGesture]) {
        let scheduler = ManualScheduler()
        var gestures: [HeadsetGesture] = []
        let recognizer = BlueParrottGestureRecognizer(
            emit: { gestures.append($0) },
            scheduleAfter: { scheduler.scheduleAfter($0, $1) }
        )
        return (recognizer, scheduler, { gestures })
    }

    // MARK: - Hold (PTT)

    /// A held press: the hold timer fires while the button is still down → holdStarted;
    /// the trailing `up` → holdEnded.
    func testHeldPress_emitsHoldStartedThenHoldEnded() {
        let (recognizer, scheduler, gestures) = makeRecognizer()

        recognizer.feed(.down)
        scheduler.fireAll()          // threshold elapsed, still down → hold
        recognizer.feed(.up)

        XCTAssertEqual(gestures(), [.holdStarted, .holdEnded])
    }

    /// The hold timer is armed at exactly `holdThreshold` (0.30 s) — no wall-clock read.
    func testHoldTimer_armedAtHoldThreshold() {
        let (recognizer, scheduler, _) = makeRecognizer()

        recognizer.feed(.down)

        XCTAssertEqual(scheduler.scheduledDelays, [BlueParrottGestureRecognizer.holdThreshold])
        XCTAssertEqual(BlueParrottGestureRecognizer.holdThreshold, 0.30, accuracy: 0.0001)
    }

    /// `longPressCode` (the in-bracket `04`) is dropped during a hold: it must not add a
    /// gesture between holdStarted and holdEnded.
    func testLongPressCode_duringHold_isIgnored() {
        let (recognizer, scheduler, gestures) = makeRecognizer()

        recognizer.feed(.down)
        scheduler.fireAll()          // → holdStarted
        recognizer.feed(.longPressCode)   // in-bracket — ignored
        recognizer.feed(.up)         // → holdEnded

        XCTAssertEqual(gestures(), [.holdStarted, .holdEnded],
                       "longPressCode inside the down/up bracket must be dropped")
    }

    /// A bare `longPressCode` with no hold in progress emits nothing.
    func testLongPressCode_standalone_isIgnored() {
        let (recognizer, _, gestures) = makeRecognizer()

        recognizer.feed(.longPressCode)

        XCTAssertEqual(gestures(), [])
    }

    // MARK: - Tap (no flicker)

    /// `down, up, tapCode` → a single tap, with NO holdStarted flicker. Even when the
    /// stale hold timer fires after release, the `isDown` guard suppresses it.
    func testTap_emitsOnlyTap_noHoldFlicker() {
        let (recognizer, scheduler, gestures) = makeRecognizer()

        recognizer.feed(.down)
        recognizer.feed(.up)         // quick release before threshold
        recognizer.feed(.tapCode)
        scheduler.fireAll()          // stale timer fires — must no-op (isDown == false)

        XCTAssertEqual(gestures(), [.tap], "a quick press-release must not flicker holdStarted")
    }

    /// The stale hold timer firing after a quick release emits nothing on its own.
    func testQuickRelease_staleHoldTimer_doesNotEmit() {
        let (recognizer, scheduler, gestures) = makeRecognizer()

        recognizer.feed(.down)
        recognizer.feed(.up)
        scheduler.fireAll()          // timer fires after up → guard kills it

        XCTAssertEqual(gestures(), [], "a release before threshold must cancel the pending hold")
    }

    // MARK: - Double-tap

    /// A fast double-tap (`down, up, down, up, doubleTapCode`) emits ONLY doubleTap.
    /// The generation bump on the second `down` plus the `isDown` guard suppress both
    /// stale hold timers.
    func testFastDoubleTap_emitsOnlyDoubleTap() {
        let (recognizer, scheduler, gestures) = makeRecognizer()

        recognizer.feed(.down)       // generation 1, arms timer 1
        recognizer.feed(.up)
        recognizer.feed(.down)       // generation 2, arms timer 2
        recognizer.feed(.up)
        recognizer.feed(.doubleTapCode)
        scheduler.fireAll()          // timer 1 (stale generation) + timer 2 (isDown false) → no-op

        XCTAssertEqual(gestures(), [.doubleTap],
                       "the generation/isDown guard must suppress both stale hold timers")
    }

    // MARK: - Sequencing

    /// Successive physical actions each yield exactly one gesture: hold, then tap.
    func testHoldThenTap_eachYieldsOneGesture() {
        let (recognizer, scheduler, gestures) = makeRecognizer()

        // Hold
        recognizer.feed(.down)
        scheduler.fireAll()          // → holdStarted
        recognizer.feed(.up)         // → holdEnded
        // Tap
        recognizer.feed(.down)
        recognizer.feed(.up)
        recognizer.feed(.tapCode)    // → tap
        scheduler.fireAll()          // stale timer → no-op

        XCTAssertEqual(gestures(), [.holdStarted, .holdEnded, .tap])
    }
}
