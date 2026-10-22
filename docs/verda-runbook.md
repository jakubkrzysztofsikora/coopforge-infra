# Verda (ex-DataCrunch) runbook

Finland-based GPU cloud with a self-serve REST API. Used for the `spot-fi-l40s`
tier: one L40S 48GB in FIN-01, priced at the spot rate.

## Why this provider

| | Verda spot | Verda on-demand | Scaleway L40S |
|---|---|---|---|
| L40S 48GB per hour | $0.9045 | $1.809 | €1.47 |
| 730 h per month | €613.20 | €1,226.40 | €1,073.10 |
| Per seat (60 seats) | €10.22 | €20.44 | €19.40 |

Spot is the only rate that beats Scaleway. On-demand is dearer per seat, so the
tier is spot-only and not sold yet.

## Credentials

Verda console → Project → **Keys** → **Cloud API Credentials** → Create.
OAuth 2.0 client credentials; the API mints a one-hour access token from them.

Platform (Cloudflare Worker) secrets, needed for close-out to terminate boxes:

```
wrangler secret put VERDA_CLIENT_ID
wrangler secret put VERDA_CLIENT_SECRET
```

Provisioning scripts read the same two variables from the environment.

## Provision

```
VERDA_CLIENT_ID=... VERDA_CLIENT_SECRET=... COOP_SLUG=<coop-slug> \
  scripts/verda-provision.sh --dry-run spot-fi-l40s      # plan, no network writes
VERDA_CLIENT_ID=... VERDA_CLIENT_SECRET=... COOP_SLUG=<coop-slug> \
  scripts/verda-provision.sh --yes spot-fi-l40s          # create + bootstrap
```

Stages resume from `state/verda/<slug>.env`; a re-run adopts the recorded
instance instead of creating a second one.

The instance is tagged `coop_slug=<slug>`. That tag is the only handle the
platform has: close-out lists by tag and terminates the instance with its
volumes. Do not delete the tag by hand.

## Teardown

```
scripts/verda-teardown.sh --dry-run <coop-slug>
VERDA_CLIENT_ID=... VERDA_CLIENT_SECRET=... scripts/verda-teardown.sh --yes <coop-slug>
```

Deletes every instance carrying the tag **and** its OS volume. An orphaned
volume bills on its own.

## Spot risk

Verda may evict spot instances. Nothing in the platform re-provisions after an
eviction yet, which is why the tier is `status: "soon"` — pre-registration
only. Before selling it:

1. Run the tier for a week and count evictions.
2. Add eviction detection to the status agent (missed heartbeats) and a
   re-provision path in `app/api/internal/sweep/route.ts`.
3. Only then flip `status` to `live` in `web/lib/coop-rules.ts`.

Reserved commitments (1 month −2% to 2 years −25%) exist; they do not fix
eviction, only price.

## Known gaps

- **No CO2 stat.** Verda publishes neither PUE nor its host CPU model, so the
  use-phase estimate has no sourced term. `power_w` is `null` and
  `localGridFactor()` returns `null` for `verda`, so no CO2 row is written.
  Add a factor only with a published source.
- **No published price for reserved capacity in EUR.** `hourly_rate_cents: 84`
  assumes $0.9045/h at 1.08 USD/EUR. Re-check the rate before launch.
- **Instance type is resolved at run time.** `/v1/instance-types` is filtered
  for a single L40S with ≥48GB, so a Verda catalogue rename does not break the
  script; the display string in `coop-rules.ts` is not an API identifier.
