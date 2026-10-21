# Test tier runbook

How to provision, use and tear down the single-seat Test tier. Everything here
has been run end to end; the numbers are from those runs.

## What the tier is

One DEV1-L VM (4 vCPU, 8 GB RAM, 40 GB disk, ~€0.043/h) running **Ollama behind
a LiteLLM gateway**, with a Cloudflare TLS tunnel in front and the key signer on
the box. Members get an OpenAI-compatible HTTPS endpoint and a real per-member
gateway key, not raw access to the model server.

Model: `SpeakLeash/bielik-minitron-7B-v3.0-Instruct:Q4_K_M` (~4.5 GB).
Measured: ~6.5 tok/s generation, ~19 tok/s prompt on 4 vCPU. Fine for
exercising the buy → bootstrap → use path; not for heavy coding throughput.

Only `jakub@gruba.it` may pick this template. Everyone else sees it read-only.

## Before you start

Four values. The first two come from the platform; the last two are secrets.

| Value | Where it comes from |
|---|---|
| `COOP_SLUG` | the coop's slug (`coops.slug`) |
| `COOPFORGE_STATUS_TOKEN` | the coop's `provisioning_token`, from the founder email |
| `LITELLM_MASTER_KEY` | the platform's secret of the same name |
| `CLOUDFLARE_API_TOKEN` | DNS:Edit on `coopforge.eu` |
| `COOPFORGE_API_KEY` | the platform's secret of the same name |

`CLOUDFLARE_API_TOKEN` and `COOPFORGE_API_KEY` are optional: without them the box
skips TLS and key minting respectively, warns, and still leaves a usable box.

## Provision

One command. It creates the VM, installs the stack, installs TLS, registers with
the platform, and installs the signer.

    COOP_SLUG=<slug> \
    COOPFORGE_STATUS_TOKEN=<token> \
    LITELLM_MASTER_KEY=<secret> \
    CLOUDFLARE_API_TOKEN=<secret> \
    COOPFORGE_API_KEY=<secret> \
      bash coopforge-infra/scripts/scaleway-test-provision.sh --yes

Takes ~4 minutes (Docker install plus the 4.5 GB model pull). Each stage is
recorded in `state/scaleway/test.env`, so a re-run resumes rather than repeating.
`--dry-run` prints the plan; `--status` shows what has run.

Expect:

    TLS gateway live: https://<slug>-gw.coopforge.eu
    registered: {"ok":true}
    signer installed and running

## Use it

The box mints a key per charged member and reports it to the platform, which
mails the member their endpoint, key and model id. The key is also readable:

    cd coopforge/web
    npx wrangler d1 execute coopforge-db --remote --json \
      --command "SELECT litellm_key FROM members WHERE coop_id=(SELECT id FROM coops WHERE slug='<slug>')"

Then:

    curl https://<slug>-gw.coopforge.eu/v1/chat/completions \
      -H "Authorization: Bearer <key>" -H 'Content-Type: application/json' \
      -d '{"model":"bielik-minitron-7b","messages":[{"role":"user","content":"ping"}]}'

The model id is `bielik-minitron-7b`, not the full Ollama tag — the gateway
routes the short name.

## Teardown

    COOP_SLUG=<slug> CLOUDFLARE_API_TOKEN=<secret> \
      bash coopforge-infra/scripts/scaleway-test-teardown.sh --yes

Deletes the server, its volume, its flexible IP, the tunnel, and the tunnel's
DNS record. Without `COOP_SLUG`/`CLOUDFLARE_API_TOKEN` the tunnel and CNAME are
left behind and reported.

## What has been verified

- One command takes the box from nothing to a working HTTPS endpoint
- The minted member key returns a completion over HTTPS
- Tool calling works: the model emits a `get_weather` call with `{"city":"Paris"}`
- Tool calling survives client prompts that teach a rival syntax: the v4 template
  override (system-block paragraph + final positive reminder) forces a structured
  `<tool_call>` even when the system prompt documents its own XML dialect. Trail and
  probes: `docs/spikes/bielik-tool-calls.md`. Offline gate:
  `scripts/verify-bielik-tool-template.py`; live gate adds `--live --api-key $KEY`
  (run on the box; sends a tool request through the gateway and requires `tool_calls`)
- Registration flips the coop `filled` → `active` and records the HTTPS endpoint
- Teardown removes server, IP, volume, tunnel and DNS with no orphans

## Known limits

- **~6.5 tok/s.** CPU-only. Usable for testing, not for real coding work.
- **History is silently truncated at ~4k tokens.** `num_ctx` is capped at 8192
  (16384 OOMs the 8 GB box), and the system prompt, tool schemas and template
  overrides consume roughly half of it; Ollama drops the oldest messages beyond
  that. Long agent sessions lose early tool results — clients should re-supply
  anything critical.
- **The tier's `duty` is unmeasured.** Every seat-count claim in the tier table
  depends on it; see the "Seat capacity" section of the infra README.
- **No load test on the GPU tiers.** Their capacity figures are arithmetic from
  vLLM's KV formulas, checked by `scripts/verify-kv-formulas.py`, not measured on
  hardware. Confirming them needs a GPU box.
- **Bielik is gated on Hugging Face** (`gated: auto`). Auto-approved, and Ollama
  pulls it from its own registry, so it is not a blocker — but it is a dependency.
