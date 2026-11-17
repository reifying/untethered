// DrivingModeLayoutTests.swift
// The driving screen's geometry: whatever the window size, the status strip, the
// replay tiles and the talk bar fill it exactly and none of them is outside it.
// That is the property "the microphone button can never end up off-screen"
// rests on. See notes/mac-driving-mode.md.

import XCTest
import CoreGraphics
@testable import VoiceCode

final class DrivingModeLayoutTests: XCTestCase {

    private let sizes: [CGSize] = [
        CGSize(width: 320, height: 240),      // the minimum window
        CGSize(width: 800, height: 500),
        CGSize(width: 1512, height: 944),     // a 14-inch MacBook Pro's visible screen
        CGSize(width: 3840, height: 2160),
        CGSize(width: 2000, height: 120),     // absurdly short
        CGSize(width: 90, height: 1400)       // absurdly narrow
    ]

    func testBandsFillTheContainerExactlyAtEverySize() {
        for size in sizes {
            for count in DrivingModeLayout.minReplayCount...DrivingModeLayout.maxReplayCount {
                let bands = DrivingModeLayout.bands(in: size, replayCount: count)
                let all = [bands.status] + bands.tiles + [bands.talk]
                let container = CGRect(origin: .zero, size: size)

                XCTAssertEqual(bands.tiles.count, count)
                var y: CGFloat = 0
                for band in all {
                    XCTAssertEqual(band.minY, y, accuracy: 0.001, "bands stack with no gap or overlap at \(size)")
                    XCTAssertEqual(band.width, size.width)
                    XCTAssertTrue(container.insetBy(dx: -0.001, dy: -0.001).contains(band),
                                  "a band is outside the window at \(size), \(count) tiles")
                    y = band.maxY
                }
                XCTAssertEqual(y, size.height, accuracy: 0.001, "the bands must use the whole height at \(size)")
            }
        }
    }

    func testTilesAreEqualAndTheTalkBarIsAlwaysThere() {
        for size in sizes {
            let bands = DrivingModeLayout.bands(in: size, replayCount: 3)
            XCTAssertEqual(bands.tiles[0].height, bands.tiles[1].height, accuracy: 0.001)
            XCTAssertEqual(bands.tiles[1].height, bands.tiles[2].height, accuracy: 0.001)
            XCTAssertGreaterThan(bands.talk.height, 0, "the talk bar has room at \(size)")
            XCTAssertGreaterThan(bands.status.height, 0)
            XCTAssertGreaterThanOrEqual(bands.tiles[0].height, 0)
        }
    }

    /// The talk bar is the button a driver has to hit without looking, so it is as
    /// tall as each reply tile rather than a thin strip under them.
    func testTheTalkBarIsAsTallAsEachReplyTile() {
        for size in sizes {
            for count in DrivingModeLayout.minReplayCount...DrivingModeLayout.maxReplayCount {
                let bands = DrivingModeLayout.bands(in: size, replayCount: count)
                for tile in bands.tiles {
                    XCTAssertEqual(bands.talk.height, tile.height, accuracy: 0.001,
                                   "the talk bar and a tile differ in height at \(size), \(count) tiles")
                }
            }
        }
    }

    func testTheTalkBarStaysAsTallAsATileWhateverTheReplayCount() {
        let size = CGSize(width: 1512, height: 944)
        let one = DrivingModeLayout.bands(in: size, replayCount: 1).talk.height
        let five = DrivingModeLayout.bands(in: size, replayCount: 5).talk.height
        XCTAssertGreaterThan(one, five, "fewer tiles means each, and the talk bar, gets taller")
        XCTAssertGreaterThan(five, 100, "even with five tiles the talk bar is a large target")
    }

    func testTheTilesAndTalkBarGetMostOfANormalScreen() {
        let bands = DrivingModeLayout.bands(in: CGSize(width: 1512, height: 944), replayCount: 3)
        let body = bands.tiles.reduce(0) { $0 + $1.height } + bands.talk.height
        XCTAssertGreaterThan(body / 944, 0.85, "the replay tiles and the talk bar are the point of the screen")
        XCTAssertGreaterThan(bands.tiles[0].height, 200, "each one is a target that is hard to miss")
        XCTAssertGreaterThan(bands.talk.height, 200, "the talk bar is as easy to hit as a tile")
    }

