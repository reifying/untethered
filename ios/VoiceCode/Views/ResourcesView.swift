// ResourcesView.swift
// Main view for managing uploaded resources

import SwiftUI

struct ResourcesView: View {
    @ObservedObject var resourcesManager: ResourcesManager
    @ObservedObject var client: VoiceCodeClient

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Resources list
                if resourcesManager.isLoadingResources {
                    LoadingResourcesView()
                } else if resourcesManager.resources.isEmpty && resourcesManager.pendingUploadCount == 0 {
                    EmptyResourcesView()
                } else {
                    List {
                        // Pending uploads section
                        if resourcesManager.pendingUploadCount > 0 {
                            Section(header: Text("Pending Uploads")) {
                                PendingUploadRow(
                                    count: resourcesManager.pendingUploadCount,
                                    isProcessing: resourcesManager.isProcessing,
                                    onProcess: {
                                        resourcesManager.processPendingUploads()
                                    }
                                )
                            }
                        }

                        // Uploaded resources section
                        if !resourcesManager.resources.isEmpty {
                            Section(header: Text("Uploaded Resources")) {
                                ForEach(resourcesManager.resources) { resource in
                                    ResourceRow(resource: resource)
                                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                            Button(role: .destructive) {
                                                resourcesManager.deleteResource(resource)
                                            } label: {
                                                Label("Delete", systemImage: "trash")
                                            }
                                        }
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Resources")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: {
                        resourcesManager.listResources()
                    }) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(!client.isConnected || resourcesManager.isLoadingResources)
                }
            }
            .onAppear {
                resourcesManager.updatePendingCount()
                if client.isConnected {
                    resourcesManager.listResources()
                }
            }
        }
    }
}

// MARK: - Resource Row

struct ResourceRow: View {
    let resource: Resource

    var body: some View {
        HStack(spacing: 12) {
            // File icon
            Image(systemName: fileIcon(for: resource.filename))
                .font(.title2)
                .foregroundColor(.blue)
                .frame(width: 40)

            VStack(alignment: .leading, spacing: 4) {
                Text(resource.filename)
                    .font(.body)
                    .lineLimit(1)
                
                HStack(spacing: 8) {
                    Text(resource.formattedSize)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Text("•")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Text(resource.relativeTimestamp)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()
        }
        .padding(.vertical, 4)
    }

    private func fileIcon(for filename: String) -> String {
        let ext = (filename as NSString).pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg", "png", "gif", "heic":
            return "photo"
        case "pdf":
            return "doc.text"
        case "zip", "tar", "gz":
            return "archivebox"
        case "txt", "md":
            return "doc.plaintext"
        case "json", "xml":
            return "doc.text.magnifyingglass"
        default:
            return "doc"
        }
    }
}

// MARK: - Pending Upload Row

struct PendingUploadRow: View {
    let count: Int
    let isProcessing: Bool
    let onProcess: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.up.circle.fill")
                .font(.title2)
                .foregroundColor(.orange)
                .frame(width: 40)

            VStack(alignment: .leading, spacing: 4) {
                Text("\(count) file\(count == 1 ? "" : "s") waiting to upload")
                    .font(.body)
                
                if isProcessing {
                    Text("Uploading...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            if isProcessing {
                ProgressView()
            } else {
                Button("Upload") {
                    onProcess()
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Loading State

struct LoadingResourcesView: View {
    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("Loading resources...")
                .font(.body)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
