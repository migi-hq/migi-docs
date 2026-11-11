-- 驗：線上好友房牌桌的整包資料，每個人帶著自己小熊現在穿的配件（2026-11-11）
-- 在 Supabase SQL Editor 跑（會寫入，所以不能走唯讀 MCP）；最後整段回滾，一列都不會留下
-- 對象：sql/pending/2026-11-11_線上好友房_牌桌帶小熊配件.sql 跑完之後
-- 做法：四個測試帳號在交易裡開一場線上打的好友練習賽。
--       第 1 位：先讓他解鎖「會送配件的那個成就」，再把穿搭直接寫成「一件擁有的 ＋ 一件根本沒有的」
--       第 2 位：穿搭直接寫成「一件根本沒有的」
--       然後看牌桌後端讀到的 players：第 1 位只剩擁有的那一件、第 2 位是空的、每個人都有 outfit 這個欄位

do $$
declare
  v_org uuid; v_m uuid[]; v_l text[]; v_sl uuid; v_msg text := ''; r jsonb; v_txt text; v_tok text; v_gid uuid; v_sid uuid; i int; v_n int;
  v_ach uuid; v_item text; v_fake constant text := '__沒有這件__'; v_want jsonb; v_got jsonb;
  ok constant text := E'\n✅ '; ng constant text := E'\n🔴 ';
