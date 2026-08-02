import SwiftUI
import AppKit

// The menu bar label shows one glyph per menu-bar provider (just the active
// one by default, or every enabled provider when the user opts in), each
// tinted by the traffic-light color for its metric.  We build NSImages with
// the color baked in — SwiftUI's `.foregroundStyle` doesn't stick in the
// status bar because AppKit force-templates whatever it's handed.
struct MenuBarLabel: View {
    @EnvironmentObject var store: UsageStore

    var body: some View {
        HStack(spacing: 7) {
            let providers = store.menuBarProviders
            if providers.isEmpty {
                Image(systemName: "circle")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(providers, id: \.id) { p in
                    ProviderGlyph(provider: p)
                }
            }
        }
    }
}

private struct ProviderGlyph: View {
    @EnvironmentObject var store: UsageStore
    let provider: UsageProvider

    var body: some View {
        HStack(spacing: 4) {
            if let img = coloredIcon {
                Image(nsImage: img)
            } else {
                // Fallback if the SF Symbol name is bogus.
                Image(systemName: "circle")
                    .foregroundStyle(.secondary)
            }
            if store.showPercentLabel, let pct = percent {
                Text("\(Int((pct * 100).rounded()))%")
                    .monospacedDigit()
            }
        }
    }

    private var isLive: Bool {
        if case .some(.available(let snap)) = store.statuses[provider.id] {
            return !snap.isStale
        }
        return false
    }

    private var percent: Double? {
        guard isLive else { return nil }
        return store.menuBarPercent(for: provider.id)
    }

    private var iconName: String {
        isLive ? provider.iconName : "circle"
    }

    private var tint: NSColor {
        guard let pct = percent else { return NSColor.secondaryLabelColor }
        return ColoredSymbol.nsColor(from: Thresholds.color(for: pct))
    }

    private var coloredIcon: NSImage? {
        BrandIcon.nsImage(asset: provider.iconAsset,
                          sfSymbol: iconName,
                          color: tint,
                          pointSize: 16)
    }
}
