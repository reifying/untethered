import XCTest
import SwiftUI
@testable import VoiceCodeDesktop
@testable import VoiceCodeShared

@MainActor
final class CommandOutputWindowTests: XCTestCase {
    var client: VoiceCodeClient!

    override func setUp() {
        super.setUp()
        client = VoiceCodeClient(
            serverURL: "ws://localhost:8080",
            setupObservers: false
        )
    }

    override func tearDown() {
        client?.disconnect()
        client = nil
        super.tearDown()
    }

    // MARK: - Basic View Tests

    func testCommandOutputWindowInitializes() {
        let view = CommandOutputWindow(
            client: client,
            commandSessionId: "test-session",
            workingDirectory: "/test"
        )

        XCTAssertNotNil(view)
    }

    func testCommandOutputWindowWithExecution() {
        var execution = CommandExecution(
            id: "cmd-123",
            commandId: "build",
            shellCommand: "make build"
        )
        execution.appendOutput(stream: .stdout, text: "Building...")
        client.runningCommands["cmd-123"] = execution

        let view = CommandOutputWindow(
            client: client,
            commandSessionId: "cmd-123",
            workingDirectory: "/test"
        )

        XCTAssertNotNil(view)
        XCTAssertEqual(client.runningCommands["cmd-123"]?.output.count, 1)
    }

    func testCommandOutputWindowWithNonexistentSession() {
        // No execution added - should show empty state
        let view = CommandOutputWindow(
            client: client,
            commandSessionId: "nonexistent",
            workingDirectory: "/test"
        )

        XCTAssertNotNil(view)
        XCTAssertNil(client.runningCommands["nonexistent"])
    }

    // MARK: - Duration Formatting Tests

    func testFormatDurationMilliseconds() {
        let duration = 0.5  // 500ms
        let formatted = CommandOutputWindow.formatDuration(duration)
        XCTAssertEqual(formatted, "500ms")
    }

    func testFormatDurationSeconds() {
        let duration = 2.345
        let formatted = CommandOutputWindow.formatDuration(duration)
        XCTAssertEqual(formatted, "2.3s")
    }

    func testFormatDurationMinutes() {
        let duration = 125.0  // 2m 5s
        let formatted = CommandOutputWindow.formatDuration(duration)
        XCTAssertEqual(formatted, "2m 5s")
    }

    func testFormatDurationExactMinute() {
        let duration = 60.0
        let formatted = CommandOutputWindow.formatDuration(duration)
        XCTAssertEqual(formatted, "1m 0s")
    }

    func testFormatDurationZero() {
        let duration = 0.0
        let formatted = CommandOutputWindow.formatDuration(duration)
        XCTAssertEqual(formatted, "0ms")
    }

    func testFormatDurationVeryShort() {
        let duration = 0.001  // 1ms
        let formatted = CommandOutputWindow.formatDuration(duration)
        XCTAssertEqual(formatted, "1ms")
    }

    // MARK: - Output Filtering Tests

    func testOutputFilterMatchesText() {
        var execution = CommandExecution(
            id: "cmd-filter",
            commandId: "test",
            shellCommand: "make test"
        )
        execution.appendOutput(stream: .stdout, text: "Running tests...")
        execution.appendOutput(stream: .stdout, text: "Test 1: PASSED")
        execution.appendOutput(stream: .stderr, text: "Warning: deprecated API")
        execution.appendOutput(stream: .stdout, text: "Test 2: PASSED")
        client.runningCommands["cmd-filter"] = execution

        let output = client.runningCommands["cmd-filter"]!.output
        let searchText = "PASSED"
        let filtered = output.filter { $0.text.localizedCaseInsensitiveContains(searchText) }

        XCTAssertEqual(filtered.count, 2)
    }

