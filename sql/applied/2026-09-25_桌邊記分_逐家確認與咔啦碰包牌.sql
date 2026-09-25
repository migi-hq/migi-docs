-- ════════════════════════════════════════════════════════════════════
-- 桌邊記分：照 A 案互動稿改後端（2026-09-25）
--   📄 設計：docs/02-POS與開桌/桌邊記分板設計.md §3（2026-09-23／24 拍板）
--   📄 互動稿：docs/_資產/桌邊記分板_A案互動.html
--
-- ① stake_levels.start_points   起始積分（使用者 09-25 選「跟著積分級距設」），回填 ＝ 底 × 20
-- ② scoring_patterns            三元牌最多 2、風牌最多 3；新增 MIGI（8 台，觸發 MIGI 成就）
-- ③ hands                       新增兩種結果（咔啦碰／包牌）＋ proposed_delta ＋ cancelled_seats
-- ④ _tbl_round_state            咔啦碰不推進；包牌「莊家包才下莊，閒家包莊家連莊」
-- ⑤ tbl_submit_hand_tx          送出四種：胡／自摸／咔啦碰／包牌（流局不變）
-- ⑥ tbl_confirm_hand_tx         🔴 逐家確認：確認的那一份當場入帳，取消的那一家不扣，互不影響
-- ⑦ tbl_state_tx                總分含「還在確認中但已經確認的那幾份」；多回起始積分、整場紀錄、照片頭像路徑
-- ⑧ _score_settle_tx            收桌時還沒確認完的那一局：照已確認的部分收尾；成就只認胡／自摸
-- ⑨ tbl_undo_last_tx            撤銷最後一筆改照時間挑（咔啦碰跟當局同局號）
--
-- 🔴 score_delta 的意思從此是「已經生效的」，proposed_delta 是「送出時提出的」。
--   同一局裡每一家各自確認 ⇒ score_delta 一家一家長出來；全部取消 ⇒ 永遠是 0。
--   ⚠ 所有加總（總分、這一將、收桌名次）一律加 score_delta，所以不用分辨狀態也不會算錯。
--
-- 簽名一支都沒改 ⇒ 全部 CREATE OR REPLACE，授權不會掉（硬規則 2）。
-- 驗證段在檔尾：只用 set_config ＋ 最後一支 SELECT，**不 raise**（硬規則 1.8）。
-- 行為測試另一份：sql/checks/2026-09-25_驗桌邊記分逐家確認.sql（交易內造一桌、跑完回滾）
-- ════════════════════════════════════════════════════════════════════

-- ── ① 起始積分 ──────────────────────────────────────────────────────
alter table public.stake_levels add column if not exists start_points integer;
update public.stake_levels set start_points = base * 20 where start_points is null;
alter table public.stake_levels alter column start_points set default 2000;
alter table public.stake_levels alter column start_points set not null;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'stake_levels_start_points_check') then
    alter table public.stake_levels add constraint stake_levels_start_points_check check (start_points >= 0);
  end if;
end $$;
comment on column public.stake_levels.start_points is
  '桌邊記分板上每位玩家開局的積分（頂部「總積分」）。畫面顯示 ＝ 這個數 ＋ 已生效的增減。2026-09-25 建立時回填 底 × 20（100/20 → 2000）。';

-- ── ② 牌型主檔 ──────────────────────────────────────────────────────
update public.scoring_patterns set max_count = 2, updated_at = now() where code = 'triplet_dragon';
update public.scoring_patterns set max_count = 3, updated_at = now() where code = 'triplet_wind';
insert into public.scoring_patterns
  (code, label, tai, max_count, group_key, needs_flower, result_only, dealer_only, conflicts, achievement_event, sort, is_active, note)
values
  ('migi', 'MIGI', 8, 1, 'special', false, null, false, '{}', 'migi_hu', 420, true,
   'MIGI 招牌牌型，固定 8 台（2026-09-24 拍板：MIGI 是一個牌型，舊的「牌型台數加總達標就算」作廢）')
on conflict (code) do update
  set label = excluded.label, tai = excluded.tai, max_count = excluded.max_count, group_key = excluded.group_key,
      achievement_event = excluded.achievement_event, sort = excluded.sort, is_active = true,
      note = excluded.note, updated_at = now();

-- ── ③ hands ─────────────────────────────────────────────────────────
alter table public.hands add column if not exists proposed_delta jsonb;
alter table public.hands add column if not exists cancelled_seats smallint[] not null default '{}';
comment on column public.hands.proposed_delta is
  '送出時提出的每家金額（誰付多少、誰收多少）。score_delta 則是已經生效的：每一家確認時才把他那一份搬過去。';
comment on column public.hands.cancelled_seats is
  '按了「取消」的座位：那一家那一份不扣、贏家也不收那一份。全部需要確認的人都取消 ⇒ 這一局不算（status = rejected）。';