    func testAZeroOrNegativeSizeDoesNotProduceNegativeBands() {
        for size in [CGSize.zero, CGSize(width: -10, height: -10)] {
            let bands = DrivingModeLayout.bands(in: size, replayCount: 3)
            for band in [bands.status] + bands.tiles + [bands.talk] {
                XCTAssertGreaterThanOrEqual(band.width, 0)
                XCTAssertGreaterThanOrEqual(band.height, 0)
            }
        }
    }

    func testReplayCountIsClamped() {
        XCTAssertEqual(DrivingModeLayout.clampedReplayCount(0), 1)
        XCTAssertEqual(DrivingModeLayout.clampedReplayCount(-4), 1)
        XCTAssertEqual(DrivingModeLayout.clampedReplayCount(3), 3)
        XCTAssertEqual(DrivingModeLayout.clampedReplayCount(99), 5)
        XCTAssertEqual(DrivingModeLayout.defaultReplayCount, 3)
        XCTAssertEqual(DrivingModeLayout.bands(in: CGSize(width: 800, height: 600), replayCount: 99).tiles.count, 5)
    }

    // MARK: - Keeping the window on the screen

    private let visible = CGRect(x: 0, y: 70, width: 1512, height: 944)

    func testTheWindowIsPinnedToTheVisibleScreen() {
        XCTAssertEqual(DrivingModeLayout.pinnedFrame(visibleFrame: visible), visible)
    }

    func testAWindowInsideTheScreenIsLeftAlone() {
        XCTAssertFalse(DrivingModeLayout.needsRepin(frame: visible, visibleFrame: visible))
        XCTAssertFalse(DrivingModeLayout.needsRepin(frame: visible.insetBy(dx: 200, dy: 100), visibleFrame: visible))
        XCTAssertFalse(DrivingModeLayout.needsRepin(frame: visible.insetBy(dx: -0.5, dy: -0.5), visibleFrame: visible),
                       "sub-point rounding from the window server is not a reason to move the window")
    }

    /// The reported failure: the window grew downward and its bottom edge, with the
    /// microphone button on it, went below the bottom of the screen.
    func testAWindowWhoseBottomIsBelowTheScreenIsPutBack() {
        let grownDownward = CGRect(x: 100, y: -400, width: 900, height: 1300)
        XCTAssertTrue(DrivingModeLayout.needsRepin(frame: grownDownward, visibleFrame: visible))
    }

    func testAWindowOffAnyEdgeIsPutBack() {
        XCTAssertTrue(DrivingModeLayout.needsRepin(frame: visible.offsetBy(dx: 300, dy: 0), visibleFrame: visible))
        XCTAssertTrue(DrivingModeLayout.needsRepin(frame: visible.offsetBy(dx: -300, dy: 0), visibleFrame: visible))
        XCTAssertTrue(DrivingModeLayout.needsRepin(frame: visible.offsetBy(dx: 0, dy: 300), visibleFrame: visible))
        XCTAssertTrue(DrivingModeLayout.needsRepin(frame: CGRect(x: 5000, y: 5000, width: 800, height: 600),
                                                   visibleFrame: visible),
                      "left behind on a display that was unplugged")
    }

    func testWithNoScreenToMeasureAgainstNothingIsMoved() {
        XCTAssertFalse(DrivingModeLayout.needsRepin(frame: visible, visibleFrame: .zero))
    }

    func testTileTitles() {
        XCTAssertEqual(DrivingModeLayout.tileTitle(index: 0), "Latest reply")
        XCTAssertEqual(DrivingModeLayout.tileTitle(index: 1), "One before")
        XCTAssertEqual(DrivingModeLayout.tileTitle(index: 2), "2 before")
    }
}
