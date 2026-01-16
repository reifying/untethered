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
- [x] WebSocket protocol messages
- [x] Domain models (Message, Session, Command)
- [x] Room database schema
- [x] API key secure storage
- [x] Basic MainActivity with Compose UI
- [x] Share receiver activity
- [x] Foreground service structure
- [x] Unit tests for core components

### In Progress
- [ ] Voice input (SpeechRecognizer)
- [ ] Text-to-speech output
- [ ] Session list UI
- [ ] Conversation view
- [ ] Command menu
- [ ] Settings screen

### Planned
- [ ] QR code scanner for API key
- [ ] File upload via Share Intent
- [ ] Priority queue support
- [ ] Session compaction
- [ ] Delta sync for message history

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
