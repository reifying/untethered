package dev.labs910.voicecode.presentation.ui.screens

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.dp
import dev.labs910.voicecode.presentation.ui.components.QRCodeScanner

/**
 * API Key configuration screen with QR code scanning support.
 * Equivalent to iOS API key entry flow.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ApiKeyScreen(
    currentApiKey: String?,
    onApiKeyChange: (String) -> Unit,
    onClearApiKey: () -> Unit,
    onBack: () -> Unit,
    modifier: Modifier = Modifier
) {
    var showScanner by remember { mutableStateOf(false) }
    var apiKeyInput by remember { mutableStateOf(currentApiKey ?: "") }
    var showApiKey by remember { mutableStateOf(false) }
    var showClearDialog by remember { mutableStateOf(false) }

    if (showScanner) {
        // Full-screen QR scanner
        QRCodeScanner(
            onQRCodeScanned = { scannedKey ->
                apiKeyInput = scannedKey
                onApiKeyChange(scannedKey)
                showScanner = false
            },
            onClose = { showScanner = false }
        )
    } else {
        Scaffold(
            modifier = modifier.fillMaxSize(),
            topBar = {
                TopAppBar(
                    title = { Text("API Key") },
                    navigationIcon = {
                        IconButton(onClick = onBack) {
                            Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                        }
                    },
                    actions = {
                        if (currentApiKey != null) {
                            IconButton(onClick = { showClearDialog = true }) {
                                Icon(Icons.Default.Delete, contentDescription = "Clear API Key")
                            }
                        }
                    }
                )
            }
        ) { paddingValues ->
            Column(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(paddingValues)
                    .verticalScroll(rememberScrollState())
                    .padding(16.dp),
                horizontalAlignment = Alignment.CenterHorizontally
            ) {
                // Status indicator
                ApiKeyStatusCard(
                    hasApiKey = currentApiKey != null,
                    modifier = Modifier.fillMaxWidth()
                )

                Spacer(modifier = Modifier.height(24.dp))

                // QR Code scan button
                ElevatedButton(
                    onClick = { showScanner = true },
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(56.dp)
                ) {
                    Icon(
                        imageVector = Icons.Default.QrCodeScanner,
                        contentDescription = null,
                        modifier = Modifier.size(24.dp)
                    )
                    Spacer(modifier = Modifier.width(8.dp))
                    Text("Scan QR Code")
                }

                Spacer(modifier = Modifier.height(16.dp))

                // Divider with text
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    HorizontalDivider(modifier = Modifier.weight(1f))
                    Text(
                        text = "or enter manually",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(horizontal = 16.dp)
                    )
                    HorizontalDivider(modifier = Modifier.weight(1f))
                }

                Spacer(modifier = Modifier.height(16.dp))

                // Manual API key entry
                OutlinedTextField(
                    value = apiKeyInput,
                    onValueChange = { apiKeyInput = it },
                    label = { Text("API Key") },
                    placeholder = { Text("untethered-...") },
                    singleLine = true,
                    visualTransformation = if (showApiKey) {
                        VisualTransformation.None
                    } else {
                        PasswordVisualTransformation()
                    },
                    trailingIcon = {
                        IconButton(onClick = { showApiKey = !showApiKey }) {
                            Icon(
                                imageVector = if (showApiKey) Icons.Default.VisibilityOff else Icons.Default.Visibility,
                                contentDescription = if (showApiKey) "Hide" else "Show"
                            )
                        }
                    },
                    modifier = Modifier.fillMaxWidth()
                )

                Spacer(modifier = Modifier.height(16.dp))

                // Save button
                Button(
                    onClick = {
                        if (apiKeyInput.isNotBlank()) {
                            onApiKeyChange(apiKeyInput)
                        }
                    },
                    enabled = apiKeyInput.isNotBlank() && isValidApiKeyFormat(apiKeyInput),
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(48.dp)
                ) {
                    Text("Save API Key")
                }

                // Validation hint
                if (apiKeyInput.isNotBlank() && !isValidApiKeyFormat(apiKeyInput)) {
                    Spacer(modifier = Modifier.height(8.dp))
                    Text(
                        text = "API key must start with 'untethered-' and be 43 characters",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.error
                    )
                }

                Spacer(modifier = Modifier.height(32.dp))

                // Help text
                Card(
                    modifier = Modifier.fillMaxWidth(),
                    colors = CardDefaults.cardColors(
                        containerColor = MaterialTheme.colorScheme.surfaceVariant
                    )
                ) {
                    Column(
                        modifier = Modifier.padding(16.dp)
                    ) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Icon(
                                imageVector = Icons.Default.Info,
                                contentDescription = null,
                                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                                modifier = Modifier.size(20.dp)
                            )
                            Spacer(modifier = Modifier.width(8.dp))
                            Text(
                                text = "How to get an API key",
                                style = MaterialTheme.typography.titleSmall
                            )
                        }
                        Spacer(modifier = Modifier.height(8.dp))
                        Text(
                            text = "Run the voice-code backend on your computer. " +
                                    "A QR code will be displayed that contains your API key. " +
                                    "Scan it or copy the key manually.",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                }
            }
        }

        // Clear API key confirmation dialog
        if (showClearDialog) {
            AlertDialog(
                onDismissRequest = { showClearDialog = false },
                icon = { Icon(Icons.Default.Warning, contentDescription = null) },
                title = { Text("Clear API Key?") },
                text = {
                    Text("You will need to re-enter or scan the API key to use VoiceCode again.")
                },
                confirmButton = {
                    TextButton(
                        onClick = {
                            onClearApiKey()
                            apiKeyInput = ""
                            showClearDialog = false
                        }
                    ) {
                        Text("Clear")
                    }
                },
                dismissButton = {
                    TextButton(onClick = { showClearDialog = false }) {
                        Text("Cancel")
                    }
                }
            )
        }
    }
}

/**
 * Card showing API key configuration status.
 */
