import SwiftUI

struct PopoverView: View {
    @EnvironmentObject var store: UsageStore
    @State private var showSettings = false

    var body: some View {
        Group {
            if showSettings {
                SettingsView(dismiss: { showSettings = false })
            } else {
                MainView(openSettings: { showSettings = true })
            }
        }
        .padding(14)
        .frame(width: 360)
    }
}

// MARK: - Main list (tabs + selected provider content)

private struct MainView: View {
    @EnvironmentObject var store: UsageStore
    let openSettings: () -> Void

    /// Which provider tab is currently shown.  Nil = follow the menu-bar
    /// active provider (default, and what we fall back to when the tab the
    /// user was on gets disabled from Settings).
    @State private var selectedTabID: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if store.isAddClaudeInProgress {
                Button {
                    store.focusPendingSignIn()
                } label: {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Claude sign-in in progress — click to reopen the window")
                            .font(.caption)
                        Spacer()
                        Image(systemName: "arrow.up.forward.app")
                            .font(.caption)
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.accentColor.opacity(0.15)))
                }
                .buttonStyle(.plain)
            }

            let enabled = store.enabledProviders
            if enabled.isEmpty {
                Divider()
                Text("No providers enabled. Open Settings to turn one on.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Divider()
                TabBar(enabled: enabled,
                       selectedID: currentTab(enabled: enabled),
                       onSelect: { selectedTabID = $0 })
                Divider().opacity(0.4)
                if let p = store.registry.provider(id: currentTab(enabled: enabled)) {
                    ProviderContent(provider: p,
                                    status: store.statuses[p.id],
                                    isActive: store.activeProviderID == p.id)
                }
            }

            Divider()
            footer
        }
    }

    private func currentTab(enabled: [UsageProvider]) -> String {
        if let s = selectedTabID, enabled.contains(where: { $0.id == s }) {
            return s
        }
        // Follow the menu-bar provider by default; if that's somehow disabled,
        // any enabled one will do.
        if enabled.contains(where: { $0.id == store.activeProviderID }) {
            return store.activeProviderID
        }
        return enabled.first?.id ?? ""
    }

    private var header: some View {
        HStack {
            Text("UsageBar").font(.headline)
            Spacer()
            if let updated = store.lastUpdatedText {
                Text(updated).font(.caption).foregroundStyle(.secondary)
            }
            Button {
                Task { await store.refreshNow() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(store.isRefreshing)
            .help("Refresh now")
        }
    }

    private var footer: some View {
        HStack {
            Button {
                openSettings()
            } label: {
                Image(systemName: "gearshape")
                Text("Settings")
            }
            .buttonStyle(.borderless)
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
    }
}

// MARK: - Tab bar

private struct TabBar: View {
    @EnvironmentObject var store: UsageStore
    let enabled: [UsageProvider]
    let selectedID: String
    let onSelect: (String) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(enabled, id: \.id) { p in
                TabButton(
                    provider: p,
                    isSelected: selectedID == p.id,
                    isMenuBar: store.activeProviderID == p.id,
                    status: store.statuses[p.id],
                    onTap: { onSelect(p.id) }
                )
            }
        }
    }
}

private struct TabButton: View {
    let provider: UsageProvider
    let isSelected: Bool
    let isMenuBar: Bool
    let status: ProviderStatus?
    let onTap: () -> Void

    @EnvironmentObject var store: UsageStore

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 3) {
                ProviderIcon(provider: provider, color: tabColor, size: 18)
                Text(store.effectiveShortName(for: provider))
                    .font(.caption2)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(isSelected ? .primary : .secondary)
                Circle()
                    .fill(Color.secondary)
                    .frame(width: 3, height: 3)
                    .opacity(isMenuBar ? 1 : 0)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color.gray.opacity(0.18) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(store.effectiveDisplayName(for: provider)
              + (isMenuBar ? " · in menu bar" : ""))
    }

    private var tabColor: Color {
        if case .some(.available(let snap)) = status, !snap.isStale {
            return Thresholds.color(for: snap.worstPercent)
        }
        return .secondary
    }
}

