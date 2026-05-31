//
//  ShareLogsWithAgentTests.swift
//  VoiceCodeTests
//
//  Tests for the Share Logs with Agent feature (tmux-untethered-11d):
//  the testable wire-format builders and filename timestamp used by
//  ConversationView.shareLogsWithAgent() / handleLogUploadResponse().
//

import XCTest
@testable import VoiceCode

final class ShareLogsWithAgentTests: XCTestCase {

    // MARK: - DateFormatter.logFileTimestamp

    func testLogFileTimestampFormatMatchesPattern() {
        // logFileTimestamp is a shared singleton; pin the timezone for a
        // deterministic assertion and restore it so we don't pollute other
        // tests or production (which uses the device-local timezone).
        let formatter = DateFormatter.logFileTimestamp
        let originalTimeZone = formatter.timeZone
        defer { formatter.timeZone = originalTimeZone }

        formatter.timeZone = TimeZone(identifier: "UTC")
        let date = Date(timeIntervalSince1970: 1_780_237_822) // 2026-05-31T14:30:22Z

        let stamp = formatter.string(from: date)

        XCTAssertEqual(stamp, "20260531-143022")
    }

    func testLogFileTimestampProducesUsableFilename() {
        let stamp = DateFormatter.logFileTimestamp.string(from: Date())
        let filename = "logs-\(stamp).txt"

        // Format is "logs-yyyyMMdd-HHmmss.txt": prefix + 8 date digits + "-" +
        // 6 time digits + extension. Verify with a regex so the share-logs
        // prefix filter (which keys on "logs-") always matches.
        let pattern = "^logs-[0-9]{8}-[0-9]{6}\\.txt$"
        let regex = try! NSRegularExpression(pattern: pattern)
        let range = NSRange(location: 0, length: filename.utf16.count)
        XCTAssertNotNil(regex.firstMatch(in: filename, range: range), "Unexpected filename: \(filename)")
        XCTAssertTrue(filename.hasPrefix("logs-"))
    }

    // MARK: - promptText

    func testPromptTextEmbedsResourcePath() {
        let text = ShareLogsMessageBuilder.promptText(forFilename: "logs-20260531-143022.txt")

        XCTAssertTrue(text.contains(".untethered/resources/logs-20260531-143022.txt"),
                      "Prompt should reference the resource path: \(text)")
        XCTAssertTrue(text.contains("read") && text.contains("review"),
                      "Prompt should ask the agent to read and review: \(text)")
    }

    // MARK: - uploadMessage

    func testUploadMessageWireFormat() {
        let message = ShareLogsMessageBuilder.uploadMessage(
            filename: "logs-20260531-143022.txt",
            base64Content: "aGVsbG8=",
            storageLocation: "/Users/test/project"
        )

        XCTAssertEqual(message["type"] as? String, "upload_file")
        XCTAssertEqual(message["filename"] as? String, "logs-20260531-143022.txt")
        XCTAssertEqual(message["content"] as? String, "aGVsbG8=")
        // storage_location must be the session's working directory, NOT the
        // global resourceStorageLocation setting (AC #8).
        XCTAssertEqual(message["storage_location"] as? String, "/Users/test/project")
        XCTAssertEqual(message.count, 4)
    }

    func testUploadMessageRoundTripsLogContent() {
        let logs = "[12:00:00.000] [VoiceCodeClient] connected\n[12:00:01.000] [HeadsetRemote] tap"
        let base64 = Data(logs.utf8).base64EncodedString()

        let message = ShareLogsMessageBuilder.uploadMessage(
            filename: "logs-x.txt",
            base64Content: base64,
            storageLocation: "/tmp"
        )

        let decoded = Data(base64Encoded: message["content"] as! String)
            .flatMap { String(data: $0, encoding: .utf8) }
        XCTAssertEqual(decoded, logs)
    }

    // MARK: - promptMessage (existing session)

    func testPromptMessageForExistingSessionUsesResumeSessionId() {
        let sessionId = "11111111-2222-3333-4444-555555555555"
        let message = ShareLogsMessageBuilder.promptMessage(
            actualFilename: "logs-20260531-143022.txt",
            sessionId: sessionId,
            workingDirectory: "/Users/test/project",
            isNewSession: false,
            provider: "claude",
            systemPrompt: ""
        )

        XCTAssertEqual(message["type"] as? String, "prompt")
        XCTAssertEqual(message["working_directory"] as? String, "/Users/test/project")
        XCTAssertEqual(message["resume_session_id"] as? String, sessionId)
        XCTAssertNil(message["new_session_id"], "Existing session must not send new_session_id")
        XCTAssertNil(message["provider"], "Existing session must not send provider")
        XCTAssertNil(message["system_prompt"], "Empty system prompt must be omitted")

        // Prompt text must reference the actual filename from the response.
        XCTAssertTrue((message["text"] as? String)?.contains("logs-20260531-143022.txt") == true)
    }

