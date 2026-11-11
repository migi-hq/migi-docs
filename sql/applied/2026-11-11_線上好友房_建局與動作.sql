-- ════════════════════════════════════════════════════════════════════
-- 線上好友房 · 第 ② 批：建局、每個動作寫回、打完一局接上計分板（2026-11-11）
-- 規格：docs/03-會員App與社交/線上好友房.md　前一批：sql/applied/2026-11-11_線上好友房_資料表.sql
--
-- 牌局規則只有一份、在後端的 JS（supabase/functions/online-game/engine.mjs），資料庫不算牌。
-- 分工：
--   Edge Function online-game   認人（叫 online_me_tx）→ 讀整包（_online_ctx）→ 跑引擎 → 寫回（下面這幾支）
--   資料庫                       管「誰可以寫、寫的時候狀態對不對」＋ 打完一局寫進 hands（之後全部沿用計分板）
--
-- 這一批建的函式：
--   online_me_tx()              前端可以叫：我現在在哪一場線上牌局、坐幾號。身分只認 current_member_id()
--   _online_ctx(session)        只給後端：這一場的整包資料（含四家手牌與牌山 —— 🔴 絕對不能開給前端）
--   online_start_round_tx(...)  只給後端：開一將 ＝ 排座位號（第一將）＋ 照兩擲骰子定莊家與順序 ＋ 第一局
--   online_next_hand_tx(...)    只給後端：同一將的下一局（莊家、連莊、局號要跟計分板算出來的一樣）
--   online_commit_tx(...)       只給後端：寫回一個動作（比對版本）；這一局打完 ⇒ 寫一筆 hands（走計分板同一條路：
--                               先 pending 再 confirmed ⇒ 爆卡時只付得出剩下的、爆卡偵測、碎片、將打完自動結算都照舊）
--   online_bust_decide_tx(...)  只給後端：爆卡的人決定追加或結束（同計分板 tbl_bust_decide_tx，差別只在不靠裝置認人）
--
-- 座位：資料庫一律 1～4（代表人）。引擎的 0～3 ＝ 這一將的出牌順序 ＝ seat_ring 的第幾個（從 0 數）。
--      seat_ring 從這一將第一個莊家開始排 ⇒ 每一將第一局，引擎的莊家一定是第 0 位。
-- 擲骰子（2026-11-11 使用者）：開一將擲兩次。① 定座位：點數從 1 號數，數到誰誰是東，其餘照 1→2→3→4 的順序接南西北
--      ② 定莊家：點數從東家數（1 點 ＝ 東自己），數到誰誰當莊；這一擲同時是第一局的骰子台。
--      第二局起每局擲一次（引擎用 seed 自己擲）。座位號在第一將開始時隨機排一次，整場不變。
--      ⚠ 第二、三將開始時「再擲兩次重新定東與莊家」是我照計分板「每一將重選」訂的，使用者還沒確認。
--
-- 權限（硬規則 2.7：新建的函式預設全關）：只有 online_me_tx 開給 authenticated；其餘只有 service_role。
-- ════════════════════════════════════════════════════════════════════

-- ① 我在哪一場、坐幾號（前端 → Edge Function 用客人的登入憑證轉叫）
create or replace function public.online_me_tx()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_me uuid; g record; v_seat smallint; v_sp uuid;
begin
  v_me := public.current_member_id();
  if v_me is null then raise exception '未登入或登入已過期，請重新開啟 App' using errcode = '28000'; end if;
  -- 最近一場還開著的線上好友房（打完之後場次還會開 15 分鐘，讓手機看整場結算）
  select fg.id as game_id, fg.status as game_status, ts.id as session_id, ts.score_channel
    into g
    from friendly_games fg
    join friendly_game_players fp on fp.game_id = fg.id and fp.member_id = v_me and fp.left_at is null
    join table_sessions ts on ts.id = fg.session_id and ts.status = 'open' and ts.deleted_at is null
   where fg.play_mode = 'online' and fg.status in ('playing', 'finished')
   order by fg.started_at desc nulls last
   limit 1;
  if not found then   -- 🔴 不可以寫 g.session_id is null：沒撈到時 g 還沒有內容，讀它的欄位會直接報錯
    return jsonb_build_object('ok', false, 'reason', 'no_game', 'message', '你現在沒有線上牌局');
  end if;
  select sp.id, sp.seat into v_sp, v_seat from session_players sp
   where sp.session_id = g.session_id and sp.member_id = v_me and sp.left_at is null;
  if v_sp is null then
    return jsonb_build_object('ok', false, 'reason', 'not_in_session', 'message', '你不在這一場牌局裡');
  end if;
  return jsonb_build_object('ok', true, 'member_id', v_me, 'game_id', g.game_id, 'game_status', g.game_status,
                            'session_id', g.session_id, 'seat', v_seat, 'channel', g.score_channel);
