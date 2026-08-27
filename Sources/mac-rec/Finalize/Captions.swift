import Foundation

/// Caption writers: SRT/VTT sidecars always, plus an ASS file when a burn-in
/// template is chosen.
enum Captions {

    // MARK: - Templates

    struct Template {
        let name: String
        let font: String
        let size: Int          // at 1080p; scaled for other heights
        let primary: String    // &HAABBGGRR (ASS = BGR, AA is *transparency*)
        let highlight: String  // karaoke: the not-yet-spoken color
        let outline: Double
        let shadow: Double
        let borderStyle: Int   // 1 = outline, 3 = opaque box
        let back: String
        let bold: Bool
        let karaoke: Bool

        static let all: [String: Template] = [
            "classic": Template(
                name: "classic", font: "Helvetica Neue", size: 30,
                primary: "&H00FFFFFF", highlight: "&H00FFFFFF",
                outline: 2.2, shadow: 0.6, borderStyle: 1, back: "&H80000000",
                bold: false, karaoke: false
            ),
            "boxed": Template(
                name: "boxed", font: "Helvetica Neue", size: 28,
                primary: "&H00FFFFFF", highlight: "&H00FFFFFF",
                outline: 0.9, shadow: 0, borderStyle: 3, back: "&H70000000",
                bold: false, karaoke: false
            ),
            "bold": Template(
                name: "bold", font: "Arial Black", size: 42,
                primary: "&H00FFFFFF", highlight: "&H00FFFFFF",
                outline: 4.5, shadow: 1.2, borderStyle: 1, back: "&H90000000",
                bold: true, karaoke: false
            ),
            "karaoke": Template(
                name: "karaoke", font: "Arial Black", size: 40,
                primary: "&H0000E5FF", highlight: "&H00FFFFFF",  // spoken = amber
                outline: 4.0, shadow: 1.0, borderStyle: 1, back: "&H90000000",
                bold: true, karaoke: true
            ),
            "minimal": Template(
                name: "minimal", font: "Helvetica Neue", size: 24,
                primary: "&H00F0F0F0", highlight: "&H00F0F0F0",
                outline: 1.4, shadow: 0, borderStyle: 1, back: "&H60000000",
                bold: false, karaoke: false
            ),
        ]

        static func named(_ s: String) -> Template? { all[s.lowercased()] }
    }

    static let styleNames = ["none", "classic", "boxed", "bold", "karaoke", "minimal"]

    // MARK: - Sidecars

    static func writeSRT(_ t: Transcript, to url: URL) throws {
        var out = ""
        for (i, seg) in t.segments.enumerated() {
            out += "\(i + 1)\n"
            out += "\(srtTime(seg.start)) --> \(srtTime(seg.end))\n"
            out += seg.text + "\n\n"
        }
        try out.write(to: url, atomically: true, encoding: .utf8)
    }

    static func writeVTT(_ t: Transcript, to url: URL) throws {
        var out = "WEBVTT\n\n"
        for seg in t.segments {
            out += "\(vttTime(seg.start)) --> \(vttTime(seg.end))\n"
            out += seg.text + "\n\n"
        }
        try out.write(to: url, atomically: true, encoding: .utf8)
    }

    static func writeText(_ t: Transcript, to url: URL) throws {
        try (t.plainText + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - ASS (burn-in)

    static func writeASS(
        _ t: Transcript,
        template: Template,
        position: String,
        videoWidth: Int,
        videoHeight: Int,
        to url: URL
    ) throws {
        // Scale the design (authored at 1080p) to the real frame height.
        let scale = max(0.5, Double(videoHeight) / 1080.0)
        let size = Int((Double(template.size) * scale).rounded())
        let outline = (template.outline * scale * 10).rounded() / 10
        let shadow = (template.shadow * scale * 10).rounded() / 10
        let margin = Int((60 * scale).rounded())

        // ASS alignment: 2 = bottom-center, 8 = top-center, 5 = middle-center.
        let alignment: Int
        switch position.lowercased() {
        case "top": alignment = 8
        case "center", "middle": alignment = 5
        default: alignment = 2
        }

        var out = """
        [Script Info]
        ScriptType: v4.00+
        PlayResX: \(videoWidth)
        PlayResY: \(videoHeight)
        WrapStyle: 0
        ScaledBorderAndShadow: yes

        [V4+ Styles]
        Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
        Style: Main,\(template.font),\(size),\(template.primary),\(template.highlight),&H00000000,\(template.back),\(template.bold ? -1 : 0),0,0,0,100,100,0,0,\(template.borderStyle),\(outline),\(shadow),\(alignment),\(margin),\(margin),\(margin),1

        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text

        """

        for seg in t.segments {
            let body: String
            if template.karaoke, !seg.words.isEmpty {
                // \kf spans highlight each word as it is spoken.
                var parts: [String] = []
                var cursor = seg.start
                for w in seg.words {
                    let lead = max(0, w.start - cursor)
                    if lead > 0.02 {
                        parts.append("{\\kf\(Int((lead * 100).rounded()))}")
                    }
                    let dur = max(0.05, w.end - max(w.start, cursor))
                    parts.append("{\\kf\(Int((dur * 100).rounded()))}\(escape(w.text)) ")
                    cursor = w.end
                }
                body = parts.joined()
            } else {
                body = escape(seg.text)
            }
            out += "Dialogue: 0,\(assTime(seg.start)),\(assTime(seg.end)),Main,,0,0,0,,\(body)\n"
        }
        try out.write(to: url, atomically: true, encoding: .utf8)
    }

    /// ffmpeg filter argument for an ASS file (paths need escaping twice).
    static func filterArgument(for ass: URL) -> String {
        var p = ass.path
        p = p.replacingOccurrences(of: "\\", with: "\\\\")
        p = p.replacingOccurrences(of: ":", with: "\\:")
        p = p.replacingOccurrences(of: "'", with: "\\'")
        p = p.replacingOccurrences(of: "[", with: "\\[")
        p = p.replacingOccurrences(of: "]", with: "\\]")
        p = p.replacingOccurrences(of: ",", with: "\\,")
        return "ass=\(p)"
    }

    // MARK: - Helpers

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "{", with: "\\{")
            .replacingOccurrences(of: "}", with: "\\}")
            .replacingOccurrences(of: "\n", with: "\\N")
    }

    private static func srtTime(_ t: Double) -> String {
        let ms = Int((max(0, t) * 1000).rounded())
        return String(format: "%02d:%02d:%02d,%03d",
                      ms / 3_600_000, (ms / 60_000) % 60, (ms / 1000) % 60, ms % 1000)
    }

    private static func vttTime(_ t: Double) -> String {
        srtTime(t).replacingOccurrences(of: ",", with: ".")
    }

    private static func assTime(_ t: Double) -> String {
        let cs = Int((max(0, t) * 100).rounded())
        return String(format: "%d:%02d:%02d.%02d",
                      cs / 360_000, (cs / 6000) % 60, (cs / 100) % 60, cs % 100)
    }
}
