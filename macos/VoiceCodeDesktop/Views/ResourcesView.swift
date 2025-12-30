// ResourcesView.swift
// Resources panel with drag-and-drop, file dialogs, and upload progress
// Per Section 11.4 of macos-desktop-design.md

import SwiftUI
import UniformTypeIdentifiers
import OSLog
import VoiceCodeShared

private let logger = Logger(subsystem: "dev.910labs.voice-code-desktop", category: "ResourcesView")

// MARK: - ResourcesView

/// Main resources view with file list and upload capabilities
struct ResourcesView: View {
    @ObservedObject var resourcesManager: ResourcesManager
    @ObservedObject var settings: AppSettings

    @State private var showingFilePicker = false
    @State private var isDragOver = false
    @State private var showingDeleteConfirmation = false
    @State private var resourceToDelete: Resource?
    @State private var sortOrder: ResourceSortOrder = .dateDescending

    enum ResourceSortOrder: String, CaseIterable {
        case dateDescending = "Newest First"
        case dateAscending = "Oldest First"
        case nameAscending = "Name A-Z"
        case nameDescending = "Name Z-A"
        case sizeDescending = "Largest First"
        case sizeAscending = "Smallest First"
    }

    var sortedResources: [Resource] {
        switch sortOrder {
        case .dateDescending:
            return resourcesManager.resources.sorted { $0.timestamp > $1.timestamp }
        case .dateAscending:
            return resourcesManager.resources.sorted { $0.timestamp < $1.timestamp }
        case .nameAscending:
            return resourcesManager.resources.sorted { $0.filename.localizedCaseInsensitiveCompare($1.filename) == .orderedAscending }
        case .nameDescending:
            return resourcesManager.resources.sorted { $0.filename.localizedCaseInsensitiveCompare($1.filename) == .orderedDescending }
        case .sizeDescending:
            return resourcesManager.resources.sorted { $0.size > $1.size }
        case .sizeAscending:
            return resourcesManager.resources.sorted { $0.size < $1.size }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            ResourcesToolbar(
                sortOrder: $sortOrder,
                onRefresh: { resourcesManager.refreshResources() },
                onAddFiles: { showingFilePicker = true },
                isLoading: resourcesManager.isLoadingResources
            )

            Divider()

            // Content area with drag-and-drop
            ZStack {
                if resourcesManager.resources.isEmpty && resourcesManager.uploadProgress.isEmpty {
                    EmptyResourcesView(
                        isDragOver: isDragOver,
                        onAddFiles: { showingFilePicker = true }
                    )
                } else {
                    ResourcesListView(
                        resources: sortedResources,
                        uploadProgress: resourcesManager.uploadProgress,
                        onDelete: { resource in
                            resourceToDelete = resource
                            showingDeleteConfirmation = true
                        },
                        onClearCompleted: { resourcesManager.clearCompletedUploads() }
                    )
                }

                // Drag overlay
                if isDragOver {
                    DragOverlayView()
                }
            }
            .onDrop(of: [.fileURL], isTargeted: $isDragOver) { providers in
                handleDrop(providers: providers)
            }
        }
        .frame(minWidth: 300)
        .navigationTitle("Resources")
        .fileImporter(
            isPresented: $showingFilePicker,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            handleFileImport(result: result)
        }
        .alert("Delete Resource?", isPresented: $showingDeleteConfirmation) {
            Button("Cancel", role: .cancel) {
                resourceToDelete = nil
            }
            Button("Delete", role: .destructive) {
                if let resource = resourceToDelete {
                    resourcesManager.deleteResource(resource)
                }
                resourceToDelete = nil
            }
        } message: {
            if let resource = resourceToDelete {
                Text("Are you sure you want to delete \"\(resource.filename)\"? This cannot be undone.")
            }
        }
        .onAppear {
            resourcesManager.refreshResources()
        }
    }

    // MARK: - Drop Handling

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        var urls: [URL] = []

        let group = DispatchGroup()

        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                group.enter()
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                    defer { group.leave() }

