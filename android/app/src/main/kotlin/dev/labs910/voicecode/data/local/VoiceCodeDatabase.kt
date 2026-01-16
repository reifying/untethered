package dev.labs910.voicecode.data.local

import android.content.Context
import androidx.room.*
import kotlinx.coroutines.flow.Flow

/**
 * Room database for voice-code local persistence.
 * Equivalent to iOS CoreData stack.
 */
@Database(
    entities = [
        SessionEntity::class,
        MessageEntity::class
    ],
    version = 1,
    exportSchema = true
)
@TypeConverters(Converters::class)
abstract class VoiceCodeDatabase : RoomDatabase() {
    abstract fun sessionDao(): SessionDao
    abstract fun messageDao(): MessageDao

    companion object {
        private const val DATABASE_NAME = "voice_code.db"

        @Volatile
        private var INSTANCE: VoiceCodeDatabase? = null

        fun getInstance(context: Context): VoiceCodeDatabase {
            return INSTANCE ?: synchronized(this) {
                INSTANCE ?: buildDatabase(context).also { INSTANCE = it }
            }
        }

        private fun buildDatabase(context: Context): VoiceCodeDatabase {
            return Room.databaseBuilder(
                context.applicationContext,
                VoiceCodeDatabase::class.java,
                DATABASE_NAME
            )
                .fallbackToDestructiveMigration()
                .build()
        }
    }
}

/**
 * Type converters for Room.
 */
class Converters {
    @TypeConverter
    fun fromTimestamp(value: Long?): java.time.Instant? {
        return value?.let { java.time.Instant.ofEpochMilli(it) }
    }

    @TypeConverter
    fun toTimestamp(instant: java.time.Instant?): Long? {
        return instant?.toEpochMilli()
    }
}

// =============================================================================
// MARK: - Session Entity
// =============================================================================

/**
 * Session entity for Room database.
 * Equivalent to iOS CDBackendSession + CDUserSession.
 */
@Entity(tableName = "sessions")
data class SessionEntity(
    @PrimaryKey
    @ColumnInfo(name = "id")
    val id: String,

    @ColumnInfo(name = "backend_session_id")
    val backendSessionId: String? = null,

    @ColumnInfo(name = "name")
    val name: String? = null,

    @ColumnInfo(name = "working_directory")
    val workingDirectory: String? = null,

    @ColumnInfo(name = "last_modified")
    val lastModified: Long = System.currentTimeMillis(),

    @ColumnInfo(name = "message_count")
    val messageCount: Int = 0,

    @ColumnInfo(name = "preview")
    val preview: String? = null,

    @ColumnInfo(name = "unread_count")
    val unreadCount: Int = 0,

    @ColumnInfo(name = "is_user_deleted")
    val isUserDeleted: Boolean = false,

    @ColumnInfo(name = "custom_name")
    val customName: String? = null,

    // Priority Queue Fields
    @ColumnInfo(name = "is_in_priority_queue", defaultValue = "0")
    val isInPriorityQueue: Boolean = false,

    @ColumnInfo(name = "priority", defaultValue = "10")
    val priority: Int = 10,

    @ColumnInfo(name = "priority_order", defaultValue = "0.0")
    val priorityOrder: Double = 0.0,

    @ColumnInfo(name = "priority_queued_at")
    val priorityQueuedAt: Long? = null
)

/**
 * Session DAO for database operations.
 */
@Dao
interface SessionDao {
    @Query("SELECT * FROM sessions WHERE is_user_deleted = 0 ORDER BY last_modified DESC")
    fun getAllSessions(): Flow<List<SessionEntity>>

    @Query("SELECT * FROM sessions WHERE is_user_deleted = 0 ORDER BY last_modified DESC LIMIT :limit")
    fun getRecentSessions(limit: Int): Flow<List<SessionEntity>>

    @Query("SELECT * FROM sessions WHERE id = :id")
    suspend fun getSession(id: String): SessionEntity?

    @Query("SELECT * FROM sessions WHERE working_directory = :directory AND is_user_deleted = 0 ORDER BY last_modified DESC")
    fun getSessionsByDirectory(directory: String): Flow<List<SessionEntity>>

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insertSession(session: SessionEntity)

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insertSessions(sessions: List<SessionEntity>)

    @Update
    suspend fun updateSession(session: SessionEntity)

    @Query("UPDATE sessions SET is_user_deleted = 1 WHERE id = :id")
    suspend fun softDeleteSession(id: String)

    @Query("DELETE FROM sessions WHERE id = :id")
    suspend fun deleteSession(id: String)

    @Query("UPDATE sessions SET unread_count = 0 WHERE id = :id")
    suspend fun markSessionRead(id: String)

