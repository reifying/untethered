// ContentBlock.swift
// Model for content blocks in Claude responses (tool_use, tool_result, thinking, text)

import Foundation

/// Represents a content block from Claude's response
/// Used for expandable display of tool_use, tool_result, and thinking blocks per Appendix K.7
public struct ContentBlock: Codable, Identifiable, Sendable {
    public let id: UUID
    public let type: ContentBlockType

    // Tool use fields
    public let toolName: String?
    public let toolInput: [String: AnyCodable]?

    // Tool result fields
    public let isError: Bool?
    public let content: String?

    // Text fields
    public let text: String?

    // Thinking fields
    public let thinking: String?

    public init(
        id: UUID = UUID(),
        type: ContentBlockType,
        toolName: String? = nil,
        toolInput: [String: AnyCodable]? = nil,
        isError: Bool? = nil,
        content: String? = nil,
        text: String? = nil,
        thinking: String? = nil
    ) {
        self.id = id
        self.type = type
        self.toolName = toolName
        self.toolInput = toolInput
        self.isError = isError
        self.content = content
        self.text = text
        self.thinking = thinking
    }

    enum CodingKeys: String, CodingKey {
        case id
        case type
        case toolName = "name"
        case toolInput = "input"
        case isError = "is_error"
        case content
        case text
        case thinking
    }
}

/// Content block type enum
public enum ContentBlockType: String, Codable, Sendable {
    case text
    case toolUse = "tool_use"
    case toolResult = "tool_result"
    case thinking
    case unknown

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = ContentBlockType(rawValue: rawValue) ?? .unknown
    }
}

/// Wrapper for encoding arbitrary JSON values
/// Note: Uses @unchecked Sendable because JSON values are immutable after construction
public struct AnyCodable: Codable, @unchecked Sendable {
    public let value: Any

    public init(_ value: Any) {
        self.value = value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self.value = NSNull()
        } else if let bool = try? container.decode(Bool.self) {
            self.value = bool
        } else if let int = try? container.decode(Int.self) {
            self.value = int
        } else if let double = try? container.decode(Double.self) {
            self.value = double
        } else if let string = try? container.decode(String.self) {
            self.value = string
        } else if let array = try? container.decode([AnyCodable].self) {
            self.value = array.map { $0.value }
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            self.value = dict.mapValues { $0.value }
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unable to decode value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch value {
        case is NSNull:
            try container.encodeNil()
        case let bool as Bool:
            try container.encode(bool)
        case let int as Int:
            try container.encode(int)
        case let double as Double:
            try container.encode(double)
        case let string as String:
            try container.encode(string)
        case let array as [Any]:
            try container.encode(array.map { AnyCodable($0) })
        case let dict as [String: Any]:
            try container.encode(dict.mapValues { AnyCodable($0) })
        default:
            throw EncodingError.invalidValue(value, EncodingError.Context(codingPath: encoder.codingPath, debugDescription: "Unable to encode value"))
        }
    }
}

// MARK: - ContentBlock Summarization (per K.7)

extension ContentBlock {
    /// Returns a summary string for display in collapsed state
    public var summary: String {
        switch type {
        case .toolUse:
            return "Using tool: \(toolName ?? "unknown")"
        case .toolResult:
            if isError == true {
                return "Tool error"
            }
            return "Tool result"
        case .thinking:
            return "Thinking..."
        case .text:
            return truncatedContent(text ?? "", maxLength: 100).text
        case .unknown:
            return "[unknown block]"
        }
    }

    /// Returns the icon for this block type
    public var icon: String {
        switch type {
        case .toolUse:
            return "wrench.and.screwdriver"
        case .toolResult:
            return isError == true ? "xmark.circle.fill" : "checkmark.circle.fill"
        case .thinking:
            return "brain.head.profile"
        case .text:
            return "text.alignleft"
        case .unknown:
            return "questionmark.circle"
        }
    }

    /// Returns the full content for display in expanded state
    public var fullContent: String {
        switch type {
        case .toolUse:
            var lines: [String] = []
            lines.append("Tool: \(toolName ?? "unknown")")
            if let input = toolInput, !input.isEmpty {
                lines.append("Input:")
                for (key, value) in input.sorted(by: { $0.key < $1.key }) {
                    let valueString = formatValue(value.value)
                    lines.append("  \(key): \(valueString)")
                }
            }
            return lines.joined(separator: "\n")
        case .toolResult:
            return content ?? ""
        case .thinking:
            return thinking ?? ""
        case .text:
            return text ?? ""
        case .unknown:
            return ""
        }
    }

    /// Whether this block type should be collapsed by default
    public var collapsedByDefault: Bool {
        switch type {
        case .toolUse, .toolResult, .thinking:
            return true
        case .text, .unknown:
            return false
        }
    }

    private func truncatedContent(_ text: String, maxLength: Int) -> (text: String, wasTruncated: Bool) {
        if text.count <= maxLength {
            return (text, false)
        }
        return (String(text.prefix(maxLength)) + "...", true)
    }

    private func formatValue(_ value: Any) -> String {
        switch value {
        case let string as String:
            // Truncate long strings
            if string.count > 60 {
                return "\"\(string.prefix(60))...\""
            }
            return "\"\(string)\""
        case let array as [Any]:
            return "[\(array.count) items]"
        case let dict as [String: Any]:
            return "{\(dict.count) keys}"
        default:
            return String(describing: value)
        }
    }
}

// MARK: - Parsing

extension ContentBlock {
    /// Parse content blocks from a raw message content array
    public static func parse(from contentArray: [[String: Any]]) -> [ContentBlock] {
        var blocks: [ContentBlock] = []

        for blockData in contentArray {
            guard let typeString = blockData["type"] as? String else { continue }

            let blockType = ContentBlockType(rawValue: typeString) ?? .unknown

            let block = ContentBlock(
                id: UUID(),
                type: blockType,
                toolName: blockData["name"] as? String,
                toolInput: parseInput(blockData["input"]),
                isError: blockData["is_error"] as? Bool,
                content: extractContentString(blockData["content"]),
                text: blockData["text"] as? String,
                thinking: blockData["thinking"] as? String
            )

            blocks.append(block)
        }

        return blocks
    }

    private static func parseInput(_ input: Any?) -> [String: AnyCodable]? {
        guard let dict = input as? [String: Any] else { return nil }
        return dict.mapValues { AnyCodable($0) }
    }

    private static func extractContentString(_ content: Any?) -> String? {
        if let string = content as? String {
            return string
        }
        if let array = content as? [[String: Any]] {
            // Handle content arrays (e.g., tool_result with multiple content parts)
            var parts: [String] = []
            for item in array {
                if let text = item["text"] as? String {
                    parts.append(text)
                }
            }
            return parts.isEmpty ? nil : parts.joined(separator: "\n")
        }
        return nil
    }

    /// Encode content blocks to JSON string for storage
    public static func encode(_ blocks: [ContentBlock]) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        guard let data = try? encoder.encode(blocks) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Decode content blocks from JSON string
    public static func decode(from json: String) -> [ContentBlock]? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([ContentBlock].self, from: data)
    }
}
