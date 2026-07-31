# PLAN.md — QuotaBar (working title)

A native macOS menu bar app that shows, at a glance, how much of your AI coding
quota you've burned — with a traffic-light indicator (green / yellow / red) and
the ability to switch between supported providers.

> **Rename freely.** "QuotaBar" is a placeholder. Pick a final name before first
> release (avoid existing ones: Usagebar, CodexBar, cclimit, SessionWatcher).

---

## 1. Goal

Ship a lightweight, native macOS menu bar app that:

1. Polls usage/rate-limit data for **two providers to start** — **Claude Code**
   (Anthropic Pro/Max) and **Codex** (included with ChatGPT plans).
2. Renders a single **traffic-light status glyph** in the menu bar reflecting the
   *worst* current usage window for the **active** provider.
3. Lets the user **switch which provider is active** (and see all supported
   providers' status in the popover).
4. Is architected around a **provider abstraction** so a third/fourth provider is
   a small, additive change — not a rewrite.

The app should feel like a native macOS utility: no dock icon, tiny footprint,
no login screen of its own, no telemetry.

---

## 2. Scope

### In scope (v1)
- Two providers: Claude Code and Codex.
- Menu bar glyph with color state + optional percentage label.
- Popover listing all supported providers, each with session/weekly meters and
  reset countdowns; tap one to make it the active (displayed) provider.
- Periodic background refresh (default 60s), with a manual "Refresh now" action.
- Graceful states: not-logged-in, network error, stale data.
- Persisted preferences (active provider, thresholds, refresh interval).

### Non-goals (v1 — keep these out to stay small)
- Historical charts / analytics / dollar-cost breakdowns.
- Teams / multi-account switching.
- Windows or Linux builds.
- Plain ChatGPT *chat* usage (see §4 — no clean feed exists; Codex is the analog).
- Notifications (nice-to-have; deferred to a later milestone, see §8 M5).

---

## 3. Tech stack

- **Language/UI:** Swift + SwiftUI, using `MenuBarExtra` (macOS 13 Ventura+).
- **Distribution:** single `.app`, Apple Silicon + Intel. `LSUIElement = true`
  (agent / no dock icon).
- **No third-party runtime deps** beyond what's needed for HTTP + JSON (Foundation
  `URLSession` + `Codable` is enough).
- **Persistence:** `UserDefaults` for prefs; nothing sensitive is ever written to
  disk by us (tokens stay in memory, read fresh each poll — see §4).

> Prototype note: a `rumps`/Python version is faster to spike but not the
> deliverable. Build the real thing in Swift.

---

## 4. Background & data sources (read this before coding)

There is **no documented public API** for consumer subscription usage. The
percentages you see in the CLIs' `/usage` (Claude Code) and `/status` (Codex)
panels come from **undocumented endpoints** that the official CLIs call after they
authenticate you. Our app **reuses the CLI's existing login** — we do **not** ask
the user for an API key, and we do **not** scrape web pages or harvest browser
cookies.

### Claude Code provider
- Auth: read the OAuth token that **Claude Code stores in the macOS Keychain**.
- Fetch: call the same usage endpoint on `api.anthropic.com` that Claude Code's
  `/usage` command hits, with that token.
- Response gives session (5-hour rolling) usage, weekly usage, and **per-model**
  windows (e.g. "All models", "Fable"). Parse the limits feed **generically** —
  model-specific windows come and go, so new caps should just appear rather than
  requiring a code change.
- **The exact endpoint path and JSON shape are undocumented — confirm them from
  a working open-source reference (see §10), do not hardcode from memory.**

### Codex provider
- Auth: read the Codex CLI sign-in at `~/.codex/auth.json`.
- Fetch: call OpenAI's usage endpoint that Codex itself uses (session = 5-hour
  rolling window, plus a weekly limit).
- Same rule: **confirm endpoint + schema against an open-source reference.**

### Cross-cutting constraints
- Both providers only work **on a machine where the user is logged into that CLI**.
  If a CLI login is absent, the provider reports `.notAvailable` (see §6) and the
  UI offers a hint (e.g. "Run `codex login`").
- Treat these endpoints as unstable: wrap parsing defensively, tolerate new/renamed
  fields, and surface a "stale data" flag rather than crashing when a poll fails.
- **Privacy is a feature.** Tokens read → used → discarded, never cached or copied.
  No analytics, no accounts, no third-party backend. Request the minimum macOS
  permissions needed (Keychain read; file read for `~/.codex/auth.json`). Avoid
  Full Disk Access if at all possible.

---

## 5. Data model

```
UsageWindow
  id            // "session" | "weekly" | model id e.g. "fable"
  label         // human label, e.g. "Current session", "Weekly · Fable"
  percentUsed   // 0.0 ... 1.0+
  resetsAt      // Date?  (nil if unknown)

UsageSnapshot
  provider      // provider id
  windows       // [UsageWindow]
  fetchedAt     // Date
  isStale       // Bool  (last fetch failed / older than N minutes)
  worstPercent  // computed: max(percentUsed) across windows -> drives the color

ProviderStatus
  .available(UsageSnapshot)
  .notAvailable(reason)   // e.g. not logged in
  .error(message)
```

`worstPercent` is the single number that drives the menu bar color for a provider.

---

## 6. Provider abstraction (the core design)

Define one protocol; each provider is one conforming type. Adding a provider =
add a file + register it. This is what makes "switch between supported ones" and
"add more later" cheap.

```swift
protocol UsageProvider {
    var id: String { get }            // "claude-code", "codex"
    var displayName: String { get }   // "Claude Code", "Codex"
    var iconName: String { get }      // SF Symbol or bundled asset

    /// Cheap check: is the underlying CLI logged in on this machine?
    func isAvailable() async -> Bool

    /// Fetch current usage. Throws -> mapped to ProviderStatus.error.
    func fetchSnapshot() async throws -> UsageSnapshot
}
```

