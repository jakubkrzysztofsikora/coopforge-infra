# coopforge-infra

Deployment manifests for CoopForge GPU coops. Each coop = one Scaleway box serving one
pinned open-weight model via vLLM.

## What is open / what is closed

- **Open**: provisioning scripts, docker-compose, engine pins, model manifests, systemd units.
- **Closed**: the platform web app (coopforge/web) and its billing code — closed until the
  billing logic is auditable; the per-seat derivation it uses is public on every coop page
  and must reconcile to the cent.

## Provision a box

Hetzner tiers are ordered and installed by the checked-in script. Each stage is
recorded in `state/hetzner/<tier>.env`, so a re-run resumes instead of re-ordering:

    scripts/hetzner-provision.sh --dry-run seed-24g                      # plan, no network, no state
    ROBOT_USER=... ROBOT_WS_PASSWORD=... scripts/hetzner-provision.sh --yes seed-24g

Operator detail — stock check, cancellation, fallback tiers: `docs/hetzner-runbook.md`.
Test tier, step by step: `docs/test-tier-runbook.md`.

Scaleway tiers are created by hand, then the serving stack from this repo is
installed on the box:

    scw instance image list zone=fr-par-1 name=ubuntu --output json | head -40   # pick GPU image id
    scw instance server create zone=fr-par-1 type=L4-1-24G image=<IMAGE_ID> \
      name=cf-<run> tags.0=coopforge tags.1=<coop-slug> --wait

## Serve the model

    docker compose up -d   # pins vLLM v0.31.0 + model repo from manifest/

Model artifacts per tier: see manifest/ (HF repo + repo SHA per template id).

## Test template (single-seat e2e)

Cheapest EU option for testing buy → bootstrap → usage flow. CPU-only, no GPU.

    scripts/scaleway-test-provision.sh --dry-run

Creates a **DEV1-L** VM (4 vCPU, 8 GB RAM, 40 GB disk, ~€0.043/h) running
**Ollama behind a LiteLLM gateway** — the same shape as the GPU tiers, minus the
GPU. Members get an OpenAI-compatible endpoint and a real per-member gateway key,
not raw access to the model server.

    LITELLM_MASTER_KEY=<secret> \
    COOP_SLUG=<coop-slug> COOPFORGE_STATUS_TOKEN=<provisioning_token> \
    CLOUDFLARE_API_TOKEN=<dns:edit on coopforge.eu> \
    COOPFORGE_API_KEY=<platform internal secret> \
      scripts/scaleway-test-provision.sh --yes

One command takes the box from nothing to a working HTTPS endpoint with a
minted member key. Stages: create VM -> start -> wait SSH -> install the
Ollama+LiteLLM stack -> install the TLS tunnel -> register with the platform ->
install the key signer -> assert the close-out tag. Each stage is recorded in
`state/scaleway/test.env`, so a re-run resumes instead of repeating.

`LITELLM_MASTER_KEY` must be the same value the platform holds: the signer mints
member keys against it. `CLOUDFLARE_API_TOKEN` is optional — without it the box
stays on plain HTTP and members are given an `http://<ip>:4000` address.
`COOPFORGE_API_KEY` is optional — without it no member keys are minted. Both
skip with a warning rather than failing, so a partial run still leaves a box.

Teardown:

    scripts/scaleway-test-teardown.sh --yes

Model: `speakleash/Bielik-Minitron-7B-v3.0-Instruct` — Polish, 7.35B params,
tool calling support. Outperforms Mistral-7B on benchmarks. Measured on the
provisioned DEV1-L: ~6.5 tok/s generation, ~19 tok/s prompt on 4 vCPU. Fine for
exercising the buy → bootstrap → use path; not for heavy coding throughput.

The stack lives in `test-tier/`: `docker-compose.yml` (Ollama + LiteLLM +
Postgres), `litellm-config.yaml` (the one route), and `test-tier-bootstrap.sh`
(installs Docker, pulls the model, waits for the gateway to answer `/health`).

### Full bootstrap from the platform (end to end)

The coop's life is driven from the platform; the box only has to register itself.

1. **Coop fills.** Mollie webhook sees the quota met, sets `coops.status='filled'`
   and mints `provisioning_token`. The founder gets an email carrying that token.
