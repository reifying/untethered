// ResourceShareView.swift
// Interface for sharing files directly from within the app

import SwiftUI
import UniformTypeIdentifiers
import CoreData
#if os(iOS)
import UIKit
#endif

struct ResourceShareView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @ObservedObject var resourcesManager: ResourcesManager
    #if os(iOS)
    @State private var showingDocumentPicker = false
    @State private var showingSessionPicker = false
    @State private var selectedFileURL: URL?
    @State private var showingError = false
    @State private var errorMessage = ""
    #endif

    var body: some View {
        #if os(iOS)
        VStack(spacing: 24) {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 64))
                .foregroundColor(.blue)

            Text("Share a File")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Select a file from your device to upload to your session.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Button(action: {
                showingDocumentPicker = true
            }) {
                Label("Choose File", systemImage: "folder")
                    .font(.headline)
                    .foregroundColor(.white)
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(Color.blue)
                    .cornerRadius(12)
            }
            .padding(.horizontal, 40)

            Spacer()
        }
        .padding(.top, 60)
        .sheet(isPresented: $showingDocumentPicker) {
            DocumentPicker { url in
                selectedFileURL = url
                showingSessionPicker = true
            }
        }
        .sheet(isPresented: $showingSessionPicker) {
            ResourceSessionPickerView(
                onSelect: { session in
                    showingSessionPicker = false
                    if let fileURL = selectedFileURL {
                        uploadFile(fileURL: fileURL, toSession: session)
                    }
                },
                onCancel: {
                    showingSessionPicker = false
                    selectedFileURL = nil
                }
            )
            .environment(\.managedObjectContext, viewContext)
        }
        .alert("Upload Error", isPresented: $showingError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(errorMessage)
        }
        #else
        // macOS: File sharing feature not available in MVP
        VStack(spacing: 24) {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 64))
                .foregroundColor(.secondary)

            Text("File Sharing")
                .font(.title2)
                .fontWeight(.semibold)

            Text("File sharing from the app is not yet available on macOS.\n\nUse the iOS Share Extension to share files to your sessions.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Spacer()
        }
        .padding(.top, 60)
        #endif
    }

    #if os(iOS)
    private func uploadFile(fileURL: URL, toSession session: CDBackendSession) {
        // Access security-scoped resource
        guard fileURL.startAccessingSecurityScopedResource() else {
            errorMessage = "Failed to access file"
            showingError = true
            return
        }

        defer {
            fileURL.stopAccessingSecurityScopedResource()
        }

        // Read file data
        let fileData: Data
        do {
            fileData = try Data(contentsOf: fileURL)
        } catch {
            errorMessage = "Failed to read file: \(error.localizedDescription)"
            showingError = true
            return
        }

        // Save to App Group pending-uploads
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.910labs.untethered.resources"
        ) else {
            errorMessage = "Failed to access App Group container"
            showingError = true
            return
        }

        let pendingUploadsURL = containerURL.appendingPathComponent("pending-uploads", isDirectory: true)

        // Create directory if needed
        do {
            try FileManager.default.createDirectory(at: pendingUploadsURL, withIntermediateDirectories: true)
        } catch {
            errorMessage = "Failed to create uploads directory: \(error.localizedDescription)"
            showingError = true
            return
        }

        // Generate unique ID
        let uploadId = UUID().uuidString.lowercased()

        // Save file data
        let dataFileURL = pendingUploadsURL.appendingPathComponent("\(uploadId).data")
        do {
            try fileData.write(to: dataFileURL)
        } catch {
            errorMessage = "Failed to write file: \(error.localizedDescription)"
            showingError = true
            return
        }

        // Save metadata with session ID
        let metadata: [String: Any] = [
            "id": uploadId,
            "filename": fileURL.lastPathComponent,
            "size": fileData.count,
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "session_id": session.id.uuidString.lowercased()
        ]

        let metadataFileURL = pendingUploadsURL.appendingPathComponent("\(uploadId).json")
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: metadata, options: .prettyPrinted)
            try jsonData.write(to: metadataFileURL)
        } catch {
            errorMessage = "Failed to write metadata: \(error.localizedDescription)"
            showingError = true
            return
        }

        // Update pending count and trigger processing
        resourcesManager.updatePendingCount()
        resourcesManager.processPendingUploads()

        print("✅ [ResourceShareView] File saved for upload: \(fileURL.lastPathComponent) -> session \(session.displayName)")
    }
    #endif
}

#if os(iOS)
// MARK: - Document Picker

struct DocumentPicker: UIViewControllerRepresentable {
    let onSelect: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onSelect: onSelect)
    }

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onSelect: (URL) -> Void

        init(onSelect: @escaping (URL) -> Void) {
            self.onSelect = onSelect
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            onSelect(url)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            // User cancelled - do nothing
        }
    }
}
#endif
