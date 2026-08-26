import Foundation

/// The daemon's recording state machine. One recording session at a time;
/// each record→pause cycle is a "run" (its own fragment directory), rewind
/// deletes trailing fragments, stop hands everything to the Finalizer.
actor RecorderController {
    enum State: String {
        case idle, recording, paused, finalizing
    }

    private let cfg: Config
    private(set) var state: State = .idle
    private var meta: SessionMeta?
    private var sessionDir: URL?
    private var engine: CaptureEngine?
    private var runIndex = 0

    init(cfg: Config) {
        self.cfg = cfg
    }

    // MARK: - Commands

    func start(_ opts: StartOptions) async throws -> StatusInfo {
        guard state == .idle else {
            throw APIError(409, "already \(state.rawValue) (session \(meta?.id ?? "?")) — stop it first")
        }

        let stamp = Self.timestamp()
        let slug = (opts.title?.isEmpty == false) ? "-" + Self.slugify(opts.title!) : ""
        let id = stamp + slug
        let dir = cfg.outputRootURL.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("runs", isDirectory: true),
            withIntermediateDirectories: true
        )

        var m = SessionMeta(id: id, createdAt: Date(), state: "recording", options: opts, fps: cfg.fps)
        runIndex = 0
        let eng = try await launchRun(opts: opts, sessionDir: dir)
        m.width = eng.width
        m.height = eng.height

        meta = m
        sessionDir = dir
        state = .recording
        try persistMeta()
        log("session \(id) started: \(eng.sourceDescription) \(eng.width)x\(eng.height)@\(cfg.fps)")
        return statusInfo()
    }

    func pause() async throws -> StatusInfo {
        guard state == .recording else { throw APIError(409, "not recording (state=\(state.rawValue))") }
        try await endCurrentRun()
        state = .paused
        meta?.state = "paused"
        try persistMeta()
        return statusInfo()
    }

    func resume() async throws -> StatusInfo {
        guard state == .paused else { throw APIError(409, "not paused (state=\(state.rawValue))") }
        guard let dir = sessionDir, let opts = meta?.options else { throw APIError(500, "no session") }
        _ = try await launchRun(opts: opts, sessionDir: dir)
        state = .recording
        meta?.state = "recording"
        try persistMeta()
        return statusInfo()
    }

    func rewind(seconds: Double) throws -> RewindResult {
        guard state == .paused else {
            throw APIError(409, "rewind requires paused state (state=\(state.rawValue)) — pause first")
        }
        guard var m = meta, let dir = sessionDir, seconds > 0 else {
            throw APIError(400, "nothing to rewind")
        }

        var remaining = seconds
        var droppedSeconds = 0.0
        var droppedCount = 0
        let fm = FileManager.default

        outer: while remaining > 0 {
            guard let runIdx = m.runs.lastIndex(where: { !$0.segments.isEmpty }) else { break outer }
            let runDir = dir.appendingPathComponent("runs/\(m.runs[runIdx].name)", isDirectory: true)
            while remaining > 0, let seg = m.runs[runIdx].segments.last {
                m.runs[runIdx].segments.removeLast()
                try? fm.removeItem(at: runDir.appendingPathComponent(seg.file))
                remaining -= seg.duration
                droppedSeconds += seg.duration
                droppedCount += 1
            }
        }

        meta = m
        try persistMeta()
        log("rewound \(String(format: "%.1f", droppedSeconds))s (\(droppedCount) fragments)")
        return RewindResult(
            droppedSeconds: droppedSeconds,
            droppedSegments: droppedCount,
            recordedSeconds: m.recordedSeconds
        )
    }

    func stop(_ opts: StopOptions) async throws -> FinalResult {
        switch state {
        case .idle: throw APIError(409, "nothing to stop")
        case .finalizing: throw APIError(409, "already finalizing")
        case .recording: try await endCurrentRun()
        case .paused: break
        }
        guard let m = meta, let dir = sessionDir else { throw APIError(500, "no session") }
        guard m.recordedSeconds > 0.05, m.segmentCount > 0 else {
            state = .idle
            meta = nil
            sessionDir = nil
            throw APIError(409, "session has no recorded footage (all rewound or capture failed) — nothing to save")
        }

        state = .finalizing
        meta?.state = "finalizing"
        try persistMeta()
        do {
            let result = try Finalizer(cfg: cfg).finalize(meta: m, sessionDir: dir, opts: opts)
            meta?.state = "done"
            try persistMeta()
            state = .idle
            meta = nil
            sessionDir = nil
            return result
        } catch {
            meta?.state = "failed"
            try? persistMeta()
            state = .idle
            // Keep meta/sessionDir cleared but the fragments stay on disk for rescue.
            let dirPath = dir.path
            meta = nil
            sessionDir = nil
            throw APIError(500, "finalize failed: \(error.localizedDescription) (fragments kept in \(dirPath))")
        }
    }

    func status() -> StatusInfo { statusInfo() }

    // MARK: - Internals

    private func launchRun(opts: StartOptions, sessionDir: URL) async throws -> CaptureEngine {
        runIndex += 1
        let runName = String(format: "run-%03d", runIndex)
        let runDir = sessionDir.appendingPathComponent("runs/\(runName)", isDirectory: true)
        let eng = CaptureEngine(runDir: runDir, runName: runName, cfg: cfg, opts: opts)
        try await eng.start()
        engine = eng
        return eng
    }

    private func endCurrentRun() async throws {
        guard let eng = engine else { return }
        let run = try await eng.stop()
        engine = nil
        if !run.segments.isEmpty {
            meta?.runs.append(run)
        } else {
            log("run \(run.name) produced no segments; dropping")
        }
    }

    private func statusInfo() -> StatusInfo {
        let recorded = meta?.recordedSeconds ?? 0
        var live = recorded
        if state == .recording, let eng = engine {
            live += Date().timeIntervalSince(eng.startedAt)
        }
        return StatusInfo(
            state: state.rawValue,
            sessionId: meta?.id,
            sessionDir: sessionDir?.path,
            source: engine?.sourceDescription ?? meta?.options.source,
            recordedSeconds: recorded,
            liveSeconds: live,
            segmentCount: meta?.segmentCount ?? 0,
            runCount: meta?.runs.count ?? 0
        )
    }

    private func persistMeta() throws {
        guard let meta, let sessionDir else { return }
        let url = sessionDir.appendingPathComponent("meta.json")
        try JSONEncoder.pretty.encode(meta).write(to: url)
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: Date())
    }

    private static func slugify(_ s: String) -> String {
        let lowered = s.lowercased()
        let allowed = CharacterSet.alphanumerics
        var out = ""
        for scalar in lowered.unicodeScalars {
            out.append(allowed.contains(scalar) ? Character(scalar) : "-")
        }
        while out.contains("--") { out = out.replacingOccurrences(of: "--", with: "-") }
        return out.trimmingCharacters(in: CharacterSet(charactersIn: "-")).prefix(40).description
    }
}
