import Foundation

/// Turns kept fragments into deliverables:
/// fragments → per-run fMP4 → lossless concat master → optional trim (stream
/// copy) → transcript → optional AI voiceover → final HEVC encode (optional
/// burned captions) → optional GCS upload.
///
/// Transcription runs BEFORE the encode because both burned captions and the
/// voiceover need the words and their timings first.
struct Finalizer {
    let cfg: Config

    func finalize(meta: SessionMeta, sessionDir: URL, opts: StopOptions) throws -> FinalResult {
        let fm = FileManager.default
        var notes: [String] = []

        let keptRuns = meta.runs.filter { !$0.segments.isEmpty }
        var micUsable = !keptRuns.isEmpty && keptRuns.allSatisfy {
            $0.hasMic && $0.micInitFile != nil && !$0.micSegments.isEmpty
        }
        if keptRuns.contains(where: { $0.hasMic }) && !micUsable {
            notes.append("mic dropped: not every run produced mic audio")
        }

        // 1. Reassemble runs (init + fragments are a valid fMP4 byte-wise).
        var normFiles: [URL] = []
        var fullFiles: [URL] = []
        for run in keptRuns {
            guard let initFile = run.initFile else {
                notes.append("run \(run.name) has no init segment; skipped")
                continue
            }
            let runDir = sessionDir.appendingPathComponent("runs/\(run.name)", isDirectory: true)
            let joined = runDir.appendingPathComponent("run.mp4")
            try binaryConcat(dir: runDir, initFile: initFile, segments: run.segments, to: joined)

            let norm = runDir.appendingPathComponent("run-norm.mp4")
            try Shell.runChecked("ffmpeg", [
                "-hide_banner", "-y", "-i", joined.path,
                "-c", "copy", "-avoid_negative_ts", "make_zero", norm.path,
            ])
            try? fm.removeItem(at: joined)
            normFiles.append(norm)

            if micUsable, let micInit = run.micInitFile {
                do {
                    let micJoined = runDir.appendingPathComponent("mic.m4a")
                    try binaryConcat(dir: runDir, initFile: micInit, segments: run.micSegments, to: micJoined)
                    let micNorm = runDir.appendingPathComponent("mic-norm.m4a")
                    try Shell.runChecked("ffmpeg", [
                        "-hide_banner", "-y", "-i", micJoined.path,
                        "-c", "copy", "-avoid_negative_ts", "make_zero", micNorm.path,
                    ])
                    try? fm.removeItem(at: micJoined)

                    let videoDur = probeDuration(norm) ?? run.duration
                    let full = runDir.appendingPathComponent("run-full.mp4")
                    try Shell.runChecked("ffmpeg", [
                        "-hide_banner", "-y",
                        "-i", norm.path,
                        "-t", String(format: "%.3f", videoDur), "-i", micNorm.path,
                        "-map", "0", "-map", "1:a", "-c", "copy",
                        full.path,
                    ])
                    fullFiles.append(full)
                } catch {
                    notes.append("mic mux failed for \(run.name): \(error.localizedDescription); mic dropped")
                    micUsable = false
                }
            }
        }
        guard !normFiles.isEmpty else { throw APIError(500, "no playable runs") }
        let runFiles = (micUsable && fullFiles.count == normFiles.count) ? fullFiles : normFiles
        if runFiles == normFiles { micUsable = false }

        // 2. Lossless concat (`-map 0` or ffmpeg silently keeps one audio track).
        let master = sessionDir.appendingPathComponent("master.mp4")
        if runFiles.count == 1 {
            try? fm.removeItem(at: master)
            try Shell.runChecked("ffmpeg", [
                "-hide_banner", "-y", "-i", runFiles[0].path,
                "-map", "0", "-c", "copy", "-movflags", "+faststart", master.path,
            ])
        } else {
            let listFile = sessionDir.appendingPathComponent("concat.txt")
            try runFiles
                .map { "file '\($0.path.replacingOccurrences(of: "'", with: "'\\''"))'" }
                .joined(separator: "\n")
                .write(to: listFile, atomically: true, encoding: .utf8)
            try Shell.runChecked("ffmpeg", [
                "-hide_banner", "-y", "-f", "concat", "-safe", "0", "-i", listFile.path,
                "-map", "0", "-c", "copy", "-movflags", "+faststart", master.path,
            ])
        }

        // 3. Optional trim (stream copy — snaps to fragment keyframes).
        var source = master
        if opts.trimStart != nil || opts.trimEnd != nil {
            let trimmed = sessionDir.appendingPathComponent("trimmed.mp4")
            var args = ["-hide_banner", "-y"]
            if let s = opts.trimStart { args += ["-ss", String(s)] }
            if let e = opts.trimEnd { args += ["-to", String(e)] }
            args += ["-i", master.path, "-map", "0", "-c", "copy",
                     "-avoid_negative_ts", "make_zero", trimmed.path]
            try Shell.runChecked("ffmpeg", args)
            source = trimmed
            notes.append("trim is stream-copy: cut points snap to ~\(Int(cfg.segmentSeconds))s keyframes")
        }

        let audioCount = probeAudioStreamCount(source)
        let expectedWithMic = (keptRuns.first?.hasSystemAudio == true ? 1 : 0) + 1
        let hasMic = micUsable && audioCount >= expectedWithMic
        let micIndex = audioCount - 1
        let sourceDuration = probeDuration(source) ?? 0

        // 4. Mic gain: measured, then lifted toward the target. A webcam mic
        //    running at -55 dBFS is unusable without this.
        var micGain = opts.micGainDb ?? cfg.micGainDb ?? 0
        var micMeanDb: Double?
        if hasMic {
            micMeanDb = measureMeanVolume(source, audioIndex: micIndex)
            if opts.micGainDb == nil, cfg.micGainDb == nil, let mean = micMeanDb {
                micGain = max(0, min(30, cfg.micTargetDb - mean))
                if micGain >= 1 {
                    notes.append(String(format: "mic auto-gain +%.0f dB (was %.0f dBFS average)", micGain, mean))
                }
            }
            if let mean = micMeanDb, mean < -50 {
                notes.append(String(
                    format: "mic was very quiet (%.0f dBFS) — check the input device and its level", mean))
            }
        }

        // 5. Transcript (from the gained mic, else system audio).
        var transcript: Transcript?
        var srtPath: String?, vttPath: String?, txtPath: String?
        if opts.transcribe, audioCount > 0 {
            if let model = cfg.resolveWhisperModel() {
                do {
                    let wav = sessionDir.appendingPathComponent("speech16k.wav")
                    var args = ["-hide_banner", "-y", "-i", source.path,
                                "-map", "0:a:\(hasMic ? micIndex : 0)"]
                    if hasMic, micGain >= 1 {
                        args += ["-af", String(format: "volume=%.1fdB", micGain)]
                    }
                    args += ["-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le", wav.path]
                    try Shell.runChecked("ffmpeg", args)

                    let t = try Whisper.transcribe(
                        wav: wav, model: model, language: cfg.whisperLanguage, workDir: sessionDir
                    )
                    try? fm.removeItem(at: wav)
                    if Whisper.looksLikeSilenceArtifact(t) {
                        notes.append("no speech detected — captions skipped (silent or unusable mic track)")
                    } else {
                        transcript = t
                    }
                } catch {
                    notes.append("transcription failed: \(error.localizedDescription)")
                }
            } else {
                notes.append("transcription skipped: no whisper model (`mac-rec setup --whisper-model base`)")
            }
        }

        // 6. Optional AI voiceover replacing the recorded narration.
        var narration: URL?
        if opts.voiceover == true {
            if let t = transcript, !t.isEmpty {
                if let key = cfg.resolveElevenKey() {
                    if let voice = opts.voiceID ?? cfg.elevenVoiceID {
                        do {
                            let vo = Voiceover(cfg: cfg, key: key, voiceID: voice)
                            let result = try vo.build(
                                from: t, videoDuration: sourceDuration, workDir: sessionDir
                            )
                            narration = result.audio
                            transcript = result.transcript   // captions follow the new voice
                            notes.append(contentsOf: result.notes)
                        } catch {
                            notes.append("voiceover failed: \(error.localizedDescription) — keeping original audio")
                        }
                    } else {
                        notes.append("voiceover skipped: no voice selected (`mac-rec voices`)")
                    }
                } else {
                    notes.append("voiceover skipped: no ElevenLabs API key (`mac-rec setup --eleven-key ...`)")
                }
            } else {
                notes.append("voiceover skipped: nothing was transcribed")
            }
        }

        // 7. Caption sidecars + optional burn-in overlay track.
        var assFile: URL?   // transparent caption video, overlaid at encode time
        if let t = transcript, !t.isEmpty {
            let srt = sessionDir.appendingPathComponent("final.srt")
            let vtt = sessionDir.appendingPathComponent("final.vtt")
            let txt = sessionDir.appendingPathComponent("final.txt")
            try Captions.writeSRT(t, to: srt)
            try Captions.writeVTT(t, to: vtt)
            try Captions.writeText(t, to: txt)
            srtPath = srt.path; vttPath = vtt.path; txtPath = txt.path

            let styleName = (opts.captionStyle ?? cfg.captionStyle).lowercased()
            if styleName != "none" {
                if let template = Captions.Template.named(styleName) {
                    do {
                        let size = probeSize(source) ?? (meta.width, meta.height)
                        assFile = try CaptionRenderer.buildOverlay(
                            transcript: t, template: template, position: cfg.captionPosition,
                            width: size.0 > 0 ? size.0 : 1920,
                            height: size.1 > 0 ? size.1 : 1080,
                            fps: cfg.fps, duration: sourceDuration, workDir: sessionDir
                        )
                        if assFile != nil { notes.append("captions burned in (\(styleName))") }
                    } catch {
                        notes.append("caption burn-in failed: \(error.localizedDescription); sidecars written")
                    }
                } else {
                    notes.append("unknown caption style \"\(styleName)\" — sidecars only")
                }
            }
        }

        // 8. Final encode.
        let final = sessionDir.appendingPathComponent("final.mp4")
        if opts.compress || assFile != nil || narration != nil {
            var args = ["-hide_banner", "-y", "-i", source.path]
            if let narration { args += ["-i", narration.path] }
            if let captionTrack = assFile { args += ["-i", captionTrack.path] }

            // One graph only — ffmpeg honours a single -filter_complex.
            var graph: [String] = []
            var maps: [String] = []
            if assFile != nil {
                let capIndex = narration != nil ? 2 : 1
                graph.append("[0:v:0][\(capIndex):v:0]overlay=0:0:format=auto[v]")
                maps += ["-map", "[v]"]
            } else {
                maps += ["-map", "0:v:0"]
            }

            let audio = audioGraph(
                audioCount: audioCount, hasMic: hasMic, micIndex: micIndex,
                micGain: micGain, cleanMic: (opts.cleanMic ?? true),
                narrationInput: narration != nil, notes: &notes
            )
            if let g = audio.graph { graph.append(g) }
            maps += audio.maps

            if !graph.isEmpty { args += ["-filter_complex", graph.joined(separator: ";")] }
            args += maps
            args += ["-c:v", "hevc_videotoolbox", "-q:v", String(cfg.compressQuality), "-tag:v", "hvc1"]
            args += audio.codec
            args += ["-movflags", "+faststart", final.path]
            try Shell.runChecked("ffmpeg", args)
        } else {
            try? fm.removeItem(at: final)
            try fm.copyItem(at: source, to: final)
        }

        let duration = probeDuration(final) ?? sourceDuration

        // 9. Optional upload.
        var shareURL: String?, gsURI: String?
        let wantUpload = opts.upload ?? (cfg.gcsBucket != nil)
        if wantUpload {
            if let bucket = cfg.gcsBucket {
                do {
                    let objectBase = "\(cfg.gcsPrefix)/\(meta.id)"
                    let dest = "gs://\(bucket)/\(objectBase).mp4"
                    try Shell.runChecked("gcloud", ["storage", "cp", final.path, dest])
                    for (path, ext) in [(srtPath, "srt"), (vttPath, "vtt")] {
                        if let path {
                            _ = try? Shell.run("gcloud", ["storage", "cp", path,
                                                          "gs://\(bucket)/\(objectBase).\(ext)"])
                        }
                    }
                    gsURI = dest
                    let url = "\(cfg.gcsPublicBase ?? "https://storage.googleapis.com/\(bucket)")/\(objectBase).mp4"
                    shareURL = url
                    Shell.pbcopy(url)
                    notes.append("share link copied to clipboard")
                } catch {
                    notes.append("upload failed: \(error.localizedDescription)")
                }
            } else {
                notes.append("upload skipped: no gcsBucket configured")
            }
        }

        var finalPath = final.path
        if let outPath = opts.output {
            let dest = URL(fileURLWithPath: (outPath as NSString).expandingTildeInPath)
            try? fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: dest)
            try fm.copyItem(at: final, to: dest)
            finalPath = dest.path
        }

