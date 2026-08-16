# MIGI 麻將連鎖 · 開發脈絡

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
│  ├─ pending/         ← 寫好還沒跑的
│  ├─ checks/          ← 唯讀盤點/驗證查詢，不是 migration
│  └─ _設計稿未落地/    ← 尚未落地的設計稿：實作方式後來改掉的，或還沒排到的
│                        （例：牌譜資料庫schema.sql 是 M5+ 的東西）。不可當成已執行
├─ docs/               ← 權威文件（2026-08-14 從六個對話整合而來，現為十一類）
│  ├─ 01-資料庫/       ← 含 db-現況快照.md，動 schema 前先讀這份
   └─ ...              ← 00-進度與索引 / 02-POS與開桌 / 03-會員App與社交 / 04-設計系統
                          05-埋點分析 / 06-架構藍圖 / 07-營運商業 / 08-決策與踩坑
                          09-環境流程 / 10-牌譜與AI辨識
└─ prototypes/         ← 不屬於任何 repo、不部署的研究原型（目前只有牌譜手牌比對 Python）
```

**本資料夾本身就是 git repo：`migi-hq/migi-docs`（私有）。**
`CLAUDE.md` / `docs/` / `sql/` 都在版控裡，三個程式 repo 由 `.gitignore` 排除。
整合前的原始檔封存 `_inbox/`（138 份）已於 2026-08-15 移除，
保存在 commit `8f48578`，需要時 `git show 8f48578:_inbox/...` 取回。

三個 repo 各自獨立，做 git 操作前要先 `cd` 進去，不要在母資料夾層下 git 指令。

## 技術棧

- 前端：React 18 + Vite
- 後端：Supabase（Postgres + RLS + RPC）
- 部署：GitHub push → Cloudflare Pages 自動 build
  - POS：`pos.migi.tw` / `migi-pos.pages.dev`
- 三端共用同一個 Supabase 專案與同一套資料表，改 schema 前要想清楚會不會影響另外兩端

## 硬規則（違反過，不要再犯）

1. **SQL 一律從 Supabase Dashboard 的 SQL Editor 執行**，不用 CLI、不做本機部署。
   產出的 SQL 放 `sql/pending/`，每份結尾都要附**單一 SELECT 的驗證段**。
   **看到驗證結果、確認執行成功之後，由 Claude 自己把檔案移到 `sql/applied/`**，
   不要留給使用者手動搬。沒看到驗證結果就留在 `pending/`，不准假設跑過了。
2. **改函式簽名必須在同一份 SQL 檔開頭附 `DROP FUNCTION IF EXISTS`**，否則會建出多載版本。
3. **不要線上猜欄位名稱或約束值。** 動任何 RPC / schema 之前，先讀 `docs/` 下的權威文件，
   或用唯讀查詢把現況撈出來確認。猜錯的成本遠高於多問一次。

   **`sql/applied/` 不是線上現況的鏡像。** 那裡的檔案只是「當時交付的版本」——
   後來可能又改過而沒留檔。2026-08-15 就踩到：本機的 `已執行-代付支援.sql` 裡
   `join_session_tx` 沒有回填 `orders.session_id` 的那段，線上版本有，
   我拿檔案當基準判斷，結論整個反了。
   → **改既有函式一律先 `pg_get_functiondef` 撈線上版**，檔案只能當背景參考。

   **`docs/` 也不是鏡像，而且漂得比 `applied/` 更兇。** 2026-08-16 我信了
   `資料模型設計說明.md` 的「⏳ `products` 尚未有 `kind` 欄位」就直接加欄位，
   線上早就有了 —— 建出兩個職責重疊的欄位。同批三支「pending」SQL，
   實際上兩支跑過、一支沒跑，全都躺在 `applied/`。
   → 判斷線上有沒有某個東西，**只有 `information_schema` / `pg_proc` /
   `pg_constraint` 的查詢算數**；檔案位置、文件敘述、待辦勾選都是二手傳聞。
   細節見 `docs/08-決策與踩坑/踩過的坑.md` 第 29 條。
4. **POS 所有查詢必須走 SECURITY DEFINER 的 RPC**，不可用 `supabase.from('表').select()`。
   原因：資料表都有 RLS（`org_id = current_org_id()`），而 POS 目前用 anon key 沒有 auth session，
   直接查表會回空陣列且不報錯 —— 這種 bug 很難抓。
5. **交付檔案要完整檔，不要 diff / patch，不要打包壓縮檔。**
6. 溝通與註解一律**繁體中文**。
7. **RPC 寫完必須實際執行並看到回傳，才算完成。**
   2026-08-14 查出 `dev_reset_test_data_tx` 有六處欄位對不上實際 schema，
   第一個 UPDATE 就會拋 42703 —— 它從建立以來一次都沒成功執行過，卻被當成已完成。
   「SQL 跑完沒報錯」不等於「函式能用」，因為 `CREATE FUNCTION` 不檢查函式體裡的欄位是否存在。

   **推論（2026-08-15 又踩一次）：從未成功執行過的函式，它的每一行邏輯都從未被驗證。**
   修好前面的錯誤之後，後面那些「看起來合理」的程式碼是**全新的未知數，不是既有的可信資產**。
   當時我修好六處欄位名，卻把原版註解裡「訂單由外鍵連動刪除」的假設照抄 ——
   實際上 `order_payments` 有 `trg_payments_no_delete` 且外鍵是 `RESTRICT`，
   收過錢的訂單根本刪不掉，執行時直接拋 23503。
   → 修這種函式時心態要是**逐行重新審視**，不是「修錯字」。
   每一個對 schema 或約束的假設都要當場查證（硬規則 3），不能因為原作者寫了註解就採信。
8. **給使用者的指令一律用 PowerShell 語法，不要用 `&&`。**
   右側 Terminal 是 Windows PowerShell 5.1，`&&` 會直接噴
   `'&&' 語彙基元不是有效的陳述式分隔符號`，整行不執行。
   要串接就分兩行，或用 `;`（不管前一個成敗）／`if ($?) { }`（前一個成功才做）。
   2026-08-15 因此給了一行跑不動的 push 指令，使用者以為推成功了，實際遠端是空的。
9. **PowerShell 讀檔一律 `Select-String -Path`，不要用 `Get-Content`。**
   專案所有 .md 是 UTF-8 無 BOM，而 PowerShell 5.1 的 `Get-Content` 預設用 ANSI（Big5）讀，
   中文會全變亂碼；`Get-Content | Select-String` 也一樣壞（管線進去前就毀了）。
   非用 `Get-Content` 不可時要加 `-Encoding UTF8`。
   2026-08-15 因此產出過一份「70 個檔案全部受損」的錯誤報告，實際一個字都沒壞。
   → **任何「全部檔案都有問題」的掃描結果，先懷疑儀器再懷疑資料。**
   細節見 `docs/08-決策與踩坑/踩過的坑.md` 第 25 條。

## 資料模型注意事項

- `tables` 表**沒有 `status` 欄位**。桌況是從 `table_sessions` 動態算出來的。
- **`void` 還是 `voided`？只有 `table_sessions` 用 `voided`，其餘一律 `void`：**

  | 表 | 作廢值 | 完整允許值 |
  |---|---|---|
  | `table_sessions.status` | **`voided`** | open / completed / voided |
  | `orders.status` | `void` | open / preparing / served / paid / void |
  | `topup_orders.status` | `void` | pending / paid / void / refunded |
  | `invoices.status` | `void` | pending / issued / void / failed |

- 場次結束時間欄位是 `ended_at`，**沒有 `closed_at`**。
- 錢包餘額在 `wallets.balance`，**`members` 沒有 `points_balance`**。
  `wallet_txns` 是 append-only（`type` / `amount`，不是 `kind` / `points`），
  沒有觸發器會自動同步餘額 —— 插完流水要呼叫 `fix_wallet_balance_tx` 重算。
- 代付：檯費份數 = 自己 1 份 + 代付人數。被代付者仍建立 `session_players` 記錄，
  但 `charged_points = 0`、`paid_by = 付款人`。消費金額與發票都歸付款人。
- 埋點測試隔離：`app_events.is_test`（由 `set_is_test_from_store()` 依門市自動帶入）。
  過濾用的檢視表共**四個**：`v_real_app_events`、`v_real_wallet_txns`、`v_real_members`、`v_real_stores`。
  做報表一律查 `v_real_*`，直接查原表會把測試資料算進營運數據且不報錯。
- 完整欄位、RPC 簽名、CHECK 約束見 `docs/01-資料庫/db-現況快照.md`（2026-08-14 盤點）。

## M2 目前進度

### 已完成
- POS 開桌流程 React 化並部署：`OpenSetupPage.jsx`、`OpenCheckoutPage.jsx`、`App.jsx`、`lib/api.js`
- 代付功能前後端（`join_session_payfor.sql` 已跑）
- 埋點測試隔離（`analytics_test_isolation.sql` 已跑）
- App 埋點基礎建設：`analytics.js`（session_id / event_id / 離線佇列 / 測試帳號閘門）、
  `wallet.jsx` 儲值漏斗、`match.jsx` 報名漏斗
- 空桌自動回收：`cleanup_empty_sessions_tx(30)` + pg_cron 每 10 分鐘（2026-08-14）
- `dev_reset_test_data_tx` 依實際 schema 重寫（原版六處欄位錯誤，從未執行成功）（2026-08-14）
- 文件整合：六個對話的 125 份檔案歸位到 `docs/`（十類）與 `sql/`，
  程式碼檔全數確認為 git 歷史舊版、無一比線上新（2026-08-14）
- **文件內容合併完成，70 → 61 份**（2026-08-15）：決策紀錄 ×3、踩坑 ×4、
  索引與待辦 ×7→2、基石規範 ×2、開桌結帳流程 ×2、`01-資料庫` ×4→2。
  分工定案：`db-現況快照.md` 是事實層，`資料模型設計說明.md` 與 `RPC職責與設計.md` 是設計意圖層。
  進行中待辦只寫在本檔，`docs/00-進度與索引/待辦與未定案.md` 只放未排程與未拍板的，兩邊不重複
- 🔴 **金流洞全數修復**（2026-08-15 發現 → 2026-08-16 完成）。
  起點是「儲值跟消費無法同時進行」與一個 `payfor_already_joined` 錯誤訊息，
  但那個訊息是誤導的，真正的問題在它底下三層：
  - `join_session_tx` **沒有 items 參數**，開桌時加的餐飲／商品不會進 `orders`，
    而前端送的 `payments` 含了那些金額 → `checkout_tx` 收款驗證必然失敗。
    → 加 `p_items`（改簽名，已 DROP 重建），拒收 `fee`（會重複收費）與 `topup`。
  - **POS 全專案沒有任何儲值 RPC 呼叫。** `topupCredit` 只改 React state，
    畫面餘額會跳但 `wallets.balance` 沒動 —— **儲值按鈕從來沒真的生效過**。
    → `pos_checkout_with_topup_tx`：單一交易內先 `topup_tx` 再結帳。
  - **關鍵陷阱**：`join_session_tx` / `pos_addon_checkout_tx` 的業務錯誤是
    **回傳 `{ok:false}` 而不是拋例外**。不主動 `raise` 的話交易照常提交，
    儲值會留下半筆帳 —— 「單一交易」會是假的。最外層用 `EXCEPTION` 接住回滾。
  - `topup_orders` 加 `session_id`，桌帳看得到儲值；
    再靠冪等鍵前綴（`pos-<sess>-<member>-<ts>` 加 `:order` / `:topup`）
    把同一次收款的兩張單併成一列。舊資料也用同一把鑰匙救回。
  - 模式由**後端**查 `session_players` 決定（join / addon / topup_only），
    不採信前端的 `cur.seated` —— 那是還原出來的推測值，
    讓推測值決定收不收檯費是重複收費的溫床。
  - 餘額改吃後端回傳的 `new_balance`，不再自己推算。
- **取消開桌**（2026-08-15）：`void_session_tx` + POS 標題列按鈕與確認彈窗。
  開桌設定按下去就建 session 並被 `uq_sessions_open_table` 鎖住那張桌，
  開錯桌原本只能等 pg_cron 空桌回收，最久 40 分鐘（30 分門檻 + 10 分排程）。
  安全設計：**有任何在座玩家就拒絕**（回 `has_players`）——
  在現行流程裡玩家紀錄只在結帳後產生，代表已收過錢，那是退款問題要走收桌結算。
  驗證通過：版本數 1 / DEFINER / 煙霧測試 `not_found`
- **座位卡稱號落地**（2026-08-15）：`get_session_tx` 的 players 補回傳 `members.title`
  （`CREATE OR REPLACE`，簽名未變故不需 DROP），`TablePage.jsx` 的 `title: null` 改吃真值。
  驗證通過：版本數 1、定義已含 title、實測取得「測試01 / 新手上路」
- **稱號與段位三端統一**（2026-08-15）：改用會員 App 個人檔案的既有寫法 ——
  稱號「直角引號」+ `--ink` 無底色，段位半透明白膠囊帶「段位: 」前綴，
  `fmtRank()` 兩端同一份定義。順序為稱號 → 暱稱 → 段位。
  **`#B8860B` 隨之移除，POS 現在零寫死色碼。**
  過程中一度以為缺「深金字」token，查了會員 App 才發現稱號本來就不是金色 ——
  那個色碼不屬於任何設計決定（實測對比僅 3.2:1，未達 AA）
