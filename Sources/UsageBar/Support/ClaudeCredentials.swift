import Foundation

// Load Claude Code's OAuth access token for a specific config dir.
//
// Claude Code's config lives at $CLAUDE_CONFIG_DIR (default: ~/.claude).
// The default install typically stores the token in the login Keychain
// under service `Claude Code-credentials`; some installs (and every
// isolated CLAUDE_CONFIG_DIR install) keep a copy in
//   <configDir>/.credentials.json
// We try the file first (works for any config dir), then fall back to
// Keychain only for the default `~/.claude` install.  The token is used
// once per poll and never cached.
enum ClaudeCredentials {

    static let defaultConfigDir = ("~/.claude" as NSString).expandingTildeInPath

    static func loadAccessToken(configDir: String = defaultConfigDir) -> String? {
        if let t = fromCredentialsFile(configDir: configDir) { return t }
        if configDir == defaultConfigDir, let t = fromKeychain() { return t }
        return nil
    }

    private struct Envelope: Decodable {
        struct OAuth: Decodable { let accessToken: String? }
        let claudeAiOauth: OAuth?
    }

    private static func decodeEnvelope(_ data: Data) -> String? {
        if let env = try? JSONDecoder().decode(Envelope.self, from: data),
           let t = env.claudeAiOauth?.accessToken, !t.isEmpty {
            return t
        }
        return nil
    }

    private static func fromCredentialsFile(configDir: String) -> String? {
        let path = "\(configDir)/.credentials.json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return nil
        }
        return decodeEnvelope(data)
    }

    // Shells out to `security` — first hit prompts the user to grant access to
    // that specific keychain item, then it's silent.  Hard-timed at 5s so a
    // stuck dialog can't freeze the poll loop.
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
