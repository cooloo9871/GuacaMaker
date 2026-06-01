# GuacaMaker 設定檔設計規格

**日期：** 2026-06-01
**狀態：** 已確認

## 概述

GuacaMaker 使用兩個設定檔驅動自動化流程：

- `env.conf`：Guacamole 實例的連線參數
- `mapping.list`：要建立的 users 與對應 connections 清單

兩個檔案均支援以 `#` 開頭的註解行。

---

## env.conf

**格式：** Shell key=value

**位置：** 專案根目錄 `env.conf`

### 範例

```bash
# GuacaMaker - Guacamole 連線設定
# 填入目標 Guacamole 實例的連線資訊

GUAC_API_URL=http://localhost:8080/guacamole
GUAC_ADMIN_USER=guacadmin
GUAC_ADMIN_PASS=guacadmin
```

### 欄位規格

| 變數 | 必填 | 說明 |
|---|---|---|
| `GUAC_API_URL` | 是 | Guacamole 的完整 base URL，含路徑，不含尾部 `/` |
| `GUAC_ADMIN_USER` | 是 | 有管理權限的帳號 |
| `GUAC_ADMIN_PASS` | 是 | 對應密碼 |

### 規則

- 格式為 `KEY=VALUE`，不加引號
- `#` 開頭的行為註解，略過不處理
- 空行略過

---

## mapping.list

**格式：** Pipe 分隔（`|`），每行一筆記錄

**位置：** 專案根目錄 `mapping.list`

### 欄位順序

```
userAccount|userPassword|connGroup|connName|connProtocol|connIP|connPort|connAccount|connPassword|connDomain
```

### 範例

```
# GuacaMaker - User 與 Connection 對應清單
# 格式：userAccount|userPassword|connGroup|connName|connProtocol|connIP|connPort|connAccount|connPassword|connDomain
# - 每行代表一個 user 及其對應的單一 connection
# - connDomain 不適用時留空（兩個 || 之間不填）
# - 以 # 開頭的行為註解，會被略過
# - connProtocol 支援：rdp / ssh / vnc / telnet

# userAccount|userPassword|connGroup|connName|connProtocol|connIP|connPort|connAccount|connPassword|connDomain
alice|Alice@2024|ServerGroup|WinServer01|rdp|192.168.1.10|3389|administrator|WinPass!|CORP
bob|Bob@2024|ServerGroup|LinuxBox01|ssh|192.168.1.11|22|root||
```

### 欄位規格

| 欄位 | 必填 | 說明 |
|---|---|---|
| `userAccount` | 是 | 在 Guacamole 建立的使用者帳號 |
| `userPassword` | 是 | 使用者登入 Guacamole 的密碼 |
| `connGroup` | 是 | Connection Group 名稱；不存在則自動建立 |
| `connName` | 是 | Connection 名稱 |
| `connProtocol` | 是 | 連線協定：`rdp`、`ssh`、`vnc`、`telnet` |
| `connIP` | 是 | 目標主機 IP 位址 |
| `connPort` | 是 | 目標主機 Port |
| `connAccount` | 是 | 登入目標主機的帳號 |
| `connPassword` | 是 | 登入目標主機的密碼 |
| `connDomain` | 是* | Windows Domain；不適用時留空 |

\* 欄位必須存在，但值可為空字串。

### 規則

- 分隔符號為 `|`（pipe）
- 每行固定 10 個欄位（即使 `connDomain` 為空，也需保留尾部 `|`）
- 每個 `userAccount` 只對應一條 connection
- `#` 開頭的行為註解，略過不處理
- 空行略過

---

## 設計決策記錄

| 決策 | 選擇 | 理由 |
|---|---|---|
| env.conf 格式 | Shell key=value | 最簡單，可直接 source 進 bash script |
| env.conf 欄位 | 最小組合（URL + 帳號 + 密碼） | 避免過度設計；data source 等進階選項未來再加 |
| mapping.list 分隔符 | pipe（`\|`） | 避免 CSV 在密碼含逗號時的逸出問題 |
| connDomain | 必填欄位，允許空值 | 保持每行欄位數固定，方便 parser 解析 |
| user:connection 比例 | 1:1 | 目前需求每個 user 只有一條 connection |
| 註解支援 | `#` 開頭 | 兩個檔案一致，符合 Unix 慣例 |
| mapping.list header | 以 `#` 註解行呈現 | 不影響解析，但讓維護者清楚欄位順序 |
