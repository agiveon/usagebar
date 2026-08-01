import Foundation
import SwiftUI
import AppKit

// Runs the whole `claude auth login` flow as a background subprocess so we
// can spare the user any Terminal handoff.  Life-cycle:
//   1. start()             — spawn `claude auth login --claudeai` with
//                            CLAUDE_CONFIG_DIR pointed at a fresh dir; read
//                            stdout until we see the OAuth URL.
//   2. state = .waitingForBrowser(url) — the UI hands that URL to the user's
//                            default browser so Google/Anthropic don't block
//                            the sign-in (WKWebView is refused).
//   3. provideCode(code)   — the user pastes the code back from the browser
//                            callback.  We write it to the CLI's stdin,
//                            close the pipe so it sees EOF, and wait for
//                            either the credentials file to appear or the
//                            process to exit.
//   4. Terminal state      — .done(configDir) on success, or .failed(reason)
//                            with whatever `claude` printed as its last words.
//
// Two things this file spent a lot of effort getting right:
// - We keep reading stdout continuously (not just until the URL match) —
//   otherwise the CLI eventually blocks writing when the pipe fills, and
//   the whole flow hangs.
// - We hook `terminationHandler` so we react to CLI exit immediately.  When
//   `claude auth login` fails (bad code, expired code, network) it exits
//   with a nonzero status; we surface its last 400 chars of stdout so the
//   user sees the actual error, not "didn't complete in time".
@MainActor
final class ClaudeAuthSession: ObservableObject {

    enum State: Equatable {
        case starting
        case waitingForBrowser(URL)
        case finalizing
        case done(configDir: String)
        case failed(reason: String)
    }

    @Published private(set) var state: State = .starting
    let configDir: String

    private var task: Process?
    private var stdinPipe: Pipe?
    private var readerTask: Task<Void, Never>?
    private var pollerTask: Task<Void, Never>?
    private var didAcceptCode = false
    /// Keychain services present before we spawned claude — anything that
    /// appears after sign-in is our newly-signed-in account.
    private var baselineKeychainServices: Set<String> = []
    /// Everything the CLI has printed so far (stdout + stderr merged).
    /// Written by the reader task via MainActor.run, read by the exit
    /// handler and by the failure paths so users see the CLI's own error
    /// text rather than "didn't complete in time".
    private var capturedOutput: String = ""

    init() {
        self.configDir = Self.pickFreshConfigDir()
    }

    func start() {
        state = .starting

        guard let cli = Self.findClaudeBinary() else {
            state = .failed(reason: """
Couldn't find the `claude` CLI on this Mac.

Install Claude Code first (https://claude.com/download), then try again.
""")
            return
        }

        // Fresh dir — leftover state confuses claude's "first-run" detection.
        try? FileManager.default.removeItem(atPath: configDir)

        // Snapshot existing Keychain services so we can detect the new one.
        baselineKeychainServices = Set(ClaudeCredentials.discoverKeychainServices())

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: cli)
        proc.arguments = ["auth", "login", "--claudeai"]

        var env = ProcessInfo.processInfo.environment
        env["CLAUDE_CONFIG_DIR"] = configDir
        env["NO_BROWSER"] = "1"    // don't let the CLI open Safari itself
        env["BROWSER"] = "true"
        proc.environment = env

        let stdin  = Pipe()
        let stdout = Pipe()
        proc.standardInput  = stdin
        proc.standardOutput = stdout
        proc.standardError  = stdout

        // Exit handler — fires the instant the CLI dies (success or failure).
        proc.terminationHandler = { [weak self] terminated in
            let code = terminated.terminationStatus
            Task { @MainActor [weak self] in
                await self?.handleProcessExit(exitCode: code)
            }
        }

        do {
            try proc.run()
        } catch {
            state = .failed(reason: "Couldn't start the sign-in helper: \(error.localizedDescription)")
            return
        }

        self.task = proc
        self.stdinPipe = stdin

        // Continuously drain stdout: publish captured text back to main,
        // detect the OAuth URL the first time it appears.  We keep going
        // after the URL match so the pipe never blocks and so we still
        // have the CLI's final messages when it exits.
        let handle = stdout.fileHandleForReading
        readerTask = Task.detached { [weak self] in
            var buffer = Data()
            var urlPublished = false
            let pattern = try? NSRegularExpression(
                pattern: "(https://[^\\s]+/oauth/authorize\\?[^\\s]+)")

            while !Task.isCancelled {
                let chunk = handle.availableData
                if chunk.isEmpty { return }   // EOF — process closed stdout
                buffer.append(chunk)
                let text = String(data: buffer, encoding: .utf8) ?? ""

                // Snapshot for the exit / failure handlers.
                await MainActor.run { [weak self] in
                    self?.capturedOutput = text
                }

                if !urlPublished, let pattern,
                   let match = pattern.firstMatch(
                    in: text, range: NSRange(text.startIndex..., in: text)),
                   let range = Range(match.range(at: 1), in: text),
                   let url = URL(string: String(text[range])) {
                    urlPublished = true
                    await MainActor.run { [weak self] in
                        guard let self, case .starting = self.state else { return }
                        self.state = .waitingForBrowser(url)
                    }
                }
            }
        }

