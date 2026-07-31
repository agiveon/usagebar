import Foundation

enum ProviderStatus: Hashable {
    case available(UsageSnapshot)
    case notAvailable(String)
    case error(String)
}
