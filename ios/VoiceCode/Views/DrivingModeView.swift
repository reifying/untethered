// DrivingModeView.swift
// The driving-mode screen of the Mac app. See notes/mac-driving-mode.md.
//
// Built for someone who cannot look at it. Everything is a horizontal band the
// full width of the window: a status strip, one band per recent reply (the top
// one is always the newest), and a talk bar. A click anywhere in a reply's band
// reads that reply again. The bands come from DrivingModeLayout, which sizes
// them from the window alone, so no amount of text can move a control or push
// one off the screen.

#if os(macOS)
import SwiftUI
import AppKit

struct DrivingModeView: View {
    @ObservedObject var controller: DrivingModeController
    @ObservedObject var client: VoiceCodeClient
    @ObservedObject var settings: AppSettings
    @ObservedObject var voiceInput: VoiceInputManager
    @EnvironmentObject private var headsetManager: HeadsetRemoteCommandManager

    var body: some View {
        GeometryReader { geometry in
            let count = DrivingModeLayout.clampedReplayCount(settings.drivingReplayCount)
            let bands = DrivingModeLayout.bands(in: geometry.size, replayCount: count)
            VStack(spacing: 0) {
                DrivingStatusStrip(controller: controller, client: client, headsetManager: headsetManager)
                    .frame(width: bands.status.width, height: bands.status.height)

                ForEach(0..<count, id: \.self) { index in
                    DrivingReplyTile(
                        index: index,
                        reply: controller.replies.indices.contains(index) ? controller.replies[index] : nil,
                        isLastReplayed: controller.replies.indices.contains(index)
                            && controller.replies[index].id == controller.lastReplayedId,
                        size: bands.tiles[index].size,
                        action: { controller.replay(index: index) }
                    )
                    .frame(width: bands.tiles[index].width, height: bands.tiles[index].height)
                }

                DrivingTalkBar(voiceInput: voiceInput,
                               state: headsetManager.state,
                               size: bands.talk.size,
                               action: { headsetManager.toggleRecordingFromUI() })
                    .frame(width: bands.talk.width, height: bands.talk.height)
            }
        }
        // A tiny minimum, and nothing inside with a size of its own: the window is
        // never made larger than the screen by what this view contains.
        .frame(minWidth: DrivingModeLayout.minimumSize.width, minHeight: DrivingModeLayout.minimumSize.height)
        .background(Color.black)
        .background(
            DrivingWindowPinner(
                keepOnTop: settings.drivingKeepOnTop,
                healthTick: controller.healthTick,
                onKey: handleKey
            )
        )
        .onAppear { controller.assertWiring() }
    }

    /// Keys that work without aiming a pointer: a digit replays that tile, Space
    /// is the talk bar. Returns whether the key was used.
    private func handleKey(_ key: DrivingKey) -> Bool {
        switch key {
        case .replay(let index):
            guard index < DrivingModeLayout.clampedReplayCount(settings.drivingReplayCount) else { return false }
            controller.replay(index: index)
            return true
        case .talk:
            headsetManager.toggleRecordingFromUI()
            return true
        }
    }
}

// MARK: - Status strip

private struct DrivingStatusStrip: View {
    @ObservedObject var controller: DrivingModeController
    @ObservedObject var client: VoiceCodeClient
    @ObservedObject var headsetManager: HeadsetRemoteCommandManager

