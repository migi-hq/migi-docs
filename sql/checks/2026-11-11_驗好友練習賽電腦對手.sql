-- 驗：線上開打加電腦對手 → 湊滿成桌 → 牌桌後端認得誰是電腦；電腦不會收到通知（2026-11-11）
-- 在 Supabase SQL Editor 跑（會寫入，所以不能走唯讀 MCP）；最後整段回滾，一列都不會留下
-- 對象：sql/pending/2026-11-11_好友練習賽_電腦對手.sql 跑完之後

do $$
declare
  v_org uuid; v_m uuid[]; v_l text[]; v_sl uuid; v_msg text := ''; r jsonb; c jsonb; v_txt text; v_gid uuid; v_sid uuid; i int; v_n int; v_b int;
  ok constant text := E'\n✅ '; ng constant text := E'\n🔴 ';
begin
  select array_agg(id), array_agg(line_user_id) into v_m, v_l
    from (select id, line_user_id from public.members
           where is_test and not is_bot and deleted_at is null and hidden_at is null and line_user_id is not null order by created_at limit 2) x;
  if coalesce(cardinality(v_m), 0) < 2 then v_msg := '⚪ 測不了：綁了 LINE 的測試帳號不到兩個'; raise exception 'migi_rollback'; end if;
  select org_id into v_org from public.members where id = v_m[1];
  select id into v_sl from public.stake_levels where org_id = v_org and is_active and deleted_at is null and base = 50 and tai = 20 limit 1;
  if v_sl is null then v_msg := '⚪ 測不了：找不到 50/20 的積分級距'; raise exception 'migi_rollback'; end if;
  for i in 1 .. 2 loop
    if public._friendly_active_game(v_m[i]) is not null or public._friendly_in_match(v_org, v_m[i]) then
      v_msg := '⚪ 測不了：第 ' || i || ' 個測試帳號現在正在一場牌局或配桌裡（等它結束再跑）'; raise exception 'migi_rollback';
    end if;
  end loop;
  perform set_config('request.jwt.claims', jsonb_build_object('sub', gen_random_uuid(), 'role', 'authenticated', 'app_metadata', jsonb_build_object('line_user_id', v_l[1]))::text, true);

  -- ① 我有麻將桌（計分板）的那一種不能加電腦。開完用小交易退掉
  v_txt := null;
  begin
    r := public.create_friendly_game_tx(v_sl, now() + interval '1 hour', '台麻', '無花', '1 將');
    perform public.add_friendly_bots_tx((r ->> 'game_id')::uuid, 1);
    v_txt := '竟然加得進去';
    raise exception 'undo';
  exception when others then
    v_txt := coalesce(v_txt, sqlerrm);
  end;
  v_msg := v_msg || case when v_txt like '%只有線上開打%' then ok else ng end || '① 我有麻將桌的那一種 ⇒ 不能加電腦（' || v_txt || '）';

  -- 開一場線上開打
  r := public.create_friendly_game_tx(v_sl, now() + interval '1 hour', '台麻', '無花', '1 將', '{}', '{}', 'online');
  v_gid := (r ->> 'game_id')::uuid;

  -- ② 數量不對 ⇒ 擋（0 位、4 位）
  v_txt := '';
  begin perform public.add_friendly_bots_tx(v_gid, 0); v_txt := v_txt || '0 位過了 '; exception when others then v_txt := v_txt || 'x'; end;
  begin perform public.add_friendly_bots_tx(v_gid, 4); v_txt := v_txt || '4 位過了 '; exception when others then v_txt := v_txt || 'x'; end;
  v_msg := v_msg || case when v_txt = 'xx' then ok else ng end || '② 加 0 位、加 4 位都擋下（' || v_txt || '）';

  -- ③ 不是開這一場的人 ⇒ 不能加（先讓第二個人用邀請連結加入，再換成他來叫）
  perform set_config('request.jwt.claims', jsonb_build_object('sub', gen_random_uuid(), 'role', 'authenticated', 'app_metadata', jsonb_build_object('line_user_id', v_l[2]))::text, true);
  perform public.join_friendly_game_tx((select invite_token from public.friendly_games where id = v_gid));
  begin
    perform public.add_friendly_bots_tx(v_gid, 1);
    v_msg := v_msg || ng || '③ 不是開局的人竟然加得了電腦';
  exception when others then
    v_msg := v_msg || case when sqlerrm like '%只有開這一場的人%' then ok else ng end || '③ 不是開局的人 ⇒ 不能加（' || sqlerrm || '）';
  end;
  perform set_config('request.jwt.claims', jsonb_build_object('sub', gen_random_uuid(), 'role', 'authenticated', 'app_metadata', jsonb_build_object('line_user_id', v_l[1]))::text, true);

  -- ④ 現在兩個真人、剩兩個空位：加 3 位 ⇒ 擋；加 1 位 ⇒ 進去一位電腦、還沒成桌
  begin
    perform public.add_friendly_bots_tx(v_gid, 3);
    v_txt := '加 3 位竟然過了';
  exception when others then v_txt := sqlerrm;
  end;
  r := public.add_friendly_bots_tx(v_gid, 1);
  select count(*), count(*) filter (where m.is_bot) into v_n, v_b
    from public.friendly_game_players fp join public.members m on m.id = fp.member_id where fp.game_id = v_gid and fp.left_at is null;
  v_msg := v_msg || case when v_txt like '%只剩 2 個空位%' and (r ->> 'ok')::boolean and not (r ->> 'started')::boolean and v_n = 3 and v_b = 1
                         then ok else ng end || '④ 空位不夠擋下（' || v_txt || '）；加 1 位之後 ' || v_n || ' 人、其中電腦 ' || v_b || ' 位、還沒成桌';

  -- ⑤ 等人卡讀得到誰是電腦
  c := public.get_my_friendly_tx() -> 'game';
  select count(*) filter (where (p ->> 'is_bot')::boolean), count(*) into v_b, v_n from jsonb_array_elements(c -> 'players') p;
  v_msg := v_msg || case when v_n = 3 and v_b = 1 then ok else ng end || '⑤ 等人卡：' || v_n || ' 人裡標成電腦的 ' || v_b || ' 位';

  -- ⑥ 再加 1 位 ⇒ 湊滿四位、直接成桌；同一位電腦不會被加兩次
  r := public.add_friendly_bots_tx(v_gid, 1);
  select session_id into v_sid from public.friendly_games where id = v_gid;
  select count(distinct fp.member_id) into v_b from public.friendly_game_players fp join public.members m on m.id = fp.member_id
   where fp.game_id = v_gid and fp.left_at is null and m.is_bot;
  v_msg := v_msg || case when (r ->> 'started')::boolean and v_sid is not null and v_b = 2
                              and exists (select 1 from public.friendly_games where id = v_gid and status = 'playing')
                         then ok else ng end || '⑥ 再加 1 位 ⇒ 成桌；兩位電腦是不同的兩個（' || v_b || '）';

  -- ⑦ 成桌通知只發給真人（兩則），電腦沒有
  select count(*), count(*) filter (where m.is_bot) into v_n, v_b
    from public.app_notifications n join public.members m on m.id = n.member_id where n.ref_id = v_gid and n.type = 'friendly_ok';
  v_msg := v_msg || case when v_n = 2 and v_b = 0 then ok else ng end || '⑦ 成桌通知 ' || v_n || ' 則，其中發給電腦的 ' || v_b || ' 則';

  -- ⑧ 牌桌後端的整包資料：四個人、兩位標成電腦；電腦也有座位以外該有的東西（配件是空的物件）
  c := public._online_ctx(v_sid);
  select count(*), count(*) filter (where (p ->> 'is_bot')::boolean), count(*) filter (where jsonb_typeof(p -> 'outfit') = 'object')
    into v_n, v_b, i from jsonb_array_elements(c -> 'players') p;
  v_msg := v_msg || case when (c ->> 'ok')::boolean and v_n = 4 and v_b = 2 and i = 4 then ok else ng end
        || '⑧ 牌桌整包資料：' || v_n || ' 人、電腦 ' || v_b || ' 位';

  -- ⑨ 開第一將 ⇒ 電腦也排到座位（1～4 不重複）
  r := public.online_start_round_tx(v_sid, '{2,2,5}', '{1,4,4}', 777, '{"dealer":0,"ren":0,"dice":[1,4,4]}', 'discard', now() + interval '30 seconds');
  select count(distinct sp.seat), count(*) filter (where m.is_bot and sp.seat is not null) into v_n, v_b
    from public.session_players sp join public.members m on m.id = sp.member_id where sp.session_id = v_sid and sp.left_at is null;
  v_msg := v_msg || case when (r ->> 'ok')::boolean and v_n = 4 and v_b = 2 then ok else ng end || '⑨ 開第一將：四個座位都排好，兩位電腦都有座位';

  -- ⑩ 電腦爆卡時牌桌後端替它選「結束整場」的那支，對電腦的座位叫得動（這裡沒有人爆卡 ⇒ 回 no_bust 就代表走得到）
  r := public.online_bust_decide_tx(v_sid, (select sp.seat from public.session_players sp join public.members m on m.id = sp.member_id
                                             where sp.session_id = v_sid and m.is_bot order by sp.seat limit 1), 0);
  v_msg := v_msg || case when r ->> 'reason' = 'no_bust' then ok else ng end || '⑩ 替電腦決定爆卡的那支叫得到（現在沒人爆卡 ⇒ ' || coalesce(r ->> 'reason', r::text) || '）';

  raise exception 'migi_rollback';
exception when others then
  perform set_config('request.jwt.claims', '', true);
  perform set_config('migi.chk', ltrim(v_msg, E'\n') ||
    case when sqlerrm = 'migi_rollback' then '' else E'\n🔴 走到一半出錯（上面沒印出來的格子都沒跑到）：' || sqlerrm end, true);
end $$;

select coalesce(nullif(current_setting('migi.chk', true), ''), '🔴 沒有訊息') as "驗證（應該 10 格全綠）";
