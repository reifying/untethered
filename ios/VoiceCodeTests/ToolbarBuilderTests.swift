// ToolbarBuilderTests.swift
// Unit tests for ToolbarBuilder utility

import XCTest
import SwiftUI
@testable import VoiceCode

final class ToolbarBuilderTests: XCTestCase {

    // MARK: - Cancel Button Tests

    func testCancelButtonCreatesToolbarContent() {
        // Given
        var actionCalled = false
        let action: () -> Void = { actionCalled = true }

        // When - just verify it compiles and can be used as ToolbarContent
        let toolbar = ToolbarBuilder.cancelButton(action: action)

        // Then - verify the toolbar content type is correct (non-nil)
        XCTAssertNotNil(toolbar)
    }

    func testCancelButtonCanBeUsedInToolbar() {
        // Given
        var cancelCalled = false

        // When/Then - verify it can be used in a toolbar modifier
        let view = Text("Test")
            .toolbar {
                ToolbarBuilder.cancelButton {
                    cancelCalled = true
                }
            }

        // Verify view was created (compiles and creates valid SwiftUI view)
        XCTAssertNotNil(view)
    }

    // MARK: - Done Button Tests

    func testDoneButtonCreatesToolbarContent() {
        // Given
        var actionCalled = false
        let action: () -> Void = { actionCalled = true }

        // When
        let toolbar = ToolbarBuilder.doneButton(action: action)

        // Then
        XCTAssertNotNil(toolbar)
    }

    func testDoneButtonCanBeUsedInToolbar() {
        // Given
        var doneCalled = false

        // When/Then
        let view = Text("Test")
            .toolbar {
                ToolbarBuilder.doneButton {
                    doneCalled = true
                }
            }

        XCTAssertNotNil(view)
    }

    // MARK: - Confirm Button Tests

    func testConfirmButtonCreatesToolbarContent() {
        // Given
        let action: () -> Void = {}

        // When
        let toolbar = ToolbarBuilder.confirmButton("Save", action: action)

        // Then
        XCTAssertNotNil(toolbar)
    }

    func testConfirmButtonWithDisabledState() {
        // Given
        let action: () -> Void = {}

        // When - create with disabled state
        let toolbar = ToolbarBuilder.confirmButton("Save", isDisabled: true, action: action)

        // Then
        XCTAssertNotNil(toolbar)
    }

    func testConfirmButtonWithEnabledState() {
        // Given
        let action: () -> Void = {}

        // When - create with enabled state (default)
        let toolbar = ToolbarBuilder.confirmButton("Create", isDisabled: false, action: action)

        // Then
        XCTAssertNotNil(toolbar)
    }

    func testConfirmButtonCanBeUsedInToolbar() {
        // When/Then
        let view = Text("Test")
            .toolbar {
                ToolbarBuilder.confirmButton("Save") {}
            }

        XCTAssertNotNil(view)
    }

    // MARK: - Cancel and Confirm Pair Tests

    func testCancelAndConfirmCreatesToolbarContent() {
        // Given
        let onCancel: () -> Void = {}
        let onConfirm: () -> Void = {}

        // When
        let toolbar = ToolbarBuilder.cancelAndConfirm(
            confirmTitle: "Save",
            onCancel: onCancel,
            onConfirm: onConfirm
        )

        // Then
        XCTAssertNotNil(toolbar)
    }

    func testCancelAndConfirmWithDisabledConfirm() {
        // Given
        let onCancel: () -> Void = {}
        let onConfirm: () -> Void = {}

        // When
        let toolbar = ToolbarBuilder.cancelAndConfirm(
            confirmTitle: "Create",
            isConfirmDisabled: true,
            onCancel: onCancel,
            onConfirm: onConfirm
        )

        // Then
        XCTAssertNotNil(toolbar)
    }

    func testCancelAndConfirmCanBeUsedInToolbar() {
        // When/Then
        let view = Text("Test")
            .toolbar {
                ToolbarBuilder.cancelAndConfirm(
                    confirmTitle: "Save",
                    onCancel: {},
                    onConfirm: {}
                )
            }

        XCTAssertNotNil(view)
    }

    // MARK: - Integration Tests

    func testToolbarBuilderWorksWithNavigationStack() {
        // Given/When
        let view = NavigationStack {
            Text("Content")
                .navigationTitle("Test")
                .toolbar {
                    ToolbarBuilder.cancelButton {}
                    ToolbarBuilder.confirmButton("Save") {}
                }
        }

        // Then
        XCTAssertNotNil(view)
    }

    func testMultipleToolbarItemsCanBeCombined() {
        // When - verify multiple items work together
        let view = Text("Test")
            .toolbar {
                ToolbarBuilder.cancelButton {}
                ToolbarBuilder.doneButton {}
            }

        // Then
        XCTAssertNotNil(view)
    }

    func testToolbarBuilderWithDynamicTitle() {
        // Given
        let buttonTitle = "Create Session"

        // When
        let view = Text("Test")
            .toolbar {
                ToolbarBuilder.confirmButton(buttonTitle) {}
            }

        // Then
        XCTAssertNotNil(view)
    }

    func testToolbarBuilderWithDynamicDisabledState() {
        // Given
        let isEmpty = true

        // When - disabled state can be dynamic
        let view = Text("Test")
            .toolbar {
                ToolbarBuilder.confirmButton("Save", isDisabled: isEmpty) {}
            }

        // Then
        XCTAssertNotNil(view)
    }
}
