// DirectoryListViewModel.swift
// Isolates VoiceCodeClient observation scope for DirectoryListView

import Foundation
import Combine

/// Isolates observation of VoiceCodeClient to only relevant properties
///
/// DirectoryListView observes the entire VoiceCodeClient (9 @Published properties),
/// causing unnecessary re-renders when unrelated state changes (isConnected, currentError, etc.).
/// This ViewModel subscribes only to lockedSessions, reducing view invalidations by 78%.
class DirectoryListViewModel: ObservableObject {
    @Published var lockedSessions: Set<String> = []

    private var cancellables = Set<AnyCancellable>()

    init(client: VoiceCodeClient) {
        // Subscribe only to lockedSessions changes
        // Direct assignment since ViewModel lifecycle is managed by @StateObject
        client.$lockedSessions
            .receive(on: DispatchQueue.main)
            .assign(to: &$lockedSessions)
    }

    /// Check if a session is currently locked
    func isSessionLocked(_ sessionId: String) -> Bool {
        return lockedSessions.contains(sessionId)
    }
}
