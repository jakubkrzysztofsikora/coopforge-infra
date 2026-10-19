#!/usr/bin/env bash
# Order, install and bootstrap a CoopForge Hetzner tier.
#
#   scripts/hetzner-provision.sh --dry-run seed-24g
#   scripts/hetzner-provision.sh --status  seed-24g
#   ROBOT_USER=... ROBOT_WS_PASSWORD=... scripts/hetzner-provision.sh --yes seed-24g
#
# Stages run in order: ORDER -> INSTALL -> BOOTSTRAP -> MODEL_PULL -> REGISTER.
# Completed stages are recorded in state/hetzner/<tier>.env, so a re-run resumes
# instead of re-ordering. Every failure names the stage it happened in.
set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
readonly SCRIPT_DIR
# shellcheck source=scripts/hetzner-lib.sh
. "$SCRIPT_DIR/hetzner-lib.sh"
readonly SSH_KEY=${SSH_KEY:-$HOME/.ssh/id_ed25519.pub}
readonly IMAGE=${IMAGE:-Ubuntu-2404-noble-amd64-base.tar.gz}
readonly ORDER_TIMEOUT=${ORDER_TIMEOUT:-1800}
readonly INSTALL_TIMEOUT=${INSTALL_TIMEOUT:-1800}
readonly MODEL_TIMEOUT=${MODEL_TIMEOUT:-3600}
readonly REMOTE_BOOTSTRAP=/opt/coopforge-node-bootstrap.sh

STAGE=START
DRY_RUN=0
ASSUME_YES=0
SHOW_STATUS=0
PRODUCT_ID_OVERRIDE=
LOCATION=${HETZNER_LOCATION:-}
SLUG=
FINGERPRINT=
SERVER_NUMBER=
SERVER_IP=
SSH_PORT=22

usage() {
  cat <<'EOF'
usage: hetzner-provision.sh [options] <tier-id>

  --dry-run        print the ordered plan and exit; no network, no state
  --status         print what has already run for this tier
  --yes            confirm the paid monthly order (required to reach ORDER)
  --product-id ID  override the product id returned by GET /order/server/product
  -h, --help       this text

Environment:
  ROBOT_USER, ROBOT_WS_PASSWORD   Robot web-service credentials (ORDER onward)
  HETZNER_LOCATION                preferred location, e.g. FSN1 or NBG1
  SSH_KEY                         public key registered in Robot and installed
  IMAGE                           installimage image name
  COOPFORGE_STATUS_PUSH_URL, COOPFORGE_STATUS_TOKEN
                                  status push endpoint and shared token
  COOP_SLUG                       the coop's platform slug (coops.slug), not the
                                  tier id; required once the COOPFORGE_STATUS_* pair is set
  ROBOT_API, STATE_DIR, ORDER_TIMEOUT, INSTALL_TIMEOUT, MODEL_TIMEOUT, POLL_INTERVAL

Exit codes: 2 usage, 10 ORDER, 11 INSTALL, 12 BOOTSTRAP, 13 MODEL_PULL, 14 REGISTER.
EOF
}

trap 'code=$?; case $code in 0 | 2 | 10 | 11 | 12 | 13 | 14) ;; *) printf "FAILED stage=%s: unexpected exit %s\n" "$STAGE" "$code" >&2 ;; esac' EXIT

while (($#)); do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --status) SHOW_STATUS=1 ;;
    --yes) ASSUME_YES=1 ;;
    --product-id)
      PRODUCT_ID_OVERRIDE=${2:-}
      [[ -n $PRODUCT_ID_OVERRIDE ]] || die 2 "--product-id needs a value"
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    -*) die 2 "unknown option: $1" ;;
    *)
      [[ -z $SLUG ]] || die 2 "only one tier id is accepted (got '$SLUG' and '$1')"
      SLUG=$1
      ;;
  esac
  shift
done

[[ -n $SLUG ]] || {
  usage >&2
  exit 2
}

