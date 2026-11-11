-- 驗：開一場好友練習賽選「線上打」→ 朋友加入 → 成桌 → 進牌桌（2026-11-11）
-- 在 Supabase SQL Editor 跑（會寫入，所以不能走唯讀 MCP）；最後整段回滾，一列都不會留下
-- 對象：sql/pending/2026-11-11_線上好友房_開一場選線上打.sql 跑完之後
-- 做法：四個測試帳號輪流「登入」（在交易裡換登入憑證的內容，跟真客人走同一條 current_member_id()），
--       走真的 create_friendly_game_tx → join_friendly_game_tx ×3 → 成桌 → online_me_tx → 開第一將

do $$
declare
  v_org uuid; v_m uuid[]; v_l text[]; v_sl uuid; v_msg text := ''; r jsonb; v_txt text; v_tok text; v_gid uuid; v_sid uuid; i int; v_n int;
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

  -- ① 沒登入 ⇒ 開不了
  perform set_config('request.jwt.claims', '', true);
  begin
    r := public.create_friendly_game_tx(v_sl, now() + interval '1 hour', p_play_mode => 'online');
    v_msg := v_msg || ng || '① 沒登入竟然開得了';
  exception when others then
    v_msg := v_msg || case when sqlstate = '28000' then ok else ng end || '① 沒登入 ⇒ 開不了（' || sqlstate || '）';
  end;

  -- 之後都是「第 i 個測試帳號登入」
  perform set_config('request.jwt.claims', jsonb_build_object('sub', gen_random_uuid(), 'role', 'authenticated', 'app_metadata', jsonb_build_object('line_user_id', v_l[1]))::text, true);

  -- ② 美麻 ＋ 線上打 ⇒ 不給開；③ 亂填打法 ⇒ 不給開
  begin
    r := public.create_friendly_game_tx(v_sl, now() + interval '1 hour', '美麻', '無花', '1 將', '{}', '{}', 'online');
    v_msg := v_msg || ng || '② 美麻的線上打竟然開得了';
  exception when others then
    v_msg := v_msg || case when sqlerrm like '%只有台麻%' then ok else ng end || '② 美麻 ＋ 線上打 ⇒ 不給開（' || sqlerrm || '）';
  end;
  begin
    r := public.create_friendly_game_tx(v_sl, now() + interval '1 hour', '台麻', '無花', '1 將', '{}', '{}', 'whatever');
    v_msg := v_msg || ng || '③ 亂填的打法竟然開得了';
  exception when others then
    v_msg := v_msg || case when sqlerrm like '%怎麼打%' then ok else ng end || '③ 亂填打法 ⇒ 不給開（' || sqlerrm || '）';
  end;

  -- ④ 正對照：不送打法（＝ 舊版 App 的叫法）⇒ 照舊是計分板。開完用小交易退掉，才不會卡住下面要開的那一場
  v_txt := null;
  begin
    r := public.create_friendly_game_tx(v_sl, now() + interval '1 hour', '台麻', '無花', '1 將');
    v_txt := coalesce(r ->> 'play_mode', '?') || '／' || coalesce((select play_mode from public.friendly_games where id = (r ->> 'game_id')::uuid), '?');
    raise exception 'undo';
  exception when others then
    if sqlerrm <> 'undo' then v_txt := sqlerrm; end if;
  end;
  v_msg := v_msg || case when v_txt = 'scoreboard／scoreboard' then ok else ng end || '④ 正對照：不送打法 ⇒ 照舊是計分板（' || coalesce(v_txt, '?') || '）';

  -- ⑤ 開一場線上打（台麻、1 將）
  r := public.create_friendly_game_tx(v_sl, now() + interval '1 hour', '台麻', '無花', '1 將', '{}', '{}', 'online');
  v_gid := (r ->> 'game_id')::uuid; v_tok := r ->> 'token';
  v_msg := v_msg || case when (r ->> 'ok')::boolean and r ->> 'play_mode' = 'online'
                              and exists (select 1 from public.friendly_games where id = v_gid and play_mode = 'online' and status = 'waiting')
                              and (public.get_my_friendly_tx() -> 'game' ->> 'play_mode') = 'online'
                         then ok else ng end || '⑤ 開一場線上打：存成 online、等人卡讀得到（' || coalesce(public.get_my_friendly_tx() -> 'game' ->> 'play_mode', '?') || '）';

  -- ⑥ 還在等人 ⇒ 牌桌還進不去
  r := public.online_me_tx();
  v_msg := v_msg || case when r ->> 'reason' = 'no_game' then ok else ng end || '⑥ 還在等人 ⇒ 牌桌還進不去（' || coalesce(r ->> 'reason', r::text) || '）';

  -- ⑦ 另外三個人用邀請連結加入；第四個人進來就成桌
  v_txt := '';
  for i in 2 .. 4 loop
    perform set_config('request.jwt.claims', jsonb_build_object('sub', gen_random_uuid(), 'role', 'authenticated', 'app_metadata', jsonb_build_object('line_user_id', v_l[i]))::text, true);
    r := public.join_friendly_game_tx(v_tok);
    v_txt := v_txt || case when (r ->> 'ok')::boolean then case when (r ->> 'started')::boolean then '成桌' else '加入' end else coalesce(r ->> 'reason', '?') end || ' ';
  end loop;
  select session_id into v_sid from public.friendly_games where id = v_gid;
  v_msg := v_msg || case when v_txt = '加入 加入 成桌 ' and v_sid is not null
                              and exists (select 1 from public.friendly_games where id = v_gid and status = 'playing')
                         then ok else ng end || '⑦ 三個人加入、第四個進來就成桌（' || trim(v_txt) || '）';

  -- ⑧ 成桌通知：四個人都收到，文字是線上打的那一句、內容帶 play_mode
  select count(*) into v_n from public.app_notifications
   where ref_id = v_gid and type = 'friendly_ok' and payload ->> 'play_mode' = 'online' and payload ->> 'text' like '%線上打牌%';
  v_msg := v_msg || case when v_n = 4 then ok else ng end || '⑧ 成桌通知四則，寫的是「打開牌桌開始線上打牌」（' || v_n || ' 則）';

  -- ⑨ 現在牌桌進得去了：每個人都認得出自己、拿到同一場；座位還沒排（等第一個人進牌桌）
  v_txt := '';
  for i in 1 .. 4 loop
    perform set_config('request.jwt.claims', jsonb_build_object('sub', gen_random_uuid(), 'role', 'authenticated', 'app_metadata', jsonb_build_object('line_user_id', v_l[i]))::text, true);
    r := public.online_me_tx();
    v_txt := v_txt || case when (r ->> 'ok')::boolean and (r ->> 'session_id')::uuid = v_sid and (r ->> 'member_id')::uuid = v_m[i] and r ->> 'seat' is null and r ->> 'channel' is not null then 'o' else 'x' end;
  end loop;
  v_msg := v_msg || case when v_txt = 'oooo' then ok else ng end || '⑨ 四個人各自認得出自己、同一場、座位還沒排（' || v_txt || '）';

  -- ⑩ 後端的整包資料：還沒開第一將
  r := public._online_ctx(v_sid);
  v_msg := v_msg || case when (r ->> 'ok')::boolean and r -> 'round' = 'null'::jsonb and r -> 'hand' = 'null'::jsonb and jsonb_array_length(r -> 'players') = 4
                              and (r -> 'session' ->> 'planned_rounds')::int = 1 and not (r ->> 'scored')::boolean
                         then ok else ng end || '⑩ 整包資料：四個人、約 1 將、還沒開第一將';

  -- ⑪ 開第一將（後端的動作）⇒ 座位排好了，每個人再問一次就拿到自己的座位號
  r := public.online_start_round_tx(v_sid, '{2,2,5}', '{1,4,4}', 777, '{"dealer":0,"ren":0,"dice":[1,4,4]}', 'discard', now() + interval '30 seconds');
  v_txt := '';
  for i in 1 .. 4 loop
    perform set_config('request.jwt.claims', jsonb_build_object('sub', gen_random_uuid(), 'role', 'authenticated', 'app_metadata', jsonb_build_object('line_user_id', v_l[i]))::text, true);
    v_txt := v_txt || coalesce(public.online_me_tx() ->> 'seat', '?');
  end loop;
  v_msg := v_msg || case when (r ->> 'ok')::boolean and length(v_txt) = 4 and v_txt ~ '^[1-4]{4}$'
                              and (select count(distinct c) from regexp_split_to_table(v_txt, '') c) = 4
                         then ok else ng end || '⑪ 開第一將之後四個人的座位號：' || v_txt || '（1～4 不重複）';

  -- ⑫ 別的測試帳號以外的人進不來：換成一個不存在的 LINE 身分 ⇒ 認不出來
  perform set_config('request.jwt.claims', jsonb_build_object('sub', gen_random_uuid(), 'role', 'authenticated', 'app_metadata', jsonb_build_object('line_user_id', 'U-nobody-' || gen_random_uuid()::text))::text, true);
  begin
    r := public.online_me_tx();
    v_msg := v_msg || ng || '⑫ 不存在的身分竟然進得去：' || r::text;
  exception when others then
    v_msg := v_msg || case when sqlstate = '28000' then ok else ng end || '⑫ 認不出來的身分 ⇒ 拒絕（' || sqlstate || '）';
  end;

  raise exception 'migi_rollback';
exception when others then
  perform set_config('request.jwt.claims', '', true);
  perform set_config('migi.chk', ltrim(v_msg, E'\n') ||
    case when sqlerrm = 'migi_rollback' then '' else E'\n🔴 走到一半出錯（上面沒印出來的格子都沒跑到）：' || sqlerrm end, true);
end $$;

select coalesce(nullif(current_setting('migi.chk', true), ''), '🔴 沒有訊息') as "驗證（應該 12 格全綠）";
