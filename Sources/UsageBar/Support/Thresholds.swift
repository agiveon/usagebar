import SwiftUI

enum Thresholds {
    static let yellow = 0.70
    static let red = 0.90

    static func color(for percent: Double) -> Color {
        if percent >= red { return .red }
        if percent >= yellow { return .yellow }
        return .green
    }
}

enum ResetFormatter {
    static func string(until date: Date) -> String {
        let total = Int(date.timeIntervalSinceNow)
        if total <= 0 { return "now" }
        let days    = total / 86400
        let hours   = (total % 86400) / 3600
        let minutes = (total % 3600) / 60

        // Two most-significant units — "31d 3h" beats "747h 24m" for a monthly
        // cycle, "3h 12m" beats "192m" for a short one.
        if days > 0 {
            return hours > 0 ? "in \(days)d \(hours)h" : "in \(days)d"
        }
        if hours > 0 {
            return minutes > 0 ? "in \(hours)h \(minutes)m" : "in \(hours)h"
        }
        return "in \(minutes)m"
    }
}
