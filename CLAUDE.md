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
├─ migi-assets/        ← 🔴 三端共用的設計 token 與品牌美術（migi-hq/migi-assets）
│                        **這是唯一一個公開 repo**（其餘三個私有）。詳見硬規則 13
├─ sql/                ← 所有 Supabase SQL（非 repo，手動保存）
│  ├─ applied/         ← 已在 Dashboard 跑過的
│  ├─ pending/         ← 寫好還沒跑的
│  ├─ checks/          ← 唯讀盤點/驗證查詢，不是 migration
│  ├─ _工具/           ← **常駐開發工具：會寫入，但不是 migration**
│                        （可重複跑、檔名沒有日期、**不歸檔**）
│                        目前：`測試戰績_造.sql` / `測試戰績_清.sql`
│                        ⚠ 它們真的寫進正式資料庫（沒有 staging），所以
│                        **只動測試帳號、用固定 UUID 認回自己造的東西**
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

   **1.5 讀與寫分家（2026-08-25 決定）** ——
   這條規則當初的目的是「不要讓 Claude 亂改線上」，而**唯讀查詢從來不在那個風險裡**。
   2026-08-25 光是「快速結帳」一件事就因為唯讀查詢停了三次
   （查後端缺口 → 撈 checkout_tx → 查儲值單 where），每次都是硬停。

   | | 走哪裡 |
   |---|---|
   | **唯讀查詢**（`sql/checks/`、`pg_get_functiondef`、`information_schema`） | **Supabase MCP，Claude 自己跑** |
   | **寫入**（`sql/pending/`：DDL、migration、改資料） | **一律 Dashboard**，且看到驗證結果才歸檔 |

   ✅ **2026-08-28 已啟用並實測通過。** 設定在專案根目錄的 `.mcp.json`
   （已 gitignore），完整說明見 `docs/09-環境流程/Supabase唯讀MCP設定.md`。
   - 連線身分是 **`supabase_read_only_user`** —— 唯讀是**在連線層強制**的，不只是旗標。
     實測 `update ... where 1=0`（一列都不會動）也直接拋 `25006 cannot execute
     UPDATE in a read-only transaction`。
   - Token 只開 **Database → READ**，鎖定單一專案，30 天到期。
     ⚠ **到期就讓它過期，不要無腦續** —— 那是唯一會自動縮小暴露面的機制。
   ⚠ 已知代價：Claude 看得到會員真實資料（手機、消費、餘額）。唯讀擋「改」不擋「看」。
   ⚠ **token 無法避免進入對話紀錄** —— 編輯 `.mcp.json` 時環境會自動把差異顯示給
     Claude，這擋不掉。所以 token 的權限範圍要小、要有到期日，而不是指望它不外洩。
   ⚠ 啟用後 `checks/` 仍然要**存檔**（那是查證的紀錄，不是拋棄式指令）。

   **1.6 歸檔 pending 時，一併重跑現況匯出**（2026-08-28 立，MCP 啟用後生效）。
   `docs/01-資料庫/db-現況快照.md` 是 2026-08-14 產生的，兩週後
   **連 `products` 這張表都沒有** —— 2026-08-27 一天內查到的 7 個東西有 5 個不在裡面
   （`is_available`／`subcategory`／`discountable`／`tracks_stock`／`is_system`）。
   🔴 **靠「記得更新」已經被證明行不通一次了。**

   → 綁進既有流程：**把檔案從 `pending/` 移到 `applied/` 的那一刻，
     就是 schema 剛改過而且剛確認過的時刻** —— 同時重跑
     `sql/checks/2026-08-28_現況全匯出.sql` 並更新快照。
   ✅ **MCP 已於 2026-08-28 啟用，這條從現在起生效** ——
     重跑匯出不需要打擾使用者，所以沒有藉口讓快照再爛掉一次。

   **1.65 `applied/` 拼不回一個完整的資料庫 —— 那是 `_baseline/` 存在的理由。**
   （2026-08-29 立）
   🔴 直接在 Dashboard 改、沒留檔的東西**不在 `applied/` 裡**
     （承重牆 `uq_members_line_user` 就是）。
   → 所以**沒有人能從 `sql/` 重建一個一樣的資料庫**，只能一支一支
     `pg_get_functiondef` 撈。對「未來有人維護」是致命的。

   ✅ **`sql/_baseline/` = 某一天的完整結構快照**（機器產生，不手改）。
   ```
   重建 = baseline ＋ 之後累加的 applied/
   ```
   ⚠ **baseline 不取代 `applied/`** —— 那是歷史，記著「**為什麼**」；
     baseline 回答「**現在長什麼樣**」。**兩份都要。**

   **產生方式**：`sql/checks/匯出完整結構baseline.sql`
   （常駐工具，檔名沒有日期）→ Supabase SQL Editor 執行 → 匯出 CSV
   → 用 Python 轉成 `.sql` 放進 `sql/_baseline/`。
   🔴 **不要貼進對話** —— 347 KB 會把上下文吃光，而那份是給**人**看的不是給我看的。

   目前：`2026-08-29_完整結構.sql`（761 個物件、347 KB）
   涵蓋 12 段：擴充套件／列舉型別／資料表／約束／外鍵／索引／
   函式／**函式授權**／觸發器／檢視表／啟用 RLS／RLS policy。
   ⚠ **不含**：種子資料、Storage bucket 與 policy、pg_cron 排程、
     Edge Functions、auth schema（檔尾都標了）。

   📌 **順帶證明了文件會漂**：CLAUDE.md 記「135 支函式」實際 **138**；
     待辦 21 記「24 條 org 級 policy」實際 **28**。

   **1.7 讓過期看得見，不要靠記性。**
   快照檔頭記兩個數字：產生時間、**當時 `sql/applied/` 的檔案數與最後一個檔名**。
   要用之前比對現在的檔案數 —— 不同就是過期，而**這個檢查不需要資料庫**。
   ⚠ 但它只能證明「確定過期」，不能證明「還是新的」——
     **直接在 Dashboard 手改、沒留檔案的東西抓不到**，
     而那不是假設：`uq_members_line_user` 就是這樣來的（承重牆，`sql/` 裡找不到）。
   → 真要改 schema 時**硬規則 3 永遠成立**：先 `pg_get_functiondef` 撈線上版。
     快照只當背景參考。
2. **改函式簽名必須在同一份 SQL 檔開頭附 `DROP FUNCTION IF EXISTS`**，否則會建出多載版本。
   ⚠ **`DROP` + 重建會把 `GRANT` 一起丟掉**，所以那種檔案結尾一定要有
   `grant execute on function ...(簽名) to anon, authenticated;`。
   （`CREATE OR REPLACE` 不會丟，只有 `DROP` 會。）

   **2.5 「函式在包裝裡跑得動」不代表「前端叫得動」。**（2026-08-25 踩到）
   權限是在**呼叫點**檢查的。一支長期只被 SECURITY DEFINER 包裝**從內部**呼叫的函式，
   可能整支從來沒授權給 `anon` —— 而且**完全沒有跡象**，因為在 DEFINER 裡面
   呼叫端的權限根本不會被檢查。
   - 實例：`topup_tx` 一直只被 `pos_checkout_with_topup_tx` 內部呼叫。
     2026-08-24 會員頁第一次讓前端**直接**叫它 → `permission denied`。
     也就是**櫃檯儲值從上線那天起就沒成功過一次**，不是壞掉是從來沒通。
   - 🔴 我第一次判斷成「DROP 帶走 GRANT」，查證後推翻 ——
     那支檔案用的是 `CREATE OR REPLACE`，根本沒 DROP。**先查再下結論。**
   → **讓前端第一次直接呼叫某支既有 RPC 時，必須確認它有 `anon EXECUTE`。**
     盤點範本：`sql/applied/2026-08-25_補回前端RPC的執行權.sql`
     （一次掃三個前端呼叫的 70 支，順便查「函式存不存在」與「是不是 INVOKER」）。
   **2.6 「anon 叫得動」不等於「anon 被授權」—— 中間隔著 `PUBLIC`。**
   （2026-08-29 踩到，一份 SQL 整份是空操作）
   Postgres **建立函式時預設就把 EXECUTE 授權給 `PUBLIC`**，而 `PUBLIC`
   涵蓋所有角色。所以：
   ```
   grant_staff_tx 的 proacl：
     =X/postgres              ← 🔴 grantee 空白 = PUBLIC，anon 從這裡進來
     postgres=X/postgres
     authenticated=X/postgres
     service_role=X/postgres
                              ← ⚠ 沒有 anon 這一列
   ```
   🔴 **`revoke execute ... from anon` 對它完全沒有效果，而且不會報錯** ——
     收一個沒被授權的角色是合法的空操作。
   → 要真的收，是 `revoke ... from public`。

   ⚠ **`has_function_privilege('anon', oid, 'execute')` 分不出這兩種**
     （明確授權 vs 從 PUBLIC 繼承），所以它可以用來**驗結果**，
     **不能用來判斷「誰被授權了」**。要分辨只有 `aclexplode`：
   ```sql
   -- 明確授權給 anon
   exists (select 1 from aclexplode(p.proacl) a
            where a.grantee = 'anon'::regrole::oid and a.privilege_type='EXECUTE')
   -- PUBLIC 有沒有
   (p.proacl is null or exists (select 1 from aclexplode(p.proacl) a
            where a.grantee = 0 and a.privilege_type='EXECUTE'))
   ```
   📌 `proacl is null` = **完全沒動過** = PUBLIC 有、其他人沒有。

   🎯 **這件事救回來是因為驗證段**：revoke 成功、驗證回「12 支全部還在」，
     兩者同時發生而且都不是 bug —— 是**指令下錯了**。
     沒有那段驗證，那份 SQL 會被當成做完了（同硬規則 3.55）。

   ### 🔴 2.6b 反過來的那一半：新建的函式，anon 是**明確**授權
   （2026-08-29 同一天踩到，方向相反）
   Supabase 在這個專案設了：
   ```sql
   alter default privileges in schema public
     grant execute on functions to anon, authenticated, service_role;
   ```
   （`pg_default_acl` 可查，`postgres` 與 `supabase_admin` 各設了一份。）
   ⇒ **在 `public` 新建的每一支函式，一建立就是 anon 叫得動的**，
     而且那是**明確授權**不是 PUBLIC 繼承。

   | 情況 | anon 從哪來 | 要怎麼收 |
   |---|---|---|
   | 舊的管理函式 | **PUBLIC 繼承** | `revoke from public` |
   | **新建的函式** | **default privileges 明確授權** | `revoke from anon` |

   🔴 **兩條路都要收才乾淨。** 我在同一天兩次都收錯方向：
     先是收了 anon 沒效果（來源是 PUBLIC），
     後是收了 PUBLIC 沒效果（來源是明確授權）。
   → 新建**不該給前端叫**的函式時，兩行都要寫：
   ```sql
   revoke execute on function public.f(...) from public;
   revoke execute on function public.f(...) from anon, authenticated;
   grant  execute on function public.f(...) to service_role;
   ```
   ⚠ 驗證段不要只印 `has_function_privilege` ——
     **同時印「明確有沒有」與「PUBLIC 有沒有」**，
     否則收錯方向時看到的症狀跟沒收一模一樣。

   ### 🔴 2.6c `create extension` 一律寫 `with schema extensions`
   （2026-09-01 踩到，踩坑第 30 條）
   ```sql
   create extension if not exists btree_gist with schema extensions;
   ```
   不寫 schema → 進 `public` → **整包函式吃上面那條 default privileges**。
   實例：`btree_gist` 帶了 **188 支**進 `public`，**全部明確授權給 anon**，
   `public` 的函式數 157 → 347。
   ✅ 這個專案的慣例本來就對（`pgcrypto`／`uuid-ossp`／`pg_stat_statements`
     都在 `extensions`），是我沒跟。
   🎯 **它是被硬規則 1.6 抓到的** —— 那一步抓到的不是「文件過期」，
     是**一個沒有任何症狀的授權變動**。

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

   **3.5 掃全文找禁字時，禁字不能是自己註解裡會出現的詞。**
   驗證段常寫「掃全庫確認某個舊寫法已消失」，但 `pg_get_functiondef` 回的是
   **含註解的全文**，字串比對分不出程式碼與說明文字。已經踩兩次：
   - 2026-08-23 修 `grant_staff_tx` 角色值，掃 `clerk` 被自己寫的註解觸發
   - 2026-08-25 建 `pos_quick_checkout_tx`，掃 `session_id` 被
     自己寫的「**不回填 session_id**」觸發，回報「🔴 竟然引用了桌次」

   → **禁字只用「會產生行為的東西」：表名、函式名。**
   表名不會出現在正常的說明文字裡，欄位名會（`session_id`、`kind`、`status`
   這種到處都有的詞尤其危險）。
   → 真的必須掃欄位名時，改成**逐行印出來讓人判讀**，不要回傳一個是非題
   （範本：`sql/checks/2026-08-25_驗證快速結帳沒碰桌次.sql`）。
   → 同踩坑第 25 條：**先懷疑儀器再懷疑資料。**

   **3.55 驗「應該是空的」時，一定要有正對照。**（2026-08-28 立）
   🔴 **「回 0 列」同時是「正確阻擋」與「東西寫壞了」的症狀 ——
     兩者長得一模一樣。** 只驗「應該是 0」的那一半，等於沒驗。

   → 一定要再跑一次**故意讓它應該有資料**的版本，看它真的會冒出來。
   實例：2026-08-28 建 12 個 `v_real_*`，`live_from` 未設時全部回 0 ——
   看起來完美。但把時間下限換成很早的日期跑正對照，才發現
   **我把「漏出去的筆數」說成 2847，實際只有 2** ——
   舊 view 早就有「會員是測試」那一道，擋掉了 2845 筆。
   ⚠ 沒有正對照，那個錯誤的數字會留在文件裡，而且看起來完全合理。

   📌 同樣適用於：擋牆（要驗「該擋的擋了」**也要驗「不該擋的沒被誤擋」**）、
     RLS policy、任何回傳「沒有結果」的查詢。
     **過度阻擋跟沒擋一樣糟，而且更難發現。**

   **3.6 `{/* */}` 只在 JSX 的「子元素位置」合法。**（2026-08-25 掛掉一次 build）
   2026-08-18 記的是「不能放進屬性列表」，但實際規則更嚴：
   運算式位置（`? (` / `: (` / `=> (` / `return (` 之後）也不行，要用**裸的** `/* */`。
   ```jsx
   ) : (
     {/* 說明 */}            ← 🔴 parser 把 { 當成物件實字
     <div style={{ ... }}>
   ```
   🔴 **錯誤訊息會指向下一行**：`Expected ")" but found "style"` ——
   看起來像 `style` 有問題，實際原因在前面兩行。這是這個坑最花時間的部分。
   → 檢查器：`jsxcomment.py`（屬性列表變體）＋ `jsxcomment2.py`（運算式位置變體）。

   ✅ **2026-08-28：本機終於裝了 Node（v24.20.0），`npm run build` 跑得動了。**
   三個 repo 都是 `vite build`，在此之前**從來沒在本機 build 過** ——
   每次都是推上去讓 Cloudflare 告訴你對不對，而這個坑就炸過一次 Cloudflare build。
   🔴 **從現在起，推之前先在本機 build。** migi-web 實測 2.29 秒。
   ⚠ 靜態檢查器仍然有用（它們抓的是 build 抓不到的東西，例如
     `tone="plain"` 站在灰底上），但**不再是唯一的防線**。
   ⚠ 首次要先 `npm install`（`node_modules` 不進版控）。

   **3.7 掃全庫函式內文時，`pg_get_functiondef` 一定要先過濾 `prokind = 'f'`。**
   （2026-08-25 炸過一次）
   它**對聚合函式會直接拋錯**：`ERROR 42809: "array_agg" is an aggregate function`。
   `pg_proc` 裡混著 `f` 一般函式 / `a` 聚合 / `w` 視窗 / `p` 預存程序。
   🔴 **光加 `nspname = 'public'` 擋不住** —— WHERE 裡的函式可能在 join 過濾
   之前就被求值，規劃器不保證順序。安全寫法：
   ```sql
   from pg_proc p
   where p.pronamespace = 'public'::regnamespace   -- 直接比對，不 join
     and p.prokind = 'f'                            -- 排除聚合／視窗／程序
     and pg_get_functiondef(p.oid) ilike '%關鍵字%'
   ```
   ⚠ 先前幾支同樣寫法沒炸，是因為它們還有 `proname = any(名單)` 這個便宜的
   條件先把範圍縮掉了 —— **那是運氣不是設計**。

   **3.8 約束名稱不等於約束內容。**（2026-08-26 踩到）
   錯誤訊息只給你名字（`app_events_event_check`），**沒給定義**。
   看到 `xxx_check` 就推論它是白名單／範圍／格式，那是猜。
   - 實例：`app_events_event_check` 我推論成「事件名白名單」，
     還據此討論了一整段「要擴充 CHECK 還是改成註冊表」——
     實際上它是 `CHECK (event ~ '^[a-z][a-z0-9_]{0,49}$')`，**只管格式**。
     我的測試事件叫 `_smoke_pos_log`，敗在底線開頭而已。
   → `pg_get_constraintdef(oid)` 一句話就撈得到。**先撈再說。**

   **3.8.5 猜「約束允許哪些值」跟猜約束內容一樣糟。**（2026-08-26 踩到）
   測試裡寫 `origin = 'manual'`，而實際是 `origin ∈ ('pre_existing','matched')`
   —— 整個唯一性測試因此沒跑到。
   → 要在測試裡填一個受 CHECK 約束的欄位時，**從約束把值撈出來**：
   ```sql
   select (regexp_matches(pg_get_constraintdef(c.oid), '''([a-zA-Z0-9_]+)''::text'))[1]
   ```
   ⚠ **讀一半比沒讀更危險**：我當天讀過那張表的定義，看到
     `check (member_id <> buddy_id)` 就以為那是全部的 CHECK，
     而 `origin` 的 check 在我沒讀到的上面幾行。「我看過了」給了不該有的信心。
     （同日另一例：看到 `api.js` 每支都送 `p_session_id` 就推論後端非有桌不可。）

   **3.85 前端也有「跑得起來但看不見」這一類。**（2026-08-27 踩到兩處）
   統一膠囊時把「店的客觀屬性」改成中性色調 `plain`（＝`--field-bg`），
   但那兩列的**底色本身就是 `--field-bg`** —— 膠囊整顆消失，
   而且 `match.jsx` 的門市列看起來像**資料壞掉**（店名後面浮著三個字）。
   🔴 **括號平衡、漏 import、JSX 註解位置、build 全部通過，什麼都不會說。**
   → 這跟硬規則 4 的「RLS 濾成空陣列且不報錯」是同一個形狀，
     差別只在一個是資料層一個是視覺層。**畫出來才會發現。**
   → 定色調時要問的不是「這是什麼顏色」而是「**它站在什麼底上**」。
     `Pill` 因此分成 `plain`（只能用在白底）與 `paper`（用在灰底的列）。
   ⚠ 檢查器 `pillcheck.py` 已加一段：每顆 `tone="plain"` 往上找最近的
     容器背景並**逐行印出讓人判讀**（不回傳是非題，同 3.5）。

   **3.86 🔴 元件不可以定義在另一個元件的函式體裡。**（2026-08-28 實測抓到）
   React 是**用元件型別辨識元件**的。定義在函式體裡的話，每次 render
   都會產生一個新的函式（＝新的型別）→ React 認定「這是別的東西」→
   **卸載整棵子樹再重新掛載**，而不是更新它。

   實測（`Register` 的暱稱欄位，每打一個字）：
   ```
   節點有換嗎 = true　　焦點還在嗎 = false
   ```
   → **客人每打一個字，輸入框就被銷毀重建、焦點掉** ——
     在真的手機上等於**打一個字鍵盤就收起來**。

   🔴 **完全不會有任何錯誤訊息**：build 通過、靜態檢查器通過、
     畫面看起來也完全正常 —— 因為畫面**確實**畫對了，
     壞的是「同一個 DOM 節點有沒有被保留」。
     這與 3.85（`tone="plain"` 站在灰底上）是同一族：**只有真的操作才會發現。**

   ⚠ 這個 bug 在 `Register` 裡活了很久沒人發現，因為
     ① 那時註冊只寫 localStorage，沒有人認真在上面打過字
     ② 本機 dev server 從來沒跑起來過（硬規則 11.5）

   → 判準很簡單：**`const X = (...) => <.../>` 出現在另一個元件裡面就是錯的。**
     它們通常只吃 props、沒有用到外層的閉包，搬到模組層是零成本。
   ⚠ 真的需要閉包時也不要留在裡面 —— 把需要的東西當 props 傳進去。

   **3.9 `set_config(key, val, true)` 會被 savepoint 回滾。**（2026-08-26 踩到）
   驗證段常用 `DO ... EXCEPTION` 接住錯誤、再用 set_config 把結果傳給
   最後那支 SELECT。⚠ 但 `is_local = true` 是**交易內**的設定 ——
   寫在 `raise` 之前的話，會跟著被回滾掉，最後印出**空白**。
   ```sql
   -- 🔴 訊息會不見
   perform set_config('migi.x', '✅ 成功', true);
   raise exception 'rollback_on_purpose';
   -- ✅ 訊息留得住
   exception when others then perform set_config('migi.x', '…', true);
   ```
   → **訊息一律設在 exception 處理器裡**，不要設在成功路徑上再 raise。
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

   **5.6 排優先序的判準是「這個捷徑的利息」，不是「有多不完美」。**
   （2026-08-27 討論，2026-08-28 補記）

   | 捷徑 | 利息 | 所以 |
   |---|---|---|
   | **身分靠前端宣告** | 🔴 **複利** —— 客人越多、綁定越固定、越難拆 | 越早越好 |
   | **稽核欄位空著** | 🔴 **不可回溯** —— 今天不填，這段歷史就永遠沒有 | 越早越好 |
   | 價格／贈點信前端 | 🟡 **固定** —— 今天改跟明年改成本一樣（一支函式） | 排隊即可，但 KIOSK 一出現就變成洞 |
   | 角色只有一欄 | 🟢 **負利息** —— 只有 1 個 staff，現在定義是憑空想像 | **現在做反而錯** |

   → **利息高的先還，固定利息的排隊，負利息的不要碰。**

   **5.7 永遠不要做（明列，不要每次重新討論）：**
   - **角色繼承** —— RBAC 最常被誤用的功能，而且沒有人說得出「店長繼承店員」包含什麼
   - **自建密碼系統** —— 一律用託管的
   - 🔴 **開發用的 JWT 旁路**（「給我一個 sub 就發 JWT」）——
     那等於「輸入任何會員 id 就能變成他」，**而且一旦存在就會忘記拿掉**
   - **促銷規則引擎／DSL** —— 待辦 0.8 的 `coupon_scope` 表是對的規模，再大就是為七間店蓋 SAP
   - **為七間店做完整權限矩陣** —— 權限碼控制在 10–15 個
   - **staging 環境** —— 要有人維護三套資料，而那個人不存在。
     現行的「交易內測試 + 回滾」對這個規模是對的選擇

   **5.8 一句話的鐵律：`never trust the client`。**
   前端只送**意圖**（`product_id` + `qty`、儲值金額），不送**事實**（單價、贈點、身分）。
   Stripe 不讓你送金額給別人的卡；Shopify 的 checkout 從來不信前端算的價格。
   ✅ 價格（待辦 2）與贈點（待辦 17）都已完成；⏳ 只剩身分（待辦 14，卡 LINE）。
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

