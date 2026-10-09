-- ════════════════════════════════════════════════════════════════════
-- 2026-10-09 智慧計分板「分紅」接上後端
-- ════════════════════════════════════════════════════════════════════
-- 使用者：「分紅異常，顯示系統忙碌」
--
-- 原因：分紅 2026-09-27 只做了計分板畫面（預覽），後端**從來沒做**：
--   計分板送 tbl_submit_hand_tx 時多帶 p_tai，而那支沒有這個參數 ⇒ 找不到函式 ⇒ 「系統忙碌中」。
--   不是壞掉，是從來沒接通過。
--
-- 規則（照計分板 BonusSheet 的設計）
--   · 我分給某一家 N 台：金額 ＝ N × 每台積分（不算底、不加莊家台）
--   · **付的人自己按確認就生效，對方不用再按**（白給的，不需要對方同意）
--   · 不是一局：不推進局數、莊家、連莊（同咔啦碰）
--   · 積分會算進最後的成績（結算是把所有生效那筆的積分加總）
--   · 不發胡牌類成就（那些只看胡與自摸）
--   · 不可以把自己分到歸零或負數 ⇒ 擋下並告訴他剩多少
--   · **只能分 10 的倍數**，10～990 台（2026-10-09 使用者；計分板鍵盤打的數字自動 ×10：打 12 ＝ 120 台）
--
-- 做法
--   ① hands 的結果多一種 'bonus'（兩條 CHECK 一起改；形狀同咔啦碰：winner＝收的人、deal_in＝付的人）
--   ② 新函式 tbl_bonus_tx(p_token, p_to_seat, p_tai)——不去動原本那支大的送出函式（改簽名要整支 DROP 重建）
--      🔴 先寫成「待確認」再改成「已生效」：爆卡檢查（trg_hands_bust_detect）只在狀態變成已生效那一刻跑，
--        直接寫成已生效會跳過它
--   ③ 5 支函式裡 6 處「不是咔啦碰才算一局」改成「不是咔啦碰也不是分紅」
--      （_ach_session_events／_score_settle_tx ×2／_tbl_round_state／_tbl_state_for_device／tbl_confirm_hand_tx）
--      用 regexp 換，換的數量對不上就整份不提交（下面 guard）
-- ════════════════════════════════════════════════════════════════════

-- ① 結果多一種 bonus
alter table public.hands drop constraint if exists hands_result_check;
alter table public.hands add constraint hands_result_check
  check (result = any (array['tsumo', 'ron', 'draw', 'kala', 'bao', 'bonus']));

alter table public.hands drop constraint if exists hands_result_shape;
alter table public.hands add constraint hands_result_shape check (
     (result = 'ron'   and winner_seat is not null and deal_in_seat is not null and winner_seat <> deal_in_seat)
  or (result = 'tsumo' and winner_seat is not null and deal_in_seat is null)
  or (result = 'draw'  and winner_seat is null     and deal_in_seat is null)
  or (result = 'kala'  and winner_seat is not null and deal_in_seat is not null and winner_seat <> deal_in_seat)
  or (result = 'bao'   and winner_seat is null     and deal_in_seat is not null)
  -- 分紅：winner_seat＝收的人、deal_in_seat＝付的人（同咔啦碰的形狀）
  or (result = 'bonus' and winner_seat is not null and deal_in_seat is not null and winner_seat <> deal_in_seat));

-- ② 分紅
create or replace function public.tbl_bonus_tx(p_token text, p_to_seat smallint, p_tai integer)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
/* 分紅（2026-10-09）：我分給 p_to_seat 那一家 p_tai 台，金額 ＝ 台數 × 每台積分。
   付的人自己按就生效，對方不用確認。不是一局（不推進局數、莊家、連莊）。
   前置檢查與 tbl_submit_hand_tx 相同（開桌、包桌時間、台麻、座位、這一將在打、沒有待確認）。 */
