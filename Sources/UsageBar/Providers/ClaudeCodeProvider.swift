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
    let id: String
    let displayName: String
    let shortName: String
    let iconName = "sparkles"
    let iconAsset: String? = "claude"
    let signInAction: SignInAction

    /// Keychain service name this instance's token lives under.  Every
    /// `Claude Code-credentials*` item = one account.
    let keychainService: String

    /// Default install (the un-suffixed Keychain item).
    init() {
        self.keychainService = "Claude Code-credentials"
        self.id = "claude-code"
        self.displayName = "Claude Code"
        self.shortName = "Claude"
        self.signInAction = .runCommand(
            "claude",
            hint: "Signs in to Claude Code via its own OAuth browser flow."
        )
    }

    /// Extra account discovered from a `Claude Code-credentials-<suffix>`
    /// Keychain item.  Suffix disambiguates the id; the display starts as
    /// "Claude Code · <suffix>" and gets nicer once we fetch the email.
    init(keychainService: String, suffix: String) {
        self.keychainService = keychainService
        self.id = "claude-code:\(suffix)"
        self.displayName = "Claude Code · \(suffix)"
        self.shortName = suffix
        self.signInAction = .runCommand(
            "claude",
            hint: "Sign in with your other account from the Claude Code CLI."
        )
    }

    private let usageURL   = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private let profileURL = URL(string: "https://api.anthropic.com/api/oauth/profile")!
    private let userAgent  = "claude-code/2.1.204"

    func isAvailable() async -> Bool {
        ClaudeCredentials.loadAccessToken(keychainService: keychainService) != nil
    }

    func fetchSnapshot() async throws -> UsageSnapshot {
        guard let token = ClaudeCredentials.loadAccessToken(keychainService: keychainService) else {
            throw ProviderError.tokenMissing
        }

        // Kick both requests in parallel — profile is cheap, and we want the
        // account email to land in the same snapshot as the usage numbers.
        async let usageData = self.getJSON(url: usageURL, token: token)
        async let profileData = try? self.getJSON(url: profileURL, token: token)

        let usage = try await usageData
        let windows = try ClaudeUsageParser.parseWindows(data: usage)

        var email: String?
        if let data = await profileData,
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let account = obj["account"] as? [String: Any] {
            email = (account["email"] as? String)
                ?? (account["display_name"] as? String)
                ?? (account["full_name"] as? String)
        }

        return UsageSnapshot(provider: id,
                             windows: windows,
                             fetchedAt: Date(),
                             isStale: false,
                             accountLabel: email)
    }

    private func getJSON(url: URL, token: String) async throws -> Data {
        var req = URLRequest(url: url, timeoutInterval: 12)
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
        case 200...299: return data
        case 401: throw ProviderError.notLoggedIn("auth expired — re-login in Claude Code")
        case 429: throw ProviderError.badResponse("rate limited")
        default:  throw ProviderError.badResponse("HTTP \(http.statusCode)")
        }
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
        var seenIDs = Set<String>()

        // 1. Top-level fields — five_hour / seven_day / seven_day_<model>.
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
            seenIDs.insert(key)
        }

        // 2. `limits[]` — model-scoped windows the API surfaces here rather
        //    than at the top level (e.g. weekly_scoped for Fable/Sonnet/Opus
        //    when they have their own cap).  Skip entries duplicating a
        //    top-level field, skip inactive-and-nil ones.
        if let limits = dict["limits"] as? [[String: Any]] {
            for limit in limits {
                guard let percent = numeric(limit["percent"]) else { continue }
                let group = (limit["group"] as? String) ?? "custom"
                let scope = limit["scope"] as? [String: Any]
                let model = scope?["model"] as? [String: Any]
                let modelName = model?["display_name"] as? String

                // A limit is "scoped" iff it names a model.  Unscoped limits
                // duplicate the top-level five_hour/seven_day we already saw.
                guard let modelName else { continue }

                let slug = modelName.lowercased()
                    .replacingOccurrences(of: " ", with: "_")
                let id = "\(group)_\(slug)"
                if seenIDs.contains(id) { continue }

                let resetsAt = (limit["resets_at"] as? String).flatMap(parseDate)
                windows.append(UsageWindow(
                    id: id,
                    label: label(group: group, model: modelName),
                    percentUsed: max(0, percent / 100.0),
                    resetsAt: resetsAt
                ))
                seenIDs.insert(id)
            }
        }

        return windows
    }

    private static func numeric(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let i = any as? Int    { return Double(i) }
        if let n = any as? NSNumber { return n.doubleValue }
        return nil
    }

    private static func label(group: String, model: String) -> String {
        switch group {
        case "session", "five_hour": return "Session · \(model)"
        case "weekly", "seven_day":  return "Weekly · \(model)"
        default:                     return "\(prettify(group)) · \(model)"
        }
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
