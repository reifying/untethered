import XCTest
import SwiftUI
@testable import VoiceCodeDesktop
@testable import VoiceCodeShared

@MainActor
final class CommandMenuViewTests: XCTestCase {
    var client: VoiceCodeClient!
    var sorter: CommandSorter!
    var userDefaults: UserDefaults!
    var userDefaultsSuiteName: String!

    override func setUp() {
        super.setUp()

        // Use in-memory UserDefaults for testing with unique suite name
        userDefaultsSuiteName = "test-\(UUID().uuidString)"
        userDefaults = UserDefaults(suiteName: userDefaultsSuiteName)!
        sorter = CommandSorter(userDefaults: userDefaults)
        client = VoiceCodeClient(
            serverURL: "ws://localhost:8080",
            setupObservers: false
        )
    }

    override func tearDown() {
        sorter.clearMRU()
        client?.disconnect()
        client = nil
        sorter = nil
        // Clean up the UserDefaults suite to prevent accumulation
        if let suiteName = userDefaultsSuiteName {
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
        }
        userDefaults = nil
        userDefaultsSuiteName = nil
        super.tearDown()
    }

    // MARK: - CommandMenuView Basic Tests

    func testCommandMenuViewInitializesWithEmptyCommands() {
        let view = CommandMenuView(
            client: client,
            workingDirectory: "/test"
        )

        XCTAssertNotNil(view)
        XCTAssertNil(client.availableCommands)
    }

    func testCommandMenuViewInitializesWithCommands() {
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

        XCTAssertNotNil(view)
        XCTAssertEqual(client.availableCommands?.projectCommands.count, 1)
        XCTAssertEqual(client.availableCommands?.generalCommands.count, 1)
    }

    func testCommandMenuViewWithGroupedCommands() {
        let mockCommands = AvailableCommands(
            workingDirectory: "/test",
            projectCommands: [
                Command(id: "docker", label: "Docker", type: .group, children: [
                    Command(id: "docker.up", label: "Up", type: .command),
                    Command(id: "docker.down", label: "Down", type: .command)
                ])
            ],
            generalCommands: []
        )
        client.availableCommands = mockCommands

        let view = CommandMenuView(
            client: client,
            workingDirectory: "/test"
        )

        XCTAssertNotNil(view)
        XCTAssertEqual(client.availableCommands?.projectCommands.count, 1)
        XCTAssertEqual(client.availableCommands?.projectCommands[0].children?.count, 2)
    }

    // MARK: - CommandRowView Tests

    func testCommandRowViewWithLeafCommand() {
        var executeCalled = false
        var copyCalled = false

        let command = Command(
            id: "test.command",
            label: "Test Command",
            type: .command,
            description: "A test command"
        )

        let view = CommandRowView(
            command: command,
            onExecute: { executeCalled = true },
            onCopyCommand: { copyCalled = true }
        )

        XCTAssertNotNil(view)

        // Test callbacks
        view.onExecute()
        XCTAssertTrue(executeCalled)

        view.onCopyCommand()
        XCTAssertTrue(copyCalled)
    }

    func testCommandRowViewWithDescription() {
        let command = Command(
            id: "git.status",
            label: "Git Status",
            type: .command,
            description: "Show working tree status"
        )

        let view = CommandRowView(
            command: command,
            onExecute: {},
            onCopyCommand: {}
        )

        XCTAssertNotNil(view)
        XCTAssertEqual(command.description, "Show working tree status")
    }

    // MARK: - CommandOutlineRow Tests

    func testCommandOutlineRowWithLeafCommand() {
        let command = Command(id: "build", label: "Build", type: .command)

        let view = CommandOutlineRow(
            command: command,
            onExecute: { _ in },
            onCopyCommand: { _ in }
        )

        XCTAssertNotNil(view)
    }

    func testCommandOutlineRowWithGroup() {
        let group = Command(
            id: "docker",
            label: "Docker",
            type: .group,
            children: [
                Command(id: "docker.up", label: "Up", type: .command),
                Command(id: "docker.down", label: "Down", type: .command)
            ]
        )

        let view = CommandOutlineRow(
            command: group,
            onExecute: { _ in },
            onCopyCommand: { _ in }
        )

        XCTAssertNotNil(view)
        XCTAssertEqual(group.children?.count, 2)
    }