@Composable
private fun ApiKeyStatusCard(
    hasApiKey: Boolean,
    modifier: Modifier = Modifier
) {
    Card(
        modifier = modifier,
        colors = CardDefaults.cardColors(
            containerColor = if (hasApiKey) {
                MaterialTheme.colorScheme.primaryContainer
            } else {
                MaterialTheme.colorScheme.errorContainer
            }
        )
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(16.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Icon(
                imageVector = if (hasApiKey) Icons.Default.CheckCircle else Icons.Default.Error,
                contentDescription = null,
                tint = if (hasApiKey) {
                    MaterialTheme.colorScheme.onPrimaryContainer
                } else {
                    MaterialTheme.colorScheme.onErrorContainer
                },
                modifier = Modifier.size(32.dp)
            )
            Spacer(modifier = Modifier.width(16.dp))
            Column {
                Text(
                    text = if (hasApiKey) "API Key Configured" else "API Key Required",
                    style = MaterialTheme.typography.titleMedium,
                    color = if (hasApiKey) {
                        MaterialTheme.colorScheme.onPrimaryContainer
                    } else {
                        MaterialTheme.colorScheme.onErrorContainer
                    }
                )
                Text(
                    text = if (hasApiKey) {
                        "Your device is ready to connect"
                    } else {
                        "Scan a QR code or enter key manually"
                    },
                    style = MaterialTheme.typography.bodySmall,
                    color = if (hasApiKey) {
                        MaterialTheme.colorScheme.onPrimaryContainer.copy(alpha = 0.8f)
                    } else {
                        MaterialTheme.colorScheme.onErrorContainer.copy(alpha = 0.8f)
                    }
                )
            }
        }
    }
}

/**
 * Validates API key format.
 * Expected format: "untethered-" followed by 32 hex characters (43 total).
 */
private fun isValidApiKeyFormat(key: String): Boolean {
    return key.startsWith("untethered-") && key.length == 43
}
