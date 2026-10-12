/* ============================================================
   智慧計分板：選牌型頁加「數字鍵」模式，直接輸入台數（2026-10-12 使用者）
   ------------------------------------------------------------
   🔴 這是把 2026-09-23 的決定改回來（`2026-09-23_收掉手動台數與修連莊台.sql`，
     當時理由「不能直接輸入台數，會影響日後數據統計與成就」）。
     使用者 10-12 知道代價後選「加回來，標成手動台數」：
       · 用數字鍵記的那一局 hands.manual_tai = true、patterns = []（沒有牌型資料）
       · 積分、名次、段位分、胡牌率／自摸率／放槍率照算（那些只看誰胡誰付）
       · 牌型成就本來就看 patterns ⇒ 自然不會觸發
       · 「8 台以上」的大牌成就**排除手動台數**（數字可以隨便打，不能拿來發成就；同 9/23 之前的做法）

   規則（前端只送台數，算錢照舊在後端）：
     · 只有胡／自摸可以用；台數 0～99；不能同時帶牌型
     · 輸入的是**牌型台數**：莊家台照舊由系統自己加（跟選牌型一樣）；自摸不再自動多帶 1 台（打的數字就是全部牌型台數）
     · 豹子是牌型 ⇒ 數字鍵模式沒有豹子倍數

   改四個地方：
     ① hands.manual_tai 加回來（boolean，預設 false）
     ② tbl_submit_hand_tx 多一個參數 p_manual_tai ⇒ 改簽名 ⇒ DROP 重建 ⇒ 結尾補 GRANT（硬規則 2）
        新參數有預設值 ⇒ 舊版平板照樣叫得到（先跑 SQL 再推前端）
     ③ _tbl_state_for_device：三處回傳多帶 manual_tai（紀錄頁要標「手動輸入」）
     ④ _ach_session_events：三處「8 台以上」排除手動台數
     ③④ 讀線上全文程式化替換，處數不對就整份停下（不手抄那兩支長函式）
   ============================================================ */

-- ① 欄位
alter table public.hands add column if not exists manual_tai boolean not null default false;
comment on column public.hands.manual_tai is
  '這一局是在計分板用數字鍵直接輸入台數（沒有牌型資料、不觸發牌型與大牌成就）。2026-10-12 加回。';

-- ② 送出函式：全文重建（照線上 2026-10-12 版本，只動手動台數那幾段）
drop function if exists public.tbl_submit_hand_tx(text, text, smallint, jsonb);

