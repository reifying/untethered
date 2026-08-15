// SessionSyncManager.swift
// Manages session metadata synchronization with backend

import Foundation
import CoreData

// MARK: - Notification Names

extension Notification.Name {
    /// Posted when session list is updated from backend
    static let sessionListDidUpdate = Notification.Name("sessionListDidUpdate")

    /// Posted when session history is updated (messages added via session_history)
    /// userInfo contains "sessionId" key with the session UUID string
    static let sessionHistoryDidUpdate = Notification.Name("sessionHistoryDidUpdate")
}

// MARK: - Delegate

/// Sink for out-of-band sync events that need a UI response. The UI layer
/// (typically `VoiceCodeClient`) conforms and surfaces these to the user.
protocol SessionSyncDelegate: AnyObject {
    /// Fires when the backend replies with a `session_history` payload whose
    /// `gap.reason == "pruned"` — the server no longer retains the seq range
    /// the client asked for. The client is expected to warn the user that
    /// local state is partial; no automatic merge or reload happens.
    /// See docs/design/append-only-message-stream.md AC5.
    func didDetectPrunedGap(_ sessionId: String, gap: SessionHistoryPayload.Gap)

    /// Fires when the sync manager needs the client to send a new `subscribe`
    /// for the given session starting from `fromSeq`. Two triggers:
    ///   1. A push arrived with `first_seq > local_last_seq + 1` — a missed
    ///      window needs backfilling. `fromSeq = local_last_seq` (pre-gap).
    ///   2. The payload carried `is_complete == false` — the server's budget
    ///      was exhausted and the next window is ready. `fromSeq` is the
    ///      latest seq we just received.
    /// The manager never advances any shared cursor past the gap until the
    /// client completes this resubscribe; see AC3/AC6 of the design.
    func sessionSyncNeedsResubscribe(_ sessionId: String, fromSeq: Int64)

    /// Fires when the manager has aborted a chained `is_complete: false`
    /// resubscribe loop because the server is not making progress — i.e.
    /// the most recent payload's `last_seq` did not advance past the
    /// cursor we asked from. Likeliest cause is a single message whose
    /// JSON encoding exceeds the per-window byte budget so the server
    /// can't fit it. `cursor` is the unchanged cursor at which the chain
    /// stopped; the UI should surface this so the user knows older history
    /// past this point cannot load automatically. See beads
    /// tmux-untethered-l8t.
    func sessionSyncDidStallChain(_ sessionId: String, atCursor: Int64)

    /// v0.5.0: fires after a `file_replaced: true` recovery has purged the
    /// session's cached messages and reset its cursors. The client must
    /// re-subscribe so the server resends from offset 0 with the new
    /// signature. The implementation typically calls `subscribe(sessionId:)`
    /// directly — the freshly-persisted `lastOffsetMerged=0` and
    /// `lastFileSignature=<new>` are the inputs to the next outbound
    /// `subscribe`. ORDERING: the manager dispatches this AFTER `ctx.save()`
    /// has committed the purge, so the next subscribe reads the post-purge
    /// state. See voice-code-sync-kafka-redesign-2026-05-10.md §3.3, §6 R2.
    func sessionSyncRequestsResubscribeFromZero(_ sessionId: UUID)
}

extension SessionSyncDelegate {
    /// Default no-op so existing conformers (VoiceCodeClient shipped before
    /// tmux-untethered-fh3) compile without modification. Real implementers
    /// route `fromSeq` into a `subscribe` message on the socket.
    func sessionSyncNeedsResubscribe(_ sessionId: String, fromSeq: Int64) {}

    /// Default no-op for backwards compatibility. The default behavior on
    /// chain stall is to fall silent — the manager has already stopped
    /// firing resubscribes, so the only consequence of a no-op is the user
    /// not being told why the conversation stopped loading. Implementers
    /// that care should surface a banner or warning.
    func sessionSyncDidStallChain(_ sessionId: String, atCursor: Int64) {}

    /// Default no-op for v0.4.0 conformers. v0.5.0 implementers should call
    /// `subscribe(sessionId:)` so the freshly-persisted post-purge cursors
    /// (`lastOffsetMerged=0`, new `lastFileSignature`) drive the next round.
    func sessionSyncRequestsResubscribeFromZero(_ sessionId: UUID) {}
}

/// Manages synchronization of session metadata between backend and CoreData
class SessionSyncManager {
    private let persistenceController: PersistenceController
    private let context: NSManagedObjectContext
    private weak var voiceOutputManager: VoiceOutputManager?

    /// One-shot record of prompts this device has sent and not yet seen answered.
    /// It is the sole admission signal for the priority queue: an assistant
    /// message only enqueues its session if the user is the one who asked for it.
    /// See `PriorityQueueAdmission` and docs/design/priority-queue-revisit.md.
    let pendingReplies: PendingReplyLedger

    /// UI-layer sink for pruned-gap and similar events. See `SessionSyncDelegate`.
    weak var delegate: SessionSyncDelegate?

    /// Sessions for which a pruned-gap payload has been received and not yet
    /// acknowledged by the user. Keyed by lowercased session UUID. Set
    /// synchronously when a pruned `session_history` lands so that any
    /// subsequent payload arriving on the same WebSocket pump tick is
    /// refused before it reaches the upsert path. Cleared via
    /// `clearPrunedFlag(sessionId:)` (typically when the user dismisses the
    /// banner). See AC5 of docs/design/append-only-message-stream.md and
    /// beads tmux-untethered-8i4: without this guard, a non-gap push
    /// arriving between the synchronous pruned-detection branch and the
    /// async delegate dispatch would silently mix stale messages with new
    /// post-gap ones.
    ///
    /// Accessed only on the main queue. The WebSocket pump dispatches
    /// `handleSessionHistoryPayload` to main, and `clearPrunedFlag` is
    /// documented as main-only.
    private(set) var prunedSessions: Set<String> = []

    /// For each session with an in-flight `is_complete: false` chain, the
    /// cursor we last asked the server to resume from (i.e. the `last_seq`
    /// passed to the most recent chained subscribe). Keyed by lowercased
    /// session UUID. A subsequent `is_complete: false` payload whose
    /// `last_seq` does not advance past this cursor (or is nil) means the
    /// server cannot make progress for the current cursor — typically a
    /// single message whose JSON encoding exceeds the per-window byte
    /// budget. The chain is aborted instead of spinning at maximum speed,
    /// and the failure is surfaced via `sessionSyncDidStallChain`. See
    /// beads tmux-untethered-l8t.
    ///
    /// Cleared whenever the chain terminates: `is_complete: true`, gap
    /// (either reason), pruned-gap event, or save-failure recovery — any
    /// of which kicks off a path that doesn't share the chain's cursor.
    ///
    /// Accessed only on the main queue. All reads/writes happen inside the
    /// `DispatchQueue.main.async` block where the resubscribe is fired.
    private var incompleteChainCursors: [String: Int64] = [:]

    /// v0.5.0 sibling of `incompleteChainCursors`. Tracks the `next_offset`
    /// cursor we last asked the server to start from so we can detect a
    /// stalled `end_of_file:false` chain (server repeatedly returning the
    /// same `next_offset` without advancing). Accessed only on the main queue.
    private var incompleteChainCursorsV5: [String: Int64] = [:]

    /// Per-session serial queues that gate concurrent
    /// `handleSessionHistoryPayload` invocations for the same session.
    /// Without this, two payloads landing simultaneously (subscribe reply
    /// crossing a live push, two backfills in quick succession) each spawn
    /// independent background contexts whose seqHit fetches see stale
    /// snapshots and both insert duplicate rows for overlapping seqs.
    /// See beads tmux-untethered-prf. Different sessions still process in
    /// parallel — only same-session payloads serialize.
    private var sessionUpsertQueues: [String: DispatchQueue] = [:]
    private let sessionUpsertQueuesLock = NSLock()

    private func upsertQueue(forSessionId sessionId: String) -> DispatchQueue {
        sessionUpsertQueuesLock.lock()
        defer { sessionUpsertQueuesLock.unlock() }
        if let existing = sessionUpsertQueues[sessionId] { return existing }
        let q = DispatchQueue(label: "dev.910labs.voice-code.SessionSync.upsert.\(sessionId)")
        sessionUpsertQueues[sessionId] = q
        return q
    }

    /// Server-assigned message UUIDs already fanned out for TTS / notification
    /// this launch, keyed by lowercased session id. The normal dedup is
    /// `upsertMessage` returning `isNew == false` for an existing
    /// `(sessionId, offset)` row, but `file_replaced` recovery purges every
    /// cached row and re-subscribes from offset 0, so re-delivered messages
    /// look brand-new and would be spoken again — and rapid `file_signature`
    /// churn re-speaks the same recent messages 2-3x (tmux-untethered-icf).
    /// This set survives the purge and is keyed on the message UUID (stable
    /// across compaction / offset renumbering, unlike `offset`), so history
    /// replay never re-enqueues speech for a message already announced.
    /// Accessed from the per-session upsert queues (which run concurrently
    /// across sessions), so all access goes through `spokenMessageLock`.
    private var spokenMessageUUIDs: [String: Set<String>] = [:]
    private let spokenMessageLock = NSLock()

    /// Returns `true` and records `uuid` if this session has not yet announced
    /// it; returns `false` if it was already announced (caller must suppress
    /// the TTS / notification fan-out). Thread-safe. Both the session id and
    /// the message uuid are lowercased so a case difference between two
    /// deliveries of the same message can't slip a duplicate past the set.
    private func claimUnspokenMessage(sessionId: String, uuid: String) -> Bool {
        spokenMessageLock.lock()
        defer { spokenMessageLock.unlock() }
        let key = sessionId.lowercased()
        let messageKey = uuid.lowercased()
        if spokenMessageUUIDs[key]?.contains(messageKey) == true {
            return false
        }
        spokenMessageUUIDs[key, default: []].insert(messageKey)
        return true
    }

    init(persistenceController: PersistenceController = .shared,
         voiceOutputManager: VoiceOutputManager? = nil,
         pendingReplies: PendingReplyLedger = .shared) {
        self.persistenceController = persistenceController
        self.context = persistenceController.container.viewContext
        self.voiceOutputManager = voiceOutputManager
        self.pendingReplies = pendingReplies
    }

    // MARK: - Priority Queue Admission

    /// Called when this device sends a prompt to `sessionId`. Two effects, both
    /// halves of the same turn-taking rule (docs/design/priority-queue-revisit.md):
    ///
    /// 1. The ball moves to the agent, so the session leaves the priority queue.
    ///    Priority is preserved — it is coming back as soon as the agent answers.
    /// 2. The ledger is armed, so the reply that lands is recognized as one the
    ///    user is the addressee of and re-enqueues the session.
    ///
    /// Safe to call for any session, queued or not, and for sessions the local
    /// store has never seen (a brand-new session's row is created on first
    /// payload) — the dequeue half is simply a no-op there.
    func recordOutboundPrompt(sessionId: String) {
        let key = sessionId.lowercased()
        pendingReplies.arm(sessionId: key)

        guard let sessionUUID = UUID(uuidString: key) else {
            LogManager.shared.log("⚠️ [PriorityQueue] Outbound prompt for non-UUID session id: \(key)", category: "PriorityQueue")
            return
        }

        let backgroundContext = persistenceController.container.newBackgroundContext()
        // The session_history handlers write the same CDBackendSession row
        // (messageCount, preview, unreadCount) concurrently. Without this the
        // default NSErrorMergePolicy turns any overlap into a failed save; the
        // attributes touched here are disjoint from theirs, so last-write-wins
        // per property is exactly right. Matches every other background context
        // in this file and in PersistenceController.
        backgroundContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        backgroundContext.perform {
            guard let session = try? backgroundContext
                    .fetch(CDBackendSession.fetchBackendSession(id: sessionUUID)).first,
                  session.isInPriorityQueue else {
                return
            }
            // resetPriority: false — the user's chosen priority must survive the
            // round trip, or a P1 session returns as P10 after every reply.
            if CDBackendSession.removeFromPriorityQueue(session,
                                                        context: backgroundContext,
                                                        resetPriority: false) {
                LogManager.shared.log("📤 [PriorityQueue] Dequeued on outbound prompt (ball back with agent): \(key)", category: "PriorityQueue")
            } else {
                LogManager.shared.log("⚠️ [PriorityQueue] Dequeue on outbound prompt did not commit; session stays queued: \(key)", category: "PriorityQueue")
            }
        }
    }

