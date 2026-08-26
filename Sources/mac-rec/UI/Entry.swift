import Foundation
import ArgumentParser

/// Real entry point. `mac-rec ui` — or launching the Mac-Rec.app bundle with no
/// arguments — boots the AppKit menu-bar UI; everything else goes through the
/// ArgumentParser CLI.
///
/// IMPORTANT: main() must stay SYNCHRONOUS. Booting NSApplication from an
/// async main leaves the libdispatch main queue detached from the run loop, so
/// every DispatchQueue.main.async silently never executes (the UI "sees"
/// nothing). The CLI side bridges to async via a detached task instead, with
/// the real main thread parked in dispatchMain().
@main
struct Entry {
    static func main() {
        var args = Array(CommandLine.arguments.dropFirst())
        let inAppBundle = Bundle.main.bundleURL.pathExtension == "app"
        if args.isEmpty && inAppBundle { args = ["ui"] }
        // Finder/LaunchServices passes -psn_... style args on some launches.
        if inAppBundle && args.allSatisfy({ $0.hasPrefix("-psn") }) { args = ["ui"] }

        if args.first == "ui" {
            // static main() runs on the primordial main thread.
            MainActor.assumeIsolated { UIMain.boot() }
            return
        }

        let cliArgs = args
        Task.detached {
            do {
                var command = try MacRec.parseAsRoot(cliArgs)
                if var asyncCommand = command as? AsyncParsableCommand {
                    try await asyncCommand.run()
                } else {
                    try command.run()
                }
                MacRec.exit()
            } catch {
                MacRec.exit(withError: error)
            }
        }
        dispatchMain()  // parked; the CLI task calls exit()
    }
}
