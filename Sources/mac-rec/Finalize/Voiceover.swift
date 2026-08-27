import Foundation

/// Replaces recorded narration with an ElevenLabs voice while keeping picture
/// sync.
///
/// Each transcript sentence is spoken separately and dropped back onto the
/// timeline at its own start time. If a take runs long for its slot it is
/// gently sped up (never beyond `maxTempo`); if it still overruns, the next
/// sentence starts late rather than overlapping. Captions are then rebuilt
/// from where the audio *actually* landed, so what is read always matches
/// what is heard.
struct Voiceover {
    let cfg: Config
    let key: String
    let voiceID: String

    /// Never speed a take up more than this; past ~1.3× it sounds rushed.
    let maxTempo = 1.3
    /// Keep a breath between sentences.
    let minGap = 0.12

    struct Result {
        let audio: URL
        /// Transcript re-timed to the synthetic audio (for captions).
        let transcript: Transcript
        let notes: [String]
    }

    func build(from transcript: Transcript, videoDuration: Double, workDir: URL) throws -> Result {
        let fm = FileManager.default
        let parts = workDir.appendingPathComponent("vo", isDirectory: true)
        try? fm.removeItem(at: parts)
        try fm.createDirectory(at: parts, withIntermediateDirectories: true)

        var notes: [String] = []
        var pieces: [URL] = []          // silence/speech chunks, in order
        var placed: [Segment] = []
        var cursor: Double = 0          // end of audio written so far
        var drifted = 0
        var modelsUsed = Set<String>()

        let segments = transcript.segments
        for (i, seg) in segments.enumerated() {
            let text = seg.text.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }

            let speech = try ElevenLabs.speak(
                text: text,
                voiceID: voiceID,
                model: cfg.elevenModel,
                key: key,
                previous: i > 0 ? segments[i - 1].text : nil,
                next: i + 1 < segments.count ? segments[i + 1].text : nil
            )
            modelsUsed.insert(speech.modelUsed)

            let mp3 = parts.appendingPathComponent(String(format: "seg_%04d.mp3", i))
            try speech.mp3.write(to: mp3)
            let rawDuration = probeDuration(mp3) ?? estimatedDuration(speech) ?? seg.end - seg.start

            // How much room this sentence has before the next one is due.
            let anchor = max(seg.start, cursor)
            let nextAnchor = (i + 1 < segments.count ? segments[i + 1].start : videoDuration) - minGap
            let available = max(0.4, nextAnchor - anchor)

            var tempo = 1.0
            if rawDuration > available {
                tempo = min(maxTempo, rawDuration / available)
            }
            let placedDuration = rawDuration / tempo
            if anchor > seg.start + 0.25 { drifted += 1 }

            // Lead-in silence so this sentence starts on its anchor.
            let gap = anchor - cursor
            if gap > 0.01 {
                let sil = parts.appendingPathComponent(String(format: "sil_%04d.wav", i))
                try makeSilence(seconds: gap, at: sil)
                pieces.append(sil)
            }

            let wav = parts.appendingPathComponent(String(format: "seg_%04d.wav", i))
            try convert(mp3, to: wav, tempo: tempo)
            pieces.append(wav)

            let start = max(anchor, cursor + max(0, gap))
            placed.append(Segment(
                text: text,
                start: start,
                end: start + placedDuration,
                words: retimeWords(speech, segmentText: text, start: start,
                                   duration: placedDuration, fallback: seg.words)
            ))
            cursor = start + placedDuration
        }

        guard !pieces.isEmpty else { throw APIError(500, "voiceover produced no audio") }

        // Tail silence so the narration track spans the whole video.
        if videoDuration > cursor + 0.05 {
            let sil = parts.appendingPathComponent("sil_tail.wav")
            try makeSilence(seconds: videoDuration - cursor, at: sil)
            pieces.append(sil)
        }

