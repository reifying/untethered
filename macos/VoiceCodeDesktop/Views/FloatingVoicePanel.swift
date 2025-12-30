// FloatingVoicePanel.swift
// Floating panel for quick voice input with waveform visualization per Appendix Y.4

import SwiftUI
import OSLog

private let logger = Logger(subsystem: "dev.910labs.voice-code-desktop", category: "FloatingVoicePanel")

// MARK: - WaveformView

/// Visualizes real-time audio levels as animated bars for waveform display
struct WaveformView: View {
    /// Audio levels from AVAudioEngine tap (0-1 normalized)
    let levels: [Float]

    /// Maximum height of waveform bars
    var maxHeight: CGFloat = 40

    /// Minimum height for bars (ensures visibility even at 0 level)
    var minHeight: CGFloat = 2

    var body: some View {
        HStack(spacing: 2) {
            ForEach(levels.indices, id: \.self) { index in
                WaveformBar(level: levels[index], maxHeight: maxHeight, minHeight: minHeight)
            }
        }
    }
}

/// Individual bar in the waveform visualization
struct WaveformBar: View {
    let level: Float
    let maxHeight: CGFloat
    let minHeight: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(Color.accentColor)
            .frame(width: 4, height: barHeight)
            .animation(.easeOut(duration: 0.1), value: level)
    }

    private var barHeight: CGFloat {
        let height = CGFloat(level) * maxHeight
        return max(minHeight, height)
    }
}

// MARK: - FloatingVoicePanel

/// Floating panel for less intrusive voice input with waveform and live transcription preview
struct FloatingVoicePanel: View {
    @ObservedObject var voiceInput: VoiceInputManager
    @Environment(\.dismiss) private var dismiss

    /// Callback when transcription is completed and accepted
    var onTranscriptionAccepted: ((String) -> Void)?

    /// Callback when panel is cancelled
    var onCancel: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            // Waveform visualization
            WaveformPlaceholder(levels: voiceInput.audioLevels)
                .frame(height: 40)

            // Transcription preview
            TranscriptionPreview(text: voiceInput.partialTranscription)

            // Status and controls
            StatusControls(
                isRecording: voiceInput.isRecording,
                onCancel: handleCancel,
                onAccept: handleAccept
            )
        }
        .padding()
        .frame(width: 400)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.2), radius: 10, x: 0, y: 5)
        .onAppear {
            logger.debug("FloatingVoicePanel appeared")
            startRecordingIfNeeded()
        }
        .onDisappear {
            logger.debug("FloatingVoicePanel disappeared")
            stopRecordingIfNeeded()
        }
    }

    // MARK: - Actions

    private func startRecordingIfNeeded() {
        if !voiceInput.isRecording {
            voiceInput.startRecording()
        }
    }

    private func stopRecordingIfNeeded() {
        if voiceInput.isRecording {
            voiceInput.stopRecording()
        }
    }

    private func handleCancel() {
        logger.info("Voice input cancelled")
        stopRecordingIfNeeded()
        onCancel?()
        dismiss()
    }

    private func handleAccept() {
        let text = voiceInput.partialTranscription.isEmpty
            ? voiceInput.transcribedText
            : voiceInput.partialTranscription
        logger.info("Voice input accepted: \(text.prefix(50))...")
        stopRecordingIfNeeded()
        onTranscriptionAccepted?(text)
        dismiss()
    }
}

// MARK: - Subviews

/// Waveform visualization with placeholder for empty state
private struct WaveformPlaceholder: View {
    let levels: [Float]

    var body: some View {
        if levels.isEmpty {
            // Empty state - show placeholder bars
            HStack(spacing: 2) {
                ForEach(0..<20, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.secondary.opacity(0.3))
                        .frame(width: 4, height: 2)
                }
            }
        } else {
            WaveformView(levels: levels)
        }
    }
}

/// Preview area showing partial transcription
private struct TranscriptionPreview: View {
    let text: String