    /// Called when the backend reports that an agent finished a turn
    /// (`agent_replied`). This is the enqueue path that does NOT depend on
    /// being subscribed to the session.
    ///
    /// The message-arrival path in the `session_history` handlers only fires
    /// while the client holds a subscription and the reply arrives as a *live*
    /// push. Leaving a conversation unsubscribes, and coming back replays the
    /// reply as history (below `liveFromOffset`, so deliberately not "live") —
    /// so for the send-and-walk-away workflow the queue exists to serve, that
    /// path fires never. This one covers it.
    ///
    /// Both paths claim the same one-shot ledger entry, so whichever arrives
    /// first enqueues and the other is a no-op. No double entry.
    func recordAgentReply(sessionId: String) {
        let key = sessionId.lowercased()

        guard UserDefaults.standard.bool(forKey: "priorityQueueEnabled") else { return }
        guard let sessionUUID = UUID(uuidString: key) else {
            LogManager.shared.log("⚠️ [PriorityQueue] agent_replied for non-UUID session id: \(key)", category: "PriorityQueue")
            return
        }
        // Claim before touching CoreData: the claim is the decision, and it is
        // cheap to leave armed if we can't act on it.
        guard pendingReplies.claim(sessionId: key) else { return }

        let backgroundContext = persistenceController.container.newBackgroundContext()
        // agent_replied lands within milliseconds of the session_history push for
        // the same turn (they are the same transcript write), so this context and
        // the payload handler's routinely commit the same row at once. See the
        // note in recordOutboundPrompt.
        backgroundContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        backgroundContext.perform {
            guard let session = try? backgroundContext
                    .fetch(CDBackendSession.fetchBackendSession(id: sessionUUID)).first else {
                // No local row yet (an agent this client has never seen). Re-arm
                // so the claim isn't silently burned — the next reply, or the
                // session showing up in a session_list, can still enqueue it.
                self.pendingReplies.arm(sessionId: key)
                LogManager.shared.log("⏭️ [PriorityQueue] agent_replied for unknown session, re-arming: \(key)", category: "PriorityQueue")
                return
            }
            if CDBackendSession.addToPriorityQueue(session, context: backgroundContext) {
                LogManager.shared.log("📌 [PriorityQueue] Enqueued on agent_replied (your turn): \(key)", category: "PriorityQueue")
            } else {
                // The claim is already spent, so without re-arming this entry is
                // lost with nothing left to retry from — the queue silently drops
                // a session the user is waiting on.
                self.pendingReplies.arm(sessionId: key)
                LogManager.shared.log("⚠️ [PriorityQueue] Enqueue on agent_replied did not commit; re-arming for the next signal: \(key)", category: "PriorityQueue")
            }
        }
    }
    
    // MARK: - Session List Handling
    
    /// Handle session_list message from backend
    /// - Parameter sessions: Array of session metadata dictionaries
    func handleSessionList(_ sessions: [[String: Any]]) async {
        LogManager.shared.log("📥 Received session_list with \(sessions.count) sessions", category: "SessionSync")

        // Log all received sessions with their details
        LogManager.shared.log("📋 Sessions received from backend:", category: "SessionSync")
        for (index, sessionData) in sessions.enumerated() {
            let sessionId = sessionData["session_id"] as? String ?? "unknown"
            let name = sessionData["name"] as? String ?? "unknown"
            let workingDir = sessionData["working_directory"] as? String ?? "unknown"
            let messageCount = sessionData["message_count"] as? Int ?? 0
            LogManager.shared.log("  [\(index + 1)] \(sessionId) | \(messageCount) msgs | \(name) | \(workingDir)", category: "SessionSync")
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            persistenceController.performBackgroundTask { [weak self] backgroundContext in
                guard let self = self else {
                    continuation.resume()
                    return
                }

                for sessionData in sessions {
                    self.upsertSession(sessionData, in: backgroundContext)
                }

                do {
                    if backgroundContext.hasChanges {
                        try backgroundContext.save()
                        LogManager.shared.log("✅ Saved \(sessions.count) sessions to CoreData", category: "SessionSync")

                        // Notify observers that session list was updated
                        DispatchQueue.main.async {
                            NotificationCenter.default.post(name: .sessionListDidUpdate, object: nil)
                        }
                    }
                } catch {
                    LogManager.shared.log("❌ Failed to save session_list: \(error.localizedDescription)", category: "SessionSync")
                }

                continuation.resume()
            }
        }
    }
    
    // MARK: - Session Created Handling

    /// Handle session_created message from backend
    /// - Parameters:
    ///   - sessionData: Session metadata dictionary
    ///   - completion: Optional callback with session ID on successful save
    func handleSessionCreated(_ sessionData: [String: Any], completion: ((String) -> Void)? = nil) {
        let sessionId = sessionData["session_id"] as? String ?? "unknown"
        let name = sessionData["name"] as? String ?? "unknown"
        let workingDir = sessionData["working_directory"] as? String ?? "unknown"
        let messageCount = sessionData["message_count"] as? Int ?? 0
        let hasPreview = (sessionData["preview"] as? String)?.isEmpty == false

        LogManager.shared.log("📨 session_created received: \(sessionId)", category: "SessionSync")
        LogManager.shared.log("  Name: \(name)", category: "SessionSync")
        LogManager.shared.log("  Working dir: \(workingDir)", category: "SessionSync")
        LogManager.shared.log("  Message count: \(messageCount)", category: "SessionSync")
        LogManager.shared.log("  Has preview: \(hasPreview)", category: "SessionSync")

        guard sessionData["session_id"] as? String != nil else {
            LogManager.shared.log("⚠️ session_created missing session_id, dropping", category: "SessionSync")
            return
        }

        // Backend guarantees all notified sessions have messages via delayed notification pattern
        // Just log for observability if we receive a 0-message session
        if messageCount == 0 {
            LogManager.shared.log("📝 Note: Received session with 0 messages (may update soon): \(sessionId)", category: "SessionSync")
        }

        LogManager.shared.log("✅ Accepting session_created for: \(sessionId)", category: "SessionSync")

        persistenceController.performBackgroundTask { [weak self] backgroundContext in
            guard let self = self else { return }

            self.upsertSession(sessionData, in: backgroundContext)

            do {
                if backgroundContext.hasChanges {
                    try backgroundContext.save()
                    LogManager.shared.log("Created session: \(sessionId)", category: "SessionSync")

                    // Call completion on main thread after successful save
                    if let completion = completion {
                        DispatchQueue.main.async {
                            completion(sessionId)
                        }
                    }
                }
            } catch {
                LogManager.shared.log("Failed to save session_created: \(error.localizedDescription)", category: "SessionSync")
            }
        }
    }
    
    // MARK: - Session History Handling
    
    /// Handle session_history message from backend (full or delta conversation history)
    ///
    /// With delta sync, backend may return only messages newer than the last_message_id
    /// iOS sent. This method merges new messages with existing ones instead of replacing all.
    ///
    /// - Parameters:
    ///   - sessionId: Session UUID
    ///   - messages: Array of message dictionaries (may be delta or full history)
    func handleSessionHistory(sessionId: String, messages: [[String: Any]]) {
        let historyStart = Date()
        LogManager.shared.log("⏱️ handleSessionHistory START - \(sessionId.prefix(8))... with \(messages.count) messages", category: "SessionSync")

        // Early return if no messages - delta sync with no new messages
        // Don't touch existing messages
        if messages.isEmpty {
            LogManager.shared.log("⏱️ handleSessionHistory COMPLETE - no new messages (delta sync up to date)", category: "SessionSync")
            return
        }

        persistenceController.performBackgroundTask { [weak self] backgroundContext in
            guard let self = self else { return }

            // Validate UUID format
            guard let sessionUUID = UUID(uuidString: sessionId) else {
                LogManager.shared.log("Invalid session ID format in handleSessionHistory: \(sessionId)", category: "SessionSync")
                return
            }

            // Fetch the session
            let fetchStart = Date()
            let fetchRequest = CDBackendSession.fetchBackendSession(id: sessionUUID)

            guard let session = try? backgroundContext.fetch(fetchRequest).first else {
                LogManager.shared.log("Session not found for history: \(sessionId)", category: "SessionSync")
                return
            }
            LogManager.shared.log("⏱️ +\(Int(Date().timeIntervalSince(fetchStart) * 1000))ms - fetched session", category: "SessionSync")

            // Get existing message IDs to avoid duplicates
            let existingIds: Set<UUID>
            if let existingMessages = session.messages?.allObjects as? [CDMessage] {
                existingIds = Set(existingMessages.map { $0.id })
                LogManager.shared.log("⏱️ Found \(existingIds.count) existing messages", category: "SessionSync")
            } else {
                existingIds = Set()
            }

            // Add only new messages (those not already in CoreData)
            let createStart = Date()
            var addedCount = 0
            for messageData in messages {
                // Extract UUID from message data
                if let messageId = self.extractMessageId(from: messageData),
                   existingIds.contains(messageId) {
                    // Skip - message already exists
                    continue
                }
                self.createMessage(messageData, sessionId: sessionId, in: backgroundContext, session: session)
                addedCount += 1
            }
            LogManager.shared.log("⏱️ +\(Int(Date().timeIntervalSince(createStart) * 1000))ms - added \(addedCount) new messages (skipped \(messages.count - addedCount) duplicates)", category: "SessionSync")

            // Prune old messages to prevent unbounded growth in long-running sessions
            // This keeps only the newest N messages (iOS only needs recent history; backend retains full)
            let pruneStart = Date()
            let prunedCount = CDMessage.pruneOldMessages(sessionId: sessionUUID, in: backgroundContext)
            if prunedCount > 0 {
                LogManager.shared.log("⏱️ +\(Int(Date().timeIntervalSince(pruneStart) * 1000))ms - pruned \(prunedCount) old messages", category: "SessionSync")
            }

            // Update session metadata with actual count after pruning
            let finalMessageCount: Int
            if let currentMessages = session.messages?.allObjects as? [CDMessage] {
                finalMessageCount = currentMessages.count
            } else {
                finalMessageCount = existingIds.count + addedCount - prunedCount
            }
            session.messageCount = Int32(finalMessageCount)
            // Note: Do NOT update lastModified here - we're replaying existing history.
            // The correct lastModified timestamp was already set from the backend's session_list message.
            // Only handleSessionUpdated() should update lastModified for truly NEW messages.

            if let lastMessage = messages.last,
               let text = self.extractText(from: lastMessage) {
                session.preview = String(text.prefix(100))
            }

            do {
                if backgroundContext.hasChanges {
                    let saveStart = Date()
                    try backgroundContext.save()
                    LogManager.shared.log("⏱️ +\(Int(Date().timeIntervalSince(saveStart) * 1000))ms - saved to CoreData", category: "SessionSync")
                    LogManager.shared.log("⏱️ handleSessionHistory COMPLETE - total: \(Int(Date().timeIntervalSince(historyStart) * 1000))ms, \(addedCount) new messages, \(prunedCount) pruned", category: "SessionSync")

                    // Post notification on main thread to trigger UI refresh
                    // This is needed because @FetchRequest may not auto-update when messages are
                    // added via background context merge (especially after backend reconnection)
                    if addedCount > 0 {
                        DispatchQueue.main.async {
                            NotificationCenter.default.post(
                                name: .sessionHistoryDidUpdate,
                                object: nil,
                                userInfo: ["sessionId": sessionId]
                            )
                        }
                    }
                } else {
                    LogManager.shared.log("⏱️ handleSessionHistory COMPLETE - no changes to save", category: "SessionSync")
                }
            } catch {
                LogManager.shared.log("Failed to save session_history: \(error.localizedDescription)", category: "SessionSync")
            }
        }
    }
    
    // MARK: - Session History Payload (v0.4.0)

