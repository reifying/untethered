import XCTest
import CoreBluetooth
import ObjectiveC.runtime
@testable import VoiceCode

#if DEBUG && os(iOS)

// MARK: - Test doubles

/// A delegate that implements the notify method — `hookNotify` should hook it.
private final class ConformingNotifyDelegate: NSObject, CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {}
}

/// A delegate that omits the (optional) notify method — `hookNotify` should skip it.
private final class NonNotifyDelegate: NSObject, CBPeripheralDelegate {}

/// Base implementing the notify method, plus a subclass that *inherits* it
/// without overriding — exercises the inherited-method detection in `hookNotify`.
private class BaseNotifyDelegate: NSObject, CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {}
}
private final class InheritingNotifyDelegate: BaseNotifyDelegate {}

/// A plain class with two ObjC methods, to exercise the same-class swizzle path
/// (the mechanism the CBPeripheral write hook relies on) without CoreBluetooth.
private final class SwizzleSubject: NSObject {
    @objc dynamic func original() -> String { "original" }
    @objc dynamic func bp_replacement() -> String { "replacement" }
}

/// Donor host for a cross-class swizzle test (mirrors how `BPNotifyHook` grafts
/// its IMP onto the SDK's private delegate class at runtime).
private final class SwizzleDonor: NSObject {
    @objc dynamic func donor_replacement() -> String { "from-donor" }
}

/// Target whose `original` gets replaced by the donor IMP.
private final class SwizzleTarget: NSObject {
    @objc dynamic func original() -> String { "target-original" }
}

final class BPSnifferTests: XCTestCase {

    // `resetForTesting()` clears only BPSniffer's bookkeeping — it does NOT
    // un-swizzle the ObjC runtime, so install/hook exchanges persist across tests
    // in this process. That is harmless: no real `CBPeripheral` is exercised, and
    // assertions check bookkeeping + `instancesRespond(to:)`, not live redirects.
    override func setUp() {
        super.setUp()
        BPSniffer.resetForTesting()
        LogManager.shared.clearLogs()
    }

    override func tearDown() {
        BPSniffer.resetForTesting()
        LogManager.shared.clearLogs()
        super.tearDown()
    }

    private func char(_ uuid: String) -> CBCharacteristic {
        CBMutableCharacteristic(type: CBUUID(string: uuid), properties: [.write, .notify], value: nil, permissions: [.writeable])
    }

    // MARK: - Data.bpHex

    func testBpHex_formatsLowercaseSpaceSeparated() {
        XCTAssertEqual(Data([0x00, 0x01, 0xab, 0xff]).bpHex, "00 01 ab ff")
    }

    func testBpHex_emptyData() {
        XCTAssertEqual(Data().bpHex, "")
    }

    // MARK: - Log line formatting

    func testFormatWrite_includesUuidAndHex() {
        let line = BPSniffer.formatWrite(char("95665A02-8704-11E5-960C-0002A5D5C51B"), Data([0x01, 0x02]))
        XCTAssertEqual(line, "WRITE 95665A02-8704-11E5-960C-0002A5D5C51B ← 01 02")
    }

    func testFormatUpdate_includesUuidAndHex() {
        let line = BPSniffer.formatUpdate(char("95665A01-8704-11E5-960C-0002A5D5C51B"), Data([0x03]))
        XCTAssertEqual(line, "NOTIFY 95665A01-8704-11E5-960C-0002A5D5C51B → 03")
    }

    func testFormatUpdate_nilData() {
        let line = BPSniffer.formatUpdate(char("95665A01-8704-11E5-960C-0002A5D5C51B"), nil)
        XCTAssertEqual(line, "NOTIFY 95665A01-8704-11E5-960C-0002A5D5C51B → <nil>")
    }

    // MARK: - LogManager routing (category "BPSniff")

    func testLogWrite_routesThroughBPSniffCategory() {
        BPSniffer.logWrite(char("95665A02-8704-11E5-960C-0002A5D5C51B"), Data([0xde, 0xad]))
        let logs = LogManager.shared.getAllLogs()
        XCTAssertTrue(logs.contains("[BPSniff]"), "expected BPSniff category, got: \(logs)")
        XCTAssertTrue(logs.contains("WRITE 95665A02-8704-11E5-960C-0002A5D5C51B ← de ad"), logs)
    }

    func testLogUpdate_routesThroughBPSniffCategory() {
        BPSniffer.logUpdate(char("95665A01-8704-11E5-960C-0002A5D5C51B"), Data([0x05]))
        let logs = LogManager.shared.getAllLogs()
        XCTAssertTrue(logs.contains("[BPSniff]"), logs)
        XCTAssertTrue(logs.contains("NOTIFY 95665A01-8704-11E5-960C-0002A5D5C51B → 05"), logs)
    }

    // MARK: - Swizzle primitive: same-class exchange

