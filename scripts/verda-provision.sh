#!/usr/bin/env bash
# Provision a CoopForge Verda (ex-DataCrunch) tier.
#
#   scripts/verda-provision.sh --dry-run spot-fi-l40s
#   scripts/verda-provision.sh --status  spot-fi-l40s
#   VERDA_CLIENT_ID=... VERDA_CLIENT_SECRET=... COOP_SLUG=<coop-slug> \
#     scripts/verda-provision.sh --yes spot-fi-l40s
#
# Stages run in order: RESOLVE -> CREATE -> WAIT -> BOOTSTRAP -> MODEL_PULL ->
# REGISTER. Completed stages are recorded in state/verda/<slug>.env, so a re-run
# resumes instead of creating a second instance. The instance carries the
# `coop_slug` tag the platform uses to terminate it on close-out, so the tag is
# written before the box can bill for a whole month unaccounted for.
set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
readonly SCRIPT_DIR
readonly ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
readonly API=${VERDA_API:-https://api.verda.com/v1}
readonly TIERS=$ROOT/manifest/tiers.json
readonly NODE_BOOTSTRAP=$SCRIPT_DIR/hetzner-node-bootstrap.sh
readonly STATE_DIR=${STATE_DIR:-$ROOT/state/verda}
readonly SSH_KEY=${SSH_KEY:-$HOME/.ssh/id_ed25519.pub}
readonly SSH_KEY_NAME=${VERDA_SSH_KEY_NAME:-coopforge}
readonly LOCATION=${VERDA_LOCATION:-FIN-01}
readonly GPU_FILTER=${GPU_FILTER:-L40S}
readonly MIN_VRAM_GB=${MIN_VRAM_GB:-48}
readonly POLL_INTERVAL=${POLL_INTERVAL:-15}
readonly CREATE_TIMEOUT=${CREATE_TIMEOUT:-1800}
readonly SSH_TIMEOUT=${SSH_TIMEOUT:-900}
readonly SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=8)
readonly REMOTE_BOOTSTRAP=/opt/coopforge-node-bootstrap.sh

STAGE=START
DRY_RUN=0
ASSUME_YES=0
SHOW_STATUS=0
TIER=
SLUG=
SPOT=
ACCESS_TOKEN=
INSTANCE_TYPE=
INSTANCE_ID=
INSTANCE_IP=
IMAGE=
SSH_KEY_ID=

usage() {
  cat <<'EOF'
usage: verda-provision.sh [options] <tier-id>

  --dry-run       resolve nothing over the network; print the plan and exit
  --status        print the recorded state for COOP_SLUG and exit
  --yes           confirm the paid instance (required to reach CREATE)
  --spot          create a spot instance (default: on for tiers named spot-*)
  --on-demand     create an on-demand instance
  -h, --help      this text

Environment:
  VERDA_CLIENT_ID, VERDA_CLIENT_SECRET  Cloud API credentials (Verda console:
                                        Project -> Keys -> Cloud API Credentials)
  COOP_SLUG       the coop's platform slug (coops.slug), not the tier id; it is
                  the tag the platform tears down on close-out
  VERDA_LOCATION  location code, default FIN-01
  VERDA_IMAGE     OS image name override; default is the newest Ubuntu + CUDA image
  GPU_FILTER      GPU model substring to select, default L40S
  MIN_VRAM_GB     minimum GPU memory, default 48
  SSH_KEY         public key registered in Verda and installed on the box
  COOPFORGE_STATUS_PUSH_URL, COOPFORGE_STATUS_TOKEN  status push endpoint
  VLLM_API_KEY    engine bearer written on the box during MODEL_PULL
  VERDA_API, STATE_DIR, POLL_INTERVAL, CREATE_TIMEOUT, SSH_TIMEOUT

Exit codes: 2 usage, 5 RESOLVE, 6 CREATE, 7 WAIT, 12 BOOTSTRAP, 13 MODEL_PULL, 14 REGISTER.
EOF
}

log() { printf '%s\n' "$*"; }

die() {
  local code=$1
  shift
  printf 'FAILED stage=%s: %s\n' "$STAGE" "$*" >&2
  exit "$code"
}

state_file() { printf '%s/%s.env' "$STATE_DIR" "$SLUG"; }

state_get() {
  local file
  file=$(state_file)
  [[ -f $file ]] || return 1
  (
    # shellcheck source=/dev/null
    . "$file"
    eval "printf '%s' \"\${$1:-}\""
  )
}

