package dev.labs910.voicecode.presentation.ui.screens

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Debug logs screen for viewing app diagnostic output.
 * Equivalent to iOS DebugLogsView.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DebugLogsScreen(
    onBack: () -> Unit,
    modifier: Modifier = Modifier
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var logs by remember { mutableStateOf<List<String>>(emptyList()) }
    var isLoading by remember { mutableStateOf(true) }
    var showCopyConfirmation by remember { mutableStateOf(false) }
    var selectedSource by remember { mutableStateOf(LogSource.APP) }
    val listState = rememberLazyListState()

    // Load logs when source changes
    LaunchedEffect(selectedSource) {
        isLoading = true
        logs = when (selectedSource) {
            LogSource.APP -> loadAppLogs()
            LogSource.SYSTEM -> loadSystemLogs()
            LogSource.WEBSOCKET -> loadWebSocketLogs()
        }
        isLoading = false
    }

    Scaffold(
        modifier = modifier.fillMaxSize(),
        topBar = {
            TopAppBar(
                title = { Text("Debug Logs") },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                    }
                },
                actions = {
                    IconButton(
                        onClick = {
                            scope.launch {
                                isLoading = true
                                logs = when (selectedSource) {
                                    LogSource.APP -> loadAppLogs()
                                    LogSource.SYSTEM -> loadSystemLogs()
                                    LogSource.WEBSOCKET -> loadWebSocketLogs()
                                }
                                isLoading = false
                            }
                        }
                    ) {
                        Icon(Icons.Default.Refresh, contentDescription = "Refresh")
                    }
                    IconButton(
                        onClick = {
                            copyToClipboard(context, logs.joinToString("\n"))
                            showCopyConfirmation = true
                        }
                    ) {
                        Icon(Icons.Default.ContentCopy, contentDescription = "Copy")
                    }
                }
            )
        }
    ) { paddingValues ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(paddingValues)
        ) {
            // Log source selector
            SingleChoiceSegmentedButtonRow(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp, vertical = 8.dp)
            ) {
                LogSource.entries.forEachIndexed { index, source ->
                    SegmentedButton(
                        selected = selectedSource == source,
                        onClick = { selectedSource = source },
                        shape = SegmentedButtonDefaults.itemShape(
                            index = index,
                            count = LogSource.entries.size
                        )
                    ) {
                        Text(
                            text = source.displayName,
                            maxLines = 1,
                            style = MaterialTheme.typography.labelSmall
                        )
                    }
                }
            }

            // Log count
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp, vertical = 4.dp),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text(
                    text = "${logs.size} log entries",
                    style = MaterialTheme.typography.labelMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )

                if (logs.isNotEmpty()) {
                    TextButton(
                        onClick = {
                            scope.launch {
                                listState.animateScrollToItem(logs.size - 1)
                            }
                        }
                    ) {
                        Text("Jump to End")
                    }
                }
            }

            // Logs display
            if (isLoading) {
                Box(
                    modifier = Modifier
                        .fillMaxSize()
                        .padding(16.dp),
                    contentAlignment = Alignment.Center
                ) {
                    CircularProgressIndicator()
                }
            } else if (logs.isEmpty()) {
                Box(
                    modifier = Modifier
                        .fillMaxSize()
                        .padding(16.dp),
                    contentAlignment = Alignment.Center
                ) {
                    Column(
                        horizontalAlignment = Alignment.CenterHorizontally
                    ) {
                        Icon(
                            imageVector = Icons.Default.Description,
                            contentDescription = null,
                            modifier = Modifier.size(48.dp),
                            tint = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                        Spacer(modifier = Modifier.height(16.dp))
                        Text(
                            text = "No logs available",
                            style = MaterialTheme.typography.titleMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                        Text(
                            text = "Logs will appear here as the app runs",
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                }
            } else {
                LazyColumn(
                    state = listState,
                    modifier = Modifier
                        .fillMaxSize()
                        .padding(horizontal = 8.dp),
                    contentPadding = PaddingValues(bottom = 16.dp)
                ) {
                    items(logs) { line ->
                        LogLine(line = line)
                    }
                }
            }
        }
    }

    // Copy confirmation snackbar
    if (showCopyConfirmation) {
        LaunchedEffect(Unit) {
            kotlinx.coroutines.delay(2000)
            showCopyConfirmation = false
        }

        Box(
            modifier = Modifier
                .fillMaxSize()
                .padding(16.dp),
            contentAlignment = Alignment.BottomCenter
        ) {
            Surface(
                color = MaterialTheme.colorScheme.inverseSurface,
                shape = MaterialTheme.shapes.medium
            ) {
                Text(
                    text = "Logs copied to clipboard",
                    modifier = Modifier.padding(horizontal = 16.dp, vertical = 12.dp),
                    color = MaterialTheme.colorScheme.inverseOnSurface
                )
            }
        }
    }
}

@Composable
private fun LogLine(
    line: String,
    modifier: Modifier = Modifier
) {
    val (level, color) = getLogLevelColor(line)

    Text(
        text = line,
        modifier = modifier
            .fillMaxWidth()
            .horizontalScroll(rememberScrollState())
            .padding(vertical = 2.dp, horizontal = 8.dp),
        style = MaterialTheme.typography.bodySmall.copy(
            fontFamily = FontFamily.Monospace,
            fontSize = 10.sp,
            lineHeight = 14.sp
        ),
        color = color
    )
}

@Composable
private fun getLogLevelColor(line: String): Pair<String, androidx.compose.ui.graphics.Color> {
    return when {
        line.contains(" E/") || line.contains(" E ") || line.contains("ERROR") ->
            "ERROR" to MaterialTheme.colorScheme.error
        line.contains(" W/") || line.contains(" W ") || line.contains("WARN") ->
            "WARN" to MaterialTheme.colorScheme.tertiary
        line.contains(" D/") || line.contains(" D ") || line.contains("DEBUG") ->
            "DEBUG" to MaterialTheme.colorScheme.onSurfaceVariant
        line.contains(" I/") || line.contains(" I ") || line.contains("INFO") ->
            "INFO" to MaterialTheme.colorScheme.onSurface
        else -> "OTHER" to MaterialTheme.colorScheme.onSurfaceVariant
    }
}

private enum class LogSource(val displayName: String) {
    APP("App Logs"),
    SYSTEM("System"),
    WEBSOCKET("WebSocket")
}

private suspend fun loadAppLogs(): List<String> = withContext(Dispatchers.IO) {
    try {
        val process = Runtime.getRuntime().exec(
            arrayOf("logcat", "-d", "-t", "500", "-v", "time", "VoiceCode:*", "*:S")
        )
        process.inputStream.bufferedReader().readLines()
    } catch (e: Exception) {
        listOf("Failed to load logs: ${e.message}")
    }
}

private suspend fun loadSystemLogs(): List<String> = withContext(Dispatchers.IO) {
    try {
        val process = Runtime.getRuntime().exec(
            arrayOf("logcat", "-d", "-t", "1000", "-v", "time")
        )
        process.inputStream.bufferedReader().readLines()
    } catch (e: Exception) {
        listOf("Failed to load system logs: ${e.message}")
    }
}

private suspend fun loadWebSocketLogs(): List<String> = withContext(Dispatchers.IO) {
    try {
        val process = Runtime.getRuntime().exec(
            arrayOf("logcat", "-d", "-t", "500", "-v", "time", "VoiceCodeClient:*", "OkHttp:*", "*:S")
        )
        process.inputStream.bufferedReader().readLines()
    } catch (e: Exception) {
        listOf("Failed to load WebSocket logs: ${e.message}")
    }
}

private fun copyToClipboard(context: Context, text: String) {
    val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
    val clip = ClipData.newPlainText("Debug Logs", text)
    clipboard.setPrimaryClip(clip)
}
