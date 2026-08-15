// PendingReplyLedger.swift
// Durable record of "this device asked that session something and hasn't seen
// the answer yet".
//
// The priority queue is a turn-taking inbox — the sessions where the ball is in
// the user's court (see docs/design/priority-queue-revisit.md). The signal for
// "a reply I'm the addressee of" is not available on the wire: every session runs
// through tmux, and nothing distinguishes an agent the user prompted from one
// `tmux-agent start` launched. So the client records its own outbound prompts and
// matches the next live assistant arrival against them.
//
// Backed by UserDefaults because an agent can work for many minutes and the app
// may be killed in between; an in-memory set would lose the claim exactly in the
// case that matters most (phone locked, agent working).

import Foundation

/// One-shot claims keyed by lowercased session id. `arm` on send, `claim` on the
/// first live assistant message, `disarm` when the claim is abandoned.
final class PendingReplyLedger {

    static let shared = PendingReplyLedger()

    /// Entries older than this are treated as never having been armed. An agent
    /// that died without replying must not leave a claim that fires on some
    /// unrelated reply days later.
    static let defaultTTL: TimeInterval = 24 * 60 * 60

    private let defaults: UserDefaults
    private let storageKey: String
    private let ttl: TimeInterval

    /// `arm`/`claim` are called from the WebSocket send path (main queue) and
    /// from the per-session upsert queues (concurrent across sessions), so all
    /// access is serialized.
    private let lock = NSLock()

    init(defaults: UserDefaults = .standard,
         storageKey: String = "pendingReplySessions",
         ttl: TimeInterval = PendingReplyLedger.defaultTTL) {
        self.defaults = defaults
        self.storageKey = storageKey
        self.ttl = ttl
    }

    /// Record that this device just sent a prompt to `sessionId`. Re-arming an
    /// already-armed session refreshes its timestamp rather than stacking.
    func arm(sessionId: String, at now: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }

        var entries = prunedEntries(now: now)
        entries[sessionId.lowercased()] = now.timeIntervalSince1970
        defaults.set(entries, forKey: storageKey)
        LogManager.shared.log("📮 [PendingReply] Armed \(sessionId.lowercased()) (\(entries.count) outstanding)", category: "PriorityQueue")
    }

    /// Consume the claim for `sessionId`. Returns `true` exactly once per `arm`:
    /// the reply that lands first takes the claim, later messages in the same
    /// turn do not re-enqueue.
    func claim(sessionId: String, at now: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        var entries = prunedEntries(now: now)
        guard entries.removeValue(forKey: sessionId.lowercased()) != nil else {
            return false
        }
        defaults.set(entries, forKey: storageKey)
        LogManager.shared.log("📬 [PendingReply] Claimed \(sessionId.lowercased()) (\(entries.count) outstanding)", category: "PriorityQueue")
        return true
    }

    /// Drop the claim without treating it as answered.
    func disarm(sessionId: String, at now: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }

        var entries = prunedEntries(now: now)
        guard entries.removeValue(forKey: sessionId.lowercased()) != nil else { return }
        defaults.set(entries, forKey: storageKey)
    }

    /// Non-destructive read, for diagnostics and tests.
    func isArmed(sessionId: String, at now: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return prunedEntries(now: now)[sessionId.lowercased()] != nil
    }

    /// Sessions with an outstanding prompt, for diagnostics and tests.
    func armedSessionIds(at now: Date = Date()) -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return Set(prunedEntries(now: now).keys)
    }

    // MARK: - Storage

    /// Current entries with expired ones dropped. Callers hold `lock`.
    private func prunedEntries(now: Date) -> [String: Double] {
        let raw = defaults.dictionary(forKey: storageKey) as? [String: Double] ?? [:]
        let cutoff = now.timeIntervalSince1970 - ttl
        return raw.filter { $0.value >= cutoff }
    }
}
