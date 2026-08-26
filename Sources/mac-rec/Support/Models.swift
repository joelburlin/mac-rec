import Foundation

// MARK: - API request/response types (shared by CLI client and daemon)

struct StartOptions: Codable {
    /// "fullscreen" | "window" | "app"
    var source: String = "fullscreen"
    /// Display index (order of SCShareableContent.displays); nil = main display.
    var display: Int?
    /// Title / app-name substring for window and app sources.
    var query: String?
    var mic: Bool = true
    var systemAudio: Bool = true
    /// Optional slug used in the session directory name.
    var title: String?
}

struct StopOptions: Codable {
    /// Absolute path to copy the final video to (optional).
    var output: String?
    var compress: Bool = true
    var transcribe: Bool = true
    /// nil = upload iff a GCS bucket is configured; true/false forces.
    var upload: Bool?
    var trimStart: Double?
    var trimEnd: Double?
}

struct RewindRequest: Codable {
    var seconds: Double
}

struct StatusInfo: Codable {
    var state: String
    var sessionId: String?
    var sessionDir: String?
    var source: String?
    /// Seconds of footage currently kept on disk (finished segments).
    var recordedSeconds: Double
    /// Estimated seconds including the in-flight run (while recording).
    var liveSeconds: Double
    var segmentCount: Int
    var runCount: Int
    var version: String = macRecVersion
}

struct RewindResult: Codable {
    var droppedSeconds: Double
    var droppedSegments: Int
    var recordedSeconds: Double
}

struct FinalResult: Codable {
    var sessionId: String
    var sessionDir: String
    var master: String
    var final: String
    var durationSeconds: Double
    var srt: String?
    var vtt: String?
    var transcript: String?
    var shareURL: String?
    var gsURI: String?
    var notes: [String] = []
}

struct APIErrorBody: Codable {
    var error: String
}

struct APIError: Error, LocalizedError {
    let status: Int
    let message: String
    var errorDescription: String? { message }

    init(_ status: Int, _ message: String) {
        self.status = status
        self.message = message
    }
}

// MARK: - Session metadata persisted on disk

struct SegmentMeta: Codable {
    var file: String
    var duration: Double
}

struct RunMeta: Codable {
    var name: String
    var initFile: String?
    var segments: [SegmentMeta]
    /// The mic is a parallel audio-only fragment stream (the HLS writer profile
    /// allows a single audio track per stream). Rewind only deletes video
    /// segments; the mic is trimmed to the kept video duration at finalize.
    var micInitFile: String?
    var micSegments: [SegmentMeta] = []
    var hasSystemAudio: Bool
    var hasMic: Bool

    var duration: Double { segments.reduce(0) { $0 + $1.duration } }
}

struct SessionMeta: Codable {
    var id: String
    var createdAt: Date
    var state: String
    var options: StartOptions
    var width: Int = 0
    var height: Int = 0
    var fps: Int
    var runs: [RunMeta] = []

    var recordedSeconds: Double { runs.reduce(0) { $0 + $1.duration } }
    var segmentCount: Int { runs.reduce(0) { $0 + $1.segments.count } }
}

// MARK: - JSON helpers

extension JSONEncoder {
    static var api: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }
    static var pretty: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }
}

extension JSONDecoder {
    static var api: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
