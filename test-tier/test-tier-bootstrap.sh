#!/usr/bin/env bash
# Test-tier bootstrap, run by scaleway-test-provision.sh on a fresh box.
#
# Installs Docker, brings up the Ollama + LiteLLM stack, and pulls the model.
# One script rather than cloud-init: it needs the stack files from this repo,
# which cloud-init does not have.
#
#   TIER_DIR=/opt/coopforge/test-tier bash test-tier-bootstrap.sh <up|status|down>
set -Eeuo pipefail

readonly STAGE=${1:?usage: test-tier-bootstrap.sh <up|status|down>}
readonly TIER_DIR=${TIER_DIR:-/opt/coopforge/test-tier}
readonly MODEL_TAG=${MODEL_TAG:-SpeakLeash/bielik-minitron-7B-v3.0-instruct:Q4_K_M}
# The registry template cannot express Bielik's own tool-call format, so the
# model is rebuilt from the Modfile next to this script.
readonly TOOLS_MODEL_TAG=${TOOLS_MODEL_TAG:-coopforge/bielik-minitron-7b-tools:Q4_K_M}
readonly GATEWAY_URL=${GATEWAY_URL:-http://127.0.0.1:4000}

fail() { printf 'FAILED stage=%s: %s\n' "$STAGE" "$*" >&2; exit 1; }

# The docker group is added by cloud-init during this same session, so it is not
# in the running shell's groups and socket access fails. Every docker call goes
# through `sg docker -c` as ONE string: command substitution inside the caller
# would otherwise run outside the group and fail.
# Runs compose with the docker group applied. The one-string form of `sg -c`
# mangles arguments containing spaces, so compose is rebuilt as a literal
# command string with the -f flag already resolved.
COMPOSE_FILE="$TIER_DIR/docker-compose.yml"
compose() {
  sg docker -c "docker compose -f '$COMPOSE_FILE' $*"
}

install_docker() {
  if command -v docker >/dev/null 2>&1; then return; fi
  # cloud-init also installs Docker, and two apt runs deadlock on
  # /var/lib/apt/lists/lock. Wait for cloud-init, then for the lock.
  if command -v cloud-init >/dev/null 2>&1; then
    cloud-init status --wait >/dev/null 2>&1 || true
    command -v docker >/dev/null 2>&1 && return
  fi
  for _ in $(seq 1 60); do
    sudo fuser /var/lib/apt/lists/lock >/dev/null 2>&1 || break
    sleep 5
  done
  curl -fsSL https://get.docker.com | sh || fail "docker install failed"
  systemctl enable --now docker || fail "could not start docker"
}

stage_up() {
  install_docker
  [[ -f $TIER_DIR/docker-compose.yml ]] || fail "$TIER_DIR/docker-compose.yml is missing"
  [[ -f $TIER_DIR/litellm-config.yaml ]] || fail "$TIER_DIR/litellm-config.yaml is missing"
  [[ -f $TIER_DIR/.env ]] || fail "$TIER_DIR/.env is missing (needs LITELLM_MASTER_KEY)"

  compose up -d || fail "compose up failed"

  # The model has to exist before litellm can serve the route. `compose exec`
  # rather than `docker exec $(compose ps -q ...)`: the substitution would run
  # outside the docker group and fail with permission denied.
  local deadline=$((SECONDS + 1800))
  while ((SECONDS < deadline)); do
    if compose "exec -T ollama ollama list" 2>/dev/null | grep -q "${MODEL_TAG%%:*}"; then
      break
    fi
    compose "exec -T ollama ollama pull $MODEL_TAG" >/dev/null 2>&1 || true
    sleep 15
  done
  compose "exec -T ollama ollama list" 2>/dev/null | grep -q "${MODEL_TAG%%:*}" ||
    fail "model $MODEL_TAG never landed in the box's ollama"

  # Rebuild the model with a template Ollama can parse. The registry template
  # injects tool schemas but never renders a tool call, so Ollama does not know
  # which tag to watch for and hands the caller the tool call as plain text.
  [[ -f $TIER_DIR/bielik-tools.Modfile ]] || fail "$TIER_DIR/bielik-tools.Modfile is missing"
  local modfile="/tmp/bielik-tools.Modfile"
  sed "s|^FROM .*|FROM $MODEL_TAG|" "$TIER_DIR/bielik-tools.Modfile" > "$modfile"
  local ollama_container
  ollama_container=$(compose "ps -q ollama")
  sg docker -c "docker cp '$modfile' '$ollama_container:/tmp/bielik-tools.Modfile'" ||
    fail "could not copy the modfile into the ollama container"
  compose "exec -T ollama ollama create $TOOLS_MODEL_TAG -f /tmp/bielik-tools.Modfile" ||
    fail "tool-aware model creation failed"
  compose "exec -T ollama ollama list" 2>/dev/null | grep -q "${TOOLS_MODEL_TAG%%:*}" ||
    fail "model $TOOLS_MODEL_TAG never landed in the box's ollama"

  # /health/liveliness is the unauthenticated probe; /health requires the master
  # key and returns 401 without it, so asserting on /health would always fail.
  deadline=$((SECONDS + 600))
  while ((SECONDS < deadline)); do
    curl -fsS -m 5 "$GATEWAY_URL/health/liveliness" >/dev/null 2>&1 && break
    sleep 10
  done
  curl -fsS -m 5 "$GATEWAY_URL/health/liveliness" >/dev/null 2>&1 ||
    fail "litellm never became healthy on $GATEWAY_URL"
  echo "stage=up ok: gateway healthy on $GATEWAY_URL"
}

stage_status() {
  compose ps || true
  echo "--- gateway ---"
  curl -fsS -m 5 "$GATEWAY_URL/health/liveliness" 2>/dev/null || echo "gateway not answering"
  echo
  echo "--- models ---"
  compose "exec -T ollama ollama list" 2>/dev/null || true
}

stage_down() {
  compose "down -v" || fail "compose down failed"
  echo "stage=down ok: stack and volumes removed"
}

case "$STAGE" in
  up) stage_up ;;
  status) stage_status ;;
  down) stage_down ;;
  *) fail "unknown stage '$STAGE'" ;;
esac
