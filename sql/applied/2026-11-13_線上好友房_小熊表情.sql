/* ============================================================
   線上好友房：小熊表情（2026-11-13 使用者：「小熊的表情貼圖 做」）
   📄 規格：docs/03-會員App與社交/線上好友房.md

   做法跟「電腦代打」同一條路：記在座位上（online_seats），_online_ctx 的 presence 帶回去，
   _tbl_ping 通知四支手機重讀 ⇒ 另外三家在那一家名牌下面冒泡泡、3D 小熊做動作。

   · 表情只記「最後一個」與送出時間（emote／emote_at），不留歷史 —— 它是一瞬間的東西，不是紀錄
   · 同一個座位 2 秒內只能送一次（擋洗版）：太快回 too_fast，不寫入
   · 代碼只檢查格式；哪幾個代碼合法由 Edge Function（core.mjs 的 EMOTES）把關，句子寫在 App 那一層
   · 座位要真的有人坐著（同 online_set_auto_tx）

   一、online_seats 加兩欄
   二、online_emote_tx（只給 service_role，Edge Function 用）
   三、_online_ctx：presence 多帶 emote／emote_at（其餘逐字照線上 2026-11-13 撈出來的版本）
   ============================================================ */

alter table public.online_seats add column if not exists emote text;
alter table public.online_seats add column if not exists emote_at timestamptz;