end $$;

-- ② 這一場的整包資料（只給後端）
create or replace function public._online_ctx(p_session uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
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
                                  'stake_label', sl.label, 'is_hygiene', coalesce(sl.is_hygiene, false), 'channel', s.score_channel),
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
    'presence', (select coalesce(jsonb_object_agg(o.seat::text, jsonb_build_object('last_seen_at', o.last_seen_at, 'auto_since', o.auto_since)), '{}'::jsonb)
                   from online_seats o where o.session_id = s.id));
end $$;

-- 共用：這一場是不是可以繼續寫的線上好友房（回傳 null ＝ 可以；不然回原因）
create or replace function public._online_block(p_session uuid)
returns text language sql stable security definer set search_path = public as $$
  select case
    when ts.id is null or ts.mode <> 'friendly' or ts.deleted_at is not null then 'no_session'
    when ts.status <> 'open' then 'session_closed'
    when fg.id is null or fg.play_mode <> 'online' then 'not_online'
    when public._session_scored(ts.id) then 'scored'
    when exists (select 1 from session_busts b where b.session_id = ts.id and b.decision = 'pending') then 'bust_pending'
    else null end
  from (select p_session as sid) x
  left join table_sessions ts on ts.id = x.sid
  left join friendly_games fg on fg.session_id = ts.id;
$$;

-- ③ 開一將：排座位號（第一將）＋ 兩擲骰子定莊家與順序 ＋ 第一局
create or replace function public.online_start_round_tx(
  p_session uuid, p_seat_dice smallint[], p_dealer_dice smallint[],
  p_seed bigint, p_state jsonb, p_phase text, p_deadline timestamptz)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  s table_sessions; v_why text; v_no int; v_east smallint; v_dealer smallint; v_ring smallint[];
  v_rid uuid; v_hid uuid; r record; i smallint := 0;
