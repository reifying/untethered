// Notifications.swift
// Custom notification names for app-wide communication

import Foundation

public extension Notification.Name {
    // Session updates
    static let sessionListDidUpdate = Notification.Name("sessionListDidUpdate")
    static let priorityQueueChanged = Notification.Name("priorityQueueChanged")

    // Connection state
    static let connectionRestored = Notification.Name("connectionRestored")
    static let connectionLost = Notification.Name("connectionLost")

    // Data sync
    static let requestFullSync = Notification.Name("requestFullSync")
    static let dataChanged = Notification.Name("dataChanged")
}
