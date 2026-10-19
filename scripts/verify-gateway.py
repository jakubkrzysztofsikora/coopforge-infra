#!/usr/bin/env python3
"""Validate manifest/gateway.yaml per_tier_budgets against lib/coop-rules.ts.

    scripts/verify-gateway.py
    GATEWAY=manifest/gateway.yaml scripts/verify-gateway.py

Every per_tier_budgets key must be a tier id in manifest/tiers.json, and its
tpm/parallelism must match that tier's tpm_cap_per_member/concurrency_per_member.
"""
import json
import os
import pathlib
import subprocess
import sys

import yaml

ROOT = pathlib.Path(__file__).resolve().parent.parent
GATEWAY = pathlib.Path(os.environ.get("GATEWAY", ROOT / "manifest" / "gateway.yaml"))

failures = []
checks = 0


def check(ok, label):
    global checks
    checks += 1
    if ok:
        print(f"ok   {label}")
    else:
        print(f"FAIL {label}")
        failures.append(label)


gateway = yaml.safe_load(GATEWAY.read_text())
budgets = gateway.get("per_tier_budgets") or {}
tiers = json.loads((ROOT / "manifest" / "tiers.json").read_text())

check(bool(budgets), f"{GATEWAY.name} parses and has per_tier_budgets")
check(
    set(budgets) == set(tiers),
    f"per_tier_budgets keys match tiers.json ({len(budgets)}/{len(tiers)})",
)
check(
    set(budgets) == set(tiers),
    f"keys: {', '.join(sorted(budgets))}",
)

for tier in tiers:
    entry = budgets.get(tier)
    if entry is None:
        check(False, f"{tier}: missing from per_tier_budgets")
        continue
    facts = json.loads(
        subprocess.run(
            [
                "node",
                "--experimental-strip-types",
                "--no-warnings",
                str(ROOT / "scripts" / "tier-facts.mjs"),
                tier,
            ],
            capture_output=True,
            text=True,
            check=True,
        ).stdout
    )
    check(
        entry.get("tpm") == facts["tpm_cap_per_member"],
        f"{tier}: tpm {entry.get('tpm')} == tpm_cap_per_member {facts['tpm_cap_per_member']}",
    )
    check(
        entry.get("parallelism") == facts["concurrency_per_member"],
        f"{tier}: parallelism {entry.get('parallelism')} == concurrency_per_member {facts['concurrency_per_member']}",
    )
    check(
        isinstance(entry.get("rpm"), int) and entry["rpm"] > 0,
        f"{tier}: rpm {entry.get('rpm')}",
    )
    check(
        isinstance(entry.get("burst"), (int, float)) and entry["burst"] > 0,
        f"{tier}: burst {entry.get('burst')}",
    )

print(f"\n{checks - len(failures)}/{checks} checks passed")
if failures:
    print(f"{len(failures)} FAILED")
    sys.exit(1)
