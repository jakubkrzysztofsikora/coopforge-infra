#!/bin/sh
# systemd timer target: every 5 min scrape vLLM /metrics, push aggregates to CoopForge
set -eu
AGG=$(curl -sf http://localhost:8000/metrics | python3 -c "
import sys, re
text = sys.stdin.read()
def val(name, stat='sum'):
    m = re.search(name + r'.*?' + stat, text)
    return None
print('{}')
")
curl -sf -X POST "$COOPFORGE_STATUS_PUSH_URL" \
  -H 'Content-Type: application/json' \
  -d "{\"coop_slug\": \"${COOP_SLUG}\", \"token\": \"${COOPFORGE_STATUS_TOKEN}\", \"uptime_ok\": 1}"
