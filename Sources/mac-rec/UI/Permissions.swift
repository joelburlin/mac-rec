import AppKit
import AVFoundation
import CoreGraphics

/// Permission state + repair flows for the two TCC grants the recorder needs.
/// Both the UI and the daemon it spawns resolve to the same responsible app
/// (Mac-Rec.app), so checks made here reflect what the daemon can do.
@MainActor
enum Permissions {
    static var screenGranted: Bool { CGPreflightScreenCaptureAccess() }
    static var micGranted: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    private static var pollTimer: Timer?

    /// Ask for Screen Recording: fires the system prompt when possible, opens
    /// the Settings pane, and polls until granted — then restarts the daemon
    /// (screen TCC only applies to freshly launched processes).
    static func requestScreen(proxy: RecorderProxy) {
        if CGRequestScreenCaptureAccess() {
            proxy.restartDaemon()
            return
        }
        openPane("Privacy_ScreenCapture")
        pollTimer?.invalidate()
        var ticks = 0
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { t in
            ticks += 1
            if CGPreflightScreenCaptureAccess() {
                t.invalidate()
                DispatchQueue.main.async { proxy.restartDaemon() }
            } else if ticks > 90 {  // give up after ~3 minutes
                t.invalidate()
            }
        }
    }

    /// Ask for Microphone: native prompt when undecided, Settings pane when
    /// previously denied. Mic TCC applies to new capture sessions immediately,
    /// so no daemon restart is needed.
    static func requestMic() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        case .denied, .restricted:
            openPane("Privacy_Microphone")
        default:
            break
        }
    }

    static func openPane(_ anchor: String) {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
        NSWorkspace.shared.open(url)
    }
}
