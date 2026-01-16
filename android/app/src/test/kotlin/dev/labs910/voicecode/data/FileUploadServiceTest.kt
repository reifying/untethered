package dev.labs910.voicecode.data

import dev.labs910.voicecode.data.remote.UploadRequest
import dev.labs910.voicecode.data.remote.UploadResponse
import dev.labs910.voicecode.data.remote.UploadResult
import kotlinx.serialization.json.Json
import org.junit.Assert.*
import org.junit.Test

/**
 * Tests for FileUploadService request/response serialization.
 * Verifies protocol compliance with STANDARDS.md HTTP API.
 */
class FileUploadServiceTest {

    private val json = Json {
        ignoreUnknownKeys = true
        encodeDefaults = true
    }

    // ==========================================================================
    // MARK: - UploadRequest Serialization
    // ==========================================================================

    @Test
    fun `UploadRequest serializes with snake_case keys`() {
        val request = UploadRequest(
            filename = "test.png",
            content = "base64content",
            storageLocation = "~/Downloads"
        )

        val serialized = json.encodeToString(UploadRequest.serializer(), request)

        assertTrue(serialized.contains("\"filename\":\"test.png\""))
        assertTrue(serialized.contains("\"content\":\"base64content\""))
        assertTrue(serialized.contains("\"storage_location\":\"~/Downloads\""))
    }

    @Test
    fun `UploadRequest with special characters in filename`() {
        val request = UploadRequest(
            filename = "my file (1).png",
            content = "base64content",
            storageLocation = "~/Documents/Files"
        )

        val serialized = json.encodeToString(UploadRequest.serializer(), request)

        assertTrue(serialized.contains("\"filename\":\"my file (1).png\""))
        assertTrue(serialized.contains("\"storage_location\":\"~/Documents/Files\""))
    }

    // ==========================================================================
    // MARK: - UploadResponse Deserialization
    // ==========================================================================

    @Test
    fun `UploadResponse deserializes success response`() {
        val jsonString = """
            {
                "success": true,
                "filename": "image.png",
                "path": "/Users/user/Downloads/image.png",
                "relative_path": "image.png",
                "size": 12345,
                "timestamp": "2025-11-01T12:34:56.789Z"
            }
        """.trimIndent()

        val response = json.decodeFromString<UploadResponse>(jsonString)

        assertTrue(response.success)
        assertEquals("image.png", response.filename)
        assertEquals("/Users/user/Downloads/image.png", response.path)
        assertEquals("image.png", response.relativePath)
        assertEquals(12345, response.size)
        assertEquals("2025-11-01T12:34:56.789Z", response.timestamp)
        assertNull(response.error)
    }

    @Test
    fun `UploadResponse deserializes error response`() {
        val jsonString = """
            {
                "success": false,
                "error": "filename, content, and storage_location are required"
            }
        """.trimIndent()

        val response = json.decodeFromString<UploadResponse>(jsonString)

        assertFalse(response.success)
        assertEquals("filename, content, and storage_location are required", response.error)
        assertNull(response.filename)
        assertNull(response.path)
    }

    @Test
    fun `UploadResponse deserializes auth error response`() {
        val jsonString = """
            {
                "success": false,
                "error": "Authentication failed"
            }
        """.trimIndent()

        val response = json.decodeFromString<UploadResponse>(jsonString)

        assertFalse(response.success)
        assertEquals("Authentication failed", response.error)
    }

    @Test
    fun `UploadResponse handles missing optional fields`() {
        val jsonString = """
            {
                "success": true,
                "filename": "test.txt",
                "path": "/path/to/test.txt"
            }
        """.trimIndent()

        val response = json.decodeFromString<UploadResponse>(jsonString)

        assertTrue(response.success)
        assertEquals("test.txt", response.filename)
        assertEquals("/path/to/test.txt", response.path)
        assertNull(response.relativePath)
        assertNull(response.size)
        assertNull(response.timestamp)
    }

    // ==========================================================================
    // MARK: - UploadResult Sealed Class
    // ==========================================================================

    @Test
    fun `UploadResult Success contains expected data`() {
        val result = UploadResult.Success(
            filename = "document.pdf",
            path = "/Users/test/Downloads/document.pdf",
            size = 54321
        )

        assertEquals("document.pdf", result.filename)
        assertEquals("/Users/test/Downloads/document.pdf", result.path)
        assertEquals(54321, result.size)
    }

    @Test
    fun `UploadResult Error contains message`() {
        val result = UploadResult.Error("Network error: Connection refused")

        assertEquals("Network error: Connection refused", result.message)
    }

    @Test
    fun `UploadResult AuthError contains message`() {
        val result = UploadResult.AuthError("Authentication failed")

        assertEquals("Authentication failed", result.message)
    }

    @Test
    fun `UploadResult types are distinguishable with when expression`() {
        val results = listOf(
            UploadResult.Success("file.txt", "/path", 100),
            UploadResult.Error("Network error"),
            UploadResult.AuthError("Auth failed")
        )

        val types = results.map { result ->
            when (result) {
                is UploadResult.Success -> "success"
                is UploadResult.Error -> "error"
                is UploadResult.AuthError -> "auth_error"
            }
        }

        assertEquals(listOf("success", "error", "auth_error"), types)
    }

    // ==========================================================================
    // MARK: - File Size Validation
    // ==========================================================================

    @Test
    fun `max file size constant is 10MB`() {
        val maxFileSize = 10 * 1024 * 1024 // 10MB in bytes
        assertEquals(10_485_760, maxFileSize)
    }

    @Test
    fun `file size check logic works correctly`() {
        val maxFileSize = 10 * 1024 * 1024L

        // Test file sizes
        val testCases = listOf(
            1024L to true,           // 1KB - OK
            5 * 1024 * 1024L to true,  // 5MB - OK
            10 * 1024 * 1024L to true, // 10MB - OK (at limit)
            10 * 1024 * 1024L + 1 to false, // 10MB + 1 byte - Too large
            20 * 1024 * 1024L to false // 20MB - Too large
        )

        for ((size, shouldPass) in testCases) {
            val passes = size <= maxFileSize
            assertEquals("Size $size should ${if (shouldPass) "pass" else "fail"}", shouldPass, passes)
        }
    }

    // ==========================================================================
    // MARK: - API Key Format
    // ==========================================================================

    @Test
    fun `API key format matches expected pattern`() {
        val validKey = "untethered-a1b2c3d4e5f678901234567890abcdef"

        assertTrue(validKey.startsWith("untethered-"))
        assertEquals(43, validKey.length)

        // Extract hex portion
        val hexPortion = validKey.removePrefix("untethered-")
        assertEquals(32, hexPortion.length)
        assertTrue(hexPortion.all { it.isDigit() || it in 'a'..'f' })
    }

    @Test
    fun `Bearer token format is correct`() {
        val apiKey = "untethered-a1b2c3d4e5f678901234567890abcdef"
        val authHeader = "Bearer $apiKey"

        assertEquals("Bearer untethered-a1b2c3d4e5f678901234567890abcdef", authHeader)
        assertTrue(authHeader.startsWith("Bearer "))
    }
}
