import Foundation

// Read the GitHub Copilot OAuth token that the Copilot editor extension
// writes on sign-in.  Two file formats have existed:
//
//   ~/.config/github-copilot/apps.json   — newer, keyed by "github.com:<appId>"
//     { "github.com:Iv1....": { "oauth_token": "gho_...", ... } }
//
//   ~/.config/github-copilot/hosts.json  — older, keyed by host
//     { "github.com": { "oauth_token": "gho_..." } }
//
// We try both, most-recent first.
enum CopilotCredentials {

    static func loadToken() -> String? {
        let base = ("~/.config/github-copilot" as NSString).expandingTildeInPath
        for name in ["apps.json", "hosts.json"] {
            let url = URL(fileURLWithPath: base).appendingPathComponent(name)
            if let token = readToken(from: url) { return token }
        }
        return nil
    }

    private static func readToken(from url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        // Value may be a dict with oauth_token, or an array of such dicts.
        for (_, val) in obj {
            if let dict = val as? [String: Any],
               let t = dict["oauth_token"] as? String, !t.isEmpty {
                return t
            }
        }
        return nil
    }
}