create or replace function public.tbl_submit_hand_tx(
  p_token text,
  p_result text,
  p_deal_in_seat smallint default null::smallint,
  p_patterns jsonb default '[]'::jsonb,
  p_manual_tai integer default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
/* p_result：
     ron    我胡了，p_deal_in_seat ＝ 放槍的人（要選牌型，或用數字鍵輸入台數）
     tsumo  我自摸（要選牌型；沒選門清自摸就自動帶自摸 1 台。數字鍵模式不自動帶）
     draw   流局：只有按的人確認，直接生效
     kala   咔啦碰：我直接付 p_deal_in_seat 那一家 1 台（不算底、不加莊家台），收的人確認
     bao    我包牌：我付另外三家各 1 底 3 台（莊家有牽涉再加莊家台），收的三家各自確認
   p_manual_tai：數字鍵模式（2026-10-12）—— 直接給牌型台數，不帶牌型；那一局記成 manual_tai
   🔴 付錢的那一方永遠是「確認的人」以外的那一台：胡／自摸是別人付我、咔啦碰與包牌是我付別人。 */
declare
  d public.table_devices; s public.table_sessions; v_me smallint; v_round public.session_rounds;
  v_st jsonb; v_dealer smallint; v_ren smallint; v_base int; v_unit int;
  v_pats jsonb := '[]'::jsonb; v_codes text[] := '{}'; e jsonb; p public.scoring_patterns;
  v_n int; v_tai int := 0; v_extra int; v_mult int := 1;
  v_delta jsonb; v_zero jsonb := '{"1":0,"2":0,"3":0,"4":0}'::jsonb;
  v_sum int := 0; v_pay int; v_payers smallint[]; i smallint;
  v_need smallint[] := '{}'; v_hand uuid; v_winner smallint;
  v_manual boolean := p_manual_tai is not null;
  c_kala_tai constant int := 1;   -- 咔啦碰固定 1 台
  c_bao_tai  constant int := 3;   -- 包牌 1 底 3 台
  c_manual_max constant int := 99;   -- 數字鍵最多 99 台
begin
  d := public._tbl_device(p_token);
  select * into s from table_sessions
   where table_id = d.table_id and status = 'open' and deleted_at is null;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'no_session', 'message', '這桌還沒開桌');
  end if;
  /* ⏰ 包桌續時（2026-10-01）：到期後 15 分鐘還沒補完檯費就不能再記分，要先到櫃檯補 */
  if (public._pkg_time(s.id, false) ->> 'phase') = 'locked' then
    return jsonb_build_object('ok', false, 'reason', 'pkg_locked', 'message', '包桌時間已到，請到櫃檯補檯費');
  end if;
  if coalesce(s.game_type, '台麻') not in ('台麻', '美麻') then
    return jsonb_build_object('ok', false, 'reason', 'unsupported_game_type', 'message', '記分板目前只支援台麻與美麻');
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

  /* 數字鍵模式（2026-10-12）：只有胡／自摸能用、0～99 台、不能同時帶牌型 */
  if v_manual then
    if p_result not in ('ron', 'tsumo') then
      return jsonb_build_object('ok', false, 'reason', 'bad_manual', 'message', '只有胡牌、自摸可以直接輸入台數');
    end if;
    if p_manual_tai < 0 or p_manual_tai > c_manual_max then
      return jsonb_build_object('ok', false, 'reason', 'bad_manual_tai', 'message', '台數請輸入 0～' || c_manual_max);
    end if;
    if jsonb_array_length(coalesce(p_patterns, '[]'::jsonb)) > 0 then
      return jsonb_build_object('ok', false, 'reason', 'manual_with_patterns', 'message', '直接輸入台數時不能同時選牌型');
    end if;
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

  if v_manual then
    /* 數字鍵模式：台數就是打的那個數字，沒有牌型、沒有豹子、不自動帶自摸 */
    v_tai := p_manual_tai;
  else
    /* 選牌型模式：台數從牌型換算。
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
      if p.code = 'baozi' then v_mult := 1 + v_n; end if;   -- 豹子：倍數 ＝ 1 ＋ 次數（2026-10-10）
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

    v_tai := v_tai * v_mult;   -- 豹子：牌型台數一起乘（含自動帶的自摸），存進 tai_pattern 的就是乘過的
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
    v_pay := v_base * v_mult + v_unit * (v_tai + case when v_winner = v_dealer or i = v_dealer then v_extra * v_mult else 0 end);   -- 豹子連底一起乘（2026-10-10）
    v_delta := jsonb_set(v_delta, array[i::text], to_jsonb(-v_pay));
    v_sum := v_sum + v_pay;
  end loop;
  v_delta := jsonb_set(v_delta, array[v_winner::text], to_jsonb(v_sum));

  insert into hands (org_id, session_id, round_id, hand_no, wind, dealer_seat, renzhuang,
                     result, winner_seat, deal_in_seat, patterns, tai_pattern, manual_tai,
                     base, tai_unit, score_delta, proposed_delta, status, need_confirm, submitted_seat, submitted_device_id)
  values (s.org_id, s.id, v_round.id, (v_st ->> 'hand_no')::int, (v_st ->> 'wind')::smallint,
          v_dealer, v_ren, p_result, v_winner, case when p_result = 'ron' then p_deal_in_seat end,
          v_pats, v_tai, v_manual, v_base, v_unit, v_zero, v_delta, 'pending', v_need, v_me, d.id)
  returning id into v_hand;

  perform public._tbl_ping(s.id);
  return jsonb_build_object('ok', true, 'hand_id', v_hand, 'status', 'pending', 'manual_tai', v_manual,
                            'tai_pattern', v_tai, 'proposed_delta', v_delta, 'need_confirm', to_jsonb(v_need));
end $function$;

-- DROP 重建 ⇒ 授權要補回來（平板用裝置憑證、沒有登入，所以要給 anon）
revoke execute on function public.tbl_submit_hand_tx(text, text, smallint, jsonb, integer) from public;
grant execute on function public.tbl_submit_hand_tx(text, text, smallint, jsonb, integer) to anon, authenticated, service_role;

-- ③④ 兩支長函式：讀線上全文程式化替換，處數不對就停下
do $$
declare v_def text; v_new text; v_n int;
begin
  -- ③ 平板狀態：三處回傳多帶 manual_tai
  v_def := pg_get_functiondef('public._tbl_state_for_device'::regproc);
  select count(*) into v_n from regexp_matches(v_def, '''tai_pattern'', h\.tai_pattern,', 'g');
  if v_n <> 3 then raise exception '平板狀態函式：預期 3 處，實際 % 處 —— 線上版本跟寫這份時不同，停下', v_n; end if;
  v_new := replace(v_def, '''tai_pattern'', h.tai_pattern,', '''tai_pattern'', h.tai_pattern, ''manual_tai'', h.manual_tai,');
  execute v_new;

  -- ④ 大牌成就：三處「8 台以上」排除手動台數
  v_def := pg_get_functiondef('public._ach_session_events'::regproc);
  select count(*) into v_n from regexp_matches(v_def, 'h\.tai_pattern >= 8', 'g');
  if v_n <> 3 then raise exception '成就事件函式：預期 3 處，實際 % 處 —— 線上版本跟寫這份時不同，停下', v_n; end if;
  v_new := replace(v_def, 'h.tai_pattern >= 8', 'h.tai_pattern >= 8 and not h.manual_tai');
  execute v_new;
end $$;

-- ── 驗證（單一 SELECT，不 raise）──
select concat_ws(E'\n',
  case when exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'hands'
                     and column_name = 'manual_tai' and data_type = 'boolean' and is_nullable = 'NO')
       then '✅ ① hands.manual_tai 在（boolean，不可空）' else '🔴 ① hands.manual_tai 沒建好' end,
  case when (select count(*) from pg_proc where pronamespace = 'public'::regnamespace and proname = 'tbl_submit_hand_tx') = 1
        and exists (select 1 from pg_proc where oid = 'public.tbl_submit_hand_tx(text,text,smallint,jsonb,integer)'::regprocedure)
       then '✅ ② 送出函式只有一個版本（多了 p_manual_tai）' else '🔴 ② 送出函式版本不對' end,
  case when has_function_privilege('anon', 'public.tbl_submit_hand_tx(text,text,smallint,jsonb,integer)', 'execute')
        and exists (select 1 from aclexplode((select proacl from pg_proc where oid = 'public.tbl_submit_hand_tx(text,text,smallint,jsonb,integer)'::regprocedure)) a
                     where a.grantee = 'anon'::regrole::oid and a.privilege_type = 'EXECUTE')
       then '✅ ② 平板叫得到（anon 明確授權）' else '🔴 ② anon 叫不到 —— 平板會一按送出就失敗' end,
  case when (select count(*) from regexp_matches(pg_get_functiondef('public._tbl_state_for_device'::regproc), '''manual_tai'', h\.manual_tai', 'g')) = 3
       then '✅ ③ 平板狀態三處都帶 manual_tai' else '🔴 ③ 平板狀態沒改到' end,
  case when (select count(*) from regexp_matches(pg_get_functiondef('public._ach_session_events'::regproc), 'h\.tai_pattern >= 8 and not h\.manual_tai', 'g')) = 3
       then '✅ ④ 大牌成就三處都排除手動台數' else '🔴 ④ 大牌成就沒改到' end
) as "驗證";
