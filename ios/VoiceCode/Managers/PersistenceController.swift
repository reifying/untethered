// PersistenceController.swift
// CoreData persistence stack management

import CoreData
import os.log

private let logger = Logger(subsystem: "dev.910labs.voice-code", category: "Persistence")

class PersistenceController {
    static let shared = PersistenceController()

    /// Shared managed object model to prevent multiple entity description conflicts during tests.
    /// CoreData requires a single NSManagedObjectModel instance per entity class. When multiple
    /// containers load different model instances, the @objc(EntityName) class mappings conflict,
    /// causing "+[Entity entity] Failed to find a unique match" errors.
    private static let sharedModel: NSManagedObjectModel = {
        // Use Bundle(for:) to find the model in the correct bundle, which works in both
        // the app context and test host context
        let bundle = Bundle(for: PersistenceController.self)
        guard let modelURL = bundle.url(forResource: "VoiceCode", withExtension: "momd") else {
            fatalError("Failed to find VoiceCode.momd in bundle \(bundle.bundlePath)")
        }
        guard let model = NSManagedObjectModel(contentsOf: modelURL) else {
            fatalError("Failed to load CoreData model from \(modelURL)")
        }
        return model
    }()

    /// Preview instance for SwiftUI previews
    static var preview: PersistenceController = {
        let controller = PersistenceController(inMemory: true)
        let viewContext = controller.container.viewContext

        // Create sample data for previews
        let session = CDBackendSession(context: viewContext)
        session.id = UUID()
        session.backendName = "Terminal: voice-code - 2025-10-17 14:30"
        session.workingDirectory = "~/projects/voice-code"
        session.lastModified = Date()
        session.messageCount = 2
        session.preview = "Hello! How can I help you?"

        let message1 = CDMessage(context: viewContext)
        message1.id = UUID()
        message1.sessionId = session.id
        message1.role = "user"
        message1.text = "Hello!"
        message1.timestamp = Date().addingTimeInterval(-60)
        message1.messageStatus = .confirmed
        message1.session = session

        let message2 = CDMessage(context: viewContext)
        message2.id = UUID()
        message2.sessionId = session.id
        message2.role = "assistant"
        message2.text = "Hello! How can I help you?"
        message2.timestamp = Date()
        message2.messageStatus = .confirmed
        message2.session = session

        do {
            try viewContext.save()
        } catch {
            logger.error("Preview data creation failed: \(error.localizedDescription)")
        }

        return controller
    }()

    let container: NSPersistentContainer

    init(inMemory: Bool = false) {
        // Use shared model to prevent multiple entity description conflicts
        container = NSPersistentContainer(name: "VoiceCode", managedObjectModel: Self.sharedModel)

        if inMemory {
            container.persistentStoreDescriptions.first?.url = URL(fileURLWithPath: "/dev/null")
        } else {
            // Enable automatic lightweight migration
            let description = container.persistentStoreDescriptions.first
            description?.shouldInferMappingModelAutomatically = true
            description?.shouldMigrateStoreAutomatically = true
        }

        container.loadPersistentStores { description, error in
            if let error = error {
                logger.error("CoreData failed to load: \(error.localizedDescription)")

                // Attempt recovery by deleting and recreating the store
                if let storeURL = self.container.persistentStoreDescriptions.first?.url {
                    logger.warning("Attempting to recover by deleting corrupt store...")

                    do {
                        try FileManager.default.removeItem(at: storeURL)
                        logger.info("Deleted corrupt store, reloading...")

                        // Attempt to reload after deletion
                        self.container.loadPersistentStores { recoveryDescription, recoveryError in
                            if let recoveryError = recoveryError {
                                logger.error("Recovery failed: \(recoveryError.localizedDescription)")
                                // Cannot recover - show error to user but don't crash
                                DispatchQueue.main.async {
                                    // Note: @Published doesn't work on struct, but leaving for reference
                                    // In practice, app will function with in-memory store
                                }
                            } else {
                                logger.info("Store recovered successfully: \(recoveryDescription.url?.path ?? "unknown")")
                            }
                        }
                    } catch {
                        logger.error("Failed to delete corrupt store: \(error.localizedDescription)")
                        // Continue with in-memory store as fallback
                    }
                } else {
                    logger.error("No store URL found for recovery")
                }
            } else {
                logger.info("CoreData store loaded: \(description.url?.path ?? "unknown")")
            }
        }

        // Enable automatic merging of changes from parent context
        container.viewContext.automaticallyMergesChangesFromParent = true

        // Set merge policy to prefer property-level changes
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy

        // Reset CDBackendSession.liveFromSeq + liveFromOffset across all
        // sessions on app launch. Both are TTS gate cursors — anything below
        // is treated as historical (do not speak). Persisted only so they
        // survive the is_complete:false / paginated subscribe chain within a
        // single app session; they must not leak across app launches or the
        // first subscribe reply after relaunch would misclassify messages as
        // live and read aloud hours-old transcripts.
        //
        // The `liveFromOffset = 0` reset is also load-bearing for the v6→v7
        // migration: the migration seeds `liveFromOffset = max(0, liveFromSeq
        // - 1)` so the field is non-negative on every row, but the value
        // would otherwise re-anchor the TTS boundary at a stale historical
        // point. The reset overwrites it back to 0 before the first v0.5.0
        // reply lands; `handleSessionHistoryPayload`'s `payload.nextOffset > 0`
        // gate then re-captures the boundary from the first non-empty reply.
        // See tmux-untethered-i2n (liveFromSeq) and §6 R1 (liveFromOffset).
        if !inMemory {
            // Chain reset → backfill so the backfill's fetch sees the
            // post-reset store (liveFromSeq=0, liveFromOffset=0). Running
            // them concurrently raced: backfill could fetch liveFromSeq=5
            // before the reset committed, then write a stale liveFromOffset
            // that survives until the first session_history reply.
            resetTTSGateCursorsOnAllSessions { [weak self] in
                self?.backfillV6ToV7OffsetsIfNeeded()
            }
        }
    }

