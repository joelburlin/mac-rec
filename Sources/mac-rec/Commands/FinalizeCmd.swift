import Foundation
import ArgumentParser

/// Re-run the finalize pipeline on a session directory whose fragments are
/// still on disk — the rescue path when a `stop` failed (or after a crash).
/// Runs in-process; the daemon is not involved.
struct FinalizeCmd: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "finalize",
        abstract: "Rebuild deliverables from a session's on-disk fragments (rescue a failed stop)."
    )

    @Argument(help: "Session directory, or a session id under the output root.")
    var session: String

    @Option(help: "Copy the final video to this path.")
    var output: String?

    @Flag(name: .customLong("no-compress"), help: "Keep the lossless master as the final file.")
    var noCompress = false

    @Flag(name: .customLong("no-transcribe"), help: "Skip whisper captions.")
    var noTranscribe = false

    @Flag(name: .customLong("no-upload"), help: "Skip GCS upload even if a bucket is configured.")
    var noUpload = false

    @Option(name: .customLong("trim-start"), help: "Trim: drop everything before this second.")
    var trimStart: Double?

    @Option(name: .customLong("trim-end"), help: "Trim: drop everything after this second.")
    var trimEnd: Double?

    @Flag(help: "Print machine-readable JSON.")
    var json = false

    func run() throws {
        let cfg = Config.load()
        let fm = FileManager.default

        var dir = URL(fileURLWithPath: (session as NSString).expandingTildeInPath,
                      relativeTo: URL(fileURLWithPath: fm.currentDirectoryPath)).standardizedFileURL
        if !fm.fileExists(atPath: dir.appendingPathComponent("meta.json").path) {
            dir = cfg.outputRootURL.appendingPathComponent(session, isDirectory: true)
        }
        let metaURL = dir.appendingPathComponent("meta.json")
        guard let data = try? Data(contentsOf: metaURL) else {
            throw ValidationError("no meta.json at \(dir.path) — not a mac-rec session")
        }
        let meta = try JSONDecoder.api.decode(SessionMeta.self, from: data)
        guard meta.segmentCount > 0 else {
            throw ValidationError("session \(meta.id) has no kept fragments")
        }

        let opts = StopOptions(
            output: output.map {
                URL(fileURLWithPath: $0, relativeTo: URL(fileURLWithPath: fm.currentDirectoryPath)).path
            },
            compress: !noCompress,
            transcribe: !noTranscribe,
            upload: noUpload ? false : nil,
            trimStart: trimStart,
            trimEnd: trimEnd
        )
        let r = try Finalizer(cfg: cfg).finalize(meta: meta, sessionDir: dir, opts: opts)

        var updated = meta
        updated.state = "done"
        try? JSONEncoder.pretty.encode(updated).write(to: metaURL)

        printJSONOrText(r, json: json) {
            var lines = ["■ saved \(fmtDuration(r.durationSeconds)) — \(r.final)"]
            if let s = r.srt { lines.append("  captions: \(s)") }
            if let u = r.shareURL { lines.append("  share:    \(u) (on clipboard)") }
            lines.append(contentsOf: r.notes.map { "  note: \($0)" })
            return lines.joined(separator: "\n")
        }
    }
}
