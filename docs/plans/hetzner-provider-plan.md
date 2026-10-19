# Plan: Wire Hetzner as CoopForge GPU provider

Source: ohno epics `epic-db5b8193` (P0) / `epic-ead21bd3` (P1). Evidence base:
`coopforge-trooper-migration/report.md`.

## Goal

Add Hetzner dedicated GPU boxes (GEX45 = RTX PRO 4000 24GB, GEX63 = RTX PRO 6000
96GB) as a provisioning provider for the two tiers where Hetzner beats Scaleway
on seat price, and reconcile the three-way catalog drift.

## Global Constraints

- Billing truth is `coopforge/web/lib/coop-rules.ts`. `manifest/tiers.json` and
  `README.md` follow it, never the reverse.
- `seatPricing()` and `fairUseQuotaTokens()` formulas do not change.
- Seat prices must land on: seed-24g = 600c (EUR 6.00), everyday-96g = 1360c
  (EUR 13.60) at recommended quotas 40 / 80.
- The 5 existing Scaleway tiers keep their exact current numbers.
- Engine pin is `vllm/vllm-openai:v0.31.0` unless a spike proves it cannot run
  on sm_120 (Blackwell).
- Hetzner is monthly-commit only: no hourly billing path, no autoscaling.

## Environment Constraints (rulings taken at setup)

- R1: `coopforge/` is not a git repository. Commit steps cannot apply there.
  Originals are backed up to the plan workspace before any edit; verification
  evidence lives in the ledger.
- R2: `coopforge-infra/` is a git repo with zero commits and pre-existing
  untracked files that are not mine. I do not create the initial commit.
  Commit steps record the workspace diff instead.
- R3: no Hetzner Robot credentials exist in the environment. Spikes 5-7 deliver
  documented findings from public sources plus the API contract; live
  order/install acceptance criteria are deferred and recorded as such.
- R4: no test runner exists in `coopforge/web` (no vitest/jest, no test script).
  Per-task RED→GREEN uses Node 26 native TypeScript execution
  (`node --experimental-strip-types`) on a throwaway assertion script; no test
  framework is added to the repo (out of plan scope).

## Task 1: Extend Provider union and add Hetzner SPECS entries

File: `coopforge/web/lib/coop-rules.ts`. ohno `task-8ef1f9b0`.

Steps:
1. Write throwaway harness `tools/verify-tiers.ts` asserting: `seed-24g` and
   `everyday-96g` exist in `HARDWARE_TEMPLATES`; their `monthly_cost_cents` are
   21404 / 99700; `seatPricing(...).seat_price_cents` are 600 / 1360; the 5
   Scaleway tiers' seat prices are unchanged at their known values.
2. Run it. Expected: FAIL — `seed-24g` undefined.
3. Edit `coop-rules.ts`: `Provider` = `"scaleway" | "hetzner"`; add `hetzner:
   "Hetzner"` to `PROVIDER_LABELS`; add optional `monthly_cost_override_cents`
   to `HardwareSpec`; use it in the `HARDWARE_TEMPLATES` map; add the two SPECS
   entries.
4. Run it. Expected: PASS, all assertions, exit 0.
5. Run `npx tsc --noEmit` in `coopforge/web`. Expected: no new errors vs the
   pre-change baseline recorded in the ledger.
6. Remove the throwaway harness; record evidence in the ledger.

## Task 2: Handle hetzner provider in UI and provisioning dispatch

Files: consumers of `Provider` / `HARDWARE_TEMPLATES` under `coopforge/web/`.
ohno `task-55488bf7`.

Steps:
1. Enumerate consumers: `grep -rn "PROVIDER_LABELS\|HARDWARE_TEMPLATES\|getHardwareTemplate\|Provider" coopforge/web --include=*.ts --include=*.tsx`.
   Expected: list captured to the ledger.
2. Write throwaway harness asserting every consumer path is provider-agnostic:
   for each template, `generateCoopDescription(t, t.default_model, "Test")`
   returns a string containing the tier's provider label and no `undefined`.
3. Run it. Expected: FAIL on the two Hetzner templates (missing provider copy)
   or PASS if already generic — record which.
4. Edit the failing consumers so Hetzner tiers render with their label, region
   label, and a monthly-commit note; ensure no SCW-only branch is reachable for
   a Hetzner template.
5. Run it. Expected: PASS.
6. `npx tsc --noEmit`. Expected: no new errors.

## Task 3: Rewrite manifest/tiers.json to the shipped 7-tier catalog

