# GuacaMaker Script Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 實作 `guacamaker.sh`，讀取 `env.conf` 和 `mapping.list`，透過 Guacamole REST API 批次建立或更新 users、connection groups、connections，並完成授權指派。

**Architecture:** 單一 bash 腳本，分四區塊：Config（讀設定/解析參數）、API 層（curl 封裝）、資源層（upsert 邏輯）、主流程（逐行處理 mapping.list）。所有 INFO 訊息輸出至 stderr；ensure_* 函數僅透過 stdout 回傳 ID，讓 `$()` 捕捉乾淨。

**Tech Stack:** bash (`set -euo pipefail`)、`curl`、`jq`。無外部依賴需安裝。

---

## 檔案結構

| 路徑 | 動作 | 說明 |
|---|---|---|
| `guacamaker.sh` | 新增 | 主腳本 |
| `env.conf.example` | 修改 | 新增 `GUAC_DATA_SOURCE` 欄位 |

---

### Task 1：腳本骨架、依賴檢查、設定讀取

**Files:**
- Create: `guacamaker.sh`

- [ ] **Step 1：建立腳本骨架**

建立 `guacamaker.sh`，內容如下：

```bash
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
```

- [ ] **Step 2：設為可執行並檢查語法**

```bash
chmod +x guacamaker.sh
bash -n guacamaker.sh
```

預期輸出：無任何輸出（語法正確）。

- [ ] **Step 3：Commit**

```bash
git add guacamaker.sh
git commit -m "feat: add guacamaker.sh scaffold with config loading and dependency check"
```

---

### Task 2：API 層——登入與 CRUD 函數

**Files:**
- Modify: `guacamaker.sh`

- [ ] **Step 1：在 `TOKEN=""` 行之後加入 API 層**

在 `DATA_SOURCE=""` 那行之後，緊接著加入：

```bash

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
```

- [ ] **Step 2：確認語法**

```bash
bash -n guacamaker.sh
```

預期輸出：無任何輸出。

- [ ] **Step 3：Commit**

```bash
git add guacamaker.sh
git commit -m "feat: add API layer (login, get, post, put, patch)"
```

---

### Task 3：資源層——ensure_connection_group

**Files:**
- Modify: `guacamaker.sh`

- [ ] **Step 1：在 api_patch 之後加入 Resource 層標題與 ensure_connection_group**

```bash

# ─── Resource Layer ──────────────────────────────────────────────────────────

ensure_connection_group() {
  local name="$1"
  local groups existing_id
  groups=$(api_get "/api/session/data/$DATA_SOURCE/connectionGroups")
  existing_id=$(jq -r --arg name "$name" '
    to_entries[]
    | select(.value.name == $name and .key != "ROOT")
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
```

- [ ] **Step 2：確認語法**

```bash
bash -n guacamaker.sh
```

預期輸出：無任何輸出。

- [ ] **Step 3：Commit**

```bash
git add guacamaker.sh
git commit -m "feat: add ensure_connection_group with upsert logic"
```

---

### Task 4：資源層——ensure_connection

**Files:**
- Modify: `guacamaker.sh`

- [ ] **Step 1：在 ensure_connection_group 之後加入 ensure_connection**

```bash
ensure_connection() {
  local name="$1" group_id="$2" protocol="$3" ip="$4" port="$5"
  local account="$6" password="$7" domain="$8"
  local connections existing_id
  connections=$(api_get "/api/session/data/$DATA_SOURCE/connections")
  existing_id=$(jq -r --arg name "$name" --arg gid "$group_id" '
    to_entries[]
    | select(.value.name == $name and .value.parentIdentifier == $gid)
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
```

- [ ] **Step 2：確認語法**

```bash
bash -n guacamaker.sh
```

預期輸出：無任何輸出。

- [ ] **Step 3：Commit**

```bash
git add guacamaker.sh
git commit -m "feat: add ensure_connection with upsert logic"
```

---

### Task 5：資源層——ensure_user 與 assign_connection

**Files:**
- Modify: `guacamaker.sh`

- [ ] **Step 1：在 ensure_connection 之後加入 ensure_user 和 assign_connection**

```bash
ensure_user() {
  local username="$1" password="$2"
  local users body
  users=$(api_get "/api/session/data/$DATA_SOURCE/users")
  body=$(jq -n --arg u "$username" --arg p "$password" \
    '{"username":$u,"password":$p,"attributes":{}}')

  if jq -e --arg u "$username" 'has($u)' <<< "$users" &>/dev/null; then
    api_put "/api/session/data/$DATA_SOURCE/users/$username" "$body"
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
  api_patch "/api/session/data/$DATA_SOURCE/users/$username/permissions" "$body"
  echo "[INFO]   assigned $conn_name to $username" >&2
}
```

- [ ] **Step 2：確認語法**

```bash
bash -n guacamaker.sh
```

預期輸出：無任何輸出。

- [ ] **Step 3：Commit**

```bash
git add guacamaker.sh
git commit -m "feat: add ensure_user and assign_connection"
```

---

### Task 6：主流程

**Files:**
- Modify: `guacamaker.sh`

- [ ] **Step 1：在 assign_connection 之後加入主流程**

```bash

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

done < <(grep -v '^#' "$MAPPING_LIST" | grep -v '^[[:space:]]*$')

echo "[INFO] Done. $row_num rows processed." >&2
```

- [ ] **Step 2：確認完整語法**

```bash
bash -n guacamaker.sh
```

預期輸出：無任何輸出。

- [ ] **Step 3：確認 --dry-run 參數可被接受（不連 API，僅測試參數解析）**

```bash
# 暫時把 api_login 呼叫注解掉，確認 --dry-run 旗標本身不報錯
bash -c 'source ./guacamaker.sh --dry-run 2>&1 || true' | head -5
```

> 注意：此步驟僅確認旗標解析正確；完整 dry-run 測試需要 env.conf 和可用的 Guacamole 實例（GET 仍會呼叫真實 API）。

- [ ] **Step 4：Commit**

```bash
git add guacamaker.sh
git commit -m "feat: add main flow to process mapping.list"
```

---

### Task 7：更新 env.conf.example

**Files:**
- Modify: `env.conf.example`

- [ ] **Step 1：在 env.conf.example 末尾加入 GUAC_DATA_SOURCE**

在 `GUAC_ADMIN_PASS=guacadmin` 那行之後加入：

```bash

# Guacamole 資料來源名稱（API 路徑 /api/session/data/{dataSource}/... 用）
# 預設為 mysql；若使用 PostgreSQL 後端，請改為 postgresql
GUAC_DATA_SOURCE=mysql
```

- [ ] **Step 2：確認 GUAC_ 變數共 4 個**

```bash
grep -c "^GUAC_" env.conf.example
```

預期輸出：`4`

- [ ] **Step 3：Commit**

```bash
git add env.conf.example
git commit -m "feat: add GUAC_DATA_SOURCE field to env.conf.example"
```

---

## 驗收標準

完成後，下列確認應全部通過：

```bash
# 1. 語法正確
bash -n guacamaker.sh

# 2. 可執行
[[ -x guacamaker.sh ]] && echo "OK"

# 3. env.conf.example 有 4 個 GUAC_ 變數
grep -c "^GUAC_" env.conf.example   # → 4

# 4. 缺少 env.conf 時報錯且 exit 1
bash guacamaker.sh 2>&1 | grep "env.conf not found"

# 5. 缺少依賴時報錯（模擬 jq 不存在）
PATH=/usr/bin bash guacamaker.sh 2>&1 | grep "Required command not found" || true
```
