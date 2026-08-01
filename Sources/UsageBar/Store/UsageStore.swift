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
    @AppStorage("refreshIntervalSeconds") var refreshInterval: Double = 60
    @AppStorage("showPercentLabel") var showPercentLabel: Bool = true
    /// User-chosen nicknames per provider id, JSON-encoded.
    @AppStorage("customLabels") private var customLabelsRaw: String = "{}"

    private var timerTask: Task<Void, Never>?
    private var consecutiveFailures: [String: Int] = [:]
    private var registryCancellable: AnyCancellable?

    init(registry: ProviderRegistry) {
        self.registry = registry
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
        // Drop statuses / failure counts for instances that no longer exist.
        for id in Array(statuses.keys) where !liveIDs.contains(id) {
            statuses.removeValue(forKey: id)
            consecutiveFailures.removeValue(forKey: id)
        }
        // Placeholder + immediate refresh for anything new & enabled.
        let newIDs = liveIDs.subtracting(statuses.keys)
        for id in newIDs where !isDisabled(id) {
            statuses[id] = .notAvailable("checking…")
            Task { await refreshOne(providerID: id) }
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

    var enabledProviders: [UsageProvider] {
        let dups = duplicateProviderIDs
        return registry.providers.filter { !isDisabled($0.id) && !dups.contains($0.id) }
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

    private var customLabels: [String: String] {
        guard let data = customLabelsRaw.data(using: .utf8),
              let dict = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return dict
    }

    func customLabel(for providerID: String) -> String? {
        let raw = customLabels[providerID]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (raw?.isEmpty == false) ? raw : nil
    }

    func setCustomLabel(_ label: String, for providerID: String) {
        var dict = customLabels
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            dict.removeValue(forKey: providerID)
        } else {
            dict[providerID] = trimmed
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

    /// Delete the Keychain item backing a Claude account.  The tab
    /// disappears on the next registry rebuild.  Deleting the default
    /// item signs the user out of Claude Code in every editor — the UI
    /// confirmation dialog spells this out.
    func deleteClaudeAccount(providerID: String) {
        guard let p = registry.provider(id: providerID) as? ClaudeCodeProvider
        else { return }
        _ = ClaudeCredentials.deleteKeychainItem(service: p.keychainService)
        statuses.removeValue(forKey: providerID)
        registry.rebuild()
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

        // A manual refresh doubles as a rescan — cheap, and it lets the
        // user pick up a freshly-signed-in ~/.claude-work without quitting.
        registry.rebuild()

        await withTaskGroup(of: (String, ProviderStatus).self) { group in
            for provider in enabledProviders {
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
        let (id, status) = await Self.fetch(provider: p)
        applyResult(id: id, status: status)
    }

    private func applyResult(id: String, status: ProviderStatus) {
        // Failure smoothing: after 2 consecutive errors we mark the previous
        // snapshot stale rather than replacing it with an error string, so the
        // popover keeps showing something useful.
        if case .error = status {
            let n = (consecutiveFailures[id] ?? 0) + 1
            consecutiveFailures[id] = n
            if n >= 2, case .available(var snap) = statuses[id] {
                snap.isStale = true
                statuses[id] = .available(snap)
                return
            }
        } else {
            consecutiveFailures[id] = 0
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
                let interval = max(30.0, self?.refreshInterval ?? 60)
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                await self?.refreshNow()
            }
        }
    }
}