10. **假資料是流程的一部分，不是缺陷。**（2026-08-27 使用者說明，我違反過）
    開發順序固定是：**先用假資料把 UI／UX 做出來 → 再一個一個接真資料 → 全部接完才上線。**

    → 所以看到寫死的資料時，正確的反應是「**這一項還沒接**」，
      不是「這是 bug」，更不是「這個功能該砍掉」。
    🔴 **不准提議標「即將推出」，也不准提議把功能移出上線範圍。**
      2026-08-27 我盤點完假資料後同時提了這兩個，兩個都違反這條原則。
      「所有功能都要留著」是既定的，不是每次要重新討論的選項。
    ⚠ 唯一該做的是**把「還沒接」講清楚並排序**，讓接線有先後。

    **推論：假資料的存在不構成「不能上線」的理由，但「上線」的定義是全部接完。**
    因此上線時間受最慢的那一項決定 —— 例如逐手重播與結算依賴牌譜（M5+），
    那上線就在 M5 之後。**這是排程事實，不是要拿來說服使用者砍功能的理由。**

    ⚠ 判斷「假的」時仍要分辨兩種東西：
    - **狀態**（餘額、解鎖了沒、誰在團裡）→ 一定要接
    - **內容清單**（成就有哪些、小熊有幾種、零食圖）→ 寫死是合理的，那是內容不是狀態

11. **推之前先在本機 build。**（2026-08-28 起可行）
    ```
    cd <repo>；npm run build
    ```
    三個 repo 實測：migi-web 2.29s／migi-pos 3.87s／migi-admin 2.20s，
    **加起來不到 9 秒**。便宜到沒有理由不做。

    🔴 在此之前**從來沒有在本機 build 過** —— 每次都是推上去讓 Cloudflare 告訴你對不對。
    2026-08-27 就因此炸過一次（JSX 註解位置，錯誤訊息還指向下一行），
    而那種錯誤本機 build 兩秒就會抓到。

    ⚠ 首次要先 `npm install`（`node_modules` 不進版控，各約 72 個套件、10 秒內）。
    ⚠ **靜態檢查器仍然要跑** —— 它們抓的是 build 抓不到的東西
    （`tone="plain"` 站在灰底上、`{/* */}` 在運算式位置）。**兩者不重疊。**

    📌 這是「沒有自動化測試」那個缺口裡**唯一今天就能關掉的一格**。
      其餘兩格（`sql/checks/` 沒人定期跑、`app_events` 的錯誤沒人在看）還開著。

    **11.5 🔴 `npm run build` 通過**不代表** `npm run dev` 跑得動。**（2026-08-28 踩到）
    兩者的模組解析根本不同：
    | | 誰在解析 | import 一個不存在的具名匯出 |
    |---|---|---|
    | `npm run build` | Rollup（打包） | 🟡 只警告，值變 `undefined` |
    | `npm run dev` | **瀏覽器原生 ESM** | 🔴 **模組載入期 SyntaxError，整個 App 起不來** |

    實例：`App.jsx` import 了 `DEMO_MATCHES` / `DEMO_RECORDS`，而 `data.jsx`
    根本沒有 export 它們。CLAUDE.md 待辦 33 寫「只因為沒人用才沒炸」——
    **錯的**：build 不炸，dev **畫面全白**。
    → 也就是**本機 dev server 從來沒有人成功跑起來過**，
      而那正是為什麼這個死 import 活了這麼久。

    ✅ **要看畫面就一定要跑 dev server**（硬規則 3.85：畫出來才會發現）。
    ⚠ 開發環境需求（2026-08-28 建立）：
    - `.claude/launch.json` 在**母資料夾**（不是各 repo 底下），
      三個 repo 用 `npm --prefix <repo> run dev`，port 5173／5174／5175
    - 各 repo 要有 `.env`（已被各自的 `.gitignore` 擋住）：
      `VITE_SUPABASE_URL` ＋ `VITE_SUPABASE_ANON_KEY`
      ⚠ anon key **本來就是公開的**（會被打包進瀏覽器拿得到的 JS），
        真正的防線是 RLS 與 SECURITY DEFINER，不是這把 key 的機密性。
    - 🔴 **MCP 的 token 拿不到 API key**（只開 Database READ）——
      那不是缺陷，是權限範圍設對了的證據。要 anon key 得去 Dashboard。

    **11.6 🔴 本機 dev server 連的是「正式資料庫」—— 在上面點按鈕就是在改真資料。**
    （2026-08-30 踩到）
    `.env` 裡的 `VITE_SUPABASE_URL` 指向唯一那個 Supabase 專案，
    **沒有 staging**（硬規則 5.7 明講不做）。所以：
    ```
    npm run dev  →  真的 RPC  →  真的 members / orders / wallets
    ```
    實例：驗「頭像選取會不會移動」時在瀏覽器點了幾下，
    創辦人的 `avatar_bear` 從 `null` 變成 `bronze` ——
    `updated_at` 距當下 **4 分 38 秒**，時間戳直接指認是我做的。
    🔴 **我原本以為那是使用者昨天改的**，是查了 `now() - updated_at` 才確定。

    ⚠ **唯讀 MCP 完全擋不到這件事** —— 那條防線管的是我下的 SQL，
      而瀏覽器走的是 anon key ＋ SECURITY DEFINER 的 RPC，是另一條路。
      **「Claude 只有唯讀權限」在開著 dev server 的時候是假的。**

    → 規矩：
    · **驗證盡量用量測（`getComputedStyle` / `getBoundingClientRect`）而不是點按鈕。**
      畫面對不對用量的就夠了，不需要真的送出。
    · 非點不可時（例如驗「選取會不會移動」），**只點到狀態改變為止，
      不要按下「套用／送出／刪除」那一類會寫入的按鈕**。
    · 真的寫進去了：**先用 `updated_at` 確認是不是自己造成的**（不要假設），
      **然後用同一條 UI 路徑還原**，並主動告知。
    · 要造資料驗證後端就走「交易內測試 ＋ 回滾」（硬規則 1），不要用瀏覽器。

    ### ✅ 寫入攔截器：驗證前先裝，讓寫入物理上送不出去
    （2026-08-30 實戰通過）
    ```js
    // 白名單只放讀取類，其餘回 403 並記錄
    if (m && !/^(get_|list_|has_|calc_)/.test(m[1])) { … return 403 }
    ```
    🔴 **2026-09-01 踩到一個順序問題：攔截器裝在 `location.reload()` 之前
      等於沒裝。** reload 會把 `window.fetch` 還原，而那一次載入
      **正是最需要保護的時刻**（App 開機會呼叫最多東西）。
      ⚠ 而且**它不會有任何症狀** —— 攔截器「裝好了」的訊息照樣印出來。
    → **正確順序：先 `navigate`／reload，再裝攔截器，然後才操作。**
      ⚠ 真的順序做錯了：用 `updated_at` 事後查一次
      （那天查了七張表全部 0 列，POS 桌況確實只呼叫 `list_*`）——
      **但那是事後查證不是事前防護，不要拿它當通過。**

    🎯 為什麼是這個而不是「我會小心」：
    · **不進產品碼** → 不可能被部署出去（避開硬規則 5.7「一旦存在就會忘記拿掉」）
    · **fail closed** → 忘了裝只是失去保護，不會弄壞東西
    · 它會**列出擋下了什麼**，等於順便告訴你「這一頁其實會寫入」

    🔴 第一次用就抓到：**光是打開「養成小熊」那一頁就會呼叫
      `save_app_state_tx`** —— 那一頁的 debounce 在載入後就會存一次。
      沒有攔截器的話，只是「看一眼畫面」就會動到線上資料。

    📌 更安全的替代做法：**攔截 `fetch` 改寫回應**。
      它能逼元件走自己真正的渲染路徑（比改 DOM 有意義），
      而且**完全不寫入**。2026-08-30 用它驗了兩件事：
      「有照片時標籤變成『我的照片』」與「餘額兩頁同步」。
      ⚠ 用完要還原 `window.fetch` 並重載，不要留在頁面上。

13. 🔴 **設計 token 一律來自 `@migi/assets`，不要在任何 repo 裡再定義一份。**
    （2026-08-29 建立）

    ```jsonc
    // 三端的 package.json
    "@migi/assets": "github:migi-hq/migi-assets#v1.3.0"
    ```
    ```js
    import '@migi/assets/tokens.css'              // 定義 :root（三端）
    import { C } from '@migi/assets/tokens.js'    // POS 的 C 物件（從 shared.jsx re-export）
    ```

    ### 為什麼存在（這是一個真的發生過的病）
    2026-08-15「三端統一色彩 token」統一的是**命名**不是**來源** ——
    三份 `:root` 靠手抄同步。而**手抄的東西只會抄「當下需要的」**：
    ```
    2026-08-15  POS 抄了 17 個顏色
    之後        web 長出字級／圓角／間距／陰影（27 個）→ POS 沒跟上
    2026-08-29  POS 有 304 個寫死 fontSize、117 個寫死 borderRadius，
                而它的 var(--) 只用了 17 次
    ```
    🔴 **那不是店員端偷懶，是那份 token 從來沒送到它手上。**

    ### 改 token 的流程（**不要直接改 dist/**）
    ```bash
    cd migi-assets
    # 1. 改 tokens.json    2. npm run build    3. commit（產出物一起）
    git tag v1.4.0 && git push --tags
    # 4. 三端 package.json 把 #v1.3.0 改成 #v1.4.0 → npm install
    ```
    ⚠ **版本用 tag 不要用 branch** —— `#main` 會讓同一份 package.json
      在不同時間裝到不同東西。
    📌 **這不會讓三端變成一起部署**：POS 可以停在舊版，
      它是收銀機，不該因為會員 App 改了顏色就跟著動。
    ⚠ 產出物 `dist/` 要 commit（git 相依沒有 publish 步驟）。
      `npm run check` 會擋「改了 tokens.json 但忘了 build」——
      那件事一定會發生，而症狀是**三端裝到舊值且沒有任何錯誤**。

    ### 🔴 什麼可以進去、什麼不行
    | | |
    |---|---|
    | ✅ **設計 token** | 顏色／圓角／字級／間距／陰影／層級／邊框／動畫／圖示尺度 |
    | ✅ **品牌識別美術** | 段位熊、預設頭像、日後的 logo —— **穩定、跨端** |
    | ❌ **內容美術** | 徽章、零食、活動 hero、抽獎獎品 —— **隨活動更新、只有會員 App 用** |
    | ❌ **任何碰 Supabase 的程式碼** | 那個 repo 是**公開**的 |

    ⚠ 判準是**變更頻率**不是大小。活動圖進來的話，每換一張 hero 就要
      改套件 → 打 tag → 三個 repo 可能都要 bump，**而其中兩個根本沒用到那張圖**。
    ⚠ 灰色地帶（養成小熊 `bear-lv*`、教練熊）歸類為**內容** ——
      **判準問的是「它為什麼存在」，不是「它畫的是什麼」。**

    ### 檢查器
    ```bash
    python tokencheck.py            # 抓「有 token 可用卻寫死」
    python tokencheck.py --all      # 連「沒有 token 可用」的也列（判斷用）
    ```
    🔴 **遷移舊的寫死值是固定利息**（今天改一處跟明年改一處成本一樣），
      **但「新寫的程式碼繼續寫死」是複利** —— 每寫一行 UI 就多一個要遷移的點。
      → 檢查器才是那個擋著的東西，遷移可以慢慢來。

    ⚠ 它只報「值剛好等於某個 token」的 —— 那些是零風險零判斷的取代。
      值對不上的（`fontSize: 17` 那種）預設不報，因為那是**設計問題**
      （該升 16 還是降 19），不是機械工作。

    **13.5 字階只有 9 階，圖示與字階分家。**
    ```
    --xxxs 11  --xxs 12  --xs 13  --s 14  --m 15  --l 16  --xl 18  --xxl 22  --h 38
    --icon-sm 13   --icon-nav 22        ← 返回 ‹、關閉 ×、小箭頭 ›
    ```
    🔴 **挑不到就提出來討論，不要再加一階。** 2026-08-29 之前有 **22 種字級** ——
      那不是「需要 22 個 token」，是「沒有人決定過字階是什麼」。
      把 22 個都給名字，等於**用 token 認可那個混亂**。
    🔴 **用文字字元畫的圖示（`›` `‹` `×` `+`）不可以用字級 token。**
      它們用 `fontSize` 只是實作方式。掛上 `--xxl` 的話，
      哪天把 `--xxl` 從 22 調到 24，**全站的返回鍵會一起變大而沒有人預期**。
      ⚠ 那是**分類錯誤不是視覺 bug** —— 而分類錯誤會**在下一次改動時才爆炸**。

    **13.6 層級只有 6 階，不要再往上加數字。**
    ```
    --z-sticky 100（切頁）  --z-sheet 1000  --z-sheet2 1100  --z-sheet3 1200
    --z-overlay 1500        --z-toast 2000  --z-alert 2100
    ```
    🔴 這條規則存在的原因：在這之前有 9 個手挑的數字，
      其中 `1050` / `1300` / `1400` / `1600` **各只出現一次** ——
      它們不是層級，是**當時有人發現「我被蓋住了」就往上加了一點**。
    ⚠ 它**沒有錯誤訊息**：症狀是「彈窗被蓋住、按了沒反應」，
      而且要**剛好開到那個組合**才會遇到。
    ⚠ **不要加第四層抽屜** —— 三層以上的堆疊對手機是迷路，那時該用切頁。
    ⚠ `position: absolute` 在卡片**內部**的 `z-index: 0/1/2/3` 是局部堆疊，
      **與全域層級無關，不要換成 token**（換了會讓它跳出那張卡）。

12. **每次 session 開始跑一次 `sql/checks/錯誤儀表.sql`。**（2026-08-28 起，MCP 直接跑）
    埋點的寫入端做好了（migi-web 2026-07、POS 2026-08-26），但**讀取端是零** ——
    🔴 2026-08-28 第一次打開，**50 筆 `app_error` 躺了一個多月沒有人看過**，
    而其中一個是**還活著的結構問題**（`players` 一個 key 兩種形狀，見待辦 35）。

    ⚠ 為什麼是「session 開始」而不是排程：**排程要有人看告警，而那個人不存在**（硬規則 5.5）。
      CLAUDE.md 每次 session 都會載入 —— **寫在這裡就是機制本身**。
      同硬規則 1.6／1.7：把檢查綁在一個**一定會發生的動作**上。

    ⚠ **「零筆錯誤」不等於沒問題** —— 也可能是埋點自己壞了。
      `app_events` 有 CHECK（`event ~ '^[a-z][a-z0-9_]{0,49}$'`、`props <= 8192`），
      違反就插入失敗，**而埋點是靜默的，那一筆會直接消失**。
      所以儀表的第 ② 段看的是「近 7 天有沒有事件進來」。

## localStorage 放什麼（2026-08-30 盤點並清理）

**判準：狀態進後端，快取與暫存留本機。**

| key | 是什麼 | 正本 |
|---|---|---|
| `migi_member` | **身分 ＋ 暱稱快取** | 身分 🔴 沒有正本（待辦 14）／暱稱 = `members.display_name` |
| `migi_avatar_cache` | 頭像 URL | `members.avatar_*` |
| `migi_evt_queue` | 埋點離線佇列 | — 本來就該在本機 |
| `migi_reload_mark` | 版本重載記號 | — 本機 |
| `migi_pending_table_invite` | 待處理的桌邀請 | — 暫存 |
| `migi_noti_*` | 通知開關 | ⚠ 只在本機，換裝置會回預設（可接受，但要知道） |

