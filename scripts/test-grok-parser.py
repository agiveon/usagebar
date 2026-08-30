#!/usr/bin/env python3
"""Mirrors GrokCredits so we can lock the 0..100 percent scale.

creditUsagePercent 1.0 on the wire is 1% used, not 100%.
"""
import json
import sys
from pathlib import Path

root = Path(__file__).resolve().parents[1]
fixture = json.loads((root / "Tests/fixtures/grok-billing-credits.json").read_text())
config = fixture["config"]


def percent(n):
    return max(0.0, min(1.0, float(n) / 100.0))


weekly = percent(config["creditUsagePercent"])
assert abs(weekly - 0.01) < 1e-9, f"weekly percentUsed expected 0.01, got {weekly}"
assert config["currentPeriod"]["type"] == "USAGE_PERIOD_TYPE_WEEKLY"
assert config["currentPeriod"]["end"].startswith("2026-09-04")

products = [
    p for p in config["productUsage"] if "usagePercent" in p
]
assert [p["product"] for p in products] == ["GrokChat"]
assert abs(percent(products[0]["usagePercent"]) - 0.01) < 1e-9

assert config["prepaidBalance"]["val"] == 0

# Source contracts — Add Provider must list these titles.
store = (root / "Sources/UsageBar/Store/UsageStore.swift").read_text()
for title in ('title: "Grok API"', 'title: "SuperGrok"'):
    assert title in store, f"missing {title} in addableKinds"

popover = (root / "Sources/UsageBar/UI/PopoverView.swift").read_text()
assert "ForEach(store.addableKinds)" in popover
assert "kind.title" in popover
assert 'Text("Grok API")' not in popover.split("AddProviderPanel")[0]  # listed via kinds

registry = (root / "Sources/UsageBar/Providers/ProviderRegistry.swift").read_text()
assert "SuperGrokProvider()" in registry
assert "GrokAPIProvider()" in registry

add = store.split("func addProvider")[1].split("func removeProvider")[0]
assert "SignInLauncher.perform(p.signInAction)" in add
assert "GrokCLILogin" not in add
assert 'kindID == "supergrok"' not in add
assert 'kindID == "grok-api"' not in add

usage = (root / "Sources/UsageBar/Providers/UsageProvider.swift").read_text()
assert "spawnCommand" in usage
super_p = (root / "Sources/UsageBar/Providers/SuperGrokProvider.swift").read_text()
assert "spawnCommand" in super_p
assert "runCommand" not in super_p

print("ok")
sys.exit(0)
