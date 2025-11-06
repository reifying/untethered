// CommandSorter.swift
// MRU (Most Recently Used) sorting for commands

import Foundation

class CommandSorter {
    private let userDefaults: UserDefaults
    private let mruKey = "commandMRU"

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    // Mark a command as used (updates timestamp)
    func markCommandUsed(commandId: String) {
        var mru = getMRU()
        mru[commandId] = Date().timeIntervalSince1970
        setMRU(mru)
    }

    // Sort commands with MRU logic:
    // - Used commands first, sorted by timestamp descending (most recent first)
    // - Unused commands second, sorted alphabetically by label
    // - Recursive sorting for nested groups
    func sortCommands(_ commands: [Command]) -> [Command] {
        let mru = getMRU()

        return commands
            .map { command -> (Command, Double?) in
                let timestamp = mru[command.id]
                return (command, timestamp)
            }
            .sorted { lhs, rhs in
                // Both used: sort by timestamp descending
                if let lhsTime = lhs.1, let rhsTime = rhs.1 {
                    return lhsTime > rhsTime
                }
                // Only lhs used: lhs comes first
                if lhs.1 != nil {
                    return true
                }
                // Only rhs used: rhs comes first
                if rhs.1 != nil {
                    return false
                }
                // Both unused: sort alphabetically by label
                return lhs.0.label < rhs.0.label
            }
            .map { pair in
                let command = pair.0
                // Recursively sort children if this is a group
                if command.type == .group, let children = command.children {
                    return Command(
                        id: command.id,
                        label: command.label,
                        type: command.type,
                        description: command.description,
                        children: sortCommands(children)
                    )
                }
                return command
            }
    }

    // Get MRU dictionary from UserDefaults
    private func getMRU() -> [String: Double] {
        guard let data = userDefaults.data(forKey: mruKey),
              let mru = try? JSONDecoder().decode([String: Double].self, from: data) else {
            return [:]
        }
        return mru
    }

    // Save MRU dictionary to UserDefaults
    private func setMRU(_ mru: [String: Double]) {
        guard let data = try? JSONEncoder().encode(mru) else {
            return
        }
        userDefaults.set(data, forKey: mruKey)
    }

    // Clear all MRU data (useful for testing)
    func clearMRU() {
        userDefaults.removeObject(forKey: mruKey)
    }
}
