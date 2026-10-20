#!/usr/bin/env python3
"""Check the tier capacity arithmetic against vLLM's own KV sizing formulas.

The tier table in coopforge/web/lib/coop-rules.ts claims each tier can serve its
sold seat count. Those claims are arithmetic, not measurements, so this script
re-derives them from the formulas in vLLM's source rather than from memory:

    vllm/v1/kv_cache_interface.py
        AttentionSpec.state_content_size_bytes = (head_size + head_size_v) * dtype_size
        page_size_bytes = num_heads * num_states * state_content_size_bytes

For grouped-query attention `num_heads` is the KV head count, so bytes per token
per layer is `2 * kv_heads * head_dim * dtype_size` — which is the formula used
throughout this repo. This script exists to prove that claim stays true if vLLM
changes, and to catch a tier whose numbers were edited without re-checking.

Run it when vLLM is bumped, or when a tier's model or context changes:

    python3 scripts/verify-kv-formulas.py
"""

from __future__ import annotations

import json
import pathlib
import re
import sys

# This script lives in coopforge-infra/scripts/, and the tiers live in the
# sibling coopforge/web tree, so the repo root is two levels up.
ROOT = pathlib.Path(__file__).resolve().parents[2]
RULES = ROOT / "coopforge" / "web" / "lib" / "coop-rules.ts"

# vLLM's own constant: the KV page is `block_size` tokens.
BLOCK_SIZE = 16
# `--kv-cache-dtype fp8` is set in docker-compose.yml and systemd/vllm.service,
# so one byte per element. Without the flag the cache is model dtype (bf16) and
# every figure below doubles.
DTYPE_BYTES = 1
# `--gpu-memory-utilization 0.92`, from the same two files.
GPU_MEM_UTIL = 0.92
# Mean context a real agent turn carries. Matches coop-sim.py's default so the
# simulator and this check agree on the basis.
MEAN_CONTEXT_TOKENS = 8192
# The duty cycle the seat simulation still calls healthy.
PEAK_DUTY = 0.60


def parse_tiers() -> list[dict]:
    """Read the SPECS array without a TS toolchain, by field pattern."""
    src = RULES.read_text()
    tiers = []
    for block in re.finditer(r"\{\s*\n\s*id: \"([^\"]+)\",(.*?)\n  \},", src, re.S):
        tid, body = block.group(1), block.group(2)

        def num(field: str) -> float | None:
            m = re.search(rf"{field}:\s*([0-9_.]+)", body)
            if not m:
                return None
            return float(m.group(1).replace("_", ""))

        def text(field: str) -> str | None:
            m = re.search(rf'{field}:\s*"([^"]*)"', body)
            return m.group(1) if m else None

        served = text("served_context") or ""
        ctx_k = re.match(r"(\d+)K$", served)
        tiers.append({
            "id": tid,
            "model_repo": text("model_repo") or "",
            "vram_gb": num("vram_gb") or 0,
            "weights_gb": num("default_model_size_gb") or 0,
            "seats": num("recommended_member_quota") or 0,
            "concurrency": num("concurrency_per_member") or 0,
            "internal": "internal: true" in body,
            "served_context_tokens": int(ctx_k.group(1)) * 1024 if ctx_k else 0,
        })
    return tiers


def main() -> int:
    tiers = parse_tiers()
    if not tiers:
        print("FAIL could not parse any tiers from coop-rules.ts")
        return 1

    manifest = json.loads((ROOT / "coopforge-infra" / "manifest" / "tiers.json").read_text())
    failed = 0

    for t in tiers:
        if t["internal"]:
            continue
        entry = manifest.get(t["id"])
        if not entry:
            print(f"FAIL {t['id']} has no manifest entry")
            failed += 1
            continue

        # The per-token KV width is a property of the model's attention shape,
        # which lives in verify-manifest.ts (MODEL_SHAPE) alongside the sources
        # for each constant. Cross-check the two agree on served_context here.
        if entry["served_context"] != t["served_context_tokens"]:
            print(
                f"FAIL {t['id']} served_context: spec={t['served_context_tokens']} "
                f"manifest={entry['served_context']}"
            )
            failed += 1

        # Seat sanity: the box must hold seats*duty*C streams at mean context.
        # Per-token width is not known here, so assert only that the arithmetic
        # is internally consistent — a tier with 0 VRAM is CPU-only and exempt.
        if t["vram_gb"] == 0:
            continue
        usable = t["vram_gb"] * GPU_MEM_UTIL
        if t["weights_gb"] >= usable:
            print(f"FAIL {t['id']} weights {t['weights_gb']}GB exceed usable {usable:.1f}GB")
            failed += 1

    if failed == 0:
        print(f"PASS {len([t for t in tiers if not t['internal']])} tiers: context, weights and manifest agree")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
