# Config Files Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在專案根目錄建立 `env.conf.example` 與 `mapping.list.example` 模板檔，以及 `.gitignore`，讓使用者複製後填入真實值即可使用。

**Architecture:** 兩個模板檔（`.example`）commit 進 git；真實檔案（`env.conf`、`mapping.list`）含密碼，列入 `.gitignore` 不追蹤。使用者工作流程：複製 `.example` → 去掉副檔名 → 填入真實值 → 執行自動化腳本。

**Tech Stack:** Plain text files（shell key=value、pipe-delimited）；無額外依賴。

---

## 檔案結構

| 路徑 | 動作 | 說明 |
|---|---|---|
| `.gitignore` | 新增 | 排除含真實憑證的 `env.conf` 和 `mapping.list` |
| `env.conf.example` | 新增 | Guacamole 連線參數模板 |
| `mapping.list.example` | 新增 | User／Connection 對應清單模板 |

---

### Task 1：建立 `.gitignore`

**Files:**
- Create: `.gitignore`

- [ ] **Step 1：建立 `.gitignore`**

```
# 含真實憑證的設定檔，不 commit 進 git
env.conf
mapping.list
```

- [ ] **Step 2：確認 `.gitignore` 正確排除目標檔**

```bash
touch env.conf mapping.list
git status
```

預期輸出：`env.conf` 和 `mapping.list` **不出現**在 `Untracked files` 清單中。

```bash
rm env.conf mapping.list
```

- [ ] **Step 3：Commit**

```bash
git add .gitignore
git commit -m "chore: add .gitignore to exclude credential files"
```

---

### Task 2：建立 `env.conf.example`

**Files:**
- Create: `env.conf.example`

- [ ] **Step 1：建立模板檔**

內容如下（完整複製，不省略）：

```bash
# GuacaMaker - Guacamole 連線設定
# 使用方式：複製本檔為 env.conf 並填入真實值
#   cp env.conf.example env.conf
#
# 注意：env.conf 已列入 .gitignore，不會被 commit

# Guacamole 的完整 base URL（含路徑，不含尾部 /）
GUAC_API_URL=http://localhost:8080/guacamole

# 有管理權限的 Guacamole 帳號
GUAC_ADMIN_USER=guacadmin

# 對應密碼
GUAC_ADMIN_PASS=guacadmin
```

- [ ] **Step 2：確認欄位齊全**

```bash
grep -c "^GUAC_" env.conf.example
```

預期輸出：`3`

- [ ] **Step 3：Commit**

```bash
git add env.conf.example
git commit -m "feat: add env.conf.example with Guacamole connection settings template"
```

---

### Task 3：建立 `mapping.list.example`

**Files:**
- Create: `mapping.list.example`

- [ ] **Step 1：建立模板檔**

內容如下（完整複製，不省略）：

```
# GuacaMaker - User 與 Connection 對應清單
# 使用方式：複製本檔為 mapping.list 並填入真實值
#   cp mapping.list.example mapping.list
#
# 注意：mapping.list 已列入 .gitignore，不會被 commit
#
# 格式規則：
#   - 分隔符號為 | (pipe)
#   - 每行固定 10 個欄位
#   - connDomain 不適用時留空（保留尾部的 |，例如 ...|root||）
#   - connProtocol 支援：rdp / ssh / vnc / telnet
#   - # 開頭的行為註解，略過不處理
#   - 空行略過

# userAccount|userPassword|connGroup|connName|connProtocol|connIP|connPort|connAccount|connPassword|connDomain
alice|Alice@2024|ServerGroup|WinServer01|rdp|192.168.1.10|3389|administrator|WinPass!|CORP
bob|Bob@2024|ServerGroup|LinuxBox01|ssh|192.168.1.11|22|root||
```

- [ ] **Step 2：確認每筆資料行均有 10 個欄位**

```bash
grep -v "^#" mapping.list.example | grep -v "^$" | awk -F'|' '{print NF}' | sort -u
```

預期輸出：`10`（全部資料行欄位數一致）

- [ ] **Step 3：Commit**

```bash
git add mapping.list.example
git commit -m "feat: add mapping.list.example with user/connection mapping template"
```

---

## 驗收標準

完成後，下列指令的輸出應符合預期：

```bash
# 1. 模板檔存在
ls env.conf.example mapping.list.example

# 2. 真實憑證檔不被 git 追蹤
touch env.conf mapping.list
git status   # env.conf 和 mapping.list 不出現在 Untracked files
rm env.conf mapping.list

# 3. env.conf.example 有 3 個 GUAC_ 變數
grep -c "^GUAC_" env.conf.example   # → 3

# 4. mapping.list.example 資料行均為 10 欄
grep -v "^#" mapping.list.example | grep -v "^$" | awk -F'|' '{print NF}' | sort -u   # → 10
```
