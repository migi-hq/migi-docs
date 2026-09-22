-- 2026-09-23 驗電子計分的收桌結算（跑在 2026-09-23_電子計分_收桌結算.sql 之後）
-- ⚠ 交易內造一桌、四台平板、四位測試會員，打完兩將再照正常流程收桌，
--   最後 raise 'migi_rollback' 整個退掉 —— 段位分、成就、通知一列都不會留下。
-- ⚠ 訊息設在 exception 處理器裡（硬規則 3.9）。

do $$
declare
  v_org uuid; v_store uuid; v_table uuid; v_stake uuid; v_sess uuid;
  v_mem uuid[]; v_tok text[]; v_pid uuid[]; v_id uuid;
  r jsonb; st jsonb; v_msg text := ''; i int; k int; v_dealer int; v_w int; v_round int;
  v_ok boolean; v_txt text; v_rating_before int[]; v_n int;
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
  select array_agg(rating order by created_at) into v_rating_before from members where id = any(v_mem);

  insert into table_sessions (org_id, store_id, table_id, mode, status, stake_level_id, game_type, flower, planned_rounds)
  values (v_org, v_store, v_table, 'matched', 'open', v_stake, '台麻', '無花', 2) returning id into v_sess;
  v_tok := array[repeat('a', 40), repeat('b', 40), repeat('c', 40), repeat('d', 40)];
  v_pid := '{}';
  for i in 1..4 loop
    insert into table_devices (org_id, store_id, table_id, label, token_hash)
    values (v_org, v_store, v_table, 'T-' || i, public._tbl_hash(v_tok[i]));
    insert into session_players (org_id, session_id, member_id, join_type, status)
    values (v_org, v_sess, v_mem[i], 'opener', 'playing') returning id into v_id;
    v_pid := v_pid || v_id;
  end loop;
  for i in 1..4 loop perform public.tbl_claim_seat_tx(v_tok[i], v_pid[i]); end loop;
  perform public.tbl_set_order_tx(v_tok[1], v_pid[1], v_pid[2], v_pid[3]);

  -- 第一將的第一把：座位 2 大三元 8 台胡座位 1（咪幾）、第二把座位 3 自摸碰碰胡
  r := public.tbl_submit_hand_tx(v_tok[2], 'ron', 1::smallint, '[{"code":"dasanyuan"}]'::jsonb);
  perform public.tbl_confirm_hand_tx(v_tok[1], (r ->> 'hand_id')::uuid, true);
  r := public.tbl_submit_hand_tx(v_tok[3], 'tsumo', null, '[{"code":"pengpenghu"}]'::jsonb);
  for i in 1..4 loop
    if i <> 3 then perform public.tbl_confirm_hand_tx(v_tok[i], (r ->> 'hand_id')::uuid, true); end if;
  end loop;

  -- 打完兩將：每把讓莊家的下家胡、莊家放槍（平胡 2 台）
  for v_round in 1..2 loop
    k := 0;
    for i in 1..40 loop
      st := public.tbl_state_tx(v_tok[1]);
      exit when (st -> 'round' ->> 'status') = 'finished';
      v_dealer := (st -> 'round' ->> 'dealer_seat')::int;
      v_w := (v_dealer % 4) + 1;
      r := public.tbl_submit_hand_tx(v_tok[v_w], 'ron', v_dealer::smallint, '[{"code":"pinghu"}]'::jsonb);
      perform public.tbl_confirm_hand_tx(v_tok[v_dealer], (r ->> 'hand_id')::uuid, true);
      k := k + 1;
    end loop;
    if v_round = 1 then perform public.tbl_start_round_tx(v_tok[1], 1::smallint); end if;
  end loop;
  -- 第三將開了但只打一把（沒打完）⇒ 分數算進 final_score，段位分不算
  perform public.tbl_start_round_tx(v_tok[1], 1::smallint);
  r := public.tbl_submit_hand_tx(v_tok[4], 'ron', 1::smallint, '[{"code":"pinghu"}]'::jsonb);
  perform public.tbl_confirm_hand_tx(v_tok[1], (r ->> 'hand_id')::uuid, true);
  -- 再留一把等確認的在桌上 ⇒ 收桌要把它收掉
  r := public.tbl_submit_hand_tx(v_tok[2], 'ron', 1::smallint, '[{"code":"pinghu"}]'::jsonb);

  select count(*) into v_n from session_rounds where session_id = v_sess and status = 'finished';
  v_msg := v_msg || (case when v_n = 2 then ok else bad end) || '① 兩將打完、第三將打到一半：打完 ' || v_n || ' 將' || E'\n';

  -- ── 照正常流程收桌 ──
  r := public.settle_session_tx(v_sess, null, false);
  v_msg := v_msg || (case when (r ->> 'ok')::boolean then ok else bad end) || '② 收桌成功' || E'\n';

  -- ③ 名次：四個人 1–4 各一個，而且依總分排
  select count(distinct finish_rank) = 4 and bool_and(finish_rank is not null) into v_ok
    from session_players where session_id = v_sess;
  select string_agg('座' || seat || '：第' || finish_rank || '名 ' || final_score, '、' order by seat) into v_txt
    from session_players where session_id = v_sess;
  v_msg := v_msg || (case when v_ok then ok else bad end) || '③ 名次 1–4 各一個：' || coalesce(v_txt, '∅') || E'\n';

  select bool_and(x.ok) into v_ok from (
    select sp.finish_rank = row_number() over (order by sp.final_score desc, sp.seat) as ok
      from session_players sp where sp.session_id = v_sess) x;
  v_msg := v_msg || (case when v_ok then ok else bad end) || '③-1 名次依總分排（同分座位小的在前）' || E'\n';

  -- ④ 桌上積分：四家加總 0，而且等於所有確認過的把（含第三將那一把）的加總
  select sum(final_score) = 0 into v_ok from session_players where session_id = v_sess;
  v_msg := v_msg || (case when v_ok then ok else bad end) || '④ 桌上積分零和' || E'\n';
  select bool_and(sp.final_score = coalesce((select sum((h.score_delta ->> sp.seat::text)::int) from hands h
                                              where h.session_id = v_sess and h.status = 'confirmed'), 0))
    into v_ok from session_players sp where sp.session_id = v_sess;
  v_msg := v_msg || (case when v_ok then ok else bad end) || '④-1 桌上積分 ＝ 每一把確認過的加總（不是隨機名次）' || E'\n';

  -- ⑤ 段位分動了（兩將都算了），而且有記 rating_after
  select bool_and(sp.rating_after is not null) into v_ok from session_players sp where sp.session_id = v_sess;
  select string_agg(m.display_name || ' ' || v_rating_before[array_position(v_mem, m.id)] || '→' || m.rating, '、')
    into v_txt from members m where m.id = any(v_mem);
  v_msg := v_msg || (case when v_ok then ok else bad end) || '⑤ 段位分有算：' || coalesce(v_txt, '∅') || E'\n';

  -- ⑥ 等確認的那一把被收掉了
  select count(*) into v_n from hands where session_id = v_sess and status = 'pending';
  v_msg := v_msg || (case when v_n = 0 then ok else bad end) || '⑥ 收桌時沒有留下待確認的把' || E'\n';

  -- ⑦ 平板放掉了
  select count(*) into v_n from session_players where session_id = v_sess and device_id is not null;
  v_msg := v_msg || (case when v_n = 0 then ok else bad end) || '⑦ 四台平板都放掉了' || E'\n';

  -- ⑧ 成就：座位 2 大三元 ⇒ 首次胡牌、第一次牌型、大三元、MIGI；座位 3 自摸 ⇒ 首次自摸、碰碰胡
  select string_agg(a.code, ',' order by a.code) into v_txt
    from member_achievements ma join achievements a on a.id = ma.achievement_id
   where ma.member_id = v_mem[2] and ma.status = 'unlocked'
     and a.code in ('onboarding_03','onboarding_05','tile_14','migi_01');
  v_msg := v_msg || (case when v_txt = 'migi_01,onboarding_03,onboarding_05,tile_14' then ok else bad end)
           || '⑧ 大三元那一位解鎖：' || coalesce(v_txt, '∅') || E'\n';
  select string_agg(a.code, ',' order by a.code) into v_txt
    from member_achievements ma join achievements a on a.id = ma.achievement_id
   where ma.member_id = v_mem[3] and ma.status = 'unlocked'
     and a.code in ('onboarding_04','tile_20');
  v_msg := v_msg || (case when v_txt = 'onboarding_04,tile_20' then ok else bad end)
           || '⑧-1 自摸碰碰胡那一位解鎖：' || coalesce(v_txt, '∅') || E'\n';
  -- 負對照：沒胡過大三元的人不可以拿到大三元
  select count(*) into v_n from member_achievements ma join achievements a on a.id = ma.achievement_id
   where ma.member_id = v_mem[1] and ma.status = 'unlocked' and a.code in ('tile_14','migi_01');
  v_msg := v_msg || (case when v_n = 0 then ok else bad end) || '⑧-2 負對照：座位 1 沒有拿到大三元／MIGI' || E'\n';
  -- 十次 MIGI 是累積型：這一場只有一次
  select coalesce(max(ma.current_value), 0) into v_n from member_achievements ma join achievements a on a.id = ma.achievement_id
   where ma.member_id = v_mem[2] and a.code = 'migi_02';
  v_msg := v_msg || (case when v_n = 1 then ok else bad end) || '⑧-3 十次 MIGI 累積 1 次：' || v_n || E'\n';

  -- ⑨ 冪等：再收一次桌，名次與成就不會重來
  r := public.settle_session_tx(v_sess, null, false);
  select coalesce(max(ma.current_value), 0) into v_n from member_achievements ma join achievements a on a.id = ma.achievement_id
   where ma.member_id = v_mem[2] and a.code = 'migi_02';
  v_msg := v_msg || (case when (r ->> 'already_settled')::boolean and v_n = 1 then ok else bad end)
           || '⑨ 再按一次收桌不會重算（MIGI 仍是 ' || v_n || ' 次）';

  raise exception 'migi_rollback';
exception when others then
  if sqlerrm = 'migi_rollback' then
    perform set_config('migi.t', v_msg, false);
  else
    perform set_config('migi.t', '🔴 中途失敗：' || sqlerrm || E'\n已經跑完的：\n' || coalesce(v_msg, ''), false);
  end if;
end $$;

select coalesce(nullif(current_setting('migi.t', true), ''), '🔴 沒有訊息') as "驗證";
