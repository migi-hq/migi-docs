-- ============================================================
-- v_real_session_players 補 hidden_from_history_at（2026-10-10，錯誤儀表 ⑫ 抓到）
--
-- 2026-10-09 session_players 加了 hidden_from_history_at（從本人紀錄藏起來的場次），
-- 而報表檢視表的欄位是寫死的清單 ⇒ 底層表加欄位不會跟著進去，查詢不報錯，
-- 寫報表的人只會得到「沒有這筆資料」的結論。
-- 修法：CREATE OR REPLACE VIEW 在最後面加這一欄（原有欄位、條件、權限都不動 ——
--   replace 不是新建，不吃 default privileges；驗證段 ③ 確認前端仍然讀不到）。
-- ============================================================

create or replace view public.v_real_session_players as
 select id,
    org_id,
    session_id,
    member_id,
    join_type,
    status,
    charged_points,
    joined_at,
    created_at,
    created_by,
    finish_rank,
    score_points,
    settled_at,
    order_id,
    seat,
    left_at,
    paid_by,
    fee_waived_amount,
    fee_waived_reason,
    rating_after,
    final_score,
    device_id,
    hidden_from_history_at
   from session_players x
  where (exists ( select 1
           from v_real_table_sessions rs
          where rs.id = x.session_id)) and not (exists ( select 1
           from members m
          where m.id = x.member_id and m.is_test));

-- ── 驗證（單一 SELECT）──
-- ① 檢視表有這一欄　② 跟底層表比，沒有再漏任何欄位（錯誤儀表 ⑫ 同一個比法）
-- ③ 前端（anon／authenticated）仍然讀不到（檢視表繞過 RLS，2026-09-29 收掉的權限不可以回來）
select
  (select case when exists (select 1 from information_schema.columns
                             where table_schema = 'public' and table_name = 'v_real_session_players'
                               and column_name = 'hidden_from_history_at')
               then '✅ 有 hidden_from_history_at' else '🔴 沒有' end)                         as "①",
  (select coalesce('🔴 還漏：' || string_agg(t.column_name, '、'), '✅ 跟 session_players 欄位一致')
     from information_schema.columns t
    where t.table_schema = 'public' and t.table_name = 'session_players'
      and not exists (select 1 from information_schema.columns v
                       where v.table_schema = 'public' and v.table_name = 'v_real_session_players'
                         and v.column_name = t.column_name))                                   as "②",
  (select case when has_table_privilege('anon', 'public.v_real_session_players', 'SELECT')
                 or has_table_privilege('authenticated', 'public.v_real_session_players', 'SELECT')
               then '🔴 前端讀得到了' else '✅ 前端仍然讀不到' end)                             as "③";