alter table public.hands drop constraint if exists hands_result_check;
alter table public.hands add constraint hands_result_check
  check (result = any (array['tsumo','ron','draw','kala','bao']));

/* 座位欄位在五種結果裡的意思：
     ron    winner＝胡的人   deal_in＝放槍的人
     tsumo  winner＝胡的人   deal_in＝空
     draw   兩個都空
     kala   winner＝收的人   deal_in＝付的人（按咔啦碰的那一台）
     bao    winner＝空       deal_in＝付的人（按我包牌的那一台） */
alter table public.hands drop constraint if exists hands_result_shape;
alter table public.hands add constraint hands_result_shape check (
     (result = 'ron'   and winner_seat is not null and deal_in_seat is not null and winner_seat <> deal_in_seat)
  or (result = 'tsumo' and winner_seat is not null and deal_in_seat is null)
  or (result = 'draw'  and winner_seat is null     and deal_in_seat is null)
  or (result = 'kala'  and winner_seat is not null and deal_in_seat is not null and winner_seat <> deal_in_seat)
  or (result = 'bao'   and winner_seat is null     and deal_in_seat is not null));

-- 咔啦碰跟當局共用局號（它不是一局），所以「同一將同一局號只能一筆」要把它排除
drop index if exists public.uq_hands_confirmed_no;
create unique index uq_hands_confirmed_no on public.hands (round_id, hand_no)
  where status = 'confirmed' and result <> 'kala';

-- ── ④ 這一將打到哪 ──────────────────────────────────────────────────
create or replace function public._tbl_round_state(p_round_id uuid)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'public'
as $fn$
declare
  v_first smallint; v_dealer smallint; v_wind smallint := 1; v_ren smallint := 0;
  v_pass smallint := 0; v_n int := 0; v_fin boolean := false; h record; v_stay boolean;
begin
  select first_dealer_seat into v_first from session_rounds where id = p_round_id;
  if v_first is null then return null; end if;
  v_dealer := v_first;
  /* 只看已生效的局；咔啦碰不是一局（不推進局數、莊家、連莊） */
  for h in select result, winner_seat, deal_in_seat from hands
            where round_id = p_round_id and status = 'confirmed' and result <> 'kala'
            order by hand_no, created_at
  loop
    v_n := v_n + 1;
    /* 誰留莊：
         流局              莊家連莊
         胡／自摸          胡的人是莊家 ⇒ 連莊，否則換莊
         包牌（09-24 拍板）莊家包牌才下莊；閒家包牌莊家繼續連莊 */
    v_stay := case h.result
                when 'draw' then true
                when 'bao'  then h.deal_in_seat <> v_dealer
                else h.winner_seat = v_dealer
              end;
    if v_stay then
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
end $fn$;

-- ── ⑤ 送出 ──────────────────────────────────────────────────────────
create or replace function public.tbl_submit_hand_tx(p_token text, p_result text, p_deal_in_seat smallint default null::smallint, p_patterns jsonb default '[]'::jsonb)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $fn$
/* p_result：
     ron    我胡了，p_deal_in_seat ＝ 放槍的人（要選牌型）
     tsumo  我自摸（要選牌型；沒選門清自摸就自動帶自摸 1 台）
     draw   流局：只有按的人確認，直接生效
     kala   咔啦碰：我直接付 p_deal_in_seat 那一家 1 台（不算底、不加莊家台），收的人確認
     bao    我包牌：我付另外三家各 1 底 3 台（莊家有牽涉再加莊家台），收的三家各自確認
   🔴 付錢的那一方永遠是「確認的人」以外的那一台：胡／自摸是別人付我、咔啦碰與包牌是我付別人。 */
