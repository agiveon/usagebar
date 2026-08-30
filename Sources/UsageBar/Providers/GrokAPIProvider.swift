import Foundation

// Prepaid xAI developer API.  Not the SuperGrok weekly pool — a SuperGrok
// subscription does not fund api.x.ai.  Auth is XAI_API_KEY (or ~/.xai/api_key).
struct GrokAPIProvider: UsageProvider {
    let id = "grok-api"
    let displayName = "Grok API"
    let shortName = "Grok API"
    let iconName = "key"
    let signInAction = SignInAction.openURL(
        URL(string: "https://console.x.ai/team/default/api-keys")!,
        hint: "Create an API key in the xAI console. UsageBar reads XAI_API_KEY."
    )

    func isAvailable() async -> Bool { GrokCredentials.loadAPIKey() != nil }

    func fetchSnapshot() async throws -> UsageSnapshot {
        guard let key = GrokCredentials.loadAPIKey() else { throw ProviderError.tokenMissing }
        var req = URLRequest(url: URL(string: "https://api.x.ai/v1/models")!, timeoutInterval: 12)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let (_, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw ProviderError.badResponse("no HTTP response")
        }
        switch http.statusCode {
        case 200...299: break
        case 401, 403: throw ProviderError.notLoggedIn("API key rejected — create a new one at console.x.ai")
        case 429: throw ProviderError.badResponse("rate limited")
        default:  throw ProviderError.badResponse("HTTP \(http.statusCode)")
        }
        // Inference keys have no billing access; a live key is "connected".
        return UsageSnapshot(provider: id,
                             windows: [UsageWindow(id: "api", label: "API",
                                                   percentUsed: 0, resetsAt: nil)],
                             fetchedAt: Date(),
                             isStale: false)
    }
}
