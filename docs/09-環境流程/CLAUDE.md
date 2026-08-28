# MIGI 咪吉麻將 · 開發脈絡

> 這份檔案是 Claude Code 每次開 session 都會自動讀的常駐脈絡。
> 規則改了就改這裡，不要靠對話重講。

## 專案結構

GitHub organization：`migi-hq`

```
migi github/           ← Claude Code 的 project folder 選這層
├─ CLAUDE.md           ← 本檔
├─ migi-pos/           ← 店員端 POS，React 18 + Vite（migi-hq/migi-pos）
├─ migi-web/           ← 會員端 App，LIFF（migi-hq/migi-web）
├─ migi-admin/         ← 後台（migi-hq/migi-admin）
├─ sql/                ← 所有 Supabase SQL（非 repo，手動保存）
│  ├─ applied/         ← 已在 Dashboard 跑過的
│  └─ pending/         ← 寫好還沒跑的
└─ docs/               ← 權威文件、資料庫結構、規格書
```

三個 repo 各自獨立，做 git 操作前要先 `cd` 進去，不要在母資料夾層下 git 指令。

## 技術棧

- 前端：React 18 + Vite
- 後端：Supabase（Postgres + RLS + RPC）
- 部署：GitHub push → Cloudflare Pages 自動 build
  - POS：`pos.migi.tw` / `migi-pos.pages.dev`
- 三端共用同一個 Supabase 專案與同一套資料表，改 schema 前要想清楚會不會影響另外兩端

## 硬規則（違反過，不要再犯）

1. **SQL 一律從 Supabase Dashboard 的 SQL Editor 執行**，不用 CLI、不做本機部署。
   產出的 SQL 放 `sql/pending/`，我跑完再自己移到 `sql/applied/`。
2. **改函式簽名必須在同一份 SQL 檔開頭附 `DROP FUNCTION IF EXISTS`**，否則會建出多載版本。
3. **不要線上猜欄位名稱或約束值。** 動任何 RPC / schema 之前，先讀 `docs/` 下的權威文件，
   或用唯讀查詢把現況撈出來確認。猜錯的成本遠高於多問一次。
4. **POS 所有查詢必須走 SECURITY DEFINER 的 RPC**，不可用 `supabase.from('表').select()`。
   原因：資料表都有 RLS（`org_id = current_org_id()`），而 POS 目前用 anon key 沒有 auth session，
   直接查表會回空陣列且不報錯 —— 這種 bug 很難抓。
5. **交付檔案要完整檔，不要 diff / patch，不要打包壓縮檔。**
6. 溝通與註解一律**繁體中文**。

## 這台開發機的注意事項

- 本機同時有樂活眼鏡與 MIGI 兩個 GitHub 帳號。git 身分靠
  `includeIf` 依**資料夾位置**切換：在 `migi github\` 底下 commit 才會
  署名 MIGI，放到其他位置會靜默掛回樂活帳號。MIGI 的 repo 一律留在這層底下。
- 憑證設了 `credential.https://github.com.useHttpPath true`，
  每個新 repo 第一次 clone 都要重新授權一次，屬正常現象。
- 細節見 `docs/Git雙帳號設定.md`。

## 資料模型注意事項

- `tables` 表**沒有 `status` 欄位**。桌況是從 `table_sessions` 動態算出來的。
- `table_sessions.status` 的 constraint 只允許 `open` / `completed` / `voided`
  （注意是 `voided`，不是 `void`）。
- 代付：檯費份數 = 自己 1 份 + 代付人數。被代付者仍建立 `session_players` 記錄，
  但 `charged_points = 0`、`paid_by = 付款人`。消費金額與發票都歸付款人。
- 埋點測試隔離：`app_events.is_test`、`v_real_app_events`、`v_real_wallet_txns`。

## M2 目前進度

### 已完成
- POS 開桌流程 React 化並部署：`OpenSetupPage.jsx`、`OpenCheckoutPage.jsx`、`App.jsx`、`lib/api.js`
- 代付功能前後端（`join_session_payfor.sql` 已跑）
- 埋點測試隔離（`analytics_test_isolation.sql` 已跑）
- App 埋點基礎建設：`analytics.js`（session_id / event_id / 離線佇列 / 測試帳號閘門）、
  `wallet.jsx` 儲值漏斗、`match.jsx` 報名漏斗

### 待辦
1. `enterTable` 改走新結帳頁 —— 目前開桌到一半退出，再點那張桌會進到 `TablePage`。
   注意 `TablePage.jsx` 傳給 `OpenCheckoutPage` 的是舊 props（`ctx={table, mode2}`），
   新版解構的是 `{sessionId, table, mode, rounds, minutes, kind, flower, stakeLabel}`，
   這條路現在是壞的、不只是假資料。
2. `OpenCheckoutPage` 進入時用 `get_session_tx` 還原座位：撈回已入座的人
   （有 `order_id` = 已結帳、有 `paid_by` = 代付中），店員接續收剩下的。
3. pg_cron 自動清理：作廢「開超過 30 分鐘無人入座」的 session，避免空桌卡住。
4. 修正 `dev_reset_test_data_tx`：裡面寫了 `'void'`，正確值是 `'voided'`。

### PENDING
- `settle_session_tx` 仍是空殼（收桌結算、包桌超時補收、發票、消費累積）
- 店員登入未做，`staffId` 目前傳 null
- LINE Developers 帳號未申請
