import Foundation

// Reads the Codex CLI's sign-in from $CODEX_HOME/auth.json (default: ~/.codex).
// For ChatGPT-signed-in accounts we need both the access_token and the
// ChatGPT-Account-Id; API-key-only installs (OPENAI_API_KEY without `tokens`)
// don't expose a usage endpoint, so we report that as "not available".
enum CodexCredentials {

    struct Credentials {
        let accessToken: String
        let chatgptAccountId: String?
    }

    static func load() -> Credentials? {
        let dir = ProcessInfo.processInfo.environment["CODEX_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? ("~/.codex" as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: dir).appendingPathComponent("auth.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        guard let tokens = obj["tokens"] as? [String: Any],
              let access = tokens["access_token"] as? String, !access.isEmpty else {
            return nil
        }
        // Prefer explicit account_id; fall back to decoding the JWT id_token.
        let accountId = (tokens["account_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? chatgptAccountIdFromIdToken(tokens: tokens)
        return Credentials(accessToken: access, chatgptAccountId: accountId)
    }

    // id_token may be stored either as a raw JWT string or as a
    // pre-decoded `{ raw_jwt, chatgpt_account_id, ... }` object.
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
        // JWT is base64url with no padding.
        var b64 = payload.replacingOccurrences(of: "-", with: "+")
                          .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64.append("=") }
        guard let data = Data(base64Encoded: b64),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        // Codex stores the account id under a namespaced claim.
        if let auth = obj["https://api.openai.com/auth"] as? [String: Any],
           let acc = auth["chatgpt_account_id"] as? String, !acc.isEmpty {
            return acc
        }
        return nil
    }
}
