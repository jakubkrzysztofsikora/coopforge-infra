#!/usr/bin/env python3
"""Gateway mesh membership, health checks and rotation.

    scripts/gateway-mesh.py status
    scripts/gateway-mesh.py check
    scripts/gateway-mesh.py register --tier seed-24g --server 1234567 --ip 10.0.0.1
    scripts/gateway-mesh.py mark --node-id seed-24g-01 --state unhealthy

Membership is declared in manifest/gateway.yaml (mesh.nodes); liveness is not —
it lives in the registry that manifest declares (mesh.registry), so a node is
rotated out of service without editing the manifest. A node is in service only
while it is registered and its last check passed, and it then carries `weight`
over the weights of its in-service peers in the same tier. Tiers with no node in
service are offline, which is a served state, not a manifest error.
"""
from __future__ import annotations

import argparse
import json
import os
import pathlib
import urllib.error
import urllib.request
from datetime import datetime, timezone

import yaml

ROOT = pathlib.Path(__file__).resolve().parent.parent
GATEWAY = pathlib.Path(os.environ.get("GATEWAY", ROOT / "manifest" / "gateway.yaml"))
ENGINE_PORT = 8000


def now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def load_gateway(path: pathlib.Path = GATEWAY) -> dict:
    return yaml.safe_load(path.read_text()) or {}


def mesh_of(gateway: dict) -> dict:
    return gateway.get("mesh") or {}


def registry_path(gateway: dict, override: str | None = None) -> pathlib.Path:
    if override:
        return pathlib.Path(override)
    declared = mesh_of(gateway).get("registry")
    if not declared:
        raise SystemExit(f"{GATEWAY}: mesh.registry is not declared")
    return ROOT / declared


def load_registry(path: pathlib.Path) -> dict:
    if not path.exists():
        return {"nodes": {}}
    registry = json.loads(path.read_text())
    registry.setdefault("nodes", {})
    return registry


def save_registry(path: pathlib.Path, registry: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(registry, indent=2, sort_keys=True) + "\n")
    tmp.replace(path)


def declared_nodes(gateway: dict) -> list[dict]:
    return mesh_of(gateway).get("nodes") or []


def node_for_tier(gateway: dict, tier: str, node_id: str | None = None) -> dict:
    candidates = [n for n in declared_nodes(gateway) if n.get("tier") == tier]
    if node_id:
        candidates = [n for n in candidates if n.get("id") == node_id]
    if not candidates:
        raise SystemExit(f"no node declared for tier {tier!r} in {GATEWAY.name}")
    if len(candidates) > 1:
        raise SystemExit(
            f"tier {tier!r} has {len(candidates)} declared nodes "
            f"({', '.join(n['id'] for n in candidates)}); pass --node-id"
        )
    return candidates[0]


def address(node: dict, entry: dict | None) -> str:
    return (entry or {}).get("endpoint") or node.get("endpoint") or ""


def in_service(entry: dict | None) -> bool:
    return bool(entry) and entry.get("health") == "healthy"


def served_set(gateway: dict, registry: dict) -> dict[str, dict]:
    entries = registry.get("nodes") or {}
    served: dict[str, dict] = {}
    for node in declared_nodes(gateway):
        bucket = served.setdefault(node.get("tier"), {"nodes": [], "weight_total": 0.0, "offline": True})
        entry = entries.get(node.get("id"))
        if not in_service(entry):
            continue
        weight = float(node.get("weight") or 0)
        bucket["weight_total"] += weight
        bucket["nodes"].append({"id": node.get("id"), "weight": weight, "endpoint": address(node, entry)})
    for bucket in served.values():
        total = bucket["weight_total"]
        for node in bucket["nodes"]:
            node["share"] = node["weight"] / total if total else 0.0
        bucket["offline"] = not bucket["nodes"]
    return served


def probe(endpoint: str, path: str, timeout: float) -> bool:
    try:
        with urllib.request.urlopen(endpoint.rstrip("/") + path, timeout=timeout) as response:
            return 200 <= response.status < 300
    except (urllib.error.URLError, OSError, ValueError):
        return False


