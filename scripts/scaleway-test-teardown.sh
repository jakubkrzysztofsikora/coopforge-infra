#!/usr/bin/env bash
# Tear down the single-seat CPU test VM created by scaleway-test-provision.sh.
#
#   scripts/scaleway-test-teardown.sh          # dry-run: show what would go
#   scripts/scaleway-test-teardown.sh --yes    # delete server + volume + IP
#
# Deleting the server releases its local root volume; the detached flexible IP
# and any leftover volumes are removed explicitly so nothing keeps billing.
set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
readonly SCRIPT_DIR
STATE_DIR=${STATE_DIR:-$SCRIPT_DIR/../state/scaleway}
readonly SLUG=test
ZONE=${ZONE:-fr-par-1}

log() { printf '%s\n' "$*"; }
die() { printf 'FAILED: %s\n' "$*" >&2; exit 1; }

ASSUME_YES=0
while (($#)); do
  case $1 in
    --yes) ASSUME_YES=1 ;;
    -h|--help) echo "Usage: $(basename "$0") [--yes]"; exit 0 ;;
    *) die "unknown arg: $1" ;;
  esac
  shift
done

STATE_FILE="$STATE_DIR/$SLUG.env"
[[ -f $STATE_FILE ]] || die "no state file at $STATE_FILE — nothing to tear down"

# shellcheck source=/dev/null
. "$STATE_FILE"
SERVER_ID=${server_id:-}
SERVER_IP=${server_ip:-}
[[ -n $SERVER_ID ]] || die "server_id missing from $STATE_FILE"

# Only the server's own resources: match on the id, not on an address that the
# API may already have detached.
VOLUME_IDS=$(scw instance volume list zone="$ZONE" --output json |
  jq -r --arg s "$SERVER_ID" '.[] | select(.server.id == $s) | .id' || true)
IP_IDS=$(scw instance ip list zone="$ZONE" --output json |
  jq -r --arg a "$SERVER_IP" '.[] | select(.address == $a) | .id' || true)

if ((!ASSUME_YES)); then
  log "DRY RUN — would delete:"
  log "  server : $SERVER_ID  ($SERVER_IP)"
  [[ -n $VOLUME_IDS ]] && log "  volumes: $(tr '\n' ' ' <<<"$VOLUME_IDS")"
  [[ -n $IP_IDS ]] && log "  ips    : $(tr '\n' ' ' <<<"$IP_IDS")"
  log "  state  : $STATE_FILE"
  log ""
  log "Run with --yes to execute."
  exit 0
fi

log "Stopping server $SERVER_ID"
scw instance server stop zone="$ZONE" server-id="$SERVER_ID" >/dev/null 2>&1 || true
scw instance server wait zone="$ZONE" server-id="$SERVER_ID" timeout=5m >/dev/null 2>&1 || true

log "Deleting server $SERVER_ID"
# A server can still report in-use for a few seconds after poweroff.
for attempt in 1 2 3 4 5; do
  if scw instance server delete zone="$ZONE" server-id="$SERVER_ID" >/dev/null 2>&1; then
    break
  fi
  [[ $attempt == 5 ]] && die "server delete failed after 5 attempts"
  sleep 10
done

# The root volume goes with the server; any block volume left behind is deleted
# here. A volume already gone returns "not found", which is the desired state.
for vol in $VOLUME_IDS; do
  log "Deleting volume $vol"
  scw instance volume delete zone="$ZONE" volume-id="$vol" >/dev/null 2>&1 ||
    log "  volume $vol already gone"
done

# `scw instance ip delete` takes the id as a positional argument, not `ip-id=`.
for ip in $IP_IDS; do
  log "Deleting IP $ip"
  scw instance ip delete "$ip" zone="$ZONE" >/dev/null 2>&1 ||
    log "  ip $ip already gone"
done

# The tunnel and its DNS record are per-coop and would otherwise leak: an orphan
# tunnel keeps a route alive, and an orphan CNAME points at nothing.
if [[ -n ${COOP_SLUG:-} ]]; then
  TUNNEL_NAME="coopforge-$COOP_SLUG"
  if cloudflared tunnel list 2>/dev/null | awk '{print $2}' | grep -qx "$TUNNEL_NAME"; then
    log "Deleting tunnel $TUNNEL_NAME"
    cloudflared tunnel delete "$TUNNEL_NAME" >/dev/null 2>&1 ||
      log "  tunnel delete failed (delete it by hand: cloudflared tunnel delete $TUNNEL_NAME)"
  fi
  if [[ -n ${CLOUDFLARE_API_TOKEN:-} ]]; then
    HOST="${COOP_SLUG}-gw.${TUNNEL_ZONE:-coopforge.eu}"
    ZONE_ID=$(curl -fsS "https://api.cloudflare.com/client/v4/zones?name=${TUNNEL_ZONE:-coopforge.eu}" \
      -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" | jq -r '.result[0].id // empty')
    if [[ -n $ZONE_ID ]]; then
      REC=$(curl -fsS "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?name=$HOST" \
        -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" | jq -r '.result[0].id // empty')
      if [[ -n $REC ]]; then
        log "Deleting DNS record $HOST"
        curl -fsS -X DELETE "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$REC" \
          -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" >/dev/null || log "  DNS delete failed"
      fi
    fi
  else
    log "CLOUDFLARE_API_TOKEN unset — delete the CNAME for ${COOP_SLUG}-gw.* by hand"
  fi
fi

rm -f "$STATE_FILE" "$STATE_DIR/$SLUG-cloud-init.yaml"
log "Teardown complete"
