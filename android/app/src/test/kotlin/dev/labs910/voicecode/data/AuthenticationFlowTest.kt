package dev.labs910.voicecode.data

import dev.labs910.voicecode.data.model.*
import kotlinx.serialization.json.Json
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test

/**
 * Tests for WebSocket authentication flow.
 * Mirrors iOS authentication tests.
 *
 * Authentication flow:
 * 1. Connect WebSocket
 * 2. Receive "hello" message
 * 3. Send "connect" with api_key and session_id
 * 4. Receive "connected" on success OR "auth_error" on failure
 */
class AuthenticationFlowTest {

    private lateinit var json: Json

    @Before
    fun setUp() {
        json = Json {
            ignoreUnknownKeys = true
            isLenient = true
            encodeDefaults = true
        }
    }

    // =========================================================================
    // MARK: - Hello Message Tests
    // =========================================================================

    @Test
    fun `HelloMessage parses correctly`() {
        val jsonString = """
            {
                "type": "hello",
                "message": "Welcome to voice-code backend",
                "version": "0.2.0",
                "auth_version": 1,
                "instructions": "Send connect message with api_key"
            }
        """.trimIndent()

        val message = json.decodeFromString<HelloMessage>(jsonString)

        assertEquals("hello", message.type)
        assertEquals("Welcome to voice-code backend", message.message)
        assertEquals("0.2.0", message.version)
        assertEquals(1, message.authVersion)
        assertEquals("Send connect message with api_key", message.instructions)
    }

    @Test
    fun `HelloMessage uses snake_case for auth_version`() {
        val jsonString = """
            {
                "type": "hello",
                "message": "Welcome",
                "version": "0.2.0",
                "auth_version": 2,
                "instructions": "Instructions"
            }
        """.trimIndent()

        val message = json.decodeFromString<HelloMessage>(jsonString)

        assertEquals(2, message.authVersion)
    }

    // =========================================================================
    // MARK: - Connect Message Tests
    // =========================================================================

    @Test
    fun `ConnectMessage serializes with correct format`() {
        val message = ConnectMessage(
            sessionId = "abc123de-4567-89ab-cdef-0123456789ab",
            apiKey = "untethered-a1b2c3d4e5f678901234567890abcdef"
        )

        val jsonString = json.encodeToString(ConnectMessage.serializer(), message)

        assertTrue(jsonString.contains("\"type\":\"connect\""))
        assertTrue(jsonString.contains("\"session_id\":\"abc123de-4567-89ab-cdef-0123456789ab\""))
        assertTrue(jsonString.contains("\"api_key\":\"untethered-a1b2c3d4e5f678901234567890abcdef\""))
    }

    @Test
    fun `ConnectMessage uses snake_case keys`() {
        val message = ConnectMessage(
            sessionId = "test-session",
            apiKey = "untethered-12345678901234567890123456789012"
        )

        val jsonString = json.encodeToString(ConnectMessage.serializer(), message)

        assertTrue(jsonString.contains("session_id"))
        assertTrue(jsonString.contains("api_key"))
        assertFalse(jsonString.contains("sessionId"))
        assertFalse(jsonString.contains("apiKey"))
    }

    @Test
    fun `ConnectMessage session_id should be lowercase`() {
        // Per STANDARDS.md, all UUIDs must be lowercase
        val sessionId = "abc123de-4567-89ab-cdef-0123456789ab"
        val message = ConnectMessage(
            sessionId = sessionId,
            apiKey = "untethered-12345678901234567890123456789012"
        )

        val jsonString = json.encodeToString(ConnectMessage.serializer(), message)

        // Should contain lowercase UUID
        assertTrue(jsonString.contains(sessionId))
        // Should not contain uppercase
        assertFalse(jsonString.contains("ABC"))
    }

    // =========================================================================
    // MARK: - Connected Message Tests
    // =========================================================================

