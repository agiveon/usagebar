import Foundation

// Talks to `api.github.com/copilot_internal/user` — the same endpoint the
// Copilot editor extensions and `gh copilot` hit.  Response carries a
// `quota_snapshots` object with one entry per metered category (e.g.
// `premium_interactions`, `chat`, `completions`), each with fields like
// `percent_remaining`, `used`, `entitlement`, `unlimited`, `remaining`.
//
// We parse generically: any category with a numeric quota becomes a
// UsageWindow.  Unlimited categories are skipped.
struct CopilotProvider: UsageProvider {
    let id = "copilot"
    let displayName = "GitHub Copilot"
    let iconName = "chevron.left.forwardslash.chevron.right"
    let iconAsset: String? = "githubcopilot"
    let signInAction = SignInAction.openURL(
        URL(string: "https://docs.github.com/en/copilot/getting-started-with-github-copilot")!,
        hint: "Copilot sign-in lives in your editor's Copilot extension."
    )

    private let usageURL = URL(string: "https://api.github.com/copilot_internal/user")!
    private let userAgent = "usagebar/0.1"

    func isAvailable() async -> Bool {
        CopilotCredentials.loadToken() != nil
    }

    func fetchSnapshot() async throws -> UsageSnapshot {
        guard let token = CopilotCredentials.loadToken() else {
            throw ProviderError.tokenMissing
        }

        var req = URLRequest(url: usageURL, timeoutInterval: 12)
        req.httpMethod = "GET"
        req.setValue("token \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw ProviderError.badResponse("no HTTP response")
        }
        switch http.statusCode {
        case 200...299: break
        case 401, 403: throw ProviderError.notLoggedIn("token invalid — re-sign in to Copilot in your editor")
        case 429: throw ProviderError.badResponse("rate limited")
        case 404: throw ProviderError.notLoggedIn("no active Copilot subscription for this account")
        default:  throw ProviderError.badResponse("HTTP \(http.statusCode)")
        }

        let windows = try CopilotUsageParser.parseWindows(data: data)
        return UsageSnapshot(provider: id,
                             windows: windows,
                             fetchedAt: Date(),
                             isStale: false)
    }
}

enum CopilotUsageParser {

    static func parseWindows(data: Data) throws -> [UsageWindow] {
        let obj = try JSONSerialization.jsonObject(with: data)
        guard let root = obj as? [String: Any] else {
            throw ProviderError.decoding("root not an object")
        }

        var windows: [UsageWindow] = []

        // Preferred shape: { quota_snapshots: { <category>: {...}, ... } }
        if let snapshots = root["quota_snapshots"] as? [String: Any] {
            for key in snapshots.keys.sorted() {
                guard let entry = snapshots[key] as? [String: Any] else { continue }
                // Skip unlimited categories.
                if entry["unlimited"] as? Bool == true { continue }
                guard let pct = percentUsed(from: entry) else { continue }
                windows.append(UsageWindow(
                    id: key,
                    label: humanLabel(key),
                    percentUsed: pct,
                    resetsAt: parseReset(entry)
                ))
            }
        }

        // Fallback: some responses expose flat fields like `access_expires_at`
        // + `plan.quota_used_pct`.  Best-effort — leaves the list empty rather
        // than crashing if the shape drifts.
        if windows.isEmpty {
            if let pct = percentUsed(from: root) {
                windows.append(UsageWindow(id: "quota",
                                           label: "Copilot quota",
                                           percentUsed: pct,
                                           resetsAt: parseReset(root)))
            }
        }

        return windows
    }

    /// Try several shapes for "how much of this quota is used" and return 0..1.
    private static func percentUsed(from entry: [String: Any]) -> Double? {
        if let rem = numeric(entry["percent_remaining"]) {
            let scale = rem <= 1.0 ? 1.0 : 100.0
            return max(0, min(1, 1.0 - (rem / scale)))
        }
        if let used = numeric(entry["percent_used"]) {
            let scale = used <= 1.0 ? 1.0 : 100.0
            return max(0, min(1, used / scale))
        }
        if let used = numeric(entry["used"] ?? entry["used_count"]),
           let cap  = numeric(entry["entitlement"]
                              ?? entry["allowance"]
                              ?? entry["limit"]
                              ?? entry["quota"]),
           cap > 0 {
            return max(0, used / cap)
        }
        return nil
    }

    private static func parseReset(_ entry: [String: Any]) -> Date? {
        for key in ["reset_date", "resets_at", "period_end", "access_expires_at"] {
            if let s = entry[key] as? String {
                let iso = ISO8601DateFormatter()
                iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if let d = iso.date(from: s) { return d }
                let iso2 = ISO8601DateFormatter()
                iso2.formatOptions = [.withInternetDateTime]
                if let d = iso2.date(from: s) { return d }
            }
            if let n = entry[key] as? Double, n > 0 {
                return Date(timeIntervalSince1970: n)
            }
        }
        return nil
    }

    private static func numeric(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let i = any as? Int    { return Double(i) }
        if let n = any as? NSNumber { return n.doubleValue }
        return nil
    }

    private static func humanLabel(_ raw: String) -> String {
        switch raw {
        case "premium_interactions": return "Premium requests"
        case "chat":                 return "Chat"
        case "completions":          return "Completions"
        default:
            return raw.split(separator: "_")
                .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                .joined(separator: " ")
        }
    }
}
