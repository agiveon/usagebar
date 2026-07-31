import SwiftUI
import AppKit

// The menu bar glyph shows the active provider's icon, tinted by the
// traffic-light color for the selected metric.  We build an NSImage with the
// color baked in — SwiftUI's `.foregroundStyle` doesn't stick in the status
// bar because AppKit force-templates whatever it's handed.
struct MenuBarLabel: View {
    @EnvironmentObject var store: UsageStore

    var body: some View {
        HStack(spacing: 4) {
            if let img = coloredIcon {
                Image(nsImage: img)
            } else {
                // Fallback if the SF Symbol name is bogus.
                Image(systemName: "circle")
                    .foregroundStyle(.secondary)
            }
            if store.showPercentLabel, let pct = store.menuBarPercent {
                Text("\(Int((pct * 100).rounded()))%")
                    .monospacedDigit()
            }
        }
    }

    private var activeProvider: UsageProvider? {
        store.registry.provider(id: store.activeProviderID)
    }

    private var isLive: Bool {
        if case .some(.available(let snap)) = store.activeStatus { return !snap.isStale }
        return false
    }

    private var iconName: String {
        guard isLive, let p = activeProvider else { return "circle" }
        return p.iconName
    }

    private var tint: NSColor {
        guard isLive, let pct = store.menuBarPercent else {
            return NSColor.secondaryLabelColor
        }
        return ColoredSymbol.nsColor(from: Thresholds.color(for: pct))
    }

    private var coloredIcon: NSImage? {
        BrandIcon.nsImage(asset: activeProvider?.iconAsset,
                          sfSymbol: iconName,
                          color: tint,
                          pointSize: 16)
    }
}
