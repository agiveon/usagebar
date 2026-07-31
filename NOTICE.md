# Third-party attribution

## Endpoints & response schemas

UsageBar talks to undocumented usage endpoints. Rather than guess at the
shapes, we cross-checked each one against a working open-source
implementation:

- **Claude Code** — endpoint (`api.anthropic.com/api/oauth/usage`),
  headers (`anthropic-beta: oauth-2025-04-20`, `Authorization: Bearer`),
  and response schema (per-model `{utilization, resets_at}` entries)
  confirmed against
  [jens-duttke/usage-monitor-for-claude](https://github.com/jens-duttke/usage-monitor-for-claude)
  (`usage_monitor_for_claude/api.py`, `docs/api-reference.md`).

- **Codex / ChatGPT** — endpoint (`chatgpt.com/backend-api/wham/usage`),
  `ChatGPT-Account-Id` header requirement, and response schema
  (`RateLimitStatusPayload` with `primary_window` / `secondary_window`)
  taken directly from
  [openai/codex](https://github.com/openai/codex)
  (`codex-rs/backend-client/src/client/rate_limit_resets.rs`,
  `codex-rs/codex-backend-openapi-models/src/models/rate_limit_status_details.rs`).
  Window-length labelling matches
  `codex-rs/tui/src/chatwidget/rate_limits.rs::get_limits_duration`.

- **Cursor** — the "read `cursorAuth/accessToken` from `state.vscdb`,
  decode the JWT's `sub` for the user id, send it as
  `WorkosCursorSessionToken=<userId>::<jwt>`" recipe comes from
  [raycast/extensions](https://github.com/raycast/extensions)
  (`extensions/agent-usage/src/cursor/auth.ts`). Response schema
  (`individualUsage.plan.{auto,api,total}PercentUsed`, `onDemand`,
  `billingCycleEnd`) verified against
  [vokal-pe/cursor-usage-menubar](https://github.com/vokal-pe/cursor-usage-menubar)
  (`app.py::parse_data`).

- **GitHub Copilot** — endpoint (`api.github.com/copilot_internal/user`)
  and `quota_snapshots.<category>.percent_remaining` shape taken from
  [cjdcordeiro/copilot-usage-tray-icon](https://github.com/cjdcordeiro/copilot-usage-tray-icon)
  (`copilot-tray.py::_extract_percent_remaining`).

Every one of these was consulted only for endpoint URLs, auth mechanics,
and response fields — no code was copied.

## Brand marks

The SVG files under
[`Sources/UsageBar/Resources/Icons/`](Sources/UsageBar/Resources/Icons)
are the corresponding services' brand marks, used solely to identify the
service in the UI (nominative fair use). All marks are trademarks of their
respective owners:

- `claude.svg` — Claude, Anthropic PBC. Sourced from
  [simple-icons](https://simpleicons.org).
- `openai.svg` — OpenAI, OpenAI, L.L.C. Sourced from
  [iconify.design](https://iconify.design)'s simple-icons collection.
- `cursor.svg` — Cursor, Anysphere Inc. Sourced from
  [simple-icons](https://simpleicons.org).
- `githubcopilot.svg` — GitHub Copilot, GitHub, Inc. / Microsoft.
  Sourced from [simple-icons](https://simpleicons.org).

The [simple-icons](https://github.com/simple-icons/simple-icons) project
itself is CC0-licensed; the marks it distributes remain the property of
their trademark holders.

If you own one of these marks and would prefer we not use it, open an
issue and we'll swap in a neutral glyph.

## Runtime dependencies

None beyond the macOS SDK (Foundation, AppKit, SwiftUI, CommonCrypto,
SQLite3). No third-party Swift packages.
