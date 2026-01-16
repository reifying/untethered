package dev.labs910.voicecode.data.remote

import android.content.Context
import android.net.Uri
import android.provider.OpenableColumns
import android.util.Base64
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.io.IOException

/**
 * Service for uploading files to the voice-code backend.
 * Equivalent to iOS Share Extension upload functionality.
 *
 * Uses HTTP POST /upload with Bearer token authentication.
 */
class FileUploadService(
    private val context: Context,
    private val apiKeyProvider: () -> String?
) {
    companion object {
        private const val UPLOAD_PATH = "/upload"
        private const val MAX_FILE_SIZE = 10 * 1024 * 1024 // 10MB
    }

    private val json = Json {
        ignoreUnknownKeys = true
        encodeDefaults = true
    }

    private val client = OkHttpClient.Builder()
        .build()

    /**
     * Upload a file to the backend.
     *
     * @param uri Content URI of the file
     * @param serverUrl Server base URL (e.g., "http://localhost:9999")
     * @param storageLocation Storage location on server (e.g., "~/Downloads")
     * @return Upload result
     */
    suspend fun uploadFile(
        uri: Uri,
        serverUrl: String,
        storageLocation: String = "~/Downloads"
    ): UploadResult = withContext(Dispatchers.IO) {
        val apiKey = apiKeyProvider()
            ?: return@withContext UploadResult.Error("No API key configured")

        try {
            // Get file info
            val fileInfo = getFileInfo(uri)
                ?: return@withContext UploadResult.Error("Could not read file info")

            // Check file size
            if (fileInfo.size > MAX_FILE_SIZE) {
                return@withContext UploadResult.Error("File too large (max ${MAX_FILE_SIZE / 1024 / 1024}MB)")
            }

            // Read file content
            val content = readFileContent(uri)
                ?: return@withContext UploadResult.Error("Could not read file content")

            // Encode to base64
            val base64Content = Base64.encodeToString(content, Base64.NO_WRAP)

            // Create request body
            val requestBody = UploadRequest(
                filename = fileInfo.name,
                content = base64Content,
                storageLocation = storageLocation
            )

            val requestJson = json.encodeToString(UploadRequest.serializer(), requestBody)

            // Build HTTP request
            val request = Request.Builder()
                .url("$serverUrl$UPLOAD_PATH")
                .addHeader("Authorization", "Bearer $apiKey")
                .addHeader("Content-Type", "application/json")
                .post(requestJson.toRequestBody("application/json".toMediaType()))
                .build()

            // Execute request
            val response = client.newCall(request).execute()

            if (response.isSuccessful) {
                val responseBody = response.body?.string()
                if (responseBody != null) {
                    val uploadResponse = json.decodeFromString<UploadResponse>(responseBody)
                    if (uploadResponse.success) {
                        UploadResult.Success(
                            filename = uploadResponse.filename ?: fileInfo.name,
                            path = uploadResponse.path ?: "",
                            size = uploadResponse.size ?: fileInfo.size.toInt()
                        )
                    } else {
                        UploadResult.Error(uploadResponse.error ?: "Upload failed")
                    }
                } else {
                    UploadResult.Error("Empty response")
                }
            } else {
                when (response.code) {
                    401 -> UploadResult.AuthError("Authentication failed")
                    400 -> {
                        val body = response.body?.string()
                        val error = try {
                            json.decodeFromString<UploadResponse>(body ?: "").error
                        } catch (e: Exception) {
                            null
                        }
                        UploadResult.Error(error ?: "Invalid request")
                    }
                    else -> UploadResult.Error("Server error: ${response.code}")
                }
            }
        } catch (e: IOException) {
            UploadResult.Error("Network error: ${e.message}")
        } catch (e: Exception) {
            UploadResult.Error("Upload error: ${e.message}")
        }
    }

    /**
     * Upload multiple files.
     */
    suspend fun uploadFiles(
        uris: List<Uri>,
        serverUrl: String,
        storageLocation: String = "~/Downloads"
    ): List<UploadResult> {
        return uris.map { uri ->
            uploadFile(uri, serverUrl, storageLocation)
        }
    }

    /**
     * Get file information from a content URI.
     */
    private fun getFileInfo(uri: Uri): FileInfo? {
        return try {
            context.contentResolver.query(uri, null, null, null, null)?.use { cursor ->
                val nameIndex = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                val sizeIndex = cursor.getColumnIndex(OpenableColumns.SIZE)

                if (cursor.moveToFirst()) {
                    val name = if (nameIndex >= 0) cursor.getString(nameIndex) else "unknown"
                    val size = if (sizeIndex >= 0) cursor.getLong(sizeIndex) else 0L
                    FileInfo(name, size)
                } else {
                    null
                }
            }
        } catch (e: Exception) {
            null
        }
    }

    /**
     * Read file content as byte array.
     */
    private fun readFileContent(uri: Uri): ByteArray? {
        return try {
            context.contentResolver.openInputStream(uri)?.use { inputStream ->
                inputStream.readBytes()
            }
        } catch (e: Exception) {
            null
        }
    }
}

/**
 * File information.
 */
data class FileInfo(
    val name: String,
    val size: Long
)

/**
 * Upload request body.
 */
@Serializable
data class UploadRequest(
    val filename: String,
    val content: String,
    @kotlinx.serialization.SerialName("storage_location")
    val storageLocation: String
)

/**
 * Upload response body.
 */
@Serializable
data class UploadResponse(
    val success: Boolean,
    val filename: String? = null,
    val path: String? = null,
    @kotlinx.serialization.SerialName("relative_path")
    val relativePath: String? = null,
    val size: Int? = null,
    val timestamp: String? = null,
    val error: String? = null
)

/**
 * Upload result.
 */
sealed class UploadResult {
    data class Success(
        val filename: String,
        val path: String,
        val size: Int
    ) : UploadResult()

    data class Error(val message: String) : UploadResult()

    data class AuthError(val message: String) : UploadResult()
}
