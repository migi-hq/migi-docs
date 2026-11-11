-- 驗：開一場好友練習賽選「特殊規則」→ 存得進去、等人卡讀得到、牌桌後端讀得到（2026-11-11）
-- 在 Supabase SQL Editor 跑（會寫入，所以不能走唯讀 MCP）；最後整段回滾，一列都不會留下
-- 對象：sql/pending/2026-11-11_好友練習賽_特殊規則.sql 跑完之後

do $$
declare
  v_org uuid; v_m uuid[]; v_l text[]; v_sl uuid; v_msg text := ''; r jsonb; c jsonb; v_txt text; v_tok text; v_gid uuid; v_sid uuid; i int;
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
  perform set_config('request.jwt.claims', jsonb_build_object('sub', gen_random_uuid(), 'role', 'authenticated', 'app_metadata', jsonb_build_object('line_user_id', v_l[1]))::text, true);

  -- ① 不認得的規則代碼 ⇒ 不給開（不是安靜略過）
  begin
    r := public.create_friendly_game_tx(v_sl, now() + interval '1 hour', '台麻', '無花', '1 將', '{}', '{}', 'online', array['baozi', 'whatever']);
    v_msg := v_msg || ng || '① 亂填的規則竟然開得了';
  exception when others then
    v_msg := v_msg || case when sqlerrm like '%特殊規則%' then ok else ng end || '① 不認得的規則 ⇒ 不給開（' || sqlerrm || '）';
  end;

  -- ② 正對照：不送特殊規則（＝ 舊版 App 的叫法，八個參數）⇒ 開得了，存成「都不開」。開完用小交易退掉，才不會卡住下面那一場
  v_txt := null;
  begin
    r := public.create_friendly_game_tx(v_sl, now() + interval '1 hour', '台麻', '無花', '1 將', '{}', '{}', 'online');
    v_txt := coalesce((r -> 'special_rules')::text, '?') || '／' || coalesce((select special_rules::text from public.friendly_games where id = (r ->> 'game_id')::uuid), '?');
    raise exception 'undo';
  exception when others then
    if sqlerrm <> 'undo' then v_txt := sqlerrm; end if;
  end;
  v_msg := v_msg || case when v_txt = '[]／{}' then ok else ng end || '② 正對照：不送 ⇒ 都不開（' || coalesce(v_txt, '?') || '）';

  -- ③ 面對面打（計分板）也存得進去（這一欄不限打法）。同樣開完退掉
  v_txt := null;
  begin
    r := public.create_friendly_game_tx(v_sl, now() + interval '1 hour', '台麻', '無花', '1 將', '{}', '{}', 'scoreboard', array['quanhong']);
    v_txt := coalesce((select special_rules::text from public.friendly_games where id = (r ->> 'game_id')::uuid), '?');
    raise exception 'undo';
  exception when others then
    if sqlerrm <> 'undo' then v_txt := sqlerrm; end if;
  end;
  v_msg := v_msg || case when v_txt = '{quanhong}' then ok else ng end || '③ 面對面打也存得進去（' || coalesce(v_txt, '?') || '）';

  -- ④ 開一場線上打，勾 豹子 ＋ 骰龜（故意重複、順序顛倒）⇒ 存成固定順序、不重複
  r := public.create_friendly_game_tx(v_sl, now() + interval '1 hour', '台麻', '無花', '1 將', '{}', '{}', 'online', array['baozi', 'shaigui', 'baozi']);
  v_gid := (r ->> 'game_id')::uuid; v_tok := r ->> 'token';
  select special_rules::text into v_txt from public.friendly_games where id = v_gid;
  v_msg := v_msg || case when (r ->> 'ok')::boolean and v_txt = '{shaigui,baozi}' and r -> 'special_rules' = '["shaigui", "baozi"]'::jsonb
                         then ok else ng end || '④ 勾 豹子＋骰龜（重複、顛倒）⇒ 存成 ' || coalesce(v_txt, '?');

  -- ⑤ 等人卡讀得到
  c := public.get_my_friendly_tx() -> 'game';
  v_msg := v_msg || case when c -> 'special_rules' = '["shaigui", "baozi"]'::jsonb and c ->> 'play_mode' = 'online'
                         then ok else ng end || '⑤ 等人卡讀到的特殊規則：' || coalesce((c -> 'special_rules')::text, '?');

  -- ⑥ 另外三個人加入成桌 ⇒ 牌桌後端的整包資料帶著同一份
  for i in 2 .. 4 loop
    perform set_config('request.jwt.claims', jsonb_build_object('sub', gen_random_uuid(), 'role', 'authenticated', 'app_metadata', jsonb_build_object('line_user_id', v_l[i]))::text, true);
    perform public.join_friendly_game_tx(v_tok);
  end loop;
  select session_id into v_sid from public.friendly_games where id = v_gid;
  if v_sid is null then v_msg := v_msg || ng || '⑥ 前置失敗：四個人加入之後沒有成桌'; raise exception 'migi_rollback'; end if;
  c := public._online_ctx(v_sid);
  v_msg := v_msg || case when (c ->> 'ok')::boolean and c -> 'session' -> 'special_rules' = '["shaigui", "baozi"]'::jsonb
                              and c -> 'session' ->> 'game_type' = '台麻' and c -> 'session' ->> 'started_at' is not null
                         then ok else ng end || '⑥ 牌桌後端讀到的特殊規則：' || coalesce((c -> 'session' -> 'special_rules')::text, '?');

  -- ⑦ 加入的朋友在自己的等人卡／進行中也讀得到（不是只有開局的人）
  c := public.get_my_friendly_tx() -> 'game';
  v_msg := v_msg || case when c -> 'special_rules' = '["shaigui", "baozi"]'::jsonb then ok else ng end
        || '⑦ 加入的朋友讀到的特殊規則：' || coalesce((c -> 'special_rules')::text, '?');

  raise exception 'migi_rollback';
exception when others then
  perform set_config('request.jwt.claims', '', true);
  perform set_config('migi.chk', ltrim(v_msg, E'\n') ||
    case when sqlerrm = 'migi_rollback' then '' else E'\n🔴 走到一半出錯（上面沒印出來的格子都沒跑到）：' || sqlerrm end, true);
end $$;

select coalesce(nullif(current_setting('migi.chk', true), ''), '🔴 沒有訊息') as "驗證（應該 7 格全綠）";
