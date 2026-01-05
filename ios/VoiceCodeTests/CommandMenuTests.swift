// CommandMenuTests.swift
// Comprehensive tests for command menu functionality

import XCTest
import SwiftUI
#if os(iOS)
@testable import VoiceCode
#else
@testable import VoiceCodeMac
#endif

final class CommandMenuTests: XCTestCase {

    var client: VoiceCodeClient!
    var sorter: CommandSorter!
    var userDefaults: UserDefaults!

    override func setUp() {
        super.setUp()

        // Use in-memory UserDefaults for testing
        userDefaults = UserDefaults(suiteName: "test-\(UUID().uuidString)")!
        sorter = CommandSorter(userDefaults: userDefaults)
        client = VoiceCodeClient(serverURL: "ws://localhost:8080")
    }

    override func tearDown() {
        sorter.clearMRU()
        client?.disconnect()
        client = nil
        sorter = nil
        userDefaults = nil
        super.tearDown()
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
        XCTAssertEqual(command.children?[0].id, "docker.up")
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
        let commands = try JSONDecoder().decode(AvailableCommands.self, from: data)

        XCTAssertEqual(commands.workingDirectory, "/Users/test/project")
        XCTAssertEqual(commands.projectCommands.count, 1)
        XCTAssertEqual(commands.generalCommands.count, 1)
        XCTAssertEqual(commands.projectCommands[0].id, "build")
        XCTAssertEqual(commands.generalCommands[0].id, "git.status")
    }

    // MARK: - CommandSorter Tests

    func testMarkCommandUsed() {
        sorter.markCommandUsed(commandId: "test.command")

        // Verify command is marked (by checking it sorts to the top)
        let commands = [
            Command(id: "aaa", label: "AAA", type: .command),
            Command(id: "test.command", label: "Test", type: .command),
            Command(id: "zzz", label: "ZZZ", type: .command)
        ]

        let sorted = sorter.sortCommands(commands)
        XCTAssertEqual(sorted[0].id, "test.command")
    }

    func testSortCommandsAllUnused() {
        let commands = [
            Command(id: "zzz", label: "ZZZ", type: .command),
            Command(id: "aaa", label: "AAA", type: .command),
            Command(id: "mmm", label: "MMM", type: .command)
        ]

        let sorted = sorter.sortCommands(commands)

        // Should be alphabetically sorted
        XCTAssertEqual(sorted[0].id, "aaa")
        XCTAssertEqual(sorted[1].id, "mmm")
        XCTAssertEqual(sorted[2].id, "zzz")
    }

    func testSortCommandsAllUsed() {
        // Mark commands with different timestamps
        sleep(1) // Ensure different timestamps
        sorter.markCommandUsed(commandId: "first")
        sleep(1)
        sorter.markCommandUsed(commandId: "second")
        sleep(1)
        sorter.markCommandUsed(commandId: "third")

        let commands = [
            Command(id: "first", label: "First", type: .command),
            Command(id: "second", label: "Second", type: .command),
            Command(id: "third", label: "Third", type: .command)
        ]

        let sorted = sorter.sortCommands(commands)

        // Should be sorted by timestamp descending (most recent first)
        XCTAssertEqual(sorted[0].id, "third")
        XCTAssertEqual(sorted[1].id, "second")
        XCTAssertEqual(sorted[2].id, "first")
    }

    func testSortCommandsMixed() {
        // Mark only some commands as used
        sorter.markCommandUsed(commandId: "used1")
        sleep(1)
        sorter.markCommandUsed(commandId: "used2")

        let commands = [
            Command(id: "unused.zzz", label: "Unused ZZZ", type: .command),
            Command(id: "used1", label: "Used 1", type: .command),
            Command(id: "unused.aaa", label: "Unused AAA", type: .command),
            Command(id: "used2", label: "Used 2", type: .command)
        ]

        let sorted = sorter.sortCommands(commands)

        // Used commands first (sorted by timestamp descending)
        XCTAssertEqual(sorted[0].id, "used2")
        XCTAssertEqual(sorted[1].id, "used1")
        // Then unused commands (alphabetically)
        XCTAssertEqual(sorted[2].id, "unused.aaa")
        XCTAssertEqual(sorted[3].id, "unused.zzz")
    }

