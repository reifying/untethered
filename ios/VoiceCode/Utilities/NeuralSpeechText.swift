// NeuralSpeechText.swift
// Text preparation and audio packaging for the neural (Kokoro) voice.
// Design: docs/design/kokoro-neural-voice.md

import Foundation

/// The Settings choice between the neural voice and Apple's, stored in `UserDefaults`.
enum NeuralVoiceSettings {
    static let engineKey = "speechVoiceEngine"
    static let kokoro = "kokoro"
    static let apple = "apple"

    /// Kokoro unless Apple was chosen. Kokoro is the default on the iPhone and the Mac.
    static func isKokoroSelected(_ defaults: UserDefaults = .standard) -> Bool {
        (defaults.string(forKey: engineKey) ?? kokoro) == kokoro
    }
}

/// When the neural voice may read, given where the app is.
///
/// iOS 27 needs an entitlement for Neural Engine work from a background app, so a read that
/// fails there makes the engine stand down until the app is active again. The Mac has no such
/// limit, and it reads most replies with another app in front (driving mode, or simply working
/// in another window), so there the app not being active never holds the neural voice back.
enum NeuralVoiceAvailability {
    static var backgroundSynthesisIsRestricted: Bool {
        #if os(iOS)
        return true
        #else
        return false
        #endif
    }

    /// Whether the neural engine reads the next utterance.
    static func isReadyToSpeak(modelLoaded: Bool, selected: Bool, failedInBackground: Bool, appIsActive: Bool,
                               backgroundRestricted: Bool = backgroundSynthesisIsRestricted) -> Bool {
        guard modelLoaded, selected else { return false }
        if backgroundRestricted, failedInBackground, !appIsActive { return false }
        return true
    }

    /// Whether a failed read means "stop trying until the app is active again".
    static func shouldStandDownAfterFailure(appIsActive: Bool,
                                            backgroundRestricted: Bool = backgroundSynthesisIsRestricted) -> Bool {
        backgroundRestricted && !appIsActive
    }
}

/// Wording of the Voice Engine section in Settings that differs between the iPhone and the Mac.
enum NeuralVoiceSettingsText {
    static var deviceName: String {
        #if os(macOS)
        return "Mac"
        #else
        return "iPhone"
        #endif
    }

    static func kokoroFooter(device: String = deviceName) -> String {
        "Kokoro is a neural voice that runs on this \(device). Its model downloads once, over Wi-Fi. "
            + "Until it is ready, and whenever it can't speak, the Apple voice below reads instead."
    }
}

/// One piece of a reply, synthesized in one pass, followed by `pauseAfter` of silence.
struct NeuralSpeechChunk: Equatable {
    let text: String
    let pauseAfter: TimeInterval
}

enum NeuralSpeechText {
    /// Silence after a line or paragraph, as in the listening-test render of voice E.
    static let pauseAfterLine: TimeInterval = 0.3
    /// Silence where a long line was split at a sentence end.
    static let pauseAfterSentence: TimeInterval = 0.12
    /// Longest chunk, in characters, before a line is split at sentence ends.
    static let maxChunkLength = 380

