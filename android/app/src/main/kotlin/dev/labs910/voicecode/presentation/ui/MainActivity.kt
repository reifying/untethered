package dev.labs910.voicecode.presentation.ui

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import dev.labs910.voicecode.VoiceCodeApplication
import dev.labs910.voicecode.data.remote.ConnectionState
import dev.labs910.voicecode.data.remote.VoiceCodeClient
import dev.labs910.voicecode.presentation.ui.theme.VoiceCodeTheme

/**
 * Main activity for VoiceCode Android app.
 * Entry point for the application.
 */
class MainActivity : ComponentActivity() {

    private lateinit var voiceCodeClient: VoiceCodeClient

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()

        voiceCodeClient = VoiceCodeClient()

        setContent {
            VoiceCodeTheme {
                Surface(
                    modifier = Modifier.fillMaxSize(),
                    color = MaterialTheme.colorScheme.background
                ) {
                    VoiceCodeApp(
                        client = voiceCodeClient,
                        apiKeyManager = VoiceCodeApplication.getInstance().apiKeyManager
                    )
                }
            }
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        voiceCodeClient.destroy()
    }
}

@Composable
fun VoiceCodeApp(
    client: VoiceCodeClient,
    apiKeyManager: dev.labs910.voicecode.data.local.ApiKeyManager
) {
    val connectionState by client.connectionState.collectAsState()
    val isAuthenticated by client.isAuthenticated.collectAsState()
    val requiresReauth by client.requiresReauthentication.collectAsState()

    var showApiKeyDialog by remember { mutableStateOf(!apiKeyManager.hasApiKey()) }

    // Show API key dialog if needed
    if (showApiKeyDialog || requiresReauth) {
        ApiKeyDialog(
            onApiKeyEntered = { apiKey ->
                if (apiKeyManager.setApiKey(apiKey)) {
                    showApiKeyDialog = false
                    // TODO: Connect to server
                }
            },
            onDismiss = {
                if (apiKeyManager.hasApiKey()) {
                    showApiKeyDialog = false
                }
            }
        )
    }

    Scaffold(
        modifier = Modifier.fillMaxSize()
    ) { innerPadding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(innerPadding)
                .padding(16.dp),
            verticalArrangement = Arrangement.Center,
            horizontalAlignment = Alignment.CenterHorizontally
        ) {
            // Connection status
            ConnectionStatusCard(connectionState, isAuthenticated)

            Spacer(modifier = Modifier.height(24.dp))

            // Placeholder for session list
            Text(
                text = "VoiceCode Android",
                style = MaterialTheme.typography.headlineMedium
            )

            Spacer(modifier = Modifier.height(8.dp))

            Text(
                text = "iOS feature parity in progress",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )

            Spacer(modifier = Modifier.height(24.dp))

            // Settings button
            OutlinedButton(
                onClick = { showApiKeyDialog = true }
            ) {
                Text("Configure API Key")
            }
        }
    }
}

@Composable
fun ConnectionStatusCard(
    connectionState: ConnectionState,
    isAuthenticated: Boolean
) {
    val (statusText, statusColor) = when (connectionState) {
        ConnectionState.CONNECTED -> {
            if (isAuthenticated) "Connected" to MaterialTheme.colorScheme.primary
            else "Authenticating..." to MaterialTheme.colorScheme.tertiary
        }
        ConnectionState.CONNECTING -> "Connecting..." to MaterialTheme.colorScheme.tertiary
        ConnectionState.RECONNECTING -> "Reconnecting..." to MaterialTheme.colorScheme.error
        ConnectionState.DISCONNECTED -> "Disconnected" to MaterialTheme.colorScheme.error
    }

    Card(
        modifier = Modifier.fillMaxWidth(),
        colors = CardDefaults.cardColors(
            containerColor = statusColor.copy(alpha = 0.1f)
        )
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(16.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Surface(
                modifier = Modifier.size(12.dp),
                shape = MaterialTheme.shapes.small,
                color = statusColor
            ) {}

            Spacer(modifier = Modifier.width(12.dp))

            Text(
                text = statusText,
                style = MaterialTheme.typography.bodyMedium,
                color = statusColor
            )
        }
    }
}

@Composable
fun ApiKeyDialog(
    onApiKeyEntered: (String) -> Unit,
    onDismiss: () -> Unit
) {
    var apiKey by remember { mutableStateOf("") }
    var isError by remember { mutableStateOf(false) }

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Enter API Key") },
        text = {
            Column {
                Text(
                    text = "Enter your VoiceCode API key to connect to the backend.",
                    style = MaterialTheme.typography.bodyMedium
                )
                Spacer(modifier = Modifier.height(16.dp))
                OutlinedTextField(
                    value = apiKey,
                    onValueChange = {
                        apiKey = it
                        isError = false
                    },
                    label = { Text("API Key") },
                    placeholder = { Text("untethered-...") },
                    isError = isError,
                    supportingText = if (isError) {
                        { Text("Invalid API key format") }
                    } else null,
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth()
                )
            }
        },
        confirmButton = {
            TextButton(
                onClick = {
                    if (apiKey.isNotBlank()) {
                        onApiKeyEntered(apiKey)
                    } else {
                        isError = true
                    }
                }
            ) {
                Text("Connect")
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) {
                Text("Cancel")
            }
        }
    )
}
