import Foundation

final class ProviderRegistry {
    let providers: [UsageProvider]

    init(providers: [UsageProvider]) {
        self.providers = providers
    }

    static let `default` = ProviderRegistry(providers: [
        ClaudeCodeProvider(),
        CodexProvider(),
        CursorProvider(),
        CopilotProvider()
    ])

    func provider(id: String) -> UsageProvider? {
        providers.first { $0.id == id }
    }
}
