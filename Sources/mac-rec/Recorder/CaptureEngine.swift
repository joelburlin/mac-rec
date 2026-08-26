import Foundation
import AVFoundation
import ScreenCaptureKit
import UniformTypeIdentifiers
import CoreMedia

/// One capture run: an SCStream feeding an AVAssetWriter that emits fragmented
/// MP4 segments (~2s each) to disk. Pause/resume creates a new engine per run;
/// rewind is implemented by deleting trailing segment files.
final class CaptureEngine: NSObject, SCStreamDelegate, SCStreamOutput, AVAssetWriterDelegate {

    private let runDir: URL
    private let runName: String
    private let cfg: Config
    private let opts: StartOptions

    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var videoIn: AVAssetWriterInput?
    private var sysAudioIn: AVAssetWriterInput?
    /// The HLS-profile writer allows only one audio track per stream, so the
    /// mic gets its own audio-only fragmented writer sharing the same clock.
    private var micWriter: AVAssetWriter?
    private var micIn: AVAssetWriterInput?

    /// Serializes writer state + appends (SCK delivers on our handler queues).
    private let writerQueue = DispatchQueue(label: "mac-rec.writer")
    /// Serializes segment file IO + segment bookkeeping.
    private let ioQueue = DispatchQueue(label: "mac-rec.segments")

    private var sessionStarted = false
    private var sessionStartPTS: CMTime = .invalid
    private var segIndex = 0
    private var micSegIndex = 0
    private var initFile: String?
    private var micInitFile: String?
    private var segments: [SegmentMeta] = []
    private var micSegments: [SegmentMeta] = []
    private var streamError: Error?
    private var stoppedNotified = false
    private var notReadyDrops = 0

    /// SCK only delivers frames when content changes; during static stretches
    /// the last frame is re-appended so the video timeline stays continuous
    /// (otherwise audio outruns video and static time collapses).
    private var lastImageBuffer: CVImageBuffer?
    private var lastFormatDesc: CMFormatDescription?
    private var lastVideoPTS: CMTime = .invalid
    private var repeatTimer: DispatchSourceTimer?

    /// Fired once (on an internal queue) if the stream dies out from under us —
    /// e.g. the user hits the system screen-sharing stop control.
    var onStopped: ((Error) -> Void)?

    private(set) var width = 0
    private(set) var height = 0
    private(set) var sourceDescription = ""
    let startedAt = Date()

    init(runDir: URL, runName: String, cfg: Config, opts: StartOptions) {
        self.runDir = runDir
        self.runName = runName
        self.cfg = cfg
        self.opts = opts
    }

    // MARK: - Start

    func start() async throws {
        try FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)

        // A daemon process has no window-server connection yet; window capture
        // (SCContentFilter desktopIndependentWindow) traps with CGS_REQUIRE_INIT
        // unless CoreGraphics is initialized first.
        _ = CGMainDisplayID()

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let (filter, desc) = try Self.makeFilter(content: content, opts: opts)
        sourceDescription = desc

        let scale = filter.pointPixelScale
        width = max(2, Int(filter.contentRect.width * CGFloat(scale)) & ~1)
        height = max(2, Int(filter.contentRect.height * CGFloat(scale)) & ~1)
        if let area = opts.area {
            width = max(2, Int(area.width * Double(scale)) & ~1)
            height = max(2, Int(area.height * Double(scale)) & ~1)
        }

