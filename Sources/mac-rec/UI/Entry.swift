import Foundation
import ArgumentParser

/// Real entry point. `mac-rec ui` — or launching the Mac-Rec.app bundle with no
/// arguments — boots the AppKit menu-bar UI on the main thread; everything else
/// goes through the ArgumentParser CLI.
@main
struct Entry {
    static func main() async {
        var args = Array(CommandLine.arguments.dropFirst())
        let inAppBundle = Bundle.main.bundleURL.pathExtension == "app"
        if args.isEmpty && inAppBundle { args = ["ui"] }
        // Finder/LaunchServices passes -psn_... style args on some launches.
        if inAppBundle && args.allSatisfy({ $0.hasPrefix("-psn") }) { args = ["ui"] }

        if args.first == "ui" {
            // Never returns; async main starts on the main actor and AppKit
            // must own the main thread from here on.
            await MainActor.run { UIMain.boot() }
            return
        }

        do {
            var command = try MacRec.parseAsRoot(args)
            if var asyncCommand = command as? AsyncParsableCommand {
                try await asyncCommand.run()
            } else {
                try command.run()
            }
        } catch {
            MacRec.exit(withError: error)
        }
    }
}