begin
  select * into s from table_sessions where id = p_session for update;   -- 鎖住這一場：四支手機同時叫只會開出一將
  v_why := public._online_block(p_session);
  if v_why is not null then return jsonb_build_object('ok', false, 'reason', v_why); end if;
  if exists (select 1 from session_rounds where session_id = s.id and status = 'playing') then
    return jsonb_build_object('ok', false, 'reason', 'round_playing');
  end if;
  if (select count(*) from session_players where session_id = s.id and left_at is null) <> 4 then
    return jsonb_build_object('ok', false, 'reason', 'need_four_players');
  end if;
  select coalesce(max(round_no), 0) + 1 into v_no from session_rounds where session_id = s.id and status <> 'voided';
  if v_no > coalesce(s.planned_rounds, 1) then
    return jsonb_build_object('ok', false, 'reason', 'all_rounds_done');
  end if;
  if p_seat_dice is null or p_dealer_dice is null
     or cardinality(p_seat_dice) <> 3 or cardinality(p_dealer_dice) <> 3
     or not (p_seat_dice <@ '{1,2,3,4,5,6}'::smallint[]) or not (p_dealer_dice <@ '{1,2,3,4,5,6}'::smallint[]) then
    return jsonb_build_object('ok', false, 'reason', 'bad_dice');
  end if;
  -- 這一將第一局：引擎的莊家一定是第 0 位、連莊 0、骰子就是定莊家那一擲
  if p_state is null or (p_state ->> 'dealer')::int <> 0 or (p_state ->> 'ren')::int <> 0
     or (p_state -> 'dice') is distinct from to_jsonb(p_dealer_dice) then
    return jsonb_build_object('ok', false, 'reason', 'bad_state');
  end if;

  -- 座位號（代表人，整場不變）：還沒排過才排，隨機
  if exists (select 1 from session_players where session_id = s.id and left_at is null and seat is null) then
    update session_players set seat = null where session_id = s.id;
    for r in select id from session_players where session_id = s.id and left_at is null order by random() loop
      i := i + 1;
      update session_players set seat = i where id = r.id;
    end loop;
  end if;

  v_east   := ((p_seat_dice[1] + p_seat_dice[2] + p_seat_dice[3] - 1) % 4) + 1;                       -- 從 1 號數
  v_dealer := ((v_east - 1 + p_dealer_dice[1] + p_dealer_dice[2] + p_dealer_dice[3] - 1) % 4) + 1;   -- 從東家數（1 點是東自己）
  v_ring   := array[v_dealer, v_dealer % 4 + 1, (v_dealer + 1) % 4 + 1, (v_dealer + 2) % 4 + 1]::smallint[];

  insert into session_rounds (org_id, session_id, round_no, first_dealer_seat, seat_ring)
  values (s.org_id, s.id, v_no, v_dealer, v_ring)
  returning id into v_rid;
  insert into online_hands (org_id, session_id, round_id, hand_no, seed, dice, seat_dice, dealer_seat, renzhuang, state, phase, deadline_at)
  values (s.org_id, s.id, v_rid, 1, p_seed, p_dealer_dice, p_seat_dice, v_dealer, 0, p_state, p_phase, p_deadline)
  returning id into v_hid;
  insert into online_seats (session_id, seat, org_id)
  select s.id, x::smallint, s.org_id from generate_series(1, 4) x
  on conflict (session_id, seat) do nothing;
  insert into online_actions (org_id, online_hand_id, version, seat, actor, action)
  values (s.org_id, v_hid, 0, null, 'system',
          jsonb_build_object('type', 'deal', 'round_no', v_no, 'seat_dice', to_jsonb(p_seat_dice), 'dealer_dice', to_jsonb(p_dealer_dice),
                             'east_seat', v_east, 'dealer_seat', v_dealer));
  perform public._tbl_ping(s.id);
  return jsonb_build_object('ok', true, 'round_id', v_rid, 'hand_id', v_hid, 'round_no', v_no,
                            'east_seat', v_east, 'dealer_seat', v_dealer, 'ring', to_jsonb(v_ring));
end $$;

-- ④ 同一將的下一局
create or replace function public.online_next_hand_tx(
  p_session uuid, p_hand_no int, p_seed bigint, p_dice smallint[], p_dealer_seat smallint, p_ren smallint,
  p_state jsonb, p_phase text, p_deadline timestamptz)
returns jsonb language plpgsql security definer set search_path = public as $$
declare s table_sessions; v_why text; r session_rounds; v_rs jsonb; v_idx int; v_hid uuid;
begin
  select * into s from table_sessions where id = p_session for update;
  v_why := public._online_block(p_session);
  if v_why is not null then return jsonb_build_object('ok', false, 'reason', v_why); end if;
  select * into r from session_rounds where session_id = s.id and status = 'playing';
  if r.id is null then return jsonb_build_object('ok', false, 'reason', 'no_round'); end if;
  if exists (select 1 from online_hands where session_id = s.id and status = 'playing') then
    return jsonb_build_object('ok', false, 'reason', 'hand_playing');
  end if;
  v_rs := public._tbl_round_state(r.id);
  if (v_rs ->> 'finished')::boolean then return jsonb_build_object('ok', false, 'reason', 'round_finished'); end if;
  -- 局號、莊家、連莊一律以計分板那一套算出來的為準；後端送的對不上就不收
  if (v_rs ->> 'hand_no')::int <> p_hand_no or (v_rs ->> 'dealer_seat')::int <> p_dealer_seat or (v_rs ->> 'renzhuang')::int <> p_ren then
    return jsonb_build_object('ok', false, 'reason', 'out_of_sync', 'state', v_rs);
  end if;
  if p_dice is null or cardinality(p_dice) <> 3 or not (p_dice <@ '{1,2,3,4,5,6}'::smallint[]) then
    return jsonb_build_object('ok', false, 'reason', 'bad_dice');
  end if;
  v_idx := array_position(coalesce(r.seat_ring, '{1,2,3,4}'::smallint[]), p_dealer_seat) - 1;
  if p_state is null or (p_state ->> 'dealer')::int <> v_idx or (p_state ->> 'ren')::int <> p_ren
     or (p_state -> 'dice') is distinct from to_jsonb(p_dice) then
    return jsonb_build_object('ok', false, 'reason', 'bad_state');
  end if;
  insert into online_hands (org_id, session_id, round_id, hand_no, seed, dice, dealer_seat, renzhuang, state, phase, deadline_at)
  values (s.org_id, s.id, r.id, p_hand_no, p_seed, p_dice, p_dealer_seat, p_ren, p_state, p_phase, p_deadline)
  returning id into v_hid;
  insert into online_actions (org_id, online_hand_id, version, seat, actor, action)
  values (s.org_id, v_hid, 0, null, 'system', jsonb_build_object('type', 'deal', 'hand_no', p_hand_no, 'dice', to_jsonb(p_dice)));
  perform public._tbl_ping(s.id);
  return jsonb_build_object('ok', true, 'hand_id', v_hid, 'hand_no', p_hand_no);
