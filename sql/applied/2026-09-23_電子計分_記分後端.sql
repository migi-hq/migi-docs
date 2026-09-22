-- ════════════════════════════════════════════════════════════════════
-- 2026-09-23 電子計分 · 第二批：記分的後端
-- 📄 設計：docs/02-POS與開桌/桌邊記分板設計.md（§8.5 是 2026-09-23 的決定）
--
-- 平板是系統的第三種身分：沒有會員 JWT，用配對時拿到的 device_token。
--   · 每一支 tbl_* 都吃 p_token，後端比對雜湊 ⇒ 知道「哪一桌」
--   · 「哪個人」由這台平板綁定的座位決定 —— **沒有任何一支接受呼叫端宣告身分**
--   · 胡牌只能由胡的人自己按（贏家 ＝ 這台平板的座位，不收參數）
--
-- 這一份做的：
--   helper   _tbl_hash / _tbl_device / _tbl_ping / _tbl_round_state
--   平板     tbl_state_tx            整桌狀態（平板收到廣播後來拿）
--            tbl_claim_seat_tx       「我是誰」
--            tbl_release_seat_tx     放掉（拿錯平板）
--            tbl_set_order_tx        三次點擊：莊家 → 莊家的下家 → 莊家的對家
--            tbl_submit_hand_tx      胡（放槍／自摸）或流局
--            tbl_confirm_hand_tx     被胡的人確認或駁回
--            tbl_cancel_pending_tx   送出的人收回還沒確認的那一把
--            tbl_undo_last_tx        撤銷上一把（任何人）
--            tbl_start_round_tx      開始下一將
--   POS      pos_pair_table_device_tx / pos_list_table_devices_tx / pos_revoke_table_device_tx
--
-- 🔴 這一份**不碰收桌結算**（那是 2b）：段位分、名次、final_score、成就
--   都在收桌時一次做 —— 成就刻意不在確認當下發，因為「撤銷上一把」存在：
--   確認當下就發的話，記一把假的大四喜、確認、撤銷，成就就白拿了，而成就收不回來。
-- 🔴 只支援台麻（MIGI ruleset）。美麻桌回 unsupported_game_type。
-- ════════════════════════════════════════════════════════════════════

-- ── 0. 將號在作廢之後可以重用 ──────────────────────────────────────
-- 撤銷會把「剛開、一把都沒打」的下一將作廢，之後重開要能用同一個號碼。
alter table public.session_rounds drop constraint if exists session_rounds_session_id_round_no_key;
create unique index if not exists uq_session_rounds_no
  on public.session_rounds (session_id, round_no) where status <> 'voided';

-- ── 1. helper ──────────────────────────────────────────────────────
create or replace function public._tbl_hash(p_token text)
returns text language sql immutable set search_path to 'public'
as $$ select encode(extensions.digest(p_token, 'sha256'), 'hex') $$;

create or replace function public._tbl_device(p_token text)
returns public.table_devices
language plpgsql security definer set search_path to 'public'
as $$
declare d public.table_devices;
begin
  if p_token is null or length(p_token) < 32 then
    raise exception '這台平板還沒配對，請找店員' using errcode = '28000';
  end if;
  select * into d from table_devices
   where token_hash = public._tbl_hash(p_token) and is_active;
  if not found then
    raise exception '這台平板還沒配對或已停用，請找店員' using errcode = '28000';
  end if;
  /* 最後上線時間：一分鐘寫一次就好（平板每次收到廣播都會來拿狀態） */
  if d.last_seen_at is null or d.last_seen_at < now() - interval '1 minute' then
    update table_devices set last_seen_at = now() where id = d.id;
  end if;
  return d;
end $$;

/* 廣播「這一場變了」。只帶時間，不帶任何分數或名字。
   ⚠ 廣播失敗不可以讓記分失敗 —— 平板另外有定時拉取當後路。 */
create or replace function public._tbl_ping(p_session_id uuid)
returns void language plpgsql security definer set search_path to 'public'
as $$
declare v_ch text;
begin
  select score_channel into v_ch from table_sessions where id = p_session_id;
  if v_ch is null then return; end if;
  begin
    perform realtime.send(
      jsonb_build_object('at', (extract(epoch from clock_timestamp()) * 1000)::bigint),
      'changed', 'score:' || v_ch, false);
  exception when others then
    null;
  end;
end $$;

/* 一將現在打到哪裡：從已確認的每一把推出來，**不另外存** ——
   另外存的話撤銷時要記得倒回去，漏一次就永遠錯（同「不存計數欄位」那條）。
   規則：莊家胡或流局 ⇒ 連莊；否則莊家交給下家（seat % 4 + 1）。
   四個莊家都交過一輪 ⇒ 換下一圈；北風圈交完 ⇒ 這一將結束。 */
create or replace function public._tbl_round_state(p_round_id uuid)
returns jsonb language plpgsql stable security definer set search_path to 'public'
as $$
declare
  v_first smallint; v_dealer smallint; v_wind smallint := 1; v_ren smallint := 0;
  v_pass smallint := 0; v_n int := 0; v_fin boolean := false; h record;
begin
  select first_dealer_seat into v_first from session_rounds where id = p_round_id;
  if v_first is null then return null; end if;
  v_dealer := v_first;
  for h in select result, winner_seat from hands
            where round_id = p_round_id and status = 'confirmed' order by hand_no
  loop
    v_n := v_n + 1;
    if h.result = 'draw' or h.winner_seat = v_dealer then
      v_ren := v_ren + 1;
    else
      v_dealer := (v_dealer % 4) + 1;
      v_ren := 0;
      v_pass := v_pass + 1;
      if v_pass = 4 then
        v_pass := 0;
        v_wind := v_wind + 1;
        if v_wind > 4 then v_wind := 4; v_fin := true; exit; end if;
      end if;
    end if;
  end loop;
  return jsonb_build_object('wind', v_wind, 'dealer_seat', v_dealer, 'renzhuang', v_ren,
                            'hand_no', v_n + 1, 'finished', v_fin, 'confirmed_hands', v_n);
