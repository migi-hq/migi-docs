/* ============================================================
   開打時間改用「第一將選完莊家」的那一刻（2026-11-06）
   使用者：「開打時間 改成第一將選莊完的時間」

   ── 為什麼 ─────────────────────────────────────────
   原本開打時間是 activated_at（帶桌），那時客人還在入座、定座位、選莊。
   選完莊家才是真的開始打 ⇒ 改用第 1 將那一列（session_rounds）建立的時間。
   11-06 實測差 2～9 分鐘（A1 凌晨：帶桌 02:44、選完莊 02:47、第一局 02:49）。
   同日已經把「結束」改成最後一局打完（_session_played_until），這份補上另一端。

   ── 改了什麼 ───────────────────────────────────────
   ① 新函式 _session_played_from(場次)：第 1 將的 started_at（沒有就 created_at）；沒用計分板 ⇒ null，退回原本的帶桌時間
      ⚠ 重選位置（tbl_reorder_round_tx）不改這個時間 ⇒ 仍然是第一次選完莊的那一刻
   ② _game_row：開打時間、打了多久的起點
   ③ _member_stats_core：麻將足跡每一場的起點
   ④ pos_list_private_sessions_tx：只改**顯示**的開打時間；列表排序與「這是哪一天」的判斷不動
   ⑤ pos_session_record_tx：開打時間
   五個地方各只換一個片段 ⇒ 撈線上全文做字串取代；找不到或不只一處 ⇒ 整份停下、什麼都不改。
   ============================================================ */

create or replace function public._session_played_from(p_session_id uuid)
returns timestamptz
language sql
stable security definer
set search_path to 'public'
as $function$
  /* 這一場第一將選完莊家的時間（2026-11-06）：第 1 將那一列在選莊送出時建立。沒用計分板 ⇒ null */
  select coalesce(r.started_at, r.created_at)
    from session_rounds r
   where r.session_id = p_session_id and r.round_no = 1
   limit 1
$function$;

revoke execute on function public._session_played_from(uuid) from public;
revoke execute on function public._session_played_from(uuid) from anon, authenticated;
grant  execute on function public._session_played_from(uuid) to service_role;

do $$
declare
  r record;
  v_def text;
  v_n int;