declare
  d public.table_devices; s public.table_sessions; v_me smallint; v_round public.session_rounds;
  v_st jsonb; v_dealer smallint; v_ren smallint; v_base int; v_unit int;
  v_pats jsonb := '[]'::jsonb; v_codes text[] := '{}'; e jsonb; p public.scoring_patterns;
  v_n int; v_tai int := 0; v_extra int;
  v_delta jsonb; v_zero jsonb := '{"1":0,"2":0,"3":0,"4":0}'::jsonb;
  v_sum int := 0; v_pay int; v_payers smallint[]; i smallint;
  v_need smallint[] := '{}'; v_hand uuid; v_winner smallint;
  c_kala_tai constant int := 1;   -- 咔啦碰固定 1 台
  c_bao_tai  constant int := 3;   -- 包牌 1 底 3 台
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
    return jsonb_build_object('ok', false, 'reason', 'pending_exists', 'message', '上一局還有人沒確認');
  end if;

  if p_result is null or p_result not in ('tsumo', 'ron', 'draw', 'kala', 'bao') then
    return jsonb_build_object('ok', false, 'reason', 'bad_result', 'message', '動作不對');
  end if;

  v_st := public._tbl_round_state(v_round.id);
  v_dealer := (v_st ->> 'dealer_seat')::smallint;
  v_ren := (v_st ->> 'renzhuang')::smallint;
  v_extra := 1 + 2 * v_ren;   -- 莊家台：連 N 拉 N（2026-09-23）

  select sl.base, sl.tai into v_base, v_unit
    from stake_levels sl where sl.id = s.stake_level_id;
  if v_base is null or v_unit is null then
    return jsonb_build_object('ok', false, 'reason', 'no_stake', 'message', '這桌沒有設定積分級距，請找店員');
  end if;

  -- ── 流局：只有按的人確認，直接生效 ──
  if p_result = 'draw' then
    insert into hands (org_id, session_id, round_id, hand_no, wind, dealer_seat, renzhuang,
                       result, base, tai_unit, score_delta, proposed_delta, status, need_confirm,
                       submitted_seat, submitted_device_id, confirmed_at)
    values (s.org_id, s.id, v_round.id, (v_st ->> 'hand_no')::int, (v_st ->> 'wind')::smallint,
            v_dealer, v_ren, 'draw', v_base, v_unit, v_zero, v_zero, 'confirmed', '{}', v_me, d.id, now())
    returning id into v_hand;
    if (public._tbl_round_state(v_round.id) ->> 'finished')::boolean then
      update session_rounds set status = 'finished', finished_at = now() where id = v_round.id;
    end if;
    perform public._tbl_ping(s.id);
    return jsonb_build_object('ok', true, 'hand_id', v_hand, 'status', 'confirmed');
  end if;

  -- ── 咔啦碰：我付那一家 1 台，他確認 ──
  if p_result = 'kala' then
    if p_deal_in_seat is null or p_deal_in_seat not between 1 and 4 or p_deal_in_seat = v_me then
      return jsonb_build_object('ok', false, 'reason', 'bad_target', 'message', '請選要付給誰');
    end if;
    v_pay := v_unit * c_kala_tai;
    v_delta := jsonb_set(jsonb_set(v_zero, array[p_deal_in_seat::text], to_jsonb(v_pay)),
                         array[v_me::text], to_jsonb(-v_pay));
    insert into hands (org_id, session_id, round_id, hand_no, wind, dealer_seat, renzhuang,
                       result, winner_seat, deal_in_seat, patterns, tai_pattern,
                       base, tai_unit, score_delta, proposed_delta, status, need_confirm,
                       submitted_seat, submitted_device_id)
    values (s.org_id, s.id, v_round.id, (v_st ->> 'hand_no')::int, (v_st ->> 'wind')::smallint,
            v_dealer, v_ren, 'kala', p_deal_in_seat, v_me, '[]'::jsonb, c_kala_tai,
            v_base, v_unit, v_zero, v_delta, 'pending', array[p_deal_in_seat], v_me, d.id)
    returning id into v_hand;
    perform public._tbl_ping(s.id);
    return jsonb_build_object('ok', true, 'hand_id', v_hand, 'status', 'pending',
                              'proposed_delta', v_delta, 'need_confirm', to_jsonb(array[p_deal_in_seat]));
  end if;

  -- ── 包牌：我付另外三家，三家各自確認 ──
  if p_result = 'bao' then
    v_payers := array(select g::smallint from generate_series(1, 4) g where g <> v_me);   -- 這裡是「收的人」
    v_delta := v_zero;
    foreach i in array v_payers loop
      v_pay := v_base + v_unit * (c_bao_tai + case when v_me = v_dealer or i = v_dealer then v_extra else 0 end);
      v_delta := jsonb_set(v_delta, array[i::text], to_jsonb(v_pay));
      v_sum := v_sum + v_pay;
    end loop;
    v_delta := jsonb_set(v_delta, array[v_me::text], to_jsonb(-v_sum));
    insert into hands (org_id, session_id, round_id, hand_no, wind, dealer_seat, renzhuang,
                       result, winner_seat, deal_in_seat, patterns, tai_pattern,
                       base, tai_unit, score_delta, proposed_delta, status, need_confirm,
                       submitted_seat, submitted_device_id)
    values (s.org_id, s.id, v_round.id, (v_st ->> 'hand_no')::int, (v_st ->> 'wind')::smallint,
            v_dealer, v_ren, 'bao', null, v_me, '[]'::jsonb, c_bao_tai,
            v_base, v_unit, v_zero, v_delta, 'pending', v_payers, v_me, d.id)
    returning id into v_hand;
    perform public._tbl_ping(s.id);
    return jsonb_build_object('ok', true, 'hand_id', v_hand, 'status', 'pending',
                              'proposed_delta', v_delta, 'need_confirm', to_jsonb(v_payers));
  end if;

  -- ── 胡／自摸：贏家一律是這台平板的座位 ──
  v_winner := v_me;
  if p_result = 'ron' then
    if p_deal_in_seat is null or p_deal_in_seat not between 1 and 4 or p_deal_in_seat = v_winner then
      return jsonb_build_object('ok', false, 'reason', 'bad_deal_in', 'message', '請選是誰放槍');
    end if;
  end if;

  /* 台數只能從牌型換算（2026-09-23 起沒有第二條路）。
     ⚠ 空陣列是合法的：放槍胡一手沒有任何台的雜牌只收底（畫面上的「沒台」）。 */
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

  /* 每個付款人付：底 ＋ 台 ×（牌型台數 ＋ 莊家台）；莊家台只在「胡的人或付的人是莊家」時加 */
  if p_result = 'ron' then
    v_payers := array[p_deal_in_seat];
  else
    v_payers := array(select g::smallint from generate_series(1, 4) g where g <> v_winner);
  end if;
  v_need := v_payers;
  v_delta := v_zero;
  foreach i in array v_payers loop
    v_pay := v_base + v_unit * (v_tai + case when v_winner = v_dealer or i = v_dealer then v_extra else 0 end);
    v_delta := jsonb_set(v_delta, array[i::text], to_jsonb(-v_pay));
    v_sum := v_sum + v_pay;
  end loop;
  v_delta := jsonb_set(v_delta, array[v_winner::text], to_jsonb(v_sum));

  insert into hands (org_id, session_id, round_id, hand_no, wind, dealer_seat, renzhuang,
                     result, winner_seat, deal_in_seat, patterns, tai_pattern,
                     base, tai_unit, score_delta, proposed_delta, status, need_confirm, submitted_seat, submitted_device_id)
  values (s.org_id, s.id, v_round.id, (v_st ->> 'hand_no')::int, (v_st ->> 'wind')::smallint,
          v_dealer, v_ren, p_result, v_winner, case when p_result = 'ron' then p_deal_in_seat end,
          v_pats, v_tai, v_base, v_unit, v_zero, v_delta, 'pending', v_need, v_me, d.id)
  returning id into v_hand;

  perform public._tbl_ping(s.id);
  return jsonb_build_object('ok', true, 'hand_id', v_hand, 'status', 'pending',
                            'tai_pattern', v_tai, 'proposed_delta', v_delta, 'need_confirm', to_jsonb(v_need));