    @Test
    fun `ConnectedMessage parses successfully`() {
        val jsonString = """
            {
                "type": "connected",
                "message": "Session registered",
                "session_id": "abc123de-4567-89ab-cdef-0123456789ab"
            }
        """.trimIndent()

        val message = json.decodeFromString<ConnectedMessage>(jsonString)

        assertEquals("connected", message.type)
        assertEquals("Session registered", message.message)
        assertEquals("abc123de-4567-89ab-cdef-0123456789ab", message.sessionId)
    }

    @Test
    fun `ConnectedMessage confirms session_id matches request`() {
        val requestedSessionId = "abc123de-4567-89ab-cdef-0123456789ab"

        val responseJson = """
            {
                "type": "connected",
                "message": "Session registered",
                "session_id": "$requestedSessionId"
            }
        """.trimIndent()

        val response = json.decodeFromString<ConnectedMessage>(responseJson)

        assertEquals(requestedSessionId, response.sessionId)
    }

    // =========================================================================
    // MARK: - Auth Error Tests
    // =========================================================================

    @Test
    fun `AuthErrorMessage parses authentication failure`() {
        val jsonString = """
            {
                "type": "auth_error",
                "message": "Authentication failed"
            }
        """.trimIndent()

        val message = json.decodeFromString<AuthErrorMessage>(jsonString)

        assertEquals("auth_error", message.type)
        assertEquals("Authentication failed", message.message)
    }

    @Test
    fun `AuthErrorMessage has generic error message`() {
        // Per STANDARDS.md, error message is intentionally generic
        // to prevent information leakage about valid keys
        val jsonString = """
            {
                "type": "auth_error",
                "message": "Authentication failed"
            }
        """.trimIndent()

        val message = json.decodeFromString<AuthErrorMessage>(jsonString)

        // Message should be generic, not specific
        assertFalse(message.message.contains("invalid"))
        assertFalse(message.message.contains("missing"))
        assertFalse(message.message.contains("key"))
    }

    // =========================================================================
    // MARK: - API Key Format Tests
    // =========================================================================

    @Test
    fun `API key format validation - valid key`() {
        val validKey = "untethered-a1b2c3d4e5f678901234567890abcdef"

        assertTrue(isValidApiKeyFormat(validKey))
    }

    @Test
    fun `API key format validation - missing prefix`() {
        val invalidKey = "a1b2c3d4e5f678901234567890abcdef"

        assertFalse(isValidApiKeyFormat(invalidKey))
    }

    @Test
    fun `API key format validation - wrong prefix`() {
        val invalidKey = "tethered-a1b2c3d4e5f678901234567890abcdef"

        assertFalse(isValidApiKeyFormat(invalidKey))
    }

    @Test
    fun `API key format validation - too short`() {
        val invalidKey = "untethered-a1b2c3d4"

        assertFalse(isValidApiKeyFormat(invalidKey))
    }

    @Test
    fun `API key format validation - too long`() {
        val invalidKey = "untethered-a1b2c3d4e5f678901234567890abcdef0000"

        assertFalse(isValidApiKeyFormat(invalidKey))
    }

    @Test
    fun `API key format validation - uppercase hex should be normalized`() {
        val upperCaseKey = "untethered-A1B2C3D4E5F678901234567890ABCDEF"

        // Key should be normalized to lowercase before use
        assertTrue(isValidApiKeyFormat(upperCaseKey.lowercase()))
    }

    @Test
    fun `API key format validation - non-hex characters`() {
        val invalidKey = "untethered-g1h2i3j4k5l678901234567890zyxwvu"

        assertFalse(isValidApiKeyFormat(invalidKey))
    }

    @Test
    fun `API key is exactly 43 characters`() {
        val validKey = "untethered-a1b2c3d4e5f678901234567890abcdef"

        assertEquals(43, validKey.length)
        assertEquals(11, "untethered-".length) // Prefix length
        assertEquals(32, validKey.removePrefix("untethered-").length) // Hex part
    }

