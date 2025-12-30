// RecoverableErrorView.swift
// User-recoverable error display per Appendix Z.3

import SwiftUI
import VoiceCodeShared

/// Displays a user-recoverable error with optional action button
struct RecoverableErrorView: View {
    let error: UserRecoverableError
    let onRetry: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                Text(error.title)
                    .font(.headline)
            }

            Text(error.message)
                .foregroundColor(.secondary)

            if let recoveryAction = error.recoveryAction {
                HStack {
                    Spacer()
                    Button("Dismiss") { onDismiss() }
                    Button(recoveryAction.label) {
                        recoveryAction.perform()
                        onRetry()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            } else {
                HStack {
                    Spacer()
                    Button("Dismiss") { onDismiss() }
                }
            }
        }
        .padding()
        .background(Color.orange.opacity(0.1))
        .cornerRadius(8)
    }
}

#Preview("With Recovery Action") {
    RecoverableErrorView(
        error: UserRecoverableError(
            title: "Connection Lost",
            message: "Unable to connect to the server. Please check your network.",
            recoveryAction: UserRecoveryAction(label: "Retry") {
                print("Retrying...")
            }
        ),
        onRetry: {},
        onDismiss: {}
    )
    .padding()
}

#Preview("Without Recovery Action") {
    RecoverableErrorView(
        error: UserRecoverableError(
            title: "Session Busy",
            message: "This session is processing another request. Please wait.",
            recoveryAction: nil
        ),
        onRetry: {},
        onDismiss: {}
    )
    .padding()
}
