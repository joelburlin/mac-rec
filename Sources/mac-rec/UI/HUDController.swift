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
    private let micMeter = MicLevelView()
    private let button1 = NSButton()   // record / pause / resume
    private let button2 = NSButton()   // area (idle) / rewind
    private let button3 = NSButton()   // hide (idle) / stop
    private var lastState = ""
    /// Set by the ✕ button; cleared when a recording starts.
    private var userHidden = false

    init(proxy: RecorderProxy) {
        self.proxy = proxy

        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 270, height: 44),
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

        // The meter doubles as the mute button.
        micMeter.onClick = { [weak proxy] in proxy?.toggleMic() }

        let stack = NSStackView(views: [dot, timeLabel, micMeter, button1, button2, button3])
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

    /// Self-driving: reads proxy.status on a timer so the pill works even if
    /// the onChange callback chain ever breaks.
    func startAutoUpdate() {
        update(proxy.status)
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.update(self.proxy.status) }
        }
        RunLoop.main.add(t, forMode: .common)
    }

    func update(_ s: StatusInfo) {
        if s.state != lastState {
            RecorderProxy.uiLog("HUD state \(lastState.isEmpty ? "launch" : lastState) → \(s.state)")
        }
        if s.state != "idle" { userHidden = false }
        micMeter.level = s.micMuted ? 0 : (s.micLevel ?? 0)
        micMeter.active = s.micLevel != nil && !s.micMuted
        micMeter.muted = s.micMuted || (s.state == "idle" && !proxy.micEnabledPreference)
        if let db = s.micDb, s.micLevel != nil {
            micMeter.toolTip = s.micMuted
                ? "Mic muted — click to unmute"
                : String(format: "Mic %.0f dBFS — click to mute", db)
        } else {
            micMeter.toolTip = micMeter.muted ? "Mic off — click to enable" : "Microphone"
        }
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

/// Small horizontal mic input meter: 🎙 + a level bar that lights up while
/// speaking (green → yellow → red). Dimmed when the mic isn't being captured.
@MainActor
final class MicLevelView: NSView {
    var level: Double = 0 {
        didSet { if abs(level - oldValue) > 0.01 { needsDisplay = true } }
    }
    var active = false {
        didSet { if active != oldValue { needsDisplay = true } }
    }
    var muted = false {
        didSet { if muted != oldValue { needsDisplay = true } }
    }
    /// Clicking the meter mutes/unmutes.
    var onClick: (() -> Void)?

    override var intrinsicContentSize: NSSize { NSSize(width: 46, height: 18) }

    override func mouseDown(with event: NSEvent) { onClick?() }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func draw(_ dirtyRect: NSRect) {
        let iconSize: CGFloat = 12
        if let icon = NSImage(
            systemSymbolName: muted ? "mic.slash.fill" : (active ? "mic.fill" : "mic"),
            accessibilityDescription: "mic level"
        )?.withSymbolConfiguration(.init(pointSize: iconSize, weight: .medium)) {
            let tint: NSColor = muted ? .systemRed : (active ? .labelColor : .tertiaryLabelColor)
            icon.tinted(tint).draw(in: NSRect(x: 0, y: (bounds.height - iconSize) / 2 - 1,
                                              width: iconSize, height: iconSize + 2))
        }

        let track = NSRect(x: iconSize + 5, y: bounds.midY - 2.5,
                           width: bounds.width - iconSize - 6, height: 5)
        NSColor.tertiaryLabelColor.withAlphaComponent(0.35).setFill()
        NSBezierPath(roundedRect: track, xRadius: 2.5, yRadius: 2.5).fill()

        guard active, !muted, level > 0.02 else { return }
        var fill = track
        fill.size.width = max(3, track.width * CGFloat(min(1, level)))
        let color: NSColor = level > 0.85 ? .systemRed : (level > 0.65 ? .systemYellow : .systemGreen)
        color.setFill()
        NSBezierPath(roundedRect: fill, xRadius: 2.5, yRadius: 2.5).fill()
    }
}

private extension NSImage {
    func tinted(_ color: NSColor) -> NSImage {
        let img = NSImage(size: size, flipped: false) { rect in
            color.set()
            rect.fill()
            self.draw(in: rect, from: .zero, operation: .destinationIn, fraction: 1)
            return true
        }
        return img
    }
}
