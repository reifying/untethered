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
/// UITextView subclass that reports its full word-wrapped height as intrinsic
/// content size, so SwiftUI ScrollView gives it the room it needs.
///
/// The default UITextView returns an intrinsicContentSize that's computed without
/// knowing the eventual width, so SwiftUI clips the view after only a few lines.
/// Recomputing in layoutSubviews (when bounds.width is known) and forcing a
/// re-invalidation reports the correct full height.
private final class WrappingTextView: UITextView {
    override var intrinsicContentSize: CGSize {
        let width = bounds.width > 0 ? bounds.width : UIScreen.main.bounds.width
        let size = sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: ceil(size.height))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Re-publish intrinsic size now that bounds.width is known.
        invalidateIntrinsicContentSize()
    }
}

struct SelectableTextView_iOS: UIViewRepresentable {
    let text: String
    let isMonospaced: Bool
    let fontSize: CGFloat?
    let textColor: Color?

    func makeUIView(context: Context) -> UITextView {
        let textView = WrappingTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = false
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.textContainer.widthTracksTextView = true
        textView.textContainer.lineBreakMode = .byWordWrapping
        // Allow horizontal narrowing so the view conforms to the SwiftUI ScrollView width.
        // Resist vertical compression and don't hug vertically so the view grows to its
        // full intrinsic height.
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.setContentCompressionResistancePriority(.required, for: .vertical)
        textView.setContentHuggingPriority(.defaultLow, for: .vertical)
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        if textView.text != text {
            textView.text = text
        }
        textView.font = uiFont
        textView.textColor = uiColor
        textView.invalidateIntrinsicContentSize()
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

    func makeNSView(context: Context) -> NSTextView {
        // Bare NSTextView (no NSScrollView wrapper) — the enclosing SwiftUI ScrollView
        // handles scrolling. Wrapping in NSScrollView causes nested-scrolling issues
        // and a fixed intrinsicContentSize that doesn't grow with the message.
        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )
        return textView
    }

    func updateNSView(_ textView: NSTextView, context: Context) {
        if textView.string != text {
            textView.string = text
        }
        textView.font = nsFont
        textView.textColor = nsColor
        textView.invalidateIntrinsicContentSize()
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
