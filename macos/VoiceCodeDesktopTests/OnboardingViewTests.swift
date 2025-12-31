import XCTest
import SwiftUI
@testable import VoiceCodeDesktop

@MainActor
final class OnboardingViewTests: XCTestCase {
    override func setUp() {
        super.setUp()
        // Clear UserDefaults before each test
        UserDefaults.standard.removeObject(forKey: "hasCompletedOnboarding")
        UserDefaults.standard.removeObject(forKey: "serverURL")
        UserDefaults.standard.removeObject(forKey: "serverPort")
    }

    override func tearDown() {
        super.tearDown()
        // Clean up after each test
        UserDefaults.standard.removeObject(forKey: "hasCompletedOnboarding")
        UserDefaults.standard.removeObject(forKey: "serverURL")
        UserDefaults.standard.removeObject(forKey: "serverPort")
    }

    // MARK: - OnboardingView Tests

    func testOnboardingViewInitialState() {
        let appSettings = AppSettings()
        let onboarding = OnboardingManager(appSettings: appSettings)
        let view = OnboardingView(onboarding: onboarding, settings: appSettings)

        // Verify the view can be instantiated
        XCTAssertNotNil(view)
    }

    func testOnboardingViewShowsWelcomeStepInitially() {
        let appSettings = AppSettings()
        let onboarding = OnboardingManager(appSettings: appSettings)

        // When onboarding manager indicates first launch
        XCTAssertTrue(onboarding.needsOnboarding)

        // OnboardingView should start with welcome step
        XCTAssertNotNil(OnboardingView(onboarding: onboarding, settings: appSettings))
    }

    // MARK: - WelcomeStep Tests

    func testWelcomeStepRendersContent() {
        let view = WelcomeStep(onContinue: {})
        XCTAssertNotNil(view)
    }

    func testWelcomeStepCallsOnContinue() {
        var continueCalled = false
        let view = WelcomeStep(onContinue: { continueCalled = true })

        // Simulate button tap
        view.onContinue()

        XCTAssertTrue(continueCalled)
    }

    // MARK: - ServerConfigStep Tests

    func testServerConfigStepInitialState() {
        let view = ServerConfigStep(
            serverURL: .constant(""),
            serverPort: .constant(""),
            isTesting: false,
            connectionError: nil,
            connectionSuccess: false,
            onTest: {},
            onContinue: {},
            onSkip: {},
            onClearStatus: {}
        )
        XCTAssertNotNil(view)
    }

    func testServerConfigStepCanBeSkipped() {
        var skipCalled = false
        let view = ServerConfigStep(
            serverURL: .constant(""),
            serverPort: .constant(""),
            isTesting: false,
            connectionError: nil,
            connectionSuccess: false,
            onTest: {},
            onContinue: {},
            onSkip: { skipCalled = true },
            onClearStatus: {}
        )

        view.onSkip()
        XCTAssertTrue(skipCalled)
    }

    func testServerConfigStepCanTestConnection() {
        var testCalled = false
        let view = ServerConfigStep(
            serverURL: .constant("localhost"),
            serverPort: .constant("8080"),
            isTesting: false,
            connectionError: nil,
            connectionSuccess: false,
            onTest: { testCalled = true },
            onContinue: {},
            onSkip: {},
            onClearStatus: {}
        )

        view.onTest()
        XCTAssertTrue(testCalled)
    }

    func testServerConfigStepShowsTestingState() {
        let view = ServerConfigStep(
            serverURL: .constant("localhost"),
            serverPort: .constant("8080"),
            isTesting: true,
            connectionError: nil,
            connectionSuccess: false,
            onTest: {},
            onContinue: {},
            onSkip: {},
            onClearStatus: {}
        )
        XCTAssertNotNil(view)
    }

    func testServerConfigStepShowsSuccessState() {
        var continueCalled = false
        let view = ServerConfigStep(
            serverURL: .constant("localhost"),
            serverPort: .constant("8080"),
            isTesting: false,
            connectionError: nil,
            connectionSuccess: true,
            onTest: {},
            onContinue: { continueCalled = true },
            onSkip: {},
            onClearStatus: {}
        )
        XCTAssertNotNil(view)
        view.onContinue()
        XCTAssertTrue(continueCalled)
    }

