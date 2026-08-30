import Foundation
import AppKit

// Best-effort launchers for the three SignInAction kinds.  We never enter
// credentials for the user — we just open their own sign-in surface and let
// them do it.
@MainActor
enum SignInLauncher {

    static func perform(_ action: SignInAction) {
        switch action {
        case .runCommand(let cmd, _):
            openTerminal(runningCommand: cmd)
        case .openApp(let bundleID, let appName, _):
            openApp(bundleID: bundleID, appName: appName)
        case .openURL(let url, _):
            NSWorkspace.shared.open(url)
        }
    }

    private static func openTerminal(runningCommand cmd: String) {
        let escaped = cmd.replacingOccurrences(of: "\\", with: "\\\\")
                          .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "tell application \"Terminal\"\nactivate\ndo script \"\(escaped)\"\nend tell"
        if let apple = NSAppleScript(source: script) {
            var err: NSDictionary?
            apple.executeAndReturnError(&err)
            if err == nil { return }
        }
        // AppleScript blocked (e.g. Automation permission denied) — copy the
        // command to the clipboard and open Terminal so the user can paste.
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(cmd, forType: .string)
        openApp(bundleID: "com.apple.Terminal", appName: "Terminal")
    }

    private static func openApp(bundleID: String?, appName: String) {
        if let id = bundleID,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            NSWorkspace.shared.openApplication(at: url,
                                                configuration: NSWorkspace.OpenConfiguration(),
                                                completionHandler: nil)
            return
        }
        if let url = NSWorkspace.shared.urlForApplication(toOpen: URL(fileURLWithPath: "/tmp"))
                        ?? NSWorkspace.shared.urlForApplication(
                            withBundleIdentifier: "com.apple.finder") {
            _ = url  // suppress warning
        }
        // Last resort: try common paths for the named app.
        for path in ["/Applications/\(appName).app", "/System/Applications/\(appName).app"] {
            let u = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: path) {
                NSWorkspace.shared.openApplication(at: u,
                                                    configuration: NSWorkspace.OpenConfiguration(),
                                                    completionHandler: nil)
                return
            }
        }
    }
}
