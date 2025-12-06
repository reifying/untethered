import Foundation

/// Represents a file resource uploaded to the backend
public struct Resource: Identifiable, Codable, Equatable {
    public let id: UUID
    public let filename: String
    public let path: String  // Relative path: .untethered/resources/filename
    public let size: Int64
    public let timestamp: Date

    public init(id: UUID = UUID(), filename: String, path: String, size: Int64, timestamp: Date) {
        self.id = id
        self.filename = filename
        self.path = path
        self.size = size
        self.timestamp = timestamp
    }

    public init?(json: [String: Any]) {
        guard let filename = json["filename"] as? String,
              let path = json["path"] as? String,
              let size = json["size"] as? Int64 else {
            return nil
        }

        self.id = UUID()
        self.filename = filename
        self.path = path
        self.size = size

        // Parse timestamp - backend sends ISO-8601 string
        if let timestampString = json["timestamp"] as? String {
            let formatter = ISO8601DateFormatter()
            self.timestamp = formatter.date(from: timestampString) ?? Date()
        } else {
            self.timestamp = Date()
        }
    }

    /// Human-readable file size
    public var formattedSize: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: size)
    }

    /// Relative timestamp (e.g., "2 min ago")
    public var relativeTimestamp: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: timestamp, relativeTo: Date())
    }
}
