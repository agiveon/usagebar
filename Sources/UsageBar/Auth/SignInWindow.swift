import SwiftUI
import AppKit

// Hosts the ClaudeAuthSession in a proper window.  We can't use an embedded
// WKWebView for the sign-in because Google (and increasingly others) refuse
// OAuth from any non-system browser.  So we hand the OAuth URL to the user's
// real browser and ask them to paste back the callback (full URL or just
// the code — either works).
//
// The window uses `.floating` level and stays visible on every Space so it
// can't get buried behind the browser mid-sign-in — the #1 problem in our
// first pass was users finishing OAuth and never finding the paste field.
@MainActor
final class SignInWindowController {

    private var window: NSWindow?
    private var session: ClaudeAuthSession?
    private let onFinished: () -> Void

    init(onFinished: @escaping () -> Void) {
        self.onFinished = onFinished
    }

    var isPresenting: Bool { window != nil }

    func present() {
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let session = ClaudeAuthSession()
        self.session = session

        let view = SignInView(
            session: session,
            onCancel: { [weak self] in self?.close() },
            onDone:   { [weak self] in self?.close() }
        )

        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "Sign in to Claude Code"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 480, height: 360))
        window.center()
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        // Float above the browser so it stays reachable while the user is
        // signing in, and follow the user across Spaces.
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.window = window

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        session.start()
    }

    /// Bring the window back to focus (used from the popover's "sign-in in
    /// progress" indicator when the user has clicked away).
    func bringToFront() {
        guard let window else { return }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func close() {
        session?.cancel()
        session = nil
        window?.close()
        window = nil
        onFinished()
    }
}

// MARK: - The view

private struct SignInView: View {
    @ObservedObject var session: ClaudeAuthSession
    let onCancel: () -> Void
    let onDone: () -> Void

    @State private var pastedInput = ""
    @State private var browserOpenedForURL: URL?
    @State private var localError: String?
    @FocusState private var pasteFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
                .padding(18)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            Divider()
            footer.padding(12)
        }
        .frame(minWidth: 460, minHeight: 340)
        .onChange(of: session.state) { newState in
            if case .waitingForBrowser(let url) = newState,
               browserOpenedForURL != url {
                NSWorkspace.shared.open(url)
                browserOpenedForURL = url
                // Focus the paste field the moment we're ready for it.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    pasteFieldFocused = true
                }
            }
            if case .done = newState {
                Task {
                    try? await Task.sleep(nanoseconds: 700_000_000)
                    onDone()
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch session.state {
        case .starting:
            spinnerState("Opening sign-in…")

        case .waitingForBrowser(let url):
            pasteState(url: url)

        case .finalizing:
            spinnerState("Finishing sign-in…")

        case .done:
            successState

        case .failed(let reason):
            failureState(reason)
        }
    }

    // MARK: - The main "paste" state

    private func pasteState(url: URL) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Paste the code from your browser")
                .font(.title3.weight(.semibold))

            TextField("code or full callback URL", text: $pastedInput)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 15, design: .monospaced))
                .focused($pasteFieldFocused)
                .onSubmit(submit)

            HStack {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Label("Reopen sign-in page", systemImage: "safari")
                }
                .buttonStyle(.borderless)
                Spacer()
                Button("Continue", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(extractCode(from: pastedInput) == nil)
            }

            if let localError {
                Text(localError).font(.caption).foregroundStyle(.red)
            }

            Divider().padding(.vertical, 2)

            Text("A sign-in page opened in your browser. Sign in with the other Anthropic account, then copy either the code shown after sign-in or the whole URL from your browser's address bar and paste it above.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Other states

    private func spinnerState(_ text: String) -> some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(text).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var successState: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 46))
                .foregroundStyle(.green)
            Text("Signed in! Adding to UsageBar…")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func failureState(_ reason: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 38))
                .foregroundStyle(.orange)
            Text("Couldn't complete sign-in").font(.headline)
            Text(reason)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Spacer()
            Button(closeLabel) { onCancel() }
                .keyboardShortcut(.cancelAction)
        }
    }

    private var closeLabel: String {
        if case .done = session.state { return "Close" }
        return "Cancel"
    }

    // MARK: - Submit

    private func submit() {
        guard let code = extractCode(from: pastedInput) else {
            localError = "That doesn't look like the code or the callback URL — try again."
            return
        }
        localError = nil
        session.provideCode(code)
    }

    /// Accept either the raw code (`abc123`) or the full callback URL
    /// (`https://platform.claude.com/oauth/code/callback?code=abc123&state=…`).
    private func extractCode(from raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.lowercased().hasPrefix("http"),
           let comps = URLComponents(string: trimmed),
           let code = comps.queryItems?.first(where: { $0.name == "code" })?.value,
           !code.isEmpty {
            return code
        }
        return trimmed.contains(where: { $0.isWhitespace }) ? nil : trimmed
    }
}