    /// Markdown a listener should not hear, removed the way the listening-test texts were:
    /// link URLs (the link text stays), `**`/`__`, single `*` emphasis, heading marks and
    /// bullet markers. A bare URL is read as its host. Runs after `TextProcessor`, which
    /// has already removed code blocks and inline-code backticks.
    static func cleanMarkdown(_ text: String) -> String {
        var t = text
        t = replace(#"\[([^\]]+)\]\([^)]+\)"#, in: t, with: "$1")
        t = replaceURLsWithHosts(t)
        t = replace(#"\*\*|__"#, in: t, with: "")
        t = replace(#"(?m)^[ \t]*#+[ \t]*"#, in: t, with: "")
        t = replace(#"(?m)^[ \t]*[-*•][ \t]+"#, in: t, with: "")
        t = replace(#"(?<![\w*])\*(?=\S)([^*\n]+?)(?<=\S)\*(?![\w*])"#, in: t, with: "$1")
        return t
    }

    /// Split cleaned text into synthesis chunks: one per line, long lines at sentence ends
    /// up to `maxLength` characters. The very first sentence is a chunk of its own, so the
    /// first audio is ready sooner.
    static func chunks(_ text: String, maxLength: Int = maxChunkLength) -> [NeuralSpeechChunk] {
        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            // A line with nothing to pronounce (a rule, a lone dash) has no phonemes.
            .filter { $0.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) } }
        var result: [NeuralSpeechChunk] = []
        for line in lines {
            var sentences = splitSentences(line)
            var pieces: [String] = []
            if result.isEmpty, sentences.count > 1 {
                pieces.append(sentences.removeFirst())
            }
            var current = ""
            for sentence in sentences {
                if !current.isEmpty, current.count + 1 + sentence.count > maxLength {
                    pieces.append(current)
                    current = sentence
                } else {
                    current = current.isEmpty ? sentence : current + " " + sentence
                }
            }
            if !current.isEmpty { pieces.append(current) }
            for (index, piece) in pieces.enumerated() {
                let last = index == pieces.count - 1
                result.append(NeuralSpeechChunk(text: piece, pauseAfter: last ? pauseAfterLine : pauseAfterSentence))
            }
        }
        return result
    }

    /// Abbreviations whose period does not end a sentence.
    private static let abbreviations: Set<String> = ["e.g.", "i.e.", "etc.", "vs.", "mr.", "mrs.", "ms.", "dr.", "st.", "approx.", "no."]

    /// Split at `.`, `!`, `?`, `;` or `:` followed by whitespace, as the reference render did.
    static func splitSentences(_ line: String) -> [String] {
        var sentences: [String] = []
        var current = ""
        let chars = Array(line)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            current.append(c)
            let atBoundary = ".!?;:".contains(c) && i + 1 < chars.count && chars[i + 1].isWhitespace
            if atBoundary {
                let lastWord = current.split(separator: " ").last.map { String($0).lowercased() } ?? ""
                if !(c == "." && abbreviations.contains(lastWord)) {
                    sentences.append(current.trimmingCharacters(in: .whitespaces))
                    current = ""
                }
            }
            i += 1
        }
        let tail = current.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { sentences.append(tail) }
        return sentences
    }

    /// Kokoro's speed for an AVSpeech rate: the app's default rate (0.5) is speed 1.0.
    static func speed(forRate rate: Float) -> Float {
        let base: Float = 0.5
        return min(2.0, max(0.5, rate / base))
    }

    private static func replace(_ pattern: String, in text: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }

    private static func replaceURLsWithHosts(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"https?://[^\s<>()\]]+"#) else { return text }
        var result = text
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            let urlString = String(result[range]).trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?"))
            var host = URL(string: urlString)?.host ?? "a link"
            if host.hasPrefix("www.") { host.removeFirst(4) }
            let trailing = String(result[range].dropFirst(urlString.count))
            result.replaceSubrange(range, with: host + trailing)
        }
        return result
    }
}

/// 16-bit mono WAV for `AVAudioPlayer`, with loudness matched to Apple's voice.
enum NeuralSpeechAudio {
    /// Kokoro reads about 7 LU quieter than Apple's Premium voices (−25.4 against −18.0 LUFS
    /// on the same reply), so switching between them would jump in volume. This gain brings it
    /// to about the same loudness; `softLimit` keeps the boosted peaks out of clipping.
    static let gain: Float = 2.2

    static func wav(samples: [Float], sampleRate: Int, trailingSilence: TimeInterval, gain: Float = gain) -> Data {
        let silence = Int(Double(sampleRate) * max(0, trailingSilence))
        let count = samples.count + silence
        var data = Data(capacity: 44 + count * 2)
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + count * 2))
        data.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16); u16(1); u16(1)
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        data.append(contentsOf: Array("data".utf8)); u32(UInt32(count * 2))
        var pcm = [Int16](repeating: 0, count: count)
        for (i, s) in samples.enumerated() {
            pcm[i] = Int16(softLimit(s * gain) * 32767)
        }
        // Apple platforms are little-endian, as WAV is.
        pcm.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }

    /// Unchanged below 0.7; above it, bends smoothly toward ±1 so peaks never clip.
    static func softLimit(_ x: Float) -> Float {
        let threshold: Float = 0.7
        let magnitude = abs(x)
        guard magnitude > threshold else { return x.isFinite ? x : 0 }
        let bent = threshold + (1 - threshold) * Float(tanh(Double((magnitude - threshold) / (1 - threshold))))
        return x < 0 ? -bent : bent
    }
}