    @Query("UPDATE sessions SET message_count = message_count + 1, last_modified = :timestamp WHERE id = :id")
    suspend fun incrementMessageCount(id: String, timestamp: Long = System.currentTimeMillis())

    @Query("UPDATE sessions SET preview = :preview WHERE id = :id")
    suspend fun updatePreview(id: String, preview: String)

    @Query("UPDATE sessions SET backend_session_id = :backendSessionId WHERE id = :id")
    suspend fun updateBackendSessionId(id: String, backendSessionId: String)

    // Priority Queue Queries

    @Query("SELECT * FROM sessions WHERE is_in_priority_queue = 1 AND is_user_deleted = 0 ORDER BY priority ASC, priority_order ASC")
    fun getPriorityQueueSessions(): Flow<List<SessionEntity>>

    @Query("UPDATE sessions SET is_in_priority_queue = 1, priority_queued_at = :timestamp WHERE id = :id")
    suspend fun addToPriorityQueue(id: String, timestamp: Long = System.currentTimeMillis())

    @Query("UPDATE sessions SET is_in_priority_queue = 0, priority = 10, priority_order = 0.0, priority_queued_at = NULL WHERE id = :id")
    suspend fun removeFromPriorityQueue(id: String)

    @Query("UPDATE sessions SET priority = :priority, priority_order = :priorityOrder WHERE id = :id")
    suspend fun updateSessionPriority(id: String, priority: Int, priorityOrder: Double)

    @Query("SELECT MAX(priority_order) FROM sessions WHERE priority = :priority AND is_in_priority_queue = 1")
    suspend fun getMaxPriorityOrder(priority: Int): Double?
}

// =============================================================================
// MARK: - Message Entity
// =============================================================================

/**
 * Message entity for Room database.
 * Equivalent to iOS CDMessage.
 */
@Entity(
    tableName = "messages",
    foreignKeys = [
        ForeignKey(
            entity = SessionEntity::class,
            parentColumns = ["id"],
            childColumns = ["session_id"],
            onDelete = ForeignKey.CASCADE
        )
    ],
    indices = [
        Index(value = ["session_id"]),
        Index(value = ["timestamp"])
    ]
)
data class MessageEntity(
    @PrimaryKey
    @ColumnInfo(name = "id")
    val id: String,

    @ColumnInfo(name = "session_id")
    val sessionId: String,

    @ColumnInfo(name = "role")
    val role: String,

    @ColumnInfo(name = "text")
    val text: String,

    @ColumnInfo(name = "timestamp")
    val timestamp: Long = System.currentTimeMillis(),

    @ColumnInfo(name = "status")
    val status: String = "confirmed",

    @ColumnInfo(name = "input_tokens")
    val inputTokens: Int? = null,

    @ColumnInfo(name = "output_tokens")
    val outputTokens: Int? = null,

    @ColumnInfo(name = "input_cost")
    val inputCost: Double? = null,

    @ColumnInfo(name = "output_cost")
    val outputCost: Double? = null,

    @ColumnInfo(name = "total_cost")
    val totalCost: Double? = null
)

/**
 * Message DAO for database operations.
 */
@Dao
interface MessageDao {
    @Query("SELECT * FROM messages WHERE session_id = :sessionId ORDER BY timestamp ASC")
    fun getMessagesForSession(sessionId: String): Flow<List<MessageEntity>>

    @Query("SELECT * FROM messages WHERE session_id = :sessionId ORDER BY timestamp DESC LIMIT :limit")
    fun getRecentMessages(sessionId: String, limit: Int): Flow<List<MessageEntity>>

    @Query("SELECT * FROM messages WHERE id = :id")
    suspend fun getMessage(id: String): MessageEntity?

    @Query("SELECT * FROM messages WHERE session_id = :sessionId ORDER BY timestamp DESC LIMIT 1")
    suspend fun getLatestMessage(sessionId: String): MessageEntity?

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insertMessage(message: MessageEntity)

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insertMessages(messages: List<MessageEntity>)

    @Update
    suspend fun updateMessage(message: MessageEntity)

    @Query("UPDATE messages SET status = :status WHERE id = :id")
    suspend fun updateMessageStatus(id: String, status: String)

    @Query("DELETE FROM messages WHERE id = :id")
    suspend fun deleteMessage(id: String)

    @Query("DELETE FROM messages WHERE session_id = :sessionId")
    suspend fun deleteMessagesForSession(sessionId: String)

    @Query("SELECT COUNT(*) FROM messages WHERE session_id = :sessionId")
    suspend fun getMessageCount(sessionId: String): Int
}
