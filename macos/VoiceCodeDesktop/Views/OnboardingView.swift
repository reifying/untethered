import SwiftUI
import AVFoundation
import Speech

struct OnboardingView: View {
    @ObservedObject var onboarding: OnboardingManager
    @ObservedObject var settings: AppSettings
    @State private var step: OnboardingStep = .welcome
    @State private var isTestingConnection = false
    @State private var connectionError: String?
    @State private var connectionTestTask: Task<Void, Never>?

    enum OnboardingStep {
        case welcome
        case serverConfig
        case testConnection
        case voicePermissions
        case success
    }

    var body: some View {
        VStack(spacing: 20) {
            switch step {
            case .welcome:
                WelcomeStep(onContinue: { step = .serverConfig })

            case .serverConfig:
                ServerConfigStep(
                    serverURL: $settings.serverURL,
                    serverPort: $settings.serverPort,
                    onTest: testConnection,
                    onSkip: skipOnboarding
                )

            case .testConnection:
                TestConnectionStep(
                    isLoading: isTestingConnection,
                    error: connectionError,
                    onRetry: testConnection,
                    onSkip: skipOnboarding
                )

            case .voicePermissions:
                VoicePermissionsStep(
                    onContinue: { step = .success },
                    onSkip: { step = .success }
                )

            case .success:
                SuccessStep(onFinish: {
                    onboarding.completeOnboarding()
                })
            }
        }
        .frame(width: 500, height: 400)
        .interactiveDismissDisabled()
        .onDisappear {
            // Cancel any in-flight connection test when view is dismissed
            connectionTestTask?.cancel()
            connectionTestTask = nil
        }
    }

    private func testConnection() {
        // Cancel any previous connection test task BEFORE updating state
        // This prevents a race condition where user taps Retry before new Task is assigned
        connectionTestTask?.cancel()

        isTestingConnection = true
        connectionError = nil
        step = .testConnection

        // Create new connection test task
        connectionTestTask = Task {
            let testClient = VoiceCodeClient(serverURL: settings.fullServerURL)
            testClient.connect()

            // Wait for either successful connection or 5-second timeout
            // - 5 second timeout is standard for connection attempts (matches iOS implementation)
            // - 100ms polling interval balances responsiveness with CPU efficiency
            // - Task.isCancelled check ensures clean cleanup if view is dismissed
            let startTime = Date()
            let timeoutInterval: TimeInterval = 5.0
            let pollInterval: UInt64 = 100_000_000 // 100 milliseconds in nanoseconds

            while Date().timeIntervalSince(startTime) < timeoutInterval {
                // Check if task was cancelled (e.g., view dismissed or user retried)
                if Task.isCancelled {
                    testClient.disconnect()
                    return
                }

                if testClient.isConnected {
                    // Connection succeeded - proceed to voice permissions
                    await MainActor.run {
                        isTestingConnection = false
                        step = .voicePermissions
                        testClient.disconnect()
                    }
                    return
                }

                // Check again after a short delay
                // 100ms provides good UI responsiveness without excessive CPU usage
                do {
                    try await Task.sleep(nanoseconds: pollInterval)
                } catch {
                    // Task was cancelled - clean up and return immediately
                    testClient.disconnect()
                    return
                }
            }

            // Timeout reached without successful connection - return to config screen
            await MainActor.run {
                isTestingConnection = false
                connectionError = "Could not connect to server. Please check URL and port."
                step = .serverConfig
                testClient.disconnect()
            }
        } as Task<Void, Never>
    }

    private func skipOnboarding() {
        onboarding.completeOnboarding()
    }
}

// MARK: - Step Views

struct WelcomeStep: View {
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 80))
                .foregroundColor(.accentColor)

            Text("Welcome to Voice Code")
                .font(.largeTitle)

            Text("Voice-powered AI coding assistant for your projects.")
                .foregroundColor(.secondary)

            Spacer()

            Button("Get Started") { onContinue() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .padding(40)
    }
}

struct ServerConfigStep: View {
    @Binding var serverURL: String
    @Binding var serverPort: String
    let onTest: () -> Void
    let onSkip: () -> Void

    @State private var urlError: String?
    @State private var portError: String?

    var isURLValid: Bool {
        guard !serverURL.isEmpty else { return false }
        return serverURL.contains("://")
    }

    var isPortValid: Bool {
        guard !serverPort.isEmpty else { return true } // Port is optional
        guard let port = Int(serverPort) else { return false }
        return port >= 1 && port <= 65535
    }

    var isConfigurationValid: Bool {
        isURLValid && isPortValid
    }

