# Supabase 唯讀 MCP 設定

> 2026-08-28 建立。對應 CLAUDE.md 硬規則 1.5「讀與寫分家」。
> **設定檔本身是 `.mcp.json`（專案根目錄），刻意寫成純英文** ——
> 它裡面有 token，任何編輯器重存都不能讓編碼出問題，所以說明放這裡不放那裡。

---

## 為什麼要做這件事

唯讀查詢從來不在「不要讓 Claude 亂改線上」那個風險裡，
但每一次查證都要使用者手動跑查詢再貼回來。

2026-08-25 光是「快速結帳」一件事就因此**硬停三次**；
2026-08-27 餐飲文件有三個問題只能寫成「⚠ 要先查證」。

| | 走哪裡 |
|---|---|
| **唯讀查詢**（`sql/checks/`、`pg_get_functiondef`、`information_schema`） | **MCP，Claude 自己跑** |
| **寫入**（`sql/pending/`：DDL、migration、改資料） | **一律 Dashboard**，看到驗證結果才歸檔 |

⚠ 啟用後 `sql/checks/` **仍然要存檔** —— 那是查證的紀錄，不是拋棄式指令。

---

## 前置：Node.js

MCP server 是一個 npm 套件，靠 `npx` 執行 —— **沒有 Node 就跑不起來**。

✅ 2026-08-28 已安裝 **v24.20.0**（`C:\Program Files\nodejs`）。

📌 順帶解決另一件事：**本機終於能跑 `npm run build`**。
三個 repo 都有 `vite build`，但在此之前從來沒在本機 build 過 ——
每次都是推上去讓 Cloudflare 告訴你對不對，而 2026-08-27 就因此炸過一次
（JSX 註解位置，本機 build 兩秒就會抓到）。

⚠ 安裝時**不要勾「Tools for Native Modules」**（Chocolatey + Python + VS Build Tools，
好幾 GB，Vite 與 MCP 都用不到）。

---

## Token 設定（2026-08-28 實際採用的）

Supabase Dashboard → 右上頭像 → **Account Settings** → **Access Tokens**
→ 綠色 **Generate new token**（⚠ **不要**選下拉的「for experimental API」）

| 欄位 | 值 | 為什麼 |
|---|---|---|
| Name | `migi-claude-readonly` | 🔴 **token 是唯一能事後撤銷的把手** —— 取 `token1` 之後不會知道那是給誰的 |
| Expires in | **30 days** | 7 天太頻繁會讓人放棄；永久 token 是「一旦外洩就永遠外洩」。過期只是 MCP 停擺，重發即可 |
| Resource access | **Project** → `migi` | 在 token 層再鎖一次專案，與 `--project-ref` **雙重保險** |
| Permissions | **只開 `Database` → READ** | 見下 |

### 🔴 其餘全部 None

| 不要開 | 為什麼 |
|---|---|
| **Project Settings**（HIGH） | 專案 metadata **可能包含 service_role key** —— 那把鑰匙**繞過所有 RLS**，整個唯讀限制會失效 |
| **Migrations**（HIGH） | 「migration history **and application**」—— 能套用 migration = 能改 schema |
| **Backups**（HIGH） | 能還原備份 = 能把資料庫回捲 |
| **Network Restrictions**（HIGH） | 能改誰連得上資料庫 |
| **`Read-only Mode`**（MEDIUM） | 🔴 **名字會騙人** —— 它是「控制資料庫要不要進入唯讀模式」，是一個**寫入設定**的權限（開了能讓全站停止寫入），跟我們要的「唯讀查詢」完全無關 |
| Advisors／Logs／Usage Analytics（LOW） | 用不到，先不開 |

### 🎯 只給最少，不夠再加

MCP 起不來的症狀很明顯（server 載入失敗或查詢回權限錯誤），
那時再回來加，而且會知道**確切少了哪一個**。

反過來（先全開再縮）永遠不會發生 —— **沒有人會回頭收緊一個能用的東西**。
⚠ 這跟那 24 條 org 級 RLS policy 是同一個教訓：
當初寬鬆是因為當時沒人讀得到，而現在沒有人知道每一條在做什麼。

### 產生前的 Review 畫面應該長這樣

```
Risk assessment   Medium risk · Read on 1 capability, across 1 project
Capabilities      Database · 6 endpoints · READ
Available MCP tools
  confirm_cost │ execute_sql │ generate_typescript_types
  list_extensions │ list_tables │ search_docs
```

🎯 `execute_sql` ＋ `list_tables` 就是全部需要的。
而**沒有出現**的正好是該避開的：`get_project_url`／`get_anon_key`（洩漏金鑰）、
`apply_migration`（改 schema）、`get_logs`。

⚠ 提示「**Access can't be changed after creation**」—— 之後要加權限只能重發新的。

---

## 把 token 放進設定檔

檔案：`C:\Users\user\Desktop\migi github\.mcp.json`

把 `PASTE_YOUR_TOKEN_HERE` 換成真的 token，存檔。

✅ 那個檔已在 `.gitignore` 裡（`git check-ignore` 驗過）——
🔴 **token 進了 git 就永遠在歷史裡**，之後刪那一行也沒用，只能整個作廢重發。

⚠ 設定檔刻意寫成**純 ASCII**（沒有中文註解），這樣任何編輯器重存都不會
因為 UTF-8 BOM 讓 JSON 解析失敗。**說明留在這份文件，不要寫回那個檔。**

**改完要重開 Claude Code session** —— MCP server 是啟動時載入的。

---

## 啟用後的規矩沒有變

- 寫入一律 `sql/pending/` → Dashboard → 看到驗證結果才歸檔（硬規則 1）
- `sql/checks/` 仍然要存檔
- 🔴 **硬規則 3 永遠成立**：改既有函式一律先 `pg_get_functiondef` 撈線上版。
  `db-現況快照.md` 只當背景參考

## ⚠ 已知代價

**Claude 看得到會員真實資料**（手機、消費、餘額）。
**唯讀擋「改」不擋「看」。**

## 撤銷

Dashboard → Account Settings → Access Tokens → 找 `migi-claude-readonly` → 刪除。
撤銷後 MCP 立即失效，回到「使用者手動貼查詢結果」的流程 —— 不會弄壞任何東西。