create or replace function public.online_emote_tx(p_session uuid, p_seat smallint, p_code text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare s table_sessions; v_last timestamptz;
begin
  select * into s from table_sessions where id = p_session;
  if s.id is null or s.mode <> 'friendly'
     or not exists (select 1 from friendly_games g where g.session_id = s.id and g.play_mode = 'online') then
    return jsonb_build_object('ok', false, 'reason', 'not_online');
  end if;
  if p_seat is null or not exists (select 1 from session_players sp where sp.session_id = s.id and sp.seat = p_seat and sp.left_at is null) then
    return jsonb_build_object('ok', false, 'reason', 'bad_seat');
  end if;
  if p_code is null or p_code !~ '^[a-z]{2,16}$' then
    return jsonb_build_object('ok', false, 'reason', 'bad_emote');
  end if;
  select emote_at into v_last from online_seats where session_id = s.id and seat = p_seat;
  if v_last is not null and v_last > now() - interval '2 seconds' then
    return jsonb_build_object('ok', false, 'reason', 'too_fast');
  end if;
  insert into online_seats (session_id, seat, org_id, emote, emote_at)
  values (s.id, p_seat, s.org_id, p_code, now())
  on conflict (session_id, seat) do update set emote = excluded.emote, emote_at = excluded.emote_at;
  perform public._tbl_ping(s.id);      -- 通知四支手機重讀，別家才會馬上冒泡泡
  return jsonb_build_object('ok', true, 'emote', p_code);
end $function$;

-- 預設權限是全關（硬規則 2.7）；只給 Edge Function 用的 service_role
grant execute on function public.online_emote_tx(uuid, smallint, text) to service_role;

CREATE OR REPLACE FUNCTION public._online_ctx(p_session uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare s table_sessions; g friendly_games; sl stake_levels; r session_rounds; h online_hands; v_rs jsonb;
begin
  select * into s from table_sessions where id = p_session;
  if s.id is null or s.mode <> 'friendly' then
    return jsonb_build_object('ok', false, 'reason', 'no_session');
  end if;
  select * into g from friendly_games where session_id = s.id;
  if g.id is null or g.play_mode <> 'online' then
    return jsonb_build_object('ok', false, 'reason', 'not_online');
  end if;
  select * into sl from stake_levels where id = s.stake_level_id;
  select * into r from session_rounds where session_id = s.id and status <> 'voided' order by round_no desc limit 1;
  if r.id is not null then v_rs := public._tbl_round_state(r.id); end if;
  select * into h from online_hands where session_id = s.id order by created_at desc, hand_no desc limit 1;
  return jsonb_build_object(
    'ok', true,
    'session', jsonb_build_object('id', s.id, 'org_id', s.org_id, 'status', s.status, 'flower', (s.flower = '有花'),
                                  'planned_rounds', coalesce(s.planned_rounds, 1), 'base', coalesce(sl.base, 0), 'unit', coalesce(sl.tai, 0),
                                  'stake_label', sl.label, 'is_hygiene', coalesce(sl.is_hygiene, false), 'channel', s.score_channel,
                                  -- 牌桌右下角那一行（玩法、使用時間）要用的：這一場什麼玩法、幾點開始的
                                  'game_type', s.game_type, 'started_at', s.started_at,
                                  -- 這一場開了哪幾個特殊規則（全紅／骰龜／豹子）。牌桌後端照它算台；空的 ＝ 都不算
                                  'special_rules', to_jsonb(g.special_rules)),
    'game', jsonb_build_object('id', g.id, 'status', g.status),
    'scored', public._session_scored(s.id),
    'rounds_done', (select count(*) from session_rounds where session_id = s.id and status = 'finished'),
    'round', case when r.id is null then null else jsonb_build_object(
               'id', r.id, 'round_no', r.round_no, 'status', r.status,
               'ring', to_jsonb(coalesce(r.seat_ring, '{1,2,3,4}'::smallint[])), 'state', v_rs) end,
    'hand', case when h.id is null then null else jsonb_build_object(
               'id', h.id, 'round_id', h.round_id, 'hand_no', h.hand_no, 'version', h.version, 'status', h.status, 'phase', h.phase,
               'deadline_at', h.deadline_at, 'dealer_seat', h.dealer_seat, 'renzhuang', h.renzhuang,
               'dice', to_jsonb(h.dice), 'seat_dice', to_jsonb(h.seat_dice), 'state', h.state,
               'started_at', h.started_at, 'ended_at', h.ended_at,
               -- 實際入帳的增減（爆卡時只付得出剩下的 ⇒ 可能比引擎算的少）
               'applied', (select hh.score_delta from hands hh where hh.id = h.hand_id)) end,
    'players', (select coalesce(jsonb_agg(jsonb_build_object(
                         'seat', sp.seat, 'member_id', m.id, 'nickname', m.display_name, 'rank', m.rank, 'title', m.title,
                         'avatar_url', m.avatar_url, 'avatar_source', m.avatar_source,
                         'avatar_photo_path', m.avatar_photo_path, 'avatar_bear', m.avatar_bear,
                         -- 這個人養的小熊現在穿什麼（牌桌上對家、上家、下家那三隻照著穿）
                         'outfit', public._member_outfit(m.id),
                         -- 🆕 電腦對手：牌桌後端替它出牌（等同一直開著電腦代打）、爆卡時替它決定
                         'is_bot', m.is_bot,
                         'finish_rank', sp.finish_rank, 'final_score', sp.final_score) order by sp.seat nulls last, sp.joined_at), '[]'::jsonb)
                  from session_players sp join members m on m.id = sp.member_id
                 where sp.session_id = s.id and sp.left_at is null),
    'balances', public._tbl_balances(s.id),
    'bust', (select jsonb_build_object('seat', b.seat) from session_busts b
              where b.session_id = s.id and b.decision = 'pending' order by b.seat limit 1),
    'cat', (select coalesce(jsonb_agg(jsonb_build_object(
                     'code', p.code, 'label', p.label, 'tai', p.tai, 'max_count', p.max_count,
                     'conflicts', to_jsonb(coalesce(p.conflicts, '{}'::text[])),
                     'flower_conflicts', to_jsonb(coalesce(p.flower_conflicts, '{}'::text[]))) order by p.sort), '[]'::jsonb)
              from scoring_patterns p where p.is_active),
    -- auto_since ＝ 逾時後由後端代打；auto_on ＝ 他自己開了「電腦代打」。畫面上兩種都標「某某 電腦代打中」
    -- 🆕 2026-11-13 emote／emote_at ＝ 這一家最後送的小熊表情與時間（畫面只演最近幾秒內的）
    'presence', (select coalesce(jsonb_object_agg(o.seat::text, jsonb_build_object('last_seen_at', o.last_seen_at, 'auto_since', o.auto_since, 'auto_on', o.auto_on,
                                                                                  'emote', o.emote, 'emote_at', o.emote_at)), '{}'::jsonb)
                   from online_seats o where o.session_id = s.id));
end $function$;

/* ── 驗證（硬規則 1.8：不用 raise，結果放 set_config，最後一支 SELECT 讀回來）── */
do $$
declare v_msg text := ''; v_ok int := 0; v_all int := 6; v_oid oid;
begin
  -- ① 兩欄都加上了
  if (select count(*) from information_schema.columns where table_schema = 'public' and table_name = 'online_seats' and column_name in ('emote', 'emote_at')) = 2
    then v_ok := v_ok + 1; v_msg := v_msg || E'\n✅ ① online_seats 有 emote、emote_at';
    else v_msg := v_msg || E'\n🔴 ① online_seats 少了 emote／emote_at'; end if;

  select oid into v_oid from pg_proc where pronamespace = 'public'::regnamespace and proname = 'online_emote_tx';
  -- ② 新函式在、是 DEFINER、只有一個版本
  if v_oid is not null and (select prosecdef from pg_proc where oid = v_oid)
     and (select count(*) from pg_proc where pronamespace = 'public'::regnamespace and proname = 'online_emote_tx') = 1
    then v_ok := v_ok + 1; v_msg := v_msg || E'\n✅ ② online_emote_tx 在、DEFINER、一個版本';
    else v_msg := v_msg || E'\n🔴 ② online_emote_tx 不在、不是 DEFINER、或有多載'; end if;

  -- ③ 只有 service_role 叫得動（明確授權 ＋ PUBLIC 兩個方向都看，硬規則 2.6）
  if v_oid is not null
     and exists (select 1 from aclexplode((select proacl from pg_proc where oid = v_oid)) a where a.grantee = 'service_role'::regrole::oid and a.privilege_type = 'EXECUTE')
     and not has_function_privilege('anon', v_oid, 'EXECUTE') and not has_function_privilege('authenticated', v_oid, 'EXECUTE')
    then v_ok := v_ok + 1; v_msg := v_msg || E'\n✅ ③ online_emote_tx 只有 service_role 叫得動';
    else v_msg := v_msg || E'\n🔴 ③ online_emote_tx 的權限不對（前端叫得動，或 service_role 叫不動）'; end if;

  -- ④ _online_ctx 的 presence 帶了 emote_at（看「拿來組回傳」的那一段，不看註解：註解那一行是 emote／emote_at 用全形斜線寫的）
  if pg_get_functiondef('public._online_ctx(uuid)'::regprocedure) ~ '''emote_at'', o\.emote_at'
    then v_ok := v_ok + 1; v_msg := v_msg || E'\n✅ ④ _online_ctx 的 presence 帶 emote_at';
    else v_msg := v_msg || E'\n🔴 ④ _online_ctx 沒帶 emote_at'; end if;

  -- ⑤ _online_ctx 只有一個版本，權限沒變（CREATE OR REPLACE 不會丟授權；照樣只有 service_role）
  if (select count(*) from pg_proc where pronamespace = 'public'::regnamespace and proname = '_online_ctx') = 1
     and has_function_privilege('service_role', 'public._online_ctx(uuid)'::regprocedure, 'EXECUTE')
     and not has_function_privilege('anon', 'public._online_ctx(uuid)'::regprocedure, 'EXECUTE')
    then v_ok := v_ok + 1; v_msg := v_msg || E'\n✅ ⑤ _online_ctx 一個版本、權限照舊';
    else v_msg := v_msg || E'\n🔴 ⑤ _online_ctx 版本或權限不對'; end if;

  -- ⑥ _online_ctx 其他鍵沒被改壞（隨便挑一場線上牌局叫一次，回傳要有 presence 與 players）
  if exists (select 1 from friendly_games g where g.play_mode = 'online') then
    if (select public._online_ctx(g.session_id) ? 'presence' and public._online_ctx(g.session_id) ? 'players'
          from friendly_games g where g.play_mode = 'online' order by g.created_at desc limit 1)
      then v_ok := v_ok + 1; v_msg := v_msg || E'\n✅ ⑥ _online_ctx 叫得動，presence、players 都在';
      else v_msg := v_msg || E'\n🔴 ⑥ _online_ctx 回傳少了 presence 或 players'; end if;
  else v_msg := v_msg || E'\n⚪ ⑥ 沒有線上牌局可以叫（這一格測不了）'; end if;

  perform set_config('migi.emote', v_ok || ' / ' || v_all || v_msg, true);
end $$;
select coalesce(nullif(current_setting('migi.emote', true), ''), '🔴 沒有訊息') as "驗證";
