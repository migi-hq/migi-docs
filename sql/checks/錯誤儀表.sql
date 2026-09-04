/* ============================================================
   錯誤儀表 —— **每次 session 開始跑一次**
   2026-08-28 建立 · 唯讀 · 可重複執行，不是 migration

   ⚠ 檔名刻意沒有日期：它不是「某一天的查證紀錄」，是**常駐工具**。

   ── 為什麼存在 ──────────────────────────────────────
   埋點的寫入端做好了（migi-web 從 2026-07、POS 從 2026-08-26），
   但**讀取端是零** —— 錯誤一直在累積而沒有人打開來看。

   🔴 2026-08-28 第一次打開，50 筆 `app_error` 裡找到一個**還活著的結構問題**：
     `(t.players || []).map is not a function` ×5 ——
     後端三支 RPC 用同一個 key 名 `players` 表達兩種形狀
     （`list_match_queues_tx` 回數字、另外兩支回陣列），
     而 `|| []` 擋不住「是數字」這種真值。
   → **那 50 筆躺了一個多月沒有人看過。** 這支就是為了不要再發生。

   ── 為什麼是「session 開始跑」而不是排程 ────────────
   排程要有人看告警，而那個人不存在（硬規則 5.5）。
   CLAUDE.md 每次 session 都會載入 —— **把它寫進 CLAUDE.md 就是機制本身**，
   不是靠記性。⚠ 這跟硬規則 1.6／1.7 是同一個想法：
   把檢查綁在一個「一定會發生的動作」上。

   ── 讀法 ────────────────────────────────────────────
   · ①② 是**新東西**（近 7 天）—— 有東西就要看
   · ③④ 是全期統計 —— 用來判斷「這是新問題還是老朋友」
   · ⑤ 是資料品質，不是錯誤

   ── 🔴 2026-09-04：①③ 開始過濾「開發期的 HMR 噪音」──────────
   `npm run dev` 連的是正式資料庫（硬規則 11.6），而改程式時 HMR
   會產生一堆暫態錯誤（`X is not defined`、
   `Cannot access 'y' before initialization`）——
   **那是編輯過程不是產品問題。**
   🔴 實測：近 30 天 88 筆錯誤裡 **74 筆是這種**，也就是唯一的監控面
     有 84% 是雜訊，而真的問題被埋在裡面。
   ✅ **寫入端已經擋掉**（`migi-web/main.jsx`＋`ErrorBoundary.jsx`、
     `migi-pos/lib/analytics.js`＋`main.jsx` 都加了 `import.meta.env.DEV` 守衛）。
   🔴 **但歷史那 80 筆改不掉** —— `trg_app_events_no_mutate`
     連 UPDATE 與 DELETE 都擋。所以 ①③ 要在讀取端過濾。
   ⚠ 過濾條件只認**這一族的訊息形狀**，不是「所有含 not defined 的」——
     真的產品錯誤也可能長這樣（例如漏了 import 就上線）。
     🎯 判準：`is not defined` / `before initial` 這兩個字串在**正式版**
       幾乎不可能出現（build 會先擋下來，硬規則 11），所以拿它們當標記
       是安全的。要是哪天真的漏了一個上線，那也**應該**被當成噪音濾掉之後
       靠 ② 的事件量與客訴發現 —— 不要為了這個把 84% 的雜訊放回來。

   ── 📌 一個教訓（2026-09-04）───────────────────────────
   我當天沒跑這一支，而是**隨手改了一份查詢** —— 那份只讀
   `props->>'msg'`，於是 60 筆用 `props->>'message'` 的完全沒被算到，
   我因此以為「儀表有 bug」。**儀表本來就 `coalesce` 兩個鍵（見 ① 第 40 行）。**
   🎯 **有現成工具就跑現成的。** 即興的查詢沒有人審過。
   （寫入端 2026-09-04 已統一成 `msg`，但歷史那 60 筆是 `message`
     且改不掉 —— 所以 `coalesce` 要一直留著。同 `wallet_txns.type`
     那個「歷史值凍結、只讀不寫」的做法。）
   ============================================================ */

