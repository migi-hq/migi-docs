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
   └─ _資產/           ← 非文章的東西：原型 HTML／程式、圖檔、簡報、試算表。
                          程式碼不進 00–10 那些分類，但「在別處沒有正本」的原型放這裡
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
   **交付方式：在對話裡給一個可點擊的 markdown 連結指向那個檔案，不要貼內容。**
   貼整份 SQL 會把對話洗掉，使用者從檔案複製就好。
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

5.5 **資料結構太薄弱時，直接說，不要照著使用者的想法做。**
   看到欄位語意曖昧、一欄兩用、行為靠呼叫順序決定、或「每加一個需求就要改金流函式」
   這類形狀，**主動對照世界級做法**（Shopify / Square / Stripe / Oracle Retail / SAP），
   指出缺口並給**依痛感排序的務實建議**，同時明講哪些功能該永遠不做。
   判準是「這個功能需要有人每週維護嗎？需要的話先確認那個人存在」——
   單店規模照抄大廠的完整結構是另一種錯。
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

   **寫檔一律用 Write／Edit 工具，不要用 PowerShell。**
   PS 5.1 的 `Set-Content -Encoding UTF8` / `Add-Content -Encoding UTF8`
   寫的是 **UTF-8 with BOM**，會在檔頭插入 `EF BB BF`；不加 `-Encoding` 則是 ANSI。
   **兩種都錯，沒有正確的選項。**（2026-08-17 因此在一份文件檔頭加了 BOM。）
   真的非用不可時走 .NET：
   `[System.IO.File]::WriteAllText($f, $s, (New-Object System.Text.UTF8Encoding $false))`
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

- **包桌改單人計價，前端不再自己算檯費**（2026-08-17，SQL 已驗證通過）。
  查 `calcFee` 為何從沒被呼叫時發現：POS 的檯費金額**完全來自前端寫死常數**
  （`PRIV_PRICE = {120:400,300:600,1440:800}`、`rounds===3?150:100`），
  而後端收的是 `products.unit_price`。今天對得上純屬巧合。
  - **包桌前後端是兩套算法，各錯一半**：後端整桌計價（opener 全額、其餘 0），
    前端 `PRIV_PRICE ÷ 在座人數`。而 POS 送的 `join_type` 是
    `tableStarted ? 'mid_join' : 'opener'` —— 帶桌前**所有人都是 opener**，
    四人分開結帳時後端每人算全額；用代付則是 `v_unit × 4 = 1600`。
    **只有「結帳當下剛好一人在座」會對上**，那也是測試時唯一會過的路徑。
  - 決定：**包桌比照配桌，一律單人計價**（P02/P05/P24 改 100/150/200，四人總額不變）。
    「整桌 vs 人頭」的分歧從根本消失。整桌計價要回答「誰是 opener」，
    而那個答案來自前端的 `tableStarted` —— 讓推測值決定收多少錢，
    跟 2026-08-16 修掉的 `cur.seated` 是同一類的洞。
    ⚠ 只來三人就收三份；要收滿請在**開桌設定 UI** 擋四人，不要回頭改計價。
  - POS 改成**逐人**呼叫 `calcFee()` —— 暢打持有者檯費為 0，
    同桌不同人金額本來就不同，一個數字套四個座位會多收暢打那人。
    報價未回時結帳鈕鎖住（否則品項少一筆檯費、金額偏低而畫面看不出異常）。
  - 新增 `list_fee_menu_tx`：開桌設定頁在「還沒有 session」時顯示價格用
    （`list_products_tx` 撈不到 service 類，所以 POS 沒有「服務」分頁）。
  - **開桌設定五項全部不預選**（原本預帶台麻／無花／第一個級距）——
    預選會讓「店員確認過」與「店員沒看」在畫面上長得一模一樣，而這幾題決定收多少錢。
  - 🔴 **順帶發現未修**：`join_session_tx` 是 `v_unit × (1 + 代付人數)`，
    而 `v_unit` 來自**付款人**的試算 —— **持有暢打的人幫別人代付會全部免費**。
    暢打只該免他自己那份。此洞在包桌改動之前就存在。

- **會員等級折扣改成只折檯費**（2026-08-17，前後端皆完成、實機驗證通過）。
  規格寫的是「桌時費 95 折 / 桌時費 9 折」，但 `checkout_tx` 一直拿
  `(v_sub - v_coupon_cut)` 當基數，整張單都折了（實測檯費 150 + 水餃 80 折 −$23，應為 −$15）。
  - 後端基數換成 **`rem_fee`** —— 券的分桶邏輯本來就一路維護著它，不需另外重算
  - 前端 `couponResult()` **逐行鏡射後端**的券邏輯（順序、上限、未指定範圍的券依
    fee → fnb → goods 排乾）並回傳 `remFee`。畫面與實收不同是最糟的 bug ——
    結帳會成功、店員不會發現，只有客人覺得金額怪
  - 順帶補上兩處前端漏的（還沒發過券所以沒爆）：未指定 `applies_to` 的券後端可折
    goods 桶、`max_discount` 上限前端完全沒套用。兩者都會讓畫面折抵顯示得比實際多
  - **已知後果：會員加購餐飲從此零折扣**（提拉米蘇買 $80 水餃從折 $8 變 $0）。
    仍照規格 —— 餐飲的權益本來就是生日招待與限定品購買權，不是折扣。
    理由與業界對照見 `docs/08-決策與踩坑/決策紀錄.md` 第二十節
  - ⚠ 查證時發現 **`coupons.discount_value` 是「折抵百分比」不是「折數」** ——
    9 折券要填 10 不是 90。見 `docs/01-資料庫/資料模型設計說明.md` 的 `coupons` 節