state_set() {
  mkdir -p "$STATE_DIR"
  chmod 700 "$STATE_DIR"
  local file tmp
  file=$(state_file)
  tmp="$file.tmp"
  touch "$tmp"
  chmod 600 "$tmp"
  local key
  for key in "$@"; do
    printf '%s=%q\n' "$key" "${!key}"
  done >"$tmp"
  mv "$tmp" "$file"
}

while (($#)); do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --status) SHOW_STATUS=1 ;;
    --yes) ASSUME_YES=1 ;;
    --spot) SPOT=1 ;;
    --on-demand) SPOT=0 ;;
    -h | --help)
      usage
      exit 0
      ;;
    -*) die 2 "unknown option $1" ;;
    *)
      [[ -z $TIER ]] || die 2 "one tier at a time"
      TIER=$1
      ;;
  esac
  shift
done

[[ -n $TIER ]] || {
  usage >&2
  exit 2
}
command -v jq >/dev/null || die 2 "jq not found"
[[ -f $TIERS ]] || die 2 "missing $TIERS"

SLUG=${COOP_SLUG:-}
if ((SHOW_STATUS)); then
  [[ -n $SLUG ]] || die 2 "--status needs COOP_SLUG"
  state_file
  [[ -f $(state_file) ]] || {
    log "no state for $SLUG"
    exit 0
  }
  # shellcheck disable=SC1090
  . "$(state_file)"
  log "tier=$TIER slug=$SLUG instance=$INSTANCE_ID ip=$INSTANCE_IP type=$INSTANCE_TYPE"
  exit 0
fi

[[ -n $SLUG ]] || die 2 "COOP_SLUG is required (the coop's platform slug, not the tier id)"

REPO=$(jq -r --arg t "$TIER" '.[$t].repo // empty' "$TIERS")
SHA=$(jq -r --arg t "$TIER" '.[$t].sha // empty' "$TIERS")
ENGINE=$(jq -r --arg t "$TIER" '.[$t].engine // empty' "$TIERS")
SERVED_CONTEXT=$(jq -r --arg t "$TIER" '.[$t].served_context // empty' "$TIERS")
TP_SIZE=$(jq -r --arg t "$TIER" '.[$t].tp_size // empty' "$TIERS")
ROUTE=$(jq -r --arg t "$TIER" '.[$t].route // empty' "$TIERS")
[[ -n $REPO && -n $ENGINE && -n $SERVED_CONTEXT && -n $TP_SIZE && -n $ROUTE ]] ||
  die 2 "tier $TIER is not in manifest/tiers.json"

if [[ -z $SPOT ]]; then
  case "$TIER" in
    spot-*) SPOT=1 ;;
    *) SPOT=0 ;;
  esac
fi

api() { # api <method> <path> [body]
  local method=$1 path=$2 body=${3:-}
  if [[ -n $body ]]; then
    curl -fsS -X "$method" "$API$path" \
      -H "Authorization: Bearer $ACCESS_TOKEN" \
      -H 'Content-Type: application/json' \
      -d "$body"
  else
    curl -fsS -X "$method" "$API$path" -H "Authorization: Bearer $ACCESS_TOKEN"
  fi
}

dry_plan() {
  cat <<EOF
plan for tier=$TIER slug=$SLUG
  contract        $([[ $SPOT == 1 ]] && echo SPOT || echo PAY_AS_YOU_GO)
  location        $LOCATION
  instance type   ${INSTANCE_TYPE:-<resolved: ${GPU_FILTER} >=${MIN_VRAM_GB}GB, 1 GPU>}
  image           ${IMAGE:-<resolved: newest Ubuntu + CUDA>}
  ssh key         ${SSH_KEY_ID:-<registered: $SSH_KEY_NAME>}
  tag             coop_slug=$SLUG
  engine          $ENGINE
  model           $REPO @ ${SHA:-<unpinned>}
  served context  $SERVED_CONTEXT tokens, tp=$TP_SIZE, route=$ROUTE
  node stages     BOOTSTRAP -> MODEL_PULL -> REGISTER (over SSH as root)
  teardown        scripts/verda-teardown.sh --yes  (also called by platform close-out)
EOF
}

STAGE=RESOLVE
if ((DRY_RUN)); then
  dry_plan
  exit 0
fi

: "${VERDA_CLIENT_ID:?VERDA_CLIENT_ID is required}"
: "${VERDA_CLIENT_SECRET:?VERDA_CLIENT_SECRET is required}"

ACCESS_TOKEN=$(curl -fsS -X POST "$API/oauth2/token" \
  -H 'Content-Type: application/json' \
  -d "$(jq -n --arg id "$VERDA_CLIENT_ID" --arg secret "$VERDA_CLIENT_SECRET" \
    '{grant_type: "client_credentials", client_id: $id, client_secret: $secret}')" |
  jq -r '.access_token // empty') || die 5 "token request failed"