    var body: some View {
        GeometryReader { geometry in
            let font = Font.system(size: max(geometry.size.height * 0.36, 11), weight: .semibold)
            HStack(spacing: 14) {
                Circle()
                    .fill(client.isConnected ? Color.green : Color.red)
                    .frame(width: geometry.size.height * 0.3, height: geometry.size.height * 0.3)
                Text(client.isConnected ? "Connected" : "Offline")
                    .foregroundColor(client.isConnected ? .white : .red)
                Text(DrivingStateLabel.text(for: headsetManager.state))
                    .foregroundColor(DrivingStateLabel.color(for: headsetManager.state))
                Text(controller.sessionId == nil ? "No session" : controller.sessionName)
                    .foregroundColor(.white.opacity(0.75))
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                Button("Exit Driving Mode") { controller.exit() }
                    .help("Leave driving mode (Cmd+Shift+D)")
                    .accessibilityIdentifier("drivingExitButton")
            }
            .font(font)
            .lineLimit(1)
            .padding(.horizontal, 16)
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .background(Color(white: 0.12))
    }
}

/// How the headset state reads on the status strip.
enum DrivingStateLabel {
    static func text(for state: SessionState) -> String {
        switch state {
        case .idle: return "READY"
        case .recording: return "LISTENING"
        case .finalizing: return "SENDING"
        case .awaitingResponse: return "WAITING"
        case .speaking: return "SPEAKING"
        }
    }

    static func color(for state: SessionState) -> Color {
        switch state {
        case .idle: return .white
        case .recording: return .red
        case .finalizing, .awaitingResponse: return .orange
        case .speaking: return .green
        }
    }
}

// MARK: - Reply tile

private struct DrivingReplyTile: View {
    let index: Int
    let reply: RecentReply?
    let isLastReplayed: Bool
    let size: CGSize
    let action: () -> Void

    var body: some View {
        let numberSize = max(min(size.height * 0.55, size.width * 0.14), 18)
        let titleSize = max(min(size.height * 0.16, 30), 11)
        let textSize = max(min(size.height * 0.13, 24), 10)
        HStack(alignment: .center, spacing: 18) {
            Text("\(index + 1)")
                .font(.system(size: numberSize, weight: .bold, design: .rounded))
                .foregroundColor(reply == nil ? .white.opacity(0.25) : .white)
                .frame(width: numberSize * 1.1)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) {
                    Text(DrivingModeLayout.tileTitle(index: index))
                        .font(.system(size: titleSize, weight: .semibold))
                        .foregroundColor(.white.opacity(reply == nil ? 0.35 : 0.9))
                    if let reply {
                        Text(reply.timestamp, style: .time)
                            .font(.system(size: titleSize * 0.8))
                            .foregroundColor(.white.opacity(0.6))
                    }
                }
                Text(reply.map(DrivingReplyPreview.text) ?? "Nothing here yet")
                    .font(.system(size: textSize))
                    .foregroundColor(.white.opacity(reply == nil ? 0.3 : 0.8))
                    .multilineTextAlignment(.leading)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 6)
        // The text is clipped to the tile. It can never ask for more room.
        .frame(width: size.width, height: size.height, alignment: .leading)
        .clipped()
        .background(isLastReplayed ? Color.blue.opacity(0.55) : Self.backgrounds[index % Self.backgrounds.count])
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.white.opacity(0.15)).frame(height: 1)
        }
        .overlay(
            FirstClickArea(label: "Replay \(DrivingModeLayout.tileTitle(index: index).lowercased())",
                           identifier: "drivingReplayTile\(index + 1)",
                           action: action)
        )
    }

    private static let backgrounds = [Color(white: 0.20), Color(white: 0.15), Color(white: 0.10)]

}

/// The few words of a reply a tile shows.
enum DrivingReplyPreview {
    /// How much of a reply is laid out. The tile shows a few lines; laying out
    /// thousands of characters only to truncate them is wasted work on every redraw.
    static let length = 400

    static func text(of reply: RecentReply) -> String {
        let flat = reply.text
            .prefix(length)
            .split(whereSeparator: \.isNewline)
            .joined(separator: " ")
        return reply.text.count > length ? flat + "…" : flat
    }
}

// MARK: - Talk bar

private struct DrivingTalkBar: View {
    @ObservedObject var voiceInput: VoiceInputManager
    let state: SessionState
    let size: CGSize
    let action: () -> Void

