// BPSniffer.swift
// DEBUG-only collector that captures the proprietary BlueParrott GATT protocol
// (characteristic UUIDs, App-Mode enable write, button-event byte format) by
// instrumenting the working iOS BPHeadset SDK with Objective-C method swizzling.
//
// See @docs/design/macos-blueparrott-corebluetooth.md §3 (Phase A1). Output goes
// to LogManager (category "BPSniff") so it lands in the in-app Captured Logs the
// user already shares. Diagnostic only — `#if DEBUG && os(iOS)`, never shipped.

#if DEBUG && os(iOS)
import Foundation
import CoreBluetooth
import ObjectiveC.runtime

/// Logs every characteristic write the SDK performs and every value-update its
/// peripheral delegate receives. The write side is captured by swizzling
/// `CBPeripheral.writeValue(_:for:type:)`; the notify side by discovering the
/// SDK's private peripheral delegate at runtime (it is assigned via
/// `CBPeripheral.delegate`) and swizzling its
/// `peripheral:didUpdateValueForCharacteristic:error:`.
enum BPSniffer {
    static let logCategory = "BPSniff"

    /// `CBPeripheralDelegate.peripheral(_:didUpdateValueFor:error:)` for the
    /// **characteristic** overload. Spelled as an explicit ObjC selector because
    /// the Swift `#selector` is ambiguous with the `CBDescriptor` overload.
    static let didUpdateValueSelector = NSSelectorFromString("peripheral:didUpdateValueForCharacteristic:error:")

    /// Guards `didInstall` and `hookedDelegateClasses`. `install()` runs on the
    /// main thread, but the delegate-discovery path (`hookNotify`, via the
    /// swizzled `setDelegate:`) fires on whichever queue the SDK assigns its
    /// delegate on — so the shared state needs synchronization, not a bare `var`.
    private static let stateLock = NSLock()
    private static var didInstall = false
    /// Delegate classes whose notify method has already been hooked, keyed by
    /// class identity so a reconnect (same class, new instance) is not re-hooked.
    private static var hookedDelegateClasses = Set<ObjectIdentifier>()

    private static func withLock<T>(_ body: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }

    /// Whether `install()` has run. Test accessor.
    static var isInstalled: Bool { withLock { didInstall } }

    /// Install the write hook and the delegate-discovery hook. Idempotent — safe
    /// to call from every `startBlueParrott()` even if BlueParrott is toggled.
    static func install() {
        // Claim the install exactly once; the swizzles below touch only the ObjC
        // runtime, so they run outside the lock.
        let shouldInstall = withLock { () -> Bool in
            guard !didInstall else { return false }
            didInstall = true
            return true
        }
        guard shouldInstall else { return }

        let writeHooked = swizzle(
            target: CBPeripheral.self,
            original: #selector(CBPeripheral.writeValue(_:for:type:)),
            donor: CBPeripheral.self,
            replacement: #selector(CBPeripheral.bp_writeValue(_:for:type:))
        )
        // Discover the SDK's delegate at runtime: swizzle the `delegate` setter so
        // every assignment routes through us, where we hook the delegate's class.
        let setterHooked = swizzle(
            target: CBPeripheral.self,
            original: #selector(setter: CBPeripheral.delegate),
            donor: CBPeripheral.self,
            replacement: #selector(CBPeripheral.bp_setDelegate(_:))
        )
        LogManager.shared.log(
            "installed (writeHook=\(writeHooked), delegateSetterHook=\(setterHooked))",
            category: logCategory
        )
    }

    /// Discover and hook the notify method on the runtime class of `delegate`,
    /// once per class. Returns true when a new hook was installed.
    @discardableResult
    static func hookNotify(onDelegateClassOf delegate: CBPeripheralDelegate) -> Bool {
        let cls: AnyClass = type(of: delegate)
        let id = ObjectIdentifier(cls)
        // Reserve the class under the lock *before* swizzling so two concurrent
        // delegate assignments can't both hook it (a double exchange would cancel
        // out). Rolled back below if the class turns out not to be hookable.
        let reserved = withLock { () -> Bool in
            guard !hookedDelegateClasses.contains(id) else { return false }
            hookedDelegateClasses.insert(id)
            return true
        }
        guard reserved else { return false }

        // If the delegate only *inherits* the notify method, swizzling it mutates
        // the superclass IMP — capture still works, but any sibling subclasses are
        // affected too. Surface it; the SDK's delegate implements it directly.
        if methodIsInherited(cls, Self.didUpdateValueSelector) {
            LogManager.shared.log(
                "⚠️ delegate class \(cls) inherits didUpdateValueForCharacteristic; hook also affects its superclass/siblings",
                category: logCategory
            )
        }

        let hooked = swizzle(
            target: cls,
            original: Self.didUpdateValueSelector,
            donor: BPNotifyHook.self,
            replacement: #selector(BPNotifyHook.bp_peripheral(_:didUpdateValueFor:error:))
        )
        if hooked {
            LogManager.shared.log("hooked notify on delegate class \(cls)", category: logCategory)
        } else {
            // Not hookable — release the reservation so a class that later gains
            // the method (different runtime class, same name) can still be tried.
            withLock { _ = hookedDelegateClasses.remove(id) }
            LogManager.shared.log(
                "notify hook skipped — delegate class \(cls) has no didUpdateValueForCharacteristic",
                category: logCategory
            )
        }
        return hooked
    }

