import Foundation
import ArgumentParser
import ScreenCaptureKit

struct ListSources: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List capturable displays and windows."
    )

    @Option(help: "Filter windows by title / app substring.")
    var query: String?

    func run() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

        print("displays:")
        for (i, d) in content.displays.enumerated() {
            let main = d.displayID == CGMainDisplayID() ? "  (main)" : ""
            print("  [\(i)] id=\(d.displayID) \(d.width)x\(d.height)\(main)")
        }

        print("windows:")
        let q = query?.lowercased()
        let windows = content.windows
            .filter { $0.isOnScreen && $0.frame.width >= 100 && $0.frame.height >= 100 }
            .filter { w in
                guard let q else { return true }
                let title = (w.title ?? "").lowercased()
                let app = (w.owningApplication?.applicationName ?? "").lowercased()
                return title.contains(q) || app.contains(q)
            }
            .sorted {
                ($0.owningApplication?.applicationName ?? "") < ($1.owningApplication?.applicationName ?? "")
            }
        for w in windows {
            let app = w.owningApplication?.applicationName ?? "?"
            let title = w.title?.isEmpty == false ? w.title! : "(untitled)"
            print("  \(app) — \(title)  [\(Int(w.frame.width))x\(Int(w.frame.height))]")
        }
    }
}