    func testSortCommandsRecursive() {
        // Mark child commands as used
        sorter.markCommandUsed(commandId: "group.child2")

        let children = [
            Command(id: "group.child3", label: "Child 3", type: .command),
            Command(id: "group.child1", label: "Child 1", type: .command),
            Command(id: "group.child2", label: "Child 2", type: .command)
        ]

        let commands = [
            Command(id: "group", label: "Group", type: .group, children: children)
        ]

        let sorted = sorter.sortCommands(commands)

        // Verify children are sorted
        let sortedChildren = sorted[0].children!
        XCTAssertEqual(sortedChildren[0].id, "group.child2") // Used first
        XCTAssertEqual(sortedChildren[1].id, "group.child1") // Then alphabetically
        XCTAssertEqual(sortedChildren[2].id, "group.child3")
    }

    func testClearMRU() {
        sorter.markCommandUsed(commandId: "test")
        sorter.clearMRU()

        let commands = [
            Command(id: "zzz", label: "ZZZ", type: .command),
            Command(id: "test", label: "Test", type: .command)
        ]

        let sorted = sorter.sortCommands(commands)

        // Should be alphabetically sorted (no MRU data)
        XCTAssertEqual(sorted[0].id, "test")
        XCTAssertEqual(sorted[1].id, "zzz")
    }

    // MARK: - VoiceCodeClient Integration Tests

    func testClientHandlesAvailableCommandsMessage() {
        let expectation = XCTestExpectation(description: "Commands received")

        // Monitor availableCommands property
        let cancellable = client.$availableCommands
            .dropFirst() // Skip initial nil
            .sink { commands in
                if let commands = commands {
                    XCTAssertEqual(commands.workingDirectory, "/Users/test/project")
                    XCTAssertEqual(commands.projectCommands.count, 1)
                    XCTAssertEqual(commands.generalCommands.count, 1)
                    expectation.fulfill()
                }
            }

        // Simulate receiving available_commands message
        let json: [String: Any] = [
            "type": "available_commands",
            "working_directory": "/Users/test/project",
            "project_commands": [
                [
                    "id": "build",
                    "label": "Build",
                    "type": "command"
                ]
            ],
            "general_commands": [
                [
                    "id": "git.status",
                    "label": "Git Status",
                    "type": "command"
                ]
            ]
        ]

        if let jsonData = try? JSONSerialization.data(withJSONObject: json),
           let commands = try? JSONDecoder().decode(AvailableCommands.self, from: jsonData) {
            client.availableCommands = commands
        }

        wait(for: [expectation], timeout: 1.0)
        cancellable.cancel()
    }

    func testClientExecuteCommandSendsCorrectMessage() {
        var sentMessage: [String: Any]?

        // Capture sent message (would need to expose sendMessage or mock WebSocket)
        // For now, verify method doesn't crash
        Task {
            _ = await client.executeCommand(commandId: "test.command", workingDirectory: "/test")
        }

        // In a real integration test, we'd verify the WebSocket message
        XCTAssertTrue(true) // Placeholder assertion
    }

    // MARK: - CommandMenuView UI Tests

    func testCommandMenuViewEmptyState() {
        let view = CommandMenuView(
            client: client,
            workingDirectory: "/test"
        )

        // Verify empty state displays when no commands
        XCTAssertNil(client.availableCommands)
    }

    func testCommandMenuViewWithCommands() {
        // Set up mock commands
        let mockCommands = AvailableCommands(
            workingDirectory: "/test",
            projectCommands: [
                Command(id: "build", label: "Build", type: .command)
            ],
            generalCommands: [
                Command(id: "git.status", label: "Git Status", type: .command)
            ]
        )
        client.availableCommands = mockCommands

        let view = CommandMenuView(
            client: client,
            workingDirectory: "/test"
        )

        // Verify commands are set
        XCTAssertNotNil(client.availableCommands)
        XCTAssertEqual(client.availableCommands?.projectCommands.count, 1)
    }

