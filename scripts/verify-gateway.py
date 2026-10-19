#!/usr/bin/env python3
"""Validate manifest/gateway.yaml against lib/coop-rules.ts.

    scripts/verify-gateway.py
    GATEWAY=manifest/gateway.yaml scripts/verify-gateway.py

Every per_tier_budgets key must be a tier id in manifest/tiers.json, and its
tpm/parallelism must match that tier's tpm_cap_per_member/concurrency_per_member.

Every model route must name the tiers it serves, and every named tier must be a
SPECS tier in lib/coop-rules.ts: a route with no tier has no box to run it.

Every mesh node must reference a declared tier with a positive weight, and the
per-tier shares computed by scripts/gateway-mesh.py must sum to 1 across the
nodes in service. Rotation is asserted here too — an unhealthy node leaves the
served set, its healthy peers absorb the share, and the manifest is not
rewritten by a health change.
"""
import importlib.util
import json
import os
import pathlib
import subprocess
import sys

import yaml

sys.dont_write_bytecode = True

ROOT = pathlib.Path(__file__).resolve().parent.parent
GATEWAY = pathlib.Path(os.environ.get("GATEWAY", ROOT / "manifest" / "gateway.yaml"))
MESH = ROOT / "scripts" / "gateway-mesh.py"
COOP_RULES = next(
    (
        p
        for p in (
            *([pathlib.Path(os.environ["COOP_RULES"])] if os.environ.get("COOP_RULES") else []),
            ROOT / "../coopforge/web/lib/coop-rules.ts",
            ROOT / "../../coopforge/web/lib/coop-rules.ts",
        )
        if p.is_file()
    ),
    None,
)

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


