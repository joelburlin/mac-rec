import AppKit

/// The floating recording pill: ● 0:42  ⏸  ⏪  ■
/// Non-activating, floats over everything, draggable, remembers its position,
/// and is excluded from the capture itself (the daemon filters this app's pid).
@MainActor
final class HUDController {
    private let proxy: RecorderProxy
    private let panel: NSPanel
    private let dot = NSTextField(labelWithString: "●")
    private let timeLabel = NSTextField(labelWithString: "0:00.00")
    private let pauseButton = NSButton()
    private let rewindButton = NSButton()
    private let stopButton = NSButton()
    private var lastState = "idle"

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

        configure(pauseButton, symbol: "pause.fill",
                  tip: "Pause / Resume (\(HotkeyMap.display(.toggle)))", action: #selector(pauseResume))
        configure(rewindButton, symbol: "gobackward.10",
                  tip: "Rewind 10s (\(HotkeyMap.display(.rewind)))", action: #selector(rewind))
        configure(stopButton, symbol: "stop.fill",
                  tip: "Stop & Save (\(HotkeyMap.display(.stop)))", action: #selector(stop))

        let stack = NSStackView(views: [dot, timeLabel, pauseButton, rewindButton, stopButton])
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

        panel.setFrameAutosaveName("mac-rec.hud")
    }

    private func configure(_ button: NSButton, symbol: String, tip: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.imagePosition = .imageOnly
        button.contentTintColor = .labelColor
        button.toolTip = tip
        button.target = self
        button.action = action
    }

    // MARK: - State

    func update(_ s: StatusInfo) {
        switch s.state {
        case "recording":
            dot.textColor = .systemRed
            timeLabel.stringValue = fmtDuration(s.liveSeconds)
            setButtons(pause: "pause.fill", enabled: true)
            show()
        case "paused":
            dot.textColor = .systemOrange
            timeLabel.stringValue = fmtDuration(s.recordedSeconds)
            setButtons(pause: "play.fill", enabled: true)
            show()
        case "finalizing":
            dot.textColor = .systemBlue
            timeLabel.stringValue = "saving…"
            setButtons(pause: "pause.fill", enabled: false)
            show()
        default:
            panel.orderOut(nil)
        }
        lastState = s.state
    }

    func finishedSaving() {
        panel.orderOut(nil)
    }

    private func setButtons(pause symbol: String, enabled: Bool) {
        pauseButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))
        pauseButton.isEnabled = enabled
        rewindButton.isEnabled = enabled
        stopButton.isEnabled = enabled
    }

    private func show() {
        guard !panel.isVisible else { return }
        if panel.frameAutosaveName.isEmpty || !panel.setFrameUsingName("mac-rec.hud") {
            centerBottom()
        }
        panel.orderFrontRegardless()
    }

    private func centerBottom() {
        guard let screen = NSScreen.main else { return }
        let f = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(
            x: f.midX - panel.frame.width / 2,
            y: f.minY + 24
        ))
    }

    // MARK: - Actions

    @objc private func pauseResume() {
        lastState == "paused" ? proxy.resume() : proxy.pause()
    }

    @objc private func rewind() {
        proxy.rewind(seconds: 10)
    }

    @objc private func stop() {
        proxy.stopAndSave()
    }
}
