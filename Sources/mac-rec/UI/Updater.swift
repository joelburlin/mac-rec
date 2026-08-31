import AppKit

/// Checks GitHub Releases for a newer build. There is no Sparkle feed and no
/// auto-install: this points the user at the release, which is honest for an
/// unnotarized app they have to approve themselves.
@MainActor
enum Updater {
    static let releasesAPI = "https://api.github.com/repos/joelburlin/mac-rec/releases/latest"
    static let releasesPage = "https://github.com/joelburlin/mac-rec/releases/latest"

    private static let lastCheckKey = "lastUpdateCheck"
    private static let skippedKey = "skippedVersion"

    struct Release {
        let version: String      // "0.5.0"
        let tag: String          // "v0.5.0"
        let url: String
        let notes: String
    }

    /// `silent` = launch-time check: says nothing unless there's a new version.
    static func check(silent: Bool) {
        if silent {
            let last = UserDefaults.standard.double(forKey: lastCheckKey)
            guard Date().timeIntervalSince1970 - last > 86_400 else { return }
        }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastCheckKey)

        DispatchQueue.global().async {
            let result = fetchLatest()
            DispatchQueue.main.async {
                switch result {
                case .success(let release):
                    if isNewer(release.version, than: macRecVersion) {
                        if silent, UserDefaults.standard.string(forKey: skippedKey) == release.version { return }
                        presentUpdate(release, silent: silent)
                    } else if !silent {
                        let a = NSAlert()
                        a.messageText = "You're up to date"
                        a.informativeText = "mac-rec \(macRecVersion) is the latest version."
                        NSApp.activate(ignoringOtherApps: true)
                        a.runModal()
                    }
                case .failure(let error):
                    guard !silent else { return }
                    let a = NSAlert()
                    a.messageText = "Couldn't check for updates"
                    a.informativeText = error.localizedDescription
                    a.alertStyle = .warning
                    NSApp.activate(ignoringOtherApps: true)
                    a.runModal()
                }
            }
        }
    }

    private static func presentUpdate(_ release: Release, silent: Bool) {
        let a = NSAlert()
        a.messageText = "mac-rec \(release.version) is available"
        a.informativeText = "You have \(macRecVersion).\n\n"
            + String(release.notes.prefix(320))
        a.addButton(withTitle: "Download")
        a.addButton(withTitle: "Later")
        if silent { a.addButton(withTitle: "Skip This Version") }
        NSApp.activate(ignoringOtherApps: true)
        switch a.runModal() {
        case .alertFirstButtonReturn:
            NSWorkspace.shared.open(URL(string: release.url)!)
        case .alertThirdButtonReturn:
            UserDefaults.standard.set(release.version, forKey: skippedKey)
        default:
            break
        }
    }

    private static func fetchLatest() -> Result<Release, Error> {
        var req = URLRequest(url: URL(string: releasesAPI)!)
        req.timeoutInterval = 15
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("mac-rec/\(macRecVersion)", forHTTPHeaderField: "User-Agent")

        let sem = DispatchSemaphore(value: 0)
        var out: Result<Release, Error>!
        URLSession.shared.dataTask(with: req) { data, resp, err in
            defer { sem.signal() }
            if let err { out = .failure(err); return }
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200, let data,
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = root["tag_name"] as? String
            else {
                out = .failure(APIError(status, "GitHub returned HTTP \(status)"))
                return
            }
            let page = (root["html_url"] as? String) ?? releasesPage
            let notes = (root["body"] as? String) ?? ""
            out = .success(Release(
                version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag,
                tag: tag, url: page, notes: notes
            ))
        }.resume()
        sem.wait()
        return out
    }

    /// Numeric semver compare — "0.10.0" must beat "0.9.0".
    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
