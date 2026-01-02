import SwiftUI
import AVFoundation
import Speech

struct OnboardingView: View {
    @ObservedObject var onboarding: OnboardingManager
    @ObservedObject var settings: AppSettings
    @State private var step: OnboardingStep = .welcome
    @State private var isTestingConnection = false
    @State private var connectionError: String?
    @State private var connectionSuccess = false
    @State private var connectionTestTask: Task<Void, Never>?

    enum OnboardingStep {
        case welcome
        case serverConfig
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
                    isTesting: isTestingConnection,
                    connectionError: connectionError,
                    connectionSuccess: connectionSuccess,
                    onTest: testConnection,
                    onContinue: { step = .voicePermissions },
                    onSkip: skipOnboarding,
                    onClearStatus: clearConnectionStatus
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

    private func clearConnectionStatus() {
        connectionError = nil
        connectionSuccess = false
    }

    private func testConnection() {
        // Cancel any previous connection test task BEFORE updating state
        // This prevents a race condition where user taps Retry before new Task is assigned
        connectionTestTask?.cancel()

        isTestingConnection = true
        connectionError = nil
        connectionSuccess = false

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
                    // Connection succeeded - show success state with Continue button
                    await MainActor.run {
                        isTestingConnection = false
                        connectionSuccess = true
                        testClient.disconnect()
                    }
                    return
                }

                // Check again after a short delay
                // 100ms provides good UI responsiveness without excessive CPU usage
                do {
                    try await Task.sleep(nanoseconds: pollInterval)
                } catch {
                    // Task was cancelled or error occurred - clean up and return immediately
                    // In practice, only CancellationError occurs with Task.sleep
                    testClient.disconnect()
                    return
                }
            }

            // Timeout reached - show error on same screen with retry option
            await MainActor.run {
                isTestingConnection = false
                connectionError = "Could not connect to server at \(settings.serverURL):\(settings.serverPort). Please check the address and ensure the backend is running."
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
                .accessibilityHidden(true)

            Text("Welcome to Voice Code")
                .font(.largeTitle)
                .accessibilityAddTraits(.isHeader)

            Text("Voice-powered AI coding assistant for your projects.")
                .foregroundColor(.secondary)

            Spacer()

            Button("Get Started") { onContinue() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityHint("Continue to server configuration")
        }
        .padding(40)
    }
}

struct ServerConfigStep: View {
    @Binding var serverURL: String
    @Binding var serverPort: String
    let isTesting: Bool
    let connectionError: String?
    let connectionSuccess: Bool
    let onTest: () -> Void
    let onContinue: () -> Void
    let onSkip: () -> Void
    let onClearStatus: () -> Void

    @State private var urlError: String?
    @State private var portError: String?

    var isURLValid: Bool {
        // Accept hostname only (e.g., "localhost", "192.168.1.100")
        // The app prepends ws:// automatically via fullServerURL
        let trimmed = serverURL.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        // Basic hostname validation: no spaces, has some content
        return !trimmed.contains(" ")
    }

    var isPortValid: Bool {
        guard !serverPort.isEmpty else { return true } // Port is optional (defaults to 8080)
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

            Text("Enter your voice-code backend server address")
                .font(.subheadline)
                .foregroundColor(.secondary)

            VStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    TextField("Server Address (e.g., localhost)", text: $serverURL)
                        .textFieldStyle(.roundedBorder)
                        .disabled(isTesting)
                        .onChange(of: serverURL) { _, newValue in
                            let trimmed = newValue.trimmingCharacters(in: .whitespaces)
                            urlError = trimmed.isEmpty ? nil : (!isURLValid ? "Enter a valid hostname" : nil)
                            onClearStatus()
                        }

                    if let error = urlError {
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }
                .padding(.horizontal)

                VStack(alignment: .leading, spacing: 4) {
                    TextField("Port (default: 8080)", text: $serverPort)
                        .textFieldStyle(.roundedBorder)
                        .disabled(isTesting)
                        .onChange(of: serverPort) { _, newValue in
                            if !newValue.isEmpty {
                                if let port = Int(newValue) {
                                    portError = (port < 1 || port > 65535) ? "Port must be between 1 and 65535" : nil
                                } else {
                                    portError = "Port must be a number"
                                }
                            } else {
                                portError = nil
                            }
                            onClearStatus()
                        }

                    if let error = portError {
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }
                .padding(.horizontal)
            }

            // Inline test status
            if isTesting {
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Testing connection...")
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 8)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Testing connection to server")
            } else if connectionSuccess {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .accessibilityHidden(true)
                    Text("Connection successful!")
                        .foregroundColor(.green)
                }
                .padding(.vertical, 8)
                .accessibilityLabel("Connection successful")
            } else if let error = connectionError {
                VStack(spacing: 4) {
                    HStack(spacing: 8) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.red)
                            .accessibilityHidden(true)
                        Text("Connection failed")
                            .foregroundColor(.red)
                    }
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                .padding(.vertical, 8)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Connection failed. \(error)")
            }

            Spacer()

            HStack {
                Button("Skip") { onSkip() }
                    .buttonStyle(.plain)
                    .disabled(isTesting)

                Spacer()

                if connectionSuccess {
                    Button("Continue") { onContinue() }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button(isTesting ? "Testing..." : "Test Connection") { onTest() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!isConfigurationValid || isTesting)
                }
            }
            .padding(.horizontal)
        }
        .padding(40)
    }
}

