// AudioCaptureStatsTests.swift
// Unit tests for the mic-capture observability + readiness accumulator
// (headset capture, findings F2/F3). Pure logic — cross-platform, runs under both
// `make test` (iOS) and `make test-mac` (macOS).

import XCTest
@testable import VoiceCode

final class AudioCaptureStatsTests: XCTestCase {

    // MARK: - AudioCaptureStats (pure accumulator)

    func testEmptyStatsReportNothingCaptured() {
        let stats = AudioCaptureStats()
        XCTAssertEqual(stats.bufferCount, 0)
        XCTAssertEqual(stats.totalFrames, 0)
        XCTAssertEqual(stats.peak, 0)
        XCTAssertNil(stats.firstAudioOffset)
        XCTAssertTrue(stats.summary.contains("buffers=0"))
        XCTAssertTrue(stats.summary.contains("firstAudio=never"))
    }

    func testAllSilentBuffers_noFirstAudio_100PercentSilent() {
        var stats = AudioCaptureStats()
        for i in 0..<10 {
            stats.record(peak: 0.0, frames: 1024, offset: Double(i) * 0.064)
        }
        XCTAssertEqual(stats.bufferCount, 10)
        XCTAssertEqual(stats.silentBufferCount, 10)
        XCTAssertEqual(stats.peak, 0)
        XCTAssertNil(stats.firstAudioOffset, "no non-silent buffer → no first-audio offset")
        XCTAssertTrue(stats.summary.contains("silent=100%"))
        XCTAssertTrue(stats.summary.contains("firstAudio=never"))
    }

    func testFirstAudioOffsetCapturedOnceAndNotOverwritten() {
        var stats = AudioCaptureStats()
        stats.record(peak: 0.0, frames: 1024, offset: 0.0)    // silent
        stats.record(peak: 0.0, frames: 1024, offset: 0.5)    // silent
        stats.record(peak: 0.3, frames: 1024, offset: 1.2)    // first audio here
        stats.record(peak: 0.6, frames: 1024, offset: 1.8)    // louder, but offset stays
        XCTAssertEqual(stats.firstAudioOffset, 1.2)
        XCTAssertEqual(stats.peak, 0.6, accuracy: 0.0001)
        XCTAssertEqual(stats.silentBufferCount, 2)
        XCTAssertTrue(stats.summary.contains("firstAudio=1.20s"))
    }

    /// The first-non-silent detection is the pure piece the live `captureProducedAudio`
    /// signal is built on: `record` must return true on exactly the buffer that crosses
    /// from silence to audio, and false on every other (silent before, or non-silent after).
    func testRecordReturnsTrueOnlyOnTheFirstNonSilentBuffer() {
        var stats = AudioCaptureStats()
        XCTAssertFalse(stats.record(peak: 0.0, frames: 1024, offset: 0.0), "silent → not first audio")
        XCTAssertFalse(stats.record(peak: 0.001, frames: 1024, offset: 0.1), "below threshold → still silent")
        XCTAssertTrue(stats.record(peak: 0.4, frames: 1024, offset: 0.2), "first non-silent buffer → true (once)")
        XCTAssertFalse(stats.record(peak: 0.9, frames: 1024, offset: 0.3), "subsequent audio → false")
        XCTAssertFalse(stats.record(peak: 0.0, frames: 1024, offset: 0.4), "later silence → false")
    }

    func testRecordReturnsTrueOnImmediateFirstBufferWhenNonSilent() {
        var stats = AudioCaptureStats()
        XCTAssertTrue(stats.record(peak: 0.5, frames: 1024, offset: 0.0),
                      "a non-silent very first buffer is still the first-audio edge")
    }

    func testSilenceThresholdIsInclusive() {
        var stats = AudioCaptureStats()
        XCTAssertFalse(stats.record(peak: AudioCaptureStats.silenceThreshold, frames: 256, offset: 0.0))
        XCTAssertEqual(stats.silentBufferCount, 1, "peak == threshold counts as silence")
        XCTAssertNil(stats.firstAudioOffset)

        XCTAssertTrue(stats.record(peak: AudioCaptureStats.silenceThreshold + 0.001, frames: 256, offset: 0.1))
        XCTAssertEqual(stats.silentBufferCount, 1, "just above threshold is non-silent")
        XCTAssertEqual(stats.firstAudioOffset, 0.1)
    }

