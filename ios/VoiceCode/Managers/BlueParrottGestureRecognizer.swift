// BlueParrottGestureRecognizer.swift
// Pure de-bracketer: converts the raw bracketed GATT button stream into exactly
// one semantic gesture per physical action — the unit-testable core that drives
// the session state machine. Replaces the retired `BlueParrottPTTArbitrator`.
//
// Platform-agnostic and SDK-free, so it compiles into BOTH the iOS and macOS
// targets. The raw GATT stream brackets every gesture with down/up — a single
// tap is `01,00,02` (down, up, tapCode), a double `01,00,01,00,03`, and a hold
// `01,04,00` (down, longPressCode ~1s after down, up). Driving the session
// machine off raw down/up flickers on taps (findings F5); this recognizer
// emits clean gestures instead. See
// @docs/design/macos-headset-loop-state-machine.md §Gesture recognizer.
//
// Hold/PTT is detected by a timer (`holdThreshold`) and is code-independent;
// discrete tap/double come from the hardware's own gesture codes (02/03,
// authoritative on firmware 2.6.4). A per-press `generation` + `isDown` guard
// stops a fast double-tap (two `down`s) from tripping a stale hold timer. The
// `scheduleAfter` scheduler is injected so the recognizer reads no wall-clock
// and is unit-testable without real time.

import Foundation

/// One raw signal off the bracketed GATT stream. `tapCode`/`doubleTapCode` are the
/// hardware's trailing classification codes (02/03); `longPressCode` (04) arrives
/// *inside* a hold's down/up bracket and is dropped.
enum RawButtonSignal: Equatable { case down, up, tapCode, doubleTapCode, longPressCode }

/// A clean, de-bracketed gesture — exactly one per physical action. There is no
/// `longPress`: a hold is PTT (`holdStarted`/`holdEnded`), and the raw `04` code
/// is ignored.
enum HeadsetGesture: Equatable { case holdStarted, holdEnded, tap, doubleTap }

/// Converts the raw bracketed GATT stream into clean gestures. Hold is detected by a
/// timer (`holdThreshold`); discrete tap/double come from the hardware's own gesture
/// codes (02/03). A per-press `generation` + `isDown` guard prevents a stale hold timer
/// from firing across a fast double-tap. `scheduleAfter` is injected so it is
/// unit-testable without real time (no wall-clock is read).
final class BlueParrottGestureRecognizer {
    static let holdThreshold: TimeInterval = 0.30

    private let emit: (HeadsetGesture) -> Void
    private let scheduleAfter: (TimeInterval, @escaping () -> Void) -> Void
    private var generation = 0          // bumped per `down`; invalidates older hold timers
    private var isDown = false
    private var holdActive = false

    init(emit: @escaping (HeadsetGesture) -> Void,
         scheduleAfter: @escaping (TimeInterval, @escaping () -> Void) -> Void) {
        self.emit = emit
        self.scheduleAfter = scheduleAfter
    }

    /// Convert one raw GATT signal into at most one semantic gesture.
    /// - Hold: `down` arms a timer keyed to this press's `generation`; if it fires while
    ///   the button is still down → `.holdStarted`; the later `up` → `.holdEnded`.
    /// - Tap/double: a quick release classified by the trailing hardware code. The
    ///   `generation` + `isDown` guards stop a fast double-tap (two `down`s) from
    ///   tripping a stale hold timer.
    func feed(_ signal: RawButtonSignal) {
        switch signal {
        case .down:
            generation += 1
            isDown = true
            holdActive = false
            let gen = generation
            scheduleAfter(Self.holdThreshold) { [weak self] in
                guard let self, self.isDown, gen == self.generation, !self.holdActive else { return }
                self.holdActive = true
                self.emit(.holdStarted)              // still held, same press → it's a hold
            }
        case .up:
            isDown = false
            if holdActive { emit(.holdEnded); holdActive = false }
            // else: quick release — classified by the trailing tap/double code below.
        case .tapCode:        if !holdActive { emit(.tap) }
        case .doubleTapCode:  if !holdActive { emit(.doubleTap) }
        case .longPressCode:  break                  // in-bracket during a hold — ignored
        }
    }
}