- `list_tables_tx` 人數修正：原本用 `sp.status <> 'left'` 判斷在座，
  但 status 沒有 'left' 這個值，條件恆為真、離座者被算進去（2026-08-14）
- **POS M2 開收桌全流程完成並實機驗證通過**（2026-08-14～15，共 20 個 commit，`e91fafd`）：
  - 從桌況進入已開桌：`enterTable` 用 `list_tables_tx` 本來就回傳的 `session_id`
    撈 `get_session_tx`，依 `is_playing` 決定進結帳頁或桌工作區；座位還原
    （有 `order_id` 或 `paid_by` 皆標為已結帳）；移除 `DETAIL_PLAYERS` 等四組假資料
  - **桌帳**：右欄改為本場消費流水（檯費 1 張 + 每次加購各 1 張），
    收據在上、流水在下，共用 `OrderDetail` 元件；單號與時間放收據最上面（收據慣例）
  - **加購**：`pos_addon_checkout_tx`（DEFINER 包 checkout_tx）只收商品不再收檯費，
    三道防線避免重複收：`feeQty` 對 seated 回 0、`doPay` 分流、首次結帳即設 `seated`
  - 帶桌後直接進座位分頁；座位頁左欄與消費分頁同一套座位卡
  - 牌規落地：`table_sessions` 新增 `game_type` / `flower`
  - `ErrorBoundary`（POS + admin）與 `api.js` 的 `rpc()` 統一收斂網路層例外 ——
    supabase-js 在 HTTP 層失敗時是直接 throw 而非回 error 物件，
    原本會變成 unhandled rejection：畫面沒反應也沒提示
  - **版本號與開機看門狗**：側邊欄顯示 `vMMDD-HHmm`，開機比對 `version.json` 自動重載。
    一天內三次因為分不清「跑的是哪一版」而誤判，這是根治
  - Toast 改用會員 App 同一套視覺，分 ok / warn / error 三種語意
  - 色彩 token 三端統一，全部對標 migi-web 命名
  - migi-web 與 migi-admin 的資料層**還沒**比照加 try/catch
