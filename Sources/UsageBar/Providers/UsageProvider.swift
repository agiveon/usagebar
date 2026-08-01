import Foundation

// How the user signs in to this service.  We never enter credentials for them
// — we only open their own sign-in surface.
enum SignInAction: Sendable {
    /// Open a Terminal window and run `command`.
    case runCommand(String, hint: String)
    /// Launch a native macOS app (by bundle identifier if known, else app name).
    case openApp(bundleID: String?, appName: String, hint: String)
    /// Open a URL in the user's default browser.
    case openURL(URL, hint: String)

    var hint: String {
        switch self {
        case .runCommand(_, let h),
             .openApp(_, _, let h),
             .openURL(_, let h):
            return h
        }
    }

    var buttonLabel: String {
        switch self {
        case .runCommand:   return "Open Terminal & sign in"
        case .openApp(_, let name, _): return "Open \(name)"
        case .openURL:      return "Open sign-in page"
        }
    }
}

protocol UsageProvider: Sendable {
    var id: String { get }
    var displayName: String { get }
    /// One-word label used on the tab bar in the popover — short enough
    /// that four of them fit across ~340 pt.  Defaults to the first
    /// word of `displayName`.
    var shortName: String { get }
    /// SF Symbol name — used as a fallback when the bundled SVG asset is
    /// missing (e.g. during a `swift run` dev launch that bypasses the .app).
    var iconName: String { get }
    /// Bundled SVG asset (base name, no extension) under
    /// `.app/Contents/Resources/Icons/`.  When present, we render the brand
    /// logo tinted by the traffic-light color.
    var iconAsset: String? { get }
    var signInAction: SignInAction { get }

    func isAvailable() async -> Bool
    func fetchSnapshot() async throws -> UsageSnapshot
}

extension UsageProvider {
    var iconAsset: String? { nil }
    var shortName: String {
        displayName.split(whereSeparator: { $0 == " " || $0 == "·" })
            .first.map(String.init) ?? displayName
    }
}
