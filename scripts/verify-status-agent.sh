#!/usr/bin/env bash
# Drives status-agent.sh against fixtures/vllm-metrics.txt over HTTP and asserts the
# payload it POSTs. Degraded fixtures prove missing series become null, not a crash.
set -Eeuo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
WEB=${COOPFORGE_WEB:-$ROOT/../coopforge/web}
ROUTE=$WEB/app/api/status-push/route.ts
WORK=$(mktemp -d)
SERVER=
trap 'if [ -n "$SERVER" ]; then kill "$SERVER" 2>/dev/null || true; fi; rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; }
check() { if [ "$2" = "$3" ]; then ok "$1 = $3"; else bad "$1 (got $2, want $3)"; fi; }
field() {
  python3 -c 'import json, sys; print(json.dumps(json.load(open(sys.argv[1])).get(sys.argv[2])))' "$1" "$2"
}

cat >"$WORK/serve.py" <<'PY'
import http.server, json, pathlib, sys

root = pathlib.Path(sys.argv[1])
port = int(sys.argv[2])


class Handler(http.server.BaseHTTPRequestHandler):
    def reply(self, code, body, ctype):
        data = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == "/health":
            return self.reply(200, "ok", "text/plain")
        path = root / self.path.lstrip("/")
        if not path.is_file():
            return self.reply(404, "not found", "text/plain")
        return self.reply(200, path.read_text(), "text/plain")

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        name = self.path.lstrip("/").replace("/", "-")
        (root / f"body-{name}.json").write_bytes(body)
        (root / f"headers-{name}.txt").write_text(
            f"content-type: {self.headers.get('Content-Type')}\n"
        )
        return self.reply(200, json.dumps({"ok": True}), "application/json")

    def log_message(self, *args):
        pass


http.server.HTTPServer(("127.0.0.1", port), Handler).serve_forever()
PY

PORT=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')
python3 "$WORK/serve.py" "$WORK" "$PORT" &
SERVER=$!
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  curl -sf "http://127.0.0.1:$PORT/health" >/dev/null 2>&1 && break
  sleep 0.3
done

cp "$ROOT/fixtures/vllm-metrics.txt" "$WORK/metrics-full.txt"
grep -v '^vllm:time_to_first_token_seconds' "$ROOT/fixtures/vllm-metrics.txt" >"$WORK/metrics-no-ttft.txt"
grep -v '^vllm:request_time_per_output_token_seconds' "$ROOT/fixtures/vllm-metrics.txt" >"$WORK/metrics-no-tpot.txt"
grep -v '^vllm:cache_config_info' "$ROOT/fixtures/vllm-metrics.txt" >"$WORK/metrics-no-kv.txt"
: >"$WORK/metrics-empty.txt"

run_agent() {
  local metrics=$1 case_name=$2
  COOPFORGE_STATUS_PUSH_URL="http://127.0.0.1:$PORT/push/$case_name" \
    COOPFORGE_METRICS_URL="http://127.0.0.1:$PORT/$metrics" \
    COOPFORGE_HEALTH_URL="http://127.0.0.1:$PORT/health" \
    COOPFORGE_VLLM_ENV="$ROOT/fixtures/vllm.env" \
    COOP_SLUG=everyday-96g \
    COOPFORGE_STATUS_TOKEN=push-token-fixture \
    sh "$ROOT/status-agent.sh" >/dev/null
}

if run_agent metrics-full.txt full; then ok "full scrape exits 0"; else bad "full scrape exits 0"; fi
BODY=$WORK/body-push-full.json

check "coop_slug" "$(field "$BODY" coop_slug)" '"everyday-96g"'
check "token" "$(field "$BODY" token)" '"push-token-fixture"'
check "uptime_ok" "$(field "$BODY" uptime_ok)" '1'
check "ttft_p50_ms" "$(field "$BODY" ttft_p50_ms)" '35000'
check "ttft_p95_ms" "$(field "$BODY" ttft_p95_ms)" '150000'
check "tok_s_1k" "$(field "$BODY" tok_s_1k)" '96.739'
check "tok_s_32k" "$(field "$BODY" tok_s_32k)" '96.739'
check "tok_s_200k" "$(field "$BODY" tok_s_200k)" '96.739'
check "kv_ceiling_tokens" "$(field "$BODY" kv_ceiling_tokens)" '13632'
check "engine" "$(field "$BODY" engine)" '"vllm/vllm-openai:v0.31.0"'
check "model_sha" "$(field "$BODY" model_sha)" '"95a723d08a9490559dae23d0cff1d9466213d989"'

