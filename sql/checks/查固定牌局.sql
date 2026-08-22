-- 【這是什麼】唯讀盤點：固定牌局（recurring）從畫面上消失，先分辨是「資料沒了」還是「查不出來」。
-- 【何時讀】App 配桌頁看不到固定牌局時。
--
-- 前端條件很單純：queues.filter(q => q.source === 'recurring')（match.jsx:342）。
-- 所以只有三種可能：
--   ① match_queues 裡真的沒有 source='recurring' 的列
--   ② 有，但 list_match_queues_tx 沒回傳（狀態、時間、門市或積分級距條件把它濾掉了）
--   ③ 有回傳但 source 欄位的值不是 'recurring'
--
-- 單一 SELECT，整段貼進 SQL Editor。

select 項目, 結果
from (
  select 1 as ord, 'match_queues 各 source × status 筆數' as 項目,
    coalesce((select string_agg(coalesce(source, '<null>') || '/' || coalesce(status, '<null>') || ' = ' || n, '   ' order by source, status)
                from (select source, status, count(*) as n from match_queues group by source, status) t),
             '（整張表沒有資料）') as 結果

  union all select 2, 'recurring 的筆數（不分狀態）',
    (select count(*)::text from match_queues where source = 'recurring')

  union all select 3, 'recurring 的 play_at 範圍',
    coalesce((select '最早 ' || min(play_at)::text || '　最晚 ' || max(play_at)::text
                from match_queues where source = 'recurring'), '（沒有 recurring）')

  union all select 4, 'recurring 裡開打時間還在未來的筆數',
    (select count(*)::text from match_queues
      where source = 'recurring' and play_at > now())

  -- ⚠ 若第 2 項 > 0 但第 4 項 = 0，代表實例全部過期了 —— 那不是 bug，
  --   是「排程沒有繼續生成新實例」。要查的是生成那一段，不是前端。

  union all select 10, 'match_queues 有哪些欄位',
    (select string_agg(column_name, ', ' order by ordinal_position)
       from information_schema.columns
      where table_schema = 'public' and table_name = 'match_queues')

  union all select 11, 'source 欄位允許哪些值（CHECK）',
    coalesce((select string_agg(pg_get_constraintdef(oid), ' ｜ ')
                from pg_constraint
               where conrelid = 'match_queues'::regclass and contype = 'c'
                 and pg_get_constraintdef(oid) ilike '%source%'),
             '（沒有 CHECK 限制）')

  union all select 20, '最近 5 筆 recurring（不分狀態）',
    coalesce((select string_agg(
                '[' || status || '] ' || play_at::text ||
                ' 門市=' || coalesce(store_id::text, 'null'), '   ' order by play_at desc)
                from (select status, play_at, store_id from match_queues
                       where source = 'recurring' order by play_at desc limit 5) t),
             '（沒有 recurring）')

  union all select 21, '最近 5 筆非 recurring（對照組）',
    coalesce((select string_agg(
                '[' || coalesce(source, '<null>') || '/' || status || '] ' || play_at::text, '   ' order by play_at desc)
                from (select source, status, play_at from match_queues
                       where source is distinct from 'recurring' order by play_at desc limit 5) t),
             '（沒有）')

  -- 生成端：固定局是排程產生的，先確認排程存在
  union all select 30, 'pg_cron 排程清單',
    coalesce((select string_agg(jobname || ' → ' || schedule, '   ' order by jobname)
                from cron.job), '（沒有排程，或沒有 cron schema 的讀取權限）')

  union all select 31, '名字裡有 recurring 的函式',
    coalesce((select string_agg(proname, '、' order by proname)
                from pg_proc
               where pronamespace = 'public'::regnamespace and prokind = 'f'
                 and (proname ilike '%recur%' or prosrc ilike '%recurring%')),
             '（無 —— 代表沒有任何函式會產生固定局實例）')
) x
order by ord;

-- ── 讀完之後怎麼判斷 ─────────────────────────────────────────
-- 第 2 項 = 0            → 資料真的沒了。看第 31 項有沒有生成函式；
--                          沒有的話「固定局」從來就是靠手動或假資料撐著。
-- 第 2 項 > 0、第 4 項 = 0 → 實例全過期。要修的是排程生成，不是前端。
-- 第 2 項 > 0、第 4 項 > 0 → 資料在、時間也對，那就是 list_match_queues_tx
--                          的條件把它濾掉了，下一步撈那支的定義來看。
-- 第 11 項若 source 沒有 'recurring' 這個值 → 前端的判斷字串從一開始就對不上。
