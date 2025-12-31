// SessionNotFoundView.swift
// Recovery view when a selected session no longer exists (AD.3)

import SwiftUI

/// Recovery view shown when a user navigates to a session that no longer exists.
/// Provides actions to refresh from backend or dismiss the view.
///
/// Per design doc Appendix AD.3:
/// - Scenario: User has a session selected that no longer exists (deleted on backend, corrupted data)
/// - Recovery Actions:
///   - Refresh: Re-fetch session list from backend
///   - Close: Clear selection, return to sidebar view
struct SessionNotFoundView: View {
    let sessionId: UUID
    let onDismiss: () -> Void
    let onRefresh: () -> Void

    @State private var showingCopyConfirmation = false

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundColor(.orange)

            Text("Session Not Found")
                .font(.title2)
                .fontWeight(.semibold)

            Text("This session may have been deleted or is no longer available.")
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Text(sessionId.uuidString.lowercased())
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.top, 8)

            HStack(spacing: 16) {
                Button(action: { onRefresh() }) {
                    HStack {
                        Image(systemName: "arrow.clockwise")
                        Text("Refresh")
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color(UIColor.systemGray5))
                    .cornerRadius(8)
                }

                Button(action: { onDismiss() }) {
                    HStack {
                        Image(systemName: "xmark")
                        Text("Close")
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(8)
                }
            }
            .padding(.top, 8)
        }
        .padding(40)
        .contentShape(Rectangle())
        .contextMenu {
            Button(action: {
                copySessionID()
            }) {
                Label("Copy Session ID", systemImage: "doc.on.clipboard")
            }
        }
        .overlay(alignment: .top) {
            if showingCopyConfirmation {
                Text("Session ID copied to clipboard")
                    .font(.caption)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.green.opacity(0.9))
                    .foregroundColor(.white)
                    .cornerRadius(8)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }

    private func copySessionID() {
        // Copy session ID to clipboard
        UIPasteboard.general.string = sessionId.uuidString.lowercased()

        // Trigger haptic feedback
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)

        // Show confirmation banner
        withAnimation {
            showingCopyConfirmation = true
        }

        // Hide confirmation after 2 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            withAnimation {
                showingCopyConfirmation = false
            }
        }
    }
}