    // =========================================================================
    // MARK: - Authentication Flow Sequence Tests
    // =========================================================================

    @Test
    fun `authentication flow - successful sequence`() {
        // Step 1: Parse hello
        val helloJson = """
            {
                "type": "hello",
                "message": "Welcome",
                "version": "0.2.0",
                "auth_version": 1,
                "instructions": "Send connect"
            }
        """.trimIndent()

        val hello = json.decodeFromString<HelloMessage>(helloJson)
        assertEquals("hello", hello.type)

        // Step 2: Send connect
        val connect = ConnectMessage(
            sessionId = "session-123",
            apiKey = "untethered-a1b2c3d4e5f678901234567890abcdef"
        )
        val connectJson = json.encodeToString(ConnectMessage.serializer(), connect)
        assertTrue(connectJson.contains("connect"))

        // Step 3: Receive connected
        val connectedJson = """
            {
                "type": "connected",
                "message": "Session registered",
                "session_id": "session-123"
            }
        """.trimIndent()

        val connected = json.decodeFromString<ConnectedMessage>(connectedJson)
        assertEquals("connected", connected.type)
        assertEquals("session-123", connected.sessionId)
    }

    @Test
    fun `authentication flow - failed sequence`() {
        // Step 1: Parse hello
        val helloJson = """
            {
                "type": "hello",
                "message": "Welcome",
                "version": "0.2.0",
                "auth_version": 1,
                "instructions": "Send connect"
            }
        """.trimIndent()

        val hello = json.decodeFromString<HelloMessage>(helloJson)
        assertEquals("hello", hello.type)

        // Step 2: Send connect with invalid key
        val connect = ConnectMessage(
            sessionId = "session-123",
            apiKey = "invalid-key"
        )
        assertFalse(isValidApiKeyFormat(connect.apiKey))

        // Step 3: Receive auth_error
        val authErrorJson = """
            {
                "type": "auth_error",
                "message": "Authentication failed"
            }
        """.trimIndent()

        val authError = json.decodeFromString<AuthErrorMessage>(authErrorJson)
        assertEquals("auth_error", authError.type)
    }

    // =========================================================================
    // MARK: - Reconnection Authentication Tests
    // =========================================================================

    @Test
    fun `reconnection requires re-authentication`() {
        // After disconnect, client must send connect message again
        val connect = ConnectMessage(
            sessionId = "same-session-123",
            apiKey = "untethered-a1b2c3d4e5f678901234567890abcdef"
        )

        val jsonString = json.encodeToString(ConnectMessage.serializer(), connect)

        // Same session ID can be used for reconnection
        assertTrue(jsonString.contains("same-session-123"))
        // API key must be included
        assertTrue(jsonString.contains("api_key"))
    }

    @Test
    fun `refresh sessions does not require re-authentication`() {
        // Per STANDARDS.md, refresh_sessions only works when already authenticated
        val refreshMessage = RefreshSessionsMessage(
            recentSessionsLimit = 10
        )

        val jsonString = json.encodeToString(RefreshSessionsMessage.serializer(), refreshMessage)

        assertTrue(jsonString.contains("\"type\":\"refresh_sessions\""))
        assertTrue(jsonString.contains("\"recent_sessions_limit\":10"))
        // Should not contain api_key
        assertFalse(jsonString.contains("api_key"))
    }

    // =========================================================================
    // MARK: - Helper Functions
    // =========================================================================

    /**
     * Validates API key format.
     * Format: "untethered-" + 32 lowercase hex characters (43 chars total)
     */
    private fun isValidApiKeyFormat(key: String): Boolean {
        if (!key.startsWith("untethered-")) return false
        if (key.length != 43) return false

        val hexPart = key.removePrefix("untethered-")
        return hexPart.length == 32 && hexPart.all { it in '0'..'9' || it in 'a'..'f' }
    }
}
