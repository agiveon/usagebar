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
        .frame(width: 340)
    }
}

// MARK: - Main list

private struct MainView: View {
    @EnvironmentObject var store: UsageStore
    let openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()

            let enabled = store.enabledProviders
            if enabled.isEmpty {
                Text("No providers enabled. Open settings to turn one on.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(enabled, id: \.id) { provider in
                    ProviderRow(provider: provider,
                                status: store.statuses[provider.id],
                                isActive: store.activeProviderID == provider.id,
                                onSelect: { store.setActive(provider.id) })
                    if provider.id != enabled.last?.id {
                        Divider().opacity(0.4)
                    }
                }
            }

            Divider()
            footer
        }
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

private struct ProviderRow: View {
    @EnvironmentObject var store: UsageStore
    let provider: UsageProvider
    let status: ProviderStatus?
    let isActive: Bool
    let onSelect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                ProviderIcon(provider: provider, color: dotColor, size: 16)
                Text(provider.displayName)
                    .font(.system(.body).weight(isActive ? .semibold : .regular))
                if isActive {
                    Text("· in menu bar")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !isActive {
                    Button("Show in menu bar", action: onSelect)
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
            }

            switch status {
            case .some(.available(let snap)):
                ForEach(snap.windows) { w in
                    WindowBar(window: w,
                              isMenuBarMetric: isActive
                                && store.menuBarWindowID == w.id)
                }
                if snap.isStale {
                    Text("stale data")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            case .some(.notAvailable(let reason)):
                VStack(alignment: .leading, spacing: 4) {
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

    private var dotColor: Color {
        if case .some(.available(let snap)) = status, !snap.isStale {
            return Thresholds.color(for: snap.worstPercent)
        }
        return .secondary
    }
}

// Renders a provider's bundled brand SVG (tinted), falling back to its SF Symbol.
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

            // Providers -------------------------------------------------
            Text("Providers")
                .font(.subheadline).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(store.registry.providers, id: \.id) { p in
                    Toggle(p.displayName, isOn: store.enabledBinding(p.id))
                        .toggleStyle(.checkbox)
                }
            }

            Divider()

            // Menu bar display -----------------------------------------
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

            // Refresh --------------------------------------------------
            Text("Refresh interval: \(Int(store.refreshInterval))s")
                .font(.subheadline).foregroundStyle(.secondary)
            Slider(value: $store.refreshInterval, in: 30...300, step: 15)
        }
    }

    private var providerBinding: Binding<String> {
        Binding(
            get: { store.activeProviderID },
            set: { store.setActive($0) }
        )
    }
}
