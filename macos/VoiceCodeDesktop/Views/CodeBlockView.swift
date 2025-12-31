// CodeBlockView.swift
// Appearance-aware code block display per Appendix AC.3

import SwiftUI

/// Displays code with appearance-aware styling
///
/// This view provides theme-aware code display that automatically adapts
/// to light and dark mode. For MVP, it uses monospaced fonts and semantic
/// background colors. A syntax highlighting library (e.g., Highlightr) can
/// be integrated later for full highlighting support.
struct CodeBlockView: View {
    let code: String
    let language: String?
    @Environment(\.colorScheme) var colorScheme

    /// Theme name for future syntax highlighting integration
    /// Returns appropriate theme based on system appearance
    var themeName: String {
        colorScheme == .dark ? "xcode-dark" : "xcode"
    }

    init(code: String, language: String? = nil) {
        self.code = code
        self.language = language
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            Text(code)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .padding(12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.codeBlockBackground)
        .cornerRadius(8)
    }
}

// MARK: - Inline Code View

/// Displays inline code snippets with subtle styling
struct InlineCodeView: View {
    let code: String
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        Text(code)
            .font(.system(.body, design: .monospaced))
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(Color.codeBlockBackground.opacity(0.7))
            .cornerRadius(4)
    }
}

// MARK: - Previews

#Preview("Code Block - Light") {
    CodeBlockView(
        code: """
        func greet(name: String) -> String {
            return "Hello, \\(name)!"
        }
        """,
        language: "swift"
    )
    .padding()
    .preferredColorScheme(.light)
}

#Preview("Code Block - Dark") {
    CodeBlockView(
        code: """
        func greet(name: String) -> String {
            return "Hello, \\(name)!"
        }
        """,
        language: "swift"
    )
    .padding()
    .preferredColorScheme(.dark)
}

#Preview("Inline Code") {
    VStack(alignment: .leading, spacing: 8) {
        Text("Use the ")
            + Text("InlineCodeView").font(.system(.body, design: .monospaced))
            + Text(" for inline code.")

        HStack {
            Text("Or use:")
            InlineCodeView(code: "let x = 42")
        }
    }
    .padding()
}
