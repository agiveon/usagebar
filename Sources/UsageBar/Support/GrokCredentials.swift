import Foundation

// Grok CLI OIDC session at `$GROK_HOME/auth.json` (default `~/.grok`) and
// the optional developer API key.  Tokens are read fresh every call.
enum GrokCredentials {

    struct Credentials {
        let accessToken: String
        let email: String?
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

        // Prefer SuperGrok OIDC (`https://auth.x.ai::<client>`), then any bearer.
        let keys = obj.keys.sorted()
        let ordered = keys.filter { $0.hasPrefix("https://auth.x.ai") }
            + keys.filter { !$0.hasPrefix("https://auth.x.ai") }
        for key in ordered {
            guard let entry = obj[key] as? [String: Any],
                  let token = entry["key"] as? String, !token.isEmpty
            else { continue }
            let email = (entry["email"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return Credentials(accessToken: token,
                               email: (email?.isEmpty == false) ? email : nil)
        }
        return nil
    }

    /// GUI apps don't inherit the user's shell, so also check well-known files.
    static func loadAPIKey() -> String? {
        for name in ["XAI_API_KEY", "GROK_API_KEY"] {
            if let v = ProcessInfo.processInfo.environment[name], !v.isEmpty {
                return v
            }
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for rel in [".xai/api_key", ".grok/api_key"] {
            if let raw = try? String(contentsOfFile: "\(home)/\(rel)", encoding: .utf8) {
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }
}