- **`member_tiers` 主檔：折扣率統一成「折抵幅度」，等級設定改成資料**（2026-08-17）。
  起點是「世界級的券要用 9 折邏輯還是 10% 邏輯」。
  - **世界級一律存折抵幅度**（Shopify `value`+`value_type`、Square `percentage`、
    Stripe `percent_off`、Oracle RPM / SAP condition record）。理由三個都很實際：
    ① 折扣是會計科目（銷貨折讓），財報要的是「折了多少」，存保留比例每次都要 `1 - x`
    ② 零值是自然的恆等元；保留比例的「沒折扣」是 100，加總平均累計都會出錯
    ③ 折扣相加有意義，保留比例相加沒有
  - 原本兩種相反的存法並存：`coupons.discount_value` 是折抵幅度，
    `orders.tier_rate` 是保留比例（`checkout_tx` 那個 `* (1 - v_rate)` 就是在補償）。
    → `orders.tier_rate` 已 drop，改 **`tier_discount_pct`**。訂單全是測試資料，回填零成本。
  - **折扣率原本寫在兩支函式各一份 case**（`checkout_tx` 與 `pos_member_detail_tx`），
    後者的註解自己寫著「與 checkout_tx 邏輯一致」—— 而「一致」是靠人維護的。
    改一邊忘另一邊就是畫面顯示與實收不同，且不報錯。
    → 兩支都改查 `member_tiers`。驗證掃全庫「仍寫死 `caramel_pudding` 的函式數 = 0」。
  - 升等門檻（暫定 0 / 10,000 / 50,000）從此有欄位可放（`threshold_amount`）；
    `chef_special` 為 null = 邀請制，不靠累積取得。
  - **儲存與顯示刻意分層**：資料庫存折抵幅度，畫面一律折數（POS 顯示「9 折」不是「10%」）。
    遷就顯示去存 90，就會長出 `coupons.discount_value` 那種矛盾。

- **當日暢打全鏈路完成**（2026-08-17～19，三支 SQL 均已驗證）。
  - **它不是「券」** —— 系統裡沒有 daypass 表、沒有 `member_coupons` 那一列。
    `has_daypass_tx(org, member, store)` 問的只有一句：
    「今天（台北時區）這間店有沒有一張 `status='paid'` 且含 `SVC-TBL-DAY` 的訂單」。
    **沒有核銷動作、不會被消耗**，同一天開十桌都免。座位卡的 pill 是查詢結果不是庫存。
  - 販售路徑：`list_daypass_tx`（`list_products_tx` 不回 service 類，得單獨撈），
    在結帳頁「檯費」分頁**單選**。`join_session_tx` 對 `kind='fee'` 的擋牆
    只放行 `SVC-TBL-DAY`，其餘照擋。
    **買的當下那一桌就免** —— 否則 `calc_session_fee_tx` 跑的時候訂單還沒成立、
    `has_daypass_tx` 查不到，會收「暢打 300 + 場地費 150」。
  - 包桌也免：暢打判斷從配桌分支移到模式判斷之前。
  - 單店限定但預留跨店：`p_store_id` **必填可為 null**（給值＝限該店、null＝全連鎖）。
    不給預設值是刻意的 —— 忘記傳會靜靜變成跨店，那是收錢的行為。
  - 🔴 修掉**暢打持有者代付會全部免費**：份數改**逐人判斷**
    （`v_qty` 從 0 起算，自己與每個被代付者各自查 `has_daypass_tx`）。
    原本 `v_unit × (1 + 代付人數)` 而 `v_unit` 來自付款人的試算 ——
    暢打是個人權利，不因誰付錢而轉移。
  - **免收金額記在 `session_players`**（`fee_waived_amount` / `fee_waived_reason`），
    不進 `orders`。暢打是**履約**不是折讓 —— 那 300 元在購買當天就認列了，
    記成「場地費 150 + 折讓 150」的話淨額對但毛額虛增，客單價、
    場地費營收、折扣率全歪，而店家一毛沒少收。
    健身房不會在會員每次進場記「單次入場費 200 + 折讓 200」。
    → **`暢打抵掉金額 ÷ 暢打售出金額` 就是定價對不對的答案。**
  - `reason` 刻意不設 CHECK。已知未來值：`staff`（店員身分，內部使用不進營收）、
    `comp`（店長特調，**唯一真的少收錢的**，做的時候必須同時加授權人）。
    **三者互相獨立，店員與店長特調不經過暢打。**
    `daypass` 底下兩種會計性質（買的＝履約、活動送＝促銷費用）**不需要加欄位**：
    活動贈送就是開一張 `payable = 0` 的暢打訂單，用金額就分得開。
    ⚠ **券做不到暢打** —— 券是單次核銷憑證，暢打是當日不限次數。
  - UI：**身分列的桃紅底白字膠囊**「當日暢打 · 剩 3 小時 12 分」，
    跟會員等級並排（結帳區與加購分頁都有）。不隨剩餘時間變色 ——
    一種狀態一種樣子。倒數只到分鐘、不補零、`tabular-nums` 防寬度抖動。
    座位卡維持 pill 不放倒數（四個倒數並排是純噪音）。
    放身分列而非品項列的理由：暢打是**這個人今天的狀態**不是這一筆的屬性，
    而且權益變多時就是多幾顆膠囊，形狀不用重做。
  - 測試重置一併作廢訂單與儲值單，暢打因此可以重測
    （`has_daypass_tx` 只認 `paid`，舊版留著訂單會讓測試帳號整天免費）。
  - **不可重複購買**（2026-08-19）：`has_daypass_tx` 只問「今天有沒有」，
    第二張完全沒作用而錢照收 300。前端不再顯示暢打卡，後端另有
    `daypass_already_held` —— `hasPass` 讀的是報價回傳，
    **報價還沒回來時它是 false**，只靠前端會有時間差。擋牆放在
    `v_self_pass` 算完的下一行（尚未寫入，回 `{ok:false}` 不留半筆帳）。
  - **`api.js` 少了一整類錯誤對照**（順手修）：外層 `pos_checkout_with_topup_tx`
    必須 `raise` 才能回滾儲值，它丟的是 `checkout_failed:<reason>` ——
    **JSON 裡那句中文 `message` 在這條路上就遺失了**。
    `fee_item_not_allowed` / `payfor_already_joined` 一直以英文代碼顯示給店員。
  - ⚠ **報表分母寫錯過一次**：「暢打售出金額」原本寫 `sum(orders.payable)`，
    那是整張訂單，同一次結帳的餐飲會被算進來（實測 580，而暢打單價 300）。
    正解是 `sum(order_items.line_total)`。
    **`暢打抵掉金額 ÷ 暢打售出金額` 是定價對不對的答案，分母錯結論會整個反。**

