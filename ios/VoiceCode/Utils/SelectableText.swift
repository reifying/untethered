// SelectableText.swift
// A cross-platform text view with reliable native text selection.
// Replaces Text + .textSelection(.enabled) which is unreliable inside ScrollView.

import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct SelectableText: View {
    let text: String
    var isMonospaced: Bool = false
    var fontSize: CGFloat? = nil
    var textColor: Color? = nil

    var body: some View {
        #if os(iOS)
        SelectableTextView_iOS(
            text: text,
            isMonospaced: isMonospaced,
            fontSize: fontSize,
            textColor: textColor
        )
        #elseif os(macOS)
        SelectableTextView_macOS(
            text: text,
            isMonospaced: isMonospaced,
            fontSize: fontSize,
            textColor: textColor
        )
        #endif
    }
}

#if os(iOS)
struct SelectableTextView_iOS: UIViewRepresentable {
    let text: String
    let isMonospaced: Bool
    let fontSize: CGFloat?
    let textColor: Color?

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = false
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.setContentHuggingPriority(.defaultHigh, for: .vertical)
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        textView.text = text
        textView.font = uiFont
        textView.textColor = uiColor
    }

    private var uiFont: UIFont {
        let size = fontSize ?? UIFont.preferredFont(forTextStyle: .body).pointSize
        if isMonospaced {
            return UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
        } else {
            return UIFont.systemFont(ofSize: size)
        }
    }

    private var uiColor: UIColor {
        if let color = textColor {
            return UIColor(color)
        }
        return .label
    }
}
#endif

#if os(macOS)
struct SelectableTextView_macOS: NSViewRepresentable {
    let text: String
    let isMonospaced: Bool
    let fontSize: CGFloat?
    let textColor: Color?

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else {
            return scrollView
        }

        textView.isEditable = false
        textView.isSelectable = true
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0

        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        textView.string = text
        textView.font = nsFont
        textView.textColor = nsColor
    }

    private var nsFont: NSFont {
        let size = fontSize ?? NSFont.systemFontSize
        if isMonospaced {
            return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        } else {
            return NSFont.systemFont(ofSize: size)
        }
    }

    private var nsColor: NSColor {
        if let color = textColor {
            return NSColor(color)
        }
        return .labelColor
    }
}
#endif
