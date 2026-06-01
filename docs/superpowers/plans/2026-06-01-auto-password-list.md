# Auto-Password Generation & --list Mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 `--create` 時自動產生空白 `userPassword` 的 7 字元隨機密碼並寫入 `passwords.csv`；新增 `--list` 模式印出 passwords.csv 內容。

**Architecture:** 三處修改 `guacamaker.sh`：(1) MODE 解析加入 `list` 並插入 `--list` 早期退出路徑；(2) create 主流程加密碼產生 + 陣列收集 + 迴圈後寫 CSV；(3) 更新用法說明。另更新 `.gitignore` 和 `README.md`。

**Tech Stack:** bash、`tr`、`/dev/urandom`（不新增依賴）

---

## 檔案結構

| 路徑 | 動作 | 說明 |
|---|---|---|
| `guacamaker.sh` | 修改 | MODE 解析、--list 早退、密碼產生、陣列收集、CSV 寫入、用法說明 |
| `.gitignore` | 修改 | 加入 `passwords.csv` |
| `README.md` | 修改 | 新增自動密碼與 --list 說明 |

---

### Task 1：MODE 解析加入 `--list`、插入早期退出路徑、更新用法說明

**Files:**
- Modify: `guacamaker.sh` (lines 14-27)

- [ ] **Step 1：更新 MODE 解析 case + 用法說明**

找到 lines 14-27（現有 --create / --delete case 與 usage 訊息），完整替換為：

```bash
    --create)  [[ -n "$MODE" ]] && { echo "[ERROR] --create, --delete and --list are mutually exclusive" >&2; exit 1; }; MODE=create ;;
    --delete)  [[ -n "$MODE" ]] && { echo "[ERROR] --create, --delete and --list are mutually exclusive" >&2; exit 1; }; MODE=delete ;;
    --list)    [[ -n "$MODE" ]] && { echo "[ERROR] --create, --delete and --list are mutually exclusive" >&2; exit 1; }; MODE=list ;;
    --dry-run) DRY_RUN=1 ;;
    *) echo "[ERROR] Unknown argument: $arg" >&2; exit 1 ;;
  esac
done

if [[ -z "$MODE" ]]; then
  echo "Usage: guacamaker.sh --create | --delete | --list [--dry-run]" >&2
  echo "" >&2
  echo "  --create    建立或更新 mapping.list 中的 users 與 connections" >&2
  echo "  --delete    刪除 mapping.list 中的 users、connections 及空的 connection groups" >&2
  echo "  --list      列出所有帳號與密碼（CSV 格式）" >&2
  echo "  --dry-run   模擬執行，不實際呼叫寫入 API（僅適用 --create）" >&2
  exit 1
fi

if [[ "$MODE" == "list" ]]; then
  if [[ ! -f "$SCRIPT_DIR/passwords.csv" ]]; then
    echo "[ERROR] passwords.csv not found at $SCRIPT_DIR/passwords.csv. Run --create first." >&2
    exit 1
  fi
  cat "$SCRIPT_DIR/passwords.csv"
  exit 0
fi
```

> 注意：這段替換從 `--create)` 那行（原 line 14）開始，一直到原 `fi`（原 line 28）的**上一行**為止，最後的 `fi` 保留不動。實際上你要替換的是 case 的兩個 mode 行（14-15）加上整個 usage block（21-27），然後在 `fi` 之後緊接加入 `--list` 早退 block。

更清楚的做法：
1. 把 line 14 的 `--create)` 那行改為含互斥檢查的新版
2. 把 line 15 的 `--delete)` 那行改為含互斥檢查的新版
3. 在 line 16（`--dry-run`）之前插入 `--list)` 那行
4. 把 usage 訊息（lines 22-27）改為新版（含 --list 行）
5. 在 `fi`（line 28）之後加入 `--list` 早退 block

- [ ] **Step 2：確認語法**

```bash
bash -n guacamaker.sh
```
預期：無輸出。

- [ ] **Step 3：確認 --list 無 passwords.csv 時報錯**

```bash
mv passwords.csv passwords.csv.bak 2>/dev/null || true
./guacamaker.sh --list 2>&1
mv passwords.csv.bak passwords.csv 2>/dev/null || true
```
預期輸出包含：`passwords.csv not found`

- [ ] **Step 4：確認互斥旗標報錯**

```bash
./guacamaker.sh --create --list 2>&1
```
預期輸出包含：`mutually exclusive`

- [ ] **Step 5：Commit**

```bash
git add guacamaker.sh
git commit -m "feat: add --list mode with early exit and update usage message"
```

---

### Task 2：--create 加入密碼產生、陣列收集、passwords.csv 寫入

