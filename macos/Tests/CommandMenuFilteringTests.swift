// CommandMenuFilteringTests.swift
// Unit tests for CommandMenuSheet filtering logic (macOS)

import XCTest
import SwiftUI
@testable import UntetheredMac
@testable import UntetheredCore

final class CommandMenuFilteringTests: XCTestCase {

    // MARK: - Test Data

    private func makeSampleCommands() -> [Command] {
        [
            Command(
                id: "build",
                label: "Build",
                type: .command,
                description: "Build the project"
            ),
            Command(
                id: "test",
                label: "Test",
                type: .command,
                description: "Run all tests"
            ),
            Command(
                id: "docker",
                label: "Docker",
                type: .group,
                children: [
                    Command(id: "docker.up", label: "Up", type: .command, description: "Start Docker containers"),
                    Command(id: "docker.down", label: "Down", type: .command, description: "Stop Docker containers"),
                    Command(id: "docker.logs", label: "Logs", type: .command, description: "View Docker logs")
                ]
            ),
            Command(
                id: "deploy",
                label: "Deploy",
                type: .command,
                description: "Deploy to production"
            )
        ]
    }

    // MARK: - Command Model Tests

    func testCommandInitialization() {
        let command = Command(
            id: "test.command",
            label: "Test Command",
            type: .command,
            description: "A test command"
        )

        XCTAssertEqual(command.id, "test.command")
        XCTAssertEqual(command.label, "Test Command")
        XCTAssertEqual(command.type, .command)
        XCTAssertEqual(command.description, "A test command")
        XCTAssertNil(command.children)
    }

    func testCommandGroupInitialization() {
        let children = [
            Command(id: "child1", label: "Child 1", type: .command),
            Command(id: "child2", label: "Child 2", type: .command)
        ]

        let group = Command(
            id: "group",
            label: "Group",
            type: .group,
            children: children
        )

        XCTAssertEqual(group.type, .group)
        XCTAssertEqual(group.children?.count, 2)
        XCTAssertEqual(group.children?[0].id, "child1")
    }

    func testCommandJSONDecoding() throws {
        let json = """
        {
            "id": "git.status",
            "label": "Git Status",
            "type": "command",
            "description": "Show git working tree status"
        }
        """

        let data = json.data(using: .utf8)!
        let command = try JSONDecoder().decode(Command.self, from: data)

        XCTAssertEqual(command.id, "git.status")
        XCTAssertEqual(command.label, "Git Status")
        XCTAssertEqual(command.type, .command)
        XCTAssertEqual(command.description, "Show git working tree status")
    }

    func testCommandGroupJSONDecoding() throws {
        let json = """
        {
            "id": "docker",
            "label": "Docker",
            "type": "group",
            "children": [
                {
                    "id": "docker.up",
                    "label": "Up",
                    "type": "command"
                },
                {
                    "id": "docker.down",
                    "label": "Down",
                    "type": "command"
                }
            ]
        }
        """

        let data = json.data(using: .utf8)!
        let command = try JSONDecoder().decode(Command.self, from: data)

        XCTAssertEqual(command.id, "docker")
        XCTAssertEqual(command.type, .group)
        XCTAssertEqual(command.children?.count, 2)
        XCTAssertEqual(command.children?[0].label, "Up")
        XCTAssertEqual(command.children?[1].label, "Down")
    }

    // MARK: - Filtering Logic Tests

    func testFilterCommandsEmptySearchReturnsAll() {
        let commands = makeSampleCommands()
        let searchText = ""

        // Empty search should return all commands
        let filtered = filterCommands(commands, searchText: searchText)

        XCTAssertEqual(filtered.count, commands.count)
        XCTAssertEqual(filtered[0].id, "build")
        XCTAssertEqual(filtered[1].id, "test")
        XCTAssertEqual(filtered[2].id, "docker")
        XCTAssertEqual(filtered[3].id, "deploy")
    }