    var body: some View {
        let recording = state == .recording
        let labelSize = max(min(size.height * 0.34, 34), 12)
        HStack(spacing: 16) {
            Image(systemName: recording ? "mic.fill" : "mic")
                .font(.system(size: labelSize * 1.2, weight: .bold))
            Text(recording ? "LISTENING — CLICK OR PRESS SPACE TO SEND" : "CLICK OR PRESS SPACE TO TALK")
                .font(.system(size: labelSize, weight: .bold))
            if recording, !voiceInput.transcribedText.isEmpty {
                // One line, newest words kept. A long dictation cannot grow the bar.
                Text(voiceInput.transcribedText.suffix(120))
                    .font(.system(size: labelSize * 0.7))
                    .truncationMode(.head)
                    .opacity(0.85)
            }
            Spacer(minLength: 0)
        }
        .lineLimit(1)
        .foregroundColor(.white)
        .padding(.horizontal, 20)
        .frame(width: size.width, height: size.height, alignment: .leading)
        .clipped()
        .background(recording ? Color.red.opacity(0.75) : Color.blue.opacity(0.6))
        .overlay(
            FirstClickArea(label: recording ? "Stop and send" : "Talk",
                           identifier: "drivingTalkBar",
                           action: action)
        )
    }
}

// MARK: - A click target that works on the first click

/// A transparent click target that acts on the first click even when the app is
/// not the active one. A plain SwiftUI button in an inactive window spends the
/// first click on activating the window, so a driver who clicked once would hear
/// nothing and have to click again.
private struct FirstClickArea: NSViewRepresentable {
    let label: String
    let identifier: String
    let action: () -> Void

    func makeNSView(context: Context) -> FirstClickNSView {
        let view = FirstClickNSView()
        view.action = action
        view.label = label
        view.setAccessibilityIdentifier(identifier)
        return view
    }

    func updateNSView(_ view: FirstClickNSView, context: Context) {
        view.action = action
        view.label = label
    }
}

final class FirstClickNSView: NSView {
    var action: (() -> Void)?
    var label = ""

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        action?()
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { label }
    override func accessibilityPerformPress() -> Bool {
        action?()
        return true
    }
}

// MARK: - Keeping the window on the screen

/// A key the driving screen acts on.
enum DrivingKey: Equatable {
    case replay(Int)   // zero-based tile
    case talk

    /// Map a key press to a driving key. Only bare keys count: with Command,
    /// Control or Option held the press belongs to a menu shortcut.
    static func from(characters: String?, modifiers: NSEvent.ModifierFlags) -> DrivingKey? {
        guard modifiers.intersection([.command, .control, .option]).isEmpty,
              let characters, characters.count == 1, let character = characters.first else { return nil }
        if character == " " { return .talk }
        if let digit = character.wholeNumberValue, (1...9).contains(digit) { return .replay(digit - 1) }
        return nil
    }
}

/// Puts the driving window where it can be reached and keeps it there: filling
/// the visible screen on entry, above other windows, and moved back whenever any
/// part of it is found outside the screen (a display unplugged, a resolution
/// change, a stray drag). Also listens for the driving keys. Restores the
/// window's frame and level when driving mode ends.
private struct DrivingWindowPinner: NSViewRepresentable {
    let keepOnTop: Bool
    let healthTick: Int
    let onKey: (DrivingKey) -> Bool

    func makeNSView(context: Context) -> DrivingPinnerNSView {
        let view = DrivingPinnerNSView()
        view.keepOnTop = keepOnTop
        view.onKey = onKey
        return view
    }

    func updateNSView(_ view: DrivingPinnerNSView, context: Context) {
        view.onKey = onKey
        view.keepOnTop = keepOnTop
        // Runs on every health tick (and any other update): cheap, and idempotent.
        view.applyLevel()
        view.repinIfNeeded(reason: "check")
    }

    static func dismantleNSView(_ view: DrivingPinnerNSView, coordinator: ()) {
        view.restore()
    }
}

