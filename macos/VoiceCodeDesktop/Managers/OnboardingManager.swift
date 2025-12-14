import Foundation
import Combine

@MainActor
final class OnboardingManager: ObservableObject {
    @Published var needsOnboarding: Bool
    @Published var isServerConfigured: Bool

    private let appSettings: AppSettings
    private var cancellable: AnyCancellable?

    init(appSettings: AppSettings) {
        self.appSettings = appSettings
        needsOnboarding = !UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")
        isServerConfigured = !appSettings.serverURL.isEmpty

        // Observe changes to serverURL and update isServerConfigured reactively
        self.cancellable = appSettings.$serverURL
            .map { !$0.isEmpty }
            .assign(to: \.isServerConfigured, on: self)
    }

    func completeOnboarding() {
        UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
        needsOnboarding = false
    }
}