end $$;

-- ── 2. 整桌狀態 ────────────────────────────────────────────────────
create or replace function public.tbl_state_tx(p_token text)
returns jsonb language plpgsql security definer set search_path to 'public'
as $$
declare
  d public.table_devices; s public.table_sessions; v_table text; v_store text;
  v_my_seat smallint; v_my_player uuid; v_round public.session_rounds; v_state jsonb;
  v_players jsonb; v_pending jsonb; v_history jsonb; v_totals jsonb; v_round_totals jsonb;
  v_rounds jsonb; v_catalog jsonb; v_stake jsonb; v_last_reject jsonb;
begin
  d := public._tbl_device(p_token);
  select t.label, st.name into v_table, v_store
    from tables t join stores st on st.id = t.store_id where t.id = d.table_id;

  select * into s from table_sessions
   where table_id = d.table_id and status = 'open' and deleted_at is null;
  if not found then
    return jsonb_build_object('ok', true,
      'device', jsonb_build_object('label', d.label, 'table', v_table, 'store', v_store),
      'session', null);
  end if;

  select sp.seat, sp.id into v_my_seat, v_my_player
    from session_players sp
   where sp.session_id = s.id and sp.device_id = d.id and sp.left_at is null;

  /* 🔴 不回 member_id —— 平板認人用的是 player_id（session_players.id），
     會員 uuid 不需要出現在一台四個陌生人碰一整晚的裝置上。 */
  select coalesce(jsonb_agg(jsonb_build_object(
           'player_id', sp.id, 'seat', sp.seat, 'name', m.display_name,
           'rank', m.rank, 'title', m.title,
           'avatar_url', m.avatar_url, 'avatar_source', m.avatar_source, 'avatar_bear', m.avatar_bear,
           'bound', sp.device_id is not null, 'is_me', sp.device_id = d.id)
         order by sp.seat nulls last, sp.joined_at), '[]'::jsonb)
    into v_players
    from session_players sp join members m on m.id = sp.member_id
   where sp.session_id = s.id and sp.left_at is null;

  select case when sl.id is null then null else jsonb_build_object(
           'label', sl.label, 'base', sl.base, 'tai', sl.tai, 'hygiene', sl.is_hygiene) end
    into v_stake
    from table_sessions ts left join stake_levels sl on sl.id = ts.stake_level_id
   where ts.id = s.id;

  select coalesce(jsonb_agg(jsonb_build_object(
           'code', p.code, 'label', p.label, 'tai', p.tai, 'max_count', p.max_count,
           'group', p.group_key, 'result_only', p.result_only, 'dealer_only', p.dealer_only,
           'conflicts', to_jsonb(p.conflicts)) order by p.sort), '[]'::jsonb)
    into v_catalog
    from scoring_patterns p
   where p.is_active and (not p.needs_flower or s.flower = '有花');

  select * into v_round from session_rounds
   where session_id = s.id and status <> 'voided' order by round_no desc limit 1;
  if found then v_state := public._tbl_round_state(v_round.id); end if;

  /* 分數：每個座位的整場累計與這一將累計（只算已確認的） */
  select coalesce(jsonb_object_agg(k, tot), '{}'::jsonb) into v_totals
    from (select e.key as k, sum(e.value::int) as tot
            from hands h, jsonb_each_text(h.score_delta) e
           where h.session_id = s.id and h.status = 'confirmed' group by e.key) x;
  if v_round.id is not null then
    select coalesce(jsonb_object_agg(k, tot), '{}'::jsonb) into v_round_totals
      from (select e.key as k, sum(e.value::int) as tot
              from hands h, jsonb_each_text(h.score_delta) e
             where h.round_id = v_round.id and h.status = 'confirmed' group by e.key) x;

    select jsonb_build_object(
             'hand_id', h.id, 'result', h.result, 'winner_seat', h.winner_seat,
             'deal_in_seat', h.deal_in_seat, 'tai_pattern', h.tai_pattern, 'manual_tai', h.manual_tai,
             'patterns', h.patterns, 'score_delta', h.score_delta,
             'need_confirm', to_jsonb(h.need_confirm), 'confirmed_seats', to_jsonb(h.confirmed_seats),
             'submitted_seat', h.submitted_seat,
             'i_must_confirm', v_my_seat = any(h.need_confirm) and not (v_my_seat = any(h.confirmed_seats)))
      into v_pending
      from hands h where h.round_id = v_round.id and h.status = 'pending';

    /* 最近一次被駁回（而且之後還沒有新的一把）⇒ 讓送出的人知道要重填 */
    select jsonb_build_object('hand_id', h.id, 'rejected_seat', h.rejected_seat,
                              'submitted_seat', h.submitted_seat, 'at', h.created_at)
      into v_last_reject
      from hands h
     where h.round_id = v_round.id and h.status = 'rejected'
       and not exists (select 1 from hands h2 where h2.round_id = v_round.id
                        and h2.status in ('pending','confirmed') and h2.created_at > h.created_at)
     order by h.created_at desc limit 1;

    select coalesce(jsonb_agg(x.j order by x.hand_no desc), '[]'::jsonb) into v_history
      from (select h.hand_no, jsonb_build_object(
                     'hand_id', h.id, 'hand_no', h.hand_no, 'wind', h.wind, 'dealer_seat', h.dealer_seat,
                     'renzhuang', h.renzhuang, 'result', h.result, 'winner_seat', h.winner_seat,
                     'deal_in_seat', h.deal_in_seat, 'tai_pattern', h.tai_pattern, 'manual_tai', h.manual_tai,
                     'patterns', h.patterns, 'score_delta', h.score_delta) as j
              from hands h where h.round_id = v_round.id and h.status = 'confirmed'
             order by h.hand_no desc limit 12) x;
  end if;

  select coalesce(jsonb_agg(jsonb_build_object('round_no', r.round_no, 'status', r.status)
                            order by r.round_no), '[]'::jsonb)
    into v_rounds
    from session_rounds r where r.session_id = s.id and r.status <> 'voided';

  return jsonb_build_object('ok', true,
    'device', jsonb_build_object('label', d.label, 'table', v_table, 'store', v_store),
    'session', jsonb_build_object(
      'id', s.id, 'channel', s.score_channel, 'game_type', s.game_type, 'flower', s.flower,
      'planned_rounds', s.planned_rounds, 'stake', v_stake,
      'supported', coalesce(s.game_type, '台麻') = '台麻'),
    'players', v_players, 'my_seat', v_my_seat, 'my_player_id', v_my_player,
    'order_set', (select count(*) from session_players where session_id = s.id and left_at is null and seat is not null) = 4,
    'rounds', v_rounds,
    'round', case when v_round.id is null then null else
               jsonb_build_object('round_no', v_round.round_no, 'status', v_round.status,
                                  'first_dealer_seat', v_round.first_dealer_seat) || v_state end,
    'totals', coalesce(v_totals, '{}'::jsonb), 'round_totals', coalesce(v_round_totals, '{}'::jsonb),
    'pending', v_pending, 'last_reject', v_last_reject, 'history', coalesce(v_history, '[]'::jsonb),
    'patterns', v_catalog);
