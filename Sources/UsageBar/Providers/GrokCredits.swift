import Foundation

// GET cli-chat-proxy.grok.com/v1/billing?format=credits — the same feed
// the Grok CLI TUI hits.  Shape from QuotaKit / a live proxy response
// (see NOTICE.md).  Every field is optional; these endpoints drift.
//
//   { "config": {
//       "creditUsagePercent": Number,          // 0..100  (1.0 = 1 %)
//       "currentPeriod": { "type": "USAGE_PERIOD_TYPE_WEEKLY", "end": ISO },
//       "productUsage": [ { "product": "GrokChat", "usagePercent": Number } ],
//       "prepaidBalance": { "val": cents }
//   } }
enum GrokCredits {

    static let url = URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!

    static func fetch(token: String) async throws -> Data {
        var req = URLRequest(url: url, timeoutInterval: 12)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("xai-grok-cli", forHTTPHeaderField: "x-xai-token-auth")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("xai-grok-cli", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw ProviderError.badResponse("no HTTP response")
        }
        switch http.statusCode {
        case 200...299: return data
        case 401, 403: throw ProviderError.notLoggedIn("auth expired — run `grok login`")
        case 429: throw ProviderError.badResponse("rate limited")
        default:  throw ProviderError.badResponse("HTTP \(http.statusCode)")
        }
    }

    static func subscriptionWindows(from data: Data) throws -> [UsageWindow] {
        let config = try config(from: data)
        let resetsAt = date(config)
        var windows: [UsageWindow] = []
        if let pct = percent(config["creditUsagePercent"]) {
            windows.append(UsageWindow(id: "weekly",
                                       label: periodLabel(config),
                                       percentUsed: pct,
                                       resetsAt: resetsAt))
        }
        if let products = config["productUsage"] as? [[String: Any]] {
            for product in products {
                let name = (product["product"] as? String) ?? "product"
                guard let pct = percent(product["usagePercent"]) else { continue }
                windows.append(UsageWindow(id: "product_\(name)",
                                           label: name.replacingOccurrences(of: "Grok", with: ""),
                                           percentUsed: pct,
                                           resetsAt: resetsAt))
            }
        }
        return windows
    }

    static func apiWindows(from data: Data) throws -> [UsageWindow] {
        let config = try config(from: data)
        guard let cents = Self.cents(config["prepaidBalance"]) else { return [] }
        let dollars = String(format: "$%.2f", cents / 100.0)
        // Remaining-balance, not a quota %.  0 so an empty wallet isn't red.
        return [UsageWindow(id: "prepaid",
                            label: "Prepaid credits (\(dollars) left)",
                            percentUsed: 0,
                            resetsAt: nil)]
    }

    private static func config(from data: Data) throws -> [String: Any] {
        let obj = try JSONSerialization.jsonObject(with: data)
        guard let root = obj as? [String: Any] else {
            throw ProviderError.decoding("root not an object")
        }
        return (root["config"] as? [String: Any]) ?? root
    }

    /// `creditUsagePercent` is 0..100 on the wire (1.0 = 1 %).
    private static func percent(_ any: Any?) -> Double? {
        guard let n = numeric(any) else { return nil }
        return max(0, min(1, n / 100.0))
    }

    private static func cents(_ any: Any?) -> Double? {
        if let n = numeric(any) { return n }
        if let obj = any as? [String: Any] { return numeric(obj["val"]) }
        return nil
    }

    private static func numeric(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        if let n = any as? NSNumber { return n.doubleValue }
        if let s = any as? String { return Double(s) }
        return nil
    }

    private static func date(_ config: [String: Any]) -> Date? {
        let period = config["currentPeriod"] as? [String: Any]
        return parseDate(period?["end"] as? String)
            ?? parseDate(config["billingPeriodEnd"] as? String)
    }

    private static func periodLabel(_ config: [String: Any]) -> String {
        let type = ((config["currentPeriod"] as? [String: Any])?["type"] as? String) ?? ""
        if type.localizedCaseInsensitiveContains("WEEKLY") { return "Weekly" }
        if type.localizedCaseInsensitiveContains("MONTHLY") { return "Monthly" }
        if type.localizedCaseInsensitiveContains("DAILY") { return "Daily" }
        return "Credits"
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
