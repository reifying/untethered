// MacAudioOutputRouterTests.swift
// Pure-decision tests for MacAudioOutput — the choice of WHEN to move the system output off
// the headset for capture (the A2DP-out / HFP-in conflict). The CoreAudio device get/set is
// I/O and exercised on hardware; this covers the decision that gates it.
//
// macOS-only (the type is #if os(macOS)); excluded from the iOS target via project.yml, with
// the #if guard as a secondary safeguard.

#if os(macOS)
import XCTest
@testable import VoiceCode

final class MacAudioOutputRouterTests: XCTestCase {

    func testDeviceBase_stripsBluetoothHalfSuffix() {
        XCTAssertEqual(MacAudioOutput.deviceBase("3C-68-16-60-A8-1E:output"), "3C-68-16-60-A8-1E")
        XCTAssertEqual(MacAudioOutput.deviceBase("3C-68-16-60-A8-1E:input"), "3C-68-16-60-A8-1E")
        XCTAssertEqual(MacAudioOutput.deviceBase("BuiltInSpeakerDevice"), "BuiltInSpeakerDevice")
    }

    /// The conflict case: output and input are the SAME physical headset (UIDs share a base)
    /// → reroute output off it so the HFP mic can come up.
    func testReroute_whenOutputAndInputAreSameHeadset() {
        XCTAssertTrue(MacAudioOutput.shouldRerouteForCapture(
            outputUID: "3C-68-16-60-A8-1E:output",
            inputUID: "3C-68-16-60-A8-1E:input"))
    }

    /// Output already on a different device (built-in speakers) → no conflict, leave it.
    func testNoReroute_whenOutputIsDifferentDevice() {
        XCTAssertFalse(MacAudioOutput.shouldRerouteForCapture(
            outputUID: "BuiltInSpeakerDevice",
            inputUID: "3C-68-16-60-A8-1E:input"))
    }

    /// A different Bluetooth device for output than the capture mic → no conflict.
    func testNoReroute_whenOutputIsADifferentBluetoothDevice() {
        XCTAssertFalse(MacAudioOutput.shouldRerouteForCapture(
            outputUID: "AA-BB-CC-DD-EE-FF:output",
            inputUID: "3C-68-16-60-A8-1E:input"))
    }

    func testNoReroute_whenEitherUIDMissingOrEmpty() {
        XCTAssertFalse(MacAudioOutput.shouldRerouteForCapture(outputUID: nil, inputUID: "x:input"))
        XCTAssertFalse(MacAudioOutput.shouldRerouteForCapture(outputUID: "x:output", inputUID: nil))
        XCTAssertFalse(MacAudioOutput.shouldRerouteForCapture(outputUID: "", inputUID: "x:input"))
        XCTAssertFalse(MacAudioOutput.shouldRerouteForCapture(outputUID: "x:output", inputUID: ""))
    }
}
#endif
