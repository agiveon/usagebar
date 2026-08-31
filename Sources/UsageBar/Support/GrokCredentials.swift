import Foundation

// Grok CLI OIDC session (`$GROK_HOME/auth.json`, default ~/.grok) and the
// optional developer API key.  Read fresh every call — never cached.
enum GrokCredentials {
    static let billingURL = URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!

    struct Credentials {
        let accessToken: String
        let email: String?
    }

    static func load() -> Credentials? {
        let home = ProcessInfo.processInfo.environment["GROK_HOME"]
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? ("~/.grok" as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: home).appendingPathComponent("auth.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let keys = obj.keys.sorted()
        for key in keys.filter({ $0.hasPrefix("https://auth.x.ai") }) + keys.filter({ !$0.hasPrefix("https://auth.x.ai") }) {
            guard let entry = obj[key] as? [String: Any],
                  let token = entry["key"] as? String, !token.isEmpty else { continue }
            let email = (entry["email"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return Credentials(accessToken: token, email: email?.isEmpty == false ? email : nil)
        }
        return nil
    }

    static func loadAPIKey() -> String? {
        for name in ["XAI_API_KEY", "GROK_API_KEY"] {
            if let v = ProcessInfo.processInfo.environment[name], !v.isEmpty { return v }
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for rel in [".xai/api_key", ".grok/api_key"] {
            if let raw = try? String(contentsOfFile: "\(home)/\(rel)", encoding: .utf8) {
                let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { return t }
            }
        }
        return nil
    }
}