    func testSwizzle_sameClass_exchangesImplementations() {
        let before = SwizzleSubject().original()
        XCTAssertEqual(before, "original")

        let ok = BPSniffer.swizzle(
            target: SwizzleSubject.self,
            original: #selector(SwizzleSubject.original),
            donor: SwizzleSubject.self,
            replacement: #selector(SwizzleSubject.bp_replacement)
        )
        XCTAssertTrue(ok)
        // After exchange, calling `original` runs the replacement IMP.
        XCTAssertEqual(SwizzleSubject().original(), "replacement")

        // Restore so the swizzle does not leak into other tests.
        BPSniffer.swizzle(
            target: SwizzleSubject.self,
            original: #selector(SwizzleSubject.original),
            donor: SwizzleSubject.self,
            replacement: #selector(SwizzleSubject.bp_replacement)
        )
        XCTAssertEqual(SwizzleSubject().original(), "original")
    }

    // MARK: - Swizzle primitive: cross-class graft (delegate-style)

    func testSwizzle_crossClass_graftsDonorImpOntoTarget() {
        XCTAssertEqual(SwizzleTarget().original(), "target-original")

        let ok = BPSniffer.swizzle(
            target: SwizzleTarget.self,
            original: #selector(SwizzleTarget.original),
            donor: SwizzleDonor.self,
            replacement: #selector(SwizzleDonor.donor_replacement)
        )
        XCTAssertTrue(ok)
        // The target's `original` selector now runs the donor's IMP.
        XCTAssertEqual(SwizzleTarget().original(), "from-donor")
        // And the target gained the replacement selector (the grafted method).
        XCTAssertTrue(SwizzleTarget.instancesRespond(to: #selector(SwizzleDonor.donor_replacement)))
    }

    func testSwizzle_returnsFalse_whenTargetLacksOriginalSelector() {
        let ok = BPSniffer.swizzle(
            target: NonNotifyDelegate.self,
            original: BPSniffer.didUpdateValueSelector,
            donor: BPNotifyHook.self,
            replacement: #selector(BPNotifyHook.bp_peripheral(_:didUpdateValueFor:error:))
        )
        XCTAssertFalse(ok)
    }

    // MARK: - hookNotify: runtime delegate discovery

    func testHookNotify_hooksConformingDelegateClass() {
        let delegate = ConformingNotifyDelegate()
        XCTAssertFalse(BPSniffer.isDelegateClassHooked(ConformingNotifyDelegate.self))

        let hooked = BPSniffer.hookNotify(onDelegateClassOf: delegate)
        XCTAssertTrue(hooked)
        XCTAssertTrue(BPSniffer.isDelegateClassHooked(ConformingNotifyDelegate.self))
        // The grafted forwarding selector is present on the delegate class.
        XCTAssertTrue(ConformingNotifyDelegate.instancesRespond(
            to: #selector(BPNotifyHook.bp_peripheral(_:didUpdateValueFor:error:))))
    }

    func testHookNotify_isIdempotentPerClass() {
        let first = BPSniffer.hookNotify(onDelegateClassOf: ConformingNotifyDelegate())
        let second = BPSniffer.hookNotify(onDelegateClassOf: ConformingNotifyDelegate())
        XCTAssertTrue(first)
        XCTAssertFalse(second, "same delegate class should not be hooked twice")
    }

    func testHookNotify_warnsButHooks_whenNotifyMethodIsInherited() {
        let hooked = BPSniffer.hookNotify(onDelegateClassOf: InheritingNotifyDelegate())
        XCTAssertTrue(hooked, "an inherited notify method is still hookable")
        XCTAssertTrue(BPSniffer.isDelegateClassHooked(InheritingNotifyDelegate.self))
        let logs = LogManager.shared.getAllLogs()
        XCTAssertTrue(logs.contains("inherits didUpdateValueForCharacteristic"),
                      "expected an inherited-method warning, got: \(logs)")
    }

    func testHookNotify_skipsDelegateWithoutNotifyMethod() {
        let hooked = BPSniffer.hookNotify(onDelegateClassOf: NonNotifyDelegate())
        XCTAssertFalse(hooked)
        XCTAssertFalse(BPSniffer.isDelegateClassHooked(NonNotifyDelegate.self))
        let logs = LogManager.shared.getAllLogs()
        XCTAssertTrue(logs.contains("notify hook skipped"), logs)
    }

    // MARK: - install()

    func testInstall_isIdempotent() {
        XCTAssertFalse(BPSniffer.isInstalled)
        BPSniffer.install()
        XCTAssertTrue(BPSniffer.isInstalled)
        // Second call is a no-op (does not re-swizzle CBPeripheral).
        BPSniffer.install()
        XCTAssertTrue(BPSniffer.isInstalled)
        let logs = LogManager.shared.getAllLogs()
        let installLines = logs.components(separatedBy: "\n").filter { $0.contains("installed (writeHook=") }
        XCTAssertEqual(installLines.count, 1, "install should log exactly once: \(logs)")
    }
}

#endif