    func testFilterCommandsByLabel() {
        let commands = makeSampleCommands()
        let searchText = "build"

        let filtered = filterCommands(commands, searchText: searchText)

        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered[0].id, "build")
    }

    func testFilterCommandsByDescription() {
        let commands = makeSampleCommands()
        let searchText = "production"

        let filtered = filterCommands(commands, searchText: searchText)

        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered[0].id, "deploy")
    }

    func testFilterCommandsCaseInsensitive() {
        let commands = makeSampleCommands()
        let searchText = "BUILD"

        let filtered = filterCommands(commands, searchText: searchText)

        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered[0].id, "build")
    }

    func testFilterCommandsPartialMatch() {
        let commands = makeSampleCommands()
        let searchText = "dep"

        let filtered = filterCommands(commands, searchText: searchText)

        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered[0].id, "deploy")
    }

    func testFilterCommandsNoMatches() {
        let commands = makeSampleCommands()
        let searchText = "nonexistent"

        let filtered = filterCommands(commands, searchText: searchText)

        XCTAssertEqual(filtered.count, 0)
    }

    func testFilterCommandsGroupWithMatchingChildren() {
        let commands = makeSampleCommands()
        let searchText = "up"

        let filtered = filterCommands(commands, searchText: searchText)

        // Should return docker group with only matching children
        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered[0].id, "docker")
        XCTAssertEqual(filtered[0].type, .group)
        XCTAssertEqual(filtered[0].children?.count, 1)
        XCTAssertEqual(filtered[0].children?[0].id, "docker.up")
    }

    func testFilterCommandsGroupPartialChildrenMatch() {
        let commands = makeSampleCommands()
        let searchText = "docker"

        let filtered = filterCommands(commands, searchText: searchText)

        // "docker" should match group label and all children descriptions
        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered[0].id, "docker")
        XCTAssertEqual(filtered[0].children?.count, 3)
    }

    func testFilterCommandsGroupNoChildrenMatch() {
        let commands = makeSampleCommands()
        let searchText = "build"

        let filtered = filterCommands(commands, searchText: searchText)

        // "build" matches leaf command, not docker group
        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered[0].id, "build")
    }

    func testFilterCommandsMultipleMatches() {
        let commands = makeSampleCommands()
        let searchText = "test"

        let filtered = filterCommands(commands, searchText: searchText)

        // Should match "test" command
        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered[0].id, "test")
    }

    func testFilterCommandsWhitespace() {
        let commands = makeSampleCommands()
        let searchText = "  build  "

        let filtered = filterCommands(commands, searchText: searchText)

        // Should match despite whitespace
        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered[0].id, "build")
    }

    func testFilterCommandsPreservesGroupStructure() {
        let commands = makeSampleCommands()
        let searchText = "logs"

        let filtered = filterCommands(commands, searchText: searchText)

        // Should return docker group with only "logs" child
        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered[0].id, "docker")
        XCTAssertEqual(filtered[0].type, .group)
        XCTAssertEqual(filtered[0].label, "Docker")
        XCTAssertEqual(filtered[0].children?.count, 1)
        XCTAssertEqual(filtered[0].children?[0].id, "docker.logs")
    }

    func testFilterCommandsNestedGroups() {
        let commands = [
            Command(
                id: "services",
                label: "Services",
                type: .group,
                children: [
                    Command(
                        id: "services.web",
                        label: "Web",
                        type: .group,
                        children: [
                            Command(id: "services.web.start", label: "Start", type: .command, description: "Start web server"),
                            Command(id: "services.web.stop", label: "Stop", type: .command, description: "Stop web server")
                        ]
                    )
                ]
            )
        ]

        let searchText = "start"
        let filtered = filterCommands(commands, searchText: searchText)

        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered[0].id, "services")
        XCTAssertEqual(filtered[0].children?.count, 1)
        XCTAssertEqual(filtered[0].children?[0].id, "services.web")
        XCTAssertEqual(filtered[0].children?[0].children?.count, 1)
        XCTAssertEqual(filtered[0].children?[0].children?[0].id, "services.web.start")
    }

    func testFilterCommandsWithNilDescription() {
        let commands = [
            Command(id: "cmd1", label: "Command 1", type: .command, description: nil),
            Command(id: "cmd2", label: "Command 2", type: .command, description: "Has description")
        ]

        let searchText = "description"
        let filtered = filterCommands(commands, searchText: searchText)

        // Should only match cmd2 (has description in description field)
        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered[0].id, "cmd2")
    }

    func testFilterCommandsEmptyLabel() {
        let commands = [
            Command(id: "cmd1", label: "", type: .command, description: "Test description")
        ]

        let searchText = "test"
        let filtered = filterCommands(commands, searchText: searchText)

        // Should match via description even with empty label
        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered[0].id, "cmd1")
    }

    // MARK: - Helper Methods (Mirror of CommandMenuSheet logic)

    private func filterCommands(_ commands: [Command], searchText: String) -> [Command] {
        let trimmed = searchText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return commands }

        return commands.compactMap { command in
            if command.type == .group, let children = command.children {
                let filteredChildren = filterCommands(children, searchText: trimmed)
                if !filteredChildren.isEmpty {
                    return Command(
                        id: command.id,
                        label: command.label,
                        type: command.type,
                        description: command.description,
                        children: filteredChildren
                    )
                }
                return nil
            } else {
                // Leaf command: check if label or description matches search
                let query = trimmed.lowercased()
                let matchesLabel = command.label.lowercased().contains(query)
                let matchesDescription = command.description?.lowercased().contains(query) ?? false
                return (matchesLabel || matchesDescription) ? command : nil
            }
        }
    }

    // MARK: - AvailableCommands Tests

    func testAvailableCommandsInitialization() {
        let projectCommands = [
            Command(id: "build", label: "Build", type: .command)
        ]
        let generalCommands = [
            Command(id: "git.status", label: "Git Status", type: .command)
        ]

        let availableCommands = AvailableCommands(
            workingDirectory: "/Users/test/project",
            projectCommands: projectCommands,
            generalCommands: generalCommands
        )

        XCTAssertEqual(availableCommands.workingDirectory, "/Users/test/project")
        XCTAssertEqual(availableCommands.projectCommands.count, 1)
        XCTAssertEqual(availableCommands.generalCommands.count, 1)
    }

    func testAvailableCommandsJSONDecoding() throws {
        let json = """
        {
            "working_directory": "/Users/test/project",
            "project_commands": [
                {
                    "id": "build",
                    "label": "Build",
                    "type": "command"
                }
            ],
            "general_commands": [
                {
                    "id": "git.status",
                    "label": "Git Status",
                    "type": "command"
                }
            ]
        }
        """

        let data = json.data(using: .utf8)!
        let decoder = JSONDecoder()
        // AvailableCommands has custom CodingKeys, so no need for keyDecodingStrategy
        let availableCommands = try decoder.decode(AvailableCommands.self, from: data)

        XCTAssertEqual(availableCommands.workingDirectory, "/Users/test/project")
        XCTAssertEqual(availableCommands.projectCommands.count, 1)
        XCTAssertEqual(availableCommands.projectCommands[0].id, "build")
        XCTAssertEqual(availableCommands.generalCommands.count, 1)
        XCTAssertEqual(availableCommands.generalCommands[0].id, "git.status")
    }

    // MARK: - Command Equality Tests

    func testCommandEquality() {
        let cmd1 = Command(id: "test", label: "Test", type: .command)
        let cmd2 = Command(id: "test", label: "Test", type: .command)
        let cmd3 = Command(id: "test2", label: "Test", type: .command)

        XCTAssertEqual(cmd1, cmd2)
        XCTAssertNotEqual(cmd1, cmd3)
    }

    func testCommandGroupEquality() {
        let children1 = [Command(id: "child", label: "Child", type: .command)]
        let children2 = [Command(id: "child", label: "Child", type: .command)]

        let group1 = Command(id: "group", label: "Group", type: .group, children: children1)
        let group2 = Command(id: "group", label: "Group", type: .group, children: children2)

        XCTAssertEqual(group1, group2)
    }
}