                    if let data = item as? Data,
                       let url = URL(dataRepresentation: data, relativeTo: nil) {
                        urls.append(url)
                    } else if let url = item as? URL {
                        urls.append(url)
                    }
                }
            }
        }

        group.notify(queue: .main) {
            if !urls.isEmpty {
                logger.info("📥 Dropped \(urls.count) file(s)")
                resourcesManager.uploadFiles(urls)
            }
        }

        return true
    }

    private func handleFileImport(result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            logger.info("📁 Selected \(urls.count) file(s) from picker")
            resourcesManager.uploadFiles(urls)
        case .failure(let error):
            logger.error("❌ File import failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - ResourcesToolbar

struct ResourcesToolbar: View {
    @Binding var sortOrder: ResourcesView.ResourceSortOrder
    let onRefresh: () -> Void
    let onAddFiles: () -> Void
    let isLoading: Bool

    var body: some View {
        HStack {
            // Sort menu
            Menu {
                ForEach(ResourcesView.ResourceSortOrder.allCases, id: \.self) { order in
                    Button(action: { sortOrder = order }) {
                        HStack {
                            Text(order.rawValue)
                            if sortOrder == order {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                Label("Sort", systemImage: "arrow.up.arrow.down")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Spacer()

            // Refresh button
            Button(action: onRefresh) {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(.borderless)
            .disabled(isLoading)
            .help("Refresh resources")
            .accessibilityLabel("Refresh resources")

            // Add files button
            Button(action: onAddFiles) {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .help("Add files")
            .accessibilityLabel("Add files")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

// MARK: - EmptyResourcesView

struct EmptyResourcesView: View {
    let isDragOver: Bool
    let onAddFiles: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: isDragOver ? "arrow.down.doc.fill" : "doc.badge.plus")
                .font(.system(size: 48))
                .foregroundColor(isDragOver ? .accentColor : .secondary)
                .animation(.easeInOut(duration: 0.2), value: isDragOver)

            Text(isDragOver ? "Drop files here" : "No Resources")
                .font(.title3)
                .foregroundColor(isDragOver ? .accentColor : .secondary)

            if !isDragOver {
                Text("Drag and drop files here or click the button below")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)

                Button("Add Files...") {
                    onAddFiles()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

// MARK: - ResourcesListView

struct ResourcesListView: View {
    let resources: [Resource]
    let uploadProgress: [UploadProgress]
    let onDelete: (Resource) -> Void
    let onClearCompleted: () -> Void

    var body: some View {
        List {
            // Upload progress section
            if !uploadProgress.isEmpty {
                Section {
                    ForEach(uploadProgress) { upload in
                        UploadProgressRowView(upload: upload)
                    }
                } header: {
                    HStack {
                        Text("Uploads")
                        Spacer()
                        if uploadProgress.contains(where: { $0.isComplete }) {
                            Button("Clear Completed") {
                                onClearCompleted()
                            }
                            .font(.caption)
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }

            // Resources section
            if !resources.isEmpty {
                Section {
                    ForEach(resources) { resource in
                        ResourceRowView(resource: resource)
                            .contextMenu {
                                Button("Delete") {
                                    onDelete(resource)
                                }
                            }
                    }
                } header: {
                    Text("Files (\(resources.count))")
                }
            }
        }
        .listStyle(.inset)
    }
}

// MARK: - ResourceRowView

struct ResourceRowView: View {
    let resource: Resource

    var body: some View {
        HStack(spacing: 12) {
            // File type icon
            Image(systemName: iconForFile(resource.filename))
                .font(.title2)
                .foregroundColor(.secondary)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                // Filename
                Text(resource.filename)
                    .font(.body)
                    .lineLimit(1)

                // Size and timestamp
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
        .contentShape(Rectangle())
    }

    private func iconForFile(_ filename: String) -> String {
        let ext = (filename as NSString).pathExtension.lowercased()

        switch ext {
        case "pdf":
            return "doc.richtext"
        case "jpg", "jpeg", "png", "gif", "heic", "webp":
            return "photo"
        case "mp4", "mov", "avi", "mkv":
            return "film"
        case "mp3", "wav", "aac", "m4a":
            return "music.note"
        case "zip", "tar", "gz", "rar":
            return "doc.zipper"
        case "txt", "md", "rtf":
            return "doc.text"
        case "swift", "py", "js", "ts", "java", "clj", "cljs":
            return "chevron.left.forwardslash.chevron.right"
        case "json", "xml", "yaml", "yml":
            return "curlybraces"
        default:
            return "doc"
        }
    }
}

// MARK: - UploadProgressRowView

struct UploadProgressRowView: View {
    let upload: UploadProgress

    var body: some View {
        HStack(spacing: 12) {
            // Status icon
            statusIcon
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 4) {
                // Filename
                Text(upload.filename)
                    .font(.body)
                    .lineLimit(1)

                // Progress bar or status text
                switch upload.status {
                case .pending:
                    Text("Pending...")
                        .font(.caption)
                        .foregroundColor(.secondary)

                case .uploading:
                    HStack(spacing: 8) {
                        ProgressView(value: upload.progress)
                            .progressViewStyle(.linear)
                            .frame(maxWidth: 150)

                        Text("\(Int(upload.progress * 100))%")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }

                case .completed:
                    Text("Completed")
                        .font(.caption)
                        .foregroundColor(.green)

                case .failed(let error):
                    Text("Failed: \(error)")
                        .font(.caption)
                        .foregroundColor(.red)
                        .lineLimit(1)
                }
            }

            Spacer()
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch upload.status {
        case .pending:
            Image(systemName: "clock")
                .foregroundColor(.secondary)
                .font(.title2)
        case .uploading:
            ProgressView()
                .controlSize(.small)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
                .font(.title2)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundColor(.red)
                .font(.title2)
        }
    }
}

// MARK: - DragOverlayView

struct DragOverlayView: View {
    var body: some View {
        ZStack {
            Color.accentColor.opacity(0.1)

            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8]))
                .padding(16)

            VStack(spacing: 8) {
                Image(systemName: "arrow.down.doc.fill")
                    .font(.system(size: 40))
                    .foregroundColor(.accentColor)

                Text("Drop files to upload")
                    .font(.headline)
                    .foregroundColor(.accentColor)
            }
        }
    }
}

// MARK: - Preview

#Preview("With Resources") {
    let settings = AppSettings()
    let client = VoiceCodeClient(serverURL: "ws://localhost:8080", setupObservers: false)
    let manager = ResourcesManager(client: client, appSettings: settings)

    return ResourcesView(resourcesManager: manager, settings: settings)
        .frame(width: 350, height: 500)
}

#Preview("Empty State") {
    let settings = AppSettings()
    let client = VoiceCodeClient(serverURL: "ws://localhost:8080", setupObservers: false)
    let manager = ResourcesManager(client: client, appSettings: settings)

    return ResourcesView(resourcesManager: manager, settings: settings)
        .frame(width: 350, height: 500)
}