end $$;

-- ── 3. 「我是誰」 ──────────────────────────────────────────────────
create or replace function public.tbl_claim_seat_tx(p_token text, p_player_id uuid)
returns jsonb language plpgsql security definer set search_path to 'public'
as $$
declare d public.table_devices; v_session uuid; v_owner uuid;
begin
  d := public._tbl_device(p_token);
  select id into v_session from table_sessions
   where table_id = d.table_id and status = 'open' and deleted_at is null;
  if v_session is null then
    return jsonb_build_object('ok', false, 'reason', 'no_session', 'message', '這桌還沒開桌');
  end if;

  select device_id into v_owner from session_players
   where id = p_player_id and session_id = v_session and left_at is null;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'not_in_session', 'message', '這個人不在這一桌');
  end if;
  if v_owner is not null and v_owner <> d.id then
    return jsonb_build_object('ok', false, 'reason', 'taken', 'message', '這個人已經在另一台平板上了');
  end if;

  -- 這台平板原本綁的是別人 ⇒ 先放掉
  update session_players set device_id = null
   where session_id = v_session and device_id = d.id and id <> p_player_id;
  begin
    update session_players set device_id = d.id where id = p_player_id;
  exception when unique_violation then
    -- 兩台同時按同一個人：資料庫擋下晚到的那一台
    return jsonb_build_object('ok', false, 'reason', 'taken', 'message', '這個人剛剛被另一台平板選走了');
  end;

  perform public._tbl_ping(v_session);
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.tbl_release_seat_tx(p_token text)
returns jsonb language plpgsql security definer set search_path to 'public'
as $$
declare d public.table_devices; v_session uuid;
begin
  d := public._tbl_device(p_token);
  select id into v_session from table_sessions
   where table_id = d.table_id and status = 'open' and deleted_at is null;
  if v_session is null then
    return jsonb_build_object('ok', false, 'reason', 'no_session', 'message', '這桌還沒開桌');
  end if;
  update session_players set device_id = null where session_id = v_session and device_id = d.id;
  perform public._tbl_ping(v_session);
  return jsonb_build_object('ok', true);
end $$;

-- ── 4. 三次點擊定座位 ──────────────────────────────────────────────
/* 莊家 ＝ 座位 1，莊家的下家 ＝ 2，莊家的對家 ＝ 3，剩下那個人 ＝ 4（莊家的上家）。
   ⚠ 任何一台都可以點，不需要先選「我是誰」。
   ⚠ 第一把確認之前都可以重來；之後就鎖住（座位一改，已記的分數就對不上人了）。 */
create or replace function public.tbl_set_order_tx(
  p_token text, p_dealer uuid, p_next uuid, p_opposite uuid)