2. **Box provisions.** Run the test template with the coop's slug, token and the
   gateway master key:

       LITELLM_MASTER_KEY=<secret> \
       COOP_SLUG=<coop-slug> COOPFORGE_STATUS_TOKEN=<provisioning_token> \
         scripts/scaleway-test-provision.sh --yes

3. **Box registers.** The provision script POSTs a status sample carrying the
   box's own `gateway_endpoint`; the first accepted push flips the coop to
   `active` and records that address on the coop.
4. **Signer mints keys, outbound.** `test-tier/install-signer.sh` installs
   `manifest/signer.py` as a systemd service on the box. It polls
   `/api/internal/coops-with-members`, mints one key per charged member against
   the box's own gateway, and reports each to `/api/internal/keys`.
5. **Members are mailed.** The key report triggers the platform to mail that
   member their base URL, key and model id.

Why the signer runs on the box: the platform cannot reach into it. Cloudflare
refuses to fetch a plain-HTTP origin and blocks a raw-IP fetch outright
(`error 1003`), so reaching a box needs a hostname and a trusted certificate.
Polling outbound needs neither.

Platform env: `COOPFORGE_API_KEY`, `BREVO_API_KEY`, `SCALEWAY_SECRET_KEY`.
`LITELLM_MASTER_KEY` is only needed by whoever mints — on the test tier that is
the box, not the platform. `LITELLM_GATEWAY_URL` is a fallback for a box that
does not announce its own endpoint.

#### TLS

Members reach the gateway over HTTPS at `https://<coop-slug>-gw.coopforge.eu`;
the plaintext port is bound to loopback, so it never faces the internet.

    COOP_SLUG=<slug> CLOUDFLARE_API_TOKEN=... bash test-tier/install-tunnel.sh

Prints the HTTPS endpoint to pass as `GATEWAY_ENDPOINT` when registering.

`CLOUDFLARE_API_TOKEN` needs **DNS:Edit on coopforge.eu**. It is required because
`cloudflared tunnel route dns` writes into whatever zone the local origin
certificate is scoped to, which is a personal zone, not coopforge.eu — so the
CNAME is created through the API instead.

A tunnel, not a certificate on the box: the box then needs no inbound ports, the
edge presents a publicly trusted certificate, and the box's IP stays unpublished.
A self-signed certificate would not work — Cloudflare Workers will not fetch a
plain-HTTP origin, and browsers reject an unknown CA.

One tunnel per coop, so tearing a coop down removes its route without touching
another. Delete it on close-out:

    cloudflared tunnel delete coopforge-<slug>

The deadline sweeper runs as its own Worker (`web/sweep-worker`, cron every 15
minutes) because open-next regenerates the app's `worker.js`, so a `scheduled`
handler added there would be overwritten. Deploy it with `npm run deploy:sweep`.

### Coop end — clearing everything

A coop that ends must leave nothing running and nothing billing. One path does
all of it, used by both the deadline sweeper and a manual close-out:

    curl -X POST https://coopforge.eu/api/internal/sweep \
      -H "Authorization: Bearer $COOPFORGE_API_KEY"      # every expired coop
    curl -X POST https://coopforge.eu/api/internal/closeout \
      -H "Authorization: Bearer $COOPFORGE_API_KEY" \
      -d '{"slug":"<coop-slug>","reason":"archived"}'    # one coop

Close-out, in order: revoke every gateway key → release the box, its flexible
IP and its volumes via the Scaleway API → null every stored credential
(`litellm_key`, `api_key_hash`, `cache_salt`, `provisioning_token`) → notify
members. A member's key stops working even if the box lingers, and a released
provisioning token cannot be replayed.

Release is driven from the platform, not the box: a box holds no Scaleway
credentials and cannot delete itself, and deleting the VM is what destroys the
secrets it holds. The box is found by its `coop=<slug>` tag, so the platform
stores no infrastructure ids.

Needs `SCALEWAY_SECRET_KEY` on the platform. Without it close-out still revokes
keys and clears credentials, and reports `no_credentials` rather than claiming a
release it did not perform.

Operator path for a box that predates this, or a release that failed:

    scripts/scaleway-test-teardown.sh --yes

open-next emits no `scheduled` handler, so the sweeper is an HTTP endpoint, not
a Cron Trigger: point any scheduler at it (systemd timer, GitHub Action, or a
small cron Worker that fetches the URL).

## Seat capacity — how many members a tier can carry

