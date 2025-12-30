// StatusBarController.swift
// Menu bar status item per Appendix J.4

import AppKit
import SwiftUI
import Combine
import OSLog
import VoiceCodeShared

private let logger = Logger(subsystem: "dev.910labs.voice-code-desktop", category: "StatusBarController")

/// Controls the menu bar status item with connection state icons and menu.
/// Per Appendix J.4: Shows waveform icon with color states, provides quick access menu.
@MainActor
final class StatusBarController: ObservableObject {
    // MARK: - Properties

    private var statusItem: NSStatusItem?
    private var cancellables = Set<AnyCancellable>()
    private weak var appSettings: AppSettings?

    /// Observes connection state from VoiceCodeClient
    @Published var connectionState: ConnectionState = .disconnected

    /// Whether the status bar icon is visible (controlled by AppSettings.showInMenuBar)
    @Published var isVisible: Bool = true {
        didSet { updateVisibility() }
    }

    /// Callback for retry connection action
    var onRetryConnection: (() -> Void)?

    /// Callback for showing main window
    var onShowMainWindow: (() -> Void)?

    /// Callback for opening preferences
    var onOpenPreferences: (() -> Void)?

    // MARK: - Initialization

    init(appSettings: AppSettings) {
        self.appSettings = appSettings
        self.isVisible = appSettings.showInMenuBar

        setupSettingsObserver(appSettings)
    }

    // MARK: - Setup

    /// Sets up the status bar item if visible
    func setup() {
        guard isVisible else { return }

        if statusItem == nil {
            statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            statusItem?.button?.target = self
            statusItem?.button?.action = #selector(handleClick(_:))
            statusItem?.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

            logger.info("StatusBar: Created status item")
        }

        updateIcon(for: connectionState)
        buildMenu()
    }