def tier_facts(tier):
    return json.loads(
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


def spec_tier_ids():
    script = (
        f"const m = await import({json.dumps(COOP_RULES.as_uri())});"
        'process.stdout.write(m.HARDWARE_TEMPLATES.map((t) => t.id).join("\\n"));'
    )
    out = subprocess.run(
        ["node", "--experimental-strip-types", "--no-warnings", "--input-type=module", "-e", script],
        capture_output=True,
        text=True,
        check=True,
    ).stdout
    return out.split()


def load_mesh():
    spec = importlib.util.spec_from_file_location("gateway_mesh", MESH)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


if COOP_RULES is None:
    print("FAIL coopforge/web/lib/coop-rules.ts not found next to this checkout; set COOP_RULES")
    sys.exit(1)

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
    facts = tier_facts(tier)
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

spec_tiers = spec_tier_ids()
model_names = [m.get("model_name") for m in gateway.get("model_list") or []]
model_tiers = gateway.get("model_tiers") or {}

check(set(spec_tiers) == set(tiers), f"SPECS ids match tiers.json ({len(spec_tiers)})")
check(bool(model_names), f"model_list declares {len(model_names)} routes")
check(set(model_tiers) == set(model_names), "every model route declares the tiers it serves")
for name in sorted(model_tiers):
    served_tiers = model_tiers[name] or []
    check(
        bool(served_tiers) and all(tier in spec_tiers for tier in served_tiers),
        f"{name}: {' + '.join(served_tiers) or 'no tier'}",
    )

mesh = gateway.get("mesh") or {}
nodes = mesh.get("nodes") or []
policy = mesh.get("health_check") or {}
registry_decl = mesh.get("registry")

check(bool(nodes), f"mesh declares {len(nodes)} node(s)")
check(
    isinstance(registry_decl, str) and bool(registry_decl) and not registry_decl.startswith("/"),
    f"mesh registry {registry_decl!r} is a repo-relative path",
)
check(str(policy.get("path", "")).startswith("/"), f"health check path {policy.get('path')}")
for field in ("interval_seconds", "timeout_seconds", "failures_before_rotation"):
    check(
        isinstance(policy.get(field), int) and policy[field] > 0,
        f"health check {field} {policy.get(field)}",
    )

node_ids = [node.get("id") for node in nodes]
check(len(node_ids) == len(set(node_ids)), "mesh node ids are unique")
for node in nodes:
    node_id = node.get("id")
    check(bool(node_id) and isinstance(node.get("tier"), str), f"{node_id}: declares an id and a tier")
    check(node.get("tier") in budgets, f"{node_id}: tier {node.get('tier')} is a declared tier")
    check(
        isinstance(node.get("weight"), (int, float)) and node["weight"] > 0,
        f"{node_id}: weight {node.get('weight')} > 0",
    )
    endpoint = node.get("endpoint")
    check(
        isinstance(endpoint, str) and endpoint.startswith(("http://", "https://")),
        f"{node_id}: endpoint {endpoint}",
    )

mesh_mod = load_mesh()
manifest_bytes = GATEWAY.read_bytes()
tier0 = nodes[0]["tier"]


def shares_consistent(served):
    for bucket in served.values():
        if bucket["offline"]:
            if bucket["nodes"]:
                return False
            continue
        if any(node["share"] <= 0 for node in bucket["nodes"]):
            return False
        if abs(sum(node["share"] for node in bucket["nodes"]) - 1.0) > 1e-9:
            return False
    return True


def healthy_entry(node, **overrides):
    entry = {"tier": node["tier"], "endpoint": node["endpoint"], "health": "healthy", "failures": 0}
    entry.update(overrides)
    return entry


unregistered = mesh_mod.served_set(gateway, {"nodes": {}})
check(
    bool(unregistered) and all(b["offline"] for b in unregistered.values()) and shares_consistent(unregistered),
    "a node serves nothing until it is registered",
)

registered = {"nodes": {node["id"]: healthy_entry(node) for node in nodes}}
served = mesh_mod.served_set(gateway, registered)
check(
    all(not bucket["offline"] for bucket in served.values()),
    f"registered healthy nodes are in service ({len(served)} tier(s))",
)
check(shares_consistent(served), "served shares sum to 1 per tier")

victim = nodes[0]["id"]
rotated = {"nodes": {node_id: dict(entry) for node_id, entry in registered["nodes"].items()}}
rotated["nodes"][victim]["health"] = "unhealthy"
served_rotated = mesh_mod.served_set(gateway, rotated)
check(
    victim not in [node["id"] for node in served_rotated[tier0]["nodes"]],
    f"{victim}: unhealthy node is out of the served set",
)
check(shares_consistent(served_rotated), "served shares still sum to 1 after rotation")
check(GATEWAY.read_bytes() == manifest_bytes, "rotation writes the registry, never the manifest")
check(
    [node["id"] for node in (mesh_mod.load_gateway(GATEWAY).get("mesh") or {}).get("nodes", [])] == node_ids,
    "the manifest still declares every node after a health change",
)

pair = {
    "mesh": {
        "registry": registry_decl,
        "health_check": policy,
        "nodes": [
            {"id": "pair-a", "tier": tier0, "endpoint": "http://pair-a:8000", "weight": 1},
            {"id": "pair-b", "tier": tier0, "endpoint": "http://pair-b:8000", "weight": 3},
        ],
    }
}
pair_registry = {"nodes": {node["id"]: healthy_entry(node) for node in pair["mesh"]["nodes"]}}
before = mesh_mod.served_set(pair, pair_registry)
check(
    abs(before[tier0]["nodes"][0]["share"] - 0.25) < 1e-9,
    "weight 1 of 1 + 3 -> share 0.250",
)
pair_registry["nodes"]["pair-b"]["health"] = "unhealthy"
after = mesh_mod.served_set(pair, pair_registry)
check(
    [node["id"] for node in after[tier0]["nodes"]] == ["pair-a"]
    and abs(after[tier0]["nodes"][0]["share"] - 1.0) < 1e-9,
    "the healthy peer takes the whole share after rotation",
)

probe_registry = {"nodes": {node["id"]: healthy_entry(node) for node in pair["mesh"]["nodes"]}}
only_pair_b_down = lambda endpoint, path, timeout: "pair-a" in endpoint
changes = []
for _ in range(policy["failures_before_rotation"]):
    changes = mesh_mod.check_once(pair, probe_registry, only_pair_b_down)
check(
    probe_registry["nodes"]["pair-b"]["health"] == "unhealthy" and bool(changes),
    f"pair-b rotated out after {policy['failures_before_rotation']} consecutive failed probes",
)
check(
    [node["id"] for node in mesh_mod.served_set(pair, probe_registry)[tier0]["nodes"]] == ["pair-a"],
    "only the healthy peer is served after the probes fail",
)
mesh_mod.check_once(pair, probe_registry, lambda endpoint, path, timeout: True)
check(
    probe_registry["nodes"]["pair-b"]["health"] == "healthy"
    and len(mesh_mod.served_set(pair, probe_registry)[tier0]["nodes"]) == 2,
    "one successful probe returns the node to service",
)

ghost = mesh_mod.served_set(gateway, {"nodes": {"ghost": {"health": "healthy"}}})
check(all(bucket["offline"] for bucket in ghost.values()), "a registry entry for an undeclared node is not served")

print(f"\n{checks - len(failures)}/{checks} checks passed")
if failures:
    print(f"{len(failures)} FAILED")
    sys.exit(1)