// MARK: - Selected tab's content

private struct ProviderContent: View {
    @EnvironmentObject var store: UsageStore
    let provider: UsageProvider
    let status: ProviderStatus?
    let isActive: Bool

    private var health: UsageStore.ProviderHealth { store.health(for: provider.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            headerRow
            windowsOrPlaceholder
        }
    }

    private var headerRow: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Text(store.effectiveDisplayName(for: provider))
                    .font(.system(.body).weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if isActive {
                    Text("· in menu bar")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                inlineAction
            }
            if store.customLabel(for: provider.id) != nil,
               let email = store.accountLabel(for: provider.id) {
                Text(email)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    /// A single small text-button on the right of the header when the
    /// account needs the user's attention.  No colored banners — we don't
    /// want to make transient issues look like the app is broken.
    @ViewBuilder
    private var inlineAction: some View {
        switch health {
        case .ok:
            if !isActive {
                Button("Show in menu bar") { store.setActive(provider.id) }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
        case .notSignedIn:
            Button(provider.signInAction.buttonLabel) {
                store.signIn(providerID: provider.id)
            }
            .buttonStyle(.borderless)
            .font(.caption)
        case .authExpired:
            Button("Reconnect") { store.signIn(providerID: provider.id) }
                .buttonStyle(.borderless)
                .font(.caption)
                .foregroundStyle(.orange)
        case .checking, .rateLimited, .otherError:
            EmptyView()
        }
    }

    /// Whenever we have snapshot data — even stale — show it.  Rate limits
    /// and transient errors keep the last-known windows visible; only the
    /// "no data ever" states show a placeholder.
    @ViewBuilder
    private var windowsOrPlaceholder: some View {
        if case .some(.available(let snap)) = status, !snap.windows.isEmpty {
            ForEach(snap.windows) { w in
                WindowBar(window: w,
                          isMenuBarMetric: isActive
                            && store.menuBarWindowID == w.id)
            }
        } else if case .checking = health {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Loading…").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Shared little views

/// Brand SVG (or SF Symbol fallback), tinted.  Used by both tab buttons
/// and the provider content header.
private struct ProviderIcon: View {
    let provider: UsageProvider
    let color: Color
    let size: CGFloat

    var body: some View {
        Group {
            if let img = BrandIcon.nsImage(asset: provider.iconAsset,
                                            sfSymbol: provider.iconName,
                                            color: NSColor(color),
                                            pointSize: size) {
                Image(nsImage: img)
            } else {
                Image(systemName: provider.iconName).foregroundStyle(color)
            }
        }
        .frame(width: size, height: size)
    }
}

private struct WindowBar: View {
    let window: UsageWindow
    let isMenuBarMetric: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                if isMenuBarMetric {
                    Image(systemName: "menubar.rectangle")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(window.label).font(.caption)
                Spacer()
                Text("\(Int((window.percentUsed * 100).rounded()))%")
                    .font(.caption).monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.secondary.opacity(0.2))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Thresholds.color(for: window.percentUsed))
                        .frame(width: geo.size.width
                               * CGFloat(min(1.0, max(0.0, window.percentUsed))))
                }
            }
            .frame(height: 6)
            if let resets = window.resetsAt {
                Text("resets \(ResetFormatter.string(until: resets))")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Settings

private struct SettingsView: View {
    @EnvironmentObject var store: UsageStore
    let dismiss: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "chevron.left")
                        Text("Back")
                    }
                    .buttonStyle(.borderless)
                    Spacer()
                    Text("Settings").font(.headline)
                }

                Divider()

                if let err = store.lastDeleteError {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(err).font(.caption)
                        Spacer()
                        Button("Dismiss") { store.lastDeleteError = nil }
                            .buttonStyle(.borderless).font(.caption)
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.orange.opacity(0.15)))
                }

