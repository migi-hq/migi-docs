-- 驗：加電腦對手指定哪一隻（點商人熊就是商人熊）、擋牆、湊滿成桌（2026-11-11）
-- 在 Supabase SQL Editor 跑（會寫入，所以不能走唯讀 MCP）；最後整段回滾，一列都不會留下
-- 對象：sql/pending/2026-11-11_加電腦對手指定哪一隻.sql 跑完之後

do $$
declare
  v_org uuid; v_m uuid[]; v_l text[]; v_sl uuid; v_msg text := ''; r jsonb; c jsonb; v_txt text; v_gid uuid; i int; v_n int; v_b int;
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
    perform public.add_friendly_bot_tx((r ->> 'game_id')::uuid, 'coach');
    v_txt := '竟然加得進去';
    raise exception 'undo';
  exception when others then
    v_txt := coalesce(v_txt, sqlerrm);
  end;
  v_msg := v_msg || case when v_txt like '%只有線上開打%' then ok else ng end || '① 我有麻將桌的那一種 ⇒ 不能加電腦（' || v_txt || '）';

  -- 開一場線上開打
  r := public.create_friendly_game_tx(v_sl, now() + interval '1 hour', '台麻', '無花', '1 將', '{}', '{}', 'online');
  v_gid := (r ->> 'game_id')::uuid;

  -- ② 代號不認得 ⇒ 擋（亂打的字、段位熊的代號、空的）
  v_txt := '';
  begin perform public.add_friendly_bot_tx(v_gid, 'panda'); v_txt := v_txt || 'panda 過了 '; exception when others then v_txt := v_txt || 'x'; end;
  begin perform public.add_friendly_bot_tx(v_gid, 'gold');  v_txt := v_txt || 'gold 過了 ';  exception when others then v_txt := v_txt || 'x'; end;
  begin perform public.add_friendly_bot_tx(v_gid, null);    v_txt := v_txt || '空的過了 ';   exception when others then v_txt := v_txt || 'x'; end;
  v_msg := v_msg || case when v_txt = 'xxx' then ok else ng end || '② 不認得的代號、段位熊的代號、空的都擋下（' || v_txt || '）';

  -- ③ 🎯 點商人熊就是商人熊（舊那支照順序加，第一位一定是教練熊 —— 這一格是新函式存在的理由）
  r := public.add_friendly_bot_tx(v_gid, 'merchant');
  select string_agg(m.avatar_bear, ',' order by m.avatar_bear), count(*) into v_txt, v_b
    from public.friendly_game_players fp join public.members m on m.id = fp.member_id where fp.game_id = v_gid and fp.left_at is null and m.is_bot;
  v_msg := v_msg || case when (r ->> 'ok')::boolean and not (r ->> 'started')::boolean and v_b = 1 and v_txt = 'merchant' then ok else ng end
        || '③ 指定商人熊 ⇒ 進來的是 ' || coalesce(v_txt, '沒有人') || '（' || v_b || ' 位）、還沒成桌';

  -- ④ 同一隻不能加兩次
  begin
    perform public.add_friendly_bot_tx(v_gid, 'merchant');
    v_msg := v_msg || ng || '④ 同一隻竟然加了兩次';
  exception when others then
    v_msg := v_msg || case when sqlerrm like '%已經在這一場%' then ok else ng end || '④ 同一隻再加一次 ⇒ 擋（' || sqlerrm || '）';
  end;

  -- ⑤ 等人卡讀得到那一隻是誰（畫面靠這個把已經加入的那一隻反灰）
  c := public.get_my_friendly_tx() -> 'game';
  select count(*) filter (where (p ->> 'is_bot')::boolean and p ->> 'avatar_bear' = 'merchant'), count(*) into v_b, v_n from jsonb_array_elements(c -> 'players') p;
  v_msg := v_msg || case when v_n = 2 and v_b = 1 then ok else ng end || '⑤ 等人卡：' || v_n || ' 人，其中標成電腦而且頭像代號是商人熊的 ' || v_b || ' 位';

  -- ⑥ 不是開這一場的人 ⇒ 不能加（讓第二個人用邀請連結加入，再換成他來叫）
  perform set_config('request.jwt.claims', jsonb_build_object('sub', gen_random_uuid(), 'role', 'authenticated', 'app_metadata', jsonb_build_object('line_user_id', v_l[2]))::text, true);
  perform public.join_friendly_game_tx((select invite_token from public.friendly_games where id = v_gid));
  begin
    perform public.add_friendly_bot_tx(v_gid, 'chef');
    v_msg := v_msg || ng || '⑥ 不是開局的人竟然加得了電腦';
  exception when others then
    v_msg := v_msg || case when sqlerrm like '%只有開這一場的人%' then ok else ng end || '⑥ 不是開局的人 ⇒ 不能加（' || sqlerrm || '）';
  end;
  perform set_config('request.jwt.claims', jsonb_build_object('sub', gen_random_uuid(), 'role', 'authenticated', 'app_metadata', jsonb_build_object('line_user_id', v_l[1]))::text, true);

  -- ⑦ 現在兩個真人 ＋ 商人熊，剩一個空位：加教練熊 ⇒ 湊滿、直接成桌
  r := public.add_friendly_bot_tx(v_gid, 'coach');
  select string_agg(m.avatar_bear, ',' order by m.avatar_bear) into v_txt
    from public.friendly_game_players fp join public.members m on m.id = fp.member_id where fp.game_id = v_gid and fp.left_at is null and m.is_bot;
  v_msg := v_msg || case when (r ->> 'started')::boolean and v_txt = 'coach,merchant'
                              and exists (select 1 from public.friendly_games where id = v_gid and status = 'playing' and session_id is not null)
                         then ok else ng end || '⑦ 再加教練熊 ⇒ 湊滿四位、直接成桌（電腦：' || coalesce(v_txt, '沒有') || '）';

  -- ⑧ 成桌之後不能再加
  begin
    perform public.add_friendly_bot_tx(v_gid, 'chef');
    v_msg := v_msg || ng || '⑧ 成桌之後竟然還加得進去';
  exception when others then
    v_msg := v_msg || case when sqlerrm like '%已經開始了%' then ok else ng end || '⑧ 成桌之後 ⇒ 不能再加（' || sqlerrm || '）';
  end;

  raise exception 'migi_rollback';
exception when others then
  perform set_config('request.jwt.claims', '', true);
  perform set_config('migi.chk', ltrim(v_msg, E'\n') ||
    case when sqlerrm = 'migi_rollback' then '' else E'\n🔴 走到一半出錯（上面沒印出來的格子都沒跑到）：' || sqlerrm end, true);
end $$;

select coalesce(nullif(current_setting('migi.chk', true), ''), '🔴 沒有訊息') as "驗證（應該 8 格全綠）";
