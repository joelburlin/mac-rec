import Foundation

let macRecVersion = "0.5.0"

struct Config: Codable {
    var port: Int = 5757
    var outputRoot: String = "~/Movies/mac-rec"
    var fps: Int = 30
    var segmentSeconds: Double = 2.0
    /// Recording (master) bitrate for HEVC hardware encode, in Mbps.
    var recordBitrateMbps: Double = 16
    /// hevc_videotoolbox constant-quality value (0-100) for the final compress pass.
    var compressQuality: Int = 52
    /// Path to a ggml whisper model. When nil, ~/.config/mac-rec/models is searched.
    var whisperModel: String?
    var whisperLanguage: String = "auto"
    /// Mic gain in dB applied at finalize. nil = auto: measure the track and
    /// lift it to `micTargetDb`. This is what rescues quiet webcam mics.
    var micGainDb: Double?
    var micTargetDb: Double = -24
    /// Burned-in caption style: none | classic | boxed | bold | karaoke | minimal
    var captionStyle: String = "none"
    /// Caption placement: bottom | top | center
    var captionPosition: String = "bottom"
    /// ElevenLabs narration replacement.
    var elevenKey: String?
    var elevenVoiceID: String?
    var elevenVoiceName: String?
    var elevenModel: String = "eleven_v3"
    /// GCS bucket name (no gs:// prefix). Upload is skipped when nil.
    var gcsBucket: String?
    var gcsPrefix: String = "screencasts"
    /// Base URL for share links. Defaults to https://storage.googleapis.com/<bucket>.
    var gcsPublicBase: String?
    /// UI hotkey overrides, e.g. {"toggle": "cmd+shift+2"}. Format:
    /// modifiers (cmd/opt/ctrl/shift) + one key (a-z, 0-9, f1-f12, arrows,
    /// space), joined with "+". Restart the UI app to apply.
    var hotkeys: [String: String]?

    static let defaultHotkeys: [String: String] = [
        "toggle": "opt+cmd+r",   // start / pause / resume
        "area": "opt+cmd+a",     // drag-select area recording
        "rewind": "opt+cmd+left",
        "stop": "opt+cmd+s",     // stop & save
    ]

    /// Effective bindings: defaults overridden by config.
    func hotkeyBindings() -> [String: String] {
        Config.defaultHotkeys.merging(hotkeys ?? [:]) { _, override in override }
    }

    init() {}

    /// Tolerant decoding: every field falls back to its default when absent.
    /// Swift's synthesized Decodable throws on a missing key instead, which
    /// silently reset the whole config file on version upgrades.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func v<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: key)) as? T ?? fallback
        }
        port = v(.port, 5757)
        outputRoot = v(.outputRoot, "~/Movies/mac-rec")
        fps = v(.fps, 30)
        segmentSeconds = v(.segmentSeconds, 2.0)
        recordBitrateMbps = v(.recordBitrateMbps, 16)
        compressQuality = v(.compressQuality, 52)
        whisperModel = try? c.decodeIfPresent(String.self, forKey: .whisperModel)
        whisperLanguage = v(.whisperLanguage, "auto")
        micGainDb = try? c.decodeIfPresent(Double.self, forKey: .micGainDb)
        micTargetDb = v(.micTargetDb, -24)
        captionStyle = v(.captionStyle, "none")
        captionPosition = v(.captionPosition, "bottom")
        elevenKey = try? c.decodeIfPresent(String.self, forKey: .elevenKey)
        elevenVoiceID = try? c.decodeIfPresent(String.self, forKey: .elevenVoiceID)
        elevenVoiceName = try? c.decodeIfPresent(String.self, forKey: .elevenVoiceName)
        elevenModel = v(.elevenModel, "eleven_v3")
        gcsBucket = try? c.decodeIfPresent(String.self, forKey: .gcsBucket)
        gcsPrefix = v(.gcsPrefix, "screencasts")
        gcsPublicBase = try? c.decodeIfPresent(String.self, forKey: .gcsPublicBase)
        hotkeys = try? c.decodeIfPresent([String: String].self, forKey: .hotkeys)
    }

    /// ElevenLabs key from config, then the environment.
    func resolveElevenKey() -> String? {
        if let k = elevenKey, !k.isEmpty { return k }
        let env = ProcessInfo.processInfo.environment
        for name in ["ELEVENLABS_API_KEY", "ELEVEN_API_KEY", "ELEVENLABS_KEY"] {
            if let v = env[name], !v.isEmpty { return v }
        }
        return nil
    }

    static var configDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/mac-rec", isDirectory: true)
    }
    static var configFile: URL { configDir.appendingPathComponent("config.json") }
    static var modelsDir: URL { configDir.appendingPathComponent("models", isDirectory: true) }
    static var daemonLog: URL { configDir.appendingPathComponent("daemon.log") }

    static func load() -> Config {
        guard let data = try? Data(contentsOf: configFile),
              let cfg = try? JSONDecoder().decode(Config.self, from: data)
        else { return Config() }
        return cfg
    }

    func save() throws {
        try FileManager.default.createDirectory(at: Config.configDir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(self).write(to: Config.configFile)
        // The file can hold an API key; don't leave it world-readable.
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: Config.configFile.path)
    }

    var outputRootURL: URL {
        URL(fileURLWithPath: (outputRoot as NSString).expandingTildeInPath, isDirectory: true)
    }

    /// Resolve a ggml whisper model: explicit config path first, then models dir.
    func resolveWhisperModel() -> URL? {
        let fm = FileManager.default
        if let p = whisperModel {
            let url = URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
            if fm.fileExists(atPath: url.path) { return url }
        }
        guard let entries = try? fm.contentsOfDirectory(at: Config.modelsDir, includingPropertiesForKeys: nil) else {
            return nil
        }
        return entries
            .filter { $0.lastPathComponent.hasPrefix("ggml-") && $0.pathExtension == "bin" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .first
    }
}
