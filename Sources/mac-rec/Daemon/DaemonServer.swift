import Foundation

/// Routes the localhost REST API onto the RecorderController.
///
/// POST /start  {StartOptions}   POST /pause    POST /resume
/// POST /rewind {seconds}        POST /stop {StopOptions}
/// GET  /status  GET /health     POST /quit
final class DaemonServer {
    private let cfg: Config
    private let controller: RecorderController
    private var server: HTTPServer?

    init(cfg: Config) {
        self.cfg = cfg
        self.controller = RecorderController(cfg: cfg)
    }

    /// Start listening (non-blocking). All work happens on queues/tasks.
    func start() throws {
        let server = try HTTPServer(port: UInt16(cfg.port)) { [weak self] req, respond in
            guard let self else { return }
            Task { respond(await self.route(req)) }
        }
        self.server = server
        server.start()
        log("mac-rec daemon \(macRecVersion) listening on 127.0.0.1:\(cfg.port)")

        signal(SIGHUP, SIG_IGN)  // survive the spawning terminal closing
        signal(SIGPIPE, SIG_IGN)
    }

    private func route(_ req: HTTPRequest) async -> HTTPResponse {
        do {
            switch (req.method, req.path) {
            case ("GET", "/health"):
                return .json(["ok": "true", "version": macRecVersion])
            case ("GET", "/status"):
                return .json(await controller.status())
            case ("POST", "/start"):
                let opts = req.body.isEmpty
                    ? StartOptions()
                    : try JSONDecoder.api.decode(StartOptions.self, from: req.body)
                return .json(try await controller.start(opts))
            case ("POST", "/pause"):
                return .json(try await controller.pause())
            case ("POST", "/resume"):
                return .json(try await controller.resume())
            case ("POST", "/rewind"):
                let r = try JSONDecoder.api.decode(RewindRequest.self, from: req.body)
                return .json(try await controller.rewind(seconds: r.seconds))
            case ("POST", "/stop"):
                let opts = req.body.isEmpty
                    ? StopOptions()
                    : try JSONDecoder.api.decode(StopOptions.self, from: req.body)
                return .json(try await controller.stop(opts))
            case ("POST", "/quit"):
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { exit(0) }
                return .json(["ok": "true"])
            default:
                return .json(APIErrorBody(error: "no route \(req.method) \(req.path)"), status: 404)
            }
        } catch let e as DecodingError {
            return .json(APIErrorBody(error: "bad request body: \(e)"), status: 400)
        } catch {
            return .error(error)
        }
    }
}
