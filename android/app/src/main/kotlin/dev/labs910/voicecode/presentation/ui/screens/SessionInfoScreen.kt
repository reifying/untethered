package dev.labs910.voicecode.presentation.ui.screens

import androidx.compose.foundation.clickable
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
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import dev.labs910.voicecode.domain.model.Session
import java.text.SimpleDateFormat
import java.util.*

/**
 * Session info screen with priority queue management.
 * Equivalent to iOS SessionInfoView.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SessionInfoScreen(
    session: Session,
    priorityQueueEnabled: Boolean,
    onBack: () -> Unit,
    onAddToPriorityQueue: (Int) -> Unit,
    onRemoveFromPriorityQueue: () -> Unit,
    onChangePriority: (Int) -> Unit,
    modifier: Modifier = Modifier
) {
    var showCopySnackbar by remember { mutableStateOf(false) }
    var copyMessage by remember { mutableStateOf("") }
    val snackbarHostState = remember { SnackbarHostState() }

    LaunchedEffect(showCopySnackbar) {
        if (showCopySnackbar) {
            snackbarHostState.showSnackbar(
                message = copyMessage,
                duration = SnackbarDuration.Short
            )
            showCopySnackbar = false
        }
    }

    Scaffold(
        modifier = modifier.fillMaxSize(),
        topBar = {
            TopAppBar(
                title = { Text("Session Info") },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                    }
                }
            )
        },
        snackbarHost = { SnackbarHost(snackbarHostState) }
    ) { paddingValues ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(paddingValues)
                .verticalScroll(rememberScrollState())
        ) {
            // Session Information Section
            SettingsSectionHeader("Session Information")

            InfoRow(
                label = "Name",
                value = session.displayName,
                onCopy = {
                    copyMessage = "Name copied"
                    showCopySnackbar = true
                }
            )

            session.workingDirectory?.let { dir ->
                InfoRow(
                    label = "Working Directory",
                    value = dir,
                    onCopy = {
                        copyMessage = "Directory copied"
                        showCopySnackbar = true
                    }
                )
            }

            InfoRow(
                label = "Session ID",
                value = session.id,
                onCopy = {
                    copyMessage = "Session ID copied"
                    showCopySnackbar = true
                }
            )

            HorizontalDivider()

            // Priority Queue Section (only shown if enabled)
            if (priorityQueueEnabled) {
                SettingsSectionHeader("Priority Queue")

                if (session.isInPriorityQueue) {
                    // Priority Picker
                    PriorityPicker(
                        currentPriority = session.priority,
                        onPriorityChange = onChangePriority
                    )

                    // Priority Order (read-only)
                    ReadOnlyInfoRow(
                        label = "Order",
                        value = String.format("%.1f", session.priorityOrder)
                    )

                    // Queued Timestamp (read-only)
                    session.priorityQueuedAt?.let { queuedAt ->
                        val dateFormat = SimpleDateFormat("MMM d, h:mm a", Locale.getDefault())
                        ReadOnlyInfoRow(
                            label = "Queued",
                            value = dateFormat.format(Date.from(queuedAt))
                        )
                    }

                    Spacer(modifier = Modifier.height(8.dp))

                    // Remove from queue button
                    Button(
                        onClick = onRemoveFromPriorityQueue,
                        colors = ButtonDefaults.buttonColors(
                            containerColor = MaterialTheme.colorScheme.errorContainer,
                            contentColor = MaterialTheme.colorScheme.onErrorContainer
                        ),
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(horizontal = 16.dp)
                    ) {
                        Icon(
                            imageVector = Icons.Default.StarBorder,
                            contentDescription = null,
                            modifier = Modifier.size(18.dp)
                        )
                        Spacer(modifier = Modifier.width(8.dp))
                        Text("Remove from Priority Queue")
                    }

                    Text(
                        text = "Change priority to adjust position in queue. Lower priority number = higher importance.",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp)
                    )
                } else {
                    // Add to queue button when not in queue
                    Button(
                        onClick = { onAddToPriorityQueue(10) }, // Default to Low priority
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(horizontal = 16.dp)
                    ) {
                        Icon(
                            imageVector = Icons.Default.Star,
                            contentDescription = null,
                            modifier = Modifier.size(18.dp)
                        )
                        Spacer(modifier = Modifier.width(8.dp))
                        Text("Add to Priority Queue")
                    }

                    Text(
                        text = "Add to priority queue to track this session with custom priority ordering.",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp)
                    )
                }

                HorizontalDivider()
            }

            // Session Statistics Section
            SettingsSectionHeader("Statistics")

            ReadOnlyInfoRow(
                label = "Messages",
                value = session.messageCount.toString()
            )

            ReadOnlyInfoRow(
                label = "Unread",
                value = session.unreadCount.toString()
            )

            val dateFormat = SimpleDateFormat("MMM d, yyyy h:mm a", Locale.getDefault())
            ReadOnlyInfoRow(
                label = "Last Modified",
                value = dateFormat.format(Date.from(session.lastModified))
            )

            session.preview?.let { preview ->
                ReadOnlyInfoRow(
                    label = "Preview",
                    value = preview
                )
            }
        }
    }
}

/**
 * Priority picker using segmented buttons.
 */
@Composable
fun PriorityPicker(
    currentPriority: Int,
    onPriorityChange: (Int) -> Unit,
    modifier: Modifier = Modifier
) {
    Column(modifier = modifier.padding(16.dp)) {
        Text(
            text = "Priority",
            style = MaterialTheme.typography.labelMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
        Spacer(modifier = Modifier.height(8.dp))

        SingleChoiceSegmentedButtonRow(
            modifier = Modifier.fillMaxWidth()
        ) {
            SegmentedButton(
                selected = currentPriority == 1,
                onClick = { onPriorityChange(1) },
                shape = SegmentedButtonDefaults.itemShape(index = 0, count = 3)
            ) {
                Text("High (1)")
            }
            SegmentedButton(
                selected = currentPriority == 5,
                onClick = { onPriorityChange(5) },
                shape = SegmentedButtonDefaults.itemShape(index = 1, count = 3)
            ) {
                Text("Medium (5)")
            }
            SegmentedButton(
                selected = currentPriority == 10,
                onClick = { onPriorityChange(10) },
                shape = SegmentedButtonDefaults.itemShape(index = 2, count = 3)
            ) {
                Text("Low (10)")
            }
        }
    }
}

/**
 * Copyable info row.
 */
@Composable
fun InfoRow(
    label: String,
    value: String,
    onCopy: () -> Unit,
    modifier: Modifier = Modifier
) {
    Row(
        modifier = modifier
            .fillMaxWidth()
            .clickable(onClick = onCopy)
            .padding(16.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Column(
            modifier = Modifier.weight(1f)
        ) {
            Text(
                text = label,
                style = MaterialTheme.typography.labelMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
            Spacer(modifier = Modifier.height(4.dp))
            Text(
                text = value,
                style = MaterialTheme.typography.bodyLarge,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis
            )
        }
        Icon(
            imageVector = Icons.Default.ContentCopy,
            contentDescription = "Copy",
            tint = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.size(20.dp)
        )
    }
}

/**
 * Read-only info row (no copy action).
 */
@Composable
fun ReadOnlyInfoRow(
    label: String,
    value: String,
    modifier: Modifier = Modifier
) {
    Row(
        modifier = modifier
            .fillMaxWidth()
            .padding(16.dp),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically
    ) {
        Text(
            text = label,
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
        Text(
            text = value,
            style = MaterialTheme.typography.bodyMedium,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.widthIn(max = 200.dp)
        )
    }
}
