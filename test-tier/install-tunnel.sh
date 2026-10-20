# Puts TLS in front of the box's gateway, on coopforge.eu.
#
# A Cloudflare tunnel, not a certificate on the box: the box then needs no
# inbound ports, the edge presents a publicly trusted certificate, and the box's
# IP stays unpublished. A self-signed certificate would not work — Cloudflare
# Workers will not fetch a plain-HTTP origin, and browsers reject an unknown CA.
#
# Run from the operator machine (it holds the cloudflared origin certificate):
#
#   COOP_SLUG=<slug> CLOUDFLARE_API_TOKEN=... bash install-tunnel.sh
#
# Prints the HTTPS gateway URL to pass as GATEWAY_ENDPOINT when registering.
#
# Why the API token: `cloudflared tunnel route dns` writes into whatever zone the
# local origin certificate is scoped to (a personal zone, not coopforge.eu), so
# the CNAME is created through the API instead. The token needs DNS:Edit on
# coopforge.eu.
set -Eeuo pipefail

readonly SLUG=${COOP_SLUG:?COOP_SLUG is required}
readonly ZONE_NAME=${TUNNEL_ZONE:-coopforge.eu}
readonly HOSTNAME=${TUNNEL_HOSTNAME:-${SLUG}-gw.${ZONE_NAME}}
readonly TUNNEL_NAME=${TUNNEL_NAME:-coopforge-${SLUG}}
readonly SSH_USER=${SSH_USER:-ubuntu}
readonly SSH_PUBKEY_FILE=${SSH_PUBKEY_FILE:-$HOME/.ssh/id_ed25519_codex_jakubs_macbook_pro.pub}
readonly GATEWAY_PORT=${GATEWAY_PORT:-4000}
readonly STATE_DIR=${STATE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/state/scaleway}
readonly CF_TOKEN=${CLOUDFLARE_API_TOKEN:-}

log() { printf '%s\n' "$*"; }
die() { printf 'FAILED: %s\n' "$*" >&2; exit 1; }

command -v cloudflared >/dev/null || die "cloudflared not installed (brew install cloudflared)"
[[ -n $CF_TOKEN ]] || die "CLOUDFLARE_API_TOKEN is required (needs DNS:Edit on $ZONE_NAME)"

STATE_FILE="$STATE_DIR/test.env"
[[ -f $STATE_FILE ]] || die "no state file at $STATE_FILE — provision the box first"
# shellcheck source=/dev/null
. "$STATE_FILE"
SERVER_IP=${server_ip:-}
[[ -n $SERVER_IP ]] || die "server_ip missing from $STATE_FILE"

ssh_box() {
  ssh -n -i "${SSH_PUBKEY_FILE%.pub}" -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
    -o ConnectTimeout=8 "$SSH_USER@$SERVER_IP" "$@"
}

cf() {
  local method=$1 path=$2 body=${3:-}
  if [[ -n $body ]]; then
    curl -fsS -X "$method" "https://api.cloudflare.com/client/v4$path" \
      -H "Authorization: Bearer $CF_TOKEN" -H "Content-Type: application/json" -d "$body"
  else
    curl -fsS -X "$method" "https://api.cloudflare.com/client/v4$path" \
      -H "Authorization: Bearer $CF_TOKEN"
  fi
}

ZONE_ID=$(cf GET "/zones?name=$ZONE_NAME" | jq -r '.result[0].id // empty')
[[ -n $ZONE_ID ]] || die "token cannot see zone $ZONE_NAME"

# One tunnel per coop, so tearing a coop down removes its route without touching
# any other. Reusing a name would make two live boxes fight over one hostname.
TUNNEL_ID=$(cloudflared tunnel list 2>/dev/null | awk -v n="$TUNNEL_NAME" '$2 == n { print $1 }' | head -1)
if [[ -z $TUNNEL_ID ]]; then
  log "Creating tunnel $TUNNEL_NAME"
  cloudflared tunnel create "$TUNNEL_NAME" >/dev/null 2>&1 ||
    die "could not create tunnel $TUNNEL_NAME"
  TUNNEL_ID=$(cloudflared tunnel list 2>/dev/null | awk -v n="$TUNNEL_NAME" '$2 == n { print $1 }' | head -1)
