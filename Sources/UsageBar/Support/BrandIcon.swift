import AppKit
import SwiftUI

// Prefer a bundled brand SVG (rendered + tinted) over the provider's SF Symbol.
// SVGs live in the .app under Contents/Resources/Icons/<asset>.svg — copied
// there by build.sh.  If the asset isn't present (or NSImage can't render it),
// we fall back to the SF Symbol path in ColoredSymbol.
enum BrandIcon {

    static func nsImage(asset: String?,
                        sfSymbol: String,
                        color: NSColor,
                        pointSize: CGFloat = 16) -> NSImage? {
        if let asset,
           let url = Bundle.main.url(forResource: asset,
                                      withExtension: "svg",
                                      subdirectory: "Icons"),
           let base = NSImage(contentsOfFile: url.path) {
            return tinted(base: base, color: color, pointSize: pointSize)
        }
        return ColoredSymbol.nsImage(named: sfSymbol, color: color, pointSize: pointSize)
    }

    private static func tinted(base: NSImage,
                                color: NSColor,
                                pointSize: CGFloat) -> NSImage {
        let size = NSSize(width: pointSize, height: pointSize)
        let out = NSImage(size: size, flipped: false) { rect in
            base.draw(in: rect,
                      from: .zero,
                      operation: .sourceOver,
                      fraction: 1.0)
            color.set()
            // `.sourceAtop` paints the color only where the image drew pixels,
            // giving us the brand shape in our target color.
            rect.fill(using: .sourceAtop)
            return true
        }
        out.isTemplate = false
        return out
    }
}
