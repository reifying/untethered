import XCTest
@testable import VoiceCodeShared

final class UtilityTests: XCTestCase {

    // MARK: - TextProcessor Tests

    func testRemoveFencedCodeBlocks() {
        let markdown = """
        Here is some code:
        ```swift
        let x = 5
        print(x)
        ```
        And more text.
        """
        let result = TextProcessor.removeCodeBlocks(from: markdown)
        XCTAssertTrue(result.contains("[code block]"))
        XCTAssertFalse(result.contains("let x = 5"))
        XCTAssertTrue(result.contains("And more text."))
    }

    func testRemoveInlineCode() {
        let markdown = "Use the `print()` function to output text."
        let result = TextProcessor.removeCodeBlocks(from: markdown)
        XCTAssertEqual(result, "Use the print() function to output text.")
    }

    func testRemoveMultipleCodeBlocks() {
        let markdown = """
        First block:
        ```
        code1
        ```
        Second block:
        ```python
        code2
        ```
        Done.
        """
        let result = TextProcessor.removeCodeBlocks(from: markdown)
        XCTAssertEqual(result.components(separatedBy: "[code block]").count, 3)
    }

    func testCleanupExcessiveNewlines() {
        let markdown = """
        Before



        After
        """
        let result = TextProcessor.removeCodeBlocks(from: markdown)
        XCTAssertFalse(result.contains("\n\n\n"))
    }

    // MARK: - CommandSorter Tests

    func testCommandSorterMRU() {
        let sorter = CommandSorter(userDefaults: .standard)
        sorter.clearMRU()

        let commands = [
            Command(id: "a", label: "Alpha", type: .command),
            Command(id: "b", label: "Beta", type: .command),
            Command(id: "c", label: "Charlie", type: .command)
        ]

        // Initially sorted alphabetically
        let initial = sorter.sortCommands(commands)
        XCTAssertEqual(initial.map { $0.id }, ["a", "b", "c"])

        // Mark 'c' as used, should come first
        sorter.markCommandUsed(commandId: "c")
        let afterC = sorter.sortCommands(commands)
        XCTAssertEqual(afterC.first?.id, "c")

        // Mark 'a' as used, should come first (most recent)
        sorter.markCommandUsed(commandId: "a")
        let afterA = sorter.sortCommands(commands)
        XCTAssertEqual(afterA.first?.id, "a")
        XCTAssertEqual(afterA[1].id, "c") // Second most recent

        sorter.clearMRU()
    }

    func testCommandSorterRecursiveGroups() {
        let sorter = CommandSorter(userDefaults: .standard)
        sorter.clearMRU()

        let children = [
            Command(id: "child.b", label: "Beta Child", type: .command),
            Command(id: "child.a", label: "Alpha Child", type: .command)
        ]
        let group = Command(id: "group", label: "Group", type: .group, children: children)

        let sorted = sorter.sortCommands([group])
        XCTAssertEqual(sorted.first?.children?.first?.id, "child.a") // Alphabetical

        sorter.clearMRU()
    }
}