def check_once(gateway: dict, registry: dict, probe_fn=probe) -> list[str]:
    policy = mesh_of(gateway).get("health_check") or {}
    path = policy.get("path", "/health")
    timeout = float(policy.get("timeout_seconds", 5))
    limit = int(policy.get("failures_before_rotation", 3))
    entries = registry.setdefault("nodes", {})
    changes = []
    for node in declared_nodes(gateway):
        node_id = node.get("id")
        entry = entries.get(node_id)
        if entry is None:
            continue
        url = address(node, entry)
        entry["last_checked_at"] = now()
        if probe_fn(url, path, timeout):
            if not in_service(entry):
                changes.append(f"{node_id} back in service ({url})")
            entry["health"] = "healthy"
            entry["failures"] = 0
            continue
        failures = int(entry.get("failures") or 0) + 1
        entry["failures"] = failures
        if failures >= limit:
            if in_service(entry):
                entry["health"] = "unhealthy"
                changes.append(f"{node_id} rotated out after {failures} consecutive failures ({url})")
        else:
            changes.append(f"{node_id} probe failed ({failures}/{limit}) ({url})")
    return changes


def register(
    gateway: dict,
    registry: dict,
    tier: str,
    server: str,
    ip: str,
    ssh_port: int = 22,
    node_id: str | None = None,
) -> dict:
    node = node_for_tier(gateway, tier, node_id)
    entry = registry.setdefault("nodes", {}).setdefault(node["id"], {})
    entry.update(
        {
            "tier": tier,
            "endpoint": f"http://{ip}:{ENGINE_PORT}",
            "server_number": server,
            "ssh_port": ssh_port,
            "registered_at": now(),
            "health": "healthy",
            "failures": 0,
        }
    )
    return entry


def set_health(gateway: dict, registry: dict, node_id: str, state: str) -> dict:
    if node_id not in {n.get("id") for n in declared_nodes(gateway)}:
        raise SystemExit(f"{node_id!r} is not a declared mesh node in {GATEWAY.name}")
    entry = registry.setdefault("nodes", {}).setdefault(node_id, {})
    entry["health"] = state
    entry["failures"] = 0
    entry["last_checked_at"] = now()
    return entry


def print_served(gateway: dict, registry: dict) -> None:
    served = served_set(gateway, registry)
    if not served:
        print("mesh: no nodes declared")
        return
    for tier in sorted(served):
        bucket = served[tier]
        if bucket["offline"]:
            print(f"tier {tier:<16} offline: no node in service")
            continue
        for node in bucket["nodes"]:
            print(
                f"tier {tier:<16} {node['id']:<18} weight {node['weight']:g} "
                f"share {node['share']:.3f} {node['endpoint']}"
            )
    online = sum(1 for b in served.values() if not b["offline"])
    print(f"{online}/{len(served)} tiers in service")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--gateway", default=str(GATEWAY))
    parser.add_argument("--registry", default=None)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("status")
    commands.add_parser("check")
    register_cmd = commands.add_parser("register")
    register_cmd.add_argument("--tier", required=True)
    register_cmd.add_argument("--server", required=True)
    register_cmd.add_argument("--ip", required=True)
    register_cmd.add_argument("--ssh-port", type=int, default=22)
    register_cmd.add_argument("--node-id", default=None)
    mark_cmd = commands.add_parser("mark")
    mark_cmd.add_argument("--node-id", required=True)
    mark_cmd.add_argument("--state", choices=("healthy", "unhealthy"), required=True)
    args = parser.parse_args()

    gateway = load_gateway(pathlib.Path(args.gateway))
    path = registry_path(gateway, args.registry)
    registry = load_registry(path)

    if args.command == "status":
        print_served(gateway, registry)
        return

    if args.command == "check":
        for change in check_once(gateway, registry):
            print(change)
        save_registry(path, registry)
        print_served(gateway, registry)
        return

    if args.command == "register":
        node_id = args.node_id or node_for_tier(gateway, args.tier)["id"]
        register(
            gateway,
            registry,
            args.tier,
            args.server,
            args.ip,
            args.ssh_port,
            node_id,
        )
        save_registry(path, registry)
        print(f"{node_id} registered for tier {args.tier} in {path}")
        return

    entry = set_health(gateway, registry, args.node_id, args.state)
    save_registry(path, registry)
    print(f"{args.node_id} {entry['health']}")


if __name__ == "__main__":
    main()
