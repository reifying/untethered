// RenderTracker.swift
// Utility to track and report SwiftUI view render counts

import Foundation

/// Thread-safe tracker for SwiftUI view body evaluations.
/// Usage in any SwiftUI view:
///   let _ = RenderTracker.count(Self.self)
///
/// This line executes during body evaluation but doesn't trigger re-renders
/// because it doesn't modify any @State or other observable properties.
@MainActor
class RenderTracker {
    // Thread-safe storage for render counts
    private static var counts: [String: Int] = [:]
    private static var startTime: Date = Date()

    /// Track a single render for the given view type
    static func count(_ type: Any.Type) {
        let name = String(describing: type)
        counts[name, default: 0] += 1
    }

    /// Get top N most-rendered views, sorted by count descending
    static func topRendered(limit: Int = 10) -> [(name: String, count: Int)] {
        counts
            .sorted { $0.value > $1.value }
            .prefix(limit)
            .map { (name: $0.key, count: $0.value) }
    }

    /// Get all render counts, sorted by count descending
    static func allCounts() -> [(name: String, count: Int)] {
        counts
            .sorted { $0.value > $1.value }
            .map { (name: $0.key, count: $0.value) }
    }

    /// Generate formatted report of render statistics
    static func generateReport() -> String {
        let elapsed = Date().timeIntervalSince(startTime)
        let hours = Int(elapsed) / 3600
        let minutes = Int(elapsed) % 3600 / 60
        let seconds = Int(elapsed) % 60

        var report = "RENDER STATISTICS\n"
        report += "=================\n\n"
        report += "Tracking period: \(hours)h \(minutes)m \(seconds)s\n"
        report += "Unique views tracked: \(counts.count)\n"
        report += "Total renders: \(counts.values.reduce(0, +))\n\n"
        report += "TOP RENDERED VIEWS:\n"
        report += "-------------------\n\n"

        let topViews = topRendered(limit: 10)

        if topViews.isEmpty {
            report += "No renders tracked yet.\n"
            report += "Add tracking to views with:\n"
            report += "  let _ = RenderTracker.count(Self.self)\n"
        } else {
            for (index, item) in topViews.enumerated() {
                report += "\(index + 1). \(item.name)\n"
                report += "   \(item.count) renders"

                // Calculate renders per minute
                if elapsed > 0 {
                    let rendersPerMinute = Double(item.count) / (elapsed / 60.0)
                    report += " (\(String(format: "%.1f", rendersPerMinute))/min)"
                }
                report += "\n\n"
            }

            // Summary of other views
            if counts.count > 10 {
                let otherCount = counts.count - 10
                let otherRenders = counts.values.reduce(0, +) - topViews.reduce(0) { $0 + $1.count }
                report += "... and \(otherCount) other view(s) with \(otherRenders) total renders\n"
            }
        }

        return report
    }

    /// Reset all tracking data and restart timer
    static func reset() {
        counts.removeAll()
        startTime = Date()
    }

    /// Get tracking metadata (for debugging)
    static func metadata() -> (viewCount: Int, totalRenders: Int, elapsedSeconds: TimeInterval) {
        let elapsed = Date().timeIntervalSince(startTime)
        return (
            viewCount: counts.count,
            totalRenders: counts.values.reduce(0, +),
            elapsedSeconds: elapsed
        )
    }
}