end $fn$;

-- ── ⑥ 逐家確認 ──────────────────────────────────────────────────────
create or replace function public.tbl_confirm_hand_tx(p_token text, p_hand_id uuid, p_accept boolean)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $fn$
/* 🔴 每一家各自確認、各自取消，互不影響（2026-09-23／24 拍板）：
     確認 ＝ 我這一份當場入帳（我的 score_delta 與對方的 score_delta 同時變）
     取消 ＝ 我這一份不算，對方也不收這一份
   最後一家回應完這一局才結束：至少一家確認 ⇒ confirmed（推進局數）；全部取消 ⇒ rejected（這局不算）。 */
declare
  d public.table_devices; v_session uuid; v_me smallint; h public.hands;
  v_other smallint; v_amt int; v_delta jsonb; v_ok smallint[]; v_no smallint[]; v_status text;
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
    return jsonb_build_object('ok', false, 'reason', 'not_pending', 'message', '這一局已經處理過了');
  end if;
  if v_me is null or not (v_me = any(h.need_confirm)) then
    return jsonb_build_object('ok', false, 'reason', 'not_yours', 'message', '這一局不需要你確認');
  end if;
  if v_me = any(h.confirmed_seats) or v_me = any(h.cancelled_seats) then
    return jsonb_build_object('ok', true, 'already', true);
  end if;

  -- 這一份的另一方：胡／自摸是胡的人，咔啦碰與包牌是付的人
  v_other := case when h.result in ('ron', 'tsumo') then h.winner_seat else h.deal_in_seat end;
  v_ok := h.confirmed_seats;
  v_no := h.cancelled_seats;
  v_delta := h.score_delta;

  if p_accept then
    v_amt := coalesce((h.proposed_delta ->> v_me::text)::int, 0);
    v_delta := jsonb_set(v_delta, array[v_me::text], to_jsonb(coalesce((v_delta ->> v_me::text)::int, 0) + v_amt));
    v_delta := jsonb_set(v_delta, array[v_other::text], to_jsonb(coalesce((v_delta ->> v_other::text)::int, 0) - v_amt));
    v_ok := v_ok || v_me;
  else
    v_no := v_no || v_me;
  end if;

  -- 還有人沒回應 ⇒ 繼續等
  if exists (select 1 from unnest(h.need_confirm) x where not (x = any(v_ok)) and not (x = any(v_no))) then
    update hands set score_delta = v_delta, confirmed_seats = v_ok, cancelled_seats = v_no where id = h.id;
    perform public._tbl_ping(v_session);
    return jsonb_build_object('ok', true, 'status', 'pending', 'accepted', p_accept);
  end if;

  v_status := case when cardinality(v_ok) > 0 then 'confirmed' else 'rejected' end;
  update hands
     set score_delta = v_delta, confirmed_seats = v_ok, cancelled_seats = v_no, status = v_status,
         confirmed_at = case when v_status = 'confirmed' then now() end,
         rejected_seat = case when v_status = 'rejected' then v_me end
   where id = h.id;
  if v_status = 'confirmed' and h.result <> 'kala'
     and (public._tbl_round_state(h.round_id) ->> 'finished')::boolean then
    update session_rounds set status = 'finished', finished_at = now() where id = h.round_id;
  end if;
  perform public._tbl_ping(v_session);
  return jsonb_build_object('ok', true, 'status', v_status, 'accepted', p_accept);
