-- 2026-09-29 驗打完自動結算成績、收桌記錄是誰按的（跑在 2026-09-29_打完自動結算成績_收桌記錄是誰按的.sql 之後）
-- ⚠ 交易內造兩場、各四台平板、四位測試會員，最後 raise 'migi_rollback' 整個退掉 ——
--   段位分、成就、通知一列都不會留下。訊息設在 exception 處理器裡（硬規則 3.9）。
--
-- 情境 A：約定 2 將，打完第 2 將 ⇒ 系統自動結算；收桌只放桌、記是誰按的、不重算
-- 情境 B：約定 3 將，只打 2 將就收桌 ⇒ 沒有自動結算，由收桌補算（客人提早走的備援）
--
-- 🔴 舊的 sql/checks/2026-09-23_驗電子計分的收桌結算.sql 會在「第三將」那一步被擋下
--    （它約定 2 將卻開了第 3 將）—— 那是新規則的預期結果，以這一份為準。

do $$
declare
  v_org uuid; v_store uuid; v_table uuid; v_stake uuid; v_sess uuid;
  v_mem uuid[]; v_tok text[]; v_pid uuid[]; v_id uuid;
  r jsonb; st jsonb; v_msg text := ''; i int; sc int; v_dealer int; v_w int; v_round int; v_planned int;
  v_ok boolean; v_txt text; v_n int; v_err text; v_staff uuid; v_auth uuid; v_closed uuid;
  v_rating_before int[]; v_rating_mid int[]; v_ranks_mid text; p text;
  ok text := '✅ '; bad text := '🔴 ';
