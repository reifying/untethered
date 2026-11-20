// DrivingModeLayout.swift
// The geometry of the driving-mode screen as pure functions, so "no control can
// end up off-screen" is something a unit test can assert.
//
// The screen is three kinds of horizontal band that always add up to exactly the
// height they are given: a status strip, the replay tiles, and a bottom row. The
// bottom row is as tall as one tile and holds two buttons, each half the width:
// talk and silence. They are the controls a driver must hit without looking, so
// they are not a thin strip under the tiles. Nothing is sized by its
// content. A long reply is truncated inside its tile; it never
// makes the tile, the window, or anything below it grow. That is the opposite of
// the conversation view, whose input area grows with its content and can push
// the microphone button below the bottom of the screen.

import Foundation
import CoreGraphics

enum DrivingModeLayout {
    static let minReplayCount = 1
    static let maxReplayCount = 5
    static let defaultReplayCount = 3

    /// The smallest window the screen still works in. Deliberately tiny: the
    /// window is never forced to be larger than a display can show.
    static let minimumSize = CGSize(width: 320, height: 240)

    static func clampedReplayCount(_ count: Int) -> Int {
        min(max(count, minReplayCount), maxReplayCount)
    }

    /// The bands of the screen, top to bottom, in the coordinate space of a
    /// container of `size` (origin top-left, as SwiftUI lays out).
    struct Bands: Equatable {
        let status: CGRect
        let tiles: [CGRect]
        /// The left half of the bottom row.
        let talk: CGRect
        /// The right half of the bottom row: stops the reply being read.
        let silence: CGRect
    }

    /// Split `size` into the status strip, then `replayCount` tiles and a bottom
    /// row, all the same height. The bottom row is two buttons side by side, each
    /// half the width: talk on the left, silence on the right. The bands tile the
    /// container exactly: no gaps, no overlap, nothing outside it, whatever the size.
    static func bands(in size: CGSize, replayCount: Int) -> Bands {
        let count = clampedReplayCount(replayCount)
        let width = max(size.width, 0)
        let height = max(size.height, 0)
        // The strip takes a fixed share, bounded so it stays usable on a small
        // window and does not eat a large one. Everything below it is split into
        // equal rows: one per tile, and one more for the talk bar.
        let statusHeight = min(max(height * 0.10, 28), 72, height * 0.2)
        let rowHeight = max(height - statusHeight, 0) / CGFloat(count + 1)
        let tiles = (0..<count).map { index in
            CGRect(x: 0, y: statusHeight + CGFloat(index) * rowHeight, width: width, height: rowHeight)
        }
        let bottomY = statusHeight + CGFloat(count) * rowHeight
        let half = width / 2
        return Bands(
            status: CGRect(x: 0, y: 0, width: width, height: statusHeight),
            tiles: tiles,
            talk: CGRect(x: 0, y: bottomY, width: half, height: rowHeight),
            silence: CGRect(x: half, y: bottomY, width: width - half, height: rowHeight)
        )
    }

    /// Where the driving window belongs: filling the part of the screen that is
    /// actually visible (inside the menu bar and the Dock).
    static func pinnedFrame(visibleFrame: CGRect) -> CGRect {
        visibleFrame
    }

    /// Whether `frame` needs to be put back. True when any part of the window is
    /// outside the visible screen, which is how a control ends up unreachable.
    /// A one-point tolerance absorbs rounding from the window server.
    static func needsRepin(frame: CGRect, visibleFrame: CGRect) -> Bool {
        guard !visibleFrame.isEmpty else { return false }
        return !visibleFrame.insetBy(dx: -1, dy: -1).contains(frame)
    }

    /// What a tile is called, by position. Tile 0 is always the newest reply.
    static func tileTitle(index: Int) -> String {
        switch index {
        case 0: return "Latest reply"
        case 1: return "One before"
        default: return "\(index) before"
        }
    }
}
