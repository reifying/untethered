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

    public init(inMemory: Bool = false) {
        let logger = Logger(subsystem: PersistenceConfig.subsystem, category: "Persistence")

        // Load CoreData model from Bundle.module (Swift Package resources)
        // Try Bundle.module first, then fall back to creating an empty model for testing
        let managedObjectModel: NSManagedObjectModel
        if let modelURL = Bundle.module.url(forResource: "VoiceCode", withExtension: "momd"),
           let model = NSManagedObjectModel(contentsOf: modelURL) {
            managedObjectModel = model
        } else {
            // Create model programmatically for testing when resources aren't available
            managedObjectModel = Self.createTestModel()
            logger.warning("CoreData model loaded from programmatic definition (test mode)")
        }

        container = NSPersistentContainer(name: "VoiceCode", managedObjectModel: managedObjectModel)

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
                    logger.warning("Attempting to recover by deleting corrupt store at: \(storeURL.path)")

                    do {
                        try FileManager.default.removeItem(at: storeURL)
                        logger.info("Deleted corrupt store, reloading...")

                        // Attempt to reload after deletion
                        self.container.loadPersistentStores { recoveryDescription, recoveryError in
                            if let recoveryError = recoveryError {
                                logger.error("Recovery failed: \(recoveryError.localizedDescription)")
                            } else {
                                logger.info("Store recovered successfully: \(recoveryDescription.url?.path ?? "unknown")")
                            }
                        }
                    } catch {
                        logger.error("Failed to delete corrupt store: \(error.localizedDescription)")
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
            let logger = Logger(subsystem: PersistenceConfig.subsystem, category: "Persistence")
            logger.debug("Context saved successfully")
        } catch {
            let logger = Logger(subsystem: PersistenceConfig.subsystem, category: "Persistence")
            logger.error("Failed to save context: \(error.localizedDescription)")
        }
    }

    /// Perform a background task
    public func performBackgroundTask(_ block: @escaping @Sendable (NSManagedObjectContext) -> Void) {
        container.performBackgroundTask(block)
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
