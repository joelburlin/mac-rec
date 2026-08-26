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

    // MARK: - Polling

    func startPolling() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func refresh() {
        queue.async {
            let s: StatusInfo
            if self.client.isRunning(),
               let fetched = try? self.client.get("/status", as: StatusInfo.self, timeout: 3) {
                s = fetched
            } else {
                s = StatusInfo(state: "idle", recordedSeconds: 0, liveSeconds: 0,
                               segmentCount: 0, runCount: 0)
            }
            DispatchQueue.main.async {
                self.status = s
                self.onChange?(s)
            }
        }
    }

    // MARK: - Commands (fire and refresh; errors surface as alerts)

    func startRecording(display: Int?) {
        let opts = StartOptions(
            source: "fullscreen",
            display: display,
            mic: UserDefaults.standard.object(forKey: "captureMic") as? Bool ?? true,
            systemAudio: UserDefaults.standard.object(forKey: "captureSystemAudio") as? Bool ?? true,
            title: nil,
            excludeAppPIDs: [ProcessInfo.processInfo.processIdentifier]
        )
        run("start recording") {
            try self.client.ensureRunning()
            _ = try self.client.post("/start", body: opts, as: StatusInfo.self, timeout: 30)
        }
    }

    func pause() {
        run("pause") { _ = try self.client.post("/pause", body: Optional<Int>.none, as: StatusInfo.self) }
    }

    func resume() {
        run("resume") { _ = try self.client.post("/resume", body: Optional<Int>.none, as: StatusInfo.self, timeout: 30) }
    }

    /// Rewind; auto-pauses first when still recording.
    func rewind(seconds: Double) {
        run("rewind") {
            let s = try self.client.get("/status", as: StatusInfo.self)
            if s.state == "recording" {
                _ = try self.client.post("/pause", body: Optional<Int>.none, as: StatusInfo.self)
            }
            _ = try self.client.post("/rewind", body: RewindRequest(seconds: seconds), as: RewindResult.self)
        }
    }

    func stopAndSave() {
        queue.async {
            do {
                let result = try self.client.post(
                    "/stop", body: StopOptions(), as: FinalResult.self, timeout: 1800
                )
                DispatchQueue.main.async { self.onSaved?(result) }
            } catch {
                DispatchQueue.main.async {
                    self.onSaved?(nil)
                    Self.showError("stop & save failed", error)
                }
            }
            self.refresh()
        }
        refresh()
    }

    /// One hotkey drives the whole flow: idle → start, recording → pause,
    /// paused → resume.
    func smartToggle() {
        switch status.state {
        case "idle": startRecording(display: nil)
        case "recording": pause()
        case "paused": resume()
        default: break
        }
    }

    func ensureDaemon() {
        queue.async { try? self.client.ensureRunning() }
    }

    private func run(_ label: String, _ body: @escaping () throws -> Void) {
        queue.async {
            do {
                try body()
            } catch {
                DispatchQueue.main.async { Self.showError(label + " failed", error) }
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