**Read this before setting `recommended_member_quota` on a tier.** Two models
answer the question and they disagree; the simulator is the better evidence.

    python3 scripts/coop-sim.py --config studio-4x-h100 --seats 120 --duty 0.15
    python3 scripts/coop-sim.py --config studio-4x-h100 --seats 120 --duty 0.15 --burst
    python3 scripts/seat-capacity-model.py --streams 74 --seats 120 --duty 0.15

### What each tool is for

| Tool | Model | Use it for |
|---|---|---|
| `coop-sim.py` | Discrete-event: turn arrivals, think gaps, decode slots, KV residency and eviction | **The decision.** Simulates the interleaving that produces queue wait |
| `seat-capacity-model.py` | Closed-form: binomial tail + Erlang-C | A fast sanity check. Assumes smooth arrivals, so it is pessimistic and coarse |

`coop-sim.py` is deterministic (fixed seed, no wall-clock): same input, same
output.

### The one input that decides everything: `duty`

`duty` is the fraction of a working day a member's agent is actively decoding.
Mean concurrent turns = `seats × duty`. Every verdict scales with it, and it is
**not yet measured** — it must come from real members (`demand-variance-profile`
in `../proof-of-viability/`).

### Results at 120 seats, 8h window, 8k mean context

| Tier | Slots | duty 15% | duty 40% | duty 60% |
|---|---|---|---|---|
| pro-fr-2x-l40s | 669 | ok | ok | ok |
| everyday-96g | 669 | ok | ok | ok |
| power-h100 | 182 | ok | ok | ok |
| everyday-fr-l40s | 104 | ok | ok | ok |
| studio-4x-h100 | 74 | ok | ok | p95 3.8s |
| seed-24g | 35 | ok | ok | ok (0.7s at 80%) |

"ok" means p95 queue wait stays inside the 1s flow threshold. Slots are
`KV_tokens / mean_context` — the derived concurrency ceiling, not a guess.

### Actions from these results

**1. `seed-24g` was fixed by swapping the model (done).** It originally ran a
30B AWQ coder: 18 GB of weights on a 24 GB card left only ~4 GB of KV, which is
10 slots at 8k context, and it failed the simulation at *every* duty cycle
(p95 6.0h at just 15%). It now runs **Mistral-7B-Instruct-v0.3 AWQ**: 4.2 GB of
weights, ~17.9 GB of KV, **35 slots**, healthy to 80% duty at its full 40 seats.

Why a 7B model and not something larger: KV budget scales as `usable - weights`,
so on a 24 GB card the model size is what buys concurrency. Mistral Small 4
(242 GB) and the 30B coder both blow the budget; a 7-8B model is the only class
that leaves useful KV. Apache 2.0, so no licence question.

**2. The four large tiers are safe past 60% duty.** No action needed on their
seat counts; the constraint on them is cost, not capacity. studio-4x-h100 is the
exception at the margin: 3.8s p95 at 60% duty, so treat 60% as its practical
ceiling.

**3. Measure `duty` before trusting any seat count.** Add it to the status push
the box already sends: concurrent turns and KV utilisation are both already
exposed by the engine (`vllm:num_requests_running`, `vllm:kv_cache_usage_perc`).
Until that number exists, every quota is an assumption.

**4. Raise `mean_context` before believing a slot count.** Slots scale as
`1 / mean_context`. At 32k mean context studio drops from 74 slots to 18, and the
same 40% duty that was fine at 8k becomes a **12.7 hour** p95 wait. Agent traffic
is long-context; 8k is the optimistic case.

**5. Prefer an idle cap over more hardware.** A one-hour idle cap cuts the
hold-all-live KV ceiling ~3.6× for ~0.5pp more recompute (M365 production study,
121M calls). Cheaper than a bigger box.

**6. Instrument eviction, not just latency.** Evictions and recompute tokens are
the leading indicator; queue wait is the lagging one. `coop-sim.py` reports both.

### Caveats

- The workload is synthetic. Context lengths, think gaps and burst shape come
  from published traces, not this coop's members.
- Slots are derived from KV arithmetic, not read from the engine. vLLM's own
  startup line (`GPU KV cache size: N tokens, Maximum concurrency for M tokens
  per request: X.XXx`) is the authoritative check and should confirm or refute
  the slot count on a real box.
- Bursts are modelled as two regimes (normal / correlated). The literature's
  tool is a Gamma or MMPP fit with measured α; that needs real traces.