                // Providers, grouped by kind -----------------------------
                Text("Providers").font(.subheadline).foregroundStyle(.secondary)
                ProvidersSection()

                Divider()

                // Menu bar display --------------------------------------
                Text("Menu bar display")
                    .font(.subheadline).foregroundStyle(.secondary)

                Toggle("Show every enabled provider",
                       isOn: $store.showAllProvidersInMenuBar)
                Text("Off: only the provider below appears in the menu bar. On: one icon per enabled provider.")
                    .font(.caption2).foregroundStyle(.secondary)

                Picker("Provider", selection: providerBinding) {
                    ForEach(store.enabledProviders, id: \.id) { p in
                        Text(store.effectiveDisplayName(for: p)).tag(p.id)
                    }
                }

                Picker("Metric", selection: $store.menuBarWindowID) {
                    Text("Worst window").tag(MenuBarWorstMetric)
                    ForEach(store.activeProviderWindows) { w in
                        Text(w.label).tag(w.id)
                    }
                }
                .disabled(store.activeProviderWindows.isEmpty)

                Toggle("Show percentage next to icon", isOn: $store.showPercentLabel)

                Divider()

                // Refresh -----------------------------------------------
                Text("Refresh interval: \(Int(store.refreshInterval))s")
                    .font(.subheadline).foregroundStyle(.secondary)
                Slider(value: $store.refreshInterval,
                       in: UsageStore.minRefreshInterval...600,
                       step: 30)
                Text("Anthropic and OpenAI rate-limit around 30s intervals with multiple accounts — 60s is the floor.")
                    .font(.caption2).foregroundStyle(.secondary)

                Divider()

                // Diagnostics ------------------------------------------
                DiagnosticsSection()
            }
        }
        .frame(maxHeight: 520)
    }

    private var providerBinding: Binding<String> {
        Binding(
            get: { store.activeProviderID },
            set: { store.setActive($0) }
        )
    }
}

// MARK: - Diagnostics

private struct DiagnosticsSection: View {
    @EnvironmentObject var store: UsageStore
    @State private var showReport = false
    @State private var copyConfirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Diagnostics")
                    .font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(store.diagnosticsReport(), forType: .string)
                    copyConfirm = true
                    Task {
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        copyConfirm = false
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: copyConfirm ? "checkmark" : "doc.on.doc")
                        Text(copyConfirm ? "Copied!" : "Copy diagnostics")
                    }
                    .font(.caption)
                }
                .buttonStyle(.borderless)
                Button(showReport ? "Hide" : "Show") { showReport.toggle() }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
            Text("If something looks wrong, paste this into an issue and I'll know exactly what UsageBar sees. No tokens or credentials are included.")
                .font(.caption2).foregroundStyle(.secondary)

            if showReport {
                ScrollView {
                    Text(store.diagnosticsReport())
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(maxHeight: 220)
                .background(RoundedRectangle(cornerRadius: 6)
                                .fill(Color.gray.opacity(0.15)))
            }
        }
    }
}

// MARK: - Providers section (grouped by kind + add/remove for Claude/Codex)

private struct ProvidersSection: View {
    @EnvironmentObject var store: UsageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            KindGroup(kind: .claude,
                      title: "Claude Code",
                      providers: instances(prefix: "claude-code"))
            KindGroup(kind: .codex,
                      title: "ChatGPT · Codex",
                      providers: instances(prefix: "codex"))
            KindGroup(kind: nil,
                      title: "Cursor",
                      providers: instances(prefix: "cursor"))
            KindGroup(kind: nil,
                      title: "GitHub Copilot",
                      providers: instances(prefix: "copilot"))
        }
    }

    private func instances(prefix: String) -> [UsageProvider] {
        // Settings shows every provider the registry knows about — even
        // broken extras hidden from the tab bar — so the user can manage
        // and delete them.
        store.registry.providers.filter {
            $0.id == prefix || $0.id.hasPrefix("\(prefix):")
        }
    }
}

