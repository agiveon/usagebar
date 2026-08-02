# Security policy

## Threat model

UsageBar reads locally-stored auth material (OAuth tokens, JWTs, OS
Keychain entries) belonging to services you're already signed into, sends
them straight to those services' own API hosts over HTTPS, and drops them.
It never persists tokens itself. Anything that violates this contract is
in scope.

## Reporting a vulnerability

Please **do not open a public issue** for security concerns.

Instead, email **agiveon@gmail.com** with:

- What you found and where in the code (file:line if possible)
- A minimal reproduction or a description of the impact
- Any suggested fix, if you have one

We'll acknowledge within a few days and coordinate a fix + disclosure
timeline with you.

## Out of scope

- Anything that requires already having local access to a user's machine
  as the same user (at that point, the tokens are readable anyway — see
  the threat model above).
- Bugs in the upstream services' own auth mechanisms (report to them).
- Feature requests dressed up as security reports.

## Auth material handled

For transparency, here's every file / keychain item / DB UsageBar reads,
and what it does with the contents:

| Source | Read every | Kept in memory | Written anywhere |
|---|---|---|---|
| Keychain items `Claude Code-credentials*` (via `security find-generic-password`) — one per Claude account | poll (default 120 s, floor 60 s) | duration of one HTTP request | never |
| `~/.codex/auth.json` | poll | duration of one HTTP request | never |
| `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb` (copied read-only, WAL-immutable) | poll | duration of one HTTP request | never |
| `~/.config/github-copilot/apps.json` / `hosts.json` | poll | duration of one HTTP request | never |

Discovery is attribute-only (via `SecItemCopyMatching` without
`kSecReturnData`) and filters out Keychain items whose `acct` attribute
isn't a plausible user identifier — so unrelated Apple items that happen
to share the `Claude Code-credentials` prefix (Handoff keys, etc.) are
never treated as accounts.

The **only** thing UsageBar caches across polls is the account email
returned by the profile endpoint (kept in-memory for up to 30 min per
account to halve request load). No tokens are ever cached.

Preferences stored under `com.magicmirrorsecurity.usagebar` in
`UserDefaults` are non-sensitive: which providers are enabled, refresh
interval, which window drives the menu bar glyph.

## Network destinations

Exactly four hosts, all over HTTPS:

- `api.anthropic.com`
- `chatgpt.com` (specifically `/backend-api/wham/usage`)
- `cursor.com`
- `api.github.com`

Anything else is a bug — please report it.
