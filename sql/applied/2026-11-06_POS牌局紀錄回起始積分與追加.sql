/* ============================================================
   POS 牌局紀錄：名次表比照計分板「牌局結束」卡（2026-11-06）
   使用者：「要比照結算，有目前積分與 +- 分」

   計分板結算卡每家寫「積分 2,200　+220」：
     積分 ＝ 級距的起始積分 ＋ 爆卡追加的積分 ＋ 這一場的得失（migi-table App.jsx 的 balanceOf）
     +220 ＝ 這一場的得失（final_score）
   POS 原本只有得失，少了前兩樣 ⇒ 這支多回：
     session.start_points   級距的起始積分（純娛樂或沒設是 null）
     players[].extra        這一家爆卡時選擇追加的積分合計（跟計分板 _tbl_state_for_device 的 extras 同一個算法）

   簽名不變 ⇒ CREATE OR REPLACE，授權不會掉（硬規則 2）。
   順手更正一段過期的註解：2026-11-06 起沒打完那一將的分數**有**算進桌上積分，只是不算段位分。
   ============================================================ */

create or replace function public.pos_session_record_tx(p_session_id uuid)
returns jsonb
language plpgsql
stable security definer
set search_path to 'public'
as $function$
declare
  v_org uuid;
  s     record;
begin
  /* 從 API 進來（前端）⇒ 一定要是店員（_api_staff_only），而且只看自己機構的場次。
     沒有 API 身分（SQL Editor、排程、別的函式在內部叫）⇒ _api_staff_only 放行，v_org 是 null ⇒ 不限機構。
     ⚠ 不可以「查不到店員就 raise」—— 那會讓驗證段在 SQL Editor 裡拋錯、整份回滾（硬規則 1.8） */
  perform public._api_staff_only();
  v_org := public.current_org_id();   -- ⚠ current_staff() 沒有回 org_id（staff_id／member_id／store_id／role／name），第一版寫錯過

  select ts.*, t.label as table_label, sl.label as stake_label, coalesce(sl.is_hygiene, false) as hygiene,
         sl.start_points
    into s
    from table_sessions ts
    left join tables t on t.id = ts.table_id
    left join stake_levels sl on sl.id = ts.stake_level_id
   where ts.id = p_session_id and (v_org is null or ts.org_id = v_org) and ts.deleted_at is null;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'not_found', 'message', '找不到這一場');
  end if;

  return jsonb_build_object('ok', true,
    'session', jsonb_build_object(
      'table_label', s.table_label, 'mode', s.mode, 'game_type', s.game_type, 'flower', s.flower,
      'planned_rounds', s.planned_rounds, 'stake_label', s.stake_label, 'hygiene', s.hygiene,
      /* 🆕 2026-11-06：級距的起始積分（名次表「積分」＝ 起始 ＋ 追加 ＋ 得失，同計分板結算卡） */
      'start_points', s.start_points,
      'started_at', coalesce(s.activated_at, s.started_at), 'ended_at', s.ended_at, 'status', s.status),
    'players', coalesce((
      select jsonb_agg(jsonb_build_object(
               'seat', sp.seat, 'name', m.display_name, 'rank', sp.finish_rank,
               'final_score', sp.final_score, 'rating_delta', sp.score_points, 'rating_after', sp.rating_after,
               /* 🆕 2026-11-06：爆卡時選擇追加的積分合計（同 _tbl_state_for_device 的 extras） */
               'extra', coalesce((select sum(b.added_points) from session_busts b
                                   where b.session_id = p_session_id and b.seat = sp.seat
                                     and b.decision = 'added'), 0))
             order by sp.seat nulls last, sp.joined_at)
        from session_players sp join members m on m.id = sp.member_id
       where sp.session_id = p_session_id), '[]'::jsonb),
    'hands', public._session_hands(p_session_id),
    /* 沒打完的將：桌上積分照算（2026-11-06 起），段位分只算打完的將 ⇒ 畫面標「沒打完，不算段位分」 */
    'unfinished_rounds', coalesce((
      select jsonb_agg(r.round_no order by r.round_no) from session_rounds r
       where r.session_id = p_session_id and r.status <> 'finished'), '[]'::jsonb));
end $function$;

/* ── 驗證（單一 SELECT，不用 raise）──────────────────────
   ① 起始積分：最近一場有級距的已收桌場次，回的 start_points 等於它級距的起始積分
   ② 正對照：d7f35e03 那一場 2 號位爆卡追加過 1000 ⇒ extra = 1000；其他座位是 0
   ③ 授權沒變（postgres、service_role、authenticated） */
with r1 as (
  select ts.id, sl.start_points as want, public.pos_session_record_tx(ts.id) as j
    from table_sessions ts join stake_levels sl on sl.id = ts.stake_level_id
   where ts.status = 'completed' and ts.deleted_at is null and sl.start_points is not null
   order by ts.ended_at desc limit 1
), r2 as (
  select public.pos_session_record_tx('d7f35e03-93f0-4040-8e03-f0fb2ec0958e') as j
)
select string_agg(line, E'\n' order by ord) as "驗證"
from (
  select 1 as ord, coalesce((select
         case when (j -> 'session' ->> 'start_points')::int = want
              then '✅ ① 起始積分 ' || want || '（跟級距一樣）'
              else '🔴 ① 起始積分回 ' || coalesce(j -> 'session' ->> 'start_points', 'null') || '，級距是 ' || want end
         from r1), '⚪ ① 找不到有起始積分的場次') as line
  union all
  select 2, (select
         case when (select (p ->> 'extra')::int from jsonb_array_elements(j -> 'players') p where (p ->> 'seat')::int = 2) = 1000
               and (select coalesce(sum((p ->> 'extra')::int), 0) from jsonb_array_elements(j -> 'players') p where (p ->> 'seat')::int <> 2) = 0
              then '✅ ② 爆卡追加：2 號位 1000、其他座位 0'
              else '🔴 ② 追加不對：' || coalesce((select string_agg((p ->> 'seat') || '號 ' || coalesce(p ->> 'extra', 'null'), '、') from jsonb_array_elements(j -> 'players') p), '沒有玩家') end
         from r2)
  union all
  select 3, case when (select proacl::text from pg_proc where proname = 'pos_session_record_tx' and pronamespace = 'public'::regnamespace)
                      = '{postgres=X/postgres,service_role=X/postgres,authenticated=X/postgres}'
                 then '✅ ③ 授權沒變' else '🔴 ③ 授權變了' end
) t;
