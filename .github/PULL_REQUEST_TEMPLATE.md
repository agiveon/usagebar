## What this changes

<!-- One or two sentences. -->

## Why

<!-- Link an issue if there is one. -->

## Provider changes (delete if N/A)

- [ ] Endpoint and response schema cross-checked against a working
      open-source reference (linked in the file header).
- [ ] Auth material is read fresh per poll and never written to disk.
- [ ] Parser is defensive (missing/renamed fields don't crash).

## Test plan

- [ ] `./build.sh release` succeeds.
- [ ] `open .build/UsageBar.app` — the affected provider shows the right
      windows / colors / reset countdowns.
- [ ] No regressions in the other providers (menu bar glyph, popover,
      Settings toggles).
