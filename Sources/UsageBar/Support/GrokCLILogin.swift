import Foundation
import AppKit

// SuperGrok sign-in without opening Terminal.  The Grok CLI's `grok login
// --oauth` already drives the browser itself; we spawn it as a detached
// process so UsageBar never AppleScripts Terminal.app (that's what the
// Codex path does, and it's what Add Provider was accidentally doing).
enum GrokCLILogin {

    static func launch() {
        if let grok = findBinary() {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: grok)
            task.arguments = ["login", "--oauth"]
            task.standardOutput = FileHandle.nullDevice
            task.standardError = FileHandle.nullDevice
            do {
                try task.run()
                return
            } catch {
                // Fall through to the browser.
            }
        }
        if let url = URL(string: "https://accounts.x.ai/sign-in") {
            NSWorkspace.shared.open(url)
        }
    }

    private static func findBinary() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin/grok",
            "/opt/homebrew/bin/grok",
            "/usr/local/bin/grok",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return ShellRunner.run("/usr/bin/which", args: ["grok"], timeout: 2)
    }
}
