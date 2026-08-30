import Foundation

// xAI developer API prepaid credits.  Separate from the SuperGrok weekly
// pool: a SuperGrok subscription does not fund `api.x.ai`.  Auth is an
// `XAI_API_KEY` when present; we also reuse the Grok CLI OIDC token to
// read `prepaidBalance` off the CLI billing proxy (same feed SuperGrok
// uses, different slice).
struct GrokAPIProvider: UsageProvider {
    let id = "grok-api"
    let displayName = "Grok API"
    let shortName = "Grok API"
    let iconName = "key"
    let iconAsset: String? = "xai"
    let signInAction = SignInAction.openURL(
        URL(string: "https://console.x.ai/team/default/api-keys")!,
        hint: "Create an API key in the xAI console. UsageBar reads XAI_API_KEY (or ~/.xai/api_key)."
    )

    private let billingURL = URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!
    private let modelsURL = URL(string: "https://api.x.ai/v1/models")!

    func isAvailable() async -> Bool {
        // SuperGrok's OIDC session is not an API key — don't auto-connect
        // this tab from `grok login` or the two providers collapse into one.
        GrokCredentials.loadAPIKey() != nil
    }

    func fetchSnapshot() async throws -> UsageSnapshot {
        let oidc = GrokCredentials.load()
        let apiKey = GrokCredentials.loadAPIKey()
        guard oidc != nil || apiKey != nil else {
            throw ProviderError.tokenMissing
        }

        if let apiKey {
            try await pingModels(apiKey: apiKey)
        }

        var windows: [UsageWindow] = []
        if let oidc {
            windows = try await fetchPrepaid(token: oidc.accessToken)
        }
        if windows.isEmpty {
            // Key is valid but billing isn't on this credential.  Surface a
            // connected-but-uncapped window rather than looking signed-out.
            windows = [UsageWindow(id: "api",
                                   label: "API",
                                   percentUsed: 0,
                                   resetsAt: nil)]
        }

        return UsageSnapshot(provider: id,
                             windows: windows,
                             fetchedAt: Date(),
                             isStale: false,
                             accountLabel: oidc?.email)
    }

    private func pingModels(apiKey: String) async throws {
        var req = URLRequest(url: modelsURL, timeoutInterval: 12)
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (_, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw ProviderError.badResponse("no HTTP response")
        }
        switch http.statusCode {
        case 200...299: return
        case 401, 403: throw ProviderError.notLoggedIn("API key rejected — create a new one at console.x.ai")
        case 429: throw ProviderError.badResponse("rate limited")
        default:  throw ProviderError.badResponse("HTTP \(http.statusCode)")
        }
    }

    private func fetchPrepaid(token: String) async throws -> [UsageWindow] {
        var req = URLRequest(url: billingURL, timeoutInterval: 12)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("xai-grok-cli", forHTTPHeaderField: "x-xai-token-auth")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("xai-grok-cli", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            return []
        }
        return try GrokCreditsParser.parse(data: data, include: .api).windows
    }
}