        return FinalResult(
            sessionId: meta.id,
            sessionDir: sessionDir.path,
            master: master.path,
            final: finalPath,
            durationSeconds: duration,
            srt: srtPath,
            vtt: vttPath,
            transcript: txtPath,
            shareURL: shareURL,
            gsURI: gsURI,
            notes: notes
        )
    }

    // MARK: - Audio graph

    /// System audio + (AI narration | cleaned mic) mixed to one AAC track,
    /// expressed as a filter-graph fragment plus its map/codec arguments.
    private func audioGraph(
        audioCount: Int,
        hasMic: Bool,
        micIndex: Int,
        micGain: Double,
        cleanMic: Bool,
        narrationInput: Bool,
        notes: inout [String]
    ) -> (graph: String?, maps: [String], codec: [String]) {
        let aac = ["-c:a", "aac", "-b:a", "192k"]
        var micChain: [String] = []
        if micGain >= 0.5 { micChain.append(String(format: "volume=%.1fdB", micGain)) }
        if cleanMic {
            micChain.append(contentsOf: ["highpass=f=75", "afftdn=nf=-30", "speechnorm=e=6:r=0.0003:l=1"])
            notes.append("mic cleaned: denoise + speech leveling")
        }

        // AI narration replaces the mic entirely.
        if narrationInput {
            let systemStreams = hasMic ? micIndex : audioCount
            if systemStreams > 0 {
                // Duck system audio under the narration.
                var graph = (0..<systemStreams).map { "[0:a:\($0)]" }.joined()
                graph += "amix=inputs=\(systemStreams):duration=longest:normalize=0,volume=0.35[sys];"
                graph += "[1:a]volume=1.0[vo];[sys][vo]amix=inputs=2:duration=longest:normalize=0[a]"
                return (graph, ["-map", "[a]"], aac)
            }
            return (nil, ["-map", "1:a"], aac)
        }

        guard audioCount > 0 else { return (nil, [], []) }

        if hasMic && audioCount >= 2 {
            let others = (0..<micIndex).map { "[0:a:\($0)]" }.joined()
            let chain = micChain.isEmpty ? "anull" : micChain.joined(separator: ",")
            let graph = "[0:a:\(micIndex)]\(chain)[mc];\(others)[mc]"
                + "amix=inputs=\(audioCount):duration=longest:normalize=0[a]"
            return (graph, ["-map", "[a]"], aac)
        }

        // Single audio stream: run the mic chain inside the graph too, so we
        // never mix -af with -filter_complex.
        if hasMic, !micChain.isEmpty {
            return ("[0:a:0]\(micChain.joined(separator: ","))[a]", ["-map", "[a]"], aac)
        }
        return (nil, ["-map", "0:a:0"], aac)
    }

    // MARK: - Helpers

    private func binaryConcat(dir: URL, initFile: String, segments: [SegmentMeta], to out: URL) throws {
        let fm = FileManager.default
        try? fm.removeItem(at: out)
        fm.createFile(atPath: out.path, contents: nil)
        let handle = try FileHandle(forWritingTo: out)
        defer { try? handle.close() }
        try handle.write(contentsOf: Data(contentsOf: dir.appendingPathComponent(initFile)))
        for seg in segments {
            try handle.write(contentsOf: Data(contentsOf: dir.appendingPathComponent(seg.file)))
        }
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

    private func probeAudioStreamCount(_ url: URL) -> Int {
        guard let r = try? Shell.run("ffprobe", [
            "-v", "error", "-select_streams", "a",
            "-show_entries", "stream=index", "-of", "csv=p=0", url.path,
        ]), r.status == 0 else { return 0 }
        return r.stdout.split(separator: "\n").filter { !$0.isEmpty }.count
    }

    private func measureMeanVolume(_ url: URL, audioIndex: Int) -> Double? {
        guard let r = try? Shell.run("ffmpeg", [
            "-hide_banner", "-i", url.path,
            "-map", "0:a:\(audioIndex)", "-af", "volumedetect", "-f", "null", "-",
        ]) else { return nil }
        let text = r.stderr + r.stdout
        guard let range = text.range(of: "mean_volume: ") else { return nil }
        let rest = text[range.upperBound...].prefix(12)
        return Double(rest.split(separator: " ").first ?? "")
    }

    private func probeDuration(_ url: URL) -> Double? {
        guard let r = try? Shell.run("ffprobe", [
            "-v", "error", "-show_entries", "format=duration",
            "-of", "default=noprint_wrappers=1:nokey=1", url.path,
        ]), r.status == 0 else { return nil }
        return Double(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
