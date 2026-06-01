# GuacaMaker

批次建立 [Apache Guacamole](https://guacamole.apache.org/) 使用者、連線群組與連線，並自動完成授權指派。透過兩個設定檔驅動，一行指令執行完畢。

## 需求

- `bash` 4.0+
- `curl`
- `jq`
- 可存取 Guacamole REST API 的管理員帳號

## 安裝

```bash
git clone https://github.com/your-org/GuacaMaker.git
cd GuacaMaker
```

## 快速開始

**1. 編輯 `env.conf`**，填入你的 Guacamole 連線資訊：

```bash
GUAC_API_URL=http://your-guacamole:8080/guacamole
GUAC_ADMIN_USER=guacadmin
GUAC_ADMIN_PASS=your-password
```

**2. 編輯 `mapping.list`**，填入要建立的使用者與連線：

```
alice|Alice@2024|ServerGroup|WinServer01|rdp|192.168.1.10|3389|administrator|WinPass!|CORP
bob|Bob@2024|ServerGroup|LinuxBox01|ssh|192.168.1.11|22|root||
```

**3. 執行**：

```bash
./guacamaker.sh --create
```

## 設定檔說明

### env.conf

Guacamole 管理 API 的連線參數。

| 變數 | 必填 | 預設值 | 說明 |
|---|---|---|---|
| `GUAC_API_URL` | 是 | — | Guacamole 完整 base URL，含路徑，不含尾部 `/` |
| `GUAC_ADMIN_USER` | 是 | — | 有管理權限的帳號 |
| `GUAC_ADMIN_PASS` | 是 | — | 對應密碼 |

> `dataSource`（mysql / postgresql）由腳本登入時自動從 Guacamole 回應取得，不需手動設定。

### mapping.list

每行代表一個使用者及其對應的單一連線，以 `|`（pipe）分隔，固定 10 個欄位：

```
userAccount|userPassword|connGroup|connName|connProtocol|connIP|connPort|connAccount|connPassword|connDomain
```

| 欄位 | 說明 |
|---|---|
| `userAccount` | 在 Guacamole 建立的使用者帳號 |
| `userPassword` | 使用者登入 Guacamole 的密碼 |
| `connGroup` | Connection Group 名稱；不存在則自動建立 |
| `connName` | Connection 名稱 |
| `connProtocol` | 連線協定：`rdp`、`ssh`、`vnc`、`telnet` |
| `connIP` | 目標主機 IP 位址 |
| `connPort` | 目標主機 Port |
| `connAccount` | 登入目標主機的帳號 |
| `connPassword` | 登入目標主機的密碼 |
| `connDomain` | Windows Domain；不適用時**留空**（仍需保留欄位，例如 `\|root\|\|`） |

**格式規則：**
- `#` 開頭的行為註解，略過不處理
- 空行略過
- Windows（CRLF）格式的換行會自動處理

## 用法

執行時未提供旗標會顯示用法說明並以 exit 1 結束：

```bash
./guacamaker.sh
# Usage: guacamaker.sh --create | --delete [--dry-run]
```

### 建立或更新（--create）

```bash
./guacamaker.sh --create
```

執行時輸出範例：

```
[INFO] Logging in to http://localhost:8080/guacamole...
[INFO] Row 1: alice → WinServer01
[INFO]   connection group 'ServerGroup'... created (id=3)
[INFO]   connection 'WinServer01'... created (id=7)
[INFO]   user 'alice'... created
[INFO]   assigned WinServer01 to alice
[INFO] Row 2: bob → LinuxBox01
[INFO]   connection group 'ServerGroup'... exists (id=3)
[INFO]   connection 'LinuxBox01'... created (id=8)
[INFO]   user 'bob'... created
[INFO]   assigned LinuxBox01 to bob
[INFO] Done. 2 rows processed.
```

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

### Dry-run 模式

加上 `--dry-run` 可模擬執行——**只讀取不寫入**，確認設定無誤後再正式執行：

```bash
./guacamaker.sh --create --dry-run
./guacamaker.sh --delete --dry-run
```

Dry-run 模式下，寫入操作會顯示為：

```
[DRY-RUN] Would POST /api/session/data/mysql/connectionGroups
[DRY-RUN] Would POST /api/session/data/mysql/connections
[DRY-RUN] Would POST /api/session/data/mysql/users
[DRY-RUN] Would PATCH /api/session/data/mysql/users/alice/permissions
```

## 行為說明

- **Upsert**：`mapping.list` 中的每筆資料，若已存在則**更新**，不存在則**建立**。清單以外的既有資料**不受影響**。
- **遇錯即停**：任何 API 呼叫失敗，腳本立即終止並顯示錯誤訊息（HTTP 狀態碼與回應內容）。
- **Connection Group**：若指定的 group 不存在，自動建立於根目錄（ROOT）下。
- **授權指派**：每個 user 只能看到自己對應的 connection，指派為 READ 權限。

## 常見問題

**Q: 執行後 user 無法在 Guacamole 看到連線？**
確認 `assign_connection` 步驟有顯示 `[INFO]   assigned ... to ...`，若沒有請檢查是否有錯誤訊息。

**Q: 登入失敗（HTTP 403）？**
確認 `GUAC_ADMIN_USER` 帳號有管理員權限，且密碼正確。

**Q: Guacamole 啟用了雙因子驗證（TOTP）？**
腳本會自動偵測並暫停提示輸入：
```
[INFO] TOTP required. Enter code: ______
```
輸入 6 位數驗證碼後繼續執行。

**Q: mapping.list 可以有多個 connection group 嗎？**
可以。每行可以指定不同的 `connGroup`，腳本會自動建立或重用。

## 授權

MIT License
