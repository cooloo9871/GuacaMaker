#!/usr/bin/env bash
set -euo pipefail

# ─── Config ──────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_CONF="$SCRIPT_DIR/env.conf"
MAPPING_LIST="$SCRIPT_DIR/mapping.list"
DRY_RUN=0
MODE=""

for arg in "$@"; do
  case "$arg" in
    --create)  [[ -n "$MODE" ]] && { echo "[ERROR] --create and --delete are mutually exclusive" >&2; exit 1; }; MODE=create ;;
    --delete)  [[ -n "$MODE" ]] && { echo "[ERROR] --create and --delete are mutually exclusive" >&2; exit 1; }; MODE=delete ;;
    --dry-run) DRY_RUN=1 ;;
    *) echo "[ERROR] Unknown argument: $arg" >&2; exit 1 ;;
  esac
done

if [[ -z "$MODE" ]]; then
  echo "Usage: guacamaker.sh --create | --delete [--dry-run]" >&2
  echo "" >&2
  echo "  --create    建立或更新 mapping.list 中的 users 與 connections" >&2
  echo "  --delete    刪除 mapping.list 中的 users、connections 及空的 connection groups" >&2
  echo "  --dry-run   模擬執行，不實際呼叫寫入 API" >&2
  exit 1
fi

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

  if [[ "$http_code" == "403" ]] && \
     jq -e '.type == "INSUFFICIENT_CREDENTIALS" and ([.expected[]?.name] | contains(["guac-totp"]))' \
     <<< "$body" &>/dev/null; then
    local totp_code
    printf "[INFO] TOTP required. Enter code: " >&2
    read -r totp_code < /dev/tty
    response=$(curl -s -w "\n%{http_code}" \
      -X POST "$GUAC_API_URL/api/tokens" \
      -H "Content-Type: application/x-www-form-urlencoded" \
      --data-urlencode "username=$GUAC_ADMIN_USER" \
      --data-urlencode "password=$GUAC_ADMIN_PASS" \
      --data-urlencode "guac-totp=$totp_code")
    http_code=$(tail -1 <<< "$response")
    body=$(sed '$d' <<< "$response")
  fi

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
  if [[ "$DATA_SOURCE" == "null" || -z "$DATA_SOURCE" ]]; then
    DATA_SOURCE="$GUAC_DATA_SOURCE"
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

# ─── Resource Layer ──────────────────────────────────────────────────────────

url_encode() {
  jq -rn --arg s "$1" '$s | @uri'
}