begin
  for r in
    select * from (values
      (1, 'public._game_row(uuid,uuid,uuid)',
          '''started_at'', coalesce(m.activated_at, m.started_at),',
          '''started_at'', coalesce(public._session_played_from(m.id), m.activated_at, m.started_at),'),
      (2, 'public._game_row(uuid,uuid,uuid)',
          '(coalesce(public._session_played_until(m.id), m.ended_at, sp.settled_at) - coalesce(m.activated_at, m.started_at))',
          '(coalesce(public._session_played_until(m.id), m.ended_at, sp.settled_at) - coalesce(public._session_played_from(m.id), m.activated_at, m.started_at))'),
      (3, 'public._member_stats_core(uuid,uuid,timestamptz,timestamptz)',
          '(coalesce(public._session_played_until(m.id), m.ended_at) - coalesce(m.activated_at, m.started_at))',
          '(coalesce(public._session_played_until(m.id), m.ended_at) - coalesce(public._session_played_from(m.id), m.activated_at, m.started_at))'),
      (4, 'public.pos_list_private_sessions_tx(uuid,date)',
          '''started_at'', coalesce(ts.activated_at, ts.created_at), ''ended_at''',
          '''started_at'', coalesce(public._session_played_from(ts.id), ts.activated_at, ts.created_at), ''ended_at'''),
      (5, 'public.pos_session_record_tx(uuid)',
          '''started_at'', coalesce(s.activated_at, s.started_at), ''ended_at''',
          '''started_at'', coalesce(public._session_played_from(s.id), s.activated_at, s.started_at), ''ended_at''')
    ) t(ord, fn, old_frag, new_frag)
    order by ord
  loop
    -- 每一次都重撈全文：同一支函式改兩處時，第二處要在第一處改完的版本上找
    v_def := pg_get_functiondef(r.fn::regprocedure);
    v_n := (length(v_def) - length(replace(v_def, r.old_frag, ''))) / length(r.old_frag);
    if v_n <> 1 then
      raise exception '第 % 處（%）的片段找到 % 處（應該是 1），整份停下', r.ord, r.fn, v_n;
    end if;
    execute replace(v_def, r.old_frag, r.new_frag);
  end loop;
end $$;

/* ── 驗證（單一 SELECT，不用 raise）──────────────────────
   ① 新函式在、前端叫不到
   ② 11-06 A1 凌晨那一場（帶桌 02:44、選完莊 02:47、最後一局 07:35）：
      會員 App 開打 02:47、打了 07:35 − 02:47 分鐘；POS 牌局紀錄開打 02:47
   ③ 正對照：沒用計分板的已收桌場次，開打時間退回帶桌時間
   ④ 麻將足跡：那一場其中一位的累積分鐘，跟逐場自己算一次相同
   ⑤ POS 包桌列表：最近一場有選莊的包桌，列表上的開打時間 ＝ 選完莊的時間（找不到樣本印 ⚪）
   ⑥ 四支舊函式的授權沒變 */
with a1 as (
  select s.id, s.org_id, s.activated_at,
         (select sp.member_id from session_players sp where sp.session_id = s.id order by sp.seat limit 1) as mem,
         public._session_played_from(s.id) as from_at, public._session_played_until(s.id) as until_at
    from table_sessions s where s.id = '1fcb201f-92ed-460a-b727-11afe1b2554e'
), g as (
  select a1.*, public._game_row(a1.org_id, a1.id, a1.mem) as j,
         public.pos_session_record_tx(a1.id) as pj
    from a1
), nohand as (
  select s.id, s.org_id, coalesce(s.activated_at, s.started_at) as want, sp.member_id
    from table_sessions s join session_players sp on sp.session_id = s.id
   where s.status = 'completed' and s.deleted_at is null
     and not exists (select 1 from session_rounds r where r.session_id = s.id)
   order by s.ended_at desc nulls last limit 1
), foot as (
  select (public._member_stats_core(g.org_id, g.mem) -> 'all' ->> 'minutes')::int as got,
         (select coalesce(sum(greatest(0, extract(epoch from
                   (coalesce(public._session_played_until(s.id), s.ended_at)
                    - coalesce(public._session_played_from(s.id), s.activated_at, s.started_at))) / 60)), 0)::int
            from session_players sp join table_sessions s on s.id = sp.session_id
           where sp.member_id = g.mem and sp.org_id = g.org_id and s.org_id = g.org_id and s.deleted_at is null
             and (s.status = 'completed' or sp.finish_rank is not null) and s.mode <> 'friendly'
             and sp.hidden_from_history_at is null
             and s.ended_at is not null and coalesce(s.activated_at, s.started_at) is not null) as want
    from g
), pv as (
  select s.id, s.store_id, public._session_played_from(s.id) as want,
         (coalesce(s.activated_at, s.created_at) at time zone 'Asia/Taipei')::date as day
    from table_sessions s
   where s.mode = 'private' and s.deleted_at is null and public._session_played_from(s.id) is not null
   order by s.created_at desc limit 1
)
select string_agg(line, E'\n' order by ord) as "驗證"
from (
  select 1 as ord,
         case when exists (select 1 from pg_proc where proname = '_session_played_from' and pronamespace = 'public'::regnamespace)
               and not has_function_privilege('authenticated', 'public._session_played_from(uuid)', 'execute')
               and not has_function_privilege('anon', 'public._session_played_from(uuid)', 'execute')
              then '✅ ① 新函式在，前端叫不到'
              else '🔴 ① 新函式不在，或前端叫得到' end as line
  union all
  select 2, coalesce((select
         case when (j ->> 'started_at')::timestamptz = from_at
               and (j ->> 'duration_minutes')::int = greatest(0, (extract(epoch from (until_at - from_at)) / 60)::int)
               and (pj -> 'session' ->> 'started_at')::timestamptz = from_at
              then '✅ ② A1：開打 ' || to_char(from_at at time zone 'Asia/Taipei', 'HH24:MI')
                   || '（帶桌 ' || to_char(activated_at at time zone 'Asia/Taipei', 'HH24:MI') || '）、打了 '
                   || (j ->> 'duration_minutes') || ' 分鐘；POS 牌局紀錄也是 '
                   || to_char((pj -> 'session' ->> 'started_at')::timestamptz at time zone 'Asia/Taipei', 'HH24:MI')
              else '🔴 ② A1：App 開打 ' || coalesce(j ->> 'started_at', 'null') || ' 分鐘 ' || coalesce(j ->> 'duration_minutes', 'null')
                   || '　POS 開打 ' || coalesce(pj -> 'session' ->> 'started_at', 'null') end
         from g), '🔴 ② 找不到 A1 那一場')
  union all
  select 3, coalesce((select
         case when (public._game_row(n.org_id, n.id, n.member_id) ->> 'started_at')::timestamptz = n.want
              then '✅ ③ 沒用計分板的場次退回帶桌時間'
              else '🔴 ③ 沒用計分板的場次開打回 ' || coalesce(public._game_row(n.org_id, n.id, n.member_id) ->> 'started_at', 'null') end
         from nohand n), '⚪ ③ 找不到沒用計分板的已收桌場次，這一格測不了')
  union all
  select 4, coalesce((select
         case when got = want then '✅ ④ 麻將足跡 ' || got || ' 分鐘，跟逐場自己算的一樣'
              else '🔴 ④ 麻將足跡 ' || coalesce(got::text, 'null') || ' 分鐘，逐場算是 ' || want end
         from foot), '🔴 ④ 算不出來')
  union all
  select 5, coalesce((select
         case when (select (e ->> 'started_at')::timestamptz
                      from jsonb_array_elements(public.pos_list_private_sessions_tx(pv.store_id, pv.day) -> 'list') e
                     where (e ->> 'session_id')::uuid = pv.id) = pv.want
              then '✅ ⑤ POS 包桌列表的開打時間 ＝ 選完莊（' || to_char(pv.want at time zone 'Asia/Taipei', 'MM-DD HH24:MI') || '）'
              else '🔴 ⑤ POS 包桌列表：' || left(public.pos_list_private_sessions_tx(pv.store_id, pv.day)::text, 200) end
         from pv), '⚪ ⑤ 找不到有選莊的包桌，這一格測不了')
  union all
  select 6,
         case when (select string_agg(proacl::text, ' | ' order by proname) from pg_proc
                     where pronamespace = 'public'::regnamespace
                       and proname in ('_game_row', '_member_stats_core', 'pos_list_private_sessions_tx', 'pos_session_record_tx'))
                   = '{postgres=X/postgres,service_role=X/postgres} | {postgres=X/postgres,service_role=X/postgres}'
                     || ' | {postgres=X/postgres,service_role=X/postgres,authenticated=X/postgres}'
                     || ' | {postgres=X/postgres,service_role=X/postgres,authenticated=X/postgres}'
              then '✅ ⑥ 四支舊函式的授權沒變'
              else '🔴 ⑥ 授權變了' end
) t;
