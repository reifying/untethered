// TextProcessorTests.swift
// Tests for text processing utilities

import XCTest
#if os(iOS)
@testable import VoiceCode
#else
@testable import VoiceCodeMac
#endif

final class TextProcessorTests: XCTestCase {
    
    // MARK: - Fenced Code Block Tests
    
    func testRemovesFencedCodeBlock() {
        let input = """
        Here's some code:
        ```swift
        let x = 5
        print(x)
        ```
        That's the code.
        """
        
        let expected = """
        Here's some code:
        [code block]
        That's the code.
        """
        
        let result = TextProcessor.removeCodeBlocks(from: input)
        XCTAssertEqual(result, expected)
    }
    
    func testRemovesMultipleFencedCodeBlocks() {
        let input = """
        First example:
        ```python
        def hello():
            print("hello")
        ```
        
        Second example:
        ```javascript
        console.log("hello");
        ```
        
        Done.
        """
        
        let expected = """
        First example:
        [code block]

        Second example:
        [code block]

        Done.
        """
        
        let result = TextProcessor.removeCodeBlocks(from: input)
        XCTAssertEqual(result, expected)
    }
    
    func testRemovesFencedCodeBlockWithoutLanguage() {
        let input = """
        Code:
        ```
        some code
        more code
        ```
        End.
        """
        
        let expected = """
        Code:
        [code block]
        End.
        """
        
        let result = TextProcessor.removeCodeBlocks(from: input)
        XCTAssertEqual(result, expected)
    }
    
    func testRemovesFencedCodeBlockWithSpecialCharacters() {
        let input = """
        Here's a regex:
        ```regex
        ^[a-z]+\\.txt$
        (?:foo|bar)
        ```
        Complex pattern.
        """
        
        let expected = """
        Here's a regex:
        [code block]
        Complex pattern.
        """
        
        let result = TextProcessor.removeCodeBlocks(from: input)
        XCTAssertEqual(result, expected)
    }
    
    // MARK: - Inline Code Tests
    
    func testRemovesInlineCodeBackticks() {
        let input = "Use the `print()` function to output text."
        let expected = "Use the print() function to output text."
        
        let result = TextProcessor.removeCodeBlocks(from: input)
        XCTAssertEqual(result, expected)
    }
    
    func testRemovesMultipleInlineCodes() {
        let input = "Call `foo()` then `bar()` and finally `baz()`."
        let expected = "Call foo() then bar() and finally baz()."
        
        let result = TextProcessor.removeCodeBlocks(from: input)
        XCTAssertEqual(result, expected)
    }
    
    func testPreservesInlineCodeContent() {
        let input = "The variable `userName` stores the name."
        let expected = "The variable userName stores the name."
        
        let result = TextProcessor.removeCodeBlocks(from: input)
        XCTAssertEqual(result, expected)
    }
    
    func testHandlesInlineCodeWithSpecialCharacters() {
        let input = "Use `console.log()` or `System.out.println()`."
        let expected = "Use console.log() or System.out.println()."
        
        let result = TextProcessor.removeCodeBlocks(from: input)
        XCTAssertEqual(result, expected)
    }
    
    // MARK: - Mixed Content Tests
    
    func testHandlesMixedInlineAndFencedCode() {
        let input = """
        Call the `initialize()` function like this:
        ```swift
        let app = App()
        app.initialize()
        ```
        Then use `app.run()` to start.
        """
        
        let expected = """
        Call the initialize() function like this:
        [code block]
        Then use app.run() to start.
        """
        
        let result = TextProcessor.removeCodeBlocks(from: input)
        XCTAssertEqual(result, expected)
    }
    
    func testRealClaudeCodeResponse() {
        let input = """
        I'll help you implement that feature. Here's the code:
        
        ```swift
        func processData(_ input: String) -> [String] {
            return input.components(separatedBy: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        ```
        
        This function takes a `String` parameter and returns an array. You can call it with `processData("a, b, c")`.
        """
        
        let expected = """
        I'll help you implement that feature. Here's the code:

        [code block]

        This function takes a String parameter and returns an array. You can call it with processData("a, b, c").
        """
        
        let result = TextProcessor.removeCodeBlocks(from: input)
        XCTAssertEqual(result, expected)
    }
    
    // MARK: - Edge Cases
    
    func testEmptyString() {
        let result = TextProcessor.removeCodeBlocks(from: "")
        XCTAssertEqual(result, "")
    }
    
    func testStringWithNoCode() {
        let input = "This is just plain text with no code at all."
        let result = TextProcessor.removeCodeBlocks(from: input)
        XCTAssertEqual(result, input)
    }
    
    func testStringWithOnlyCodeBlock() {
        let input = """
        ```python
        print("hello")
        ```
        """
        
        let result = TextProcessor.removeCodeBlocks(from: input)
        XCTAssertEqual(result, "[code block]")
    }
    
    func testStringWithOnlyInlineCode() {
        let input = "`code`"
        let result = TextProcessor.removeCodeBlocks(from: input)
        XCTAssertEqual(result, "code")
    }
    
    func testCleansUpExtraNewlines() {
        let input = """
        Text
        
        ```code
        foo
        ```
        
        
        
        More text
        """
        
        let expected = """
        Text

        [code block]

        More text
        """
        
        let result = TextProcessor.removeCodeBlocks(from: input)
        XCTAssertEqual(result, expected)
    }
    
    func testTrimsWhitespace() {
        let input = "  \n  Some text  \n  "
        let result = TextProcessor.removeCodeBlocks(from: input)
        XCTAssertEqual(result, "Some text")
    }
    
    // MARK: - Backtick Edge Cases
    
    func testDoesNotRemoveInlineCodeAcrossNewlines() {
        // Inline code pattern shouldn't match across newlines
        let input = """
        This is `code
        on multiple lines`
        """
        
        // Should not match because inline code pattern excludes newlines
        let result = TextProcessor.removeCodeBlocks(from: input)
        XCTAssertEqual(result, input.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    
    func testNestedBackticksInFencedBlock() {
        let input = """
        Example:
        ```
        Use `variable` here
        ```
        Done.
        """
        
        let expected = """
        Example:
        [code block]
        Done.
        """
        
        let result = TextProcessor.removeCodeBlocks(from: input)
        XCTAssertEqual(result, expected)
    }
}
