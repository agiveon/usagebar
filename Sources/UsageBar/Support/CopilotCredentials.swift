import Foundation

// Copilot's editor-extension config supports multiple accounts natively:
// `~/.config/github-copilot/apps.json` is keyed by "github.com:<appId>",
// with a `user` field for the GitHub username.  Every entry with an
// `oauth_token` becomes its own UsageBar instance.  Older installs
// used `hosts.json` with the same structure keyed by host.
enum CopilotCredentials {

    struct Account: Equatable {
        let appKey: String    // "github.com:Iv1...."
        let user: String?     // GitHub username, if present
        let token: String
    }

    private static let baseDir = ("~/.config/github-copilot" as NSString)
        .expandingTildeInPath

    /// All accounts we can find — one per apps.json / hosts.json entry
    /// that carries an `oauth_token`.
    static func discoverAccounts() -> [Account] {
        var out: [Account] = []
        var seenKeys = Set<String>()
        for name in ["apps.json", "hosts.json"] {
            let url = URL(fileURLWithPath: baseDir).appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url),
                  let obj = try? JSONSerialization.jsonObject(with: data)
                    as? [String: Any] else { continue }
            for key in obj.keys.sorted() {
                if seenKeys.contains(key) { continue }
                guard let dict = obj[key] as? [String: Any],
                      let token = dict["oauth_token"] as? String, !token.isEmpty
                else { continue }
                let user = (dict["user"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                out.append(Account(appKey: key, user: user, token: token))
                seenKeys.insert(key)
            }
        }
        return out
    }

    /// Look up a specific account by its `appKey`.  When appKey is nil,
    /// returns the first-discovered account (backward-compat).
    static func loadAccount(appKey: String?) -> Account? {
        let all = discoverAccounts()
        if let appKey { return all.first(where: { $0.appKey == appKey }) }
        return all.first
    }
}
