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
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.unit.dp

/**
 * Settings screen for app configuration.
 * Equivalent to iOS SettingsView.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(
    serverUrl: String,
    serverPort: String,
    hasApiKey: Boolean,
    selectedVoiceName: String?,
    notificationsEnabled: Boolean,
    silentModeRespected: Boolean,
    onBack: () -> Unit,
    onServerUrlChange: (String) -> Unit,
    onServerPortChange: (String) -> Unit,
    onApiKeyClick: () -> Unit,
    onVoiceSettingsClick: () -> Unit,
    onNotificationsToggle: (Boolean) -> Unit,
    onSilentModeToggle: (Boolean) -> Unit,
    onDebugLogsClick: () -> Unit,
    onAboutClick: () -> Unit,
    modifier: Modifier = Modifier
) {
    Scaffold(
        modifier = modifier.fillMaxSize(),
        topBar = {
            TopAppBar(
                title = { Text("Settings") },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
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
        ) {
            // Server Configuration Section
            SettingsSectionHeader("Server Configuration")

            SettingsTextField(
                label = "Server URL",
                value = serverUrl,
                onValueChange = onServerUrlChange,
                placeholder = "localhost"
            )

            SettingsTextField(
                label = "Server Port",
                value = serverPort,
                onValueChange = onServerPortChange,
                placeholder = "9999"
            )

            HorizontalDivider()

            // Authentication Section
            SettingsSectionHeader("Authentication")

            SettingsClickableRow(
                icon = Icons.Default.Key,
                title = "API Key",
                subtitle = if (hasApiKey) "Configured" else "Not configured",
                onClick = onApiKeyClick
            )

            HorizontalDivider()

            // Voice Settings Section
            SettingsSectionHeader("Voice")

            SettingsClickableRow(
                icon = Icons.Default.RecordVoiceOver,
                title = "Voice Selection",
                subtitle = selectedVoiceName ?: "System Default",
                onClick = onVoiceSettingsClick
            )

            SettingsToggleRow(
                icon = Icons.Default.VolumeOff,
                title = "Respect Silent Mode",
                subtitle = "Mute speech when device is silent",
                checked = silentModeRespected,
                onCheckedChange = onSilentModeToggle
            )

            HorizontalDivider()

            // Notifications Section
            SettingsSectionHeader("Notifications")

            SettingsToggleRow(
                icon = Icons.Default.Notifications,
                title = "Response Notifications",
                subtitle = "Notify when Claude responds",
                checked = notificationsEnabled,
                onCheckedChange = onNotificationsToggle
            )

            HorizontalDivider()

            // Developer Section
            SettingsSectionHeader("Developer")

            SettingsClickableRow(
                icon = Icons.Default.BugReport,
                title = "Debug Logs",
                subtitle = "View diagnostic logs",
                onClick = onDebugLogsClick
            )

            HorizontalDivider()

            // About Section
            SettingsSectionHeader("About")

            SettingsClickableRow(
                icon = Icons.Default.Info,
                title = "About VoiceCode",
                subtitle = "Version, licenses, and more",
                onClick = onAboutClick
            )
        }
    }
}

@Composable
fun SettingsSectionHeader(
    title: String,
    modifier: Modifier = Modifier
) {
    Text(
        text = title,
        style = MaterialTheme.typography.titleSmall,
        color = MaterialTheme.colorScheme.primary,
        modifier = modifier.padding(horizontal = 16.dp, vertical = 12.dp)
    )
}

@Composable
fun SettingsTextField(
    label: String,
    value: String,
    onValueChange: (String) -> Unit,
    placeholder: String,
    modifier: Modifier = Modifier
) {
    OutlinedTextField(
        value = value,
        onValueChange = onValueChange,
        label = { Text(label) },
        placeholder = { Text(placeholder) },
        singleLine = true,
        modifier = modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 8.dp)
    )
}

@Composable
fun SettingsClickableRow(
    icon: ImageVector,
    title: String,
    subtitle: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier
) {
    Row(
        modifier = modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(16.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Icon(
            imageVector = icon,
            contentDescription = null,
            tint = MaterialTheme.colorScheme.onSurfaceVariant
        )

        Column(
            modifier = Modifier
                .weight(1f)
                .padding(horizontal = 16.dp)
        ) {
            Text(
                text = title,
                style = MaterialTheme.typography.bodyLarge
            )
            Text(
                text = subtitle,
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }

        Icon(
            imageVector = Icons.Default.ChevronRight,
            contentDescription = null,
            tint = MaterialTheme.colorScheme.onSurfaceVariant
        )
    }
}

@Composable
fun SettingsToggleRow(
    icon: ImageVector,
    title: String,
    subtitle: String,
    checked: Boolean,
    onCheckedChange: (Boolean) -> Unit,
    modifier: Modifier = Modifier
) {
    Row(
        modifier = modifier
            .fillMaxWidth()
            .clickable { onCheckedChange(!checked) }
            .padding(16.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Icon(
            imageVector = icon,
            contentDescription = null,
            tint = MaterialTheme.colorScheme.onSurfaceVariant
        )

        Column(
            modifier = Modifier
                .weight(1f)
                .padding(horizontal = 16.dp)
        ) {
            Text(
                text = title,
                style = MaterialTheme.typography.bodyLarge
            )
            Text(
                text = subtitle,
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }

        Switch(
            checked = checked,
            onCheckedChange = onCheckedChange
        )
    }
}

/**
 * About screen with app information.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AboutScreen(
    versionName: String,
    versionCode: Int,
    onBack: () -> Unit,
    modifier: Modifier = Modifier
) {
    Scaffold(
        modifier = modifier.fillMaxSize(),
        topBar = {
            TopAppBar(
                title = { Text("About") },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                    }
                }
            )
        }
    ) { paddingValues ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(paddingValues)
                .padding(16.dp),
            horizontalAlignment = Alignment.CenterHorizontally
        ) {
            Spacer(modifier = Modifier.height(32.dp))

            // App icon placeholder
            Surface(
                modifier = Modifier.size(96.dp),
                shape = MaterialTheme.shapes.large,
                color = MaterialTheme.colorScheme.primaryContainer
            ) {
                Box(contentAlignment = Alignment.Center) {
                    Icon(
                        imageVector = Icons.Default.Mic,
                        contentDescription = null,
                        modifier = Modifier.size(48.dp),
                        tint = MaterialTheme.colorScheme.onPrimaryContainer
                    )
                }
            }

            Spacer(modifier = Modifier.height(24.dp))

            Text(
                text = "VoiceCode",
                style = MaterialTheme.typography.headlineMedium
            )

            Text(
                text = "Version $versionName ($versionCode)",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )

            Spacer(modifier = Modifier.height(32.dp))

            Text(
                text = "Voice-controlled interface for Claude Code",
                style = MaterialTheme.typography.bodyLarge,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )

            Spacer(modifier = Modifier.weight(1f))

            Text(
                text = "910 Labs",
                style = MaterialTheme.typography.labelMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
    }
}
