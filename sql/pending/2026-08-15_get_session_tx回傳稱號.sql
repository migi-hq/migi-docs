-- ============================================================
-- get_session_tx 的 players 加回傳 members.title（稱號）
-- ------------------------------------------------------------
-- 為什麼：POS 座位卡（SeatPage.jsx）早就寫好稱號膠囊的完整實作，
--         但 TablePage.jsx 組 players 時 title 只能寫死 null，
--         因為這支 RPC 沒回傳這個欄位 —— 稱號功能等於從未顯示過。
--
-- 線上版來源：2026-08-15 以 pg_get_functiondef 撈出（硬規則 3），
--             本檔是在該版本上「只加一行」，其餘一字未動。
--
-- 不需要 DROP FUNCTION：簽名 get_session_tx(uuid) returns jsonb 沒有變，
-- 只是 jsonb 內容多一個 key。用 CREATE OR REPLACE 可保留既有 grant。
-- （硬規則 2 針對的是簽名變更，此處不適用。）
--
-- members.title 已查證為 text NOT NULL（預設「新手上路」），
-- 所以前端不必處理 null。
-- ============================================================

CREATE OR REPLACE FUNCTION public.get_session_tx(p_session_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  return (
    select jsonb_build_object(
      'id', s.id, 'status', s.status, 'mode', s.mode,
      'is_playing', (s.activated_at is not null),
      'table_id', s.table_id, 'table_label', t.label, 'area', t.area,
      'planned_rounds', s.planned_rounds, 'planned_minutes', s.planned_minutes,
      'game_type', s.game_type,
      'flower', s.flower,
      'started_at', s.started_at, 'activated_at', s.activated_at,
      'stake_level_id', s.stake_level_id,
      'stake_label', (select label from stake_levels where id = s.stake_level_id),
      'fee_total', (select coalesce(sum(charged_points),0) from session_players
                     where session_id = s.id and left_at is null),
      'players', (
        select coalesce(jsonb_agg(jsonb_build_object(
          'player_id', sp.id, 'member_id', m.id, 'nickname', m.display_name,
          'rank', m.rank,
          'title', m.title,                     -- ★ 本次唯一新增：座位卡稱號
          'avatar_source', m.avatar_source,
          'avatar_photo_path', m.avatar_photo_path,
          'join_type', sp.join_type, 'seat', sp.seat, 'status', sp.status,
          'charged', sp.charged_points, 'joined_at', sp.joined_at,
          'order_id', sp.order_id,
          'paid_by', sp.paid_by,
          'paid_by_name', (select display_name from members where id = sp.paid_by)
        ) order by sp.joined_at), '[]'::jsonb)
        from session_players sp join members m on m.id = sp.member_id
        where sp.session_id = s.id and sp.left_at is null)
    )
    from table_sessions s
    left join tables t on t.id = s.table_id
    where s.id = p_session_id
  );
end $function$;


-- ============================================================
-- 驗證（單一 SELECT —— SQL Editor 一次跑多個只會顯示最後一個）
-- ------------------------------------------------------------
-- 期待結果：
--   版本數        = 1        （沒有建出多載）
--   定義已含title = true
--   實測稱號      = 某個稱號字串，例如「新手上路」
--
-- 若「實測用場次」是 null，表示目前沒有任何有人入座的 open 場次，
-- 那是沒資料可測、不是失敗 —— 開一桌加個人再跑一次驗證即可。
-- ============================================================
select
  (select count(*)
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'get_session_tx')          as 版本數,

  (select pg_get_functiondef(p.oid) like '%''title'', m.title%'
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'get_session_tx'
    limit 1)                                                             as 定義已含title,

  (select s.id
     from table_sessions s
    where s.status = 'open'
      and exists (select 1 from session_players sp
                   where sp.session_id = s.id and sp.left_at is null)
    order by s.started_at desc
    limit 1)                                                             as 實測用場次,

  (select get_session_tx(s.id) -> 'players' -> 0 ->> 'title'
     from table_sessions s
    where s.status = 'open'
      and exists (select 1 from session_players sp
                   where sp.session_id = s.id and sp.left_at is null)
    order by s.started_at desc
    limit 1)                                                             as 實測第一位玩家稱號,

  (select get_session_tx(s.id) -> 'players' -> 0 ->> 'nickname'
     from table_sessions s
    where s.status = 'open'
      and exists (select 1 from session_players sp
                   where sp.session_id = s.id and sp.left_at is null)
    order by s.started_at desc
    limit 1)                                                             as 實測第一位玩家暱稱;
