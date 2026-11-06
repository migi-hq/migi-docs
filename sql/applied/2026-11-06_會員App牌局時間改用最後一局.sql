/* ============================================================
   會員 App 的牌局時間改用「最後一局打完」（2026-11-06）
   使用者：「客人的 APP 顯示也是尾將結束時間嗎？」→「都改」

   ── 為什麼 ─────────────────────────────────────────
   收桌常常晚好幾個小時（11-06 A1：02:44 開打、07:35 最後一局、10:33 才收桌），
   而會員 App 三個地方用的是收桌時間：
     · 牌局詳情的「開打–結束」
     · 牌局詳情的「打了多久」
     · 個人頁麻將足跡的累積時數
   POS 的牌局紀錄同日已經改成最後一局（migi-pos SessionRecord.jsx），這份讓會員 App 跟它一致。

   ── 改了什麼 ───────────────────────────────────────
   ① 新函式 _session_played_until(場次)：這一場最後一局打完的時間
      條件跟 _session_hands 一樣（status = confirmed、沒撤銷，時間取 confirmed_at，沒有才用 created_at）
      沒有用計分板記分 ⇒ null，呼叫的地方自己退回收桌時間
      前端叫不到（預設全關，只給內部呼叫）
   ② _game_row：多回 played_until；duration_minutes 改用它算
      ⚠ ended_at **不改** —— 走勢圖與排序在用它
      ⚠ 還沒收桌也還沒結算（正在打）⇒ played_until 照舊是 null，畫面不會在打的時候先印結束時間
   ③ _member_stats_core：麻將足跡的累積分鐘改用最後一局；「要收了桌才算」的條件不變
   ⚠ 營運報表的佔桌時間**不改**：那一份要的是桌子被佔了多久，收桌時間才是對的

   ── 做法 ───────────────────────────────────────────
   兩支各只改一個片段，所以撈線上全文做字串取代再執行（不重貼全文，免得抄錯其他地方）。
   找不到片段、或找到不只一處 ⇒ 整份停下、什麼都不改。
   ============================================================ */

create or replace function public._session_played_until(p_session_id uuid)
returns timestamptz
language sql
stable security definer
set search_path to 'public'
as $function$
  /* 這一場最後一局打完的時間（2026-11-06）。條件同 _session_hands：已確認、沒撤銷。
     咔啦碰、分紅也算（它們也是牌桌上發生的事，時間一樣真）。沒有記分 ⇒ null */
  select max(coalesce(h.confirmed_at, h.created_at))
    from hands h
   where h.session_id = p_session_id
     and h.status = 'confirmed'
     and h.undone_at is null
$function$;

revoke execute on function public._session_played_until(uuid) from public;
revoke execute on function public._session_played_until(uuid) from anon, authenticated;
grant  execute on function public._session_played_until(uuid) to service_role;

do $$
declare
  v_def text;
  v_old text;
  v_new text;
  v_n   int;