end $fn$;

-- ── ⑦ 整桌狀態 ──────────────────────────────────────────────────────
create or replace function public.tbl_state_tx(p_token text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $fn$
declare
  d public.table_devices; s public.table_sessions; v_table text; v_store text;
  v_my_seat smallint; v_my_player uuid; v_round public.session_rounds; v_state jsonb;
  v_players jsonb; v_pending jsonb; v_history jsonb; v_totals jsonb; v_round_totals jsonb;
  v_rounds jsonb; v_catalog jsonb; v_stake jsonb; v_last_reject jsonb; v_log jsonb;
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

  /* 不回 member_id —— 平板認人用的是 player_id（session_players.id），
     會員 uuid 不需要出現在一台四個陌生人碰一整晚的裝置上。 */
  select coalesce(jsonb_agg(jsonb_build_object(
           'player_id', sp.id, 'seat', sp.seat, 'name', m.display_name,
           'rank', m.rank, 'title', m.title,
           'avatar_url', m.avatar_url, 'avatar_source', m.avatar_source, 'avatar_bear', m.avatar_bear,
           'avatar_photo_path', m.avatar_photo_path,   -- 上傳照片的人要靠它才畫得出來（2026-09-25 補）
           'bound', sp.device_id is not null, 'is_me', sp.device_id = d.id)
         order by sp.seat nulls last, sp.joined_at), '[]'::jsonb)
    into v_players
    from session_players sp join members m on m.id = sp.member_id
   where sp.session_id = s.id and sp.left_at is null;

  select case when sl.id is null then null else jsonb_build_object(
           'label', sl.label, 'base', sl.base, 'tai', sl.tai, 'hygiene', sl.is_hygiene,
           'start_points', sl.start_points) end
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

  /* 分數：加 score_delta（＝已經生效的）。還在確認中的那一局，已經確認的那幾份也算進去
     —— 逐家確認的意思就是「確認了當場入帳」。 */
  select coalesce(jsonb_object_agg(k, tot), '{}'::jsonb) into v_totals
    from (select e.key as k, sum(e.value::int) as tot
            from hands h, jsonb_each_text(h.score_delta) e
           where h.session_id = s.id and h.status in ('confirmed', 'pending') group by e.key) x;
  if v_round.id is not null then
    select coalesce(jsonb_object_agg(k, tot), '{}'::jsonb) into v_round_totals
      from (select e.key as k, sum(e.value::int) as tot
              from hands h, jsonb_each_text(h.score_delta) e
             where h.round_id = v_round.id and h.status in ('confirmed', 'pending') group by e.key) x;

    select jsonb_build_object(
             'hand_id', h.id, 'result', h.result, 'winner_seat', h.winner_seat,
             'deal_in_seat', h.deal_in_seat, 'tai_pattern', h.tai_pattern,
             'patterns', h.patterns, 'score_delta', h.score_delta, 'proposed_delta', h.proposed_delta,
             'need_confirm', to_jsonb(h.need_confirm), 'confirmed_seats', to_jsonb(h.confirmed_seats),
             'cancelled_seats', to_jsonb(h.cancelled_seats),
             'submitted_seat', h.submitted_seat, 'hand_no', h.hand_no, 'wind', h.wind,
             'dealer_seat', h.dealer_seat, 'renzhuang', h.renzhuang, 'at', h.created_at,
             'i_must_confirm', v_my_seat = any(h.need_confirm)
                               and not (v_my_seat = any(h.confirmed_seats))
                               and not (v_my_seat = any(h.cancelled_seats)))
      into v_pending
      from hands h where h.round_id = v_round.id and h.status = 'pending';

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
                     'deal_in_seat', h.deal_in_seat, 'tai_pattern', h.tai_pattern,
                     'patterns', h.patterns, 'score_delta', h.score_delta) as j
              from hands h where h.round_id = v_round.id and h.status = 'confirmed' and h.result <> 'kala'
             order by h.hand_no desc limit 12) x;
  end if;

  /* 整場紀錄（牌局紀錄頁）：還在確認中、已生效、全部取消的都列，撤銷掉的不列 */
  select coalesce(jsonb_agg(x.j order by x.at desc), '[]'::jsonb) into v_log
    from (select h.created_at as at, jsonb_build_object(
                   'hand_id', h.id, 'round_no', r.round_no, 'wind', h.wind, 'hand_no', h.hand_no,
                   'dealer_seat', h.dealer_seat, 'renzhuang', h.renzhuang, 'result', h.result,
                   'winner_seat', h.winner_seat, 'deal_in_seat', h.deal_in_seat,
                   'submitted_seat', h.submitted_seat, 'patterns', h.patterns, 'tai_pattern', h.tai_pattern,
                   'proposed_delta', coalesce(h.proposed_delta, h.score_delta), 'score_delta', h.score_delta,
                   'need_confirm', to_jsonb(h.need_confirm), 'confirmed_seats', to_jsonb(h.confirmed_seats),
                   'cancelled_seats', to_jsonb(h.cancelled_seats), 'status', h.status, 'at', h.created_at) as j
            from hands h join session_rounds r on r.id = h.round_id
           where h.session_id = s.id and h.status in ('pending', 'confirmed', 'rejected')
           order by h.created_at desc limit 300) x;

  select coalesce(jsonb_agg(jsonb_build_object('round_no', r.round_no, 'status', r.status)
                            order by r.round_no), '[]'::jsonb)
    into v_rounds
    from session_rounds r where r.session_id = s.id and r.status <> 'voided';

  return jsonb_build_object('ok', true,
    'device', jsonb_build_object('label', d.label, 'table', v_table, 'store', v_store),
    'session', jsonb_build_object(
      'id', s.id, 'channel', s.score_channel, 'game_type', s.game_type, 'flower', s.flower,
      'planned_rounds', s.planned_rounds, 'stake', v_stake, 'started_at', s.started_at,
      'supported', coalesce(s.game_type, '台麻') = '台麻'),
    'players', v_players, 'my_seat', v_my_seat, 'my_player_id', v_my_player,
    'order_set', (select count(*) from session_players where session_id = s.id and left_at is null and seat is not null) = 4,
    'rounds', v_rounds,
    'round', case when v_round.id is null then null else
               jsonb_build_object('round_no', v_round.round_no, 'status', v_round.status,
                                  'first_dealer_seat', v_round.first_dealer_seat) || v_state end,
    'totals', coalesce(v_totals, '{}'::jsonb), 'round_totals', coalesce(v_round_totals, '{}'::jsonb),
    'pending', v_pending, 'last_reject', v_last_reject, 'history', coalesce(v_history, '[]'::jsonb),
    'log', coalesce(v_log, '[]'::jsonb), 'patterns', v_catalog);