end $$;

-- ⑤ 寫回一個動作；這一局打完就寫進 hands
--    p_result（打完才給）：{ type: tsumo｜ron｜draw, winner_seat, deal_in_seat, patterns: [{ code, n }], tai, deltas: { "1": n, … } }
--    座位都是 1～4（後端已經從引擎的 0～3 換算好）；tai ＝ 牌型台（已乘豹子、不含莊家台，同計分板 hands.tai_pattern）
create or replace function public.online_commit_tx(
  p_hand uuid, p_version int, p_state jsonb, p_phase text, p_deadline timestamptz,
  p_seat smallint, p_actor text, p_action jsonb, p_result jsonb default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  h online_hands; sl record; v_rs jsonb; v_type text; v_win smallint; v_from smallint; v_deltas jsonb;
  v_hand uuid; v_applied jsonb; v_round_done boolean := false; v_ver int;
begin
  -- 比對版本：兩支手機同時按，只有先到的那一個算數，後到的拿到 stale、重新讀
  update online_hands
     set state = p_state, phase = p_phase, deadline_at = p_deadline, version = version + 1, updated_at = now()
   where id = p_hand and version = p_version and status = 'playing'
   returning * into h;
  if h.id is null then
    return jsonb_build_object('ok', false, 'reason', 'stale');
  end if;
  v_ver := h.version;
  insert into online_actions (org_id, online_hand_id, version, seat, actor, action)
  values (h.org_id, h.id, v_ver, p_seat, p_actor, p_action);
  -- 本人動了 ⇒ 記上線時間、解除代打；電腦代打 ⇒ 記下從什麼時候開始代打
  if p_seat is not null then
    insert into online_seats (session_id, seat, org_id, last_seen_at, auto_since)
    values (h.session_id, p_seat, h.org_id, case when p_actor = 'player' then now() end, case when p_actor = 'auto' then now() end)
    on conflict (session_id, seat) do update
      set last_seen_at = case when p_actor = 'player' then now() else online_seats.last_seen_at end,
          auto_since   = case when p_actor = 'player' then null else coalesce(online_seats.auto_since, now()) end;
  end if;

  if p_result is null then
    perform public._tbl_ping(h.session_id);
    return jsonb_build_object('ok', true, 'version', v_ver);
  end if;

  -- ── 這一局打完 ──
  v_type   := p_result ->> 'type';
  v_win    := nullif(p_result ->> 'winner_seat', '')::smallint;
  v_from   := nullif(p_result ->> 'deal_in_seat', '')::smallint;
  v_deltas := p_result -> 'deltas';
  if v_type not in ('tsumo', 'ron', 'draw') then raise exception '線上牌局：不認得的結果 %', v_type; end if;
  if v_deltas is null or (select count(*) from jsonb_object_keys(v_deltas)) <> 4
     or not (v_deltas ?& array['1', '2', '3', '4'])
     or (select sum(e.value::int) from jsonb_each_text(v_deltas) e) <> 0 then
    raise exception '線上牌局：四家的增減加起來不是 0（%）', v_deltas;   -- 整筆退回：寧可這一步失敗，不可以寫進一局對不起來的帳
  end if;
  select coalesce(x.base, 0) as base, coalesce(x.tai, 0) as tai into sl
    from table_sessions ts left join stake_levels x on x.id = ts.stake_level_id where ts.id = h.session_id;
  v_rs := public._tbl_round_state(h.round_id);

  -- 走計分板同一條路：先 pending（BEFORE INSERT 的爆卡觸發器會把付不出來的部分夾掉）再 confirmed（爆卡偵測、碎片）
  insert into hands (org_id, session_id, round_id, hand_no, wind, dealer_seat, renzhuang, result, winner_seat, deal_in_seat,
                     patterns, tai_pattern, base, tai_unit, proposed_delta, status, submitted_seat)
  values (h.org_id, h.session_id, h.round_id, h.hand_no, (v_rs ->> 'wind')::smallint, h.dealer_seat, h.renzhuang, v_type, v_win, v_from,
          coalesce(p_result -> 'patterns', '[]'::jsonb), coalesce((p_result ->> 'tai')::int, 0), sl.base, sl.tai, v_deltas, 'pending', v_win)
  returning id, proposed_delta into v_hand, v_applied;
  update hands set score_delta = v_applied, status = 'confirmed', confirmed_at = now() where id = v_hand;

  update online_hands set status = 'finished', ended_at = now(), hand_id = v_hand, deadline_at = null where id = h.id;

  -- 這一將打完了沒（東南西北四圈）；打完 ⇒ 標記，最後一將會由既有的觸發器自動結算成績
  if (public._tbl_round_state(h.round_id) ->> 'finished')::boolean then
    update session_rounds set status = 'finished', finished_at = now() where id = h.round_id and status = 'playing';
    v_round_done := true;
  end if;
  perform public._tbl_ping(h.session_id);
  return jsonb_build_object('ok', true, 'version', v_ver, 'hand_id', v_hand, 'applied', v_applied,
                            'round_finished', v_round_done, 'scored', public._session_scored(h.session_id));
end $$;

-- ⑥ 爆卡的人決定：追加積分（p_amount > 0）或結束整場（0）—— 同計分板 tbl_bust_decide_tx，差別只在座位由後端認好傳進來
create or replace function public.online_bust_decide_tx(p_session uuid, p_seat smallint, p_amount int)
returns jsonb language plpgsql security definer set search_path = public as $$
declare s table_sessions; b session_busts;
begin
  select * into s from table_sessions where id = p_session and status = 'open' and mode = 'friendly' for update;
  if s.id is null then return jsonb_build_object('ok', false, 'reason', 'no_session'); end if;
  if not exists (select 1 from friendly_games fg where fg.session_id = s.id and fg.play_mode = 'online') then
    return jsonb_build_object('ok', false, 'reason', 'not_online');
  end if;
  if public._session_scored(s.id) then
    return jsonb_build_object('ok', false, 'reason', 'scored', 'message', '這場的成績已經結算');
  end if;
  select * into b from session_busts where session_id = s.id and decision = 'pending' order by seat limit 1 for update;
  if b.id is null then
    return jsonb_build_object('ok', false, 'reason', 'no_bust', 'message', '現在沒有人爆卡');
  end if;
  if p_seat is null or b.seat <> p_seat then
    return jsonb_build_object('ok', false, 'reason', 'not_yours', 'message', '只有爆卡的人可以決定');
  end if;
  if coalesce(p_amount, 0) > 0 then
    if p_amount > 9999999 then
      return jsonb_build_object('ok', false, 'reason', 'bad_amount', 'message', '追加的積分太多了');
    end if;
    update session_busts set decision = 'added', added_points = p_amount, decided_at = now() where id = b.id;
    perform public._tbl_ping(s.id);
    return jsonb_build_object('ok', true, 'added', p_amount);
  end if;
  -- 不追加 ⇒ 整場結束
  update session_busts set decision = 'ended', decided_at = now() where id = b.id;
  update session_busts set decision = 'voided', decided_at = now() where session_id = s.id and decision = 'pending';
  update session_rounds set status = 'finished', finished_at = now() where session_id = s.id and status = 'playing';
  if coalesce(s.planned_rounds, 0) >= 1 and not public._session_scored(s.id) then
    begin
      perform public._score_settle_tx(s.id);
    exception when others then null;   -- 不可以讓結算失敗把「結束」一起回滾；收尾排程會補
    end;
  end if;
  perform public._tbl_ping(s.id);
  return jsonb_build_object('ok', true, 'ended', true);
end $$;

-- ⑦ 權限：預設全關之後新建的函式只有 postgres 與 service_role 叫得動；這裡明寫一次，兩個方向都收（硬規則 2.6／2.7）
do $$
declare f text;
begin
  foreach f in array array[
    'public._online_ctx(uuid)',
    'public._online_block(uuid)',
    'public.online_start_round_tx(uuid, smallint[], smallint[], bigint, jsonb, text, timestamptz)',
    'public.online_next_hand_tx(uuid, int, bigint, smallint[], smallint, smallint, jsonb, text, timestamptz)',
    'public.online_commit_tx(uuid, int, jsonb, text, timestamptz, smallint, text, jsonb, jsonb)',
    'public.online_bust_decide_tx(uuid, smallint, int)'
  ] loop
    execute format('revoke execute on function %s from public', f);
    execute format('revoke execute on function %s from anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
end $$;
revoke execute on function public.online_me_tx() from public;
revoke execute on function public.online_me_tx() from anon;
grant  execute on function public.online_me_tx() to authenticated, service_role;

-- ════════════════════════════════════════════════════════════════════
-- 驗證（單一 SELECT；不 raise —— 硬規則 1.8）
-- 行為（開一將、寫回、打完寫進 hands、下一局、擋牆）另外跑：sql/checks/2026-11-11_驗線上好友房建局與動作.sql
-- ════════════════════════════════════════════════════════════════════
with f(n) as (values ('online_me_tx'), ('_online_ctx'), ('_online_block'), ('online_start_round_tx'),
                     ('online_next_hand_tx'), ('online_commit_tx'), ('online_bust_decide_tx')),
p as (select pr.proname, pr.oid, pr.prosecdef, pr.proacl from pg_proc pr join f on f.n = pr.proname where pr.pronamespace = 'public'::regnamespace),
has as (select p.proname,
               exists (select 1 from aclexplode(p.proacl) a where a.grantee = 'anon'::regrole::oid and a.privilege_type = 'EXECUTE') as anon,
               exists (select 1 from aclexplode(p.proacl) a where a.grantee = 'authenticated'::regrole::oid and a.privilege_type = 'EXECUTE') as authed,
               exists (select 1 from aclexplode(p.proacl) a where a.grantee = 'service_role'::regrole::oid and a.privilege_type = 'EXECUTE') as svc,
               (p.proacl is null or exists (select 1 from aclexplode(p.proacl) a where a.grantee = 0 and a.privilege_type = 'EXECUTE')) as pub
          from p),
c(item, ok) as (
  select '① 七支函式都在、各只有一個版本（實際 ' || (select count(*) from p) || ' 支）', (select count(*) from p) = 7
  union all
  select '② 全部是 SECURITY DEFINER', coalesce((select bool_and(prosecdef) from p), false)
  union all
  select '③ PUBLIC 與 anon 一支都叫不動', not exists (select 1 from has where pub or anon)
  union all
  select '④ 給後端的六支：authenticated 叫不動（含讀得到四家手牌的 _online_ctx）',
         not exists (select 1 from has where proname <> 'online_me_tx' and authed)
  union all
  select '⑤ 正對照：六支 service_role 都叫得動（不然 Edge Function 會當場壞）',
         (select count(*) from has where proname <> 'online_me_tx' and svc) = 6
  union all
  select '⑥ 正對照：online_me_tx 開給 authenticated（前端要叫）',
         coalesce((select authed from has where proname = 'online_me_tx'), false)
  union all
  select '⑦ online_me_tx 的身分只認 current_member_id()，沒有任何會員 id 參數',
         (select pg_get_function_identity_arguments(oid) = '' from p where proname = 'online_me_tx')
         and (select pg_get_functiondef(oid) ~ 'v_me := public\.current_member_id\(\)' from p where proname = 'online_me_tx')
  union all
  select '⑧ 打完一局走計分板那條路：先 pending 再 confirmed（爆卡與碎片的觸發器才會動）',
         (select pg_get_functiondef(oid) ~ '''pending'', v_win\)' and pg_get_functiondef(oid) ~ 'status = ''confirmed''' from p where proname = 'online_commit_tx')
)
select string_agg(case when ok then '✅ ' else '🔴 ' end || item, E'\n') as "驗證" from c;