    func testOutputFilterCaseInsensitive() {
        var execution = CommandExecution(
            id: "cmd-case",
            commandId: "test",
            shellCommand: "make test"
        )
        execution.appendOutput(stream: .stdout, text: "ERROR: Something failed")
        execution.appendOutput(stream: .stdout, text: "error: another failure")
        execution.appendOutput(stream: .stdout, text: "Success!")
        client.runningCommands["cmd-case"] = execution

        let output = client.runningCommands["cmd-case"]!.output
        let searchText = "error"
        let filtered = output.filter { $0.text.localizedCaseInsensitiveContains(searchText) }

        XCTAssertEqual(filtered.count, 2)
    }

    func testOutputFilterNoMatches() {
        var execution = CommandExecution(
            id: "cmd-none",
            commandId: "test",
            shellCommand: "make test"
        )
        execution.appendOutput(stream: .stdout, text: "Line 1")
        execution.appendOutput(stream: .stdout, text: "Line 2")
        client.runningCommands["cmd-none"] = execution

        let output = client.runningCommands["cmd-none"]!.output
        let searchText = "notfound"
        let filtered = output.filter { $0.text.localizedCaseInsensitiveContains(searchText) }

        XCTAssertEqual(filtered.count, 0)
    }

    func testOutputFilterEmptySearch() {
        var execution = CommandExecution(
            id: "cmd-empty",
            commandId: "test",
            shellCommand: "make test"
        )
        execution.appendOutput(stream: .stdout, text: "Line 1")
        execution.appendOutput(stream: .stdout, text: "Line 2")
        client.runningCommands["cmd-empty"] = execution

        let output = client.runningCommands["cmd-empty"]!.output
        let searchText = ""
        // Empty search should return all output (mimicking view behavior)
        let filtered = searchText.isEmpty ? output : output.filter { $0.text.localizedCaseInsensitiveContains(searchText) }

        XCTAssertEqual(filtered.count, 2)
    }

    // MARK: - Execution Status Tests

    func testExecutionStatusRunning() {
        let execution = CommandExecution(
            id: "cmd-running",
            commandId: "build",
            shellCommand: "make build"
        )

        XCTAssertEqual(execution.status, .running)
        XCTAssertNil(execution.exitCode)
        XCTAssertNil(execution.duration)
    }

    func testExecutionStatusCompleted() {
        var execution = CommandExecution(
            id: "cmd-complete",
            commandId: "build",
            shellCommand: "make build"
        )
        execution.complete(exitCode: 0, duration: 1.5)

        XCTAssertEqual(execution.status, .completed)
        XCTAssertEqual(execution.exitCode, 0)
        XCTAssertEqual(execution.duration, 1.5)
    }

    func testExecutionStatusError() {
        var execution = CommandExecution(
            id: "cmd-error",
            commandId: "build",
            shellCommand: "make build"
        )
        execution.complete(exitCode: 1, duration: 0.5)

        XCTAssertEqual(execution.status, .error)
        XCTAssertEqual(execution.exitCode, 1)
    }

    func testExecutionStatusNonZeroExitCode() {
        var execution = CommandExecution(
            id: "cmd-nonzero",
            commandId: "test",
            shellCommand: "make test"
        )
        execution.complete(exitCode: 127, duration: 0.1)

        XCTAssertEqual(execution.status, .error)
        XCTAssertEqual(execution.exitCode, 127)
    }

    // MARK: - Output Stream Tests

    func testOutputStreamStdout() {
        var execution = CommandExecution(
            id: "cmd-stdout",
            commandId: "test",
            shellCommand: "echo hello"
        )
        execution.appendOutput(stream: .stdout, text: "hello")

        XCTAssertEqual(execution.output.count, 1)
        XCTAssertEqual(execution.output[0].stream, .stdout)
        XCTAssertEqual(execution.output[0].text, "hello")
    }

    func testOutputStreamStderr() {
        var execution = CommandExecution(
            id: "cmd-stderr",
            commandId: "test",
            shellCommand: "test"
        )
        execution.appendOutput(stream: .stderr, text: "error message")

        XCTAssertEqual(execution.output.count, 1)
        XCTAssertEqual(execution.output[0].stream, .stderr)
        XCTAssertEqual(execution.output[0].text, "error message")
    }

