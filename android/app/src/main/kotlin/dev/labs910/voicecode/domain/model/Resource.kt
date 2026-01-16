package dev.labs910.voicecode.domain.model

import java.time.Instant
import java.util.UUID

/**
 * Domain model for a file resource uploaded to the backend.
 * Corresponds to iOS Resource.swift model.
 */
data class Resource(
    /** Unique identifier for this resource */
    val id: String = UUID.randomUUID().toString().lowercase(),

    /** Original filename */
    val filename: String,

    /** Relative path on backend: .untethered/resources/filename */
    val path: String,

    /** File size in bytes */
    val size: Long,

    /** Upload timestamp */
    val timestamp: Instant = Instant.now()
) {
    /**
     * Human-readable file size.
     * Uses standard units: B, KB, MB, GB.
     */
    val formattedSize: String
        get() = when {
            size < 1024 -> "$size B"
            size < 1024 * 1024 -> String.format("%.1f KB", size / 1024.0)
            size < 1024 * 1024 * 1024 -> String.format("%.1f MB", size / (1024.0 * 1024))
            else -> String.format("%.1f GB", size / (1024.0 * 1024 * 1024))
        }
}

/**
 * Upload status for tracking pending uploads.
 */
enum class UploadStatus {
    PENDING,
    UPLOADING,
    COMPLETED,
    FAILED
}

/**
 * Pending upload metadata.
 * Used by ResourcesManager to track uploads from Share Intent.
 */
data class PendingUpload(
    val id: String = UUID.randomUUID().toString().lowercase(),
    val filename: String,
    val localPath: String,
    val size: Long,
    val status: UploadStatus = UploadStatus.PENDING,
    val createdAt: Instant = Instant.now(),
    val errorMessage: String? = null
)
