import Foundation
import ArgumentParser

struct VoicesCmd: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "voices",
        abstract: "List ElevenLabs voices (and optionally pick one as the default)."
    )

    @Option(help: "Set the default voice by name substring or id.")
    var use: String?

    @Flag(help: "Print machine-readable JSON.")
    var json = false

    func run() throws {
        var cfg = Config.load()
        guard let key = cfg.resolveElevenKey() else {
            throw ValidationError(
                "no ElevenLabs API key — `mac-rec setup --eleven-key sk_...` "
                + "or export ELEVENLABS_API_KEY")
        }
        let voices = try ElevenLabs.listVoices(key: key)

        if let want = use {
            let needle = want.lowercased()
            guard let match = voices.first(where: { $0.id == want })
                ?? voices.first(where: { $0.name.lowercased().contains(needle) })
            else { throw ValidationError("no voice matching \"\(want)\"") }
            cfg.elevenVoiceID = match.id
            cfg.elevenVoiceName = match.name
            try cfg.save()
            print("default voice set: \(match.name) (\(match.id))")
            return
        }

        if json {
            let payload = voices.map { ["id": $0.id, "name": $0.name, "description": $0.description] }
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted])
            print(String(data: data, encoding: .utf8) ?? "[]")
            return
        }
        print("voices:  (use `mac-rec voices --use NAME` to set the default)")
        for v in voices {
            let mark = v.id == cfg.elevenVoiceID ? "  ← default" : ""
            let desc = v.description.isEmpty ? "" : "  — \(v.description)"
            print("  \(v.name)\(desc)\(mark)")
            print("    id=\(v.id)")
        }
    }
}
