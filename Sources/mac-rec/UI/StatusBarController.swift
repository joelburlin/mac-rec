import AppKit
import ScreenCaptureKit

@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    private let proxy: RecorderProxy
    private let item: NSStatusItem
    private let menu = NSMenu()
    /// (index in SCShareableContent.displays order, label) — refreshed on menu open.
    private var displays: [(Int, String)] = []
    /// (CGWindowID, label) — refreshed on menu open.
    private var windows: [(UInt32, String)] = []

    init(proxy: RecorderProxy) {
        self.proxy = proxy
        self.item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        menu.delegate = self
        item.menu = menu
        update(proxy.status)
    }

    // MARK: - Status item appearance

    func update(_ s: StatusInfo) {
        guard let button = item.button else { return }
        let (symbol, tint, title): (String, NSColor?, String)
        switch s.state {
        case "recording":
            (symbol, tint, title) = ("record.circle.fill", .systemRed, " " + fmtDuration(s.liveSeconds))
        case "paused":
            (symbol, tint, title) = ("pause.circle.fill", .systemOrange, " " + fmtDuration(s.recordedSeconds))
        case "finalizing":
            (symbol, tint, title) = ("arrow.triangle.2.circlepath.circle.fill", .systemBlue, " saving…")
        default:
            (symbol, tint, title) = ("record.circle", nil, "")
        }
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "mac-rec")
        button.contentTintColor = tint
        button.attributedTitle = NSAttributedString(
            string: title,
            attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)]
        )
        rebuildMenu(for: s)
    }

    // MARK: - Menu

    func menuWillOpen(_ menu: NSMenu) {
        refreshDisplays()
        rebuildMenu(for: proxy.status)
    }

    private func rebuildMenu(for s: StatusInfo) {
        menu.removeAllItems()

        switch s.state {
        case "idle":
            menu.addItem(key(makeItem("Record Full Screen", #selector(startMain)), "r"))
            if displays.count > 1 {
                let sub = NSMenu()
                for (idx, label) in displays {
                    let it = NSMenuItem(title: label, action: #selector(startDisplay(_:)), keyEquivalent: "")
                    it.target = self
                    it.tag = idx
                    sub.addItem(it)
                }
                let holder = NSMenuItem(title: "Record Display", action: nil, keyEquivalent: "")
                holder.submenu = sub
                menu.addItem(holder)
            }
            menu.addItem(key(makeItem("Record Area…", #selector(startArea)), "a"))
            if !windows.isEmpty {
                let sub = NSMenu()
                for (wid, label) in windows {
                    let it = NSMenuItem(title: label, action: #selector(startWindow(_:)), keyEquivalent: "")
                    it.target = self
                    it.tag = Int(wid)
                    sub.addItem(it)
                }
                let holder = NSMenuItem(title: "Record Window", action: nil, keyEquivalent: "")
                holder.submenu = sub
                menu.addItem(holder)
            }
            menu.addItem(.separator())
            menu.addItem(check(makeItem("Capture Microphone", #selector(toggleMic)), "captureMic"))
            menu.addItem(check(makeItem("Capture System Audio", #selector(toggleSystemAudio)), "captureSystemAudio"))
            addPermissionItems()

        case "recording":
            menu.addItem(disabled("Recording — \(fmtDuration(s.liveSeconds))  (\(s.source ?? ""))"))
            menu.addItem(.separator())
            menu.addItem(key(makeItem("Pause", #selector(pause)), "r"))
            menu.addItem(key(makeItem("Rewind 10s (pauses)", #selector(rewind10)), String(UnicodeScalar(NSLeftArrowFunctionKey)!)))
            menu.addItem(key(makeItem("Stop & Save", #selector(stop)), "s"))

        case "paused":
            menu.addItem(disabled("Paused — \(fmtDuration(s.recordedSeconds)) kept"))
            menu.addItem(.separator())
            menu.addItem(key(makeItem("Resume", #selector(resume)), "r"))
            menu.addItem(key(makeItem("Rewind 10s", #selector(rewind10)), String(UnicodeScalar(NSLeftArrowFunctionKey)!)))
            menu.addItem(makeItem("Rewind 30s", #selector(rewind30)))
            menu.addItem(key(makeItem("Stop & Save", #selector(stop)), "s"))

        case "finalizing":
            menu.addItem(disabled("Saving… (compress + captions)"))

        default:
            break
        }

        menu.addItem(.separator())
        menu.addItem(makeItem("Open Recordings Folder", #selector(openFolder)))
        menu.addItem(disabled("Hotkeys: ⌃⌥⌘R record/pause · ⌃⌥⌘A area · ⌃⌥⌘← rewind · ⌃⌥⌘S save"))
        menu.addItem(.separator())
        menu.addItem(makeItem("Quit mac-rec UI", #selector(quit)))
    }

    private func refreshDisplays() {
        Task {
            guard let content = try? await SCShareableContent
                .excludingDesktopWindows(false, onScreenWindowsOnly: true) else { return }
            let displayList = content.displays.enumerated().map { (i, d) in
                (i, "Display \(i + 1) — \(d.width)×\(d.height)\(d.displayID == CGMainDisplayID() ? " (main)" : "")")
            }
            let ownPID = ProcessInfo.processInfo.processIdentifier
            let windowList = content.windows
                .filter {
                    $0.isOnScreen && $0.frame.width >= 200 && $0.frame.height >= 150
                        && $0.owningApplication?.processID != ownPID
                        && $0.title?.isEmpty == false
                }
                .sorted { ($0.owningApplication?.applicationName ?? "") < ($1.owningApplication?.applicationName ?? "") }
                .prefix(20)
                .map { w in
                    (w.windowID, "\(w.owningApplication?.applicationName ?? "?") — \(shorten(w.title ?? ""))")
                }
            await MainActor.run {
                self.displays = displayList
                self.windows = Array(windowList)
                // Live-update the open menu so submenus appear on first click.
                self.rebuildMenu(for: self.proxy.status)
            }
        }
    }

    private nonisolated func shorten(_ s: String) -> String {
        s.count > 45 ? String(s.prefix(44)) + "…" : s
    }

    private func addPermissionItems() {
        let needScreen = !Permissions.screenGranted
        let needMic = !Permissions.micGranted
            && (UserDefaults.standard.object(forKey: "captureMic") as? Bool ?? true)
        guard needScreen || needMic else { return }
        menu.addItem(.separator())
        if needScreen {
            menu.addItem(makeItem("⚠️ Grant Screen Recording…", #selector(grantScreen)))
        }
        if needMic {
            menu.addItem(makeItem("⚠️ Grant Microphone…", #selector(grantMic)))
        }
    }

    // MARK: - Item helpers

    private func makeItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: "")
        it.target = self
        return it
    }

    private func key(_ it: NSMenuItem, _ k: String) -> NSMenuItem {
        it.keyEquivalent = k
        it.keyEquivalentModifierMask = [.control, .option, .command]
        return it
    }

    private func check(_ it: NSMenuItem, _ defaultsKey: String) -> NSMenuItem {
        let on = UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true
        it.state = on ? .on : .off
        it.representedObject = defaultsKey
        return it
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        it.isEnabled = false
        return it
    }

    // MARK: - Actions

    @objc private func startMain() { proxy.startRecording(display: nil) }
    @objc private func startDisplay(_ sender: NSMenuItem) { proxy.startRecording(display: sender.tag) }
    @objc private func startWindow(_ sender: NSMenuItem) { proxy.startWindow(windowID: UInt32(sender.tag)) }

    @objc private func startArea() {
        let proxy = self.proxy
        AreaSelector.begin { selection in
            guard let selection else { return }
            proxy.startArea(displayID: selection.displayID, rect: selection.rect)
        }
    }

    @objc private func grantScreen() { Permissions.requestScreen(proxy: proxy) }
    @objc private func grantMic() { Permissions.requestMic() }
    @objc private func pause() { proxy.pause() }
    @objc private func resume() { proxy.resume() }
    @objc private func rewind10() { proxy.rewind(seconds: 10) }
    @objc private func rewind30() { proxy.rewind(seconds: 30) }
    @objc private func stop() { proxy.stopAndSave() }

    @objc private func toggleMic() { flip("captureMic") }
    @objc private func toggleSystemAudio() { flip("captureSystemAudio") }
    private func flip(_ k: String) {
        let cur = UserDefaults.standard.object(forKey: k) as? Bool ?? true
        UserDefaults.standard.set(!cur, forKey: k)
    }

    @objc private func openFolder() {
        NSWorkspace.shared.open(Config.load().outputRootURL)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
