import Foundation
import ArgumentParser

struct MacRec: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mac-rec",
        abstract: "Native macOS screen recorder with live-rewind, captions, and a local REST API.",
        version: macRecVersion,
        subcommands: [
            Start.self, Pause.self, Resume.self, Rewind.self, Stop.self,
            Status.self, ListSources.self, Serve.self, Setup.self,
            ShowConfig.self, Quit.self,
        ]
    )
}

// MARK: - Shared helpers

func withClient<T>(_ body: (DaemonClient) throws -> T) throws -> T {
    let client = DaemonClient(cfg: Config.load())
    try client.ensureRunning()
    return try body(client)
}

func printJSONOrText<T: Encodable>(_ value: T, json: Bool, text: () -> String) {
    if json {
        let data = (try? JSONEncoder.pretty.encode(value)) ?? Data()
        print(String(data: data, encoding: .utf8) ?? "{}")
    } else {
        print(text())
    }
}

func fmtDuration(_ s: Double) -> String {
    String(format: "%d:%05.2f", Int(s) / 60, s.truncatingRemainder(dividingBy: 60))
}

// MARK: - Recording commands

struct Start: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Start recording.")

    @Option(help: "Capture source: fullscreen | window | app.")
    var source: String = "fullscreen"

    @Option(help: "Display index for fullscreen (see `mac-rec list`). Default: main display.")
    var display: Int?

    @Option(help: "Window title / app name substring for window and app sources.")
    var query: String?

    @Flag(name: .customLong("no-mic"), help: "Skip microphone capture.")
    var noMic = false

    @Flag(name: .customLong("no-system-audio"), help: "Skip system audio capture.")
    var noSystemAudio = false

    @Option(help: "Optional session title (used in the session directory name).")
    var title: String?

    @Flag(help: "Print machine-readable JSON.")
    var json = false

    func run() throws {
        let opts = StartOptions(
            source: source,
            display: display,
            query: query,
            mic: !noMic,
            systemAudio: !noSystemAudio,
            title: title
        )
        let status = try withClient { try $0.post("/start", body: opts, as: StatusInfo.self, timeout: 30) }
        printJSONOrText(status, json: json) {
            "● recording \(status.source ?? "") — session \(status.sessionId ?? "?")\n  \(status.sessionDir ?? "")"
        }
    }
}

struct Pause: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Pause recording (enables rewind).")

    @Flag(help: "Print machine-readable JSON.")
    var json = false

    func run() throws {
        let status = try withClient { try $0.post("/pause", body: Optional<Int>.none, as: StatusInfo.self) }
        printJSONOrText(status, json: json) {
            "⏸ paused at \(fmtDuration(status.recordedSeconds)) (\(status.segmentCount) fragments kept)"
        }
    }
}

struct Resume: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Resume a paused recording.")

    @Flag(help: "Print machine-readable JSON.")
    var json = false

    func run() throws {
        let status = try withClient { try $0.post("/resume", body: Optional<Int>.none, as: StatusInfo.self, timeout: 30) }
        printJSONOrText(status, json: json) {
            "● resumed — \(fmtDuration(status.recordedSeconds)) kept so far"
        }
    }
}

struct Rewind: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "While paused, drop the last N seconds (fragment-granular, ~2s)."
    )

    @Argument(help: "Seconds to rewind.")
    var seconds: Double

    @Flag(help: "Print machine-readable JSON.")
    var json = false

    func run() throws {
        let r = try withClient { try $0.post("/rewind", body: RewindRequest(seconds: seconds), as: RewindResult.self) }
        printJSONOrText(r, json: json) {
            "⏪ dropped \(String(format: "%.1f", r.droppedSeconds))s "
            + "(\(r.droppedSegments) fragments) — \(fmtDuration(r.recordedSeconds)) kept"
        }
    }
}

struct Stop: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Stop and finalize: concat, compress, captions, optional upload."
    )

    @Option(help: "Copy the final video to this path.")
    var output: String?

    @Flag(name: .customLong("no-compress"), help: "Keep the lossless master as the final file.")
    var noCompress = false

    @Flag(name: .customLong("no-transcribe"), help: "Skip whisper captions.")
    var noTranscribe = false

    @Flag(name: .customLong("no-upload"), help: "Skip GCS upload even if a bucket is configured.")
    var noUpload = false

    @Flag(help: "Force GCS upload.")
    var upload = false

    @Option(name: .customLong("trim-start"), help: "Trim: drop everything before this second.")
    var trimStart: Double?

    @Option(name: .customLong("trim-end"), help: "Trim: drop everything after this second.")
    var trimEnd: Double?

    @Flag(help: "Print machine-readable JSON.")
    var json = false

    func run() throws {
        var uploadFlag: Bool?
        if upload { uploadFlag = true }
        if noUpload { uploadFlag = false }
        let opts = StopOptions(
            output: output.map { URL(fileURLWithPath: $0, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)).path },
            compress: !noCompress,
            transcribe: !noTranscribe,
            upload: uploadFlag,
            trimStart: trimStart,
            trimEnd: trimEnd
        )
        // Finalizing re-encodes + transcribes; allow plenty of time.
        let r = try withClient { try $0.post("/stop", body: opts, as: FinalResult.self, timeout: 1800) }
        printJSONOrText(r, json: json) {
            var lines = ["■ saved \(fmtDuration(r.durationSeconds)) — \(r.final)"]
            if let s = r.srt { lines.append("  captions: \(s)") }
            if let u = r.shareURL { lines.append("  share:    \(u) (on clipboard)") }
            lines.append(contentsOf: r.notes.map { "  note: \($0)" })
            return lines.joined(separator: "\n")
        }
    }
}

struct Status: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show recorder state.")

    @Flag(help: "Print machine-readable JSON.")
    var json = false

    func run() throws {
        let client = DaemonClient(cfg: Config.load())
        guard client.isRunning() else {
            printJSONOrText(
                StatusInfo(state: "idle", recordedSeconds: 0, liveSeconds: 0, segmentCount: 0, runCount: 0),
                json: json
            ) { "idle (daemon not running)" }
            return
        }
        let s = try client.get("/status", as: StatusInfo.self)
        printJSONOrText(s, json: json) {
            switch s.state {
            case "recording":
                return "● recording \(s.source ?? "") — \(fmtDuration(s.liveSeconds)) (session \(s.sessionId ?? "?"))"
            case "paused":
                return "⏸ paused — \(fmtDuration(s.recordedSeconds)) kept, \(s.segmentCount) fragments (session \(s.sessionId ?? "?"))"
            case "finalizing":
                return "⏳ finalizing session \(s.sessionId ?? "?")"
            default:
                return "idle"
            }
        }
    }
}

struct Quit: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Shut down the background daemon.")

    func run() throws {
        let client = DaemonClient(cfg: Config.load())
        guard client.isRunning() else {
            print("daemon not running")
            return
        }
        _ = try? client.post("/quit", body: Optional<Int>.none, as: [String: String].self, timeout: 5)
        for _ in 0..<20 {
            if !client.isRunning() { break }
            Thread.sleep(forTimeInterval: 0.2)
        }
        print("daemon stopped")
    }
}
