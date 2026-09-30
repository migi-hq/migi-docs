/* ============================================================
   行為測試：爆卡與追加積分（交易內造 4 台平板，**全部回滾**）
   2026-09-30 · 配 sql/pending/2026-09-30_爆卡與追加積分.sql（先跑那份）

   樣本：高雄自由店 A1 那一場（1ea984c6…，純娛樂、第 3 將還在打）
   目前每人累積：座位 1 −120、2 −280、3 +340、4 +60
   交易內把起始積分調成 300 ⇒ 座位 2 只剩 20（300 − 280）

   ⓐ 追加路線：夾 0 → 爆卡 → 爆卡中擋送出 → 別人不能替他決定 → 追加 500
   ⓑ 撤銷路線：爆卡之後撤銷那一局 ⇒ 爆卡作廢、不用再決定
   ⓒ 結束路線（換成有記分的級距）：不追加 ⇒ 整場結束、成績算好、不能再開一將；
      收桌之後「爆卡」（座位 2）「讓對手爆卡」（座位 1）兩枚成就要亮
   ⓓ 純娛樂負對照：同樣結束並收桌，兩枚成就都不可以亮

   ⚠ 故意 raise 回滾（硬規則 1.8 的例外），訊息設在 exception handler 裡（硬規則 3.9）
   ============================================================ */

-- 共用：造 4 台平板並綁座位、把起始積分調低（每一段各自重做，前一段已經回滾）
create or replace function pg_temp.migi_setup(p_hygiene boolean) returns void language plpgsql as $$
declare v_sid uuid := '1ea984c6-e15e-4888-a4d6-9f99f0860120'; v_org uuid; v_store uuid; v_table uuid; v_stake uuid; g int; v_dev uuid;
begin
  select org_id, store_id, table_id into v_org, v_store, v_table from public.table_sessions where id = v_sid and status = 'open';
  if v_org is null then raise exception '🔴 A1 那一場已經不是進行中（可能已經收桌），這份測不了'; end if;
  if not p_hygiene then
    select id into v_stake from public.stake_levels where org_id = v_org and is_hygiene = false order by sort_order limit 1;
    update public.table_sessions set stake_level_id = v_stake where id = v_sid;
  end if;
  update public.stake_levels set start_points = 300
   where id = (select stake_level_id from public.table_sessions where id = v_sid);
  for g in 1 .. 4 loop
    insert into public.table_devices (org_id, store_id, table_id, label, token_hash)
    values (v_org, v_store, v_table, '測試平板' || g, public._tbl_hash('migi-bust-test-seat-' || g || '-0123456789abcdef'))
    returning id into v_dev;
    update public.session_players set device_id = v_dev where session_id = v_sid and seat = g;
  end loop;
end $$;
create or replace function pg_temp.tok(g int) returns text language sql as $$ select 'migi-bust-test-seat-' || g || '-0123456789abcdef' $$;

