-- ============================================================
-- 唯讀盤點（不改任何東西）
-- ------------------------------------------------------------
-- 一次確認三件事，省往返：
--   ① get_session_tx 的線上實際定義（要加回傳 members.title）
--   ② members.title / rank 欄位存在且型別正確
--   ③ 《總路線圖 M0~M8》聲稱「LAUNCH 後端已完成」的那批函式，
--      db-現況快照 裡完全沒有 —— 究竟是真的沒部署，還是快照漏盤？
--      這關係到「券核銷／桌邊點餐／最小報表」到底能不能用。
--
-- 依 CLAUDE.md 硬規則 3：不要用文件推斷線上狀態，要實查。
-- 依踩過的坑第 19 條：SQL Editor 一次跑多個 SELECT 只顯示最後一個，
-- 所以本檔刻意只有「一個 SELECT」。
-- ============================================================

select
  p.oid::regprocedure  as 簽名,
  case p.prosecdef when true then 'DEFINER' else 'INVOKER' end as 安全模式,

  -- ② members 稱號與段位欄位
  (select string_agg(column_name || ' ' || data_type
                     || case when is_nullable = 'YES' then ' NULL' else ' NOT NULL' end, ' / '
                     order by column_name)
     from information_schema.columns
    where table_schema = 'public'
      and table_name   = 'members'
      and column_name in ('title', 'rank'))            as members稱號與段位,

  -- ③ LAUNCH 那批函式實際存在哪些（沒有就回 NULL）
  (select string_agg(distinct pr.proname, ' / ' order by pr.proname)
     from pg_proc pr
     join pg_namespace ns on ns.oid = pr.pronamespace
    where ns.nspname = 'public'
      and pr.proname ~ '(grant_points|grant_coupon|on_trigger|redeem_coupon|place_fnb_order|set_order_status|daily_report)')
                                                       as LAUNCH函式實際存在,

  -- ③b 券發放相關資料表實際存在哪些
  (select string_agg(table_name, ' / ' order by table_name)
     from information_schema.tables
    where table_schema = 'public'
      and table_name in ('grant_rules','grant_log','member_tags','games','game_players'))
                                                       as相關資料表實際存在,

  pg_get_functiondef(p.oid)                            as 完整定義

from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname = 'get_session_tx';