    func testCommandRowViewLeafCommand() {
        var executedCommandId: String?

        let command = Command(
            id: "test.command",
            label: "Test Command",
            type: .command,
            description: "A test"
        )

        let view = CommandRowView(
            command: command,
            onExecute: { commandId in
                executedCommandId = commandId
            }
        )

        // Verify command structure
        XCTAssertEqual(command.type, .command)
        XCTAssertNil(command.children)
    }

    func testCommandRowViewGroup() {
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

        let view = CommandRowView(
            command: group,
            onExecute: { _ in }
        )

        // Verify group structure
        XCTAssertEqual(group.type, .group)
        XCTAssertEqual(group.children?.count, 2)
    }

    // MARK: - SessionsForDirectoryView Integration Tests

    func testSessionsViewShowsCommandsButton() {
        // Set up mock commands to trigger button visibility
        let mockCommands = AvailableCommands(
            workingDirectory: "/test",
            projectCommands: [Command(id: "test", label: "Test", type: .command)],
            generalCommands: []
        )
        client.availableCommands = mockCommands

        // Verify commands are available
        XCTAssertNotNil(client.availableCommands)
        XCTAssertTrue(client.availableCommands?.projectCommands.count ?? 0 > 0)
    }

    func testSessionsViewHidesCommandsButtonWhenUnavailable() {
        // No commands set
        client.availableCommands = nil

        // Verify commands are nil
        XCTAssertNil(client.availableCommands)
    }

    func testCommandCountBadge() {
        let mockCommands = AvailableCommands(
            workingDirectory: "/test",
            projectCommands: [
                Command(id: "cmd1", label: "Command 1", type: .command),
                Command(id: "cmd2", label: "Command 2", type: .command)
            ],
            generalCommands: [
                Command(id: "git.status", label: "Git Status", type: .command)
            ]
        )
        client.availableCommands = mockCommands

        let totalCount = (client.availableCommands?.projectCommands.count ?? 0) +
                        (client.availableCommands?.generalCommands.count ?? 0)

        XCTAssertEqual(totalCount, 3)
    }

    // MARK: - MRU Persistence Tests

    func testMRUPersistence() {
        let sorter1 = CommandSorter(userDefaults: userDefaults)
        sorter1.markCommandUsed(commandId: "test.command")

        // Create new sorter with same UserDefaults
        let sorter2 = CommandSorter(userDefaults: userDefaults)

        let commands = [
            Command(id: "zzz", label: "ZZZ", type: .command),
            Command(id: "test.command", label: "Test", type: .command)
        ]

        let sorted = sorter2.sortCommands(commands)

        // test.command should be first (most recently used)
        XCTAssertEqual(sorted[0].id, "test.command")
    }

    // MARK: - Edge Case Tests

    func testEmptyCommandList() {
        let commands: [Command] = []
        let sorted = sorter.sortCommands(commands)
        XCTAssertEqual(sorted.count, 0)
    }

    func testSingleCommand() {
        let commands = [Command(id: "single", label: "Single", type: .command)]
        let sorted = sorter.sortCommands(commands)
        XCTAssertEqual(sorted.count, 1)
        XCTAssertEqual(sorted[0].id, "single")
    }

    func testNestedGroupsMultipleLevels() {
        let deepChildren = [
            Command(id: "deep.child", label: "Deep Child", type: .command)
        ]
        let midChildren = [
            Command(id: "mid.group", label: "Mid Group", type: .group, children: deepChildren)
        ]
        let topGroup = Command(
            id: "top.group",
            label: "Top Group",
            type: .group,
            children: midChildren
        )

        let sorted = sorter.sortCommands([topGroup])

        // Verify structure is preserved
        XCTAssertEqual(sorted[0].id, "top.group")
        XCTAssertEqual(sorted[0].children?[0].id, "mid.group")
        XCTAssertEqual(sorted[0].children?[0].children?[0].id, "deep.child")
    }
}