-- ⓐ 追加路線
do $$
declare v_sid uuid := '1ea984c6-e15e-4888-a4d6-9f99f0860120'; r jsonb; st jsonb; v_hand uuid; v_msg text := ''; v_ok int := 0; v_all int := 0; v_err text;
begin
  perform set_config('request.jwt.claims', '', true);
  perform pg_temp.migi_setup(true);

  -- ① 座位 1 胡座位 2 一副混一色（照算遠超過 20）⇒ 只扣 20
  r := public.tbl_submit_hand_tx(pg_temp.tok(1), 'ron', 2::smallint, '[{"code":"hunyise","n":1}]'::jsonb);
  select id, proposed_delta into v_hand, st from public.hands where id = (r ->> 'hand_id')::uuid;
  v_all := v_all + 1;
  if (st ->> '2')::int = -20 and (st ->> '1')::int = 20 and (st ->> '3')::int = 0 and (st ->> '4')::int = 0 then v_ok := v_ok + 1; v_msg := v_msg || '✅'; else v_msg := v_msg || '🔴'; end if;
  v_msg := v_msg || ' ① 夾 0：' || coalesce(st::text, '∅') || '（期望 座位2 −20、座位1 +20）' || E'\n';

  -- ② 座位 2 確認 ⇒ 爆卡、在等座位 2、胡的人記成座位 1
  r := public.tbl_confirm_hand_tx(pg_temp.tok(2), v_hand, true);
  st := public.tbl_state_tx(pg_temp.tok(3));
  v_all := v_all + 1;
  if (st -> 'bust' ->> 'seat')::int = 2
     and exists (select 1 from public.session_busts where session_id = v_sid and seat = 2 and by_seat = 1 and decision = 'pending')
    then v_ok := v_ok + 1; v_msg := v_msg || '✅'; else v_msg := v_msg || '🔴'; end if;
  v_msg := v_msg || ' ② 爆卡：state.bust = ' || coalesce((st -> 'bust')::text, 'null') || E'\n';

  -- ③ 爆卡中別人送出 ⇒ 擋下
  v_all := v_all + 1;
  begin
    r := public.tbl_submit_hand_tx(pg_temp.tok(3), 'draw', null, '[]'::jsonb);
    v_msg := v_msg || '🔴 ③ 爆卡中竟然送得出去：' || r::text || E'\n';
  exception when others then
    v_ok := v_ok + 1; v_msg := v_msg || '✅ ③ 爆卡中送出被擋：' || sqlerrm || E'\n';
  end;

  -- ④ 別人不能替他決定
  r := public.tbl_bust_decide_tx(pg_temp.tok(1), 500);
  v_all := v_all + 1;
  if r ->> 'reason' = 'not_yours' then v_ok := v_ok + 1; v_msg := v_msg || '✅'; else v_msg := v_msg || '🔴'; end if;
  v_msg := v_msg || ' ④ 座位 1 替他決定 → ' || r::text || E'\n';

  -- ⑤ 座位 2 追加 500 ⇒ 不再等、extras 500、剩 500
  r := public.tbl_bust_decide_tx(pg_temp.tok(2), 500);
  st := public.tbl_state_tx(pg_temp.tok(2));
  v_all := v_all + 1;
  if (r ->> 'ok')::boolean and st -> 'bust' = 'null'::jsonb and (st -> 'extras' ->> '2')::int = 500
     and (public._tbl_balances(v_sid) ->> '2')::int = 500
    then v_ok := v_ok + 1; v_msg := v_msg || '✅'; else v_msg := v_msg || '🔴'; end if;
  v_msg := v_msg || ' ⑤ 追加 500：extras = ' || coalesce((st -> 'extras')::text, '∅') || '、剩 ' || coalesce(public._tbl_balances(v_sid) ->> '2', '∅') || E'\n';

  -- ⑥ 追加完可以繼續送
  v_all := v_all + 1;
  begin
    r := public.tbl_submit_hand_tx(pg_temp.tok(3), 'draw', null, '[]'::jsonb);
    if (r ->> 'ok')::boolean then v_ok := v_ok + 1; v_msg := v_msg || '✅ ⑥ 追加之後可以繼續打' || E'\n';
    else v_msg := v_msg || '🔴 ⑥ 追加之後送不出去：' || r::text || E'\n'; end if;
  exception when others then v_msg := v_msg || '🔴 ⑥ 追加之後送不出去：' || sqlerrm || E'\n';
  end;

  v_msg := 'ⓐ 追加：通過 ' || v_ok || ' / ' || v_all || E'\n' || v_msg;
  raise exception 'migi_rollback';
exception when others then
  if sqlerrm = 'migi_rollback' then perform set_config('migi.a', v_msg, true);
  else perform set_config('migi.a', v_msg || '🔴 中途出錯：' || sqlstate || ' ' || sqlerrm, true); end if;
end $$;

