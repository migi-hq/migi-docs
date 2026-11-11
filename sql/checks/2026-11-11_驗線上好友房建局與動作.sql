-- 驗：線上好友房 建局、寫回、打完一局接上計分板、下一局、爆卡（2026-11-11）
-- 在 Supabase SQL Editor 跑（會寫入，所以不能走唯讀 MCP）；樣本全部自己造，最後整段回滾，一列都不會留下
-- 對象：sql/pending/2026-11-11_線上好友房_建局與動作.sql 跑完之後
-- 樣本：四個測試帳號、一場 50/20（每人 2000 起）、約 1 將的線上好友房。
--       這裡不跑引擎（引擎在後端的 JS），state 只放資料庫會檢查的三格：莊家是第幾位、連莊、骰子。
-- ⚠ 不走「不追加 ⇒ 整場結束」那一支：它會叫真的結算（通知、成就），這裡只驗到「追加積分」為止

do $$
declare
  v_org uuid; v_store uuid; v_sl uuid; v_tbl uuid; v_sid uuid; v_gid uuid; v_m uuid[];
  v_msg text := ''; r jsonb; v_hid uuid; v_rid uuid; v_n int; v_txt text; i int;
  ok constant text := E'\n✅ '; ng constant text := E'\n🔴 ';
begin
  select org_id, id into v_org, v_store from public.stores where is_virtual and deleted_at is null limit 1;
  select array_agg(id) into v_m from (select id from public.members where is_test and deleted_at is null and org_id = v_org order by created_at limit 4) x;
  select id into v_sl from public.stake_levels
   where org_id = v_org and is_active and deleted_at is null and base = 50 and tai = 20 and start_points = 2000 limit 1;
  if v_store is null or coalesce(cardinality(v_m), 0) < 4 or v_sl is null then
    v_msg := '⚪ 測不了：找不到虛擬門市、四個測試帳號或 50/20 的積分級距';
    raise exception 'migi_rollback';
  end if;

  -- 造一場（硬規則 3.57：不借線上的資料）
  insert into public.tables (org_id, store_id, label, is_active, seats, sort_order, auto_assign, note)
  values (v_org, v_store, '驗證用 ' || gen_random_uuid()::text, false, 4, 9999, false, '驗證用，會回滾') returning id into v_tbl;
  insert into public.table_sessions (org_id, store_id, table_id, mode, stake_level_id, status, planned_rounds, game_type, flower)
  values (v_org, v_store, v_tbl, 'friendly', v_sl, 'open', 1, '台麻', '無花') returning id into v_sid;
  insert into public.friendly_games (org_id, opened_by, stake_level_id, game_type, flower, rounds, play_at, status, invite_token, session_id, started_at, play_mode)
  values (v_org, v_m[1], v_sl, '台麻', '無花', 1, now() + interval '1 hour', 'playing', 'chk-' || gen_random_uuid()::text, v_sid, now(), 'online')
  returning id into v_gid;
  for i in 1 .. 4 loop
    insert into public.friendly_game_players (org_id, game_id, member_id, join_source) values (v_org, v_gid, v_m[i], case when i = 1 then 'open' else 'buddy' end);
    insert into public.session_players (org_id, session_id, member_id, join_type, status, charged_points) values (v_org, v_sid, v_m[i], 'opener', 'playing', 0);
  end loop;

  -- ① 第一局的 state 莊家不是第 0 位 ⇒ 不收，而且什麼都沒建
  r := public.online_start_round_tx(v_sid, '{5,2,4}', '{3,3,3}', 1, '{"dealer":1,"ren":0,"dice":[3,3,3]}', 'baozi', now() + interval '15 seconds');
  v_msg := v_msg || case when r ->> 'reason' = 'bad_state' and not exists (select 1 from public.session_rounds where session_id = v_sid)
                         then ok else ng end || '① 第一局的莊家不是第 0 位 ⇒ 不收（' || coalesce(r ->> 'reason', r::text) || '）';

  -- ② 開一將：5-2-4 ＝ 11 點，從 1 號數 ⇒ 3 號是東；3-3-3 ＝ 9 點，從東家數 ⇒ 數回東自己 ⇒ 3 號當莊；順序 3→4→1→2
  r := public.online_start_round_tx(v_sid, '{5,2,4}', '{3,3,3}', 12345, '{"dealer":0,"ren":0,"dice":[3,3,3]}', 'baozi', now() + interval '15 seconds');
  v_hid := (r ->> 'hand_id')::uuid; v_rid := (r ->> 'round_id')::uuid;
  v_msg := v_msg || case when (r ->> 'ok')::boolean and (r ->> 'east_seat')::int = 3 and (r ->> 'dealer_seat')::int = 3 and r -> 'ring' = '[3,4,1,2]'::jsonb
                         then ok else ng end || '② 開一將：東 ' || coalesce(r ->> 'east_seat', '?') || ' 號、莊家 ' || coalesce(r ->> 'dealer_seat', '?') || ' 號、順序 ' || coalesce(r ->> 'ring', r::text);
  select count(distinct seat) into v_n from public.session_players where session_id = v_sid and seat between 1 and 4;
  v_msg := v_msg || case when v_n = 4 then ok else ng end || '③ 四個人排到 1～4 號，沒有重複（' || v_n || ' 個）';
  v_msg := v_msg || case when exists (select 1 from public.online_hands where id = v_hid and hand_no = 1 and version = 0 and status = 'playing' and dealer_seat = 3 and seat_dice = '{5,2,4}')
                              and exists (select 1 from public.session_rounds where id = v_rid and first_dealer_seat = 3 and seat_ring = '{3,4,1,2}')
                         then ok else ng end || '④ 第一局與這一將都寫進去了（莊家 3 號、帶著定座位那一擲）';

  -- ⑤ 這一將還在打，再開一次 ⇒ 擋下（四支手機同時叫只會開出一將）
  r := public.online_start_round_tx(v_sid, '{1,1,1}', '{1,1,2}', 2, '{"dealer":0,"ren":0,"dice":[1,1,2]}', 'discard', null);
  v_msg := v_msg || case when r ->> 'reason' = 'round_playing' then ok else ng end || '⑤ 這一將還在打，再開一次擋下（' || coalesce(r ->> 'reason', r::text) || '）';

  -- ⑥ 版本不對 ⇒ stale；版本對 ⇒ 版本 +1、動作有記、那個座位記了上線時間
  r := public.online_commit_tx(v_hid, 7, '{"dealer":0,"ren":0,"dice":[3,3,3],"x":1}', 'discard', null, 3::smallint, 'player', '{"type":"baozi","mult":2}');
  v_msg := v_msg || case when r ->> 'reason' = 'stale' then ok else ng end || '⑥ 版本不對 ⇒ 不寫（' || coalesce(r ->> 'reason', r::text) || '）';
  r := public.online_commit_tx(v_hid, 0, '{"dealer":0,"ren":0,"dice":[3,3,3],"x":1}', 'discard', now() + interval '15 seconds', 3::smallint, 'player', '{"type":"baozi","mult":2}');
  v_msg := v_msg || case when (r ->> 'ok')::boolean and (r ->> 'version')::int = 1
                              and (select count(*) from public.online_actions where online_hand_id = v_hid) = 2
                              and exists (select 1 from public.online_seats where session_id = v_sid and seat = 3 and last_seen_at is not null and auto_since is null)
                         then ok else ng end || '⑦ 版本對 ⇒ 版本變 1、動作紀錄 2 筆（發牌 ＋ 這一步）、3 號記了上線時間';

  -- ⑧ 電腦代打 ⇒ 記下從什麼時候開始代打；本人再動 ⇒ 解除
  r := public.online_commit_tx(v_hid, 1, '{"dealer":0,"ren":0,"dice":[3,3,3],"x":2}', 'claim', null, 4::smallint, 'auto', '{"type":"pass"}');
  select case when auto_since is not null then 'on' else 'off' end into v_txt from public.online_seats where session_id = v_sid and seat = 4;
  r := public.online_commit_tx(v_hid, 2, '{"dealer":0,"ren":0,"dice":[3,3,3],"x":3}', 'discard', null, 4::smallint, 'player', '{"type":"discard","tile":"1m"}');
  v_msg := v_msg || case when v_txt = 'on' and exists (select 1 from public.online_seats where session_id = v_sid and seat = 4 and auto_since is null)
                         then ok else ng end || '⑧ 代打時記下代打中、本人再動就解除';

  -- ⑨ 四家增減加起來不是 0 ⇒ 整筆退回（版本不動、沒有寫進 hands）
  begin
    r := public.online_commit_tx(v_hid, 3, '{"dealer":0,"ren":0,"dice":[3,3,3],"x":4}', 'over', null, 4::smallint, 'player', '{"type":"hu"}',
           '{"type":"ron","winner_seat":4,"deal_in_seat":1,"patterns":[],"tai":1,"deltas":{"1":-110,"2":0,"3":0,"4":999}}');
    v_msg := v_msg || ng || '⑨ 加起來不是 0 的帳竟然寫進去了';
  exception when others then
    v_msg := v_msg || case when (select version from public.online_hands where id = v_hid) = 3 and not exists (select 1 from public.hands where session_id = v_sid)
                           then ok else ng end || '⑨ 加起來不是 0 ⇒ 整筆退回，版本還是 3、hands 沒有東西';
  end;

  -- ⑩ 正常打完：4 號胡 1 號打的牌（3 台 ⇒ 50 ＋ 20×3 ＝ 110）⇒ hands 一筆已確認、線上那一局結束、4 號變 2110
  r := public.online_commit_tx(v_hid, 3, '{"dealer":0,"ren":0,"dice":[3,3,3],"x":4}', 'over', null, 4::smallint, 'player', '{"type":"hu"}',
         '{"type":"ron","winner_seat":4,"deal_in_seat":1,"patterns":[{"code":"menqing","n":1},{"code":"triplet_wind","n":1},{"code":"zhenghua","n":1}],"tai":3,"deltas":{"1":-110,"2":0,"3":0,"4":110}}');
  v_msg := v_msg || case when (r ->> 'ok')::boolean
                              and exists (select 1 from public.hands where id = (r ->> 'hand_id')::uuid and status = 'confirmed' and result = 'ron' and winner_seat = 4 and deal_in_seat = 1
                                           and hand_no = 1 and wind = 1 and dealer_seat = 3 and tai_pattern = 3 and base = 50 and tai_unit = 20 and score_delta = '{"1":-110,"2":0,"3":0,"4":110}'::jsonb)
                              and exists (select 1 from public.online_hands where id = v_hid and status = 'finished' and hand_id = (r ->> 'hand_id')::uuid)
                              and (public._tbl_balances(v_sid) ->> '4')::int = 2110 and (public._tbl_balances(v_sid) ->> '1')::int = 1890
                         then ok else ng end || '⑩ 打完一局：hands 一筆已確認、線上那一局結束、4 號 2110／1 號 1890（' || coalesce(public._tbl_balances(v_sid)::text, '?') || '）';

  -- ⑪ 莊家 3 號沒胡 ⇒ 換莊，照順序 3→4 ⇒ 4 號當莊、連莊 0、第 2 局（用計分板同一支算）
  r := public._tbl_round_state(v_rid);
  v_msg := v_msg || case when (r ->> 'dealer_seat')::int = 4 and (r ->> 'renzhuang')::int = 0 and (r ->> 'hand_no')::int = 2 and not (r ->> 'finished')::boolean
                         then ok else ng end || '⑪ 換莊：4 號當莊、連莊 0、第 2 局（' || r::text || '）';

  -- ⑫ 下一局：莊家送錯 ⇒ out_of_sync；state 的莊家位置不對 ⇒ bad_state；都對 ⇒ 建起來（4 號在順序 3→4→1→2 的第 1 位）
  r := public.online_next_hand_tx(v_sid, 2, 22, '{2,5,6}', 3::smallint, 0::smallint, '{"dealer":0,"ren":0,"dice":[2,5,6]}', 'discard', null);
  v_txt := coalesce(r ->> 'reason', r::text);
  r := public.online_next_hand_tx(v_sid, 2, 22, '{2,5,6}', 4::smallint, 0::smallint, '{"dealer":0,"ren":0,"dice":[2,5,6]}', 'discard', null);
  v_txt := v_txt || '／' || coalesce(r ->> 'reason', r::text);
  r := public.online_next_hand_tx(v_sid, 2, 22, '{2,5,6}', 4::smallint, 0::smallint, '{"dealer":1,"ren":0,"dice":[2,5,6]}', 'discard', now() + interval '15 seconds');
  v_hid := (r ->> 'hand_id')::uuid;
  v_msg := v_msg || case when v_txt = 'out_of_sync／bad_state' and (r ->> 'ok')::boolean then ok else ng end || '⑫ 下一局：莊家送錯、位置送錯都不收（' || v_txt || '），都對才建';

  -- ⑬ 上一局還在打，再建一局 ⇒ 擋下
  r := public.online_next_hand_tx(v_sid, 2, 23, '{1,2,3}', 4::smallint, 0::smallint, '{"dealer":1,"ren":0,"dice":[1,2,3]}', 'discard', null);
  v_msg := v_msg || case when r ->> 'reason' = 'hand_playing' then ok else ng end || '⑬ 上一局還在打，再建一局擋下（' || coalesce(r ->> 'reason', r::text) || '）';

  -- ⑭ 流局 ⇒ 莊家連莊：4 號繼續當莊、連莊 1、第 3 局
  r := public.online_commit_tx(v_hid, 0, '{"dealer":1,"ren":0,"dice":[2,5,6],"x":1}', 'over', null, null, 'system', '{"type":"draw"}',
         '{"type":"draw","winner_seat":null,"deal_in_seat":null,"patterns":[],"tai":0,"deltas":{"1":0,"2":0,"3":0,"4":0}}');
  r := public._tbl_round_state(v_rid);
  v_msg := v_msg || case when (r ->> 'dealer_seat')::int = 4 and (r ->> 'renzhuang')::int = 1 and (r ->> 'hand_no')::int = 3
                         then ok else ng end || '⑭ 流局 ⇒ 4 號連莊 1、第 3 局（' || r::text || '）';

  -- ⑮ 爆卡：第 3 局 1 號放槍要付 5000，他只剩 1890 ⇒ 只付得出 1890；之後不能開下一局
  r := public.online_next_hand_tx(v_sid, 3, 33, '{1,4,4}', 4::smallint, 1::smallint, '{"dealer":1,"ren":1,"dice":[1,4,4]}', 'discard', null);
  v_hid := (r ->> 'hand_id')::uuid;
  r := public.online_commit_tx(v_hid, 0, '{"dealer":1,"ren":1,"dice":[1,4,4],"x":1}', 'over', null, 4::smallint, 'player', '{"type":"hu"}',
         '{"type":"ron","winner_seat":4,"deal_in_seat":1,"patterns":[],"tai":200,"deltas":{"1":-5000,"2":0,"3":0,"4":5000}}');
  v_txt := coalesce(r ->> 'applied', r::text);
  v_msg := v_msg || case when r -> 'applied' = '{"1":-1890,"2":0,"3":0,"4":1890}'::jsonb
                              and exists (select 1 from public.session_busts where session_id = v_sid and seat = 1 and decision = 'pending')
                         then ok else ng end || '⑮ 爆卡：1 號只付得出 1890，記成等他決定（實際入帳 ' || v_txt || '）';
  r := public.online_next_hand_tx(v_sid, 4, 44, '{1,2,4}', 4::smallint, 2::smallint, '{"dealer":1,"ren":2,"dice":[1,2,4]}', 'discard', null);
  v_msg := v_msg || case when r ->> 'reason' = 'bust_pending' then ok else ng end || '⑯ 有人爆卡還沒決定 ⇒ 不能開下一局（' || coalesce(r ->> 'reason', r::text) || '）';

  -- ⑰ 只有爆卡的人能決定；追加 500 ⇒ 他變 500、可以開下一局了
  r := public.online_bust_decide_tx(v_sid, 2::smallint, 500);
  v_txt := coalesce(r ->> 'reason', r::text);
  r := public.online_bust_decide_tx(v_sid, 1::smallint, 500);
  v_msg := v_msg || case when v_txt = 'not_yours' and (r ->> 'ok')::boolean and (public._tbl_balances(v_sid) ->> '1')::int = 500
                         then ok else ng end || '⑰ 別人不能替他決定（' || v_txt || '）；本人追加 500 ⇒ 他變 500';
  r := public.online_next_hand_tx(v_sid, 4, 44, '{1,2,4}', 4::smallint, 2::smallint, '{"dealer":1,"ren":2,"dice":[1,2,4]}', 'discard', null);
  v_msg := v_msg || case when (r ->> 'ok')::boolean then ok else ng end || '⑱ 正對照：追加之後下一局建得起來（4 號連莊 2、第 4 局）';

  -- ⑲ 給後端的整包資料：這一場、這一將、這一局（含 state）、四個人、牌型主檔、四家積分都有
  r := public._online_ctx(v_sid);
  v_msg := v_msg || case when (r ->> 'ok')::boolean and (r -> 'session' ->> 'base')::int = 50 and (r -> 'session' ->> 'unit')::int = 20
                              and (r -> 'round' ->> 'round_no')::int = 1 and r -> 'round' -> 'ring' = '[3,4,1,2]'::jsonb
                              and (r -> 'hand' ->> 'hand_no')::int = 4 and r -> 'hand' -> 'state' ->> 'dealer' = '1'
                              and jsonb_array_length(r -> 'players') = 4 and jsonb_array_length(r -> 'cat') > 20
                              and r -> 'balances' ? '4' and r -> 'bust' = 'null'::jsonb
                         then ok else ng end || '⑲ 整包資料齊全（第 ' || coalesce(r -> 'hand' ->> 'hand_no', '?') || ' 局、' || coalesce(jsonb_array_length(r -> 'players')::text, '?') || ' 人、牌型 ' || coalesce(jsonb_array_length(r -> 'cat')::text, '?') || ' 種）';

  -- ⑳ 沒登入叫 online_me_tx ⇒ 拒絕（這裡沒有登入身分）
  begin
    r := public.online_me_tx();
    v_msg := v_msg || ng || '⑳ 沒登入竟然叫得動 online_me_tx：' || r::text;
  exception when others then
    v_msg := v_msg || case when sqlstate = '28000' then ok else ng end || '⑳ 沒登入叫 online_me_tx ⇒ 拒絕（' || sqlstate || '）';
  end;

  raise exception 'migi_rollback';
exception when others then
  -- 訊息設在這裡才留得住（硬規則 3.9）；上面寫的東西全部隨這個例外退掉
  perform set_config('migi.chk', ltrim(v_msg, E'\n') ||
    case when sqlerrm = 'migi_rollback' then '' else E'\n🔴 走到一半出錯（上面沒印出來的格子都沒跑到）：' || sqlerrm end, true);
end $$;

select coalesce(nullif(current_setting('migi.chk', true), ''), '🔴 沒有訊息') as "驗證（應該 20 格全綠）";
