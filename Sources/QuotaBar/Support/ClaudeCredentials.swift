import Foundation

// Load Claude Code's OAuth access token.
//
// Claude Code on macOS stores its credentials in the login Keychain under the
// generic-password service `Claude Code-credentials` (a JSON blob).  Some
// installs (e.g. --dangerously-skip-permissions setups, CI images, and users
// who opted out of Keychain storage) also keep a copy at
// ~/.claude/.credentials.json.  We try Keychain first, then the file — the
// token is used once per poll and never cached.
enum ClaudeCredentials {

    static func loadAccessToken() -> String? {
        if let t = fromKeychain() { return t }
        if let t = fromCredentialsFile() { return t }
        return nil
    }

    private struct Envelope: Decodable {
        struct OAuth: Decodable { let accessToken: String? }
        let claudeAiOauth: OAuth?
    }

    private static func decodeEnvelope(_ data: Data) -> String? {
        let decoder = JSONDecoder()
        if let env = try? decoder.decode(Envelope.self, from: data),
           let t = env.claudeAiOauth?.accessToken, !t.isEmpty {
            return t
        }
        return nil
    }

    private static func fromCredentialsFile() -> String? {
        let path = ("~/.claude/.credentials.json" as NSString).expandingTildeInPath
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return nil
        }
        return decodeEnvelope(data)
    }

    // Shells out to `security` — first hit prompts the user to grant access to
    // that specific keychain item, then it's silent.  Avoids linking against
    // Security.framework directly.  Hard-timed at 5s so a stuck dialog can't
    // freeze the poll loop.
    private static func fromKeychain() -> String? {
        guard let raw = ShellRunner.run(
            "/usr/bin/security",
            args: ["find-generic-password", "-s", "Claude Code-credentials", "-w"],
            timeout: 5.0
        ) else { return nil }
        guard let jsonData = raw.data(using: .utf8) else { return nil }
        return decodeEnvelope(jsonData)
    }
}