- **`kind` → `revenue_type` 全面替換完成**（2026-08-19～20，四支 SQL 全部驗證通過）。
  用 expand → migrate → contract：A 後端雙軌（前端不動）→ B POS 改用新詞彙 →
  C-1 收掉 `order_items.kind` → C-2 收掉 `products.kind` 並把兩個
  `revenue_type` 收成 NOT NULL → C-3 清掉發射端與三道失效的擋牆。
  值同時改名：`fee`→`venue_fee`、`goods`→`retail`。
  - 🔴 **文件的兩個數字都是錯的，而且錯得很危險**。CLAUDE.md 記「前端 84 處、
    SQL 15 支」，實際是**前端 27 處（全在 migi-pos）、SQL 6 支**。
    差額全是**同名不同義**：`migi-web` 那 42 處一處都不是商品分類
    （rewards 的收藏類型、match 的房型、data 的牌局類型、ErrorBoundary 的錯誤類型、
    `coupons.kind`）；POS 有 13 處是**牌規**（台麻／美麻），`OpenSetupPage` 整支。
    資料庫端 `kind` 出現在**六張表、六種意思**
    （coupons / invoices / legal_entities / member_interactions / order_items / products）。
    → **全域取代在這種題目上是災難**：把 `match.jsx` 的 `kind="live"` 改掉不會報錯，
    只會讓配桌房型靜靜失效。先盤點語意，再決定改哪些。
  - 🔴 **`NULL not in (...)` 的結果是 NULL 不是 TRUE。**
    `checkout_tx` 的品項防護寫成 `if l_kind not in ('fee','fnb','goods') then raise`，
    欄位改名後 `l_kind` 是 null，**那道防護完全不擋**，接著
    `if l_kind='fee' ... else v_goods` 讓**所有品項都掉進 goods 桶** ——
    `rem_fee` 恆為 0 → 等級折扣恆為 0、檯費券一律「不適用」。
    金額不爆、結帳成功，只有折扣默默不見。
    → 防護一律先判 null。存在目的是擋不合法值的檢查，遇到 null 卻放行，是最壞的組合。
  - 🔴 **排序不要靠字母巧合。** 收據原本 `order by i.kind`，
    `fee/fnb/goods` 剛好讓檯費第一。換成 revenue_type 後字母序是
    `fnb/other/retail/venue_fee`，檯費會掉到最後一行 —— 畫面沒壞、金額也對。
    → 改成明寫的桶序 CASE。
  - **`topup` 從分類欄位抽成獨立旗標**（前端 `isTopup`、API `is_topup`）。
    儲值是預收款不是收入桶，它從來不會進 `order_items`。
  - ✅ **「改到一半就整支失敗」的 guard 救了兩次。**
    DO 區塊末尾加 `if v_new ~ '\ykind\y' then raise`，
    兩次都擋下只改對一半的函式並整支回滾（Supabase SQL Editor 是單一交易）。
    沒有它，線上會出現「場地費擋牆修好了、白名單還是壞的」而且不報錯。
    → 但更根本的教訓是：**同一支函式要改三處以上就撈全文重建，不要堆 DO 區塊。**
    我在 `join_session_tx` 上連續判斷錯兩次，都是因為只看片段。

### 待辦

0. **分類主檔只有一端在讀** —— `product_taxonomy` 與 `list_product_taxonomy_tx`
   已上線，但目前**只有 migi-admin 讀它**：
   - migi-pos：`OpenCheckoutPage.jsx:522` 與 `:537` 仍寫死
     `category === 'fnb' ? '餐飲' : category === 'merch' ? '周邊' : '服務'`
   - migi-web：`wallet.jsx` 的 `tile()` 把 `wallet_txns.type` 與商品分類混在一張對照表
     （`table_fee` / `merch` / `event_fee` / `adjust` / `topup` / `fnb` 六種值混用）
   建了主檔卻沒人讀，就是踩坑第 29 條那個形狀。
   ⚠ migi-web 那份會跟「會員 App 最近消費」一起重寫（見待辦 1），先不要單獨改。

   **同一個問題也存在於 `member_tiers`**（2026-08-17 建立）：
   `discount_pct` 與 `threshold_amount` 已由 `checkout_tx` 與 `pos_member_detail_tx` 讀取，
   但 **`label` 沒人讀** —— 等級中文名仍寫死在 `migi-pos/src/shared.jsx` 的 `TIER_LABEL`。
   要讀它得把 `list_member_tiers_tx` 的結果傳進 `OpenCheckoutPage` 的三個子元件
   （:857、:1381、:1452），是純 prop 串接的工。
   風險比分類前綴低（品牌名幾乎不變，且錯了只是名字錯不會算錯錢），
   但**不做就是「建了主檔沒人讀」**，一併排進來。

