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

        // Reset CDBackendSession.liveFromSeq across all sessions on app launch.
        // liveFromSeq is the TTS gate cursor — anything below it is treated
        // as historical (do not speak). Persisted only so it survives the
        // is_complete:false re-subscribe chain within a single app session;
        // it must not leak across app launches or the first subscribe reply
        // after relaunch would misclassify messages as live and read aloud
        // hours-old transcripts. See tmux-untethered-i2n.
        if !inMemory {
            resetLiveFromSeqOnAllSessions()
        }
    }

    private func resetLiveFromSeqOnAllSessions() {
        let context = container.newBackgroundContext()
        context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        context.perform {
            // NSBatchUpdateRequest skips the in-memory object graph and goes
            // straight to the store — much cheaper than fetching every row
            // when the user has hundreds of sessions.
            let batchUpdate = NSBatchUpdateRequest(entityName: "CDBackendSession")
            batchUpdate.propertiesToUpdate = ["liveFromSeq": Int64(0)]
            batchUpdate.resultType = .updatedObjectsCountResultType
            do {
                let result = try context.execute(batchUpdate) as? NSBatchUpdateResult
                if let count = result?.result as? Int, count > 0 {
                    logger.info("Reset liveFromSeq on \(count) sessions for fresh app launch")
                }
            } catch {
                // Non-fatal: TTS gate falls back to "suppress all" behavior
                // until each session captures liveFromSeq from its first
                // post-launch reply, which is correct (just slightly more
                // aggressive than intended).
                logger.error("Failed to reset liveFromSeq: \(error.localizedDescription)")
            }
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
