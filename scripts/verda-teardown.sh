#!/usr/bin/env bash
# Terminate every Verda instance tagged with a coop slug, volumes included.
#
#   scripts/verda-teardown.sh --dry-run demo-coop-1
#   VERDA_CLIENT_ID=... VERDA_CLIENT_SECRET=... scripts/verda-teardown.sh --yes demo-coop-1
#
# This mirrors lib/verda.ts in the web app: the platform calls the same API on
# close-out, so a coop cannot stay billing after it is archived. Deleting the
# volumes matters — an orphaned OS volume keeps charging on its own.
set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
readonly SCRIPT_DIR
readonly ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
readonly API=${VERDA_API:-https://api.verda.com/v1}
readonly STATE_DIR=${STATE_DIR:-$ROOT/state/verda}

DRY_RUN=0
ASSUME_YES=0
SLUG=

usage() {
  cat <<'EOF'
usage: verda-teardown.sh [--dry-run|--yes] <coop-slug>

  --dry-run   list what would be deleted; no writes
  --yes       actually delete instances and their volumes
  -h, --help  this text

Environment:
  VERDA_CLIENT_ID, VERDA_CLIENT_SECRET  Cloud API credentials
  VERDA_API, STATE_DIR                  overrides for testing

Exit codes: 2 usage, 5 auth, 6 list, 7 delete.
EOF
}

log() { printf '%s\n' "$*"; }
die() { # die <message> [exit-code]
  local message=$1 code=${2:-1}
  printf 'FAILED %s\n' "$message" >&2
  exit "$code"
}

while (($#)); do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --yes) ASSUME_YES=1 ;;
    -h | --help)
      usage
      exit 0
      ;;
    -*) die "unknown option $1" 2 ;;
    *)
      [[ -z $SLUG ]] || die "one slug at a time" 2
      SLUG=$1
      ;;
  esac
  shift
done

[[ -n $SLUG ]] || {
  usage >&2
  exit 2
}
command -v jq >/dev/null || die "jq not found" 2

if ((!DRY_RUN && !ASSUME_YES)); then
  die "refusing to delete without --yes (use --dry-run to inspect)" 2
fi

if ((DRY_RUN)); then
  log "would delete: instances tagged coop_slug=$SLUG (and their volumes)"
  exit 0
fi

: "${VERDA_CLIENT_ID:?VERDA_CLIENT_ID is required}"
: "${VERDA_CLIENT_SECRET:?VERDA_CLIENT_SECRET is required}"

ACCESS_TOKEN=$(curl -fsS -X POST "$API/oauth2/token" \
  -H 'Content-Type: application/json' \
  -d "$(jq -n --arg id "$VERDA_CLIENT_ID" --arg secret "$VERDA_CLIENT_SECRET" \
    '{grant_type: "client_credentials", client_id: $id, client_secret: $secret}')" |
  jq -r '.access_token // empty') || die "token request failed" 5
[[ -n $ACCESS_TOKEN ]] || die "no access token returned" 5

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

rows=$(api GET "/instances?tag=coop_slug=$SLUG") || die "instance list failed" 6
# The query filter is the contract, but a filter bug must not delete another
# coop's box, so the tag is matched again locally.
ids=$(jq -r --arg slug "$SLUG" '
  [.[] | select(any(.tags[]?; .key == "coop_slug" and .value == $slug)) | .id]
  | .[]' <<<"$rows")
volumes=$(jq -r --arg slug "$SLUG" '
  [.[] | select(any(.tags[]?; .key == "coop_slug" and .value == $slug))
       | (.os_volume_id // empty), (.volume_ids[]?)]
  | .[]' <<<"$rows")

if [[ -z $ids ]]; then
  log "nothing found for $SLUG"
  rm -f "$STATE_DIR/$SLUG.env"
  exit 0
fi

log "deleting instance(s): $(tr '\n' ' ' <<<"$ids")"
# Empty lines must not become "" volume ids: the API rejects unknown ids and
# would abort a delete that is otherwise fine.
payload=$(jq -n \
  --argjson ids "$(sed '/^$/d' <<<"$ids" | jq -R . | jq -s .)" \
  --argjson vols "$(sed '/^$/d' <<<"$volumes" | jq -R . | jq -s .)" \
  '{action: "delete", id: $ids, volume_ids: $vols}')
api POST "/instances/action" "$payload" >/dev/null || die "delete failed" 7

log "deleted; volumes: $(tr '\n' ' ' <<<"$volumes")"
rm -f "$STATE_DIR/$SLUG.env"