0.5 ~~當日暢打全鏈路~~ → **已完成並實機驗證通過**（2026-08-17～19，詳見已完成區）。
   2026-08-19 三項實測全過：買暢打當桌檯費 $0、買完暢打卡消失、
   **持有暢打者代付兩人收 $300**（自己免、兩人各 150）——
   這是 8/17 修的代付破洞第一次真正被驗證，舊版會收 $0。

   ✅ **暢打固定 300，不參與任何折扣**（2026-08-20 決定、完成並實測通過）。
   實測發現提拉米蘇會員買暢打實收 270 —— 它是 `venue_fee` 商品，
   被等級折扣折到了。暢打本來就是為了讓人多打，再疊一層是兩層優惠
   打在同一件事上。
   做法不是在 `checkout_tx` 判斷 SKU，而是加 **`products.discountable`**
   （NOT NULL 預設 true）：**「這個商品參不參與折扣」是商品屬性，不是金流函式的 if。**
   已知未來會用到的：禮券、寄杯、派車代收款 —— 代收性質的東西在會計上
   根本不是收入，更不該被折。每多一種就改一次金流函式，就是待辦 0.8 的病。
   Square / Lightspeed 都是每個品項一個 discountable 旗標。
   - **範圍是全部三個桶，券也折不到** —— 只擋等級折扣的話，
     一張檯費 9 折券還是能把它折成 270，那就不是固定。
     ⚠ 後果：日後辦「暢打特價」不能發檯費券，要改售價。那其實比較對 ——
     券的成本歸屬是 store/hq，而**調價不是折讓**。
   - **後端用 `product_id` 回查主檔，不採信前端送的值。**
     `checkout_tx` 的價格已經全部來自前端 JSON（待辦 2），
     不要再多一個可被竄改的折扣開關。前端那份只為了讓畫面算得一樣。

   ✅ **跨午夜：維持日曆日，00:00 換日**（2026-08-20 拍板）。
   曾評估購買後 24 小時制與營業日制（凌晨 6 點換日），選日曆日。
   「當日」兩個字對客人與店員都不需要解釋，而滑動視窗要回答
   「我的暢打到底幾點過期」—— 每個人的答案都不一樣，店員記不住也查不到。
   `has_daypass_tx` 用 `(created_at at time zone 'Asia/Taipei')::date = today`
   一句話講完，沒有可以算錯的地方。
   ⚠ **已知代價**：22:30 買的客人只能用 1.5 小時，打到凌晨就開始收場地費。
   這是規則本身的性質不是 bug —— 要處理是在**現場話術**（深夜買之前先講清楚）
   或**定價**（例如深夜時段本來就不賣暢打），不要回頭改判準。
   改判準等於讓「今天」變成一個要查的東西。

0. ~~金流洞~~ **已全部修復**（2026-08-15 發現 → 2026-08-16 完成，詳見已完成區）
0.7 ~~`kind` → `revenue_type` 全面替換~~ → **已完成**（2026-08-19～20，詳見已完成區）。
   四支 SQL（A 雙軌 / C-1 order_items / C-2 products / C-3 收尾），
   POS 27 處，`kind` 作為商品分類已從整個系統消失。
   2026-08-20 三項實測全過：入座同時點餐飲、買暢打、**用檯費券**。
   最後一項最深：`revenue_type` 分桶 → 券只吃 `rem_fee` →
   等級折扣吃券折後的 `rem_fee`（150 → 券 −15 → 等級 −14 → 應付 201）。

0.8 **`coupons.applies_to` 改成 `coupon_scope` 表**。
   促銷適用範圍不該是型別欄位而是規則：行銷每發明一種新範圍
   （聯名商品專用、週二飲料、段位解鎖限定品）就要改 CHECK、跑 migration、
   改 `checkout_tx` —— 等於「一個活動企劃 = 一次金流函式改版」。
   `coupon_scope(coupon_id, scope_type, scope_value)`，`scope_type ∈ revenue_type | category | product_id`，
   一張券可多列。`ride` / `topup` 那兩個不是商品分類的值自然消失。
   **動手時機：發券後台開工前。** `grant_rules` / `grant_log` 目前完全不存在，
   還沒有任何已發出的券要遷移，現在改成本最低。

1. **會員 App 沒有消費明細** —— `wallet.jsx` 的「明細」是錢包點數流水（`wallet_txns`），
   不是消費紀錄（`orders`）。**付現金的消費完全不會出現** ——
   改元計價 + 混合付款後檯費可直接收現金，收現金不產生點數異動，會員端就什麼都看不到。
   資料早就齊（`orders` / `order_items` / `order_payments`），只差一支
   `get_my_orders_tx`，與 `get_session_member_orders_tx` 是同一份資料的不同切法。
   連帶要確認：會員分級的「消費累積」是用什麼算的 —— 若讀 `wallet_txns` 會漏掉所有現金消費。

   **UI 端已指定**（2026-08-16）：首頁「最近消費」只顯示**前 10 筆**；
   切頁標題從「點數明細」改成「**最近消費**」；內容要含**現金消費 + 點數消費 + 儲值**。
   前兩項是純前端，第三項要等 `get_my_orders_tx`（現在 `get_wallet_tx` 只回 `wallet_txns`）。

   **消費累積採 B 案：從 `orders` 即時算，不存計數欄位**（2026-08-16 決定）。
   存欄位會出現「欄位與訂單對不上」而且無從得知哪邊才對；退款、作廢、補開都要記得回沖，
   漏一次就永久偏差。從事實表算則永遠一致，慢了再加物化檢視表。