end $fn$;

-- ── ⑧ 收桌結算 ──────────────────────────────────────────────────────
create or replace function public._score_settle_tx(p_session_id uuid)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $fn$
declare
  v_seatmem jsonb; v_hyg boolean; v_payload jsonb := '[]'::jsonb; v_ranks jsonb;
  v_totals jsonb; v_res jsonb; v_rated boolean := false; v_nfin int; v_nhands int;
  r record; h record; e record; v_winner uuid; v_idem text; v_fired int := 0;
begin
  -- ⑤ 先放掉平板（就算這桌一把都沒記也要放）
  update session_players set device_id = null
   where session_id = p_session_id and device_id is not null;

  /* ① 還在確認中的那一局：桌都收了，不會有人再按。
       已經有人確認 ⇒ 照已確認的部分收尾（那幾份早就入帳了）；一個都沒有 ⇒ 撤銷 */
  update hands set status = case when cardinality(confirmed_seats) > 0 then 'confirmed' else 'undone' end,
                   confirmed_at = case when cardinality(confirmed_seats) > 0 then now() end,
                   undone_at    = case when cardinality(confirmed_seats) > 0 then null else now() end
   where session_id = p_session_id and status = 'pending';

  select count(*) into v_nhands from hands
   where session_id = p_session_id and status = 'confirmed' and result <> 'kala';
  if v_nhands = 0 then
    return jsonb_build_object('ok', false, 'reason', 'no_hands');
  end if;

  select jsonb_object_agg(seat::text, member_id) into v_seatmem
    from session_players where session_id = p_session_id and seat is not null;
  if coalesce((select count(*) from jsonb_object_keys(v_seatmem)), 0) <> 4 then
    return jsonb_build_object('ok', false, 'reason', 'no_seats');
  end if;

  select coalesce(sl.is_hygiene, false) into v_hyg
    from table_sessions ts left join stake_levels sl on sl.id = ts.stake_level_id
   where ts.id = p_session_id;

  -- ② 每一將的名次（只算打完的將；同分座位小的在前）
  for r in select id from session_rounds
            where session_id = p_session_id and status = 'finished' order by round_no
  loop
    select jsonb_agg(jsonb_build_object('member_id', v_seatmem ->> x.seat::text, 'finish_rank', x.rk) order by x.rk)
      into v_ranks
      from (select g.seat, row_number() over (order by coalesce(t.tot, 0) desc, g.seat) as rk
              from generate_series(1, 4) as g(seat)
              left join (select e2.key::int as seat, sum(e2.value::int) as tot
                           from hands h2, jsonb_each_text(h2.score_delta) e2
                          where h2.round_id = r.id and h2.status = 'confirmed'
                          group by 1) t on t.seat = g.seat) x;
    v_payload := v_payload || jsonb_build_array(v_ranks);
  end loop;
  v_nfin := jsonb_array_length(v_payload);

  -- 整場每個座位的總分（所有生效的，包含咔啦碰與沒打完的那一將）
  select coalesce(jsonb_object_agg(k, tot), '{}'::jsonb) into v_totals
    from (select e2.key as k, sum(e2.value::int) as tot
            from hands h2, jsonb_each_text(h2.score_delta) e2
           where h2.session_id = p_session_id and h2.status = 'confirmed' group by 1) x;

  -- 段位分：未滿 2 將由 apply_session_rounds_tx 自己擋（too_few_rounds）
  if v_nfin >= 2 then
    v_res := public.apply_session_rounds_tx(p_session_id, v_payload);
    v_rated := coalesce((v_res ->> 'ok')::boolean, false);
  end if;

  -- ③ 名次與桌上積分：只在段位分真的算了才寫（兩者要嘛都有要嘛都沒有，同 placeholder）
  if v_rated then
    update session_players sp
       set finish_rank = x.rk,
           final_score = case when v_hyg then null else x.tot end
      from (select g.seat, coalesce((v_totals ->> g.seat::text)::int, 0) as tot,
                   row_number() over (order by coalesce((v_totals ->> g.seat::text)::int, 0) desc, g.seat) as rk
              from generate_series(1, 4) as g(seat)) x
     where sp.session_id = p_session_id and sp.seat = x.seat;
  end if;

  -- ④ 成就（整段吞例外：名次已經算好了，成就失敗不可以把名次一起回滾）
  begin
    for h in select * from hands where session_id = p_session_id and status = 'confirmed' order by created_at loop
      v_idem := 'hand:' || h.id::text;
      /* 只有胡與自摸算「胡牌」；咔啦碰的收款人、包牌的收款人都不是胡牌 */
      if h.result in ('ron', 'tsumo') then
        v_winner := (v_seatmem ->> h.winner_seat::text)::uuid;
        perform public.fire_event_tx(v_winner, 'hand_won', 1, null, v_idem);
        v_fired := v_fired + 1;
        if h.result = 'tsumo' then
          perform public.fire_event_tx(v_winner, 'hand_tsumo', 1, null, v_idem);
        end if;
        -- 「第一次胡出可計台的牌型」：自摸那 1 台不算牌型
        if exists (select 1 from jsonb_array_elements(h.patterns) x where x ->> 'code' <> 'zimo') then
          perform public.fire_event_tx(v_winner, 'hand_pattern_any', 1, null, v_idem);
        end if;
        /* 每個牌型各自的事件（主檔 achievement_event）。
           MIGI 成就也走這裡：牌型 migi 的事件就是 MIGI 成就聽的那一個（2026-09-25 起，
           不再用「牌型台數加總」判斷） */
        for e in select distinct sp.achievement_event as ev
                   from jsonb_array_elements(h.patterns) x
                   join scoring_patterns sp on sp.code = x ->> 'code'
                  where sp.achievement_event is not null
        loop
          perform public.fire_event_tx(v_winner, e.ev, 1, null, v_idem);
        end loop;
      end if;
      -- 連莊：這一局開打時莊家已經在連莊（咔啦碰不是一局）
      if h.renzhuang >= 1 and h.result <> 'kala' then
        perform public.fire_event_tx((v_seatmem ->> h.dealer_seat::text)::uuid, 'renzhuang', 1, null, v_idem);
      end if;
    end loop;
  exception when others then
    null;
  end;

  return jsonb_build_object('ok', true, 'rated', v_rated, 'rounds_finished', v_nfin,
                            'hands', v_nhands, 'fired', v_fired, 'hygiene', v_hyg);
