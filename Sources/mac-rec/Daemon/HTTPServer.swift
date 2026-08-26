import Foundation
import Network

struct HTTPRequest {
    let method: String
    let path: String
    let body: Data
}

struct HTTPResponse {
    let status: Int
    let body: Data

    static func json<T: Encodable>(_ value: T, status: Int = 200) -> HTTPResponse {
        let data = (try? JSONEncoder.api.encode(value)) ?? Data("{}".utf8)
        return HTTPResponse(status: status, body: data)
    }

    static func error(_ err: Error) -> HTTPResponse {
        if let api = err as? APIError {
            return .json(APIErrorBody(error: api.message), status: api.status)
        }
        return .json(APIErrorBody(error: err.localizedDescription), status: 500)
    }
}

/// Minimal localhost-only HTTP/1.1 server (one request per connection).
/// Deliberately dependency-free; the API is a handful of JSON endpoints.
final class HTTPServer {
    private let listener: NWListener
    private let handler: (HTTPRequest, @escaping (HTTPResponse) -> Void) -> Void
    private let queue = DispatchQueue(label: "mac-rec.http")

    init(port: UInt16, handler: @escaping (HTTPRequest, @escaping (HTTPResponse) -> Void) -> Void) throws {
        self.handler = handler
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host("127.0.0.1"),
            port: NWEndpoint.Port(rawValue: port)!
        )
        listener = try NWListener(using: params)
    }

    func start() {
        listener.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            conn.start(queue: self.queue)
            self.receive(conn, buffer: Data())
        }
        listener.start(queue: queue)
    }

    func stop() {
        listener.cancel()
    }

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 128 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if error != nil {
                conn.cancel()
                return
            }
            if let request = Self.parse(buf) {
                self.handler(request) { resp in
                    self.send(conn, resp)
                }
            } else if isComplete || buf.count > 4 * 1024 * 1024 {
                conn.cancel()
            } else {
                self.receive(conn, buffer: buf)
            }
        }
    }

    /// Returns a request once the full head + Content-Length body has arrived.
    private static func parse(_ data: Data) -> HTTPRequest? {
        guard let headEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard let head = String(data: data[..<headEnd.lowerBound], encoding: .utf8) else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }

        var contentLength = 0
        for line in lines.dropFirst() {
            let kv = line.split(separator: ":", maxSplits: 1)
            if kv.count == 2, kv[0].lowercased() == "content-length" {
                contentLength = Int(kv[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        let body = data[headEnd.upperBound...]
        guard body.count >= contentLength else { return nil }
        return HTTPRequest(
            method: String(parts[0]),
            path: String(parts[1]),
            body: Data(body.prefix(contentLength))
        )
    }

    private func send(_ conn: NWConnection, _ resp: HTTPResponse) {
        let reason = resp.status == 200 ? "OK" : "Error"
        var head = "HTTP/1.1 \(resp.status) \(reason)\r\n"
        head += "Content-Type: application/json\r\n"
        head += "Content-Length: \(resp.body.count)\r\n"
        head += "Connection: close\r\n\r\n"
        var out = Data(head.utf8)
        out.append(resp.body)
        conn.send(content: out, completion: .contentProcessed { _ in
            conn.cancel()
        })
    }
}
