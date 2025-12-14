import Foundation

@MainActor
final class OnboardingManager: ObservableObject {
    @Published var needsOnboarding: Bool
    @Published var isServerConfigured: Bool

    private let appSettings: AppSettings

    init(appSettings: AppSettings) {
        self.appSettings = appSettings
        needsOnboarding = !UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")
        isServerConfigured = !appSettings.serverURL.isEmpty
    }

    func completeOnboarding() {
        UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
        needsOnboarding = false
    }
}
