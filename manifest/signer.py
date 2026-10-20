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
from datetime import datetime, timezone
from pathlib import Path

API = os.environ["COOPFORGE_API"].rstrip("/")
# Cloudflare rejects the default Python-urllib User-Agent with 403, so every
# request carries an explicit one.
UA = os.environ.get("COOPFORGE_USER_AGENT", "coopforge-signer/1.0")
API_KEY = os.environ["COOPFORGE_API_KEY"]
LITELLM = os.environ["LITELLM_URL"].rstrip("/")
MASTER = os.environ["LITELLM_MASTER_KEY"]
SYNC_EVERY = int(os.environ.get("SYNC_INTERVAL_SECONDS", "60"))
STATE = Path(os.environ.get("STATE_FILE", "/app/data/state.json"))


def log(level: str, event: str, rid: str, **data) -> None:
    line = json.dumps(
        {"ts": datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z"),
         "level": level, "event": event, "rid": rid, **data},
        default=str,
    )
    print(line, file=sys.stderr if level == "error" else sys.stdout, flush=True)


def new_rid() -> str:
    return f"rid_{int(time.time())}_{secrets.token_hex(4)}"


def fetch_coops() -> list[dict]:
    req = urllib.request.Request(
        f"{API}/api/internal/coops-with-members",
        headers={"Authorization": f"Bearer {API_KEY}", "User-Agent": UA},
    )
    with urllib.request.urlopen(req, timeout=15) as r:
        return json.loads(r.read())


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
    """Mint this member's key, or None if the gateway will not give one.

    The alias is unique gateway-wide, so a mint can lose a race with another
    minter (the platform, or a previous run whose state was lost). A lost race is
    not a failure to report as one: the key exists, but its plaintext is only
    ever returned at creation, so the stale alias is revoked and reminted. That
    invalidates the old key, which is correct — the state file that held it is
    gone, so nobody can be using it knowingly.
    """
    kid = member_key_id(member["coop_slug"], member["id"])
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
    if "key" in created:
        return created["key"]

    # Alias taken by a key we cannot read back. Revoke and remint.
    revoked = litellm("POST", "/key/delete", {"key_aliases": [kid]})
    if not revoked.get("deleted_keys"):
        print(f"  could not free alias {kid}: {revoked}", file=sys.stderr)
        return None
    reminted = litellm("POST", "/key/generate", body)
    if "key" not in reminted:
        print(f"  key create failed for {kid}: {reminted}", file=sys.stderr)
        return None
    return reminted["key"]


def report_new_key(member_id: str, key: str, key_id: str | None, rid: str) -> None:
    body = json.dumps({"member_id": member_id, "litellm_key": key, "litellm_key_id": key_id}).encode()
    req = urllib.request.Request(
        f"{API}/api/internal/keys",
        data=body,
        method="POST",
        headers={
            "Authorization": f"Bearer {API_KEY}",
            "Content-Type": "application/json",
            "User-Agent": UA,
            "x-request-id": rid,
        },
    )
    try:
        urllib.request.urlopen(req, timeout=10).read()
        log("info", "key_report.sent", rid, member_id=member_id, key_id=key_id)
    except Exception as e:
        log("error", "key_report.failed", rid, member_id=member_id, error=str(e))


def main() -> None:
    STATE.parent.mkdir(parents=True, exist_ok=True)
    seen: dict[str, str] = json.loads(STATE.read_text()) if STATE.exists() else {}
    while True:
        rid = new_rid()
        try:
            coops = fetch_coops()
            minted = 0
            for coop in coops:
                # The platform derives the budget per tier; the manifest copy is
                # only a fallback for a tier it does not know about yet.
                budget = coop.get("budget")
                if not budget:
                    continue
                for m in coop.get("members", []):
                    # 'charged' | 'trial' | 'active' — a member is entitled to a
                    # key as soon as their payment cleared.
                    if m["status"] not in ("charged", "trial", "active"):
                        continue
                    kid = member_key_id(coop["coop_slug"], m["id"])
                    if kid in seen:
                        continue
                    key = ensure_member_key(m, budget)
                    if key:
                        seen[kid] = key
                        minted += 1
                        report_new_key(m["id"], key, kid, rid)
            fd = os.open(STATE, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            try:
                os.write(fd, json.dumps(seen).encode())
            finally:
                os.close(fd)
            os.chmod(STATE, 0o600)
            log("info", "sync.completed", rid, coops=len(coops), minted=minted)
        except Exception as e:
            log("error", "sync.failed", rid, error=str(e))
        time.sleep(SYNC_EVERY)


if __name__ == "__main__":
    main()