-- ⓑ 撤銷路線
do $$
declare v_sid uuid := '1ea984c6-e15e-4888-a4d6-9f99f0860120'; r jsonb; st jsonb; v_hand uuid; v_msg text := ''; v_ok int := 0; v_all int := 0;
begin
  perform set_config('request.jwt.claims', '', true);
  perform pg_temp.migi_setup(true);
  r := public.tbl_submit_hand_tx(pg_temp.tok(1), 'ron', 2::smallint, '[{"code":"hunyise","n":1}]'::jsonb);
  v_hand := (r ->> 'hand_id')::uuid;
  r := public.tbl_confirm_hand_tx(pg_temp.tok(2), v_hand, true);
  r := public.tbl_undo_last_tx(pg_temp.tok(1));
  st := public.tbl_state_tx(pg_temp.tok(2));
  v_all := v_all + 1;
  if st -> 'bust' = 'null'::jsonb
     and exists (select 1 from public.session_busts where session_id = v_sid and hand_id = v_hand and decision = 'voided')
    then v_ok := v_ok + 1; v_msg := v_msg || '✅'; else v_msg := v_msg || '🔴'; end if;
  v_msg := v_msg || ' 撤銷造成爆卡的那一局 → 撤銷結果 ' || left(coalesce(r::text, '∅'), 60) || '、state.bust = ' || coalesce((st -> 'bust')::text, 'null') || E'\n';

  v_msg := 'ⓑ 撤銷：通過 ' || v_ok || ' / ' || v_all || E'\n' || v_msg;
  raise exception 'migi_rollback';
exception when others then
  if sqlerrm = 'migi_rollback' then perform set_config('migi.b', v_msg, true);
  else perform set_config('migi.b', v_msg || '🔴 中途出錯：' || sqlstate || ' ' || sqlerrm, true); end if;
end $$;

-- ⓒ 結束路線（有記分）＋ 收桌看成就
do $$
declare v_sid uuid := '1ea984c6-e15e-4888-a4d6-9f99f0860120'; r jsonb; st jsonb; v_hand uuid; v_msg text := ''; v_ok int := 0; v_all int := 0;
  m1 uuid; m2 uuid; v_has1 boolean; v_has2 boolean;
begin
  perform set_config('request.jwt.claims', '', true);
  perform pg_temp.migi_setup(false);
  select member_id into m1 from public.session_players where session_id = v_sid and seat = 1;
  select member_id into m2 from public.session_players where session_id = v_sid and seat = 2;
  r := public.tbl_submit_hand_tx(pg_temp.tok(1), 'ron', 2::smallint, '[{"code":"hunyise","n":1}]'::jsonb);
  v_hand := (r ->> 'hand_id')::uuid;
  r := public.tbl_confirm_hand_tx(pg_temp.tok(2), v_hand, true);
  r := public.tbl_bust_decide_tx(pg_temp.tok(2), 0);
  st := public.tbl_state_tx(pg_temp.tok(1));
  v_all := v_all + 1;
  if (r ->> 'ended')::boolean and st -> 'session' ->> 'ended_reason' = 'bust' and (st -> 'session' ->> 'bust_seat')::int = 2
     and public._session_scored(v_sid)
     and not exists (select 1 from public.session_rounds where session_id = v_sid and status = 'playing')
    then v_ok := v_ok + 1; v_msg := v_msg || '✅'; else v_msg := v_msg || '🔴'; end if;
  v_msg := v_msg || ' 不追加 → ' || r::text || '、ended_reason ' || coalesce(st -> 'session' ->> 'ended_reason', '∅')
        || '、成績已算 ' || public._session_scored(v_sid)::text || E'\n';

  -- 成績算完不能再開一將（既有擋牆）
  v_all := v_all + 1;
  begin
    r := public.tbl_start_round_tx(pg_temp.tok(1), 1::smallint, 2::smallint, 3::smallint);
    if coalesce((r ->> 'ok')::boolean, false) then v_msg := v_msg || '🔴 結束之後還能開新的一將' || E'\n';
    else v_ok := v_ok + 1; v_msg := v_msg || '✅ 結束之後不能再開一將：' || coalesce(r ->> 'message', r::text) || E'\n'; end if;
  exception when others then
    v_ok := v_ok + 1; v_msg := v_msg || '✅ 結束之後不能再開一將：' || sqlerrm || E'\n';
  end;

  -- 收桌 ⇒ 成就
  r := public.settle_session_tx(v_sid, null, false);
  select exists (select 1 from public.member_achievements ma join public.achievements a on a.id = ma.achievement_id
                  where ma.member_id = m2 and a.code = 'game_25' and ma.status = 'unlocked') into v_has2;
  select exists (select 1 from public.member_achievements ma join public.achievements a on a.id = ma.achievement_id
                  where ma.member_id = m1 and a.code = 'game_26' and ma.status = 'unlocked') into v_has1;
  v_all := v_all + 1;
  if v_has2 and v_has1 then v_ok := v_ok + 1; v_msg := v_msg || '✅'; else v_msg := v_msg || '🔴'; end if;
  v_msg := v_msg || ' 收桌後：座位 2「爆卡」' || case when v_has2 then '亮' else '沒亮' end
        || '、座位 1「讓對手爆卡」' || case when v_has1 then '亮' else '沒亮' end || E'\n';

  v_msg := 'ⓒ 結束（有記分）：通過 ' || v_ok || ' / ' || v_all || E'\n' || v_msg;
  raise exception 'migi_rollback';
