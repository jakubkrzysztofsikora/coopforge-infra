#!/usr/bin/env bash
# Watch a coop through provisioning and use. Read-only: queries the platform and
# the box, never changes either.
#
#   scripts/coop-watch.sh <coop-slug> [--follow]
#
# Without --follow it prints one status block. With it, refreshes every 20s until
# the coop is `active` and its member key has been delivered, then stops.
#
# This exists because provisioning is several minutes of "is it working?" and the
# answer is spread across D1, the box, and the tunnel.
set -Eeuo pipefail

readonly SLUG=${1:?usage: coop-watch.sh <coop-slug> [--follow]}
readonly FOLLOW=${2:-}
readonly WEB_DIR=${WEB_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../coopforge/web" && pwd)}
readonly ZONE=${TUNNEL_ZONE:-coopforge.eu}
readonly GATEWAY="https://${SLUG}-gw.${ZONE}"

d1() {
  (cd "$WEB_DIR" && npx wrangler d1 execute coopforge-db --remote --json --command "$1" 2>/dev/null) |
    jq -r '.[0].results' 2>/dev/null
}

show() {
  echo "── $SLUG ── $(date -u +%H:%M:%SZ)"
  local coop
  coop=$(d1 "SELECT status, provisioning_token, gateway_endpoint, member_quota FROM coops WHERE slug='$SLUG'")
  if [[ $coop == "[]" || -z $coop ]]; then
    echo "  coop: not found"
    return 1
  fi
  echo "  coop : $(jq -r '.[0] | "\(.status)  endpoint=\(.gateway_endpoint // "-")  seats=\(.member_quota)"' <<<"$coop")"
  echo "  token: $(jq -r '.[0].provisioning_token // "(none)"' <<<"$coop" | cut -c1-12)…"

  local members
  members=$(d1 "SELECT m.email, m.status, m.litellm_key IS NOT NULL AS has_key, m.key_delivered_at FROM members m JOIN coops c ON c.id=m.coop_id WHERE c.slug='$SLUG'")
  if [[ $members != "[]" && -n $members ]]; then
    while IFS= read -r row; do
      echo "  member: $(jq -r '"\(.email)  \(.status)  key=\(if .has_key == 1 then "yes" else "no" end)  delivered=\(.key_delivered_at // "-")"' <<<"$row")"
    done < <(jq -c '.[]' <<<"$members")
  fi

  # The tunnel only answers once the box is up and registered.
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "$GATEWAY/health/liveliness" 2>/dev/null); code=${code:-000}
  echo "  tunnel: $GATEWAY -> $code"

  # Ready when the coop is active AND every charged member has a delivered key.
  local active missing
  active=$(jq -r '.[0].status' <<<"$coop")
  missing=$(jq -r '[.[] | select(.status=="charged" and .has_key != 1)] | length' <<<"${members:-[]}")
  [[ $active == "active" && $missing == "0" ]]
}

if [[ $FOLLOW == "--follow" ]]; then
  for _ in $(seq 1 60); do
    if show; then
      echo "  READY"
      exit 0
    fi
    sleep 20
  done
  echo "  still not ready after 20 minutes"
  exit 1
else
  show || true
fi
