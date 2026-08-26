import Foundation
import ArgumentParser

struct Serve: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Run the recorder daemon in the foreground (the CLI normally auto-spawns this)."
    )

    @Option(help: "Port to listen on (127.0.0.1 only).")
    var port: Int?

    func run() async throws {
        var cfg = Config.load()
        if let port { cfg.port = port }
        let daemon = DaemonServer(cfg: cfg)
        try daemon.start()
        while true {
            try await Task.sleep(for: .seconds(3600))
        }
    }
}
