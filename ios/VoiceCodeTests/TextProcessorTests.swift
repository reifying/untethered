// TextProcessorTests.swift
// Tests for text processing utilities

import XCTest
#if os(iOS)
@testable import VoiceCode
#else
@testable import VoiceCode
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
    
    // MARK: - CamelCase Splitting Tests

    func testSplitsSimplePascalCase() {
        XCTAssertEqual(TextProcessor.splitCamelCase(in: "FooBar"), "Foo Bar")
    }

    func testSplitsCamelCase() {
        XCTAssertEqual(TextProcessor.splitCamelCase(in: "fooBar"), "foo Bar")
    }

    func testSplitsAcronymFollowedByWord() {
        XCTAssertEqual(TextProcessor.splitCamelCase(in: "XMLHttpRequest"), "XML Http Request")
    }

    func testSplitsJavaStyleClassName() {
        XCTAssertEqual(TextProcessor.splitCamelCase(in: "NullPointerException"),
                       "Null Pointer Exception")
    }

    func testSplitsShortAcronymPrefix() {
        XCTAssertEqual(TextProcessor.splitCamelCase(in: "NSObject"), "NS Object")
        XCTAssertEqual(TextProcessor.splitCamelCase(in: "IOException"), "IO Exception")
    }

    func testLeavesNonCamelWordsAlone() {
        XCTAssertEqual(TextProcessor.splitCamelCase(in: "hello world"), "hello world")
        XCTAssertEqual(TextProcessor.splitCamelCase(in: "ALLCAPS"), "ALLCAPS")
        XCTAssertEqual(TextProcessor.splitCamelCase(in: "lowercase"), "lowercase")
    }

    func testSplitsCamelCaseInsideSentence() {
        XCTAssertEqual(
            TextProcessor.splitCamelCase(in: "Call FooBar.doWork() before HTTPClient."),
            "Call Foo Bar.do Work() before HTTP Client."
        )
    }

    // MARK: - prepareForSpeech

    func testPrepareForSpeechRemovesCodeAndSplitsCamelCase() {
        let input = "The `HTTPClient` calls `FooBar.doWork()` now."
        let expected = "The HTTP Client calls Foo Bar.do Work() now."
        XCTAssertEqual(TextProcessor.prepareForSpeech(from: input), expected)
    }

    func testPrepareForSpeechHandlesFencedBlocksAndCamelCase() {
        let input = """
        Use MyClass like this:
        ```swift
        let x = MyClass()
        ```
        Done.
        """
        let expected = """
        Use My Class like this:
        [code block]
        Done.
        """
        XCTAssertEqual(TextProcessor.prepareForSpeech(from: input), expected)
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

    // MARK: - Tool announcements
    //
    // The backend folds tool_use / tool_result blocks into the message's
    // display text as bracketed markers (providers.clj `summarize-tool-use`),
    // and that same text drives both the transcript and TTS. These cover the
    // speech-side filter; the transcript keeps the markers.

    func testRemovesStandaloneToolUseMarker() {
        let input = "Let me read that file.\n\n[Tool: Read file_path=/tmp/test.txt]"
        XCTAssertEqual(TextProcessor.removeToolAnnouncements(from: input), "Let me read that file.")
    }

    func testToolOnlyMessageBecomesEmpty() {
        let input = "[Tool: Read file_path=/tmp/test.txt]"
        XCTAssertEqual(TextProcessor.removeToolAnnouncements(from: input), "")
    }

    func testRemovesToolMarkersInterleavedWithProse() {
        let input = """
        First I'll look.

        [Tool: Grep pattern=needle]

        Then I'll fix it.

        [Tool: Edit file_path=/tmp/a.swift]

        Done.
        """
        let expected = """
        First I'll look.

        Then I'll fix it.

        Done.
        """
        XCTAssertEqual(TextProcessor.removeToolAnnouncements(from: input), expected)
    }

    /// Copilot joins consecutive tool summaries with a single newline
    /// (providers.clj `parse-message :copilot`), so the filter must handle
    /// markers that are adjacent lines, not just separate paragraphs.
    func testRemovesNewlineJoinedToolMarkers() {
        let input = "Searching.\n\n[Tool: rg pattern=test]\n[Tool: glob pattern=**/*.clj]"
        XCTAssertEqual(TextProcessor.removeToolAnnouncements(from: input), "Searching.")
    }

    /// A parameter value can contain "]" — a Grep pattern especially. Matching
    /// to the first "]" would leave the tail behind to be spoken.
    func testRemovesToolMarkerWhoseParamsContainBrackets() {
        let input = "Looking.\n\n[Tool: Grep pattern=[0-9]+ items]"
        XCTAssertEqual(TextProcessor.removeToolAnnouncements(from: input), "Looking.")
    }

    /// Bash commands are truncated at 50 characters, which can land mid-way
    /// through a multi-line command and leave newlines inside the marker.
    func testRemovesToolMarkerSpanningNewlines() {
        let input = "Running it.\n\n[Tool: Bash command=echo one\necho two\necho thre...]"
        XCTAssertEqual(TextProcessor.removeToolAnnouncements(from: input), "Running it.")
    }

    func testTruncatesAtToolResultMarker() {
        let input = "Here's what came back.\n\n[Tool Result]\nline one\nline two\n\nline three"
        XCTAssertEqual(TextProcessor.removeToolAnnouncements(from: input), "Here's what came back.")
    }

    func testToolResultOnlyMessageBecomesEmpty() {
        let input = "[Tool Result]\nsome captured output"
        XCTAssertEqual(TextProcessor.removeToolAnnouncements(from: input), "")
    }

    /// Thinking is signal for a listener and must survive the filter.
    func testKeepsThinkingMarker() {
        let input = "[Thinking: I should check the config first...]\n\n[Tool: Read file_path=/tmp/c.json]"
        XCTAssertEqual(
            TextProcessor.removeToolAnnouncements(from: input),
            "[Thinking: I should check the config first...]"
        )
    }

    func testLeavesProseWithoutToolMarkersUntouched() {
        let input = "Just a normal reply with a [bracketed] aside."
        XCTAssertEqual(TextProcessor.removeToolAnnouncements(from: input), input)
    }

    // MARK: - prepareForSpeech + tool announcements

    func testPrepareForSpeechDropsToolCallsAndKeepsThinking() {
        let input = """
        [Thinking: Need to look at the parser...]

        I'll check the parser now.

        [Tool: Read file_path=/tmp/Parser.swift]
        """
        let expected = """
        [Thinking: Need to look at the parser...]

        I'll check the parser now.
        """
        XCTAssertEqual(TextProcessor.prepareForSpeech(from: input), expected)
    }

    /// The whole point of the empty result: callers must be able to tell that a
    /// tool-only message has nothing to say, so no utterance is produced.
    func testPrepareForSpeechYieldsEmptyForToolOnlyMessage() {
        let input = "[Tool: Bash command=make test]\n\n[Tool: Read file_path=/tmp/log.txt]"
        XCTAssertTrue(TextProcessor.prepareForSpeech(from: input).isEmpty)
    }

    /// Tool stripping has to run before CamelCase splitting, or "[Tool: WebFetch]"
    /// would already have been rewritten to "[Tool: Web Fetch]".
    func testPrepareForSpeechStripsToolMarkerBeforeCamelCaseSplit() {
        let input = "Fetching.\n\n[Tool: WebFetch url=https://example.com]"
        XCTAssertEqual(TextProcessor.prepareForSpeech(from: input), "Fetching.")
    }
}