        let sc = SCStreamConfiguration()
        sc.width = width
        sc.height = height
        if let area = opts.area {
            sc.sourceRect = CGRect(x: area.x, y: area.y, width: area.width, height: area.height)
            sourceDescription += String(format: " area %.0f×%.0f@%.0f,%.0f", area.width, area.height, area.x, area.y)
        }
        sc.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(cfg.fps))
        sc.showsCursor = true
        sc.pixelFormat = kCVPixelFormatType_32BGRA
        sc.queueDepth = 8
        if opts.systemAudio {
            sc.capturesAudio = true
            sc.sampleRate = 48000
            sc.channelCount = 2
            sc.excludesCurrentProcessAudio = true
        }
        if opts.mic {
            sc.captureMicrophone = true
        }

        try setupWriter()

        let stream = SCStream(filter: filter, configuration: sc, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: writerQueue)
        if opts.systemAudio {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: writerQueue)
        }
        if opts.mic {
            try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: writerQueue)
        }
        try await stream.startCapture()
        self.stream = stream

        let t = DispatchSource.makeTimerSource(queue: writerQueue)
        t.schedule(deadline: .now() + 1, repeating: .milliseconds(500))
        t.setEventHandler { [weak self] in self?.repeatLastFrameIfStalled() }
        t.resume()
        repeatTimer = t
    }

    private func setupWriter() throws {
        let writer = AVAssetWriter(contentType: UTType.mpeg4Movie)
        writer.outputFileTypeProfile = .mpeg4AppleHLS
        writer.preferredOutputSegmentInterval = CMTime(seconds: cfg.segmentSeconds, preferredTimescale: 600)
        writer.delegate = self

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: Int(cfg.recordBitrateMbps * 1_000_000),
                AVVideoExpectedSourceFrameRateKey: cfg.fps,
                // Keyframe cadence must match the segment interval so every
                // fragment starts on a sync frame.
                AVVideoMaxKeyFrameIntervalDurationKey: cfg.segmentSeconds,
                AVVideoAllowFrameReorderingKey: false,
            ] as [String: Any],
        ]
        let v = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        v.expectsMediaDataInRealTime = true
        writer.add(v)
        videoIn = v

        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 160_000,
        ]
        if opts.systemAudio {
            let a = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            a.expectsMediaDataInRealTime = true
            writer.add(a)
            sysAudioIn = a
        }
        self.writer = writer

        if opts.mic {
            let mw = AVAssetWriter(contentType: UTType.mpeg4Movie)
            mw.outputFileTypeProfile = .mpeg4AppleHLS
            mw.preferredOutputSegmentInterval = CMTime(seconds: cfg.segmentSeconds, preferredTimescale: 600)
            mw.delegate = self
            let m = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            m.expectsMediaDataInRealTime = true
            mw.add(m)
            micIn = m
            micWriter = mw
        }
    }

    // MARK: - Sample handling (on writerQueue)

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sb.isValid, streamError == nil else { return }

        switch type {
        case .screen:
            guard isCompleteFrame(sb) else { return }
            if !sessionStarted {
                startWriterSession(at: sb.presentationTimeStamp)
            }
            append(sb, to: videoIn)
            if let img = CMSampleBufferGetImageBuffer(sb) {
                lastImageBuffer = img
                lastFormatDesc = CMSampleBufferGetFormatDescription(sb)
                lastVideoPTS = sb.presentationTimeStamp
            }
        case .audio:
            guard sessionStarted, sb.presentationTimeStamp >= sessionStartPTS else { return }
            append(sb, to: sysAudioIn)
        case .microphone:
            guard sessionStarted, sb.presentationTimeStamp >= sessionStartPTS else { return }
            append(sb, to: micIn)
        @unknown default:
            break
        }
    }

    private func isCompleteFrame(_ sb: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false)
            as? [[SCStreamFrameInfo: Any]],
            let statusRaw = attachments.first?[.status] as? Int,
            let status = SCFrameStatus(rawValue: statusRaw)
        else { return false }
        return status == .complete
    }

    private func startWriterSession(at pts: CMTime) {
        guard let writer else { return }
        writer.initialSegmentStartTime = pts
        guard writer.startWriting() else {
            streamError = writer.error ?? APIError(500, "asset writer failed to start")
            return
        }
        writer.startSession(atSourceTime: pts)
        // The mic writer shares the same timeline zero so the tracks line up
        // when muxed back together at finalize.
        if let micWriter {
            micWriter.initialSegmentStartTime = pts
            if micWriter.startWriting() {
                micWriter.startSession(atSourceTime: pts)
            } else {
                log("mic writer failed to start: \(String(describing: micWriter.error))")
                self.micWriter = nil
                micIn = nil
            }
        }
        sessionStartPTS = pts
        sessionStarted = true
    }

    private func append(_ sb: CMSampleBuffer, to input: AVAssetWriterInput?) {
        guard let input else { return }
        guard input.isReadyForMoreMediaData else {
            notReadyDrops += 1
            if notReadyDrops % 100 == 1 {
                log("dropping samples: writer input not ready (\(notReadyDrops) so far)")
            }
            return
        }
        if !input.append(sb) {
            streamError = writer?.error ?? APIError(500, "sample append failed")
            log("append failed: \(String(describing: writer?.error))")
        }
    }

    /// On writerQueue. Re-encode the previous frame with a fresh timestamp
    /// when SCK has gone quiet (static screen content).
    private func repeatLastFrameIfStalled() {
        guard sessionStarted, streamError == nil,
              let img = lastImageBuffer, let fmt = lastFormatDesc,
              let input = videoIn, input.isReadyForMoreMediaData,
              lastVideoPTS.isValid
        else { return }
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        guard now.seconds - lastVideoPTS.seconds > 0.9 else { return }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(cfg.fps)),
            presentationTimeStamp: now,
            decodeTimeStamp: .invalid
        )
        var sb: CMSampleBuffer?
        let status = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: img,
            formatDescription: fmt,
            sampleTiming: &timing,
            sampleBufferOut: &sb
        )
        if status == noErr, let sb, input.append(sb) {
            lastVideoPTS = now
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        log("stream stopped with error: \(error.localizedDescription)")
        writerQueue.async {
            self.streamError = error
            if !self.stoppedNotified {
                self.stoppedNotified = true
                self.onStopped?(error)
            }
        }
    }

    // MARK: - Segment output

    func assetWriter(
        _ writer: AVAssetWriter,
        didOutputSegmentData segmentData: Data,
        segmentType: AVAssetSegmentType,
        segmentReport: AVAssetSegmentReport?
    ) {
        let isMic = writer === micWriter
        ioQueue.async {
            do {
                switch segmentType {
                case .initialization:
                    let name = isMic ? "mic-init.mp4" : "init.mp4"
                    try segmentData.write(to: self.runDir.appendingPathComponent(name))
                    if isMic { self.micInitFile = name } else { self.initFile = name }
                case .separable:
                    let name: String
                    if isMic {
                        name = String(format: "mic_%05d.m4s", self.micSegIndex)
                        self.micSegIndex += 1
                    } else {
                        name = String(format: "seg_%05d.m4s", self.segIndex)
                        self.segIndex += 1
                    }
                    try segmentData.write(to: self.runDir.appendingPathComponent(name))
                    let wantedType: AVMediaType = isMic ? .audio : .video
                    let duration = segmentReport?.trackReports
                        .first(where: { $0.mediaType == wantedType })?
                        .duration.seconds ?? 0
                    let meta = SegmentMeta(file: name, duration: duration)
                    if isMic { self.micSegments.append(meta) } else { self.segments.append(meta) }
                @unknown default:
                    break
                }
            } catch {
                log("segment write failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Stop

    /// Stop capture, finish the writer, and return this run's metadata.
    func stop() async throws -> RunMeta {
        repeatTimer?.cancel()
        repeatTimer = nil
        if let stream {
            try? await stream.stopCapture()
        }
        stream = nil

        let started = writerQueue.sync { sessionStarted }
        if started, let writer {
            writerQueue.sync {
                videoIn?.markAsFinished()
                sysAudioIn?.markAsFinished()
                micIn?.markAsFinished()
            }
            await writer.finishWriting()
            if writer.status == .failed {
                log("writer finished with error: \(String(describing: writer.error))")
            }
            if let micWriter, micWriter.status == .writing {
                await micWriter.finishWriting()
            }
        } else {
            writer?.cancelWriting()
            micWriter?.cancelWriting()
        }

        // Barrier: make sure all segment files hit the disk before we report.
        let meta: RunMeta = ioQueue.sync {
            RunMeta(
                name: runName,
                initFile: initFile,
                segments: segments,
                micInitFile: micInitFile,
                micSegments: micSegments,
                hasSystemAudio: opts.systemAudio,
                hasMic: opts.mic && micInitFile != nil
            )
        }
        if let err = writerQueue.sync(execute: { streamError }) {
            log("run \(runName) ended with stream error: \(err.localizedDescription)")
        }
        return meta
    }

    // MARK: - Source resolution

    static func makeFilter(content: SCShareableContent, opts: StartOptions) throws -> (SCContentFilter, String) {
        switch opts.source {
        case "fullscreen", "display", "screen":
            let displays = content.displays
            guard !displays.isEmpty else { throw APIError(500, "no displays found") }
            let display: SCDisplay
            if let did = opts.displayID {
                guard let d = displays.first(where: { $0.displayID == did }) else {
                    throw APIError(400, "no display with id \(did)")
                }
                display = d
            } else if let idx = opts.display {
                guard idx >= 0, idx < displays.count else {
                    throw APIError(400, "display index \(idx) out of range (have \(displays.count))")
                }
                display = displays[idx]
            } else {
                display = displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? displays[0]
            }
            let excludedApps = content.applications.filter {
                (opts.excludeAppPIDs ?? []).contains($0.processID)
            }
            let filter = SCContentFilter(
                display: display,
                excludingApplications: excludedApps,
                exceptingWindows: []
            )
            return (filter, "display \(display.displayID) (\(display.width)x\(display.height))")

        case "window", "app":
            if let wid = opts.windowID {
                guard let win = content.windows.first(where: { $0.windowID == wid }) else {
                    throw APIError(404, "no on-screen window with id \(wid)")
                }
                let filter = SCContentFilter(desktopIndependentWindow: win)
                let label = "\(win.owningApplication?.applicationName ?? "?"): \(win.title ?? "untitled")"
                return (filter, "window \(label)")
            }
            guard let q = opts.query?.lowercased(), !q.isEmpty else {
                throw APIError(400, "source=\(opts.source) requires --query or --window-id")
            }
            let candidates = content.windows.filter { w in
                guard w.isOnScreen, w.frame.width >= 100, w.frame.height >= 100 else { return false }
                let title = (w.title ?? "").lowercased()
                let app = (w.owningApplication?.applicationName ?? "").lowercased()
                if opts.source == "app" { return app.contains(q) }
                return title.contains(q) || app.contains(q)
            }
            guard let win = candidates.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else {
                throw APIError(404, "no on-screen window matching \"\(opts.query ?? "")\"")
            }
            let filter = SCContentFilter(desktopIndependentWindow: win)
            let label = "\(win.owningApplication?.applicationName ?? "?"): \(win.title ?? "untitled")"
            return (filter, "window \(label)")

        default:
            throw APIError(400, "unknown source \"\(opts.source)\" (use fullscreen|window|app)")
        }
    }
}
