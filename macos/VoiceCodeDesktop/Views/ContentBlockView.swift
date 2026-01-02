// ContentBlockView.swift
// Expandable content block display for tool_use, tool_result, and thinking blocks per Appendix K.7

import SwiftUI
import VoiceCodeShared

/// View for displaying a single content block with expand/collapse functionality
struct ContentBlockView: View {
    let block: ContentBlock
    @State private var isExpanded: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(block: ContentBlock) {
        self.block = block
        // Initialize expansion state based on block type
        _isExpanded = State(initialValue: !block.collapsedByDefault)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Header row with icon, summary, and expand button
            Button(action: {
                if reduceMotion {
                    isExpanded.toggle()
                } else {
                    withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
                }
            }) {
                HStack(spacing: 8) {
                    Image(systemName: block.icon)
                        .foregroundColor(iconColor)
                        .font(.system(size: 14))

                    Text(block.summary)
                        .font(.subheadline)
                        .foregroundColor(.primary)
                        .lineLimit(1)

                    Spacer()

                    if block.collapsedByDefault {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(block.summary), \(isExpanded ? "expanded" : "collapsed")")
            .accessibilityHint(block.collapsedByDefault ? "Double-tap to \(isExpanded ? "collapse" : "expand")" : "")

            // Expanded content
            if isExpanded && block.collapsedByDefault {
                Text(block.fullContent)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
                    .padding(.leading, 22) // Align with text after icon
                    .padding(.vertical, 4)
                    .transition(reduceMotion ? .identity : .opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.vertical, 2)
    }

    private var iconColor: Color {
        switch block.type {
        case .toolUse:
            return .toolUse
        case .toolResult:
            return block.isError == true ? .toolResultError : .toolResultSuccess
        case .thinking:
            return .thinking
        case .text:
            return .primary
        case .unknown:
            return .secondary
        }
    }
}

/// View for displaying all content blocks in a message
struct ContentBlocksView: View {
    let blocks: [ContentBlock]
    var searchText: String = ""

    /// Creates an AttributedString with search matches highlighted
    private func highlightedText(_ text: String) -> AttributedString {
        guard !searchText.isEmpty else {
            return AttributedString(text)
        }

        var attributedString = AttributedString(text)
        let lowercasedText = text.lowercased()
        let lowercasedSearch = searchText.lowercased()

        var searchStartIndex = lowercasedText.startIndex
        while let range = lowercasedText.range(of: lowercasedSearch, range: searchStartIndex..<lowercasedText.endIndex) {
            // Convert String.Index range to AttributedString range
            let startOffset = lowercasedText.distance(from: lowercasedText.startIndex, to: range.lowerBound)
            let endOffset = lowercasedText.distance(from: lowercasedText.startIndex, to: range.upperBound)

            let attrStart = attributedString.index(attributedString.startIndex, offsetByCharacters: startOffset)
            let attrEnd = attributedString.index(attributedString.startIndex, offsetByCharacters: endOffset)

            attributedString[attrStart..<attrEnd].backgroundColor = .yellow.opacity(0.4)
            attributedString[attrStart..<attrEnd].foregroundColor = .primary

            searchStartIndex = range.upperBound
        }

        return attributedString
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(blocks) { block in
                if block.type == .text {
                    // Text blocks are displayed inline without collapse
                    Text(highlightedText(block.text ?? ""))
                        .font(.body)
                        .textSelection(.enabled)
                } else {
                    ContentBlockView(block: block)
                }

                // Add separator between blocks except after the last one
                if block.id != blocks.last?.id {
                    Divider()
                        .padding(.vertical, 2)
                }
            }
        }
    }
}

// MARK: - Previews

#Preview("Tool Use Block") {
    let block = ContentBlock(
        type: .toolUse,
        toolName: "Read",
        toolInput: [
            "file_path": AnyCodable("/Users/test/project/src/main.swift")
        ]
    )

    return ContentBlockView(block: block)
        .padding()
        .frame(width: 400)
}

#Preview("Tool Result Block - Success") {
    let block = ContentBlock(
        type: .toolResult,
        isError: false,
        content: "// main.swift\nimport Foundation\n\nprint(\"Hello, World!\")"
    )

    return ContentBlockView(block: block)
        .padding()
        .frame(width: 400)
}

#Preview("Tool Result Block - Error") {
    let block = ContentBlock(
        type: .toolResult,
        isError: true,
        content: "Error: File not found at path /Users/test/missing.swift"
    )

    return ContentBlockView(block: block)
        .padding()
        .frame(width: 400)
}

#Preview("Thinking Block") {
    let block = ContentBlock(
        type: .thinking,
        thinking: "Let me analyze this code structure. First, I'll look at the imports to understand the dependencies. Then I'll examine the main function to understand the entry point. This appears to be a standard Swift application with Foundation framework usage."
    )

    return ContentBlockView(block: block)
        .padding()
        .frame(width: 400)
}

#Preview("Multiple Blocks") {
    let blocks: [ContentBlock] = [
        ContentBlock(type: .thinking, thinking: "I need to read this file to understand its contents."),
        ContentBlock(type: .toolUse, toolName: "Read", toolInput: ["file_path": AnyCodable("/path/to/file.swift")]),
        ContentBlock(type: .toolResult, isError: false, content: "File contents here..."),
        ContentBlock(type: .text, text: "Based on the file contents, I can see that this is a Swift file that defines a simple data model.")
    ]

    return ContentBlocksView(blocks: blocks)
        .padding()
        .frame(width: 500)
}
