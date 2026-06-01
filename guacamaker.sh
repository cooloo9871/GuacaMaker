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
    --create)  [[ -n "$MODE" ]] && { echo "[ERROR] --create, --delete and --list are mutually exclusive" >&2; exit 1; }; MODE=create ;;
    --delete)  [[ -n "$MODE" ]] && { echo "[ERROR] --create, --delete and --list are mutually exclusive" >&2; exit 1; }; MODE=delete ;;
    --list)    [[ -n "$MODE" ]] && { echo "[ERROR] --create, --delete, --list and --list-pw are mutually exclusive" >&2; exit 1; }; MODE=list ;;
    --list-pw) [[ -n "$MODE" ]] && { echo "[ERROR] --create, --delete, --list and --list-pw are mutually exclusive" >&2; exit 1; }; MODE=list-pw ;;
    --dry-run) DRY_RUN=1 ;;
    *) echo "[ERROR] Unknown argument: $arg" >&2; exit 1 ;;
  esac
done

if [[ -z "$MODE" ]]; then
  echo "Usage: guacamaker.sh --create | --delete | --list | --list-pw [--dry-run]" >&2
  echo "" >&2
  echo "  --create     建立或更新 mapping.list 中的 users 與 connections" >&2
  echo "  --delete     刪除 mapping.list 中的 users、connections 及空的 connection groups" >&2
  echo "  --list       列出所有帳號與密碼（CSV 格式）" >&2
  echo "  --list-pw    只列出密碼欄位" >&2
  echo "  --dry-run    模擬執行，不實際呼叫寫入 API（適用 --create 與 --delete）" >&2
  exit 1
fi

if [[ "$MODE" == "list" || "$MODE" == "list-pw" ]]; then
  if [[ ! -f "$SCRIPT_DIR/passwords.csv" ]]; then
    echo "[ERROR] passwords.csv not found at $SCRIPT_DIR/passwords.csv. Run --create first." >&2
    exit 1
  fi
  if [[ "$MODE" == "list" ]]; then
    cat "$SCRIPT_DIR/passwords.csv"
  else
    awk -F, 'NR==1{print "userPassword"} NR>1{print $2}' "$SCRIPT_DIR/passwords.csv"
  fi
  exit 0
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

api_delete() {
  local path="$1"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[DRY-RUN] Would DELETE $path" >&2
    echo "204"
    return
  fi
  local response http_code resp_body
  response=$(curl -s -w "\n%{http_code}" \
    -X DELETE "$GUAC_API_URL$path" \
    -H "Guacamole-Token: $TOKEN")
  http_code=$(tail -1 <<< "$response")
  resp_body=$(sed '$d' <<< "$response")
  if [[ "$http_code" != "200" && "$http_code" != "204" && "$http_code" != "404" ]]; then
    echo "[ERROR] DELETE $path failed (HTTP $http_code): $resp_body" >&2
    exit 1
  fi
  echo "$http_code"
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
  if [[ "$protocol" == "rdp" ]]; then
    if [[ -n "$domain" ]]; then
      params=$(jq -n \
        --arg h "$ip" --arg p "$port" \
        --arg u "$account" --arg pw "$password" --arg d "$domain" \
        '{"hostname":$h,"port":$p,"username":$u,"password":$pw,"domain":$d,"security":"any","ignore-cert":"true"}')
    else
      params=$(jq -n \
        --arg h "$ip" --arg p "$port" \
        --arg u "$account" --arg pw "$password" \
        '{"hostname":$h,"port":$p,"username":$u,"password":$pw,"security":"any","ignore-cert":"true"}')
    fi
  elif [[ -n "$domain" ]]; then
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
  local users
  _user_created=0
  _user_password=""
  users=$(api_get "/api/session/data/$DATA_SOURCE/users")

  if jq -e --arg u "$username" 'has($u)' <<< "$users" &>/dev/null; then
    echo "[INFO]   user '$username'... exists (password unchanged)" >&2
  else
    if [[ -z "$password" ]]; then
      password=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 7 || true)
    fi
    local body
    body=$(jq -n --arg u "$username" --arg p "$password" \
      '{"username":$u,"password":$p,"attributes":{}}')
    api_post "/api/session/data/$DATA_SOURCE/users" "$body" >/dev/null
    echo "[INFO]   user '$username'... created" >&2
    _user_created=1
    _user_password="$password"
  fi
}

assign_connection() {
  local username="$1" conn_id="$2" conn_name="$3" group_id="$4"
  local body
  body=$(jq -n --arg cid "$conn_id" --arg gid "$group_id" '[
    {"op":"add","path":("/connectionPermissions/" + $cid),"value":"READ"},
    {"op":"add","path":("/connectionGroupPermissions/" + $gid),"value":"READ"}
  ]')
  api_patch "/api/session/data/$DATA_SOURCE/users/$(url_encode "$username")/permissions" "$body"
  echo "[INFO]   assigned $conn_name to $username" >&2
}

delete_user() {
  local username="$1"
  local status
  _user_deleted=0
  status=$(api_delete "/api/session/data/$DATA_SOURCE/users/$(url_encode "$username")")
  if [[ "$status" == "404" ]]; then
    echo "[INFO]   user '$username'... not found, skipped" >&2
  else
    echo "[INFO]   user '$username'... deleted" >&2
    _user_deleted=1
  fi
}