✅ **已搬進後端**：小熊名字 → `member_app_state.bear.name`（2026-08-30，零 SQL）。
🧹 **已刪除**：`migi_bear_name` 的寫入端、`migi_def_store`（沒有任何地方讀它）。

### 🔴 快取有一條鐵律：**只能有一個寫入點，而且要會自我校正**
`migi_member.name` 修之前是「註冊當下回傳的名字，之後再也不會更新」——
在別的裝置改了暱稱，這台**永遠顯示舊的而且完全沒有症狀**。
→ 現在 `fetchMyProfile()` 每次讀到後端資料就順手校正它，
  `setMyNickname()` 成功後也更新它，**其他地方一律不准寫**。

⚠ 這個病在這個專案出現過**三次**，形狀都一樣（本機說了算）：
`App.jsx:95` 的身分判斷（待辦 14）、手機號碼那一列（待辦 36）、暱稱。
**下次看到「畫面的值來自 localStorage 而後端也有一份」就是它。**

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
- **一個 LINE 帳號只能屬於一個 org**（2026-08-26 查證後確立的既成決定）。
  `members` 上有**兩個**與 `line_user_id` 有關的唯一索引，它們的意圖互相矛盾：

  | 索引 | 意圖 | 來源 |
  |---|---|---|
  | `uq_members_line (org_id, line_user_id)` | 允許同一個 LINE 帳號在**不同 org** 各有一個會員 | M0 地基，`00a_M0建表_資料骨架.sql:131` 有註解 |
  | `uq_members_line_user (line_user_id)` | **全域唯一**，跨 org 不行 | 🔴 `sql/` 裡完全找不到 —— 直接在 Dashboard 手動建的，沒留紀錄 |

  🔴 **`uq_members_line_user` 是承重牆，不可移除**（2026-08-26 逐行查證）：

  ```sql
  -- current_member_id()：**完全沒有 org 過濾**
  select m.id from members m
   where m.line_user_id = (auth.jwt() ->> 'sub')
     and m.deleted_at is null
   limit 1;              -- 沒有 order by ⇒ 任意一列
  ```
  沒有 org 過濾是**必然的不是疏漏** —— org 是從 member 查出來的，
  不可能先用 org 縮小範圍（雞生蛋）。
  → 因此 **composite `(org_id, line_user_id)` 在身分解析上完全幫不上忙**：
    查詢根本不給 org，它只保證「同 org 內不重複」，跨 org 重複照樣通過。
  → **只有全域唯一能保證「我是誰」有唯一答案。**

  ⚠ 三支身分函式（`current_org_id` / `current_member_id` / `current_staff`）
    **都有 `LIMIT 1`**，所以重複時**不會報錯，會靜默選錯**——
    那位客人會拿到別人的身分、看到別人的錢包。**完全沒有症狀。**

  📌 所以真相不是「手動索引推翻了地基設計」，而是
    **地基的設計（允許跨 org）與地基自己寫的 `current_org_id()` 互相矛盾**，
    有人發現了、補上索引，但沒把這件事寫下來。
  → **兩個都留著**（刪 composite 省不到東西，而且它是 M0 文件引用的那個）。
  ⚠ 日後真的要跨 org（加盟、代營運）時，**要改的是那三支函式的身分解析方式**
    （例如 JWT 帶 org、或 line_user_id + org 一起當鍵），**不是把索引拿掉**。
  ✅ 2026-08-26 確認兩個索引都是 `indisvalid = true`（INVALID 的索引會
    存在、看得到、但完全不擋 —— 而且沒有任何症狀）。

- **註冊就是綁定：`register_member_tx` 本身就是 find-or-bind-or-create**
  （2026-08-26 查證）。不需要為「既有客人第一次用 LINE」另外設計流程：
  ```
  ① 有 line_user_id 且查得到 → 'existing_line'（不新建）
  ② 有 phone 且查得到 → 綁上去 → 'rebound'
     ⚠ 那個會員已綁**別的** LINE → 'line_conflict'（2026-08-26 修，舊版會謊報成功）
  ③ 都查不到 → 'created'
  ```
  ⚠ `rebind_line_user_tx` **不是註冊流程的一部分**，它是店員的補救工具
    （客人換手機／換 LINE 帳號），簽名裡有 `p_staff_id` 就是證據。
  ⚠ 四個測試帳號接 LINE 時走 ②，`is_test` 不受影響。

- 代付：檯費份數 = 自己 1 份 + 代付人數。被代付者仍建立 `session_players` 記錄，
  但 `charged_points = 0`、`paid_by = 付款人`。消費金額與發票都歸付款人。
- 埋點測試隔離：`app_events.is_test`。
  ⚠ **2026-08-29 再更正一次**：這裡曾寫「`app_events` **沒有 `store_id` 欄位**」
  —— **現在是錯的**，它有，而且 `v_real_app_events` 正在用它擋測試門市
  （`not exists (select 1 from stores s where s.id = x.store_id and s.is_test)`）。
  📌 那句話在 2026-08-26 寫下時是對的，是後來補上的 —— **文件會漂，第三次**。
  `is_test` 本身仍然是 `log_app_event_tx` **從會員**推的
  （`if p_member_id is not null then select is_test from members`），
  寫入時蓋章，而 `trg_app_events_no_mutate` **連 UPDATE 都擋 ⇒ 蓋錯了改不掉**。

  ### 🔒 三層防線，各自管什麼（2026-08-29 查 view 定義確認）
  | 層 | 擋什麼 | 現在 |
  |---|---|---|
  | ③ **時間下限** `orgs.live_from` | **上線日之前的一切** | 🔒 最硬。`coalesce(live_from,'infinity')` ⇒ null = **全擋** |
  | ① `members.is_test` | 特定的人 | 五個帳號（含創辦人）都是 true |
  | ② `stores.is_test` | 測試門市 | 一直都在 |

  🎯 **`live_from` 是 null 時，每一支 `v_real_*` 都是空的** ——
  ```
  x.created_at >= coalesce(o.live_from, 'infinity'::timestamptz)   -- 永遠 false
  ```
  實測 2026-08-29：原表 `orders` 153／`app_events` 3375，
  而 `v_real_orders` = `v_real_app_events` = `v_real_wallet_txns` = **0**。
  → **今天沒有任何東西汙染得了報表，而那是設計上的空不是巧合。**
  → 上線那天把 `live_from` 設成當天，**今天這批全部永久消失在報表外**。

  ⚠ 所以 `is_test` 管的**不是**上線前的資料（時間下限已經全擋），
    而是**上線之後你還在用同一個帳號測試**的那段時間。
  🔴 真正會漏的只剩一種：**上線之後、既沒有會員也沒有測試門市的紀錄**
    —— 三層都認不出它。那正是 CLAUDE.md 記過的那 2 筆的形狀。

  過濾用的檢視表共 **12 個** `v_real_*`。
  ⚠ 其中 `v_real_order_items` / `v_real_order_payments` **自己不判斷 `is_test`**，
    而是 `exists (select 1 from v_real_orders ro where ro.id = x.order_id)`
    —— **間接繼承，過濾邏輯只有一份**。那是對的設計，不是漏掉。
  做報表一律查 `v_real_*`，直接查原表會把測試資料算進營運數據且不報錯。

  ⚠ **`app_events` 有 2847 筆 `is_test = false`，而它們全部是測試資料** ——
  那是 2026-08-26 修 `is_test` 推導之前累積的（在那之前 POS 事件的
  `member_id` 一律 null → `is_test` 恆為 false）。而且**改不掉**：
  `trg_app_events_no_mutate` 同時擋 DELETE 與 UPDATE。

  🔴 **我一度把這件事說成「2847 筆會原樣通過報表」—— 那是錯的**（2026-08-28 更正）。
  舊的 `v_real_app_events` 本來就有「會員是測試」那一道，它擋掉 2845 筆，
  **實際漏出去的只有 2 筆**：
  ```
  2026-07-13  test_event  門市=null 會員=null  {"ok": true}
  2026-08-19  app_error   門市=null 會員=null  "Script error."
  ```
  ⚠ **兩筆都沒有門市也沒有會員 —— 任何關聯都認不出它們是測試。**
  那正是第三層（時間下限）唯一擋得住、而前兩層永遠擋不住的那一類。

  🎯 **這個數字是靠「正對照」抓出來的**：把時間下限換成一個很早的日期跑一次，
    看 view 會不會冒出資料。
    🔴 **因為「全部 0 列」同時是「正確阻擋」與「view 寫壞了」的症狀 ——
      兩者長得一模一樣。** 只驗「應該是 0」的那一半，等於沒驗。

  🎯 **正解不是去補那個檢視表，是承認一件事：**
  **今天資料庫裡沒有任何一筆營運資料。**
  `orders` 150 筆、`table_sessions` 99 場、`app_events` 3331 筆 ——
  **全部都是測試**，因為真實客人到現在都還沒出現。
  `is_test` 這個旗標的工作**從真實客人出現那天才開始**。

  → **上線時要定一個「營運起始時間」，所有報表以它為下限。**
  ⚠ 不要在檢視表裡寫死 `2026-08-26` —— 那只是修 bug 的日期，不是營運起點。
  ⚠ 這條對 `orders` / `table_sessions` / `wallet_txns` 同樣成立：
    **任何跨越上線日的全期統計都是無意義的。**
- **`order_payments` 的三條 CHECK**（2026-08-27 撈出來留檔，寫付款測試前先看）：
  ```
  method ∈ ('cash','credit_card','line_pay')
  amount > 0
  cash_fields_only_for_cash：
     method <> 'cash' → cash_received 與 change_given 都必須是 NULL
     method  = 'cash' → cash_received NOT NULL 且 >= amount
                        且 change_given = cash_received - amount
  ```
  ⚠ 我因為只送 `method` + `amount` 而讓一次驗證整個失敗（同踩坑 3.8：
    **錯誤訊息只給約束名字不給定義**，看到名字就推論它在管什麼是猜的）。
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

- **快速結帳的後端完成**（2026-08-25，兩支 SQL 均已驗證）。
  起點是「會員儲值跟快速結帳要不要合併」，結論是**版型沿用桌況結帳，只換左欄**
  （四格座位 → 搜尋選客人），底部不要帶桌列，而「沒有 session 就沒有檯費」是
  **自己消失的**，不用特別拿掉。
  - 🔴 **我從 `api.js` 看到「每支結帳都送 `p_session_id`」就推論「後端非有桌不可」——
    結論反了。** `checkout_tx` 的簽名根本沒有 session 參數、INSERT orders 也沒寫
    `session_id`（桌邊訂單是外層包裝事後回填的）。綁桌次的是外面那三支包裝。
    → **看前端推後端不算數**，只有 `pg_proc` 算數（硬規則 3）。
  - 所以 `pos_quick_checkout_tx` 只是**一層 DEFINER 外殼**，不是新的結帳邏輯。
    🔴 為什麼非要外殼：**`checkout_tx` 是 SECURITY INVOKER**，POS 用 anon
    直接叫它 RLS 會濾成「什麼都沒發生而且不報錯」（同 `settle_session_tx` 那個洞）。
    **前端永遠不可以直接呼叫 `checkout_tx`。**
  - 三種模式：`topup_only` / `items_only` / `topup_and_items`。
    純儲值不能走 `checkout_tx`（它開頭就擋「沒有品項」）。
    ✅ 不需要 `EXCEPTION` 回滾 —— `topup_tx` 與 `checkout_tx` 失敗都是 `raise`，
    例外自然往上拋。`pos_checkout_with_topup_tx` 當初要自己接住是因為
    `join_session_tx` 回 `{ok:false}` 不拋。
  - 🔴 **匿名結帳做不到，而且欄位可空性騙了我一次**：`orders.member_id` 可為 null，
    但 `checkout_tx` 有一段 `select balance into v_bal from wallets ...; if v_bal is null then raise`
    ——**即使 `points_used = 0` 也會查錢包**。
    **欄位可為 null ≠ 函式接受 null。** 要做外帶一杯奶茶得改 `checkout_tx` 本身。
  - ⚠ **第二支 SQL 是補我漏的**：建立時少了 `p_topup_cash_received` /
    `p_topup_change_given`。理由是「`topup_tx` 沒有這兩個」—— **又漏了一層**，
    `pos_checkout_with_topup_tx` 是自己 `update topup_orders`（用 `topup_id` 認回）。
    🔴 在快速結帳更嚴重：**純儲值時 `orderCash = 0` → `payments` 是 null，
    沒有任何 `order_payments` 能承接實收找零**，「收 2000 找 500」完全不落地。
    → 趁「還沒有東西呼叫它」時改簽名是免費的，上線後就要走部署順序。
  - 📌 查證順帶得到：**`orders.channel` 是 NOT NULL DEFAULT `'counter'`，150 筆全是
    `counter`**（含桌邊）。也就是這欄目前**沒有分辨力**，櫃檯與桌邊只能靠
    `session_id` 是不是 null 分。所以快速結帳刻意不寫 channel ——
    只補一邊會讓兩條路的資料長得不一樣。
  - ⏳ **前端還沒做**：見待辦 22。

### 待辦

0. ~~分類主檔只有一端在讀~~ → ✅ **POS 已接上兩張主檔**（2026-08-26，`migi-pos` f246b58）。
   - `shared.jsx` 的 `TIER_LABEL` → `list_member_tiers_tx`
   - `OpenCheckoutPage.jsx:769,808` 的 `'fnb' ? '餐飲' : …` → `list_product_taxonomy_tx`

   🔴 **接之前就在錯**：寫死那份 `TIER_LABEL` **少了 `chef_special`**，
   所以主廚特調的會員在 POS 上顯示「chef_special」四個字 ——
   而 2026-08-26 才剛把主廚特調改成 8 折。**那就是「建了主檔沒人讀」的代價。**

   ⚠ **一定要走 RPC 不能直接查表**：兩張主檔表**都有 RLS**（各 1 條 policy），
   POS 用 anon 沒有 auth session，`from('member_tiers')` 會回空陣列
   **而且不報錯**（硬規則 4）。兩支 RPC 都是 DEFINER + anon ✅。

   **設計：寫死的不刪，降級成 fallback。**
   | 情況 | 顯示 |
   |---|---|
   | 主檔還沒載回來／載入失敗 | fallback → **不會閃英文代碼、不會整頁中文名消失** |
   | 主檔載回來了 | 主檔覆蓋 → 總部改名 POS 跟著變 |

   🔴 POS 是收銀機，**中文名突然變成英文代碼比顯示舊名字更糟**。
   ⚠ 但 fallback **必須完整**（補上 `chef_special`）—— 少一個等於什麼都沒防到。
   ⚠ 載入在 `App.jsx` 開機一次，**載完要 bump 一個 state 觸發重繪**
     （`shared.jsx` 讀的是模組層快取，單純寫進去的話已畫好的畫面不會更新）。
     不 await、不擋畫面 —— POS 不能因為讀不到主檔就開不起來。

   📌 順帶：`member_tiers` **早就有 `sort` 欄位**，所以等級高低可以由主檔決定。
   2026-08-26 早上我還在 `MemberPage.jsx` 寫死一份 `TIER_ORDER`，
   註解寫「等等級編輯頁做出來，順序應該由主檔給」—— **查了才知道主檔早就有**。
   已改用 `shared.jsx` 的 `tierRank()`。

   ⏳ **還沒接的：migi-web `wallet.jsx` 的 `tile()`**
   （把 `wallet_txns.type` 與商品分類混在一張對照表，六種值混用）。
   ⚠ 它會跟「會員 App 最近消費」一起重寫（見待辦 1），先不要單獨改。

0.6 **總部要能調會員等級的折數與門檻**（2026-08-25 使用者指定）。
   `member_tiers` 是主檔、`checkout_tx` 與 `pos_member_detail_tx` 都即時查它，
   所以改一個數字**立刻生效不用部署** —— 但 migi-admin **沒有編輯畫面**，
   目前只能跑 SQL（範本：`sql/applied/2026-08-25_主廚特調改20趴.sql`）。
   要做的是 migi-admin 的一頁：四級的 `label` / `discount_pct` / `threshold_amount` /
   `is_active` 可編輯。
   ⚠ **`code` 不可編輯**：`chef_special` 這類代碼被寫進判斷邏輯與歷史訂單快照，
     改了會讓舊資料對不上。中文名（`label`）才是可以改的那一層。
   ⚠ 存的是**折抵幅度**（20 = 8 折），畫面要顯示折數 —— 兩層刻意分開，
     遷就顯示去存 80 就會長出 `coupons.discount_value` 那種矛盾。
   ⚠ 這一頁做出來之前，**`label` 仍然沒人讀**（待辦 0 那個「建了主檔沒人讀」）。

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
   ✅ **更正（2026-08-25）：`get_my_orders_tx` 早就存在而且早就接好了。**
   這條原本寫「只差一支 `get_my_orders_tx`」—— 錯的。
   `migi-web/src/pages/wallet.jsx:125` 一直在呼叫它，首頁與明細頁都是。
   2026-08-25 盤點三個前端呼叫的 70 支 RPC 時證實它在線上（0 支不存在）。
   簽名：`get_my_orders_tx(p_member_id, p_limit, p_before)` →
   `{ orders: [...], has_more }`，每列有 `paid_at` / `payable` / `collected` /
   `points_used` / `payments[]` / `items[]` / `topup`。
   → 又一個「文件說沒有、實際上有」（同踩坑第 29 條）。**先查再說沒有。**
   → POS 的會員查詢已於 2026-08-25 接上（最近消費 5 筆 + 上次來訪）。

   🔴 **真正還缺的是「累積消費」**：`get_my_orders_tx` 是分頁的，
   前 N 筆加總不是總額。B 案（從 `orders` 即時算）需要自己的 RPC 或
   在既有回傳裡多一個欄位 —— 這也是會員分級門檻要用的數字。
   連帶要確認：會員分級的「消費累積」是用什麼算的 —— 若讀 `wallet_txns` 會漏掉所有現金消費。

   **UI 端已指定**（2026-08-16）：首頁「最近消費」只顯示**前 10 筆**；
   切頁標題從「點數明細」改成「**最近消費**」；內容要含**現金消費 + 點數消費 + 儲值**。
   前兩項是純前端，第三項要等 `get_my_orders_tx`（現在 `get_wallet_tx` 只回 `wallet_txns`）。

   **消費累積採 B 案：從 `orders` 即時算，不存計數欄位**（2026-08-16 決定）。
   存欄位會出現「欄位與訂單對不上」而且無從得知哪邊才對；退款、作廢、補開都要記得回沖，
   漏一次就永久偏差。從事實表算則永遠一致，慢了再加物化檢視表。
