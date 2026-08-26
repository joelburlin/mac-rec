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

    func run() throws {
        var cfg = Config.load()
        var changed = false

        if let model = whisperModel {
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