returns jsonb language plpgsql security definer set search_path to 'public'
as $$
declare d public.table_devices; s public.table_sessions; v_n int; v_last uuid; v_round uuid;
begin
  d := public._tbl_device(p_token);
  select * into s from table_sessions
   where table_id = d.table_id and status = 'open' and deleted_at is null;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'no_session', 'message', '這桌還沒開桌');
  end if;
  if coalesce(s.game_type, '台麻') <> '台麻' then
    return jsonb_build_object('ok', false, 'reason', 'unsupported_game_type',
                              'message', '記分板目前只支援台麻');
  end if;

  select count(*) into v_n from session_players where session_id = s.id and left_at is null;
  if v_n <> 4 then
    return jsonb_build_object('ok', false, 'reason', 'need_four_players',
                              'message', '要四個人都入座才能開始', 'n', v_n);
  end if;
  if p_dealer is null or p_next is null or p_opposite is null
     or p_dealer = p_next or p_dealer = p_opposite or p_next = p_opposite then
    return jsonb_build_object('ok', false, 'reason', 'bad_order', 'message', '三個人要選不同的人');
  end if;
  if (select count(*) from session_players
       where session_id = s.id and left_at is null and id in (p_dealer, p_next, p_opposite)) <> 3 then
    return jsonb_build_object('ok', false, 'reason', 'not_in_session', 'message', '有人不在這一桌');
  end if;
  if exists (select 1 from hands where session_id = s.id and status = 'confirmed') then
    return jsonb_build_object('ok', false, 'reason', 'already_started',
                              'message', '已經開始記分了，座位不能再改');
  end if;

  select id into v_last from session_players
   where session_id = s.id and left_at is null and id not in (p_dealer, p_next, p_opposite);

  -- 先全部清掉再填，避開 (session_id, seat) 唯一索引的中間狀態
  update session_players set seat = null where session_id = s.id;
  update session_players set seat = 1 where id = p_dealer;
  update session_players set seat = 2 where id = p_next;
  update session_players set seat = 3 where id = p_opposite;
  update session_players set seat = 4 where id = v_last;

  -- 第一將：還沒有就建，有（而且一把都沒確認）就把莊家重設成 1
  select id into v_round from session_rounds
   where session_id = s.id and status = 'playing';
  if v_round is null then
    insert into session_rounds (org_id, session_id, round_no, first_dealer_seat)
    values (s.org_id, s.id, 1, 1);
  else
    update session_rounds set first_dealer_seat = 1 where id = v_round;
  end if;
  -- 還掛著的待確認（座位改了就沒意義）一律收掉
  update hands set status = 'undone', undone_at = now()
   where session_id = s.id and status = 'pending';

  perform public._tbl_ping(s.id);
  return jsonb_build_object('ok', true);
end $$;

-- ── 5. 送出一把 ────────────────────────────────────────────────────
create or replace function public.tbl_submit_hand_tx(
  p_token text, p_result text, p_deal_in_seat smallint default null,
  p_patterns jsonb default '[]'::jsonb, p_manual_tai int default null)
returns jsonb language plpgsql security definer set search_path to 'public'
as $$
declare
  d public.table_devices; s public.table_sessions; v_me smallint; v_round public.session_rounds;
  v_st jsonb; v_dealer smallint; v_ren smallint; v_base int; v_unit int;
  v_pats jsonb := '[]'::jsonb; v_codes text[] := '{}'; e jsonb; p public.scoring_patterns;
  v_n int; v_tai int := 0; v_manual boolean := false; v_extra int;
  v_delta jsonb; v_win int := 0; v_pay int; v_payers smallint[]; i smallint;
  v_need smallint[] := '{}'; v_status text; v_hand uuid; v_winner smallint;
