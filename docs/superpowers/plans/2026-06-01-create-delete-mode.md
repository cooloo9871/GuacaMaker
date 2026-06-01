# Create / Delete Mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 `guacamaker.sh` 加入 `--create`（現有 upsert 行為）與 `--delete`（刪除 user、connection、空 group）兩個執行模式；無旗標時顯示用法說明並退出。

**Architecture:** 在現有單一腳本中新增 `MODE` 變數控制分支，API 層補充 `api_delete()`，Resource 層補充三個 delete 函數，主流程依 `MODE` 執行 create 或 delete 路徑。

**Tech Stack:** bash、curl、jq（不新增依賴）

---

## 檔案結構

| 路徑 | 動作 | 說明 |
|---|---|---|
| `guacamaker.sh` | 修改 | 加入 MODE 解析、api_delete、delete_* 函數、主流程分支 |
| `README.md` | 修改 | 更新用法說明，加入 --create / --delete |

---

### Task 1：Config 區塊——MODE 解析與用法說明

**Files:**
- Modify: `guacamaker.sh` (lines 9-16)

- [ ] **Step 1：將 Config 區塊的 `DRY_RUN=0` 及參數解析替換為以下內容**

找到這段（lines 9-16）：
```bash
DRY_RUN=0

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    *) echo "[ERROR] Unknown argument: $arg" >&2; exit 1 ;;
  esac
done
```

替換為：
```bash
DRY_RUN=0
MODE=""

for arg in "$@"; do
  case "$arg" in
    --create)  MODE=create ;;
    --delete)  MODE=delete ;;
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
```

- [ ] **Step 2：確認語法與用法說明輸出**

```bash
bash -n guacamaker.sh
```
預期：無輸出。

```bash
./guacamaker.sh 2>&1
```
預期輸出：
```
Usage: guacamaker.sh --create | --delete [--dry-run]

  --create    建立或更新 mapping.list 中的 users 與 connections
  --delete    刪除 mapping.list 中的 users、connections 及空的 connection groups
  --dry-run   模擬執行，不實際呼叫寫入 API
```

- [ ] **Step 3：Commit**

```bash
git add guacamaker.sh
git commit -m "feat: add --create/--delete mode parsing with usage message"
```

---

### Task 2：API 層——api_delete

**Files:**
- Modify: `guacamaker.sh`（在 `api_patch` 函數結尾 `}` 之後加入）

- [ ] **Step 1：在 api_patch 函數之後加入 api_delete**

在 `api_patch()` 的結尾 `}` 後緊接著加入：

```bash

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
```

> `api_delete` 將 HTTP 狀態碼 echo 至 stdout，讓呼叫端判斷 200/204（成功）或 404（不存在）。

- [ ] **Step 2：確認語法**

```bash
bash -n guacamaker.sh
```
預期：無輸出。

- [ ] **Step 3：Commit**

```bash
git add guacamaker.sh
git commit -m "feat: add api_delete with 404 tolerance"
```

---

### Task 3：Resource 層——delete_user、delete_connection、delete_connection_group_if_empty

**Files:**
- Modify: `guacamaker.sh`（在 `assign_connection` 函數結尾 `}` 之後加入）

- [ ] **Step 1：在 assign_connection 之後加入三個 delete 函數**

在 `assign_connection()` 的結尾 `}` 後緊接著加入：

```bash

delete_user() {
  local username="$1"
  local status
  status=$(api_delete "/api/session/data/$DATA_SOURCE/users/$(url_encode "$username")")
  if [[ "$status" == "404" ]]; then
    echo "[INFO]   user '$username'... not found, skipped" >&2
  else
    echo "[INFO]   user '$username'... deleted" >&2
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
    api_delete "/api/session/data/$DATA_SOURCE/connectionGroups/$group_id" >/dev/null
    echo "[INFO]   connection group '$name'... deleted (empty)" >&2
  fi
}
```

- [ ] **Step 2：確認語法**

```bash
bash -n guacamaker.sh
```
預期：無輸出。

- [ ] **Step 3：Commit**

```bash
git add guacamaker.sh
git commit -m "feat: add delete_user, delete_connection, delete_connection_group_if_empty"
```

---

### Task 4：主流程——MODE 分支

**Files:**
- Modify: `guacamaker.sh`（Main 區塊，約 line 280 附近）

- [ ] **Step 1：將主流程 while 迴圈內容替換為 MODE 分支**

找到 while 迴圈內部這段（在 `echo "[INFO] Row $row_num: ..."` 之後）：

