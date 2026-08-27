import Foundation

/// Minimal ElevenLabs client (synchronous — the finalize pipeline is serial).
enum ElevenLabs {
    static let base = "https://api.elevenlabs.io/v1"

    struct Voice {
        let id: String
        let name: String
        let description: String
    }

    struct Speech {
        let mp3: Data
        /// Per-character timings of the generated audio, when the API
        /// returned them (v3 alpha sometimes doesn't).
        let charStarts: [Double]
        let charEnds: [Double]
        let characters: [String]
        let modelUsed: String
    }

    // MARK: - Voices

    static func listVoices(key: String) throws -> [Voice] {
        var req = URLRequest(url: URL(string: "\(base)/voices")!)
        req.setValue(key, forHTTPHeaderField: "xi-api-key")
        req.timeoutInterval = 30
        let (data, status) = try send(req)
        guard status == 200 else {
            throw APIError(status, "ElevenLabs /voices failed: \(shortBody(data))")
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["voices"] as? [[String: Any]]
        else { throw APIError(500, "unreadable /voices response") }
        return items.compactMap { v in
            guard let id = v["voice_id"] as? String, let name = v["name"] as? String else { return nil }
            var bits: [String] = []
            if let labels = v["labels"] as? [String: Any] {
                for k in ["gender", "accent", "age", "use_case", "description"] {
                    if let s = labels[k] as? String, !s.isEmpty { bits.append(s) }
                }
            }
            return Voice(id: id, name: name, description: bits.joined(separator: ", "))
        }
    }

    // MARK: - TTS

    /// Speak one chunk. Tries the timestamped endpoint first (exact character
    /// timings → captions that match the synthetic audio sample-for-sample),
    /// then plain TTS, then a known-good model.
    static func speak(
        text: String,
        voiceID: String,
        model: String,
        key: String,
        previous: String?,
        next: String?
    ) throws -> Speech {
        var lastError: Error?
        for (m, timestamps) in [(model, true), (model, false), ("eleven_multilingual_v2", true)] {
            do {
                return try request(
                    text: text, voiceID: voiceID, model: m, key: key,
                    previous: previous, next: next, timestamps: timestamps
                )
            } catch {
                lastError = error
            }
        }
        throw lastError ?? APIError(500, "ElevenLabs TTS failed")
    }

    private static func request(
        text: String,
        voiceID: String,
        model: String,
        key: String,
        previous: String?,
        next: String?,
        timestamps: Bool
    ) throws -> Speech {
        let path = timestamps
            ? "\(base)/text-to-speech/\(voiceID)/with-timestamps"
            : "\(base)/text-to-speech/\(voiceID)"
        var req = URLRequest(url: URL(string: path)!)
        req.httpMethod = "POST"
        req.timeoutInterval = 180
        req.setValue(key, forHTTPHeaderField: "xi-api-key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // v3 carries its own emotional delivery and rejects the continuity
        // fields outright ("not yet supported with the 'eleven_v3' model").
        let isV3 = model.hasPrefix("eleven_v3")
        var body: [String: Any] = [
            "text": text,
            "model_id": model,
            "voice_settings": isV3
                ? ["stability": 0.5, "use_speaker_boost": true]
                : ["stability": 0.45, "similarity_boost": 0.8, "style": 0.3, "use_speaker_boost": true],
        ]
        if !isV3 {
            // Prosody continuity across chunk boundaries.
            if let previous, !previous.isEmpty { body["previous_text"] = previous }
            if let next, !next.isEmpty { body["next_text"] = next }
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, status) = try send(req)
        guard status == 200 else {
            throw APIError(status, "ElevenLabs TTS \(status): \(shortBody(data))")
        }

        if timestamps {
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let b64 = root["audio_base64"] as? String,
                  let audio = Data(base64Encoded: b64)
            else { throw APIError(500, "unreadable timestamped TTS response") }
            let align = (root["alignment"] as? [String: Any])
                ?? (root["normalized_alignment"] as? [String: Any])
            let chars = (align?["characters"] as? [String]) ?? []
            let starts = (align?["character_start_times_seconds"] as? [Double]) ?? []
            let ends = (align?["character_end_times_seconds"] as? [Double]) ?? []
            return Speech(mp3: audio, charStarts: starts, charEnds: ends,
                          characters: chars, modelUsed: model)
        }
        return Speech(mp3: data, charStarts: [], charEnds: [], characters: [], modelUsed: model)
    }

    // MARK: - Plumbing

    private static func send(_ req: URLRequest) throws -> (Data, Int) {
        let sem = DispatchSemaphore(value: 0)
        var out: Result<(Data, Int), Error>!
        URLSession.shared.dataTask(with: req) { data, resp, err in
            if let err {
                out = .failure(err)
            } else {
                out = .success((data ?? Data(), (resp as? HTTPURLResponse)?.statusCode ?? 0))
            }
            sem.signal()
        }.resume()
        sem.wait()
        return try out.get()
    }

    private static func shortBody(_ data: Data) -> String {
        let s = String(data: data, encoding: .utf8) ?? "<binary>"
        return String(s.prefix(240))
    }
}