2. **`checkout_tx` 的價格完全來自前端傳入的 JSON** —— `l_price := (it->>'unit_price')::bigint`，
   不讀 `products` 表。前端送什麼價格就記什麼價格，**可以送 0**。
   POS 是店員在用，風險可控；但 KIOSK 或任何會員端能觸發結帳的路徑一出現，就是可竄改價格的漏洞。
   根本解：前端只送 `product_id` + `qty`，`checkout_tx` 自己從主檔查名稱／單價／kind。
   檯費那筆虛擬品項也有真實 SKU（`SVC-TBL-*`），`calc_session_fee_tx` 已回 `product_id`，一樣查得到。
   **KIOSK 開工前必須做完。**
3. **收桌結算：第一版（關場次 + 放桌）已完成並實測通過**（2026-08-20）。
   四步全過：開桌結帳帶桌 → 收桌 → 桌況變空桌 → **重新開同一張桌成功**。
   最後一步才是真正驗到放桌（部分索引確實隨 status 變動而放行）。
   ⚠ **原本這條寫「`settle_session_tx` 仍是空殼」，那是錯的** ——
   線上版本一直都在做 `status='completed'` / `ended_at` / `fee_points`。
   真正的問題是它 **`SECURITY INVOKER`**：POS 用 anon 沒有 auth session，
   RLS 把那個 UPDATE 過濾成 0 列，**而且不報錯**，函式照樣回 ok。
   「跑了、回了、什麼都沒發生」正是硬規則 4 要防的形狀，
   也再次證明只有 `pg_get_functiondef` 算數（硬規則 3）。
   - 改 `DEFINER` + 加 `p_staff_id`（簽名變了，已先 `DROP`）
   - **放桌不需要額外動作**：`uq_sessions_open_table` 是部分索引
     （`WHERE status='open' AND deleted_at IS NULL`），改狀態就自動解鎖
   - 在座玩家一律寫 `left_at`；冪等（已收桌回 `already_settled`）
   - POS 按鈕改名「**收桌**」不叫「收桌結算」—— 這一版不結算任何東西，
     檯費在入座時已收清，叫「結算」會讓店員以為還要收錢
   - **沒有「未結帳就不給收桌」的擋牆**：`session_players` 每一列都是
     checkout 成功後才建立的，系統裡不存在「已入座但未付款」。
     持有暢打的人 `order_id` 是 null，那是「不用付」不是「還沒付」——
     拿它當判準會把暢打的客人擋在桌上下不來。

   **第二版待做**，四個規則已於 2026-08-20 拍板：
   - **包桌超時** → 收桌時補收到**實際級距**（打 4 小時就按 5 小時那檔，補差額）。
     單一規則、不用每小時算，與現行級距定價一致（停車場與 KTV 都是這套）。
   - **發票** → 維持**每筆結帳各一張**，收桌不碰發票。
     合開要作廢重開，且代付時「整桌」屬於誰也要定義。
   - **消費累積** → 用**實付金額 `payable`**（折扣後）。
     用折前小計的話，發券等於送升等進度。
   - **尾款** → 現行檯費入座收清，暫無尾款概念；等超時補收做完再看是否需要。
   ⚠ 超時補收會撞上暢打的跨午夜規則：跨午夜的長桌到那時才第一次被計算時長。
4. ~~`fix_members_tier_constraint` 仍未執行~~ → **假警報，2026-08-17 更正**。
   我當時用 `pg_get_constraintdef(c.oid) ilike '%tier%'` 數出 2 條就判定「還在打架」，
   但那兩條是 `members_tier_chk` 與 **`members_tier_override_chk`**（作用於不同欄位），
   兩條都允許 `chef_special`。較嚴的那條早在 2026-08-16 就移除了
   （見 `docs/01-資料庫/db-現況快照.md` 已知待修問題第 2 項）。
   → **教訓：數量不等於衝突。** 數 constraint 的數量卻不看它們約束哪個欄位，
   等於用一個不會分辨的儀器下結論 —— 同踩坑第 25 條「先懷疑儀器再懷疑資料」。
5. **配桌列表整頁是假資料** —— `App.jsx` 的 `QueuePage` 寫死四個房間與人名。
   後端 `list_match_queues_tx` 已存在，但參數帶 `p_member`（為會員端設計），
   POS 要的是「本店所有進行中的房」，得先確認 `p_member` 傳 null 的行為。

   **自動配桌的規則已於 2026-08-20 拍板，做配桌時一起實作（四件事缺一不可）：**
   - `tables.auto_assign boolean NOT NULL default true` ——
     **預設所有桌都開放系統自動配**，店員可把個別桌改成「現場專用」。
     ⚠ 這是**設定不是狀態**：桌況（使用中／空桌）是每次從 `table_sessions` 算出來的，
     而「這桌不給系統配」是店員的意思，沒人改就不會變，所以要存欄位。
     `tables` 仍然沒有 `status` 欄位，兩者不衝突。
   - **桌況卡片要顯示「現場」標記** —— 否則週六關掉的桌週一沒人記得，
     那幾桌從此永遠不會被自動配而且畫面上看不出來。
     不加到期時間（那會變成「為什麼我設的又跑掉了」），用看得見來防忘記。
   - **收桌彈窗加一個勾選「收完保留給現場」** ——
     情境是「現場有四人在等」，店員必須**先關掉那桌再按收桌**，
     順序反了就被 App 搶走，而那是客人站在旁邊時要記得的事。
     一個勾選同時做兩件事，就沒有順序可以搞錯。
   - **指派時只看 `auto_assign = true` 且目前沒有 open 場次的桌。**

   🔴 **還沒解決：現場客人與 App 不在同一條隊。**
   就算桌不會被自動搶走，店員仍要自己判斷「App 那組先報名還是現場這組先到」——
   那個判斷沒有依據，就會變成客訴。
   → POS 要能**幫現場客人登記進同一個隊列**（walk-in），先來先排、同一份名單。
   餐飲業的候位系統（OpenTable / Yelp Waitlist）都是這樣：
   系統從不自己帶位，但兩種客人一定進同一條隊。

   ⚠ **現在不要先建 `auto_assign` 欄位。** 自動配桌根本還不存在 ——
   `open_method` 允許 `'auto'` 但沒有任何程式送這個值，
   `table_sessions` 只有 `open_session_tx` 會寫入而它只有 POS 呼叫。
   現在加就是第四個「建了沒人讀」（前三個：`product_taxonomy`、
   `member_tiers.label`、分類前綴），正是踩坑第 29 條的形狀。