delete_connection() {
  local name="$1" group_id="$2"
  local connections existing_id
  connections=$(api_get "/api/session/data/$DATA_SOURCE/connections")
  existing_id=$(jq -r --arg name "$name" --arg gid "$group_id" '
    to_entries[]
    | select(.value.name == $name and .value.parentIdentifier == $gid and .value.identifier != null)
    | .value.identifier
  ' <<< "$connections" | head -1)

  if [[ -z "$existing_id" ]]; then
    echo "[INFO]   connection '$name'... not found, skipped" >&2
    return
  fi

  local status
  status=$(api_delete "/api/session/data/$DATA_SOURCE/connections/$existing_id")
  if [[ "$status" == "404" ]]; then
    echo "[INFO]   connection '$name'... not found, skipped" >&2
  else
    echo "[INFO]   connection '$name'... deleted (id=$existing_id)" >&2
  fi
}

delete_connection_group_if_empty() {
  local name="$1"
  local groups group_id
  groups=$(api_get "/api/session/data/$DATA_SOURCE/connectionGroups")
  group_id=$(jq -r --arg name "$name" '
    to_entries[]
    | select(.value.name == $name and .key != "ROOT" and .value.identifier != null)
    | .value.identifier
  ' <<< "$groups" | head -1)

  if [[ -z "$group_id" ]]; then
    echo "[INFO]   connection group '$name'... not found, skipped" >&2
    return
  fi

  local connections remaining
  connections=$(api_get "/api/session/data/$DATA_SOURCE/connections")
  remaining=$(jq -r --arg gid "$group_id" '
    [to_entries[] | select(.value.parentIdentifier == $gid)] | length
  ' <<< "$connections")

  if [[ "$remaining" -gt 0 ]]; then
    echo "[INFO]   connection group '$name'... kept (has connections)" >&2
  else
    local gs
    gs=$(api_delete "/api/session/data/$DATA_SOURCE/connectionGroups/$group_id")
    if [[ "$gs" == "404" ]]; then
      echo "[INFO]   connection group '$name'... not found, skipped" >&2
    else
      echo "[INFO]   connection group '$name'... deleted (empty)" >&2
    fi
  fi
}

# ─── Main ────────────────────────────────────────────────────────────────────

trap '
  if [[ "$MODE" == "create" && "$DRY_RUN" -eq 0 && "${#pw_accounts[@]}" -gt 0 ]]; then
    if [[ -f "$SCRIPT_DIR/passwords.csv" ]]; then
      for i in "${!pw_accounts[@]}"; do
        echo "${pw_accounts[$i]},${pw_passwords[$i]}"
      done >> "$SCRIPT_DIR/passwords.csv"
    else
      {
        echo "userAccount,userPassword"
        for i in "${!pw_accounts[@]}"; do
          echo "${pw_accounts[$i]},${pw_passwords[$i]}"
        done
      } > "$SCRIPT_DIR/passwords.csv"
    fi
    echo "[INFO] Passwords saved to $SCRIPT_DIR/passwords.csv" >&2
  fi
  if [[ "$MODE" == "delete" && "$DRY_RUN" -eq 0 && "${#_deleted_accounts[@]}" -gt 0 && -f "$SCRIPT_DIR/passwords.csv" ]]; then
    _tmp=$(mktemp)
    head -1 "$SCRIPT_DIR/passwords.csv" > "$_tmp"
    while IFS=, read -r acct pw; do
      _skip=0
      for _d in "${_deleted_accounts[@]}"; do
        [[ "$acct" == "$_d" ]] && _skip=1 && break
      done
      [[ "$_skip" -eq 0 ]] && echo "$acct,$pw"
    done < <(tail -n +2 "$SCRIPT_DIR/passwords.csv") >> "$_tmp"
    mv "$_tmp" "$SCRIPT_DIR/passwords.csv"
    echo "[INFO] Removed deleted users from $SCRIPT_DIR/passwords.csv" >&2
  fi
' EXIT

api_login

pw_accounts=()
pw_passwords=()
_deleted_accounts=()
declare -A _seen_users
row_num=0
while IFS='|' read -r userAccount userPassword connGroup connName \
                       connProtocol connIP connPort connAccount connPassword connDomain; do
  [[ -z "$userAccount" ]] && continue
  row_num=$((row_num + 1))
  echo "[INFO] Row $row_num: $userAccount → $connName" >&2

  if [[ "$MODE" == "create" ]]; then
    group_id=$(ensure_connection_group "$connGroup")
    conn_id=$(ensure_connection "$connName" "$group_id" "$connProtocol" \
               "$connIP" "$connPort" "$connAccount" "$connPassword" "$connDomain")
    ensure_user "$userAccount" "$userPassword"
    if [[ "$_user_created" -eq 1 && -z "${_seen_users[$userAccount]:-}" ]]; then
      pw_accounts+=("$userAccount")
      pw_passwords+=("$_user_password")
      _seen_users[$userAccount]=1
    fi
    assign_connection "$userAccount" "$conn_id" "$connName" "$group_id"
  else
    _groups=$(api_get "/api/session/data/$DATA_SOURCE/connectionGroups")
    group_id=$(jq -r --arg name "$connGroup" '
      to_entries[]
      | select(.value.name == $name and .key != "ROOT" and .value.identifier != null)
      | .value.identifier
    ' <<< "$_groups" | head -1)
    if [[ -z "$group_id" ]]; then
      echo "[WARN]   connection group '$connGroup'... not found, skipping connection lookup" >&2
    fi
    delete_user "$userAccount"
    [[ "$_user_deleted" -eq 1 ]] && _deleted_accounts+=("$userAccount")
    delete_connection "$connName" "$group_id"
    delete_connection_group_if_empty "$connGroup"
  fi

done < <(sed 's/\r//' "$MAPPING_LIST" | grep -v '^#' | grep -v '^[[:space:]]*$')

echo "[INFO] Done. $row_num rows processed." >&2
