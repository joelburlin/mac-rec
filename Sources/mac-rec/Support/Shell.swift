import Foundation

struct ShellResult {
    let status: Int32
    let stdout: String
    let stderr: String
}

enum ShellError: Error, LocalizedError {
    case toolNotFound(String)
    case failed(tool: String, status: Int32, stderr: String)

    var errorDescription: String? {
        switch self {
        case .toolNotFound(let t):
            return "required tool not found: \(t)"
        case .failed(let tool, let status, let stderr):
            let tail = stderr.split(separator: "\n").suffix(6).joined(separator: "\n")
            return "\(tool) exited \(status): \(tail)"
        }
    }
}

enum Shell {
    /// Locate a tool by name, checking common Homebrew/system locations then PATH.
    static func find(_ name: String) -> String? {
        let candidates = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)",
            "/bin/\(name)",
        ]
        let fm = FileManager.default
        for c in candidates where fm.isExecutableFile(atPath: c) { return c }
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for dir in path.split(separator: ":") {
            let p = "\(dir)/\(name)"
            if fm.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    @discardableResult
    static func run(_ tool: String, _ args: [String], stdin: Data? = nil) throws -> ShellResult {
        guard let exe = find(tool) else { throw ShellError.toolNotFound(tool) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        if let stdin {
            let inPipe = Pipe()
            p.standardInput = inPipe
            try p.run()
            inPipe.fileHandleForWriting.write(stdin)
            inPipe.fileHandleForWriting.closeFile()
        } else {
            try p.run()
        }
        // Drain pipes concurrently so big outputs can't deadlock the child.
        var outData = Data(), errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        p.waitUntilExit()
        group.wait()
        return ShellResult(
            status: p.terminationStatus,
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? ""
        )
    }

    /// Run and throw if the exit status is non-zero.
    @discardableResult
    static func runChecked(_ tool: String, _ args: [String], stdin: Data? = nil) throws -> ShellResult {
        let r = try run(tool, args, stdin: stdin)
        guard r.status == 0 else {
            throw ShellError.failed(tool: tool, status: r.status, stderr: r.stderr.isEmpty ? r.stdout : r.stderr)
        }
        return r
    }

    static func pbcopy(_ text: String) {
        _ = try? run("pbcopy", [], stdin: Data(text.utf8))
    }
}

func log(_ msg: String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    FileHandle.standardError.write(Data("[\(ts)] \(msg)\n".utf8))
}
