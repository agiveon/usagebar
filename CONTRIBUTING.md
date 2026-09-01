# Contributing

Thanks for looking — small, focused patches are very welcome.

## Dev setup

```bash
git clone https://github.com/agiveon/usagebar.git
cd usagebar
swift build          # incremental dev build
./build.sh debug     # assemble .build/UsageBar.app
open .build/UsageBar.app
```

Requirements: macOS 13+, Xcode Command Line Tools with Swift 5.9+. No
third-party packages, no Xcode project — everything is SwiftPM.

## Project layout

```
Sources/UsageBar/
  UsageBarApp.swift          — @main, MenuBarExtra scene
  Models/                    — UsageWindow, UsageSnapshot, ProviderStatus
  Providers/                 — UsageProvider protocol + one file per service
  Store/UsageStore.swift     — @MainActor store, polling, prefs
  Support/                   — SQLite / Keychain / SVG helpers
  Resources/Icons/*.svg      — bundled brand marks
  UI/                        — MenuBarLabel + PopoverView (main + settings)
```

## Adding a new provider

Every provider is one file. Copy an existing one
(e.g. [`CopilotProvider.swift`](Sources/UsageBar/Providers/CopilotProvider.swift))
and edit:

1. Confirm the endpoint against a working open-source reference — **don't
   guess**. Note the reference in the file header.
2. Implement `UsageProvider`:
   - `id`, `displayName`, `iconName` (SF Symbol), optionally `iconAsset`
     (bundled SVG base name).
   - `signInAction` — one of `.runCommand`, `.openApp`, `.openURL`.
   - `isAvailable() async -> Bool` — a cheap check (does the file/DB/
     keychain item exist?).
   - `fetchSnapshot() async throws -> UsageSnapshot` — one HTTP request,
     mapped to `UsageWindow`s.
3. If auth requires reading a Chromium cookie DB or a VS Code-style
   `state.vscdb`, reuse the helpers under `Support/`.
4. Register it in
   [`ProviderRegistry.default`](Sources/UsageBar/Providers/ProviderRegistry.swift).
5. Add a `notAvailableHint` case in `UsageStore.notAvailableHint(for:)`.

That's it — the Settings toggles, popover row, menu-bar picker, and
sign-in button all pick it up automatically.

### Rules of thumb

- **Never** ask the user for an API key or password inside the app.
  Reuse an existing local sign-in or open the service's own sign-in flow.
- Connect must create the credential this provider reads, and every
  window must be a real number from the API. If either isn't true,
  don't ship the provider.
- Treat every field in the response as optional and parse defensively —
  these endpoints are undocumented and change without notice.
- Any blocking I/O (SQLite, shell-outs, file reads) must be safe to run
  off the main actor; `UsageStore.fetch` already does this via
  `Task.detached`.
- Shell subprocesses (`security`, etc.) must use
  [`ShellRunner`](Sources/UsageBar/Support/ShellRunner.swift) with a
  hard timeout — never `waitUntilExit()` without one.

## Style

- Small files (< 200 lines) grouped by role.
- Comments explain the *why* (undocumented endpoint quirks, workarounds
  for AppKit oddities). No comments that just restate the code.
- No new third-party packages without discussion.

## Reporting bugs

Use the issue template. Include your macOS version, which provider is
misbehaving, and the exact text the popover shows for that provider.

## Security

Security issues go to **agiveon@gmail.com**, not the issue tracker. See
[SECURITY.md](SECURITY.md).
