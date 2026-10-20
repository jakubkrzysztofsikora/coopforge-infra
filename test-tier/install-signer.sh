# Installs the key signer on the box.
#
# The signer polls the platform outbound and mints keys against the box's own
# gateway, so the box needs no inbound reachability: the platform cannot fetch a
# plain-HTTP origin, and a raw-IP fetch is blocked outright (Cloudflare 1003), so
# "platform calls the box" is not a workable design. This is.
#
#   COOPFORGE_API=https://coopforge.eu COOPFORGE_API_KEY=... \
#     LITELLM_MASTER_KEY=... bash install-signer.sh
set -Eeuo pipefail

readonly SIGNER_SRC=${SIGNER_SRC:-/opt/coopforge/test-tier/signer.py}
readonly SIGNER_DIR=/opt/coopforge/signer
readonly UNIT=/etc/systemd/system/coopforge-signer.service
readonly PY=${PY:-python3}

fail() { printf 'FAILED: %s\n' "$*" >&2; exit 1; }

[[ -f $SIGNER_SRC ]] || fail "$SIGNER_SRC is missing"
: "${COOPFORGE_API:?COOPFORGE_API is required}"
: "${COOPFORGE_API_KEY:?COOPFORGE_API_KEY is required}"
: "${LITELLM_MASTER_KEY:?LITELLM_MASTER_KEY is required}"

# urllib only: no pip install, so this works on a bare box.
sudo mkdir -p "$SIGNER_DIR"
sudo install -m 0755 "$SIGNER_SRC" "$SIGNER_DIR/signer.py"

# The env holds two secrets, so it is root-only and never in the repo.
sudo tee "$SIGNER_DIR/signer.env" >/dev/null <<EOF
COOPFORGE_API=$COOPFORGE_API
COOPFORGE_API_KEY=$COOPFORGE_API_KEY
LITELLM_URL=http://127.0.0.1:4000
LITELLM_MASTER_KEY=$LITELLM_MASTER_KEY
STATE_FILE=$SIGNER_DIR/state.json
SYNC_INTERVAL_SECONDS=${SYNC_INTERVAL_SECONDS:-60}
EOF
sudo chmod 600 "$SIGNER_DIR/signer.env"
if [[ -f $SIGNER_DIR/state.json ]]; then
  sudo chmod 600 "$SIGNER_DIR/state.json"
fi

sudo tee "$UNIT" >/dev/null <<'EOF'
[Unit]
Description=CoopForge key signer
After=network-online.target docker.service
Wants=docker.service

[Service]
Type=simple
EnvironmentFile=/opt/coopforge/signer/signer.env
ExecStart=/usr/bin/python3 /opt/coopforge/signer/signer.py
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now coopforge-signer.service || fail "could not start the signer"
sleep 5
systemctl is-active --quiet coopforge-signer.service || {
  sudo journalctl -u coopforge-signer.service -n 30 --no-pager || true
  fail "signer is not running"
}
echo "signer installed and running"
