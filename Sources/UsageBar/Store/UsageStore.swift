import Foundation
import SwiftUI
import Combine

// Sentinel used when the menu-bar metric is "the worst window in the active
// provider" (the default) rather than a specific window id.
let MenuBarWorstMetric = "worst"

@MainActor
final class UsageStore: ObservableObject {
    let registry: ProviderRegistry

    @Published private(set) var statuses: [String: ProviderStatus] = [:]
    @Published private(set) var lastRefreshedAt: Date?
    @Published private(set) var isRefreshing = false

    // Persisted preferences.
    // We store *disabled* provider IDs (not enabled) so that new providers
    // added in a future release automatically appear — an existing install
    // that never touched Settings shouldn't need to know they exist.
    @AppStorage("activeProviderID") private var storedActiveID: String = ""
    @AppStorage("menuBarWindowID")  var menuBarWindowID: String = MenuBarWorstMetric
    @AppStorage("disabledProviderIDs") private var disabledIDsRaw: String = ""
    @AppStorage("refreshIntervalSeconds") var refreshInterval: Double = 120
    @AppStorage("showPercentLabel") var showPercentLabel: Bool = true
    /// User-chosen nicknames per provider id, JSON-encoded.
    @AppStorage("customLabels") private var customLabelsRaw: String = "{}"

    private var timerTask: Task<Void, Never>?
    private var consecutiveFailures: [String: Int] = [:]
    private var registryCancellable: AnyCancellable?
    /// Per-provider "don't poll again until" timestamp — set silently when
    /// we hit a 429 so we don't hammer an endpoint that's already told us
    /// to wait.  This is entirely invisible to the user; the tab keeps
    /// showing whatever we last saw.
    private var backoffUntil: [String: Date] = [:]
    /// Minimum poll interval we'll ever honor.  30s used to be the floor
    /// but that reliably provokes 429 from Anthropic once you have two
    /// Claude accounts (usage + profile = 8 req/min) — 60s is polite.
    static let minRefreshInterval: Double = 60