declare
  d public.table_devices; s public.table_sessions; v_me smallint; v_round public.session_rounds;
  v_st jsonb; v_base int; v_unit int; v_pay int; v_have int; v_hand uuid;
  v_delta jsonb; v_zero jsonb := '{"1":0,"2":0,"3":0,"4":0}'::jsonb;
  c_step    constant int := 10;    -- 只能分 10 的倍數（2026-10-09 使用者）；計分板 BONUS_STEP 同值
  c_max_tai constant int := 990;   -- 計分板鍵盤最多打 99（×10）＝ 990 台，兩邊要一起改
begin
  d := public._tbl_device(p_token);
  select * into s from table_sessions
   where table_id = d.table_id and status = 'open' and deleted_at is null;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'no_session', 'message', '這桌還沒開桌');
  end if;
  if (public._pkg_time(s.id, false) ->> 'phase') = 'locked' then
    return jsonb_build_object('ok', false, 'reason', 'pkg_locked', 'message', '包桌時間已到，請到櫃檯補檯費');
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

  if p_to_seat is null or p_to_seat not between 1 and 4 or p_to_seat = v_me then
    return jsonb_build_object('ok', false, 'reason', 'bad_target', 'message', '請選要分給誰');
  end if;
  if p_tai is null or p_tai < c_step or p_tai > c_max_tai or p_tai % c_step <> 0 then
    return jsonb_build_object('ok', false, 'reason', 'bad_tai',
      'message', '分紅只能分 ' || c_step || ' 的倍數，最多 ' || c_max_tai || ' 台');
  end if;

  select sl.base, sl.tai into v_base, v_unit from stake_levels sl where sl.id = s.stake_level_id;
  if v_base is null or v_unit is null then
    return jsonb_build_object('ok', false, 'reason', 'no_stake', 'message', '這桌沒有設定積分級距，請找店員');
  end if;

  v_pay  := v_unit * p_tai;
  v_have := coalesce((public._tbl_balances(s.id) ->> v_me::text)::int, 0);
  if v_pay >= v_have then
    return jsonb_build_object('ok', false, 'reason', 'not_enough',
      'message', '你目前剩 ' || v_have || ' 積分，分紅後會歸零，請少分一點');
  end if;

  v_st := public._tbl_round_state(v_round.id);
  v_delta := jsonb_set(jsonb_set(v_zero, array[p_to_seat::text], to_jsonb(v_pay)),
                       array[v_me::text], to_jsonb(-v_pay));

  -- 先寫成待確認（不入帳），再改成已生效 ⇒ 爆卡檢查照常觸發
  insert into hands (org_id, session_id, round_id, hand_no, wind, dealer_seat, renzhuang,
                     result, winner_seat, deal_in_seat, patterns, tai_pattern,
                     base, tai_unit, score_delta, proposed_delta, status, need_confirm,
                     submitted_seat, submitted_device_id)
  values (s.org_id, s.id, v_round.id, (v_st ->> 'hand_no')::int, (v_st ->> 'wind')::smallint,
          (v_st ->> 'dealer_seat')::smallint, (v_st ->> 'renzhuang')::smallint,
          'bonus', p_to_seat, v_me, '[]'::jsonb, p_tai,
          v_base, v_unit, v_zero, v_delta, 'pending', '{}', v_me, d.id)
  returning id into v_hand;

  update hands
     set score_delta = proposed_delta, status = 'confirmed', confirmed_at = now()
   where id = v_hand;

  perform public._tbl_ping(s.id);
  return jsonb_build_object('ok', true, 'hand_id', v_hand, 'status', 'confirmed',
                            'score_delta', (select score_delta from hands where id = v_hand));
end $function$;

revoke execute on function public.tbl_bonus_tx(text, smallint, integer) from public;
grant  execute on function public.tbl_bonus_tx(text, smallint, integer) to anon, authenticated;

-- ③ 「不是咔啦碰才算一局」→「不是咔啦碰也不是分紅」
do $$
declare
  r record; v_old text; v_new text; v_before int; v_after int; v_total int := 0;
