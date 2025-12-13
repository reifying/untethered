// UUID+Lowercase.swift
// UUID extension for backend-compatible lowercase string representation

import Foundation

extension UUID {
    /// Lowercase string representation for backend communication
    /// Backend expects lowercase UUIDs; Swift's uuidString returns uppercase
    public var lowercasedString: String {
        uuidString.lowercased()
    }
}
