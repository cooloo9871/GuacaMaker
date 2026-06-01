# 自動產生密碼與 --list 模式設計規格

**日期：** 2026-06-01
**狀態：** 已確認

## 概述

兩個新功能：
1. `--create` 執行時，若 `mapping.list` 的 `userPassword` 欄位為空，自動產生 7 字元隨機密碼
2. `--list` 模式：列出所有帳號與密碼（從 `passwords.csv` 讀取）

---

## CLI 介面

```bash
./guacamaker.sh --create             # 建立/更新；空白密碼自動產生；寫入 passwords.csv
./guacamaker.sh --create --dry-run   # 模擬；產生密碼但不寫 passwords.csv、不呼叫 API
./guacamaker.sh --delete             # 不變
./guacamaker.sh --list               # 印出 passwords.csv 內容至 stdout
./guacamaker.sh                      # 顯示用法說明並 exit 1
```

**用法說明更新（新增 --list 行）：**
```
Usage: guacamaker.sh --create | --delete | --list [--dry-run]

  --create    建立或更新 mapping.list 中的 users 與 connections
  --delete    刪除 mapping.list 中的 users、connections 及空的 connection groups
  --list      列出所有帳號與密碼（CSV 格式）
  --dry-run   模擬執行，不實際呼叫寫入 API（僅適用 --create）
```

**MODE 值新增 `list`**，與 `--create`、`--delete` 三者互斥。

---

## 密碼產生

**觸發條件：** `userPassword` 欄位為空字串時（`mapping.list` 中兩個 `|` 之間沒有值）

**產生方式：**
```bash
tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 7
```

**字元集：** 大寫英文、小寫英文、數字（共 62 種字元）

**長度：** 7 字元

---

## passwords.csv

**位置：** `$SCRIPT_DIR/passwords.csv`（與腳本同目錄）

**格式：**
```
userAccount,userPassword
alice,Alice@2024
bob,xK3mP9q
```

**規則：**
- 第一行固定為標頭 `userAccount,userPassword`
- 包含 `mapping.list` 所有 user（手填或自動產生的密碼一律寫入）
- 每次 `--create` 執行都**覆寫**整個檔案（不 append）
- `--create --dry-run` 時**不寫入** passwords.csv
- 加入 `.gitignore`，不 commit 進 git

---

## --create 主流程變更

在主流程 while 迴圈前宣告兩個陣列：
```bash
pw_accounts=()
pw_passwords=()
```

迴圈內（create 分支），在現有邏輯之前加入：
```bash
if [[ -z "$userPassword" ]]; then
  userPassword=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 7)
fi
pw_accounts+=("$userAccount")
pw_passwords+=("$userPassword")
```

迴圈結束後（done 之後），若非 dry-run，寫入 passwords.csv：
```bash
if [[ "$MODE" == "create" && "$DRY_RUN" -eq 0 ]]; then
  {
    echo "userAccount,userPassword"
    for i in "${!pw_accounts[@]}"; do
      echo "${pw_accounts[$i]},${pw_passwords[$i]}"
    done
  } > "$SCRIPT_DIR/passwords.csv"
  echo "[INFO] Passwords saved to $SCRIPT_DIR/passwords.csv" >&2
fi
```

---

## --list 模式

`--list` 不需要登入 Guacamole，直接讀取 `passwords.csv`：

```bash
if [[ ! -f "$SCRIPT_DIR/passwords.csv" ]]; then
  echo "[ERROR] passwords.csv not found. Run --create first." >&2
  exit 1
fi
cat "$SCRIPT_DIR/passwords.csv"
```

在 MODE 解析完成後**立即**執行並 exit（在依賴檢查、env.conf 讀取之前），不需要 curl/jq 或 Guacamole 連線。

---

## .gitignore 更新

在 `.gitignore` 加入：
```
passwords.csv
```

---

## 檔案結構

| 路徑 | 動作 | 說明 |
|---|---|---|
| `guacamaker.sh` | 修改 | MODE 解析加 list、密碼產生、陣列收集、passwords.csv 寫入、--list 執行路徑 |
| `.gitignore` | 修改 | 加入 passwords.csv |
| `README.md` | 修改 | 更新用法說明，加入自動密碼與 --list 說明 |
