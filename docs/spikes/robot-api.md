# Spike — Hetzner Robot webservice API (ordering, cancellation, rescue)

Date: 2026-10-18
Status: documented from vendor documentation and public product pages. Live order/install
acceptance is **deferred** — no Robot credentials are available in this environment (ruling R3).

Sources:
- <https://robot.hetzner.com/doc/webservice/en.html> (fetched 2026-10-18, 670,762 bytes, HTTP 200)
- <https://www.hetzner.com/dedicated-rootserver/gex45/> and `/gex63/` (fetched 2026-10-18)
- <https://www.hetzner.com/dedicated-rootserver/matrix-gpu/> (fetched 2026-10-18)
- Press releases: GEX45 2026-09-01, GEX63 2026-10-06

## Transport and authentication

| Item | Value |
| --- | --- |
| Base URL | `https://robot-ws.your-server.de` |
| Auth | HTTP Basic — `curl -u "user:password"` (Robot webservice user, not the main Robot login) |
| Content type | Form-encoded requests (`-d`, `--data-urlencode`); JSON responses |
| Failed logins | 3 failures block the calling IP for 10 minutes |
| Rate limit | 403 `RATE_LIMIT_EXCEEDED` with `max_request` / `interval`; per-endpoint limits below |
| Maintenance | 503 `Service Unavailable` |

Ordering through the webservice is **disabled by default**. It must be switched on in Robot:
*Administration → Settings → Web Service Settings → Ordering*. Until then every `POST /order/...`
fails. This is a manual, per-account prerequisite the provisioning script cannot satisfy.

## Endpoints the provisioning and teardown paths need

| Method | Path | Purpose | Limit |
| --- | --- | --- | --- |
| GET | `/order/server/product` | Orderable products with prices per location and setup fee | — |
| POST | `/order/server/transaction` | Place the order | — |
| GET | `/order/server/transaction/{id}` | Poll order state until `server_number` is assigned | — |
| GET | `/server` | All servers: `status` (`ready` / `in process`), `paid_until`, `cancelled` | 200/h |
| GET | `/server/{server-number}` | Single server detail | — |
| POST | `/key` | Register an SSH public key, returns `fingerprint` | — |
| POST | `/boot/{server-number}/rescue` | Activate rescue system (`os=linux`, `authorized_key[]`) | — |
| GET | `/boot/{server-number}/rescue` | Rescue state; `password` is a one-time root password | — |
| DELETE | `/boot/{server-number}/rescue` | Deactivate rescue | — |
| POST | `/reset/{server-number}` | Hardware reset (`type=hw`) | 50/h |
| GET | `/server/{server-number}/cancellation` | `earliest_cancellation_date`, `cancelled`, `cancellation_date` | 200/h |
| POST | `/server/{server-number}/cancellation` | Cancel (`cancellation_date=YYYY-MM-DD`) | — |
| DELETE | `/server/{server-number}/cancellation` | Revert a cancellation | — |

Key request/response shapes:

```bash
# order (IPv6-only server; add addon[]=primary_ipv4 for an IPv4 address)
curl -u "$ROBOT_USER:$ROBOT_WS_PASSWORD" https://robot-ws.your-server.de/order/server/transaction \
  --data-urlencode 'product_id=GEX45' \
  --data-urlencode 'dist=Ubuntu 24.04 minimal' \
  --data-urlencode 'authorized_key[]=15:28:b0:03:95:f0:77:b3:10:56:15:6b:77:22:a5:bb' \
  --data-urlencode 'location=FSN1' \
  --data-urlencode 'addon[]=primary_ipv4'
# -> { "transaction": { "id": "B20150121-344958-251479", "status": "in process", "server_number": null } }

# cancel
curl -u "$ROBOT_USER:$ROBOT_WS_PASSWORD" https://robot-ws.your-server.de/server/321/cancellation \
  -d 'cancellation_date=2026-10-18'
# -> { "cancellation": { "cancelled": true, "earliest_cancellation_date": "2026-10-18", ... } }
```

`GET /order/server/product` returns `prices[]` per location with `price.net` / `price.gross`
(monthly) and `price.hourly_net` / `price.hourly_gross`, plus `price_setup.net` / `.gross`.
Prices are in the account currency. This endpoint is the only scriptable source of truth for the
price actually charged; the public product pages render prices client-side and cannot be scraped.

## Cancellation semantics

