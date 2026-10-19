#!/bin/sh
# systemd timer target: every 5 min scrape vLLM /metrics, push aggregates to CoopForge.
# Payload keys must match StatusPushBody in coopforge/web/app/api/status-push/route.ts.
set -eu

: "${COOPFORGE_STATUS_PUSH_URL:?COOPFORGE_STATUS_PUSH_URL is required}"
: "${COOPFORGE_STATUS_TOKEN:?COOPFORGE_STATUS_TOKEN is required}"
: "${COOP_SLUG:?COOP_SLUG is required}"

METRICS_URL=${COOPFORGE_METRICS_URL:-http://localhost:8000/metrics}
HEALTH_URL=${COOPFORGE_HEALTH_URL:-http://localhost:8000/health}
VLLM_ENV=${COOPFORGE_VLLM_ENV:-/opt/coopforge/vllm.env}

# Served-model metadata written by hetzner-node-bootstrap.sh stage_model_pull.
ENGINE=
MODEL_SHA=
if [ -r "$VLLM_ENV" ]; then
  while IFS='=' read -r key value; do
    case $key in
      ENGINE) ENGINE=$value ;;
      SHA) MODEL_SHA=$value ;;
    esac
  done <"$VLLM_ENV"
fi

if curl -sfS -m 5 "$HEALTH_URL" >/dev/null 2>&1; then
  UPTIME_OK=1
else
  UPTIME_OK=0
fi

# A dead engine still reports uptime_ok=0 instead of dropping the heartbeat.
METRICS=$(curl -sfS -m 15 "$METRICS_URL" || true)

export UPTIME_OK ENGINE MODEL_SHA
PAYLOAD=$(
  printf '%s' "$METRICS" | python3 -c '
import json, os, sys
from datetime import datetime, timezone

Q = chr(34)


def label_value(labels, key):
    marker = key + "="
    pos = labels.find(marker)
    while pos != -1:
        if pos == 0 or labels[pos - 1] in ",{ ":
            rest = labels[pos + len(marker):]
            if rest.startswith(Q):
                end = rest.find(Q, 1)
                if end != -1:
                    return rest[1:end]
        pos = labels.find(marker, pos + 1)
    return None


def samples(text):
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        brace = line.find("{")
        if brace != -1:
            close = line.rfind("}")
            if close == -1:
                continue
            name, labels = line[:brace], line[brace + 1:close]
            rest = line[close + 1:]
        else:
            parts = line.split(" ", 1)
            if len(parts) != 2:
                continue
            name, labels, rest = parts[0], "", parts[1]
        try:
            value = float(rest.strip())
        except ValueError:
            continue
        yield name, labels, value


totals = {}
buckets = {}
config_labels = []

for name, labels, value in samples(sys.stdin.read()):
    totals[name] = totals.get(name, 0.0) + value
    if name.endswith("_bucket"):
        le = label_value(labels, "le")
        if le is not None:
            bucket = buckets.setdefault(name[:-7], {})
            bucket[le] = bucket.get(le, 0.0) + value
    elif name == "vllm:cache_config_info":
        config_labels.append(labels)


def quantile(metric, q):
    counts = buckets.get(metric)
    if not counts:
        return None
    entries = []
    for le, cumulative in counts.items():
        try:
            bound = float("inf") if le == "+Inf" else float(le)
        except ValueError:
            continue
        entries.append((bound, cumulative))
    entries.sort()
    total = entries[-1][1]
    if total <= 0:
        return None
    rank = q * total
    lower, lower_cum = 0.0, 0.0
    for bound, cumulative in entries:
        if cumulative >= rank:
            if bound == float("inf") or cumulative == lower_cum:
                return lower
            return lower + (bound - lower) * (rank - lower_cum) / (cumulative - lower_cum)
        lower, lower_cum = bound, cumulative
    return None


def mean_of(metric):
    count = totals.get(metric + "_count", 0.0)
    if count <= 0:
        return None
    return totals.get(metric + "_sum", 0.0) / count


def to_ms(seconds):
    return None if seconds is None else int(round(seconds * 1000))


# vLLM reports KV capacity as block_size * num_gpu_blocks; kv_cache_usage_perc is a
# fraction of blocks in use, so it cannot yield a ceiling.
kv_ceiling = None
for labels in config_labels:
    block_size = label_value(labels, "block_size")
    blocks = label_value(labels, "num_gpu_blocks")
    if block_size and blocks and block_size.isdigit() and blocks.isdigit():
        kv_ceiling = int(block_size) * int(blocks)
        break

# No per-context-length throughput series exists (thoughts/shared/research/status-metrics.md
# section 4), so all three depth columns carry the measured decode rate: the mean
# time-per-output-token inverted.
tpot = mean_of("vllm:request_time_per_output_token_seconds")
tok_s = None if not tpot else round(1.0 / tpot, 3)


def env(name):
    return os.environ.get(name) or None


print(json.dumps({
    "coop_slug": env("COOP_SLUG"),
    "token": env("COOPFORGE_STATUS_TOKEN"),
    "sample_ts": datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z"),
    "uptime_ok": int(os.environ.get("UPTIME_OK") or 0),
    "ttft_p50_ms": to_ms(quantile("vllm:time_to_first_token_seconds", 0.5)),
    "ttft_p95_ms": to_ms(quantile("vllm:time_to_first_token_seconds", 0.95)),
    "tok_s_1k": tok_s,
    "tok_s_32k": tok_s,
    "tok_s_200k": tok_s,
    "kv_ceiling_tokens": kv_ceiling,
    "engine": env("ENGINE"),
    "model_sha": env("MODEL_SHA"),
}))
'
)

curl -sfS -X POST "$COOPFORGE_STATUS_PUSH_URL" \
  -H 'Content-Type: application/json' \
  -d "$PAYLOAD"
