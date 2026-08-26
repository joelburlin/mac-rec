import Foundation

/// CLI-side client: talks to the daemon over localhost, auto-spawning it when
/// it isn't running yet.
struct DaemonClient {
    let cfg: Config

    var baseURL: URL { URL(string: "http://127.0.0.1:\(cfg.port)")! }

    // MARK: - Requests

    func get<R: Decodable>(_ path: String, as type: R.Type, timeout: TimeInterval = 10) throws -> R {
        try request("GET", path, body: Optional<Int>.none, as: type, timeout: timeout)
    }

    func post<B: Encodable, R: Decodable>(
        _ path: String, body: B?, as type: R.Type, timeout: TimeInterval = 30
    ) throws -> R {
        try request("POST", path, body: body, as: type, timeout: timeout)
    }

    private func request<B: Encodable, R: Decodable>(
        _ method: String, _ path: String, body: B?, as: R.Type, timeout: TimeInterval
    ) throws -> R {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = method
        req.timeoutInterval = timeout
        if let body {
            req.httpBody = try JSONEncoder.api.encode(body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let sem = DispatchSemaphore(value: 0)
        var result: Result<(Data, Int), Error>!
        let task = URLSession.shared.dataTask(with: req) { data, resp, err in
            if let err {
                result = .failure(err)
            } else {
                let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
                result = .success((data ?? Data(), status))
            }
            sem.signal()
        }
        task.resume()
        sem.wait()

        let (data, status) = try result.get()
        if status != 200 {
            if let apiErr = try? JSONDecoder.api.decode(APIErrorBody.self, from: data) {
                throw APIError(status, apiErr.error)
            }
            throw APIError(status, "daemon returned HTTP \(status)")
        }
        return try JSONDecoder.api.decode(R.self, from: data)
    }

    // MARK: - Lifecycle

    func isRunning() -> Bool {
        (try? get("/health", as: [String: String].self, timeout: 2)) != nil
    }

    /// Ensure a daemon is up, spawning `mac-rec serve` detached if needed.
    func ensureRunning() throws {
        if isRunning() { return }

        guard let exe = Bundle.main.executableURL else {
            throw APIError(500, "cannot locate own executable to spawn the daemon")
        }
        try FileManager.default.createDirectory(at: Config.configDir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: Config.daemonLog.path, contents: nil)
        let logHandle = try FileHandle(forWritingTo: Config.daemonLog)
        logHandle.seekToEndOfFile()

        let p = Process()
        p.executableURL = exe
        p.arguments = ["serve", "--port", String(cfg.port)]
        p.standardOutput = logHandle
        p.standardError = logHandle
        try p.run()

        for _ in 0..<50 {
            if isRunning() { return }
            Thread.sleep(forTimeInterval: 0.2)
        }
        throw APIError(500, "daemon failed to start (see \(Config.daemonLog.path))")
    }
}
