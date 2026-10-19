#!/usr/bin/env bash
# Shared primitives for the Hetzner provisioning scripts: runtime state, Robot
# API access and SSH helpers. Sourced by hetzner-provision.sh and
# hetzner-teardown.sh; never run directly.

HETZNER_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
API=${ROBOT_API:-https://robot-ws.your-server.de}
STATE_DIR=${STATE_DIR:-$HETZNER_ROOT/state/hetzner}
SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=8)
POLL_INTERVAL=${POLL_INTERVAL:-15}
SSH_PORT=${SSH_PORT:-22}

log() { printf '%s\n' "$*"; }

die() {
  local code=$1
  shift
  printf 'FAILED stage=%s: %s\n' "${STAGE:-START}" "$*" >&2
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
  {
    [[ -f $file ]] && grep -v -E "^$1=" "$file" || true
    printf '%s=%q\n' "$1" "$2"
  } >"$tmp"
  chmod 600 "$tmp"
  mv "$tmp" "$file"
}

stage_done() { [[ $(state_get "stage_$1" 2>/dev/null) == "done" ]]; }
mark_done() { state_set "stage_$1" "done"; }

load_facts() {
  FACTS=$(node --experimental-strip-types --no-warnings "$HETZNER_ROOT/scripts/tier-facts.mjs" "$SLUG") ||
    die "${1:-2}" "cannot read tier facts for '$SLUG'"
}

fact() { jq -r "$1" <<<"$FACTS"; }

require_creds() {
  local code=$1
  [[ -n ${ROBOT_USER:-} ]] ||
    die "$code" "ROBOT_USER is unset — nothing was sent. Use the Robot web-service user, not the Robot login."
  [[ -n ${ROBOT_WS_PASSWORD:-} ]] || die "$code" "ROBOT_WS_PASSWORD is unset — nothing was sent."
}

api() {
  local method=$1 path=$2
  shift 2
  curl -fsS --max-time 60 --fail-with-body -u "$ROBOT_USER:$ROBOT_WS_PASSWORD" -X "$method" "$API$path" "$@"
}

ssh_run() { ssh -n "${SSH_OPTS[@]}" -p "$SSH_PORT" "root@$SERVER_IP" "$@"; }
# Same, but lets stdin through: `ssh -n` reads stdin from /dev/null, so a heredoc
# piped into ssh_run arrives empty on the far side.
ssh_run_stdin() { ssh "${SSH_OPTS[@]}" -p "$SSH_PORT" "root@$SERVER_IP" "$@"; }

scp_to() { scp -q "${SSH_OPTS[@]}" -P "$SSH_PORT" "$1" "root@$SERVER_IP:$2"; }

cents() { awk -v c="${1:-0}" 'BEGIN { printf "€%.2f", c / 100 }'; }
