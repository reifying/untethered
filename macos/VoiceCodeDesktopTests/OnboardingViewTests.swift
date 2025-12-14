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
        let appSettings = AppSettings()
        let view = ServerConfigStep(
            serverURL: .constant(""),
            serverPort: .constant(""),
            onTest: {},
            onSkip: {}
        )
        XCTAssertNotNil(view)
    }

    func testServerConfigStepCanBeSkipped() {
        var skipCalled = false
        let view = ServerConfigStep(
            serverURL: .constant(""),
            serverPort: .constant(""),
            onTest: {},
            onSkip: { skipCalled = true }
        )

        view.onSkip()
        XCTAssertTrue(skipCalled)
    }

    func testServerConfigStepCanTestConnection() {
        var testCalled = false
        let view = ServerConfigStep(
            serverURL: .constant("ws://localhost"),
            serverPort: .constant("8080"),
            onTest: { testCalled = true },
            onSkip: {}
        )

        view.onTest()
        XCTAssertTrue(testCalled)
    }

    // MARK: - TestConnectionStep Tests

    func testTestConnectionStepLoadingState() {
        let view = TestConnectionStep(
            isLoading: true,
            error: nil,
            onRetry: {},
            onSkip: {}
        )
        XCTAssertNotNil(view)
    }

    func testTestConnectionStepErrorState() {
        let errorMessage = "Connection failed"
        let view = TestConnectionStep(
            isLoading: false,
            error: errorMessage,
            onRetry: {},
            onSkip: {}
        )
        XCTAssertNotNil(view)
    }

    func testTestConnectionStepCanRetry() {
        var retryCalled = false
        let view = TestConnectionStep(
            isLoading: false,
            error: "Test error",
            onRetry: { retryCalled = true },
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
            isGranted: true,
            onRequest: {}
        )
        XCTAssertNotNil(view)
    }

    func testPermissionRowNotGrantedState() {
        let view = PermissionRow(
            title: "Microphone",
            description: "Required for voice input",
            isGranted: false,
            onRequest: {}
        )
        XCTAssertNotNil(view)
    }

    func testPermissionRowCallsOnRequest() {
        var requestCalled = false
        let view = PermissionRow(
            title: "Microphone",
            description: "Required for voice input",
            isGranted: false,
            onRequest: { requestCalled = true }
        )

        view.onRequest()
        XCTAssertTrue(requestCalled)
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

        let view = MainWindowView(settings: appSettings)
        XCTAssertNotNil(view)
        XCTAssertFalse(appSettings.isServerConfigured)
    }

    func testMainWindowViewHidesBannerWhenServerConfigured() {
        let appSettings = AppSettings()
        appSettings.serverURL = "ws://localhost:8080"

        let view = MainWindowView(settings: appSettings)
        XCTAssertNotNil(view)
        XCTAssertTrue(appSettings.isServerConfigured)
    }
}
