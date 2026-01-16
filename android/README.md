# VoiceCode Android

Android native implementation of the VoiceCode mobile app, designed for feature parity with the iOS version.

## Project Structure

```
android/
├── app/
│   ├── src/
│   │   ├── main/
│   │   │   ├── kotlin/dev/labs910/voicecode/
│   │   │   │   ├── data/
│   │   │   │   │   ├── local/          # Room database, ApiKeyManager
│   │   │   │   │   ├── model/          # WebSocket message DTOs
│   │   │   │   │   ├── remote/         # VoiceCodeClient, Service
│   │   │   │   │   └── repository/     # Repository implementations
│   │   │   │   ├── domain/
│   │   │   │   │   ├── model/          # Message, Session, Command
│   │   │   │   │   ├── repository/     # Repository interfaces
│   │   │   │   │   └── usecase/        # Business logic
│   │   │   │   ├── presentation/
│   │   │   │   │   ├── ui/             # Activities, Composables
│   │   │   │   │   ├── viewmodel/      # ViewModels
│   │   │   │   │   └── theme/          # Material 3 theme
│   │   │   │   └── util/               # Extensions, helpers
│   │   │   └── res/                    # Android resources
│   │   └── test/                       # Unit tests
│   └── build.gradle.kts
├── gradle/
│   └── libs.versions.toml              # Version catalog
├── build.gradle.kts
└── settings.gradle.kts
```

## Requirements

- Android Studio Hedgehog or newer
- JDK 17
- Android SDK 35 (API level 35)
- Minimum SDK 26 (Android 8.0)

## Building

```bash
cd android
./gradlew assembleDebug
```

## Testing

```bash
cd android
./gradlew test
```

## Key Components

### WebSocket Client (`VoiceCodeClient.kt`)

Implements the voice-code WebSocket protocol from `STANDARDS.md`:
- Automatic reconnection with exponential backoff
- Session locking to prevent concurrent Claude executions
- Message acknowledgment and delivery tracking
- Ping/keepalive for connection health

### Data Models

Domain models match iOS equivalents:
- `Message` - Conversation messages with truncation support
- `Session` - Claude sessions with lowercase UUID enforcement
- `Command` - Shell commands with hierarchical groups

### Local Storage

- `Room` database for sessions and messages (like CoreData)
- `EncryptedSharedPreferences` for API key (like Keychain)

## Protocol Compliance

All WebSocket messages use `snake_case` keys per `STANDARDS.md`:
- `session_id` (not `sessionId`)
- `api_key` (not `apiKey`)
- `working_directory` (not `workingDirectory`)

UUIDs are always lowercase.

## iOS Parity Status

### Implemented
- [x] WebSocket protocol messages (all message types from STANDARDS.md)
- [x] Domain models (Message, Session, Command)
- [x] Room database schema with DAOs
- [x] API key secure storage (EncryptedSharedPreferences)
- [x] VoiceInputManager (SpeechRecognizer wrapper)
- [x] VoiceOutputManager (TextToSpeech wrapper)
- [x] Session list UI with grouping by directory
- [x] Conversation view with auto-scroll
- [x] Command menu with hierarchical groups
- [x] Command history screen
- [x] Settings screen with all preferences
- [x] About screen
- [x] AppSettings persistence (SharedPreferences)
- [x] SessionRepository for data coordination
- [x] MainViewModel for state management
- [x] Navigation with back stack
- [x] Share receiver activity
- [x] Foreground service structure
- [x] Material 3 theming with dynamic colors
- [x] Unit tests (39 Kotlin files, ~9,000 lines)
- [x] QR code scanner composable (CameraX + ML Kit)
- [x] File upload service for Share Intent
- [x] Notification manager with channels
- [x] API Key screen with QR scanner integration
- [x] Notification manager integrated into ViewModel
- [x] Voice selection screen (TTS voice, rate, pitch)
- [x] Session compaction confirmation dialog

### Planned
- [ ] Priority queue support UI
- [ ] Debug logs view
- [ ] Instrumented tests

## Development

### Adding New WebSocket Message Types

1. Add serializable data class to `WebSocketMessages.kt`
2. Add handling in `VoiceCodeClient.handleMessage()`
3. Add corresponding `WebSocketEvent` sealed class variant
4. Write tests in `WebSocketMessagesTest.kt`

### Database Migrations

Room handles migrations. For schema changes:
1. Increment version in `@Database` annotation
2. Add migration in `VoiceCodeDatabase.getInstance()`
3. Test migration path
