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

Scaleway tiers are created by hand, then the serving stack from this repo is
installed on the box:

    scw instance image list zone=fr-par-1 name=ubuntu --output json | head -40   # pick GPU image id
    scw instance server create zone=fr-par-1 type=L4-1-24G image=<IMAGE_ID> \
      name=cf-<run> tags.0=coopforge tags.1=<coop-slug> --wait

## Serve the model

    docker compose up -d   # pins vLLM v0.31.0 + model repo from manifest/

Model artifacts per tier: see manifest/ (HF repo + repo SHA per template id).