    var body: some View {
        VStack(spacing: 20) {
            Text("Connect to Backend")
                .font(.title)

            VStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    TextField("Server URL", text: $serverURL)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: serverURL) { newValue in
                            urlError = newValue.isEmpty ? nil : (!isURLValid ? "URL must contain '://' (e.g., ws://localhost)" : nil)
                        }

                    if let error = urlError {
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }
                .padding(.horizontal)

                VStack(alignment: .leading, spacing: 4) {
                    TextField("Port (optional)", text: $serverPort)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: serverPort) { newValue in
                            if !newValue.isEmpty {
                                if let port = Int(newValue) {
                                    portError = (port < 1 || port > 65535) ? "Port must be between 1 and 65535" : nil
                                } else {
                                    portError = "Port must be a number"
                                }
                            } else {
                                portError = nil
                            }
                        }

                    if let error = portError {
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }
                .padding(.horizontal)
            }

            Spacer()

            HStack {
                Button("Skip") { onSkip() }
                    .buttonStyle(.plain)

                Spacer()

                Button("Test Connection") { onTest() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!isConfigurationValid)
            }
            .padding(.horizontal)
        }
        .padding(40)
    }
}

struct TestConnectionStep: View {
    let isLoading: Bool
    let error: String?
    let onRetry: () -> Void
    let onSkip: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            if isLoading {
                Spacer()

                ProgressView()
                    .scaleEffect(1.5)

                Text("Testing connection...")
                    .foregroundColor(.secondary)

                Spacer()
            } else if let error = error {
                Spacer()

                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 48))
                    .foregroundColor(.orange)

                Text(error)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)

                Spacer()

                HStack {
                    Button("Skip") { onSkip() }
                        .buttonStyle(.plain)

                    Spacer()

                    Button("Retry") { onRetry() }
                        .buttonStyle(.borderedProminent)
                }
                .padding(.horizontal)
            } else {
                // Initial state before test begins
                Spacer()

                ProgressView()
                    .scaleEffect(1.5)

                Text("Starting connection test...")
                    .foregroundColor(.secondary)

                Spacer()
            }
        }
        .padding(40)
    }
}

struct VoicePermissionsStep: View {
    let onContinue: () -> Void
    let onSkip: () -> Void

    @State private var microphoneGranted = false
    @State private var speechGranted = false
    @State private var isRequestingMicrophone = false
    @State private var isRequestingSpeech = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "mic.circle.fill")
                .font(.system(size: 60))
                .foregroundColor(.accentColor)

            Text("Voice Input")
                .font(.title)

            Text("Voice Code uses your microphone for speech-to-text input. Grant permissions to enable voice features.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 12) {
                PermissionRow(
                    title: "Microphone",
                    description: "Required for voice input",
                    isGranted: microphoneGranted,
                    isRequesting: isRequestingMicrophone,
                    onRequest: requestMicrophone
                )

                PermissionRow(
                    title: "Speech Recognition",
                    description: "Required for transcription",
                    isGranted: speechGranted,
                    isRequesting: isRequestingSpeech,
                    onRequest: requestSpeechRecognition
                )
            }
            .padding(12)
            .background(Color.gray.opacity(0.1))
            .cornerRadius(8)
            .padding(.horizontal)

            Spacer()

            HStack {
                Button("Skip for Now") { onSkip() }
                    .buttonStyle(.plain)

                Spacer()

                Button("Continue") { onContinue() }
                    .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal)
        }
        .padding(40)
    }

    private func requestMicrophone() {
        isRequestingMicrophone = true
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async {
                microphoneGranted = granted
                isRequestingMicrophone = false
            }
        }
    }

    private func requestSpeechRecognition() {
        isRequestingSpeech = true
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                speechGranted = (status == .authorized)
                isRequestingSpeech = false
            }
        }
    }
}

struct PermissionRow: View {
    let title: String
    let description: String
    let isGranted: Bool
    let isRequesting: Bool
    let onRequest: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(title)
                    .font(.headline)

                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            if isGranted {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
            } else if isRequesting {
                ProgressView()
            } else {
                Button("Grant") { onRequest() }
                    .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 4)
    }
}

struct SuccessStep: View {
    let onFinish: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 80))
                .foregroundColor(.green)

            Text("You're All Set!")
                .font(.largeTitle)

            Text("Voice Code is ready to use.")
                .foregroundColor(.secondary)

            Spacer()

            Button("Start Using Voice Code") { onFinish() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .padding(40)
    }
}

#Preview {
    OnboardingView(
        onboarding: OnboardingManager(appSettings: AppSettings()),
        settings: AppSettings()
    )
}
