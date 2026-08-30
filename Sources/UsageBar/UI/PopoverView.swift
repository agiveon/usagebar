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
        // ScrollView is back so the window stays a reasonable size, but
        // scroll indicators are hidden — the visible scrollbar was
        // catching clicks meant for the delete buttons next to it.
        // Trackpad / mousewheel scrolling still works.
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

            Toggle("Show every provider in the menu bar",
                   isOn: store.showAllProvidersBinding)
            Text(store.showAllProvidersInMenuBar
                 ? "One icon per provider, each colored by its own worst window.  The Provider and Metric pickers below only apply when this is off."
                 : "A single icon.  Pick which provider and which window drive it below.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Picker("Provider", selection: providerBinding) {
                ForEach(store.enabledProviders, id: \.id) { p in
                    Text(store.effectiveDisplayName(for: p)).tag(p.id)
                }
            }
            .disabled(store.showAllProvidersInMenuBar)

            Picker("Metric", selection: $store.menuBarWindowID) {
                Text("Worst window").tag(MenuBarWorstMetric)
                ForEach(store.activeProviderWindows) { w in
                    Text(w.label).tag(w.id)
                }
            }
            .disabled(store.activeProviderWindows.isEmpty
                      || store.showAllProvidersInMenuBar)

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
        .scrollIndicators(.hidden)
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
    var body: some View { ProvidersFlatList() }
}

/// Big, obvious "Add Provider" entry.  Collapsed = a full-width prominent
/// button.  Expanded = a visible list of kinds (Grok API, SuperGrok, …)
/// so the user can see the entries instead of a hidden menu + Connect
/// that used to fire `codex login` in Terminal.
private struct AddProviderPanel: View {
    @EnvironmentObject var store: UsageStore
    @Binding var expanded: Bool

    var body: some View {
        if !expanded {
            Button {
                expanded = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 16, weight: .semibold))
                    Text("Add Provider")
                        .font(.callout.weight(.semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Which provider do you want to connect?")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") { expanded = false }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
                ForEach(store.addableKinds) { kind in
                    Button {
                        store.addProvider(kind: kind.id)
                        expanded = false
                    } label: {
                        HStack(spacing: 8) {
                            if let img = BrandIcon.nsImage(asset: kind.iconAsset,
                                                            sfSymbol: kind.sfSymbol,
                                                            color: .labelColor,
                                                            pointSize: 16) {
                                Image(nsImage: img)
                            }
                            VStack(alignment: .leading, spacing: 1) {
                                Text(kind.title)
                                    .font(.callout.weight(.medium))
                                    .foregroundStyle(.primary)
                                Text(kind.subtitle)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                            Image(systemName: "plus")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 8)
                            .fill(Color.gray.opacity(0.14)))
        }
    }
}

/// Settings row for a single connected account: brand icon, effective
/// name, email subtitle, nickname field, trash to remove.  No enable
/// checkbox — being in this list *is* being enabled.
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
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if let img = BrandIcon.nsImage(asset: provider.iconAsset,
                                                sfSymbol: provider.iconName,
                                                color: .labelColor,
                                                pointSize: 18) {
                    Image(nsImage: img)
                }
                Text(store.effectiveDisplayName(for: provider))
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if confirmingDelete {
                    Button("Cancel") { confirmingDelete = false }
                        .buttonStyle(.borderless).font(.caption)
                    Button("Remove") {
                        store.removeProvider(provider.id)
                        confirmingDelete = false
                    }
                    .buttonStyle(.borderedProminent).tint(.red)
                    .controlSize(.small)
                } else {
                    Button {
                        confirmingDelete = true
                    } label: {
                        Image(systemName: "trash")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help(isClaude
                          ? "Remove this account (deletes its Keychain entry)"
                          : "Hide this account from UsageBar")
                }
            }
            if confirmingDelete {
                Text(isClaude
                     ? "Removes this account's Keychain entries — including any sibling install signed in to the same account.  You'll need to run `claude auth login` to use them again."
                     : "Hides this account from UsageBar.  The underlying sign-in in the source app is untouched.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 26)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let email = store.accountLabel(for: provider.id),
               store.customLabel(for: provider.id) != nil {
                Text(email)
                    .font(.caption2).foregroundStyle(.secondary)
                    .padding(.leading, 26)
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
            .padding(.leading, 26)
        }
        .padding(.vertical, 3)
    }

    private var nicknamePlaceholder: String {
        if let email = store.accountLabel(for: provider.id) {
            return email
        }
        return "e.g. Work"
    }

}

/// The new flat providers list — connected accounts + a single
/// "Add Provider" entry point.  No kind grouping, no enable/disable
/// checkboxes — being in the list IS being enabled.
private struct ProvidersFlatList: View {
    @EnvironmentObject var store: UsageStore
    @State private var expandAdd = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            let connected = store.connectedProviders
            if connected.isEmpty {
                Text("No providers connected yet.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(connected, id: \.id) { p in
                    AccountRow(provider: p)
                }
            }
            AddProviderPanel(expanded: $expandAdd)
        }
    }
}
