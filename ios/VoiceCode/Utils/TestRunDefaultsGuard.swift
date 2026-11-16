// TestRunDefaultsGuard.swift
// Stops a unit-test run from changing the real Mac app's settings.
//
// The Mac unit tests run inside the app itself (it is their test host), with the
// app's own bundle identifier and sandbox. So `UserDefaults.standard` in a test
// IS the real app's settings, and the tests write to it freely: they clear the
// headset and BlueParrott switches, set the mute flag, change the server address.
// After a test run on the Mac the app is used on, the app came up with headset
// control off, its paired BlueParrott forgotten and speech muted, with nothing to
// say why.
//
// Rather than chase every test, the app itself brackets a test run:
//   • launched for a test run, it saves the settings to a file once, before
//     anything reads them (a file, so it survives the test host crashing);
//   • launched normally, it puts a saved file back and deletes it.
// The iOS simulator has its own sandbox, so this is for the Mac only.

#if os(macOS)
import Foundation

enum TestRunDefaultsGuard {
    static let snapshotFileName = "settings-before-unit-tests.plist"

    static var defaultSnapshotURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Untethered", isDirectory: true)
            .appendingPathComponent(snapshotFileName)
    }

    /// Call first thing at launch, before any setting is read.
    static func run() {
        guard let domain = Bundle.main.bundleIdentifier, let url = defaultSnapshotURL else { return }
        if TestingEnvironment.isTestRun {
            saveIfAbsent(domain: domain, to: url)
        } else {
            restoreIfPresent(domain: domain, from: url)
        }
    }

    /// Save the settings of `domain` to `url`, unless a snapshot is already there:
    /// the test host is relaunched many times in one run, and only the first
    /// launch sees the settings as the user left them.
    @discardableResult
    static func saveIfAbsent(domain: String, to url: URL, defaults: UserDefaults = .standard) -> Bool {
        let files = FileManager.default
        guard !files.fileExists(atPath: url.path) else { return false }
        let settings = defaults.persistentDomain(forName: domain) ?? [:]
        do {
            try files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: settings, format: .binary, options: 0)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            LogManager.shared.log("Could not save settings before the unit tests to \(url.path): \(error.localizedDescription)", category: "TestRunDefaultsGuard")
            return false
        }
    }

    /// Put the settings saved at `url` back as the whole of `domain`, and delete
    /// the snapshot. Keys the tests added are removed, keys they removed return.
    @discardableResult
    static func restoreIfPresent(domain: String, from url: URL, defaults: UserDefaults = .standard) -> Bool {
        let files = FileManager.default
        guard files.fileExists(atPath: url.path) else { return false }
        defer { try? files.removeItem(at: url) }
        do {
            let data = try Data(contentsOf: url)
            guard let settings = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
                LogManager.shared.log("Settings snapshot at \(url.path) is not a dictionary, ignoring it", category: "TestRunDefaultsGuard")
                return false
            }
            defaults.setPersistentDomain(settings, forName: domain)
            LogManager.shared.log("Put back the \(settings.count) settings a unit-test run had changed", category: "TestRunDefaultsGuard")
            return true
        } catch {
            LogManager.shared.log("Could not read the settings snapshot at \(url.path): \(error.localizedDescription)", category: "TestRunDefaultsGuard")
            return false
        }
    }
}
#endif
