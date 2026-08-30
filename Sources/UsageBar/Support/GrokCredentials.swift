import Foundation

// Reads the Grok CLI's sign-in from `$GROK_HOME/auth.json` (default `~/.grok`).
// The file is a map of OIDC-scope keys to credential objects.  We prefer
// `https://auth.x.ai::<client>` (SuperGrok) and fall back to any entry that
// still has a bearer `key`.  Token is read fresh every call — never cached.
enum GrokCredentials {

    struct Credentials {
        let accessToken: String
        let email: String?
        let teamID: String?
        let expiresAt: Date?
        let principalType: String?
    }

    static var defaultHome: String {
        if let env = ProcessInfo.processInfo.environment["GROK_HOME"], !env.isEmpty {
            return (env as NSString).expandingTildeInPath
        }
        return ("~/.grok" as NSString).expandingTildeInPath
    }

    static func load(home: String = GrokCredentials.defaultHome) -> Credentials? {
        let url = URL(fileURLWithPath: home).appendingPathComponent("auth.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let preferred = obj.keys.sorted { a, b in
            let aScore = a.hasPrefix("https://auth.x.ai") ? 0 : 1
            let bScore = b.hasPrefix("https://auth.x.ai") ? 0 : 1
            return aScore == bScore ? a < b : aScore < bScore
        }

        for key in preferred {
            guard let entry = obj[key] as? [String: Any],
                  let token = entry["key"] as? String, !token.isEmpty
            else { continue }
            return Credentials(
                accessToken: token,
                email: nonempty(entry["email"] as? String),
                teamID: nonempty(entry["team_id"] as? String),
                expiresAt: parseDate(entry["expires_at"] as? String),
                principalType: nonempty(entry["principal_type"] as? String)
            )
        }
        return nil
    }

    /// Inference / management keys live outside auth.json.  GUI apps don't
    /// inherit the user's shell, so we also look at well-known files.
    static func loadAPIKey() -> String? {
        for name in ["XAI_API_KEY", "GROK_API_KEY"] {
            if let v = ProcessInfo.processInfo.environment[name], !v.isEmpty {
                return v
            }
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for rel in [".xai/api_key", ".grok/api_key"] {
            let path = "\(home)/\(rel)"
            if let raw = try? String(contentsOfFile: path, encoding: .utf8) {
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    private static func nonempty(_ s: String?) -> String? {
        guard let s, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return s
    }

    private static func parseDate(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: raw) { return d }
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: raw)
    }
}
