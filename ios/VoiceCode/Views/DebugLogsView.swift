// DebugLogsView.swift
// Debug view for viewing and copying app logs

import SwiftUI
import OSLog
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct DebugLogsView: View {
    @State private var logs: String = "Loading logs..."
    @State private var isLoadingSystemLogs = false
    @State private var showingCopyConfirmation = false
    @State private var logSource: LogSource = .system

    enum LogSource: String, CaseIterable {
        case system = "System Logs"
        case captured = "Captured Logs"
        case renderStats = "Render Stats"
    }

    var body: some View {
        let _ = RenderTracker.count(Self.self)
        VStack(spacing: 0) {
            // Log source picker
            Picker("Log Source", selection: $logSource) {
                ForEach(LogSource.allCases, id: \.self) { source in
                    Text(source.rawValue).tag(source)
                }
            }
            .pickerStyle(.segmented)
            .padding()
            .onChange(of: logSource) { _, _ in
                loadLogs()
            }

            // Logs display
            ScrollView {
                Text(logs)
                    .font(.system(size: 10, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            #if os(iOS)
            .background(Color(UIColor.systemGroupedBackground))
            #elseif os(macOS)
            .background(Color(NSColor.windowBackgroundColor))
            #endif

            // Action buttons
            HStack(spacing: 16) {
                if logSource == .renderStats {
                    // Reset button for render stats
                    Button(action: {
                        RenderTracker.reset()
                        loadRenderStats()
                    }) {
                        HStack {
                            Image(systemName: "trash")
                            Text("Reset Stats")
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.red.opacity(0.8))
                        .foregroundColor(.white)
                        .cornerRadius(10)
                    }
                } else {
                    // Copy button for logs
                    Button(action: {
                        copyLogs()
                    }) {
                        HStack {
                            Image(systemName: "doc.on.clipboard")
                            Text("Copy Last 15KB")
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                    }
                }

                Button(action: {
                    loadLogs()
                }) {
                    HStack {
                        Image(systemName: "arrow.clockwise")
                        Text("Refresh")
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.gray.opacity(0.2))
                    .foregroundColor(.primary)
                    .cornerRadius(10)
                }
            }
            .padding()
        }
        .navigationTitle("Debug Logs")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .overlay(alignment: .top) {
            if showingCopyConfirmation {
                Text("Last 15KB of logs copied to clipboard")
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
        .onAppear {
            loadLogs()
        }
    }

    private func loadLogs() {
        switch logSource {
        case .system:
            loadSystemLogs()
        case .captured:
            loadCapturedLogs()
        case .renderStats:
            loadRenderStats()
        }
    }

    private func loadSystemLogs() {
        isLoadingSystemLogs = true
        logs = "Loading system logs..."

        Task {
            do {
                let systemLogs = try await LogManager.shared.getSystemLogs(maxBytes: 50_000)
                await MainActor.run {
                    if systemLogs.isEmpty {
                        logs = "No system logs available.\n\nNote: System logs from OSLog may require device connection to Xcode Console."
                    } else {
                        logs = systemLogs
                    }
                    isLoadingSystemLogs = false
                }
            } catch {
                await MainActor.run {
                    logs = "Failed to load system logs: \(error.localizedDescription)\n\nTry using Xcode Console instead:\n1. Connect device to Mac\n2. Open Xcode → Window → Devices and Simulators\n3. Select your device → Open Console\n4. Filter by 'VoiceCode' process"
                    isLoadingSystemLogs = false
                }
            }
        }
    }

    private func loadCapturedLogs() {
        let capturedLogs = LogManager.shared.getAllLogs()
        if capturedLogs.isEmpty {
            logs = "No captured logs yet.\n\nLogs are captured when you call:\nLogManager.shared.log(\"Your message\", category: \"Category\")"
        } else {
            logs = capturedLogs
        }
    }

    private func loadRenderStats() {
        logs = RenderTracker.generateReport()
    }

    private func copyLogs() {
        let logsToCopy: String

        switch logSource {
        case .system:
            // Get last 15KB of system logs
            Task {
                do {
                    let systemLogs = try await LogManager.shared.getSystemLogs(maxBytes: 15_000)
                    await MainActor.run {
                        ClipboardUtility.copy(systemLogs)
                        showCopyConfirmation()
                    }
                } catch {
                    await MainActor.run {
                        // Fallback to current view content
                        ClipboardUtility.copy(String(logs.suffix(15_000)))
                        showCopyConfirmation()
                    }
                }
            }
        case .captured:
            logsToCopy = LogManager.shared.getRecentLogs(maxBytes: 15_000)
            ClipboardUtility.copy(logsToCopy)
            showCopyConfirmation()
        case .renderStats:
            // Render stats don't use copy button (has reset button instead)
            break
        }
    }

    private func showCopyConfirmation() {
        // Trigger haptic feedback
        ClipboardUtility.triggerSuccessHaptic()

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

struct DebugLogsView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack {
            DebugLogsView()
        }
    }
}