end $fn$;

-- ── ⑨ 撤銷最後一筆：照時間挑，不照局號（咔啦碰跟當局同局號，照局號會挑錯） ──
create or replace function public.tbl_undo_last_tx(p_token text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $fn$
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
    return jsonb_build_object('ok', false, 'reason', 'pending_exists', 'message', '上一局還有人沒確認，先處理那一局');
  end if;

  select * into r from session_rounds
   where session_id = v_session and status <> 'voided' order by round_no desc limit 1;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'nothing', 'message', '還沒有可以撤銷的');
  end if;

  -- 最新一將一局都沒打 ⇒ 作廢它，撤銷的對象變成上一將的最後一筆
  if not exists (select 1 from hands where round_id = r.id and status = 'confirmed') and r.round_no > 1 then
    update session_rounds set status = 'voided' where id = r.id;
    select * into r from session_rounds
     where session_id = v_session and status <> 'voided' order by round_no desc limit 1;
  end if;

  select id into v_hand from hands
   where round_id = r.id and status = 'confirmed' order by created_at desc limit 1;
  if v_hand is null then
    return jsonb_build_object('ok', false, 'reason', 'nothing', 'message', '還沒有可以撤銷的');
  end if;

  update hands set status = 'undone', undone_at = now() where id = v_hand;
  update session_rounds set status = 'playing', finished_at = null where id = r.id and status = 'finished';

  perform public._tbl_ping(v_session);
  return jsonb_build_object('ok', true, 'undone_hand_id', v_hand);
