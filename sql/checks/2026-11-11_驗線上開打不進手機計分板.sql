-- 驗：線上開打的牌局，手機計分板拿不到那一場（當成沒有牌局、另外回 online_playing）（2026-11-11）
-- 在 Supabase SQL Editor 跑（會寫入，所以不能走唯讀 MCP）；最後整段回滾，一列都不會留下
-- 對象：sql/pending/2026-11-11_線上開打不進手機計分板.sql 跑完之後

do $$
declare
  v_org uuid; v_m uuid[]; v_l text[]; v_sl uuid; v_msg text := ''; r jsonb; st jsonb; v_gid uuid; v_sid uuid; i int;
  v_tok constant text := 'chk-online-phone-' || repeat('a', 32); d public.table_devices; v_n int;
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

  -- 第一個測試帳號配一支手機（只活在這個交易裡）
  insert into public.table_devices (org_id, label, token_hash, kind, member_id)
  values (v_org, '驗證用手機', public._tbl_hash(v_tok), 'phone', v_m[1]);

  -- ① 還沒有任何牌局：計分板回「沒有牌局」，而且不是線上對戰中
  st := public.tbl_state_tx(v_tok);
  v_msg := v_msg || case when (st -> 'session') = 'null'::jsonb and not coalesce((st ->> 'online_playing')::boolean, true) then ok else ng end
        || '① 還沒有牌局 ⇒ 計分板：沒有牌局、online_playing = ' || coalesce(st ->> 'online_playing', '（沒有這個鍵）');

  -- 開一場線上開打，加三位電腦湊滿 ⇒ 成桌
  perform set_config('request.jwt.claims', jsonb_build_object('sub', gen_random_uuid(), 'role', 'authenticated', 'app_metadata', jsonb_build_object('line_user_id', v_l[1]))::text, true);
  r := public.create_friendly_game_tx(v_sl, now() + interval '1 hour', '台麻', '無花', '1 將', '{}', '{}', 'online');
  v_gid := (r ->> 'game_id')::uuid;
  r := public.add_friendly_bots_tx(v_gid, 3);
  select session_id into v_sid from public.friendly_games where id = v_gid;

  -- ② 前提（少了它，後面幾格會因為「他根本沒坐進去」而變綠）：他真的坐在一場開著的牌局裡
  select count(*) into v_n from public.session_players sp join public.table_sessions ts on ts.id = sp.session_id
   where sp.member_id = v_m[1] and sp.left_at is null and ts.id = v_sid and ts.status = 'open';
  v_msg := v_msg || case when (r ->> 'started')::boolean and v_sid is not null and v_n = 1 then ok else ng end
        || '② 前提：成桌了，他坐在那一場開著的牌局裡（' || v_n || ' 列）';

  -- ③ 這一場認得出是線上開打
  v_msg := v_msg || case when public._is_online_session(v_sid) then ok else ng end || '③ 這一場認得出是線上開打';

  -- ④ 🎯 認裝置：手機沒有被帶到那一場的桌（桌是空的 ⇒ 計分板每一支函式都找不到牌局）
  d := public._tbl_device(v_tok);
  v_msg := v_msg || case when d.table_id is null then ok else ng end || '④ 認裝置：手機沒有被帶到那一桌（table_id ' || coalesce(d.table_id::text, '是空的') || '）';

  -- ⑤ 計分板的狀態：沒有牌局 ＋ 正在線上對戰
  st := public.tbl_state_tx(v_tok);
  v_msg := v_msg || case when (st -> 'session') = 'null'::jsonb and (st ->> 'online_playing')::boolean then ok else ng end
        || '⑤ 計分板的狀態：' || case when (st -> 'session') = 'null'::jsonb then '沒有牌局' else '🔴 拿到了牌局' end || '、online_playing = ' || coalesce(st ->> 'online_playing', '（沒有這個鍵）');

  -- ⑥ 從計分板送一局 ⇒ 送不進去（計分板的寫入都先認裝置，認不到牌局就擋）
  begin
    r := public.tbl_submit_hand_tx(v_tok, 'draw', null::smallint, '[]'::jsonb, null::integer);   -- 參數照線上簽名：憑證、結果、放槍座位、牌型、數字鍵台數
    v_msg := v_msg || case when coalesce((r ->> 'ok')::boolean, false) then ng else ok end || '⑥ 從計分板送一局流局 ⇒ ' || case when coalesce((r ->> 'ok')::boolean, false) then '竟然送進去了' else '沒有送進去（' || coalesce(r ->> 'message', r ->> 'reason', r::text) || '）' end;
  exception when others then
    v_msg := v_msg || ok || '⑥ 從計分板送一局流局 ⇒ 擋下（' || sqlerrm || '）';
  end;
  select count(*) into v_n from public.hands where session_id = v_sid;
  v_msg := v_msg || case when v_n = 0 then ok else ng end || '⑦ 那一場的計分紀錄還是 ' || v_n || ' 局（計分板沒有寫進任何東西）';

  -- ⑧ 另一個沒在打的測試帳號：不會被標成線上對戰中（不可以誤標）
  insert into public.table_devices (org_id, label, token_hash, kind, member_id)
  values (v_org, '驗證用手機二', public._tbl_hash(v_tok || 'b'), 'phone', v_m[2]);
  st := public.tbl_state_tx(v_tok || 'b');
  v_msg := v_msg || case when (st -> 'session') = 'null'::jsonb and not coalesce((st ->> 'online_playing')::boolean, true) then ok else ng end
        || '⑧ 沒在打的另一個人 ⇒ online_playing = ' || coalesce(st ->> 'online_playing', '（沒有這個鍵）');

  raise exception 'migi_rollback';
exception when others then
  perform set_config('request.jwt.claims', '', true);
  perform set_config('migi.chk', ltrim(v_msg, E'\n') ||
    case when sqlerrm = 'migi_rollback' then '' else E'\n🔴 走到一半出錯（上面沒印出來的格子都沒跑到）：' || sqlerrm end, true);
end $$;

select coalesce(nullif(current_setting('migi.chk', true), ''), '🔴 沒有訊息') as "驗證（應該 8 格全綠）";
