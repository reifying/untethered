// WindowSessionRegistry.swift
// Tracks which sessions are open in which windows to prevent duplicate editing
// Per design: Sessions can only be open in ONE window at a time

import AppKit
import Combine
import OSLog

private let logger = Logger(subsystem: "dev.910labs.voice-code-desktop", category: "WindowSessionRegistry")

/// Registry that tracks which sessions are open in which windows.
/// Ensures each session is only open in one window at a time.
/// When a session is selected in another window, that window is focused instead.
final class WindowSessionRegistry: ObservableObject {
    /// Shared singleton instance
    static let shared = WindowSessionRegistry()

    /// Maps session UUIDs to their containing windows
    private var sessionToWindow: [UUID: NSWindow] = [:]

    /// Published set of session IDs that are currently in detached windows
    /// (i.e., not the main window). Used for sidebar indicators.
    @Published private(set) var sessionsInDetachedWindows: Set<UUID> = []

    /// The main window reference (first window created)
    private weak var mainWindow: NSWindow?

    /// Lock for thread-safe access
    private let lock = NSLock()

    private init() {}

    // MARK: - Registration

    /// Register a window for a session.
    /// - Parameters:
    ///   - window: The window displaying the session
    ///   - sessionId: The session's UUID
    func registerWindow(_ window: NSWindow, for sessionId: UUID) {
        lock.lock()
        defer { lock.unlock() }

        // If this is the first window registered, treat it as main window
        if mainWindow == nil {
            mainWindow = window
            logger.info("📍 [WindowRegistry] Main window registered")
        }

        // Clean up any existing registration for this session
        sessionToWindow[sessionId] = window

        // Update detached windows set
        updateDetachedWindowsSet()

        let windowTitle = window.title
        logger.info("📍 [WindowRegistry] Registered window '\(windowTitle)' for session \(sessionId.uuidString.prefix(8))...")
    }

    /// Unregister a session from its window.
    /// Call when the window closes or navigates away from the session.
    /// - Parameter sessionId: The session's UUID to unregister
    func unregisterWindow(for sessionId: UUID) {
        lock.lock()
        defer { lock.unlock() }

        if let window = sessionToWindow.removeValue(forKey: sessionId) {
            let windowTitle = window.title
            logger.info("📍 [WindowRegistry] Unregistered session \(sessionId.uuidString.prefix(8))... from window '\(windowTitle)'")
            updateDetachedWindowsSet()
        }
    }

    /// Unregister all sessions associated with a specific window.
    /// Call when a window is about to close.
    /// - Parameter window: The window being closed
    func unregisterAllSessions(for window: NSWindow) {
        lock.lock()
        defer { lock.unlock() }

        let sessionIds = sessionToWindow.filter { $0.value === window }.map { $0.key }
        for sessionId in sessionIds {
            sessionToWindow.removeValue(forKey: sessionId)
            logger.info("📍 [WindowRegistry] Unregistered session \(sessionId.uuidString.prefix(8))... (window closing)")
        }

        // Clear main window reference if it's closing
        if window === mainWindow {
            mainWindow = nil
            logger.info("📍 [WindowRegistry] Main window closed")
        }

        updateDetachedWindowsSet()
    }

    // MARK: - Query

    /// Get the window currently displaying a session.
    /// - Parameter sessionId: The session's UUID
    /// - Returns: The window displaying the session, or nil if not in any window
    func windowForSession(_ sessionId: UUID) -> NSWindow? {
        lock.lock()
        defer { lock.unlock() }
        return sessionToWindow[sessionId]
    }

    /// Check if a session is currently open in any window.
    /// - Parameter sessionId: The session's UUID
    /// - Returns: True if the session is open in a window
    func isSessionInWindow(_ sessionId: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return sessionToWindow[sessionId] != nil
    }

    /// Check if a session is in a detached (non-main) window.
    /// - Parameter sessionId: The session's UUID
    /// - Returns: True if the session is in a detached window
    func isSessionInDetachedWindow(_ sessionId: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard let window = sessionToWindow[sessionId] else { return false }
        return window !== mainWindow
    }

    /// Get all session IDs currently registered.
    /// - Returns: Array of session UUIDs
    func allRegisteredSessions() -> [UUID] {
        lock.lock()
        defer { lock.unlock() }
        return Array(sessionToWindow.keys)
    }

    // MARK: - Session Selection

    /// Attempt to select a session. If the session is already open in another window,
    /// focuses that window instead and returns false.
    /// - Parameters:
    ///   - sessionId: The session's UUID
    ///   - currentWindow: The window attempting to select the session
    /// - Returns: True if selection should proceed, false if another window was focused
    func trySelectSession(_ sessionId: UUID, from currentWindow: NSWindow?) -> Bool {
        // Capture the window reference while holding the lock
        let windowToFocus: NSWindow?

        lock.lock()
        if let existingWindow = sessionToWindow[sessionId], existingWindow !== currentWindow {
            windowToFocus = existingWindow
            logger.info("📍 [WindowRegistry] Session \(sessionId.uuidString.prefix(8))... already open in another window, focusing")
        } else {
            windowToFocus = nil
        }
        lock.unlock()

        // Perform UI operations outside the lock
        if let window = windowToFocus {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return false
        }

        return true
    }

    // MARK: - Private

    /// Updates the published set of sessions in detached windows
    private func updateDetachedWindowsSet() {
        // Called with lock held
        var detached = Set<UUID>()
        for (sessionId, window) in sessionToWindow {
            if window !== mainWindow {
                detached.insert(sessionId)
            }
        }

        // Update on main thread since this affects UI
        DispatchQueue.main.async { [weak self] in
            self?.sessionsInDetachedWindows = detached
        }
    }

    // MARK: - Window Lifecycle Support

    /// Set a window as the main window (typically called when app launches)
    /// - Parameter window: The main window
    func setMainWindow(_ window: NSWindow) {
        lock.lock()
        defer { lock.unlock() }

        mainWindow = window
        updateDetachedWindowsSet()
        logger.info("📍 [WindowRegistry] Main window set explicitly")
    }
}