| Question | Answer | Evidence |
| --- | --- | --- |
| Minimum contract term | None | Product pages, "Terms" section, both GEX45 and GEX63 |
| Cancellation period | Immediately | Product pages; `earliest_cancellation_date` is the date the API returns as the floor |
| Can a cancellation be reverted | Yes — `DELETE /server/{n}/cancellation` | Robot docs |
| What is billed | `paid_until` on `GET /server/{n}`; monthly billing, no pro-rata refund of a started period | Robot docs field list |

Consequence for teardown: cancel with `cancellation_date=<today>` (never earlier than
`earliest_cancellation_date`, or the API rejects the request). A server cancelled mid-period stays
usable until the end of the paid period, so teardown must **drain and deregister first, then
cancel** — cancelling is not a kill switch.

## Stock visibility

- `GET /order/server/product` lists only what is currently orderable; a product missing from the
  list cannot be ordered at that moment. This is the scriptable stock check.
- Public product pages render an availability badge; both pages reported `Available` on 2026-10-18.

### Date-stamped snapshot — 2026-10-18

| | GEX45 | GEX63 |
| --- | --- | --- |
| GPU | NVIDIA RTX PRO 4000 Blackwell SFF Edition, 24 GB GDDR7 ECC | NVIDIA RTX PRO 6000 Blackwell Max-Q, 96 GB GDDR7 ECC |
| Compute capability | sm_120 | sm_120 |
| CPU | Intel Core i5-13500 (6P+8E, 20 threads) | Intel Core Ultra 7 265 (8P+12E, 20 cores) |
| RAM | 64 GB DDR4 | 128 GB DDR5 UDIMM |
| Disk | 2 × 512 GB NVMe | 2 × 1.92 TB NVMe Gen4 Datacenter Edition |
| AI throughput (vendor) | 770 KI-TOPS | 3511 KI-TOPS |
| Idle / max power | 33 W / 187 W | not published |
| Price, net of VAT | €214.00/month | €999.00/month |
| Setup fee, one-time | €209.00 | €999.00 |
| Orderable via webservice | not verified (no credentials) | not verified (no credentials) |
| Availability badge | Available | Available (product launched 2026-10-06) |
| Public hourly rate | €0.3429/h | not published |
| Locations | FSN1 / NBG1 (Germany) | Germany (FSN1/NBG1) |

## Reconciliation against the catalog

The catalog (`coopforge/web/lib/coop-rules.ts`, mirrored into `manifest/tiers.json` and
`coopforge/README.md`) carries `monthly_cost_cents` 21404 and 99733. The published list prices are
€214.00 and €999.00 net of VAT.

| Tier | Catalog | Published (net) | Delta | Seat price if the published price is used |
| --- | --- | --- | --- | --- |
| seed-24g | €214.04 | €214.00 | −€0.04 | unchanged (€6.00) |
| everyday-96g | €997.33 | €999.00 | +€1.67 | €13.62 instead of €13.60 |

Two things the catalog does not model and that are real cash:

1. **Setup fees.** €209 (GEX45) and €999 (GEX63) once per server. First-month cost for one
   everyday-96g server is €1,998.00 net, not €999.00.
2. **Hourly rate.** The catalog's `hourly_rate_cents` (29 and 137) does not match the published
   €0.3429/h for GEX45. This is inert today because `monthly_cost_override_cents` wins in
   `seatPricing()`, but dropping that override would silently mis-price the tier.

The catalog values stand for now: the plan fixes the seat prices at €6.00 and €13.60 exactly, and
moving everyday-96g to €999.00 would move its seat price to €13.62. Revisit both numbers before
the first real order, and decide then whether the setup fee is amortised into the tier cost or
billed separately.

## Ruling on the unverifiable parts (R3)

Not verifiable here, and what it costs if wrong:

| Item | Why unverifiable | Cost if wrong | Mitigation in the provisioning script |
| --- | --- | --- | --- |
| Order → `ready` lead time | Needs a live account and a real order | Script that waits forever, or reports success on an unbootable server | Poll `GET /server/{n}` for `status == "ready"` with a hard timeout; fail at stage `ORDER` |
| Whether ordering is enabled for the account | Robot UI toggle, account state | Every order attempt fails with 403 | First call is `GET /order/server/product`; a 403 aborts before any order with an explicit "enable Web Service Ordering" message |
| Stock at order time | Live inventory | Order silently not placed | Require the product id to be present in `GET /order/server/product`, else abort at stage `ORDER` |
| Actual charged price | Robot UI / invoice | Seat price computed from a stale cost | Log the `prices[]` entry returned for the ordered product so the invoice can be reconciled |
| IPv4 addon price | Not published on the product page | Missing line item | Request `addon[]=primary_ipv4` explicitly and record the addon price from the order transaction response |
