-- ════════════════════════════════════════════════════════════════════
-- 2026-10-09 分紅改成「打的數字就是台數、每台固定 10 積分」
-- ════════════════════════════════════════════════════════════════════
-- 使用者（同日第三次定案，以這次為準）：
--   「分紅跟積分一律都用數字，按 1 顯示 1 台 10 積分、按 12 顯示 12 台 120 積分」
--   並確認：**1 台固定 10 積分，不跟這桌的每台積分走**
--
-- 跟上一份（2026-10-09_智慧計分板分紅.sql）的差別，只動 tbl_bonus_tx：
--   之前  金額 ＝ 台數 × 這桌每台積分；台數只收 10 的倍數、10～990
--   現在  金額 ＝ 台數 × 10；台數 1～99
--   紀錄裡這一筆的 tai_unit 寫 10（跟實際算法一致），base 仍記這桌的底
-- 其餘不變：付的人按就生效、不算一局、先寫待確認再生效（經過爆卡檢查）、分完會歸零就擋
-- 簽名不變 ⇒ create or replace，不丟權限
-- ⚠ 計分板 App.jsx（BONUS_PER_TAI）與 lib/engine.js（教學模式）同一套，三邊一起改（CLAUDE.md 待辦 51）
-- ════════════════════════════════════════════════════════════════════

create or replace function public.tbl_bonus_tx(p_token text, p_to_seat smallint, p_tai integer)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
/* 分紅（2026-10-09）：我分給 p_to_seat 那一家 p_tai 台，**每台固定 10 積分**（不看這桌的級距）。
   付的人自己按就生效，對方不用確認。不是一局（不推進局數、莊家、連莊）。
   前置檢查與 tbl_submit_hand_tx 相同（開桌、包桌時間、台麻、座位、這一將在打、沒有待確認）。 */
declare
  d public.table_devices; s public.table_sessions; v_me smallint; v_round public.session_rounds;
  v_st jsonb; v_base int; v_pay int; v_have int; v_hand uuid;
  v_delta jsonb; v_zero jsonb := '{"1":0,"2":0,"3":0,"4":0}'::jsonb;
  c_per_tai constant int := 10;   -- 每台固定 10 積分；計分板 BONUS_PER_TAI、engine.js 同值
  c_max_tai constant int := 99;   -- 最多 99 台；計分板 BONUS_MAX_INPUT 同值
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
  if p_tai is null or p_tai < 1 or p_tai > c_max_tai then
    return jsonb_build_object('ok', false, 'reason', 'bad_tai', 'message', '分紅台數要在 1 到 ' || c_max_tai || ' 之間');
  end if;

  select sl.base into v_base from stake_levels sl where sl.id = s.stake_level_id;
  if v_base is null then
    return jsonb_build_object('ok', false, 'reason', 'no_stake', 'message', '這桌沒有設定積分級距，請找店員');
  end if;

  v_pay  := c_per_tai * p_tai;
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
          v_base, c_per_tai, v_zero, v_delta, 'pending', '{}', v_me, d.id)
  returning id into v_hand;

  update hands
     set score_delta = proposed_delta, status = 'confirmed', confirmed_at = now()
   where id = v_hand;

  perform public._tbl_ping(s.id);
  return jsonb_build_object('ok', true, 'hand_id', v_hand, 'status', 'confirmed',
                            'score_delta', (select score_delta from hands where id = v_hand));
end $function$;

-- ── 驗證（單一 SELECT，不 raise）──────────────────────────────────────
select concat_ws(E'\n',
  (select case when count(*) = 1 then '✅ ① 分紅函式只有一個版本' else '🔴 ① 版本數 ' || count(*) end
     from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = 'tbl_bonus_tx'),
  (select case when pg_get_functiondef(p.oid) ~ 'c_per_tai constant int := 10'
                and pg_get_functiondef(p.oid) ~ 'v_pay  := c_per_tai \* p_tai'
               then '✅ ② 每台固定 10 積分' else '🔴 ② 金額算法沒改到' end
     from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = 'tbl_bonus_tx'),
  (select case when pg_get_functiondef(p.oid) ~ 'c_max_tai constant int := 99'
                and pg_get_functiondef(p.oid) !~ 'p_tai % '
               then '✅ ③ 台數 1～99，不再限 10 的倍數' else '🔴 ③ 台數範圍沒改到' end
     from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = 'tbl_bonus_tx'),
  (select case when has_function_privilege('anon', p.oid, 'execute') and pg_get_functiondef(p.oid) ~ '_tbl_device\(p_token\)'
                and pg_get_functiondef(p.oid) ~ '''pending''' and pg_get_functiondef(p.oid) ~ 'status = ''confirmed'''
               then '✅ ④ 平板叫得到、先驗憑證、先待確認再生效（照舊）' else '🔴 ④ 權限或流程被改到了' end
     from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = 'tbl_bonus_tx')
) as "驗證";
