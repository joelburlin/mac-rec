import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

/// Renders caption frames with CoreText and composites them as one alpha
/// overlay track.
///
/// This machine's ffmpeg ships without libass/drawtext, but rendering the
/// captions natively is better anyway: real font fallback, correct bidi for
/// Hebrew/Arabic, and per-word karaoke without ASS tag gymnastics.
enum CaptionRenderer {

    struct Frame {
        let image: URL
        let start: Double
        let end: Double
    }

    /// Build a transparent overlay video covering `duration`; nil when there
    /// is nothing to draw.
    static func buildOverlay(
        transcript: Transcript,
        template: Captions.Template,
        position: String,
        width: Int,
        height: Int,
        fps: Int,
        duration: Double,
        workDir: URL
    ) throws -> URL? {
        let dir = workDir.appendingPathComponent("captions", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let frames = try renderFrames(
            transcript: transcript, template: template, position: position,
            width: width, height: height, dir: dir
        )
        guard !frames.isEmpty else { return nil }

        // Transparent spacer for the gaps between captions.
        let blank = dir.appendingPathComponent("blank.png")
        try writePNG(makeContext(width: width, height: height).makeImage()!, to: blank)

        var lines: [String] = []
        var cursor = 0.0
        func add(_ url: URL, _ seconds: Double) {
            guard seconds > 0.001 else { return }
            lines.append("file '\(url.path.replacingOccurrences(of: "'", with: "'\\''"))'")
            lines.append(String(format: "duration %.3f", seconds))
        }
        for f in frames {
            if f.start > cursor { add(blank, f.start - cursor) }
            add(f.image, max(0.05, f.end - max(f.start, cursor)))
            cursor = max(cursor, f.end)
        }
        if duration > cursor { add(blank, duration - cursor) }
        // concat demuxer needs the last file repeated to honour its duration.
        lines.append("file '\(blank.path)'")

        let list = dir.appendingPathComponent("frames.txt")
        try lines.joined(separator: "\n").write(to: list, atomically: true, encoding: .utf8)

        let overlay = dir.appendingPathComponent("overlay.mov")
        try Shell.runChecked("ffmpeg", [
            "-hide_banner", "-y",
            "-f", "concat", "-safe", "0", "-i", list.path,
            "-fps_mode", "cfr", "-r", String(fps),
            "-c:v", "qtrle", "-pix_fmt", "argb",
            overlay.path,
        ])
        return overlay
    }

    // MARK: - Frame rendering

    private static func renderFrames(
        transcript: Transcript,
        template: Captions.Template,
        position: String,
        width: Int,
        height: Int,
        dir: URL
    ) throws -> [Frame] {
        var frames: [Frame] = []
        var index = 0
        for seg in transcript.segments {
            let text = seg.text.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }

            if template.karaoke, !seg.words.isEmpty {
                // One frame per word so the spoken word can be highlighted.
                for (i, word) in seg.words.enumerated() {
                    let url = dir.appendingPathComponent(String(format: "cap_%05d.png", index))
                    index += 1
                    try draw(text: text, highlightWord: i, words: seg.words,
                             template: template, position: position,
                             width: width, height: height, to: url)
                    let end = i + 1 < seg.words.count ? seg.words[i + 1].start : seg.end
                    frames.append(Frame(image: url, start: word.start, end: max(word.start + 0.08, end)))
                }
            } else {
                let url = dir.appendingPathComponent(String(format: "cap_%05d.png", index))
                index += 1
                try draw(text: text, highlightWord: nil, words: seg.words,
                         template: template, position: position,
                         width: width, height: height, to: url)
                frames.append(Frame(image: url, start: seg.start, end: max(seg.start + 0.2, seg.end)))
            }
        }
        return frames
    }

    private static func draw(
        text: String,
        highlightWord: Int?,
        words: [Word],
        template: Captions.Template,
        position: String,
        width: Int,
        height: Int,
        to url: URL
    ) throws {
        let ctx = makeContext(width: width, height: height)
        let scale = max(0.5, Double(height) / 1080.0)
        let fontSize = CGFloat(Double(template.size) * scale)
        let font = makeFont(template.font, size: fontSize, bold: template.bold)

        let attributed = NSMutableAttributedString()
        let spoken = colorFromASS(template.primary)
        let plain = colorFromASS(template.highlight)

        if let hi = highlightWord, !words.isEmpty {
            for (i, w) in words.enumerated() {
                let color = i == hi ? spoken : plain
                attributed.append(NSAttributedString(
                    string: w.text + (i == words.count - 1 ? "" : " "),
                    attributes: attributes(font: font, color: color, template: template, scale: scale)
                ))
            }
        } else {
            attributed.append(NSAttributedString(
                string: text,
                attributes: attributes(font: font, color: plain, template: template, scale: scale)
            ))
        }

        // Layout inside a comfortable safe area.
        let margin = CGFloat(80 * scale)
        let maxWidth = CGFloat(width) - margin * 2
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let suggested = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, CFRange(location: 0, length: 0), nil,
            CGSize(width: maxWidth, height: .greatestFiniteMagnitude), nil
        )
        let boxWidth = min(maxWidth, ceil(suggested.width) + 4)
        let boxHeight = ceil(suggested.height) + 4