    init(registry: ProviderRegistry) {
        self.registry = registry
        // Migrate existing installs that had the old 30 s floor.
        if refreshInterval < Self.minRefreshInterval {
            refreshInterval = Self.minRefreshInterval
        }
        seedPlaceholders()
        ensureActiveIsValid()

        // Re-sync statuses whenever the registry rebuilds (user added or
        // removed an extra account).  We seed placeholders for newcomers,
        // drop stale entries, and kick a refresh for any newcomer that's
        // enabled.
        registryCancellable = registry.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.reconcileWithRegistry()
                }
            }

        startPolling()
        Task { await refreshNow() }
    }

    private func seedPlaceholders() {
        for p in registry.providers where !isDisabled(p.id) {
            if statuses[p.id] == nil {
                statuses[p.id] = .notAvailable("checking…")
            }
        }
    }

    private func ensureActiveIsValid() {
        if storedActiveID.isEmpty || registry.provider(id: storedActiveID) == nil,
           let first = enabledProviders.first {
            storedActiveID = first.id
            menuBarWindowID = MenuBarWorstMetric
        }
    }

    private func reconcileWithRegistry() {
        let liveIDs = Set(registry.providers.map(\.id))
        for id in Array(statuses.keys) where !liveIDs.contains(id) {
            statuses.removeValue(forKey: id)
            consecutiveFailures.removeValue(forKey: id)
            backoffUntil.removeValue(forKey: id)
        }
        let newIDs = liveIDs.subtracting(statuses.keys)
        for id in newIDs where !isDisabled(id) {
            statuses[id] = .notAvailable("checking…")
            Task { await refreshOne(providerID: id) }
        }
        // Prune ghost prefs left behind when we delete an account so
        // preferences don't accumulate corpses across sessions.
        var disabled = disabledProviderIDs
        let disabledGhosts = disabled.subtracting(liveIDs)
        if !disabledGhosts.isEmpty {
            disabled.subtract(disabledGhosts)
            disabledIDsRaw = disabled.sorted().joined(separator: ",")
        }
        // Only prune label keys that look like provider ids (contain ":" or
        // match a known kind prefix).  Email-keyed labels are kept forever
        // — they'll re-attach to the account next time it appears.
        var labels = customLabels
        let looksLikeProviderID: (String) -> Bool = { key in
            key.contains(":")
                || ["claude-code","codex","cursor","copilot"].contains(key)
        }
        let candidates = Set(labels.keys.filter(looksLikeProviderID))
        let ghosts = candidates.subtracting(liveIDs)
        if !ghosts.isEmpty {
            for k in ghosts { labels.removeValue(forKey: k) }
            if let data = try? JSONEncoder().encode(labels),
               let str = String(data: data, encoding: .utf8) {
                customLabelsRaw = str
            }
        }
        ensureActiveIsValid()
        objectWillChange.send()
    }

    // MARK: - Active provider (drives the menu-bar glyph)

    var activeProviderID: String { storedActiveID }
    var activeStatus: ProviderStatus? { statuses[activeProviderID] }

    func setActive(_ id: String) {
        guard registry.provider(id: id) != nil, !isDisabled(id) else { return }
        storedActiveID = id
        menuBarWindowID = MenuBarWorstMetric
    }

    // MARK: - Enabled providers  (stored as "disabled" set, inverted)

    private var disabledProviderIDs: Set<String> {
        Set(disabledIDsRaw.split(separator: ",").map(String.init))
    }

    func isDisabled(_ id: String) -> Bool { disabledProviderIDs.contains(id) }
    func isEnabled(_ id: String)  -> Bool { !isDisabled(id) }

    /// Providers eligible to appear as tabs / drive the menu bar.  We
    /// hide disabled ones and true duplicates, but we DO show broken /
    /// rate-limited / auth-expired accounts — with a clear state
    /// indicator and an action button — because "silently missing" is a
    /// worse UX than "visibly needs attention".
    var enabledProviders: [UsageProvider] {
        let dups = duplicateProviderIDs
        return registry.providers.filter { p in
            !isDisabled(p.id) && !dups.contains(p.id)
        }
    }

    private func isExtraInstance(_ id: String) -> Bool { id.contains(":") }

    /// Human-readable state for a provider tab: rate-limited, auth-expired,
    /// or normal.  Drives the warning chip + action button on the row.
    enum ProviderHealth {
        case ok, checking, notSignedIn, rateLimited(retryAt: Date?), authExpired, otherError(String)
    }

    func health(for providerID: String) -> ProviderHealth {
        if let until = backoffUntil[providerID], until > Date() {
            return .rateLimited(retryAt: until)
        }
        switch statuses[providerID] {
        case .none:
            return .checking
        case .some(.notAvailable(let r)) where r == "checking…":
            return .checking
        case .some(.available):
            return .ok
        case .some(.notAvailable):
            return .notSignedIn
        case .some(.error(let msg)):
            let lower = msg.lowercased()
            if lower.contains("rate limited") {
                return .rateLimited(retryAt: backoffUntil[providerID])
            }
            if lower.contains("auth") { return .authExpired }
            return .otherError(msg)
        }
    }

    func setEnabled(_ id: String, _ enabled: Bool) {
        var disabled = disabledProviderIDs
        if enabled { disabled.remove(id) } else { disabled.insert(id) }

        // Refuse to disable the last one; snap the toggle back visually.
        let remaining = registry.providers.filter { !disabled.contains($0.id) }
        if remaining.isEmpty {
            objectWillChange.send()
            return
        }
        disabledIDsRaw = disabled.sorted().joined(separator: ",")

        if enabled {
            statuses[id] = .notAvailable("checking…")
            Task { await refreshOne(providerID: id) }
        } else {
            statuses.removeValue(forKey: id)
            if storedActiveID == id, let next = enabledProviders.first {
                storedActiveID = next.id
                menuBarWindowID = MenuBarWorstMetric
            }
        }
        objectWillChange.send()
    }

    func enabledBinding(_ id: String) -> Binding<Bool> {
        Binding(get: { self.isEnabled(id) },
                set: { self.setEnabled(id, $0) })
    }

    // MARK: - Custom labels / display names
    //
    // We store nicknames by *account identity* (email) whenever we know it,
    // and fall back to the provider id for accounts that haven't fetched a
    // profile yet.  Keying by email means a nickname survives Claude Code
    // creating a new Keychain item (different hash) for the same account —
    // which is exactly what happens when the user re-signs in from another
    // CLAUDE_CONFIG_DIR or after a restart.

    private var customLabels: [String: String] {
        guard let data = customLabelsRaw.data(using: .utf8),
              let dict = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return dict
    }

    /// Best identity key we have for this provider.  Prefer email; fall back
    /// to provider id (used for accounts that haven't polled successfully yet).
    private func labelKeys(for providerID: String) -> [String] {
        var keys: [String] = []
        if let email = accountLabel(for: providerID)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !email.isEmpty {
            keys.append(email.lowercased())
        }
        keys.append(providerID)
        return keys
    }

    func customLabel(for providerID: String) -> String? {
        for key in labelKeys(for: providerID) {
            if let val = customLabels[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !val.isEmpty {
                return val
            }
        }
        return nil
    }

    func setCustomLabel(_ label: String, for providerID: String) {
        var dict = customLabels
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        // Prefer the email as the storage key so this label survives the
        // account being re-signed-in with a different Keychain hash.
        let primaryKey = labelKeys(for: providerID).first ?? providerID
        // Cleanup any stray copies under the id key so future email lookups
        // don't disagree with themselves.
        for key in labelKeys(for: providerID) where key != primaryKey {
            dict.removeValue(forKey: key)
        }
        if trimmed.isEmpty {
            dict.removeValue(forKey: primaryKey)
        } else {
            dict[primaryKey] = trimmed
        }
        if let data = try? JSONEncoder().encode(dict),
           let str  = String(data: data, encoding: .utf8) {
            customLabelsRaw = str
            objectWillChange.send()
        }
    }

    func customLabelBinding(for providerID: String) -> Binding<String> {
        Binding(get: { self.customLabel(for: providerID) ?? "" },
                set: { self.setCustomLabel($0, for: providerID) })
    }

    /// The email / display name the provider reported for this account, if
    /// we've successfully polled it.
    func accountLabel(for providerID: String) -> String? {
        guard case .some(.available(let snap)) = statuses[providerID] else { return nil }
        return snap.accountLabel
    }

    /// Full row/tab header: "Claude Code · Work" or "Claude Code · amir@…".
    func effectiveDisplayName(for provider: UsageProvider) -> String {
        let baseTitle = baseKindTitle(for: provider)
        if let custom = customLabel(for: provider.id) {
            return "\(baseTitle) · \(custom)"
        }
        if let email = accountLabel(for: provider.id), !email.isEmpty {
            return "\(baseTitle) · \(email)"
        }
        return provider.displayName
    }

    /// Compact label for tab bar (keeps tabs skinny).
    func effectiveShortName(for provider: UsageProvider) -> String {
        if let custom = customLabel(for: provider.id) { return custom }
        if let email = accountLabel(for: provider.id) {
            // Local part before @ — usually the friendliest 1-word label.
            if let at = email.firstIndex(of: "@") { return String(email[..<at]) }
            return email
        }
        return provider.shortName
    }

    /// The kind-only title without any account/instance suffix — e.g.
    /// "Claude Code" (from "Claude Code · Account 2" or plain "Claude Code").
    private func baseKindTitle(for provider: UsageProvider) -> String {
        // If displayName has " · " in it, take the prefix — that's the
        // clean per-kind title.  Otherwise use displayName as-is.
        if let sep = provider.displayName.range(of: " · ") {
            return String(provider.displayName[..<sep.lowerBound])
        }
        return provider.displayName
    }

    // MARK: - Menu bar metric

    var menuBarPercent: Double? {
        guard case .some(.available(let snap)) = activeStatus else { return nil }
        if menuBarWindowID == MenuBarWorstMetric || menuBarWindowID.isEmpty {
            return snap.worstPercent
        }
        return snap.windows.first { $0.id == menuBarWindowID }?.percentUsed
    }

    var activeProviderWindows: [UsageWindow] {
        if case .some(.available(let snap)) = activeStatus { return snap.windows }
        return []
    }

    // MARK: - Sign-in

    func signIn(providerID: String) {
        guard let p = registry.provider(id: providerID) else { return }
        SignInLauncher.perform(p.signInAction)
        // OAuth in the browser typically takes 15–30 s.  Poll every 3 s for
        // up to 90 s so the tab flips to live data seconds after the user
        // finishes signing in, not on the next 60 s poll tick.
        Task { await pollUntilAvailable(providerID: providerID) }
    }

    /// Trigger a manual disk rescan.
    func rescanDisk() {
        registry.rebuild()
    }

    /// Delete the Keychain item backing a Claude account.  Publishes the
    /// error string on failure so the UI can show what went wrong instead
    /// of the button appearing to do nothing.
    @Published var lastDeleteError: String?

    func deleteClaudeAccount(providerID: String) {
        guard let p = registry.provider(id: providerID) as? ClaudeCodeProvider
        else {
            lastDeleteError = "provider \(providerID) not found"
            return
        }
        switch ClaudeCredentials.deleteKeychainItem(service: p.keychainService) {
        case .success:
            lastDeleteError = nil
            statuses.removeValue(forKey: providerID)
            // Also drop any prefs referencing this instance.
            if storedActiveID == providerID { storedActiveID = "" }
            var disabled = disabledProviderIDs
            if disabled.remove(providerID) != nil {
                disabledIDsRaw = disabled.sorted().joined(separator: ",")
            }
            registry.rebuild()
        case .failed(let reason):
            lastDeleteError = "Delete failed: \(reason)"
        }
    }

    /// Providers whose account emails duplicate another provider's — used
    /// by the UI to grey out or hide obvious duplicates.  Preference for
    /// which to keep: the default `claude-code` beats any suffixed instance;
    /// otherwise the alphabetically-first id wins so it's stable across runs.
    var duplicateProviderIDs: Set<String> {
        var seen: [String: String] = [:]     // email -> chosen provider id
        var dups: Set<String> = []
        // Prefer default first, then everything else sorted.
        let ordered = registry.providers.sorted { a, b in
            if a.id == "claude-code" { return true }
            if b.id == "claude-code" { return false }
            return a.id < b.id
        }
        for p in ordered {
            guard let email = accountLabel(for: p.id), !email.isEmpty else { continue }
            let key = "\(kindPrefix(p.id))|\(email)"
            if let existing = seen[key] {
                _ = existing
                dups.insert(p.id)
            } else {
                seen[key] = p.id
            }
        }
        return dups
    }

    private func kindPrefix(_ id: String) -> String {
        id.split(separator: ":").first.map(String.init) ?? id
    }

    // MARK: - Diagnostics

    /// A plain-text snapshot of everything UsageBar sees right now.  The
    /// user can copy this from Settings and paste into an issue / email so
    /// we can debug without asking "what does yours show?" for 3 rounds.
    /// Deliberately excludes any credential data.
    func diagnosticsReport() -> String {
        var out: [String] = []
        out.append("== UsageBar diagnostics ==")
        out.append("time: \(ISO8601DateFormatter().string(from: Date()))")

        out.append("")
        out.append("== preferences ==")
        out.append("activeProviderID:      \(storedActiveID.isEmpty ? "(unset)" : storedActiveID)")
        out.append("menuBarWindowID:       \(menuBarWindowID)")
        out.append("refreshInterval:       \(Int(refreshInterval))s")
        out.append("showPercentLabel:      \(showPercentLabel)")
        out.append("disabledProviderIDs:   \(disabledIDsRaw.isEmpty ? "(none)" : disabledIDsRaw)")

        out.append("")
        out.append("== Claude Keychain items (attribute-only) ==")
        let items = ClaudeCredentials.discoverKeychainItems()
        if items.isEmpty {
            out.append("(none passed the filter)")
        } else {
            for it in items {
                out.append("- svc=\(it.service)  acct=\(it.account ?? "(nil)")")
            }
        }

        out.append("")
        out.append("== registered providers (\(registry.providers.count)) ==")
        let dups = duplicateProviderIDs
        for p in registry.providers {
            let flags = [
                isDisabled(p.id) ? "disabled" : nil,
                dups.contains(p.id) ? "duplicate" : nil,
                storedActiveID == p.id ? "active" : nil,
            ].compactMap { $0 }.joined(separator: ",")
            let flagText = flags.isEmpty ? "" : "  [\(flags)]"
            out.append("- \(p.id)\(flagText)")
            out.append("    displayName:  \(p.displayName)")
            out.append("    effective:    \(effectiveDisplayName(for: p))")
            if let email = accountLabel(for: p.id) {
                out.append("    email:        \(email)")
            }
            if let custom = customLabel(for: p.id) {
                out.append("    nickname:     \(custom)")
            }
            switch statuses[p.id] {
            case .some(.available(let snap)):
                out.append("    status:       available (\(snap.windows.count) windows, worst=\(Int(snap.worstPercent * 100))%)\(snap.isStale ? " STALE" : "")")
            case .some(.notAvailable(let hint)):
                out.append("    status:       notAvailable — \(hint)")
            case .some(.error(let msg)):
                out.append("    status:       error — \(msg)")
            case .none:
                out.append("    status:       (no snapshot yet)")
            }
        }

        if let err = lastDeleteError {
            out.append("")
            out.append("== last delete error ==")
            out.append(err)
        }
        return out.joined(separator: "\n")
    }

    /// One-click, zero-Terminal add-a-Claude-account flow.  Opens a
    /// floating window, runs `claude auth login` in the background, and
    /// picks up the new install once creds land.
    @Published private(set) var isAddClaudeInProgress = false
    private var pendingSignInController: SignInWindowController?

    func beginAddClaudeAccount() {
        if let existing = pendingSignInController {
            existing.bringToFront()
            return
        }
        let controller = SignInWindowController { [weak self] in
            self?.pendingSignInController = nil
            self?.isAddClaudeInProgress = false
            self?.rescanDisk()
            Task { await self?.refreshNow() }
        }
        pendingSignInController = controller
        isAddClaudeInProgress = true
        controller.present()
    }

    /// Bring the in-progress sign-in window back to front if there is one.
    /// Called from the popover so the user can never lose the window.
    func focusPendingSignIn() {
        pendingSignInController?.bringToFront()
    }

    private func pollUntilAvailable(providerID: String, maxSeconds: Int = 90) async {
        let start = Date()
        while Date().timeIntervalSince(start) < TimeInterval(maxSeconds) {
            try? await Task.sleep(nanoseconds: 3 * 1_000_000_000)
            await refreshOne(providerID: providerID)
            if case .some(.available) = statuses[providerID] { return }
        }
    }

    // MARK: - Refresh

    var lastUpdatedText: String? {
        guard let d = lastRefreshedAt else { return nil }
        let s = Int(-d.timeIntervalSinceNow)
        if s < 5 { return "just now" }
        if s < 60 { return "\(s)s ago" }
        return "\(s / 60)m ago"
    }

    func refreshNow() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        registry.rebuild()

        // Only poll providers not currently in a backoff window.  Registry
        // includes disabled/dup-hidden ones so we still refresh them for
        // Settings visibility.
        let now = Date()
        let due = registry.providers.filter { p in
            !isDisabled(p.id) && (backoffUntil[p.id].map { $0 <= now } ?? true)
        }

        await withTaskGroup(of: (String, ProviderStatus).self) { group in
            for provider in due {
                group.addTask {
                    await Self.fetch(provider: provider)
                }
            }
            for await (id, status) in group {
                applyResult(id: id, status: status)
            }
        }
        lastRefreshedAt = Date()
    }

    func refreshOne(providerID: String) async {
        guard let p = registry.provider(id: providerID), !isDisabled(providerID) else { return }
        backoffUntil.removeValue(forKey: providerID)
        let (id, status) = await Self.fetch(provider: p)
        applyResult(id: id, status: status)
    }

    private func applyResult(id: String, status: ProviderStatus) {
        if case .error(let msg) = status {
            let lower = msg.lowercased()
            // 429 → back off silently for 5 minutes.  Don't blame the user.
            if lower.contains("rate limited") {
                backoffUntil[id] = Date().addingTimeInterval(300)
                // Absolutely never replace live data with an error string
                // for a transient thing — keep last snapshot visible.
                if case .available = statuses[id] { return }
                // No prior snapshot either?  Leave whatever placeholder
                // was there ("checking…") — don't downgrade to an error.
                return
            }
            let n = (consecutiveFailures[id] ?? 0) + 1
            consecutiveFailures[id] = n
            // Non-auth transient errors: keep last data, mark stale after 2.
            if !lower.contains("auth"),
               n >= 2, case .available(var snap) = statuses[id] {
                snap.isStale = true
                statuses[id] = .available(snap)
                return
            }
            // For anything else (auth-expired, decoding, tokenMissing)
            // we DO set an error status — that's a real state the user
            // needs to know about so they can reconnect.
        } else {
            consecutiveFailures[id] = 0
            backoffUntil.removeValue(forKey: id)
        }
        statuses[id] = status
    }

    // Runs the actual I/O off the main actor so a stuck `security` shell,
    // a slow SQLite copy, or a hanging HTTP request can't freeze the UI.
    nonisolated private static func fetch(provider: UsageProvider) async -> (String, ProviderStatus) {
        await Task.detached { () -> (String, ProviderStatus) in
            if await !provider.isAvailable() {
                return (provider.id, .notAvailable(notAvailableHint(for: provider)))
            }
            do {
                let snapshot = try await provider.fetchSnapshot()
                return (provider.id, .available(snapshot))
            } catch {
                return (provider.id, .error(error.localizedDescription))
            }
        }.value
    }

    nonisolated private static func notAvailableHint(for provider: UsageProvider) -> String {
        // Match on the id prefix so extra instances (e.g. "claude-code:work")
        // get the same base hint as their default counterpart.
        let base = provider.id.split(separator: ":").first.map(String.init) ?? provider.id
        switch base {
        case "claude-code": return "not signed in to \(provider.displayName)"
        case "codex":       return "not signed in to \(provider.displayName)"
        case "cursor":      return "not signed in to Cursor (or Cursor.app not installed)"
        case "copilot":     return "no GitHub Copilot token found for \(provider.displayName)"
        default:            return "not available"
        }
    }

    private func startPolling() {
        timerTask?.cancel()
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                let interval = max(Self.minRefreshInterval,
                                   self?.refreshInterval ?? 90)
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                await self?.refreshNow()
            }
        }
    }
}