```bash
  group_id=$(ensure_connection_group "$connGroup")
  conn_id=$(ensure_connection "$connName" "$group_id" "$connProtocol" \
             "$connIP" "$connPort" "$connAccount" "$connPassword" "$connDomain")
  ensure_user "$userAccount" "$userPassword"
  assign_connection "$userAccount" "$conn_id" "$connName"
```

替換為：

```bash
  if [[ "$MODE" == "create" ]]; then
    group_id=$(ensure_connection_group "$connGroup")
    conn_id=$(ensure_connection "$connName" "$group_id" "$connProtocol" \
               "$connIP" "$connPort" "$connAccount" "$connPassword" "$connDomain")
    ensure_user "$userAccount" "$userPassword"
    assign_connection "$userAccount" "$conn_id" "$connName"
  else
    _groups=$(api_get "/api/session/data/$DATA_SOURCE/connectionGroups")
    group_id=$(jq -r --arg name "$connGroup" '
      to_entries[]
      | select(.value.name == $name and .key != "ROOT" and .value.identifier != null)
      | .value.identifier
    ' <<< "$_groups" | head -1)
    delete_user "$userAccount"
    delete_connection "$connName" "$group_id"
    delete_connection_group_if_empty "$connGroup"
  fi
```

- [ ] **Step 2：確認語法**

```bash
bash -n guacamaker.sh
```
預期：無輸出。

- [ ] **Step 3：確認 --create 舊行為不變、--delete 旗標被接受**

```bash
./guacamaker.sh --create 2>&1 | head -3
```
預期：看到 `[INFO] Logging in to ...`（或 env.conf 相關錯誤，不應出現 Unknown argument）

```bash
./guacamaker.sh --delete 2>&1 | head -3
```
預期：同上（接受旗標）

```bash
./guacamaker.sh --create --dry-run 2>&1 | head -3
```
預期：看到 `[INFO] Logging in to ...`

- [ ] **Step 4：Commit**

```bash
git add guacamaker.sh
git commit -m "feat: branch main flow on --create / --delete mode"
```

---

### Task 5：更新 README

**Files:**
- Modify: `README.md`

- [ ] **Step 1：將「用法」章節的執行指令更新**

找到：
```bash
### 正常執行

```bash
./guacamaker.sh
```
```

替換為：
```markdown
### 建立或更新（--create）

```bash
./guacamaker.sh --create
```
```

- [ ] **Step 2：在 --create 區塊之後加入 --delete 說明**

在 `--create` 執行輸出範例之後，新增：

```markdown
### 刪除（--delete）

```bash
./guacamaker.sh --delete
```

依序刪除 `mapping.list` 中每筆資料的 user、connection，若 connection group 已無任何 connection 則一併刪除。

執行時輸出範例：

```
[INFO] Logging in to http://localhost:8080/guacamole...
[INFO] Row 1: alice → WinServer01
[INFO]   user 'alice'... deleted
[INFO]   connection 'WinServer01'... deleted (id=7)
[INFO]   connection group 'ServerGroup'... kept (has connections)
[INFO] Row 2: bob → LinuxBox01
[INFO]   user 'bob'... deleted
[INFO]   connection 'LinuxBox01'... deleted (id=8)
[INFO]   connection group 'ServerGroup'... deleted (empty)
[INFO] Done. 2 rows processed.
```
```

- [ ] **Step 3：更新 Dry-run 說明，反映兩個模式都支援**

找到：
```bash
./guacamaker.sh --dry-run
```

替換為：
```bash
./guacamaker.sh --create --dry-run
./guacamaker.sh --delete --dry-run
```

- [ ] **Step 4：Commit**

```bash
git add README.md
git commit -m "docs: update README for --create/--delete modes"
```

---

## 驗收標準

```bash
# 1. 語法正確
bash -n guacamaker.sh

# 2. 無旗標顯示用法
./guacamaker.sh 2>&1 | grep "Usage:"

# 3. --create 旗標被接受（不報 Unknown argument）
./guacamaker.sh --create 2>&1 | grep -v "Unknown argument"

# 4. --delete 旗標被接受
./guacamaker.sh --delete 2>&1 | grep -v "Unknown argument"

# 5. --dry-run 可與兩個模式組合
./guacamaker.sh --create --dry-run 2>&1 | grep -v "Unknown argument"
./guacamaker.sh --delete --dry-run 2>&1 | grep -v "Unknown argument"
```
