import Foundation

// SuperGrok / Grok Build weekly pool.  Auth is the Grok CLI OIDC session
// at `~/.grok/auth.json`.  Usage is GET cli-chat-proxy …/billing?format=credits.
// Separate from the prepaid xAI developer API (`GrokAPIProvider`).
struct SuperGrokProvider: UsageProvider {
    let id = "supergrok"
    let displayName = "SuperGrok"
    let shortName = "SuperGrok"
    let iconName = "sparkle"
    let iconAsset: String? = "xai"
    let signInAction = SignInAction.spawnCommand(
        "grok login --oauth",
        fallback: URL(string: "https://accounts.x.ai/sign-in"),
        hint: "Uses your Grok CLI login (`grok login --oauth`)."
    )

    func isAvailable() async -> Bool {
        GrokCredentials.load() != nil
    }

    func fetchSnapshot() async throws -> UsageSnapshot {
        guard let creds = GrokCredentials.load() else {
            throw ProviderError.tokenMissing
        }
        let data = try await GrokCredits.fetch(token: creds.accessToken)
        return UsageSnapshot(provider: id,
                             windows: try GrokCredits.subscriptionWindows(from: data),
                             fetchedAt: Date(),
                             isStale: false,
                             accountLabel: creds.email)
    }
}
