import AppKit
import Foundation

/// UI-side gateway to the daemon: serializes all HTTP calls off the main
/// thread, polls /status once a second, and publishes changes to the UI.
final class RecorderProxy {
    private let queue = DispatchQueue(label: "mac-rec.ui.client")
    private let client = DaemonClient(cfg: Config.load())
    private let cfg = Config.load()

    /// Last known daemon state; read/written on the main thread only.
    private(set) var status = StatusInfo(
        state: "idle", recordedSeconds: 0, liveSeconds: 0, segmentCount: 0, runCount: 0
    )
    /// Fired on the main thread whenever fresh status arrives.
    var onChange: ((StatusInfo) -> Void)?
    /// Fired on the main thread when a stop completes (nil body on failure).
    var onSaved: ((FinalResult?) -> Void)?

    private var timer: Timer?
    /// Tracks reachability transitions so ui.log records them exactly once.
    private var daemonReachable: Bool?

    // MARK: - Polling

    func startPolling() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func refresh() {
        queue.async {
            var s = StatusInfo(state: "idle", recordedSeconds: 0, liveSeconds: 0,
                               segmentCount: 0, runCount: 0)
            do {
                s = try self.client.get("/status", as: StatusInfo.self, timeout: 3)
                if self.daemonReachable != true {
                    self.daemonReachable = true
                    Self.uiLog("daemon reachable (state=\(s.state))")
                }
            } catch {
                if self.daemonReachable != false {
                    self.daemonReachable = false
                    Self.uiLog("status fetch FAILED: \(error.localizedDescription)")
                }
            }
            DispatchQueue.main.async {
                self.status = s
                self.onChange?(s)
            }
        }
    }

