import Foundation

struct UsageSnapshot: Hashable {
    let provider: String
    let windows: [UsageWindow]
    let fetchedAt: Date
    var isStale: Bool

    var worstPercent: Double {
        windows.map(\.percentUsed).max() ?? 0
    }
}
