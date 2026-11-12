-- ════════════════════════════════════════════════════════════════════
-- 2026-11-12　行為測試：好友練習賽公開佇列（先跑 sql/applied/2026-11-12_好友練習賽公開佇列.sql）
-- ════════════════════════════════════════════════════════════════════
-- 用四個測試帳號的身分（JWT 的 sub 直接放 LINE id，同 migi_jwt_line_id 的第二條路）真的開局、看佇列、加入；
-- 整段最後 raise 'migi_rollback' ⇒ 一筆都不留（這一份本來就不要留下東西，所以可以 raise，硬規則 1.8）。
--   T1 開一場「公開」的線上開打　T4 開一場「不公開」的線上開打　T3 封鎖 T1
--   ⓐ 我有麻將桌不能公開　ⓑ 公開的開得起來　ⓒ 佇列看得到公開的、看不到不公開的
--   ⓓ 自己的那一場不列給自己　ⓔ 有封鎖的看不到也加不進去　ⓕ 從佇列加入、來源記 queue
--   ⓖ 不公開的不能從佇列加入（當作找不到）　ⓗ 邀請連結照舊能加入、來源記 link　ⓘ 沒登入叫不到佇列
-- ════════════════════════════════════════════════════════════════════
do $$
declare
  t1 uuid := 'd73fdac2-d6b9-4b8a-bcff-b19c2786056f';  -- 測試01
  t2 uuid := '218378e1-fb6c-43fb-b642-99fdbf5c52b1';  -- 測試02
  t3 uuid := 'd0db928e-5a75-4535-90d4-93ede67790a8';  -- 測試03
  t4 uuid := '526aa8b9-cc93-4327-b878-6d21d399af8e';  -- 測試04
  v_org uuid; v_stake uuid; r jsonb; q jsonb; g1 uuid; g4 uuid; v_tok text; v_src text;
  v_msg text := '';
