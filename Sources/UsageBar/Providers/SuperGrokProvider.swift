import Foundation

// SuperGrok / Grok Build weekly pool.  Auth is the Grok CLI's OIDC session
// at `~/.grok/auth.json` (`grok login`).  Usage comes from the same CLI
// proxy the TUI hits: GET cli-chat-proxy.grok.com/v1/billing?format=credits.
//
// This is the consumer subscription, not the prepaid xAI developer API —
// that's `GrokAPIProvider`.
struct SuperGrokProvider: UsageProvider {
    let id = "supergrok"
    let displayName = "SuperGrok"
    let shortName = "SuperGrok"
    let iconName = "sparkle"
    let iconAsset: String? = "xai"
    let signInAction = SignInAction.openURL(
        URL(string: "https://accounts.x.ai/sign-in")!,
        hint: "Uses your Grok CLI login. Run `grok login` if UsageBar can't see the session."
    )

    private let billingURL = URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!

    func isAvailable() async -> Bool {
        GrokCredentials.load() != nil
    }

    func fetchSnapshot() async throws -> UsageSnapshot {
        guard let creds = GrokCredentials.load() else {
            throw ProviderError.tokenMissing
        }

        var req = URLRequest(url: billingURL, timeoutInterval: 12)
        req.httpMethod = "GET"
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

        let parsed = try GrokCreditsParser.parse(data: data, include: .subscription)
        return UsageSnapshot(provider: id,
                             windows: parsed.windows,
                             fetchedAt: Date(),
                             isStale: false,
                             accountLabel: creds.email)
    }
}
