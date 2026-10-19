#!/usr/bin/env bash
# Drain, deregister and cancel a CoopForge Hetzner tier.
#
#   scripts/hetzner-teardown.sh --dry-run seed-24g
#   scripts/hetzner-teardown.sh --status  seed-24g
#   ROBOT_USER=... ROBOT_WS_PASSWORD=... scripts/hetzner-teardown.sh --yes seed-24g
#
# Order matters: a cancelled Hetzner server keeps running until the end of its
# paid period, so the node is drained and taken out of rotation first and only
# then cancelled. Cancelling a tier with no fallback capacity needs --force.
set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
readonly SCRIPT_DIR
# shellcheck source=scripts/hetzner-lib.sh
. "$SCRIPT_DIR/hetzner-lib.sh"
readonly DRAIN_TIMEOUT=${DRAIN_TIMEOUT:-300}

STAGE=START
DRY_RUN=0
FORCE=0
ASSUME_YES=0
SHOW_STATUS=0
SLUG=
SERVER_NUMBER=
SERVER_IP=
CANCEL_DATE=

usage() {
  cat <<'EOF'
usage: hetzner-teardown.sh [options] <tier-id>

  --dry-run            print the ordered plan and exit; no network, no state
  --status             print what has already run for this tier
  --yes                confirm the cancellation (required to reach CANCEL)
  --force              continue past a failed drain/deregister, or cancel a tier
                       with no fallback capacity
  --server N           cancel this server number instead of the recorded one
  --ip ADDR            node address for the drain and deregister stages
  --cancel-date DATE   cancellation_date, YYYY-MM-DD (default: Robot's earliest)
  -h, --help           this text

Environment:
  ROBOT_USER, ROBOT_WS_PASSWORD   Robot web-service credentials
  FALLBACK_TIER                   override the fallback tier for this tier
  ROBOT_API, STATE_DIR, DRAIN_TIMEOUT

Exit codes: 2 usage, 3 refused, 20 DRAIN, 21 DEREGISTER, 22 CANCEL.
EOF
}

on_exit() {
  local code=$?
  case $code in 0 | 2 | 3 | 20 | 21 | 22) return 0 ;; esac
  printf 'FAILED stage=%s: unexpected exit %s\n' "$STAGE" "$code" >&2
}
trap on_exit EXIT

while (($#)); do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --status) SHOW_STATUS=1 ;;
    --yes) ASSUME_YES=1 ;;
    --force) FORCE=1 ;;
    --server | --ip | --cancel-date)
      [[ -n ${2:-} ]] || die 2 "$1 needs a value"
      case "$1" in
        --server) SERVER_NUMBER=$2 ;;
        --ip) SERVER_IP=$2 ;;
        --cancel-date) CANCEL_DATE=$2 ;;
      esac
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

# Capacity that absorbs this tier's coops after the node goes away. The seat-price
# deltas are in docs/hetzner-runbook.md; empty means --force is required.
fallback_for() {
  case "$1" in
    seed-24g) printf 'everyday-fr-l40s' ;;
    everyday-96g) printf 'power-h100' ;;
  esac
}

load_facts
[[ $(fact .provider) == hetzner ]] ||
  die 2 "tier $SLUG runs on $(fact .provider), not Hetzner; this script tears down Hetzner tiers only"

if ((SHOW_STATUS)); then
  file=$(state_file)
  if [[ ! -f $file ]]; then
    log "no state for $SLUG ($file)"
    exit 0
  fi
  log "state: $file"
  grep -v -E '^(rescue_password|stage_)' "$file"
  for stage in order install bootstrap model_pull register drain deregister cancel; do
    if stage_done "$stage"; then
      log "stage_$stage=done"
    else
      log "stage_$stage=pending"
    fi
  done
  exit 0
fi

FALLBACK_TIER=${FALLBACK_TIER-$(fallback_for "$SLUG")}

if ((DRY_RUN)); then
  cat <<EOF
tier            $SLUG  ($(fact .instance), $(fact .gpu))
provider        $(fact .provider)  $(fact .region_label)
cost            $(cents "$(fact .monthly_cost_cents)")/month catalog, seat $(cents "$(fact .seat_price_cents)"), $(fact .recommended_member_quota) seats
fallback        ${FALLBACK_TIER:-none — --force required}
state           $(state_file)

DRAIN       wait for vllm:num_requests_running == 0 on the node, up to ${DRAIN_TIMEOUT}s
            (a node that does not answer is already out of rotation)
DEREGISTER  ssh  systemctl disable --now coopforge-vllm.service coopforge-status.timer
            (a node that cannot be reached needs --force to continue)