    var body: some View {
        Group {
            if text.isEmpty {
                Text("Listening...")
                    .foregroundColor(.secondary)
                    .font(.system(.body, design: .monospaced))
            } else {
                Text(text)
                    .font(.system(.body, design: .monospaced))
            }
        }
        .lineLimit(3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.secondary.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

/// Status indicator and control buttons
private struct StatusControls: View {
    let isRecording: Bool
    let onCancel: () -> Void
    let onAccept: () -> Void

    var body: some View {
        HStack {
            // Recording indicator
            Circle()
                .fill(isRecording ? .red : .gray)
                .frame(width: 8, height: 8)
                .opacity(isRecording ? 1 : 0.5)

            Text(isRecording ? "Listening..." : "Stopped")
                .foregroundColor(.secondary)
                .font(.caption)

            Spacer()

            // Cancel button
            Button("Cancel") {
                onCancel()
            }
            .keyboardShortcut(.escape, modifiers: [])
            .buttonStyle(.plain)
            .foregroundColor(.secondary)

            // Accept button
            Button("Accept") {
                onAccept()
            }
            .keyboardShortcut(.return, modifiers: [])
            .buttonStyle(.borderedProminent)
        }
    }
}

// MARK: - FloatingVoicePanelController

/// Controller for managing the floating voice panel window
@MainActor
class FloatingVoicePanelController: ObservableObject {
    @Published private(set) var isVisible = false

    private var window: NSPanel?
    private var panelDelegate: PanelDelegate?  // Strong reference to prevent deallocation
    private let voiceInput: VoiceInputManager

    /// Callback when transcription is completed
    var onTranscriptionComplete: ((String) -> Void)?

    init(voiceInput: VoiceInputManager) {
        self.voiceInput = voiceInput
    }

    /// Show the floating voice panel
    func show() {
        guard window == nil else {
            // Already showing, bring to front
            window?.makeKeyAndOrderFront(nil)
            return
        }

        let panel = createPanel()
        self.window = panel
        isVisible = true

        // Position near top center of screen
        positionPanel(panel)

        panel.makeKeyAndOrderFront(nil)
        logger.info("FloatingVoicePanel shown")
    }

    /// Hide and clean up the floating voice panel
    func hide() {
        window?.close()
        window = nil
        isVisible = false
        logger.info("FloatingVoicePanel hidden")
    }

    /// Toggle visibility
    func toggle() {
        if isVisible {
            hide()
        } else {
            show()
        }
    }

    // MARK: - Private

    private func createPanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 150),
            styleMask: [.nonactivatingPanel, .titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.hasShadow = true

        // Create the SwiftUI content
        let contentView = FloatingVoicePanel(voiceInput: voiceInput) { [weak self] text in
            self?.onTranscriptionComplete?(text)
            self?.hide()
        } onCancel: { [weak self] in
            self?.hide()
        }

        panel.contentView = NSHostingView(rootView: contentView)

        // Handle window close button - store delegate to prevent deallocation
        let delegate = PanelDelegate { [weak self] in
            self?.isVisible = false
            self?.window = nil
            self?.panelDelegate = nil
        }
        self.panelDelegate = delegate
        panel.delegate = delegate

        return panel
    }

    private func positionPanel(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }

        let screenFrame = screen.visibleFrame
        let panelFrame = panel.frame

        // Position near top center
        let x = screenFrame.midX - panelFrame.width / 2
        let y = screenFrame.maxY - panelFrame.height - 100 // 100px from top

        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

// MARK: - PanelDelegate

/// Delegate to handle panel close events
private class PanelDelegate: NSObject, NSWindowDelegate {
    private let onClose: () -> Void

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}

// MARK: - Previews

#Preview("WaveformView") {
    WaveformView(levels: [0.2, 0.5, 0.8, 0.3, 0.6, 0.9, 0.4, 0.7, 0.2, 0.5])
        .padding()
}

#Preview("WaveformView Empty") {
    WaveformView(levels: [])
        .padding()
}

#Preview("FloatingVoicePanel") {
    FloatingVoicePanel(voiceInput: VoiceInputManager())
        .frame(width: 420)
}
