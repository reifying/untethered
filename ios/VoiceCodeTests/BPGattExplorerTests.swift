// BPGattExplorerTests.swift
// Unit tests for the Phase A2 GATT explorer's pure formatting/classification
// helpers, plus construction/teardown safety. The explorer's CoreBluetooth
// plumbing (scan/connect/discover) needs real hardware and is exercised in the
// manual App-Mode persistence experiment, not here — mirroring how BPSniffer's
// swizzle plumbing is left to manual capture while its pure helpers are tested.
//
// BPGattExplorer is `#if DEBUG` on BOTH platforms, so these tests are
// cross-platform (no project.yml exclude) and run under `make test` (iOS) and
// `make test-mac` (macOS).

import XCTest
import CoreBluetooth
@testable import VoiceCode

#if DEBUG

final class BPGattExplorerTests: XCTestCase {

    private func char(_ uuid: String, _ properties: CBCharacteristicProperties) -> CBCharacteristic {
        // value: nil is required for notifying characteristics; readable/writeable
        // permissions keep CBMutableCharacteristic from asserting on construction.
        CBMutableCharacteristic(type: CBUUID(string: uuid),
                                properties: properties,
                                value: nil,
                                permissions: [.readable, .writeable])
    }

    // MARK: - hex

    func testHex_formatsLowercaseSpaceSeparated() {
        XCTAssertEqual(BPGattExplorer.hex(Data([0x00, 0x01, 0xab, 0xff])), "00 01 ab ff")
    }

    func testHex_singleByte() {
        XCTAssertEqual(BPGattExplorer.hex(Data([0x05])), "05")
    }

    func testHex_emptyData() {
        XCTAssertEqual(BPGattExplorer.hex(Data()), "")
    }

    func testHex_nilData() {
        XCTAssertEqual(BPGattExplorer.hex(nil), "<nil>")
    }

    // MARK: - describeProperties

    func testDescribeProperties_singleProperty() {
        XCTAssertEqual(BPGattExplorer.describeProperties(.notify), "notify")
        XCTAssertEqual(BPGattExplorer.describeProperties(.read), "read")
        XCTAssertEqual(BPGattExplorer.describeProperties(.write), "write")
    }

    func testDescribeProperties_multipleProperties_inDeclaredOrder() {
        // read|write|notify regardless of how the OptionSet is assembled.
        let line = BPGattExplorer.describeProperties([.notify, .write, .read])
        XCTAssertEqual(line, "read|write|notify")
    }

    func testDescribeProperties_indicateAndWriteWithoutResponse() {
        let line = BPGattExplorer.describeProperties([.indicate, .writeWithoutResponse])
        XCTAssertEqual(line, "writeWithoutResponse|indicate")
    }

    func testDescribeProperties_empty() {
        XCTAssertEqual(BPGattExplorer.describeProperties([]), "none")
    }

    // MARK: - isSubscribable

    func testIsSubscribable_trueForNotify() {
        XCTAssertTrue(BPGattExplorer.isSubscribable(.notify))
    }

    func testIsSubscribable_trueForIndicate() {
        XCTAssertTrue(BPGattExplorer.isSubscribable(.indicate))
    }

    func testIsSubscribable_trueWhenNotifyAmongOthers() {
        XCTAssertTrue(BPGattExplorer.isSubscribable([.read, .write, .notify]))
    }

    func testIsSubscribable_falseForReadWriteOnly() {
        XCTAssertFalse(BPGattExplorer.isSubscribable([.read, .write]))
    }

    func testIsSubscribable_falseForEmpty() {
        XCTAssertFalse(BPGattExplorer.isSubscribable([]))
    }

    // MARK: - Log line formatting

    func testFormatService_includesUuid() {
        let service = CBMutableService(type: BPGattExplorer.serviceUUID, primary: true)
        XCTAssertEqual(BPGattExplorer.formatService(service),
                       "SERVICE 95665A00-8704-11E5-960C-0002A5D5C51B")
    }

    func testFormatCharacteristic_includesUuidAndProperties() {
        let characteristic = char("95665A01-8704-11E5-960C-0002A5D5C51B", [.read, .notify])
        XCTAssertEqual(BPGattExplorer.formatCharacteristic(characteristic),
                       "CHAR 95665A01-8704-11E5-960C-0002A5D5C51B [read|notify]")
    }

    func testFormatNotification_includesUuidAndHex() {
        let characteristic = char("95665A01-8704-11E5-960C-0002A5D5C51B", [.notify])
        XCTAssertEqual(BPGattExplorer.formatNotification(characteristic, Data([0x01])),
                       "NOTIFY 95665A01-8704-11E5-960C-0002A5D5C51B → 01")
    }

    func testFormatNotification_nilValue() {
        let characteristic = char("95665A01-8704-11E5-960C-0002A5D5C51B", [.notify])
        XCTAssertEqual(BPGattExplorer.formatNotification(characteristic, nil),
                       "NOTIFY 95665A01-8704-11E5-960C-0002A5D5C51B → <nil>")
    }

    // MARK: - Lifecycle safety (no CoreBluetooth spun up without start)

    func testInit_succeeds() {
        let explorer = BPGattExplorer()
        XCTAssertNotNil(explorer)
    }

    func testStop_beforeStart_doesNotCrash() {
        let explorer = BPGattExplorer()
        explorer.stop()
    }
}

#endif