begin
  select array_agg(id), array_agg(line_user_id) into v_m, v_l
    from (select id, line_user_id from public.members
           where is_test and deleted_at is null and hidden_at is null and line_user_id is not null order by created_at limit 4) x;
  if coalesce(cardinality(v_m), 0) < 4 then v_msg := '⚪ 測不了：綁了 LINE 的測試帳號不到四個'; raise exception 'migi_rollback'; end if;
  select org_id into v_org from public.members where id = v_m[1];
  select id into v_sl from public.stake_levels where org_id = v_org and is_active and deleted_at is null and base = 50 and tai = 20 limit 1;
  if v_sl is null then v_msg := '⚪ 測不了：找不到 50/20 的積分級距'; raise exception 'migi_rollback'; end if;
  select id, grants_closet into v_ach, v_item from public.achievements
   where org_id = v_org and grants_closet is not null order by sort, code limit 1;
  if v_ach is null then v_msg := '⚪ 測不了：沒有任何成就會送配件'; raise exception 'migi_rollback'; end if;
  for i in 1 .. 4 loop
    if public._friendly_active_game(v_m[i]) is not null or public._friendly_in_match(v_org, v_m[i]) then
      v_msg := '⚪ 測不了：第 ' || i || ' 個測試帳號現在正在一場牌局或配桌裡（等它結束再跑）'; raise exception 'migi_rollback';
    end if;
  end loop;

  -- 造樣本：第 1 位解鎖那個成就（⇒ 擁有那件配件），穿搭直接寫成「擁有的 ＋ 沒有的」；第 2 位只穿「沒有的」
  insert into public.member_achievements (org_id, member_id, achievement_id, status, unlocked_at)
  values (v_org, v_m[1], v_ach, 'unlocked', now())
  on conflict (member_id, achievement_id) do update set status = 'unlocked', unlocked_at = coalesce(public.member_achievements.unlocked_at, now());
  insert into public.member_app_state (member_id, org_id, bear, titles, outfit, updated_at)
  values (v_m[1], v_org, '{}'::jsonb, '[]'::jsonb, jsonb_build_object('head', v_item, 'neck', v_fake), now())
  on conflict (member_id) do update set outfit = excluded.outfit, updated_at = now();
  insert into public.member_app_state (member_id, org_id, bear, titles, outfit, updated_at)
  values (v_m[2], v_org, '{}'::jsonb, '[]'::jsonb, jsonb_build_object('head', v_fake), now())
  on conflict (member_id) do update set outfit = excluded.outfit, updated_at = now();
  v_want := jsonb_build_object('head', v_item);

  -- ① 第 1 位：只留擁有的那一件（沒有的那件被濾掉）
  v_got := public._member_outfit(v_m[1]);
  v_msg := v_msg || case when v_got = v_want then ok else ng end || '① 擁有的留著、沒有的濾掉（存的是 ' || v_item || ' ＋ 一件沒有的 ⇒ 算出 ' || v_got::text || '）';

  -- ② 第 2 位：只穿了沒有的 ⇒ 空的物件
  v_got := public._member_outfit(v_m[2]);
  v_msg := v_msg || case when v_got = '{}'::jsonb then ok else ng end || '② 只存了一件沒有的 ⇒ 空的（' || v_got::text || '）';

  -- ③ 衣櫃（App 養成小熊那一頁讀的）跟牌桌用的是同一個答案
  perform set_config('request.jwt.claims', jsonb_build_object('sub', gen_random_uuid(), 'role', 'authenticated', 'app_metadata', jsonb_build_object('line_user_id', v_l[1]))::text, true);
  r := public.get_my_closet_tx();
  v_msg := v_msg || case when r -> 'outfit' = v_want and exists (select 1 from jsonb_array_elements(r -> 'owned') o where o ->> 'item' = v_item)
                         then ok else ng end || '③ 衣櫃讀到的穿搭一樣、擁有清單裡有那一件（' || coalesce((r -> 'outfit')::text, '?') || '）';

  -- ④ 開一場線上打、另外三個人加入成桌
  r := public.create_friendly_game_tx(v_sl, now() + interval '1 hour', '台麻', '無花', '1 將', '{}', '{}', 'online');
  v_gid := (r ->> 'game_id')::uuid; v_tok := r ->> 'token';
  v_txt := '';
  for i in 2 .. 4 loop
    perform set_config('request.jwt.claims', jsonb_build_object('sub', gen_random_uuid(), 'role', 'authenticated', 'app_metadata', jsonb_build_object('line_user_id', v_l[i]))::text, true);
    r := public.join_friendly_game_tx(v_tok);
    v_txt := v_txt || case when (r ->> 'ok')::boolean then case when (r ->> 'started')::boolean then '成桌' else '加入' end else coalesce(r ->> 'reason', '?') end || ' ';
  end loop;
  select session_id into v_sid from public.friendly_games where id = v_gid;
  v_msg := v_msg || case when v_txt = '加入 加入 成桌 ' and v_sid is not null then ok else ng end || '④ 開一場線上打並成桌（' || trim(v_txt) || '）';

  -- ⑤ 牌桌後端讀到的整包資料：四個人、每個人都有 outfit 而且是物件（不是 null、不是缺這個欄位）
  r := public._online_ctx(v_sid);
  select count(*) filter (where jsonb_typeof(p -> 'outfit') = 'object'), count(*) into v_n, i from jsonb_array_elements(r -> 'players') p;
  v_msg := v_msg || case when (r ->> 'ok')::boolean and i = 4 and v_n = 4 then ok else ng end || '⑤ 整包資料：' || i || ' 個人裡 ' || v_n || ' 個帶著 outfit 物件';

  -- ⑥ 第 1 位在牌桌上穿的 ＝ 他擁有的那一件；第 2 位是空的
  select p -> 'outfit' into v_got from jsonb_array_elements(r -> 'players') p where (p ->> 'member_id')::uuid = v_m[1];
  select p -> 'outfit' into v_want from jsonb_array_elements(r -> 'players') p where (p ->> 'member_id')::uuid = v_m[2];
  v_msg := v_msg || case when v_got = jsonb_build_object('head', v_item) and v_want = '{}'::jsonb then ok else ng end
        || '⑥ 牌桌上：第 1 位 ' || coalesce(v_got::text, '?') || '、第 2 位 ' || coalesce(v_want::text, '?');

  -- ⑦ 登入的客人自己叫不到這兩支（只有牌桌後端叫得到）
  begin
    set local role authenticated;
    perform public._member_outfit(v_m[1]);
    reset role;
    v_msg := v_msg || ng || '⑦ 登入的客人竟然叫得動 _member_outfit';
  exception when insufficient_privilege then
    reset role;
    v_msg := v_msg || ok || '⑦ 登入的客人叫不到 _member_outfit（權限不足）';
  end;

  raise exception 'migi_rollback';
exception when others then
  reset role;
  perform set_config('request.jwt.claims', '', true);
  perform set_config('migi.chk', ltrim(v_msg, E'\n') ||
    case when sqlerrm = 'migi_rollback' then '' else E'\n🔴 走到一半出錯（上面沒印出來的格子都沒跑到）：' || sqlerrm end, true);
end $$;

select coalesce(nullif(current_setting('migi.chk', true), ''), '🔴 沒有訊息') as "驗證（應該 7 格全綠）";
