// BlueParrottEventParser.swift
// Pure decode of a BlueParrott GATT button-event notification payload to a
// logical gesture — the unit-testable core of the macOS CoreBluetooth client.
//
// Platform-agnostic and SDK-free, so it compiles into BOTH the iOS and macOS
// targets; the macOS `BlueParrottBLEManager` (b4i.9/b4i.10) feeds it the raw
// notification bytes from the button-event characteristic `66339E60-…`.
//
// Opcodes were captured on-hardware in Phase A2 (firmware 2.6.4); see
// @docs/design/macos-blueparrott-corebluetooth.md §3 (button parser). A single
// tap arrives as `01,00,02` (down, up, tap), a double as `01,00,01,00,03`, and a
// hold as `01,04,00` (down, long-press ~1s after down, up) — every gesture is
// bracketed by down/up, which the b4i.10 dispatcher must account for.

import Foundation

/// Logical button gesture, decoded from a raw GATT notification. Mirrors the
/// events iOS's `BPHeadsetListener` delivers, so both platforms converge on one
/// `BlueParrottButtonDelegate`.
enum BlueParrottButtonEvent: Equatable {
    case down
    case up
    case tap
    case doubleTap
    case longPress
}

enum BlueParrottEventParser {
    /// Decode a raw notification payload from the button-event characteristic.
    /// Returns nil for unrecognized payloads — callers log and drop, never guess
    /// (criterion: never misclassify). Opcodes are frozen from the Phase A2
    /// capture; the gesture rides in the first byte.
    static func parse(_ data: Data) -> BlueParrottButtonEvent? {
        guard let opcode = data.first else { return nil } // edge: empty payload
        switch opcode {
        case 0x01: return .down
        case 0x00: return .up
        case 0x02: return .tap
        case 0x03: return .doubleTap
        case 0x04: return .longPress
        default:   return nil                              // edge: unknown opcode
        }
    }
}
