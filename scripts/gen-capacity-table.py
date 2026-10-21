#!/usr/bin/env python3
"""Generate content/capacity-sim.json for the landing page.

Runs the coop-sim discrete-event simulator for every public tier at its
recommended seat count, three duty cycles and two mean contexts, with a fixed
seed, and emits one committed JSON file so the web build needs no Python.

The duty cycle is the one input no research could supply; it must be measured
from real members. Everything else traces to tier hardware constants.
"""

from __future__ import annotations

import argparse
import json
import random
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

import importlib.util  # noqa: E402

_spec = importlib.util.spec_from_file_location(
    "coop_sim", Path(__file__).parent / "coop-sim.py"
)
coop_sim = importlib.util.module_from_spec(_spec)
sys.modules["coop_sim"] = coop_sim
_spec.loader.exec_module(coop_sim)

# (kv_gb, kv_per_token_bytes, service_s) per tier, extended from coop_sim.CONFIGS
# with the deepseek entry: 8x H100 640GB, 511GB MXFP4 weights, MLA cache
# 61 layers x (512 latent + 64 rope) x 1 byte fp8 = 35136 B/token, same ~0.87
# usable-KV fraction as the sibling tiers.
DEEPSEEK = (112.0, 35136)

SEATS = {**{t: c[2] for t, c in coop_sim.CONFIGS.items()}, "deepseek-v4-flash": 150}

TIER_CONFIGS = {
    **{t: (c[0], c[1], c[3]) for t, c in coop_sim.CONFIGS.items()},
    "deepseek-v4-flash": (*DEEPSEEK, 25.0),
}

PUBLIC_TIERS = [
    "everyday-fr-l40s",
    "pro-fr-2x-l40s",
    "power-h100",
    "studio-4x-h100",
    "deepseek-v4-flash",
    "seed-24g",
    "everyday-96g",
]

DUTIES = (0.15, 0.40, 0.60)
CONTEXTS = (8192, 32768)
SEED = 7
DURATION_H = 8.0
IDLE_CAP_S = 3600.0


def slots_for(capacity_tokens: int, mean_ctx: int) -> int:
    return max(1, capacity_tokens // mean_ctx)


def verdict(p95: float) -> str:
    if p95 > 5.0:
        return "p95 wait exceeds the 5s impatience tipping point"
    if p95 > 1.0:
        return "p95 wait breaks flow (>1s)"
    return "healthy"


def run() -> dict:
    out: dict = {"seed": SEED, "duties": list(DUTIES), "contexts": list(CONTEXTS), "tiers": {}}
    for tier in PUBLIC_TIERS:
        kv_gb, per_tok, service_s = TIER_CONFIGS[tier]
        seats = SEATS[tier]
        capacity_tokens = int(kv_gb * 1024**3 / per_tok)
        entry: dict = {"seats": seats}
        for mean_ctx in CONTEXTS:
            slots = slots_for(capacity_tokens, mean_ctx)
            entry[f"slots_{mean_ctx}"] = slots
            for duty in DUTIES:
                rng = random.Random(SEED)
                members = coop_sim.build_members(
                    rng, seats, DURATION_H * 3600, duty, False
                )
                res = coop_sim.simulate(
                    members, capacity_tokens, slots, service_s, IDLE_CAP_S, SEED
                )
                entry[f"d{int(duty*100)}_c{mean_ctx}"] = {
                    "p50": round(res.pct(0.50), 1),
                    "p95": round(res.pct(0.95), 1),
                    "verdict": verdict(res.pct(0.95)),
                    "peak_kv_pct": round(100.0 * res.peak_kv / capacity_tokens),
                }
        out["tiers"][tier] = entry
    return out


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument(
        "--out",
        type=Path,
        default=Path(__file__).resolve().parents[2] / "coopforge/web/content/capacity-sim.json",
        help="destination path (default repo sibling coopforge/web/content)",
    )
    args = ap.parse_args()
    dest = args.out
    if not dest.parent.is_dir():
        sys.exit(f"destination directory does not exist: {dest.parent}")
    data = run()
    dest.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")
    print(f"wrote {dest}")


if __name__ == "__main__":
    main()
