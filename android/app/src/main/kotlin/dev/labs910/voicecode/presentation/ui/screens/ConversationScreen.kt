package dev.labs910.voicecode.presentation.ui.screens

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import dev.labs910.voicecode.domain.model.Message
import dev.labs910.voicecode.domain.model.MessageRole
import dev.labs910.voicecode.domain.model.MessageStatus
import dev.labs910.voicecode.domain.model.Session
import kotlinx.coroutines.launch
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle

/**
 * Conversation screen showing messages for a session.
 * Equivalent to iOS ConversationView.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ConversationScreen(
    session: Session,
    messages: List<Message>,
    isLoading: Boolean,
    isSessionLocked: Boolean,
    onBack: () -> Unit,
    onSendMessage: (String) -> Unit,
    onVoiceInput: () -> Unit,
    onCompact: () -> Unit,
    onSessionInfo: () -> Unit,
    modifier: Modifier = Modifier
) {
    var inputText by remember { mutableStateOf("") }
    var showCompactDialog by remember { mutableStateOf(false) }
    val listState = rememberLazyListState()
    val scope = rememberCoroutineScope()

    // Auto-scroll to bottom when new messages arrive
    LaunchedEffect(messages.size) {
        if (messages.isNotEmpty()) {
            listState.animateScrollToItem(messages.size - 1)
        }
    }

    Scaffold(
        modifier = modifier.fillMaxSize(),
        topBar = {
            TopAppBar(
                title = {
                    Column {
                        Text(
                            text = session.displayName,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis
                        )
                        if (session.workingDirectory != null) {
                            Text(
                                text = session.workingDirectory,
                                style = MaterialTheme.typography.labelSmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis
                            )
                        }
                    }
                },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                    }
                },
                actions = {
                    IconButton(onClick = onSessionInfo) {
                        Icon(Icons.Default.Info, contentDescription = "Session Info")
                    }
                    IconButton(onClick = { showCompactDialog = true }) {
                        Icon(Icons.Default.Compress, contentDescription = "Compact Session")
                    }
                }
            )
        },
        bottomBar = {
            MessageInputBar(
                text = inputText,
                onTextChange = { inputText = it },
                onSend = {
                    if (inputText.isNotBlank()) {
                        onSendMessage(inputText)
                        inputText = ""
                    }
                },
                onVoice = onVoiceInput,
                enabled = !isSessionLocked,
                isLocked = isSessionLocked
            )
        }
    ) { paddingValues ->
        if (isLoading && messages.isEmpty()) {
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(paddingValues),
                contentAlignment = Alignment.Center
            ) {
                CircularProgressIndicator()
            }
        } else if (messages.isEmpty()) {
            EmptyConversationView(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(paddingValues)
            )
        } else {
            LazyColumn(
                state = listState,
                modifier = Modifier
                    .fillMaxSize()
                    .padding(paddingValues),
                contentPadding = PaddingValues(16.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp)
            ) {
                items(messages, key = { it.id }) { message ->
                    MessageBubble(message = message)
                }

                // Show locked indicator at bottom
                if (isSessionLocked) {
                    item {
                        SessionLockedIndicator()
                    }
                }
            }
        }
    }

    // Compaction confirmation dialog
    if (showCompactDialog) {
        CompactSessionDialog(
            sessionName = session.displayName,
            onConfirm = {
                onCompact()
                showCompactDialog = false
            },
            onDismiss = { showCompactDialog = false }
        )
    }
}

@Composable
fun MessageBubble(
    message: Message,
    modifier: Modifier = Modifier
) {
    val isUser = message.role == MessageRole.USER
    val alignment = if (isUser) Alignment.End else Alignment.Start
    val bubbleColor = if (isUser) {
        MaterialTheme.colorScheme.primaryContainer
    } else {
        MaterialTheme.colorScheme.surfaceVariant
    }
    val textColor = if (isUser) {
        MaterialTheme.colorScheme.onPrimaryContainer
    } else {
        MaterialTheme.colorScheme.onSurfaceVariant
    }

    Column(
        modifier = modifier.fillMaxWidth(),
        horizontalAlignment = alignment
    ) {
        Surface(
            shape = MaterialTheme.shapes.medium,
            color = bubbleColor,
            modifier = Modifier.widthIn(max = 320.dp)
        ) {
            Column(
                modifier = Modifier.padding(12.dp)
            ) {
                Text(
                    text = message.displayText(),
                    style = MaterialTheme.typography.bodyMedium,
                    color = textColor
                )

                Row(
                    modifier = Modifier.padding(top = 4.dp),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    // Timestamp
                    Text(
                        text = formatMessageTime(message.timestamp),
                        style = MaterialTheme.typography.labelSmall,
                        color = textColor.copy(alpha = 0.7f)
                    )

                    // Status indicator for user messages
                    if (isUser) {
                        when (message.status) {
                            MessageStatus.SENDING -> {
                                CircularProgressIndicator(
                                    modifier = Modifier.size(12.dp),
                                    strokeWidth = 1.dp
                                )
                            }
                            MessageStatus.CONFIRMED -> {
                                Icon(
                                    imageVector = Icons.Default.Check,
                                    contentDescription = "Sent",
                                    modifier = Modifier.size(12.dp),
                                    tint = textColor.copy(alpha = 0.7f)
                                )
                            }
                            MessageStatus.ERROR -> {
                                Icon(
                                    imageVector = Icons.Default.Error,
                                    contentDescription = "Failed",
                                    modifier = Modifier.size(12.dp),
                                    tint = MaterialTheme.colorScheme.error
                                )
                            }
                        }
                    }

                    // Token usage for assistant messages
                    if (!isUser && message.usage != null) {
                        Text(
                            text = "${message.usage.totalTokens} tokens",
                            style = MaterialTheme.typography.labelSmall,
                            color = textColor.copy(alpha = 0.7f)
                        )
                    }
                }
            }
        }
    }
}

@Composable
fun MessageInputBar(
    text: String,
    onTextChange: (String) -> Unit,
    onSend: () -> Unit,
    onVoice: () -> Unit,
    enabled: Boolean,
    isLocked: Boolean,
    modifier: Modifier = Modifier
) {
    Surface(
        modifier = modifier.fillMaxWidth(),
        tonalElevation = 3.dp
    ) {
        Row(
            modifier = Modifier
                .padding(8.dp)
                .fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            // Voice input button
            IconButton(
                onClick = onVoice,
                enabled = enabled
            ) {
                Icon(
                    imageVector = Icons.Default.Mic,
                    contentDescription = "Voice Input",
                    tint = if (enabled) {
                        MaterialTheme.colorScheme.primary
                    } else {
                        MaterialTheme.colorScheme.onSurface.copy(alpha = 0.38f)
                    }
                )
            }

            // Text input
            OutlinedTextField(
                value = text,
                onValueChange = onTextChange,
                placeholder = {
                    Text(
                        if (isLocked) "Session is processing..." else "Type a message..."
                    )
                },
                enabled = enabled,
                modifier = Modifier.weight(1f),
                maxLines = 4,
                shape = MaterialTheme.shapes.large
            )

            // Send button
            IconButton(
                onClick = onSend,
                enabled = enabled && text.isNotBlank()
            ) {
                Icon(
                    imageVector = Icons.AutoMirrored.Filled.Send,
                    contentDescription = "Send",
                    tint = if (enabled && text.isNotBlank()) {
                        MaterialTheme.colorScheme.primary
                    } else {
                        MaterialTheme.colorScheme.onSurface.copy(alpha = 0.38f)
                    }
                )
            }
        }
    }
}

@Composable
fun SessionLockedIndicator(
    modifier: Modifier = Modifier
) {
    Card(
        modifier = modifier.fillMaxWidth(),
        colors = CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.tertiaryContainer
        )
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(12.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.Center
        ) {
            CircularProgressIndicator(
                modifier = Modifier.size(16.dp),
                strokeWidth = 2.dp,
                color = MaterialTheme.colorScheme.onTertiaryContainer
            )
            Spacer(modifier = Modifier.width(8.dp))
            Text(
                text = "Claude is thinking...",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onTertiaryContainer
            )
        }
    }
}

@Composable
fun EmptyConversationView(
    modifier: Modifier = Modifier
) {
    Column(
        modifier = modifier,
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        Icon(
            imageVector = Icons.Default.ChatBubbleOutline,
            contentDescription = null,
            modifier = Modifier.size(48.dp),
            tint = MaterialTheme.colorScheme.onSurfaceVariant
        )

        Spacer(modifier = Modifier.height(16.dp))

        Text(
            text = "Start a conversation",
            style = MaterialTheme.typography.titleMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )

        Spacer(modifier = Modifier.height(8.dp))

        Text(
            text = "Use voice or text to talk with Claude",
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
    }
}

private fun formatMessageTime(instant: java.time.Instant): String {
    val formatter = DateTimeFormatter.ofLocalizedTime(FormatStyle.SHORT)
        .withZone(ZoneId.systemDefault())
    return formatter.format(instant)
}

/**
 * Confirmation dialog for session compaction.
 * Shows a warning that this operation cannot be undone.
 */
@Composable
fun CompactSessionDialog(
    sessionName: String,
    onConfirm: () -> Unit,
    onDismiss: () -> Unit
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        icon = {
            Icon(
                imageVector = Icons.Default.Compress,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.primary
            )
        },
        title = {
            Text("Compact Session?")
        },
        text = {
            Column(
                verticalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                Text(
                    text = "Compacting \"$sessionName\" will summarize the conversation history to reduce context usage."
                )
                Text(
                    text = "This operation cannot be undone.",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.error
                )
            }
        },
        confirmButton = {
            Button(
                onClick = onConfirm
            ) {
                Text("Compact")
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) {
                Text("Cancel")
            }
        }
    )
}
