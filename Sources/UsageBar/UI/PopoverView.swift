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

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 3) {
                ProviderIcon(provider: provider, color: tabColor, size: 18)
                Text(provider.shortName)
                    .font(.caption2)
                    .lineLimit(1)
                    .foregroundStyle(isSelected ? .primary : .secondary)
                // Small dot marks the provider currently in the menu bar.
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
        .help(provider.displayName + (isMenuBar ? " · in menu bar" : ""))
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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(provider.displayName)
                    .font(.system(.body).weight(.semibold))
                if isActive {
                    Text("· in menu bar")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if !isActive, case .some(.available) = status {
                    Button("Show in menu bar") { store.setActive(provider.id) }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
            }

            switch status {
            case .some(.available(let snap)):
                if snap.windows.isEmpty {
                    Text("no active windows")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(snap.windows) { w in
                        WindowBar(window: w,
                                  isMenuBarMetric: isActive
                                    && store.menuBarWindowID == w.id)
                    }
                }
                if snap.isStale {
                    Text("stale data")
                        .font(.caption2).foregroundStyle(.secondary)
                }

            case .some(.notAvailable(let reason)):
                VStack(alignment: .leading, spacing: 6) {
                    Text(reason).font(.caption).foregroundStyle(.secondary)
                    Text(provider.signInAction.hint)
                        .font(.caption2).foregroundStyle(.secondary)
                    Button(provider.signInAction.buttonLabel) {
                        store.signIn(providerID: provider.id)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }

            case .some(.error(let msg)):
                Text(msg).font(.caption).foregroundStyle(.red)

            case .none:
                Text("loading…").font(.caption).foregroundStyle(.secondary)
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

                // Providers, grouped by kind -----------------------------
                Text("Providers").font(.subheadline).foregroundStyle(.secondary)
                ProvidersSection()

                Divider()

                // Menu bar display --------------------------------------
                Text("Menu bar display")
                    .font(.subheadline).foregroundStyle(.secondary)

                Picker("Provider", selection: providerBinding) {
                    ForEach(store.enabledProviders, id: \.id) { p in
                        Text(p.displayName).tag(p.id)
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
                Slider(value: $store.refreshInterval, in: 30...300, step: 15)
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
        store.registry.providers.filter {
            $0.id == prefix || $0.id.hasPrefix("\(prefix):")
        }
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
                    Toggle(p.displayName, isOn: store.enabledBinding(p.id))
                        .toggleStyle(.checkbox)
                }
            }

            if let addHint {
                Text(addHint)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.top, 2)
            }
        }
    }

    private var addHint: String? {
        switch kind {
        case .claude:
            return "Second account? Run  CLAUDE_CONFIG_DIR=~/.claude-work claude  in Terminal, sign in, then hit refresh."
        case .codex:
            return "Second account? Run  CODEX_HOME=~/.codex-work codex login  in Terminal, sign in, then hit refresh."
        case .none:
            return nil
        }
    }
}
