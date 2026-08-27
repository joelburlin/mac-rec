import Foundation
import ArgumentParser

/// Re-narrate any video with an ElevenLabs voice, keeping picture sync, and
/// (optionally) burn matching captions. Works on a mac-rec session's final.mp4
/// or on any file you already have.
struct VoiceoverCmd: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "voiceover",
        abstract: "Replace a video's narration with an ElevenLabs voice, perfectly time-aligned."
    )

    @Option(name: .shortAndLong, help: "Input video (or a session directory's final.mp4).")
    var input: String

    @Option(name: .shortAndLong, help: "Output path (default: <input>-voiced.mp4).")
    var output: String?

    @Option(help: "ElevenLabs voice id or name substring (default: configured voice).")
    var voice: String?

    @Option(help: "Burn in captions: none|classic|boxed|bold|karaoke|minimal.")
    var captions: String?

    @Option(help: "Keep the original audio underneath at this gain (0 = drop it).")
    var duck: Double = 0.25

    @Flag(help: "Print machine-readable JSON.")
    var json = false

    func run() throws {
        let cfg = Config.load()
        let fm = FileManager.default

        let src = URL(fileURLWithPath: (input as NSString).expandingTildeInPath,
                      relativeTo: URL(fileURLWithPath: fm.currentDirectoryPath)).standardizedFileURL
        guard fm.fileExists(atPath: src.path) else {
            throw ValidationError("no such file: \(src.path)")
        }
        guard let key = cfg.resolveElevenKey() else {
            throw ValidationError("no ElevenLabs API key — `mac-rec setup --eleven-key env`")
        }
        guard let model = cfg.resolveWhisperModel() else {
            throw ValidationError("no whisper model — `mac-rec setup --whisper-model base`")
        }

        // Resolve the voice (accepts a name substring).
        var voiceID = voice ?? cfg.elevenVoiceID
        if let want = voice, !want.hasPrefix("voice_"), want.count < 30 {
            let all = try ElevenLabs.listVoices(key: key)
            if let hit = all.first(where: { $0.id == want })
                ?? all.first(where: { $0.name.lowercased().contains(want.lowercased()) }) {
                voiceID = hit.id
            }
        }
        guard let voiceID else {
            throw ValidationError("no voice selected — `mac-rec voices --use NAME`")
        }

        let work = src.deletingLastPathComponent()
            .appendingPathComponent(".macrec-vo-" + src.deletingPathExtension().lastPathComponent,
                                    isDirectory: true)
        try? fm.removeItem(at: work)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        // 1. Speech track → whisper.
        let wav = work.appendingPathComponent("speech16k.wav")
        try Shell.runChecked("ffmpeg", [
            "-hide_banner", "-y", "-i", src.path,
            "-map", "0:a:0", "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le", wav.path,
        ])
        let transcript = try Whisper.transcribe(
            wav: wav, model: model, language: cfg.whisperLanguage, workDir: work
        )
        guard !transcript.isEmpty, !Whisper.looksLikeSilenceArtifact(transcript) else {
            throw ValidationError("no speech found in \(src.lastPathComponent)")
        }

        // 2. Speak it back, slot-anchored.
        let duration = probeDuration(src) ?? transcript.segments.last?.end ?? 0
        let vo = Voiceover(cfg: cfg, key: key, voiceID: voiceID)
        let built = try vo.build(from: transcript, videoDuration: duration, workDir: work)

        // 3. Captions from the *placed* audio, so they always match.
        let outURL = URL(fileURLWithPath: (output ?? defaultOutput(src)) as String)
        let base = outURL.deletingPathExtension()
        let srt = base.appendingPathExtension("srt")
        try Captions.writeSRT(built.transcript, to: srt)
        let vtt = base.appendingPathExtension("vtt")
        try Captions.writeVTT(built.transcript, to: vtt)

        var captionTrack: URL?
        let styleName = (captions ?? cfg.captionStyle).lowercased()
        if styleName != "none", let template = Captions.Template.named(styleName) {
            let (w, h) = probeSize(src) ?? (1920, 1080)
            captionTrack = try CaptionRenderer.buildOverlay(
                transcript: built.transcript, template: template,
                position: cfg.captionPosition, width: w, height: h,
                fps: cfg.fps, duration: duration, workDir: work
            )
        }

        // 4. Mux — one filter graph for picture and sound together.
        var args = ["-hide_banner", "-y", "-i", src.path, "-i", built.audio.path]
        if let captionTrack { args += ["-i", captionTrack.path] }

        var graph: [String] = []
        var maps: [String] = []
        var videoCodec = ["-c:v", "copy"]
        if captionTrack != nil {
            graph.append("[0:v:0][2:v:0]overlay=0:0:format=auto[v]")
            maps += ["-map", "[v]"]
            videoCodec = ["-c:v", "hevc_videotoolbox", "-q:v", String(cfg.compressQuality), "-tag:v", "hvc1"]
        } else {
            maps += ["-map", "0:v:0"]
        }
        if duck > 0.001, probeAudioCount(src) > 0 {
            graph.append("[0:a:0]volume=\(String(format: "%.2f", duck))[bed];"
                         + "[bed][1:a]amix=inputs=2:duration=longest:normalize=0[a]")
            maps += ["-map", "[a]"]
        } else {
            maps += ["-map", "1:a"]
        }
        if !graph.isEmpty { args += ["-filter_complex", graph.joined(separator: ";")] }
        args += maps + videoCodec
        args += ["-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart", outURL.path]
        try Shell.runChecked("ffmpeg", args)

        let result = FinalResult(
            sessionId: src.deletingPathExtension().lastPathComponent,
            sessionDir: outURL.deletingLastPathComponent().path,
            master: src.path,
            final: outURL.path,
            durationSeconds: probeDuration(outURL) ?? duration,
            srt: srt.path,
            vtt: vtt.path,
            transcript: nil,
            shareURL: nil,
            gsURI: nil,
            notes: built.notes + (captionTrack != nil ? ["captions burned in (\(styleName))"] : [])
        )
        printJSONOrText(result, json: json) {
            var lines = ["🎙 re-narrated \(fmtDuration(result.durationSeconds)) — \(result.final)",
                         "  captions: \(srt.path)"]
            lines += result.notes.map { "  note: \($0)" }
            return lines.joined(separator: "\n")
        }
    }

    private func defaultOutput(_ src: URL) -> String {
        src.deletingPathExtension().path + "-voiced.mp4"
    }

    private func probeDuration(_ url: URL) -> Double? {
        guard let r = try? Shell.run("ffprobe", [
            "-v", "error", "-show_entries", "format=duration",
            "-of", "default=noprint_wrappers=1:nokey=1", url.path,
        ]), r.status == 0 else { return nil }
        return Double(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func probeSize(_ url: URL) -> (Int, Int)? {
        guard let r = try? Shell.run("ffprobe", [
            "-v", "error", "-select_streams", "v:0",
            "-show_entries", "stream=width,height", "-of", "csv=p=0:s=x", url.path,
        ]), r.status == 0 else { return nil }
        let parts = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "x")
        guard parts.count >= 2, let w = Int(parts[0]), let h = Int(parts[1]) else { return nil }
        return (w, h)
    }

    private func probeAudioCount(_ url: URL) -> Int {
        guard let r = try? Shell.run("ffprobe", [
            "-v", "error", "-select_streams", "a",
            "-show_entries", "stream=index", "-of", "csv=p=0", url.path,
        ]), r.status == 0 else { return 0 }
        return r.stdout.split(separator: "\n").filter { !$0.isEmpty }.count
    }
}
