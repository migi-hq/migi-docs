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
        📌 更新 baseline 時，記得把下面這四個數字一起改。 */
  select 6, '⑥ 結構物件數 vs baseline（2026-08-29：表39 函式138 索引81 policy28）',
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
              || case when (select count(*) from pg_class c
                             join pg_namespace n on n.oid=c.relnamespace
                            where n.nspname='public' and c.relkind='r') = 39
                       and (select count(*) from pg_proc p
                             where p.pronamespace='public'::regnamespace and p.prokind='f') = 138
                       and (select count(*) from pg_policies where schemaname='public') = 28
                      then E'\n  ✅ 與 baseline 相同'
                      else E'\n  ⚠ 與 baseline 不同 —— 重跑 sql/checks/匯出完整結構baseline.sql'
                 end)

  union all
  select 5, '⑤ 測試標記（修好前的歷史資料仍標成營運）',
         (select 'is_test=true ' || count(*) filter (where is_test)::text ||
                 '　is_test=false ' || count(*) filter (where not is_test)::text ||
                 E'\n  其中 2026-08-26 之前且 is_test=false：' ||
                 count(*) filter (where not is_test and created_at < '2026-08-26')::text ||
                 ' 筆（那些其實都是測試）'
            from app_events)

) x order by 序;