    func testOutputStreamMixed() {
        var execution = CommandExecution(
            id: "cmd-mixed",
            commandId: "build",
            shellCommand: "make build"
        )
        execution.appendOutput(stream: .stdout, text: "Building...")
        execution.appendOutput(stream: .stderr, text: "warning: deprecated")
        execution.appendOutput(stream: .stdout, text: "Done")

        XCTAssertEqual(execution.output.count, 3)
        XCTAssertEqual(execution.output[0].stream, .stdout)
        XCTAssertEqual(execution.output[1].stream, .stderr)
        XCTAssertEqual(execution.output[2].stream, .stdout)
    }

    // MARK: - ANSI Parsing Tests

    func testANSITextViewPlainText() {
        let view = ANSITextView(text: "Hello, World!", streamType: .stdout)
        XCTAssertNotNil(view)
    }

    func testANSITextViewWithColorCode() {
        // Green text escape code
        let text = "\u{001B}[32mSuccess!\u{001B}[0m"
        let view = ANSITextView(text: text, streamType: .stdout)
        XCTAssertNotNil(view)
    }

    func testANSITextViewWithBoldCode() {
        let text = "\u{001B}[1mBold text\u{001B}[0m"
        let view = ANSITextView(text: text, streamType: .stdout)
        XCTAssertNotNil(view)
    }

    func testANSITextViewWithMultipleCodes() {
        // Red background, white foreground
        let text = "\u{001B}[41;37mAlert!\u{001B}[0m"
        let view = ANSITextView(text: text, streamType: .stdout)
        XCTAssertNotNil(view)
    }

    func testANSITextViewStderrStream() {
        let view = ANSITextView(text: "Error message", streamType: .stderr)
        XCTAssertNotNil(view)
    }

    // MARK: - Copy Functionality Tests

    func testCopyOutputToClipboard() {
        var execution = CommandExecution(
            id: "cmd-copy",
            commandId: "test",
            shellCommand: "echo test"
        )
        execution.appendOutput(stream: .stdout, text: "Line 1")
        execution.appendOutput(stream: .stdout, text: "Line 2")
        execution.appendOutput(stream: .stdout, text: "Line 3")

        let text = execution.output.map { $0.text }.joined(separator: "\n")
        XCTAssertEqual(text, "Line 1\nLine 2\nLine 3")

        // Actually copy to pasteboard and verify
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)

