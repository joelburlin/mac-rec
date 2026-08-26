import AppKit

@MainActor
enum UIMain {
    private static var delegate: AppDelegate?

    static func boot() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)  // menu-bar only, no Dock icon
        let d = AppDelegate()
        delegate = d
        app.delegate = d
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let proxy = RecorderProxy()
    var statusBar: StatusBarController?
    var hud: HUDController?
    var hotkeys: HotkeyManager?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let statusBar = StatusBarController(proxy: proxy)
        let hud = HUDController(proxy: proxy)
        self.statusBar = statusBar
        self.hud = hud

        proxy.onChange = { [weak self] status in
            self?.statusBar?.update(status)
            self?.hud?.update(status)
        }
        proxy.onSaved = { [weak self] result in
            self?.hud?.finishedSaving()
            guard let result else { return }
            // Land the user on the deliverable.
            NSWorkspace.shared.activateFileViewerSelecting(
                [URL(fileURLWithPath: result.final)]
            )
        }

        let hotkeys = HotkeyManager(bindings: HotkeyMap.bindings)
        hotkeys.onAction = { [weak self] action in
            guard let self else { return }
            switch action {
            case .toggle: self.proxy.smartToggle()
            case .stop: if self.proxy.status.state != "idle" { self.proxy.stopAndSave() }
            case .rewind: if self.proxy.status.state != "idle" { self.proxy.rewind(seconds: 10) }
            case .area:
                guard self.proxy.status.state == "idle" else { return }
                let proxy = self.proxy
                AreaSelector.begin { selection in
                    guard let selection else { return }
                    proxy.startArea(displayID: selection.displayID, rect: selection.rect)
                }
            }
        }
        self.hotkeys = hotkeys

        proxy.ensureDaemon()  // spawn the daemon under this app's TCC identity
        proxy.startPolling()
    }
}
