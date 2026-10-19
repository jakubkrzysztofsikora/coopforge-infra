# Hetzner tier runbook

Covers the two Hetzner tiers — `seed-24g` (GEX45, RTX PRO 4000 24 GB) and
`everyday-96g` (GEX63, RTX PRO 6000 96 GB) — from stock check to cancellation.

Hetzner bills monthly with a committed term: there is no hourly path and no
autoscaling. A tier is either ordered for the month or not, so the teardown
decision is a monthly one.

## Where the truth lives

| Fact | Source |
| --- | --- |
| Tier specs, seat price, caps, provider | `coopforge/web/lib/coop-rules.ts` (`SPECS`) |
| Serving manifest (repo, sha, engine, context, gpus) | `manifest/tiers.json` |
| Per-member gateway budgets | `manifest/gateway.yaml` (`per_tier_budgets`) |
| Mesh membership and per-node weight | `manifest/gateway.yaml` (`mesh.nodes`) |
| Mesh liveness: registered nodes and health | `state/gateway-nodes.json` (`mesh.registry`, gitignored — rotation writes here, never the manifest) |
| Robot API contract and rate limits | `docs/spikes/robot-api.md` |
| Unattended install details | `docs/spikes/install-image.md` |
| Engine image and driver requirement | `docs/spikes/vllm-sm120.md` |

Nothing is hand-edited into two places: the scripts read tier facts through
`scripts/tier-facts.mjs`, which imports `lib/coop-rules.ts` and reads
`manifest/tiers.json`.

```bash
node --experimental-strip-types --no-warnings scripts/tier-facts.mjs everyday-96g | jq .
```

## 1. Before ordering

1. Robot web-service user with **Web Service Ordering** enabled. `ROBOT_USER` is
   the web-service user, not the Robot login.
2. An SSH public key (`SSH_KEY`, default `~/.ssh/id_ed25519.pub`); it is
   registered in Robot and installed on the box.
3. `ROBOT_WS_PASSWORD` exported in the shell. The scripts refuse to touch the
   network without it.
4. Know the fallback tier (section 6) — you need it the day you cancel.

## 2. Stock check

```bash
curl -fsS -u "$ROBOT_USER:$ROBOT_WS_PASSWORD" \
  https://robot-ws.your-server.de/order/server/product | jq '.product[] | .name, .prices[0].price'
```

A 403 here means ordering is not enabled for the web-service user; fix that
before spending time on anything else. `hetzner-provision.sh` saves the same
response to `state/hetzner/<tier>.products.json` as price evidence.

## 3. Order and provision

```bash
scripts/hetzner-provision.sh --dry-run seed-24g          # plan, no network, no state
scripts/hetzner-provision.sh --status  seed-24g          # what has already run
ROBOT_USER=... ROBOT_WS_PASSWORD=... scripts/hetzner-provision.sh --yes everyday-96g
```

Stages run in order: ORDER → INSTALL → BOOTSTRAP → MODEL_PULL → REGISTER.
Completed stages are recorded in `state/hetzner/<tier>.env`, so a re-run resumes
instead of re-ordering. Exit codes name the stage that failed: 10 ORDER,
11 INSTALL, 12 BOOTSTRAP, 13 MODEL_PULL, 14 REGISTER.

REGISTER writes the box into the gateway mesh — `scripts/gateway-mesh.py
register --tier <tier> --server <n> --ip <ip>` records it in
`state/gateway-nodes.json`, so the tier is only served once provisioning has
registered the node. A node that is not in the registry serves nothing.

Timings for the live stages are unmeasured — no box has been ordered yet (see
section 8).

## 4. Verify serving

On the box (or over SSH), the engine answers on port 8000 under the tier id as
its model name:

```bash
curl -fsS http://<ip>:8000/health
curl -fsS http://<ip>:8000/v1/chat/completions -H 'Content-Type: application/json' \
  -d '{"model":"everyday-96g","messages":[{"role":"user","content":"say hi"}],"max_tokens":16}'
curl -fsS http://<ip>:8000/metrics | grep -E '^vllm:(num_requests_running|gpu_cache_usage_perc)'
```

Repo-side checks, all green as of the last change:

```bash
# coopforge/web
node --experimental-strip-types --no-warnings scripts/verify-tiers.ts
node --experimental-strip-types --no-warnings --import ./scripts/register-ts-hook.mjs scripts/verify-provider.ts
node --experimental-strip-types --no-warnings --import ./scripts/register-ts-hook.mjs scripts/verify-manifest.ts
node --experimental-strip-types --no-warnings --import ./scripts/register-ts-hook.mjs scripts/verify-readme.ts
npx tsc --noEmit

# coopforge-infra
scripts/verify-gateway.py
scripts/gateway-mesh.py status          # served set per tier, from the registry
docker compose --env-file .env.example config -q
bash -n scripts/hetzner-lib.sh scripts/hetzner-provision.sh scripts/hetzner-node-bootstrap.sh scripts/hetzner-teardown.sh
shellcheck -S warning scripts/hetzner-lib.sh scripts/hetzner-provision.sh scripts/hetzner-node-bootstrap.sh scripts/hetzner-teardown.sh
```

## 5. Monthly cost reconciliation