[[ -n $ACCESS_TOKEN ]] || die 5 "no access token returned"

# A box already recorded for this slug is adopted, never duplicated: a second
# instance would double the monthly bill and only one is reachable by tag.
EXISTING=$(state_get INSTANCE_ID 2>/dev/null || true)
if [[ -n $EXISTING ]]; then
  current=$(api GET "/instances/$EXISTING" 2>/dev/null | jq -r '.id // empty' || true)
  if [[ -n $current ]]; then
    INSTANCE_ID=$EXISTING
    INSTANCE_TYPE=$(api GET "/instances/$EXISTING" | jq -r '.instance_type // empty')
    INSTANCE_IP=$(api GET "/instances/$EXISTING" | jq -r '.ip // empty')
    log "adopting instance $INSTANCE_ID for $SLUG"
  fi
fi

if [[ -z $INSTANCE_ID ]]; then
  INSTANCE_TYPE=$(api GET "/instance-types" |
    jq -r --arg gpu "$GPU_FILTER" --argjson min "$MIN_VRAM_GB" '
      [.[] | select((.gpu.description // "") | test($gpu; "i"))
           | select(.gpu.number_of_gpus == 1)
           | select(.gpu_memory.size_in_gigabytes >= $min)]
      | sort_by(.gpu_memory.size_in_gigabytes) | .[0].instance_type // empty')
  [[ -n $INSTANCE_TYPE ]] || die 5 "no ${GPU_FILTER} instance with >=${MIN_VRAM_GB}GB on Verda"

  available=$(api GET "/instance-availability/$INSTANCE_TYPE" |
    jq -r --arg loc "$LOCATION" '.[]? | select(.location_code == $loc) | .location_code' |
    head -1 || true)
  if [[ -z $available ]]; then
    locations=$(api GET "/instance-availability/$INSTANCE_TYPE" | jq -r '[.[].location_code] | join(",")')
    die 5 "$INSTANCE_TYPE is unavailable in $LOCATION (available: ${locations:-none})"
  fi

  if [[ -n ${VERDA_IMAGE:-} ]]; then
    IMAGE=$VERDA_IMAGE
  else
    IMAGE=$(api GET "/images?instance_type=$INSTANCE_TYPE" |
      jq -r '[.[] | select((.name // "") | test("ubuntu"; "i"))]
             | sort_by(.name) | reverse | .[0].name // empty')
    [[ -n $IMAGE ]] || die 5 "no Ubuntu image for $INSTANCE_TYPE; set VERDA_IMAGE"
  fi

  SSH_KEY_ID=$(api GET "/ssh-keys" |
    jq -r --arg n "$SSH_KEY_NAME" '[.[] | select(.name == $n)][0].id // empty')
  if [[ -z $SSH_KEY_ID ]]; then
    [[ -f $SSH_KEY ]] || die 5 "missing public key $SSH_KEY"
    SSH_KEY_ID=$(api POST "/ssh-keys" \
      "$(jq -n --arg n "$SSH_KEY_NAME" --rawfile k "$SSH_KEY" '{name: $n, key: ($k | rtrimstr("\n"))}')" |
      jq -r '.id // empty') || die 5 "could not register $SSH_KEY"
    [[ -n $SSH_KEY_ID ]] || die 5 "no ssh key id returned"
  fi
fi

STAGE=CREATE
if [[ -z $INSTANCE_ID ]]; then
  if ((!ASSUME_YES)); then
    dry_plan
    log ""
    log "re-run with --yes to create this instance"
    exit 0
  fi
  payload=$(jq -n \
    --arg type "$INSTANCE_TYPE" \
    --arg image "$IMAGE" \
    --arg key "$SSH_KEY_ID" \
    --arg host "$SLUG" \
    --arg desc "CoopForge coop $SLUG (tier $TIER)" \
    --arg loc "$LOCATION" \
    --arg slug "$SLUG" \
    --arg tier "$TIER" \
    --argjson spot "$([[ $SPOT == 1 ]] && echo true || echo false)" \
    '{instance_type: $type, image: $image, ssh_key_ids: [$key],
      hostname: $host, description: $desc, location_code: $loc,
      is_spot: $spot, contract: (if $spot then "SPOT" else "PAY_AS_YOU_GO" end),
      tags: [{key: "coop_slug", value: $slug}, {key: "tier", value: $tier}]}')
  created=$(api POST "/instances" "$payload") || die 6 "instance create failed"
  INSTANCE_ID=$(jq -r '.id // empty' <<<"$created")
  INSTANCE_IP=$(jq -r '.ip // empty' <<<"$created")
  [[ -n $INSTANCE_ID ]] || die 6 "no instance id returned"
  state_set INSTANCE_ID INSTANCE_IP INSTANCE_TYPE
  log "created $INSTANCE_ID ($INSTANCE_TYPE) in $LOCATION"
fi

STAGE=WAIT
deadline=$((SECONDS + CREATE_TIMEOUT))
while :; do
  row=$(api GET "/instances/$INSTANCE_ID") || die 7 "instance lookup failed"
  status=$(jq -r '.status // empty' <<<"$row")
  ip=$(jq -r '.ip // empty' <<<"$row")
  [[ -n $ip ]] && INSTANCE_IP=$ip
  case "$status" in
    running) break ;;
    error | deleted) die 7 "instance entered status=$status" ;;
  esac
  ((SECONDS < deadline)) || die 7 "instance still status=$status after ${CREATE_TIMEOUT}s"
  sleep "$POLL_INTERVAL"
done
state_set INSTANCE_ID INSTANCE_IP INSTANCE_TYPE
log "instance $INSTANCE_ID running at $INSTANCE_IP"

STAGE=WAIT
ssh_run() { ssh "${SSH_OPTS[@]}" "root@$INSTANCE_IP" "$@"; }
ssh_ready_deadline=$((SECONDS + SSH_TIMEOUT))
until ssh_run true 2>/dev/null; do
  ((SECONDS < ssh_ready_deadline)) || die 7 "ssh did not come up on $INSTANCE_IP"
  sleep "$POLL_INTERVAL"
done

node_stage() { # node_stage <bootstrap|model-pull|register>
  local stage=$1
  local env_prefix="TIER=$TIER REPO=$REPO"
  [[ -n $SHA ]] && env_prefix+=" SHA=$SHA"
  env_prefix+=" ENGINE=$ENGINE SERVED_CONTEXT=$SERVED_CONTEXT TP_SIZE=$TP_SIZE"
  env_prefix+=" SERVED_MODEL_NAME=$ROUTE"
  if [[ $stage == model-pull && -n ${VLLM_API_KEY:-} ]]; then
    env_prefix+=" VLLM_API_KEY=$VLLM_API_KEY"
  fi
  if [[ -n ${COOPFORGE_STATUS_PUSH_URL:-} && -n ${COOPFORGE_STATUS_TOKEN:-} ]]; then
    env_prefix+=" COOPFORGE_STATUS_PUSH_URL=$COOPFORGE_STATUS_PUSH_URL"
    env_prefix+=" COOPFORGE_STATUS_TOKEN=$COOPFORGE_STATUS_TOKEN COOP_SLUG=$SLUG"
  fi
  ssh_run "env $env_prefix bash $REMOTE_BOOTSTRAP $stage"
}

STAGE=BOOTSTRAP
if [[ $(state_get STAGE_BOOTSTRAP 2>/dev/null || true) != done ]]; then
  scp -q "${SSH_OPTS[@]}" "$NODE_BOOTSTRAP" "root@$INSTANCE_IP:$REMOTE_BOOTSTRAP" ||
    die 12 "could not copy the node script"
  node_stage bootstrap || die 12 "bootstrap failed"
  STAGE_BOOTSTRAP=done
  state_set INSTANCE_ID INSTANCE_IP INSTANCE_TYPE STAGE_BOOTSTRAP
fi

STAGE=MODEL_PULL
if [[ $(state_get STAGE_MODEL_PULL 2>/dev/null || true) != done ]]; then
  node_stage model-pull || die 13 "model pull or engine start failed"
  STAGE_MODEL_PULL=done
  state_set INSTANCE_ID INSTANCE_IP INSTANCE_TYPE STAGE_BOOTSTRAP STAGE_MODEL_PULL
fi

STAGE=REGISTER
if [[ $(state_get STAGE_REGISTER 2>/dev/null || true) != done ]]; then
  node_stage register || die 14 "status registration failed"
  STAGE_REGISTER=done
  state_set INSTANCE_ID INSTANCE_IP INSTANCE_TYPE STAGE_BOOTSTRAP STAGE_MODEL_PULL STAGE_REGISTER
fi

log "provisioned $SLUG on $INSTANCE_ID ($INSTANCE_TYPE, $LOCATION, $INSTANCE_IP)"
log "teardown: scripts/verda-teardown.sh --yes"