begin
  select t.id, t.store_id, t.org_id into v_table, v_store, v_org
    from tables t join stores s on s.id = t.store_id
   where t.deleted_at is null and s.is_test
     and not exists (select 1 from table_sessions ts where ts.table_id = t.id and ts.status = 'open' and ts.deleted_at is null)
   order by t.label limit 1;
  if v_table is null then perform set_config('migi.t', '⚪ 找不到沒開桌的測試桌，這份測不了', false); return; end if;
  select id into v_stake from stake_levels where label = '100/20' and deleted_at is null limit 1;
  select array_agg(id order by created_at) into v_mem from (select id, created_at from members
   where deleted_at is null and is_test and org_id = v_org order by created_at limit 4) x;
  if coalesce(array_length(v_mem, 1), 0) < 4 or v_stake is null then
    perform set_config('migi.t', '⚪ 測試會員不足四位或找不到 100/20，這份測不了', false); return;
  end if;
  -- 找一位有登入身分的店員（收桌記誰按的要用真的身分驗）
  select id, auth_uid into v_staff, v_auth from staff
   where auth_uid is not null and deleted_at is null and role in ('hq', 'owner') limit 1;

  for sc in 1..2 loop
    v_planned := sc + 1;                       -- A：2 將；B：3 將
    p := case when sc = 1 then '【A】' else '【B】' end;
    select array_agg(rating order by created_at) into v_rating_before from members where id = any(v_mem);

    insert into table_sessions (org_id, store_id, table_id, mode, status, stake_level_id, game_type, flower, planned_rounds)
    values (v_org, v_store, v_table, 'matched', 'open', v_stake, '台麻', '無花', v_planned) returning id into v_sess;
    v_tok := array[repeat(chr(96 + sc*4 - 3), 40), repeat(chr(96 + sc*4 - 2), 40),
                   repeat(chr(96 + sc*4 - 1), 40), repeat(chr(96 + sc*4), 40)];
    v_pid := '{}';
    for i in 1..4 loop
      insert into table_devices (org_id, store_id, table_id, label, token_hash)
      values (v_org, v_store, v_table, 'T' || sc || '-' || i, public._tbl_hash(v_tok[i]));
      insert into session_players (org_id, session_id, member_id, join_type, status)
      values (v_org, v_sess, v_mem[i], 'opener', 'playing') returning id into v_id;
      v_pid := v_pid || v_id;
    end loop;
    for i in 1..4 loop perform public.tbl_claim_seat_tx(v_tok[i], v_pid[i]); end loop;
    perform public.tbl_set_order_tx(v_tok[1], v_pid[1], v_pid[2], v_pid[3]);

    -- 第一將的前三把：座位 2 大三元胡座位 1、座位 3 自摸碰碰胡、座位 2 選「MIGI」牌型胡座位 1
    -- ⚠ 2026-09-25 起 MIGI 成就只認選了 MIGI 牌型的那一局（事件 migi_hu），大三元 8 台不再算 ——
    --   第一次跑時照抄 09-23 舊測試的期望值，⑦ 與 ⑫-1 紅了兩格（硬規則 3.56：期望值錯，函式是對的）
    r := public.tbl_submit_hand_tx(v_tok[2], 'ron', 1::smallint, '[{"code":"dasanyuan"}]'::jsonb);
    perform public.tbl_confirm_hand_tx(v_tok[1], (r ->> 'hand_id')::uuid, true);
    r := public.tbl_submit_hand_tx(v_tok[3], 'tsumo', null, '[{"code":"pengpenghu"}]'::jsonb);
    for i in 1..4 loop
      if i <> 3 then perform public.tbl_confirm_hand_tx(v_tok[i], (r ->> 'hand_id')::uuid, true); end if;
    end loop;
    r := public.tbl_submit_hand_tx(v_tok[2], 'ron', 1::smallint, '[{"code":"migi"}]'::jsonb);
    if not coalesce((r ->> 'ok')::boolean, false) then
      raise exception '選 MIGI 牌型的那一局送不出去：%', r;
    end if;
    perform public.tbl_confirm_hand_tx(v_tok[1], (r ->> 'hand_id')::uuid, true);

    -- 打完第 1 將
    for i in 1..40 loop
      st := public.tbl_state_tx(v_tok[1]);
      exit when (st -> 'round' ->> 'status') = 'finished';
      v_dealer := (st -> 'round' ->> 'dealer_seat')::int;  v_w := (v_dealer % 4) + 1;
      r := public.tbl_submit_hand_tx(v_tok[v_w], 'ron', v_dealer::smallint, '[{"code":"pinghu"}]'::jsonb);
      perform public.tbl_confirm_hand_tx(v_tok[v_dealer], (r ->> 'hand_id')::uuid, true);
    end loop;
    -- 🔴 負對照：第 1 將打完（不是最後一將）不可以結算
    v_ok := not public._session_scored(v_sess);
    v_msg := v_msg || (case when v_ok then ok else bad end) || p || '① 第 1 將打完，沒有結算（還沒到約定的 ' || v_planned || ' 將）' || E'\n';

    -- 打完第 2 將
    perform public.tbl_start_round_tx(v_tok[1], 1::smallint);
    for i in 1..40 loop
      st := public.tbl_state_tx(v_tok[1]);
      exit when (st -> 'round' ->> 'status') = 'finished';
      v_dealer := (st -> 'round' ->> 'dealer_seat')::int;  v_w := (v_dealer % 4) + 1;
      r := public.tbl_submit_hand_tx(v_tok[v_w], 'ron', v_dealer::smallint, '[{"code":"pinghu"}]'::jsonb);
      perform public.tbl_confirm_hand_tx(v_tok[v_dealer], (r ->> 'hand_id')::uuid, true);
    end loop;
    select array_agg(rating order by created_at) into v_rating_mid from members where id = any(v_mem);

    if sc = 1 then
      -- ══ 情境 A：第 2 將 ＝ 約定的最後一將 ⇒ 已經自動結算 ══
      select status into v_txt from table_sessions where id = v_sess;
      v_msg := v_msg || (case when v_txt = 'open' then ok else bad end) || p || '② 場次還是開著（沒有被收桌）：' || v_txt || E'\n';

      select count(distinct finish_rank) = 4 and bool_and(finish_rank is not null) into v_ok from session_players where session_id = v_sess;
      select string_agg('座' || seat || ' 第' || finish_rank || '名 ' || coalesce(final_score::text, 'null'), '、' order by seat) into v_txt
        from session_players where session_id = v_sess;
      v_msg := v_msg || (case when v_ok then ok else bad end) || p || '③ 打完當下名次就有了：' || coalesce(v_txt, '∅') || E'\n';

      select bool_and(x.ok) into v_ok from (
        select sp.finish_rank = row_number() over (order by sp.final_score desc, sp.seat) as ok
          from session_players sp where sp.session_id = v_sess) x;
      v_msg := v_msg || (case when v_ok then ok else bad end) || p || '③-1 名次依整場總分（同分座位小的在前）' || E'\n';

      select bool_and(sp.rating_after is not null and sp.score_points is not null) into v_ok from session_players sp where sp.session_id = v_sess;
      v_msg := v_msg || (case when v_ok then ok else bad end) || p || '④ 段位分算了（rating_after、score_points 都有）' || E'\n';

      select count(*) into v_n from session_players where session_id = v_sess and device_id is not null;
      v_msg := v_msg || (case when v_n = 4 then ok else bad end) || p || '⑤ 四台平板還綁著（要看得到牌局結束卡）：' || v_n || '/4' || E'\n';

      -- ⑥ 平板讀得到 rating_delta，而且每個座位等於 score_points
      st := public.tbl_state_tx(v_tok[1]);
      select bool_and((st -> 'rating_delta' ->> sp.seat::text)::int = sp.score_points)
             and count(*) = (select count(*) from jsonb_object_keys(st -> 'rating_delta'))
        into v_ok from session_players sp where sp.session_id = v_sess;
      v_msg := v_msg || (case when coalesce(v_ok, false) then ok else bad end) || p || '⑥ tbl_state_tx 的 rating_delta ＝ 每個座位的 score_points：' || coalesce((st -> 'rating_delta')::text, 'null') || E'\n';

      -- ⑦ 成就在自動結算就發了
      select string_agg(a.code, ',' order by a.code) into v_txt
        from member_achievements ma join achievements a on a.id = ma.achievement_id
       where ma.member_id = v_mem[2] and ma.status = 'unlocked' and a.code in ('onboarding_03','onboarding_05','tile_14','migi_01');
      v_msg := v_msg || (case when v_txt = 'migi_01,onboarding_03,onboarding_05,tile_14' then ok else bad end)
               || p || '⑦ 座位 2（大三元＋MIGI 牌型）解鎖：' || coalesce(v_txt, '∅') || E'\n';
      select count(*) into v_n from member_achievements ma join achievements a on a.id = ma.achievement_id
       where ma.member_id = v_mem[1] and ma.status = 'unlocked' and a.code in ('tile_14','migi_01');
      v_msg := v_msg || (case when v_n = 0 then ok else bad end) || p || '⑦-1 負對照：座位 1 沒有拿到大三元／MIGI' || E'\n';

      -- ⑧ 🔴 負對照：算完之後不准再開新的一將、不准撤銷
      v_err := null;
      begin perform public.tbl_start_round_tx(v_tok[1], 1::smallint);
      exception when others then v_err := sqlerrm; end;
      v_msg := v_msg || (case when v_err like '%已經結算%' then ok else bad end) || p || '⑧ 成績算完，再開新的一將被擋：' || coalesce(v_err, '沒有被擋') || E'\n';
      v_err := null;
      begin perform public.tbl_undo_last_tx(v_tok[1]);
      exception when others then v_err := sqlerrm; end;
      v_msg := v_msg || (case when v_err like '%已經結算%' then ok else bad end) || p || '⑧-1 成績算完，撤銷被擋：' || coalesce(v_err, '沒有被擋') || E'\n';
    else
      -- ══ 情境 B：第 2 將 < 約定的 3 將 ⇒ 沒有自動結算 ══
      v_ok := not public._session_scored(v_sess);
      v_msg := v_msg || (case when v_ok then ok else bad end) || p || '② 打完 2 將但約定 3 將 ⇒ 沒有自動結算' || E'\n';
    end if;

    -- ── 收桌（情境 A 用有登入身分的店員按；情境 B 用沒有身分的）──
    if sc = 1 and v_auth is not null then
      perform set_config('request.jwt.claims', json_build_object('sub', v_auth::text, 'role', 'authenticated')::text, true);
    else
      perform set_config('request.jwt.claims', '', true);
    end if;
    select string_agg(finish_rank::text, ',' order by seat) into v_ranks_mid from session_players where session_id = v_sess;
    r := public.settle_session_tx(v_sess, null, false);
    v_msg := v_msg || (case when (r ->> 'ok')::boolean then ok else bad end) || p || '⑨ 收桌成功' || E'\n';

    select count(distinct finish_rank) = 4 and bool_and(finish_rank is not null) into v_ok from session_players where session_id = v_sess;
    v_msg := v_msg || (case when v_ok then ok else bad end) || p || '⑩ 收桌後四個人都有名次 1–4' || E'\n';

    select count(*) into v_n from session_players where session_id = v_sess and device_id is not null;
    v_msg := v_msg || (case when v_n = 0 then ok else bad end) || p || '⑪ 收桌才放掉平板：' || v_n || ' 台還綁著' || E'\n';

    if sc = 1 then
      -- 不重算：名次沒變、四個人的段位分收桌前後一樣
      select string_agg(finish_rank::text, ',' order by seat) into v_txt from session_players where session_id = v_sess;
      select bool_and(m.rating = v_rating_mid[array_position(v_mem, m.id)]) into v_ok from members m where m.id = any(v_mem);
      v_msg := v_msg || (case when v_txt = v_ranks_mid and v_ok then ok else bad end)
               || p || '⑫ 收桌沒有重算：名次 ' || v_ranks_mid || ' → ' || v_txt || '，段位分收桌前後相同' || E'\n';
      select coalesce(max(ma.current_value), 0) into v_n from member_achievements ma join achievements a on a.id = ma.achievement_id
       where ma.member_id = v_mem[2] and a.code = 'migi_02';
      v_msg := v_msg || (case when v_n = 1 then ok else bad end) || p || '⑫-1 十次 MIGI 仍是 1 次（沒有多加）：' || v_n || E'\n';
    else
      -- 備援：收桌補算 ⇒ 段位分動了
      select bool_and(sp.rating_after is not null) into v_ok from session_players sp where sp.session_id = v_sess;
      v_msg := v_msg || (case when v_ok then ok else bad end) || p || '⑫ 收桌補算了段位分（rating_after 都有）' || E'\n';
    end if;

    -- 誰收的桌
    select closed_by_staff_id into v_closed from table_sessions where id = v_sess;
    if sc = 1 then
      if v_auth is null then
        v_msg := v_msg || '⚪ ' || p || '⑬ 找不到有登入身分的總部／老闆，測不了「記誰收的桌」' || E'\n';
      else
        v_msg := v_msg || (case when v_closed = v_staff then ok else bad end) || p || '⑬ closed_by_staff_id ＝ 按收桌的那位店員：' || coalesce(v_closed::text, 'null') || E'\n';
        -- 第二次按（換成沒有身分的人）不會蓋掉第一次
        perform set_config('request.jwt.claims', '', true);
        r := public.settle_session_tx(v_sess, null, false);
        select closed_by_staff_id into v_closed from table_sessions where id = v_sess;
        v_msg := v_msg || (case when (r ->> 'already_settled')::boolean and v_closed = v_staff then ok else bad end)
                 || p || '⑬-1 再按一次是「已經收好了」，closed_by_staff_id 沒被覆蓋' || E'\n';
      end if;
    else
      v_msg := v_msg || (case when v_closed is null then ok else bad end) || p || '⑬ 沒有店員身分收桌 ⇒ closed_by_staff_id 是 null（不列入獎金）' || E'\n';
    end if;
  end loop;

  raise exception 'migi_rollback';
exception when others then
  if sqlerrm = 'migi_rollback' then
    perform set_config('migi.t', v_msg, false);
  else
    perform set_config('migi.t', '🔴 中途失敗：' || sqlerrm || E'\n已經跑完的：\n' || coalesce(v_msg, ''), false);
  end if;
end $$;

select coalesce(nullif(current_setting('migi.t', true), ''), '🔴 沒有訊息') as "驗證";
