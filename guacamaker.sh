#!/usr/bin/env bash
set -euo pipefail

# ─── Config ──────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_CONF="$SCRIPT_DIR/env.conf"
MAPPING_LIST="$SCRIPT_DIR/mapping.list"
DRY_RUN=0

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    *) echo "[ERROR] Unknown argument: $arg" >&2; exit 1 ;;
  esac
done

for cmd in curl jq; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "[ERROR] Required command not found: $cmd" >&2
    exit 1
  fi
done

if [[ ! -f "$ENV_CONF" ]]; then
  echo "[ERROR] env.conf not found at: $ENV_CONF" >&2
  exit 1
fi
if [[ ! -f "$MAPPING_LIST" ]]; then
  echo "[ERROR] mapping.list not found at: $MAPPING_LIST" >&2
  exit 1
fi

# shellcheck source=/dev/null
source "$ENV_CONF"

GUAC_DATA_SOURCE="${GUAC_DATA_SOURCE:-mysql}"

for var in GUAC_API_URL GUAC_ADMIN_USER GUAC_ADMIN_PASS; do
  if [[ -z "${!var:-}" ]]; then
    echo "[ERROR] $var is not set in env.conf" >&2
    exit 1
  fi
done

TOKEN=""
DATA_SOURCE=""

# ─── API Layer ───────────────────────────────────────────────────────────────

api_login() {
  echo "[INFO] Logging in to $GUAC_API_URL..." >&2
  local response http_code body
  response=$(curl -s -w "\n%{http_code}" \
    -X POST "$GUAC_API_URL/api/tokens" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    --data-urlencode "username=$GUAC_ADMIN_USER" \
    --data-urlencode "password=$GUAC_ADMIN_PASS")
  http_code=$(tail -1 <<< "$response")
  body=$(sed '$d' <<< "$response")
  if [[ "$http_code" != "200" ]]; then
    echo "[ERROR] Login failed (HTTP $http_code): $body" >&2
    exit 1
  fi
  TOKEN=$(jq -r '.authToken' <<< "$body")
  DATA_SOURCE=$(jq -r '.dataSource' <<< "$body")
  if [[ "$TOKEN" == "null" || -z "$TOKEN" ]]; then
    echo "[ERROR] Failed to extract authToken from login response" >&2
    exit 1
  fi
}

api_get() {
  local path="$1"
  local response http_code body
  response=$(curl -s -w "\n%{http_code}" \
    -H "Guacamole-Token: $TOKEN" \
    "$GUAC_API_URL$path")
  http_code=$(tail -1 <<< "$response")
  body=$(sed '$d' <<< "$response")
  if [[ "$http_code" != "200" ]]; then
    echo "[ERROR] GET $path failed (HTTP $http_code): $body" >&2
    exit 1
  fi
  echo "$body"
}

api_post() {
  local path="$1" body="$2"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[DRY-RUN] Would POST $path" >&2
    echo '{"identifier":"0"}'
    return
  fi
  local response http_code resp_body
  response=$(curl -s -w "\n%{http_code}" \
    -X POST "$GUAC_API_URL$path" \
    -H "Content-Type: application/json" \
    -H "Guacamole-Token: $TOKEN" \
    -d "$body")
  http_code=$(tail -1 <<< "$response")
  resp_body=$(sed '$d' <<< "$response")
  if [[ "$http_code" != "200" ]]; then
    echo "[ERROR] POST $path failed (HTTP $http_code): $resp_body" >&2
    exit 1
  fi
  echo "$resp_body"
}

api_put() {
  local path="$1" body="$2"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[DRY-RUN] Would PUT $path" >&2
    return
  fi
  local response http_code resp_body
  response=$(curl -s -w "\n%{http_code}" \
    -X PUT "$GUAC_API_URL$path" \
    -H "Content-Type: application/json" \
    -H "Guacamole-Token: $TOKEN" \
    -d "$body")
  http_code=$(tail -1 <<< "$response")
  resp_body=$(sed '$d' <<< "$response")
  if [[ "$http_code" != "200" && "$http_code" != "204" ]]; then
    echo "[ERROR] PUT $path failed (HTTP $http_code): $resp_body" >&2
    exit 1
  fi
}

api_patch() {
  local path="$1" body="$2"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[DRY-RUN] Would PATCH $path" >&2
    return
  fi
  local response http_code resp_body
  response=$(curl -s -w "\n%{http_code}" \
    -X PATCH "$GUAC_API_URL$path" \
    -H "Content-Type: application/json" \
    -H "Guacamole-Token: $TOKEN" \
    -d "$body")
  http_code=$(tail -1 <<< "$response")
  resp_body=$(sed '$d' <<< "$response")
  if [[ "$http_code" != "200" && "$http_code" != "204" ]]; then
    echo "[ERROR] PATCH $path failed (HTTP $http_code): $resp_body" >&2
    exit 1
  fi
}