begin
  select org_id into v_org from members where id = t1;
  select id into v_stake from stake_levels where org_id = v_org and is_active and deleted_at is null order by sort_order nulls last limit 1;
  if v_stake is null then select id into v_stake from stake_levels where org_id = v_org and is_active and deleted_at is null limit 1; end if;

  -- ⓐ T4：我有麻將桌 ＋ 公開 ⇒ 擋
  perform set_config('request.jwt.claims', json_build_object('sub', (select line_user_id from members where id = t4), 'role', 'authenticated')::text, true);
  begin
    r := public.create_friendly_game_tx(v_stake, now() + interval '1 hour', '台麻', '無花', '2 將', '{}'::jsonb, '{}'::uuid[], 'scoreboard', '{}'::text[], true);
    v_msg := v_msg || E'\n🔴 ⓐ 我有麻將桌也開得出公開的一場';
  exception when others then
    v_msg := v_msg || E'\n' || case when sqlerrm like '%只有線上開打可以公開%' then '✅ ⓐ 我有麻將桌不能公開' else '🔴 ⓐ 擋下的原因不對：' || sqlerrm end;
  end;

  -- T4 開一場不公開的線上開打
  r := public.create_friendly_game_tx(v_stake, now() + interval '1 hour', '台麻', '無花', '2 將', '{}'::jsonb, '{}'::uuid[], 'online', '{}'::text[], false);
  g4 := (r ->> 'game_id')::uuid;
  select invite_token into v_tok from friendly_games where id = g4;

  -- ⓑ T1 開一場公開的線上開打
  perform set_config('request.jwt.claims', json_build_object('sub', (select line_user_id from members where id = t1), 'role', 'authenticated')::text, true);
  r := public.create_friendly_game_tx(v_stake, now() + interval '1 hour', '台麻', '有花', '1 將', '{}'::jsonb, '{}'::uuid[], 'online', '{}'::text[], true);
  g1 := (r ->> 'game_id')::uuid;
  v_msg := v_msg || E'\n' || case when (select is_public from friendly_games where id = g1) and (r ->> 'is_public')::boolean
                                  then '✅ ⓑ 公開的線上開打開得起來' else '🔴 ⓑ 開出來不是公開的：' || r::text end;

  -- ⓓ T1 自己看佇列：自己那一場不列
  q := public.list_friendly_queue_tx();
  v_msg := v_msg || E'\n' || case when not exists (select 1 from jsonb_array_elements(q) e where (e ->> 'id')::uuid = g1)
                                  then '✅ ⓓ 自己開的那一場不列給自己' else '🔴 ⓓ 自己的那一場出現在自己的佇列裡' end;

  -- ⓒ T2 看佇列：有 T1 的（公開）、沒有 T4 的（不公開）；欄位跟配桌清單同名
  perform set_config('request.jwt.claims', json_build_object('sub', (select line_user_id from members where id = t2), 'role', 'authenticated')::text, true);
  q := public.list_friendly_queue_tx();
  v_msg := v_msg || E'\n' || case
    when exists (select 1 from jsonb_array_elements(q) e where (e ->> 'id')::uuid = g1 and (e ->> 'player_count')::int = 1
                   and e ? 'stake_label' and e ? 'play_at' and (e -> 'host' ->> 'member_id')::uuid = t1)
     and not exists (select 1 from jsonb_array_elements(q) e where (e ->> 'id')::uuid = g4)
    then '✅ ⓒ 佇列看得到公開的那一場（1 人、開局的是 T1），看不到不公開的'
    else '🔴 ⓒ 佇列內容不對：' || q::text end;

  -- ⓔ T3 封鎖 T1 ⇒ T3 看不到、也加不進去
  insert into member_blocks (org_id, blocker_id, blocked_id) values (v_org, t3, t1);
  perform set_config('request.jwt.claims', json_build_object('sub', (select line_user_id from members where id = t3), 'role', 'authenticated')::text, true);
  q := public.list_friendly_queue_tx();
  r := public.join_public_friendly_tx(g1);
  v_msg := v_msg || E'\n' || case
    when not exists (select 1 from jsonb_array_elements(q) e where (e ->> 'id')::uuid = g1) and r ->> 'reason' = 'blocked'
    then '✅ ⓔ 有封鎖的看不到那一場，硬加也加不進去'
    else '🔴 ⓔ 封鎖沒擋住：清單 ' || q::text || ' 加入 ' || r::text end;

  -- ⓖ T3 從佇列加入不公開的那一場 ⇒ 當作找不到
  r := public.join_public_friendly_tx(g4);
  v_msg := v_msg || E'\n' || case when r ->> 'reason' = 'not_found'
                                  then '✅ ⓖ 不公開的不能從佇列加入（回「找不到」，不透露有這一場）' else '🔴 ⓖ ' || r::text end;

  -- ⓗ T3 用邀請連結加入不公開的那一場 ⇒ 照舊可以，來源 link
  r := public.join_friendly_game_tx(v_tok);
  select join_source into v_src from friendly_game_players where game_id = g4 and member_id = t3 and left_at is null;
  v_msg := v_msg || E'\n' || case when (r ->> 'ok')::boolean and v_src = 'link'
                                  then '✅ ⓗ 邀請連結照舊加得進去，來源記 link' else '🔴 ⓗ ' || r::text || ' 來源 ' || coalesce(v_src, '—') end;

  -- ⓕ T2 從佇列加入公開的那一場 ⇒ 坐上位置，來源 queue
  perform set_config('request.jwt.claims', json_build_object('sub', (select line_user_id from members where id = t2), 'role', 'authenticated')::text, true);
  r := public.join_public_friendly_tx(g1);
  select join_source into v_src from friendly_game_players where game_id = g1 and member_id = t2 and left_at is null;
  v_msg := v_msg || E'\n' || case when (r ->> 'ok')::boolean and v_src = 'queue'
                                       and (select count(*) from friendly_game_players where game_id = g1 and left_at is null) = 2
                                  then '✅ ⓕ 從佇列加入成功，2 / 4，來源記 queue' else '🔴 ⓕ ' || r::text || ' 來源 ' || coalesce(v_src, '—') end;

  -- ⓘ 沒登入 ⇒ 佇列叫不到
  perform set_config('request.jwt.claims', '{}', true);
  begin
    q := public.list_friendly_queue_tx();
    v_msg := v_msg || E'\n🔴 ⓘ 沒登入也讀得到佇列';
  exception when others then
    v_msg := v_msg || E'\n' || case when sqlstate = '28000' then '✅ ⓘ 沒登入叫不到佇列' else '🔴 ⓘ 擋下的原因不對：' || sqlerrm end;
  end;

  raise exception 'migi_rollback';
exception when others then
  perform set_config('migi.r', coalesce(nullif(v_msg, ''), '') || E'\n' ||
    case when sqlerrm = 'migi_rollback' then '（測完全部退回，沒有留下任何一筆）' else '🔴 中途出錯：' || sqlerrm end, true);
end $$;

select coalesce(nullif(current_setting('migi.r', true), ''), '🔴 沒有結果') as "行為測試";
