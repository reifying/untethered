// ResourcesView.swift
// Main view for managing uploaded resources

import SwiftUI

struct ResourcesView: View {
    @ObservedObject var resourcesManager: ResourcesManager
    @ObservedObject var client: VoiceCodeClient

    var body: some View {
        NavigationView {
            VStack(spacing: 16) {
                // Upload status card
                if resourcesManager.pendingUploadCount > 0 {
                    PendingUploadCard(
                        count: resourcesManager.pendingUploadCount,
                        isProcessing: resourcesManager.isProcessing
                    )
                    .padding(.horizontal)
                    .padding(.top)
                }

                // Resource list placeholder
                if resourcesManager.pendingUploadCount == 0 {
                    EmptyResourcesView()
                }

                Spacer()
            }
            .navigationTitle("Resources")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: {
                        resourcesManager.processPendingUploads()
                    }) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(!client.isConnected || resourcesManager.isProcessing)
                }
            }
            .onAppear {
                resourcesManager.updatePendingCount()
            }
        }
    }
}

// MARK: - Pending Upload Card

struct PendingUploadCard: View {
    let count: Int
    let isProcessing: Bool

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
                    .foregroundColor(.blue)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Pending Uploads")
                        .font(.headline)
                    Text("\(count) file\(count == 1 ? "" : "s") waiting to upload")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                if isProcessing {
                    ProgressView()
                }
            }

            if isProcessing {
                Text("Uploading files to backend...")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.blue.opacity(0.1))
        )
    }
}

// MARK: - Empty State

struct EmptyResourcesView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.on.doc")
                .font(.system(size: 64))
                .foregroundColor(.secondary)
            Text("No Resources")
                .font(.title2)
                .foregroundColor(.secondary)
            Text("Share files from other apps to upload them to your session.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 100)
    }
}
