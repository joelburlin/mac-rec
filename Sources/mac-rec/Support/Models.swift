import Foundation

// MARK: - API request/response types (shared by CLI client and daemon)

/// Free-style capture region, in display points, top-left origin, relative to
/// the chosen display (matches SCStreamConfiguration.sourceRect).
struct AreaRect: Codable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
}

struct StartOptions: Codable {
    /// "fullscreen" | "window" | "app"
    var source: String = "fullscreen"
    /// Display index (order of SCShareableContent.displays); nil = main display.
    var display: Int?
    /// Exact display by CGDirectDisplayID — wins over `display` when set.
    var displayID: UInt32?
    /// Exact window by CGWindowID (source "window") — wins over `query`.
    var windowID: UInt32?
    /// Crop the display capture to this region ("area" recording).
    var area: AreaRect?
    /// Title / app-name substring for window and app sources.
    var query: String?
    var mic: Bool = true
    /// Microphone device: AVCaptureDevice uniqueID or a name substring;
    /// nil = system default.
    var micDeviceID: String?
    var systemAudio: Bool = true
    /// Optional slug used in the session directory name.
    var title: String?
    /// PIDs whose windows are excluded from display capture (the UI app passes
    /// its own pid so the floating HUD never appears in the recording).
    var excludeAppPIDs: [Int32]?
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
    /// Denoise + level the mic track during the final encode (default true).
    var cleanMic: Bool?
    /// Mic gain in dB; nil = auto from config.
    var micGainDb: Double?
    /// Burn-in caption style; nil = config default.
    var captionStyle: String?
    /// Replace the recorded narration with an ElevenLabs voice.
    var voiceover: Bool?
    /// ElevenLabs voice id; nil = config default.
    var voiceID: String?
}

struct RewindRequest: Codable {
    var seconds: Double
}

struct StatusInfo: Codable {
    var state: String
    var sessionId: String?
    var sessionDir: String?
    var source: String?
    /// CGDirectDisplayID of the display being captured (nil for window sources)
    /// — lets the UI put the floating HUD on the right screen.
    var displayID: UInt32?
    /// Live mic input level 0…1 (peak-decayed), nil when mic is off.
    var micLevel: Double?
    /// Raw mic level in dBFS — the honest number behind the meter.
    var micDb: Double?
    /// Mic muted live (samples dropped, recording continues).
    var micMuted: Bool = false
    /// Human-readable note about the last notable event (e.g. why the
    /// session auto-paused). Cleared on start/resume.
    var lastEvent: String?
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