- A `ProviderRegistry` holds the ordered list of all supported providers.
- A `UsageStore` (ObservableObject) polls each **registered & available** provider
  on the refresh timer and publishes `[providerID: ProviderStatus]`.
- The **active provider** (what the menu bar glyph reflects) is a persisted user
  choice; default to the first available one.

---

## 7. Menu bar UI & behavior

### Traffic-light glyph (menu bar)
- Show a colored indicator for the **active provider**, colored by its
  `worstPercent`:
  - **Green:** `< 0.70`
  - **Yellow:** `0.70 – 0.90`
  - **Red:** `> 0.90`
  - **Grey / hollow:** provider not available or data stale.
- Thresholds are constants in one place and **user-configurable** later.
- Default glyph: a filled SF Symbol circle (e.g. `circle.fill`) tinted by state,
  optionally a ring/gauge style. Keep it legible in both light and dark menu bars.
- **Optional numeric label** next to the glyph (e.g. `68%`), toggleable in prefs.
  Default: show the number for the active provider.
- Consider a small provider glyph so the user can tell *which* provider is active
  when more than one is supported.

### Popover (on click)
- Header: active provider name + "last updated Xs ago" + manual refresh button.
- For **each supported provider**, a row showing:
  - provider name + its own mini traffic-light dot,
  - each `UsageWindow` as a labeled progress bar with `percentUsed` and a
    reset countdown ("resets in 4h 56m"),
  - a not-logged-in hint if `.notAvailable`.
- **Switching:** tapping a provider row (or a segmented control at top) sets it as
  the active provider; the menu bar glyph updates immediately and the choice
  persists.
- Footer: "Refresh interval", "Preferences…", "Quit".

### Refresh
- Timer-driven poll, default every 60s, configurable (min 30s to be polite to the
  endpoints). Poll only available providers. Debounce manual refreshes.
- On failure: keep last good snapshot, mark `isStale = true`, flip glyph to the
  grey/hollow state after a threshold (e.g. 2 consecutive failures).

---

## 8. Milestones

**M0 — Scaffold.** SwiftUI `MenuBarExtra` app, `LSUIElement`, static glyph, quits
cleanly. No data yet.

**M1 — Provider protocol + Claude Code.** Implement `UsageProvider`,
`UsageSnapshot`, registry, and the Claude Code provider (Keychain token → fetch →
parse windows). Print snapshots to console; verify against the real `/usage` panel.

**M2 — Live traffic-light.** Wire the Claude snapshot to the menu bar glyph +
color logic + refresh timer + stale handling. Popover shows Claude's windows with
progress bars and reset countdowns.

**M3 — Codex provider.** Add the Codex provider (`~/.codex/auth.json` → fetch →
parse). It appears in the registry/popover with no other code changes — this
validates the abstraction.

**M4 — Provider switching.** Active-provider selection UI + persistence; glyph
reflects the active provider; per-provider status rows in the popover.

**M5 — Polish (optional/deferred).** Preferences window (thresholds, interval,
show-number toggle, launch-at-login), threshold notifications (e.g. at 75% / 90%),
app icon, signing/notarization for distribution.

---

## 9. Acceptance criteria (v1 done)

- With Claude Code and/or Codex logged in, the menu bar shows a correctly colored
  glyph whose percentage matches each CLI's own `/usage` / `/status` within a
  poll cycle.
- The color follows the green/yellow/red thresholds off the *worst* window.
- The user can switch the active provider and the glyph updates + the choice
  survives a relaunch.
- A provider that isn't logged in shows a clear "not available" state, not a crash
  or a fake 0%.
- Killing network connectivity yields a stale/grey state, and recovery restores
  live data automatically.
- No dock icon; no tokens written to disk; no network calls except to the two
  provider endpoints.

---

## 10. References (crib the exact endpoints/parsing from these)

These are working open-source implementations. Read their source for the precise
endpoint paths, auth handling, and response schemas rather than guessing:

- **cclimit** — Swift/SwiftUI Claude Code monitor; reads the Keychain OAuth token
  and calls the same `api.anthropic.com` usage endpoint. Good Claude-side model.
  https://cclimit.app/
- **CodexBar Lite** — minimal open-source Codex monitor; reads `~/.codex/auth.json`
  and calls OpenAI's own usage endpoint. Good Codex-side model.
  https://getcodexbar.xyz/
- **claude-monitor (rjwalters)** — macOS menu bar widget, multi-account, session/
  weekly %; useful for the "same internal endpoints via OAuth" pattern.
  https://github.com/rjwalters/claude-monitor
- **usage-monitor-for-claude (jens-duttke)** — auth-through-existing-login pattern,
  generic quota parsing (Session/Weekly/per-model) worth copying.
  https://github.com/jens-duttke/usage-monitor-for-claude
- **openai/codex #15281** — context on Codex's hidden 5-hour + weekly limits.
  https://github.com/openai/codex/issues/15281

---

## 11. Open decisions (confirm with the owner)

1. **Glyph style:** plain colored dot vs. ring/gauge vs. dot + number. Default
   assumed: colored dot **+** number for the active provider.
2. **Active vs. aggregate:** v1 shows one active provider in the bar. Do we also
   want an "All" mode that colors by the worst across *all* providers? (Deferred.)
3. **Thresholds:** 70 / 90 assumed. Adjust?
4. **Refresh interval floor:** 30s assumed as the minimum to avoid hammering the
   undocumented endpoints. OK?
5. **Provider set:** starting with Claude Code + Codex. Confirm these are the two
   "basic ones" (vs., say, Cursor or Copilot).
