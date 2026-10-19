#!/usr/bin/env bash
# Runs on a freshly installed CoopForge GPU node. Called by hetzner-provision.sh
# over SSH, one stage per call:
#
#   bootstrap   install the NVIDIA driver, the container toolkit and Docker
#   model-pull  render systemd/vllm.service into the unit, start it, wait for /health
#   register    install the status agent and push one heartbeat
#
# Environment: TIER REPO SHA ENGINE SERVED_CONTEXT TP_SIZE
#              COOPFORGE_STATUS_PUSH_URL COOPFORGE_STATUS_TOKEN (register only)
set -Eeuo pipefail

readonly STAGE=${1:?usage: hetzner-node-bootstrap.sh <bootstrap|model-pull|register>}
readonly TIER=${TIER:?TIER is required}
readonly REPO=${REPO:?REPO is required}
readonly ENGINE=${ENGINE:?ENGINE is required}
readonly SHA=${SHA:-}
readonly SERVED_CONTEXT=${SERVED_CONTEXT:-131072}
readonly TP_SIZE=${TP_SIZE:-1}
readonly MODEL_TIMEOUT=${MODEL_TIMEOUT:-3600}
readonly NODE_DIR=/opt/coopforge
readonly UNIT=coopforge-vllm.service

stage_code() {
  case "$1" in
    bootstrap) echo 12 ;;
    model-pull) echo 13 ;;
    register) echo 14 ;;
    *) echo 1 ;;
  esac
}

fail() {
  echo "FAILED stage=$STAGE: $*" >&2
  exit "$(stage_code "$STAGE")"
}

stage_bootstrap() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq || fail "apt-get update failed"
  apt-get install -y -qq --no-install-recommends ca-certificates curl gnupg || fail "base packages failed"

  curl -fsSL -o /tmp/cuda-keyring.deb \
    https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb \
    || fail "could not fetch the CUDA keyring"
  dpkg -i /tmp/cuda-keyring.deb >/dev/null || fail "CUDA keyring install failed"
  apt-get update -qq || fail "apt-get update after keyring failed"
  apt-get install -y -qq cuda-drivers-580 nvidia-container-toolkit \
    || fail "driver 580 / container toolkit install failed (the engine tag needs driver >= 580; the -cu129 tag needs 575.51.03)"

  nvidia-smi >/dev/null 2>&1 || fail "nvidia-smi is not working after the driver install"
  nvidia-smi --query-gpu=name,driver_version --format=csv,noheader || true

  if ! command -v docker >/dev/null 2>&1; then
    curl -fsSL https://get.docker.com | sh || fail "Docker install failed"
  fi
  nvidia-ctk runtime configure --runtime=docker || fail "nvidia-ctk could not configure the Docker runtime"
  systemctl restart docker || fail "Docker restart failed"

  mkdir -p "$NODE_DIR/hf"
  echo "stage=$STAGE ok: $(nvidia-smi --query-gpu=name,driver_version --format=csv,noheader | head -n1)"
}

stage_model_pull() {
  mkdir -p "$NODE_DIR/hf"
  cat >"$NODE_DIR/vllm.env" <<EOF
TIER=$TIER
REPO=$REPO
SHA=$SHA
ENGINE=$ENGINE
SERVED_CONTEXT=$SERVED_CONTEXT
TP_SIZE=$TP_SIZE
EOF

  local revision=
  if [[ -n $SHA ]]; then revision="--revision $SHA"; fi

  [[ -f $NODE_DIR/vllm.service ]] ||
    fail "$NODE_DIR/vllm.service is missing — BOOTSTRAP copies it from systemd/vllm.service"
  sed -e "s|@TIER@|$TIER|g" \
    -e "s|@NODE_DIR@|$NODE_DIR|g" \
    -e "s|@ENGINE@|$ENGINE|g" \
    -e "s|@REPO@|$REPO|g" \
    -e "s|@REVISION@|$revision|g" \
    -e "s|@SERVED_CONTEXT@|$SERVED_CONTEXT|g" \
    -e "s|@TP_SIZE@|$TP_SIZE|g" \
    "$NODE_DIR/vllm.service" >"/etc/systemd/system/$UNIT" ||
    fail "could not render $UNIT from $NODE_DIR/vllm.service"

  systemctl daemon-reload || fail "systemctl daemon-reload failed"
  systemctl enable --now "$UNIT" || fail "could not start $UNIT"

  local deadline=$((SECONDS + MODEL_TIMEOUT))
  while ((SECONDS < deadline)); do
    if curl -fsS -m 5 http://127.0.0.1:8000/health >/dev/null 2>&1; then
      echo "stage=$STAGE ok: /health is answering"
      return 0
    fi
    sleep 15
  done

  journalctl -u "$UNIT" -n 60 --no-pager || true
  fail "no /health from the engine within ${MODEL_TIMEOUT}s"
}

stage_register() {
  if [[ -z ${COOPFORGE_STATUS_PUSH_URL:-} || -z ${COOPFORGE_STATUS_TOKEN:-} ]]; then
    echo "stage=$STAGE skipped: COOPFORGE_STATUS_PUSH_URL / COOPFORGE_STATUS_TOKEN are not set"
    return 0
  fi
  [[ -f $NODE_DIR/status-agent.sh ]] || fail "$NODE_DIR/status-agent.sh is missing"

  cat >"/etc/systemd/system/coopforge-status.service" <<EOF
[Unit]
Description=CoopForge status heartbeat for tier $TIER
After=network-online.target

[Service]
Type=oneshot
Environment=COOPFORGE_STATUS_PUSH_URL=$COOPFORGE_STATUS_PUSH_URL
Environment=COOPFORGE_STATUS_TOKEN=$COOPFORGE_STATUS_TOKEN
Environment=COOP_SLUG=$TIER
ExecStart=/bin/sh $NODE_DIR/status-agent.sh
EOF

  cat >"/etc/systemd/system/coopforge-status.timer" <<EOF
[Unit]
Description=CoopForge status heartbeat timer

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload || fail "systemctl daemon-reload failed"
  systemctl enable --now coopforge-status.timer || fail "could not enable the status timer"
  systemctl start coopforge-status.service || fail "the first heartbeat failed"
  echo "stage=$STAGE ok: heartbeat pushed to $COOPFORGE_STATUS_PUSH_URL"
}

case "$STAGE" in
  bootstrap) stage_bootstrap ;;
  model-pull) stage_model_pull ;;
  register) stage_register ;;
  *) fail "unknown stage '$STAGE'" ;;
esac