begin
  d := public._tbl_device(p_token);
  select * into s from table_sessions
   where table_id = d.table_id and status = 'open' and deleted_at is null;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'no_session', 'message', '這桌還沒開桌');
  end if;
  if coalesce(s.game_type, '台麻') <> '台麻' then
    return jsonb_build_object('ok', false, 'reason', 'unsupported_game_type', 'message', '記分板目前只支援台麻');
  end if;

  select seat into v_me from session_players
   where session_id = s.id and device_id = d.id and left_at is null;
  if v_me is null then
    return jsonb_build_object('ok', false, 'reason', 'no_seat', 'message', '請先選「我是誰」並定好座位');
  end if;

  select * into v_round from session_rounds where session_id = s.id and status = 'playing';
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'no_round', 'message', '這一將已經結束，請先開始下一將');
  end if;
  if exists (select 1 from hands where round_id = v_round.id and status = 'pending') then
    return jsonb_build_object('ok', false, 'reason', 'pending_exists', 'message', '上一把還在等確認');
  end if;

  if p_result not in ('tsumo', 'ron', 'draw') then
    return jsonb_build_object('ok', false, 'reason', 'bad_result', 'message', '胡牌方式不對');
  end if;

  v_st := public._tbl_round_state(v_round.id);
  v_dealer := (v_st ->> 'dealer_seat')::smallint;
  v_ren := (v_st ->> 'renzhuang')::smallint;

  select sl.base, sl.tai into v_base, v_unit
    from stake_levels sl where sl.id = s.stake_level_id;
  if v_base is null or v_unit is null then
    return jsonb_build_object('ok', false, 'reason', 'no_stake', 'message', '這桌沒有設定積分級距，請找店員');
  end if;

  -- ── 流局：不用確認，直接生效 ──
  if p_result = 'draw' then
    insert into hands (org_id, session_id, round_id, hand_no, wind, dealer_seat, renzhuang,
                       result, base, tai_unit, score_delta, status, need_confirm,
                       submitted_seat, submitted_device_id, confirmed_at)
    values (s.org_id, s.id, v_round.id, (v_st ->> 'hand_no')::int, (v_st ->> 'wind')::smallint,
            v_dealer, v_ren, 'draw', v_base, v_unit,
            '{"1":0,"2":0,"3":0,"4":0}'::jsonb, 'confirmed', '{}', v_me, d.id, now())
    returning id into v_hand;
    if (public._tbl_round_state(v_round.id) ->> 'finished')::boolean then
      update session_rounds set status = 'finished', finished_at = now() where id = v_round.id;
    end if;
    perform public._tbl_ping(s.id);
    return jsonb_build_object('ok', true, 'hand_id', v_hand, 'status', 'confirmed');
  end if;

  -- ── 胡：贏家一律是這台平板的座位 ──
  v_winner := v_me;
  if p_result = 'ron' then
    if p_deal_in_seat is null or p_deal_in_seat not between 1 and 4 or p_deal_in_seat = v_winner then
      return jsonb_build_object('ok', false, 'reason', 'bad_deal_in', 'message', '請選是誰放槍');
    end if;
  end if;

  if p_manual_tai is not null then
    -- 直接輸台數：沒有牌型資料（不觸發牌型成就）
    if jsonb_array_length(coalesce(p_patterns, '[]'::jsonb)) > 0 then
      return jsonb_build_object('ok', false, 'reason', 'both_given', 'message', '選牌型或直接輸台數，擇一');
    end if;
    if p_manual_tai < 0 or p_manual_tai > 200 then
      return jsonb_build_object('ok', false, 'reason', 'bad_tai', 'message', '台數不對');
    end if;
    v_tai := p_manual_tai; v_manual := true;
  else
    for e in select * from jsonb_array_elements(coalesce(p_patterns, '[]'::jsonb)) loop
      select * into p from scoring_patterns where code = e ->> 'code' and is_active;
      if not found then
        return jsonb_build_object('ok', false, 'reason', 'unknown_pattern', 'message', '沒有這個牌型', 'code', e ->> 'code');
      end if;
      if p.code = any(v_codes) then
        return jsonb_build_object('ok', false, 'reason', 'duplicate_pattern', 'message', p.label || ' 選了兩次');
      end if;
      v_n := coalesce(nullif(e ->> 'n', '')::int, 1);
      if v_n < 1 or v_n > p.max_count then
        return jsonb_build_object('ok', false, 'reason', 'bad_count', 'message', p.label || ' 最多 ' || p.max_count);
      end if;
      if p.needs_flower and coalesce(s.flower, '無花') <> '有花' then
        return jsonb_build_object('ok', false, 'reason', 'no_flower', 'message', '這桌是無花，不能選 ' || p.label);
      end if;
      if p.result_only is not null and p.result_only <> p_result then
        return jsonb_build_object('ok', false, 'reason', 'wrong_result',
          'message', p.label || (case when p.result_only = 'tsumo' then ' 只有自摸才有' else ' 只有放槍才有' end));
      end if;
      if p.dealer_only and v_winner <> v_dealer then
        return jsonb_build_object('ok', false, 'reason', 'dealer_only', 'message', p.label || ' 只有莊家才有');
      end if;
      v_codes := v_codes || p.code;
      v_pats := v_pats || jsonb_build_array(jsonb_build_object('code', p.code, 'n', v_n));
      v_tai := v_tai + p.tai * v_n;
    end loop;

    -- 自摸：沒選門清自摸就自動帶自摸 1 台
    if p_result = 'tsumo' and not ('zimo' = any(v_codes)) and not ('menqing_tsumo' = any(v_codes)) then
      select * into p from scoring_patterns where code = 'zimo' and is_active;
      if found then
        v_codes := v_codes || p.code;
        v_pats := v_pats || jsonb_build_array(jsonb_build_object('code', p.code, 'n', 1));
        v_tai := v_tai + p.tai;
      end if;
    end if;

    -- 互斥（雙向）
    if exists (select 1 from scoring_patterns a, unnest(a.conflicts) c
                where a.code = any(v_codes) and c = any(v_codes)) then
      return jsonb_build_object('ok', false, 'reason', 'conflicting_patterns',
        'message', '有兩個牌型不能同時算：' ||
          (select string_agg(a.label || '／' || b.label, '、')
             from scoring_patterns a, unnest(a.conflicts) c, scoring_patterns b
            where a.code = any(v_codes) and c = any(v_codes) and b.code = c));
    end if;
  end if;

  /* 計分（MIGI ruleset，設計文件 §4）
     每個付款人付：底 ＋ 台 ×（牌型台數 ＋ 莊家附加台）
     莊家附加台 ＝ 1 ＋ 連莊數，只有「胡牌者是莊家」或「付款人是莊家」時才加。 */
  v_extra := 1 + v_ren;
  if p_result = 'ron' then
    v_payers := array[p_deal_in_seat];
    v_need := array[p_deal_in_seat];
  else
    v_payers := array(select g::smallint from generate_series(1, 4) g where g <> v_winner);
    v_need := v_payers;
  end if;
  v_delta := '{"1":0,"2":0,"3":0,"4":0}'::jsonb;
  foreach i in array v_payers loop
    v_pay := v_base + v_unit * (v_tai + case when v_winner = v_dealer or i = v_dealer then v_extra else 0 end);
    v_delta := jsonb_set(v_delta, array[i::text], to_jsonb(-v_pay));
    v_win := v_win + v_pay;
  end loop;
  v_delta := jsonb_set(v_delta, array[v_winner::text], to_jsonb(v_win));

  insert into hands (org_id, session_id, round_id, hand_no, wind, dealer_seat, renzhuang,
                     result, winner_seat, deal_in_seat, patterns, tai_pattern, manual_tai,
                     base, tai_unit, score_delta, status, need_confirm, submitted_seat, submitted_device_id)
  values (s.org_id, s.id, v_round.id, (v_st ->> 'hand_no')::int, (v_st ->> 'wind')::smallint,
          v_dealer, v_ren, p_result, v_winner, case when p_result = 'ron' then p_deal_in_seat end,
          v_pats, v_tai, v_manual, v_base, v_unit, v_delta, 'pending', v_need, v_me, d.id)
  returning id into v_hand;

  perform public._tbl_ping(s.id);
  return jsonb_build_object('ok', true, 'hand_id', v_hand, 'status', 'pending',
                            'tai_pattern', v_tai, 'score_delta', v_delta, 'need_confirm', to_jsonb(v_need));
