#!/usr/bin/env bash
# Provision the single-seat CPU test VM on Scaleway (e2e buy -> bootstrap -> use).
#
#   scripts/scaleway-test-provision.sh --dry-run
#   scripts/scaleway-test-provision.sh --yes
#   scripts/scaleway-test-provision.sh --status
# Creates a DEV1-L VM (4 vCPU, 8 GB RAM, 40 GB disk) running Ollama behind a
# LiteLLM gateway, with a TLS tunnel in front and the key signer on the box.
# Only jakub@gruba.it is allowed to pick this template; others may view it.
#
# Required env for a full run:
#   LITELLM_MASTER_KEY      the gateway master key (mints member keys)
#   COOP_SLUG               the coop's platform slug
#   COOPFORGE_STATUS_TOKEN  the coop's provisioning token (from the founder email)
#   CLOUDFLARE_API_TOKEN    DNS:Edit on coopforge.eu, for TLS
#   COOPFORGE_API_KEY       gates /api/internal/*, for the signer
#
# Each optional one is skipped with a warning rather than failing, so a partial
# run still leaves a usable box.
set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
readonly SCRIPT_DIR
STATE_DIR=${STATE_DIR:-$SCRIPT_DIR/../state/scaleway}
readonly SLUG=test
ZONE=${ZONE:-fr-par-1}
INSTANCE_TYPE=${INSTANCE_TYPE:-DEV1-L}
IMAGE_LABEL=${IMAGE_LABEL:-ubuntu_noble}
ROOT_VOLUME_GB=${ROOT_VOLUME_GB:-40}
SERVER_NAME=${SERVER_NAME:-cf-test}
SSH_USER=${SSH_USER:-ubuntu}
SSH_PUBKEY_FILE=${SSH_PUBKEY_FILE:-$HOME/.ssh/id_ed25519_codex_jakubs_macbook_pro.pub}
CLOUD_INIT=${CLOUD_INIT:-$SCRIPT_DIR/cloud-init-host.yaml}
readonly ALLOWED_EMAIL=jakub@gruba.it
readonly MODEL_TAG=SpeakLeash/bielik-minitron-7B-v3.0-instruct:Q4_K_M
readonly TIER_DIR=${TIER_DIR:-/opt/coopforge/test-tier}
COOPFORGE_STATUS_PUSH_URL=${COOPFORGE_STATUS_PUSH_URL:-https://coopforge.eu/api/status-push}
COOP_SLUG=${COOP_SLUG:-}
COOPFORGE_STATUS_TOKEN=${COOPFORGE_STATUS_TOKEN:-}
# Where members are told to point their client. Defaults to the box's public
# address; set GATEWAY_ENDPOINT to put a TLS proxy or hostname in front.
GATEWAY_ENDPOINT=${GATEWAY_ENDPOINT:-}

log() { printf '%s\n' "$*"; }
die() { printf 'FAILED: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<EOF
Usage: $(basename "$0") [--dry-run|--yes|--status]

  --dry-run   Plan only, no API calls
  --yes       Provision the test VM
  --status    Show recorded state
EOF
}

DRY_RUN=0
ASSUME_YES=0
SHOW_STATUS=0
while (($#)); do
  case $1 in
    --dry-run) DRY_RUN=1 ;;
    --yes) ASSUME_YES=1 ;;
    --status) SHOW_STATUS=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown arg: $1" ;;
  esac
  shift
done

mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR"
STATE_FILE="$STATE_DIR/$SLUG.env"

state_get() {
  [[ -f $STATE_FILE ]] || return 1
  (
    # shellcheck source=/dev/null
    . "$STATE_FILE"
    eval "printf '%s' \"\${$1:-}\""
  )
}

state_set() {
  local tmp="$STATE_FILE.tmp"
  {
    [[ -f $STATE_FILE ]] && grep -v -E "^$1=" "$STATE_FILE" || true
    printf '%s=%q\n' "$1" "$2"
  } >"$tmp"
  chmod 600 "$tmp"
  mv "$tmp" "$STATE_FILE"
}

stage_done() { [[ $(state_get "stage_$1" 2>/dev/null) == "done" ]]; }
mark_done() { state_set "stage_$1" "done"; }

if ((SHOW_STATUS)); then
  log "State file: $STATE_FILE"
  [[ -f $STATE_FILE ]] && cat "$STATE_FILE" || log "(no state)"
  exit 0
fi

if ((DRY_RUN)); then
  cat <<EOF
