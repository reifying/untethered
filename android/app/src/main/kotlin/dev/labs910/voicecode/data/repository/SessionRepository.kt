package dev.labs910.voicecode.data.repository

import dev.labs910.voicecode.data.local.MessageDao
import dev.labs910.voicecode.data.local.MessageEntity
import dev.labs910.voicecode.data.local.SessionDao
import dev.labs910.voicecode.data.local.SessionEntity
import dev.labs910.voicecode.data.model.HistoryMessageData
import dev.labs910.voicecode.data.model.SessionMetadata
import dev.labs910.voicecode.domain.model.*
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map
import java.time.Instant
import java.util.UUID

/**
 * Repository for session and message data.
 * Coordinates between local database and remote WebSocket client.
 */
class SessionRepository(
    private val sessionDao: SessionDao,
    private val messageDao: MessageDao
) {
    // ==========================================================================
    // MARK: - Sessions
    // ==========================================================================

    /**
     * Get all sessions as a Flow.
     */
    fun getAllSessions(): Flow<List<Session>> {
        return sessionDao.getAllSessions().map { entities ->
            entities.map { it.toDomain() }
        }
    }

    /**
     * Get recent sessions.
     */
    fun getRecentSessions(limit: Int = 5): Flow<List<Session>> {
        return sessionDao.getRecentSessions(limit).map { entities ->
            entities.map { it.toDomain() }
        }
    }

    /**
     * Get sessions by working directory.
     */
    fun getSessionsByDirectory(directory: String): Flow<List<Session>> {
        return sessionDao.getSessionsByDirectory(directory).map { entities ->
            entities.map { it.toDomain() }
        }
    }

    /**
     * Get a single session by ID.
     */
    suspend fun getSession(id: String): Session? {
        return sessionDao.getSession(id)?.toDomain()
    }

    /**
     * Create a new session.
     */
    suspend fun createSession(params: CreateSessionParams = CreateSessionParams()): Session {
        val session = Session(
            id = UUID.randomUUID().toString().lowercase(),
            workingDirectory = params.workingDirectory,
            name = params.name,
            lastModified = Instant.now()
        )

        sessionDao.insertSession(session.toEntity())
        return session
    }

    /**
     * Update a session from backend metadata.
     */
    suspend fun updateSessionFromBackend(metadata: SessionMetadata) {
        val existing = sessionDao.getSession(metadata.sessionId)

        val entity = SessionEntity(
            id = metadata.sessionId,
            backendSessionId = existing?.backendSessionId,
            name = metadata.name ?: existing?.name,
            workingDirectory = metadata.workingDirectory ?: existing?.workingDirectory,
            lastModified = metadata.lastModified?.let { parseTimestamp(it) }
                ?: existing?.lastModified
                ?: System.currentTimeMillis(),
            messageCount = existing?.messageCount ?: 0,
            preview = existing?.preview,
            unreadCount = existing?.unreadCount ?: 0,
            isUserDeleted = existing?.isUserDeleted ?: false,
            customName = existing?.customName,
            isInQueue = existing?.isInQueue ?: false,
            queuePosition = existing?.queuePosition ?: 0,
            queuedAt = existing?.queuedAt,
            isInPriorityQueue = existing?.isInPriorityQueue ?: false,
            priority = existing?.priority ?: 10,
            priorityOrder = existing?.priorityOrder ?: 0.0,
            priorityQueuedAt = existing?.priorityQueuedAt
        )

        sessionDao.insertSession(entity)
    }

    /**
     * Update the backend session ID for a local session.
     */
    suspend fun updateBackendSessionId(localId: String, backendId: String) {
        sessionDao.updateBackendSessionId(localId, backendId)
    }

    /**
     * Soft delete a session (mark as deleted but keep in database).
     */
    suspend fun deleteSession(id: String) {
        sessionDao.softDeleteSession(id)
    }

    /**
     * Mark a session as read.
     */
    suspend fun markSessionRead(id: String) {
        sessionDao.markSessionRead(id)
    }

    /**
     * Update session preview text.
     */
    suspend fun updateSessionPreview(id: String, preview: String) {
        sessionDao.updatePreview(id, preview)
    }

    // ==========================================================================
    // MARK: - Messages
    // ==========================================================================

    /**
     * Get messages for a session as a Flow.
     */
    fun getMessagesForSession(sessionId: String): Flow<List<Message>> {
        return messageDao.getMessagesForSession(sessionId).map { entities ->
            entities.map { it.toDomain() }
        }
    }

    /**
     * Get a single message by ID.
     */
    suspend fun getMessage(id: String): Message? {
        return messageDao.getMessage(id)?.toDomain()
    }

    /**
     * Create a new user message (optimistic insert).
     */
    suspend fun createUserMessage(sessionId: String, text: String): Message {
        val message = Message(
            id = UUID.randomUUID().toString().lowercase(),
            sessionId = sessionId,
            role = MessageRole.USER,
            text = text,
            timestamp = Instant.now(),
            status = MessageStatus.SENDING
        )

        messageDao.insertMessage(message.toEntity())
        sessionDao.incrementMessageCount(sessionId)
        sessionDao.updatePreview(sessionId, text.take(100))

        return message
    }

    /**
     * Save a message from backend response.
     */
    suspend fun saveBackendMessage(
        sessionId: String,
        messageId: String?,
        role: String,
        text: String,
        timestamp: String?,
        usage: dev.labs910.voicecode.data.model.UsageData? = null,
        cost: dev.labs910.voicecode.data.model.CostData? = null
    ): Message {
        val message = Message(
            id = messageId ?: UUID.randomUUID().toString().lowercase(),
            sessionId = sessionId,
            role = MessageRole.fromString(role),
            text = text,
            timestamp = timestamp?.let { parseInstant(it) } ?: Instant.now(),
            status = MessageStatus.CONFIRMED,
            usage = usage?.let { MessageUsage(it.inputTokens, it.outputTokens, it.cacheReadTokens, it.cacheWriteTokens) },
            cost = cost?.let { MessageCost(it.inputCost, it.outputCost, it.totalCost) }
        )

        messageDao.insertMessage(message.toEntity())
        sessionDao.incrementMessageCount(sessionId)

        if (role == "assistant") {
            sessionDao.updatePreview(sessionId, text.take(100))
        }

        return message
    }

    /**
     * Save messages from session history.
     */
    suspend fun saveHistoryMessages(sessionId: String, messages: List<HistoryMessageData>) {
        val entities = messages.map { data ->
            MessageEntity(
                id = data.id ?: UUID.randomUUID().toString().lowercase(),
                sessionId = sessionId,
                role = data.role,
                text = data.text,
                timestamp = data.timestamp?.let { parseTimestamp(it) } ?: System.currentTimeMillis(),
                status = "confirmed"
            )
        }

        messageDao.insertMessages(entities)
    }

    /**
     * Update message status (e.g., from SENDING to CONFIRMED or ERROR).
     */
    suspend fun updateMessageStatus(id: String, status: MessageStatus) {
        messageDao.updateMessageStatus(id, status.name.lowercase())
    }

    /**
     * Delete all messages for a session.
     */
    suspend fun clearSessionMessages(sessionId: String) {
        messageDao.deleteMessagesForSession(sessionId)
    }

    // ==========================================================================
    // MARK: - FIFO Queue
    // ==========================================================================

    /**
     * Get sessions in the FIFO queue, ordered by queue position.
     */
    fun getQueueSessions(): Flow<List<Session>> {
        return sessionDao.getQueueSessions().map { entities ->
            entities.map { it.toDomain() }
        }
    }

    /**
     * Add a session to the FIFO queue.
     * Places it at the end of the queue.
     */
    suspend fun addToQueue(sessionId: String) {
        val maxPosition = sessionDao.getMaxQueuePosition() ?: -1
        sessionDao.addToQueue(sessionId, maxPosition + 1)
    }

    /**
     * Remove a session from the FIFO queue.
     * Reorders remaining sessions to close the gap.
     */
    suspend fun removeFromQueue(sessionId: String) {
        val session = sessionDao.getSession(sessionId) ?: return
        if (!session.isInQueue) return

        val position = session.queuePosition
        sessionDao.removeFromQueue(sessionId)
        sessionDao.shiftQueuePositionsDown(position)
    }

    // ==========================================================================
    // MARK: - Priority Queue
    // ==========================================================================

    /**
     * Get sessions in the priority queue, ordered by priority then priorityOrder.
     */
    fun getPriorityQueueSessions(): Flow<List<Session>> {
        return sessionDao.getPriorityQueueSessions().map { entities ->
            entities.map { it.toDomain() }
        }
    }

    /**
     * Add a session to the priority queue.
     * Assigns default priority (10 = Low) and places it at the end of that priority level.
     */
    suspend fun addToPriorityQueue(sessionId: String, priority: Int = 10) {
        // Get the max order for this priority level and add 1.0
        val maxOrder = sessionDao.getMaxPriorityOrder(priority) ?: 0.0
        val newOrder = maxOrder + 1.0

        sessionDao.addToPriorityQueue(sessionId)
        sessionDao.updateSessionPriority(sessionId, priority, newOrder)
    }

    /**
     * Remove a session from the priority queue.
     */
    suspend fun removeFromPriorityQueue(sessionId: String) {
        sessionDao.removeFromPriorityQueue(sessionId)
    }

    /**
     * Change a session's priority level.
     * Places it at the end of the new priority level.
     */
    suspend fun changeSessionPriority(sessionId: String, newPriority: Int) {
        val maxOrder = sessionDao.getMaxPriorityOrder(newPriority) ?: 0.0
        val newOrder = maxOrder + 1.0
        sessionDao.updateSessionPriority(sessionId, newPriority, newOrder)
    }

    /**
     * Reorder a session within its priority level.
     * Used for drag-and-drop reordering.
     */
    suspend fun reorderSession(sessionId: String, newOrder: Double) {
        val session = sessionDao.getSession(sessionId) ?: return
        sessionDao.updateSessionPriority(sessionId, session.priority, newOrder)
    }

    // ==========================================================================
    // MARK: - Mappers
    // ==========================================================================

    private fun SessionEntity.toDomain(): Session {
        return Session(
            id = id,
            backendSessionId = backendSessionId,
            name = name,
            workingDirectory = workingDirectory,
            lastModified = Instant.ofEpochMilli(lastModified),
            messageCount = messageCount,
            preview = preview,
            unreadCount = unreadCount,
            isUserDeleted = isUserDeleted,
            customName = customName,
            isInQueue = isInQueue,
            queuePosition = queuePosition,
            queuedAt = queuedAt?.let { Instant.ofEpochMilli(it) },
            isInPriorityQueue = isInPriorityQueue,
            priority = priority,
            priorityOrder = priorityOrder,
            priorityQueuedAt = priorityQueuedAt?.let { Instant.ofEpochMilli(it) }
        )
    }

    private fun Session.toEntity(): SessionEntity {
        return SessionEntity(
            id = id,
            backendSessionId = backendSessionId,
            name = name,
            workingDirectory = workingDirectory,
            lastModified = lastModified.toEpochMilli(),
            messageCount = messageCount,
            preview = preview,
            unreadCount = unreadCount,
            isUserDeleted = isUserDeleted,
            customName = customName,
            isInQueue = isInQueue,
            queuePosition = queuePosition,
            queuedAt = queuedAt?.toEpochMilli(),
            isInPriorityQueue = isInPriorityQueue,
            priority = priority,
            priorityOrder = priorityOrder,
            priorityQueuedAt = priorityQueuedAt?.toEpochMilli()
        )
    }

    private fun MessageEntity.toDomain(): Message {
        return Message(
            id = id,
            sessionId = sessionId,
            role = MessageRole.fromString(role),
            text = text,
            timestamp = Instant.ofEpochMilli(timestamp),
            status = MessageStatus.valueOf(status.uppercase()),
            usage = if (inputTokens != null && outputTokens != null) {
                MessageUsage(inputTokens, outputTokens)
            } else null,
            cost = if (inputCost != null && outputCost != null && totalCost != null) {
                MessageCost(inputCost, outputCost, totalCost)
            } else null
        )
    }

    private fun Message.toEntity(): MessageEntity {
        return MessageEntity(
            id = id,
            sessionId = sessionId,
            role = role.toString(),
            text = text,
            timestamp = timestamp.toEpochMilli(),
            status = status.name.lowercase(),
            inputTokens = usage?.inputTokens,
            outputTokens = usage?.outputTokens,
            inputCost = cost?.inputCost,
            outputCost = cost?.outputCost,
            totalCost = cost?.totalCost
        )
    }

    private fun parseTimestamp(iso: String): Long {
        return try {
            Instant.parse(iso).toEpochMilli()
        } catch (e: Exception) {
            System.currentTimeMillis()
        }
    }

    private fun parseInstant(iso: String): Instant {
        return try {
            Instant.parse(iso)
        } catch (e: Exception) {
            Instant.now()
        }
    }
}
