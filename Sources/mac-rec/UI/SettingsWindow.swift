import AppKit

/// Settings window — the place for things that don't belong in a menu:
/// the ElevenLabs key, the whisper model, and where recordings land.
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {

    private let keyField = NSSecureTextField()
    private let keyStatus = NSTextField(labelWithString: "")
    private let voicePopup = NSPopUpButton()
    private let whisperStatus = NSTextField(labelWithString: "")
    private let outputField = NSTextField()
    private var voices: [ElevenLabs.Voice] = []

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 430),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false
        )
        window.title = "mac-rec Settings"
        window.isReleasedWhenClosed = false
        self.init(window: window)
        window.delegate = self
        window.center()
        build()
        load()
    }

    // MARK: - Layout

    private func build() {
        guard let content = window?.contentView else { return }
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 22, bottom: 20, right: 22)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor),
        ])

        stack.addArrangedSubview(header("AI voiceover"))
        stack.addArrangedSubview(caption(
            "An ElevenLabs key lets mac-rec re-narrate a recording in a chosen voice. "
            + "Optional — everything else works without it."))

        keyField.placeholderString = "sk_…"
        keyField.controlSize = .regular
        keyField.translatesAutoresizingMaskIntoConstraints = false
        keyField.widthAnchor.constraint(equalToConstant: 330).isActive = true

        let saveKey = NSButton(title: "Save", target: self, action: #selector(saveKey))
        saveKey.bezelStyle = .rounded
        stack.addArrangedSubview(row([label("API key"), keyField, saveKey]))

        keyStatus.font = .systemFont(ofSize: 11)
        keyStatus.textColor = .secondaryLabelColor
        stack.addArrangedSubview(keyStatus)

        voicePopup.translatesAutoresizingMaskIntoConstraints = false
        voicePopup.widthAnchor.constraint(equalToConstant: 330).isActive = true
        voicePopup.target = self
        voicePopup.action = #selector(pickVoice)
        let reload = NSButton(title: "Reload", target: self, action: #selector(loadVoices))
        reload.bezelStyle = .rounded
        stack.addArrangedSubview(row([label("Voice"), voicePopup, reload]))

        stack.addArrangedSubview(divider())
        stack.addArrangedSubview(header("Captions"))
        whisperStatus.font = .systemFont(ofSize: 11)
        whisperStatus.textColor = .secondaryLabelColor
        let getModel = NSButton(title: "Download base model (148 MB)",
                                target: self, action: #selector(downloadModel))
        getModel.bezelStyle = .rounded
        stack.addArrangedSubview(whisperStatus)
        stack.addArrangedSubview(getModel)

        stack.addArrangedSubview(divider())
        stack.addArrangedSubview(header("Recordings"))
        outputField.translatesAutoresizingMaskIntoConstraints = false
        outputField.widthAnchor.constraint(equalToConstant: 330).isActive = true
        outputField.isEditable = false
        let choose = NSButton(title: "Choose…", target: self, action: #selector(chooseFolder))
        choose.bezelStyle = .rounded
        stack.addArrangedSubview(row([label("Folder"), outputField, choose]))

        stack.addArrangedSubview(divider())
        let version = NSTextField(labelWithString: "mac-rec \(macRecVersion)")
        version.font = .systemFont(ofSize: 11)
        version.textColor = .secondaryLabelColor
        let updates = NSButton(title: "Check for Updates…", target: self, action: #selector(checkUpdates))
        updates.bezelStyle = .rounded
        stack.addArrangedSubview(row([version, updates]))
    }

    private func header(_ s: String) -> NSTextField {
        let t = NSTextField(labelWithString: s)
        t.font = .systemFont(ofSize: 13, weight: .semibold)
        return t
    }

    private func caption(_ s: String) -> NSTextField {
        let t = NSTextField(wrappingLabelWithString: s)
        t.font = .systemFont(ofSize: 11)
        t.textColor = .secondaryLabelColor
        t.translatesAutoresizingMaskIntoConstraints = false
        t.widthAnchor.constraint(equalToConstant: 470).isActive = true
        return t
    }

    private func label(_ s: String) -> NSTextField {
        let t = NSTextField(labelWithString: s)
        t.translatesAutoresizingMaskIntoConstraints = false
        t.widthAnchor.constraint(equalToConstant: 58).isActive = true
        return t
    }

    private func row(_ views: [NSView]) -> NSStackView {
        let r = NSStackView(views: views)
        r.orientation = .horizontal
        r.spacing = 8
        r.alignment = .firstBaseline
        return r
    }

    private func divider() -> NSBox {
        let b = NSBox()
        b.boxType = .separator
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(equalToConstant: 470).isActive = true
        return b
    }

    // MARK: - State

    private func load() {
        let cfg = Config.load()
        if let k = cfg.elevenKey, !k.isEmpty {
            keyField.stringValue = k
            keyStatus.stringValue = "Key saved. Voices load from your ElevenLabs account."
        } else if ProcessInfo.processInfo.environment["ELEVENLABS_API_KEY"] != nil {
            keyStatus.stringValue = "Using ELEVENLABS_API_KEY from the environment."
        } else {
            keyStatus.stringValue = "No key set — AI voiceover is disabled."
        }
        outputField.stringValue = cfg.outputRoot
        whisperStatus.stringValue = cfg.resolveWhisperModel().map {
            "Model: \($0.lastPathComponent)"
        } ?? "No whisper model — captions and voiceover are unavailable."
        rebuildVoiceMenu(selected: cfg.elevenVoiceID)
        if cfg.resolveElevenKey() != nil, voices.isEmpty { loadVoices() }
    }

    @objc private func saveKey() {
        var cfg = Config.load()
        let value = keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        cfg.elevenKey = value.isEmpty ? nil : value
        do {
            try cfg.save()
            keyStatus.stringValue = value.isEmpty
                ? "Key removed."
                : "Key saved to ~/.config/mac-rec/config.json (readable only by you)."
            if !value.isEmpty { loadVoices() }
        } catch {
            keyStatus.stringValue = "Couldn't save: \(error.localizedDescription)"
        }
    }

    @objc private func loadVoices() {
        guard let key = Config.load().resolveElevenKey() else {
            keyStatus.stringValue = "Add a key first."
            return
        }
        keyStatus.stringValue = "Loading voices…"
        DispatchQueue.global().async {
            let result = Result { try ElevenLabs.listVoices(key: key) }
            DispatchQueue.main.async {
                switch result {
                case .success(let list):
                    self.voices = list
                    self.rebuildVoiceMenu(selected: Config.load().elevenVoiceID)
                    self.keyStatus.stringValue = "Key works — \(list.count) voices available."
                case .failure(let error):
                    self.keyStatus.stringValue = "Key rejected: \(error.localizedDescription)"
                }
            }
        }
    }

    private func rebuildVoiceMenu(selected: String?) {
        voicePopup.removeAllItems()
        if voices.isEmpty {
            let cfg = Config.load()
            voicePopup.addItem(withTitle: cfg.elevenVoiceName ?? "—")
            voicePopup.isEnabled = false
            return
        }
        voicePopup.isEnabled = true
        for v in voices {
            voicePopup.addItem(withTitle: v.name)
            voicePopup.lastItem?.representedObject = v.id
        }
        if let selected, let idx = voices.firstIndex(where: { $0.id == selected }) {
            voicePopup.selectItem(at: idx)
        }
    }

    @objc private func pickVoice() {
        guard let id = voicePopup.selectedItem?.representedObject as? String else { return }
        var cfg = Config.load()
        cfg.elevenVoiceID = id
        cfg.elevenVoiceName = voicePopup.selectedItem?.title
        try? cfg.save()
    }

    @objc private func downloadModel() {
        whisperStatus.stringValue = "Downloading base model…"
        DispatchQueue.global().async {
            let dest = Config.modelsDir.appendingPathComponent("ggml-base.bin")
            let result = Result {
                try FileManager.default.createDirectory(at: Config.modelsDir, withIntermediateDirectories: true)
                try Shell.runChecked("curl", [
                    "-L", "--fail", "-o", dest.path,
                    "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin",
                ])
            }
            DispatchQueue.main.async {
                switch result {
                case .success:
                    var cfg = Config.load()
                    cfg.whisperModel = dest.path
                    try? cfg.save()
                    self.whisperStatus.stringValue = "Model: ggml-base.bin"
                case .failure(let error):
                    self.whisperStatus.stringValue = "Download failed: \(error.localizedDescription)"
                }
            }
        }
    }

    @objc private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = Config.load().outputRootURL
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var cfg = Config.load()
        cfg.outputRoot = url.path
        try? cfg.save()
        outputField.stringValue = url.path
    }

    @objc private func checkUpdates() {
        Updater.check(silent: false)
    }
}
