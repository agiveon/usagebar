import Foundation

// Talks to `cursor.com/api/usage-summary` — the same endpoint the Cursor.app
// dashboard uses.  Auth is the WorkosCursorSessionToken cookie that Cursor.app
// stores in its Chromium cookie DB (decrypted via ChromiumCookies).
//
// Response shape (trimmed, from vokal-pe/cursor-usage-menubar):
//   {
//     "individualUsage": {
//       "plan":     { "autoPercentUsed": Number,  "apiPercentUsed": Number,
//                     "totalPercentUsed": Number, "used": Number, "limit": Number },
//       "onDemand": { "used": Number (cents), "limit": Number (cents) }
//     },
//     "billingCycleEnd": "ISO date",
//     "membershipType": "pro" | ...
//   }
struct CursorProvider: UsageProvider {
    let id = "cursor"
    let displayName = "Cursor"
    let iconName = "keyboard"
    let iconAsset: String? = "cursor"
    let signInAction = SignInAction.openApp(
        bundleID: "com.todesktop.230313mzl4w4u92",  // Cursor's bundle id
        appName: "Cursor",
        hint: "Sign in from Cursor's own window (Account menu)."
    )

    private let usageURL = URL(string: "https://cursor.com/api/usage-summary")!
    private let userAgent = "quotabar/0.1"

    func isAvailable() async -> Bool {
        CursorCredentials.loadCookieValue() != nil
    }

    func fetchSnapshot() async throws -> UsageSnapshot {
        guard let cookieValue = CursorCredentials.loadCookieValue() else {
            throw ProviderError.tokenMissing
        }

        var req = URLRequest(url: usageURL, timeoutInterval: 12)
        req.httpMethod = "GET"
        req.setValue("WorkosCursorSessionToken=\(cookieValue)", forHTTPHeaderField: "Cookie")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw ProviderError.badResponse("no HTTP response")
        }
        switch http.statusCode {
        case 200...299: break
        case 401, 403: throw ProviderError.notLoggedIn("session expired — re-sign into Cursor.app")
        case 429: throw ProviderError.badResponse("rate limited")
        default:  throw ProviderError.badResponse("HTTP \(http.statusCode)")
        }

        let windows = try CursorUsageParser.parseWindows(data: data)
        return UsageSnapshot(provider: id,
                             windows: windows,
                             fetchedAt: Date(),
                             isStale: false)
    }
}

enum CursorUsageParser {

    static func parseWindows(data: Data) throws -> [UsageWindow] {
        let obj = try JSONSerialization.jsonObject(with: data)
        guard let root = obj as? [String: Any] else {
            throw ProviderError.decoding("root not an object")
        }

        let cycleEnd = parseCycleEnd(root["billingCycleEnd"] as? String)
        var windows: [UsageWindow] = []

        let individual = (root["individualUsage"] as? [String: Any]) ?? [:]
        let plan = (individual["plan"] as? [String: Any]) ?? [:]

        if let auto = numeric(plan["autoPercentUsed"]) {
            windows.append(UsageWindow(id: "auto",
                                       label: "Auto models",
                                       percentUsed: auto / 100.0,
                                       resetsAt: cycleEnd))
        }
        if let named = numeric(plan["apiPercentUsed"]) {
            windows.append(UsageWindow(id: "named",
                                       label: "Named models",
                                       percentUsed: named / 100.0,
                                       resetsAt: cycleEnd))
        }
        if let total = numeric(plan["totalPercentUsed"]) {
            windows.append(UsageWindow(id: "total",
                                       label: "Plan total",
                                       percentUsed: total / 100.0,
                                       resetsAt: cycleEnd))
        }

        // On-demand: monthly credit spend (cents).  Only show if there's a cap.
        let onDemand = (individual["onDemand"] as? [String: Any]) ?? [:]
        if let used = numeric(onDemand["used"]),
           let limit = numeric(onDemand["limit"]),
           limit > 0 {
            windows.append(UsageWindow(id: "on_demand",
                                       label: "On-demand ($ this cycle)",
                                       percentUsed: max(0, used / limit),
                                       resetsAt: cycleEnd))
        }

        return windows
    }

    private static func numeric(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let i = any as? Int    { return Double(i) }
        if let n = any as? NSNumber { return n.doubleValue }
        return nil
    }

    private static func parseCycleEnd(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) { return d }
        let iso2 = ISO8601DateFormatter()
        iso2.formatOptions = [.withInternetDateTime]
        return iso2.date(from: s)
    }
}
