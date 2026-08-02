import SwiftUI
import AppKit

// The menu bar label shows one glyph per menu-bar provider — just the active
// one by default, or every enabled provider when the user opts in.  Each is
// tinted by the traffic-light color for its metric.  Colors are baked into
// NSImages because AppKit force-templates whatever SwiftUI hands the status
// bar.  With several providers everything is pre-composed into a single
// NSImage: MenuBarExtra flattens composite label views down to one image and
// one text, so an HStack of per-provider glyphs renders as only its first.
struct MenuBarLabel: View {
    @EnvironmentObject var store: UsageStore

    var body: some View {
        let providers = store.menuBarProviders
        if providers.count > 1 {
            Image(nsImage: composed(providers))
        } else if let p = providers.first {
            HStack(spacing: 4) {
                if let img = glyphImage(for: p) {
                    Image(nsImage: img)
                } else {
                    // Fallback if the SF Symbol name is bogus.
                    Image(systemName: "circle")
                        .foregroundStyle(.secondary)
                }
                if store.showPercentLabel, let pct = percent(for: p) {
                    Text("\(Int((pct * 100).rounded()))%")
                        .monospacedDigit()
                }
            }
        } else {
            Image(systemName: "circle")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Per-provider pieces

    private func isLive(_ p: UsageProvider) -> Bool {
        if case .some(.available(let snap)) = store.statuses[p.id] {
            return !snap.isStale
        }
        return false
    }

    private func percent(for p: UsageProvider) -> Double? {
        guard isLive(p) else { return nil }
        return store.menuBarPercent(for: p.id)
    }

    private func glyphImage(for p: UsageProvider) -> NSImage? {
        let tint: NSColor = percent(for: p).map {
            ColoredSymbol.nsColor(from: Thresholds.color(for: $0))
        } ?? .secondaryLabelColor
        return BrandIcon.nsImage(asset: p.iconAsset,
                                 sfSymbol: isLive(p) ? p.iconName : "circle",
                                 color: tint,
                                 pointSize: 16)
    }

    // MARK: - Multi-provider composition

    private func composed(_ providers: [UsageProvider]) -> NSImage {
        struct Segment {
            let icon: NSImage?
            let text: NSAttributedString?
        }
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        let segments: [Segment] = providers.map { p in
            var text: NSAttributedString?
            if store.showPercentLabel, let pct = percent(for: p) {
                // labelColor is dynamic and the drawing handler below runs at
                // display time, so the text follows the menu bar appearance.
                text = NSAttributedString(
                    string: "\(Int((pct * 100).rounded()))%",
                    attributes: [.font: font,
                                 .foregroundColor: NSColor.labelColor])
            }
            return Segment(icon: glyphImage(for: p), text: text)
        }

        let iconSide: CGFloat = 16
        let iconTextGap: CGFloat = 3
        let segmentGap: CGFloat = 8
        let height: CGFloat = 18

        var width: CGFloat = 0
        for (i, seg) in segments.enumerated() {
            if i > 0 { width += segmentGap }
            width += iconSide
            if let t = seg.text { width += iconTextGap + ceil(t.size().width) }
        }

        let img = NSImage(size: NSSize(width: max(width, iconSide),
                                       height: height),
                          flipped: false) { _ in
            var x: CGFloat = 0
            for (i, seg) in segments.enumerated() {
                if i > 0 { x += segmentGap }
                seg.icon?.draw(in: NSRect(x: x, y: (height - iconSide) / 2,
                                          width: iconSide, height: iconSide))
                x += iconSide
                if let t = seg.text {
                    x += iconTextGap
                    let size = t.size()
                    t.draw(at: NSPoint(x: x, y: (height - size.height) / 2))
                    x += ceil(size.width)
                }
            }
            return true
        }
        img.isTemplate = false
        return img
    }
}