end $$;

-- ── 6. 確認或駁回 ──────────────────────────────────────────────────
create or replace function public.tbl_confirm_hand_tx(p_token text, p_hand_id uuid, p_accept boolean)
returns jsonb language plpgsql security definer set search_path to 'public'
as $$
declare d public.table_devices; v_session uuid; v_me smallint; h public.hands; v_done smallint[];
begin
  d := public._tbl_device(p_token);
  select id into v_session from table_sessions
   where table_id = d.table_id and status = 'open' and deleted_at is null;
  if v_session is null then
    return jsonb_build_object('ok', false, 'reason', 'no_session', 'message', '這桌還沒開桌');
  end if;
  select seat into v_me from session_players
   where session_id = v_session and device_id = d.id and left_at is null;

  select * into h from hands where id = p_hand_id and session_id = v_session for update;
  if not found or h.status <> 'pending' then
    return jsonb_build_object('ok', false, 'reason', 'not_pending', 'message', '這一把已經處理過了');
  end if;
  if v_me is null or not (v_me = any(h.need_confirm)) then
    return jsonb_build_object('ok', false, 'reason', 'not_yours', 'message', '這一把不需要你確認');
  end if;
  if v_me = any(h.confirmed_seats) then
    return jsonb_build_object('ok', true, 'already', true);
  end if;

  if not p_accept then
    update hands set status = 'rejected', rejected_seat = v_me where id = h.id;
    perform public._tbl_ping(v_session);
    return jsonb_build_object('ok', true, 'status', 'rejected');
  end if;

  v_done := h.confirmed_seats || v_me;
  if (select bool_and(x = any(v_done)) from unnest(h.need_confirm) x) then
    update hands set confirmed_seats = v_done, status = 'confirmed', confirmed_at = now() where id = h.id;
    if (public._tbl_round_state(h.round_id) ->> 'finished')::boolean then
      update session_rounds set status = 'finished', finished_at = now() where id = h.round_id;
    end if;
    perform public._tbl_ping(v_session);
    return jsonb_build_object('ok', true, 'status', 'confirmed');
  end if;

  update hands set confirmed_seats = v_done where id = h.id;
  perform public._tbl_ping(v_session);
  return jsonb_build_object('ok', true, 'status', 'pending', 'confirmed_seats', to_jsonb(v_done));
end $$;

-- ── 7. 收回還沒確認的那一把（只有送出的人） ───────────────────────
create or replace function public.tbl_cancel_pending_tx(p_token text)
returns jsonb language plpgsql security definer set search_path to 'public'
as $$
declare d public.table_devices; v_session uuid; v_me smallint; v_n int;
begin
  d := public._tbl_device(p_token);
  select id into v_session from table_sessions
   where table_id = d.table_id and status = 'open' and deleted_at is null;
  select seat into v_me from session_players
   where session_id = v_session and device_id = d.id and left_at is null;
  update hands set status = 'undone', undone_at = now()
   where session_id = v_session and status = 'pending' and submitted_seat = v_me;
  get diagnostics v_n = row_count;
  if v_n = 0 then
    return jsonb_build_object('ok', false, 'reason', 'nothing', 'message', '沒有你送出、還在等確認的那一把');
  end if;
  perform public._tbl_ping(v_session);
  return jsonb_build_object('ok', true);
end $$;

-- ── 8. 撤銷上一把（任何人） ────────────────────────────────────────
/* 設計文件 §3.4：不設超時，但所有人都要有「撤銷上一把」—— 那才是真正的後路。
   ⚠ 剛開、一把都沒打的下一將會被作廢，並把上一將重新打開。
   ⚠ 有待確認的一把時不能撤銷（先處理那一把）。 */
create or replace function public.tbl_undo_last_tx(p_token text)
returns jsonb language plpgsql security definer set search_path to 'public'
as $$
declare d public.table_devices; v_session uuid; v_me smallint; r public.session_rounds; v_hand uuid;
begin
  d := public._tbl_device(p_token);
  select id into v_session from table_sessions
   where table_id = d.table_id and status = 'open' and deleted_at is null;
  if v_session is null then
    return jsonb_build_object('ok', false, 'reason', 'no_session', 'message', '這桌還沒開桌');
  end if;
  select seat into v_me from session_players
   where session_id = v_session and device_id = d.id and left_at is null;
  if v_me is null then
    return jsonb_build_object('ok', false, 'reason', 'no_seat', 'message', '請先選「我是誰」');
  end if;
  if exists (select 1 from hands where session_id = v_session and status = 'pending') then
    return jsonb_build_object('ok', false, 'reason', 'pending_exists', 'message', '有一把還在等確認，先處理那一把');
  end if;

  select * into r from session_rounds
   where session_id = v_session and status <> 'voided' order by round_no desc limit 1;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'nothing', 'message', '還沒有可以撤銷的');
  end if;

  -- 最新一將一把都沒打 ⇒ 作廢它，撤銷的對象變成上一將的最後一把
  if not exists (select 1 from hands where round_id = r.id and status = 'confirmed') and r.round_no > 1 then
    update session_rounds set status = 'voided' where id = r.id;
    select * into r from session_rounds
     where session_id = v_session and status <> 'voided' order by round_no desc limit 1;
  end if;

  select id into v_hand from hands
   where round_id = r.id and status = 'confirmed' order by hand_no desc limit 1;
  if v_hand is null then
    return jsonb_build_object('ok', false, 'reason', 'nothing', 'message', '還沒有可以撤銷的');
  end if;

  update hands set status = 'undone', undone_at = now() where id = v_hand;
  update session_rounds set status = 'playing', finished_at = null where id = r.id and status = 'finished';

  perform public._tbl_ping(v_session);
  return jsonb_build_object('ok', true, 'undone_hand_id', v_hand);
