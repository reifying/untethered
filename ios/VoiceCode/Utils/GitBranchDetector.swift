// GitBranchDetector.swift
// Utility for detecting the current git branch for a working directory

import Foundation

struct GitBranchDetector {
    /// Detects the current git branch for a given working directory
    /// Returns nil if the directory is not a git repository or if detection fails
    static func detectBranch(workingDirectory: String) async -> String? {
        // On iOS, we can't use Process to run git commands
        // Instead, read .git/HEAD file directly
        let gitHeadPath = (workingDirectory as NSString).appendingPathComponent(".git/HEAD")

        do {
            let headContents = try String(contentsOfFile: gitHeadPath, encoding: .utf8)

            // HEAD file format is typically:
            // "ref: refs/heads/main\n" for a branch
            // "abc123...\n" for detached HEAD
            let trimmed = headContents.trimmingCharacters(in: .whitespacesAndNewlines)

            if trimmed.hasPrefix("ref: refs/heads/") {
                // Extract branch name after "ref: refs/heads/"
                let branch = String(trimmed.dropFirst("ref: refs/heads/".count))
                return branch.isEmpty ? nil : branch
            }

            // Detached HEAD or other format
            return nil
        } catch {
            // Not a git repo or file read failed
            return nil
        }
    }
}