final class DrivingPinnerNSView: NSView {
    var keepOnTop = true
    var onKey: ((DrivingKey) -> Bool)?

    private weak var pinnedWindow: NSWindow?
    private var savedFrame: NSRect?
    private var savedLevel: NSWindow.Level?
    private var observers: [NSObjectProtocol] = []
    private var keyMonitor: Any?

    private func log(_ message: String) {
        LogManager.shared.log(message, category: "DrivingMode")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            pin(window)
        } else {
            restore()
        }
    }

    private func pin(_ window: NSWindow) {
        guard pinnedWindow !== window else { return }
        restore()
        pinnedWindow = window
        savedFrame = window.frame
        savedLevel = window.level
        applyLevel()
        fill(reason: "entered driving mode")

        let center = NotificationCenter.default
        let repin: (Notification) -> Void = { [weak self] note in
            self?.repinIfNeeded(reason: note.name.rawValue)
        }
        observers = [
            center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main, using: repin),
            center.addObserver(forName: NSWindow.didChangeScreenNotification, object: window, queue: .main, using: repin),
            center.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main, using: repin),
            center.addObserver(forName: NSWindow.didMoveNotification, object: window, queue: .main, using: repin)
        ]
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let pinned = self.pinnedWindow, event.window === pinned,
                  let key = DrivingKey.from(characters: event.charactersIgnoringModifiers, modifiers: event.modifierFlags),
                  self.onKey?(key) == true else { return event }
            return nil
        }
    }

    func applyLevel() {
        guard let window = pinnedWindow, let savedLevel else { return }
        let wanted: NSWindow.Level = keepOnTop ? .floating : savedLevel
        if window.level != wanted { window.level = wanted }
    }

    /// Fill the visible part of the screen the window is on. Skipped in native
    /// full screen, where the window already covers its display.
    private func fill(reason: String) {
        guard let window = pinnedWindow, !window.styleMask.contains(.fullScreen),
              let screen = window.screen ?? NSScreen.main else { return }
        let target = DrivingModeLayout.pinnedFrame(visibleFrame: screen.visibleFrame)
        guard window.frame != target else { return }
        log("window \(reason): frame \(Self.describe(window.frame)) → \(Self.describe(target))")
        window.setFrame(target, display: true)
        if window.frame != target {
            log("window is at \(Self.describe(window.frame)) after asking for \(Self.describe(target)); min \(window.minSize) max \(window.maxSize)")
        }
    }

    func repinIfNeeded(reason: String) {
        guard let window = pinnedWindow, !window.styleMask.contains(.fullScreen),
              let screen = window.screen ?? NSScreen.main else { return }
        if DrivingModeLayout.needsRepin(frame: window.frame, visibleFrame: screen.visibleFrame) {
            fill(reason: "was partly off-screen (\(reason))")
        }
    }

    func restore() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        if let window = pinnedWindow {
            if let savedLevel { window.level = savedLevel }
            if let savedFrame, !window.styleMask.contains(.fullScreen) {
                // Back to where the window was, unless that was itself off-screen.
                let visible = (window.screen ?? NSScreen.main)?.visibleFrame ?? .zero
                if !DrivingModeLayout.needsRepin(frame: savedFrame, visibleFrame: visible) {
                    log("window leaving driving mode: frame \(Self.describe(window.frame)) → \(Self.describe(savedFrame))")
                    window.setFrame(savedFrame, display: true)
                } else {
                    log("window leaving driving mode: its earlier frame \(Self.describe(savedFrame)) was off-screen, leaving it at \(Self.describe(window.frame))")
                }
            }
        }
        pinnedWindow = nil
        savedFrame = nil
        savedLevel = nil
    }

    private static func describe(_ rect: NSRect) -> String {
        "(\(Int(rect.origin.x)),\(Int(rect.origin.y)) \(Int(rect.width))x\(Int(rect.height)))"
    }
}
#endif
