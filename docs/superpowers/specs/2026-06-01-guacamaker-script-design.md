# GuacaMaker 主腳本設計規格

**日期：** 2026-06-01
**狀態：** 已確認

## 概述

`guacamaker.sh` 是 GuacaMaker 的核心自動化腳本。讀取 `env.conf` 和 `mapping.list`，透過 Guacamole REST API 批次建立或更新使用者、連線群組、連線，並完成授權指派。

---

## 整體結構

```
guacamaker.sh
├── [1. Config]    讀取 env.conf、解析 CLI 參數
├── [2. API 層]    登入與通用 HTTP 函數
├── [3. 資源層]    ensure_* 函數與 assign_connection
└── [4. 主流程]    解析 mapping.list、依序呼叫資源層
```

---

## 執行流程

```
source env.conf
  → api_login() → 取得 TOKEN + DATA_SOURCE

逐行讀取 mapping.list（跳過 # 和空行）：
  → ensure_connection_group(connGroup)               → GROUP_ID
  → ensure_connection(connName, GROUP_ID, ...)        → CONN_ID
  → ensure_user(userAccount, userPassword)
  → assign_connection(userAccount, CONN_ID)
```

---

## CLI 介面

```bash
./guacamaker.sh              # 正常執行
./guacamaker.sh --dry-run    # 模擬執行，不實際呼叫寫入 API
```

---

## env.conf 變更

新增一個選填欄位（有預設值）：

| 變數 | 必填 | 預設值 | 說明 |
|---|---|---|---|
| `GUAC_API_URL` | 是 | — | Guacamole base URL |
| `GUAC_ADMIN_USER` | 是 | — | 管理員帳號 |
| `GUAC_ADMIN_PASS` | 是 | — | 管理員密碼 |
| `GUAC_DATA_SOURCE` | 否 | `mysql` | Guacamole 資料來源名稱（API 路徑用） |

---

## API 層

**依賴檢查：** 腳本啟動時確認 `curl` 和 `jq` 存在，缺少則報錯退出。

### api_login()

```
POST /api/tokens
body: username=...&password=...
→ 解析 JSON 取得 TOKEN、DATA_SOURCE
→ 後續請求帶 header: Guacamole-Token: $TOKEN
```

### 通用函數

| 函數 | 方法 | Dry-run 行為 |
|---|---|---|
| `api_get(path)` | GET | 正常執行（查詢不影響資料） |
| `api_post(path, body)` | POST | 印出 `[DRY-RUN] Would POST ...`，不執行 |
| `api_put(path, body)` | PUT | 印出 `[DRY-RUN] Would PUT ...`，不執行 |
| `api_patch(path, body)` | PATCH | 印出 `[DRY-RUN] Would PATCH ...`，不執行 |

**錯誤判斷：** 每個 curl 呼叫用 `-w "%{http_code}"` 取得 HTTP status code，非 2xx 印出錯誤訊息並 `exit 1`。

---

## 資源層

所有函數遵循 **upsert 邏輯**：GET 清單判斷是否存在，再決定 POST（建立）或 PUT（更新）。`mapping.list` 以外的既有資源不受影響。

### ensure_connection_group(name)

```
GET /api/session/data/{dataSource}/connectionGroups
  找同名 group：
    不存在 → POST 建立（type=ORGANIZATIONAL） → 回傳新 id
    存在   → PUT 更新                         → 回傳既有 id
```

### ensure_connection(name, group_id, protocol, ip, port, account, password, domain)

```
GET /api/session/data/{dataSource}/connections
  找「同名且 parentIdentifier == group_id」的 connection：
    不存在 → POST 建立（帶完整參數）           → 回傳新 id
    存在   → PUT 更新參數                      → 回傳既有 id
```

### ensure_user(username, password)

```
GET /api/session/data/{dataSource}/users
  找同名 user：
    不存在 → POST 建立
    存在   → PUT 更新密碼
```

### assign_connection(username, conn_id)

```
PATCH /api/session/data/{dataSource}/users/{username}/permissions
body: [{"op":"add","path":"/connectionPermissions/{conn_id}","value":"READ"}]
（Guacamole assign 為冪等操作，重複執行不報錯）
```

---

## 錯誤處理

- 腳本開頭加 `set -euo pipefail`
- API 呼叫失敗時印出：哪一行（row N）、哪個資源、HTTP 狀態碼，然後 `exit 1`
- 遇第一個錯誤立即停止，不繼續處理後續行

---

## 輸出格式

```
[INFO] Logging in to http://localhost:8080/guacamole...
[INFO] Row 1: alice → WinServer01
[INFO]   connection group 'ServerGroup'... created (id=3)
[INFO]   connection 'WinServer01'... created (id=7)
[INFO]   user 'alice'... created
[INFO]   assigned WinServer01 to alice
[INFO] Row 2: bob → LinuxBox01
[INFO]   connection group 'ServerGroup'... exists (id=3)
[INFO]   connection 'LinuxBox01'... updated (id=8)
[INFO]   user 'bob'... updated
[INFO]   assigned LinuxBox01 to bob
[INFO] Done. 2 rows processed.
```

Dry-run 模式下寫入操作改為：
```
[DRY-RUN] Would POST /api/session/data/mysql/users ...
```

---

## 檔案結構

| 路徑 | 動作 | 說明 |
|---|---|---|
| `guacamaker.sh` | 新增 | 主腳本 |
| `env.conf.example` | 更新 | 新增 `GUAC_DATA_SOURCE` 欄位 |