6. 約桌邀請：`table_invites` 表不存在，但 `send_table_invite_tx` / `respond_table_invite_tx` 在，
   實際載體待確認（推測掛在 `app_notifications`）。設計稿見 `sql/_設計稿未落地/`。
7. **會員錢包顯示三張假券** —— `migi-web/src/pages/wallet.jsx:26` 的 fallback
   `_realCoupons.length > 0 ? _realCoupons : [...]` 還在。沒券的會員一定看到，
   畫面標「結帳時可用」但 POS 核銷不了，`valid_to` 還是 2026-07-28。**會員端，會客訴。**
8. **後台新增商品會產生不相容貨號** —— `migi-admin/src/lib/products.js:18` 的 `nextSku`
   產兩段式流水號，前綴表寫 `SER-` 但資料庫實際用 `SVC-`；又取「貨號尾端數字最大值 +1」，
   掃到 `SVC-TBL-P24` 會得 24 → 產出 `SER-025`。
   其餘上線前必做見 `docs/08-決策與踩坑/決策紀錄.md` 第十六節（附驗證狀態）。
12. **`wallet_txns.type` 一欄裝兩個維度**（2026-08-17 盤點，完整分析見
    `docs/01-資料庫/資料模型設計說明.md` 三之三節）——
    `topup/refund/reversal/adjust`（交易性質）與
    `spend/table_fee/fnb/merch/event_fee`（消費類別）混在同一個 enum，
    且 `checkout_tx` 現在一律寫 `spend`，那四個類別值是舊世代
    （`_charge_core` / `charge_fnb_tx` 等）留下的 —— 同一欄兩代慣例並存。
    這也解釋了 `migi-web` 的 `tile()` 為什麼混用六種值：它忠實反映一個本來就混的欄位。

    **不要動 enum**（要處理歷史列，收益只是整齊）。改成立規矩：
    - 新寫入一律只用**性質值**（`topup` / `spend` / `refund` / `reversal` / `adjust`）
    - **消費類別一律從 `ref_table` / `ref_id` 追訂單取得**，不要讀 `type`
    - 那四個類別值視為已凍結的歷史值，只讀不寫

    → 這直接決定待辦 1 的 `tile()` 怎麼寫：看關聯訂單的品項，不看 `wallet_txns.type`。

10. **平板沒有按壓回饋** —— POS 的互動狀態只做了 hover（滑鼠移入變深灰框），
    但**手指沒有 hover**。平板上點下去到畫面更新之間完全沒有回饋，
    店員會不確定按到沒有而重複點。需要 `:active` 的按壓態，
    而那會是這個 codebase 第一個元件 CSS class（目前全是 inline style）。

11. **贈點目前可以立即消費，未確認是否符合預期** —— `topup_tx` 把本金與贈點
    都寫進 `wallets.balance`，現場儲值 1000 送 150，那 150 當下就能拿來折抵。
    若要限制（例如贈點次月生效、或不可折抵檯費），`wallet_txns` 需要能區分本金與贈點 ——
    目前兩者都是 `type='topup'`，事後分不出來。**要改就趁還沒有真實資料。**

9. **資料層例外收斂：`migi-web` 做了一半，`migi-admin` 還沒開始**（2026-08-21 更正）。
    ⚠ 原本這條寫「migi-web 還沒有 ErrorBoundary」，**是錯的** ——
    它早就有而且掛在 `main.jsx:64`，`main.jsx:28` 也有全域 `unhandledrejection` 上報。
    - 🔴 **但 `ErrorBoundary` 接不到非同步錯誤。** supabase-js 在 HTTP 層失敗
      （斷網、CORS、逾時）時是直接 throw，`.then()` 整段不執行，
      畫面永遠停在「載入中…」。全域監聽只**上報**，使用者端沒有任何提示
      —— 也就是「錯誤進了資料庫，客人還在盯著轉圈」。
    - ✅ 已加 `migi-web/src/lib/rpc.js`（與 POS 的 `api.js` 同一套想法）：
      兩種失敗收斂成同一形狀、永遠不 throw、依原因給人看得懂的話術。
      **錢包頁已遷移**並改成可重試的區塊。
    - ✅ **`lib/social.js` 與配桌頁已完成**（2026-08-22）。三種模式定案：

      | 類型 | 失敗時 | 用哪支 |
      |---|---|---|
      | 讀取整頁 | 整頁 `PageError` / 清單位置 `ListFail` | `rpcRead()` |
      | 寫入動作 | `showError()`，**畫面不動、保留輸入** | `rpc()` |
      | 背景（埋點、已讀） | **靜默** | `rpc()`，不接錯誤 |

      決定用哪一種的是「**這個呼叫在做什麼**」，不是「這是哪一頁」——
      同一個配桌頁裡三種都有。
    - ⚠ **`rpc()` 預設不自動重試，讀取要用 `rpcRead()`。**
      忘記關掉重試的代價是重複報名、重複儲值，而那不會在測試時發現，
      只會在對帳時發現 —— 所以危險的那一邊當預設。
      逾時只是**停止等待**，底層請求仍在跑，寫入防重複只能靠後端冪等鍵。
    - ⏳ 其餘仍直接呼叫 `supabase.rpc`：`lib/profile.js`（15，全是寫入 ——
      「改了沒存到而沒有提示」是這裡最危險的）、`App.jsx`、`lib/analytics.js`。
    - ⏳ `migi-admin` 兩樣都還沒有。

