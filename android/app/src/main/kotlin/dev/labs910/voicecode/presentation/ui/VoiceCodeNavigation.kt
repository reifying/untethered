package dev.labs910.voicecode.presentation.ui

import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import dev.labs910.voicecode.domain.model.Command
import dev.labs910.voicecode.domain.model.CommandExecution
import dev.labs910.voicecode.domain.model.Message
import dev.labs910.voicecode.domain.model.Session
import dev.labs910.voicecode.presentation.ui.screens.*

/**
 * Navigation destinations for the app.
 */
sealed class Screen {
    data object SessionList : Screen()
    data class Conversation(val sessionId: String) : Screen()
    data object Settings : Screen()
    data object ApiKey : Screen()
    data object About : Screen()
    data object Commands : Screen()
    data object CommandHistory : Screen()
    data class CommandOutput(val executionId: String) : Screen()
}

/**
 * Simple navigation state holder.
 * For a production app, consider using Navigation Compose.
 */
class NavigationState {
    var currentScreen by mutableStateOf<Screen>(Screen.SessionList)
        private set

    private val backStack = mutableListOf<Screen>()

    fun navigateTo(screen: Screen) {
        backStack.add(currentScreen)
        currentScreen = screen
    }

    fun goBack(): Boolean {
        return if (backStack.isNotEmpty()) {
            currentScreen = backStack.removeLast()
            true
        } else {
            false
        }
    }

    fun popToRoot() {
        backStack.clear()
        currentScreen = Screen.SessionList
    }
}

/**
 * Main navigation host composable.
 */
@Composable
fun VoiceCodeNavHost(
    navigationState: NavigationState,
    // Session data
    sessions: List<Session>,
    recentSessions: List<Session>,
    currentSession: Session?,
    currentMessages: List<Message>,
    isSessionsLoading: Boolean,
    isMessagesLoading: Boolean,
    isSessionLocked: Boolean,
    // Commands data
    projectCommands: List<Command>,
    generalCommands: List<Command>,
    commandHistory: List<CommandExecution>,
    // Settings data
    serverUrl: String,
    serverPort: String,
    hasApiKey: Boolean,
    selectedVoiceName: String?,
    notificationsEnabled: Boolean,
    silentModeRespected: Boolean,
    versionName: String,
    versionCode: Int,
    // Callbacks
    onSessionClick: (Session) -> Unit,
    onNewSession: () -> Unit,
    onRefreshSessions: () -> Unit,
    onSendMessage: (String) -> Unit,
    onVoiceInput: () -> Unit,
    onCompactSession: () -> Unit,
    onExecuteCommand: (Command) -> Unit,
    onCommandExecutionClick: (CommandExecution) -> Unit,
    onServerUrlChange: (String) -> Unit,
    onServerPortChange: (String) -> Unit,
    onApiKeyChange: (String) -> Unit,
    onClearApiKey: () -> Unit,
    currentApiKey: String?,
    onVoiceSettingsClick: () -> Unit,
    onNotificationsToggle: (Boolean) -> Unit,
    onSilentModeToggle: (Boolean) -> Unit,
    modifier: Modifier = Modifier
) {
    when (val screen = navigationState.currentScreen) {
        is Screen.SessionList -> {
            SessionListScreen(
                sessions = sessions,
                recentSessions = recentSessions,
                isLoading = isSessionsLoading,
                onSessionClick = { session ->
                    onSessionClick(session)
                    navigationState.navigateTo(Screen.Conversation(session.id))
                },
                onNewSession = {
                    onNewSession()
                },
                onRefresh = onRefreshSessions,
                onSettingsClick = {
                    navigationState.navigateTo(Screen.Settings)
                },
                modifier = modifier
            )
        }

        is Screen.Conversation -> {
            if (currentSession != null) {
                ConversationScreen(
                    session = currentSession,
                    messages = currentMessages,
                    isLoading = isMessagesLoading,
                    isSessionLocked = isSessionLocked,
                    onBack = { navigationState.goBack() },
                    onSendMessage = onSendMessage,
                    onVoiceInput = onVoiceInput,
                    onCompact = onCompactSession,
                    modifier = modifier
                )
            }
        }

        is Screen.Settings -> {
            SettingsScreen(
                serverUrl = serverUrl,
                serverPort = serverPort,
                hasApiKey = hasApiKey,
                selectedVoiceName = selectedVoiceName,
                notificationsEnabled = notificationsEnabled,
                silentModeRespected = silentModeRespected,
                onBack = { navigationState.goBack() },
                onServerUrlChange = onServerUrlChange,
                onServerPortChange = onServerPortChange,
                onApiKeyClick = { navigationState.navigateTo(Screen.ApiKey) },
                onVoiceSettingsClick = onVoiceSettingsClick,
                onNotificationsToggle = onNotificationsToggle,
                onSilentModeToggle = onSilentModeToggle,
                onAboutClick = { navigationState.navigateTo(Screen.About) },
                modifier = modifier
            )
        }

        is Screen.ApiKey -> {
            ApiKeyScreen(
                currentApiKey = currentApiKey,
                onApiKeyChange = onApiKeyChange,
                onClearApiKey = onClearApiKey,
                onBack = { navigationState.goBack() },
                modifier = modifier
            )
        }

        is Screen.About -> {
            AboutScreen(
                versionName = versionName,
                versionCode = versionCode,
                onBack = { navigationState.goBack() },
                modifier = modifier
            )
        }

        is Screen.Commands -> {
            CommandMenuScreen(
                projectCommands = projectCommands,
                generalCommands = generalCommands,
                onBack = { navigationState.goBack() },
                onExecuteCommand = onExecuteCommand,
                onHistoryClick = { navigationState.navigateTo(Screen.CommandHistory) },
                modifier = modifier
            )
        }

        is Screen.CommandHistory -> {
            CommandHistoryScreen(
                executions = commandHistory,
                onBack = { navigationState.goBack() },
                onExecutionClick = onCommandExecutionClick,
                modifier = modifier
            )
        }

        is Screen.CommandOutput -> {
            // TODO: Implement command output detail screen
        }
    }
}
