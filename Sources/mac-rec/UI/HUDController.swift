import AppKit

/// The floating recording pill — the primary control surface (a crowded menu
/// bar can silently hide the status item, so the pill must stand alone).
///
///   idle:       ● ready   [⏺] [▧ area] [✕]
///   recording:  ● 0:42    [⏸] [⏪] [■]
///   paused:     ● 0:42    [▶] [⏪] [■]
///
/// Non-activating, floats over everything, draggable, excluded from the
/// capture itself (the daemon filters this app's pid out of display filters).
@MainActor
final class HUDController {
    private let proxy: RecorderProxy
    private let panel: NSPanel
    private let dot = NSTextField(labelWithString: "●")
    private let timeLabel = NSTextField(labelWithString: "ready")
    private let button1 = NSButton()   // record / pause / resume
    private let button2 = NSButton()   // area (idle) / rewind
    private let button3 = NSButton()   // hide (idle) / stop
    private var lastState = ""
    /// Set by the ✕ button; cleared when a recording starts.
    private var userHidden = false

    init(proxy: RecorderProxy) {
        self.proxy = proxy

        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 230, height: 44),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.isMovableByWindowBackground = true
        panel.becomesKeyOnlyIfNeeded = true

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.masksToBounds = true
        panel.contentView = effect

        dot.font = NSFont.systemFont(ofSize: 14, weight: .bold)
        dot.textColor = .systemRed

        timeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 14, weight: .semibold)
        timeLabel.textColor = .labelColor

        for b in [button1, button2, button3] {
            b.isBordered = false
            b.bezelStyle = .regularSquare
            b.imagePosition = .imageOnly
            b.contentTintColor = .labelColor
            b.target = self
        }
        button1.action = #selector(primaryAction)
        button2.action = #selector(secondaryAction)
        button3.action = #selector(tertiaryAction)

        let stack = NSStackView(views: [dot, timeLabel, button1, button2, button3])
        stack.orientation = .horizontal
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            stack.topAnchor.constraint(equalTo: effect.topAnchor),
            stack.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
    }

    private func setImage(_ button: NSButton, _ symbol: String, tint: NSColor = .labelColor, tip: String) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))
        button.contentTintColor = tint
        button.toolTip = tip
    }

    // MARK: - State

    func update(_ s: StatusInfo) {
        if s.state != "idle" { userHidden = false }
        switch s.state {
        case "recording":
            // A new recording may target a different display — move to it.
            if lastState != "recording", panel.isVisible {
                centerBottom(on: screenBeingRecorded())
            }
            dot.textColor = .systemRed
            timeLabel.stringValue = fmtDuration(s.liveSeconds)
            setImage(button1, "pause.fill", tip: "Pause (\(HotkeyMap.display(.toggle)))")
            setImage(button2, "gobackward.10", tip: "Rewind 10s (\(HotkeyMap.display(.rewind)))")
            setImage(button3, "stop.fill", tip: "Stop & Save (\(HotkeyMap.display(.stop)))")
            setEnabled(true)
            show(reason: "recording")
        case "paused":
            dot.textColor = .systemOrange
            timeLabel.stringValue = fmtDuration(s.recordedSeconds)
            setImage(button1, "play.fill", tip: "Resume (\(HotkeyMap.display(.toggle)))")
            setImage(button2, "gobackward.10", tip: "Rewind 10s (\(HotkeyMap.display(.rewind)))")
            setImage(button3, "stop.fill", tip: "Stop & Save (\(HotkeyMap.display(.stop)))")
            setEnabled(true)
            show(reason: "paused")
        case "finalizing":
            dot.textColor = .systemBlue
            timeLabel.stringValue = "saving…"
            setEnabled(false)
            show(reason: "finalizing")
        default:  // idle — the pill doubles as the launcher
            if userHidden {
                panel.orderOut(nil)
            } else {
                dot.textColor = .tertiaryLabelColor
                timeLabel.stringValue = "ready"
                setImage(button1, "record.circle", tint: .systemRed,
                         tip: "Record full screen (\(HotkeyMap.display(.toggle)))")
                setImage(button2, "rectangle.dashed",
                         tip: "Record area (\(HotkeyMap.display(.area)))")
                setImage(button3, "xmark", tip: "Hide until next recording")
                setEnabled(true)
                show(reason: "idle")
            }
        }
        lastState = s.state
    }

    func finishedSaving() {
        // Falls back to the idle pill on the next poll.
    }

    private func setEnabled(_ enabled: Bool) {
        button1.isEnabled = enabled
        button2.isEnabled = enabled
        button3.isEnabled = enabled
    }

    private func show(reason: String) {
        guard !panel.isVisible else { return }
        let screen = screenBeingRecorded()
        centerBottom(on: screen)
        panel.orderFrontRegardless()
        RecorderProxy.uiLog(
            "HUD show (\(reason)) at \(NSStringFromRect(panel.frame)) on \(screen?.localizedName ?? "?")"
        )
    }

    /// The pill belongs on the display being captured; falls back to the
    /// screen with the mouse (where the user is working), then main.
    private func screenBeingRecorded() -> NSScreen? {
        if let did = proxy.status.displayID,
           let s = NSScreen.screens.first(where: {
               ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == did
           }) {
            return s
        }
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
    }

    private func centerBottom(on screen: NSScreen?) {
        guard let screen else { return }
        let f = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(
            x: f.midX - panel.frame.width / 2,
            y: f.minY + 24
        ))
    }

    // MARK: - Actions

    @objc private func primaryAction() {
        switch lastState {
        case "recording": proxy.pause()
        case "paused": proxy.resume()
        default: proxy.smartToggle()
        }
    }

    @objc private func secondaryAction() {
        if lastState == "idle" {
            let proxy = self.proxy
            AreaSelector.begin { selection in
                guard let selection else { return }
                proxy.startArea(displayID: selection.displayID, rect: selection.rect)
            }
        } else {
            proxy.rewind(seconds: 10)
        }
    }

    @objc private func tertiaryAction() {
        if lastState == "idle" {
            userHidden = true
            panel.orderOut(nil)
        } else {
            proxy.stopAndSave()
        }
    }
}