        let originY: CGFloat
        switch position.lowercased() {
        case "top": originY = CGFloat(height) - boxHeight - CGFloat(70 * scale)
        case "center", "middle": originY = (CGFloat(height) - boxHeight) / 2
        default: originY = CGFloat(70 * scale)
        }
        let originX = (CGFloat(width) - boxWidth) / 2

        if template.borderStyle == 3 {
            let pad = CGFloat(18 * scale)
            let rect = CGRect(x: originX - pad, y: originY - pad * 0.6,
                              width: boxWidth + pad * 2, height: boxHeight + pad * 1.2)
            ctx.setFillColor(colorFromASS(template.back))
            let path = CGPath(roundedRect: rect, cornerWidth: 10 * scale,
                              cornerHeight: 10 * scale, transform: nil)
            ctx.addPath(path)
            ctx.fillPath()
        }

        if template.shadow > 0 {
            ctx.setShadow(offset: CGSize(width: 0, height: -template.shadow * scale),
                          blur: 3 * scale,
                          color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.75))
        }

        let path = CGPath(rect: CGRect(x: originX, y: originY, width: boxWidth, height: boxHeight), transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
        CTFrameDraw(frame, ctx)

        guard let image = ctx.makeImage() else { throw APIError(500, "caption render failed") }
        try writePNG(image, to: url)
    }

    private static func attributes(
        font: CTFont, color: CGColor, template: Captions.Template, scale: Double
    ) -> [NSAttributedString.Key: Any] {
        // CoreText paragraph style (AppKit's NSParagraphStyle isn't available
        // in this dependency-light file, and CT is what actually lays out).
        var alignment = CTTextAlignment.center
        var lineSpacing = CGFloat(2)
        let settings = withUnsafeMutablePointer(to: &alignment) { alignPtr in
            withUnsafeMutablePointer(to: &lineSpacing) { spacePtr in
                [
                    CTParagraphStyleSetting(spec: .alignment,
                                            valueSize: MemoryLayout<CTTextAlignment>.size,
                                            value: alignPtr),
                    CTParagraphStyleSetting(spec: .lineSpacingAdjustment,
                                            valueSize: MemoryLayout<CGFloat>.size,
                                            value: spacePtr),
                ]
            }
        }
        let paragraph = CTParagraphStyleCreate(settings, settings.count)
        var attrs: [NSAttributedString.Key: Any] = [
            .init(kCTFontAttributeName as String): font,
            .init(kCTForegroundColorAttributeName as String): color,
            .init(kCTParagraphStyleAttributeName as String): paragraph,
        ]
        if template.outline > 0 {
            // Negative width = stroke *and* fill (an outline, not hollow text).
            attrs[.init(kCTStrokeWidthAttributeName as String)] = -template.outline * scale * 1.6
            attrs[.init(kCTStrokeColorAttributeName as String)] =
                CGColor(red: 0, green: 0, blue: 0, alpha: 1)
        }
        return attrs
    }

    private static func makeFont(_ name: String, size: CGFloat, bold: Bool) -> CTFont {
        let font = CTFontCreateWithName(name as CFString, size, nil)
        // CTFontCreateWithName falls back to Helvetica for unknown names, so a
        // missing "Arial Black" still renders — just apply the bold trait.
        if bold,
           let boldFont = CTFontCreateCopyWithSymbolicTraits(font, size, nil, .traitBold, .traitBold) {
            return boldFont
        }
        return font
    }

    private static func makeContext(width: Int, height: Int) -> CGContext {
        let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )!
        ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx
    }

    private static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ) else { throw APIError(500, "cannot write \(url.lastPathComponent)") }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw APIError(500, "cannot encode \(url.lastPathComponent)")
        }
    }

    /// ASS colours are &HAABBGGRR with AA as *transparency*.
    private static func colorFromASS(_ s: String) -> CGColor {
        var hex = s.uppercased()
        hex = hex.replacingOccurrences(of: "&H", with: "").replacingOccurrences(of: "&", with: "")
        while hex.count < 8 { hex = "0" + hex }
        guard let value = UInt32(hex, radix: 16) else {
            return CGColor(red: 1, green: 1, blue: 1, alpha: 1)
        }
        let transparency = Double((value >> 24) & 0xFF) / 255.0
        let blue = Double((value >> 16) & 0xFF) / 255.0
        let green = Double((value >> 8) & 0xFF) / 255.0
        let red = Double(value & 0xFF) / 255.0
        return CGColor(red: red, green: green, blue: blue, alpha: 1 - transparency)
    }
}
