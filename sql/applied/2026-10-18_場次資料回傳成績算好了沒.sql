-- 2026-10-18 POS 收桌按鈕：配桌在約定將數打完之前反灰（使用者：「牌局進行中，收桌按鈕要反灰」）
--
-- POS 的桌工作區讀的是 get_session_tx，它沒有回「成績算好了沒」；桌況卡片那個「待收桌」用的是
-- list_tables_tx 的 game_over ＝ public._session_scored(場次)。這一份讓 get_session_tx 回同一個欄位、同一個判斷，
-- 不在 POS 另外算一份。
-- ⚠ 提前結束仍然走收桌（settle_session_tx 只結算打完的將），POS 另外放一顆「提前結束」，後端不用改。
--
-- 簽名不變 ⇒ create or replace，授權（postgres／authenticated／service_role）不受影響。
-- 唯一的改動：回傳多一個 'game_over'，其餘逐字照線上版。

create or replace function public.get_session_tx(p_session_id uuid)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'public'
as $function$
begin
  -- 【身分 2026-09-29】從 API 進來的只有店員能叫（排程沒有 API 身分，照常）
  perform public._api_staff_only();
  return (
    select jsonb_build_object(
      'id', s.id, 'status', s.status, 'mode', s.mode,
      'is_playing', (s.activated_at is not null),
      -- 2026-10-18：成績算好了沒（約定將數打完那一刻自動算），跟桌況的「待收桌」同一個判斷
      'game_over', public._session_scored(s.id),
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
          'title', m.title,
          'avatar_url', m.avatar_url, 'avatar_bear', m.avatar_bear, 'avatar_source', m.avatar_source,
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

-- 驗證（單一 SELECT）
select
  case when (select count(*) from pg_proc where proname = 'get_session_tx' and pronamespace = 'public'::regnamespace) = 1
       then '✅' else '🔴' end || ' ① 版本數 '
    || (select count(*) from pg_proc where proname = 'get_session_tx' and pronamespace = 'public'::regnamespace) as "①",
  case when pg_get_functiondef('public.get_session_tx(uuid)'::regprocedure) ~ '''game_over'',\s*public\._session_scored\(s\.id\)'
       then '✅ ② 回傳多了 game_over' else '🔴 ② 沒有 game_over' end as "②",
  case when pg_get_functiondef('public.get_session_tx(uuid)'::regprocedure) ~ '_api_staff_only'
       then '✅ ③ 仍然只有店員叫得動' else '🔴 ③ 身分檢查不見了' end as "③",
  case when has_function_privilege('authenticated', 'public.get_session_tx(uuid)', 'execute')
        and not has_function_privilege('anon', 'public.get_session_tx(uuid)', 'execute')
       then '✅ ④ 授權不變（authenticated 有、anon 沒有）' else '🔴 ④ 授權變了' end as "④";
