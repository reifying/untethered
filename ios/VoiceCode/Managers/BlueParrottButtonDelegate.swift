// BlueParrottButtonDelegate.swift
// The platform-agnostic button-event contract shared by both BlueParrott button
// sources: the iOS `BlueParrottButtonManager` (BPHeadset SDK) and the macOS
// `BlueParrottBLEManager` (CoreBluetooth). Kept free of any platform/SDK types
// and compiled into BOTH the iOS and macOS targets so the two implementations
// converge on one delegate surface (see
// @docs/design/macos-blueparrott-corebluetooth.md §3 — "Delegate contract").
//
// Previously this protocol lived inside the iOS-only BlueParrottButtonManager.swift
// (which is excluded from the macOS target); it was extracted here unchanged so
// the macOS client can reuse it verbatim.

import Foundation

protocol BlueParrottButtonDelegate: AnyObject {
    func blueParrottButtonDown()
    func blueParrottButtonUp()
    func blueParrottTap()
    func blueParrottDoubleTap()
    func blueParrottLongPress()
}
