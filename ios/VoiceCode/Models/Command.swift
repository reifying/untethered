// Command.swift
// Command model for command execution menu

import Foundation

struct Command: Identifiable, Codable, Equatable {
    let id: String
    let label: String
    let type: CommandType
    let description: String?
    let children: [Command]?

    enum CommandType: String, Codable {
        case command = "command"
        case group = "group"
    }

    init(id: String, label: String, type: CommandType, description: String? = nil, children: [Command]? = nil) {
        self.id = id
        self.label = label
        self.type = type
        self.description = description
        self.children = children
    }

    // Decode from JSON (snake_case to camelCase conversion)
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        label = try container.decode(String.self, forKey: .label)
        type = try container.decode(CommandType.self, forKey: .type)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        children = try container.decodeIfPresent([Command].self, forKey: .children)
    }

    private enum CodingKeys: String, CodingKey {
        case id, label, type, description, children
    }
}

struct AvailableCommands: Codable {
    let workingDirectory: String
    let projectCommands: [Command]
    let generalCommands: [Command]

    private enum CodingKeys: String, CodingKey {
        case workingDirectory = "working_directory"
        case projectCommands = "project_commands"
        case generalCommands = "general_commands"
    }
}
