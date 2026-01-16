package dev.labs910.voicecode.presentation.ui.screens

import android.speech.tts.Voice
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import java.util.Locale

/**
 * Voice settings screen for selecting TTS voice.
 * Equivalent to iOS voice selection UI.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun VoiceSettingsScreen(
    availableVoices: List<Voice>,
    selectedVoice: Voice?,
    speechRate: Float,
    pitch: Float,
    onVoiceSelected: (Voice) -> Unit,
    onSpeechRateChange: (Float) -> Unit,
    onPitchChange: (Float) -> Unit,
    onTestVoice: () -> Unit,
    onBack: () -> Unit,
    modifier: Modifier = Modifier
) {
    val groupedVoices = remember(availableVoices) {
        availableVoices
            .filter { !it.isNetworkConnectionRequired || it.features.contains("networkTts") }
            .groupBy { it.locale.displayLanguage }
            .toSortedMap()
    }

    Scaffold(
        modifier = modifier.fillMaxSize(),
        topBar = {
            TopAppBar(
                title = { Text("Voice Settings") },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                    }
                },
                actions = {
                    TextButton(onClick = onTestVoice) {
                        Text("Test")
                    }
                }
            )
        }
    ) { paddingValues ->
        LazyColumn(
            modifier = Modifier
                .fillMaxSize()
                .padding(paddingValues),
            contentPadding = PaddingValues(bottom = 16.dp)
        ) {
            // Speech Rate Section
            item {
                SettingsSectionHeader("Speech Rate")
            }

            item {
                SliderSetting(
                    value = speechRate,
                    onValueChange = onSpeechRateChange,
                    valueRange = 0.5f..2.0f,
                    label = "Speed: ${String.format(Locale.US, "%.1fx", speechRate)}"
                )
            }

            // Pitch Section
            item {
                SettingsSectionHeader("Pitch")
            }

            item {
                SliderSetting(
                    value = pitch,
                    onValueChange = onPitchChange,
                    valueRange = 0.5f..2.0f,
                    label = "Pitch: ${String.format(Locale.US, "%.1f", pitch)}"
                )
            }

            item {
                HorizontalDivider(modifier = Modifier.padding(vertical = 8.dp))
            }

            // Voice Selection Section
            item {
                SettingsSectionHeader("Voice")
            }

            // System Default option
            item {
                VoiceRow(
                    name = "System Default",
                    locale = null,
                    isSelected = selectedVoice == null,
                    onClick = { /* Clear selection to use system default */ }
                )
            }

            // Grouped voices by language
            groupedVoices.forEach { (language, voices) ->
                item {
                    Text(
                        text = language,
                        style = MaterialTheme.typography.labelMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp)
                    )
                }

                items(voices.sortedBy { it.name }) { voice ->
                    VoiceRow(
                        name = voice.name.substringAfter("#").substringAfter("-"),
                        locale = voice.locale,
                        isSelected = selectedVoice?.name == voice.name,
                        isNetworkVoice = voice.isNetworkConnectionRequired,
                        onClick = { onVoiceSelected(voice) }
                    )
                }
            }

            // Empty state
            if (groupedVoices.isEmpty()) {
                item {
                    Column(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(32.dp),
                        horizontalAlignment = Alignment.CenterHorizontally
                    ) {
                        Icon(
                            imageVector = Icons.Default.VoiceOverOff,
                            contentDescription = null,
                            modifier = Modifier.size(48.dp),
                            tint = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                        Spacer(modifier = Modifier.height(16.dp))
                        Text(
                            text = "No voices available",
                            style = MaterialTheme.typography.bodyLarge,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                        Text(
                            text = "Check your device settings",
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun SliderSetting(
    value: Float,
    onValueChange: (Float) -> Unit,
    valueRange: ClosedFloatingPointRange<Float>,
    label: String,
    modifier: Modifier = Modifier
) {
    Column(
        modifier = modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 8.dp)
    ) {
        Text(
            text = label,
            style = MaterialTheme.typography.bodyMedium
        )
        Slider(
            value = value,
            onValueChange = onValueChange,
            valueRange = valueRange,
            steps = 5
        )
    }
}

@Composable
private fun VoiceRow(
    name: String,
    locale: Locale?,
    isSelected: Boolean,
    isNetworkVoice: Boolean = false,
    onClick: () -> Unit,
    modifier: Modifier = Modifier
) {
    Row(
        modifier = modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(horizontal = 16.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Column(
            modifier = Modifier.weight(1f)
        ) {
            Text(
                text = name,
                style = MaterialTheme.typography.bodyLarge
            )
            if (locale != null) {
                Row(
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Text(
                        text = locale.displayName,
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                    if (isNetworkVoice) {
                        Spacer(modifier = Modifier.width(4.dp))
                        Icon(
                            imageVector = Icons.Default.Cloud,
                            contentDescription = "Network voice",
                            modifier = Modifier.size(12.dp),
                            tint = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                }
            }
        }

        if (isSelected) {
            Icon(
                imageVector = Icons.Default.Check,
                contentDescription = "Selected",
                tint = MaterialTheme.colorScheme.primary
            )
        }
    }
}

/**
 * Data class representing voice info for UI display.
 */
data class VoiceInfo(
    val id: String,
    val name: String,
    val locale: Locale,
    val isNetworkVoice: Boolean
)
