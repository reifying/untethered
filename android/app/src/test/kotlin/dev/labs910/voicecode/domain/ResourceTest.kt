package dev.labs910.voicecode.domain

import dev.labs910.voicecode.domain.model.*
import org.junit.Assert.*
import org.junit.Test
import java.time.Instant

/**
 * Tests for Resource domain model.
 */
class ResourceTest {

    @Test
    fun `Resource id is lowercase UUID`() {
        val resource = Resource(
            filename = "test.png",
            path = ".untethered/resources/test.png",
            size = 1024
        )

        assertEquals(resource.id, resource.id.lowercase())
        assertEquals(36, resource.id.length) // UUID format
    }

    @Test
    fun `Resource formattedSize shows bytes for small files`() {
        val resource = Resource(
            filename = "tiny.txt",
            path = ".untethered/resources/tiny.txt",
            size = 512
        )

        assertEquals("512 B", resource.formattedSize)
    }

    @Test
    fun `Resource formattedSize shows KB for kilobyte files`() {
        val resource = Resource(
            filename = "small.txt",
            path = ".untethered/resources/small.txt",
            size = 2048
        )

        assertEquals("2.0 KB", resource.formattedSize)
    }

    @Test
    fun `Resource formattedSize shows MB for megabyte files`() {
        val resource = Resource(
            filename = "medium.jpg",
            path = ".untethered/resources/medium.jpg",
            size = 5 * 1024 * 1024 // 5 MB
        )

        assertEquals("5.0 MB", resource.formattedSize)
    }

    @Test
    fun `Resource formattedSize shows GB for gigabyte files`() {
        val resource = Resource(
            filename = "large.zip",
            path = ".untethered/resources/large.zip",
            size = 2L * 1024 * 1024 * 1024 // 2 GB
        )

        assertEquals("2.0 GB", resource.formattedSize)
    }

    @Test
    fun `Resource timestamp defaults to now`() {
        val before = Instant.now()
        val resource = Resource(
            filename = "test.txt",
            path = ".untethered/resources/test.txt",
            size = 100
        )
        val after = Instant.now()

        assertTrue(resource.timestamp >= before)
        assertTrue(resource.timestamp <= after)
    }

    // ==========================================================================
    // MARK: - PendingUpload Tests
    // ==========================================================================

    @Test
    fun `PendingUpload defaults to PENDING status`() {
        val upload = PendingUpload(
            filename = "upload.pdf",
            localPath = "/storage/emulated/0/Download/upload.pdf",
            size = 4096
        )

        assertEquals(UploadStatus.PENDING, upload.status)
    }

    @Test
    fun `PendingUpload can track error message`() {
        val upload = PendingUpload(
            filename = "failed.pdf",
            localPath = "/storage/emulated/0/Download/failed.pdf",
            size = 4096,
            status = UploadStatus.FAILED,
            errorMessage = "Network connection lost"
        )

        assertEquals(UploadStatus.FAILED, upload.status)
        assertEquals("Network connection lost", upload.errorMessage)
    }

    @Test
    fun `UploadStatus enum has all expected values`() {
        val statuses = UploadStatus.values()

        assertEquals(4, statuses.size)
        assertTrue(statuses.contains(UploadStatus.PENDING))
        assertTrue(statuses.contains(UploadStatus.UPLOADING))
        assertTrue(statuses.contains(UploadStatus.COMPLETED))
        assertTrue(statuses.contains(UploadStatus.FAILED))
    }
}