2. ~~`checkout_tx` 的價格完全來自前端傳入的 JSON~~ → ✅ **已完成**（2026-08-27）。
   兩支 SQL 都已驗證：`2026-08-27_價格一律查主檔.sql` ＋ `2026-08-27_擋牆改讀商品主檔.sql`。

   **原則：前端只送「意圖」（`product_id` + `qty`），不送「事實」。**
   `checkout_tx` 的 `unit_price` / `name` / `revenue_type` 一律回查 `products`
   （`discountable` 從 2026-08-20 起就已經是這樣做的 —— 這次是把它補完）。
   `order_items` 的快照也改成 join 主檔，**與金額計算同一個來源，不可能不一致**。

   ✅ **兩支簽名都沒變** → `CREATE OR REPLACE`、不用 DROP、不丟 GRANT、**前端不用改**
     （它照樣送 `unit_price`，後端忽略。要清掉那幾個欄位是另一批，隨時可做）。

   🔴 **順帶堵掉一個真的漏洞**：`join_session_tx` 的三道擋牆讀的是**前端送的
     `revenue_type`**，所以前端只要把它寫成 `'fnb'`，檯費商品就能穿過去
     → 檯費被收兩次。已改成讀主檔。
   🔴 **也補上 org 比對**：原本完全沒驗商品屬不屬於這張單的機構。
     目前只有一個 org 所以踩不到，**那是運氣不是設計**。
   🔴 免費券的折抵基數原本讀前端的 `unit_price`，等於讓前端決定免費券折多少。已改主檔價。

   ⚠ **刻意不過濾 `is_active`**：結帳是「已經發生的交易」，不是「決定要不要賣」。
     東西客人都吃了才在收錢那一刻擋，比讓它成立更糟。要擋銷售應該在 `list_products_tx`。

   📌 **查證的關鍵事實**（動手前確認，不是推測）：
   · 現有 **202 筆品項，0 筆單價與主檔不符** → 覆寫是 no-op
   · 檯費不是例外：**暢打是靠 `qty` 表達的**（`v_qty` 從 0 起算），
     不是把 `unit_price` 改成 0 → 查主檔不會把暢打的客人收全額
   · 萬一有落差，既有的 `if v_pay_sum <> v_cash_due then raise` 會**大聲失敗**

   🎯 **驗證用既有的機制當驗證器**：品項送 `unit_price = 1`、付款送主檔價。
     舊版在收款驗證那一步就拋錯，新版通過 —— 不用另造驗證邏輯，而且假不了。
     擋牆那支更省：品項驗證排在查場次之前，所以用**不存在的 session_id**
     就能單獨測擋牆，全程零寫入。
     ⚠ 三個子測試缺一不可（偽裝要擋／正常餐飲不可誤擋／暢打要放行）——
       **過度阻擋跟沒擋一樣糟，而且更難發現。**
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

   🎯 **自動配桌的後端已經全部做完了**（2026-08-28 用 MCP 查證，先前這條寫「還不存在」是錯的）：

   | | 現況 |
   |---|---|
   | `tables.auto_assign` | ✅ boolean NOT NULL default true，**18 張桌全開** |
   | 讀它的函式 | ✅ `_try_auto_seat_tx`／`list_tables_tx`／`pos_table_forecast_tx`／`set_table_auto_assign_tx`／`settle_session_tx` —— **不是「建了沒人讀」** |
   | 收桌保留給現場 | ✅ `settle_session_tx(p_session_id, p_staff_id, **p_keep_for_walkin**)` |
   | 自動入座 | ✅ `_try_auto_seat_tx`（由 `_finalize_queue_full_tx` 呼叫）＋ `sweep_auto_seat_tx` |
   | 排程 | ✅ **pg_cron `auto-seat-matched` 每 5 分鐘在跑** |

   **完整的 pg_cron 排程**（2026-08-28 查證）：
   ```
   auto-seat-matched        */5 * * * *    sweep_auto_seat_tx
   migi_sweep_expired       */5 * * * *    sweep_expired_queues_tx
   cleanup-empty-sessions   */10 * * * *   cleanup_empty_sessions_tx(30)
   gen-recurring-instances  0 */6 * * *    generate_recurring_instances_tx
   daily-wallet-audit       0 21 * * *     daily_wallet_audit_tx
   ```

   ⚠ **但它從來沒成功配過一次**：`match_queues` 目前 expired 47／cancelled 7／waiting 5，
     **`matched` 與 `seated` 都是 0**。機制在跑但沒有成果 ——
     可能只是「同一個 queue 湊不到四人」（正常），也可能有 bug。
     🔴 **做配桌前要先驗這件事**，不要假設它是好的。

   ⏳ **所以真正還沒做的只有前端**：
   - **桌況卡片要顯示「現場」標記**（`auto_assign = false` 的桌）—— 否則週六關掉的桌
     週一沒人記得，那幾桌從此永遠不會被自動配而且畫面上看不出來。
     不加到期時間（那會變成「為什麼我設的又跑掉了」），用看得見來防忘記。
   - **收桌彈窗的「收完保留給現場」勾選** —— 後端參數已經在了，只差 UI。
     情境是「現場有四人在等」，店員必須**先關掉那桌再按收桌**，
     順序反了就被 App 搶走。一個勾選同時做兩件事，就沒有順序可以搞錯。

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

    ### ✅ 2026-08-26 盤點結果：結構上沒有地雷，可以安心延後
    - **23 個指向 `members` 的外鍵，沒有一個是 `CASCADE`**（21 RESTRICT / 2 NO ACTION）。
      🔴 CASCADE 才是最怕的（刪舊帳號時資料靜默消失）。
      **RESTRICT 反而是保護：搬不完就刪不掉，它會逼你做完。**
    - **有三支餘額工具**：`fix_wallet_balance_tx(org, member)` /
      `reconcile_wallets_tx(org)` / `audit_wallet_balance()`
      → 合併後可以**重算驗證**，不必只靠相加。
      ⚠ 相加是「假設兩邊 balance 都對」，而 `wallet_txns` 沒有觸發器同步餘額
        —— **能重算就不要相加**。
    - `invoices` **0 筆** → 發票那條法律硬條件今天不咬。

    ### 🔴 真正的工作量在 8 個含 member_id 的唯一約束（不在外鍵清單裡）
    只改 `member_id` 會撞鍵，每一個都要決定「兩邊都有時怎麼併」：
    `wallets_pkey` / `member_app_state_pkey` / `uq_buddies` /
    `uq_session_player` / `uq_queue_member` / `uq_availability` /
    `uq_staff_member_store`。
    ⚠ 其中 **`uq_session_player (session_id, member_id)` 最刺**：
      兩個帳號在同一桌打過 = 同一個人分飾兩角，**檯費收了兩次**。
      那不只是資料問題，是要不要退款的問題。

    ### 合併規則（2026-08-26 拍板的部分）
    - **存活者 = 歷史比較貴的那個**，判準依序：
      ① **有已開立發票的**（硬條件，法律文件不能改開給別人）
      ② 訂單數多的　③ 建立時間早的
      ⚠ **不要用「有沒有綁 LINE」當判準** —— 那正是要被搬的東西，
        拿它決定誰活下來是循環論證。
    - **搬 `line_user_id`，不搬歷史**：前者一個欄位，後者上千列且有些不能改。
    - **順序**：搬 rows → 軟刪 loser → 才把 `line_user_id` 寫到存活者。
      ✅ `uq_members_line_user` 的 `WHERE deleted_at IS NULL` 讓順序做錯會被擋下來，
        不會靜默出錯 —— **索引本身就是順序的守衛**。
    - **硬搬，不做別名**（`merged_into` 指標）。別名會讓**每一支查詢都必須記得跟指標**，
      漏一支就查到空的而且不報錯 —— 那比「建了沒人讀」更糟。
    - 留一份合併紀錄（誰併誰、何時、誰按的、搬了幾列）。**不可逆，要有確認步驟。**

    ### ⏳ 為什麼工具現在不做
    ① **現在不可能發生**：0 個會員綁 LINE、4 個測試帳號、LINE 還沒接。
    ② `register_member_tx` 的 find-or-bind 已經是預防（手機對得上就綁不新建），
       2026-08-26 又修掉它會謊報成功的洞 —— **那才是重複帳號最可能的入口**。
       ⚠ 但**前端要真的送手機**，不然那條路永遠走不到。接 LINE 時必做。
    ③ 🔴 **做出來也沒人能按**：合併是稽核級操作，必須記錄 `p_staff_id`，
       而店員登入卡在 LINE Developers 帳號 —— 會是第 10 個「建了沒人讀」。

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
    🚧 **開工前先看待辦 21 的「阻擋條件」五項** ——
    那不是建議，是「沒做完就不能開 JWT」。開了之後洞是敞開的。
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

    ### 🔴 localStorage 裡的舊身分會讓整個註冊流程被跳過（2026-08-29 踩到）
    ```js
    App.jsx:95   if (!member) return <Register …/>      // member 來自 localStorage
    ```
    創辦人在 LIFF 走註冊，結果**進去變成測試01** —— 而資料庫可以證明
    `register_member_tx` 一次都沒被呼叫到（四個會員 `line_user_id` 全是 null、
    沒有第五個會員、測試01 的手機也確實已經是 `0910000001`）。
    → 不是「繼承」，是**根本沒註冊** —— 那台裝置的 localStorage 裡存著測試01，
      所以連 LINE 授權那一步都不會出現。

    ⚠ 當下的解法是「個人設定 → 登出」（`profile.jsx:207`），但那只是繞過。
    🔴 **真正的問題是：這個 App 的身分是 localStorage 說了算，不是 LINE 說了算。**
      在 LIFF 裡進來就一定拿得到驗過簽的 `line_user_id`，
      **應該拿它去問後端「我是誰」**，而不是相信瀏覽器裡存的那個。
    → 需要一支 `get_member_by_line_tx`（或讓 `line-login` 也能純查詢），
      本來就屬於這一項的範圍。
    📌 這也是待辦 15（帳號合併）非得跟這一項一起做的原因：
      **只要身分是前端宣告的，「我是誰」就永遠有第二個答案。**

    解法：LIFF 的 `id_token` 換 Supabase JWT（Edge Function 或自建端點驗簽），
    RPC 改從 `auth.uid()` 取會員、拿掉 `p_member_id` 參數、
    `SECURITY DEFINER` 大多可以改回 `INVOKER` 讓 RLS 自己擋。

    🎯 **做的時候把身分解析包成一支函式**（2026-08-27 建議，08-28 補記）：
    ```sql
    resolve_member_from_jwt()   -- 今天裡面就一行：查 line_user_id
    ```
    三支身分函式（`current_org_id` / `current_member_id` / `current_staff`）
    都呼叫它。**代價幾乎為零（多包一層），收益是日後只改一個地方。**

    🔴 為什麼要這一層：現在 `current_member_id()` 直接查 `line_user_id`，
      等於**把「LINE」寫進了身分解析本身**。日後要加 Apple 登入、手機驗證碼、
      或跨 org 加盟，就要改那三支函式 —— 而它們是 RLS 的地基。
    📌 世界級做法是把**認證**（你怎麼證明你是誰，會換會多）與
      **身分**（你是誰，永遠不變）分開：Stripe 的 customer 底下掛多個登入方式、
      Shopify 的 customer 可以 Email 也可以 Shop Pay。
    ⚠ **但現在不要建 `member_identities` 表** —— 七間店、一種登入方式，
      建了就是第 N 個「建了沒人讀」。**先做函式包裝，表等真的有第二種登入方式再說。**
      （同待辦 29 的 `can()`：先把「怎麼決定」與「誰有權限」分家。）
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

17. ~~贈點級距沒有主檔，規則只活在前端~~ → ✅ **前後端都完成了**（2026-08-28 用 MCP 查證）。
    | | 現況 |
    |---|---|
    | `topup_plans` 主檔 | ✅ 存在，**5 筆**：150→0、500→0、1000→50、2000→150、3000→300 |
    | `calc_topup_bonus_tx` | ✅ 存在 |
    | `topup_tx` | ✅ **已呼叫 `calc_topup_bonus_tx`** —— 贈點由後端查主檔算，不採信前端 |
    | `list_topup_plans_tx` | ✅ DEFINER + anon，POS 與會員 App 都能讀 |
    | POS 前端 | ✅ `bonusOf()` 已移除、`p_topup_bonus` 2026-08-25 就不送了、已接 `listTopupPlans()` |

    ⚠ **這條在文件裡過期了五天，而我 2026-08-28 差點根據它回報一個不存在的 bug**
      （以為主檔 500→0 與前端寫死 500→20 不一致）。
      🔴 **先查再說沒有** —— 同踩坑第 29 條，也正是硬規則 1.6／1.7 要防的。

    📌 連帶解除：會員頁當初「只做查詢不做儲值」的理由（怕長出第二份 `bonusOf`）
      已經不成立 —— 贈點現在只有主檔一個來源。要做會員端儲值只剩金流串接。

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

19. ⚠ **`next_doc_no` 已經存在，不要再建第二套流水編號**（2026-08-23 查證完畢）。
    機制是 **`doc_counters` 計數表 + `next_doc_no(p_org_id, p_store_id, p_doc_type)`**，
    由觸發器 `trg_orders_set_no` / `trg_topup_set_no` / `trg_coupon_set_code` 自動帶入。
    **而且它本來就是分店編號**（`p_store_id` 在簽名裡）—— 目前有 **7 間門市**，這點重要。

    | 表 | 單號 |
    |---|---|
    | `orders` | `order_no`、`txn_no` |
    | `topup_orders` | `topup_no`、`txn_no`、`invoice_no` |
    | `invoices` | `invoice_no`（法規那一套，不可混用） |
    | **`table_sessions`** | ❌ 沒有 |
    | **`match_queues`** | ❌ 沒有 |

    → 牌局／配桌要編號的話是 **`next_doc_no(org, store, 'session')` 加一個觸發器**，
    不是建新機制。
    ⚠ 我 2026-08-23 差點自己成為「加第二套編號」那個反例 ——
    當天才剛寫下「加第二套是這題最糟的結果」。**先查再提議。**

20. 🔴 **店員登入：身分是「有 LINE 的會員 + staff 表一列」**（2026-08-23 查證定案）。
    🚧 **開工前先看待辦 21 的「阻擋條件」五項** —— 店員登入也是一種 JWT。
    ⚠ 它比會員 JWT 稍微不那麼急（店員人少、可控），但**同一個洞**：
      `current_org_id()` 一旦回傳 org，那 24 條 policy 就全部通過。
    `current_staff()` 的判準是
    `members.line_user_id = (auth.jwt() ->> 'sub')`，經由 `staff.member_id` join。
    - ⚠ **文件是錯的**：`docs/01-資料庫/資料架構基石規範.md:114` 與
      `docs/02-POS與開桌/M2技術設計_桌台與配桌.md:404、468` 都還在寫
      「Supabase Auth email/password 店員登入」，那是舊設計。
      `staff.auth_uid` 這個欄位還在，但 **`current_staff()` 完全沒用到它**。
    - ✅ `grant_staff_tx` 的角色值已修（2026-08-23）：
      `floor`（一般店員，預設）/ `manager`（店長）/ `hq`（總部）/ `owner`（老闆）。
      修之前守衛寫 `clerk/manager/hq` 而 CHECK 是 `floor/manager/hq/owner`，
      **預設用法必定拋 23514** —— 那支「把會員升級成店員」的函式從來沒成功過。
    - ✅ ~~現有唯一那筆 staff 的 `member_id` 是 null，INNER JOIN 永遠 join 不到~~
      → **這句話從 2026-08-23 起就過期了**（`current_staff()` 那天改成
      LEFT JOIN ＋ 兩條 OR），2026-08-29 查證後更正。

      **總部那條 Email 路徑本來就是通的**：
      ```
      staff  role=hq  auth_uid=2485579b-…  member_id=null
      auth.users 只有 1 個帳號：admin@migi.tw（2026-07-12 建立並登入過）
      ```
      🔴 **`member_id = null` 不是 bug** —— 那是 Email 路徑的 staff 列
        **應該有的狀態**（決策紀錄第八節：總部員工不是會員）。
      ⚠ **不要把它綁到創辦人的會員身上。** 2026-08-29 我一度這樣建議並寫了 SQL，
        理由就是引用上面那句過期的敘述 —— 而我**當天才剛撈出 `current_staff()`
        看到它是 LEFT JOIN**。讀到了正確的線上版本卻照著過期文件下結論，
        正是硬規則 3 要防的形狀。SQL 已撤回。

      🎯 **日後若要讓創辦人用 LINE 登入 POS 並具有權限，正解是「另開一列 staff」**，
        不是改總部那一列：
        ```
        新列  member_id = <他的會員>  auth_uid = null  role = 'owner'
        ```
        · `uq_staff_member_store (member_id, store_id)` 不衝突（現有那列 member_id 是 null）
        · `staff_auth_uid_key UNIQUE (auth_uid)` 也不衝突（Postgres 的唯一索引視多個 NULL 為相異）
        · 同待辦 29 ②「staff 要能一人多列」
      ⚠ 那是**授予最高權限**的動作：綁下去之後，拿到那個 LINE 帳號的人就是 hq／owner。
        等真的要用 POS 時再做，不要現在先建。
    - 🔴 **整條路卡在 LINE Developers 帳號還沒申請**（見 PENDING）。
      **三端都是 LINE Login** —— LIFF 不是另一種登入方式，
      它是掛在 LINE Login channel 底下的一種**執行環境**：

      ```
      Provider（MIGI）
      └── LINE Login channel
          ├── LIFF app       → 會員 App（在 LINE App 內，liff.getIDToken()）
          └── 一般 OAuth web → POS（平板瀏覽器，redirect → callback → 換 id_token）
      ```

      **兩條路徑的使用者體驗完全不同**（2026-08-28 查官方文件確認）：

      | | 客人／店員看到什麼 |
      |---|---|
      | **LIFF（會員 App，在 LINE 內）** | 🔴 **什麼都看不到** —— 自動登入。<br>`the LIFF app can access user data without having to prompt users to log in`<br>→ **不需要登入按鈕，也畫不到同意畫面**（那是 LINE 自己算繪的） |
      | **一般 OAuth（POS，平板瀏覽器）** | ✅ 需要真的「使用 LINE 登入」按鈕 → LINE 的同意畫面 → callback |

      🔴 **所以 `migi-web` 現在那個 step 0「LINE 授權」畫面是開發期的替身，
        接上之後會整個消失** —— 客人點連結進來會直接看到暱稱那一步。
        不要再花時間打磨它的外觀。

      🔴 **POS 那顆登入按鈕必須用 LINE 提供的官方素材，不可以自己畫**：
      - 顏色：base `#06C755`／hover +10% 黑／pressed +30% 黑／disabled 白底
      - **不可改形狀** ——「使用不同或修改過的 icon」是官方明列的常見錯誤
      - 文字可改，但不可換行、必須清楚表達是用 LINE 登入
      - 素材與規範：https://developers.line.biz/en/docs/line-login/login-button/

      ### 命名（2026-08-28 查官方文件）
      | | 客人看得到嗎 | 限制 |
      |---|---|---|
      | **Business ID 的「姓名」** | ❌ | 那是**登入後台的人**的名字，不是品牌名。之後可改 |
      | **Provider 名稱** | 🔴 **會，顯示在授權畫面上** | 官方要求「反映真實的商業主體」；**認證 provider 改名要送審** |
      | **Channel 名稱** | 依官方文件**不顯示**給客人 | 🔴 **不可含「LINE」或近似字串** |

      🔴 **客人在授權畫面看到的是 Provider 名稱，不是 channel 名稱**
        （我一度寫反過，已更正）。
      ✅ **保險做法：Provider 與 channel 取同一個名字**（`MIGI 咪吉麻將`），
        這樣不管實際顯示哪一個都一致。
      ⚠ 若日後要申請**認證 provider**，名稱可能要對得上**公司登記名稱** ——
        那時「品牌名 vs 法人名」會變成一個取捨：
        用法人名客人會看到一個沒聽過的公司名而卻步，用品牌名則改名要送審。

      🔴 **硬條件：兩者必須在同一個 Provider 底下。**
      LINE 的 `userId` 是 **per-Provider 不是 per-channel** ——
      同 Provider 的所有 channel，同一個人拿到同一個 `userId`；
      **不同 Provider 會是兩個不同的值**。
      而 `members.line_user_id` 只有一欄 → 分成兩個 Provider 的話，
      同一個人在會員 App 與 POS 會變成兩個 id，`current_staff()` 的 join
      永遠接不起來，**而且不報錯，只是登不進去**。
      ⚠ 要不要分兩個 channel 是選擇（看要不要分開的同意畫面與 callback）；
      **同一個 Provider 是硬條件。**
    - ⚠ **權限差異尚未定義**（誰能收桌／作廢訂單／看報表）。
      現在定會是憑空想像，等有實際場景再拍板。
    - 相依：待辦 14（會員端 JWT）是同一套換發機制；
      待辦 15（帳號合併）必須在 JWT 之前或同時做。
    - ✅ **兩條身分路徑已查證（2026-08-23）**，設計本來就對：
      ```sql
      current_org_id()  -- 兩條都認，順序也對
        coalesce(
          (select org_id from staff   where auth_uid = auth.uid() …),            -- 總部 Email
          (select org_id from members where line_user_id = auth.jwt()->>'sub' …) -- LINE
        )
      ```
      總部走 Email 是有理由的（`總部後台架構藍圖.md:33`、`決策紀錄.md` 第八節）：
      ① 總部員工不是會員 ② **開機問題** —— 第一個管理員沒有人能升級他，
      必須有一條不依賴既有 staff 的路 ③ 職能不同。
      `staff.auth_uid` **正是為那條路存在的**，不是殘留。
      🔴 錯的是後來的漂移：店員登入改用 LINE 時 `current_staff()` 被寫成只認 LINE，
      而且用 `INNER JOIN members` —— `member_id` 是 null 的總部那列永遠 join 不到。
      → `sql/applied/2026-08-23_current_staff補回總部路徑.sql` 已修（LEFT JOIN + 兩條 OR）。