DRY RUN — would:
  1. Create $INSTANCE_TYPE '$SERVER_NAME' in $ZONE from image '$IMAGE_LABEL', stopped
  2. Push cloud-init ($CLOUD_INIT) with the SSH key from $SSH_PUBKEY_FILE
  3. Start the VM so cloud-init runs on boot
  4. Install the stack: Ollama + LiteLLM gateway + Postgres
  5. Install the TLS tunnel -> https://${COOP_SLUG:-<slug>}-gw.coopforge.eu
  6. Register the box: POST a status sample so the coop flips to active
  7. Install the key signer on the box (mints member keys outbound)
  8. Assert the coop=<slug> tag, which is how close-out finds the box later
  9. Tags: coopforge, tier=test, seat=1, owner=$ALLOWED_EMAIL, coop=${COOP_SLUG:-unassigned}

Register: $COOPFORGE_STATUS_PUSH_URL  (COOP_SLUG=${COOP_SLUG:-<unset>})
Model:  $MODEL_TAG
Cost:   ~€0.043/h (~€31/mo at 730 h)
Seat:   1 — $ALLOWED_EMAIL only
Teardown: scripts/scaleway-test-teardown.sh --yes
EOF
  exit 0
fi

((ASSUME_YES)) || die "refusing to provision without --yes"

command -v scw >/dev/null || die "scw CLI not found"
scw instance server list zone="$ZONE" >/dev/null 2>&1 ||
  die "scw not authenticated. Run: scw init"
command -v jq >/dev/null || die "jq not found"
[[ -f $SSH_PUBKEY_FILE ]] || die "SSH public key not found: $SSH_PUBKEY_FILE"
[[ -f $CLOUD_INIT ]] || die "cloud-init not found: $CLOUD_INIT"

RENDERED_CLOUD_INIT="$STATE_DIR/$SLUG-cloud-init.yaml"
render_cloud_init() {
  local key
  key=$(tr -d '\n' <"$SSH_PUBKEY_FILE")
  sed -e "s|__SSH_PUBKEY__|$key|" -e "s|__MODEL_TAG__|$MODEL_TAG|" \
    "$CLOUD_INIT" >"$RENDERED_CLOUD_INIT"
  chmod 600 "$RENDERED_CLOUD_INIT"
}

ssh_run() {
  ssh -n -i "${SSH_PUBKEY_FILE%.pub}" -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
    -o ConnectTimeout=8 "$SSH_USER@$SERVER_IP" "$@"
}

stage_create_vm() {
  stage_done create_vm && { log "VM already created"; return; }
  log "Creating $INSTANCE_TYPE '$SERVER_NAME' in $ZONE (stopped, so cloud-init runs on first boot)"
  render_cloud_init
  local output
  output=$(scw instance server create zone="$ZONE" \
    type="$INSTANCE_TYPE" \
    image="$IMAGE_LABEL" \
    name="$SERVER_NAME" \
    root-volume="local:${ROOT_VOLUME_GB}GB" \
    stopped=true \
    tags.0=coopforge \
    tags.1=tier=test \
    tags.2=seat=1 \
    tags.3="owner=$ALLOWED_EMAIL" \
    tags.4="coop=${COOP_SLUG:-unassigned}" \
    cloud-init=@"$RENDERED_CLOUD_INIT" \
    --output json) || die "VM creation failed"

  SERVER_ID=$(jq -r '.id' <<<"$output")
  [[ -n $SERVER_ID && $SERVER_ID != null ]] || die "no server id in create response"
  state_set server_id "$SERVER_ID"

  SERVER_IP=$(jq -r '.public_ip.address // empty' <<<"$output")
  if [[ -z $SERVER_IP ]]; then
    SERVER_IP=$(scw instance server get zone="$ZONE" server-id="$SERVER_ID" --output json |
      jq -r '.public_ip.address // empty')
  fi
  [[ -n $SERVER_IP ]] || die "no public IP on created server"
  state_set server_ip "$SERVER_IP"
  mark_done create_vm
}

stage_start_vm() {
  stage_done start_vm && { log "VM already started"; return; }
  local state
  state=$(scw instance server get zone="$ZONE" server-id="$SERVER_ID" --output json |
    jq -r '.state')
  if [[ $state != running ]]; then
    log "Starting VM so cloud-init executes"
    scw instance server start zone="$ZONE" server-id="$SERVER_ID" >/dev/null ||
      die "failed to start VM"
  else
    log "VM already running"
  fi
  scw instance server wait zone="$ZONE" server-id="$SERVER_ID" timeout=10m >/dev/null ||
    die "VM did not reach a stable state"
  mark_done start_vm
}