    private func resetTTSGateCursorsOnAllSessions(then continuation: (() -> Void)? = nil) {
        let context = container.newBackgroundContext()
        context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        context.perform {
            // NSBatchUpdateRequest skips the in-memory object graph and goes
            // straight to the store — much cheaper than fetching every row
            // when the user has hundreds of sessions.
            let batchUpdate = NSBatchUpdateRequest(entityName: "CDBackendSession")
            batchUpdate.propertiesToUpdate = [
                "liveFromSeq": Int64(0),
                "liveFromOffset": Int64(0)
            ]
            batchUpdate.resultType = .updatedObjectsCountResultType
            do {
                let result = try context.execute(batchUpdate) as? NSBatchUpdateResult
                if let count = result?.result as? Int, count > 0 {
                    logger.info("Reset TTS gate cursors (liveFromSeq, liveFromOffset) on \(count) sessions for fresh app launch")
                }
            } catch {
                // Non-fatal: TTS gate falls back to "suppress all" behavior
                // until each session captures the cursors from its first
                // post-launch reply, which is correct (just slightly more
                // aggressive than intended).
                logger.error("Failed to reset TTS gate cursors: \(error.localizedDescription)")
            }
            // Run continuation inside the same perform block so it observes
            // the batch update's effects on the store. Fires on the catch
            // path too: in practice a store corrupt enough to fail this
            // single-statement batch update will also fail the backfill's
            // fetch, and we'd rather attempt `lastOffsetMerged` seeding (to
            // avoid a full-history refetch next launch) than skip it. The
            // worst-case "reset fails, backfill succeeds" path leaves
            // `liveFromOffset` non-zero until the first reply re-captures
            // it — which is acceptable per the catch-block contract above.
            continuation?()
        }

        // CRITICAL: Ensure all CoreData merge notifications arrive on main queue
        // This prevents SwiftUI @FetchRequest updates from occurring on background threads
        // which would cause AttributeGraph crashes during rapid UI updates (typing/voice input)

        // Configure observer to merge background context saves on main thread
        // Using performAndWait to ensure synchronous merge - prevents race conditions
        // where @FetchRequest misses updates due to async scheduling delays
        NotificationCenter.default.addObserver(
            forName: .NSManagedObjectContextDidSave,
            object: nil,
            queue: .main
        ) { [weak container] notification in
            guard let container = container,
                  let context = notification.object as? NSManagedObjectContext,
                  context != container.viewContext,
                  context.persistentStoreCoordinator == container.viewContext.persistentStoreCoordinator else {
                return
            }

            // Merge changes synchronously on main thread
            // performAndWait is safe here since we're already on main queue and viewContext
            // uses main queue concurrency type - this ensures @FetchRequest sees updates immediately
            container.viewContext.performAndWait {
                container.viewContext.mergeChanges(fromContextDidSave: notification)
            }
        }
    }

    /// UserDefaults key marking the one-shot v6→v7 backfill as complete.
    /// Once set, the backfill never runs again — the v0.5.0 dispatch path
    /// owns `lastOffsetMerged`/`offset` from that point forward.
    static let v6ToV7BackfillCompleteKey = "VoiceCode.v6ToV7BackfillComplete"