CANCEL      GET  $API/server/{n}/cancellation          # read earliest_cancellation_date
            POST $API/server/{n}/cancellation          # cancellation_date=<earliest, or --cancel-date>
            GET  $API/server/{n}                       # read paid_until = effective billing end
            DELETE $API/server/{n}/cancellation        # revokes the cancellation, if it was a mistake

The server keeps serving until paid_until, so the drain and deregister stages run
first. Wipe the disks before asking Hetzner to take the box back early.
EOF
  exit 0
fi

((ASSUME_YES)) || die 3 "refusing to cancel without --yes (nothing was cancelled)"

if [[ -z $SERVER_NUMBER ]]; then
  SERVER_NUMBER=$(state_get server_number || true)
fi
if [[ -z $SERVER_IP ]]; then
  SERVER_IP=$(state_get server_ip || true)
fi
SSH_PORT=$(state_get ssh_port || true)
SSH_PORT=${SSH_PORT:-22}

[[ -n $SERVER_NUMBER ]] ||
  die 3 "no server number recorded for $SLUG — nothing to cancel (use --server N for a box whose state is gone)"

if [[ -z $FALLBACK_TIER ]] && ((!FORCE)); then
  die 3 "no fallback capacity recorded for $SLUG — pass --force to cancel anyway, or move its coops first"
fi

require_creds 22

drain_node() {
  STAGE=DRAIN
  if [[ -z $SERVER_IP ]]; then
    log "stage=DRAIN skipped: no address recorded (use --ip ADDR to drain a running node)"
    return 0
  fi
  local deadline=$((SECONDS + DRAIN_TIMEOUT)) running
  while ((SECONDS < deadline)); do
    running=$(curl -fsS -m 5 "http://$SERVER_IP:8000/metrics" 2>/dev/null |
      awk '/^vllm:num_requests_running/ {print $2; exit}') || running=
    if [[ -z $running ]]; then
      log "stage=DRAIN ok: $SERVER_IP:8000 is not answering; nothing is being served"
      return 0
    fi
    if [[ ${running%%.*} == 0 ]]; then
      log "stage=DRAIN ok: no requests running"
      return 0
    fi
    log "draining: $running requests still running"
    sleep 5
  done
  ((FORCE)) || die 20 "requests still running after ${DRAIN_TIMEOUT}s — re-run with --force to cancel anyway"
  log "stage=DRAIN forced: requests were still running"
}

deregister_node() {
  STAGE=DEREGISTER
  if [[ -z $SERVER_IP ]]; then
    log "stage=DEREGISTER skipped: no address recorded"
    state_set deregistered_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    mark_done deregister
    return 0
  fi
  if ! ssh_run 'systemctl disable --now coopforge-vllm.service coopforge-status.timer'; then
    ((FORCE)) || die 21 "could not stop the engine on $SERVER_IP — re-run with --force to cancel anyway"
    log "stage=DEREGISTER forced: $SERVER_IP did not accept SSH"
  else
    log "stage=DEREGISTER ok: engine and status timer stopped on $SERVER_IP"
  fi
  state_set deregistered_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  mark_done deregister
}

cancel_server() {
  STAGE=CANCEL
  local current earliest date
  current=$(api GET "/server/$SERVER_NUMBER/cancellation") ||
    die 22 "could not read the cancellation state of server $SERVER_NUMBER"
  if [[ $(jq -r '.cancellation.cancelled // false' <<<"$current") == true ]]; then
    log "server $SERVER_NUMBER is already cancelled for $(jq -r '.cancellation.cancellation_date // "?"' <<<"$current")"
  else
    earliest=$(jq -r '.cancellation.earliest_cancellation_date // empty' <<<"$current")
    date=${CANCEL_DATE:-$earliest}
    [[ -n $date ]] || die 22 "Robot returned no earliest_cancellation_date; pass --cancel-date YYYY-MM-DD"
    api POST "/server/$SERVER_NUMBER/cancellation" --data-urlencode "cancellation_date=$date" >/dev/null ||
      die 22 "POST /server/$SERVER_NUMBER/cancellation failed"
    log "cancelled: server $SERVER_NUMBER, cancellation_date $date"
  fi

  local server
  server=$(api GET "/server/$SERVER_NUMBER") || die 22 "could not read server $SERVER_NUMBER"
  state_set cancelled_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  mark_done cancel
  cat <<EOF

server          $SERVER_NUMBER  $SERVER_IP
billing ends    $(jq -r '.server.paid_until // "unknown"' <<<"$server")  (the box keeps running until then)
product         $(jq -r '.server.product // "?"' <<<"$server")
state           $(state_file)
revoke          curl -u "\$ROBOT_USER:\$ROBOT_WS_PASSWORD" -X DELETE $API/server/$SERVER_NUMBER/cancellation
EOF
}

drain_node
deregister_node
cancel_server
