#!/usr/bin/env python3
"""Sync one coop's member keys and daily usage to the platform.

Keys remain on the box-side LiteLLM gateway; usage is pushed outbound.
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
from datetime import datetime, timedelta, timezone
from pathlib import Path

API = os.environ["COOPFORGE_API"].rstrip("/")
# Cloudflare rejects the default Python-urllib User-Agent with 403, so every
# request carries an explicit one.
UA = os.environ.get("COOPFORGE_USER_AGENT", "coopforge-signer/1.0")
API_KEY = os.environ["COOPFORGE_API_KEY"]
LITELLM = os.environ["LITELLM_URL"].rstrip("/")
MASTER = os.environ["LITELLM_MASTER_KEY"]
COOP_SLUG = os.environ["COOP_SLUG"]
STATUS_TOKEN = os.environ["COOPFORGE_STATUS_TOKEN"]
STATE = Path(os.environ.get("STATE_FILE", "/app/data/state.json"))
USAGE_STATE = Path(os.environ.get("USAGE_STATE_FILE", f"{STATE}.usage.json"))


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


def parse_daily_activity(payload: dict) -> tuple[list[dict], int]:
    results = payload.get("results")
    if not isinstance(results, list):
        raise ValueError("LiteLLM activity response has no results list")
    rows = []
    for day in results:
        if not isinstance(day, dict) or not isinstance(day.get("date"), str):
            continue
        breakdown = day.get("breakdown")
        keys = breakdown.get("api_keys") if isinstance(breakdown, dict) else None
        if not isinstance(keys, dict):
            continue
        for entry in keys.values():
            if not isinstance(entry, dict):
                continue
            metadata = entry.get("metadata")
            metrics = entry.get("metrics")
            alias = metadata.get("key_alias") if isinstance(metadata, dict) else None
            if not isinstance(alias, str) or not isinstance(metrics, dict):
                continue
            counts = [metrics.get("prompt_tokens", 0), metrics.get("completion_tokens", 0), metrics.get("api_requests", 0)]
            if any(isinstance(value, bool) or not isinstance(value, int) or value < 0 for value in counts):
                continue
            rows.append({"day": day["date"], "alias": alias, "prompt": counts[0], "completion": counts[1], "requests": counts[2]})
    return rows, len(results)


def fetch_daily_activity(start: str, end: str) -> tuple[list[dict], bool]:
    rows = []
    for page in range(1, 31):
        payload = litellm("GET", f"/user/daily/activity?start_date={start}&end_date={end}&page={page}")
        if "error" in payload:
            raise RuntimeError(f"LiteLLM activity request failed: {payload['error']}")
        page_rows, result_count = parse_daily_activity(payload)
        if result_count == 0:
            return rows, True
        rows.extend(page_rows)
    return rows, False


def report_usage(rows: list[dict], rid: str) -> dict:
    totals = {"written": 0, "ignored": 0}
    chunks = [rows[offset : offset + 1000] for offset in range(0, len(rows), 1000)] or [[]]
    for chunk in chunks:
        payload = {"coop_slug": COOP_SLUG, "usage": chunk}
        req = urllib.request.Request(
            f"{API}/api/internal/usage",
            data=json.dumps(payload).encode(),
            method="POST",
            headers={
                "Authorization": f"Bearer {API_KEY}",
                "X-Coop-Token": STATUS_TOKEN,
                "Content-Type": "application/json",
                "User-Agent": UA,
                "x-request-id": rid,
            },
        )
        with urllib.request.urlopen(req, timeout=15) as response:
            result = json.loads(response.read() or b"{}")
        if not isinstance(result, dict):
            raise RuntimeError("usage report returned an invalid response")
        for field in totals:
            totals[field] += int(result.get(field, 0))
    return totals
def save_usage_state(state: dict) -> None:
    USAGE_STATE.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(USAGE_STATE, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        os.write(fd, json.dumps(state).encode())
    finally:
        os.close(fd)
    os.chmod(USAGE_STATE, 0o600)


def finalize_closeout(coop: dict, rid: str, aliases: list[str]) -> dict:
    payload = {
        "coop_id": coop["coop_id"],
        "slug": COOP_SLUG,
        "reason": coop.get("closeout_reason") or "archived",
        "revoked_aliases": aliases,
    }
    req = urllib.request.Request(
        f"{API}/api/internal/closeout",
        data=json.dumps(payload).encode(),
        method="POST",
        headers={
            "Authorization": f"Bearer {API_KEY}",
            "X-Coop-Token": STATUS_TOKEN,
            "Content-Type": "application/json",
            "User-Agent": UA,
            "x-request-id": rid,
        },
    )
    with urllib.request.urlopen(req, timeout=30) as response:
        result = json.loads(response.read() or b"{}")
    if result.get("completed") is not True:
        raise RuntimeError(f"closeout remains pending: {result.get('infra', 'unknown')}")
    return result
def sync_usage(rid: str, coop: dict, seen: dict[str, str]) -> None:
    today = datetime.now(timezone.utc).date()
    state = json.loads(USAGE_STATE.read_text()) if USAGE_STATE.exists() else {}
    if not isinstance(state, dict):
        state = {}
    try:
        cursor = datetime.fromisoformat(state["last_day"]).date()
    except (KeyError, TypeError, ValueError):
        cursor = today - timedelta(days=120)
    start = min(cursor, today) - timedelta(days=1)
    rows, complete = fetch_daily_activity(start.isoformat(), today.isoformat())
    if not complete:
        log("warn", "usage_sync.pagination_capped", rid, pages=30)
    report_usage(rows, rid)
    if complete:
        state["last_day"] = today.isoformat()
        save_usage_state(state)
    if coop.get("status") == "closing":
        if not complete:
            raise RuntimeError("daily activity pagination incomplete; closeout remains pending")
        prefix = f"coop-{COOP_SLUG[:20]}-"
        aliases = sorted({key_id for key_id in seen if key_id.startswith(prefix)} | {
            member["key_id"]
            for member in coop.get("members", [])
            if isinstance(member.get("key_id"), str) and member["key_id"].startswith(prefix)
        })
        saved_revoked = state.get("revoked_aliases", [])
        revoked = {alias for alias in saved_revoked if isinstance(alias, str)} if isinstance(saved_revoked, list) else set()
        for alias in aliases:
            if alias in revoked:
                continue
            result = litellm("POST", "/key/delete", {"key_aliases": [alias]})
            if "error" in result and result["error"] != 404:
                raise RuntimeError(f"LiteLLM key revocation failed: {result['error']}")
            revoked.add(alias)
            state["revoked_aliases"] = sorted(revoked)
            save_usage_state(state)
        finalize_closeout(coop, rid, aliases)
        log("info", "closeout.gateway_keys_revoked", rid, aliases=len(aliases))
    log("info", "usage_sync.completed", rid, rows=len(rows), complete=complete)


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

def report_revoked_key(member_id: str, key_id: str, rid: str) -> None:
    body = json.dumps({"member_id": member_id, "key_id": key_id}).encode()
    req = urllib.request.Request(
        f"{API}/api/internal/keys/revoked",
        data=body,
        method="POST",
        headers={
            "Authorization": f"Bearer {API_KEY}",
            "Content-Type": "application/json",
            "User-Agent": UA,
            "x-request-id": rid,
        },
    )
    with urllib.request.urlopen(req, timeout=10) as response:
        response.read()
    log("info", "key_revocation.acknowledged", rid, member_id=member_id, key_id=key_id)


def revoke_member_key(member: dict, coop_slug: str, seen: dict[str, str], rid: str) -> None:
    alias = member_key_id(coop_slug, member["id"])
    reported_alias = member.get("key_id")
    if reported_alias and reported_alias != alias:
        raise ValueError(f"Member key alias mismatch for {member['id']}")
    if alias in seen or reported_alias:
        result = litellm("POST", "/key/delete", {"key_aliases": [alias]})
        if "error" in result and result["error"] != 404:
            raise RuntimeError(f"LiteLLM member key revocation failed: {result['error']}")
    report_revoked_key(member["id"], alias, rid)
    seen.pop(alias, None)


def main() -> None:
    STATE.parent.mkdir(parents=True, exist_ok=True)
    seen: dict[str, str] = json.loads(STATE.read_text()) if STATE.exists() else {}
    while True:
        rid = new_rid()
        try:
            coops = [coop for coop in fetch_coops() if coop.get("coop_slug") == COOP_SLUG]
            minted = 0
            for coop in coops:
                if coop.get("status") == "closing":
                    continue
                budget = coop.get("budget")
                if not budget:
                    continue
                for member in coop.get("members", []):
                    if member["status"] in ("cancelled", "refunded"):
                        revoke_member_key(member, coop["coop_slug"], seen, rid)
                        continue
                    if member["status"] not in ("charged", "trial", "active"):
                        continue
                    key_id = member_key_id(coop["coop_slug"], member["id"])
                    if key_id in seen:
                        continue
                    key = ensure_member_key(member, budget)
                    if key:
                        seen[key_id] = key
                        minted += 1
                        report_new_key(member["id"], key, key_id, rid)
            fd = os.open(STATE, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            try:
                os.write(fd, json.dumps(seen).encode())
            finally:
                os.close(fd)
            os.chmod(STATE, 0o600)
            if coops and coops[0].get("status") in ("active", "closing"):
                sync_usage(rid, coops[0], seen)
            log("info", "sync.completed", rid, coops=len(coops), minted=minted)
        except Exception as e:
            log("error", "sync.failed", rid, error=str(e))
        time.sleep(SYNC_EVERY)


if __name__ == "__main__":
    main()
