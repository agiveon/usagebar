import Foundation

// xAI developer API prepaid credits.  A SuperGrok subscription does not
// fund `api.x.ai`.  Auth is `XAI_API_KEY` (or `~/.xai/api_key`); we overlay
// `prepaidBalance` from the CLI credits feed when a Grok login is present.
struct GrokAPIProvider: UsageProvider {
    let id = "grok-api"
    let displayName = "Grok API"
    let shortName = "Grok API"
    let iconName = "key"
    let iconAsset: String? = "xai"
    let signInAction = SignInAction.openURL(
        URL(string: "https://console.x.ai/team/default/api-keys")!,
        hint: "Create an API key in the xAI console. UsageBar reads XAI_API_KEY."
    )

    func isAvailable() async -> Bool {
        GrokCredentials.loadAPIKey() != nil
    }

    func fetchSnapshot() async throws -> UsageSnapshot {
        guard let apiKey = GrokCredentials.loadAPIKey() else {
            throw ProviderError.tokenMissing
        }
        try await pingModels(apiKey: apiKey)

        let oidc = GrokCredentials.load()
        var windows: [UsageWindow] = []
        if let oidc, let data = try? await GrokCredits.fetch(token: oidc.accessToken) {
            windows = (try? GrokCredits.apiWindows(from: data)) ?? []
        }
        if windows.isEmpty {
            windows = [UsageWindow(id: "api", label: "API", percentUsed: 0, resetsAt: nil)]
        }
        return UsageSnapshot(provider: id,
                             windows: windows,
                             fetchedAt: Date(),
                             isStale: false,
                             accountLabel: oidc?.email)
    }

    private func pingModels(apiKey: String) async throws {
        var req = URLRequest(url: URL(string: "https://api.x.ai/v1/models")!, timeoutInterval: 12)
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
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
}