15. 🔴 **同一個人可能變成兩個會員，而且沒有合併機制** —— 上線前必做，**越晚越貴**。
    現況（2026-08-22 確認）：**LINE 根本還沒接**（`migi-web/src/App.jsx:64` 註解
    明寫「LINE 尚未接上：授權為模擬」），身分就是 `localStorage.migi_member.id`。
    所有資料掛在 **`members.id`** 上，不是掛在 LINE user id 上。
    - ✅ **同一個 member 換綁不同 LINE 帳號**沒問題 —— `rebind_line_user_tx` 就是做這個的。
    - 🔴 **同一個人變成兩個 member 就完了**：先用手機號註冊過一個，
      之後從 LINE 進來又建一個 —— 兩邊各持一半的**點數、消費紀錄、牌咖、成就、段位**。
      `rebind_line_user_tx` 是「換綁」不是「合併」，**目前沒有任何合併機制**。
    - 合併要逐項決定怎麼併：錢包餘額（相加？`wallet_txns` 要不要搬）、
      `orders`（改 member_id 會動到已開的發票）、`mahjong_buddies`（去重）、
      成就與段位（取高的還是重算）。**有真實資料之後每一項都變成錢的問題。**

    ⚠ **與待辦 14 的關係（順序不能反）**
    - JWT 解決的是「**你是不是你說的那個人**」；合併解決的是「**同一個人有兩個帳號**」。
      兩個不同的問題，但 JWT 的 subject 是 **LINE 帳號**不是 member，
      所以仍然需要一張 `line_user_id → member_id` 的對應。
      **那個對應建錯了 JWT 也救不了** —— 它只會忠實地把你導到其中一個。
    - 🔴 **JWT 上線的那一刻就是「LINE 帳號 ↔ member」正式綁定的時候。**
      那時若已經有重複的 member，綁定會固定下來，之後更難拆。
      → **合併機制要在 JWT 之前或同時做，不能之後補。**
    - 另一個實務後果：現在切換測試帳號只要改 localStorage，
      JWT 之後就不能這樣切了 —— 測試流程要一起重想。
    - 順帶：JWT 之後 `rebind_line_user_tx` 等於「改身分」，需要授權控制。

14. 🔴 **會員端沒有真正的身分：LIFF 換 JWT** —— 三件事同一個根，**必須一起解**。
    現況：`migi-web` 用 anon key，會員身分靠**前端傳 `p_member_id`**，
    RPC 全是 `SECURITY DEFINER`（`get_wallet_tx` 一直如此，`get_my_orders_tx` 沿用）。
    - 🔴 **存取控制**：知道任何一個會員 uuid 就能查他的錢包與**消費明細**
      （買了什麼、花多少、什麼時間在店裡）。餘額已經夠敏感，消費明細更甚。
    - 🔴 **Supabase Realtime 做不了**：訂閱走 SELECT，**RLS 照樣套用**，
      而資料表的 RLS 是 `org_id = current_org_id()` —— anon 訂閱會**安靜地收不到任何東西**
      （與 POS 直接查表回空陣列同一個原因，硬規則 4）。
      ⚠ **不要以為 Realtime 可以單獨做** —— 它是這件事做完之後的紅利，不是獨立項目。
    - 🟡 **輪詢成本**：配桌現在每 5 秒、8 秒、30 秒各一支，
      每個開著 App 的人都在打。Realtime 上線後這些都可以拆掉
      （但**輪詢要留作 fallback** —— LIFF 進背景連線會斷）。

    解法：LIFF 的 `id_token` 換 Supabase JWT（Edge Function 或自建端點驗簽），
    RPC 改從 `auth.uid()` 取會員、拿掉 `p_member_id` 參數、
    `SECURITY DEFINER` 大多可以改回 `INVOKER` 讓 RLS 自己擋。
    ⚠ 動到每一支會員端 RPC 的簽名（硬規則 2：全部要先 DROP），
    而且 POS 用的 anon 路徑不能一起壞掉 —— 兩端的驗證模型會從此分家。

