-- ============================================================
-- 修正 list_tables_tx 人數誤算
-- 產生日期：2026-08-14
--
-- 問題：
--   原本判斷在座人數用 `sp.status <> 'left'`，
--   但 session_players_status_check 只允許 playing / completed / late / forfeit，
--   根本沒有 'left' 這個值 —— 條件恆為真，已離座的人也被算進去。
--   離座是用 left_at 時間戳表示的，get_session_tx 就寫對了（sp.left_at is null）。
--
-- 影響：
--   桌況卡顯示的在座人數虛報，連帶「差 N 位」的提示也錯。
--   人愈換得勤的桌誤差愈大。
--
-- 簽名未變更（p_org_id uuid, p_store_id uuid），CREATE OR REPLACE 不會產生多載。
-- 全函式照抄線上版本，只改 players 那一行，其餘一字未動。
-- ============================================================

CREATE OR REPLACE FUNCTION public.list_tables_tx(p_org_id uuid, p_store_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', t.id, 'label', t.label, 'area', t.area, 'seats', t.seats,
      'is_active', t.is_active, 'note', t.note,
      'status', case
                  when not t.is_active then 'off'
                  when ts.id is not null then 'use'
                  else 'idle' end,
      'session_id', ts.id,
      'started_at', ts.started_at,
      'planned_minutes', ts.planned_minutes,
      'stake_level_id', ts.stake_level_id,
      'mode', ts.mode,
      'players', coalesce((
        select count(*) from session_players sp
         where sp.session_id = ts.id
           and sp.left_at is null), 0)      -- ← 修正：原為 sp.status <> 'left'
    ) order by t.sort_order, t.label)
    from tables t
    left join lateral (
      select ts.* from table_sessions ts
       where ts.table_id = t.id and ts.status = 'open' and ts.deleted_at is null
       order by ts.started_at desc limit 1
    ) ts on true
    where t.org_id = p_org_id and t.store_id = p_store_id and t.deleted_at is null
  ), '[]'::jsonb);
end $function$;


-- ---------- 驗證：拿一間門市比對修正前後的人數 ----------
-- 把 <STORE_ID> 換成實際門市 id（例如 MIGI 高雄自由店
-- 22222222-2222-2222-2222-222222222222）
-- select jsonb_pretty(list_tables_tx(
--   '11111111-1111-1111-1111-111111111111'::uuid,
--   '<STORE_ID>'::uuid));
