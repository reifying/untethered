// SessionSidebarWorktreeTests.swift
// The Mac sidebar's New Session sheet offers "Create worktree". It used to ignore
// the switch and make a plain session in the parent folder.

#if os(macOS)
import XCTest
@testable import VoiceCode

final class SessionSidebarWorktreeTests: XCTestCase {

    func testWorktreeRequestNamesTheSessionAndTheParentFolder() {
        let message = SessionSidebarView.worktreeSessionMessage(name: "fix-login", parentDirectory: "/Users/me/code/app")
        XCTAssertEqual(message?["type"] as? String, "create_worktree_session")
        XCTAssertEqual(message?["session_name"] as? String, "fix-login")
        XCTAssertEqual(message?["parent_directory"] as? String, "/Users/me/code/app")
    }

    func testNoWorktreeRequestWithoutANameOrAFolder() {
        XCTAssertNil(SessionSidebarView.worktreeSessionMessage(name: "", parentDirectory: "/tmp"))
        XCTAssertNil(SessionSidebarView.worktreeSessionMessage(name: "x", parentDirectory: ""))
    }
}
#endif