select 序, 項目, 內容 from (

  /* ① 近 7 天的錯誤。空的是好事。 */
  select 1 as 序, '① 近 7 天的錯誤（空的是好事）' as 項目,
         coalesce((select string_agg(
                     to_char(mx,'MM-DD') || '　' || ev || '　' || knd ||
                     '　×' || n::text || '　' || msg, E'\n' order by mx desc)
                     from (
                       select event as ev,
                              coalesce(props->>'kind','(無)') as knd,
                              left(coalesce(props->>'message', props->>'msg',
                                            props->>'error', props->>'fn', '(無訊息)'), 80) as msg,
                              count(*) as n, max(created_at) as mx
                         from app_events
                        where event in ('app_error','pos_error')
                          and created_at > now() - interval '7 days'
                          -- 🔴 濾掉開發期 HMR 噪音（見檔頭）。歷史那 80 筆改不掉。
                          and coalesce(props->>'msg', props->>'message', '')
                              !~* '(is not defined|before initial)'
                        group by 1,2,3
                        order by max(created_at) desc
                        limit 15) s),
                  '✅ 近 7 天沒有錯誤') as 內容

  union all
  /* ② 近 7 天有沒有事件進來。
        🔴 「零筆」不代表沒問題 —— 可能是**埋點自己壞了**。
          埋點是靜默的：`app_events` 有 CHECK（event 格式、props <= 8192），
          違反就插入失敗而那一筆直接消失。 */
  select 2, '② 近 7 天的事件量（零筆要懷疑埋點自己壞了）',
         coalesce((select string_agg(d || '　' || n::text || ' 筆', E'\n' order by d desc)
                     from (select to_char(created_at,'MM-DD') d, count(*) n
                             from app_events
                            where created_at > now() - interval '7 days'
                            group by 1) s),
                  '🔴 近 7 天一筆事件都沒有 —— 先確認埋點還活著')

  union all
  /* ③ 全期錯誤排行。用來分辨「新問題」與「已經修好的老朋友」。 */
  select 3, '③ 全期錯誤排行（前 10）',
         coalesce((select string_agg(
                     knd || '　×' || n::text || '　' ||
                     to_char(mn,'MM-DD') || '→' || to_char(mx,'MM-DD') || '　' || msg,
                     E'\n' order by n desc)
                     from (
                       select coalesce(props->>'kind','(無)') as knd,
                              left(coalesce(props->>'message', props->>'msg',
                                            props->>'error','(無訊息)'), 70) as msg,
                              count(*) as n,
                              min(created_at) as mn, max(created_at) as mx
                         from app_events
                        where event in ('app_error','pos_error')
                          -- 同 ①：濾掉開發期 HMR 噪音
                          and coalesce(props->>'msg', props->>'message', '')
                              !~* '(is not defined|before initial)'
                        group by 1,2 order by count(*) desc limit 10) s),
                  '（沒有錯誤紀錄）')

  union all
  /* ④ POS 有沒有在用。
        ⚠ `pos_nav` 是「哪些功能有人用」唯一的入口（待辦 23）。
          它很少代表 POS 沒被實際操作，不代表埋點壞了。 */
  select 4, '④ POS 事件分佈（pos_nav 很少 = POS 還沒被真的用）',
         coalesce((select string_agg(event || ' ×' || n::text, '　' order by n desc)
                     from (select event, count(*) n from app_events
                            where event like 'pos%' group by event) s),
                  '（POS 還沒有任何事件）')

  union all
  /* ⑤ 測試資料有沒有混進營運數據。
        🔴 CLAUDE.md 記過：POS 的事件 member_id 一律是 null → is_test 恆為 false
          → 測試門市的操作會混進營運數據**且不報錯**。
          2026-08-26 已修（補門市與會員兩條推導路徑），
          但**修之前的歷史資料仍然標成 is_test=false**。
        ⚠ 所以做報表查 `v_real_app_events` 時，2026-08-26 之前的資料要另外排除。 */
  /* ⑥ baseline 有沒有過期。
        🔴 `sql/_baseline/` 是「某一天的完整結構」，**不會自動同步**。
          而 CLAUDE.md 記過：有人會直接在 Dashboard 改而不留檔
          （承重牆 `uq_members_line_user` 就是這樣來的）——
          那種變更**連 `applied/` 都沒有**，baseline 一過期就真的會漏。
        ⚠ 數字不一樣不代表壞掉，代表「該重跑
          `sql/checks/匯出完整結構baseline.sql` 了」。
        📌 更新 baseline 時，記得把下面這五個數字一起改。

        🔴 **⑥ 只數「有幾個」，數不到「權限變了」**（2026-08-29 發現）。
          收掉 12 支函式的 PUBLIC 執行權之後，表／函式／索引／policy
          **四個數字一個都沒動** —— 而那是一次真正的安全性變更。
          → 所以第 ⑦ 段數的是**授權**：明確授權 anon 的支數，
            以及「只靠 PUBLIC 進來」的支數（**那個應該永遠是 0**）。 */
  select 6, '⑥ 結構物件數 vs baseline（2026-09-04：表46 函式168 索引85 policy29 帶can20）',
         (select '表 ' || (select count(*)::text from pg_class c
                            join pg_namespace n on n.oid=c.relnamespace
                           where n.nspname='public' and c.relkind='r')
              || '　函式 ' || (select count(*)::text from pg_proc p
                              where p.pronamespace='public'::regnamespace and p.prokind='f')
              || '　索引 ' || (select count(*)::text from pg_index x
                              join pg_class t on t.oid=x.indrelid
                              join pg_namespace n on n.oid=t.relnamespace
                             where n.nspname='public'
                               and not exists (select 1 from pg_constraint con
                                                where con.conindid=x.indexrelid))
              || '　policy ' || (select count(*)::text from pg_policies
                                 where schemaname='public')
              /* 🔴 **policy 的「條數」抓不到「條件被改鬆了」**（同下面那段對授權的說明）。
                    2026-09-04 收緊 20 條 policy，四個數字**一個都沒動** ——
                    因為那是 drop + create 同名，數量不變。
                 → 所以這裡多數一個「帶 `can()` 的有幾條」：
                    3 條寫入（products／order_items／order_payments）
                    ＋ 17 條敏感讀取 = **20**。
                 ⚠ 少了就是有人把權限判斷拿掉了，而**那不會有任何症狀** ——
                    症狀是「開了 JWT 之後會員讀得到全 org 的手機與消費明細」。 */
              || '　帶 can() ' || (select count(*)::text from pg_policies
                                   where schemaname='public' and coalesce(qual,'') like '%can(%')
              || case when (select count(*) from pg_policies
                             where schemaname='public' and coalesce(qual,'') like '%can(%') <> 20
                      then E'\n  🔴 帶 can() 的 policy 不是 20 條 —— 有人動了權限判斷'
                      else '' end
              || case when (select count(*) from pg_class c
                             join pg_namespace n on n.oid=c.relnamespace
                            where n.nspname='public' and c.relkind='r') = 46
                       and (select count(*) from pg_proc p
                             where p.pronamespace='public'::regnamespace and p.prokind='f') = 168
                       and (select count(*) from pg_policies where schemaname='public') = 29
                      then E'\n  ✅ 與 baseline 相同'
                      else E'\n  ⚠ 與 baseline 不同 —— 重跑 sql/checks/匯出完整結構baseline.sql'
                 end)

  union all
  /* ⑦ 函式授權有沒有漂。
        🔴 **「anon 叫得動」有兩種來源，而它們的意思完全不同**（硬規則 2.6）：
          · **明確授權**  —— 有人決定要給前端叫的
          · **PUBLIC 繼承** —— 建函式時的預設值，**沒有人做過那個決定**
        `has_function_privilege` 分不出這兩種，所以這裡一律用 `aclexplode`。
        ⚠ 「只靠 PUBLIC」那個數字**應該永遠是 0** ——
          不是 0 就代表有人新建了函式而沒有明確決定它的授權範圍，
          **而新函式預設是 PUBLIC 可執行**（＝任何人叫得動）。 */
  select 7, '⑦ 函式授權 vs baseline（2026-09-04：明確 anon 129、只靠 PUBLIC 0）',
         (select '明確授權 anon ' || count(*) filter (where anon明確)::text
              || '　只靠 PUBLIC ' || count(*) filter (where public有 and not anon明確)::text
              || '　兩者都沒有 ' || count(*) filter (where not anon明確 and not public有)::text
              || case when count(*) filter (where public有 and not anon明確) > 0
                      then E'\n  🔴 有函式只靠 PUBLIC 進來 —— 那不是決定，是預設值。逐支確認要不要給 anon'
                      when count(*) filter (where anon明確) <> 129
                      then E'\n  ⚠ 明確授權的支數變了 —— 重跑 sql/checks/匯出完整結構baseline.sql'
                      else E'\n  ✅ 與 baseline 相同' end
            from (select
                    exists (select 1 from aclexplode(coalesce(p.proacl,'{}')) a
                             where a.grantee = 'anon'::regrole::oid
                               and a.privilege_type = 'EXECUTE') as anon明確,
                    (p.proacl is null or exists (select 1 from aclexplode(p.proacl) a
                             where a.grantee = 0
                               and a.privilege_type = 'EXECUTE')) as public有
                   from pg_proc p
                  where p.pronamespace = 'public'::regnamespace and p.prokind = 'f') s)

  union all
  /* ⑧ 最近有沒有新會員。
        🔴 **這一段的存在是因為 2026-09-01 漏了一次**：
          創辦人 8/29 用 LIFF 註冊出一個全新帳號（`山劍八舞澤`），
          而 `analytics.js` 那份寫死的測試帳號清單不知道 ——
          他在 App 上的每一個動作都不算測試。
          🟢 當時零影響（`toGA4` 是 false），但那正是待辦 37 的形狀。

        🎯 **判準很簡單：真實客人還沒出現**（`orgs.live_from` 是 null）。
          所以**現在任何一個新會員，不是你在測試，就是第一個真客人** ——
          兩種都值得在 session 開頭看到一眼。
        ⚠ `is_test = false` 的新會員**不一定是錯的** ——
          上線之後那就是正常的。這一格是**提醒**不是告警。
        ⏳ 上線（設好 `live_from`）之後這一段就沒有意義了，那時可以拿掉。 */
  select 8, '⑧ 近 14 天的新會員（上線前：不是你在測試就是第一個真客人）',
         coalesce((select string_agg(
                     to_char(created_at,'MM-DD') || '　' || display_name ||
                     '　' || case when is_test then 'is_test ✅' else '🔴 is_test = false' end ||
                     case when line_user_id is not null then '　LINE ✅' else '' end,
                     E'\n' order by created_at desc)
                     from members
                    where deleted_at is null
                      and created_at > now() - interval '14 days'),
                  '✅ 近 14 天沒有新會員')

  union all
  /* ⑨ 上線清單還剩幾項。
        🔴 **這一段存在是因為「我會提醒你」不是一個機制。**
          CLAUDE.md 硬規則 1.6 記過「靠『記得更新』已經被證明行不通一次了」，
          硬規則 12 記過「排程要有人看告警，而那個人不存在」——
          兩條的解法都一樣：**綁在一個一定會發生的動作上**。
          而這份儀表就是那個動作（每次 session 開始跑）。

        🔴 更根本的問題：**「上線」沒有明確的觸發點。**
          你不會某天宣布「今天上線」—— 你會是**某天第一個真客人走進來**，
          而那一刻沒有任何東西會響。第 ⑧ 段就是在盯那件事。

        📄 完整說明在 `docs/09-環境流程/上線當天要設的東西.md`，
          這裡只印**還沒做的**與**查得到的**。
        ⚠ 有兩項 SQL 看不到（在前端與 LINE 後台），所以固定列出來提醒 ——
          **看不到不等於不用做**，那正是最容易漏的兩項。 */
  select 9, '⑨ 上線清單（📄 docs/09-環境流程/上線當天要設的東西.md）',
         (select string_agg(項, E'\n') from (
            select 1 as ord, case when (select live_from from orgs where id='11111111-1111-1111-1111-111111111111'::uuid) is null
                   then '🔴 ① orgs.live_from 還沒設 —— 每一支 v_real_* 都回 0 列（設計上的空，不是 bug）'
                   else '✅ ① live_from = ' || (select live_from::date::text from orgs where id='11111111-1111-1111-1111-111111111111'::uuid) end as 項
            union all
            select 2, case when exists (select 1 from members where is_test and line_user_id is not null and deleted_at is null)
                   then '🟡 ② 自己人的 is_test 還是 true（' ||
                        (select count(*)::text from members where is_test and deleted_at is null) ||
                        ' 個）—— 🔴 跟 ① 是同一個動作的兩半'
                   else '✅ ② 沒有 is_test 的帳號了' end
            union all
            select 3, case when exists (select 1 from rank_seasons where now() >= starts_at and now() < ends_at)
                   then '✅ ③ 賽季涵蓋今天' else '🔴 ③ 今天不在任何賽季裡 —— 段位分不會結算' end
            union all
            /* 🎯 合併工具的截止點就是 ①（見 db-現況快照與上線清單 ⑥.5）。
                  ⚠ 跑之前先重跑 `2026-09-04_合併會員前的盤點.sql` ——
                    每加一張帶 member_id 的表，那份 SQL 就少搬一個欄位。 */
            /* ④ 會員合併 —— **刻意不上線，等觸發條件**（2026-09-04 決定）。
               🔴 **它不是「還沒做」，是「做好了放著」**：
                 實作在 `sql/_設計稿未落地/2026-09-04_會員合併.sql`，
                 觸發條件是「第一個不是自己人的會員出現」（第 ⑧ 段在盯）
                 或設 `live_from` 那天。
               ⚠ 今天用不到的理由很硬：**5 個會員裡只有 1 個綁了 LINE**
                 ⇒ 重複帳號的前提（兩個都走過 LINE 註冊）**不成立**。

               🎯 **但這一格仍然要留著，因為它在盯一個會漂的數字：**
                 那份實作**明寫要搬 25 個欄位**，而每加一張帶 `member_id`
                 的表就少搬一個 —— **不會報錯，只會把資料留在死帳號上**。
               📌 實證：CLAUDE.md 記「23 個外鍵」，2026-09-04 實查 **25** ——
                 差額全是同一週自己新建的 `season_standings` / `season_champions`，
                 而**沒有任何東西提醒過我**。 */
            select 4, case when (select count(*) from pg_constraint
                                  where contype='f' and confrelid='public.members'::regclass) <> 25
                   then '🔴 ④ 指向 members 的外鍵變成 ' ||
                        (select count(*)::text from pg_constraint
                          where contype='f' and confrelid='public.members'::regclass) ||
                        ' 個（合併稿只搬 25 個）—— 動它之前先重跑 checks/2026-09-04_合併會員前的盤點.sql'
                   else '⏸ ④ 會員合併：稿在 _設計稿未落地/，外鍵仍是 25 個（等第一個真客人）' end
            union all
            select 5, case when exists (select 1 from staff where member_id is not null and deleted_at is null)
                   then '✅ ⑤ 有店員綁了會員（LINE 登入那條路）'
                   else '⏳ ⑤ 沒有任何 staff 綁會員 —— 店員登入還沒有人能登（待辦 20）' end
            union all
            /* 🔴 這兩項 SQL 查不到，但**看不到不等於不用做**。 */
            select 6, '⏳ ⑥ LINE 官方帳號（Messaging API）—— SQL 查不到，見待辦 38'
            union all
            select 7, '⏳ ⑦ 隱私權政策頁 —— 🔴 法規要求（你收手機、生日、消費紀錄）'
            union all
            select 8, '⏳ ⑧ GA4/Meta 的 toGA4 還是 false —— ✅ 前置條件（待辦 37）已完成，隨時可開'
            order by ord) y)

  union all
  /* ⑩ 帳號救援這條路還活著嗎。
        🔴 **這一段在盯一個沒有症狀的單點依賴。**
        客人換了 LINE 帳號時，唯一的自助救援是
        `claim_member_by_phone_tx`，而它的擋牆是「**最近驗證過手機**」
        ⇒ **沒有簡訊能力，整條救援路就斷了**。

        ⚠ 斷掉的症狀是：**所有換了 LINE 的客人都救不回來，
          而且沒有人會發現** —— 除非有客人打電話來抱怨。
          簡訊商欠費、token 過期、帳戶停用，任何一個都會造成這件事。
        🎯 那正是硬規則 5.5 的形狀：需要有人維護的東西，
          要先確認「壞掉的時候有人會知道」。

        ⚠ **這是資訊格不是告警格**（同第 ⑧ 段）：
          上線前本來就沒什麼人在驗手機，回 0 是正常的。
          真正要看的是**送出與成功的落差** ——
          「發很多、成功很少」＝簡訊沒送到（而 Edge Function 那邊
          只會在 log 裡留一行，沒有人在看）。
        📌 `sent_at` 有值就是發出去了；`verified_at` 有值才是驗過。 */
  select 10, '⑩ 帳號救援（換 LINE 靠自助認領，而它需要簡訊）',
         (select '近 30 天：發出 ' || count(*) filter (where sent_at > now() - interval '30 days')
              || ' 筆　驗證成功 ' || count(*) filter (where verified_at is not null and sent_at > now() - interval '30 days')
              || E'\n  最後一次成功：'
              || coalesce(to_char(max(verified_at) at time zone 'Asia/Taipei', 'MM-DD HH24:MI'), '（從來沒有）')
              || '　累計 ' || count(*) || ' 筆'
              || case
                   when count(*) filter (where sent_at > now() - interval '30 days') = 0
                     then E'\n  ⚠ 近 30 天沒有人驗手機 —— 上線前正常，上線後要留意'
                   when count(*) filter (where verified_at is not null and sent_at > now() - interval '30 days') = 0
                     then E'\n  🔴 有發出但**一次都沒成功** —— 簡訊可能根本沒送到'
                   else '' end
            from phone_otps)

  union all
  select 5, '⑤ 測試標記（修好前的歷史資料仍標成營運）',
         (select 'is_test=true ' || count(*) filter (where is_test)::text ||
                 '　is_test=false ' || count(*) filter (where not is_test)::text ||
                 E'\n  其中 2026-08-26 之前且 is_test=false：' ||
                 count(*) filter (where not is_test and created_at < '2026-08-26')::text ||
                 ' 筆（那些其實都是測試）'
            from app_events)

) x order by 序;
