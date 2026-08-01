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
        registry.providers.filter { !isDisabled($0.id) }
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

    /// Trigger a manual disk rescan (used after a user does
    /// `CLAUDE_CONFIG_DIR=~/.claude-work claude` in their own Terminal —
    /// they can hit the popover's refresh button and we'll pick it up).
    func rescanDisk() {
        registry.rebuild()
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
