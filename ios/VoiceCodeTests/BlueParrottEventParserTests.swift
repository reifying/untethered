// BlueParrottEventParserTests.swift
// Unit tests for the pure BlueParrott byte→event parser. The opcodes and the
// multi-event gesture sequences below are the real on-hardware captures from
// Phase A2 (firmware 2.6.4, char 66339E60-…), per the design doc §3.
//
// The parser is platform-agnostic, so this file is unguarded and runs under both
// `make test` (iOS) and `make test-mac` (macOS) — no project.yml exclude.

import XCTest
@testable import VoiceCode

final class BlueParrottEventParserTests: XCTestCase {

    // MARK: - Each gesture decodes (captured opcodes)

    func testDecodesEachGesture() {
        XCTAssertEqual(BlueParrottEventParser.parse(Data([0x01])), .down)
        XCTAssertEqual(BlueParrottEventParser.parse(Data([0x00])), .up)
        XCTAssertEqual(BlueParrottEventParser.parse(Data([0x02])), .tap)
        XCTAssertEqual(BlueParrottEventParser.parse(Data([0x03])), .doubleTap)
        XCTAssertEqual(BlueParrottEventParser.parse(Data([0x04])), .longPress)
    }

    // MARK: - Edge cases → nil (never misclassify)

    func testEmptyPayloadReturnsNil() {
        XCTAssertNil(BlueParrottEventParser.parse(Data()))
    }

    func testUnknownOpcodeReturnsNil() {
        XCTAssertNil(BlueParrottEventParser.parse(Data([0xFF])))
        XCTAssertNil(BlueParrottEventParser.parse(Data([0x05]))) // 0x05 unobserved
        XCTAssertNil(BlueParrottEventParser.parse(Data([0x10])))
    }

    // MARK: - Real captured multi-event sequences

    func testCapturedTapSequence() {
        // 21:22:20 capture — a single physical tap.
        let stream: [UInt8] = [0x01, 0x00, 0x02]
        XCTAssertEqual(stream.map { BlueParrottEventParser.parse(Data([$0])) },
                       [.down, .up, .tap])
    }

    func testCapturedDoubleTapSequence() {
        // 21:22:31 capture — two quick presses then the double-tap classifier.
        let stream: [UInt8] = [0x01, 0x00, 0x01, 0x00, 0x03]
        XCTAssertEqual(stream.map { BlueParrottEventParser.parse(Data([$0])) },
                       [.down, .up, .down, .up, .doubleTap])
    }

    func testCapturedLongPressSequence() {
        // 21:28:28 capture — long-press fires ~1s after down, then up on release.
        let stream: [UInt8] = [0x01, 0x04, 0x00]
        XCTAssertEqual(stream.map { BlueParrottEventParser.parse(Data([$0])) },
                       [.down, .longPress, .up])
    }

    // MARK: - Contract: gesture rides in the first byte

    func testTrailingBytesIgnored() {
        // Captured payloads are single-byte; a longer payload decodes on byte 0.
        XCTAssertEqual(BlueParrottEventParser.parse(Data([0x01, 0xAB, 0xCD])), .down)
    }
}