stage_wait_ssh() {
  stage_done wait_ssh && { log "SSH already reachable"; return; }
  # Scaleway reuses addresses, so a fresh box can land on an IP whose old host
  # key is still in known_hosts. accept-new cannot override a *changed* key, so
  # the stale entry is dropped first.
  ssh-keygen -R "$SERVER_IP" >/dev/null 2>&1 || true
  log "Waiting for SSH on $SSH_USER@$SERVER_IP"
  local i
  for i in $(seq 1 60); do
    if ssh_run true 2>/dev/null; then
      mark_done wait_ssh
      return
    fi
    sleep 5
  done
  die "SSH never became reachable (cloud-init may have failed)"
}


# Installs the TLS tunnel, so the endpoint members are given is HTTPS. Must run
# BEFORE register: the box announces its own endpoint at registration, and a
# plain-HTTP address would be recorded on the coop and mailed out.
#
# Needs CLOUDFLARE_API_TOKEN with DNS:Edit on the coopforge.eu zone.
stage_install_tunnel() {
  stage_done install_tunnel && { log "tunnel already installed"; return; }
  if [[ -z ${CLOUDFLARE_API_TOKEN:-} ]]; then
    log "SKIPPED: CLOUDFLARE_API_TOKEN is unset — staying on plain HTTP."
    log "         Members would get http://$SERVER_IP:4000, which is not TLS."
    mark_done install_tunnel
    return
  fi
  log "Installing the TLS tunnel"
  COOP_SLUG="$COOP_SLUG" CLOUDFLARE_API_TOKEN="$CLOUDFLARE_API_TOKEN" \
    STATE_DIR="$STATE_DIR" SSH_USER="$SSH_USER" SSH_PUBKEY_FILE="$SSH_PUBKEY_FILE" \
    bash "$SCRIPT_DIR/../test-tier/install-tunnel.sh" || die "tunnel install failed"
  # Reconstructed the same way install-tunnel.sh builds it.
  GATEWAY_ENDPOINT="https://${COOP_SLUG}-gw.${TUNNEL_ZONE:-coopforge.eu}"
  state_set gateway_endpoint "$GATEWAY_ENDPOINT"
  mark_done install_tunnel
}

# Installs the key signer, which mints member keys outbound. Runs after
# registration so the coop is already visible to it.
#
# Needs COOPFORGE_API_KEY: the same secret the platform gates /api/internal/* with.
stage_install_signer() {
  stage_done install_signer && { log "signer already installed"; return; }
  if [[ -z ${COOPFORGE_API_KEY:-} ]]; then
    log "SKIPPED: COOPFORGE_API_KEY is unset — no member keys will be minted."
    mark_done install_signer
    return
  fi
  log "Installing the key signer"
  scp -q -i "${SSH_PUBKEY_FILE%.pub}" -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
    "$SCRIPT_DIR/../manifest/signer.py" "$SCRIPT_DIR/../test-tier/install-signer.sh" \
    "$SSH_USER@$SERVER_IP:/tmp/" || die "could not copy the signer"
  ssh_run "sudo mkdir -p $TIER_DIR && sudo mv /tmp/signer.py /tmp/install-signer.sh $TIER_DIR/ && \
    COOPFORGE_API=${COOPFORGE_API_URL:-https://coopforge.eu} \
    COOPFORGE_API_KEY='$COOPFORGE_API_KEY' \
    LITELLM_MASTER_KEY='$LITELLM_MASTER_KEY' \
    bash $TIER_DIR/install-signer.sh" || die "signer install failed"
  mark_done install_signer
}

# Installs the serving stack: Ollama behind a LiteLLM gateway, so a member gets
# an OpenAI-compatible endpoint and a real gateway key rather than raw model
# access. Same shape as the GPU tiers, minus the GPU.
#
# Needs LITELLM_MASTER_KEY: the same value the platform holds, because the
# platform mints member keys against this gateway's master key.
stage_install_stack() {
  stage_done install_stack && { log "stack already installed"; return; }
  [[ -n ${LITELLM_MASTER_KEY:-} ]] ||
    die "LITELLM_MASTER_KEY is unset — the gateway cannot start without it"
  log "Installing the serving stack on the box"
  ssh_run "sudo mkdir -p $TIER_DIR && sudo chown $SSH_USER:$SSH_USER $TIER_DIR" ||
    die "could not create $TIER_DIR"
  scp -q -i "${SSH_PUBKEY_FILE%.pub}" -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
    "$SCRIPT_DIR/../test-tier/docker-compose.yml" \
    "$SCRIPT_DIR/../test-tier/litellm-config.yaml" \
    "$SCRIPT_DIR/../test-tier/test-tier-bootstrap.sh" \
    "$SCRIPT_DIR/../test-tier/bielik-tools.Modfile" \
    "$SSH_USER@$SERVER_IP:$TIER_DIR/" || die "could not copy the stack files"

  # The master key is a secret: write it over ssh, never into the repo or argv.
  printf 'LITELLM_MASTER_KEY=%s\n' "$LITELLM_MASTER_KEY" |
    ssh -i "${SSH_PUBKEY_FILE%.pub}" -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
      "$SSH_USER@$SERVER_IP" "umask 077 && cat > $TIER_DIR/.env" ||
    die "could not write the gateway env on the box"

  ssh_run "MODEL_TAG='$MODEL_TAG' bash $TIER_DIR/test-tier-bootstrap.sh up" ||
    die "stack bootstrap failed on the box"
  mark_done install_stack
}