struct TestConnectionStep: View {
    let isLoading: Bool
    let error: String?
    let success: Bool
    let onRetry: () -> Void
    let onContinue: () -> Void
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
            } else if success {
                // Success state
                Spacer()

                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 64))
                    .foregroundColor(.green)

                Text("Connection Successful!")
                    .font(.title2)
                    .foregroundColor(.primary)

                Text("Your backend server is reachable.")
                    .foregroundColor(.secondary)

                Spacer()

                Button("Continue") { onContinue() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            } else if let error = error {
                // Error state
                Spacer()

                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 64))
                    .foregroundColor(.red)

                Text("Connection Failed")
                    .font(.title2)
                    .foregroundColor(.primary)

                Text(error)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

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
                // Fallback/initial state
                Spacer()

                ProgressView()
                    .scaleEffect(1.5)

                Text("Initializing...")
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

    @State private var microphoneStatus: PermissionStatus = .unknown
    @State private var speechStatus: PermissionStatus = .unknown

    enum PermissionStatus {
        case unknown
        case requesting
        case granted
        case denied
    }

    enum PermissionType {
        case microphone
        case speechRecognition

        var settingsURL: URL? {
            switch self {
            case .microphone:
                return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
            case .speechRecognition:
                return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition")
            }
        }
    }

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "mic.circle.fill")
                .font(.system(size: 60))
                .foregroundColor(.accentColor)
                .accessibilityHidden(true)

            Text("Voice Input")
                .font(.title)
                .accessibilityAddTraits(.isHeader)

            Text("Voice Code uses your microphone for speech-to-text input. Grant permissions to enable voice features.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 12) {
                PermissionRow(
                    title: "Microphone",
                    description: "Required for voice input",
                    status: microphoneStatus,
                    permissionType: .microphone,
                    onRequest: requestMicrophone
                )

                PermissionRow(
                    title: "Speech Recognition",
                    description: "Required for transcription",
                    status: speechStatus,
                    permissionType: .speechRecognition,
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
        .onAppear {
            checkCurrentPermissions()
        }
    }

    private func checkCurrentPermissions() {
        // Check microphone permission status
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            microphoneStatus = .granted
        case .denied, .restricted:
            microphoneStatus = .denied
        case .notDetermined:
            microphoneStatus = .unknown
        @unknown default:
            microphoneStatus = .unknown
        }

        // Check speech recognition permission status
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            speechStatus = .granted
        case .denied, .restricted:
            speechStatus = .denied
        case .notDetermined:
            speechStatus = .unknown
        @unknown default:
            speechStatus = .unknown
        }
    }

    private func requestMicrophone() {
        microphoneStatus = .requesting
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async {
                microphoneStatus = granted ? .granted : .denied
            }
        }
    }

    private func requestSpeechRecognition() {
        speechStatus = .requesting
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                speechStatus = (status == .authorized) ? .granted : .denied
            }
        }
    }
}

struct PermissionRow: View {
    let title: String
    let description: String
    let status: VoicePermissionsStep.PermissionStatus
    let permissionType: VoicePermissionsStep.PermissionType
    let onRequest: () -> Void

    /// Accessibility label for the permission row
    private var accessibilityDescription: String {
        switch status {
        case .granted:
            return "\(title) permission granted"
        case .denied:
            return "\(title) permission denied. Open Settings to grant."
        case .requesting:
            return "Requesting \(title) permission"
        case .unknown:
            return "\(title) permission required. \(description)"
        }
    }

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

            switch status {
            case .granted:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .accessibilityLabel("Granted")
            case .denied:
                Button("Open Settings") {
                    if let url = permissionType.settingsURL {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.bordered)
                .accessibilityHint("Opens System Settings to grant \(title) permission")
            case .requesting:
                ProgressView()
                    .accessibilityLabel("Requesting permission")
            case .unknown:
                Button("Grant") { onRequest() }
                    .buttonStyle(.bordered)
                    .accessibilityHint("Request \(title) permission")
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
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
                .accessibilityHidden(true)

            Text("You're All Set!")
                .font(.largeTitle)
                .accessibilityAddTraits(.isHeader)

            Text("Voice Code is ready to use.")
                .foregroundColor(.secondary)

            Spacer()

            Button("Start Using Voice Code") { onFinish() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityHint("Complete setup and open the main window")
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
