// PersistenceController.swift
// CoreData persistence stack management for Shared package

import CoreData
import OSLog

/// Configuration for PersistenceController logging
public enum PersistenceConfig {
    /// The OSLog subsystem for CoreData logging
    nonisolated(unsafe) public static var subsystem: String = "com.voicecode.shared"
}

/// CoreData persistence stack with automatic migration and error recovery
public final class PersistenceController: @unchecked Sendable {
    public static let shared = PersistenceController()

    /// Cached managed object model to prevent multiple entity description registrations
    /// CoreData binds entity descriptions to managed object subclasses at the class level.
    /// Creating multiple NSManagedObjectModel instances causes "Multiple NSEntityDescriptions
    /// claim the NSManagedObject subclass" warnings and test failures.
    /// Note: Safe to share because NSManagedObjectModel is thread-safe after initial creation.
    nonisolated(unsafe) private static let cachedModel: NSManagedObjectModel = {
        if let modelURL = Bundle.module.url(forResource: "VoiceCode", withExtension: "momd"),
           let model = NSManagedObjectModel(contentsOf: modelURL) {
            return model
        } else {
            // Create model programmatically for testing when resources aren't available
            return createTestModel()
        }
    }()

    /// Preview instance for SwiftUI previews
    public static let preview: PersistenceController = {
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
            let logger = Logger(subsystem: PersistenceConfig.subsystem, category: "Persistence")
            logger.error("Preview data creation failed: \(error.localizedDescription)")
        }