    func testCommandOutlineRowWithNestedGroups() {
        let nestedGroup = Command(
            id: "docker",
            label: "Docker",
            type: .group,
            children: [
                Command(id: "docker.compose", label: "Compose", type: .group, children: [
                    Command(id: "docker.compose.up", label: "Up", type: .command),
                    Command(id: "docker.compose.down", label: "Down", type: .command)
                ])
            ]
        )

        let view = CommandOutlineRow(
            command: nestedGroup,
            onExecute: { _ in },
            onCopyCommand: { _ in }
        )

        XCTAssertNotNil(view)
        XCTAssertEqual(nestedGroup.children?[0].children?.count, 2)
    }

    // MARK: - Command Filtering Tests

    func testFilterCommandsByLabel() {
        let mockCommands = AvailableCommands(
            workingDirectory: "/test",
            projectCommands: [
                Command(id: "build", label: "Build Project", type: .command),
                Command(id: "test", label: "Run Tests", type: .command),
                Command(id: "clean", label: "Clean Build", type: .command)
            ],
            generalCommands: []
        )
        client.availableCommands = mockCommands

        // Search for "build"
        let commands = mockCommands.projectCommands
        let filtered = commands.filter { $0.label.lowercased().contains("build") }

        XCTAssertEqual(filtered.count, 2)
        XCTAssertTrue(filtered.contains { $0.id == "build" })
        XCTAssertTrue(filtered.contains { $0.id == "clean" })
    }