# Tiers whose manifest model cannot load on their own GPU. seed-24g declares INT4
# but points at the BF16 Qwen3-Coder-30B-A3B-Instruct (~61 GB) on a 24 GB card, and
# no first-party INT4 artifact exists — refusing here beats downloading 61 GB to OOM.
model_blocker() {
  case "$SLUG" in
    seed-24g)
      printf 'blocker B1: %s is BF16 (~61 GB) and does not fit %s GB of %s; no first-party INT4 artifact exists. Fix repo/sha in manifest/tiers.json first.\n' \
        "$(fact .repo)" "$(fact .vram_gb)" "$(fact .instance)"
      ;;
  esac
}

ensure_key() {
  local pub existing
  pub=$(awk '{print $1" "$2}' "$SSH_KEY") || die 10 "cannot read SSH_KEY=$SSH_KEY"
  existing=$(api GET /key | jq -r --arg k "$pub" \
    '.[] | select(((.key.public_key.data // "") | split(" ") | .[0:2] | join(" ")) == $k) | .key.fingerprint' |
    head -n1)
  if [[ -n $existing && $existing != null ]]; then
    FINGERPRINT=$existing
  else
    FINGERPRINT=$(api POST /key \
      --data-urlencode "name=coopforge-$SLUG" \
      --data-urlencode "public_key=$(cat "$SSH_KEY")" |
      jq -r '.key.fingerprint // empty')
    [[ -n $FINGERPRINT ]] || die 10 "Robot returned no fingerprint for $SSH_KEY"
  fi
  log "ssh key: $FINGERPRINT ($SSH_KEY)"
}

wait_for_server_number() {
  local txn=$1 deadline=$((SECONDS + ORDER_TIMEOUT)) number
  while ((SECONDS < deadline)); do
    number=$(api GET "/order/server/transaction/$txn" | jq -r '.transaction.server_number // empty')
    if [[ -n $number ]]; then
      printf '%s' "$number"
      return 0
    fi
    sleep "$POLL_INTERVAL"
  done
  return 1
}

wait_for_ready() {
  local deadline=$((SECONDS + ORDER_TIMEOUT)) status
  while ((SECONDS < deadline)); do
    status=$(api GET "/server/$SERVER_NUMBER" | jq -r '.server.status // empty')
    [[ $status == ready ]] && return 0
    sleep "$POLL_INTERVAL"
  done
  return 1
}

wait_ssh() {
  local deadline=$((SECONDS + INSTALL_TIMEOUT)) port
  while ((SECONDS < deadline)); do
    for port in 22 222; do
      SSH_PORT=$port
      if ssh_run true 2>/dev/null; then
        return 0
      fi
    done
    sleep 10
  done
  return 1
}

