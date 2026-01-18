# Maestro E2E Tests

End-to-end tests for the Voice Code React Native app using [Maestro](https://maestro.mobile.dev/).

## Prerequisites

1. Install Maestro CLI:
   ```bash
   curl -Ls "https://get.maestro.mobile.dev" | bash
   ```

2. Build and run the app on a simulator:
   ```bash
   cd frontend
   npm run ios
   ```

3. Have the backend running (for authenticated tests):
   ```bash
   cd backend && make run
   ```

## Running Tests

### Smoke Tests (No Backend Required)

Tests that verify basic UI without needing authentication:

```bash
# App launch and auth screen verification
maestro test .maestro/flows/app-launch.yaml

# QR scanner UI (shows fallback on simulator)
maestro test .maestro/flows/auth-qr-scan.yaml
```

### Full Test Suite (Backend Required)

Set environment variables for authentication:

```bash
export API_KEY="untethered-your-api-key"
export SERVER_URL="localhost"
export SERVER_PORT="8080"
```

Run all tests:

```bash
maestro test .maestro/
```

Or run specific flows:

```bash
# Authentication
maestro test .maestro/flows/auth-manual.yaml

# Navigation
maestro test .maestro/flows/navigation-basic.yaml
maestro test .maestro/flows/session-list.yaml

# Conversation
maestro test .maestro/flows/send-prompt.yaml

# Commands
maestro test .maestro/flows/command-execution.yaml

# Settings
maestro test .maestro/flows/settings.yaml
```

### Run by Tag

```bash
# All smoke tests
maestro test .maestro/ --include-tags smoke

# All auth tests
maestro test .maestro/ --include-tags auth

# All navigation tests
maestro test .maestro/ --include-tags navigation
```

## Test Flows

| Flow | Description | Backend Required |
|------|-------------|------------------|
| `app-launch.yaml` | Verifies app launches and shows auth screen | No |
| `auth-qr-scan.yaml` | Tests QR scanner UI | No |
| `auth-manual.yaml` | Tests manual API key entry and connection | Yes |
| `navigation-basic.yaml` | Tests basic navigation between screens | Yes |
| `session-list.yaml` | Tests browsing projects and sessions | Yes |
| `send-prompt.yaml` | Tests sending a prompt and receiving response | Yes |
| `command-execution.yaml` | Tests command menu and execution | Yes |
| `settings.yaml` | Tests settings screen | Yes |

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `API_KEY` | (required) | Voice Code API key (`untethered-...`) |
| `SERVER_URL` | `localhost` | Backend server URL |
| `SERVER_PORT` | `8080` | Backend server port |

## Notes

- **Simulator vs Device**: QR scanning requires a physical device with camera. On simulator, the QR scanner shows a fallback view.
- **Session Requirements**: Some tests (`send-prompt.yaml`, `session-list.yaml`) require at least one Claude session to exist in the backend.
- **Timeouts**: The `send-prompt.yaml` test has a 60-second timeout for Claude responses, which may need adjustment based on network/server conditions.

## CI Integration

For CI/CD, you can use Maestro Cloud or run locally:

```bash
# Run in CI with environment variables
API_KEY=$VOICE_CODE_API_KEY \
SERVER_URL=$BACKEND_URL \
SERVER_PORT=$BACKEND_PORT \
maestro test .maestro/ --format junit --output results.xml
```

## Debugging

Record a test run:

```bash
maestro record .maestro/flows/app-launch.yaml
```

Run in debug mode:

```bash
maestro test .maestro/flows/app-launch.yaml --debug-output debug/
```

View Maestro Studio for interactive debugging:

```bash
maestro studio
```