    /// One-shot backfill that seeds the v0.5.0 offset fields from the v0.4.0
    /// seq fields. Lightweight migration adds the new columns with defaults
    /// (0/nil); without this backfill, every migrated session would subscribe
    /// `from_offset=0` and refetch full history (§6 R1).
    ///
    /// Mapping (§6 R1):
    ///   `CDBackendSession.lastOffsetMerged = max(0, nextSeq - 1)`
    ///   `CDBackendSession.liveFromOffset   = max(0, liveFromSeq - 1)`
    ///   `CDMessage.offset                  = max(0, seq - 1)`
    ///
    /// The `max(0, …)` clamp matters: `nextSeq == 0` means "never received a
    /// reply" (CoreData zero-init), and a bare `nextSeq - 1` would write -1
    /// which is illegal under v0.5.0 (offsets are non-negative). Clamping
    /// maps "never received" → "fresh subscribe from start" → server reads
    /// from offset 0, which is what we want.
    ///
    /// Gated by a UserDefaults sentinel so it runs exactly once per install.
    /// Idempotency-by-flag (rather than by value) protects against the
    /// edge case where v0.5.0 deliberately writes `lastOffsetMerged = 0` on
    /// a `file_replaced` recovery while `nextSeq > 0` lingers from before —
    /// a value-based guard would clobber the legitimate `0`.
    func backfillV6ToV7OffsetsIfNeeded(userDefaults: UserDefaults = .standard) {
        guard !userDefaults.bool(forKey: Self.v6ToV7BackfillCompleteKey) else {
            return
        }
        let context = container.newBackgroundContext()
        context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        context.perform {
            do {
                let (sessions, messages) = try Self.backfillV6ToV7Offsets(in: context)
                if context.hasChanges {
                    try context.save()
                }
                userDefaults.set(true, forKey: Self.v6ToV7BackfillCompleteKey)
                logger.info("v6→v7 backfill complete: updated \(sessions) sessions and \(messages) messages")
            } catch {
                // Leave the sentinel unset so the backfill retries next launch
                // — better an extra pass than a permanently-zero cursor that
                // would refetch every session's full history. Covers both
                // fetch failures (would otherwise silently mark complete) and
                // save failures.
                logger.error("v6→v7 backfill failed (will retry next launch): \(error.localizedDescription)")
            }
        }
    }

    /// Pure per-context backfill: maps `nextSeq → lastOffsetMerged`,
    /// `liveFromSeq → liveFromOffset`, `seq → offset` using the
    /// `max(0, oldField - 1)` rule. Static so tests can drive it against any
    /// context without spinning up a controller. Returns counts of rows
    /// updated for logging. Throws on fetch failure so the caller can leave
    /// the sentinel unset and retry next launch.
    @discardableResult
    static func backfillV6ToV7Offsets(in context: NSManagedObjectContext) throws -> (sessions: Int, messages: Int) {
        var updatedSessions = 0
        let sessionRequest = NSFetchRequest<CDBackendSession>(entityName: "CDBackendSession")
        let sessions = try context.fetch(sessionRequest)
        for session in sessions {
            var changed = false
            if session.lastOffsetMerged == 0 && session.nextSeq > 0 {
                session.lastOffsetMerged = max(0, session.nextSeq - 1)
                changed = true
            }
            if session.liveFromOffset == 0 && session.liveFromSeq > 0 {
                session.liveFromOffset = max(0, session.liveFromSeq - 1)
                changed = true
            }
            if changed { updatedSessions += 1 }
        }

        let messageRequest = NSFetchRequest<CDMessage>(entityName: "CDMessage")
        // Only the rows that actually need updating — saves a write on every
        // pre-seq legacy row that has seq=0 already.
        messageRequest.predicate = NSPredicate(format: "offset == 0 AND seq > 0")
        let messages = try context.fetch(messageRequest)
        for message in messages {
            message.offset = max(0, message.seq - 1)
        }
        return (updatedSessions, messages.count)
    }

    /// Save the view context if there are changes
    func save() {
        let context = container.viewContext
        
        guard context.hasChanges else { return }
        
        do {
            try context.save()
            logger.debug("Context saved successfully")
        } catch {
            logger.error("Failed to save context: \(error.localizedDescription)")
        }
    }

    /// Perform a background task. Sets the merge policy on the supplied
    /// context so uniqueness-constraint conflicts (e.g. CDMessage.id) merge
    /// instead of throwing — without this, default NSErrorMergePolicyType
    /// makes background saves fail and silently drop wire messages.
    func performBackgroundTask(_ block: @escaping (NSManagedObjectContext) -> Void) {
        container.performBackgroundTask { context in
            context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
            block(context)
        }
    }
}