File: `coopforge-infra/manifest/tiers.json`. ohno `task-f295a1c8`.

Steps:
1. Write throwaway harness asserting: every key in `tiers.json` exists as an
   `id` in `coop-rules.ts` SPECS, and every SPECS id exists in `tiers.json`.
2. Run it. Expected: FAIL — 4 drifted names on one side, 2 missing on the other.
3. Rewrite `tiers.json` with 7 entries keyed by SPECS ids, preserving the
   existing schema fields (`repo`, `sha`, `engine`, `served_context`, `gpus`,
   `gpu_model`, `tp_size`) plus `provider`.
4. Run it. Expected: PASS, 7/7 both directions.
5. Run `docker compose -f coopforge-infra/docker-compose.yml config -q`.
   Expected: exit 0.

## Task 4: Fix README pricing/hardware table from code truth

File: `coopforge/README.md`. ohno `task-0c691c5b`.

Steps:
1. Write throwaway harness that extracts the README tier table rows and asserts
   each row's seat price equals `seatPricing()` for the matching template.
2. Run it. Expected: FAIL — rows missing, or L4/L40S wording mismatched.
3. Rewrite the table from SPECS: 7 rows, provider column, GPU name verbatim
   from `gpu`, seat price from `seatPricing()`.
4. Run it. Expected: PASS, 7 rows, all prices equal.

## Task 5: Spike — Robot API order flow, lead time, stock

ohno `task-699bbd7b`. Deliverable: `coopforge-infra/docs/spikes/robot-api.md`.

Steps:
1. Read the Hetzner Robot API docs (`robot.hetzner.com/doc/webservice/en.html`):
   server list, order, cancellation endpoints; auth (HTTP basic, web-service
   user); monthly billing terms.
2. Record: endpoint + auth scheme, order-to-ready lead time, cancellation
   semantics (notice period, whether partial months bill), stock visibility.
3. Date-stamped stock snapshot for GEX45 / GEX63.
4. Ruling on the unverifiable parts (no creds) and what they cost if wrong.

## Task 6: Spike — vLLM sm_120 support on RTX PRO 4000/6000

ohno `task-512f2d71`. Deliverable: `coopforge-infra/docs/spikes/vllm-sm120.md`.

Steps:
1. Check `vllm/vllm-openai:v0.31.0` release notes and CUDA build for sm_120
   (Blackwell) kernel support; note minimum CUDA 12.8 requirement.
2. Determine whether the pinned image tag ships a Blackwell-capable build; if
   not, name the minimum version that does.
3. Record the impact on the two tiers' model/quant choices if the pin moves.

## Task 7: Spike — automated OS install on Hetzner dedicated root

ohno `task-8fc2511f`. Deliverable: `coopforge-infra/docs/spikes/install-image.md`.

Steps:
1. Compare `installimage` (rescue + config), rescue + manual debootstrap, and
   the Robot API rescue activation path.
2. Write the scripted sequence: activate rescue, run installimage with our SSH
   key, reboot, verify SSH, install docker + nvidia-container-toolkit.
3. List failure modes and the stage timings that must be measured live.

## Task 8: hetzner-provision.sh — order to serving node

File: `coopforge-infra/scripts/hetzner-provision.sh`. ohno `task-45cc0b32`.

Steps:
1. Write the script: env `ROBOT_USER` / `ROBOT_WS_PASSWORD`, tier slug arg,
   stage-named failures (ORDER/INSTALL/BOOTSTRAP/MODEL_PULL/REGISTER),
   idempotent re-entry, prints server id + monthly cost + cancel command.
2. Run `bash -n` and `shellcheck` (if present). Expected: clean.
3. Run with no creds. Expected: exits non-zero at ORDER with a clear message,
   no partial side effects.
4. Run `--dry-run` with the two tier slugs. Expected: prints the full ordered
   plan and exits 0 without network calls.
5. Record live end-to-end as deferred (R3).

## Task 9: Gateway mesh registration and health check

File: `coopforge-infra/manifest/gateway.yaml` (+ any loader). ohno `task-7e3ff62b`.

Steps:
1. Add `per_tier_budgets` entries for `seed-24g` and `everyday-96g` derived
   from the SPECS tpm caps and member quotas; add `provider` to node entries if
   the schema carries node identity.
2. Validate the YAML parses and every `per_tier_budgets` key exists in
   `tiers.json`. Expected: PASS, 7/7.
3. Record health-check rotation behaviour as needing a live node (R3).