    /// True when `sel` exists on `cls` only via inheritance (not overridden by
    /// `cls` itself). `class_getInstanceMethod` walks the hierarchy, so an
    /// inherited selector resolves to the *same* `Method` on both `cls` and its
    /// superclass.
    private static func methodIsInherited(_ cls: AnyClass, _ sel: Selector) -> Bool {
        guard class_getInstanceMethod(cls, sel) != nil,
              let superCls = class_getSuperclass(cls) else { return false }
        return class_getInstanceMethod(cls, sel) == class_getInstanceMethod(superCls, sel)
    }

    // MARK: - Log formatting (pure, unit-testable)

    static func formatWrite(_ characteristic: CBCharacteristic, _ data: Data) -> String {
        "WRITE \(characteristic.uuid) ← \(data.bpHex)"
    }

    static func formatUpdate(_ characteristic: CBCharacteristic, _ data: Data?) -> String {
        "NOTIFY \(characteristic.uuid) → \(data?.bpHex ?? "<nil>")"
    }

    static func logWrite(_ characteristic: CBCharacteristic, _ data: Data) {
        LogManager.shared.log(formatWrite(characteristic, data), category: logCategory)
    }

    static func logUpdate(_ characteristic: CBCharacteristic, _ data: Data?) {
        LogManager.shared.log(formatUpdate(characteristic, data), category: logCategory)
    }

    // MARK: - Swizzling primitive

    /// Exchange the implementations of `original` (on `target`) and `replacement`
    /// (defined on `donor`). When `donor` differs from `target`, the donor IMP is
    /// first added to `target` under the `replacement` selector, then exchanged —
    /// so the replacement can be hosted on a known class and grafted onto the
    /// SDK's private delegate class at runtime. Returns false (logs nothing) when
    /// `target` does not implement `original`, e.g. a delegate that omits the
    /// optional notify method.
    ///
    /// NOT idempotent: invoking it twice for the same `target`+`replacement`
    /// reverses the first hook (the second `method_exchangeImplementations` swaps
    /// the IMPs back). Callers must dedupe — `install()` via `didInstall`,
    /// `hookNotify` via `hookedDelegateClasses`.
    @discardableResult
    static func swizzle(target: AnyClass, original: Selector, donor: AnyClass, replacement: Selector) -> Bool {
        guard let origMethod = class_getInstanceMethod(target, original),
              let donorMethod = class_getInstanceMethod(donor, replacement) else { return false }

        if ObjectIdentifier(target) == ObjectIdentifier(donor) {
            method_exchangeImplementations(origMethod, donorMethod)
            return true
        }

        let added = class_addMethod(
            target,
            replacement,
            method_getImplementation(donorMethod),
            method_getTypeEncoding(donorMethod)
        )
        guard let targetReplacement = class_getInstanceMethod(target, replacement) else { return false }
        // `added` is false only when `target` already carries `replacement` (e.g.
        // a second hook attempt); either way `targetReplacement` is the method to
        // exchange against `original`.
        _ = added
        method_exchangeImplementations(origMethod, targetReplacement)
        return true
    }

    #if DEBUG
    /// Test-only reset of the bookkeeping so each test starts from a known state.
    /// NOTE: this deliberately does NOT un-swizzle the ObjC runtime — once a test
    /// installs/hooks, those IMP exchanges persist for the process. That is
    /// harmless here (no real `CBPeripheral` is exercised in tests), and tests
    /// assert on the bookkeeping + `instancesRespond(to:)`, not on live redirects.
    static func resetForTesting() {
        withLock {
            didInstall = false
            hookedDelegateClasses.removeAll()
        }
    }

    static func isDelegateClassHooked(_ cls: AnyClass) -> Bool {
        withLock { hookedDelegateClasses.contains(ObjectIdentifier(cls)) }
    }
    #endif
}

/// Donor host for the notify-side replacement IMP. The IMP is grafted onto the
/// SDK's delegate class at runtime, so its body must touch only `self`'s ObjC
/// messages (never `BPNotifyHook`-specific state) — once exchanged, `self` is
/// the SDK delegate instance, not a `BPNotifyHook`.
final class BPNotifyHook: NSObject {
    @objc dynamic func bp_peripheral(_ peripheral: CBPeripheral,
                                     didUpdateValueFor characteristic: CBCharacteristic,
                                     error: Error?) {
        BPSniffer.logUpdate(characteristic, characteristic.value)
        // After the exchange on the SDK delegate class, this selector holds the
        // delegate's original IMP, so this forwards the notification onward.
        bp_peripheral(peripheral, didUpdateValueFor: characteristic, error: error)
    }
}

extension CBPeripheral {
    @objc func bp_writeValue(_ data: Data, for characteristic: CBCharacteristic, type: CBCharacteristicWriteType) {
        BPSniffer.logWrite(characteristic, data)
        bp_writeValue(data, for: characteristic, type: type) // original after swap
    }

    @objc func bp_setDelegate(_ delegate: CBPeripheralDelegate?) {
        if let delegate = delegate {
            BPSniffer.hookNotify(onDelegateClassOf: delegate)
        }
        bp_setDelegate(delegate) // original after swap
    }
}

extension Data {
    /// Space-separated lowercase hex, the form used throughout the BPSniff logs.
    var bpHex: String { map { String(format: "%02x", $0) }.joined(separator: " ") }
}
#endif
