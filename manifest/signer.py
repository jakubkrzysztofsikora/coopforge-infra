#!/usr/bin/env python3
"""Sync coop members from D1 into LiteLLM as rate-limited keys.

For each admitted member, ensure a LiteLLM virtual key exists with per-tier
tpm/rpm/parallelism caps. Tracks local state so we don't recreate keys on
every poll. New keys are returned via the COOPFORGE_API webhook so the
founder can forward them to the member once.
"""
from __future__ import annotations
import hashlib
import json
import os
import secrets
import sys
import time
import urllib.request
import urllib.error
from pathlib import Path

API = os.environ["COOPFORGE_API"].rstrip("/")
API_KEY = os.environ["COOPFORGE_API_KEY"]
LITELLM = os.environ["LITELLM_URL"].rstrip("/")
MASTER = os.environ["LITELLM_MASTER_KEY"]
SYNC_EVERY = int(os.environ.get("SYNC_INTERVAL_SECONDS", "60"))
CONFIG = Path("/app/manifest/gateway.yaml")
STATE = Path("/app/data/state.json")


def fetch_coops() -> list[dict]:
    req = urllib.request.Request(
        f"{API}/api/internal/coops-with-members",
        headers={"Authorization": f"Bearer {API_KEY}"},
    )
    with urllib.request.urlopen(req, timeout=15) as r:
        return json.loads(r.read())


def fetch_budgets() -> dict:
    import yaml  # type: ignore
    with open(CONFIG) as f:
        cfg = yaml.safe_load(f)
    return cfg.get("per_tier_budgets", {})


def litellm(method: str, path: str, body: dict | None = None) -> dict:
    req = urllib.request.Request(
        f"{LITELLM}{path}",
        method=method,
        data=json.dumps(body).encode() if body else None,
        headers={
            "Authorization": f"Bearer {MASTER}",
            "Content-Type": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            return json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        return {"error": e.code, "body": e.read().decode("utf-8", "ignore")}


def member_key_id(coop_slug: str, member_id: str) -> str:
    h = hashlib.sha256(f"{coop_slug}:{member_id}".encode()).hexdigest()[:16]
    return f"coop-{coop_slug[:20]}-{h}"


def ensure_member_key(member: dict, budget: dict) -> str | None:
    kid = member_key_id(member["coop_slug"], member["id"])
    res = litellm("GET", f"/key/info?key_alias={kid}")
    if res.get("info"):
        return res["info"].get("key", None)
    body = {
        "key_alias": kid,
        "models": [member["model_name"]],
        "tpm_limit": int(budget["tpm"] * budget.get("burst", 2.0)),
        "rpm_limit": budget["rpm"],
        "max_parallel_requests": budget["parallelism"],
        "metadata": {
            "coop_slug": member["coop_slug"],
            "member_id": member["id"],
            "display_name": member.get("display_name", ""),
        },
    }
    created = litellm("POST", "/key/generate", body)
    if "key" not in created:
        print(f"  key create failed for {kid}: {created}", file=sys.stderr)
        return None
    return created["key"]


def report_new_key(member_id: str, key: str) -> None:
    body = json.dumps({"member_id": member_id, "litellm_key": key}).encode()
    req = urllib.request.Request(
        f"{API}/api/internal/keys",
        data=body,
        method="POST",
        headers={
            "Authorization": f"Bearer {API_KEY}",
            "Content-Type": "application/json",
        },
    )
    try:
        urllib.request.urlopen(req, timeout=10).read()
    except Exception as e:
        print(f"  key report failed: {e}", file=sys.stderr)


def main() -> None:
    STATE.parent.mkdir(parents=True, exist_ok=True)
    seen: dict[str, str] = json.loads(STATE.read_text()) if STATE.exists() else {}
    while True:
        try:
            coops = fetch_coops()
            budgets = fetch_budgets()
            for coop in coops:
                budget = budgets.get(coop["hardware_template"])
                if not budget:
                    continue
                for m in coop.get("members", []):
                    if m["status"] != "admitted":
                        continue
                    kid = member_key_id(coop["slug"], m["id"])
                    if kid in seen:
                        continue
                    key = ensure_member_key(m, budget)
                    if key:
                        seen[kid] = key
                        report_new_key(m["id"], key)
            STATE.write_text(json.dumps(seen))
        except Exception as e:
            print(f"sync error: {e}", file=sys.stderr)
        time.sleep(SYNC_EVERY)


if __name__ == "__main__":
    main()