/// Settings row for a single account: enable toggle, account email
/// subtitle, and an editable nickname field.  The nickname takes priority
/// over the email in the tab bar / row header.
private struct AccountRow: View {
    @EnvironmentObject var store: UsageStore
    let provider: UsageProvider

    @State private var confirmingDelete = false

    private var isDuplicate: Bool { store.duplicateProviderIDs.contains(provider.id) }
    private var isClaude: Bool { provider is ClaudeCodeProvider }
    private var isDefaultClaude: Bool {
        (provider as? ClaudeCodeProvider)?.keychainService == "Claude Code-credentials"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Toggle(store.effectiveDisplayName(for: provider),
                       isOn: store.enabledBinding(provider.id))
                    .toggleStyle(.checkbox)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if isDuplicate {
                    Text("duplicate")
                        .font(.caption2)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.orange.opacity(0.25))
                        .foregroundStyle(.orange)
                        .cornerRadius(4)
                }
                Spacer()
                if isClaude {
                    if confirmingDelete {
                        Button("Cancel") { confirmingDelete = false }
                            .buttonStyle(.borderless)
                            .font(.caption)
                        Button {
                            store.deleteClaudeAccount(providerID: provider.id)
                            confirmingDelete = false
                        } label: {
                            Text(isDefaultClaude ? "Sign out" : "Delete")
                                .font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                        .controlSize(.small)
                    } else {
                        Button {
                            confirmingDelete = true
                        } label: {
                            Image(systemName: "trash")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help(isDefaultClaude
                              ? "Delete this account (signs you out of Claude Code!)"
                              : "Delete this account's Keychain entry")
                    }
                }
            }
            if confirmingDelete {
                Text(isDefaultClaude
                     ? "Signs you out of Claude Code on this Mac. You'll have to run `claude` to sign back in."
                     : "Permanently removes this account's Keychain entry.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .padding(.leading, 20)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let email = store.accountLabel(for: provider.id),
               store.customLabel(for: provider.id) != nil {
                Text(email)
                    .font(.caption2).foregroundStyle(.secondary)
                    .padding(.leading, 20)
            }
            HStack(spacing: 6) {
                Text("Nickname")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(width: 62, alignment: .leading)
                TextField(nicknamePlaceholder,
                          text: store.customLabelBinding(for: provider.id))
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
            }
            .padding(.leading, 20)
        }
        .padding(.vertical, 2)
        .opacity(isDuplicate ? 0.6 : 1.0)
    }

    private var nicknamePlaceholder: String {
        if let email = store.accountLabel(for: provider.id) {
            return email
        }
        return "e.g. Work"
    }

}

/// One provider kind and its detected instances.  Instances come from disk —
/// there's no "Add" flow in the app.  For services that support isolated
/// installs (Claude, Codex) we show a tiny hint on how to add another one.
private struct KindGroup: View {
    @EnvironmentObject var store: UsageStore
    let kind: ProviderRegistry.Kind?    // .claude / .codex show the hint
    let title: String
    let providers: [UsageProvider]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption).foregroundStyle(.secondary)

            if providers.isEmpty {
                Text("(no accounts detected)")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(providers, id: \.id) { p in
                    AccountRow(provider: p)
                }
            }

            if kind == .claude {
                Button {
                    store.beginAddClaudeAccount()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus.circle.fill")
                        Text("Add another Claude Code account")
                    }
                    .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Opens a sign-in window inside UsageBar. No Terminal.")
            } else if kind == .codex {
                Text("Second Codex account? Run  CODEX_HOME=~/.codex-work codex login  in Terminal, then hit refresh.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.top, 2)
            }
        }
    }
}
