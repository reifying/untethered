// NeuralVoiceCrashGuard.swift
// Turns the neural voice off if the app keeps dying in the middle of synthesis.
// Design: docs/design/kokoro-neural-voice.md ("Risks and guards")

import Foundation

/// A Core ML crash inside synthesis kills the process and cannot be caught. This notices it
/// afterwards: a flag in `UserDefaults` is set while any synthesis call is running, and if the
/// next launch finds it still set, the previous run died mid-synthesis. After
/// `consecutiveLimit` such launches in a row, `isTrippedOff` turns the neural voice off until
/// Travis turns it back on, so a crash that recurs on every reply cannot make the app unusable.
/// A synthesis call that completes resets the count.
final class NeuralVoiceCrashGuard {
    static let consecutiveLimit = 2

    private let defaults: UserDefaults
    private let inFlightKey: String
    private let consecutiveKey: String
    private let totalKey: String
    private let lastCrashKey: String
    private let lock = NSLock()
    private var running = 0

    init(defaults: UserDefaults = .standard, keyPrefix: String = "kokoro") {
        self.defaults = defaults
        inFlightKey = "\(keyPrefix)SynthesisInFlight"
        consecutiveKey = "\(keyPrefix)ConsecutiveCrashes"
        totalKey = "\(keyPrefix)TotalCrashes"
        lastCrashKey = "\(keyPrefix)LastCrashDate"
    }

    /// Call once per launch, before any synthesis. Returns true when the previous run
    /// died while synthesizing.
    @discardableResult
    func recordLaunch() -> Bool {
        guard defaults.bool(forKey: inFlightKey) else { return false }
        defaults.set(false, forKey: inFlightKey)
        defaults.set(consecutiveCrashes + 1, forKey: consecutiveKey)
        defaults.set(totalCrashes + 1, forKey: totalKey)
        defaults.set(Date(), forKey: lastCrashKey)
        return true
    }

    /// Bracket every call that runs the model (load from cache, warm-up, synthesis).
    func synthesisWillStart() {
        lock.lock()
        running += 1
        if running == 1 { defaults.set(true, forKey: inFlightKey) }
        lock.unlock()
    }

    func synthesisDidEnd(succeeded: Bool) {
        lock.lock()
        running = max(0, running - 1)
        if running == 0 { defaults.set(false, forKey: inFlightKey) }
        lock.unlock()
        if succeeded, consecutiveCrashes != 0 {
            defaults.set(0, forKey: consecutiveKey)
        }
    }

    var consecutiveCrashes: Int { defaults.integer(forKey: consecutiveKey) }
    var totalCrashes: Int { defaults.integer(forKey: totalKey) }
    var lastCrashDate: Date? { defaults.object(forKey: lastCrashKey) as? Date }
    var isTrippedOff: Bool { consecutiveCrashes >= Self.consecutiveLimit }

    /// Travis turned the neural voice back on.
    func reset() {
        defaults.set(0, forKey: consecutiveKey)
    }
}
