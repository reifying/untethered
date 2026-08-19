// HeadsetEarconPlayerTests.swift
// Player-isolation tests for the macOS audible-cue seam (task .3). Constructing
// `HeadsetEarconPlayer()` synthesizes a tone per earcon to a temp file and
// `prepareToPlay()`s an `AVAudioPlayer` — no live audio route is required, since
// `AVAudioPlayer(contentsOf:)` + `prepareToPlay()` only LOAD the synthesized file. The
// internal `preparedEarcons` accessor (reachable via `@testable import`) reports which
// earcons got a prepared player, so we can verify construction without `private` access.
//
// Executor wiring (the gated `playCue`, confirmed-`.sent`, spy-driven ordering) is task .4
// and is asserted in HeadsetRemoteCommandManagerMacTests. See
// @docs/design/macos-headset-audible-feedback.md §4 (Verification — "Unit — player isolation").
//
// macOS-only (HeadsetEarconPlayer is `#if os(macOS)`): excluded from the iOS VoiceCodeTests
// target via project.yml; the `#if os(macOS)` guard is a secondary safeguard.

#if os(macOS)
import XCTest
@testable import VoiceCode

final class HeadsetEarconPlayerTests: XCTestCase {
    /// AC: constructing the player prepares a player for every shipped cue. This is the
    /// exact assertion named in the design doc / task .3 verification.
    func testInit_preparesPlayersForShippedEarcons() {
        let player = HeadsetEarconPlayer()
        XCTAssertTrue(
            player.preparedEarcons.isSuperset(of: [.listening, .stopped, .sent, .error]),
            "Expected prepared players for the shipped cues; got \(player.preparedEarcons)"
        )
    }

    /// Every `Earcon` case synthesizes — including `.cancelled` and `.stopped`, the two
    /// cues that make the three button outcomes distinguishable eyes-free.
    func testInit_preparesEveryEarcon() {
        let player = HeadsetEarconPlayer()
        XCTAssertEqual(
            player.preparedEarcons, [.listening, .stopped, .sent, .error, .cancelled],
            "Every Earcon case should get a prepared player; got \(player.preparedEarcons)"
        )
    }

    /// `.stopped` must not synthesize to the same audio as `.listening` — they are the
    /// inverse of one another, and a copy-paste that left both rising would silently
    /// destroy the start-vs-stop distinction this cue exists for. Compares the rendered
    /// temp files rather than the specs, so it catches a synthesis bug too.
    func testStoppedAndListening_renderDifferentAudio() throws {
        _ = HeadsetEarconPlayer()   // synthesis writes both temp files
        let dir = FileManager.default.temporaryDirectory
        let listening = try Data(contentsOf: dir.appendingPathComponent("headset_earcon_listening.caf"))
        let stopped = try Data(contentsOf: dir.appendingPathComponent("headset_earcon_stopped.caf"))
        XCTAssertNotEqual(listening, stopped,
                          ".stopped must be audibly distinct from .listening, not a copy")
    }

    /// `play()` on a prepared player must not crash with no live route (it just starts the
    /// loaded `AVAudioPlayer`); playing an earcon with no prepared player is a safe no-op.
    /// The precondition asserts the calls below are actually exercising prepared players
    /// (not silently hitting the no-op guard); the test then proves they don't crash.
    func testPlay_doesNotCrashWithoutLiveRoute() {
        let player = HeadsetEarconPlayer()
        XCTAssertEqual(player.preparedEarcons, [.listening, .stopped, .sent, .error, .cancelled])
        player.play(.listening)
        player.play(.stopped)
        player.play(.sent)
        player.play(.error)
        player.play(.cancelled)
    }

    /// The CoreAudio default-output diagnostic always yields a non-empty description (used
    /// in the play-time route log to catch mis-routing, Risk 2).
    func testDefaultOutputDeviceDescription_isNonEmpty() {
        XCTAssertFalse(HeadsetEarconPlayer.defaultOutputDeviceDescription().isEmpty)
    }
}
#endif