    /// Removes the status bar item
    func teardown() {
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
            logger.info("StatusBar: Removed status item")
        }
    }

    // MARK: - Icon Updates

    /// Updates the status bar icon based on connection state
    /// Per J.4:
    /// - Connected: waveform (system default)
    /// - Disconnected: waveform.slash (red tint)
    /// - Reconnecting: arrow.trianglehead.2.clockwise (yellow tint, animated)
    /// - Processing: waveform (pulsing animation) - not implemented, requires separate state
    func updateIcon(for state: ConnectionState) {
        guard let button = statusItem?.button else { return }

        let imageName: String
        let tintColor: NSColor

        switch state {
        case .connected:
            imageName = "waveform"
            tintColor = .labelColor  // System default

        case .disconnected, .failed:
            imageName = "waveform.slash"
            tintColor = .systemRed

        case .reconnecting:
            imageName = "arrow.trianglehead.2.clockwise"
            tintColor = .systemYellow

        case .connecting, .authenticating:
            imageName = "waveform"
            tintColor = .systemOrange
        }

        if let image = NSImage(systemSymbolName: imageName, accessibilityDescription: "Voice Code") {
            image.isTemplate = true
            button.image = image
            button.contentTintColor = state == .connected ? nil : tintColor
        }

        button.setAccessibilityLabel(accessibilityLabel(for: state))

        logger.debug("StatusBar: Updated icon for state \(String(describing: state))")
    }

    // MARK: - Menu

    /// Builds the status bar menu per J.4 structure
    private func buildMenu() {
        let menu = NSMenu()

        // Connection status header
        let statusItem = NSMenuItem(title: statusTitle(for: connectionState), action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        menu.addItem(statusItem)

        menu.addItem(NSMenuItem.separator())

        // Retry Connection (shown when disconnected/failed)
        if connectionState == .disconnected || connectionState == .failed {
            let retryItem = NSMenuItem(title: "Retry Connection", action: #selector(retryConnection), keyEquivalent: "r")
            retryItem.target = self
            menu.addItem(retryItem)
        }

        // Disconnect (shown when connected)
        if connectionState == .connected {
            let disconnectItem = NSMenuItem(title: "Disconnect", action: #selector(disconnect), keyEquivalent: "d")
            disconnectItem.target = self
            menu.addItem(disconnectItem)
        }

        menu.addItem(NSMenuItem.separator())

        // Show Voice Code (opens main window)
        let showItem = NSMenuItem(title: "Show Voice Code", action: #selector(showMainWindow), keyEquivalent: "")
        showItem.target = self
        menu.addItem(showItem)

        menu.addItem(NSMenuItem.separator())

        // Preferences
        let prefsItem = NSMenuItem(title: "Preferences...", action: #selector(openPreferences), keyEquivalent: ",")
        prefsItem.target = self
        menu.addItem(prefsItem)

        // Quit
        let quitItem = NSMenuItem(title: "Quit Voice Code", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        self.statusItem?.menu = menu
    }

    // MARK: - Actions

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }

        if event.modifierFlags.contains(.option) {
            // Option-click: show debug info
            showDebugInfo()
        } else {
            // Normal click: show menu (handled automatically by NSStatusItem.menu)
            // Menu is already set, so this is a no-op
        }
    }

    @objc private func retryConnection() {
        logger.info("StatusBar: Retry connection requested")
        onRetryConnection?()
    }

    @objc private func disconnect() {
        logger.info("StatusBar: Disconnect requested")
        // Post notification for VoiceCodeClient to handle
        NotificationCenter.default.post(name: .statusBarDisconnectRequested, object: nil)
    }

    @objc private func showMainWindow() {
        logger.info("StatusBar: Show main window requested")
        NSApp.activate(ignoringOtherApps: true)
        onShowMainWindow?()
    }

    @objc private func openPreferences() {
        logger.info("StatusBar: Open preferences requested")
        NSApp.activate(ignoringOtherApps: true)
        onOpenPreferences?()
    }

    @objc private func quitApp() {
        logger.info("StatusBar: Quit requested")
        NSApp.terminate(nil)
    }

    private func showDebugInfo() {
        let alert = NSAlert()
        alert.messageText = "Voice Code Debug Info"

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "Unknown"
        let serverURL = appSettings?.fullServerURL ?? "Not configured"

        alert.informativeText = """
        Version: \(version) (\(build))
        Connection: \(statusTitle(for: connectionState))
        Server: \(serverURL)
        """

        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()

        logger.info("StatusBar: Showed debug info")
    }

    // MARK: - Visibility

    private func updateVisibility() {
        if isVisible {
            setup()
        } else {
            teardown()
        }
    }

    // MARK: - Observers

    /// Observe connection state changes from a VoiceCodeClient
    func observeConnectionState(from client: VoiceCodeClient) {
        client.$connectionState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.connectionState = state
                self?.updateIcon(for: state)
                self?.buildMenu()
            }
            .store(in: &cancellables)
    }

    private func setupSettingsObserver(_ settings: AppSettings) {
        settings.$showInMenuBar
            .receive(on: DispatchQueue.main)
            .sink { [weak self] visible in
                self?.isVisible = visible
            }
            .store(in: &cancellables)
    }

    // MARK: - Helpers

    private func statusTitle(for state: ConnectionState) -> String {
        switch state {
        case .connected:
            return "Connected"
        case .connecting:
            return "Connecting..."
        case .authenticating:
            return "Authenticating..."
        case .reconnecting:
            return "Reconnecting..."
        case .disconnected:
            return "Disconnected"
        case .failed:
            return "Connection Failed"
        }
    }

    private func accessibilityLabel(for state: ConnectionState) -> String {
        switch state {
        case .connected:
            return "Voice Code - Connected"
        case .connecting:
            return "Voice Code - Connecting"
        case .authenticating:
            return "Voice Code - Authenticating"
        case .reconnecting:
            return "Voice Code - Reconnecting"
        case .disconnected:
            return "Voice Code - Disconnected"
        case .failed:
            return "Voice Code - Connection Failed"
        }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    /// Posted when disconnect is requested from status bar menu
    static let statusBarDisconnectRequested = Notification.Name("statusBarDisconnectRequested")
}