        return controller
    }()

    public let container: NSPersistentContainer
    private let logger = Logger(subsystem: PersistenceConfig.subsystem, category: "Persistence")

    public init(inMemory: Bool = false) {
        // Use cached model to prevent multiple entity description registrations
        container = NSPersistentContainer(name: "VoiceCode", managedObjectModel: Self.cachedModel)

        if inMemory {
            container.persistentStoreDescriptions.first?.url = URL(fileURLWithPath: "/dev/null")
        } else {
            // Enable automatic lightweight migration
            let description = container.persistentStoreDescriptions.first
            description?.shouldInferMappingModelAutomatically = true
            description?.shouldMigrateStoreAutomatically = true
        }

        container.loadPersistentStores { [self] description, error in
            if let error = error {
                self.logger.error("CoreData failed to load: \(error.localizedDescription)")

                // Attempt recovery per Appendix Z.5
                if let storeURL = self.container.persistentStoreDescriptions.first?.url {
                    self.recoverFromCorruption(storeURL: storeURL)
                } else {
                    self.logger.error("No store URL found for recovery")
                }
            } else {
                self.logger.info("CoreData store loaded: \(description.url?.path ?? "unknown")")
            }
        }

        // Enable automatic merging of changes from parent context
        container.viewContext.automaticallyMergesChangesFromParent = true

        // Set merge policy to prefer property-level changes
        container.viewContext.mergePolicy = NSMergePolicy.mergeByPropertyObjectTrump

        // Configure observer to merge background context saves on main thread
        // This prevents SwiftUI @FetchRequest updates from occurring on background threads
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

            // Merge changes on main thread
            // Note: Notification is not Sendable but safe to pass here since we're on main queue
            nonisolated(unsafe) let notificationCopy = notification
            container.viewContext.perform {
                container.viewContext.mergeChanges(fromContextDidSave: notificationCopy)
            }
        }
    }

    /// Save the view context if there are changes
    public func save() {
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
    public func performBackgroundTask(_ block: @escaping @Sendable (NSManagedObjectContext) -> Void) {
        container.performBackgroundTask(block)
    }

    // MARK: - Corruption Recovery (Appendix Z.5)

    /// Recover from CoreData store corruption by backing up and recreating the store
    /// - Parameter storeURL: The URL of the corrupt store
    private func recoverFromCorruption(storeURL: URL) {
        logger.error("CoreData store corruption detected at: \(storeURL.path)")

        // 1. Backup corrupted store
        let timestamp = Date().timeIntervalSince1970
        let backupURL = storeURL.deletingLastPathComponent()
            .appendingPathComponent("VoiceCode_backup_\(Int(timestamp)).sqlite")

        do {
            try FileManager.default.copyItem(at: storeURL, to: backupURL)
            logger.info("Backed up corrupted store to: \(backupURL.path)")
        } catch {
            logger.error("Failed to backup corrupted store: \(error.localizedDescription)")
            // Continue with recovery even if backup fails
        }

        // 2. Delete corrupted store and associated files
        do {
            try FileManager.default.removeItem(at: storeURL)

            // Also remove -wal and -shm files if present
            let walURL = URL(fileURLWithPath: storeURL.path + "-wal")
            let shmURL = URL(fileURLWithPath: storeURL.path + "-shm")
            try? FileManager.default.removeItem(at: walURL)
            try? FileManager.default.removeItem(at: shmURL)

            logger.info("Deleted corrupt store files")
        } catch {
            logger.error("Failed to delete corrupt store: \(error.localizedDescription)")
            return
        }

        // 3. Reload with fresh store
        container.loadPersistentStores { [weak self] description, error in
            guard let self = self else { return }

            if let error = error {
                self.logger.error("Recovery failed - could not load fresh store: \(error.localizedDescription)")
            } else {
                self.logger.info("Recovery successful - store recreated at: \(description.url?.path ?? "unknown")")

                // 4. Trigger sync from backend to repopulate data
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .requestFullSync, object: nil)
                }
            }
        }
    }

    /// Manually trigger corruption recovery (for testing or user-initiated recovery)
    /// - Returns: true if recovery was initiated, false if no store URL found
    @discardableResult
    public func attemptRecovery() -> Bool {
        guard let storeURL = container.persistentStoreDescriptions.first?.url else {
            logger.error("Cannot attempt recovery: no store URL found")
            return false
        }

        recoverFromCorruption(storeURL: storeURL)
        return true
    }

    // MARK: - Cross-Context Object Lookup

    /// Look up an object in the view context by its objectID from another context
    /// Use this when you have an objectID from a background context and need to access the object on the main thread
    /// - Parameter objectID: The NSManagedObjectID from any context
    /// - Returns: The object in the view context, or nil if not found
    public func object<T: NSManagedObject>(for objectID: NSManagedObjectID) -> T? {
        do {
            return try container.viewContext.existingObject(with: objectID) as? T
        } catch {
            logger.error("Failed to fetch object for ID: \(error.localizedDescription)")
            return nil
        }
    }

    /// Look up an object in a specific context by its objectID
    /// - Parameters:
    ///   - objectID: The NSManagedObjectID from any context
    ///   - context: The context to look up the object in
    /// - Returns: The object in the specified context, or nil if not found
    public func object<T: NSManagedObject>(for objectID: NSManagedObjectID, in context: NSManagedObjectContext) -> T? {
        do {
            return try context.existingObject(with: objectID) as? T
        } catch {
            logger.error("Failed to fetch object for ID in context: \(error.localizedDescription)")
            return nil
        }
    }

    /// Perform a background task with a completion handler called AFTER merge to view context
    /// Use this when you need to post notifications after CoreData changes are visible on main thread
    /// - Parameters:
    ///   - block: The work to perform on the background context. Returns true if save was successful.
    ///   - onMergeComplete: Called on main thread after changes have been merged to view context
    public func performBackgroundTaskWithMergeCompletion(
        _ block: @escaping @Sendable (NSManagedObjectContext) -> Bool,
        onMergeComplete: @escaping @MainActor @Sendable () -> Void
    ) {
        container.performBackgroundTask { [weak self] context in
            let didSave = block(context)

            guard didSave else { return }

            // Wait for merge to complete on main thread, then call completion
            // The merge is triggered by NSManagedObjectContextDidSave notification
            // which we observe in init() and handle with viewContext.perform {}
            // We queue our completion after that by using DispatchQueue.main.async twice:
            // - First async: lands in queue after the merge notification handler
            // - Second async (via perform): ensures merge has completed
            DispatchQueue.main.async { [weak self] in
                self?.container.viewContext.perform {
                    Task { @MainActor in
                        onMergeComplete()
                    }
                }
            }
        }
    }

    // MARK: - Test Model Creation

    /// Creates a CoreData model programmatically for testing when Bundle.module resources aren't available
    private static func createTestModel() -> NSManagedObjectModel {
        let model = NSManagedObjectModel()

        // CDBackendSession entity
        let sessionEntity = NSEntityDescription()
        sessionEntity.name = "CDBackendSession"
        sessionEntity.managedObjectClassName = NSStringFromClass(CDBackendSession.self)

        let sessionIdAttr = NSAttributeDescription()
        sessionIdAttr.name = "id"
        sessionIdAttr.attributeType = .UUIDAttributeType

        let backendNameAttr = NSAttributeDescription()
        backendNameAttr.name = "backendName"
        backendNameAttr.attributeType = .stringAttributeType

        let workingDirAttr = NSAttributeDescription()
        workingDirAttr.name = "workingDirectory"
        workingDirAttr.attributeType = .stringAttributeType

        let lastModifiedAttr = NSAttributeDescription()
        lastModifiedAttr.name = "lastModified"
        lastModifiedAttr.attributeType = .dateAttributeType

        let messageCountAttr = NSAttributeDescription()
        messageCountAttr.name = "messageCount"
        messageCountAttr.attributeType = .integer32AttributeType

        let previewAttr = NSAttributeDescription()
        previewAttr.name = "preview"
        previewAttr.attributeType = .stringAttributeType
        previewAttr.isOptional = true

        let unreadCountAttr = NSAttributeDescription()
        unreadCountAttr.name = "unreadCount"
        unreadCountAttr.attributeType = .integer32AttributeType

        let isLocallyCreatedAttr = NSAttributeDescription()
        isLocallyCreatedAttr.name = "isLocallyCreated"
        isLocallyCreatedAttr.attributeType = .booleanAttributeType

        let priorityQueuePositionAttr = NSAttributeDescription()
        priorityQueuePositionAttr.name = "priorityQueuePosition"
        priorityQueuePositionAttr.attributeType = .doubleAttributeType
        priorityQueuePositionAttr.isOptional = true

        sessionEntity.properties = [
            sessionIdAttr, backendNameAttr, workingDirAttr, lastModifiedAttr,
            messageCountAttr, previewAttr, unreadCountAttr, isLocallyCreatedAttr,
            priorityQueuePositionAttr
        ]

        // CDMessage entity
        let messageEntity = NSEntityDescription()
        messageEntity.name = "CDMessage"
        messageEntity.managedObjectClassName = NSStringFromClass(CDMessage.self)

        let messageIdAttr = NSAttributeDescription()
        messageIdAttr.name = "id"
        messageIdAttr.attributeType = .UUIDAttributeType

        let sessionIdMsgAttr = NSAttributeDescription()
        sessionIdMsgAttr.name = "sessionId"
        sessionIdMsgAttr.attributeType = .UUIDAttributeType

        let roleAttr = NSAttributeDescription()
        roleAttr.name = "role"
        roleAttr.attributeType = .stringAttributeType

        let textAttr = NSAttributeDescription()
        textAttr.name = "text"
        textAttr.attributeType = .stringAttributeType

        let timestampAttr = NSAttributeDescription()
        timestampAttr.name = "timestamp"
        timestampAttr.attributeType = .dateAttributeType

        let serverTimestampAttr = NSAttributeDescription()
        serverTimestampAttr.name = "serverTimestamp"
        serverTimestampAttr.attributeType = .dateAttributeType
        serverTimestampAttr.isOptional = true

        let statusAttr = NSAttributeDescription()
        statusAttr.name = "status"
        statusAttr.attributeType = .integer16AttributeType

        messageEntity.properties = [
            messageIdAttr, sessionIdMsgAttr, roleAttr, textAttr,
            timestampAttr, serverTimestampAttr, statusAttr
        ]

        // CDUserSession entity
        let userSessionEntity = NSEntityDescription()
        userSessionEntity.name = "CDUserSession"
        userSessionEntity.managedObjectClassName = NSStringFromClass(CDUserSession.self)

        let userSessionIdAttr = NSAttributeDescription()
        userSessionIdAttr.name = "id"
        userSessionIdAttr.attributeType = .UUIDAttributeType

        let customNameAttr = NSAttributeDescription()
        customNameAttr.name = "customName"
        customNameAttr.attributeType = .stringAttributeType
        customNameAttr.isOptional = true

        let createdAtAttr = NSAttributeDescription()
        createdAtAttr.name = "createdAt"
        createdAtAttr.attributeType = .dateAttributeType

        let isDeletedAttr = NSAttributeDescription()
        isDeletedAttr.name = "isDeleted"
        isDeletedAttr.attributeType = .booleanAttributeType

        userSessionEntity.properties = [userSessionIdAttr, customNameAttr, createdAtAttr, isDeletedAttr]

        // Relationships
        let sessionToMessages = NSRelationshipDescription()
        sessionToMessages.name = "messages"
        sessionToMessages.destinationEntity = messageEntity
        sessionToMessages.isOptional = true
        sessionToMessages.deleteRule = .cascadeDeleteRule

        let messageToSession = NSRelationshipDescription()
        messageToSession.name = "session"
        messageToSession.destinationEntity = sessionEntity
        messageToSession.maxCount = 1
        messageToSession.isOptional = true
        messageToSession.deleteRule = .nullifyDeleteRule

        sessionToMessages.inverseRelationship = messageToSession
        messageToSession.inverseRelationship = sessionToMessages

        sessionEntity.properties.append(sessionToMessages)
        messageEntity.properties.append(messageToSession)

        model.entities = [sessionEntity, messageEntity, userSessionEntity]

        return model
    }
}