- **商品分類拆成三個維度 + 分類主檔表**（2026-08-16，兩支 SQL 已驗證通過）。
  起點是「`fee`／`fnb`／`goods` 這三個詞到底是什麼層級」，查下去發現同一個「檯費」
  概念在系統裡有**四種拼法**（`category='service'`／`kind='fee'`／
  `applies_to='table_fee'`／SKU 第一段 `SVC`），而顯示名有三套、SKU 前綴有兩套。
  - `products` 加三欄，讓「放哪一頁／錢算哪個桶／要不要盤點」各自有答案，
    不再互相推導：`revenue_type`（venue_fee / fnb / retail / other）、
    `subcategory`（貨號第二段，毛利維度）、`tracks_stock`。
    推導會壞的具體案例：教室課程 `category=service` 但不該吃檯費折扣；
    器材租借 `category=service` 卻要盤點；預購商品 `category=merch` 卻不該盤點。
  - **`venue_fee` 而非 `table_fee`**：賣的是場地與服務，桌只是計價單位；
    此 schema 裡 `table_*` 已滿場；而且會員權益已承諾「專屬包廂」，包廂是房間不是桌。
    **中文顯示一律「檯費」**（店員與客人看同一畫面，不分層），識別碼與中文不對應是常態
    —— `fnb`／`retail`／`other` 本來就沒有一個是字面翻譯。
  - `product_taxonomy`（11 列）+ `list_product_taxonomy_tx()`：
    三端的分類顯示名與貨號前綴唯一來源。**無 org_id、無寫入政策** ——
    `revenue_type` 的值寫死在 `checkout_tx` 分桶邏輯裡，讓單店自訂會讓金流函式無聲算錯。
  - `other` 是候車室不是家：任何項目一有量就給它自己的桶。
    M8 教室上線時直接開 `lesson`，不要先放 `other` 再搬 ——
    `order_items` 是快照不回頭改，搬家會在報表留下永久接縫。
  - ⚠ 派車若是代收代付給司機，會計上根本不是收入而是代收款（同儲值），
    做派車前先問會計師，不要直接開 `ride` 桶。