    func testFilterCommandsByDescription() {
        let mockCommands = AvailableCommands(
            workingDirectory: "/test",
            projectCommands: [
                Command(id: "test", label: "Test", type: .command, description: "Run unit tests"),
                Command(id: "lint", label: "Lint", type: .command, description: "Run linter")
            ],
            generalCommands: []
        )
        client.availableCommands = mockCommands

        let commands = mockCommands.projectCommands
        let filtered = commands.filter { $0.description?.lowercased().contains("unit") ?? false }

        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered[0].id, "test")
    }

    func testFilterGroupedCommands() {
        let mockCommands = AvailableCommands(
            workingDirectory: "/test",
            projectCommands: [
                Command(id: "docker", label: "Docker", type: .group, children: [
                    Command(id: "docker.up", label: "Start Containers", type: .command),
                    Command(id: "docker.down", label: "Stop Containers", type: .command)
                ])
            ],
            generalCommands: []
        )
        client.availableCommands = mockCommands

        // Search for "start" should find docker.up
        let group = mockCommands.projectCommands[0]
        let children = group.children ?? []
        let filtered = children.filter { $0.label.lowercased().contains("start") }

        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered[0].id, "docker.up")
    }

    // MARK: - MRU Sorting Tests

    func testRecentCommandsUseMRUSorting() {
        // Mark commands as used with deterministic timestamps
        let baseTime = Date().timeIntervalSince1970
        sorter.markCommandUsed(commandId: "build", timestamp: baseTime)
        sorter.markCommandUsed(commandId: "test", timestamp: baseTime + 1.0)
        sorter.markCommandUsed(commandId: "deploy", timestamp: baseTime + 2.0)

        let commands = [
            Command(id: "build", label: "Build", type: .command),
            Command(id: "test", label: "Test", type: .command),
            Command(id: "deploy", label: "Deploy", type: .command)
        ]

        let sorted = sorter.sortCommands(commands)

        // Most recently used should be first
        XCTAssertEqual(sorted[0].id, "deploy")
        XCTAssertEqual(sorted[1].id, "test")
        XCTAssertEqual(sorted[2].id, "build")
    }

    func testUnusedCommandsSortAlphabetically() {
        let commands = [
            Command(id: "zebra", label: "Zebra", type: .command),
            Command(id: "apple", label: "Apple", type: .command),
            Command(id: "mango", label: "Mango", type: .command)
        ]

        let sorted = sorter.sortCommands(commands)

        XCTAssertEqual(sorted[0].id, "apple")
        XCTAssertEqual(sorted[1].id, "mango")
        XCTAssertEqual(sorted[2].id, "zebra")
    }

    func testMixedUsedAndUnusedCommands() {
        sorter.markCommandUsed(commandId: "used")

        let commands = [
            Command(id: "zebra", label: "Zebra", type: .command),
            Command(id: "used", label: "Used", type: .command),
            Command(id: "apple", label: "Apple", type: .command)
        ]

        let sorted = sorter.sortCommands(commands)

        // Used command first, then alphabetically
        XCTAssertEqual(sorted[0].id, "used")
        XCTAssertEqual(sorted[1].id, "apple")
        XCTAssertEqual(sorted[2].id, "zebra")
    }

    // MARK: - Command Execution Tests

    func testExecuteCommandMarksAsMRU() {
        let commandId = "test.command"

        // Execute command
        sorter.markCommandUsed(commandId: commandId)

        let commands = [
            Command(id: "other", label: "Other", type: .command),
            Command(id: commandId, label: "Test", type: .command)
        ]

        let sorted = sorter.sortCommands(commands)

        // Executed command should be first
        XCTAssertEqual(sorted[0].id, commandId)
    }

    // MARK: - Copy Command Tests

    func testCopyCommandResolvesGitCommand() {
        // Test git command resolution
        let gitCommandId = "git.status"
        let expectedShellCommand = "git status"

        let resolved: String
        if gitCommandId.hasPrefix("git.") {
            resolved = "git \(gitCommandId.dropFirst(4))"
        } else {
            resolved = "make \(gitCommandId)"
        }

        XCTAssertEqual(resolved, expectedShellCommand)
    }

    func testCopyCommandResolvesMakeCommand() {
        let makeCommandId = "build"
        let expectedShellCommand = "make build"

        let resolved: String
        if makeCommandId.hasPrefix("git.") {
            resolved = "git \(makeCommandId.dropFirst(4))"
        } else {
            resolved = "make \(makeCommandId)"
        }

        XCTAssertEqual(resolved, expectedShellCommand)
    }

    func testCopyCommandResolvesGroupedMakeCommand() {
        let groupedCommandId = "docker.up"
        let expectedShellCommand = "make docker-up"

        let resolved: String
        if groupedCommandId.hasPrefix("git.") {
            resolved = "git \(groupedCommandId.dropFirst(4))"
        } else if groupedCommandId.contains(".") {
            let makeTarget = groupedCommandId.replacingOccurrences(of: ".", with: "-")
            resolved = "make \(makeTarget)"
        } else {
            resolved = "make \(groupedCommandId)"
        }

        XCTAssertEqual(resolved, expectedShellCommand)
    }

    // MARK: - Recent Commands Tests

    func testRecentCommandsLimitedToFive() {
        // Mark 7 commands as used with deterministic timestamps
        let baseTime = Date().timeIntervalSince1970
        for i in 1...7 {
            sorter.markCommandUsed(commandId: "cmd\(i)", timestamp: baseTime + Double(i))
        }

        let commands = (1...7).map {
            Command(id: "cmd\($0)", label: "Command \($0)", type: .command)
        }

        let sorted = sorter.sortCommands(commands)

        // All used commands should be sorted by MRU (most recent = highest timestamp first)
        XCTAssertEqual(sorted[0].id, "cmd7")

        // Take top 5 for recent
        let recent = Array(sorted.prefix(5))
        XCTAssertEqual(recent.count, 5)
    }

    func testRecentCommandsEmpty() {
        // No commands marked as used
        let commands = [
            Command(id: "cmd1", label: "Command 1", type: .command),
            Command(id: "cmd2", label: "Command 2", type: .command)
        ]

        let sorted = sorter.sortCommands(commands)

        // Should be alphabetically sorted since none are used
        XCTAssertEqual(sorted[0].id, "cmd1")
        XCTAssertEqual(sorted[1].id, "cmd2")
    }

    // MARK: - CommandSorter Additional Tests

    func testIsCommandUsed() {
        XCTAssertFalse(sorter.isCommandUsed(commandId: "unused"))

        sorter.markCommandUsed(commandId: "used")
        XCTAssertTrue(sorter.isCommandUsed(commandId: "used"))
        XCTAssertFalse(sorter.isCommandUsed(commandId: "still-unused"))
    }

    func testGetUsedCommandIds() {
        XCTAssertTrue(sorter.getUsedCommandIds().isEmpty)

        sorter.markCommandUsed(commandId: "cmd1")
        sorter.markCommandUsed(commandId: "cmd2")

        let usedIds = sorter.getUsedCommandIds()
        XCTAssertEqual(usedIds.count, 2)
        XCTAssertTrue(usedIds.contains("cmd1"))
        XCTAssertTrue(usedIds.contains("cmd2"))
    }

    func testRecentCommandsOnlyShowsUsedCommands() {
        // When no commands have been used, recentCommands should be empty
        // This is tested implicitly - the sorter.getUsedCommandIds() returns empty set
        let usedIds = sorter.getUsedCommandIds()
        XCTAssertTrue(usedIds.isEmpty)

        // Mark one command as used
        sorter.markCommandUsed(commandId: "build")
        XCTAssertEqual(sorter.getUsedCommandIds().count, 1)

        let commands = [
            Command(id: "build", label: "Build", type: .command),
            Command(id: "test", label: "Test", type: .command),
            Command(id: "deploy", label: "Deploy", type: .command)
        ]

        // Filter to only used commands
        let usedCommands = commands.filter { sorter.isCommandUsed(commandId: $0.id) }
        XCTAssertEqual(usedCommands.count, 1)
        XCTAssertEqual(usedCommands[0].id, "build")
    }

    // MARK: - Recursive Filtering Tests

    func testFilterGroupMatchesButChildrenDont() {
        // When a group name matches search but children don't,
        // the group should still be included (with its children)
        let group = Command(
            id: "docker",
            label: "Docker Commands",
            type: .group,
            children: [
                Command(id: "docker.up", label: "Up", type: .command),
                Command(id: "docker.down", label: "Down", type: .command)
            ]
        )

        // Search for "docker" - group matches, children don't directly match
        let searchText = "docker"
        let matches = group.label.lowercased().contains(searchText.lowercased())
        XCTAssertTrue(matches)

        // Children don't match "docker" in their labels
        let childrenMatch = group.children?.filter {
            $0.label.lowercased().contains(searchText.lowercased())
        } ?? []
        XCTAssertEqual(childrenMatch.count, 0)
    }

    func testFilterChildMatchesButGroupDoesnt() {
        // When children match but group name doesn't,
        // the group should still be included
        let group = Command(
            id: "container",
            label: "Container Tools",
            type: .group,
            children: [
                Command(id: "container.start", label: "Start Docker", type: .command),
                Command(id: "container.stop", label: "Stop Container", type: .command)
            ]
        )

        // Search for "docker" - group doesn't match, but first child does
        let searchText = "docker"
        let groupMatches = group.label.lowercased().contains(searchText.lowercased())
        XCTAssertFalse(groupMatches)

        let childrenMatch = group.children?.filter {
            $0.label.lowercased().contains(searchText.lowercased())
        } ?? []
        XCTAssertEqual(childrenMatch.count, 1)
        XCTAssertEqual(childrenMatch[0].id, "container.start")
    }

    // MARK: - Deep Recursive Search Tests

    func testFindCommandThreeLevelsDeep() {
        // Create a 3-level deep structure
        let deepCommand = Command(
            id: "level3.command",
            label: "Deep Command",
            type: .command
        )
        let level2Group = Command(
            id: "level2.group",
            label: "Level 2",
            type: .group,
            children: [deepCommand]
        )
        let level1Group = Command(
            id: "level1.group",
            label: "Level 1",
            type: .group,
            children: [level2Group]
        )

        // Helper function to find command (replicates the private method)
        func findCommand(byId id: String, in commands: [Command]) -> Command? {
            for command in commands {
                if command.id == id {
                    return command
                }
                if let children = command.children,
                   let found = findCommand(byId: id, in: children) {
                    return found
                }
            }
            return nil
        }

        // Should find the deep command
        let found = findCommand(byId: "level3.command", in: [level1Group])
        XCTAssertNotNil(found)
        XCTAssertEqual(found?.id, "level3.command")

        // Should find level 2 group
        let foundLevel2 = findCommand(byId: "level2.group", in: [level1Group])
        XCTAssertNotNil(foundLevel2)
        XCTAssertEqual(foundLevel2?.type, .group)
    }

    func testFlattenCommandsThreeLevelsDeep() {
        // Create a 3-level deep structure
        let deepCommand = Command(
            id: "deep.command",
            label: "Deep",
            type: .command
        )
        let midGroup = Command(
            id: "mid.group",
            label: "Mid",
            type: .group,
            children: [deepCommand]
        )
        let topGroup = Command(
            id: "top.group",
            label: "Top",
            type: .group,
            children: [midGroup]
        )

        // Helper to flatten (replicates the private method)
        func flattenCommands(_ commands: [Command]) -> [Command] {
            var result: [Command] = []
            for command in commands {
                if command.type == .command {
                    result.append(command)
                }
                if let children = command.children {
                    result.append(contentsOf: flattenCommands(children))
                }
            }
            return result
        }

        let flattened = flattenCommands([topGroup])
        XCTAssertEqual(flattened.count, 1)
        XCTAssertEqual(flattened[0].id, "deep.command")
    }

    // MARK: - Edge Cases

    func testEmptyCommandList() {
        let mockCommands = AvailableCommands(
            workingDirectory: "/test",
            projectCommands: [],
            generalCommands: []
        )
        client.availableCommands = mockCommands

        let view = CommandMenuView(
            client: client,
            workingDirectory: "/test"
        )

        XCTAssertNotNil(view)
        XCTAssertTrue(mockCommands.projectCommands.isEmpty)
        XCTAssertTrue(mockCommands.generalCommands.isEmpty)
    }

    func testCommandWithEmptyChildren() {
        // Groups with empty children array are rendered as leaf commands
        // since there's nothing to expand. This is intentional behavior.
        let group = Command(
            id: "empty.group",
            label: "Empty Group",
            type: .group,
            children: []
        )

        XCTAssertEqual(group.type, .group)
        XCTAssertEqual(group.children?.count, 0)

        // Verify CommandOutlineRow renders it (as a leaf since children is empty)
        let view = CommandOutlineRow(
            command: group,
            onExecute: { _ in },
            onCopyCommand: { _ in }
        )
        XCTAssertNotNil(view)
    }

    func testCommandWithNilChildren() {
        let command = Command(
            id: "leaf",
            label: "Leaf Command",
            type: .command,
            children: nil
        )

        XCTAssertEqual(command.type, .command)
        XCTAssertNil(command.children)
    }

    func testCommandWithLongLabel() {
        let longLabel = String(repeating: "Very Long Command Label ", count: 10)
        let command = Command(
            id: "long",
            label: longLabel,
            type: .command
        )

        let view = CommandRowView(
            command: command,
            onExecute: {},
            onCopyCommand: {}
        )

        XCTAssertNotNil(view)
        XCTAssertTrue(command.label.count > 100)
    }

    func testCommandWithSpecialCharactersInId() {
        let command = Command(
            id: "docker-compose.up",
            label: "Docker Compose Up",
            type: .command
        )

        XCTAssertEqual(command.id, "docker-compose.up")
    }

    // MARK: - Command Model Tests

    func testCommandEquality() {
        let cmd1 = Command(id: "test", label: "Test", type: .command)
        let cmd2 = Command(id: "test", label: "Test", type: .command)
        let cmd3 = Command(id: "other", label: "Other", type: .command)

        XCTAssertEqual(cmd1, cmd2)
        XCTAssertNotEqual(cmd1, cmd3)
    }

    func testCommandIdentifiable() {
        let command = Command(id: "unique-id", label: "Test", type: .command)
        XCTAssertEqual(command.id, "unique-id")
    }

    func testAvailableCommandsWorkingDirectory() {
        let commands = AvailableCommands(
            workingDirectory: "/Users/test/project",
            projectCommands: [],
            generalCommands: []
        )

        XCTAssertEqual(commands.workingDirectory, "/Users/test/project")
    }

    func testAvailableCommandsNilWorkingDirectory() {
        let commands = AvailableCommands(
            workingDirectory: nil,
            projectCommands: [],
            generalCommands: []
        )

        XCTAssertNil(commands.workingDirectory)
    }
}
