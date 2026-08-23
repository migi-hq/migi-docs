-- 【這是什麼】唯讀：撈 generate_recurring_instances_tx 全文與 recurring_tables 欄位。
-- 【何時讀】要讓固定牌局也能掛標籤之前。
--
-- ⚠ 為什麼非撈不可：標籤要**從範本帶到每一場實例**。
--   只在 recurring_tables 加欄位而產生器沒帶過去，結果是
--   「店員設了標籤、範本裡也存著、但客人看到的每一場都沒有標籤」——
--   資料是對的、畫面是空的、完全不報錯。硬規則 4 那個形狀。

select 項目, 結果
from (
  select 1 as ord, '① generate_recurring_instances_tx 全文' as 項目,
    coalesce((select pg_get_functiondef(oid) from pg_proc
               where pronamespace='public'::regnamespace
                 and proname='generate_recurring_instances_tx' limit 1),
             '❌ 不存在') as 結果

  union all select 2, '② recurring_tables 欄位',
    coalesce((select string_agg(column_name || ' ' || data_type, '、' order by ordinal_position)
                from information_schema.columns
               where table_schema='public' and table_name='recurring_tables'),
             '❌ 表不存在')

  union all select 3, '③ pos_list_recurring_tx 全文（範本清單要顯示標籤就得改它）',
    coalesce((select pg_get_functiondef(oid) from pg_proc
               where pronamespace='public'::regnamespace
                 and proname='pos_list_recurring_tx' limit 1),
             '❌ 不存在')

  union all select 4, '④ 目前有幾個啟用中的固定牌局範本（改動影響範圍）',
    coalesce((select count(*)::text || ' 個啟用 / ' ||
                     (select count(*) from recurring_tables)::text || ' 個總計'
                from recurring_tables where enabled), '—')

  union all select 5, '⑤ 已生成但還沒開打的 recurring 實例數（要不要回填標籤）',
    coalesce((select count(*)::text from match_queues
               where source = 'recurring' and status = 'waiting' and play_at > now()), '—')
) x
order by ord;

-- ── 讀完之後的計畫 ────────────────────────────────────────
-- 1. recurring_tables 加 tags jsonb NOT NULL default '[]'（比照 match_queues）
-- 2. pos_create_recurring_tx 加 p_tags，比對 queue_tags 擋未知代碼（與即時同一套）
--    ⚠ 簽名會變 → 先 DROP
-- 3. generate_recurring_instances_tx 把 tags 帶進 match_queues
--    ⚠ 這是整件事的關鍵。少了它，範本存了標籤而每一場實例都是空的。
-- 4. pos_list_recurring_tx 回傳 tags，讓「固定牌局設定」那頁看得到自己設了什麼
--    ⚠ 設了看不到 = 店員無法確認，只能再設一次
-- 5. ⑤ 那些已生成的實例要不要回填：
--    要。否則「今天設好標籤」到「明天以後的場次才有」之間會有一段空窗，
--    而店員不會知道為什麼。回填是 update ... from recurring_tables 一句話。