exception when others then
  if sqlerrm = 'migi_rollback' then perform set_config('migi.c', v_msg, true);
  else perform set_config('migi.c', v_msg || '🔴 中途出錯：' || sqlstate || ' ' || sqlerrm, true); end if;
end $$;

-- ⓓ 純娛樂負對照
do $$
declare v_sid uuid := '1ea984c6-e15e-4888-a4d6-9f99f0860120'; r jsonb; v_hand uuid; v_msg text := ''; v_ok int := 0; v_all int := 0;
  m1 uuid; m2 uuid; v_has1 boolean; v_has2 boolean;
begin
  perform set_config('request.jwt.claims', '', true);
  perform pg_temp.migi_setup(true);
  select member_id into m1 from public.session_players where session_id = v_sid and seat = 1;
  select member_id into m2 from public.session_players where session_id = v_sid and seat = 2;
  r := public.tbl_submit_hand_tx(pg_temp.tok(1), 'ron', 2::smallint, '[{"code":"hunyise","n":1}]'::jsonb);
  v_hand := (r ->> 'hand_id')::uuid;
  r := public.tbl_confirm_hand_tx(pg_temp.tok(2), v_hand, true);
  r := public.tbl_bust_decide_tx(pg_temp.tok(2), 0);
  r := public.settle_session_tx(v_sid, null, false);
  select exists (select 1 from public.member_achievements ma join public.achievements a on a.id = ma.achievement_id
                  where ma.member_id = m2 and a.code = 'game_25' and ma.status = 'unlocked') into v_has2;
  select exists (select 1 from public.member_achievements ma join public.achievements a on a.id = ma.achievement_id
                  where ma.member_id = m1 and a.code = 'game_26' and ma.status = 'unlocked') into v_has1;
  v_all := v_all + 1;
  if not v_has2 and not v_has1 and (select count(*) from public.session_busts where session_id = v_sid and decision = 'ended') = 1
    then v_ok := v_ok + 1; v_msg := v_msg || '✅'; else v_msg := v_msg || '🔴'; end if;
  v_msg := v_msg || ' 純娛樂一樣會爆卡、結束，但兩枚成就都不亮（爆卡 ' || case when v_has2 then '亮' else '沒亮' end
        || '、讓對手爆卡 ' || case when v_has1 then '亮' else '沒亮' end || '）' || E'\n';

  v_msg := 'ⓓ 純娛樂：通過 ' || v_ok || ' / ' || v_all || E'\n' || v_msg;
  raise exception 'migi_rollback';
exception when others then
  if sqlerrm = 'migi_rollback' then perform set_config('migi.d', v_msg, true);
  else perform set_config('migi.d', v_msg || '🔴 中途出錯：' || sqlstate || ' ' || sqlerrm, true); end if;
end $$;

select coalesce(nullif(current_setting('migi.a', true), ''), '🔴 ⓐ 沒有訊息') || E'\n'
    || coalesce(nullif(current_setting('migi.b', true), ''), '🔴 ⓑ 沒有訊息') || E'\n'
    || coalesce(nullif(current_setting('migi.c', true), ''), '🔴 ⓒ 沒有訊息') || E'\n'
    || coalesce(nullif(current_setting('migi.d', true), ''), '🔴 ⓓ 沒有訊息') as "行為測試";
