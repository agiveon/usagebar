import AppKit
import SwiftUI

// macOS's status bar auto-templates any icon (paints it black/white by theme),
// which drops our traffic-light tint on the floor.  To keep the color, we
// build an NSImage with palette-color config and `isTemplate = false` — the
// bar then draws it as-is.
enum ColoredSymbol {

    static func nsImage(named name: String,
                        color: NSColor,
                        pointSize: CGFloat = 14) -> NSImage? {
        let base = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
        let palette = NSImage.SymbolConfiguration(paletteColors: [color])
        let cfg = base.applying(palette)
        let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)
        img?.isTemplate = false
        return img
    }

    /// Convert a SwiftUI Color to an NSColor via `.labelColor` fallback if the
    /// resolve fails.  We resolve against a light/dark-aware environment so
    /// system colors (.green/.red/…) still look right in both themes.
    static func nsColor(from color: Color) -> NSColor {
        NSColor(color).usingColorSpace(.sRGB) ?? NSColor.labelColor
    }
}
