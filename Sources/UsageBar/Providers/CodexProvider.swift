import Foundation

// Talks to the undocumented `chatgpt.com/backend-api/wham/usage` endpoint the
// Codex CLI itself uses for `/status`.  Endpoint + response schema captured
// from openai/codex (codex-rs/backend-client + codex-backend-openapi-models,
// see PLAN §10).
//
// Response shape (trimmed):
//   { plan_type: "...",
//     rate_limit: {
//       primary_window:   { used_percent: Int, limit_window_seconds: Int,
//                           reset_after_seconds: Int, reset_at: Int },
//       secondary_window: { same shape }
//     },
//     additional_rate_limits: [ { limit_name, rate_limit: {...} } ]  // optional
//   }
struct CodexProvider: UsageProvider {
    let id = "codex"
    let displayName = "ChatGPT · Codex"
    let iconName = "terminal"
    let iconAsset: String? = "openai"
    let signInAction = SignInAction.runCommand(
        "codex login",
        hint: "Signs in via your ChatGPT account (opens a browser)."
    )

    private let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    private let userAgent = "codex-cli"

    func isAvailable() async -> Bool {
        CodexCredentials.load() != nil
    }

    func fetchSnapshot() async throws -> UsageSnapshot {
        guard let creds = CodexCredentials.load() else {
            throw ProviderError.tokenMissing
        }

        var req = URLRequest(url: usageURL, timeoutInterval: 12)
        req.httpMethod = "GET"
        req.setValue("Bearer \(creds.accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if let acc = creds.chatgptAccountId {
            req.setValue(acc, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw ProviderError.badResponse("no HTTP response")
        }
        switch http.statusCode {
        case 200...299: break
        case 401: throw ProviderError.notLoggedIn("auth expired — run `codex login`")
        case 403: throw ProviderError.notLoggedIn("account not authorized for Codex usage endpoint")
        case 429: throw ProviderError.badResponse("rate limited")
        default:  throw ProviderError.badResponse("HTTP \(http.statusCode)")
        }

        let windows = try CodexUsageParser.parseWindows(data: data, fetchedAt: Date())
        return UsageSnapshot(provider: id,
                             windows: windows,
                             fetchedAt: Date(),
                             isStale: false)
    }
}

enum CodexUsageParser {

    static func parseWindows(data: Data, fetchedAt: Date) throws -> [UsageWindow] {
        let obj = try JSONSerialization.jsonObject(with: data)
        guard let dict = obj as? [String: Any] else {
            throw ProviderError.decoding("root not an object")
        }

        var windows: [UsageWindow] = []

        if let rl = dict["rate_limit"] as? [String: Any] {
            if let w = window(from: rl["primary_window"], id: "primary", isSecondary: false, fetchedAt: fetchedAt) {
                windows.append(w)
            }
            if let w = window(from: rl["secondary_window"], id: "secondary", isSecondary: true, fetchedAt: fetchedAt) {
                windows.append(w)
            }
        }

        // Additional rate limits (per-metered-feature) — surface generically.
        if let extras = dict["additional_rate_limits"] as? [[String: Any]] {
            for extra in extras {
                let name = (extra["limit_name"] as? String) ?? (extra["metered_feature"] as? String) ?? "extra"
                if let rl = extra["rate_limit"] as? [String: Any] {
                    if let w = window(from: rl["primary_window"], id: "extra_\(name)_primary",
                                      labelOverride: "\(name) · primary",
                                      isSecondary: false, fetchedAt: fetchedAt) {
                        windows.append(w)
                    }
                    if let w = window(from: rl["secondary_window"], id: "extra_\(name)_secondary",
                                      labelOverride: "\(name) · secondary",
                                      isSecondary: true, fetchedAt: fetchedAt) {
                        windows.append(w)
                    }
                }
            }
        }

        return windows
    }

    private static func window(from raw: Any?,
                               id: String,
                               labelOverride: String? = nil,
                               isSecondary: Bool,
                               fetchedAt: Date) -> UsageWindow? {
        guard let d = raw as? [String: Any] else { return nil }
        // `used_percent` is 0..100 (may be Int or Double depending on JSON parser).
        let used: Double
        if let i = d["used_percent"] as? Int { used = Double(i) }
        else if let f = d["used_percent"] as? Double { used = f }
        else { return nil }

        let windowSecs = (d["limit_window_seconds"] as? Int)
            ?? Int((d["limit_window_seconds"] as? Double) ?? 0)
        let resetAfter = (d["reset_after_seconds"] as? Int)
            ?? Int((d["reset_after_seconds"] as? Double) ?? 0)

        let resetsAt: Date? = resetAfter > 0
            ? fetchedAt.addingTimeInterval(TimeInterval(resetAfter))
            : nil

        let label = labelOverride ?? labelFor(windowSeconds: windowSecs, isSecondary: isSecondary)
        return UsageWindow(id: id,
                           label: label,
                           percentUsed: max(0, used / 100.0),
                           resetsAt: resetsAt)
    }

    // Matches Codex's own labelling in codex-rs/tui/src/chatwidget/rate_limits.rs.
    private static func labelFor(windowSeconds: Int, isSecondary: Bool) -> String {
        let minutes = windowSeconds / 60
        func near(_ target: Int) -> Bool {
            let lo = Int(Double(target) * 0.95)
            let hi = Int(Double(target) * 1.05)
            return minutes >= lo && minutes <= hi
        }
        if near(5 * 60)               { return "Current session (5h)" }
        if near(24 * 60)              { return "Daily" }
        if near(7 * 24 * 60)          { return "Weekly" }
        if near(30 * 24 * 60)         { return "Monthly" }
        if near(365 * 24 * 60)        { return "Annual" }
        return isSecondary ? "Secondary usage" : "Usage"
    }
}
