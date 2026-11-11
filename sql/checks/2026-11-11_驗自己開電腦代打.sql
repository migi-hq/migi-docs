-- 驗：線上好友房自己開「電腦代打」，牌桌整包資料帶得出來、出牌不會把它清掉（2026-11-11）
-- 在 Supabase SQL Editor 跑（會寫入，所以不能走唯讀 MCP）；最後整段回滾，一列都不會留下
-- 對象：sql/pending/2026-11-11_線上好友房_自己開電腦代打.sql 跑完之後
-- 做法：四個測試帳號開一場線上打、成桌、開第一將，然後替第 1 位開代打，看另外三家讀到的整包資料

do $$
declare
  v_org uuid; v_m uuid[]; v_l text[]; v_sl uuid; v_msg text := ''; r jsonb; c jsonb; v_txt text; v_tok text; v_gid uuid; v_sid uuid; i int;
  v_seat smallint; v_other smallint; v_hand uuid; v_ver int;
  ok constant text := E'\n✅ '; ng constant text := E'\n🔴 ';
begin
  select array_agg(id), array_agg(line_user_id) into v_m, v_l
    from (select id, line_user_id from public.members
           where is_test and deleted_at is null and hidden_at is null and line_user_id is not null order by created_at limit 4) x;
  if coalesce(cardinality(v_m), 0) < 4 then v_msg := '⚪ 測不了：綁了 LINE 的測試帳號不到四個'; raise exception 'migi_rollback'; end if;
  select org_id into v_org from public.members where id = v_m[1];
  select id into v_sl from public.stake_levels where org_id = v_org and is_active and deleted_at is null and base = 50 and tai = 20 limit 1;
  if v_sl is null then v_msg := '⚪ 測不了：找不到 50/20 的積分級距'; raise exception 'migi_rollback'; end if;
  for i in 1 .. 4 loop
    if public._friendly_active_game(v_m[i]) is not null or public._friendly_in_match(v_org, v_m[i]) then
      v_msg := '⚪ 測不了：第 ' || i || ' 個測試帳號現在正在一場牌局或配桌裡（等它結束再跑）'; raise exception 'migi_rollback';
    end if;
  end loop;

  -- 開一場線上打、另外三個人加入成桌
  perform set_config('request.jwt.claims', jsonb_build_object('sub', gen_random_uuid(), 'role', 'authenticated', 'app_metadata', jsonb_build_object('line_user_id', v_l[1]))::text, true);
  r := public.create_friendly_game_tx(v_sl, now() + interval '1 hour', '台麻', '無花', '1 將', '{}', '{}', 'online');
  v_gid := (r ->> 'game_id')::uuid; v_tok := r ->> 'token';
  for i in 2 .. 4 loop
    perform set_config('request.jwt.claims', jsonb_build_object('sub', gen_random_uuid(), 'role', 'authenticated', 'app_metadata', jsonb_build_object('line_user_id', v_l[i]))::text, true);
    perform public.join_friendly_game_tx(v_tok);
  end loop;
  select session_id into v_sid from public.friendly_games where id = v_gid;
  if v_sid is null then v_msg := '🔴 前置失敗：四個人加入之後沒有成桌'; raise exception 'migi_rollback'; end if;

  -- ① 還沒開第一將、座位還沒排 ⇒ 開不了（回 bad_seat，不會憑空寫一列）
  r := public.online_set_auto_tx(v_sid, 1::smallint, true);
  v_msg := v_msg || case when r ->> 'reason' = 'bad_seat' and not exists (select 1 from public.online_seats where session_id = v_sid)
                         then ok else ng end || '① 座位還沒排 ⇒ 開不了（' || coalesce(r ->> 'reason', r::text) || '）';

  -- 開第一將 ⇒ 座位排好；查第 1 位坐幾號、另外找一個別人的座位
  r := public.online_start_round_tx(v_sid, '{2,2,5}', '{1,4,4}', 777, '{"dealer":0,"ren":0,"dice":[1,4,4]}', 'discard', now() + interval '30 seconds');
  select seat into v_seat from public.session_players where session_id = v_sid and member_id = v_m[1] and left_at is null;
  select seat into v_other from public.session_players where session_id = v_sid and member_id = v_m[2] and left_at is null;
  if v_seat is null or v_other is null then v_msg := v_msg || ng || '前置失敗：開第一將之後座位沒有排好（' || coalesce(r::text, '?') || '）'; raise exception 'migi_rollback'; end if;

  -- ② 開之前：整包資料裡沒有人開著
  c := public._online_ctx(v_sid);
  v_msg := v_msg || case when not exists (select 1 from jsonb_each(c -> 'presence') e where (e.value ->> 'auto_on')::boolean)
                         then ok else ng end || '② 開之前沒有人是代打中（' || (c -> 'presence')::text || '）';

  -- ③ 第 1 位開代打 ⇒ 整包資料裡他那個座位是開的，別人不是
  r := public.online_set_auto_tx(v_sid, v_seat, true);
  c := public._online_ctx(v_sid);
  v_msg := v_msg || case when (r ->> 'ok')::boolean and (c -> 'presence' -> v_seat::text ->> 'auto_on')::boolean
                              and coalesce((c -> 'presence' -> v_other::text ->> 'auto_on')::boolean, false) = false
                         then ok else ng end || '③ 開了之後：座位 ' || v_seat || ' 是代打中、座位 ' || v_other || ' 不是';

  -- ④ 他自己的手機送出一個動作（開著代打時手機就是這樣替他打牌的）⇒ 旗標還在，不會被清掉
  v_hand := (c -> 'hand' ->> 'id')::uuid; v_ver := (c -> 'hand' ->> 'version')::int;
  r := public.online_commit_tx(v_hand, v_ver, c -> 'hand' -> 'state', c -> 'hand' ->> 'phase', now() + interval '30 seconds', v_seat, 'player', '{"type":"test"}'::jsonb);
  c := public._online_ctx(v_sid);
  v_msg := v_msg || case when (r ->> 'ok')::boolean and (c -> 'presence' -> v_seat::text ->> 'auto_on')::boolean
                              and c -> 'presence' -> v_seat::text ->> 'auto_since' is null
                              and c -> 'presence' -> v_seat::text ->> 'last_seen_at' is not null
                         then ok else ng end || '④ 他自己出一次牌之後：還是代打中、逾時代打那一格是空的、上線時間有記（' || coalesce(r ->> 'reason', 'ok') || '）';

  -- ⑤ 正對照：別人逾時被後端代打，記的是另一格（auto_since），不會被當成「自己開的」
  v_ver := (c -> 'hand' ->> 'version')::int;
  r := public.online_commit_tx(v_hand, v_ver, c -> 'hand' -> 'state', c -> 'hand' ->> 'phase', now() + interval '30 seconds', v_other, 'auto', '{"type":"test"}'::jsonb);
  c := public._online_ctx(v_sid);
  v_msg := v_msg || case when (r ->> 'ok')::boolean and c -> 'presence' -> v_other::text ->> 'auto_since' is not null
                              and (c -> 'presence' -> v_other::text ->> 'auto_on')::boolean = false
                         then ok else ng end || '⑤ 正對照：逾時被代打的人記在 auto_since，auto_on 還是關的';

  -- ⑥ 關掉 ⇒ 整包資料裡變回關的
  r := public.online_set_auto_tx(v_sid, v_seat, false);
  c := public._online_ctx(v_sid);
  v_msg := v_msg || case when (r ->> 'ok')::boolean and (c -> 'presence' -> v_seat::text ->> 'auto_on')::boolean = false
                         then ok else ng end || '⑥ 關掉之後：座位 ' || v_seat || ' 不是代打中了';

  -- ⑦ 沒人坐的座位號 ⇒ 開不了
  r := public.online_set_auto_tx(v_sid, 9::smallint, true);
  v_msg := v_msg || case when r ->> 'reason' = 'bad_seat' then ok else ng end || '⑦ 沒有人坐的座位號 ⇒ ' || coalesce(r ->> 'reason', r::text);

  -- ⑧ 登入的客人自己叫不到（只有牌桌後端叫得到，座位由後端認）
  begin
    set local role authenticated;
    perform public.online_set_auto_tx(v_sid, v_other, true);
    reset role;
    v_msg := v_msg || ng || '⑧ 登入的客人竟然叫得動 online_set_auto_tx（可以替別人開代打）';
  exception when insufficient_privilege then
    reset role;
    v_msg := v_msg || ok || '⑧ 登入的客人叫不到 online_set_auto_tx（權限不足）';
  end;

  raise exception 'migi_rollback';
exception when others then
  reset role;
  perform set_config('request.jwt.claims', '', true);
  perform set_config('migi.chk', ltrim(v_msg, E'\n') ||
    case when sqlerrm = 'migi_rollback' then '' else E'\n🔴 走到一半出錯（上面沒印出來的格子都沒跑到）：' || sqlerrm end, true);
end $$;

select coalesce(nullif(current_setting('migi.chk', true), ''), '🔴 沒有訊息') as "驗證（應該 8 格全綠）";
