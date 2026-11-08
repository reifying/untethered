// LinkDetectorTests.swift
// Which parts of a message become tappable links.

import XCTest
import SwiftUI
@testable import VoiceCode

final class LinkDetectorTests: XCTestCase {

    private func urls(in text: String) -> [String] {
        LinkDetector.links(in: text).map(\.url.absoluteString)
    }

    private func linkedSubstrings(in text: String) -> [String] {
        LinkDetector.links(in: text).map { (text as NSString).substring(with: $0.range) }
    }

    // MARK: - What is a link

    func testHttpsURLIsALink() {
        XCTAssertEqual(urls(in: "PR is up: https://github.com/reifying/untethered/pull/42"),
                       ["https://github.com/reifying/untethered/pull/42"])
    }

    func testHttpURLIsALink() {
        XCTAssertEqual(urls(in: "Backend at http://localhost:8080/health is up"),
                       ["http://localhost:8080/health"])
    }

    func testWwwAddressIsALinkOpenedOverHttp() {
        let found = urls(in: "See www.example.com for details")
        XCTAssertEqual(found.count, 1)
        XCTAssertTrue(found[0].hasSuffix("www.example.com"), "got \(found)")
        XCTAssertTrue(found[0].hasPrefix("http"), "got \(found)")
    }

    func testSeveralLinksInOneMessage() {
        let text = "Compare https://a.example.com/x with https://b.example.com/y."
        XCTAssertEqual(urls(in: text), ["https://a.example.com/x", "https://b.example.com/y"])
    }

    // MARK: - Boundaries

    func testTrailingSentencePunctuationIsNotPartOfTheLink() {
        XCTAssertEqual(linkedSubstrings(in: "Docs are at https://example.com/docs."),
                       ["https://example.com/docs"])
    }

    func testParenthesisedLinkStopsAtTheParenthesis() {
        XCTAssertEqual(linkedSubstrings(in: "the dashboard (https://example.com/dash) shows it"),
                       ["https://example.com/dash"])
    }

    func testMarkdownLinkTargetIsTappable() {
        XCTAssertEqual(urls(in: "Read [the design](https://example.com/design.md) first"),
                       ["https://example.com/design.md"])
    }

    func testRangesAreUTF16ForTextWithEmoji() {
        let text = "🔊 Listen: https://example.com/a 👍"
        let links = LinkDetector.links(in: text)
        XCTAssertEqual(links.count, 1)
        XCTAssertEqual((text as NSString).substring(with: links[0].range), "https://example.com/a")
    }

    // MARK: - What is not a link

    /// File names are valid domains (.md, .rs, .py, .sh are all TLDs); agent
    /// replies are full of them and they must stay plain text.
    func testFileNamesAreNotLinks() {
        XCTAssertEqual(urls(in: "Edited README.md, main.rs, server.py and deploy.sh"), [])
    }

    func testBareDomainWithoutSchemeIsNotALink() {
        XCTAssertEqual(urls(in: "hosted on example.com today"), [])
    }

    func testNonWebSchemesAreNotLinks() {
        XCTAssertEqual(urls(in: "ssh://host/repo and ftp://files.example.com/x"), [])
    }

    func testPlainTextHasNoLinks() {
        XCTAssertEqual(urls(in: "Nothing to see here."), [])
        XCTAssertEqual(urls(in: ""), [])
    }

    // MARK: - Attributed output

    func testAttributedTextCarriesLinkAttributeOnlyOnTheLink() {
        let text = "Open https://example.com/a now"
        let attributed = LinkDetector.attributedText(text, attributes: [.kern: 1.0])
        XCTAssertEqual(attributed.string, text, "text is unchanged")

        var linkRuns: [(String, URL)] = []
        attributed.enumerateAttribute(.link, in: NSRange(location: 0, length: attributed.length)) { value, range, _ in
            if let url = value as? URL {
                linkRuns.append(((text as NSString).substring(with: range), url))
            }
        }
        XCTAssertEqual(linkRuns.map(\.0), ["https://example.com/a"])
        XCTAssertNotNil(attributed.attribute(.kern, at: 0, effectiveRange: nil),
                        "base attributes still apply to the whole string")
    }

    func testSwiftUIAttributedStringHasALinkRun() {
        let attributed = LinkDetector.attributedString("go to https://example.com/x please")
        let links = attributed.runs.compactMap(\.link)
        XCTAssertEqual(links, [URL(string: "https://example.com/x")!])
        XCTAssertEqual(String(attributed.characters), "go to https://example.com/x please")
    }

    func testSwiftUIAttributedStringWithoutLinksIsPlain() {
        let attributed = LinkDetector.attributedString("plain README.md text")
        XCTAssertTrue(attributed.runs.allSatisfy { $0.link == nil })
    }
}
