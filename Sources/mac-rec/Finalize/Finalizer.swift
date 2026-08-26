import Foundation

/// Turns kept fragments into deliverables:
/// fragments → per-run fMP4 → lossless concat master → optional trim (stream
/// copy) → HEVC (VideoToolbox) compress → whisper.cpp captions → optional GCS
/// upload with the share link on the clipboard.
struct Finalizer {
    let cfg: Config

    func finalize(meta: SessionMeta, sessionDir: URL, opts: StopOptions) throws -> FinalResult {
        let fm = FileManager.default
        var notes: [String] = []

        // Mic is only usable when every kept run has a mic stream — otherwise
        // concat inputs would have mismatched track counts.
        let keptRuns = meta.runs.filter { !$0.segments.isEmpty }
        var micUsable = !keptRuns.isEmpty && keptRuns.allSatisfy {
            $0.hasMic && $0.micInitFile != nil && !$0.micSegments.isEmpty
        }
        if keptRuns.contains(where: { $0.hasMic }) && !micUsable {
            notes.append("mic dropped: not every run produced mic audio")
        }

        // 1. Reassemble each run: init segment + media fragments are a valid
        //    fragmented MP4 when simply concatenated byte-wise. The mic stream
        //    is rebuilt the same way, trimmed to the kept (post-rewind) video
        //    duration, and muxed back as a second audio track.
        var normFiles: [URL] = []       // video + system audio
        var fullFiles: [URL] = []       // + mic track (used only if every run got one)
        for run in keptRuns {
            guard let initFile = run.initFile else {
                notes.append("run \(run.name) has no init segment; skipped")
                continue
            }
            let runDir = sessionDir.appendingPathComponent("runs/\(run.name)", isDirectory: true)
            let joined = runDir.appendingPathComponent("run.mp4")
            try binaryConcat(dir: runDir, initFile: initFile, segments: run.segments, to: joined)

            // Normalize timestamps to start at ~0 so cross-run concat is clean.
            let norm = runDir.appendingPathComponent("run-norm.mp4")
            try Shell.runChecked("ffmpeg", [
                "-hide_banner", "-y",
                "-i", joined.path,
                "-c", "copy",
                "-avoid_negative_ts", "make_zero",
                norm.path,
            ])
            try? fm.removeItem(at: joined)
            normFiles.append(norm)

            if micUsable, let micInit = run.micInitFile {
                do {
                    let micJoined = runDir.appendingPathComponent("mic.m4a")
                    try binaryConcat(dir: runDir, initFile: micInit, segments: run.micSegments, to: micJoined)
                    let micNorm = runDir.appendingPathComponent("mic-norm.m4a")
                    try Shell.runChecked("ffmpeg", [
                        "-hide_banner", "-y",
                        "-i", micJoined.path,
                        "-c", "copy",
                        "-avoid_negative_ts", "make_zero",
                        micNorm.path,
                    ])
                    try? fm.removeItem(at: micJoined)

                    // Rewind only deletes video fragments, so cut the mic to the
                    // kept video duration before muxing.
                    let videoDur = probeDuration(norm) ?? run.duration
                    let full = runDir.appendingPathComponent("run-full.mp4")
                    try Shell.runChecked("ffmpeg", [
                        "-hide_banner", "-y",
                        "-i", norm.path,
                        "-t", String(format: "%.3f", videoDur), "-i", micNorm.path,
                        "-map", "0", "-map", "1:a",
                        "-c", "copy",
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

        // 2. Lossless concat into the master.
        let master = sessionDir.appendingPathComponent("master.mp4")
        if runFiles.count == 1 {
            try? fm.removeItem(at: master)
            try Shell.runChecked("ffmpeg", [
                "-hide_banner", "-y",
                "-i", runFiles[0].path,
                "-c", "copy", "-movflags", "+faststart",
                master.path,
            ])
        } else {
            let listFile = sessionDir.appendingPathComponent("concat.txt")
            let listBody = runFiles
                .map { "file '\($0.path.replacingOccurrences(of: "'", with: "'\\''"))'" }
                .joined(separator: "\n")
            try listBody.write(to: listFile, atomically: true, encoding: .utf8)
            try Shell.runChecked("ffmpeg", [
                "-hide_banner", "-y",
                "-f", "concat", "-safe", "0",
                "-i", listFile.path,
                "-c", "copy", "-movflags", "+faststart",
                master.path,
            ])
        }

        // 3. Optional trim — stream copy, snaps to fragment keyframes.
        var source = master
        if opts.trimStart != nil || opts.trimEnd != nil {
            let trimmed = sessionDir.appendingPathComponent("trimmed.mp4")
            var args = ["-hide_banner", "-y"]
            if let s = opts.trimStart { args += ["-ss", String(s)] }
            if let e = opts.trimEnd { args += ["-to", String(e)] }
            args += ["-i", master.path, "-c", "copy", "-avoid_negative_ts", "make_zero", trimmed.path]
            try Shell.runChecked("ffmpeg", args)
            source = trimmed
            notes.append("trim is stream-copy: cut points snap to ~\(Int(cfg.segmentSeconds))s keyframes")
        }

        let hasSys = keptRuns.first?.hasSystemAudio ?? false
        let hasMic = micUsable

        // 4. Final encode. Default: HEVC VideoToolbox constant quality, audio
        //    tracks mixed down to one AAC track for shareability.
        let final = sessionDir.appendingPathComponent("final.mp4")
        if opts.compress {
            var args = ["-hide_banner", "-y", "-i", source.path,
                        "-map", "0:v:0",
                        "-c:v", "hevc_videotoolbox", "-q:v", String(cfg.compressQuality),
                        "-tag:v", "hvc1"]
            if hasSys && hasMic {
                args += ["-filter_complex", "[0:a:0][0:a:1]amix=inputs=2:duration=longest:normalize=0[a]",
                         "-map", "[a]", "-c:a", "aac", "-b:a", "192k"]
            } else if hasSys || hasMic {
                args += ["-map", "0:a:0", "-c:a", "aac", "-b:a", "192k"]
            }
            args += ["-movflags", "+faststart", final.path]
            try Shell.runChecked("ffmpeg", args)
        } else {
            try? fm.removeItem(at: final)
            try fm.copyItem(at: source, to: final)
        }

        let duration = probeDuration(final) ?? 0

        // 5. Transcription from the mic track (falls back to system audio).
        var srt: String?, vtt: String?, txt: String?
        if opts.transcribe, hasMic || hasSys {
            if let model = cfg.resolveWhisperModel() {
                do {
                    let micTrackIndex = (hasSys && hasMic) ? 1 : 0
                    let wav = sessionDir.appendingPathComponent("speech16k.wav")
                    try Shell.runChecked("ffmpeg", [
                        "-hide_banner", "-y",
                        "-i", source.path,
                        "-map", "0:a:\(micTrackIndex)",
                        "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le",
                        wav.path,
                    ])
                    let outBase = sessionDir.appendingPathComponent("final").path
                    try Shell.runChecked("whisper-cli", [
                        "-m", model.path,
                        "-f", wav.path,
                        "-l", cfg.whisperLanguage,
                        "-osrt", "-ovtt", "-otxt",
                        "-of", outBase,
                    ])
                    try? fm.removeItem(at: wav)
                    let srtURL = sessionDir.appendingPathComponent("final.srt")
                    let vttURL = sessionDir.appendingPathComponent("final.vtt")
                    let txtURL = sessionDir.appendingPathComponent("final.txt")
                    srt = fm.fileExists(atPath: srtURL.path) ? srtURL.path : nil
                    vtt = fm.fileExists(atPath: vttURL.path) ? vttURL.path : nil
                    txt = fm.fileExists(atPath: txtURL.path) ? txtURL.path : nil
                } catch {
                    notes.append("transcription failed: \(error.localizedDescription)")
                }
            } else {
                notes.append("transcription skipped: no whisper model (run `mac-rec setup --whisper-model base`)")
            }
        }

        // 6. Optional GCS upload; share link lands on the clipboard.
        var shareURL: String?, gsURI: String?
        let wantUpload = opts.upload ?? (cfg.gcsBucket != nil)
        if wantUpload {
            if let bucket = cfg.gcsBucket {
                do {
                    let objectBase = "\(cfg.gcsPrefix)/\(meta.id)"
                    let dest = "gs://\(bucket)/\(objectBase).mp4"
                    try Shell.runChecked("gcloud", ["storage", "cp", final.path, dest])
                    if let s = srt {
                        _ = try? Shell.run("gcloud", ["storage", "cp", s, "gs://\(bucket)/\(objectBase).srt"])
                    }
                    if let v = vtt {
                        _ = try? Shell.run("gcloud", ["storage", "cp", v, "gs://\(bucket)/\(objectBase).vtt"])
                    }
                    gsURI = dest
                    let base = cfg.gcsPublicBase ?? "https://storage.googleapis.com/\(bucket)"
                    let url = "\(base)/\(objectBase).mp4"
                    shareURL = url
                    Shell.pbcopy(url)
                    notes.append("share link copied to clipboard")
                } catch {
                    notes.append("upload failed: \(error.localizedDescription)")
                }
            } else {
                notes.append("upload skipped: no gcsBucket configured (run `mac-rec setup --gcs-bucket NAME`)")
            }
        }

        // 7. Copy to a requested output path.
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
            srt: srt,
            vtt: vtt,
            transcript: txt,
            shareURL: shareURL,
            gsURI: gsURI,
            notes: notes
        )
    }

    /// init segment + media fragments byte-appended = a valid fragmented MP4.
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

    private func probeDuration(_ url: URL) -> Double? {
        guard let r = try? Shell.run("ffprobe", [
            "-v", "error",
            "-show_entries", "format=duration",
            "-of", "default=noprint_wrappers=1:nokey=1",
            url.path,
        ]), r.status == 0 else { return nil }
        return Double(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