### 待辦
0. ~~金流洞~~ **已全部修復**（2026-08-15 發現 → 2026-08-16 完成，詳見已完成區）
1. **會員 App 沒有消費明細** —— `wallet.jsx` 的「明細」是錢包點數流水（`wallet_txns`），
   不是消費紀錄（`orders`）。**付現金的消費完全不會出現** ——
   改元計價 + 混合付款後檯費可直接收現金，收現金不產生點數異動，會員端就什麼都看不到。
   資料早就齊（`orders` / `order_items` / `order_payments`），只差一支
   `get_my_orders_tx`，與 `get_session_member_orders_tx` 是同一份資料的不同切法。
   連帶要確認：會員分級的「消費累積」是用什麼算的 —— 若讀 `wallet_txns` 會漏掉所有現金消費。
2. **`checkout_tx` 的價格完全來自前端傳入的 JSON** —— `l_price := (it->>'unit_price')::bigint`，
   不讀 `products` 表。前端送什麼價格就記什麼價格，**可以送 0**。
   POS 是店員在用，風險可控；但 KIOSK 或任何會員端能觸發結帳的路徑一出現，就是可竄改價格的漏洞。
   根本解：前端只送 `product_id` + `qty`，`checkout_tx` 自己從主檔查名稱／單價／kind。
   檯費那筆虛擬品項也有真實 SKU（`SVC-TBL-*`），`calc_session_fee_tx` 已回 `product_id`，一樣查得到。
   **KIOSK 開工前必須做完。**
