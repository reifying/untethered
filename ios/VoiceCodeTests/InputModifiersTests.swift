// InputModifiersTests.swift
// Unit tests for InputModifiers view extensions

import XCTest
import SwiftUI
@testable import VoiceCode

final class InputModifiersTests: XCTestCase {

    // MARK: - URL Input Configuration Tests

    func testUrlInputConfigurationDoesNotCrash() {
        // Given a text field
        let textField = TextField("URL", text: .constant("https://example.com"))

        // When applying URL input configuration
        let modifiedView = textField.urlInputConfiguration()

        // Then the view should be created successfully (no crash)
        XCTAssertNotNil(modifiedView)
    }

    func testUrlInputConfigurationWithEmptyText() {
        // Given a text field with empty text
        let textField = TextField("URL", text: .constant(""))

        // When applying URL input configuration
        let modifiedView = textField.urlInputConfiguration()

        // Then the view should be created successfully
        XCTAssertNotNil(modifiedView)
    }

    // MARK: - Path Input Configuration Tests

    func testPathInputConfigurationDoesNotCrash() {
        // Given a text field
        let textField = TextField("Path", text: .constant("/Users/test/project"))

        // When applying path input configuration
        let modifiedView = textField.pathInputConfiguration()

        // Then the view should be created successfully
        XCTAssertNotNil(modifiedView)
    }

    func testPathInputConfigurationWithTildePath() {
        // Given a text field with tilde path
        let textField = TextField("Path", text: .constant("~/Documents"))

        // When applying path input configuration
        let modifiedView = textField.pathInputConfiguration()

        // Then the view should be created successfully
        XCTAssertNotNil(modifiedView)
    }

    // MARK: - Numeric Input Configuration Tests

    func testNumericInputConfigurationDoesNotCrash() {
        // Given a text field
        let textField = TextField("Port", text: .constant("8080"))

        // When applying numeric input configuration
        let modifiedView = textField.numericInputConfiguration()

        // Then the view should be created successfully
        XCTAssertNotNil(modifiedView)
    }

    func testNumericInputConfigurationWithEmptyText() {
        // Given a text field with empty text
        let textField = TextField("Port", text: .constant(""))

        // When applying numeric input configuration
        let modifiedView = textField.numericInputConfiguration()

        // Then the view should be created successfully
        XCTAssertNotNil(modifiedView)
    }

    // MARK: - Secret Input Configuration Tests

    func testSecretInputConfigurationDoesNotCrash() {
        // Given a text field
        let textField = TextField("API Key", text: .constant("voice-code-abc123"))

        // When applying secret input configuration
        let modifiedView = textField.secretInputConfiguration()

        // Then the view should be created successfully
        XCTAssertNotNil(modifiedView)
    }

    func testSecretInputConfigurationWithSensitiveData() {
        // Given a text field with sensitive data
        let textField = TextField("Secret", text: .constant("super-secret-value-12345"))

        // When applying secret input configuration
        let modifiedView = textField.secretInputConfiguration()

        // Then the view should be created successfully
        XCTAssertNotNil(modifiedView)
    }

    // MARK: - Text Input Configuration Tests

    func testTextInputConfigurationDoesNotCrash() {
        // Given a text field
        let textField = TextField("Prompt", text: .constant("Hello world"))

        // When applying text input configuration
        let modifiedView = textField.textInputConfiguration()

        // Then the view should be created successfully
        XCTAssertNotNil(modifiedView)
    }

    func testTextInputConfigurationWithMultipleSentences() {
        // Given a text field with multiple sentences
        let textField = TextField("Description", text: .constant("First sentence. Second sentence. Third sentence."))

        // When applying text input configuration
        let modifiedView = textField.textInputConfiguration()

        // Then the view should be created successfully
        XCTAssertNotNil(modifiedView)
    }

    // MARK: - Chaining Tests

    func testChainingMultipleModifiers() {
        // Given a text field
        let textField = TextField("Combined", text: .constant("test"))

        // When chaining with other modifiers
        let modifiedView = textField
            .urlInputConfiguration()
            .frame(width: 200)
            .padding()

        // Then the view should be created successfully
        XCTAssertNotNil(modifiedView)
    }

    // MARK: - Cross-Platform Behavior Tests

    func testModifiersWorkOnCurrentPlatform() {
        // This test verifies that all modifier extensions work on the current platform
        // without throwing or crashing

        let urlField = TextField("URL", text: .constant("")).urlInputConfiguration()
        let pathField = TextField("Path", text: .constant("")).pathInputConfiguration()
        let numericField = TextField("Number", text: .constant("")).numericInputConfiguration()
        let secretField = TextField("Secret", text: .constant("")).secretInputConfiguration()
        let textField = TextField("Text", text: .constant("")).textInputConfiguration()

        // All views should be non-nil
        XCTAssertNotNil(urlField)
        XCTAssertNotNil(pathField)
        XCTAssertNotNil(numericField)
        XCTAssertNotNil(secretField)
        XCTAssertNotNil(textField)
    }
}
