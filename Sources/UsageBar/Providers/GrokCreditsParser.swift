import Foundation

// Parses `GET https://cli-chat-proxy.grok.com/v1/billing?format=credits`.
// Shape captured from QuotaKit / CodexBar / the live Grok CLI proxy
// (see NOTICE.md).  Every field is optional — these endpoints drift.
//
//   { "config": {
//       "creditUsagePercent": Number,          // 0..100
//       "currentPeriod": { "type": "USAGE_PERIOD_TYPE_WEEKLY",
//                          "start": ISO, "end": ISO },
//       "billingPeriodEnd": ISO,
//       "productUsage": [ { "product": "GrokChat", "usagePercent": Number } ],
//       "prepaidBalance": { "val": cents },
//       "onDemandUsed": { "val": cents }, "onDemandCap": { "val": cents }
//   } }
enum GrokCreditsParser {

    struct Result {
        var windows: [UsageWindow]
        var prepaidCents: Double?
    }

    static func parse(data: Data, include: Kind) throws -> Result {
        let obj = try JSONSerialization.jsonObject(with: data)
        guard let root = obj as? [String: Any] else {
            throw ProviderError.decoding("root not an object")
        }
        let config = (root["config"] as? [String: Any]) ?? root

        let period = (config["currentPeriod"] as? [String: Any]) ?? [:]
        let periodType = period["type"] as? String
        let resetsAt = parseDate(period["end"] as? String)
            ?? parseDate(config["billingPeriodEnd"] as? String)

        var windows: [UsageWindow] = []

        if include == .subscription {
            if let pct = percent(config["creditUsagePercent"]) {
                windows.append(UsageWindow(
                    id: "weekly",
                    label: label(forPeriodType: periodType, resetsAt: resetsAt),
                    percentUsed: pct,
                    resetsAt: resetsAt
                ))
            } else if let used = cents(config["onDemandUsed"]),
                      let cap = cents(config["onDemandCap"]), cap > 0 {
                windows.append(UsageWindow(
                    id: "weekly",
                    label: label(forPeriodType: periodType, resetsAt: resetsAt),
                    percentUsed: max(0, min(1, used / cap)),
                    resetsAt: resetsAt
                ))
            }

            if let products = config["productUsage"] as? [[String: Any]] {
                for product in products {
                    let name = (product["product"] as? String) ?? "product"
                    guard let pct = percent(product["usagePercent"]) else { continue }
                    windows.append(UsageWindow(
                        id: "product_\(name)",
                        label: humanProduct(name),
                        percentUsed: pct,
                        resetsAt: resetsAt
                    ))
                }
            }
        }

        let prepaid = cents(config["prepaidBalance"])
        if include == .api {
            if let prepaid {
                // Remaining-balance, not a quota %.  Without a cap we can't
                // derive used%; show 0 so an empty wallet isn't a red bar.
                let dollars = String(format: "$%.2f", prepaid / 100.0)
                windows.append(UsageWindow(
                    id: "prepaid",
                    label: "Prepaid credits (\(dollars) left)",
                    percentUsed: 0,
                    resetsAt: nil
                ))
            }
            if let products = config["productUsage"] as? [[String: Any]] {
                for product in products {
                    let name = (product["product"] as? String) ?? ""
                    guard isAPIProduct(name),
                          let pct = percent(product["usagePercent"]) else { continue }
                    windows.append(UsageWindow(
                        id: "product_\(name)",
                        label: humanProduct(name),
                        percentUsed: pct,
                        resetsAt: resetsAt
                    ))
                }
            }
        }

        return Result(windows: windows, prepaidCents: prepaid)
    }

    enum Kind { case subscription, api }

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

    private static func parseDate(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: raw) { return d }
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: raw)
    }

    private static func label(forPeriodType type: String?, resetsAt: Date?) -> String {
        if let type {
            if type.localizedCaseInsensitiveContains("WEEKLY") { return "Weekly" }
            if type.localizedCaseInsensitiveContains("MONTHLY") { return "Monthly" }
            if type.localizedCaseInsensitiveContains("DAILY") { return "Daily" }
        }
        if let resetsAt {
            let days = resetsAt.timeIntervalSinceNow / 86_400
            if days > 3.5 && days < 12 { return "Weekly" }
            if days > 20 && days < 45 { return "Monthly" }
        }
        return "Credits"
    }

    private static func humanProduct(_ raw: String) -> String {
        switch raw {
        case "GrokChat": return "Chat"
        case "GrokBuild": return "Build"
        case "GrokVoice", "Voice": return "Voice"
        case "GrokImagine", "Imagine": return "Imagine"
        case "GrokAPI", "API": return "API"
        default:
            return raw.replacingOccurrences(of: "Grok", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty ?? raw
        }
    }

    private static func isAPIProduct(_ raw: String) -> Bool {
        let lower = raw.lowercased()
        return lower.contains("api") && !lower.contains("chat")
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