3. **`settle_session_tx` 仍是空殼** —— 收桌結算整條不存在：尾款、包桌超時補收、
   發票、消費累積全無。目前最大的洞，也是唯一牽涉收錢的。
   注意它現在是 `SECURITY INVOKER`，POS 用 anon 無 session 會被 RLS 擋，
   實作時要改成 `DEFINER`，依硬規則 2 得先 `DROP FUNCTION`。
4. **`fix_members_tier_constraint` 仍未執行** —— 2026-08-16 查證：`members` 上
   仍有**兩條** tier CHECK 打架，`chef_special` 永遠寫不進去。檔案在 `sql/applied/`
   但線上沒跑（同批另兩支 `drop_leave_match_queue_overload` 與 `products加kind欄位`
   則已執行，後者只做了一半 —— 欄位建了、`list_products_tx` 沒改）。
   `sql/pending/` 目前是空的。
5. **配桌列表整頁是假資料** —— `App.jsx` 的 `QueuePage` 寫死四個房間與人名。
   後端 `list_match_queues_tx` 已存在，但參數帶 `p_member`（為會員端設計），
   POS 要的是「本店所有進行中的房」，得先確認 `p_member` 傳 null 的行為。
6. 約桌邀請：`table_invites` 表不存在，但 `send_table_invite_tx` / `respond_table_invite_tx` 在，
   實際載體待確認（推測掛在 `app_notifications`）。設計稿見 `sql/_設計稿未落地/`。
7. **會員錢包顯示三張假券** —— `migi-web/src/pages/wallet.jsx:26` 的 fallback
   `_realCoupons.length > 0 ? _realCoupons : [...]` 還在。沒券的會員一定看到，
   畫面標「結帳時可用」但 POS 核銷不了，`valid_to` 還是 2026-07-28。**會員端，會客訴。**
8. **後台新增商品會產生不相容貨號** —— `migi-admin/src/lib/products.js:18` 的 `nextSku`
   產兩段式流水號，前綴表寫 `SER-` 但資料庫實際用 `SVC-`；又取「貨號尾端數字最大值 +1」，
   掃到 `SVC-TBL-P24` 會得 24 → 產出 `SER-025`。
   其餘上線前必做見 `docs/08-決策與踩坑/決策紀錄.md` 第十六節（附驗證狀態）。
9. **`migi-web` 與 `migi-admin` 的資料層還沒比照 POS 加 try/catch** ——
    POS 已於 2026-08-15 補上 `ErrorBoundary` 與 `rpc()` 的例外收斂
    （supabase-js 在 HTTP 層失敗時是直接 throw 而非回 error 物件，
    原本會變成 unhandled rejection：畫面沒反應也沒提示）。另外兩端同樣的洞還在。

### PENDING
- 店員登入未做，`staffId` 一律傳 null，`App.jsx` 還有 `const STAFF = "小美"` 寫死
- LINE Developers 帳號未申請