## Task 10: Teardown — drain, deregister, cancel

File: `coopforge-infra/scripts/hetzner-teardown.sh`. ohno `task-65d260a2`.

Steps:
1. Write the script: drain wait, remove node from gateway rotation, cancel via
   Robot API, print effective billing end; refuse without `--force` if the tier
   has no fallback capacity.
2. `bash -n` + `--dry-run`. Expected: clean, prints plan, exits 0.
3. No-args run. Expected: usage error, exit 2.

## Task 11: Ops runbook for Hetzner tiers

File: `coopforge-infra/docs/hetzner-runbook.md`. ohno `task-35074453`.

Steps:
1. Write: stock check, order, verify serving, cancel, monthly cost
   reconciliation, rollback table (everyday-96g → power-h100, +EUR 19.15/seat;
   seed-24g → everyday-fr-l40s, +EUR 13.40/seat).
2. Verify every command in the runbook exists in the repo or is a documented
   API call. Expected: no dangling references.

## Review Focus

- Input classes the tests do not exercise: tiers with `status: "soon"`, a
  template whose `monthly_cost_override_cents` is present but zero, seats at
  the MIN/MAX quota bounds (2 and 150), and any consumer that switches on
  `provider` exhaustively.
- Failure modes: seat price drift if `recommended_member_quota` changes; a
  Hetzner tier rendered with Scaleway region copy; provisioning scripts that
  half-succeed and leave a box billing; teardown without fallback capacity.

## Execution outcome (2026-10-18)

All 11 tasks are done; the epics `epic-db5b8193` and `epic-ead21bd3` closed on
the ohno board. Every harness in the verification sweep below is green.

Rulings worth keeping:

- Hetzner is monthly-commit, so there is no hourly path and no autoscaling;
  `monthly_cost_override_cents` carries the monthly price (21404 / 99733) and
  `seatPricing()` / `fairUseQuotaTokens()` are unchanged. Seat prices land on
  €6.00 (`seed-24g`) and €13.60 (`everyday-96g`).
- The catalog keeps 99733 rather than Hetzner's published €999.00: the published
  price is net of VAT and would move `everyday-96g` to €13.62/seat. Setup fees
  (€209 / €999) are real cash and are not modelled in the seat price.
- `manifest/tiers.json` is generated from `SPECS`; `manifest/gateway.yaml`
  `per_tier_budgets` is keyed by the same 7 tier ids. `scripts/tier-facts.mjs` is
  the one reader both repos use, and `scripts/verify-gateway.py` pins the
  budgets against the tier facts.
- State, Robot API and SSH primitives live in `scripts/hetzner-lib.sh` so the
  provision and teardown scripts cannot drift apart.
- Blocker B1 stands: `seed-24g` declares INT4 but points at a ~61 GB BF16 model
  on a 24 GB card, and no first-party INT4 artifact exists. `MODEL_PULL` refuses
  for that tier; fixing `repo`/`sha` in `manifest/tiers.json` lifts it.
- No Robot credentials were available, so ordering, `installimage`, bootstrap,
  the model pull, a successful SSH deregister and a real cancellation are
  documented but not exercised end to end.

Defect found in the final review and fixed: `ssh_run` uses `ssh -n` (stdin from
`/dev/null`), and the INSTALL stage piped the installimage config into it, so the
remote config file would have been written empty. `ssh_run_stdin()` now carries
the single stdin call site.

```bash
# coopforge/web
node --experimental-strip-types --no-warnings scripts/verify-tiers.ts
node --experimental-strip-types --no-warnings --import ./scripts/register-ts-hook.mjs scripts/verify-provider.ts
node --experimental-strip-types --no-warnings --import ./scripts/register-ts-hook.mjs scripts/verify-manifest.ts
node --experimental-strip-types --no-warnings --import ./scripts/register-ts-hook.mjs scripts/verify-readme.ts
npx tsc --noEmit

# coopforge-infra
scripts/verify-gateway.py
docker compose --env-file .env.example config -q
bash -n scripts/hetzner-lib.sh scripts/hetzner-provision.sh scripts/hetzner-node-bootstrap.sh scripts/hetzner-teardown.sh
shellcheck -S warning scripts/hetzner-lib.sh scripts/hetzner-provision.sh scripts/hetzner-node-bootstrap.sh scripts/hetzner-teardown.sh
scripts/hetzner-provision.sh --dry-run seed-24g
scripts/hetzner-teardown.sh --status everyday-96g
```