    // MARK: - promptMessage (new session)

    func testPromptMessageForNewSessionUsesNewSessionIdAndProvider() {
        let sessionId = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        let message = ShareLogsMessageBuilder.promptMessage(
            actualFilename: "logs-20260531-143022.txt",
            sessionId: sessionId,
            workingDirectory: "/Users/test/new",
            isNewSession: true,
            provider: "copilot",
            systemPrompt: ""
        )

        XCTAssertEqual(message["new_session_id"] as? String, sessionId)
        XCTAssertEqual(message["provider"] as? String, "copilot")
        XCTAssertNil(message["resume_session_id"], "New session must not send resume_session_id")
    }

    // MARK: - promptMessage (system prompt)

    func testPromptMessageIncludesNonEmptySystemPrompt() {
        let message = ShareLogsMessageBuilder.promptMessage(
            actualFilename: "logs-x.txt",
            sessionId: "id",
            workingDirectory: "/tmp",
            isNewSession: false,
            provider: "claude",
            systemPrompt: "You are a helpful reviewer."
        )

        XCTAssertEqual(message["system_prompt"] as? String, "You are a helpful reviewer.")
    }

    func testPromptMessageUsesBackendRenamedFilename() {
        // Backend may rename on conflict; the prompt must use the response's
        // filename, not the originally requested one (AC #9).
        let renamed = "logs-20260531-143022-20260531143025.txt"
        let message = ShareLogsMessageBuilder.promptMessage(
            actualFilename: renamed,
            sessionId: "id",
            workingDirectory: "/tmp",
            isNewSession: false,
            provider: "claude",
            systemPrompt: ""
        )

        XCTAssertTrue((message["text"] as? String)?.contains(renamed) == true)
    }

    // MARK: - isLogUploadResponse filter

    func testIsLogUploadResponseMatchesPendingLogsPrefix() {
        XCTAssertTrue(ShareLogsMessageBuilder.isLogUploadResponse(
            filename: "logs-20260531-143022.txt",
            pendingFilename: "logs-20260531-143022.txt"
        ))
    }

    func testIsLogUploadResponseRejectsWhenNoPending() {
        // No share in flight: a ResourcesManager upload response must be ignored.
        XCTAssertFalse(ShareLogsMessageBuilder.isLogUploadResponse(
            filename: "logs-20260531-143022.txt",
            pendingFilename: nil
        ))
    }

    func testIsLogUploadResponseRejectsNonLogsFilename() {
        // A concurrent resource upload that doesn't use the "logs-" prefix must
        // not steal our handler even while a log share is pending.
        XCTAssertFalse(ShareLogsMessageBuilder.isLogUploadResponse(
            filename: "screenshot.png",
            pendingFilename: "logs-20260531-143022.txt"
        ))
    }

    func testIsLogUploadResponseMatchesBackendRenamedLogsFile() {
        // Conflict-renamed file still starts with "logs-", so it matches.
        XCTAssertTrue(ShareLogsMessageBuilder.isLogUploadResponse(
            filename: "logs-20260531-143022-20260531143025.txt",
            pendingFilename: "logs-20260531-143022.txt"
        ))
    }

    // MARK: - logFilenamePrefix (single source of truth)

    func testLogFilenamePrefixValue() {
        XCTAssertEqual(ShareLogsMessageBuilder.logFilenamePrefix, "logs-")
    }

    func testGeneratedFilenameRecognizedByBothFilters() {
        // A filename built from the shared prefix must be recognized as ours by
        // BOTH the View-side response filter and the ResourcesManager-side guard
        // — this is exactly the drift the shared constant prevents.
        let filename = "\(ShareLogsMessageBuilder.logFilenamePrefix)20260531-143022.txt"
        XCTAssertTrue(ShareLogsMessageBuilder.isLogUploadResponse(filename: filename, pendingFilename: filename))
        XCTAssertTrue(ResourcesManager.isForeignShareLogsResponse(filename: filename, hasExactPendingMatch: false))
    }

    // MARK: - confirmationMessage

    func testConfirmationMessageForSuccess() {
        XCTAssertEqual(ShareLogsMessageBuilder.confirmationMessage(success: true), "Logs shared with agent")
    }

    func testConfirmationMessageForFailure() {
        XCTAssertEqual(ShareLogsMessageBuilder.confirmationMessage(success: false), "Log sharing failed")
    }
}
