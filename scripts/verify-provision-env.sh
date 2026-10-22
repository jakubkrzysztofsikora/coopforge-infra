#!/usr/bin/env bash
# Verify the COOP_SLUG wiring from the provisioning flow down to the status agent.
#
#   scripts/verify-provision-env.sh
#   ROOT=/tmp/pre-change-tree scripts/verify-provision-env.sh    # must FAIL
#
# COOP_SLUG has to be the coop's platform slug — slugify(title) plus a
# uniqueness suffix, e.g. glm53-flash-studio-coop-1 — because
# POST /api/status-push resolves the coop with `SELECT id, provisioning_token
# FROM coops WHERE slug = ?`. A tier id such as everyday-96g never matches, so a
# box that sends one has every sample rejected. The register stage is exercised
# for real, with NODE_DIR and SYSTEMD_DIR pointed at a scratch directory and a
# stub systemctl on PATH: no network, no root, no live systemd.
set -Eeuo pipefail

ROOT=${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
readonly ROOT
readonly BOOTSTRAP=$ROOT/scripts/hetzner-node-bootstrap.sh
readonly PROVISION=$ROOT/scripts/hetzner-provision.sh
readonly ENV_FILE=$ROOT/.env.example
readonly GATEWAY=$ROOT/manifest/gateway.yaml
readonly TIERS=$ROOT/manifest/tiers.json
# A production slug and a production tier id: the two are never interchangeable.
readonly SLUG_FIXTURE=glm53-flash-studio-coop-1
readonly TIER_FIXTURE=everyday-96g
readonly PUSH_URL=https://coopforge.eu/api/status-push
readonly PUSH_TOKEN=push-token-fixture

checks=0
failures=()

check() { # check <label> <actual> <expected>
  checks=$((checks + 1))
  if [[ $2 == "$3" ]]; then
    printf 'ok   %s\n' "$1"
    return 0
  fi
  printf 'FAIL %s: got %s, want %s\n' "$1" "${2:-<empty>}" "${3:-<empty>}"
  failures+=("$1")
}

yesno() { if "$@" >/dev/null 2>&1; then printf yes; else printf no; fi; }

env_value() { sed -n "s/^$1=//p" "$ENV_FILE" | tail -n1; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/node" "$work/systemd" "$work/bin"
cp "$ROOT/status-agent.sh" "$work/node/status-agent.sh"
cat >"$work/bin/systemctl" <<STUB
#!/bin/sh
printf 'systemctl %s\n' "\$*" >>"$work/systemctl.log"
STUB
chmod +x "$work/bin/systemctl"

RC=0
OUT=
register_case() { # register_case <push-url> <token> <coop-slug>
  RC=0
  OUT=$(env PATH="$work/bin:$PATH" \
    NODE_DIR="$work/node" SYSTEMD_DIR="$work/systemd" \
    TIER="$TIER_FIXTURE" REPO=Qwen/Qwen3.6-35B-A3B-FP8 SERVED_MODEL_NAME=qwen3.6-35b-a3b \
    ENGINE=vllm/vllm-openai:v0.31.0 \
    COOPFORGE_STATUS_PUSH_URL="$1" COOPFORGE_STATUS_TOKEN="$2" COOP_SLUG="$3" \
    bash "$BOOTSTRAP" register 2>&1) || RC=$?
}

# (a) no code path turns the tier id into the slug. The scan skips this file:
# its own assertions carry the literal COOP_SLUG=<tier> pattern.
hits=$(grep -rEn --exclude=verify-provision-env.sh \
  'COOP_SLUG=.*[$][{]?TIER([^A-Za-z0-9_]|$)' "$ROOT/scripts" "$ROOT/systemd" 2>/dev/null || true)
check "no script under scripts/ or systemd/ sets COOP_SLUG from \$TIER" "$hits" ""
check "the status unit template uses \$COOP_SLUG" \
  "$(yesno grep -qxF 'Environment=COOP_SLUG=$COOP_SLUG' "$BOOTSTRAP")" yes

# (b) the register stage: skip when unconfigured, fail without COOP_SLUG, complete with it.
register_case '' '' ''
check "register skips when the status push is unconfigured" "$RC" 0
check "the skip is announced" "$(yesno grep -q skipped <<<"$OUT")" yes

register_case "$PUSH_URL" "$PUSH_TOKEN" ''
check "register fails without COOP_SLUG" "$RC" 14
check "the failure names COOP_SLUG" "$(yesno grep -q COOP_SLUG <<<"$OUT")" yes

register_case "$PUSH_URL" "$PUSH_TOKEN" "$SLUG_FIXTURE"
check "register completes with COOP_SLUG set" "$RC" 0
check "the unit carries the coop slug" \
  "$(yesno grep -qxF "Environment=COOP_SLUG=$SLUG_FIXTURE" "$work/systemd/coopforge-status.service")" yes
check "the unit never carries the tier id as the slug" \
  "$(yesno grep -qxF "Environment=COOP_SLUG=$TIER_FIXTURE" "$work/systemd/coopforge-status.service")" no

# (c) .env.example documents COOP_SLUG and names a model the manifest ships.
slug=$(env_value COOP_SLUG)
repo=$(env_value MODEL_REPO)
served=$(env_value SERVED_MODEL_NAME)
sha=$(env_value MODEL_SHA)
tier_ids=$(python3 -c 'import json,sys; print("\n".join(json.load(open(sys.argv[1]))))' "$TIERS")
repos=$(python3 -c 'import json,sys; print("\n".join(sorted({t["repo"] for t in json.load(open(sys.argv[1])).values()})))' "$TIERS")
routes=$(python3 -c 'import sys,yaml; print("\n".join(m["model_name"] for m in yaml.safe_load(open(sys.argv[1]))["model_list"]))' "$GATEWAY")
want_sha=$(python3 -c 'import json,sys; print(",".join(sorted({t["sha"] for t in json.load(open(sys.argv[1])).values() if t["repo"] == sys.argv[2] and t["sha"]})))' "$TIERS" "$repo")
check ".env.example sets COOP_SLUG" "$(yesno test -n "$slug")" yes
check ".env.example COOP_SLUG is not a tier id" "$(yesno grep -qxF "$slug" <<<"$tier_ids")" no
check ".env.example MODEL_REPO is a repo the manifest ships" "$(yesno grep -qxF "$repo" <<<"$repos")" yes
check ".env.example SERVED_MODEL_NAME is a gateway route" "$(yesno grep -qxF "$served" <<<"$routes")" yes
check ".env.example MODEL_SHA is that repo's manifest revision" "$sha" "$want_sha"

# (d) the provision script documents COOP_SLUG as the slug and forwards it.
env_list=$(sed -n '/^Environment:/,/^Exit codes:/p' "$PROVISION")
check "the provision env list mentions COOP_SLUG" "$(yesno grep -q COOP_SLUG <<<"$env_list")" yes
check "the provision env list calls COOP_SLUG the platform slug" "$(yesno grep -qE 'COOP_SLUG.*slug' <<<"$env_list")" yes
check "run_node_stage forwards COOP_SLUG to the node" "$(yesno grep -qE 'env_prefix.*COOP_SLUG' "$PROVISION")" yes
check "the REGISTER stage refuses a missing COOP_SLUG" "$(yesno grep -q 'COOP_SLUG is required' "$PROVISION")" yes

# (e) the engine answers to its gateway route name, never to the tier id: a
# request the gateway routes as qwen3.6-35b-a3b reaches a box serving
# --served-model-name qwen3.6-35b-a3b, so the two names have to be the same one.
# A tier with "routed": false is not served by the coop gateway yet: the
# operator Mac Studio tier runs through a different gateway, and a soon tier has
# no upstream until it is provisioned. Flip the flag when the tier goes live.
unrouted=$(python3 -c 'import json,sys,yaml; tiers=json.load(open(sys.argv[1])); routes={m["model_name"] for m in yaml.safe_load(open(sys.argv[2]))["model_list"]}; print(",".join(k for k,t in tiers.items() if t.get("routed", True) and t.get("route") not in routes))' "$TIERS" "$GATEWAY")
check "every manifest tier names a gateway route" "$unrouted" ""
check "the vLLM unit takes the served name from the manifest route" \
  "$(yesno grep -q -- '--served-model-name @SERVED_MODEL_NAME@' "$ROOT/systemd/vllm.service")" yes
check "the vLLM unit never serves the tier id" \
  "$(yesno grep -q -- '--served-model-name @TIER@' "$ROOT/systemd/vllm.service")" no
check "run_node_stage forwards SERVED_MODEL_NAME to the node" \
  "$(yesno grep -qE 'env_prefix.*SERVED_MODEL_NAME' "$PROVISION")" yes
check "a node stage without SERVED_MODEL_NAME is refused" \
  "$(yesno grep -q 'SERVED_MODEL_NAME is required' "$BOOTSTRAP")" yes

printf '\n%d/%d checks passed\n' "$((checks - ${#failures[@]}))" "$checks"
if ((${#failures[@]})); then
  printf '%d FAILED\n' "${#failures[@]}"
  exit 1
fi