21. 🔴 **門市隔離「有機制但沒插電」，而且它對會員的影響比對店員更嚴重**（2026-08-23）。
    - 用到 `current_staff()` / `has_store_access()` 的 RLS policy：**0 條**
    - 整套 RLS 只靠 `current_org_id()`：**24 條**
    - 唯一呼叫 `current_staff()` 的是 `has_store_access()`，而它也沒人用
    → 也就是 RLS 目前只做到「同一個 org」，**沒有做到「店員只看自己店」**。
    店員登入之後，店員會看得到全集團 7 間門市的資料。
    🔴 **對會員更嚴重，這改變了待辦 14 的內容**：
    給會員發 JWT 之後，`current_org_id()` 會走 `members` 那條路回傳 org，
    那位會員就**通過全部 24 條 org 級 policy**。
    也就是從「知道 uuid 才查得到」變成「**登入就能查全部**」—— 可能比現在更糟。
    → **待辦 14 不是「換發 JWT」而已，是「換發 JWT ＋ 同時收緊 policy」，
    兩件事必須同一批做。** 分開做的中間那段時間，洞是敞開的。

    ### 🚧 阻擋條件：以下五項未完成前，**不得**開啟任何 JWT 換發
    （2026-08-26 從「順便做」升級為阻擋條件。
      🔴 危險不是「現在沒收緊」—— 現在沒人讀得到，是安全的。
        危險是**開 JWT 那天有人加了一條寬鬆的 policy**，
        而那一刻沒有任何東西會提醒他。）

    1. **逐條檢視那 24 條 org 級 policy**，決定每一條要不要再加
       門市限制（`has_store_access()`）或角色限制。
       ⚠ 不是全部都要收緊 —— `list_stores_tx` 那類本來就該全 org 可讀。
         **要的是「每一條都被看過並做了決定」**，不是「一律加嚴」。
    2. **敏感表清單至少涵蓋**：`app_events`、`orders`、`topup_orders`、
       `wallet_txns`、`members`、`member_interactions`、`member_blocks`。
       🔴 `app_events` 特別要收 —— 使用者拍板「只有總部分析數據的人看得到」
         （待辦 23），而那個保證**目前是靠「所有人都讀不到」達成的**。
    3. **`app_events` 的 policy 只開給 `staff.role in ('hq','owner')`。**
       這需要待辦 29 的 `can()` 或至少 `current_staff()` 能用 ——
       也就是待辦 20（店員登入）要先到位。
    4. **帳號合併機制先做好**（待辦 15）。
       JWT 上線那一刻就是「LINE 帳號 ↔ member」正式綁定的時候，
       那時若已有重複的 member，綁定會固定下來、之後更難拆。
    5. **驗證方式：拿一個真的測試 JWT 實際查一次**，確認查不到不該看的。
       🔴 **不可以只讀 policy 定義就宣告安全** —— RLS 的實際效果取決於
         policy 組合、`current_org_id()` 的回傳、以及 SECURITY DEFINER
         函式繞過的路徑。**只有真的用那個身分查一次算數**（同硬規則 7）。

22. ⏳ **快速結帳與會員查詢的前端**（2026-08-25 決定，後端已就緒）。
    後端 `pos_quick_checkout_tx` 已上線並驗證，`api.js` 的 `quickCheckout()` 也加好了。
    剩下純前端：

    | 檔案 | 要做什麼 |
    |---|---|
    | `App.jsx` NAV | 會員 → **會員查詢**（圖示換**放大鏡**）；新增 **快速結帳**（購物車圖示） |
    | `MemberPage.jsx` | **完全不碰錢**：拿掉右欄與儲值，變成 左 216 ＋ 詳情吃滿；右上加「儲值 →」 |
    | `OpenCheckoutPage.jsx` | 加 quick 模式：左欄換成搜尋選客人；`doPay` 加 `!sessionId` 分支走 `quickCheckout` |
    | `TopupPickModal` | 刪掉（方案改成中欄卡片／或沿用桌況的儲值彈窗） |

    - **版型完全沿用桌況結帳**：`seatCol 216` / `midCol` / `rCol 420`、標題列 72、
      `pbar` / `balBox` / 品項 / 收款全部同一組 `S`。**只有左欄換掉、底部沒有帶桌列。**
    - ✅ 好消息：`OpenCheckoutPage` 裡與 session 有關的 effect **本來就都有
      `if (!sessionId) return`**（還原座位、桌帳、檯費試算），所以傳 `sessionId: null`
      大部分會自己短路。要動的是左欄 UI、`cat` 預設值（現在寫死 `"檯費"`）、
      `doPay` 的分支、標題列與底部。
    - 🔴 **「儲值 →」必須有**：不然店員在會員查詢看完發現要儲值，得切頁**再搜同一個人一次**。
      按下去＝切到快速結帳**並把人帶過去**。
      按鈕寫「儲值」而頁面叫「快速結帳」是刻意的 —— **按鈕說你要做什麼，導覽說你去哪裡**。
    - ✅ **商品分類是開的**（餐飲／周邊）。原本寫「今天不顯示，實測過再打開」，
      實作時推翻：後端已支援 `items_only` 與 `topup_and_items`，
      而「因為沒實測過所以藏起來」會讓它**永遠測不到**。
    - 🔴 **但當日暢打刻意不放進快速結帳**，理由是新查到的：
      暢打的「不可重複購買」擋牆（`daypass_already_held`）在 **`join_session_tx` 裡，
      不在 `checkout_tx` 裡**。從櫃檯賣會繞過那道牆 ——
      第二張完全沒作用（`has_daypass_tx` 只問「今天有沒有」）而錢照收 300。
      要在快速結帳賣暢打，得先把擋牆搬進 `checkout_tx` 或包裝層。
    - ⚠ **沒有「不指定客人」那張卡** —— 匿名結帳做不到（見已完成區）。
      商品打開之後也不會有，那要等改 `checkout_tx` 的另一批。
    - 📌 **會員查詢的三格今天做不出來**（最近消費／累積消費／上次來訪），
      要 `get_my_orders_tx`（待辦 1）。先做兩格（等級、手機），**空格不畫** ——
      畫了會讓人以為壞掉。

23. ~~POS 完全沒有埋點~~ → ✅ **三層全部完成**（2026-08-26，`migi-pos` 0cd4fac）。
    `lib/analytics.js`（精簡版，不是移植 migi-web 那支）＋
    `main.jsx` 全域監聽 ＋ `ErrorBoundary` ＋ `rpc()` 失敗 ＋ 五個關鍵動作。

    **事件清單**（`event like 'pos_%'` 就能把 POS 與會員端分開）：
    | 事件 | 回答什麼 |
    |---|---|
    | `pos_error` | 錯誤。`kind` 分 render／unhandled／window／rpc／**network** |
    | `pos_version_stuck` / `pos_update_reload` | 這台平板卡在舊版 |
    | `pos_open_session` | 開桌（含牌規／模式 —— 那是**營運資訊**不是店員行為） |
    | `pos_checkout` | 結帳，**成功與失敗都記** |
    | `pos_carry` / `pos_settle` / `pos_void_session` | 帶桌／收桌／取消開桌 |
    | `pos_nav` | 側邊欄 from/to —— 「哪些功能有人用」唯一的入口 |

    ⚠ **`network` 要與 `rpc` 分開**：混在一起看，「店裡 wifi 爛」
      會被誤讀成「系統常出錯」。
    ⚠ **成功與失敗都記**：只記成功的話「哪一步最常中斷」永遠答不出來。

    **兩條資料庫約束（2026-08-26 查證，違反會靜默失敗）**：
    - `event ~ '^[a-z][a-z0-9_]{0,49}$'` —— 🔴 **不是白名單，是格式檢查**
      （我一度誤判成白名單並據此推論了一整段）。小寫字母開頭。
    - `pg_column_size(props) <= 8192` —— 🔴 stack trace 很容易破。
      超過 → 插入失敗 → **而埋點是靜默的，那筆會直接消失**。
      `fit()` 逐層瘦身：先截字串，再由長到短丟非 meta 欄位。

    **隱私**：現在**不帶任何個人身分**。`_did` 是這台平板的隨機 id，
    清 localStorage 就換一個 —— **夠用來除錯，不夠用來監控**。
    `rpc` 失敗只帶函式名與錯誤碼，**不帶 params**（裡面有會員 id、金額、手機）。

    ⏳ **還沒做的**：`app_events` 的 RLS 仍是 org 級 ——
    「只有總部看得到」目前是靠「所有人都讀不到」達成的（見下）。

23.5 🔴 **原始問題與政策紀錄（2026-08-25，保留供日後查）**。
    | | migi-web | migi-pos |
    |---|---|---|
    | `analytics.js`（session/event id、離線佇列、測試閘門） | ✅ | ❌ |
    | 全域 `unhandledrejection` 上報 | ✅ `main.jsx:28` | ❌ |
    | 渲染錯誤上報 | ✅ `track('app_error')` | 🔴 只有 `console.error` |

    🔴 **店員說「剛剛結帳失敗」，你查不到任何東西** —— 而 POS 是收錢的那一端。
    分三層，依急迫排序：
    - **① 錯誤上報**（最急，跟數據分析無關）：`unhandledrejection` + ErrorBoundary
      + `rpc()` 失敗 → 寫 `app_events`。`app_events.is_test` 已有
      `set_is_test_from_store()` 自動帶入，基礎建設是現成的。
    - **② 關鍵流程漏斗**（開桌設定 → 結帳 → 帶桌 → 收桌）：
      ⚠ 要等店員登入，否則只知道「這台平板」不知道「這個人」。
    - **③ 功能使用率**：等功能變多才有意義。

    ✅ **政策已拍板（2026-08-25 使用者決定）：三層全做。**
    > 「資料只有總部分析數據的人看得到。獎金計算日後討論，但數據還是要有。」

    🔴 **但「只有總部看得到」目前是靠「所有人都讀不到」達成的，不是靠設計。**
    `app_events` 的 RLS 是 `org_id = current_org_id()`；POS 用 anon 沒有
    auth session → 回 null → 讀不到。寫入走 `log_app_event_tx`（DEFINER）不受影響。
    ⚠ **待辦 14（會員 JWT）或待辦 20（店員登入）上線那天這個保護就破**：
      那時 `current_org_id()` 會回傳 org，同一條 org 級 policy 會讓店員
      甚至會員讀得到 `app_events`。同待辦 21。
    → **要讓「只有總部」成為設計，需要一條比 org 級更嚴的 policy**
      （例如只開給 `staff.role in ('hq','owner')`）。與待辦 14／21 同一批做。

    ⚠ 獎金計算「日後討論」不等於「不會發生」。埋的時候就要想到：
      事件的 `props` 一旦含了可辨識個人的欄位，事後無法回溯移除
      （歷史資料改不掉）。所以**加 staff_id 那一刻是不可逆的決定**。

24. ~~`members` 有三個欄位建了完全沒人寫~~ → ✅ **兩個已救活**（2026-08-26）。
    | 欄位 | 現況 |
    |---|---|
    | `last_visit_at` | ✅ **活的** —— `trg_orders_touch_visit` 觸發器（已回填） |
    | `visit_count` | ✅ **活的** —— 定義是「**來過幾天**」，同一天多筆算一次 |
    | `primary_staff_id` | ⏳ **刻意不動** —— 沒有店員身分就沒有東西可寫（待辦 20） |
    | `lifecycle` | ⚠ 4/4 有值但凍結（DEFAULT `'new'`，沒人更新） |
    | `last_app_active_at` | ✅ 本來就活的 |

    **做法：觸發器掛在 `orders`，不改 `checkout_tx`。**
    結帳有四條路（join / addon / quick / with_topup），改函式要改四個地方
    而且其中兩支是金流函式；觸發器**一個地方涵蓋所有路徑**，
    且完全不碰既有函式（不 DROP、不丟 GRANT、不用部署順序）。

    ⚠ **`visit_count` 是「來過幾天」不是訂單數** —— 一個客人一天加購三次
      不是來了三次。用訂單數的話**那個欄位名就會說謊**。
      日期用 `Asia/Taipei` 日曆日，與當日暢打同一個判準。
    ⚠ **沒來過的維持 `null` / 0**，不要寫成 `now()` ——
      「從來沒來過」是有意義的值，不是缺資料。
      （回填驗證：測試03/04 顯示「沒來過」，測試02 = 1 天，另一位 = 2 天。）

    ⚠ 這與待辦 1 的 B 案（累積消費從 `orders` 即時算）**不衝突**：
      即時算適合「查一個人」；MA 要掃「全店 7 天沒來的人」是全表聚合，
      而 `last_visit_at` 加索引是一次範圍掃描 —— 差一個數量級。
      ✅ 而且它們**隨時可以從 `orders` 重算驗證**（那支 SQL 的第 ③ 段就是在做），
        不像累積消費那樣一漂就沒人知道哪邊才對。

    ⏳ **`lifecycle` 還沒動**：桶子已定義（`new / growing / regular / at_risk / churned`）
      但沒有任何東西會推進它。要動它得先定義「幾天沒來算 at_risk」——
      那是 MA 的參數（待辦 25），不是這一批的事。

25. **會員再行銷（MA）：策略設計完整，一行都還沒實作**（2026-08-25 盤點）。
    - `06-架構藍圖/整合系統開發藍圖.md:345–385` 有**七個觸發式自動旅程**
      （新會員／7 天未回訪／N 天沒來／生日／點數到期／
      ⭐**牌咖上線開局**／⭐**段位快升級**）。最後兩個是 MIGI 獨有的召回鉤子。
    - **MA × 店員 CRM 是同一份資料的兩個出口**，共用 `member_interactions`
      —— 避免重複打擾、店員看得到系統已發過什麼。
      ✅ 那張表的 schema **已經完全對得上**（`channel`/`kind`/`staff_id`/`note`），
      2026-08-25 的店員備註是它的第一個寫入者。
    - `03-會員App與社交/會員情報體系.md` 的「行銷黃金訊號」：
      **`match_queues.status='expired'` = 某人在某時段想打但沒湊到人**。
      ✅ 已在累積（2026-08-25：expired 42 房 / waiting 4 / cancelled 7）。
      > 「成功的配桌是營收，**失敗的配桌是情報**。」
    - ⚠ 藍圖說「結構（RFM/lifecycle/interactions/availability）Day 1 已在」——
      **半對**：`member_interactions` / `member_availability` / `lifecycle` 在，
      但 **`member_rating` 不存在**，RFM 也沒有任何表或欄位。
    - 📌 落地時機文件已寫：**「會員量起來後做；初期會員少，店員手動就夠。」**
      推斷引擎（行為 → 回填 `member_availability.inferred`）規劃在 **M3**。
    → 現在**不該做 MA**，該做的是**把資料餵進正確的那張表**，讓 MA 上線時有料。