end $fn$;

-- ════════════════════════════════════════════════════════════════════
-- 驗證（不 raise；訊息用 set_config 帶到最後一支 SELECT）
-- ⚠ 這一段驗的是「交易內」；提交後 Claude 會另外用唯讀查詢複查線上（硬規則 1.8）
-- ════════════════════════════════════════════════════════════════════
do $$
declare v text := ''; n int; t text; ok boolean;
begin
  -- ① 起始積分
  select count(*) into n from stake_levels where start_points is null;
  select start_points::text into t from stake_levels where label = '100/20' and deleted_at is null limit 1;
  v := v || case when n = 0 and t = '2000' then '✅' else '🔴' end
         || ' ① 起始積分：空值 ' || n || ' 筆，100/20 ＝ ' || coalesce(t, '（查無 100/20）') || E'\n';

  -- ② 牌型
  select (select max_count from scoring_patterns where code = 'triplet_dragon') = 2
     and (select max_count from scoring_patterns where code = 'triplet_wind') = 3
     and exists (select 1 from scoring_patterns where code = 'migi' and tai = 8 and is_active and achievement_event = 'migi_hu')
    into ok;
  v := v || case when ok then '✅' else '🔴' end || ' ② 三元牌上限 2、風牌上限 3、MIGI 8 台並接上 MIGI 成就' || E'\n';

  -- ③ hands 結構
  select pg_get_constraintdef(oid) into t from pg_constraint where conname = 'hands_result_check';
  ok := t like '%kala%' and t like '%bao%';
  select pg_get_constraintdef(oid) into t from pg_constraint where conname = 'hands_result_shape';
  ok := ok and t like '%kala%' and t like '%bao%';
  select indexdef into t from pg_indexes where indexname = 'uq_hands_confirmed_no';
  ok := ok and t like '%kala%';
  ok := ok and exists (select 1 from information_schema.columns where table_name = 'hands' and column_name = 'proposed_delta')
           and exists (select 1 from information_schema.columns where table_name = 'hands' and column_name = 'cancelled_seats');
  v := v || case when ok then '✅' else '🔴' end || ' ③ hands：兩種新結果、兩個新欄位、局號唯一索引排除咔啦碰' || E'\n';

  -- ④ 每支函式只有一個版本（沒有長出多載）
  select count(*) into n from pg_proc
   where pronamespace = 'public'::regnamespace
     and proname in ('_tbl_round_state','tbl_submit_hand_tx','tbl_confirm_hand_tx','tbl_state_tx','_score_settle_tx','tbl_undo_last_tx');
  v := v || case when n = 6 then '✅' else '🔴' end || ' ④ 六支函式各一個版本（共 ' || n || '，應為 6）' || E'\n';

  -- ⑤ 授權沒掉：平板呼叫的三支 anon 叫得動；內部兩支 anon 叫不動
  select has_function_privilege('anon', 'public.tbl_submit_hand_tx(text,text,smallint,jsonb)', 'execute')
     and has_function_privilege('anon', 'public.tbl_confirm_hand_tx(text,uuid,boolean)', 'execute')
     and has_function_privilege('anon', 'public.tbl_state_tx(text)', 'execute')
     and has_function_privilege('anon', 'public.tbl_undo_last_tx(text)', 'execute')
     and not has_function_privilege('anon', 'public._tbl_round_state(uuid)', 'execute')
     and not has_function_privilege('anon', 'public._score_settle_tx(uuid)', 'execute')
    into ok;
  v := v || case when ok then '✅' else '🔴' end || ' ⑤ 授權：平板四支 anon 可叫、內部兩支 anon 不可叫' || E'\n';

  -- ⑥ 收桌結算：成就只在胡／自摸時發（看判斷式，不是看註解）
  select pg_get_functiondef('public._score_settle_tx(uuid)'::regprocedure) ~ 'if h\.result in \(''ron'', ''tsumo''\) then' into ok;
  v := v || case when ok then '✅' else '🔴' end || ' ⑥ 收桌結算：胡牌類成就只在胡／自摸時發' || E'\n';

  perform set_config('migi.v', v, true);
end $$;
select coalesce(nullif(current_setting('migi.v', true), ''), '🔴 沒有驗證訊息（上面的 DO 沒跑完）') as "驗證";