        // Safety net: if we haven't produced the URL within 20 s, something
        // is wrong (CLI hung, network, output format changed).  Bail clearly.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 20 * 1_000_000_000)
            guard let self else { return }
            if case .starting = self.state {
                self.state = .failed(reason:
                    "Timed out waiting for the sign-in URL from claude:\n\n" +
                    String(self.capturedOutput.suffix(400)))
                self.terminateAndClean()
            }
        }
    }

    /// Called by the SignInView once the user pastes the callback code.
    /// We hand it off to the CLI via stdin (and close the pipe so the CLI
    /// sees EOF).  Result comes back via `terminationHandler` — either
    /// creds land on disk (=> .done) or the CLI dies with an error we
    /// surface verbatim.
    func provideCode(_ code: String) {
        guard !didAcceptCode else { return }
        didAcceptCode = true
        guard let stdin = stdinPipe else { return }
        state = .finalizing

        let line = code + "\n"
        do {
            try stdin.fileHandleForWriting.write(contentsOf: Data(line.utf8))
            try stdin.fileHandleForWriting.close()
        } catch {
            state = .failed(reason: "Couldn't hand off the code: \(error.localizedDescription)")
            terminateAndClean()
            return
        }

        // Backup poller in case terminationHandler is delayed for any reason
        // (rare — but if it does happen, the poll spots creds quickly).
        pollerTask = Task { [weak self] in
            let deadline = Date().addingTimeInterval(60)
            while Date() < deadline {
                try? await Task.sleep(nanoseconds: 400_000_000)
                if Task.isCancelled { return }
                guard let self else { return }
                if self.credsReady() {
                    await MainActor.run {
                        if case .finalizing = self.state {
                            self.state = .done(configDir: self.configDir)
                            self.task?.terminate()
                        }
                    }
                    return
                }
            }
        }
    }

    /// A new Keychain item (any `Claude Code-credentials*` service that
    /// wasn't there at start) or a `.credentials.json` file at our config
    /// dir both count as success.
    private func credsReady() -> Bool {
        let current = Set(ClaudeCredentials.discoverKeychainServices())
        if !current.subtracting(baselineKeychainServices).isEmpty { return true }
        let path = "\(configDir)/.credentials.json"
        return FileManager.default.fileExists(atPath: path)
    }

    private func handleProcessExit(exitCode: Int32) async {
        // Give the CLI a beat to flush the creds file / Keychain item.
        try? await Task.sleep(nanoseconds: 300_000_000)

        switch state {
        case .done, .failed: return
        default: break
        }

        if credsReady() {
            state = .done(configDir: configDir)
            return
        }

        // Trim ANSI escape sequences and the URL noise out of the tail so
        // the user sees the useful last message from claude, not the huge
        // OAuth URL again.
        let tail = Self.cleanTail(capturedOutput, maxChars: 400)
        state = .failed(reason: """
`claude auth login` exited (code \(exitCode)) without saving credentials.

Last output:
\(tail)
""")
        try? FileManager.default.removeItem(atPath: configDir)
    }

    func cancel() {
        terminateAndClean()
    }

    private func terminateAndClean() {
        readerTask?.cancel()
        pollerTask?.cancel()
        task?.terminationHandler = nil     // avoid firing after cancel
        task?.terminate()
        if !credsReady() {
            try? FileManager.default.removeItem(atPath: configDir)
        }
    }

    // MARK: - Static helpers

    static func findClaudeBinary() -> String? {
        let candidates = [
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "/usr/bin/claude",
            expand("~/.npm-global/bin/claude"),
            expand("~/.bun/bin/claude"),
            expand("~/.local/bin/claude"),
            expand("~/.volta/bin/claude"),
            expand("~/.claude/local/claude"),
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        if let path = ShellRunner.run(
            "/bin/zsh",
            args: ["-lic", "command -v claude"],
            timeout: 3
        ), !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    private static func expand(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

    private static func pickFreshConfigDir() -> String {
        var n = 2
        while true {
            let path = expand("~/.claude-\(n)")
            if !FileManager.default.fileExists(atPath: path) { return path }
            n += 1
        }
    }

    /// Strip ANSI escapes + drop lines that are just the OAuth URL (which
    /// we already surfaced) so what's left is the CLI's actual final say.
    private static func cleanTail(_ raw: String, maxChars: Int) -> String {
        let ansi = try? NSRegularExpression(pattern: "\u{001B}\\[[0-9;?]*[A-Za-z]")
        var text = raw
        if let ansi {
            text = ansi.stringByReplacingMatches(
                in: text,
                range: NSRange(text.startIndex..., in: text),
                withTemplate: "")
        }
        let lines = text.split(whereSeparator: \.isNewline).filter { line in
            !line.contains("/oauth/authorize?")
            && !line.contains("If the browser didn't open")
            && !line.contains("Opening browser to sign in")
        }
        let joined = lines.joined(separator: "\n")
        return String(joined.suffix(maxChars)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