end $$;

-- ── 9. 開始下一將 ──────────────────────────────────────────────────
create or replace function public.tbl_start_round_tx(p_token text, p_dealer_seat smallint default 1)
returns jsonb language plpgsql security definer set search_path to 'public'
as $$
declare d public.table_devices; s public.table_sessions; r public.session_rounds;
begin
  d := public._tbl_device(p_token);
  select * into s from table_sessions
   where table_id = d.table_id and status = 'open' and deleted_at is null;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'no_session', 'message', '這桌還沒開桌');
  end if;
  if p_dealer_seat not between 1 and 4 then
    return jsonb_build_object('ok', false, 'reason', 'bad_seat', 'message', '請選莊家');
  end if;
  if exists (select 1 from session_rounds where session_id = s.id and status = 'playing') then
    return jsonb_build_object('ok', false, 'reason', 'round_playing', 'message', '這一將還沒打完');
  end if;
  select * into r from session_rounds
   where session_id = s.id and status <> 'voided' order by round_no desc limit 1;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'no_order', 'message', '請先定好座位');
  end if;

  insert into session_rounds (org_id, session_id, round_no, first_dealer_seat)
  values (s.org_id, s.id, r.round_no + 1, p_dealer_seat);
  perform public._tbl_ping(s.id);
  return jsonb_build_object('ok', true, 'round_no', r.round_no + 1);
end $$;

-- ── 10. POS：配對、列出、停用平板 ─────────────────────────────────
/* 店員在 POS 把一台平板綁到某一桌。明文憑證只在這裡回傳一次 ——
   POS 把它做成 QR，平板掃了就存進自己的 localStorage。資料庫只留雜湊。 */
create or replace function public.pos_pair_table_device_tx(p_table_id uuid, p_label text)
returns jsonb language plpgsql security definer set search_path to 'public'
as $$
declare v_staff uuid; t record; v_token text; v_id uuid;
begin
  v_staff := (select staff_id from public.current_staff());
  if v_staff is null then
    return jsonb_build_object('ok', false, 'reason', 'not_staff', 'message', '請先登入店員帳號');
  end if;
  select id, org_id, store_id, label into t from tables where id = p_table_id and deleted_at is null;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'table_not_found', 'message', '找不到這張桌');
  end if;
  if not public.has_store_access(t.store_id) then
    return jsonb_build_object('ok', false, 'reason', 'forbidden', 'message', '你沒有這間店的權限');
  end if;
  if nullif(btrim(coalesce(p_label, '')), '') is null then
    return jsonb_build_object('ok', false, 'reason', 'label_required', 'message', '請輸入平板編號，例如 A3-1');
  end if;

  v_token := encode(extensions.gen_random_bytes(32), 'hex');
  insert into table_devices (org_id, store_id, table_id, label, token_hash, created_by_staff_id)
  values (t.org_id, t.store_id, t.id, btrim(p_label), public._tbl_hash(v_token), v_staff)
  returning id into v_id;
  return jsonb_build_object('ok', true, 'device_id', v_id, 'token', v_token, 'table', t.label);
end $$;

create or replace function public.pos_list_table_devices_tx(p_store_id uuid)
returns jsonb language plpgsql stable security definer set search_path to 'public'
as $$
begin
  if (select staff_id from public.current_staff()) is null then
    return jsonb_build_object('ok', false, 'reason', 'not_staff', 'message', '請先登入店員帳號');
  end if;
  if not public.has_store_access(p_store_id) then
    return jsonb_build_object('ok', false, 'reason', 'forbidden', 'message', '你沒有這間店的權限');
  end if;
  return jsonb_build_object('ok', true, 'devices', coalesce((
    select jsonb_agg(jsonb_build_object(
             'device_id', dv.id, 'label', dv.label, 'table_id', dv.table_id, 'table', t.label,
             'is_active', dv.is_active, 'last_seen_at', dv.last_seen_at, 'created_at', dv.created_at)
           order by t.sort_order, t.label, dv.label)
      from table_devices dv join tables t on t.id = dv.table_id
     where dv.store_id = p_store_id and dv.is_active), '[]'::jsonb));
end $$;

create or replace function public.pos_revoke_table_device_tx(p_device_id uuid)
returns jsonb language plpgsql security definer set search_path to 'public'
as $$
declare v_staff uuid; v_store uuid;
begin
  v_staff := (select staff_id from public.current_staff());
  if v_staff is null then
    return jsonb_build_object('ok', false, 'reason', 'not_staff', 'message', '請先登入店員帳號');
  end if;
  select store_id into v_store from table_devices where id = p_device_id;
  if v_store is null then
    return jsonb_build_object('ok', false, 'reason', 'not_found', 'message', '找不到這台平板');
  end if;
  if not public.has_store_access(v_store) then
    return jsonb_build_object('ok', false, 'reason', 'forbidden', 'message', '你沒有這間店的權限');
  end if;
  update table_devices set is_active = false, revoked_at = now(), revoked_by_staff_id = v_staff
   where id = p_device_id and is_active;
  -- 停用的平板手上還綁著人的話一起放掉
  update session_players set device_id = null where device_id = p_device_id;
  return jsonb_build_object('ok', true);
end $$;

