import Foundation

/// A timed chunk of speech. Words carry their own timings when whisper
/// produced them (needed for karaoke captions and voiceover slotting).
struct Word {
    var text: String
    var start: Double
    var end: Double
}

struct Segment {
    var text: String
    var start: Double
    var end: Double
    var words: [Word]
}

struct Transcript {
    var segments: [Segment]
    var language: String?

    var isEmpty: Bool { segments.isEmpty }
    var plainText: String {
        segments.map { $0.text.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
    }
}

/// Runs whisper.cpp and parses its full JSON (segments + token timings).
enum Whisper {
    /// - Parameter wav: 16 kHz mono PCM.
    static func transcribe(wav: URL, model: URL, language: String, workDir: URL) throws -> Transcript {
        let base = workDir.appendingPathComponent("whisper-out")
        try Shell.runChecked("whisper-cli", [
            "-m", model.path,
            "-f", wav.path,
            "-l", language,
            "-oj", "-ojf",          // JSON with per-token timings
            "-of", base.path,
        ])
        let jsonURL = URL(fileURLWithPath: base.path + ".json")
        defer { try? FileManager.default.removeItem(at: jsonURL) }
        let data = try Data(contentsOf: jsonURL)
        return try parse(data)
    }

    static func parse(_ data: Data) throws -> Transcript {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["transcription"] as? [[String: Any]]
        else { throw APIError(500, "unreadable whisper output") }

        let language = (root["result"] as? [String: Any])?["language"] as? String
        var segments: [Segment] = []
        for item in items {
            guard let offsets = item["offsets"] as? [String: Any],
                  let from = (offsets["from"] as? NSNumber)?.doubleValue,
                  let to = (offsets["to"] as? NSNumber)?.doubleValue
            else { continue }
            let text = (item["text"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }

            var words: [Word] = []
            if let tokens = item["tokens"] as? [[String: Any]] {
                for tok in tokens {
                    guard let t = tok["text"] as? String,
                          !t.hasPrefix("[") , !t.hasPrefix("<"),   // skip specials
                          let o = tok["offsets"] as? [String: Any],
                          let ws = (o["from"] as? NSNumber)?.doubleValue,
                          let we = (o["to"] as? NSNumber)?.doubleValue
                    else { continue }
                    // whisper emits sub-word tokens; merge continuations
                    // (a new word starts with a leading space).
                    if t.hasPrefix(" ") || words.isEmpty {
                        words.append(Word(text: t.trimmingCharacters(in: .whitespaces),
                                          start: ws / 1000, end: we / 1000))
                    } else {
                        words[words.count - 1].text += t
                        words[words.count - 1].end = we / 1000
                    }
                }
                words.removeAll { $0.text.isEmpty }
            }
            segments.append(Segment(text: text, start: from / 1000, end: to / 1000, words: words))
        }
        return Transcript(segments: segments, language: language)
    }

    /// Whisper hallucinates florid nonsense on silence; a track this quiet has
    /// no usable speech in it.
    static func looksLikeSilenceArtifact(_ t: Transcript) -> Bool {
        guard !t.isEmpty else { return true }
        let text = t.plainText
        guard !text.isEmpty else { return true }
        // A single character repeated forever is the classic silence output.
        let unique = Set(text.replacingOccurrences(of: " ", with: ""))
        return unique.count <= 3 && text.count > 20
    }
}