26. **「常來時段」有兩套，而它們回答不同的問題**（2026-08-26 查證定案）。

    ### 兩套的分工（使用者 2026-08-26 拍板的框架）
    | | 誰產生 | 給誰看 | 存哪 |
    |---|---|---|---|
    | **A 行為推斷** | 系統算 | 🔴 **只有系統與總部** | `member_availability` `source='inferred'` |
    | **B 自我宣告** | 客人填 | 其他客人（自我介紹） | 目前在 `members.sched`，M3 搬到 `source='stated'` |

    ✅ **這個分法早就在 schema 裡**：
    `member_availability_source_check CHECK (source in ('stated','inferred'))`。
    其餘允許值：`slot ∈ morning|afternoon|evening|late`、
    `preference ∈ often|sometimes|never`、`weekday 0..6`。
    ⚠ 表目前是**空的** —— 設計做完了沒人實作。

    ### ✅ 2026-09-01：時段的定義落地成 `migi_slot_of(ts)`
    ```
    late 00–06 ／ morning 06–12 ／ afternoon 12–18 ／ evening 18–24（台北時間）
    ```
    🔴 那四個值早就存在，但**沒有人定義過幾點到幾點**。
      現在有了，而且**全系統只有這一份** —— M3 的推斷引擎直接用同一支。
      ⚠ 兩邊各寫一份「晚上是幾點」就是**同一個名字兩種意思**（同待辦 35）。
    ⚠ 驗證段有一格專門驗時區（`UTC 12:00 = 台北 20:00 = 晚上`）——
      忘了 `at time zone 'Asia/Taipei'` 的話，其他八個邊界測試
      **全部照樣會過**（因為它們也都寫 `+08`）。

    ### ✅ 第一個真的在用它的功能：牌咖卡的「常一起打」
    `list_buddies_tx.play_pattern` → `{weekday, slot, n}`（2026-09-01）。
    🔴 **它不是 A 也不是 B** —— 它只統計「**查看者自己也坐過**」的場次，
      所以是**兩個人共同的事實**，不是對別人的側寫。
      ⚠ 界線就在這裡：日後想加「他通常幾點來」就越線了。
    🔴 **門檻是「眾數要過半」不是「≥ 2 次」**（我第一版寫錯）——
      週六 2 次／週日 2 次會讓 `≥2` 宣稱「常在週六」，而一半的場次不是週六。
      **「最多的那一個」不等於「常」。** 都沒過半就回 null，前端顯示 `—`。

    ### 🔴 隱私邊界：A 不對客人顯示，連他本人都不行
    同 `M2技術設計:465`「合拍度只後台用，不在客人前端出現」。
    「他通常等 12 分鐘就走」對他本人都不該顯示 ——
    那會讓人覺得被監視，而且**測量行為本身會改變行為**。

    ⚠ **「遲到」這個維度特別要小心**：它推斷的是「他造成別人等」，
      是**對他的負面評價**。而且**遲到常常不是他的錯**（店員晚開桌、前一桌拖到）。
      → 只能當**統計傾向**用於配桌（把趕時間的人避開），
        **不能當事實**，更不能拿來當客訴依據。這一點要寫進設計。

    ### ✅ 原料的欄位全齊，一個都不用補（2026-08-26 查證）
    ```
    報名      match_queues.created_at
    約定開打  match_queues.play_at        ← 我原本以為沒有，它在
    成桌      match_queues.matched_at
    實際入座  session_players.joined_at   ← 遲到 = joined_at − play_at
    離座      session_players.left_at
    ```

    ### 🔴 但「他能等多久」不能從 expired 房算
    2026-08-26 實測：`expired` 43 房，`updated_at − created_at` 中位數
    **1140 分鐘（19 小時）** —— 那不是「他等了 19 小時」，
    是**房間放到過期**的時間。開房的人可能十分鐘就走了。
    → 真正的訊號是 **`cancelled`（他主動放棄）**，而那只有 7 房、中位數 0 分
      （測試時隨手取消）。**欄位齊了，但耐心這個維度還沒有可信的行為資料。**

    ### ⏳ 現在不要搬 `members.sched`
    搬過去的價值在於**跟 `inferred` 對照**（「他說他打早上，實際都晚上來」——
    **那個落差本身就是情報**），而 `inferred` 要等 M3 的推斷引擎。
    沒有對照對象，搬過去只是換一個地方存同一個字串 → 又一個「建了沒人讀」。
    → **等 M3 一起做**，但對照關係先寫下來免得有人發明第二套：
    ```
    早上為主 → (weekday 0..6, morning,   often, stated)
    下午為主 → (weekday 0..6, afternoon, often, stated)
    晚上為主 → (weekday 0..6, evening,   often, stated)
    深夜為主 → (weekday 0..6, late,      often, stated)
    不一定   → ⚠ 未定案：不寫任何列？還是四個 slot 各寫 'sometimes'？
    ```
    ⚠ **「不一定」是唯一沒有對應的值**，而它的處理方式會影響配桌演算法
      （「沒有偏好」與「沒填」在演算法裡不該是同一件事）。M3 動手前要拍板。

26.5 **（舊）「常來時段」有兩套並存，做之前要先查**（2026-08-25 的原始記錄）。
    `member_availability`（`weekday` / `slot` / `preference` / `source`）表存在，
    `get_my_availability_tx(p_org_id, p_member_id)` 也在 ——
    但會員 App 實際在用的是**另一套**：`profile.jsx:180` 的「作息偏好」
    是一個字串（早上為主／下午為主／晚上為主／深夜為主／不一定），走 `set_my_sched_tx`。
    ⚠ 要先查：`member_availability` 是不是空的、`slot` 的允許值有哪些、
      兩套哪一套才是正本。**猜形狀就是硬規則 3 那個坑**，所以 2026-08-25
      那批刻意沒做這一項。

27. ⏳ **contract 第三步：真的拿掉贈點參數**（2026-08-25 刻意延後，不是取消）。
    `topup_tx.p_bonus_points` 與 `pos_checkout_with_topup_tx.p_topup_bonus`
    仍在簽名裡。**前端已經三個版本沒送了**（7108621 送 0 → a3b5c70 不送），
    所以隨時可以做。
    - ⚠ 延後的理由是**產出與風險不成比例**：產出是「簽名少兩個參數」，
      使用者看不到任何差別；代價是動三支金流函式、DROP 後要補 GRANT、
      **部署順序不能錯**（反了 → 桌邊含儲值的結帳 404）。
    - ✅ 而它原本要防的事（有人送了贈點值卻以為有效）**topup_tx 已經自己處理**：
      回傳 `bonus_ignored`，送的值與實算不同時主動標出來。
    - 📌 大廠的判準是「公開 API 還是內部的」：公開 API（Stripe/Shopify）
      參數永遠不刪、標 deprecated、出新版本；內部 API 走完 contract。
      MIGI 是內部的 → **該做**，只是不必在有其他事情在跑的時候做。
    - ✅ 那份 SQL 裡真正有價值的兩件事**跟拿掉參數無關**，已於
      `sql/applied/2026-08-25_刪死碼與內部呼叫改具名.sql` 完成：
      刪掉死碼 `wallet_topup_tx`、內部呼叫改具名參數。

27.5 ~~`mahjong_buddies` 有兩個一模一樣的唯一索引~~ → ✅ **已刪除**（2026-08-26）。
   留 `uq_buddies`（M0 地基），刪 `uq_buddy_pair`（`MA1B-牌咖與通知.sql:33` 後來補的）。

   🔴 **根因不是粗心，是一句錯的現況敘述。**
   `_設計稿未落地/MA1C:76` 寫「M0 的 mahjong_buddies 補唯一鍵
   （**原表只有 check，沒防重複配對**）」—— 那句是錯的，
   `00a_M0建表_資料骨架.sql:502` 就已經建了定義逐字相同的 `uq_buddies`。
   MA1B 照那份設計稿執行，於是線上長出第二個。
   ⚠ 已在 MA1C 把 B2 整段註解掉並標記作廢（那份若日後執行會建回來）。

   🔴 **教訓：`IF NOT EXISTS` 只檢查名字，不檢查定義。**
   換一個名字就會靜靜建出第二個一模一樣的索引，**沒有任何警告**。
   → 要「補一個唯一鍵」之前先查那張表現有的索引，
     **不要靠 `if not exists` 當保險 —— 它保的是名字不是意圖。**

   📌 補驗時順帶查到 `origin` 的允許值，而**它比索引本身重要**：
   ```
   origin ∈ ('pre_existing', 'matched')
   ```
   對應《牌搭關係與護城河戰略》的兩種牌咖關係 ——
   `pre_existing` 是自帶團、**`matched` 是 MIGI 配桌認識的（護城河）**。
   → **護城河深度可以直接數**：`count(*) where origin = 'matched'`。
   文件講了很多策略，但沒人把它跟這個欄位連起來。

28. **資料庫裡可能有一批死碼**（2026-08-25 粗估）。
    `public` 有 **135 支函式，其中 104 支沒有被任何其他函式呼叫**。
    ⚠ 這個數字**一定偏高** —— 前端直接呼叫的 70 支不算在「被函式呼叫」裡，
      所以它只是粗略訊號，不是清單。
    ✅ 但已經抓到一個真的：`wallet_topup_tx`（無人呼叫、無觸發器、無排程，
      而且 `INVOKER` + `anon` 可執行、簽名沒有任何付款或授權參數）。已刪除。
    → 盤點方法：`135 支` 減去「三個前端呼叫的 70 支」與「被其他函式呼叫的」，
      剩下的逐一判斷。**不要一次全刪** —— 有些是給 pg_cron 或未來用的。

29. **角色要重新設計：POS 端與總部端分開**（2026-08-25 使用者指定，2026-08-26 查證）。
    目標形狀：
    ```
    POS 端   店員 / 店長 / 門市營運 / BOSS
    總部端   BOSS / 數據分析 / 財務 / 採購 / 行銷 …
    ```
    現在是**一欄 `role` 裝兩個維度**（`floor`/`manager` 是門市職務，
    `hq`/`owner` 是層級）—— 同 `wallet_txns.type`（待辦 12）那個病。
    ⚠ **不要直接把值加多**：每新增一個職務就要改 CHECK、改所有判斷邏輯，
      那是 `coupons.applies_to`（待辦 0.8）的形狀。

    **現在要打的基礎只有三件，都不是「建表」：**

    **① 判斷點一律呼叫 `can('order.void')`，不要比對 role 字串。**
       即使 `can()` 今天的實作就是一行 `role in ('hq','owner')`。
       重點是**「權限怎麼決定」與「誰有權限」從第一天就分家** ——
       之後換成查 `role_permissions` 表時，所有呼叫點一行都不用改。
       （同 `member_tiers` 的教訓：折扣率原本寫在兩支函式各一份 case。）

    **② `staff` 要能一人多列**（A 店店長兼總部採購）。
       ✅ **2026-08-26 查證：可以，但條件比我第一次說的精確** ——
       🔴 我先前寫「`member_id` 沒有 unique 約束」是**不完整的**：
         那次查的是 `pg_constraint`（約束），而它是**索引**不是約束，所以沒撈到。
         實際上有 `uq_staff_member_store (member_id, store_id) WHERE deleted_at is null`
         → **一人多列可以，但「同一個人在同一店」只能一列**。那是對的行為。
       ⚠ `staff_auth_uid_key UNIQUE (auth_uid)` 存在 ——
         **總部 Email 那條路一人只能一列**。要一人多職的話這條要拆。
       📌 教訓：查「有沒有唯一限制」時，`pg_constraint` 與 `pg_index` **兩邊都要看**
         —— `CREATE UNIQUE INDEX` 建的不會出現在 `pg_constraint` 裡。

    **③ `role` 不要繼續裝兩個維度** → 拆成 `scope`（store/hq）＋ `role`（職務名）。
       現在 `staff` 只有 **1 列**，拆是零成本；有 30 個店員之後就是
       一次 migration ＋ 回填 ＋ 對照表。

    **④ 權限碼用動詞不用頁面名**：`order.void` / `session.settle` /
       `price.override` / `report.view` / `member.export` / `analytics.view`。
       🔴 **頁面會改名、會合併、會拆開；動作不會。**
       （2026-08-25 一天內就發生過：「會員」→「會員查詢」、側邊欄八項→三項→五項。）

    **不用現在做的**：`role_permissions` 表（①做了之後補它是純加法）、
    權限碼清單（等真有第二個職務再列，現在列是憑空想像）、後台角色編輯 UI。
    ⚠ **角色繼承永遠不要做** —— RBAC 最常被誤用的功能，
      而且沒有人說得出「店長繼承店員」到底包含什麼。

    ⚠ **收斂判準：權限碼控制在 10–15 個。** 多過那個數字就會沒人記得哪個是哪個，
      最後全部給 `owner` 了事（硬規則 5.5：七間店不需要 SAP 的權限矩陣）。

    ⚠ **動手時機：跟待辦 20（店員登入）同一批。** 現在單獨做是第 9 個
      「建了沒人讀」—— 沒有店員登入就沒有人有身分可以被判斷，
      `current_staff()` 永遠回 null，而 **2026-08-26 重新確認：讀 role 的 policy 仍是 0 條**。

30. ~~生日填不了~~ → ✅ **已完成**（2026-08-26，`migi-web` 5a1f854）。
    **2026-08-27 追加**：日曆改成**三欄滾輪**（`WheelCol`，a546926）。
    🔴 換掉月曆的理由是**年份填錯不會有任何症狀** —— 月日錯了，生日當天
      沒收到招待客人馬上就知道；年份錯了永遠沒人發現，而它正是要捲最遠的那一格。
      滾輪能在正上方放大字回顯 ＋「N 歲」當**驗算**，月曆放不下（空間被日期格佔滿）。
    ⚠ **代價：看不到禮拜幾與整個月，這支不能給開房選日期用。**
      那是不同的問題（生日是「幾十年前的某一天」，開房是「這幾天的哪一天」）。
      → 開房要選日期時**另做一支**，不要硬共用。
    ⚠ 我先前寫的「滾輪不要自己寫」是針對**時間**（ichip 快捷已覆蓋 90%）；
      生日的年份沒有捷徑，滾輪確實是它的強項，而 CSS `scroll-snap`
      讓慣性與吸附由瀏覽器負責。
    📌 可試滑的原型：`docs/_資產/生日滾輪原型.html`（**要用瀏覽器開** ——
      預覽器對 `file://` 只做靜態快照，`<script>` 不會執行）。

    - `set_my_birthday_tx(p_org_id, p_member_id, p_birthday)` —— 另開一支，
      **不改 `register_member_tx` 的簽名**（生日可以之後補填，不該綁在註冊那一刻）
    - `get_my_profile_tx` 補回傳 `birthday`（簽名不變）
      ⚠ **只補 birthday**：`gender` / `occupation` / `district` /
        `acquisition_source` / `phone` 刻意不加 —— 前四個是註冊與行銷用的
        內部欄位，`phone` 是 PII 而 App 沒有顯示手機的地方。
        **多回傳一個沒人讀的欄位，是白白擴大暴露面。**
    - `lib/ui.jsx` 的 `BirthdaySheet`（自訂日曆）＋ `profile.jsx` 的設定列

    🔴 **有到期日的決定：現在允許重複修改生日。**
    生日招待是**權益** → 可以隨時改生日 = 可以隨時領招待。
    現在不鎖的理由：① 今天不可能被濫用（0 人綁 LINE、招待還沒自動化）
    ② **鎖了會讓打錯的人卡住** —— 改要找店員，而店員登入卡在 LINE（PENDING）。
    → **生日招待自動化之前必須加鎖**（`where birthday is null`，修改走店員工具）。
    ⚠ 加鎖時記得：`update ... where ...` 之後**一定要看 `FOUND`** ——
      `register_member_tx` 就是這樣謊報成功的（同日修掉）。

30.5 **（舊）生日填不了的原始記錄**（2026-08-26）。
    ```
    members.birthday          欄位在，0 / 4 有值
    register_member_tx(...)   🔴 簽名裡沒有 birthday
    migi-web 註冊 form.birth  存 localStorage，沒送後端
    ```
    🔴 2026-08-26 在 POS 會員查詢加了「🎂 生日 N 天後」的膠囊（七天內才出現），
    **但那顆永遠不會亮，因為沒有任何地方能填生日**。
    而**生日招待是已承諾的權益**。

    → 做法：**另開一支 `set_my_birthday_tx`**（比照 `set_my_sched_tx`），
      不要改 `register_member_tx` 的簽名。
      理由：生日可以之後補填，不該綁在註冊那一刻；
      而改簽名要 DROP + 補 GRANT + 部署順序。

    **順帶：日曆 sheet 元件**（2026-08-26 使用者提供參考介面）。
    App 現在的 `DateField`（`lib/ui.jsx:12`）是**粉色膠囊外觀 ＋ 透明的原生
    `<input type="date">` 疊在上面** —— 外觀是自己的，選擇器是 OS 的。
    值得換成自訂 sheet 的三個理由：
    - 🔴 **LIFF 是 LINE 的 in-app WebView**，原生 `type="date"` 在 iOS 與
      Android 的 LINE 裡長得不一樣、行為也不一致 —— 自訂是唯一可控的做法
    - 視覺斷層：點下去跳出系統灰底滾輪，與 MIGI 粉色設計系統斷開
    - **生日要往回捲幾十年**，原生 picker 在這件事上很痛
    ⚠ **但滾輪時間選擇器不要自己寫**：它解決的問題（拇指滑動選時間）
      原生已經做得很好，而 `ichip` 快捷（`+30 分` / `+1 小時` / `不限`）
      已覆蓋 90%。自己寫要處理慣性、吸附、無障礙 —— 投入大、收益小。
    ⚠ 這一項是**會員 App 的事，不要搬進 POS**：POS 是平板、店員用食指點，
      滾輪的價值（拇指滑動）在那裡不存在；而且滾輪永遠有一個當前值，
      表達不出「還沒選」——那與「開桌設定五項不預選」的決定衝突。

31. 🔴 **會員 App 有三顆膠囊在說謊（顯示寫死的假資料）**（2026-08-27 盤點）。
    | 位置 | 顯示 | 實情 |
    |---|---|---|
    | `profile.jsx` 綁定 LINE | 「已綁定」 | **無條件常數**。`App.jsx:64` 註解明寫「LINE 尚未接上：授權為模擬」 |
    | `wallet.jsx` 錢包 hero | 「會員等級: 焦糖布丁」 | 寫死。`get_wallet_tx` **只回 `balance`/`coupons`/`txns`，沒有等級** |
    | ~~`rewards.jsx` 獎勵頁「我的點數 1,250」~~ | ✅ **已接真餘額**（2026-08-30） | 見下 |

    🔴 **「已綁定」最該優先**：它旁邊每一顆（`rank`／`title`／`likes`）都有
      `prof &&` 的 fallback，**就這顆沒有**。而「未綁定」是真的會出現的狀態 ——
      `register_member_tx` 的 `'rebound'` 路徑就是「用手機註冊過的舊客人第一次用 LINE」。
      → **接 LINE（待辦 14／20）時必做**，否則會對還沒綁的人顯示已綁定。
    🔴 「會員等級」寫死是**待辦 0 的 App 版**：POS 已接 `list_member_tiers_tx`，
      會員 App 還在寫死一個特定會員的等級 —— 任何不是焦糖布丁的人看到的都是錯的。
      ⚠ 要先決定等級從哪來：加進 `get_wallet_tx` 的回傳，還是另開一支。
    ⚠ 「我的點數」不只是假資料，是**同一個 App 對同一個數字給兩個答案**，而那是錢。
    📌 三處都已在程式碼加 🔴 註解寫明缺什麼、會怎麼出錯。

32. **`Pill` 已是會員 App 唯一的資訊型膠囊**（2026-08-27，`migi-web` a546926）。
    加徽章前先讀 `lib/ui.jsx` 的 `Pill` 註解，**不要再寫 inline style**。
    | tone | 意思 |
    |---|---|
    | `pink` | **這跟你有關**（我的預設門市、綁定狀態、我收集到的） |
    | `glass` | 站在彩色卡片上 |
    | `soft` / `plain` / `paper` | 描述標籤（`plain` 只能用在白底，見硬規則 3.85） |

    **刻意不收進來的**（它們的工作是跳出來，統一進去就失去作用）：
    `buddies.jsx` 的「新加入」（例外標記）、`stats.jsx` 的 AI 即時分析與稱號
    （墨底金框）、`rewards.jsx` 的限時活動與倒數、未讀紅點。
    ⚠ **白底＋灰框不可以拿來當徽章** —— 那是「未選中的篩選 chip」，
      五處在用（`wallet:468,550`／`stats:220`／`rewards:100`／`components:320`）。
      用同一個外觀講「這不能點」是直接撞既有語意。
    ⏳ 那五處篩選 chip 逐字相同、重複五次，可收進 `.ichip`（styles.css 早就有
      這個 class 但沒人用）。**是另一批** —— 它們可以點，行為跟徽章不同。