if field "$BODY" sample_ts | grep -Eq '^"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}Z"$'; then
  ok "sample_ts is ISO-8601 UTC"
else
  bad "sample_ts is ISO-8601 UTC ($(field "$BODY" sample_ts))"
fi

check "POST content-type" "$(cat "$WORK/headers-push-full.txt")" 'content-type: application/json'

if [ -f "$ROUTE" ]; then
  if python3 - "$ROUTE" "$BODY" <<'PY'
import json, re, sys

block = re.search(r"interface StatusPushBody \{(.*?)\}", open(sys.argv[1]).read(), re.S).group(1)
keys = sorted(re.findall(r"^\s*([A-Za-z_][A-Za-z0-9_]*)\??:", block, re.M))
sys.exit(0 if keys == sorted(json.load(open(sys.argv[2]))) else 1)
PY
  then ok "payload keys match StatusPushBody"; else bad "payload keys match StatusPushBody"; fi
else
  printf 'skip payload key parity (%s not found)\n' "$ROUTE"
fi

if run_agent metrics-no-ttft.txt no-ttft; then ok "missing TTFT histogram exits 0"; else bad "missing TTFT histogram exits 0"; fi
check "ttft_p50_ms without histogram" "$(field "$WORK/body-push-no-ttft.json" ttft_p50_ms)" 'null'
check "ttft_p95_ms without histogram" "$(field "$WORK/body-push-no-ttft.json" ttft_p95_ms)" 'null'
check "kv_ceiling_tokens without histogram" "$(field "$WORK/body-push-no-ttft.json" kv_ceiling_tokens)" '13632'

if run_agent metrics-no-tpot.txt no-tpot; then ok "missing TPOT histogram exits 0"; else bad "missing TPOT histogram exits 0"; fi
check "tok_s_1k without TPOT" "$(field "$WORK/body-push-no-tpot.json" tok_s_1k)" 'null'
check "tok_s_200k without TPOT" "$(field "$WORK/body-push-no-tpot.json" tok_s_200k)" 'null'
check "ttft_p50_ms without TPOT" "$(field "$WORK/body-push-no-tpot.json" ttft_p50_ms)" '35000'

if run_agent metrics-no-kv.txt no-kv; then ok "missing cache_config_info exits 0"; else bad "missing cache_config_info exits 0"; fi
check "kv_ceiling_tokens without cache_config_info" "$(field "$WORK/body-push-no-kv.json" kv_ceiling_tokens)" 'null'
check "tok_s_1k without cache_config_info" "$(field "$WORK/body-push-no-kv.json" tok_s_1k)" '96.739'

if run_agent metrics-empty.txt empty; then ok "empty metrics body exits 0"; else bad "empty metrics body exits 0"; fi
check "uptime_ok with empty metrics" "$(field "$WORK/body-push-empty.json" uptime_ok)" '1'
check "ttft_p50_ms with empty metrics" "$(field "$WORK/body-push-empty.json" ttft_p50_ms)" 'null'
check "kv_ceiling_tokens with empty metrics" "$(field "$WORK/body-push-empty.json" kv_ceiling_tokens)" 'null'

if COOPFORGE_STATUS_PUSH_URL="http://127.0.0.1:$PORT/push/no-creds" sh "$ROOT/status-agent.sh" >/dev/null 2>&1; then
  bad "missing credentials abort"
else
  ok "missing credentials abort"
fi
if [ -f "$WORK/body-push-no-creds.json" ]; then bad "missing credentials send nothing"; else ok "missing credentials send nothing"; fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
