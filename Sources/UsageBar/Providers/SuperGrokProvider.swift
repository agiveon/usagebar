import Foundation

// SuperGrok weekly pool via the Grok CLI login (`~/.grok/auth.json`) and
// GET cli-chat-proxy.grok.com/v1/billing?format=credits.  Same feed the
// TUI hits; schema from QuotaKit docs/grok.md (see NOTICE.md).
// Separate from the prepaid xAI developer API (`GrokAPIProvider`).
struct SuperGrokProvider: UsageProvider {
    let id = "supergrok"
    let displayName = "SuperGrok"
    let shortName = "SuperGrok"
    let iconName = "sparkle"
    let signInAction = SignInAction.openURL(
        URL(string: "https://accounts.x.ai/sign-in")!,
        hint: "Uses your Grok CLI login (`grok login`)."
    )

    func isAvailable() async -> Bool { GrokCredentials.load() != nil }

    func fetchSnapshot() async throws -> UsageSnapshot {
        guard let creds = GrokCredentials.load() else { throw ProviderError.tokenMissing }
        var req = URLRequest(url: GrokCredentials.billingURL, timeoutInterval: 12)
        req.setValue("Bearer \(creds.accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("xai-grok-cli", forHTTPHeaderField: "x-xai-token-auth")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("xai-grok-cli", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw ProviderError.badResponse("no HTTP response")
        }
        switch http.statusCode {
        case 200...299: break
        case 401, 403: throw ProviderError.notLoggedIn("auth expired — run `grok login`")
        case 429: throw ProviderError.badResponse("rate limited")
        default:  throw ProviderError.badResponse("HTTP \(http.statusCode)")
        }
        return UsageSnapshot(provider: id,
                             windows: try SuperGrokParser.parse(data),
                             fetchedAt: Date(),
                             isStale: false,
                             accountLabel: creds.email)
    }
}

enum SuperGrokParser {
    // creditUsagePercent is 0..100 on the wire (1.0 = 1 %).
    static func parse(_ data: Data) throws -> [UsageWindow] {
        let obj = try JSONSerialization.jsonObject(with: data)
        guard let root = obj as? [String: Any] else {
            throw ProviderError.decoding("root not an object")
        }
        let config = (root["config"] as? [String: Any]) ?? root
        let period = config["currentPeriod"] as? [String: Any]
        let resetsAt = isoDate(period?["end"] as? String)
            ?? isoDate(config["billingPeriodEnd"] as? String)
        let type = (period?["type"] as? String) ?? ""
        let label = type.localizedCaseInsensitiveContains("MONTHLY") ? "Monthly"
            : type.localizedCaseInsensitiveContains("DAILY") ? "Daily"
            : "Weekly"

        var windows: [UsageWindow] = []
        if let pct = percent(config["creditUsagePercent"]) {
            windows.append(UsageWindow(id: "weekly", label: label,
                                       percentUsed: pct, resetsAt: resetsAt))
        }
        if let products = config["productUsage"] as? [[String: Any]] {
            for product in products {
                let name = (product["product"] as? String) ?? "product"
                guard let pct = percent(product["usagePercent"]) else { continue }
                windows.append(UsageWindow(id: "product_\(name)",
                                           label: name.replacingOccurrences(of: "Grok", with: ""),
                                           percentUsed: pct, resetsAt: resetsAt))
            }
        }
        return windows
    }

    private static func percent(_ any: Any?) -> Double? {
        let n: Double? = {
            if let d = any as? Double { return d }
            if let i = any as? Int { return Double(i) }
            if let n = any as? NSNumber { return n.doubleValue }
            return nil
        }()
        return n.map { max(0, min(1, $0 / 100.0)) }
    }

    private static func isoDate(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: raw) { return d }
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: raw)
    }
}