    /// v0.4.0 unified entry point for a decoded `session_history` envelope.
    /// Used for both initial history replies and real-time pushes; the
    /// server emits the same shape for both paths.
    ///
    /// Implements the gap contract from
    /// docs/design/append-only-message-stream.md (AC3/AC4/AC5/AC6):
    ///
    /// 1. `gap.reason == "pruned"`: surface to delegate and return — server
    ///    has lost the range the client asked for. (AC5)
    /// 2. 3-case seq comparison against `local_last_seq = max(seq)` in cache:
    ///    - `first_seq == local_last_seq + 1` → contiguous. Upsert + advance.
    ///    - `first_seq  > local_last_seq + 1` → gap. Upsert the received
    ///       window *and* fire `sessionSyncNeedsResubscribe(fromSeq:
    ///       local_last_seq)` so the client backfills before advancing. (AC3)
    ///    - `first_seq <= local_last_seq` → duplicate / reorder. The upsert
    ///       is idempotent on `(sessionId, seq)`, so it's a no-op or
    ///       in-place update; `local_last_seq` does not regress. (AC3)
    /// 3. `is_complete == false` → immediately re-subscribe with the
    ///    advanced cursor so the next window loads without user action. (AC6)
    ///
    /// The `client_ahead` gap reason is handled as a normal merge path (no
    /// delegate fire) — the server sends a full resync via `messages` in
    /// that case, and the client upserts it like any other payload.
    func handleSessionHistoryPayload(_ payload: SessionHistoryPayload) {
        let prunedKey = payload.sessionId.lowercased()

        // Pruned gap: surface to delegate and stop. Merging anything under a
        // pruned reply would silently partial-view the user's history.
        // Mark the session synchronously so any subsequent non-gap payload
        // that arrives before the async delegate hop runs is refused below.
        if let gap = payload.gap, gap.reason == "pruned" {
            LogManager.shared.log("⚠️ Pruned gap for \(payload.sessionId): requested_last_seq=\(gap.requestedLastSeq), min_available_seq=\(gap.minAvailableSeq)", category: "SessionSync")
            prunedSessions.insert(prunedKey)
            let sessionId = payload.sessionId
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                // Pruned gap means the chain (if any) is moot — the server
                // can't satisfy our cursor and the next user action runs
                // through the dismiss flow, not a chain continuation.
                self.incompleteChainCursors.removeValue(forKey: prunedKey)
                self.delegate?.didDetectPrunedGap(sessionId, gap: gap)
            }
            return
        }

        // Refuse to merge while the user has unacknowledged pruned-gap state
        // for this session. The flag is cleared by `clearPrunedFlag` (wired
        // to the dismiss action). Without this guard a fresh push that lands
        // between pruned detection and the delegate hop would mix stale and
        // post-gap messages with no visual break.
        if prunedSessions.contains(prunedKey) {
            LogManager.shared.log("🚫 Refusing session_history merge for \(payload.sessionId) — pruned-gap flag still set; awaiting user acknowledgment", category: "SessionSync")
            return
        }

        guard let sessionUUID = UUID(uuidString: payload.sessionId) else {
            LogManager.shared.log("Invalid session ID format in handleSessionHistoryPayload: \(payload.sessionId)", category: "SessionSync")
            return
        }

