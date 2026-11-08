// LinkDetector.swift
// Finds web links in message text so the transcript can make them tappable.

import Foundation

enum LinkDetector {
    struct Link: Equatable {
        /// UTF-16 range in the source string, as NSAttributedString uses.
        let range: NSRange
        let url: URL
    }

    private static let detector: NSDataDetector? = {
        do {
            return try NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        } catch {
            LogManager.shared.log("LinkDetector: could not create NSDataDetector: \(error.localizedDescription)", category: "LinkDetector")
            return nil
        }
    }()

    /// Web links written out as links: an `http://` / `https://` URL, or an
    /// address starting `www.`.
    ///
    /// NSDataDetector on its own also turns anything shaped like a domain into
    /// a link, and agent replies are full of those — `README.md`, `main.rs`,
    /// `server.py`, `notes.sh` are all valid domains. Requiring the scheme or
    /// `www.` in the text keeps file names plain.
    static func links(in text: String) -> [Link] {
        // Most messages contain no link at all; skip the detector for them.
        guard let detector = detector,
              text.range(of: "http", options: .caseInsensitive) != nil
                || text.range(of: "www.", options: .caseInsensitive) != nil
        else { return [] }

        let source = text as NSString
        let matches = detector.matches(in: text, options: [], range: NSRange(location: 0, length: source.length))
        return matches.compactMap { match in
            guard let url = match.url,
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else { return nil }
            let written = source.substring(with: match.range).lowercased()
            guard written.hasPrefix("http://") || written.hasPrefix("https://") || written.hasPrefix("www.") else {
                return nil
            }
            return Link(range: match.range, url: url)
        }
    }

    /// `text` with a `.link` attribute on every link, on top of `attributes`
    /// applied to the whole string. UITextView and NSTextView make `.link`
    /// runs tappable when the view is selectable and not editable.
    static func attributedText(_ text: String, attributes: [NSAttributedString.Key: Any] = [:]) -> NSAttributedString {
        let result = NSMutableAttributedString(string: text, attributes: attributes)
        for link in links(in: text) {
            result.addAttribute(.link, value: link.url, range: link.range)
        }
        return result
    }

    /// `text` as an AttributedString whose links SwiftUI `Text` renders as
    /// tappable (opened through the `openURL` environment action).
    static func attributedString(_ text: String) -> AttributedString {
        AttributedString(attributedText(text))
    }
}
