// SessionSyncManager.swift
// Manages session metadata synchronization with backend

import Foundation
import CoreData
import os.log

private let logger = Logger(subsystem: "com.travisbrown.VoiceCode", category: "SessionSync")

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
}

extension SessionSyncDelegate {
    /// Default no-op so existing conformers (VoiceCodeClient shipped before
    /// tmux-untethered-fh3) compile without modification. Real implementers
    /// route `fromSeq` into a `subscribe` message on the socket.
    func sessionSyncNeedsResubscribe(_ sessionId: String, fromSeq: Int64) {}
}

/// Manages synchronization of session metadata between backend and CoreData
class SessionSyncManager {
    private let persistenceController: PersistenceController
    private let context: NSManagedObjectContext
    private weak var voiceOutputManager: VoiceOutputManager?

    /// UI-layer sink for pruned-gap and similar events. See `SessionSyncDelegate`.
    weak var delegate: SessionSyncDelegate?

    init(persistenceController: PersistenceController = .shared, voiceOutputManager: VoiceOutputManager? = nil) {
        self.persistenceController = persistenceController
        self.context = persistenceController.container.viewContext
        self.voiceOutputManager = voiceOutputManager
    }
    
    // MARK: - Session List Handling
    
    /// Handle session_list message from backend
    /// - Parameter sessions: Array of session metadata dictionaries
    func handleSessionList(_ sessions: [[String: Any]]) async {
        logger.info("📥 Received session_list with \(sessions.count) sessions")

        // Log all received sessions with their details
        logger.info("📋 Sessions received from backend:")
        for (index, sessionData) in sessions.enumerated() {
            let sessionId = sessionData["session_id"] as? String ?? "unknown"
            let name = sessionData["name"] as? String ?? "unknown"
            let workingDir = sessionData["working_directory"] as? String ?? "unknown"
            let messageCount = sessionData["message_count"] as? Int ?? 0
            logger.info("  [\(index + 1)] \(sessionId) | \(messageCount) msgs | \(name) | \(workingDir)")
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
                        logger.info("✅ Saved \(sessions.count) sessions to CoreData")

                        // Notify observers that session list was updated
                        DispatchQueue.main.async {
                            NotificationCenter.default.post(name: .sessionListDidUpdate, object: nil)
                        }
                    }
                } catch {
                    logger.error("❌ Failed to save session_list: \(error.localizedDescription)")
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

        logger.info("📨 session_created received: \(sessionId)")
        logger.info("  Name: \(name)")
        logger.info("  Working dir: \(workingDir)")
        logger.info("  Message count: \(messageCount)")
        logger.info("  Has preview: \(hasPreview)")

        guard sessionData["session_id"] as? String != nil else {
            logger.warning("⚠️ session_created missing session_id, dropping")
            return
        }

        // Backend guarantees all notified sessions have messages via delayed notification pattern
        // Just log for observability if we receive a 0-message session
        if messageCount == 0 {
            logger.info("📝 Note: Received session with 0 messages (may update soon): \(sessionId)")
        }

        logger.info("✅ Accepting session_created for: \(sessionId)")

        persistenceController.performBackgroundTask { [weak self] backgroundContext in
            guard let self = self else { return }

            self.upsertSession(sessionData, in: backgroundContext)

            do {
                if backgroundContext.hasChanges {
                    try backgroundContext.save()
                    logger.info("Created session: \(sessionId)")

                    // Call completion on main thread after successful save
                    if let completion = completion {
                        DispatchQueue.main.async {
                            completion(sessionId)
                        }
                    }
                }
            } catch {
                logger.error("Failed to save session_created: \(error.localizedDescription)")
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
        logger.info("⏱️ handleSessionHistory START - \(sessionId.prefix(8))... with \(messages.count) messages")

        // Early return if no messages - delta sync with no new messages
        // Don't touch existing messages
        if messages.isEmpty {
            logger.info("⏱️ handleSessionHistory COMPLETE - no new messages (delta sync up to date)")
            return
        }

        persistenceController.performBackgroundTask { [weak self] backgroundContext in
            guard let self = self else { return }

            // Validate UUID format
            guard let sessionUUID = UUID(uuidString: sessionId) else {
                logger.error("Invalid session ID format in handleSessionHistory: \(sessionId)")
                return
            }

            // Fetch the session
            let fetchStart = Date()
            let fetchRequest = CDBackendSession.fetchBackendSession(id: sessionUUID)

            guard let session = try? backgroundContext.fetch(fetchRequest).first else {
                logger.warning("Session not found for history: \(sessionId)")
                return
            }
            logger.info("⏱️ +\(Int(Date().timeIntervalSince(fetchStart) * 1000))ms - fetched session")

            // Get existing message IDs to avoid duplicates
            let existingIds: Set<UUID>
            if let existingMessages = session.messages?.allObjects as? [CDMessage] {
                existingIds = Set(existingMessages.map { $0.id })
                logger.info("⏱️ Found \(existingIds.count) existing messages")
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
            logger.info("⏱️ +\(Int(Date().timeIntervalSince(createStart) * 1000))ms - added \(addedCount) new messages (skipped \(messages.count - addedCount) duplicates)")

            // Prune old messages to prevent unbounded growth in long-running sessions
            // This keeps only the newest N messages (iOS only needs recent history; backend retains full)
            let pruneStart = Date()
            let prunedCount = CDMessage.pruneOldMessages(sessionId: sessionUUID, in: backgroundContext)
            if prunedCount > 0 {
                logger.info("⏱️ +\(Int(Date().timeIntervalSince(pruneStart) * 1000))ms - pruned \(prunedCount) old messages")
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
                    logger.info("⏱️ +\(Int(Date().timeIntervalSince(saveStart) * 1000))ms - saved to CoreData")
                    logger.info("⏱️ handleSessionHistory COMPLETE - total: \(Int(Date().timeIntervalSince(historyStart) * 1000))ms, \(addedCount) new messages, \(prunedCount) pruned")

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
                    logger.info("⏱️ handleSessionHistory COMPLETE - no changes to save")
                }
            } catch {
                logger.error("Failed to save session_history: \(error.localizedDescription)")
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
        // Pruned gap: surface to delegate and stop. Merging anything under a
        // pruned reply would silently partial-view the user's history.
        if let gap = payload.gap, gap.reason == "pruned" {
            logger.warning("⚠️ Pruned gap for \(payload.sessionId): requested_last_seq=\(gap.requestedLastSeq), min_available_seq=\(gap.minAvailableSeq)")
            let sessionId = payload.sessionId
            DispatchQueue.main.async { [weak self] in
                self?.delegate?.didDetectPrunedGap(sessionId, gap: gap)
            }
            return
        }

        guard let sessionUUID = UUID(uuidString: payload.sessionId) else {
            logger.error("Invalid session ID format in handleSessionHistoryPayload: \(payload.sessionId)")
            return
        }

        persistenceController.performBackgroundTask { [weak self] backgroundContext in
            guard let self = self else { return }

            // Snapshot the current contiguous cursor BEFORE mutating — we
            // need the pre-upsert value to emit a correct backfill request.
            let localLastSeq = self.maxCachedSeq(sessionId: sessionUUID, in: backgroundContext)

            // 3-case gap decision. Empty windows (no first_seq) never trip a gap.
            let gapDetected: Bool
            if let firstSeq = payload.firstSeq, firstSeq > localLastSeq + 1 {
                logger.warning("📭 Gap for \(payload.sessionId): local_last_seq=\(localLastSeq), first_seq=\(firstSeq); backfilling from \(localLastSeq)")
                gapDetected = true
            } else {
                gapDetected = false
            }

            let session = self.fetchOrCreateSession(id: sessionUUID, in: backgroundContext)
            let isActiveSession = ActiveSessionManager.shared.isActive(sessionUUID)

            // Idempotent upsert on (sessionId, seq). Safe under double
            // delivery (push+history overlap, gap-backfill crossing).
            // Collect assistant message text from newly-inserted rows so we
            // can fire auto-speak / notifications / priority-queue post-save.
            var newRows = 0
            var newAssistantTexts: [String] = []
            for wireMessage in payload.messages {
                let inserted = self.upsertMessage(wireMessage, session: session, in: backgroundContext)
                if inserted {
                    newRows += 1
                    if wireMessage.role == "assistant" {
                        newAssistantTexts.append(wireMessage.text)
                    }
                }
            }

            // Preview reflects the newest message the client has actually
            // seen, which is the last element in the ascending payload.
            if let lastMessage = payload.messages.last {
                session.preview = String(lastMessage.text.prefix(100))
            }

            // Background sessions track unread count so the sidebar badge can
            // flag inbound activity the user hasn't seen. Active sessions do
            // not — the user is already looking at them.
            if !isActiveSession && newRows > 0 {
                session.unreadCount += Int32(newRows)
            }

            // Auto-add to priority queue when an assistant response lands on a
            // session the user has opted into. Read the flag before save so
            // the relationship mutation batches into the same context commit.
            if !newAssistantTexts.isEmpty
                && UserDefaults.standard.bool(forKey: "priorityQueueEnabled") {
                CDBackendSession.addToPriorityQueue(session, context: backgroundContext)
                logger.info("📌 Auto-added session to priority queue after assistant response: \(payload.sessionId)")
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
                }
            } catch {
                let nsError = error as NSError
                logger.error("Failed to save session_history payload: domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public) userInfo=\(nsError.userInfo, privacy: .public)")
                // Don't stay stuck: ask the client to resubscribe from the
                // pre-payload cursor so the next push attempts a fresh save
                // instead of permanently leaving local_last_seq stale.
                let sessionId = payload.sessionId
                DispatchQueue.main.async { [weak self] in
                    self?.delegate?.sessionSyncNeedsResubscribe(sessionId, fromSeq: localLastSeq)
                }
                return
            }

            // Prune old messages to keep CoreData footprint bounded during
            // long conversations. Only runs past the retention threshold.
            if newRows > 0 && CDMessage.needsPruning(sessionId: sessionUUID, in: backgroundContext) {
                let deletedCount = CDMessage.pruneOldMessages(sessionId: sessionUUID, in: backgroundContext)
                if deletedCount > 0 {
                    try? backgroundContext.save()
                    logger.info("🧹 Pruned \(deletedCount) old messages from session \(payload.sessionId)")
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
                            voiceManager.speak(processedText, respectSilentMode: true, workingDirectory: workingDirectory)
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
            let sessionId = payload.sessionId
            if gapDetected {
                DispatchQueue.main.async { [weak self] in
                    self?.delegate?.sessionSyncNeedsResubscribe(sessionId, fromSeq: localLastSeq)
                }
            } else if !payload.isComplete {
                // Prefer the payload's reported last_seq; fall back to the
                // cached cursor if the payload was empty (shouldn't happen
                // with is_complete == false, but be defensive).
                let nextCursor = payload.lastSeq ?? localLastSeq
                DispatchQueue.main.async { [weak self] in
                    self?.delegate?.sessionSyncNeedsResubscribe(sessionId, fromSeq: nextCursor)
                }
            }
        }
    }

    // MARK: - Session History Payload helpers

    /// Returns the largest `seq` stored for this session, or 0 if none.
    /// Used as the client's `local_last_seq` cursor for gap detection.
    internal func maxCachedSeq(sessionId: UUID, in context: NSManagedObjectContext) -> Int64 {
        let request = CDMessage.fetchRequest()
        request.predicate = NSPredicate(format: "sessionId == %@", sessionId as CVarArg)
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
        logger.info("Creating new session from history payload: \(sessionUUID.uuidString.lowercased())")
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
            logger.warning("Invalid wire session ID in upsert: \(wireMessage.sessionId)")
            return false
        }

        // Consistency guard: the wire message's session_id must match the
        // envelope-level session we're merging into. Drop any mismatched rows
        // so the scalar `sessionId` and the `session` relationship never
        // disagree. Backend should never emit this, but trust-but-verify.
        guard wireSessionUUID == session.id else {
            logger.error("Wire message session \(wireMessage.sessionId) does not match payload session \(session.id.uuidString.lowercased()); dropping")
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
    
    /// Create an optimistic message immediately when user sends a prompt
    /// - Parameters:
    ///   - sessionId: Session UUID
    ///   - text: User's prompt text
    ///   - completion: Called on main thread with the created message ID
    func createOptimisticMessage(sessionId: UUID, text: String, completion: @escaping (UUID) -> Void) {
        logger.info("Creating optimistic message for session: \(sessionId.uuidString.lowercased())")

        let messageId = UUID()

        persistenceController.performBackgroundTask { [weak self] backgroundContext in
            guard let self = self else { return }

            // Fetch the session
            let fetchRequest = CDBackendSession.fetchBackendSession(id: sessionId)

            guard let session = try? backgroundContext.fetch(fetchRequest).first else {
                logger.warning("Session not found for optimistic message: \(sessionId.uuidString.lowercased())")
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
            
            logger.info("📝 Optimistic message prepared: id=\(messageId) sessionId=\(sessionId.uuidString.lowercased()) role=user text_length=\(text.count) status=sending")
            
            // Update session metadata optimistically
            session.lastModified = Date()
            session.messageCount += 1
            session.preview = String(text.prefix(100))
            
            do {
                if backgroundContext.hasChanges {
                    try backgroundContext.save()
                    logger.info("📝 Saved optimistic message: \(messageId)")
                    
                    DispatchQueue.main.async {
                        completion(messageId)
                    }
                }
            } catch {
                logger.error("Failed to save optimistic message: \(error.localizedDescription)")
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
            logger.info("No optimistic message found to reconcile (backend-originated message)")
            return
        }
        
        // Update status and server timestamp
        message.messageStatus = .confirmed
        if let serverTimestamp = serverTimestamp {
            message.serverTimestamp = serverTimestamp
        }
        
        logger.info("Reconciled optimistic message: \(message.id)")
    }
    
    // MARK: - Session Updated Handling
    
    /// Handle session_updated message from backend
    /// - Parameters:
    ///   - sessionId: Session UUID
    ///   - messages: Array of new message dictionaries
    func handleSessionUpdated(sessionId: String, messages: [[String: Any]]) {
        logger.info("Received session_updated for: \(sessionId) with \(messages.count) messages")

        persistenceController.performBackgroundTask { [weak self] backgroundContext in
            guard let self = self else { return }

            // Validate UUID format
            guard let sessionUUID = UUID(uuidString: sessionId) else {
                logger.error("Invalid session ID format in handleSessionUpdated: \(sessionId)")
                return
            }

            // Fetch or create the session
            let fetchRequest = CDBackendSession.fetchBackendSession(id: sessionUUID)

            let session: CDBackendSession
            if let existingSession = try? backgroundContext.fetch(fetchRequest).first {
                session = existingSession
            } else {
                // Session not in our list yet - create it from the update
                logger.info("Creating new session from update: \(sessionId)")
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
                    logger.debug("Skipping message - type: \(messageType, privacy: .public), hasMessage: \(hasMessage, privacy: .public)")
                    continue
                }

                // Filter out internal Claude Code messages
                // - "summary" messages are error summaries and internal state
                // - "system" messages are local command notifications
                // - "queue-operation" messages are priority queue operations (no message content)
                if role == "summary" || role == "system" || role == "queue-operation" {
                    logger.debug("Filtering out internal message type: \(role, privacy: .public)")
                    continue
                }

                // Extract server timestamp
                let serverTimestamp = self.extractTimestamp(from: messageData)

                // Try to reconcile optimistic message first
                let fetchRequest = CDMessage.fetchMessage(sessionId: sessionUUID, role: role, text: text)

                logger.info("🔍 Looking for optimistic message to reconcile: role=\(role) text_length=\(text.count) session=\(sessionId)")

                let existingMessage = try? backgroundContext.fetch(fetchRequest).first

                if let existingMessage = existingMessage {
                    // Reconcile optimistic message
                    logger.info("✅ Found optimistic message to reconcile: id=\(existingMessage.id) current_status=\(existingMessage.messageStatus.rawValue)")
                    existingMessage.messageStatus = .confirmed
                    if let serverTimestamp = serverTimestamp {
                        existingMessage.serverTimestamp = serverTimestamp
                    }
                    // Update ID to match backend's UUID
                    if let backendId = self.extractMessageId(from: messageData) {
                        existingMessage.id = backendId
                    }
                    logger.info("✅ Reconciled optimistic message to confirmed")
                } else {
                    // Create new message (backend-originated or not found)
                    logger.info("❌ No optimistic message found - creating new message: role=\(role) text_length=\(text.count)")
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
            logger.info("🔊 Session \(sessionId.prefix(8))... isActive=\(isActiveSession), assistantMessages=\(assistantMessagesToSpeak.count), newMsgCount=\(newMessageCount)")
            if isActiveSession {
                // Active session: speak assistant messages, don't increment unread count
                logger.info("Active session: will speak \(assistantMessagesToSpeak.count) assistant messages")
            } else {
                // Background session: increment unread count, don't speak, post notification
                if newMessageCount > 0 {
                    session.unreadCount += Int32(newMessageCount)
                    logger.info("Background session: incremented unread count to \(session.unreadCount)")
                    
                    // Post notification for assistant messages when app is backgrounded
                    if !assistantMessagesToSpeak.isEmpty {
                        let sessionName = session.displayName(context: backgroundContext)
                        logger.info("📬 Posting notification for \(assistantMessagesToSpeak.count) assistant messages")

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

            // Auto-add to priority queue if enabled and we received assistant messages
            // This uses session_updated (broadcast to all clients) instead of turn_complete
            // (channel-specific) for reliable delivery even after reconnection
            // Note: Check setting and modify session BEFORE saving to batch the changes
            if !assistantMessagesToSpeak.isEmpty {
                // Read priorityQueueEnabled from UserDefaults (thread-safe for reads)
                let priorityQueueEnabled = UserDefaults.standard.bool(forKey: "priorityQueueEnabled")
                if priorityQueueEnabled {
                    // Use the session object we already have in this background context
                    CDBackendSession.addToPriorityQueue(session, context: backgroundContext)
                    logger.info("📌 Auto-added session to priority queue after assistant response: \(sessionId)")
                }
            }

            do {
                if backgroundContext.hasChanges {
                    try backgroundContext.save()
                    logger.info("Updated session: \(sessionId)")
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
                        try? backgroundContext.save()
                        logger.info("🧹 Pruned \(deletedCount) old messages from session \(sessionId)")
                    }
                }

                // Speak assistant messages on main thread (only for active session)
                // VoiceOutputManager automatically uses configured voice from AppSettings
                // Remove code blocks from text before speaking for better listening experience
                if isActiveSession && !assistantMessagesToSpeak.isEmpty {
                    let workingDirectory = session.workingDirectory
                    let voiceManager = self.voiceOutputManager  // Capture before dispatching to main queue
                    logger.info("🔊 Preparing to speak \(assistantMessagesToSpeak.count) messages, voiceOutputManager is \(voiceManager == nil ? "nil" : "set")")
                    DispatchQueue.main.async {
                        if let voiceManager = voiceManager {
                            for text in assistantMessagesToSpeak {
                                let processedText = TextProcessor.prepareForSpeech(from: text)
                                logger.info("🔊 Calling speak() with text length: \(processedText.count)")
                                voiceManager.speak(processedText, respectSilentMode: true, workingDirectory: workingDirectory)
                            }
                        } else {
                            logger.warning("⚠️ voiceOutputManager is nil, cannot speak messages")
                        }
                    }
                }
            } catch {
                logger.error("Failed to save session_updated: \(error.localizedDescription)")
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
            logger.warning("Missing session_id in session data - name: \(sessionName, privacy: .public), working_directory: \(workingDir, privacy: .public)")
            return
        }

        // Validate that session_id is a valid UUID
        guard let sessionId = UUID(uuidString: sessionIdString) else {
            let sessionName = String(describing: sessionData["name"] ?? "unknown")
            let workingDir = String(describing: sessionData["working_directory"] ?? "unknown")
            logger.warning("Invalid session_id format (not a UUID) - session_id: \(sessionIdString, privacy: .public), name: \(sessionName, privacy: .public), working_directory: \(workingDir, privacy: .public)")
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
            logger.warning("Invalid message data, missing role or text")
            return
        }

        // Validate UUID format
        guard let sessionUUID = UUID(uuidString: sessionId) else {
            logger.error("Invalid session ID format in createMessage: \(sessionId)")
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
        logger.info("Updating session custom name: \(sessionId.uuidString.lowercased()) -> \(name)")

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
                    logger.info("Updated session custom name: \(sessionId.uuidString.lowercased())")
                }
            } catch {
                logger.error("Failed to update session custom name: \(error.localizedDescription)")
            }
        }
    }
}