        let list = parts.appendingPathComponent("parts.txt")
        try pieces
            .map { "file '\($0.path.replacingOccurrences(of: "'", with: "'\\''"))'" }
            .joined(separator: "\n")
            .write(to: list, atomically: true, encoding: .utf8)

        let narration = workDir.appendingPathComponent("narration.wav")
        try Shell.runChecked("ffmpeg", [
            "-hide_banner", "-y",
            "-f", "concat", "-safe", "0", "-i", list.path,
            "-c:a", "pcm_s16le", "-ar", "48000", "-ac", "2",
            narration.path,
        ])

        notes.append("voiceover: \(placed.count) lines via \(modelsUsed.sorted().joined(separator: "+"))")
        if drifted > 0 {
            notes.append("\(drifted) line(s) started late — narration is longer than the recorded pacing")
        }
        return Result(audio: narration,
                      transcript: Transcript(segments: placed, language: transcript.language),
                      notes: notes)
    }

    // MARK: - Helpers

    /// Map the API's character timings onto words, scaled by the tempo change
    /// so caption timing tracks the audio as placed.
    private func retimeWords(
        _ speech: ElevenLabs.Speech,
        segmentText: String,
        start: Double,
        duration: Double,
        fallback: [Word]
    ) -> [Word] {
        guard !speech.characters.isEmpty,
              speech.characters.count == speech.charStarts.count,
              speech.characters.count == speech.charEnds.count,
              let rawEnd = speech.charEnds.last, rawEnd > 0
        else {
            // No alignment: distribute words evenly across the placed slot.
            let words = segmentText.split(separator: " ").map(String.init)
            guard !words.isEmpty else { return fallback }
            let per = duration / Double(words.count)
            return words.enumerated().map { i, w in
                Word(text: w, start: start + Double(i) * per, end: start + Double(i + 1) * per)
            }
        }

        let scale = duration / rawEnd
        var words: [Word] = []
        var current = ""
        var wordStart: Double?
        var wordEnd: Double = 0
        for (i, ch) in speech.characters.enumerated() {
            if ch == " " || ch == "\n" {
                if !current.isEmpty, let ws = wordStart {
                    words.append(Word(text: current,
                                      start: start + ws * scale,
                                      end: start + wordEnd * scale))
                }
                current = ""
                wordStart = nil
                continue
            }
            if wordStart == nil { wordStart = speech.charStarts[i] }
            current += ch
            wordEnd = speech.charEnds[i]
        }
        if !current.isEmpty, let ws = wordStart {
            words.append(Word(text: current, start: start + ws * scale, end: start + wordEnd * scale))
        }
        return words
    }

    private func estimatedDuration(_ speech: ElevenLabs.Speech) -> Double? {
        speech.charEnds.last
    }

    private func makeSilence(seconds: Double, at url: URL) throws {
        try Shell.runChecked("ffmpeg", [
            "-hide_banner", "-y",
            "-f", "lavfi", "-i", "anullsrc=r=48000:cl=stereo",
            "-t", String(format: "%.3f", max(0.01, seconds)),
            "-c:a", "pcm_s16le",
            url.path,
        ])
    }

    private func convert(_ mp3: URL, to wav: URL, tempo: Double) throws {
        var args = ["-hide_banner", "-y", "-i", mp3.path]
        if abs(tempo - 1.0) > 0.005 {
            args += ["-filter:a", "atempo=\(String(format: "%.4f", tempo))"]
        }
        args += ["-c:a", "pcm_s16le", "-ar", "48000", "-ac", "2", wav.path]
        try Shell.runChecked("ffmpeg", args)
    }

    private func probeDuration(_ url: URL) -> Double? {
        guard let r = try? Shell.run("ffprobe", [
            "-v", "error", "-show_entries", "format=duration",
            "-of", "default=noprint_wrappers=1:nokey=1", url.path,
        ]), r.status == 0 else { return nil }
        return Double(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