stage_order() {
  STAGE=ORDER
  local existing
  existing=$(state_get server_number 2>/dev/null) || existing=
  if [[ -n $existing ]]; then
    SERVER_NUMBER=$existing
    SERVER_IP=$(state_get server_ip)
    log "ORDER already done: server $SERVER_NUMBER ($SERVER_IP)"
    return 0
  fi

  ((ASSUME_YES)) || die 10 "refusing to place a paid monthly order without --yes (nothing was ordered)"

  require_creds 10
  ensure_key

  local products sel product_id price_net price_setup_net
  products=$(api GET /order/server/product) ||
    die 10 "GET /order/server/product failed — check the credentials and enable Web Service Ordering in Robot (Settings -> Web Service Settings)"
  mkdir -p "$STATE_DIR"
  printf '%s' "$products" >"$STATE_DIR/$SLUG.products.json"

  sel=$(jq -c --arg n "$(fact .instance)" --arg loc "$LOCATION" '
    def prod($p): ($p.product // $p);
    [ .[] | . as $p | ((.prices // [{}]) | .[])
      | { product_id: ((prod($p).id // prod($p).name // "") | tostring),
          location: (.location // $p.location // ""),
          price_net: (.price.net // $p.price.net // ""),
          price_setup_net: (.price_setup.net // $p.price_setup.net // "") } ]
    | [ .[] | select((.product_id | test($n; "i")))
        | select($loc == "" or ((.location // "") | test($loc; "i"))) ]
    | (.[0] // {})' <<<"$products")

  product_id=$(jq -r '.product_id // ""' <<<"$sel")
  price_net=$(jq -r '.price_net // ""' <<<"$sel")
  price_setup_net=$(jq -r '.price_setup_net // ""' <<<"$sel")

  if [[ -z $PRODUCT_ID_OVERRIDE ]]; then
    [[ -n $product_id ]] ||
      die 10 "$(fact .instance) is not orderable right now (stock) or the product name changed; /order/server/product listed: $(jq -r '[.[] | (.product.name // .product.id // "?")] | join(", ")' <<<"$products")"
  else
    product_id=$PRODUCT_ID_OVERRIDE
  fi

  log "ordering $(fact .instance) product_id=$product_id${price_net:+ price ${price_net} net/month}${price_setup_net:+ setup ${price_setup_net} net}${LOCATION:+ location $LOCATION}"

  local txn
  txn=$(api POST /order/server/transaction \
    --data-urlencode "product_id=$product_id" \
    --data-urlencode "authorized_key[]=$FINGERPRINT" \
    --data-urlencode "addon[]=primary_ipv4" \
    ${LOCATION:+--data-urlencode "location=$LOCATION"}) ||
    die 10 "POST /order/server/transaction failed — nothing was ordered"

  local transaction_id
  transaction_id=$(jq -r '.transaction.id // empty' <<<"$txn")
  [[ -n $transaction_id ]] || die 10 "Robot returned no transaction id: $txn"
  state_set transaction_id "$transaction_id"

  SERVER_NUMBER=$(jq -r '.transaction.server_number // empty' <<<"$txn")
  [[ -n $SERVER_NUMBER ]] || SERVER_NUMBER=$(wait_for_server_number "$transaction_id") ||
    die 10 "no server number for transaction $transaction_id within ${ORDER_TIMEOUT}s"

  state_set server_number "$SERVER_NUMBER"
  state_set price_net "$price_net"
  state_set price_setup_net "$price_setup_net"
  state_set product_id "$product_id"

  wait_for_ready || die 10 "server $SERVER_NUMBER did not reach status=ready within ${ORDER_TIMEOUT}s"
  SERVER_IP=$(api GET "/server/$SERVER_NUMBER" | jq -r '.server.server_ip // empty')
  [[ -n $SERVER_IP ]] ||
    die 10 "server $SERVER_NUMBER has no IPv4 address — order with the primary_ipv4 addon so the install can be driven over SSH"
  state_set server_ip "$SERVER_IP"
  mark_done order
  log "ordered: server $SERVER_NUMBER at $SERVER_IP"
}

stage_install() {
  STAGE=INSTALL
  if stage_done install; then
    SSH_PORT=$(state_get ssh_port || true)
    log "INSTALL already done"
    return 0
  fi

  require_creds 11

  local rescue
  rescue=$(api POST "/boot/$SERVER_NUMBER/rescue" -d 'os=linux' --data-urlencode "authorized_key[]=$FINGERPRINT") ||
    die 11 "rescue activation failed"
  state_set rescue_password "$(jq -r '.rescue.password // empty' <<<"$rescue")"
  log "rescue system activated (one boot, 60-minute window)"

  api POST "/reset/$SERVER_NUMBER" -d 'type=hw' >/dev/null || die 11 "hardware reset failed"

  wait_ssh || die 11 "no SSH in the rescue system within ${INSTALL_TIMEOUT}s"
  state_set ssh_port "$SSH_PORT"
  log "rescue SSH up on port $SSH_PORT"

  local images
  images=$(ssh_run 'ls -1 "$(dirname "$(readlink -f "$(command -v installimage)")")/../images/"') ||
    die 11 "could not list the installimage image directory"
  grep -qx "$IMAGE" <<<"$images" ||
    die 11 "image '$IMAGE' is not on the rescue system; available: $(tr '\n' ' ' <<<"$images")"

  ssh_run 'mdadm --stop /dev/md* 2>/dev/null; wipefs -fa /dev/nvme0n1 /dev/nvme1n1' ||
    die 11 "could not clear the old RAID metadata"

  ssh_run_stdin 'cat >/root/install.conf' <<EOF || die 11 "could not write /root/install.conf"
DRIVE1 /dev/nvme0n1
DRIVE2 /dev/nvme1n1
SWRAID 1
SWRAIDLEVEL 1
BOOTLOADER grub
HOSTNAME coopforge-$SLUG
PART /boot/efi esp 256M
PART /boot ext4 1G
PART /     ext4 all
IMAGE /root/images/$IMAGE
EOF

  ssh_run 'installimage -a -c /root/install.conf' || {
    ssh_run 'tail -n 40 /root/debug.txt' || true
    die 11 "installimage failed — /root/debug.txt on the server has the detail"
  }

  ssh_run 'systemctl reboot' || true
  log "installed; rebooting into the installed system"
  wait_ssh || die 11 "no SSH in the installed system within ${INSTALL_TIMEOUT}s"
  state_set ssh_port "$SSH_PORT"
  mark_done install
  log "INSTALL done: Ubuntu 24.04 on 2x NVMe RAID1, SSH port $SSH_PORT"
}

run_node_stage() {
  local node_stage=$1 provision_stage=$2 code=$3
  STAGE=$provision_stage
  if stage_done "$provision_stage"; then
    log "$provision_stage already done"
    return 0
  fi
  local sha env_prefix route
  sha=$(fact .sha)
  if [[ $sha == null ]]; then sha=; fi
  route=$(fact .route)
  [[ -n $route && $route != null ]] ||
    die "$code" "tier $SLUG has no route in manifest/tiers.json; the engine would be served as '$route'"
  env_prefix="TIER='$SLUG' REPO='$(fact .repo)' SHA='$sha' ENGINE='$(fact .engine)'"
  env_prefix+=" SERVED_MODEL_NAME='$route' SERVED_CONTEXT='$(fact .served_context)'"
  env_prefix+=" TP_SIZE='$(fact .tp_size)' MODEL_TIMEOUT='$MODEL_TIMEOUT'"
  env_prefix+=" COOPFORGE_STATUS_PUSH_URL='${COOPFORGE_STATUS_PUSH_URL:-}' COOPFORGE_STATUS_TOKEN='${COOPFORGE_STATUS_TOKEN:-}'"
  env_prefix+=" COOP_SLUG='${COOP_SLUG:-}'"
  ssh_run "env $env_prefix bash $REMOTE_BOOTSTRAP $node_stage" ||
    die "$code" "$node_stage failed on the server"
  mark_done "$provision_stage"
}

stage_bootstrap() {
  STAGE=BOOTSTRAP
  if stage_done bootstrap; then
    log "BOOTSTRAP already done"
    return 0
  fi
  scp_to "$SCRIPT_DIR/hetzner-node-bootstrap.sh" "$REMOTE_BOOTSTRAP" || die 12 "could not copy the node script"
  run_node_stage bootstrap bootstrap 12
  scp_to "$HETZNER_ROOT/systemd/vllm.service" /opt/coopforge/vllm.service ||
    die 12 "could not copy the vLLM unit"
}

stage_model_pull() {
  STAGE=MODEL_PULL
  local blocker
  blocker=$(model_blocker)
  if [[ -n $blocker ]]; then
    die 13 "$blocker"
  fi
  run_node_stage model-pull model_pull 13
}

stage_register() {
  STAGE=REGISTER
  if stage_done register; then
    log "REGISTER already done"
    return 0
  fi
  if [[ -n ${COOPFORGE_STATUS_PUSH_URL:-} && -n ${COOPFORGE_STATUS_TOKEN:-} && -z ${COOP_SLUG:-} ]]; then
    die 14 "COOP_SLUG is required when the COOPFORGE_STATUS_* pair is set: pass the coop's platform slug (coops.slug), not the tier id '$SLUG'"
  fi
  local node_id
  node_id=$(python3 "$SCRIPT_DIR/gateway-mesh.py" register \
    --tier "$SLUG" --server "$SERVER_NUMBER" --ip "$SERVER_IP" --ssh-port "$SSH_PORT") ||
    die 14 "could not register $SLUG in the gateway mesh"
  log "mesh: $node_id"
  scp_to "$HETZNER_ROOT/status-agent.sh" /opt/coopforge/status-agent.sh || die 14 "could not copy status-agent.sh"
  run_node_stage register register 14
}

show_status() {
  local file
  file=$(state_file)
  if [[ ! -f $file ]]; then
    log "no state for $SLUG ($file)"
    return 0
  fi
  log "state: $file"
  grep -v -E '^(rescue_password|stage_)' "$file"
  local stage
  for stage in order install bootstrap model_pull register; do
    if stage_done "$stage"; then
      log "stage_$stage=done"
    else
      log "stage_$stage=pending"
    fi
  done
}

blocker_line() {
  local blocker
  blocker=$(model_blocker)
  if [[ -n $blocker ]]; then
    printf 'BLOCKED  MODEL_PULL %s' "$blocker"
  fi
}

print_plan() {
  cat <<EOF
tier            $SLUG  ($(fact .instance), $(fact .gpu))
provider        $(fact .provider)  $(fact .region_label)
model           $(fact .repo)  sha $(fact .sha)
engine          $(fact .engine)
serving         $(fact .served_context) context, tensor-parallel $(fact .tp_size)
cost            $(cents "$(fact .monthly_cost_cents)")/month catalog, seat $(cents "$(fact .seat_price_cents)"), $(fact .recommended_member_quota) seats
$(blocker_line)
ORDER      GET  $API/order/server/product                     # stock + prices, saved to state/hetzner/$SLUG.products.json
           POST $API/order/server/transaction                 # product_id + authorized_key[] + addon[]=primary_ipv4
           GET  $API/order/server/transaction/{id}            # poll for server_number
           GET  $API/server/{n}                               # poll for status=ready, read server_ip
INSTALL    POST $API/boot/{n}/rescue (os=linux, key)          # one-boot rescue, 60-minute window
           POST $API/reset/{n} (type=hw)
           ssh  root@server                                  # mdadm --stop, wipefs -fa, installimage -a -c /root/install.conf
                                                             # 2x NVMe RAID1, Ubuntu 24.04, image $IMAGE
                                                             # reboot, wait for SSH again
BOOTSTRAP  scp  hetzner-node-bootstrap.sh -> $REMOTE_BOOTSTRAP
           ssh  bootstrap                                     # driver 580, nvidia-container-toolkit, Docker
           scp  systemd/vllm.service -> /opt/coopforge/vllm.service
MODEL_PULL ssh  model-pull                                    # render coopforge-vllm.service + docker run $(fact .engine), wait for /health
REGISTER   mesh register $SLUG                                # gateway.yaml mesh node, weight from the manifest
           scp  status-agent.sh -> /opt/coopforge/status-agent.sh
           ssh  register                                      # systemd timer, heartbeat (skipped without COOPFORGE_STATUS_PUSH_URL; COOP_SLUG required)

Then:    scripts/hetzner-teardown.sh $SLUG
Cancel:  POST $API/server/{n}/cancellation with cancellation_date >= earliest_cancellation_date
EOF
}

print_summary() {
  local price seat
  price=$(state_get price_net 2>/dev/null) || price=
  seat=$(cents "$(fact .seat_price_cents)")
  cat <<EOF

tier       $SLUG ($(fact .instance), $(fact .gpu))
server     $SERVER_NUMBER  $SERVER_IP  ssh port $SSH_PORT
cost       ${price:+Robot ${price} net/month, }catalog $(cents "$(fact .monthly_cost_cents)")/month, seat $seat
serving    $(fact .repo) on $(fact .engine) — /health on the node, :8000
state      $(state_file)
cancel     scripts/hetzner-teardown.sh $SLUG
           curl -u "\$ROBOT_USER:\$ROBOT_WS_PASSWORD" -X POST $API/server/$SERVER_NUMBER/cancellation \\
             -d "cancellation_date=<earliest_cancellation_date from GET /server/$SERVER_NUMBER/cancellation>"
EOF
}

load_facts
[[ $(fact .provider) == hetzner ]] ||
  die 2 "tier $SLUG runs on $(fact .provider), not Hetzner; this script provisions Hetzner tiers only"

if ((SHOW_STATUS)); then
  show_status
  exit 0
fi

if ((DRY_RUN)); then
  print_plan
  exit 0
fi

stage_order
SERVER_NUMBER=$(state_get server_number || true)
SERVER_IP=$(state_get server_ip || true)
[[ -n $SERVER_NUMBER && -n $SERVER_IP ]] ||
  die 10 "no server recorded for $SLUG — ORDER did not complete"
stage_install
stage_bootstrap
stage_model_pull
stage_register
print_summary
