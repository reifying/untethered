import XCTest
@testable import VoiceCodeDesktop

@MainActor
final class OnboardingManagerTests: XCTestCase {
    override func setUp() {
        super.setUp()
        // Clear UserDefaults before each test
        UserDefaults.standard.removeObject(forKey: "hasCompletedOnboarding")
        UserDefaults.standard.removeObject(forKey: "serverURL")
    }

    override func tearDown() {
        super.tearDown()
        // Clean up after each test
        UserDefaults.standard.removeObject(forKey: "hasCompletedOnboarding")
        UserDefaults.standard.removeObject(forKey: "serverURL")
    }

    func testFirstLaunchShowsOnboarding() {
        // First launch: hasCompletedOnboarding should not exist in UserDefaults
        XCTAssertFalse(UserDefaults.standard.bool(forKey: "hasCompletedOnboarding"))

        let appSettings = AppSettings()
        let manager = OnboardingManager(appSettings: appSettings)

        // needsOnboarding should be true on first launch
        XCTAssertTrue(manager.needsOnboarding)
    }

    func testSecondLaunchSkipsOnboarding() {
        // Simulate previous onboarding completion
        UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")

        let appSettings = AppSettings()
        let manager = OnboardingManager(appSettings: appSettings)

        // needsOnboarding should be false after onboarding completed
        XCTAssertFalse(manager.needsOnboarding)
    }

    func testCompleteOnboardingSetsFlag() {
        // Start with first launch state
        let appSettings = AppSettings()
        let manager = OnboardingManager(appSettings: appSettings)
        XCTAssertTrue(manager.needsOnboarding)

        // Call completeOnboarding()
        manager.completeOnboarding()

        // Verify flag is set in UserDefaults
        XCTAssertTrue(UserDefaults.standard.bool(forKey: "hasCompletedOnboarding"))

        // Verify needsOnboarding is updated
        XCTAssertFalse(manager.needsOnboarding)
    }

    func testSkipOnboardingShowsBanner() {
        // Simulate first launch with server not configured
        let appSettings = AppSettings()
        let manager = OnboardingManager(appSettings: appSettings)

        // needsOnboarding should be true (first launch)
        XCTAssertTrue(manager.needsOnboarding)

        // Server should not be configured
        XCTAssertFalse(manager.isServerConfigured)

        // Complete onboarding without configuring server
        manager.completeOnboarding()

        // needsOnboarding should be false
        XCTAssertFalse(manager.needsOnboarding)

        // But server is still not configured, so banner should be shown
        XCTAssertFalse(manager.isServerConfigured)
    }

    func testServerConfigurationTracking() {
        let appSettings = AppSettings()
        let manager = OnboardingManager(appSettings: appSettings)

        // Initially server is not configured
        XCTAssertFalse(manager.isServerConfigured)

        // Simulate server URL being set
        UserDefaults.standard.set("ws://localhost:8080", forKey: "serverURL")

        // Create new manager with new AppSettings to pick up the change
        let updatedAppSettings = AppSettings()
        let updatedManager = OnboardingManager(appSettings: updatedAppSettings)
        XCTAssertTrue(updatedManager.isServerConfigured)
    }
}