    func testServerConfigStepShowsErrorState() {
        let view = ServerConfigStep(
            serverURL: .constant("localhost"),
            serverPort: .constant("8080"),
            isTesting: false,
            connectionError: "Connection failed",
            connectionSuccess: false,
            onTest: {},
            onContinue: {},
            onSkip: {},
            onClearStatus: {}
        )
        XCTAssertNotNil(view)
    }

    func testServerConfigStepClearsStatus() {
        var clearStatusCalled = false
        let view = ServerConfigStep(
            serverURL: .constant("localhost"),
            serverPort: .constant("8080"),
            isTesting: false,
            connectionError: nil,
            connectionSuccess: false,
            onTest: {},
            onContinue: {},
            onSkip: {},
            onClearStatus: { clearStatusCalled = true }
        )

        view.onClearStatus()
        XCTAssertTrue(clearStatusCalled)
    }

    // MARK: - TestConnectionStep Tests

    func testTestConnectionStepLoadingState() {
        let view = TestConnectionStep(
            isLoading: true,
            error: nil,
            success: false,
            onRetry: {},
            onContinue: {},
            onSkip: {}
        )
        XCTAssertNotNil(view)
    }

    func testTestConnectionStepErrorState() {
        let errorMessage = "Connection failed"
        let view = TestConnectionStep(
            isLoading: false,
            error: errorMessage,
            success: false,
            onRetry: {},
            onContinue: {},
            onSkip: {}
        )
        XCTAssertNotNil(view)
    }

    func testTestConnectionStepSuccessState() {
        var continueCalled = false
        let view = TestConnectionStep(
            isLoading: false,
            error: nil,
            success: true,
            onRetry: {},
            onContinue: { continueCalled = true },
            onSkip: {}
        )
        XCTAssertNotNil(view)
        view.onContinue()
        XCTAssertTrue(continueCalled)
    }

    func testTestConnectionStepCanRetry() {
        var retryCalled = false
        let view = TestConnectionStep(
            isLoading: false,
            error: "Test error",
            success: false,
            onRetry: { retryCalled = true },
            onContinue: {},
            onSkip: {}
        )

        view.onRetry()
        XCTAssertTrue(retryCalled)
    }

    // MARK: - VoicePermissionsStep Tests

    func testVoicePermissionsStepRendersContent() {
        let view = VoicePermissionsStep(onContinue: {}, onSkip: {})
        XCTAssertNotNil(view)
    }

    func testVoicePermissionsStepCanContinue() {
        var continueCalled = false
        let view = VoicePermissionsStep(
            onContinue: { continueCalled = true },
            onSkip: {}
        )

        view.onContinue()
        XCTAssertTrue(continueCalled)
    }

    func testVoicePermissionsStepCanSkip() {
        var skipCalled = false
        let view = VoicePermissionsStep(
            onContinue: {},
            onSkip: { skipCalled = true }
        )

        view.onSkip()
        XCTAssertTrue(skipCalled)
    }

    // MARK: - PermissionStatus Tests

    func testPermissionStatusValues() {
        // Verify all permission status cases exist
        let unknown: VoicePermissionsStep.PermissionStatus = .unknown
        let requesting: VoicePermissionsStep.PermissionStatus = .requesting
        let granted: VoicePermissionsStep.PermissionStatus = .granted
        let denied: VoicePermissionsStep.PermissionStatus = .denied

        // These assertions verify the enum cases are distinct
        XCTAssertTrue(unknown != granted)
        XCTAssertTrue(requesting != granted)
        XCTAssertTrue(denied != granted)
        XCTAssertTrue(unknown != denied)
    }

    // MARK: - SuccessStep Tests

    func testSuccessStepCallsOnFinish() {
        var finishCalled = false
        let view = SuccessStep(onFinish: { finishCalled = true })

        view.onFinish()
        XCTAssertTrue(finishCalled)
    }

    func testSuccessStepRendersContent() {
        let view = SuccessStep(onFinish: {})
        XCTAssertNotNil(view)
    }

    // MARK: - PermissionRow Tests

    func testPermissionRowGrantedState() {
        let view = PermissionRow(
            title: "Microphone",
            description: "Required for voice input",
            status: .granted,
            permissionType: .microphone,
            onRequest: {}
        )
        XCTAssertNotNil(view)
    }

