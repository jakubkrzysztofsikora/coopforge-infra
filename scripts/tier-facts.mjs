#!/usr/bin/env node
// Provisioning facts for one CoopForge tier, as JSON.
//
//   node --experimental-strip-types --no-warnings scripts/tier-facts.mjs seed-24g
//
// Cost, seat price and per-member caps come from coopforge/web/lib/coop-rules.ts
// (billing truth). Engine, model and context come from manifest/tiers.json.
import { existsSync, readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const COOP_RULES =
  process.env.COOP_RULES ??
  ["../coopforge/web/lib/coop-rules.ts", "../../coopforge/web/lib/coop-rules.ts"]
    .map((p) => resolve(ROOT, p))
    .find((p) => existsSync(p));
const TIERS = resolve(ROOT, "manifest/tiers.json");

const slug = process.argv[2];
if (!slug) {
  console.error("usage: tier-facts.mjs <tier-id>");
  process.exit(2);
}

let coopRules;
if (!COOP_RULES) {
  console.error("coopforge/web/lib/coop-rules.ts not found next to this checkout; set COOP_RULES to its path");
  process.exit(2);
}
try {
  coopRules = await import(COOP_RULES);
} catch (error) {
  console.error(`cannot load ${COOP_RULES}: ${error.message}`);
  console.error("set COOP_RULES to coopforge/web/lib/coop-rules.ts if the checkout layout differs");
  process.exit(2);
}

const template = coopRules.HARDWARE_TEMPLATES.find((t) => t.id === slug);
if (!template) {
  console.error(`unknown tier: ${slug}`);
  process.exit(2);
}

const manifest = JSON.parse(readFileSync(TIERS, "utf8"))[slug];
if (!manifest) {
  console.error(`tier ${slug} is missing from manifest/tiers.json`);
  process.exit(2);
}

process.stdout.write(
  JSON.stringify(
    {
      id: template.id,
      provider: template.provider,
      instance: template.instance,
      gpu: template.gpu,
      vram_gb: template.vram_gb,
      region_label: template.region_label,
      status: template.status,
      monthly_cost_cents: template.monthly_cost_cents,
      recommended_member_quota: template.recommended_member_quota,
      seat_price_cents: coopRules.seatPricing(template.monthly_cost_cents, template.recommended_member_quota)
        .seat_price_cents,
      tpm_cap_per_member: template.tpm_cap_per_member,
      concurrency_per_member: template.concurrency_per_member,
      repo: manifest.repo,
      sha: manifest.sha,
      engine: manifest.engine,
      served_context: manifest.served_context,
      gpus: manifest.gpus,
      gpu_model: manifest.gpu_model,
      tp_size: manifest.tp_size,
    },
    null,
    2,
  ) + "\n",
);