33. **會員 App 接線進度表**（2026-08-27 全盤點）。
    ⚠ 讀之前先看硬規則 10：**假資料是流程的一部分，不是缺陷。**
      這張表是**工作清單與順序**，不是缺陷清單。全部功能都保留，接完才上線。
    ⚠ 查法：看每個畫面背後有沒有真的呼叫後端，不是看它像不像真的。

    ### ✅ 已接真資料
    錢包（餘額／券／點數流水／最近消費／儲值方案／**會員等級**）、
    配桌（房間／開房／報名／離開／門市／注額／我的隊列／封鎖）、
    牌咖（清單／最近同桌／邀請／接受拒絕）、個人檔案（暱稱／頭像／稱號／
    作息／打法／關於我／生日／按讚數）、通知、成績的對局紀錄清單、
    獎勵的養成小熊與頭像、**成績的段位 Hero 與段位走勢圖**（2026-08-31）、
    **賽季膠囊的倒數**（2026-09-01，在此之前「倒數 23 天」是寫死的、從來沒變過）。
    📌 **錢包的儲值抽屜是「還沒接但講清楚」的正確示範**：按下確認會說
      「儲值金流串接後開放」，現金則導向櫃檯。**它沒有假裝自己成功了。**

    ### ⏳ 還沒接 · 卡在上游能力（做不了，不是沒排）
    | 功能 | 缺什麼 |
    |---|---|
    | 成績 · 逐手重播 | 牌局**逐手**紀錄 → 牌譜辨識（M5+） |
    | 牌咖 · 結算 | 牌局分數 → 同上 |
    | 成績 · 排行榜／名人堂／歷代雀神熊 | 賽季制度 ＋ 積分演算法 ＋ 結算週期 |
    | 成績 · **KPI 四格**（胡牌率 23.4%／放槍率 11.2%／平均順位 2.4／全國排名 #128） | 前兩格要**逐手**牌譜（M5+）；排名要賽季排行榜 |
    | 成績 · **各級距勝率**（50/20 58%／30/10 44%／純娛樂 67%） | ⚠ 卡的其實不是資料而是**定義**：四人麻將「贏」是第 1 名還是正分？ |
    🔴 **上線時間由這三項決定**（硬規則 10 的推論）。
    ✅ **2026-08-31 已在程式碼標明白**（在那之前那六個數字完全沒有任何提示，
      每個會員看到的一模一樣）。
    🎯 **平均順位是六格裡最先能接的** —— `session_players.finish_rank` 就是它，
      電子計分一上就算得出來，不必等牌譜。

    ### ⏳ 還沒接 · 純補後端（獎勵頁那批）
    ✅ **2026-08-27 使用者確認：獎品、機率、每週任務都是一開始設定好，之後固定。**
      所以硬規則 5.5 的「誰每週維護」前置**已解除** —— 這批不需要有人每週顧。
    | 功能 | 最小後端範圍 |
    |---|---|
    | 獎勵 · 搓牌抽獎 | 獎品主檔／機率／庫存／發獎紀錄／扣點走 `wallet_txns` |
    | 獎勵 · 每週任務 | 任務定義＋進度＋完成判定＋發獎（固定任務，每週重置進度） |
    | 獎勵 · 每日報到 | 報到紀錄＋連續天數＋發獎 |
    | 獎勵 · 成就牆 | 成就定義主檔＋解鎖條件＋進度計算 |
    🔴 現況：`ACH` 陣列裡的 `on: 1` 是**逐一寫死**的 ——
      每個會員看到的已解鎖徽章一模一樣。

    📌 **抽獎的完整設計已寫成文件**：`docs/03-會員App與社交/抽獎獎品池設計.md`
      （維度與機制定案、100 項初稿、期望成本 16.7 元／抽、保底、法規提醒）。
    🎯 三個關鍵結論，動手前先看：
      · **稀有度不是分類維度，是機率的顯示結果** —— 主檔不用存
      · **履約方式只有三種，而且三種都已經存在**
        （`app_state`／`member_coupons`／`coupons.discount_type='free'` ＋ `free_product_id`）
        → **不需要建兌換子系統，也不需要 POS 新畫面**。
        實體周邊就是一張指定商品的免費券，走現有結帳核銷、`stock_qty` 扣庫存
      · 🔴 **機率必須在後端**（現在 `pickTier()` 是前端 `Math.random()`，
        打開 devtools 就能中傳說），**扣點必須冪等**（照抄 `idempotency_key`）
    ⚠ 最大成本不是程式是**美術**（造型／房間／頭像共 38 項）——
      所以獎品池必須是**資料不是程式碼**，首發只上 30–40 個，其餘分批。

    ### ⏳ 還沒接 · 純補後端，維護成本低（優先做這批）
    | 功能 | 現況 |
    |---|---|
    | 牌咖團 | `useState([寫死一團])`；`social.js` **沒有任何 team 函式** |
    | 預約包桌 | 假；程式碼註解自己寫「刻意保留不刪」 |
    | 結算的人員列 | `const ppl = [寫死四人]`（分數本身卡 M5+） |
    | ~~獎勵 · 我的點數 1,250~~ | ✅ **已完成**（2026-08-30，`migi-web` fb11fd7）。<br>🔴 原本這一格寫「抽獎接完自然變真」—— **那個推論是錯的**：<br>扣點需要抽獎後端，**顯示餘額不需要**。<br>→ 新增 `lib/balance.js`：**一份快取**，錢包頁載到就寫進去、其他頁讀同一格。<br>⚠ 讓獎勵頁自己也呼叫一次 `get_wallet_tx` **不算解決** ——<br>那只是把「一真一假」換成「兩個各自載入的真值」，兩頁仍可能不一樣。<br>🔴 **刻意不寫 localStorage**：頭像可以（一張圖舊一點無所謂），<br>**餘額不行** —— 隔天打開先看到昨天的點數是會打電話來的。<br>拿不到就顯示會動的三點，**不顯示 0**（0 是斷言）。 |
    | 個人檔案 · 已綁定 | 無條件常數 → 接 LINE 時一起（待辦 31） |

    ### 📌 寫死但**合理**的（是內容不是狀態，不用接）
    成就徽章清單、小熊圖鑑清單、衣櫃、零食圖、`CITIES`、`STORE_CATS`。

    ### ✅ 🧹 已清（2026-08-28，`migi-web` cc31645）
    `App.jsx` 那行 import 八個名字**一個都沒用到**，`match.jsx` 三個同樣沒用到，
    兩行整行刪除。

    🔴 **原本這裡寫「只因為沒人用才沒炸」—— 那是錯的，它會炸。**
    `DEMO_MATCHES` / `DEMO_RECORDS` 連 `data.jsx` 都沒有 export，而
    `npm run dev` 走瀏覽器原生 ESM → **模組載入期 SyntaxError，畫面全白**。
    只有正式 build 不炸（Rollup 容忍）。
    → 也就是**本機 dev server 從來沒有人成功跑起來過**，
      而那正是這個死 import 活這麼久的原因。詳見硬規則 11.5。

34. 🔴 **兩個「等著發生」的靜默故障**（2026-08-28 用 MCP 查證）。
    兩者都是「東西在那裡、看起來正常、但第一次真的用就會失敗」——
    跟 `topup_tx` 那次（櫃檯儲值從上線那天起沒成功過一次）同一個形狀。

    **① ~~`topup_void_tx` 沒有授權給 `anon`~~ → ✅ 假警報，2026-08-29 更正。**
    用 `aclexplode` 重查：`topup_void_tx` **有明確的 anon 授權**
    （而且 PUBLIC 已被收掉，是三支裡權限最乾淨的一支）。
    🔴 我 2026-08-28 判定它「沒有 anon」，那個結論是錯的 ——
      同一天我還用同一套讀法判定 12 支管理函式「有 anon」，
      而那 12 支其實是從 `PUBLIC` 繼承的（硬規則 2.6）。
      **同一個儀器，兩個方向都讀錯了。**
    → 做作廢儲值的功能時**仍然要照硬規則 2.5 確認一次**，但不必補 grant。

    **② 桌況分不出「預留中」與「正在打」。**
    自動帶桌是「**湊滿就佔桌**」（使用者 2026-08-28 確認要這個行為），
    所以 21:00 的局 19:00 湊滿就會立刻佔一張桌，**空等兩小時**。
    而 `_try_auto_seat_tx` 的註解自己寫著：
    > ⚠ 代價是那張桌在開打前會空著 —— **所以桌況一定要能顯示「預留中」**，
    > 否則店員會以為有人在打。

    ✅ **2026-08-29 查證：整條已經做完了，這一段的敘述過期了。**
    `list_tables_tx` 回的不是 `activated_at` 而是更好用的四個欄位：
    `is_hold` / `hold_kind`（queue＝配桌佔的、setup＝店員開了還沒結帳）/
    `queue_play_at` / `queue_members`，外加 `auto_assign`。
    而 POS **全部都在用**：`App.jsx:268–281` 畫「預留中 · HH:MM 開打」與要來的人，
    `App.jsx:253` 畫「現場」標記，`App.jsx:507` 可以切換 auto_assign。
    📌 **文件又漂了一次** —— 同踩坑第 29 條：先查再說沒有。

    ✅ **地基已經有了**：`table_sessions.activated_at` 欄位與 `activate_session_tx`
      都存在（「帶桌」與「真的開始打」本來就是兩個動作），缺的只是接出來。
    → 後端：`list_tables_tx` 多回 `activated_at`（簽名不變，`CREATE OR REPLACE`）
    → POS：`activated_at is null` → 「**預留中 · 21:00**」（**要顯示幾點開打**），
      有值 → 「使用中」
    ⚠ **這一項的急迫性綁在自動帶桌真的開始運作那一天** ——
      而目前 `open_method='auto'` 的場次是 **0**，一次都還沒發生過。

35. ~~🔴 **`players` 一個 key 兩種形狀**~~ → ✅ **2026-09-01 全部收完。**
    最後一步是 `list_tables_tx` 的 contract（`2026-09-01_桌況收掉players.sql`，10/10 全過）。
    驗收那一格是「**還有哪些函式回數字版 `players`** → 一支都沒有」，
    同時正對照「陣列版的兩支沒被誤傷」。
    ✅ 收完後實機看過 POS 桌況：使用 2/14、A1 四人、A2「1 人 · 差 3 位」，
      `player_count` 一切正常。
    ⚠ **`pos_add_queue_member_tx` 的 `players` 仍在，那是刻意的** ——
      它回的是「加入之後現在幾人」，是一次性操作結果不是清單欄位。
    🎯 **今後的通則：一個名字一個意思。**
      要回「有哪些人」就叫 `player_names`（比照 `queue_members`）。

    以下保留當時的分析。

    🔴 **`players` 一個 key 兩種形狀**（2026-08-28 從錯誤儀表挖出來的）。
    ```
    list_match_queues_tx     'players' = count(*)      ← 數字
    get_my_active_queue_tx   'players' = [...]         ← 陣列
    get_my_games_tx          'players' = [...]         ← 陣列
    ```
    🔴 已經真的炸過：`app_error` 裡 `(t.players || []).map is not a function` ×5（08-22）。

    ⚠ **`(x || []).map` 只擋 null／undefined，擋不住「是數字」這種真值** ——
      數字原樣通過 `|| []`，然後 `.map` 直接炸。
      **`|| []` 給了一種「我防過了」的錯覺，那比完全沒防更危險。**

    ✅ **2026-08-29 幾乎收完**：
    | | 狀態 |
    |---|---|
    | `list_match_queues_tx` | ✅ **contract 完成**，只剩 `player_count` |
    | `list_tables_tx` | 🟡 **expand 完成**（兩個並存），POS 已改讀 `player_count`。<br>⏳ **等 POS 這版部署過，再做第二次 contract** |
    | `pos_add_queue_member_tx` | ⚠ **刻意不動** —— 它回的是「加入之後現在幾人」，<br>是一次性操作結果不是清單欄位，而且從來沒有陣列版本 |

    🔴 **查證時才發現源頭有兩個**：我原本只看到 `list_match_queues_tx`，
      而桌況的 `list_tables_tx` 也是數字版的 `players`，POS 正在讀它。
      直接拿掉會讓桌況卡片的人數**變空白而且不報錯**。
    📌 **expand → migrate → contract 的意義就在中間那段兩者並存的時間** ——
      少了它，還在跑舊版的裝置會立刻壞掉。

    📌 這是同一個病的**第三次**（前兩次：`wallet_txns.type` 一欄兩義、
      `staff.role` 一欄兩維度）。**一個名字一個意思**，這條值得當成通則。

36. 🔴 **換手機／換 LINE 的四種情境，其中兩種現在無解**（2026-08-28 盤點）。

    📄 **2026-08-30 起，完整的情境表在
    `docs/03-會員App與社交/身分綁定的所有情境與處理.md`**（五張表，每格都查證過）。
    這裡只留摘要與那天修掉的東西。

    ### ✅ 2026-08-30 修掉三個洞（都已驗證歸檔）
    | | 修了什麼 |
    |---|---|
    | `register_member_tx` 收回 anon／PUBLIC | 🔴 修之前**只要知道一支手機號碼**就能拿到別人的 `member_id`，再用它叫 `get_wallet_tx` / `get_my_orders_tx` 看餘額與完整消費明細 —— **完全不需要 LINE**。Edge Function 的驗簽設計被整個繞過 |
    | `line_conflict` / `existing_phone` 不再交出 `member_id` | 🔴 那段的註解寫「不回傳對方的 `line_user_id` —— 那是別人的識別碼」，**但它回傳了 `member_id`**，而在待辦 14 完成前那才是通行證。**防到了錯的東西** |
    | 堵 A3（手機對得上不再自動綁） | 原版是**先寫再判斷**（`update … where line_user_id is null` → 看 `FOUND`），所以「不該綁」那一刻資料已經寫進去了 |

    ✅ ~~代價：換了 LINE 的舊客人自己救不回來~~ →
      **2026-08-30 傍晚已解除**（`2026-08-30_自助認領與換手機.sql`，15 項驗證全過）。
      簡訊 OTP 那條路做完了，所以堵 A3 留下的缺口不再是缺口。
    🔴 **「店員綁定」不是按一個鈕**：POS 拿不到客人的 `line_user_id`
      （那只存在他的 LIFF 裡），需要一個綁定碼機制 ＋ 店員登入（待辦 20）。
      ⚠ 唸 LINE 名稱給店員不行 —— 那不是 id，而且可以改。
    📌 順帶：**POS 現在也叫不動 `register_member_tx`**（它用 anon）。
      今天沒壞（POS 沒有註冊功能），日後要「櫃檯幫客人註冊」要包一層 DEFINER。

    ### （以下為 2026-08-28 的原始盤點，情境代號沿用）
    自助註冊（掃 QR → LINE 授權）之下，系統靠兩條線索認人：
    `line_user_id` 與 `phone`。四種情境：

    | | 情境 | 現況 |
    |---|---|---|
    | **A** | 老客人再來 | ✅ `line_user_id` 查得到 → 直接進 App |
    | **B** | 全新客人 | ✅ 查不到 → onboarding → 建立 |
    | **C** | 只換 LINE 帳號 | ✅ 靠**手機**找到舊帳號 → `rebound` 綁定 |
    | **D** | 只換手機號 | 🟡 登入沒問題（LINE 綁帳號不綁門號），**但資料庫的手機改不掉** |
    | **E** | 手機和 LINE 都換 | 🔴 **兩條線索都斷 → 建出第二個帳號，系統無法預防** |

    ### 🎯 D 與 E 是同一條因果鏈
    ```
    D 能不能更新手機  →  決定 E 會不會發生
    E 一旦發生        →  只能靠店員 + 合併工具（兩者都還沒有）
    ```
    **「讓客人能改手機」不是小功能，它是唯一能預防 E 的東西。**

    ### ✅ D 與 E **整條做完了**（2026-08-30 傍晚，前後端都上）
    · ✅ ~~沒有任何「改手機」的 RPC~~ → **`set_member_phone_tx`**
    · ✅ ~~E 完全沒有補救路徑~~ → **`claim_member_by_phone_tx`（自助認領）**
    · ✅ ~~手機編輯 sheet 假裝存好了~~ → 2026-08-28 止血，**08-30 真的接上**
    · ✅ 個人設定那一列：**完整號碼 ＋ 已驗證／未驗證 Pill ＋ 自助驗證更改**

    🔴 **顯示完整號碼不遮罩**（2026-08-30 使用者指定）。
      我先做成 `0910***736`，當天改回來 —— 遮罩露 4 頭 3 尾，
      對「**這是我的哪一支**」答不完整，而那是這一列唯一的用途。
    ⚠ 代價：`get_my_profile_tx` 是 **anon ＋ 前端送 `p_member_id`**
      ⇒ 知道某人的 member uuid 就查得到他的手機。
      📌 但它本來就已經回傳**生日**與**性別**了 —— 說「手機不能回」
        而生日可以，本身就不一致。**已知並接受的取捨**，
        待辦 14 改吃 `auth.uid()` 之後歸零。

    🔴 **三種狀態不是兩種**：「有沒有號碼」與「驗過沒有」是兩件事。
      欄位有值只代表**有人填過**，不代表那支手機是他的（櫃檯可能打錯字 ＝ C4）。
      → 有號碼但未驗證時，**號碼與「未驗證」兩個都要顯示**。
    ⚠ Pill 寫「已驗證」不寫「已綁定」：上面那一列（LINE）才是綁定。
      手機這一列回答的是「**這支號碼能不能把我的帳號救回來**」。

    ### ✅ 2026-08-28 止血：那一列原本同時說**兩個**謊
    ① `onSave` 只寫 `localStorage.migi_phone`，卻跳出「手機號碼已更新」。
    ② 🔴 **顯示的值本身也是 localStorage 的**（比本條原本記的多一層）——
      換一支手機打開就變「尚未綁定」；而**新的註冊流程根本不寫 `migi_phone`**，
      所以**每一個新客人註冊完這一列都會顯示「尚未綁定」**，即使他剛剛才填過。

    現況：不顯示號碼（`get_my_profile_tx` 不回傳 phone，前端無從得知），
    改成 `手機號碼　請洽櫃檯 ›`，點下去 toast「查詢或更改手機號碼請洽櫃檯」。
    ⚠ **刻意沒有把 phone 加進 `get_my_profile_tx`** —— 那是待辦 14 的 PII 決定：
      現在 `p_member_id` 是前端傳的，多回一個**可聯絡**的個資等於擴大暴露面。
      要顯示真值，等 JWT。

    ### ✅ E 的自助路徑（2026-08-30）
    ```
    輸入手機 → 驗證碼 → 驗過 ─┬─ 沒人用 → 繼續填生日性別 → 新帳號
                              └─ 有人用 → claim_member_by_phone_tx
    ```
    🔴 **不要先問「這支號碼有人用嗎」**（使用者 2026-08-30 指出）。
      舊版在第 2 步邊打邊查、查到就紅字「請找店員」——
      **而真正的號碼主人也被擋在門外**，自助救援永遠走不到入口。
      ⇒ `check_phone` 整支拿掉，岔路搬到**驗過之後**。
      🎯 順帶消滅一個查詢器：那本來是「有 LINE 就能一直問某支號碼是不是會員」。
        現在要知道任何事，**都得先證明你拿著那支手機**。

    ⚠ **仍然會回店員的三種**（`staff_required` / `line_bound_elsewhere` /
      `merge_required`）—— 見 db-現況快照的分級表。
      這三種目前**都沒有店員工具**：`rebind_line_user_tx` 存在但 POS 沒有 UI，
      而且需要 `p_staff_id`（店員登入還沒做）。
    📌 這仍然說明店員登入（待辦 20）與帳號合併（待辦 15）是**同一個問題的兩半**，
      只是自助那條路做完之後，**會走到店員的人少很多**。

    ### ⚠ 改手機有一個真的安全問題，所以不能全開放
    客人 A 把手機改成 **B 還沒註冊的號碼** → B 之後註冊時
    `register_member_tx` 用手機找到 A 的帳號 → **B 被綁進 A 的帳號，看到 A 的錢包**。
    `uq_members_phone` 只擋「已經有人用的號碼」，擋不掉這種佔用。

    🎯 **改手機與換綁 LINE 是同一類操作 —— 都是改身分橋樑。**
      那正是 `rebind_line_user_tx` 有 `p_staff_id` 的理由。

    ### 拍板的做法（2026-08-30 落地時**簡化成一條**）
    原本分兩格（沒填過 → 自助補；已有值 → 只有店員能改）。
    ✅ **有了 OTP 之後兩格併成一條：一律驗新號碼。**
    | 情況 | 誰能改 |
    |---|---|
    | 新號碼**驗得過** | ✅ 客人自己（不管舊號碼是空的還是有值） |
    | 新號碼**已經是別人的** | 🔴 `phone_taken` —— 那是別人的身分，不能搶 |
    | **驗不了**（手機已經不在手上） | 🔴 店員 |

    🎯 **舊號碼是什麼根本不重要** —— 你證明的是「我控制這支新號碼」，
      而那才是這個欄位存在的意義。
    ✅ 這也順帶解掉上面那個「A 把手機改成 B 還沒註冊的號碼」的問題：
      **A 改不到 B 的號碼，因為 A 收不到那支手機的簡訊。**

    ⚠ `set_member_phone_tx` **不收 `p_member_id`** —— 會員是從 `line_user_id`
      查出來的。收 member_id 的話這支就變成「給我一個 id 就改他的手機」，
      即使只有 service_role 叫得動，**那個形狀本身就不該存在**。