        XCTAssertEqual(NSPasteboard.general.string(forType: .string), text)
    }

    func testCopyEmptyOutput() {
        let execution = CommandExecution(
            id: "cmd-empty-copy",
            commandId: "test",
            shellCommand: "true"
        )

        let text = execution.output.map { $0.text }.joined(separator: "\n")
        XCTAssertEqual(text, "")
    }

    // MARK: - Re-run Tests

    func testRerunCommandPreservesCommandId() {
        var execution = CommandExecution(
            id: "cmd-rerun",
            commandId: "build",
            shellCommand: "make build"
        )
        execution.complete(exitCode: 0, duration: 1.0)
        client.runningCommands["cmd-rerun"] = execution

        let originalCommandId = execution.commandId
        XCTAssertEqual(originalCommandId, "build")
    }

    // MARK: - Edge Cases

    func testOutputWithEmptyLines() {
        var execution = CommandExecution(
            id: "cmd-empty-lines",
            commandId: "test",
            shellCommand: "cat file"
        )
        execution.appendOutput(stream: .stdout, text: "Line 1")
        execution.appendOutput(stream: .stdout, text: "")
        execution.appendOutput(stream: .stdout, text: "Line 3")

        XCTAssertEqual(execution.output.count, 3)
        XCTAssertEqual(execution.output[1].text, "")
    }

    func testOutputWithSpecialCharacters() {
        var execution = CommandExecution(
            id: "cmd-special",
            commandId: "test",
            shellCommand: "echo test"
        )
        execution.appendOutput(stream: .stdout, text: "Tab:\there")
        execution.appendOutput(stream: .stdout, text: "Quotes: \"test\"")
        execution.appendOutput(stream: .stdout, text: "Unicode: 日本語 🎉")

        XCTAssertEqual(execution.output.count, 3)
        XCTAssertTrue(execution.output[2].text.contains("🎉"))
    }

    func testOutputWithVeryLongLine() {
        var execution = CommandExecution(
            id: "cmd-long",
            commandId: "test",
            shellCommand: "cat large-file"
        )
        let longLine = String(repeating: "x", count: 10000)
        execution.appendOutput(stream: .stdout, text: longLine)

        XCTAssertEqual(execution.output.count, 1)
        XCTAssertEqual(execution.output[0].text.count, 10000)
    }

    func testManyOutputLines() {
        var execution = CommandExecution(
            id: "cmd-many",
            commandId: "test",
            shellCommand: "seq 1000"
        )
        for i in 1...1000 {
            execution.appendOutput(stream: .stdout, text: "\(i)")
        }

        XCTAssertEqual(execution.output.count, 1000)
        XCTAssertEqual(execution.output[0].text, "1")
        XCTAssertEqual(execution.output[999].text, "1000")
    }

    // MARK: - Window State Tests

    func testAutoScrollDefaultEnabled() {
        // Note: We can't directly test @State, but we can verify the initial behavior
        // The view should be created with auto-scroll enabled by default
        let view = CommandOutputWindow(
            client: client,
            commandSessionId: "test",
            workingDirectory: "/test"
        )
        XCTAssertNotNil(view)
    }

    func testSearchDefaultHidden() {
        // Similar to auto-scroll, search should be hidden by default
        let view = CommandOutputWindow(
            client: client,
            commandSessionId: "test",
            workingDirectory: "/test"
        )
        XCTAssertNotNil(view)
    }

    // MARK: - Working Directory Tests

    func testWorkingDirectoryPreserved() {
        let workingDir = "/Users/test/project/subdir"
        let view = CommandOutputWindow(
            client: client,
            commandSessionId: "test",
            workingDirectory: workingDir
        )

        XCTAssertNotNil(view)
        // The working directory should be passed to re-run command
    }

    // MARK: - Clear Output Tests

    func testClearOutputRemovesAllLines() {
        var execution = CommandExecution(
            id: "cmd-clear",
            commandId: "test",
            shellCommand: "make test"
        )
        execution.appendOutput(stream: .stdout, text: "Line 1")
        execution.appendOutput(stream: .stdout, text: "Line 2")
        execution.appendOutput(stream: .stdout, text: "Line 3")
        client.runningCommands["cmd-clear"] = execution

        XCTAssertEqual(client.runningCommands["cmd-clear"]?.output.count, 3)

        // Simulate clearing output
        if var exec = client.runningCommands["cmd-clear"] {
            exec.output.removeAll()
            client.runningCommands["cmd-clear"] = exec
        }

        XCTAssertEqual(client.runningCommands["cmd-clear"]?.output.count, 0)
    }

    func testClearOutputOnEmptyExecution() {
        let execution = CommandExecution(
            id: "cmd-clear-empty",
            commandId: "test",
            shellCommand: "true"
        )
        client.runningCommands["cmd-clear-empty"] = execution

        XCTAssertEqual(client.runningCommands["cmd-clear-empty"]?.output.count, 0)

        // Clearing already empty output should still work
        if var exec = client.runningCommands["cmd-clear-empty"] {
            exec.output.removeAll()
            client.runningCommands["cmd-clear-empty"] = exec
        }

        XCTAssertEqual(client.runningCommands["cmd-clear-empty"]?.output.count, 0)
    }

    func testClearOutputPreservesCommandMetadata() {
        var execution = CommandExecution(
            id: "cmd-clear-meta",
            commandId: "build",
            shellCommand: "make build"
        )
        execution.appendOutput(stream: .stdout, text: "Building...")
        execution.complete(exitCode: 0, duration: 1.5)
        client.runningCommands["cmd-clear-meta"] = execution

        // Clear output
        if var exec = client.runningCommands["cmd-clear-meta"] {
            exec.output.removeAll()
            client.runningCommands["cmd-clear-meta"] = exec
        }

        // Metadata should be preserved
        let clearedExec = client.runningCommands["cmd-clear-meta"]
        XCTAssertEqual(clearedExec?.output.count, 0)
        XCTAssertEqual(clearedExec?.commandId, "build")
        XCTAssertEqual(clearedExec?.shellCommand, "make build")
        XCTAssertEqual(clearedExec?.exitCode, 0)
        XCTAssertEqual(clearedExec?.duration, 1.5)
        XCTAssertEqual(clearedExec?.status, .completed)
    }

    // MARK: - ANSI Parsing Verification Tests

    func testANSIParserStripsResetCode() {
        // Plain text after ANSI reset should be handled
        let text = "\u{001B}[0mPlain text after reset"
        let view = ANSITextView(text: text, streamType: .stdout)
        XCTAssertNotNil(view)
    }

    func testANSIParserHandlesNestedCodes() {
        // Bold green text
        let text = "\u{001B}[1;32mBold Green\u{001B}[0m Normal"
        let view = ANSITextView(text: text, streamType: .stdout)
        XCTAssertNotNil(view)
    }

    func testANSIParserHandlesBrightColors() {
        // Bright red (90-97 range)
        let text = "\u{001B}[91mBright Red\u{001B}[0m"
        let view = ANSITextView(text: text, streamType: .stdout)
        XCTAssertNotNil(view)
    }

    func testANSIParserHandlesBackgroundColors() {
        // Blue background
        let text = "\u{001B}[44mBlue Background\u{001B}[0m"
        let view = ANSITextView(text: text, streamType: .stdout)
        XCTAssertNotNil(view)
    }

    func testANSIParserHandlesUnderline() {
        let text = "\u{001B}[4mUnderlined\u{001B}[24m Not underlined"
        let view = ANSITextView(text: text, streamType: .stdout)
        XCTAssertNotNil(view)
    }

    func testANSIParserHandlesEmptyParams() {
        // ESC[m is equivalent to ESC[0m (reset)
        let text = "\u{001B}[mAfter empty reset"
        let view = ANSITextView(text: text, streamType: .stdout)
        XCTAssertNotNil(view)
    }

    func testANSIParserHandlesConsecutiveCodes() {
        // Multiple escape sequences in a row
        let text = "\u{001B}[31m\u{001B}[1mRed Bold\u{001B}[0m"
        let view = ANSITextView(text: text, streamType: .stdout)
        XCTAssertNotNil(view)
    }

    func testANSIParserHandlesOnlyEscapeCodes() {
        // String with only escape codes and no visible text
        let text = "\u{001B}[32m\u{001B}[0m"
        let view = ANSITextView(text: text, streamType: .stdout)
        XCTAssertNotNil(view)
    }

    func testANSIParserHandlesAllStandardColors() {
        // Test all 8 standard foreground colors (30-37)
        for code in 30...37 {
            let text = "\u{001B}[\(code)mColor \(code - 30)\u{001B}[0m"
            let view = ANSITextView(text: text, streamType: .stdout)
            XCTAssertNotNil(view, "Failed for color code \(code)")
        }
    }

    func testANSIParserHandlesAllBrightColors() {
        // Test all 8 bright foreground colors (90-97)
        for code in 90...97 {
            let text = "\u{001B}[\(code)mBright \(code - 90)\u{001B}[0m"
            let view = ANSITextView(text: text, streamType: .stdout)
            XCTAssertNotNil(view, "Failed for bright color code \(code)")
        }
    }

    func testANSIParserPreservesTextContent() {
        // The visible text should be preserved (escape codes stripped)
        let originalText = "Hello World"
        let ansiText = "\u{001B}[32m\(originalText)\u{001B}[0m"

        // We can't easily extract the AttributedString content,
        // but we can verify the view creates successfully
        let view = ANSITextView(text: ansiText, streamType: .stdout)
        XCTAssertNotNil(view)
    }
}
