import Foundation

struct UsageWindow: Identifiable, Hashable {
    let id: String
    let label: String
    let percentUsed: Double
    let resetsAt: Date?
}
