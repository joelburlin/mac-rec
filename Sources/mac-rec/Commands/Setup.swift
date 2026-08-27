import Foundation
import ArgumentParser

struct Setup: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "One-time setup: download a whisper model, configure GCS, tune defaults."
    )

    @Option(name: .customLong("whisper-model"),
            help: "Download a ggml whisper model (tiny|base|small|medium|large-v3-turbo; add .en for English-only, e.g. base.en).")
    var whisperModel: String?

    @Option(name: .customLong("whisper-language"), help: "Transcription language code, or 'auto'.")
    var whisperLanguage: String?

    @Option(name: .customLong("gcs-bucket"), help: "GCS bucket name for uploads (no gs:// prefix).")
    var gcsBucket: String?

    @Option(name: .customLong("gcs-prefix"), help: "Object prefix inside the bucket.")
    var gcsPrefix: String?

    @Option(help: "Daemon port.")
    var port: Int?

    @Option(name: .customLong("output-root"), help: "Where session directories are written.")
    var outputRoot: String?

    @Option(name: .customLong("eleven-key"),
            help: "ElevenLabs API key (or \"env\" to copy it from $ELEVENLABS_API_KEY).")
    var elevenKey: String?

    @Option(name: .customLong("eleven-model"), help: "ElevenLabs model id (default eleven_v3).")
    var elevenModel: String?

    @Option(name: .customLong("caption-style"),
            help: "Default burned-in caption style: none|classic|boxed|bold|karaoke|minimal.")
    var captionStyle: String?

    @Option(name: .customLong("caption-position"), help: "bottom | top | center.")
    var captionPosition: String?

    @Option(name: .customLong("mic-gain"),
            help: "Fixed mic gain in dB, or \"auto\" to level automatically (default).")
    var micGain: String?

    func run() throws {
        var cfg = Config.load()
        var changed = false

        if let model = whisperModel {
            // An existing .bin path is used as-is (e.g. a model another app
            // already downloaded); a bare name is fetched.
            if model.hasSuffix(".bin") {
                let url = URL(fileURLWithPath: (model as NSString).expandingTildeInPath)
                guard FileManager.default.fileExists(atPath: url.path) else {
                    throw ValidationError("no model file at \(url.path)")
                }
                cfg.whisperModel = url.path
                try cfg.save()
                print("using whisper model: \(url.path)")
                return
            }
            let file = "ggml-\(model).bin"
            let dest = Config.modelsDir.appendingPathComponent(file)
            if FileManager.default.fileExists(atPath: dest.path) {
                print("model already present: \(dest.path)")
            } else {
                try FileManager.default.createDirectory(at: Config.modelsDir, withIntermediateDirectories: true)
                let url = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(file)"
                print("downloading \(url) ...")
                try Shell.runChecked("curl", ["-L", "--fail", "--progress-bar", "-o", dest.path, url])
                print("saved \(dest.path)")
            }
            cfg.whisperModel = dest.path
            changed = true
        }
        if let lang = whisperLanguage { cfg.whisperLanguage = lang; changed = true }
        if let bucket = gcsBucket { cfg.gcsBucket = bucket; changed = true }
        if let prefix = gcsPrefix { cfg.gcsPrefix = prefix; changed = true }
        if let port { cfg.port = port; changed = true }
        if let root = outputRoot { cfg.outputRoot = root; changed = true }
        if let k = elevenKey {
            if k == "env" {
                guard let fromEnv = ProcessInfo.processInfo.environment["ELEVENLABS_API_KEY"],
                      !fromEnv.isEmpty
                else { throw ValidationError("ELEVENLABS_API_KEY is not set in this shell") }
                cfg.elevenKey = fromEnv
            } else {
                cfg.elevenKey = k
            }
            changed = true
        }
        if let m = elevenModel { cfg.elevenModel = m; changed = true }
        if let s = captionStyle {
            guard Captions.styleNames.contains(s.lowercased()) else {
                throw ValidationError("caption style must be one of: \(Captions.styleNames.joined(separator: ", "))")
            }
            cfg.captionStyle = s.lowercased()
            changed = true
        }
        if let p = captionPosition { cfg.captionPosition = p.lowercased(); changed = true }
        if let g = micGain {
            if g.lowercased() == "auto" {
                cfg.micGainDb = nil
            } else if let v = Double(g) {
                cfg.micGainDb = v
            } else {
                throw ValidationError("--mic-gain takes a dB number or \"auto\"")
            }
            changed = true
        }

        if changed {
            try cfg.save()
            print("config saved: \(Config.configFile.path)")
        } else {
            print("nothing to do — pass at least one option (see --help)")
        }
    }
}

struct ShowConfig: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "Print the active configuration."
    )

    func run() throws {
        let cfg = Config.load()
        let data = try JSONEncoder.pretty.encode(cfg)
        print("# \(Config.configFile.path)")
        print(String(data: data, encoding: .utf8) ?? "{}")
        if let model = cfg.resolveWhisperModel() {
            print("# whisper model in use: \(model.path)")
        } else {
            print("# no whisper model found — captions disabled (mac-rec setup --whisper-model base)")
        }
    }
}
