import Foundation

// Talks to the undocumented `api.anthropic.com/api/oauth/usage` endpoint the
// Claude Code CLI uses for its own `/usage` panel.  Response shape is captured
// from jens-duttke/usage-monitor-for-claude's api-reference.md (see PLAN §10).
//
// The response is a flat object where each top-level value is either null or
// { utilization: Double (0..100), resets_at: String }.  Some keys have a
// different shape (e.g. `extra_usage` for credits) — we ignore those and only
// surface entries that fit the usage-window shape, so newly-added windows show
// up without a code change.
struct ClaudeCodeProvider: UsageProvider {
    let id = "claude-code"
    let displayName = "Claude Code"
    let iconName = "sparkles"
    let iconAsset: String? = "claude"
    let signInAction = SignInAction.runCommand(
        "claude",
        hint: "Signs in to Claude Code via its own OAuth browser flow."
    )

    private let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private let userAgent = "claude-code/2.1.204"

    func isAvailable() async -> Bool {
        ClaudeCredentials.loadAccessToken() != nil
    }

    func fetchSnapshot() async throws -> UsageSnapshot {
        guard let token = ClaudeCredentials.loadAccessToken() else {
            throw ProviderError.tokenMissing
        }

        var req = URLRequest(url: usageURL, timeoutInterval: 12)
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw ProviderError.badResponse("no HTTP response")
        }
        switch http.statusCode {
        case 200...299: break
        case 401: throw ProviderError.notLoggedIn("auth expired — re-login in Claude Code")
        case 429: throw ProviderError.badResponse("rate limited")
        default:  throw ProviderError.badResponse("HTTP \(http.statusCode)")
        }

        let windows = try ClaudeUsageParser.parseWindows(data: data)
        return UsageSnapshot(provider: id,
                             windows: windows,
                             fetchedAt: Date(),
                             isStale: false)
    }
}

enum ClaudeUsageParser {

    static func parseWindows(data: Data) throws -> [UsageWindow] {
        let obj = try JSONSerialization.jsonObject(with: data)
        guard let dict = obj as? [String: Any] else {
            throw ProviderError.decoding("root not an object")
        }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoNoFrac = ISO8601DateFormatter()
        isoNoFrac.formatOptions = [.withInternetDateTime]

        func parseDate(_ s: String) -> Date? {
            iso.date(from: s) ?? isoNoFrac.date(from: s)
        }

        var windows: [UsageWindow] = []
        // Sort keys for deterministic order (five_hour first, then seven_day*).
        for key in dict.keys.sorted(by: sortKey) {
            guard let entry = dict[key] as? [String: Any] else { continue }
            // Must have both utilization + resets_at to count as a window.
            guard let util = entry["utilization"] as? Double,
                  let resetsRaw = entry["resets_at"] as? String else {
                continue
            }
            let percent = max(0.0, util / 100.0)
            let resetsAt = parseDate(resetsRaw)
            windows.append(UsageWindow(
                id: key,
                label: humanLabel(for: key),
                percentUsed: percent,
                resetsAt: resetsAt
            ))
        }

        return windows
    }

    // five_hour before seven_day, then alphabetical within a group so
    // model-scoped windows cluster together.
    private static func sortKey(_ a: String, _ b: String) -> Bool {
        func rank(_ k: String) -> Int {
            if k == "five_hour" { return 0 }
            if k == "seven_day" { return 1 }
            if k.hasPrefix("seven_day_") { return 2 }
            return 3
        }
        let ra = rank(a), rb = rank(b)
        if ra != rb { return ra < rb }
        return a < b
    }

    private static func humanLabel(for key: String) -> String {
        switch key {
        case "five_hour": return "Current session (5h)"
        case "seven_day": return "Weekly · all models"
        default:
            if key.hasPrefix("seven_day_") {
                let suffix = String(key.dropFirst("seven_day_".count))
                return "Weekly · \(prettify(suffix))"
            }
            return prettify(key)
        }
    }

    private static func prettify(_ raw: String) -> String {
        raw.split(separator: "_")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}