-- ── 11. 授權 ───────────────────────────────────────────────────────
-- helper：前端叫不到（兩個方向都收，硬規則 2.6b）
revoke execute on function public._tbl_hash(text)          from public, anon, authenticated;
revoke execute on function public._tbl_device(text)        from public, anon, authenticated;
revoke execute on function public._tbl_ping(uuid)          from public, anon, authenticated;
revoke execute on function public._tbl_round_state(uuid)   from public, anon, authenticated;
-- 平板：沒有登入身分，用 anon key 呼叫；身分由 p_token 決定
grant execute on function public.tbl_state_tx(text)                                  to anon, authenticated;
grant execute on function public.tbl_claim_seat_tx(text, uuid)                       to anon, authenticated;
grant execute on function public.tbl_release_seat_tx(text)                           to anon, authenticated;
grant execute on function public.tbl_set_order_tx(text, uuid, uuid, uuid)            to anon, authenticated;
grant execute on function public.tbl_submit_hand_tx(text, text, smallint, jsonb, int) to anon, authenticated;
grant execute on function public.tbl_confirm_hand_tx(text, uuid, boolean)            to anon, authenticated;
grant execute on function public.tbl_cancel_pending_tx(text)                         to anon, authenticated;
grant execute on function public.tbl_undo_last_tx(text)                              to anon, authenticated;
grant execute on function public.tbl_start_round_tx(text, smallint)                  to anon, authenticated;
-- POS：只給登入的店員
revoke execute on function public.pos_pair_table_device_tx(uuid, text)   from public, anon;
revoke execute on function public.pos_list_table_devices_tx(uuid)        from public, anon;
revoke execute on function public.pos_revoke_table_device_tx(uuid)       from public, anon;
grant  execute on function public.pos_pair_table_device_tx(uuid, text)   to authenticated;
grant  execute on function public.pos_list_table_devices_tx(uuid)        to authenticated;
grant  execute on function public.pos_revoke_table_device_tx(uuid)       to authenticated;

-- ════════════════════════════════════════════════════════════════════
-- 驗證（單一 SELECT，不 raise —— 硬規則 1.8）
-- 這裡只驗結構；行為（計分、確認、撤銷、換莊）在
-- sql/checks/2026-09-23_驗電子計分的行為.sql（交易內造樣本、最後回滾）
-- ════════════════════════════════════════════════════════════════════
select * from (
  select 1 as n, '① 16 支函式都在，而且各只有一個版本' as 項目,
         case when (select count(*) from pg_proc where pronamespace = 'public'::regnamespace and proname in (
                      '_tbl_hash','_tbl_device','_tbl_ping','_tbl_round_state',
                      'tbl_state_tx','tbl_claim_seat_tx','tbl_release_seat_tx','tbl_set_order_tx',
                      'tbl_submit_hand_tx','tbl_confirm_hand_tx','tbl_cancel_pending_tx','tbl_undo_last_tx',
                      'tbl_start_round_tx','pos_pair_table_device_tx','pos_list_table_devices_tx',
                      'pos_revoke_table_device_tx')) = 16
              then '✅' else '🔴' end as 結果
  union all
  select 2, '② helper 前端叫不動（明確 ＋ PUBLIC）',
         case when not exists (select 1 from pg_proc p, aclexplode(p.proacl) a
                                where p.pronamespace = 'public'::regnamespace and p.proname like '\_tbl\_%' escape '\'
                                  and a.privilege_type = 'EXECUTE'
                                  and a.grantee in (0, 'anon'::regrole::oid, 'authenticated'::regrole::oid))
              then '✅' else '🔴' end
  union all
  select 3, '③ 平板那 9 支 anon 叫得動',
         case when (select count(*) from pg_proc p where p.pronamespace = 'public'::regnamespace
                     and p.proname like 'tbl\_%' escape '\'
                     and has_function_privilege('anon', p.oid, 'execute')) = 9
              then '✅' else '🔴' end
  union all
  select 4, '④ POS 那 3 支 anon 叫不動、authenticated 叫得動',
         case when not exists (select 1 from pg_proc p, aclexplode(p.proacl) a
                                where p.pronamespace = 'public'::regnamespace and p.proname like 'pos\_%table\_device%' escape '\'
                                  and a.privilege_type = 'EXECUTE' and a.grantee in (0, 'anon'::regrole::oid))
               and (select count(*) from pg_proc p where p.pronamespace = 'public'::regnamespace
                     and p.proname like 'pos\_%table\_device%' escape '\'
                     and has_function_privilege('authenticated', p.oid, 'execute')) = 3
              then '✅' else '🔴' end
  union all
  -- 結構性：沒有任何一支 tbl_* 的參數叫 p_member（身分不可以由呼叫端宣告）
  select 5, '⑤ 平板那 9 支沒有任何一支收 member_id',
         case when not exists (select 1 from pg_proc p where p.pronamespace = 'public'::regnamespace
                                and p.proname like 'tbl\_%' escape '\'
                                and pg_get_function_identity_arguments(p.oid) ~ 'p_member')
              then '✅' else '🔴' end
  union all
  select 6, '⑥ 將號改成「作廢的不算」的部分唯一',
         case when exists (select 1 from pg_indexes where indexname = 'uq_session_rounds_no')
               and not exists (select 1 from pg_constraint where conname = 'session_rounds_session_id_round_no_key')
              then '✅' else '🔴' end
  union all
  select 7, '⑦ 雜湊跟 pgcrypto 算的一樣（正對照）',
         case when public._tbl_hash('abc') = 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad'
              then '✅' else '🔴' end
) v order by n;