    func testSummaryReportsPartialSilencePercent() {
        var stats = AudioCaptureStats()
        stats.record(peak: 0.0, frames: 512, offset: 0.0)  // silent
        stats.record(peak: 0.0, frames: 512, offset: 0.1)  // silent
        stats.record(peak: 0.0, frames: 512, offset: 0.2)  // silent
        stats.record(peak: 0.4, frames: 512, offset: 0.3)  // audio
        XCTAssertTrue(stats.summary.contains("silent=75%"), "3 of 4 buffers silent; got: \(stats.summary)")
        XCTAssertTrue(stats.summary.contains("buffers=4"))
    }

    // MARK: - AudioCaptureMonitor (thread-safe wrapper + live signals)

    func testMonitorComputesOffsetFromStartTimeAndAccumulates() {
        let start: TimeInterval = 1000.0
        let monitor = AudioCaptureMonitor(startTime: start)
        monitor.record(peak: 0.0, frames: 1024, at: start + 0.0)   // silent at t0
        monitor.record(peak: 0.5, frames: 1024, at: start + 0.75)  // first audio at +0.75s

        let snap = monitor.snapshot()
        XCTAssertEqual(snap.bufferCount, 2)
        XCTAssertEqual(snap.firstAudioOffset, 0.75)   // 0.75 is exactly representable
        XCTAssertEqual(snap.peak, 0.5, accuracy: 0.0001)
    }

    func testMonitorSnapshotIsStableAfterMoreRecording() {
        let monitor = AudioCaptureMonitor(startTime: 0)
        monitor.record(peak: 0.2, frames: 100, at: 0.1)
        let first = monitor.snapshot()
        monitor.record(peak: 0.2, frames: 100, at: 0.2)
        XCTAssertEqual(first.bufferCount, 1, "snapshot is a value copy; later records don't mutate it")
        XCTAssertEqual(monitor.snapshot().bufferCount, 2)
    }

    /// Live buffer count is what the session executor's `captureGrace` timer reads to
    /// detect a dead route (still zero ⇒ `captureStalled`). It must reflect every
    /// buffer, silent ones included (a silent-but-present route is F2, not F3).
    func testMonitorBufferCountIsLiveAndCountsSilentBuffers() {
        let monitor = AudioCaptureMonitor(startTime: 0)
        XCTAssertEqual(monitor.bufferCount, 0, "no buffers yet")
        monitor.record(peak: 0.0, frames: 1024, at: 0.05)   // silent, but the route IS live
        XCTAssertEqual(monitor.bufferCount, 1)
        monitor.record(peak: 0.3, frames: 1024, at: 0.1)
        XCTAssertEqual(monitor.bufferCount, 2)
    }

    /// The live first-audio signal: `onFirstAudio` fires exactly once, on the first
    /// non-silent buffer — never on leading silence, never again afterward. This is
    /// what feeds the reducer's `captureProducedAudio` (F3 readiness).
    func testMonitorFiresOnFirstAudioExactlyOnce() {
        var fireCount = 0
        let monitor = AudioCaptureMonitor(startTime: 0) { fireCount += 1 }

        monitor.record(peak: 0.0, frames: 1024, at: 0.0)   // silent → no fire
        monitor.record(peak: 0.001, frames: 1024, at: 0.1) // below threshold → no fire
        XCTAssertEqual(fireCount, 0, "no non-silent buffer yet → callback must not fire")

        monitor.record(peak: 0.4, frames: 1024, at: 0.2)   // first audio → fire
        XCTAssertEqual(fireCount, 1)

        monitor.record(peak: 0.9, frames: 1024, at: 0.3)   // more audio → no re-fire
        monitor.record(peak: 0.0, frames: 1024, at: 0.4)   // silence again → no fire
        XCTAssertEqual(fireCount, 1, "first-audio signal is one-shot per monitor")
    }

    func testMonitorDoesNotFireWhenAllBuffersSilent() {
        var fired = false
        let monitor = AudioCaptureMonitor(startTime: 0) { fired = true }
        for i in 0..<5 { monitor.record(peak: 0.0, frames: 1024, at: Double(i) * 0.05) }
        XCTAssertFalse(fired, "an all-silent route never produced audio → no readiness signal")
    }
}
