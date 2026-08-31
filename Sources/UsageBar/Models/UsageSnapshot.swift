import Foundation

struct UsageSnapshot: Hashable {
    let provider: String
    let windows: [UsageWindow]
    let fetchedAt: Date
    var isStale: Bool
    /// The account this snapshot belongs to, if the provider can figure it
    /// out — usually the email address.  Used in the UI so the user knows
    /// *which* account each tab is showing.
    var accountLabel: String? = nil
    /// Shown in the popover when there's nothing to meter (empty `windows`)
    /// or as extra context under the bars.  Nil for providers that always
    /// have real windows.
    var note: String? = nil

    var worstPercent: Double? {
        windows.map(\.percentUsed).max()
    }
}