begin
  /* ── ② _game_row ── */
  v_def := pg_get_functiondef('public._game_row(uuid,uuid,uuid)'::regprocedure);

  -- (a) 打了多久：結束那一端換成最後一局
  v_old := '(coalesce(m.ended_at, sp.settled_at) - coalesce(m.activated_at, m.started_at))';
  v_n := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_n <> 1 then raise exception '_game_row 打了多久的片段找到 % 處（應該是 1），整份停下', v_n; end if;
  v_new := replace(v_def, v_old,
    '(coalesce(public._session_played_until(m.id), m.ended_at, sp.settled_at) - coalesce(m.activated_at, m.started_at))');

  -- (b) 多回一個 played_until，插在 my_rank 前面
  v_old := '''my_rank'',           sp.finish_rank,';
  v_n := (length(v_new) - length(replace(v_new, v_old, ''))) / length(v_old);
  if v_n <> 1 then raise exception '_game_row 的 my_rank 那一行找到 % 處（應該是 1），整份停下', v_n; end if;
  v_new := replace(v_new, v_old,
    '/* 🆕 2026-11-06：最後一局打完的時間（畫面的「結束」與「打了多久」用它）。'
    || chr(10) || '       沒用計分板記分就退回收桌時間；還在打（沒收桌也沒結算）是 null */'
    || chr(10) || '    ''played_until'', case when coalesce(m.ended_at, sp.settled_at) is not null'
    || chr(10) || '                           then coalesce(public._session_played_until(m.id), m.ended_at, sp.settled_at) end,'
    || chr(10) || '    ' || v_old);

  execute v_new;

  /* ── ③ _member_stats_core ── */
  v_def := pg_get_functiondef('public._member_stats_core(uuid,uuid,timestamptz,timestamptz)'::regprocedure);
  v_old := '(m.ended_at - coalesce(m.activated_at, m.started_at))';
  v_n := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_n <> 1 then raise exception '_member_stats_core 麻將足跡的片段找到 % 處（應該是 1），整份停下', v_n; end if;
  v_new := replace(v_def, v_old,
    '(coalesce(public._session_played_until(m.id), m.ended_at) - coalesce(m.activated_at, m.started_at))');

  execute v_new;
end $$;

/* ── 驗證（單一 SELECT，不用 raise）──────────────────────
   ① 新函式在、前端叫不到
   ② 11-06 A1 那一場（02:44 開打、07:35 最後一局、10:33 收桌）：
      played_until ＝ 最後一局、ended_at 還是收桌、打了多久 ＝ 開打到最後一局
   ③ 正對照：一場有收桌、卻沒用計分板記分的 ⇒ played_until 退回收桌時間
   ④ 麻將足跡：那一場其中一位的累積分鐘，跟「逐場自己算一次」相同
   ⑤ 兩支舊函式的授權沒變（仍然只有 postgres、service_role） */
with a1 as (
  select s.id, s.org_id,
         (select sp.member_id from session_players sp where sp.session_id = s.id order by sp.seat limit 1) as mem,
         coalesce(s.activated_at, s.started_at) as st, s.ended_at
    from table_sessions s where s.id = '1fcb201f-92ed-460a-b727-11afe1b2554e'
), g as (
  select a1.*, public._game_row(a1.org_id, a1.id, a1.mem) as j,
         public._session_played_until(a1.id) as last_at
    from a1
), nohand as (
  select s.id, s.org_id, s.ended_at, sp.member_id
    from table_sessions s join session_players sp on sp.session_id = s.id
   where s.status = 'completed' and s.ended_at is not null and s.deleted_at is null
     and not exists (select 1 from hands h where h.session_id = s.id)
   order by s.ended_at desc limit 1
), foot as (
  select g.mem, g.org_id,
         (public._member_stats_core(g.org_id, g.mem) -> 'all' ->> 'minutes')::int as got,
         (select coalesce(sum(greatest(0, extract(epoch from
                   (coalesce(public._session_played_until(s.id), s.ended_at) - coalesce(s.activated_at, s.started_at))) / 60)), 0)::int
            from session_players sp join table_sessions s on s.id = sp.session_id
           where sp.member_id = g.mem and sp.org_id = g.org_id and s.org_id = g.org_id and s.deleted_at is null
             and (s.status = 'completed' or sp.finish_rank is not null) and s.mode <> 'friendly'
             and sp.hidden_from_history_at is null
             and s.ended_at is not null and coalesce(s.activated_at, s.started_at) is not null) as want
    from g
)
select string_agg(line, E'\n' order by ord) as "驗證"
from (
  select 1 as ord,
         case when exists (select 1 from pg_proc where proname = '_session_played_until' and pronamespace = 'public'::regnamespace)
               and not has_function_privilege('authenticated', 'public._session_played_until(uuid)', 'execute')
               and not has_function_privilege('anon', 'public._session_played_until(uuid)', 'execute')
              then '✅ ① 新函式在，前端叫不到'
              else '🔴 ① 新函式不在，或前端叫得到' end as line
  union all
  select 2, coalesce((select
         case when (j ->> 'played_until')::timestamptz = last_at
               and (j ->> 'ended_at')::timestamptz = ended_at
               and (j ->> 'duration_minutes')::int = greatest(0, (extract(epoch from (last_at - st)) / 60)::int)
              then '✅ ② A1：結束 ' || to_char(last_at at time zone 'Asia/Taipei', 'HH24:MI')
                   || '（收桌 ' || to_char(ended_at at time zone 'Asia/Taipei', 'HH24:MI') || ' 沒動）、打了 '
                   || (j ->> 'duration_minutes') || ' 分鐘'
              else '🔴 ② A1：played_until=' || coalesce(j ->> 'played_until', 'null')
                   || ' ended_at=' || coalesce(j ->> 'ended_at', 'null')
                   || ' 分鐘=' || coalesce(j ->> 'duration_minutes', 'null') end
         from g), '🔴 ② 找不到 A1 那一場')
  union all
  select 3, coalesce((select
         case when (public._game_row(n.org_id, n.id, n.member_id) ->> 'played_until')::timestamptz = n.ended_at
              then '✅ ③ 沒用計分板的場次退回收桌時間'
              else '🔴 ③ 沒用計分板的場次 played_until=' || coalesce(public._game_row(n.org_id, n.id, n.member_id) ->> 'played_until', 'null') end
         from nohand n), '⚪ ③ 找不到沒用計分板的已收桌場次，這一格測不了')
  union all
  select 4, coalesce((select
         case when got = want then '✅ ④ 麻將足跡 ' || got || ' 分鐘，跟逐場自己算的一樣'
              else '🔴 ④ 麻將足跡 ' || coalesce(got::text, 'null') || ' 分鐘，逐場算是 ' || want end
         from foot), '🔴 ④ 算不出來')
  union all
  select 5,
         case when (select string_agg(proacl::text, ' | ' order by proname) from pg_proc
                     where pronamespace = 'public'::regnamespace and proname in ('_game_row', '_member_stats_core'))
                   = '{postgres=X/postgres,service_role=X/postgres} | {postgres=X/postgres,service_role=X/postgres}'
              then '✅ ⑤ 兩支舊函式的授權沒變'
              else '🔴 ⑤ 授權變了' end
) t;
