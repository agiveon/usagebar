import Foundation

// Reads the Codex CLI's sign-in from <configDir>/auth.json.  Default
// configDir is $CODEX_HOME or ~/.codex.  Additional accounts get their
// own dir (via `CODEX_HOME=~/.codex-work codex login`).
enum CodexCredentials {

    struct Credentials {
        let accessToken: String
        let chatgptAccountId: String?
    }

    static var defaultConfigDir: String {
        if let env = ProcessInfo.processInfo.environment["CODEX_HOME"], !env.isEmpty {
            return env
        }
        return ("~/.codex" as NSString).expandingTildeInPath
    }

    static func load(configDir: String = CodexCredentials.defaultConfigDir) -> Credentials? {
        let url = URL(fileURLWithPath: configDir).appendingPathComponent("auth.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        guard let tokens = obj["tokens"] as? [String: Any],
              let access = tokens["access_token"] as? String, !access.isEmpty else {
            return nil
        }
        let accountId = (tokens["account_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? chatgptAccountIdFromIdToken(tokens: tokens)
        return Credentials(accessToken: access, chatgptAccountId: accountId)
    }

    private static func chatgptAccountIdFromIdToken(tokens: [String: Any]) -> String? {
        if let dict = tokens["id_token"] as? [String: Any],
           let acc = dict["chatgpt_account_id"] as? String, !acc.isEmpty {
            return acc
        }
        let jwt: String?
        if let s = tokens["id_token"] as? String {
            jwt = s
        } else if let dict = tokens["id_token"] as? [String: Any] {
            jwt = dict["raw_jwt"] as? String
        } else {
            jwt = nil
        }
        return jwt.flatMap(decodeAccountIdFromJWT)
    }

    private static func decodeAccountIdFromJWT(_ jwt: String) -> String? {
        let parts = jwt.split(separator: ".")
        guard parts.count == 3 else { return nil }
        let payload = String(parts[1])
        var b64 = payload.replacingOccurrences(of: "-", with: "+")
                          .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64.append("=") }
        guard let data = Data(base64Encoded: b64),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let auth = obj["https://api.openai.com/auth"] as? [String: Any],
           let acc = auth["chatgpt_account_id"] as? String, !acc.isEmpty {
            return acc
        }
        return nil
    }
}
