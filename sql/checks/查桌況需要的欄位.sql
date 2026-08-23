-- 【這是什麼】唯讀盤點：要在桌況卡做「預留中」與「現場」兩個狀態之前，撈 list_tables_tx 全文。
-- 【何時讀】動手改那支之前（硬規則 3：改既有函式一律先撈線上版）。
--
-- ═══ 要加什麼 ═══
--
-- 🔴 **預留中**：湊滿就佔桌之後，那張桌在桌況上會顯示「使用中」**但其實沒有人在打**
--    （table_sessions 開了，但還沒有人結帳，session_players 是 0）。
--    店員會以為滿了而把現場客人推掉 —— 那是實際的生意損失。
--    → 需要回傳 seated_count（已結帳入座人數）與那一房的開打時間、成員。
--
-- 🟡 **現場**：auto_assign = false 的桌要看得出來。
--    少了它，週六為了現場客人關掉的桌，週一沒人記得改回來，
--    那幾桌會從此永遠不被自動配到，而且畫面上看不出任何異常。
--    → 需要回傳 auto_assign。

select 項目, 結果
from (
  select 1 as ord, 'list_tables_tx 全文' as 項目,
    coalesce((select pg_get_functiondef(oid) from pg_proc
               where pronamespace='public'::regnamespace and proname='list_tables_tx' limit 1),
             '（不存在）') as 結果

  union all select 2, 'settle_session_tx 簽名（收桌勾選要接在這裡）',
    coalesce((select pg_get_function_identity_arguments(oid) from pg_proc
               where pronamespace='public'::regnamespace and proname='settle_session_tx' limit 1),
             '（不存在）')

  union all select 3, 'settle_session_tx 全文',
    coalesce((select pg_get_functiondef(oid) from pg_proc
               where pronamespace='public'::regnamespace and proname='settle_session_tx' limit 1),
             '（不存在）')

  union all select 4, 'set_table_active 那類的桌位設定 RPC 有哪些',
    coalesce((select string_agg(proname || '(' || pg_get_function_identity_arguments(oid) || ')', chr(10) order by proname)
                from pg_proc
               where pronamespace='public'::regnamespace and prokind='f'
                 and proname ilike '%table%' and proname not ilike '%queue%'),
             '（無）')

  union all select 10, '現在有沒有「已配好桌但還沒結帳」的桌（＝預留中）',
    coalesce((select string_agg(t.label || '　' ||
                (q.play_at at time zone 'Asia/Taipei')::text || ' 開打　' ||
                coalesce((select string_agg(m.display_name, '、')
                            from match_queue_players p join members m on m.id = p.member_id
                           where p.queue_id = q.id and p.left_at is null), '(沒有成員)'),
                chr(10) order by q.play_at)
                from match_queues q
                join table_sessions s on s.id = q.matched_session_id
                join tables t on t.id = s.table_id
               where q.status = 'seated' and s.status = 'open'
                 and not exists (select 1 from session_players p where p.session_id = s.id)),
             '（目前沒有）')

  union all select 11, '各店有幾張桌設成「現場專用」（auto_assign = false）',
    coalesce((select string_agg(s.name || ' → ' || n || ' 張', chr(10) order by s.name)
                from (select store_id, count(*) n from tables
                       where auto_assign = false and deleted_at is null group by store_id) t
                join stores s on s.id = t.store_id),
             '（目前全部都開放自動配）')
) x
order by ord;

-- ── 讀完之後怎麼判斷 ─────────────────────────────────────────
-- 第 1 項：看它回哪些欄位，才知道加 seated_count / auto_assign 要改哪裡。
-- 第 2／3 項：收桌的「收完保留給現場」是在 settle_session_tx 加一個參數
--   （p_keep_for_walkin boolean），成功之後順手把那張桌的 auto_assign 設 false。
--   ⚠ 為什麼要合在同一支：情境是「現場有四人在等」，
--     店員必須**先關掉那桌再按收桌**，順序反了就被 App 搶走 ——
--     而那是客人站在旁邊時要記得的事。一個勾選同時做兩件事，就沒有順序可以搞錯。
-- 第 4 項：看有沒有現成的「改桌位設定」RPC 可以重用。