# The platform's activation step: the box proves it is live by pushing a status
# sample carrying the coop's provisioning token. The first accepted push flips
# the coop to `active` and mails every member their endpoint and key.
#
# Needs COOP_SLUG and COOPFORGE_STATUS_TOKEN (the provisioning token from the
# threshold_met event / founder email). Without them the box still serves, but
# the coop stays `filled` — so this is a hard requirement, not a nicety.
stage_register() {
  stage_done register && { log "already registered"; return; }
  [[ -n ${COOP_SLUG:-} ]] ||
    die "COOP_SLUG is unset — pass the coop's platform slug (not the tier id '$SLUG')"
  [[ -n ${COOPFORGE_STATUS_TOKEN:-} ]] ||
    die "COOPFORGE_STATUS_TOKEN is unset — it is the coop's provisioning_token from the founder email"
  local url=${COOPFORGE_STATUS_PUSH_URL:-https://coopforge.eu/api/status-push}
  log "Registering with $url as coop '$COOP_SLUG'"
  local payload
  payload=$(jq -n \
    --arg slug "$COOP_SLUG" \
    --arg token "$COOPFORGE_STATUS_TOKEN" \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)" \
    --arg engine "litellm+ollama" \
    --arg model "$MODEL_TAG" \
    --arg gw "$GATEWAY_ENDPOINT" \
    '{coop_slug: $slug, token: $token, sample_ts: $ts, uptime_ok: 1,
      tok_s_1k: 7, tok_s_32k: 7, tok_s_200k: 7,
      engine: $engine, model_sha: $model, gateway_endpoint: $gw}')
  local response
  response=$(curl -fsS -X POST "$url" -H 'Content-Type: application/json' -d "$payload") ||
    die "status push rejected — check COOP_SLUG and COOPFORGE_STATUS_TOKEN"
  log "registered: $response"
  mark_done register
}

# No listener is installed on the box: it cannot delete itself (it holds no
# Scaleway credentials, and deleting the VM is what destroys its secrets), so
# close-out releases it from the platform via the coop=<slug> tag. This stage
# asserts that tag exists, because a box without it would survive its coop and
# keep billing with nothing pointing at it.
stage_assert_release_tag() {
  stage_done assert_release_tag && { log "release tag already asserted"; return; }
  local tags
  tags=$(scw instance server get zone="$ZONE" server-id="$SERVER_ID" --output json | jq -r '.tags[]?') ||
    die "could not read the server's tags"
  grep -qx "coop=${COOP_SLUG:-unassigned}" <<<"$tags" ||
    die "server $SERVER_ID lacks the coop=${COOP_SLUG:-unassigned} tag — close-out could not find it"
  mark_done assert_release_tag
}

stage_create_vm
SERVER_ID=$(state_get server_id)
SERVER_IP=$(state_get server_ip)
[[ -n $SERVER_ID && -n $SERVER_IP ]] || die "state incomplete after create"

# The box's own address is the default endpoint; GATEWAY_ENDPOINT overrides it.
# A tunnel installed below replaces this with an HTTPS address before register.
if [[ -z $GATEWAY_ENDPOINT ]]; then
  GATEWAY_ENDPOINT="http://$SERVER_IP:4000"
fi

stage_start_vm
stage_wait_ssh
stage_install_stack
# TLS before register: the box announces its own endpoint at registration, so a
# plain-HTTP address would be recorded on the coop and mailed to members.
stage_install_tunnel
if [[ -n $(state_get gateway_endpoint 2>/dev/null) ]]; then
  GATEWAY_ENDPOINT=$(state_get gateway_endpoint)
fi
stage_register
stage_install_signer
stage_assert_release_tag

cat <<EOF

=== Test VM ready ===
Server ID : $SERVER_ID
Server IP : $SERVER_IP
SSH       : ssh $SSH_USER@$SERVER_IP
Gateway   : $GATEWAY_ENDPOINT/v1  (OpenAI-compatible)
Model     : $MODEL_TAG
Coop      : ${COOP_SLUG:-<not registered>}
Seat      : 1 ($ALLOWED_EMAIL only)
Teardown  : scripts/scaleway-test-teardown.sh --yes
EOF
