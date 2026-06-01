# Create / Delete 模式設計規格

**日期：** 2026-06-01
**狀態：** 已確認

## 概述

在 `guacamaker.sh` 加入 `--create` 與 `--delete` 兩個執行模式。`--create` 等同現有 upsert 行為；`--delete` 依序刪除 user、connection，並在 connection group 已空時一併刪除。不帶任何旗標則顯示用法說明並退出。

---

## CLI 介面

```bash
./guacamaker.sh --create             # 建立或更新（現有行為）
./guacamaker.sh --delete             # 刪除 user + connection + 空 group
./guacamaker.sh --create --dry-run   # 模擬 create
./guacamaker.sh --delete --dry-run   # 模擬 delete
./guacamaker.sh                      # 顯示用法說明並退出
```

**用法說明輸出（無旗標時）：**
```
Usage: guacamaker.sh --create | --delete [--dry-run]

  --create    建立或更新 mapping.list 中的 users 與 connections
  --delete    刪除 mapping.list 中的 users、connections 及空的 connection groups
  --dry-run   模擬執行，不實際呼叫寫入 API
```

---

## Config 區塊變更

新增 `MODE=""` 全域變數。參數解析：

| 參數 | 結果 |
|---|---|
| `--create` | `MODE=create` |
| `--delete` | `MODE=delete` |
| `--dry-run` | `DRY_RUN=1` |
| 其他 | 印錯誤，exit 1 |
| 無旗標 | 印用法說明，exit 1 |

---

## API 層：新增 api_delete

```
api_delete(path)
  DRY_RUN=1 → 印 [DRY-RUN] Would DELETE $path 至 stderr，return
  否則 → curl DELETE，header: Guacamole-Token: $TOKEN
  HTTP 200 或 204 → 成功（無 stdout 輸出）
  其他 → 印 [ERROR] DELETE $path failed (HTTP N) 至 stderr，exit 1
```

---

## 資源層：新增 Delete 函數

### delete_user(username)

```
DELETE /api/session/data/{dataSource}/users/{url_encode(username)}
成功 → 印 [INFO]   user '{username}'... deleted 至 stderr
```

User 不存在時（API 回 404）視為已刪除，印 skipped 不報錯。

### delete_connection(conn_name, group_id)

```
GET /api/session/data/{dataSource}/connections
找同名且 parentIdentifier == group_id 的 connection：
  找不到 → 印 [INFO]   connection '{name}'... not found, skipped 至 stderr
  找到   → DELETE /connections/{conn_id}
           印 [INFO]   connection '{name}'... deleted (id={conn_id}) 至 stderr
```

### delete_connection_group_if_empty(group_name)

```
GET /api/session/data/{dataSource}/connectionGroups → 找同名 group → 取 group_id
找不到 → 略過，不報錯

GET /api/session/data/{dataSource}/connections
過濾 parentIdentifier == group_id 的 connection 數量：
  數量 > 0 → 印 [INFO]   connection group '{name}'... kept (has connections) 至 stderr
  數量 = 0 → DELETE /connectionGroups/{group_id}
              印 [INFO]   connection group '{name}'... deleted (empty) 至 stderr
```

---

## 主流程變更

while 迴圈內依 `MODE` 分支：

**create 模式**（現有邏輯不變）：
```
ensure_connection_group → ensure_connection → ensure_user → assign_connection
```

**delete 模式**（倒序清除）：
```
group_id ← 查 connectionGroups 取得 group_id（不建立）
delete_user(userAccount)
delete_connection(connName, group_id)
delete_connection_group_if_empty(connGroup)
```

> delete 模式的 `group_id` 查詢：直接用 `api_get` + jq 內聯查詢，不呼叫 `ensure_connection_group`（avoid side effects）。

---

## Delete 模式輸出範例

```
[INFO] Logging in to https://guacamole.example.com...
[INFO] TOTP required. Enter code: 123456
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

---

## 錯誤處理

- 404（資源不存在）→ 視為已刪除，印 skipped，繼續執行
- 其他非 2xx → 印錯誤訊息，立即 exit 1

---

## 檔案結構

| 路徑 | 動作 | 說明 |
|---|---|---|
| `guacamaker.sh` | 修改 | 加入 MODE 解析、api_delete、delete_* 函數、主流程分支 |
| `README.md` | 修改 | 更新用法說明，加入 --create / --delete 說明 |