37. 🔴 **開 GA4／Meta 之前必做：測試帳號的判斷要改吃後端**（2026-08-28 標記）。
    `migi-web/src/lib/analytics.js` 用一份**寫死的 4 個 uuid 清單**判斷測試帳號。
    資料庫有 `members.is_test`，但**沒有任何 RPC 把它回傳給前端**。

    | | 現況 |
    |---|---|
    | `ANALYTICS.toGA4` | **false** |
    | `ANALYTICS.toMeta` | **false** |
    | `app_events` 的 `is_test` | ✅ 後端從 `members` 推，**與前端清單無關** |

    🟢 **所以今天零影響** —— 那份清單什麼都沒在擋。
    🔴 **但 `toGA4` 改成 true 的那一刻它就變成洞**：資料庫新增第 5 個測試帳號
      而沒人記得改 `analytics.js` → 那個人的事件會被當成真實客人送進 GA4，
      而 **GA4 的資料洗不掉，還會污染廣告受眾學習**（同 `app_events` 那 2847 筆）。

    ✅ **修法很便宜**：`isTestMember()` **已經先看 `m.is_test`**，
    才 fallback 到 uuid 清單 —— 所以只要 `register_member_tx` 回傳 `is_test`
    （`CREATE OR REPLACE`、簽名不變、不掉 GRANT），前端存進 localStorage 就生效。
    **一支 SQL ＋ 一行 JS。**

    ⚠ **現在不要做** —— 今天已經挖出兩個「建了沒人讀」
      （`TestAccountSwitcher` 死碼、`DEMO_MATCHES` 死 import），不要製造第三個。
    🎯 **它的觸發點是單一而明確的**：把 `toGA4` 或 `toMeta` 改成 `true` 之前，
      先做完這一項。寫在這裡就是機制本身（同硬規則 12）。

38. 🔴 **官方帳號（Messaging API）開通時的清單**（2026-08-28 立，開之前先讀這條）。
    2026-08-28 已建立：Provider `MIGI 咪吉麻將` ＋ 一個 **LINE Login** channel ＋ LIFF app。
    **官方帳號刻意還沒開** —— 它是另一種 channel（Messaging API），要另外建。

    ### 🔴 為什麼「是會員」不等於「能通知他」
    | | |
    |---|---|
    | 客人用 LINE 登入 | ✅ 拿到 `line_user_id`，他是會員 |
    | 你要推播給他 | 🔴 **他必須先加官方帳號好友**，否則送不到 |

    對 MIGI 這件事很具體：配桌最關鍵的一則訊息是「**你的牌局湊滿了 · 今晚 21:00 · 3 號桌**」。
    **只有加了好友的人收得到。** App 內通知（`app_notifications`）要他打開 App 才看得到 ——
    而人不會沒事打開 App。
    → 「湊滿了但當事人不知道」會直接讓配桌的價值垮掉。

    ### 開通當天要做的四件事
    1. 🔴 **Messaging API channel 必須建在同一個 Provider 底下**（`userId` 是 per-Provider，
       同硬規則：分開會讓同一個人有兩個 id，而且不報錯只是接不起來）。
    2. 🔴 **回到 LIFF 設定把 `Add friend option` 從 `Off` 改成 `On (Normal)`。**
       那一格讓「授權」與「加好友」一步完成。
       ⚠ **不要選 `On (Aggressive)`** —— 它會強迫跳出加好友，客人的第一印象變成被推銷。
       ⚠ 這一格現在是 Off 是對的（那時官方帳號還不存在），**但沒有人會自己想起來要改**。
    3. **圖文選單（Rich Menu）的「會員」按鈕**：連到 **`https://liff.line.me/{LIFF_ID}`**，
       不要連 `app.migi.tw`。走 LIFF URL 客人才會自動登入（在 LINE 內免授權畫面）。
    4. **加入好友的歡迎訊息**：第一句就給 LIFF 連結，不要只寫「感謝加入」。

    ### 🔴 三個入口指向不同的網址（2026-08-28 使用者定的流程）
    ```
    門市 QR      → 加好友 URL（https://line.me/R/ti/p/@官方帳號ID）
                   → 歡迎訊息（含 LIFF 連結）→ 註冊
    圖文選單      → LIFF URL（常駐入口，客人之後都從這裡回來）
    朋友分享／廣告 → LIFF URL → 靠 Add friend option 補上加好友
    ```
    🔴 **門市 QR 指的是「加好友」不是 LIFF**（我一度寫成 LIFF，錯的）。
      理由：**先加好友才保證推播送得到**，而配桌湊滿的通知是 MIGI 的核心。
      QR 直接指 LIFF 的話，客人註冊完卻沒加好友 —— 你有他的 id 但通知不到他。
    ⚠ 代價是多一步 → 用**歡迎訊息第一句給 LIFF 連結**把它壓成零摩擦。
    📌 加好友 URL **永遠不會失效**（官方帳號 ID 穩定），
      不像 LIFF app 刪掉就讓所有印出去的 QR 全部作廢。

    ### ✅ 已查證：Add friend option 對「已經是好友的人」不會多一步
    官方文件：已加過好友者**不顯示加好友選項**，只顯示「已加為好友」的狀態。
    → 所以走「先加好友」流程的客人，這一格開著**不會造成任何摩擦**，兩者互補。
    | | |
    |---|---|
    | `On (Normal)` | 在**既有的同意畫面裡**多一個選項，不多一頁 |
    | `On (Aggressive)` | 同意畫面**之後再開一個獨立畫面** ← 所以才叫 aggressive |

    ⚠ 還沒決定的：回應模式（聊天／自動回應）、要不要開 webhook。
      **有人要顧聊天室嗎？** 沒有的話就關掉聊天、只做推播（硬規則 5.5）。

39. **原生對話框全站盤點**（2026-08-29 做完盤點，migi-web 的 confirm 已清）。

    ### ✅ 已完成：`askConfirm()` ＋ `<ConfirmHost />`（migi-web）
    `lib/ui.jsx`，照 `showToast` / `<Toast />` 同一套慣例（全域事件 ＋ 單一 host）。
    做成回傳 Promise 是為了讓呼叫點**一行換掉**，不必各自加 state。
    危險動作 `danger: true` → `--danger` 紅；一般確認 → `--ink`。
    已取代 5 處 `window.confirm`：解除牌咖／加黑名單／移出黑名單 ×2／刪頭像照片。

    🔴 **原生 confirm 的問題不只是醜**：
    ① 在 LINE 的 WebView 裡 iOS 與 Android 各長一種
      —— 跟「自己畫日曆與滾輪」是同一個理由
    ② **講不出「這個動作是危險的」** —— 刪除與一般確認長得一模一樣
    ③ 標題會被瀏覽器加上網域名（`app.migi.tw 顯示`），像釣魚頁

    ### ⏳ 還沒處理的

    | repo | 處數 | |
    |---|---|---|
    | migi-pos | **0** ✅ | 它有自己的 `Modal`（`OpenCheckoutPage.jsx:1811`） |
    | **migi-admin** | **1** 🔴 | `Products.jsx:182` `confirm('確定刪除…此動作無法復原')` |
    | migi-web | 9 | 1 個 `prompt` ＋ 8 個 `alert` |

    🔴 **admin 那一個最該優先**：刪商品是真的破壞性動作，
      而唯一的防線是原生 confirm。而且 `migi-admin/src/lib/` 底下只有
      `ErrorBoundary` / `products` / `supabase` —— **整個 repo 沒有任何 UI 元件庫**，
      連 toast 都沒有。
    ⚠ 所以那不是「換一顆按鈕」，是**要不要給 admin 開一套 UI 基礎**的決定。
      在那之前，原生 confirm **好過沒有確認**（後台使用者是自己人，
      而且桌機瀏覽器的 confirm 比手機 WebView 一致得多）。

    **migi-web 那 9 處分成兩類，問題不一樣：**
    | 類型 | 位置 | 問題 |
    |---|---|---|
    | **「還沒接」的佔位** ×8 | `buddies.jsx:142,173,176,226`（牌咖團）／`buddies.jsx:379` 派車／`match.jsx:532` 叫車／`wallet.jsx:345,347` 儲值／`components.jsx:118` 邀進團 | 「還沒接」沒問題（硬規則 10），**錯的是用 `alert` 說**。錢包的儲值抽屜是正解，同一個 App 裡兩套講法 |
    | **`prompt` 改團名** ×1 | `buddies.jsx:101` | 🔴 `prompt` 是三個裡最糟的：沒有驗證、沒有取消語意、樣子最不可控。而 **`EditTextSheet` 這個 App 已經有了**（`rewards.jsx`） |

    ⚠ **不要把那 8 個 alert 一次全改**：牌咖團整組是待辦 33 的「純補後端」那一批，
      接後端時那些 alert 本來就會消失。**現在改等於改兩次。**
      → 該現在改的只有 `prompt`（它有現成元件）與**派車／叫車／儲值**
        那三個「短期內不會接」的，換成 `showToast`。

    ### 其他「各 OS 長相不同」的原生控制項
    | repo | |
    |---|---|
    | migi-web | `<select>` ×5、`DateField` 的 `type="date"`、`TimeField` 的 `type="time"`、`type="file"` ×1 |
    | migi-pos | `type="date"` ×1、`type="time"` ×2（`QueuePage` 固定牌局） |
    | migi-admin | 0 |

    ⚠ **`type="file"` 不用換** —— 那是「開啟系統選檔器」，本來就該是系統的。
    ⚠ **POS 的 date/time 不急** —— 平板不是 LIFF WebView，長相可控得多；
      而且 `ichip` 快捷（`+30 分`／`+1 小時`）已經覆蓋大部分情況（同待辦 30 的判斷）。
    ⏳ migi-web 的 `DateField` / `TimeField` 與 5 個 `<select>` 才是真的要換，
      理由同待辦 30：**LIFF 是 LINE 的 in-app WebView，原生選擇器兩個平台不一致**。

40. 🔴 **稱號解鎖目前是「前端說了算」**（2026-08-30 查證，**不是**要現在做解鎖機制）。
    ⚠ **稱號整套還沒討論過**（使用者 2026-08-30 明講），所以這一條**只記錄現況**，
      不是設計提案。真的要做時再從「有哪些稱號、憑什麼拿到」開始談。

    ```
    save_app_state_tx(p_org_id, p_member_id, p_bear, p_titles)   ← anon 叫得動
      titles = 兩邊聯集（只增不減）
    set_my_title_tx  的守衛：select 1 from member_app_state where titles ? p_title
    ```
    🔴 那道守衛擋的是「**前端有沒有先寫進去**」，不是「**他有沒有達成**」。
      而且「只增不減」讓它**不可逆** —— 寫一次就永遠解鎖。

    🟢 **今天沒有被利用**：前端唯一的呼叫點（`rewards.jsx:1508`）
      只送 `bear`，`p_titles` 是 null ⇒ `coalesce(null,'[]')` 聯集後不變。
      也就是**目前沒有任何人解得開任何稱號**，清單永遠只有「新手上路」。
    🔴 但那是「沒人去按」不是「按不了」：手工打一次 RPC 就能拿到「三屆雀神」。

    📌 同硬規則 5.8：**稱號是成就不是偏好**，它跟小熊造型不一樣 ——
      造型是他自己的選擇（前端說了算是對的），成就是系統對事實的認定。
      **兩種東西不該共用同一支寫入函式。**
    ⏳ 真的要做時的形狀（先記著，不要現在建）：
      解鎖由後端從事實算出來，`titles` 變成**唯讀的計算結果**，
      `save_app_state_tx` 拿掉 `p_titles` 參數。

### 上線當天

📄 **`docs/09-環境流程/上線當天要設的東西.md`**（2026-09-01 建）。

🔴 **不要在對話裡重新推導這一份** —— 它原本散在三個地方
（本檔的 PENDING、待辦與未定案、賽季表 SQL 的註解），而**散開的清單一定會漏掉一項**。

七項的共同形狀是：**不設也不會壞，只會安靜地錯。**
最硬的一項是 **`orgs.live_from` 現在是 null ⇒ 每一支 `v_real_*` 都回 0 列**
（那是設計上的空不是 bug）。

## PENDING
- 店員登入未做，`staffId` 一律傳 null，`App.jsx` 還有 `const STAFF = "小美"` 寫死。
  ⚠ 後果不只是「不知道是誰」：`table_sessions` 98/98、`orders` 150/150 的
  `updated_by` **全部是 null**，出事完全查不到經手人；而且交班日結沒有意義。
- ✅ ~~LINE Developers 帳號未申請~~ → **2026-08-28 已建立**：
  Business ID（`admin@migi.tw`）→ Provider **`MIGI 咪吉麻將`** →
  一個 **LINE Login** channel（同名）→ LIFF app（Full／`https://app.migi.tw`／
  scope `openid`+`profile`）。Region 與 Company country 都選 **Taiwan**。
  ⚠ `Require two-factor authentication` 刻意**關掉** —— 它會要求客人輸入
    **LINE 帳號密碼**，而很多人是手機號＋簡訊註冊的、**從來沒設過密碼**，
    那條路會直接斷掉。日後 POS 店員登入若要更嚴，**那才是開第二個 channel 的正當理由**
    （同一個 Provider 底下，客人寬鬆、店員嚴格）。
  ⚠ Privacy policy URL／Terms of use URL 先留空（optional）——
    🔴 **上線前必須有隱私權政策頁**：你要收手機、生日、消費紀錄，
    那是**法規要求**不是 LINE 的要求。App 裡那兩列現在還是「即將推出」的 toast。
  ✅ **LIFF ID `2011312117-Zuul0Ndo`**，前端已接（`lib/line.js` ＋ step 0 改寫）。
  ✅ **Edge Function `line-login` 已部署**（`supabase/functions/line-login/index.ts`），
    secret `LINE_CHANNEL_ID = 2011312117`（SHA256 比對確認過值正確）。
    四項測試全過：假 token → `line_token_invalid`（**證明它真的去跟 LINE 驗了**）／
    無 token → `id_token_required`／無 anon key → Verify JWT 擋下／CORS preflight 200。
  🔴 **channel 的 `Developing` 狀態會擋住登入，不只是「還沒公開」**
    （2026-08-29 踩到）。我第一次看到那個標記時說「正常，那只是還沒公開」——
    **錯的**。實際點進 LIFF 會拿到：
    ```
    400 Bad Request
    This channel is now developing status. User need to have developer role.
    ```
    ⚠ 而**你的 LINE Business ID 跟你手機上那個 LINE 帳號是兩個身分** ——
      channel 的角色掛在 Business ID 上，個人 LINE 沒有那個角色，所以
      「我就是 Admin」也一樣被擋。
    → 解法是把 channel 切成 **Published**（Basic settings，channel 名稱旁邊）。
    ⚠ **不可逆**：要回到 Developing 只能刪掉 channel 重建。
    📌 但發布**不等於公開曝光** —— 沒有商店列表也搜尋不到，
      拿不到 LIFF 網址的人進不來。
    🎯 教訓同硬規則 3.8：**看到一個狀態標記就推論它在管什麼，那是猜。**
      `Developing` 這個詞完全沒有提示它會擋登入，而**錯誤只在真的去登入時才出現**。
  ⏳ **還沒做**：官方帳號（見待辦 38）、實機走完一次註冊。

  ### 🔴 創辦人現在有**兩個**會員帳號（2026-09-01 查證，取代 08-29 那一版）
  ```
  69016205-afde-4036-95a6-5893c9d0e5fe  山劍八舞澤
    phone 0910768736 ✅已驗證   LINE ✅已綁   生日 1985-06-12  性別 male
    訂單 0 筆   餘額 0          建立 2026-08-29 06:02（LIFF 註冊當下）
    ← 🎯 **App 現在登入的就是這個**

  d73fdac2-d6b9-4b8a-bcff-b19c2786056f  測試測試測試測試測試測試（＝測試01）
    phone 0910000001            LINE ❌未綁    生日 1985-06-12
    訂單 70 筆  餘額 3,580      建立 2026-06-20
  ```

  ✅ **這個狀態是對的，不需要合併。**
  · `山劍八舞澤` = 創辦人**真的**用 LIFF 註冊出來的帳號
  · `測試01` = **一筆測試資料**。70 筆訂單與 3,580 餘額都是種進去的，
    不是他真的消費；生日一樣只是當初一起種了。
  ⇒ **兩個帳號 ≠ 同一個人的兩個帳號。** 一個是真人，一個是 fixture。

  🔴 **8/29 那一段本來就寫錯了**：它說「創辦人 = `d73fdac2`、
    手機 **0910768736**、所以用 LINE 註冊會走 `rebound` 不會建新會員」。
    實際上測試01 的手機是 `0910000001`，`register_member_tx` 用手機找人
    當然找不到 → 建新的，**而那正是應該發生的事**。

  🔴 **2026-09-01 我在這裡連錯兩次，兩次都值得記：**
  ① 照抄這段 id 寫測試工具 → **造了三場戰績給錯的帳號**，畫面上什麼都沒變。
     → 同硬規則 3 與踩坑第 29 條：**會員 id 也要當場查，不可以抄文件。**
     → `sql/_工具/測試戰績_造.sql` 已改成只留一個參數、其餘從資料庫撈。
  ② 查出「手機對不上」之後，我把它推成「**待辦 15 的雙帳號發生了**」
     並寫進這份文件。**錯的**——正確的結論是「那句話本來就寫錯了」。
     🎯 **用一個錯的前提去解釋一個矛盾，會得到第二個錯的結論。**
       矛盾出現時要先問「哪一個前提是假的」，不要急著解釋它。

  ⚠ **不要把總部那筆 staff 綁到這個會員上** —— 理由見待辦 20（Email 路徑已通，
    `member_id = null` 是對的狀態）。要讓創辦人用 LINE 登入 POS 是**另開一列**的事。

  🎯 **`is_test` 先留 `true`**（驗收期間會亂點）。
    **改成 `false` 的時機是「設 `orgs.live_from`」那一天** —— 那是同一個動作的兩半。
    ⚠ 那時要順便決定一個會計問題：**老闆自己打牌的消費要不要進營收報表？**
      他若常免費打，那些資料會扭曲客單價與場地費營收。