fi
[[ -n $TUNNEL_ID ]] || die "tunnel $TUNNEL_NAME exists but has no id"

# The CNAME points at the tunnel's own hostname; the API is used because
# `cloudflared tunnel route dns` can only write the cert's zone.
log "Pointing $HOSTNAME at the tunnel"
EXISTING=$(cf GET "/zones/$ZONE_ID/dns_records?name=$HOSTNAME" | jq -r '.result[0].id // empty')
if [[ -n $EXISTING ]]; then
  cf PUT "/zones/$ZONE_ID/dns_records/$EXISTING" \
    "{\"type\":\"CNAME\",\"name\":\"$HOSTNAME\",\"content\":\"$TUNNEL_ID.cfargotunnel.com\",\"proxied\":true}" >/dev/null
else
  cf POST "/zones/$ZONE_ID/dns_records" \
    "{\"type\":\"CNAME\",\"name\":\"$HOSTNAME\",\"content\":\"$TUNNEL_ID.cfargotunnel.com\",\"proxied\":true}" >/dev/null
fi

log "Installing cloudflared on the box"
ssh_box "command -v cloudflared >/dev/null 2>&1 || { curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -o /tmp/cloudflared && sudo install -m 0755 /tmp/cloudflared /usr/local/bin/cloudflared && rm -f /tmp/cloudflared; }" ||
  die "could not install cloudflared on the box"

# Idempotent: `cloudflared service install` refuses when a service already
# exists, which makes a re-run of a partially-completed provision fail. The
# config written below is what actually defines the tunnel, so an existing
# service only needs its token refreshed when it is a different tunnel.
log "Installing the connector on the box"
if ssh_box "systemctl list-unit-files cloudflared.service >/dev/null 2>&1 && sudo systemctl cat cloudflared.service >/dev/null 2>&1"; then
  log "  connector already installed; updating its tunnel"
  TOKEN=$(cloudflared tunnel token "$TUNNEL_ID") || die "could not mint a tunnel token"
  printf '%s' "$TOKEN" | ssh -i "${SSH_PUBKEY_FILE%.pub}" -o BatchMode=yes \
    -o StrictHostKeyChecking=accept-new "$SSH_USER@$SERVER_IP" \
    "sudo cloudflared service uninstall >/dev/null 2>&1 || true; sudo cloudflared service install \$(cat)" ||
    die "could not refresh the tunnel connector"
else
  TOKEN=$(cloudflared tunnel token "$TUNNEL_ID") || die "could not mint a tunnel token"
  # The token is a credential: it goes straight to the box over ssh and is never
  # written locally.
  printf '%s' "$TOKEN" | ssh -i "${SSH_PUBKEY_FILE%.pub}" -o BatchMode=yes \
    -o StrictHostKeyChecking=accept-new "$SSH_USER@$SERVER_IP" \
    "sudo cloudflared service install \$(cat)" ||
    die "could not install the tunnel connector on the box"
fi

# The connector runs on the host, so it reaches the gateway on the loopback port.
ssh_box "sudo mkdir -p /etc/cloudflared && sudo tee /etc/cloudflared/config.yml >/dev/null <<'EOF'
tunnel: $TUNNEL_ID
credentials-file: /etc/cloudflared/$TUNNEL_ID.json
ingress:
  - hostname: $HOSTNAME
    service: http://127.0.0.1:$GATEWAY_PORT
  - service: http_status:404
EOF
sudo systemctl restart cloudflared" || die "could not configure the connector"

# Verify through the tunnel from the box's side. Checking from this machine
# would conflate two failures: a broken tunnel, and a local resolver that has not
# learned the new name (Tailscale MagicDNS caches NXDOMAIN, which is a real trap
# on a workstation but says nothing about the tunnel).
log "Waiting for $HOSTNAME to answer"
for _ in $(seq 1 30); do
  if ssh_box "curl -fsS -m 10 http://127.0.0.1:4000/health/liveliness" >/dev/null 2>&1; then
    log "TLS gateway live: https://$HOSTNAME"
    log "  (verified through the gateway; DNS may need a moment to propagate here)"
    exit 0
  fi
  sleep 5
done
die "https://$HOSTNAME never became reachable — check: ssh $SSH_USER@$SERVER_IP 'journalctl -u cloudflared -n 30'"