begin
  for r in select p.oid, p.proname from pg_proc p
            where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
              and p.proname in ('_ach_session_events', '_score_settle_tx', '_tbl_round_state',
                                '_tbl_state_for_device', 'tbl_confirm_hand_tx') loop
    v_old := pg_get_functiondef(r.oid);
    select count(*) into v_before from regexp_matches(v_old, '<>\s*''kala''', 'g');
    if v_before = 0 then continue; end if;   -- 已經改過（重跑）
    v_new := regexp_replace(v_old, '((?:\m\w+\.)?result)\s*<>\s*''kala''', '\1 not in (''kala'', ''bonus'')', 'g');
    select count(*) into v_after from regexp_matches(v_new, 'not in \(''kala'', ''bonus''\)', 'g');
    /* guard：每一處都要換到、不能有漏網的（這是「故意不要提交」的 raise，不是驗證段） */
    if v_after <> v_before or v_new ~ '<>\s*''kala''' then
      raise exception '% 換的數量對不上（原本 % 處、換到 % 處），整份不提交', r.proname, v_before, v_after;
    end if;
    execute v_new;
    v_total := v_total + v_before;
  end loop;
end $$;

-- ── 驗證（單一 SELECT，不 raise）──────────────────────────────────────
select concat_ws(E'\n',
  -- ① 兩條 CHECK 收 bonus
  case when pg_get_constraintdef((select oid from pg_constraint where conname = 'hands_result_check')) like '%bonus%'
        and pg_get_constraintdef((select oid from pg_constraint where conname = 'hands_result_shape')) like '%bonus%'
       then '✅ ① 結果多一種「分紅」' else '🔴 ① CHECK 沒改到' end,
  -- ② 分紅函式：一個版本、平板（anon）叫得到、先驗憑證
  (select case when count(*) = 1 and bool_and(has_function_privilege('anon', p.oid, 'execute'))
                and bool_and(pg_get_functiondef(p.oid) ~ '_tbl_device\(p_token\)')
               then '✅ ② 分紅函式一個版本、平板叫得到、先驗憑證' else '🔴 ② 分紅函式版本、權限或驗證不對' end
     from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = 'tbl_bonus_tx'),
  -- ③ 先寫待確認、再改已生效（爆卡檢查才會跑）
  (select case when pg_get_functiondef(p.oid) ~ '''pending''' and pg_get_functiondef(p.oid) ~ 'status = ''confirmed'''
               then '✅ ③ 先寫待確認再生效（會經過爆卡檢查）' else '🔴 ③ 沒有走待確認 → 生效' end
     from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = 'tbl_bonus_tx'),
  -- ④ 5 支函式 6 處都改成「不是咔啦碰也不是分紅」，沒有漏網的
  (select case when count(*) filter (where pg_get_functiondef(p.oid) ~ '<>\s*''kala''') = 0
                and sum((select count(*) from regexp_matches(pg_get_functiondef(p.oid), 'not in \(''kala'', ''bonus''\)', 'g'))) = 6
               then '✅ ④ 6 處「不算一局」都包含分紅'
               else '🔴 ④ 換到 ' || coalesce(sum((select count(*) from regexp_matches(pg_get_functiondef(p.oid), 'not in \(''kala'', ''bonus''\)', 'g'))), 0) || ' 處（應該 6）' end
     from pg_proc p where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
      and p.proname in ('_ach_session_events', '_score_settle_tx', '_tbl_round_state', '_tbl_state_for_device', 'tbl_confirm_hand_tx')),
  -- ⑥ 只收 10 的倍數、上限 200
  (select case when pg_get_functiondef(p.oid) ~ 'p_tai % c_step <> 0' and pg_get_functiondef(p.oid) ~ 'c_max_tai constant int := 990'
               then '✅ ⑥ 分紅只收 10 的倍數、最多 990 台' else '🔴 ⑥ 沒有擋 10 的倍數或上限不對' end
     from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = 'tbl_bonus_tx'),
  -- ⑤ 那 5 支各只有一個版本（execute 重建沒有變成多載）
  (select case when count(*) = 5 then '✅ ⑤ 那 5 支各一個版本' else '🔴 ⑤ 版本數 ' || count(*) || '（應該 5）' end
     from pg_proc p where p.pronamespace = 'public'::regnamespace
      and p.proname in ('_ach_session_events', '_score_settle_tx', '_tbl_round_state', '_tbl_state_for_device', 'tbl_confirm_hand_tx'))
) as "驗證";