13. 🔴 **發票整條未接** —— 這是**法規**問題不是營運不便，比收桌硬性。
    現況（2026-08-20 掃過確認）：
    - `create_invoice_draft_tx` 寫好了，**`migi-pos/src` 裡 `invoice` 一次都沒出現**，
      沒有任何前端呼叫它，`invoices` 表沒有資料
    - 沒有串任何電子發票加值中心（綠界／ecPay／關貿）
    - 資料骨架其實齊了：`members.inv_type / inv_carrier / inv_donate_code /
      inv_tax_id / inv_title`（`create_invoice_draft_tx` 會讀成快照）、
      `invoices.kind ∈ invoice | allowance`、`status ∈ pending | issued | void | failed`、
      內含稅拆分（`round(payable / 1.05)`）也寫好了

    **✅ 已拍板：消費明細與發票分開，照業界做法。**
    - **消費紀錄在結帳當下就有**，不等發票 —— `get_my_orders_tx` 的條件是
      `orders.status='paid'`，與發票無關。
      讓明細等發票的話會出現「客人已經付錢了但 App 上什麼都沒有」，
      而發票失敗的原因通常跟消費無關（載具錯、加值中心斷線、字軌用完）。
    - **會員 App 之後要有獨立的發票區**（載具設定／發票查詢），
      與「最近消費」分開兩個入口。全家、星巴克、路易莎都是這樣。
    - 收桌**不碰發票**（2026-08-20 一併拍板）：維持每筆結帳各一張。

    **實作前要先想清楚的（不是寫 SQL 的問題）：**
    - **誰呼叫、什麼時機** —— `checkout_tx` 成功後同一交易內？還是結帳後非同步？
      同交易內的話，加值中心逾時會讓結帳整筆失敗（錢收不了）；
      非同步的話要有重試與失敗告警，否則失敗會沒人發現。
    - **失敗了怎麼辦** —— `status='failed'` 之後由誰重送、店員看得到嗎
    - **作廢與折讓** —— 退款時開折讓單（`kind='allowance'`）還是作廢重開，
      兩者稅務處理不同，且跨月只能折讓
    - **代付時發票開給誰** —— 訂單掛在付款人身上，但被代付者可能要自己的發票
    - **字軌與配號** —— 加值中心配發，用完要提前申請

16. **「官方推薦」要重新設計**（2026-08-23 先把舊的拿掉）。
    原本 `migi-web/src/pages/match.jsx` 的 `RecmdBadge` 掛在 `q.source === 'pos'` 上 ——
    也就是「**這房是 POS 開的**」就顯示「官方推薦」。
    那是**誰開的**不是**好不好**：店家開的桌不必然值得推薦，客人開的也不必然不值得。
    ⚠ 更實際的問題是它**不可信**：客人點進去發現跟隔壁那桌沒兩樣，
      下次所有標籤都會被略過，包括真的有意義的那些。
    → 已移除。要重做的話得先回答「憑什麼推薦」——
    可能的判準：人氣（報名速度）、段位相近、常客回訪率、店長手動指定。
    **手動指定要有人每週維護，做之前先確認那個人存在**（硬規則 5.5）。
    ✅ `QUEUE_TAGS`（新手友善／網紅在這桌／職業選手桌）**保留** ——
    那是受控清單裡的具體描述，不是價值判斷，兩者性質不同。

17. 🔴 **贈點級距沒有主檔，規則只活在前端**（2026-08-23 發現）。
    `bonusOf()` 寫死在 `migi-pos/src/OpenCheckoutPage.jsx:30`
    （150→0、500→20、1000→50、3000 以上一律 300），前端算完用
    `p_topup_bonus` 送給後端，而 **`topup_tx` 照收 `p_bonus_points` 不驗證**。
    - 🔴 這跟待辦 2（`checkout_tx` 的價格完全來自前端）是**同一個病**：
      能送任意金額。POS 是店員在用風險可控，但 KIOSK 或任何會員端能觸發的路徑
      一出現就是可竄改的贈點。
    - 🔴 **而且它擋住了會員頁的儲值功能**：在第二個地方做儲值就是第二份 `bonusOf`，
      兩邊必然漂，而「哪一邊的贈點才對」只會在對帳時才發現。
      所以 2026-08-23 的會員頁刻意**只做查詢不做儲值**，並在頁尾寫明原因。
    → 建 `topup_plans` 主檔（金額 / 贈點 / 是否啟用 / 有效期），
    POS 讀它畫按鈕、`topup_tx` 用它驗證 `p_bonus_points`。
    ⚠ 自訂金額怎麼算贈點也要一起定義 —— 現行 `bonusOf` 是級距函式不是查表，
    改成主檔時要決定「自訂 1500 算多少」是往下取級距還是不給贈點。

18. **POS 側邊欄已收成三項**（2026-08-23），以下兩項做好要加回去：
    - **快速結帳**（不開桌也能賣東西）—— 🔴 所有結帳 RPC 都要 `p_session_id`，
      所以外帶一杯奶茶、賣一副牌尺、客人只來領生日禮，**系統一律做不到**。
      這也是原本「券核銷」那一頁真正想解決的事。
      ⚠ 「券核銷」已**永久拿掉**：券是折扣，折扣必須附在消費上，
      沒有它能單獨完成的事。除非之後要接第三方團購券（GOMAJI 那類要輸入券號
      標記已使用），那是完全不同的東西，系統現在沒有那個概念。
    - **交班日結** —— 🟡 **後端幾乎齊了只是沒有畫面**：
      `v_order_settlement` / `v_entity_settlement` / `v_entity_settlement_summary` /
      `v_payment_store_mismatch` / `v_wallet_balance_check` /
      `daily_wallet_audit_tx` / `reconcile_wallets_tx`。接上就有。
      ⚠ 但它要等**店員登入**（見 PENDING）—— 不知道是誰的班，日結沒有意義。

    **庫存與報表不回來**：那是 `migi-admin` 的事。前場與後台是兩套 App
    （Square Register 上沒有進貨單），放進 POS 就是同一件事兩個地方維護。

19. ⚠ **`next_doc_no` 已經存在，不要再建第二套流水編號**（2026-08-23 發現）。
    `next_doc_no(p_org_id, p_store_id, p_doc_type)` 加上觸發器
    `trg_orders_set_no` / `trg_topup_set_no` / `trg_coupon_set_code` ——
    **訂單與儲值單在寫入當下就被自動編號了**。
    → 「配桌成功要不要給編號」的正確問法是「要不要沿用既有那套」，不是「要不要建」。
    細節查 `sql/checks/查流水編號現況.sql`（還沒跑）。

### PENDING
- 店員登入未做，`staffId` 一律傳 null，`App.jsx` 還有 `const STAFF = "小美"` 寫死
- LINE Developers 帳號未申請