| Tier | Catalog (what the seat price uses) | Published list | Setup |
| --- | --- | --- | --- |
| seed-24g (GEX45) | €214.04 | €214.00 + VAT | €209 one-off |
| everyday-96g (GEX63) | €997.33 | €999.00 + VAT | €999 one-off |

The catalog values are deliberate: `€999.00` would move `everyday-96g` to
€13.62/seat, and the published prices are net of VAT. Setup fees are real cash
and are not modelled in the seat price — the first month of one `everyday-96g`
is €1,998.00 net.

Recompute a seat price after any quota change:

```bash
node --experimental-strip-types --no-warnings scripts/tier-facts.mjs everyday-96g | jq '{monthly_cost_cents, recommended_member_quota, seat_price_cents}'
```

## 6. Rollback

If a Hetzner tier has to go, its coops move to the Scaleway tier with the
closest capacity:

| From | To | Seat price change |
| --- | --- | --- |
| everyday-96g (€13.60/seat) | power-h100 (€32.75/seat) | +€19.15/seat |
| seed-24g (€6.00/seat) | everyday-fr-l40s (€19.40/seat) | +€13.40/seat |

Order of operations:

1. Change each affected coop's `hardware_template` to the fallback tier.
2. Confirm the fallback tier is serving and the gateway is routing to it.
3. Only then tear the Hetzner node down (section 7). The teardown script refuses
   to cancel a tier with no fallback capacity unless `--force` is passed.

## 7. Cancel

```bash
scripts/hetzner-teardown.sh --dry-run seed-24g
scripts/hetzner-teardown.sh --status  seed-24g
ROBOT_USER=... ROBOT_WS_PASSWORD=... scripts/hetzner-teardown.sh --yes seed-24g
```

DRAIN → DEREGISTER → CANCEL:

- **DRAIN** polls `vllm:num_requests_running` on the node until it is 0
  (`DRAIN_TIMEOUT`, 300s). A node that does not answer is already out of
  rotation. Passing the timeout needs `--force`.
- **DEREGISTER** stops `coopforge-vllm.service` and `coopforge-status.timer` on
  the box. An unreachable node needs `--force`, because it may still be serving.
- **CANCEL** reads `earliest_cancellation_date` from
  `GET /server/{n}/cancellation`, POSTs it (override with `--cancel-date`), then
  prints `paid_until`.

Cancellation is not a kill switch: a cancelled server keeps running until the end
of its paid period, and the script prints that date. Wipe the disks before asking
Hetzner to take the box back early, and revoke a mistaken cancellation with
`DELETE /server/{n}/cancellation`.

For a box whose state file is gone, pass the identity directly:

```bash
scripts/hetzner-teardown.sh --yes --force --server 1234567 --ip 10.0.0.1 seed-24g
```

## 8. Known blockers and unexercised paths

- **Blocker B1 — `seed-24g` has no loadable model.** The manifest declares INT4
  but points at `Qwen/Qwen3-Coder-30B-A3B-Instruct`, which is ~61 GB BF16 on a
  24 GB card, and no first-party INT4 artifact exists. `hetzner-provision.sh`
  refuses MODEL_PULL for this tier and `--dry-run` prints the same `BLOCKED`
  line. Fix `repo`/`sha` in `manifest/tiers.json` first.
- **Live stages are unexercised.** No Robot credentials were available, so
  ordering, the `installimage` run, bootstrap, model pull, registration, a
  successful SSH deregister and a real cancellation have not been run end to end.
  Order/install/bootstrap timings stay unmeasured until the first box.
- **Health-check rotation is unexercised on a live node.** Rotation is
  implemented — `scripts/gateway-mesh.py check` probes `mesh.health_check.path`
  every `interval_seconds` and drops a node after `failures_before_rotation`
  consecutive failures — and `scripts/verify-gateway.py` asserts the served set
  against a stubbed probe. No box has been registered yet, so a real `/health`
  failure has never rotated a node out, and the timing between probe and gateway
  removal is unmeasured. Nothing schedules `check` either: it is run by hand
  until the gateway side has a timer for it.
- **Driver floor.** The engine pin `vllm/vllm-openai:v0.31.0` needs host driver
  R580+; the fallback tag `v0.31.0-cu129` needs R575.51.03+.

## 9. Failure modes to watch

- **A half-succeeded provisioning run leaves a box billing.** The state file
  records which stages completed; a box that was ordered but never installed is
  cancelled with `--server N` (no address needed).
- **Teardown without fallback capacity** takes the tier's coops offline. The
  script requires `--force` for that; the fallback table is section 6.
- **An unhealthy node keeps its share until `check` runs.** Rotation is not
  automatic: `scripts/gateway-mesh.py check` is what drops a failed node, so a
  box that dies between runs keeps receiving its share of the tier's traffic.
- **Seat price drift.** Changing `recommended_member_quota` or
  `monthly_cost_override_cents` moves the seat price. `scripts/verify-tiers.ts`
  pins the current values.
- **Scaleway copy on a Hetzner tier.** Provider and region labels come from
  `PROVIDER_LABELS` and `region_label`; `scripts/verify-provider.ts` and
  `scripts/verify-readme.ts` fail if a Hetzner tier renders Scaleway copy.
