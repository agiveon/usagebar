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

    init(registry: ProviderRegistry) {
        self.registry = registry
        // Seed every enabled provider with a placeholder so no row sits at
        // "loading…" forever if its first poll is slow or hangs.
        for p in registry.providers where !isDisabled(p.id) {
            statuses[p.id] = .notAvailable("checking…")
        }
        if storedActiveID.isEmpty || registry.provider(id: storedActiveID) == nil,
           let first = enabledProviders.first {
            storedActiveID = first.id
        }
        startPolling()
        Task { await refreshNow() }
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
        // Retry shortly — user usually completes sign-in within a few seconds.
        Task {
            try? await Task.sleep(nanoseconds: 5 * 1_000_000_000)
            await refreshOne(providerID: providerID)
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
        switch provider.id {
        case "claude-code": return "not signed in to Claude Code"
        case "codex":       return "not signed in to Codex"
        case "cursor":      return "not signed in to Cursor (or Cursor.app not installed)"
        case "copilot":     return "no GitHub Copilot token found"
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