**Files:**
- Modify: `guacamaker.sh` (Main section, lines 379-413)

- [ ] **Step 1：在 `api_login` 之後、`row_num=0` 之前加入陣列宣告**

找到 Main 區塊（line 381）：
```bash
api_login

row_num=0
```

改為：
```bash
api_login

pw_accounts=()
pw_passwords=()
row_num=0
```

- [ ] **Step 2：在 create 分支內加入密碼產生與陣列收集**

找到 create 分支開頭（line 390）：
```bash
  if [[ "$MODE" == "create" ]]; then
    group_id=$(ensure_connection_group "$connGroup")
```

改為：
```bash
  if [[ "$MODE" == "create" ]]; then
    if [[ -z "$userPassword" ]]; then
      userPassword=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 7)
    fi
    pw_accounts+=("$userAccount")
    pw_passwords+=("$userPassword")
    group_id=$(ensure_connection_group "$connGroup")
```

- [ ] **Step 3：在 `done` 之後、最終 INFO 訊息之前加入 CSV 寫入**

找到（lines 411-413）：
```bash
done < <(sed 's/\r//' "$MAPPING_LIST" | grep -v '^#' | grep -v '^[[:space:]]*$')

echo "[INFO] Done. $row_num rows processed." >&2
```

改為：
```bash
done < <(sed 's/\r//' "$MAPPING_LIST" | grep -v '^#' | grep -v '^[[:space:]]*$')

if [[ "$MODE" == "create" && "$DRY_RUN" -eq 0 ]]; then
  {
    echo "userAccount,userPassword"
    for i in "${!pw_accounts[@]}"; do
      echo "${pw_accounts[$i]},${pw_passwords[$i]}"
    done
  } > "$SCRIPT_DIR/passwords.csv"
  echo "[INFO] Passwords saved to $SCRIPT_DIR/passwords.csv" >&2
fi

echo "[INFO] Done. $row_num rows processed." >&2
```

- [ ] **Step 4：確認語法**

```bash
bash -n guacamaker.sh
```
預期：無輸出。

- [ ] **Step 5：Commit**

```bash
git add guacamaker.sh
git commit -m "feat: auto-generate password when empty and save passwords.csv on --create"
```

---

### Task 3：更新 .gitignore 與 README

**Files:**
- Modify: `.gitignore`
- Modify: `README.md`

- [ ] **Step 1：在 .gitignore 加入 passwords.csv**

在 `/home/bigred/GuacaMaker/.gitignore` 末尾加入：
```
passwords.csv
```

- [ ] **Step 2：在 README 的「行為說明」區塊加入自動密碼說明**

找到：
```markdown
- **Upsert**：`mapping.list` 中的每筆資料，若已存在則**更新**，不存在則**建立**。清單以外的既有資料**不受影響**。
```

在它之前加入：
```markdown
- **自動密碼**：`mapping.list` 中 `userPassword` 欄位若為空，`--create` 執行時自動產生 7 字元隨機密碼（A-Za-z0-9），並連同所有帳號密碼一起寫入 `passwords.csv`。
```

- [ ] **Step 3：在 README 的「用法」區塊加入 --list 說明**

在 `### Dry-run 模式` 之前加入：

```markdown
### 列出帳號密碼（--list）

```bash
./guacamaker.sh --list
```

印出 `passwords.csv` 內容（每次 `--create` 執行後更新）：

```
userAccount,userPassword
alice,Alice@2024
bob,xK3mP9q
```
```

- [ ] **Step 4：在 README 常見問題加入 passwords.csv 說明**

在最後一個 Q&A 之前加入：

```markdown
**Q: 如何查看自動產生的密碼？**
執行 `--create` 後，密碼會寫入同目錄的 `passwords.csv`。用 `./guacamaker.sh --list` 或直接 `cat passwords.csv` 查看。`passwords.csv` 已列入 `.gitignore`，不會被 commit。
```

- [ ] **Step 5：Commit**

```bash
git add .gitignore README.md
git commit -m "docs: add passwords.csv to gitignore and update README for auto-password and --list"
```

---

## 驗收標準

```bash
# 1. 語法正確
bash -n guacamaker.sh

# 2. --list 無 passwords.csv 時報錯
./guacamaker.sh --list 2>&1 | grep "not found"

# 3. 互斥旗標報錯
./guacamaker.sh --create --list 2>&1 | grep "mutually exclusive"

# 4. passwords.csv 在 .gitignore
grep "passwords.csv" .gitignore

# 5. 無旗標用法說明包含 --list
./guacamaker.sh 2>&1 | grep "\-\-list"
```