ensure_connection_group() {
  local name="$1"
  local groups existing_id
  groups=$(api_get "/api/session/data/$DATA_SOURCE/connectionGroups")
  existing_id=$(jq -r --arg name "$name" '
    to_entries[]
    | select(.value.name == $name and .key != "ROOT" and .value.identifier != null)
    | .value.identifier
  ' <<< "$groups" | head -1)

  if [[ -z "$existing_id" ]]; then
    local body result new_id
    body=$(jq -n --arg name "$name" \
      '{"name":$name,"type":"ORGANIZATIONAL","parentIdentifier":"ROOT","attributes":{}}')
    result=$(api_post "/api/session/data/$DATA_SOURCE/connectionGroups" "$body")
    new_id=$(jq -r '.identifier' <<< "$result")
    echo "[INFO]   connection group '$name'... created (id=$new_id)" >&2
    echo "$new_id"
  else
    local body
    body=$(jq -n --arg name "$name" --arg id "$existing_id" \
      '{"name":$name,"type":"ORGANIZATIONAL","parentIdentifier":"ROOT","identifier":$id,"attributes":{}}')
    api_put "/api/session/data/$DATA_SOURCE/connectionGroups/$existing_id" "$body"
    echo "[INFO]   connection group '$name'... exists (id=$existing_id)" >&2
    echo "$existing_id"
  fi
}

ensure_connection() {
  local name="$1" group_id="$2" protocol="$3" ip="$4" port="$5"
  local account="$6" password="$7" domain="${8:-}"
  local connections existing_id
  connections=$(api_get "/api/session/data/$DATA_SOURCE/connections")
  existing_id=$(jq -r --arg name "$name" --arg gid "$group_id" '
    to_entries[]
    | select(.value.name == $name and .value.parentIdentifier == $gid and .value.identifier != null)
    | .value.identifier
  ' <<< "$connections" | head -1)

  local params
  if [[ -n "$domain" ]]; then
    params=$(jq -n \
      --arg h "$ip" --arg p "$port" \
      --arg u "$account" --arg pw "$password" --arg d "$domain" \
      '{"hostname":$h,"port":$p,"username":$u,"password":$pw,"domain":$d}')
  else
    params=$(jq -n \
      --arg h "$ip" --arg p "$port" \
      --arg u "$account" --arg pw "$password" \
      '{"hostname":$h,"port":$p,"username":$u,"password":$pw}')
  fi

  if [[ -z "$existing_id" ]]; then
    local body result new_id
    body=$(jq -n \
      --arg name "$name" --arg gid "$group_id" \
      --arg proto "$protocol" --argjson params "$params" \
      '{"name":$name,"parentIdentifier":$gid,"protocol":$proto,"parameters":$params,"attributes":{}}')
    result=$(api_post "/api/session/data/$DATA_SOURCE/connections" "$body")
    new_id=$(jq -r '.identifier' <<< "$result")
    echo "[INFO]   connection '$name'... created (id=$new_id)" >&2
    echo "$new_id"
  else
    local body
    body=$(jq -n \
      --arg name "$name" --arg gid "$group_id" \
      --arg proto "$protocol" --arg id "$existing_id" \
      --argjson params "$params" \
      '{"name":$name,"parentIdentifier":$gid,"protocol":$proto,"identifier":$id,"parameters":$params,"attributes":{}}')
    api_put "/api/session/data/$DATA_SOURCE/connections/$existing_id" "$body"
    echo "[INFO]   connection '$name'... updated (id=$existing_id)" >&2
    echo "$existing_id"
  fi
}

ensure_user() {
  local username="$1" password="$2"
  local users body
  users=$(api_get "/api/session/data/$DATA_SOURCE/users")
  body=$(jq -n --arg u "$username" --arg p "$password" \
    '{"username":$u,"password":$p,"attributes":{}}')

  if jq -e --arg u "$username" 'has($u)' <<< "$users" &>/dev/null; then
    api_put "/api/session/data/$DATA_SOURCE/users/$(url_encode "$username")" "$body"
    echo "[INFO]   user '$username'... updated" >&2
  else
    api_post "/api/session/data/$DATA_SOURCE/users" "$body" >/dev/null
    echo "[INFO]   user '$username'... created" >&2
  fi
}

assign_connection() {
  local username="$1" conn_id="$2" conn_name="$3"
  local body
  body=$(jq -n --arg cid "$conn_id" \
    '[{"op":"add","path":("/connectionPermissions/" + $cid),"value":"READ"}]')
  api_patch "/api/session/data/$DATA_SOURCE/users/$(url_encode "$username")/permissions" "$body"
  echo "[INFO]   assigned $conn_name to $username" >&2
}

# ─── Main ────────────────────────────────────────────────────────────────────

api_login

row_num=0
while IFS='|' read -r userAccount userPassword connGroup connName \
                       connProtocol connIP connPort connAccount connPassword connDomain; do
  [[ -z "$userAccount" ]] && continue
  row_num=$((row_num + 1))
  echo "[INFO] Row $row_num: $userAccount → $connName" >&2

  group_id=$(ensure_connection_group "$connGroup")
  conn_id=$(ensure_connection "$connName" "$group_id" "$connProtocol" \
             "$connIP" "$connPort" "$connAccount" "$connPassword" "$connDomain")
  ensure_user "$userAccount" "$userPassword"
  assign_connection "$userAccount" "$conn_id" "$connName"

done < <(sed 's/\r//' "$MAPPING_LIST" | grep -v '^#' | grep -v '^[[:space:]]*$')

echo "[INFO] Done. $row_num rows processed." >&2
