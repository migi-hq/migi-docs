-- 【這是什麼】唯讀盤點：固定牌局的母範本（recurring_tables）與生成函式全文。
-- 【何時讀】接在 sql/checks/查固定局生成與過期.sql 之後。
--
-- ═══ 已知事實（2026-08-22 盤點）═══
--   · 兩個 cron job 呼叫同一支函式、同樣參數 generate_recurring_instances_tx(org, 7)
--     → 純重複，刪一個
--   · 排程近三天全部 succeeded，但回傳的「1 row」是 SELECT 的列數（純量函式本來就回一列），
--     **跟建立了幾筆實例無關**。這支可以連續產生零筆而紀錄永遠是成功 —— 觀測性的洞。
--   · p_days_ahead = 7，但 08-23 之後一筆實例都沒有
--   · 僅存的未來實例是 08-25 12:00 UTC，其餘歷史實例都是 13:00 UTC → 疑似不同母範本
--   · recurring_id 沒有外鍵指向 recurring_tables → 實例可以指向不存在的範本
--
-- 這支要回答：母範本有幾個、還開著嗎、生成函式到底依什麼條件產生實例。

select 項目, 結果
from (
  select 1 as ord, 'recurring_tables 欄位' as 項目,
    (select string_agg(column_name, ', ' order by ordinal_position)
       from information_schema.columns
      where table_schema = 'public' and table_name = 'recurring_tables') as 結果

  union all select 2, 'recurring_tables 筆數',
    (select count(*)::text from recurring_tables)

  -- 用 to_jsonb 整列印出來，免得猜欄位名（硬規則 3）
  union all select 3, 'recurring_tables 全部內容',
    coalesce((select string_agg(j::text, chr(10) order by j->>'id')
                from (select to_jsonb(r) as j from recurring_tables r) t),
             '（表是空的 —— 沒有母範本就不會生成任何實例）')

  union all select 10, '每個 recurring_id 目前有幾筆未來實例',
    coalesce((select string_agg(coalesce(recurring_id::text, '<null>') || ' → ' || n, chr(10) order by n desc)
                from (select recurring_id, count(*) as n
                        from match_queues
                       where source = 'recurring' and play_at > now()
                       group by recurring_id) t),
             '（未來一筆都沒有）')

  union all select 11, '每個 recurring_id 的歷史實例數與最後一筆時間',
    coalesce((select string_agg(coalesce(rid, '<null>') || ' → ' || n || ' 筆，最後 ' || last_at, chr(10) order by last_at desc)
                from (select coalesce(recurring_id::text, '<null>') as rid,
                             count(*)::text as n,
                             max(play_at)::text as last_at
                        from match_queues where source = 'recurring'
                       group by recurring_id) t),
             '（沒有實例）')

  union all select 12, '孤兒實例：recurring_id 在 recurring_tables 裡找不到',
    (select count(*)::text from match_queues q
      where q.source = 'recurring'
        and q.recurring_id is not null
        and not exists (select 1 from recurring_tables r where r.id = q.recurring_id))

  union all select 20, 'generate_recurring_instances_tx 全文',
    coalesce((select pg_get_functiondef(oid)
                from pg_proc where pronamespace = 'public'::regnamespace
                 and proname = 'generate_recurring_instances_tx' limit 1),
             '（函式不存在）')
) x
order by ord;

-- ── 讀完之後怎麼判斷 ─────────────────────────────────────────
-- 第 2 項 = 0        → 母範本被刪光了。生成函式每 6 小時忠實地產生零筆，
--                      而 cron 永遠回報 succeeded。這就是固定局消失的原因。
-- 第 3 項有 is_active / enabled 之類的欄位是 false → 範本被停用了。
-- 第 12 項 > 0       → 有孤兒實例。因為 recurring_id 沒有外鍵，
--                      刪範本不會連動，實例會留下來指向空氣。
-- 第 20 項           → 看它是依 recurring_tables 逐筆展開，還是有別的條件
--                      （例如只在某個星期幾、或有 until 日期）。