        // Serialize per-session so the seqHit fetch and the insert/save form
        // a single critical section against the persistent store. Two
        // payloads on the same session that land concurrently (subscribe
        // reply crossing a live push, two backfills in quick succession)
        // would otherwise each fetch against an independent stale background
        // context and both insert duplicate rows for overlapping seqs. See
        // beads tmux-untethered-prf. Different sessions keep parallelism via
        // the per-session keying. The inner `performAndWait` blocks the
        // serial queue until the save commits, so the next dispatched
        // payload reads the freshly-saved store.
        upsertQueue(forSessionId: prunedKey).async { [weak self] in
            guard let self = self else { return }
            let backgroundContext = self.persistenceController.container.newBackgroundContext()
            backgroundContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
            backgroundContext.performAndWait {

            // Snapshot the current contiguous cursor BEFORE mutating — we
            // need the pre-upsert value to emit a correct backfill request.
            let localLastSeq = self.maxCachedSeq(sessionId: sessionUUID, in: backgroundContext)

            // 3-case gap decision. Empty windows (no first_seq) never trip a gap.
            let gapDetected: Bool
            if let firstSeq = payload.firstSeq, firstSeq > localLastSeq + 1 {
                LogManager.shared.log("📭 Gap for \(payload.sessionId): local_last_seq=\(localLastSeq), first_seq=\(firstSeq); backfilling from \(localLastSeq)", category: "SessionSync")
                gapDetected = true
            } else {
                gapDetected = false
            }

            let session = self.fetchOrCreateSession(id: sessionUUID, in: backgroundContext)
            let isActiveSession = ActiveSessionManager.shared.isActive(sessionUUID)

            // TTS gate: capture the boundary between historical and live the
            // first time we see a payload for this session in the current app
            // launch. `liveFromSeq` is reset to 0 by PersistenceController on
            // launch and by `clearLiveFromSeq` on unsubscribe, so a re-entry
            // re-captures a fresh boundary. See tmux-untethered-i2n.
            //
            // Read into a local before the loop so chain replies (the catch-up
            // window split across multiple is_complete:false re-subscribes)
            // see the same boundary that was captured on the first reply —
            // their messages all have seq < liveFromSeq and are correctly
            // suppressed.
            if session.liveFromSeq == 0 && payload.nextSeq > 0 {
                session.liveFromSeq = payload.nextSeq
            }
            let liveFromSeq = session.liveFromSeq

            // Idempotent upsert on (sessionId, seq). Safe under double
            // delivery (push+history overlap, gap-backfill crossing).
            // Collect assistant message text from newly-inserted rows so we
            // can fire auto-speak / notifications / priority-queue post-save.
            // Only assistant messages whose seq is at-or-above `liveFromSeq`
            // are eligible — anything below was already on the backend when
            // the user opened the session.
            var newRows = 0
            var newAssistantTexts: [String] = []
            for wireMessage in payload.messages {
                let inserted = self.upsertMessage(wireMessage, session: session, in: backgroundContext)
                if inserted {
                    newRows += 1
                    // `claimUnspokenMessage` dedups re-delivery that survives
                    // the (sessionId, seq) idempotency — e.g. a duplicate
                    // turn_complete fan-out re-inserting after a cache prune
                    // (tmux-untethered-icf).
                    if wireMessage.role == "assistant"
                        && liveFromSeq > 0
                        && wireMessage.seq >= liveFromSeq
                        && self.claimUnspokenMessage(sessionId: wireMessage.sessionId, uuid: wireMessage.uuid) {
                        newAssistantTexts.append(wireMessage.text)
                    }
                }
            }

            // Preview reflects the newest message the client has actually
            // seen, which is the last element in the ascending payload.
            if let lastMessage = payload.messages.last {
                session.preview = String(lastMessage.text.prefix(100))
            }

            // Persist the server-reported next-seq so reconnect after local
            // cache pruning still resumes at the right cursor. Take the max
            // so an out-of-order payload (e.g. a backfill landing after a
            // newer push) cannot regress the cursor. See beads
            // tmux-untethered-fkz.
            if payload.isComplete && payload.nextSeq > session.nextSeq {
                session.nextSeq = payload.nextSeq
            }

            // Background sessions track unread count so the sidebar badge can
            // flag inbound activity the user hasn't seen. Active sessions do
            // not — the user is already looking at them.
            if !isActiveSession && newRows > 0 {
                session.unreadCount += Int32(newRows)
            }

            // Enqueue only when this reply answers a prompt the user sent from
            // this device — see `PriorityQueueAdmission`. Read the flag before
            // save so the mutation batches into the same context commit.
            if PriorityQueueAdmission.shouldEnqueue(
                featureEnabled: UserDefaults.standard.bool(forKey: "priorityQueueEnabled"),
                hasLiveAssistantMessages: !newAssistantTexts.isEmpty,
                claimAwaitedReply: { self.pendingReplies.claim(sessionId: payload.sessionId) }) {
                if CDBackendSession.addToPriorityQueue(session, context: backgroundContext) {
                    LogManager.shared.log("📌 Enqueued session — reply to a prompt from this device: \(payload.sessionId)", category: "SessionSync")
                } else {
                    // Claim already spent — re-arm or the entry is lost outright.
                    self.pendingReplies.arm(sessionId: payload.sessionId)
                    LogManager.shared.log("⚠️ Enqueue did not commit; re-arming for the next signal: \(payload.sessionId)", category: "SessionSync")
                }
            }

            // Keep messageCount in sync with actual row count to avoid
            // drift between the sidebar count and the conversation view.
            // `session.messages` reflects pending inserts synchronously
            // because `message.session = session` walks the inverse and
            // updates the NSSet before save.
            if let currentMessages = session.messages?.allObjects as? [CDMessage] {
                session.messageCount = Int32(currentMessages.count)
            }

            do {
                if backgroundContext.hasChanges {
                    try backgroundContext.save()
                }
                // Posted on `newRows`, not on `hasChanges`: the priority-queue
                // enqueue above commits the context itself, so gating the
                // notification on pending changes silently dropped the refresh
                // for exactly the batches that mattered most.
                if newRows > 0 {
                    let sessionId = payload.sessionId
                    DispatchQueue.main.async {
                        NotificationCenter.default.post(
                            name: .sessionHistoryDidUpdate,
                            object: nil,
                            userInfo: ["sessionId": sessionId]
                        )
                    }
                }
            } catch {
                let nsError = error as NSError
                LogManager.shared.log("Failed to save session_history payload: domain=\(nsError.domain) code=\(nsError.code) userInfo=\(nsError.userInfo)", category: "SessionSync")
                // Don't stay stuck: ask the client to resubscribe from the
                // pre-payload cursor so the next push attempts a fresh save
                // instead of permanently leaving local_last_seq stale. Also
                // drop the chain cursor — recovery is a fresh start, not a
                // continuation of whatever is_complete chain was active.
                let sessionId = payload.sessionId
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.incompleteChainCursors.removeValue(forKey: sessionId.lowercased())
                    self.delegate?.sessionSyncNeedsResubscribe(sessionId, fromSeq: localLastSeq)
                }
                return
            }

            // Prune old messages to keep CoreData footprint bounded during
            // long conversations. Only runs past the retention threshold.
            if newRows > 0 && CDMessage.needsPruning(sessionId: sessionUUID, in: backgroundContext) {
                let deletedCount = CDMessage.pruneOldMessages(sessionId: sessionUUID, in: backgroundContext)
                if deletedCount > 0 {
                    session.messageCount -= Int32(deletedCount)
                    try? backgroundContext.save()
                    LogManager.shared.log("🧹 Pruned \(deletedCount) old messages from session \(payload.sessionId)", category: "SessionSync")
                }
            }

            // Side-effect fan-out for new assistant messages. Active sessions
            // speak; background sessions post a local notification so the
            // user can surface the response from outside the app.
            if !newAssistantTexts.isEmpty {
                if isActiveSession {
                    let workingDirectory = session.workingDirectory
                    let voiceManager = self.voiceOutputManager
                    DispatchQueue.main.async {
                        // Re-check on main thread: the snapshot above was
                        // taken before the CoreData save; the user may have
                        // switched sessions during the async gap. Speaking
                        // against a stale snapshot would TTS for a session
                        // they no longer have open.
                        guard ActiveSessionManager.shared.isActive(sessionUUID) else { return }
                        guard let voiceManager = voiceManager else { return }
                        for text in newAssistantTexts {
                            let processedText = TextProcessor.prepareForSpeech(from: text)
                            voiceManager.speak(processedText, respectSilentMode: true, workingDirectory: workingDirectory, sessionId: sessionUUID)
                        }
                    }
                } else {
                    let sessionName = session.displayName(context: backgroundContext)
                    let workingDirectory = session.workingDirectory
                    let combinedText = newAssistantTexts.joined(separator: "\n\n")
                    DispatchQueue.main.async {
                        Task {
                            await NotificationManager.shared.postResponseNotification(
                                text: combinedText,
                                sessionName: sessionName,
                                workingDirectory: workingDirectory
                            )
                        }
                    }
                }
            }

            // Follow-up subscribes. Gap backfill takes precedence — the gap
            // window is still open, so chasing `is_complete: false` from this
            // same payload would advance past it. The gap resubscribe itself
            // may reply with `is_complete: false`; that subsequent payload
            // will chain its own window.
            //
            // The chain-cursor bookkeeping below guards against an unbounded
            // is_complete:false loop (beads tmux-untethered-l8t): if the
            // server keeps returning is_complete:false without advancing
            // past the cursor we asked from, the chain is aborted and the
            // failure is surfaced via `sessionSyncDidStallChain`. All
            // mutation of `incompleteChainCursors` happens on main, where
            // the resubscribe is already dispatched.
            let sessionId = payload.sessionId
            let isComplete = payload.isComplete
            let receivedLastSeq = payload.lastSeq
            let preGapCursor = localLastSeq
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                let key = sessionId.lowercased()

                if gapDetected {
                    // Switching to gap-backfill path — drop any in-flight
                    // is_complete chain so a later payload doesn't compare
                    // its lastSeq against a stale cursor from a different
                    // resubscribe sequence.
                    self.incompleteChainCursors.removeValue(forKey: key)
                    self.delegate?.sessionSyncNeedsResubscribe(sessionId, fromSeq: preGapCursor)
                } else if !isComplete {
                    // Empty payload with is_complete:false means the server
                    // could not fit even one message in the byte budget for
                    // the requested cursor — the pathological case the
                    // chain guard exists for. Fall back to the pre-payload
                    // cursor only so logs show the unchanged value;
                    // advancement is judged from `receivedLastSeq`.
                    let nextCursor = receivedLastSeq ?? preGapCursor
                    if let prevAskedCursor = self.incompleteChainCursors[key] {
                        // Did the server include at least one message above
                        // where we asked? lastSeq == nil means no messages
                        // at all, which is non-progress by definition.
                        let advanced: Bool
                        if let last = receivedLastSeq {
                            advanced = last > prevAskedCursor
                        } else {
                            advanced = false
                        }
                        if !advanced {
                            LogManager.shared.log("⛔ Aborting is_complete:false chain for \(sessionId): cursor stalled at \(prevAskedCursor); payload last_seq=\(receivedLastSeq.map(String.init) ?? "nil")", category: "SessionSync")
                            self.incompleteChainCursors.removeValue(forKey: key)
                            self.delegate?.sessionSyncDidStallChain(sessionId, atCursor: prevAskedCursor)
                            return
                        }
                    }
                    self.incompleteChainCursors[key] = nextCursor
                    self.delegate?.sessionSyncNeedsResubscribe(sessionId, fromSeq: nextCursor)
                } else {
                    // is_complete: true → chain (if any) terminated naturally.
                    self.incompleteChainCursors.removeValue(forKey: key)
                }
            }
            }
        }
    }

    // MARK: - Session History Payload (v0.5.0)

    /// v0.5.0 entry point for a decoded `session_history` envelope. Routed
    /// from `VoiceCodeClient.handleSessionHistoryFrame` when the channel is
    /// negotiated to `.v0_5_0`. The semantics collapse the v0.4.0 gap-and-
    /// chain logic to: optional `file_replaced` recovery → optional
    /// "I-was-ahead" reset → TTS-boundary capture (gated on `nextOffset > 0`)
    /// → idempotent `(sessionId, offset)` upsert → cursor advance.
    ///
    /// See voice-code-sync-kafka-redesign-2026-05-10.md §3.3 (handler) and
    /// §3.5 / §6 R2 (file_replaced recovery and purge semantics).
    func handleSessionHistoryPayload(_ payload: SessionHistoryPayloadV5) {
        guard let sessionUUID = UUID(uuidString: payload.sessionId) else {
            LogManager.shared.log("Invalid session ID in v5 handleSessionHistoryPayload: \(payload.sessionId)", category: "SessionSync")
            return
        }

        // Serialize per-session against the same queue the v0.4.0 path uses
        // so a v4-then-v5 (or simultaneous) delivery for the same session
        // never overlaps. Keyed on lowercased UUID like v0.4.0.
        upsertQueue(forSessionId: payload.sessionId.lowercased()).async { [weak self] in
            guard let self = self else { return }
            let ctx = self.persistenceController.container.newBackgroundContext()
            ctx.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
            ctx.performAndWait {
                let session = self.fetchOrCreateSession(id: sessionUUID, in: ctx)

                // R2 file-replaced recovery — the server's signature has
                // changed since we last subscribed (compaction, in-place
                // rewrite, restore-from-backup). Purge every cached row,
                // zero both cursors, persist the new signature, save, then
                // re-subscribe from offset 0. Order is load-bearing: the
                // save MUST land before the re-subscribe dispatch, or the
                // next subscribe re-sends the stale signature and the
                // server replies `file_replaced: true` again, looping.
                if payload.fileReplaced == true {
                    // R2 recovery — the server's file signature changed since we
                    // last subscribed (compaction, in-place rewrite, restore).
                    // The byte/line offsets are now meaningless, so we DO
                    // re-subscribe from offset 0. But we must NOT purge the
                    // cached rows: a purge blanks the conversation, and under the
                    // rapid signature churn seen in the field (e.g. three
                    // signatures within ~90s) it blanks it repeatedly — dropping
                    // the just-arrived assistant message the user is reading even
                    // though it was already received and spoken. Instead, reset
                    // only the merge cursor and let the from-0 replay reconcile
                    // every message by its stable UUID (see the uuidHit branch in
                    // upsertMessage(_:WireMessageV5)): a message that reappears at
                    // a new offset updates its existing row in place, so the
                    // visible tail is retained rather than wiped-and-refetched.
                    // Rows for messages the rewrite genuinely removed are the
                    // oldest entries and are evicted by the normal tail-anchored
                    // prune (CDMessage.pruneOldMessages keeps the newest N).
                    // (blueparrott-sync-fixes bug 1.)
                    LogManager.shared.log("🔁 file_replaced for \(payload.sessionId): re-subscribing from offset 0 and reconciling by UUID — retaining the visible tail (new signature=\(payload.fileSignature ?? "<nil>"))", category: "SessionSync")
                    session.lastOffsetMerged = 0
                    session.liveFromOffset = 0
                    // Server contract says R2 always carries a fresh
                    // signature; if it's missing, hold the cached value
                    // rather than clobbering to nil so the next subscribe
                    // can still send `file_signature_seen` and trigger a
                    // second R2 if the underlying file is genuinely replaced.
                    if let sig = payload.fileSignature {
                        session.lastFileSignature = sig
                    }
                    // NOTE: deliberately no purgeMessagesAtOrAbove / messageCount
                    // reset here — the rows survive so the UI never goes blank.
                    do {
                        try ctx.save()
                    } catch {
                        LogManager.shared.log("Failed to save file_replaced recovery for \(payload.sessionId): \(error.localizedDescription)", category: "SessionSync")
                        return
                    }
                    let sessionId = payload.sessionId
                    DispatchQueue.main.async { [weak self] in
                        guard let self = self else { return }
                        // Clear any in-flight end_of_file chain — the file was
                        // replaced, so the prior chain's cursor is meaningless
                        // for the incoming fresh subscribe.
                        self.incompleteChainCursorsV5.removeValue(forKey: sessionId.lowercased())
                        self.delegate?.sessionSyncRequestsResubscribeFromZero(sessionUUID)
                    }
                    return
                }

                // Always-persist the latest file signature on non-mismatch
                // replies so the next subscribe carries the freshest seen
                // value. Server emits `file_signature` on every v0.5.0
                // reply (push and history alike).
                if let sig = payload.fileSignature {
                    session.lastFileSignature = sig
                }

                // "I was ahead; reset" — server's `next_offset` is strictly
                // less than the cursor we hold. Happens after backend data
                // loss / rollback that lost the JSONL tail. Purge any rows
                // past the new watermark and let the upsert below refill
                // anything the reply carries.
                if payload.nextOffset < session.lastOffsetMerged {
                    LogManager.shared.log("🔁 Reset cursor for \(payload.sessionId): had=\(session.lastOffsetMerged), server next_offset=\(payload.nextOffset)", category: "SessionSync")
                    session.lastOffsetMerged = payload.nextOffset
                    self.purgeMessagesAtOrAbove(offset: payload.nextOffset, session: session, in: ctx)
                }

                // TTS boundary — capture on the first *complete* (endOfFile:true)
                // non-empty reply this launch.
                //
                // Why endOfFile is required: in v0.5.0, `nextOffset` is the batch
                // end (last_message_offset + 1), NOT the global session head like
                // v0.4.0's `nextSeq`. An endOfFile:false chain re-subscribes from
                // nextOffset, so the next batch starts at that same offset. If we
                // anchored liveFromOffset to the first batch's nextOffset (e.g. 100),
                // chain payloads would contain messages at offsets 100, 101, …—all
                // ≥ liveFromOffset—and would be spoken aloud as if live. Holding
                // liveFromOffset=0 keeps the `liveFromOffset > 0` gate closed for
                // the entire chain; the final endOfFile:true payload carries
                // nextOffset = file-end-line-count (true global head), which is the
                // correct TTS boundary (regression fix for "session history replay TTS").
                //
                // The `nextOffset > 0` guard prevents an empty caught-up reply
                // (nextOffset=0) from pinning liveFromOffset=0, which would cause
                // all subsequent messages to satisfy `offset >= 0` and be spoken
                // (regression guard for tmux-untethered-i2n).
                if session.liveFromOffset == 0 && payload.nextOffset > 0 && payload.endOfFile {
                    session.liveFromOffset = payload.nextOffset
                }
                let liveFromOffset = session.liveFromOffset

                // Idempotent upsert keyed on `(sessionId, offset)`. Only
                // newly-inserted assistant rows at or above the captured
                // boundary are eligible for TTS.
                var newRows = 0
                var newAssistantTexts: [String] = []
                for wireMessage in payload.messages {
                    let inserted = self.upsertMessage(wireMessage, session: session, in: ctx)
                    if inserted {
                        newRows += 1
                        // The `claimUnspokenMessage` check is the cross-purge
                        // dedup: after a `file_replaced` recovery the row was
                        // purged so `inserted` is true again, but the UUID set
                        // still remembers we already spoke it — preventing the
                        // 2-3x re-speak on signature churn (tmux-untethered-icf).
                        if wireMessage.role == "assistant"
                            && liveFromOffset > 0
                            && wireMessage.offset >= liveFromOffset
                            && self.claimUnspokenMessage(sessionId: wireMessage.sessionId, uuid: wireMessage.uuid) {
                            newAssistantTexts.append(wireMessage.text)
                        }
                    }
                }

                // Advance the cursor. `max` absorbs out-of-order delivery
                // (a push and history reply for the same session crossing
                // on the wire would otherwise let the older `next_offset`
                // regress the cursor).
                if payload.nextOffset > session.lastOffsetMerged {
                    session.lastOffsetMerged = payload.nextOffset
                }

                if let lastMessage = payload.messages.last {
                    session.preview = String(lastMessage.text.prefix(100))
                }

                // Count via a direct CDMessage fetch rather than the
                // inverse relationship: `NSBatchDeleteRequest` in
                // `purgeMessagesAtOrAbove` bypasses inverse-relationship
                // maintenance, so `session.messages?.allObjects` can hold
                // stale references to now-deleted MOs after an
                // "I was ahead; reset" partial purge. A count fetch reads
                // from the persistent store, which the merge has already
                // updated.
                let countRequest = CDMessage.fetchRequest()
                countRequest.predicate = NSPredicate(format: "sessionId == %@",
                                                     sessionUUID as CVarArg)
                let liveCount = (try? ctx.count(for: countRequest)) ?? 0
                session.messageCount = Int32(liveCount)

                let isActiveSession = ActiveSessionManager.shared.isActive(sessionUUID)
                if !isActiveSession && newRows > 0 {
                    session.unreadCount += Int32(newRows)
                }

                // Enqueue only when this reply answers a prompt the user sent
                // from this device — see `PriorityQueueAdmission`.
                if PriorityQueueAdmission.shouldEnqueue(
                    featureEnabled: UserDefaults.standard.bool(forKey: "priorityQueueEnabled"),
                    hasLiveAssistantMessages: !newAssistantTexts.isEmpty,
                    claimAwaitedReply: { self.pendingReplies.claim(sessionId: payload.sessionId) }) {
                    if CDBackendSession.addToPriorityQueue(session, context: ctx) {
                        LogManager.shared.log("📌 Enqueued session — reply to a prompt from this device: \(payload.sessionId)", category: "SessionSync")
                    } else {
                        self.pendingReplies.arm(sessionId: payload.sessionId)
                        LogManager.shared.log("⚠️ Enqueue did not commit; re-arming for the next signal: \(payload.sessionId)", category: "SessionSync")
                    }
                }

                do {
                    if ctx.hasChanges {
                        try ctx.save()
                    }
                    // See the v0.4.0 path: posted on `newRows`, not on
                    // `hasChanges`, because the enqueue above already committed.
                    if newRows > 0 {
                        let sessionIdString = payload.sessionId
                        DispatchQueue.main.async {
                            NotificationCenter.default.post(
                                name: .sessionHistoryDidUpdate,
                                object: nil,
                                userInfo: ["sessionId": sessionIdString]
                            )
                        }
                    }
                } catch {
                    let nsError = error as NSError
                    LogManager.shared.log("Failed to save v5 session_history payload: domain=\(nsError.domain) code=\(nsError.code) userInfo=\(nsError.userInfo)", category: "SessionSync")
                    return
                }

                if newRows > 0 && CDMessage.needsPruning(sessionId: sessionUUID, in: ctx) {
                    let deletedCount = CDMessage.pruneOldMessages(sessionId: sessionUUID, in: ctx)
                    if deletedCount > 0 {
                        session.messageCount -= Int32(deletedCount)
                        try? ctx.save()
                        LogManager.shared.log("🧹 Pruned \(deletedCount) old messages from session \(payload.sessionId)", category: "SessionSync")
                    }
                }

                // Follow-up subscribe when the server's byte budget was
                // exhausted (end_of_file:false). Mirrors v0.4.0's
                // is_complete:false chain: re-subscribe with the advanced
                // nextOffset so the next window loads without user action.
                // Stall guard: if next_offset has not advanced past the
                // cursor from the previous chain step, abort to prevent an
                // unbounded loop (same logic as v0.4.0's
                // incompleteChainCursors / sessionSyncDidStallChain).
                let sessionId = payload.sessionId
                let nextOffset = payload.nextOffset
                let endOfFile = payload.endOfFile
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    let key = sessionId.lowercased()
                    if !endOfFile {
                        if let prevCursor = self.incompleteChainCursorsV5[key],
                           nextOffset <= prevCursor {
                            LogManager.shared.log("⛔ Aborting end_of_file:false chain for \(sessionId): cursor stalled at \(prevCursor); payload next_offset=\(nextOffset)", category: "SessionSync")
                            self.incompleteChainCursorsV5.removeValue(forKey: key)
                            self.delegate?.sessionSyncDidStallChain(sessionId, atCursor: prevCursor)
                            return
                        }
                        self.incompleteChainCursorsV5[key] = nextOffset
                        self.delegate?.sessionSyncNeedsResubscribe(sessionId, fromSeq: nextOffset)
                    } else {
                        self.incompleteChainCursorsV5.removeValue(forKey: key)
                    }
                }

                if !newAssistantTexts.isEmpty {
                    if isActiveSession {
                        let workingDirectory = session.workingDirectory
                        let voiceManager = self.voiceOutputManager
                        DispatchQueue.main.async {
                            guard ActiveSessionManager.shared.isActive(sessionUUID) else { return }
                            guard let voiceManager = voiceManager else { return }
                            for text in newAssistantTexts {
                                let processedText = TextProcessor.prepareForSpeech(from: text)
                                voiceManager.speak(processedText, respectSilentMode: true, workingDirectory: workingDirectory, sessionId: sessionUUID)
                            }
                        }
                    } else {
                        let sessionName = session.displayName(context: ctx)
                        let workingDirectory = session.workingDirectory
                        let combinedText = newAssistantTexts.joined(separator: "\n\n")
                        DispatchQueue.main.async {
                            Task {
                                await NotificationManager.shared.postResponseNotification(
                                    text: combinedText,
                                    sessionName: sessionName,
                                    workingDirectory: workingDirectory
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    /// Delete every `CDMessage` belonging to `session` whose `offset >=
    /// offset`. Used in two places: the "I-was-ahead" reset (partial purge
    /// of rows past the server's watermark) and `file_replaced` recovery
    /// (full purge with `offset = 0`).
    ///
    /// Caller responsibility:
    ///   - Set `session.lastOffsetMerged = offset` BEFORE calling so a
    ///     concurrent reader doesn't observe deleted rows referenced by an
    ///     advanced cursor.
    ///   - Set `session.liveFromOffset = 0` on a full purge (`offset == 0`);
    ///     a partial purge leaves it alone — the TTS boundary is "what was
    ///     historical at app launch," not "what's still in the local DB."
    ///   - Recompute `session.messageCount` AFTER the delete; CoreData does
    ///     not auto-update the denormalized count for batch deletes.
    ///
    /// Implementation note: uses `NSBatchDeleteRequest` for predicate
    /// performance on large purges, then merges the deletion into the
    /// supplied context (and the main viewContext) so any `@FetchRequest`
    /// observers see the rows disappear immediately.
    func purgeMessagesAtOrAbove(offset: Int64,
                                session: CDBackendSession,
                                in ctx: NSManagedObjectContext) {
        let fetch = NSFetchRequest<NSFetchRequestResult>(entityName: "CDMessage")
        fetch.predicate = NSPredicate(format: "sessionId == %@ AND offset >= %lld",
                                      session.id as CVarArg, offset)
        let delete = NSBatchDeleteRequest(fetchRequest: fetch)
        delete.resultType = .resultTypeObjectIDs

        do {
            let result = try ctx.execute(delete) as? NSBatchDeleteResult
            if let deletedIDs = result?.result as? [NSManagedObjectID], !deletedIDs.isEmpty {
                let changes: [AnyHashable: Any] = [NSDeletedObjectsKey: deletedIDs]
                NSManagedObjectContext.mergeChanges(fromRemoteContextSave: changes,
                                                   into: [ctx, persistenceController.container.viewContext])
                LogManager.shared.log("🧹 Purged \(deletedIDs.count) messages at-or-above offset \(offset) for session \(session.id.uuidString.lowercased())", category: "SessionSync")
            }
        } catch {
            LogManager.shared.log("purgeMessagesAtOrAbove failed for session \(session.id.uuidString.lowercased()) offset=\(offset): \(error.localizedDescription)", category: "SessionSync")
        }
    }

    /// Idempotent upsert of a `WireMessageV5`, keyed on `(sessionId, offset)`
    /// with an optimistic-reconciliation fallback on
    /// `(sessionId, role, text, status == .sending)`. Sibling of the v0.4.0
    /// `upsertMessage(_ wireMessage: WireMessage, …)` — the two share the
    /// optimistic-fallback contract so reconnecting under either protocol
    /// upgrades a "sending" row in place rather than spawning a duplicate.
    @discardableResult
    internal func upsertMessage(_ wireMessage: WireMessageV5, session: CDBackendSession, in context: NSManagedObjectContext) -> Bool {
        guard let wireSessionUUID = UUID(uuidString: wireMessage.sessionId) else {
            LogManager.shared.log("Invalid wire session ID in v5 upsert: \(wireMessage.sessionId)", category: "SessionSync")
            return false
        }

        guard wireSessionUUID == session.id else {
            LogManager.shared.log("v5 wire message session \(wireMessage.sessionId) does not match payload session \(session.id.uuidString.lowercased()); dropping", category: "SessionSync")
            return false
        }

        let offsetRequest = CDMessage.fetchRequest()
        offsetRequest.predicate = NSPredicate(format: "sessionId == %@ AND offset == %lld",
                                              wireSessionUUID as CVarArg,
                                              wireMessage.offset)
        offsetRequest.fetchLimit = 1

        let offsetHit = (try? context.fetch(offsetRequest))?.first

        // UUID reconciliation (file_replaced / compaction recovery). The same
        // message can reappear at a *different* offset after the transcript
        // file is rewritten and we re-subscribe from offset 0. Match the
        // stable server UUID so the existing row is updated in place (its
        // `offset` rewritten below) instead of spawning a duplicate. `id`
        // carries CDMessage's uniqueness constraint, so a UUID match maps a
        // message to exactly one row regardless of how its offset moved. This
        // is what lets `file_replaced` recovery reconcile-and-retain the
        // visible tail rather than purge-and-refetch it (blueparrott-sync-fixes
        // bug 1: signature churn dropped the just-arrived assistant message).
        let uuidHit: CDMessage? = {
            guard offsetHit == nil, let wireUUID = UUID(uuidString: wireMessage.uuid) else { return nil }
            let req = CDMessage.fetchRequest()
            req.predicate = NSPredicate(format: "sessionId == %@ AND id == %@",
                                        wireSessionUUID as CVarArg,
                                        wireUUID as CVarArg)
            req.fetchLimit = 1
            return (try? context.fetch(req))?.first
        }()

        // Optimistic fallback: a locally-created "sending" row with matching
        // role+text can be upgraded in place when its server-assigned offset
        // first lands. Identical contract to the v0.4.0 path.
        let optimistic: CDMessage? = {
            guard offsetHit == nil, uuidHit == nil else { return nil }
            let req = CDMessage.fetchRequest()
            req.predicate = NSPredicate(format: "sessionId == %@ AND role == %@ AND text == %@ AND status == %@",
                                        wireSessionUUID as CVarArg,
                                        wireMessage.role,
                                        wireMessage.text,
                                        MessageStatus.sending.rawValue)
            req.fetchLimit = 1
            return (try? context.fetch(req))?.first
        }()

        let existing = offsetHit ?? uuidHit ?? optimistic
        let message = existing ?? CDMessage(context: context)
        let isNew = existing == nil

        message.sessionId = wireSessionUUID
        message.role = wireMessage.role
        message.text = wireMessage.text
        message.offset = wireMessage.offset
        message.timestamp = wireMessage.timestamp
        message.serverTimestamp = wireMessage.timestamp
        message.messageStatus = .confirmed
        message.session = session

        if let wireUUID = UUID(uuidString: wireMessage.uuid) {
            if isNew {
                message.id = wireUUID
            } else if message.id != wireUUID && wireUUIDIsUnique(wireUUID, in: context) {
                message.id = wireUUID
            }
        } else if isNew {
            message.id = UUID()
        }

        return isNew
    }

    /// Clear the pruned-gap flag for a session so subsequent
    /// `session_history` payloads merge normally. Wired to the dismiss
    /// action in the UI layer (see `VoiceCodeClient.dismissPrunedGap`).
    /// Must be called on the main queue.
    func clearPrunedFlag(sessionId: String) {
        prunedSessions.remove(sessionId.lowercased())
    }

    /// Reset the TTS gate cursor for a session so the next subscribe reply
    /// re-captures `liveFromSeq` from its `nextSeq`. Called from
    /// `VoiceCodeClient.unsubscribe` so leaving and re-entering a session
    /// treats messages produced during the absence as historical (the user
    /// expects voice-out only for content produced after they reopened the
    /// session). See tmux-untethered-i2n.
    func clearLiveFromSeq(sessionId: String) {
        guard let sessionUUID = UUID(uuidString: sessionId) else { return }
        persistenceController.performBackgroundTask { backgroundContext in
            let request = CDBackendSession.fetchBackendSession(id: sessionUUID)
            guard let session = try? backgroundContext.fetch(request).first else { return }
            if session.liveFromSeq != 0 {
                session.liveFromSeq = 0
                try? backgroundContext.save()
            }
        }
    }

    /// v0.5.0 equivalent of `clearLiveFromSeq`. Zeroes `liveFromOffset` so
    /// the next `session_history` reply re-captures the boundary from its
    /// `next_offset`. Without this, backfill messages that arrive after a
    /// navigate-away / navigate-back have offsets above the stale boundary
    /// and are incorrectly spoken as live.
    func clearLiveFromOffset(sessionId: String) {
        guard let sessionUUID = UUID(uuidString: sessionId) else { return }
        persistenceController.performBackgroundTask { backgroundContext in
            let request = CDBackendSession.fetchBackendSession(id: sessionUUID)
            guard let session = try? backgroundContext.fetch(request).first else { return }
            if session.liveFromOffset != 0 {
                session.liveFromOffset = 0
                try? backgroundContext.save()
            }
        }
    }

    // MARK: - Session History Payload helpers

    /// Returns the largest backend-assigned `seq` stored for this session,
    /// or 0 if none. Used as the client's `local_last_seq` cursor for gap
    /// detection. Optimistic rows carry a deterministic negative seq (see
    /// `optimisticSeq(for:)`) and are excluded from the cursor — the wire
    /// treats `seq=0` as "send everything", which is the right state when
    /// only locally-created rows exist.
    internal func maxCachedSeq(sessionId: UUID, in context: NSManagedObjectContext) -> Int64 {
        let request = CDMessage.fetchRequest()
        request.predicate = NSPredicate(format: "sessionId == %@ AND seq > 0", sessionId as CVarArg)
        request.sortDescriptors = [NSSortDescriptor(keyPath: \CDMessage.seq, ascending: false)]
        request.fetchLimit = 1
        return (try? context.fetch(request))?.first?.seq ?? 0
    }

    /// Fetch an existing `CDBackendSession` by id, or create a minimal one so
    /// incoming messages have a parent relationship. Mirrors the lazy-create
    /// path in `handleSessionUpdated`.
    private func fetchOrCreateSession(id sessionUUID: UUID, in context: NSManagedObjectContext) -> CDBackendSession {
        let request = CDBackendSession.fetchBackendSession(id: sessionUUID)
        if let existing = try? context.fetch(request).first {
            return existing
        }
        LogManager.shared.log("Creating new session from history payload: \(sessionUUID.uuidString.lowercased())", category: "SessionSync")
        let session = CDBackendSession(context: context)
        session.id = sessionUUID
        session.backendName = ""
        session.workingDirectory = ""
        session.lastModified = Date()
        session.unreadCount = 0
        session.isLocallyCreated = false
        return session
    }

    /// Idempotent upsert of a `WireMessage`, keyed on `(sessionId, seq)` with
    /// an optimistic-reconciliation fallback on `(sessionId, role, text,
    /// status == .sending)`. The fallback upgrades a locally-created
    /// "sending" row to "confirmed" in place rather than spawning a duplicate
    /// when the backend echoes a user prompt. See `createOptimisticMessage`.
    ///
    /// - Returns: `true` when a new row was inserted, `false` when an
    ///   existing row was updated in place (or when the wire sessionId was
    ///   malformed and the row could not be stored).
    @discardableResult
    internal func upsertMessage(_ wireMessage: WireMessage, session: CDBackendSession, in context: NSManagedObjectContext) -> Bool {
        guard let wireSessionUUID = UUID(uuidString: wireMessage.sessionId) else {
            LogManager.shared.log("Invalid wire session ID in upsert: \(wireMessage.sessionId)", category: "SessionSync")
            return false
        }

        // Consistency guard: the wire message's session_id must match the
        // envelope-level session we're merging into. Drop any mismatched rows
        // so the scalar `sessionId` and the `session` relationship never
        // disagree. Backend should never emit this, but trust-but-verify.
        guard wireSessionUUID == session.id else {
            LogManager.shared.log("Wire message session \(wireMessage.sessionId) does not match payload session \(session.id.uuidString.lowercased()); dropping", category: "SessionSync")
            return false
        }

        let seqRequest = CDMessage.fetchRequest()
        seqRequest.predicate = NSPredicate(format: "sessionId == %@ AND seq == %lld",
                                           wireSessionUUID as CVarArg,
                                           wireMessage.seq)
        seqRequest.fetchLimit = 1

        let seqHit = (try? context.fetch(seqRequest))?.first

        // Optimistic fallback: no row with this seq yet, but we may already
        // have a locally-created "sending" row with matching role+text. Upgrade
        // it in place so the UI reconciles without a duplicate bubble.
        let optimistic: CDMessage? = {
            guard seqHit == nil else { return nil }
            let req = CDMessage.fetchRequest()
            req.predicate = NSPredicate(format: "sessionId == %@ AND role == %@ AND text == %@ AND status == %@",
                                        wireSessionUUID as CVarArg,
                                        wireMessage.role,
                                        wireMessage.text,
                                        MessageStatus.sending.rawValue)
            req.fetchLimit = 1
            return (try? context.fetch(req))?.first
        }()

        let existing = seqHit ?? optimistic
        let message = existing ?? CDMessage(context: context)
        let isNew = existing == nil

        message.sessionId = wireSessionUUID
        message.role = wireMessage.role
        message.text = wireMessage.text
        message.seq = wireMessage.seq
        message.timestamp = wireMessage.timestamp
        message.serverTimestamp = wireMessage.timestamp
        message.messageStatus = .confirmed
        message.session = session

        // Keep the backend-assigned UUID aligned with what the wire carries.
        // On brand-new rows we must set an id (CDMessage requires non-nil);
        // on updates we overwrite to catch any server-side id rewrites.
        // For *existing* rows, skip the reassignment when another row already
        // holds wireUUID — that would trip the (id) uniqueness constraint and
        // throw on save. The current row keeps its existing id (which is
        // unique). The merge policy on background contexts is the belt; this
        // guard is the suspenders that avoids reaching it for the predictable
        // collision. Brand-new rows have no @NSManaged id yet — read-before-
        // write is undefined, so we skip the comparison entirely on isNew.
        if let wireUUID = UUID(uuidString: wireMessage.uuid) {
            if isNew {
                message.id = wireUUID
            } else if message.id != wireUUID && wireUUIDIsUnique(wireUUID, in: context) {
                message.id = wireUUID
            }
        } else if isNew {
            message.id = UUID()
        }

        return isNew
    }

    /// True when no row in `context` already holds `id`. The caller has
    /// already verified `message.id != id`, so a hit can only be a different
    /// row — there is no need for a `SELF != %@` clause (which behaves
    /// unreliably against unsaved-temporary-objectID rows).
    private func wireUUIDIsUnique(_ id: UUID, in context: NSManagedObjectContext) -> Bool {
        let req = CDMessage.fetchRequest()
        req.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        req.fetchLimit = 1
        return ((try? context.count(for: req)) ?? 0) == 0
    }

    // MARK: - Optimistic UI

    /// Deterministic negative seq for an optimistic message, derived from its
    /// UUID. Two optimistic messages with different UUIDs produce different
    /// seqs, so multiple pending offline rows have unique `(sessionId, seq)`
    /// pairs instead of all colliding on `seq=0`. Backend-assigned seqs start
    /// at 1, so a strictly-negative seq is unambiguously "not yet confirmed
    /// by server" and never matches the seq lookup in `upsertMessage`. See
    /// beads tmux-untethered-mgp.
    internal static func optimisticSeq(for id: UUID) -> Int64 {
        // Squeeze the 128-bit UUID into a 63-bit non-zero magnitude using
        // the first 8 bytes XORed with the last 8 bytes — preserves entropy
        // without depending on Swift's hashValue (which is salted per-run
        // and would defeat determinism across launches).
        let bytes = id.uuid
        var hi: UInt64 = 0
        var lo: UInt64 = 0
        hi |= UInt64(bytes.0) << 56
        hi |= UInt64(bytes.1) << 48
        hi |= UInt64(bytes.2) << 40
        hi |= UInt64(bytes.3) << 32
        hi |= UInt64(bytes.4) << 24
        hi |= UInt64(bytes.5) << 16
        hi |= UInt64(bytes.6) << 8
        hi |= UInt64(bytes.7)
        lo |= UInt64(bytes.8) << 56
        lo |= UInt64(bytes.9) << 48
        lo |= UInt64(bytes.10) << 40
        lo |= UInt64(bytes.11) << 32
        lo |= UInt64(bytes.12) << 24
        lo |= UInt64(bytes.13) << 16
        lo |= UInt64(bytes.14) << 8
        lo |= UInt64(bytes.15)
        // Clear the sign bit to keep the magnitude in [0, Int64.max], then
        // ensure non-zero so the result is strictly negative after negation.
        let magnitude = Int64((hi ^ lo) & 0x7FFF_FFFF_FFFF_FFFF)
        return magnitude == 0 ? -1 : -magnitude
    }

    /// Create an optimistic message immediately when user sends a prompt
    /// - Parameters:
    ///   - sessionId: Session UUID
    ///   - text: User's prompt text
    ///   - completion: Called on main thread with the created message ID
    func createOptimisticMessage(sessionId: UUID, text: String, completion: @escaping (UUID) -> Void) {
        LogManager.shared.log("Creating optimistic message for session: \(sessionId.uuidString.lowercased())", category: "SessionSync")

        let messageId = UUID()

        persistenceController.performBackgroundTask { [weak self] backgroundContext in
            guard let self = self else { return }

            // Fetch the session
            let fetchRequest = CDBackendSession.fetchBackendSession(id: sessionId)

            guard let session = try? backgroundContext.fetch(fetchRequest).first else {
                LogManager.shared.log("Session not found for optimistic message: \(sessionId.uuidString.lowercased())", category: "SessionSync")
                return
            }

            // Create optimistic message
            let message = CDMessage(context: backgroundContext)
            message.id = messageId
            message.sessionId = sessionId
            message.role = "user"
            message.text = text
            message.timestamp = Date()
            message.messageStatus = .sending
            message.session = session
            // Distinct negative seq per optimistic row: prevents two
            // back-to-back prompts from colliding on the seq=0 default and
            // stranding the second one when the backend echo arrives. See
            // beads tmux-untethered-mgp.
            message.seq = Self.optimisticSeq(for: messageId)
            // v0.5.0: mirror the negative sentinel into `offset` so that the
            // (sessionId, offset) lookup in upsertMessage(_:WireMessageV5) never
            // matches an optimistic row. Without this, any confirmed message at
            // offset=0 (the first JSONL line) would collide with every optimistic
            // row (whose @NSManaged offset defaults to 0), potentially overwriting
            // a pending prompt with historical content. See beads tmux-untethered-mqo.
            message.offset = Self.optimisticSeq(for: messageId)

            LogManager.shared.log("📝 Optimistic message prepared: id=\(messageId) sessionId=\(sessionId.uuidString.lowercased()) role=user text_length=\(text.count) status=sending seq=\(message.seq) offset=\(message.offset)", category: "SessionSync")
            
            // Update session metadata optimistically
            session.lastModified = Date()
            session.messageCount += 1
            session.preview = String(text.prefix(100))
            
            do {
                if backgroundContext.hasChanges {
                    try backgroundContext.save()
                    LogManager.shared.log("📝 Saved optimistic message: \(messageId)", category: "SessionSync")

                    DispatchQueue.main.async {
                        completion(messageId)
                    }
                }
            } catch {
                LogManager.shared.log("Failed to save optimistic message: \(error.localizedDescription)", category: "SessionSync")
            }
        }
    }
    
    /// Reconcile an optimistic message with server confirmation
    /// - Parameters:
    ///   - sessionId: Session UUID
    ///   - role: Message role (should be "user" for optimistic messages)
    ///   - text: Message text to match
    ///   - serverTimestamp: Server-provided timestamp
    private func reconcileMessage(sessionId: UUID, role: String, text: String, serverTimestamp: Date?, in context: NSManagedObjectContext) {
        // Find optimistic message by session, role, and text
        let fetchRequest = CDMessage.fetchMessage(sessionId: sessionId, role: role, text: text)
        
        guard let message = try? context.fetch(fetchRequest).first else {
            LogManager.shared.log("No optimistic message found to reconcile (backend-originated message)", category: "SessionSync")
            return
        }
        
        // Update status and server timestamp
        message.messageStatus = .confirmed
        if let serverTimestamp = serverTimestamp {
            message.serverTimestamp = serverTimestamp
        }
        
        LogManager.shared.log("Reconciled optimistic message: \(message.id)", category: "SessionSync")
    }

    // MARK: - Ghost Prompt Reconciliation

    /// Pending ghost reconciliations: sessionId → queue of optimistic message ids
    /// awaiting their `ghost_prompt` (success) or error event. A ghost send
    /// registers its bubble's id here so the matching event reconciles THAT bubble
    /// rather than merely "the latest sending message" — which an interleaved
    /// *ordinary* send would otherwise displace. That ordinary-interleave case is
    /// the realistic one: ghost mode resets after each send, so a second
    /// concurrent ghost on the same session requires a deliberate re-toggle.
    ///
    /// Drained oldest-first. This is **exact** for the common case (at most one
    /// ghost in flight per session) and **best-effort** otherwise: two concurrent
    /// ghosts on the SAME session can have their `ghost_prompt` events emitted out
    /// of send order, because the backend generates each P on an independent
    /// fork/future with no per-session serialization (server.clj ghost dispatch),
    /// so the slower task's event can arrive second. The event carries no
    /// correlation id (only session_id + text), so the client cannot perfectly
    /// disambiguate that case — the worst outcome is the two effective prompts
    /// annotating each other's bubble (cosmetic, no data loss). A precise fix
    /// would require the protocol to echo a per-send correlation key.
    ///
    /// Main-thread access only: registered from `createOptimisticMessage`'s
    /// main-queue completion, drained from `VoiceCodeClient`'s main-queue handler.
    private var pendingGhostMessageIds: [UUID: [UUID]] = [:]

    /// Remember the optimistic bubble a ghost send just created so its later
    /// `ghost_prompt`/error event can target it precisely. Call on the main thread.
    func registerPendingGhost(sessionId: UUID, messageId: UUID) {
        pendingGhostMessageIds[sessionId, default: []].append(messageId)
    }

    /// Pop the oldest pending ghost bubble id for a session (oldest-first), or nil
    /// when none is registered (e.g. the in-memory registry was lost to an app
    /// restart between send and event). Call on the main thread.
    private func dequeuePendingGhost(sessionId: UUID) -> UUID? {
        guard var queue = pendingGhostMessageIds[sessionId], !queue.isEmpty else { return nil }
        let id = queue.removeFirst()
        if queue.isEmpty {
            pendingGhostMessageIds.removeValue(forKey: sessionId)
        } else {
            pendingGhostMessageIds[sessionId] = queue
        }
        return id
    }

    /// Display text for a reconciled ghost bubble. Keeps the user's task (when
    /// known) and appends the effective prompt P the agent actually acted on.
    /// Defensive guard: an already-annotated bubble (leading 👻) is returned
    /// unchanged so a re-annotation can't double-wrap it. (Whole-event
    /// idempotency on a re-delivered `ghost_prompt` is enforced separately in
    /// `reconcileGhostPrompt`.)
    static func ghostDisplayText(task: String?, effectivePrompt: String) -> String {
        let trimmedTask = (task ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedTask.hasPrefix("👻") { return trimmedTask }
        let trimmedPrompt = effectivePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedTask.isEmpty {
            return "👻 Effective prompt\n\(trimmedPrompt)"
        }
        return "👻 Ghost task: \(trimmedTask)\n\n— Effective prompt —\n\(trimmedPrompt)"
    }

    /// The optimistic bubble a ghost event should act on: the precise row the
    /// send registered (`targetId`, still `.sending`) when known, else the most
    /// recent still-`.sending` user row as a best-effort fallback (lost registry).
    private static func ghostBubble(targetId: UUID?, sessionId: UUID, in context: NSManagedObjectContext) -> CDMessage? {
        if let targetId = targetId {
            let req = CDMessage.fetchRequest()
            req.predicate = NSPredicate(format: "id == %@ AND sessionId == %@ AND status == %@",
                                        targetId as CVarArg, sessionId as CVarArg, MessageStatus.sending.rawValue)
            req.fetchLimit = 1
            if let hit = (try? context.fetch(req))?.first { return hit }
        }
        return try? context.fetch(CDMessage.fetchLatestSendingUserMessage(sessionId: sessionId)).first
    }

    /// True when some row in the session already carries `needle`. Used to make a
    /// re-delivered `ghost_prompt` idempotent: once P is present (whether annotated
    /// onto the task bubble or stand-alone), a duplicate fallback bubble is skipped.
    private static func sessionHasMessageContaining(_ needle: String, sessionId: UUID, in context: NSManagedObjectContext) -> Bool {
        let trimmed = needle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let req = CDMessage.fetchRequest()
        req.predicate = NSPredicate(format: "sessionId == %@ AND text CONTAINS %@", sessionId as CVarArg, trimmed)
        req.fetchLimit = 1
        return ((try? context.count(for: req)) ?? 0) > 0
    }

    /// Reconcile a ghost send: the optimistic bubble currently shows the *task X*
    /// the user typed, but the agent acts on the effective prompt *P* carried by
    /// the `ghost_prompt` event. Annotate the send's registered bubble in place
    /// with P and confirm it. If that row is gone (pruned/late/lost registry),
    /// create a confirmed bubble carrying P — the event is the only channel that
    /// delivers P to iOS, so it must never be dropped silently — unless P is
    /// already present (re-delivered event), which is a no-op for idempotency.
    /// See ghost-prompt design §3.3 / protocol §ghost.
    func reconcileGhostPrompt(sessionId: UUID, effectivePrompt: String) {
        let targetId = dequeuePendingGhost(sessionId: sessionId)
        let sessionIdStr = sessionId.uuidString.lowercased()
        persistenceController.performBackgroundTask { [weak self] context in
            guard self != nil else { return }

            if let optimistic = Self.ghostBubble(targetId: targetId, sessionId: sessionId, in: context) {
                optimistic.text = Self.ghostDisplayText(task: optimistic.text, effectivePrompt: effectivePrompt)
                optimistic.messageStatus = .confirmed
                optimistic.serverTimestamp = Date()
                optimistic.session?.preview = String(optimistic.text.prefix(100))
                LogManager.shared.log("👻 Reconciled ghost optimistic bubble for session \(sessionIdStr)", category: "SessionSync")
            } else {
                // No optimistic row to annotate. P must still surface — unless it
                // is already present (a re-delivered event), which we skip so the
                // reconcile stays idempotent.
                guard !Self.sessionHasMessageContaining(effectivePrompt, sessionId: sessionId, in: context) else {
                    LogManager.shared.log("👻 ghost_prompt P already present for session \(sessionIdStr); skipping duplicate", category: "SessionSync")
                    return
                }
                let fetch = CDBackendSession.fetchBackendSession(id: sessionId)
                guard let session = try? context.fetch(fetch).first else {
                    LogManager.shared.log("👻 ghost_prompt for unknown session \(sessionIdStr); dropping effective prompt", category: "SessionSync")
                    return
                }
                let messageId = UUID()
                let message = CDMessage(context: context)
                message.id = messageId
                message.sessionId = sessionId
                message.role = "user"
                message.text = Self.ghostDisplayText(task: nil, effectivePrompt: effectivePrompt)
                message.timestamp = Date()
                message.serverTimestamp = Date()
                message.messageStatus = .confirmed
                message.session = session
                // Negative sentinel seq/offset so the (sessionId, offset) upsert
                // path never matches this locally-minted row (mirrors the
                // optimistic-message convention).
                message.seq = Self.optimisticSeq(for: messageId)
                message.offset = Self.optimisticSeq(for: messageId)
                session.lastModified = Date()
                session.messageCount += 1
                session.preview = String(message.text.prefix(100))
                LogManager.shared.log("👻 Created fallback ghost bubble for session \(sessionIdStr)", category: "SessionSync")
            }

            do {
                if context.hasChanges { try context.save() }
            } catch {
                LogManager.shared.log("Failed to save ghost reconcile for \(sessionIdStr): \(error.localizedDescription)", category: "SessionSync")
            }
        }
    }

    /// Mark a ghost send as failed: the backend returned an error envelope and
    /// delivered nothing to the session, so the send's optimistic task-X bubble
    /// would otherwise sit "sending" forever. Flip the registered bubble to
    /// `.error` (falling back to the latest still-sending row if the registry was
    /// lost). No-op if the row is already gone. The error text itself is surfaced
    /// via `currentError`.
    func failGhostPrompt(sessionId: UUID) {
        let targetId = dequeuePendingGhost(sessionId: sessionId)
        let sessionIdStr = sessionId.uuidString.lowercased()
        persistenceController.performBackgroundTask { [weak self] context in
            guard self != nil else { return }
            guard let optimistic = Self.ghostBubble(targetId: targetId, sessionId: sessionId, in: context) else {
                LogManager.shared.log("👻 No optimistic ghost bubble to fail for session \(sessionIdStr)", category: "SessionSync")
                return
            }
            optimistic.messageStatus = .error
            do {
                if context.hasChanges { try context.save() }
            } catch {
                LogManager.shared.log("Failed to save ghost failure for \(sessionIdStr): \(error.localizedDescription)", category: "SessionSync")
            }
        }
    }

    // MARK: - Session Updated Handling
    
    /// Handle session_updated message from backend
    /// - Parameters:
    ///   - sessionId: Session UUID
    ///   - messages: Array of new message dictionaries
    func handleSessionUpdated(sessionId: String, messages: [[String: Any]]) {
        LogManager.shared.log("Received session_updated for: \(sessionId) with \(messages.count) messages", category: "SessionSync")

        persistenceController.performBackgroundTask { [weak self] backgroundContext in
            guard let self = self else { return }

            // Validate UUID format
            guard let sessionUUID = UUID(uuidString: sessionId) else {
                LogManager.shared.log("Invalid session ID format in handleSessionUpdated: \(sessionId)", category: "SessionSync")
                return
            }

            // Fetch or create the session
            let fetchRequest = CDBackendSession.fetchBackendSession(id: sessionUUID)

            let session: CDBackendSession
            if let existingSession = try? backgroundContext.fetch(fetchRequest).first {
                session = existingSession
            } else {
                // Session not in our list yet - create it from the update
                LogManager.shared.log("Creating new session from update: \(sessionId)", category: "SessionSync")
                session = CDBackendSession(context: backgroundContext)
                session.id = sessionUUID
                session.backendName = "" // Will be updated on next session_list
                session.workingDirectory = "" // Will be updated on next session_list
                session.unreadCount = 0
                session.isLocallyCreated = false
            }

            // Check if this session is currently active
            let isActiveSession = ActiveSessionManager.shared.isActive(sessionUUID)

            // Process each message - reconcile optimistic ones, create new ones
            var newMessageCount = 0
            var assistantMessagesToSpeak: [String] = []

            for messageData in messages {
                // Extract fields from raw .jsonl format
                guard let role = self.extractRole(from: messageData),
                      let text = self.extractText(from: messageData) else {
                    // Log details at debug level for diagnosing message format issues
                    let messageType = messageData["type"] as? String ?? "nil"
                    let hasMessage = messageData["message"] != nil
                    LogManager.shared.log("Skipping message - type: \(messageType), hasMessage: \(hasMessage)", category: "SessionSync")
                    continue
                }

                // Filter out internal Claude Code messages
                // - "summary" messages are error summaries and internal state
                // - "system" messages are local command notifications
                // - "queue-operation" messages are priority queue operations (no message content)
                if role == "summary" || role == "system" || role == "queue-operation" {
                    LogManager.shared.log("Filtering out internal message type: \(role)", category: "SessionSync")
                    continue
                }

                // Extract server timestamp
                let serverTimestamp = self.extractTimestamp(from: messageData)

                // Try to reconcile optimistic message first
                let fetchRequest = CDMessage.fetchMessage(sessionId: sessionUUID, role: role, text: text)

                LogManager.shared.log("🔍 Looking for optimistic message to reconcile: role=\(role) text_length=\(text.count) session=\(sessionId)", category: "SessionSync")

                let existingMessage = try? backgroundContext.fetch(fetchRequest).first

                if let existingMessage = existingMessage {
                    // Reconcile optimistic message
                    LogManager.shared.log("✅ Found optimistic message to reconcile: id=\(existingMessage.id) current_status=\(existingMessage.messageStatus.rawValue)", category: "SessionSync")
                    existingMessage.messageStatus = .confirmed
                    if let serverTimestamp = serverTimestamp {
                        existingMessage.serverTimestamp = serverTimestamp
                    }
                    // Update ID to match backend's UUID
                    if let backendId = self.extractMessageId(from: messageData) {
                        existingMessage.id = backendId
                    }
                    LogManager.shared.log("✅ Reconciled optimistic message to confirmed", category: "SessionSync")
                } else {
                    // Create new message (backend-originated or not found)
                    LogManager.shared.log("❌ No optimistic message found - creating new message: role=\(role) text_length=\(text.count)", category: "SessionSync")
                    self.createMessage(messageData, sessionId: sessionId, in: backgroundContext, session: session)
                    newMessageCount += 1

                    // Collect assistant messages for speaking (if active session)
                    if role == "assistant" {
                        assistantMessagesToSpeak.append(text)
                    }
                }
            }
            
            // Update session metadata (only count truly new messages)
            // Update lastModified to current time because these are NEW messages arriving now
            session.lastModified = Date()
            session.messageCount += Int32(newMessageCount)

            // Update unread count and speaking logic
            LogManager.shared.log("🔊 Session \(sessionId.prefix(8))... isActive=\(isActiveSession), assistantMessages=\(assistantMessagesToSpeak.count), newMsgCount=\(newMessageCount)", category: "SessionSync")
            if isActiveSession {
                // Active session: speak assistant messages, don't increment unread count
                LogManager.shared.log("Active session: will speak \(assistantMessagesToSpeak.count) assistant messages", category: "SessionSync")
            } else {
                // Background session: increment unread count, don't speak, post notification
                if newMessageCount > 0 {
                    session.unreadCount += Int32(newMessageCount)
                    LogManager.shared.log("Background session: incremented unread count to \(session.unreadCount)", category: "SessionSync")
                    
                    // Post notification for assistant messages when app is backgrounded
                    if !assistantMessagesToSpeak.isEmpty {
                        let sessionName = session.displayName(context: backgroundContext)
                        LogManager.shared.log("📬 Posting notification for \(assistantMessagesToSpeak.count) assistant messages", category: "SessionSync")

                        // Post notification on main thread
                        // Combine multiple messages into one notification
                        let combinedText = assistantMessagesToSpeak.joined(separator: "\n\n")
                        let workingDirectory = session.workingDirectory
                        DispatchQueue.main.async {
                            Task {
                                await NotificationManager.shared.postResponseNotification(
                                    text: combinedText,
                                    sessionName: sessionName,
                                    workingDirectory: workingDirectory
                                )
                            }
                        }
                    }
                }
            }

            // Update preview with last message text
            if let lastMessage = messages.last,
               let text = self.extractText(from: lastMessage) {
                session.preview = String(text.prefix(100))
            }

            // Enqueue only when this reply answers a prompt the user sent from
            // this device — see `PriorityQueueAdmission`. This path uses
            // session_updated (broadcast to all clients) instead of turn_complete
            // (channel-specific) for reliable delivery even after reconnection.
            // Check the policy and modify the session BEFORE saving so the
            // mutation batches into the same context commit.
            if PriorityQueueAdmission.shouldEnqueue(
                featureEnabled: UserDefaults.standard.bool(forKey: "priorityQueueEnabled"),
                hasLiveAssistantMessages: !assistantMessagesToSpeak.isEmpty,
                claimAwaitedReply: { self.pendingReplies.claim(sessionId: sessionId) }) {
                // Use the session object we already have in this background context
                if CDBackendSession.addToPriorityQueue(session, context: backgroundContext) {
                    LogManager.shared.log("📌 Enqueued session — reply to a prompt from this device: \(sessionId)", category: "SessionSync")
                } else {
                    self.pendingReplies.arm(sessionId: sessionId)
                    LogManager.shared.log("⚠️ Enqueue did not commit; re-arming for the next signal: \(sessionId)", category: "SessionSync")
                }
            }

            do {
                if backgroundContext.hasChanges {
                    try backgroundContext.save()
                    LogManager.shared.log("Updated session: \(sessionId)", category: "SessionSync")
                }

                // Post notification to trigger UI refresh (same pattern as handleSessionHistory)
                if newMessageCount > 0 {
                    DispatchQueue.main.async {
                        NotificationCenter.default.post(
                            name: .sessionHistoryDidUpdate,
                            object: nil,
                            userInfo: ["sessionId": sessionId]
                        )
                    }
                }

                // Prune old messages if threshold exceeded
                // This keeps CoreData footprint bounded during long conversations
                if CDMessage.needsPruning(sessionId: sessionUUID, in: backgroundContext) {
                    let deletedCount = CDMessage.pruneOldMessages(sessionId: sessionUUID, in: backgroundContext)
                    if deletedCount > 0 {
                        session.messageCount -= Int32(deletedCount)
                        try? backgroundContext.save()
                        LogManager.shared.log("🧹 Pruned \(deletedCount) old messages from session \(sessionId)", category: "SessionSync")
                    }
                }

                // Speak assistant messages on main thread (only for active session)
                // VoiceOutputManager automatically uses configured voice from AppSettings
                // Remove code blocks from text before speaking for better listening experience
                if isActiveSession && !assistantMessagesToSpeak.isEmpty {
                    let workingDirectory = session.workingDirectory
                    let voiceManager = self.voiceOutputManager  // Capture before dispatching to main queue
                    LogManager.shared.log("🔊 Preparing to speak \(assistantMessagesToSpeak.count) messages, voiceOutputManager is \(voiceManager == nil ? "nil" : "set")", category: "SessionSync")
                    DispatchQueue.main.async {
                        if let voiceManager = voiceManager {
                            for text in assistantMessagesToSpeak {
                                let processedText = TextProcessor.prepareForSpeech(from: text)
                                LogManager.shared.log("🔊 Calling speak() with text length: \(processedText.count)", category: "SessionSync")
                                voiceManager.speak(processedText, respectSilentMode: true, workingDirectory: workingDirectory, sessionId: sessionUUID)
                            }
                        } else {
                            LogManager.shared.log("⚠️ voiceOutputManager is nil, cannot speak messages", category: "SessionSync")
                        }
                    }
                }
            } catch {
                LogManager.shared.log("Failed to save session_updated: \(error.localizedDescription)", category: "SessionSync")
            }
        }
    }
    
    // MARK: - Private Helpers

    /// Extract text from canonical wire format
    /// - Parameter messageData: Canonical message from backend
    /// - Returns: Text content string, or nil if extraction fails
    internal func extractText(from messageData: [String: Any]) -> String? {
        return messageData["text"] as? String
    }

    /// Extract role from canonical wire format
    /// - Parameter messageData: Canonical message from backend
    /// - Returns: Role string ("user" or "assistant"), or nil if extraction fails
    internal func extractRole(from messageData: [String: Any]) -> String? {
        return messageData["role"] as? String
    }

    /// Extract timestamp from canonical wire format
    /// - Parameter messageData: Canonical message from backend
    /// - Returns: Date object, or nil if extraction fails
    internal func extractTimestamp(from messageData: [String: Any]) -> Date? {
        guard let timestampString = messageData["timestamp"] as? String else {
            return nil
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: timestampString)
    }

    /// Extract message UUID from canonical wire format
    /// - Parameter messageData: Canonical message from backend
    /// - Returns: UUID, or nil if extraction fails
    internal func extractMessageId(from messageData: [String: Any]) -> UUID? {
        guard let uuidString = messageData["uuid"] as? String else {
            return nil
        }
        return UUID(uuidString: uuidString)
    }

    /// Extract provider from canonical wire format
    /// - Parameter messageData: Canonical message from backend
    /// - Returns: Provider string ("claude", "copilot", "cursor", or "opencode"), or nil if extraction fails
    internal func extractProvider(from messageData: [String: Any]) -> String? {
        return messageData["provider"] as? String
    }

    /// Upsert (update or insert) a session in CoreData
    private func upsertSession(_ sessionData: [String: Any], in context: NSManagedObjectContext) {
        // Check if session_id is present
        guard let sessionIdString = sessionData["session_id"] as? String else {
            let sessionName = String(describing: sessionData["name"] ?? "unknown")
            let workingDir = String(describing: sessionData["working_directory"] ?? "unknown")
            LogManager.shared.log("Missing session_id in session data - name: \(sessionName), working_directory: \(workingDir)", category: "SessionSync")
            return
        }

        // Validate that session_id is a valid UUID
        guard let sessionId = UUID(uuidString: sessionIdString) else {
            let sessionName = String(describing: sessionData["name"] ?? "unknown")
            let workingDir = String(describing: sessionData["working_directory"] ?? "unknown")
            LogManager.shared.log("Invalid session_id format (not a UUID) - session_id: \(sessionIdString), name: \(sessionName), working_directory: \(workingDir)", category: "SessionSync")
            return
        }
        
        // Try to fetch existing session
        let fetchRequest = CDBackendSession.fetchBackendSession(id: sessionId)
        let existingSession = try? context.fetch(fetchRequest).first
        
        let session = existingSession ?? CDBackendSession(context: context)
        
        // Update fields
        session.id = sessionId
        
        if let name = sessionData["name"] as? String {
            session.backendName = name
        }
        
        if let workingDir = sessionData["working_directory"] as? String {
            session.workingDirectory = workingDir
        }
        
        if let lastModified = sessionData["last_modified"] as? TimeInterval {
            session.lastModified = Date(timeIntervalSince1970: lastModified / 1000.0) // Convert from milliseconds
        }
        
        if let messageCount = sessionData["message_count"] as? Int {
            session.messageCount = Int32(messageCount)
        }
        
        if let preview = sessionData["preview"] as? String {
            session.preview = preview
        }

        // Parse provider field (defaults to "claude" for backward compatibility)
        if let provider = sessionData["provider"] as? String {
            session.provider = provider
        } else if existingSession == nil {
            // Only set default for new sessions; don't override existing
            session.provider = "claude"
        }

        // Clear isLocallyCreated flag since session is now synced from backend
        session.isLocallyCreated = false

        // Don't override unread count for existing sessions
        if existingSession == nil {
            session.unreadCount = 0
        }
    }
    
    /// Create a message in CoreData
    private func createMessage(_ messageData: [String: Any], sessionId: String, in context: NSManagedObjectContext, session: CDBackendSession) {
        // Extract fields from raw .jsonl format
        guard let role = extractRole(from: messageData),
              let text = extractText(from: messageData) else {
            LogManager.shared.log("Invalid message data, missing role or text", category: "SessionSync")
            return
        }

        // Validate UUID format
        guard let sessionUUID = UUID(uuidString: sessionId) else {
            LogManager.shared.log("Invalid session ID format in createMessage: \(sessionId)", category: "SessionSync")
            return
        }

        let message = CDMessage(context: context)

        // Use backend's UUID if available, otherwise generate new one
        message.id = extractMessageId(from: messageData) ?? UUID()
        message.sessionId = sessionUUID
        message.role = role
        message.text = text
        message.messageStatus = .confirmed
        message.session = session

        // Extract and parse timestamp
        if let timestamp = extractTimestamp(from: messageData) {
            message.timestamp = timestamp
            message.serverTimestamp = timestamp
        } else {
            message.timestamp = Date()
        }
    }
    
    // MARK: - Name Update Handling

    /// Update a session's custom name (via CDUserSession)
    /// - Parameters:
    ///   - sessionId: Session UUID
    ///   - name: New name to set
    func updateSessionLocalName(sessionId: UUID, name: String) {
        LogManager.shared.log("Updating session custom name: \(sessionId.uuidString.lowercased()) -> \(name)", category: "SessionSync")

        persistenceController.performBackgroundTask { backgroundContext in
            // Fetch or create CDUserSession
            let fetchRequest = CDUserSession.fetchUserSession(id: sessionId)

            let userSession: CDUserSession
            if let existing = try? backgroundContext.fetch(fetchRequest).first {
                userSession = existing
            } else {
                userSession = CDUserSession(context: backgroundContext)
                userSession.id = sessionId
                userSession.createdAt = Date()
            }

            userSession.customName = name

            do {
                if backgroundContext.hasChanges {
                    try backgroundContext.save()
                    LogManager.shared.log("Updated session custom name: \(sessionId.uuidString.lowercased())", category: "SessionSync")
                }
            } catch {
                LogManager.shared.log("Failed to update session custom name: \(error.localizedDescription)", category: "SessionSync")
            }
        }
    }
}