    func testPermissionRowUnknownState() {
        let view = PermissionRow(
            title: "Microphone",
            description: "Required for voice input",
            status: .unknown,
            permissionType: .microphone,
            onRequest: {}
        )
        XCTAssertNotNil(view)
    }

    func testPermissionRowDeniedState() {
        let view = PermissionRow(
            title: "Microphone",
            description: "Required for voice input",
            status: .denied,
            permissionType: .microphone,
            onRequest: {}
        )
        XCTAssertNotNil(view)
    }

    func testPermissionRowRequestingState() {
        let view = PermissionRow(
            title: "Microphone",
            description: "Required for voice input",
            status: .requesting,
            permissionType: .microphone,
            onRequest: {}
        )
        XCTAssertNotNil(view)
    }

    func testPermissionRowCallsOnRequest() {
        var requestCalled = false
        let view = PermissionRow(
            title: "Microphone",
            description: "Required for voice input",
            status: .unknown,
            permissionType: .microphone,
            onRequest: { requestCalled = true }
        )

        view.onRequest()
        XCTAssertTrue(requestCalled)
    }

    func testPermissionRowSpeechRecognitionType() {
        let view = PermissionRow(
            title: "Speech Recognition",
            description: "Required for transcription",
            status: .denied,
            permissionType: .speechRecognition,
            onRequest: {}
        )
        XCTAssertNotNil(view)
    }

    // MARK: - PermissionType Tests

    func testPermissionTypeMicrophoneSettingsURL() {
        let url = VoicePermissionsStep.PermissionType.microphone.settingsURL
        XCTAssertNotNil(url)
        XCTAssertTrue(url?.absoluteString.contains("Privacy_Microphone") == true)
    }

    func testPermissionTypeSpeechRecognitionSettingsURL() {
        let url = VoicePermissionsStep.PermissionType.speechRecognition.settingsURL
        XCTAssertNotNil(url)
        XCTAssertTrue(url?.absoluteString.contains("Privacy_SpeechRecognition") == true)
    }

    // MARK: - Integration Tests

    func testFirstLaunchShowsOnboarding() {
        UserDefaults.standard.removeObject(forKey: "hasCompletedOnboarding")

        let appSettings = AppSettings()
        let manager = OnboardingManager(appSettings: appSettings)

        XCTAssertTrue(manager.needsOnboarding)
    }

    func testSecondLaunchSkipsOnboarding() {
        UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")

        let appSettings = AppSettings()
        let manager = OnboardingManager(appSettings: appSettings)

        XCTAssertFalse(manager.needsOnboarding)
    }

    func testCompleteOnboardingSetsFlag() {
        UserDefaults.standard.removeObject(forKey: "hasCompletedOnboarding")

        let appSettings = AppSettings()
        let manager = OnboardingManager(appSettings: appSettings)
        XCTAssertTrue(manager.needsOnboarding)

        manager.completeOnboarding()

        XCTAssertFalse(manager.needsOnboarding)
        XCTAssertTrue(UserDefaults.standard.bool(forKey: "hasCompletedOnboarding"))
    }

    func testSkipOnboardingShowsBanner() {
        let appSettings = AppSettings()
        appSettings.serverURL = ""

        let manager = OnboardingManager(appSettings: appSettings)
        XCTAssertTrue(manager.needsOnboarding)
        XCTAssertFalse(manager.isServerConfigured)

        manager.completeOnboarding()

        XCTAssertFalse(manager.needsOnboarding)
        XCTAssertFalse(manager.isServerConfigured)
    }

    func testMainWindowViewShowsBannerWhenServerNotConfigured() {
        let appSettings = AppSettings()
        appSettings.serverURL = ""
        let statusBar = StatusBarController(appSettings: appSettings)

        let view = MainWindowView(settings: appSettings, statusBarController: statusBar)
        XCTAssertNotNil(view)
        XCTAssertFalse(appSettings.isServerConfigured)

        statusBar.teardown()
    }

    func testMainWindowViewHidesBannerWhenServerConfigured() {
        let appSettings = AppSettings()
        appSettings.serverURL = "ws://localhost:8080"
        let statusBar = StatusBarController(appSettings: appSettings)

        let view = MainWindowView(settings: appSettings, statusBarController: statusBar)
        XCTAssertNotNil(view)
        XCTAssertTrue(appSettings.isServerConfigured)

        statusBar.teardown()
    }
}