    /// Breadcrumbs for the bundled app, whose stderr goes nowhere useful.
    static func uiLog(_ msg: String) {
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(msg)\n"
        let url = Config.configDir.appendingPathComponent("ui.log")
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(Data(line.utf8))
            try? h.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    // MARK: - Commands (fire and refresh; errors surface as alerts)

    private func baseOptions() -> StartOptions {
        var opts = StartOptions()
        opts.mic = UserDefaults.standard.object(forKey: "captureMic") as? Bool ?? true
        opts.systemAudio = UserDefaults.standard.object(forKey: "captureSystemAudio") as? Bool ?? true
        opts.excludeAppPIDs = [ProcessInfo.processInfo.processIdentifier]
        return opts
    }

    /// Screen-recording TCC gate: opens the repair flow instead of letting the
    /// daemon fail with an opaque SCK error.
    @MainActor
    private func preflight() -> Bool {
        guard Permissions.screenGranted else {
            let alert = NSAlert()
            alert.messageText = "Mac-Rec needs Screen Recording permission"
            alert.informativeText = "Enable Mac-Rec in System Settings → Privacy & Security → Screen & System Audio Recording. The recorder restarts itself once granted."
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn {
                Permissions.requestScreen(proxy: self)
            }
            return false
        }
        if opts_micEnabled() && !Permissions.micGranted {
            Permissions.requestMic()  // native prompt / settings; recording proceeds without blocking
        }
        return true
    }

    private func opts_micEnabled() -> Bool {
        UserDefaults.standard.object(forKey: "captureMic") as? Bool ?? true
    }

    @MainActor
    func startRecording(display: Int?) {
        guard preflight() else { return }
        var opts = baseOptions()
        opts.display = display
        start(opts)
    }

    @MainActor
    func startWindow(windowID: UInt32) {
        guard preflight() else { return }
        var opts = baseOptions()
        opts.source = "window"
        opts.windowID = windowID
        start(opts)
    }

    @MainActor
    func startArea(displayID: UInt32, rect: CGRect) {
        guard preflight() else { return }
        var opts = baseOptions()
        opts.displayID = displayID
        opts.area = AreaRect(
            x: rect.origin.x, y: rect.origin.y,
            width: rect.width, height: rect.height
        )
        start(opts)
    }

    private func start(_ opts: StartOptions) {
        run("start recording") {
            try self.client.ensureRunning()
            _ = try self.client.post("/start", body: opts, as: StatusInfo.self, timeout: 30)
        }
    }

    /// Quit + respawn the daemon (used after a Screen Recording grant, which
    /// only applies to freshly launched processes). No-op mid-recording.
    func restartDaemon() {
        queue.async {
            if let st = try? self.client.get("/status", as: StatusInfo.self, timeout: 3),
               st.state != "idle" { return }
            _ = try? self.client.post("/quit", body: Optional<Int>.none, as: [String: String].self, timeout: 5)
            for _ in 0..<20 {
                if !self.client.isRunning() { break }
                Thread.sleep(forTimeInterval: 0.2)
            }
            try? self.client.ensureRunning()
            self.refresh()
        }
    }

    func pause() {
        run("pause") { _ = try self.client.post("/pause", body: Optional<Int>.none, as: StatusInfo.self) }
    }

    func resume() {
        run("resume") { _ = try self.client.post("/resume", body: Optional<Int>.none, as: StatusInfo.self, timeout: 30) }
    }

    /// Rewind; auto-pauses first when still recording.
    func rewind(seconds: Double, quiet: Bool = false) {
        run("rewind", quiet: quiet) {
            let s = try self.client.get("/status", as: StatusInfo.self)
            if s.state == "recording" {
                _ = try self.client.post("/pause", body: Optional<Int>.none, as: StatusInfo.self)
            }
            _ = try self.client.post("/rewind", body: RewindRequest(seconds: seconds), as: RewindResult.self)
        }
    }

    /// `quietIfIdle` suppresses the "nothing to stop" alert so the stop hotkey
    /// can always fire the request without trusting cached state.
    func stopAndSave(quietIfIdle: Bool = false) {
        queue.async {
            do {
                let result = try self.client.post(
                    "/stop", body: StopOptions(), as: FinalResult.self, timeout: 1800
                )
                DispatchQueue.main.async { self.onSaved?(result) }
            } catch {
                let benign = (error as? APIError)?.status == 409
                DispatchQueue.main.async {
                    self.onSaved?(nil)
                    if !(quietIfIdle && benign) {
                        Self.showError("stop & save failed", error)
                    }
                }
            }
            self.refresh()
        }
        refresh()
    }

    /// One hotkey drives the whole flow: idle → start, recording → pause,
    /// paused → resume. State is fetched fresh from the daemon, never trusted
    /// from the poll cache.
    @MainActor
    func smartToggle() {
        guard preflight() else { return }
        let opts = baseOptions()
        queue.async {
            let state = (try? self.client.get("/status", as: StatusInfo.self, timeout: 3))?.state ?? "idle"
            do {
                switch state {
                case "recording":
                    _ = try self.client.post("/pause", body: Optional<Int>.none, as: StatusInfo.self)
                case "paused":
                    _ = try self.client.post("/resume", body: Optional<Int>.none, as: StatusInfo.self, timeout: 30)
                case "finalizing":
                    break
                default:
                    try self.client.ensureRunning()
                    _ = try self.client.post("/start", body: opts, as: StatusInfo.self, timeout: 30)
                }
            } catch {
                DispatchQueue.main.async { Self.showError("record toggle failed", error) }
            }
            self.refresh()
        }
    }

    func ensureDaemon() {
        queue.async { try? self.client.ensureRunning() }
    }

    private func run(_ label: String, quiet: Bool = false, _ body: @escaping () throws -> Void) {
        queue.async {
            do {
                try body()
            } catch {
                let benign = (error as? APIError)?.status == 409
                if !(quiet && benign) {
                    DispatchQueue.main.async { Self.showError(label + " failed", error) }
                }
            }
            self.refresh()
        }
    }

    static func showError(_ title: String, _ error: Error) {
        let alert = NSAlert()
        alert.messageText = "mac-rec: \(title)"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
