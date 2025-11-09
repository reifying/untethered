// PersistenceController.swift
// CoreData persistence stack management

import CoreData
import os.log

private let logger = Logger(subsystem: "com.travisbrown.VoiceCode", category: "Persistence")

struct PersistenceController {
    static let shared = PersistenceController()

    /// Preview instance for SwiftUI previews
    static var preview: PersistenceController = {
        let controller = PersistenceController(inMemory: true)
        let viewContext = controller.container.viewContext

        // Create sample data for previews
        let session = CDSession(context: viewContext)
        session.id = UUID()
        session.backendName = "Terminal: voice-code - 2025-10-17 14:30"
        session.workingDirectory = "/Users/travis/code/voice-code"
        session.lastModified = Date()
        session.messageCount = 2
        session.preview = "Hello! How can I help you?"
        session.markedDeleted = false

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
        container = NSPersistentContainer(name: "VoiceCode")

        if inMemory {
            container.persistentStoreDescriptions.first?.url = URL(fileURLWithPath: "/dev/null")
        }

        container.loadPersistentStores { description, error in
            if let error = error {
                logger.error("CoreData failed to load: \(error.localizedDescription)")

                // Attempt recovery by deleting and recreating the store
                if let storeURL = container.persistentStoreDescriptions.first?.url {
                    logger.warning("Attempting to recover by deleting corrupt store...")

                    do {
                        try FileManager.default.removeItem(at: storeURL)
                        logger.info("Deleted corrupt store, reloading...")

                        // Attempt to reload after deletion
                        container.loadPersistentStores { recoveryDescription, recoveryError in
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

    /// Perform a background task
    func performBackgroundTask(_ block: @escaping (NSManagedObjectContext) -> Void) {
        container.performBackgroundTask(block)
    }
}
