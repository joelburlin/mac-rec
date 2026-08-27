import AppKit
import AVFoundation
import ScreenCaptureKit

@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    private let proxy: RecorderProxy
    private let item: NSStatusItem
    private let menu = NSMenu()

    /// Persistent submenus whose contents are refreshed in place — the top
    /// menu must NEVER be rebuilt while open or hovered submenus vanish
    /// mid-click.
    private let displaysSubmenu = NSMenu()
    private let windowsSubmenu = NSMenu()
    private let micsSubmenu = NSMenu()
    private let captionsSubmenu = NSMenu()
    private let voiceSubmenu = NSMenu()
    private var menuOpen = false
    /// (id, name) ElevenLabs voices, fetched lazily on first menu open.
    private var voices: [(String, String)] = []
    private var voicesLoaded = false

    /// (index in SCShareableContent.displays order, label)
    private var displays: [(Int, String)] = []
    /// (CGWindowID, label)
    private var windows: [(UInt32, String)] = []
    /// (uniqueID, name)
    private var mics: [(String, String)] = []

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
        // Rebuilding an OPEN menu destroys hovered submenus mid-click.
        if !menuOpen {
            rebuildMenu(for: s)
        }
    }

    // MARK: - Menu lifecycle

    func menuWillOpen(_ menu: NSMenu) {
        menuOpen = true
        rebuildMenu(for: proxy.status)
        refreshLists()
    }

    func menuDidClose(_ menu: NSMenu) {
        menuOpen = false
    }

    private func rebuildMenu(for s: StatusInfo) {
        menu.removeAllItems()

        switch s.state {
        case "idle":
            menu.addItem(shortcut(makeItem("Record Full Screen", #selector(startMain)), .toggle))
            if displays.count > 1 {
                let holder = NSMenuItem(title: "Record Display", action: nil, keyEquivalent: "")
                holder.submenu = displaysSubmenu
                menu.addItem(holder)
            }
            menu.addItem(shortcut(makeItem("Record Area…", #selector(startArea)), .area))
            let winHolder = NSMenuItem(title: "Record Window", action: nil, keyEquivalent: "")
            winHolder.submenu = windowsSubmenu
            menu.addItem(winHolder)
            menu.addItem(.separator())
            menu.addItem(shortcut(disabled("Stop & Save"), .stop))
            menu.addItem(shortcut(disabled("Pause"), .toggle))
            menu.addItem(shortcut(disabled("Rewind 10s"), .rewind))
            menu.addItem(.separator())
            menu.addItem(check(makeItem("Capture Microphone", #selector(toggleMic)), "captureMic"))
            let micHolder = NSMenuItem(title: "Microphone", action: nil, keyEquivalent: "")
            micHolder.submenu = micsSubmenu
            menu.addItem(micHolder)
            menu.addItem(check(makeItem("Clean Mic Audio (denoise + level)", #selector(toggleCleanMic)), "cleanMic"))
            menu.addItem(check(makeItem("Capture System Audio", #selector(toggleSystemAudio)), "captureSystemAudio"))
            menu.addItem(.separator())
            let capHolder = NSMenuItem(title: "Captions", action: nil, keyEquivalent: "")
            capHolder.submenu = captionsSubmenu
            menu.addItem(capHolder)
            let voHolder = NSMenuItem(title: "AI Voiceover", action: nil, keyEquivalent: "")
            voHolder.submenu = voiceSubmenu
            menu.addItem(voHolder)
            addPermissionItems()

        case "recording":
            menu.addItem(disabled("Recording — \(fmtDuration(s.liveSeconds))  (\(s.source ?? ""))"))
            menu.addItem(.separator())
            menu.addItem(shortcut(makeItem("Stop & Save", #selector(stop)), .stop))
            menu.addItem(shortcut(makeItem("Pause", #selector(pause)), .toggle))
            menu.addItem(shortcut(makeItem("Rewind 10s (pauses)", #selector(rewind10)), .rewind))

        case "paused":
            menu.addItem(disabled("Paused — \(fmtDuration(s.recordedSeconds)) kept"))
            if let event = s.lastEvent {
                menu.addItem(disabled("⚠️ \(event)"))
            }
            menu.addItem(.separator())
            menu.addItem(shortcut(makeItem("Stop & Save", #selector(stop)), .stop))
            menu.addItem(shortcut(makeItem("Resume", #selector(resume)), .toggle))
            menu.addItem(shortcut(makeItem("Rewind 10s", #selector(rewind10)), .rewind))
            menu.addItem(makeItem("Rewind 30s", #selector(rewind30)))

        case "finalizing":
            menu.addItem(disabled("Saving… (compress + captions)"))

        default:
            break
        }

        menu.addItem(.separator())
        menu.addItem(makeItem("Open Recordings Folder", #selector(openFolder)))
        menu.addItem(disabled(
            "Hotkeys: \(HotkeyMap.display(.toggle)) record/pause · \(HotkeyMap.display(.area)) area · "
            + "\(HotkeyMap.display(.rewind)) rewind · \(HotkeyMap.display(.stop)) save"
        ))
        menu.addItem(.separator())
        menu.addItem(makeItem("Quit mac-rec UI", #selector(quit)))
    }

    // MARK: - Source/device lists (refreshed in place; safe while menu open)

    private func refreshLists() {
        refreshMics()
        loadVoicesIfNeeded()
        fillSubmenus()
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
                self.fillSubmenus()
            }
        }
    }

    private func refreshMics() {
        let devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        ).devices
        mics = devices.map { ($0.uniqueID, $0.localizedName) }
    }

    private func fillSubmenus() {
        displaysSubmenu.removeAllItems()
        for (idx, label) in displays {
            let it = NSMenuItem(title: label, action: #selector(startDisplay(_:)), keyEquivalent: "")
            it.target = self
            it.tag = idx
            displaysSubmenu.addItem(it)
        }

        windowsSubmenu.removeAllItems()
        if windows.isEmpty {
            windowsSubmenu.addItem(disabled("Scanning windows…"))
        }
        for (wid, label) in windows {
            let it = NSMenuItem(title: label, action: #selector(startWindow(_:)), keyEquivalent: "")
            it.target = self
            it.tag = Int(wid)
            windowsSubmenu.addItem(it)
        }

        micsSubmenu.removeAllItems()
        let selected = UserDefaults.standard.string(forKey: "micDeviceID")
        let def = NSMenuItem(title: "System Default", action: #selector(selectMic(_:)), keyEquivalent: "")
        def.target = self
        def.state = selected == nil ? .on : .off
        micsSubmenu.addItem(def)
        for (id, name) in mics {
            let it = NSMenuItem(title: name, action: #selector(selectMic(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = id
            it.state = selected == id ? .on : .off
            micsSubmenu.addItem(it)
        }

        // Captions: style templates + where they sit.
        captionsSubmenu.removeAllItems()
        let cfg = Config.load()
        let style = UserDefaults.standard.string(forKey: "captionStyle") ?? cfg.captionStyle
        captionsSubmenu.addItem(disabled("Burn into the video"))
        for name in Captions.styleNames {
            let title = name == "none" ? "Off (sidecar .srt only)" : name.capitalized
            let it = NSMenuItem(title: title, action: #selector(selectCaptionStyle(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = name
            it.state = style == name ? .on : .off
            captionsSubmenu.addItem(it)
        }
        captionsSubmenu.addItem(.separator())
        captionsSubmenu.addItem(disabled("Position"))
        for pos in ["bottom", "center", "top"] {
            let it = NSMenuItem(title: pos.capitalized, action: #selector(selectCaptionPosition(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = pos
            it.state = cfg.captionPosition == pos ? .on : .off
            captionsSubmenu.addItem(it)
        }

        // AI voiceover: on/off + voice picker.
        voiceSubmenu.removeAllItems()
        let voOn = UserDefaults.standard.bool(forKey: "voiceover")
        let toggle = NSMenuItem(title: "Replace narration with AI voice",
                                action: #selector(toggleVoiceover), keyEquivalent: "")
        toggle.target = self
        toggle.state = voOn ? .on : .off
        voiceSubmenu.addItem(toggle)
        voiceSubmenu.addItem(.separator())
        if cfg.resolveElevenKey() == nil {
            voiceSubmenu.addItem(disabled("Set a key: mac-rec setup --eleven-key env"))
        } else if voices.isEmpty {
            voiceSubmenu.addItem(disabled(voicesLoaded ? "No voices found" : "Loading voices…"))
        } else {
            for (id, name) in voices {
                let it = NSMenuItem(title: name, action: #selector(selectVoice(_:)), keyEquivalent: "")
                it.target = self
                it.representedObject = id
                it.state = cfg.elevenVoiceID == id ? .on : .off
                voiceSubmenu.addItem(it)
            }
        }
    }

    private func loadVoicesIfNeeded() {
        guard !voicesLoaded, let key = Config.load().resolveElevenKey() else { return }
        voicesLoaded = true
        DispatchQueue.global().async {
            let list = (try? ElevenLabs.listVoices(key: key)) ?? []
            let mapped = list.prefix(30).map { ($0.id, $0.name) }
            DispatchQueue.main.async {
                self.voices = Array(mapped)
                self.fillSubmenus()
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

    private func shortcut(_ it: NSMenuItem, _ action: HotkeyManager.Action) -> NSMenuItem {
        guard let hk = HotkeyMap.bindings[action] else { return it }
        it.keyEquivalent = hk.menuKeyEquivalent
        it.keyEquivalentModifierMask = hk.menuModifiers
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

    @objc private func pause() { proxy.pause() }
    @objc private func resume() { proxy.resume() }
    @objc private func rewind10() { proxy.rewind(seconds: 10) }
    @objc private func rewind30() { proxy.rewind(seconds: 30) }
    @objc private func stop() { proxy.stopAndSave() }

    @objc private func selectMic(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String {
            UserDefaults.standard.set(id, forKey: "micDeviceID")
            UserDefaults.standard.set(sender.title, forKey: "micDeviceName")
        } else {
            UserDefaults.standard.removeObject(forKey: "micDeviceID")
            UserDefaults.standard.removeObject(forKey: "micDeviceName")
        }
        fillSubmenus()
    }

    @objc private func selectCaptionStyle(_ sender: NSMenuItem) {
        guard let style = sender.representedObject as? String else { return }
        UserDefaults.standard.set(style, forKey: "captionStyle")
        var cfg = Config.load()
        cfg.captionStyle = style
        try? cfg.save()
        fillSubmenus()
    }

    @objc private func selectCaptionPosition(_ sender: NSMenuItem) {
        guard let pos = sender.representedObject as? String else { return }
        var cfg = Config.load()
        cfg.captionPosition = pos
        try? cfg.save()
        fillSubmenus()
    }

    @objc private func toggleVoiceover() {
        let cur = UserDefaults.standard.bool(forKey: "voiceover")
        UserDefaults.standard.set(!cur, forKey: "voiceover")
        fillSubmenus()
    }

    @objc private func selectVoice(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        var cfg = Config.load()
        cfg.elevenVoiceID = id
        cfg.elevenVoiceName = sender.title
        try? cfg.save()
        fillSubmenus()
    }

    @objc private func toggleMic() { flip("captureMic") }
    @objc private func toggleSystemAudio() { flip("captureSystemAudio") }
    @objc private func toggleCleanMic() { flip("cleanMic") }
    private func flip(_ k: String) {
        let cur = UserDefaults.standard.object(forKey: k) as? Bool ?? true
        UserDefaults.standard.set(!cur, forKey: k)
        if !menuOpen { rebuildMenu(for: proxy.status) }
    }

    @objc private func openFolder() {
        NSWorkspace.shared.open(Config.load().outputRootURL)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    @objc private func grantScreen() { Permissions.requestScreen(proxy: proxy) }
    @objc private func grantMic() { Permissions.requestMic() }
}
