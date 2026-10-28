-- ============================================================
-- 2026-10-28 行為測試：好友練習賽結算與排除（sql/pending/2026-10-28_好友練習賽_結算與排除.sql 跑完之後）
-- 四個測試帳號在交易裡打完一場 1 將的好友練習賽（兩局直接寫進 hands），最後整段退回、一筆都不留
--   ① 名次與桌上積分寫了 ② 沒有段位分（settled_at、rating_after、score_points 都空、會員段位分沒動）
--   ③ 好友練習賽標成打完、場次還開著（手機要看結束卡） ④ 結算通知四則、文字是好友練習賽
--   ⑤ LINE 結算卡：沒有段位分、按鈕連好友練習賽頁 ⑥ 成績頁紀錄沒有這一場、好友練習賽的數據與紀錄有
--   ⑦ 常去門市沒變 ⑧ 不能按讚 ⑨ 打完 15 分鐘排程收場次
--   ⑩ 換人上桌名單跟著換 ⑪ 開打 6 小時沒有任何一局 ⇒ 作廢、通知
-- 跑法：Supabase SQL Editor 整份執行，看最後那一格
-- ============================================================
do $$
declare
  v_msg text := '';
  org uuid; sk uuid; m uuid[]; l text[]; m5 uuid;
  tok text; gid uuid; sid uuid; rid uuid; g2 uuid; sid2 uuid;
  r jsonb; f jsonb; n int; ok boolean; v_rating int[]; v_home uuid; v_games int; nid uuid;
begin
  select array_agg(id order by created_at), array_agg(line_user_id order by created_at), min(org_id::text)::uuid
    into m, l, org
    from (select id, line_user_id, org_id, created_at from members
           where is_test and deleted_at is null and hidden_at is null and line_user_id is not null
           order by created_at limit 4) x;
  if coalesce(array_length(m, 1), 0) < 4 then
    perform set_config('migi.x', '⚪ 有 LINE id 的測試帳號不到 4 個，測不了', true); return;
  end if;
  select id into m5 from members where deleted_at is null and hidden_at is null and org_id = org and not (id = any(m))
   order by is_test desc, created_at limit 1;
  select id into sk from stake_levels where org_id = org and label = '50/20' and is_active and deleted_at is null;

  begin
    -- ⓪ 前提：身上沒有配桌、沒有正在打的場次、彼此沒有封鎖
    update match_queue_players set left_at = now(), leave_reason = 'quit' where member_id = any(m) and left_at is null;
    update session_players sp set left_at = now()
      from table_sessions ts where ts.id = sp.session_id and ts.status = 'open' and sp.member_id = any(m) and sp.left_at is null;
    delete from member_blocks where blocker_id = any(m) and blocked_id = any(m);
    select array_agg(rating order by array_position(m, id)) into v_rating from members where id = any(m);
    v_home := public._member_home_store(m[1]);

    -- 開一場 1 將、湊滿四人
    perform set_config('request.jwt.claims', json_build_object('sub', l[1], 'role', 'authenticated')::text, true);
    select jsonb_array_length(public.get_my_games_tx(org, m[1], 200)) into v_games;
    r := public.create_friendly_game_tx(sk, now() + interval '2 hours', '台麻', '無花', '1 將');
    gid := (r ->> 'game_id')::uuid; tok := r ->> 'token';
    for i in 2..4 loop
      perform set_config('request.jwt.claims', json_build_object('sub', l[i], 'role', 'authenticated')::text, true);
      perform public.join_friendly_game_tx(tok);
    end loop;
    select session_id into sid from friendly_games where id = gid;

    -- 手機定好座位（座位 1～4 ＝ 測試帳號的順序），打兩局：座位 2 胡座位 3（100）、座位 1 自摸（每家 50）
    update session_players set seat = array_position(m, member_id) where session_id = sid;
    insert into session_rounds (org_id, session_id, round_no, first_dealer_seat, status)
    values (org, sid, 1, 1, 'playing') returning id into rid;
    insert into hands (org_id, session_id, round_id, hand_no, wind, dealer_seat, result, winner_seat, deal_in_seat,
                       score_delta, status, confirmed_at)
    values (org, sid, rid, 1, 1, 1, 'ron', 2, 3, '{"2": 100, "3": -100}', 'confirmed', now()),
           (org, sid, rid, 2, 1, 1, 'tsumo', 1, null, '{"1": 150, "2": -50, "3": -50, "4": -50}', 'confirmed', now());
    update session_rounds set status = 'finished', finished_at = now() where id = rid;   -- 觸發器自動結算

    -- ① 名次與桌上積分
    select count(*) into n from session_players where session_id = sid and finish_rank is not null;
    ok := n = 4 and (select final_score from session_players where session_id = sid and seat = 1) = 150
             and (select finish_rank from session_players where session_id = sid and seat = 1) = 1;
    v_msg := v_msg || case when ok then '✅' else '🔴' end || format(' ① 名次 %s／4、座位 1 第 1 名 +150', n) || E'\n';

    -- ② 沒有段位分
    select count(*) into n from session_players
     where session_id = sid and (settled_at is not null or rating_after is not null or score_points is not null);
    ok := n = 0 and (select array_agg(rating order by array_position(m, id)) from members where id = any(m)) = v_rating;
    v_msg := v_msg || case when ok then '✅' else '🔴' end || ' ② 沒有段位分：settled_at／rating_after／score_points 都空、會員段位分沒動' || E'\n';

    -- ③ 好友練習賽打完、場次還開著
    ok := (select status from friendly_games where id = gid) = 'finished'
      and (select status from table_sessions where id = sid) = 'open'
      and public._friendly_active_game(m[1]) is null;
    v_msg := v_msg || case when ok then '✅' else '🔴' end || ' ③ 好友練習賽標成打完、人放出來、場次還開著（手機看結束卡）' || E'\n';

    -- ④ 結算通知
    select count(*) into n from app_notifications
     where ref_id = sid and type = 'settle' and payload ->> 'mode' = 'friendly' and payload ->> 'text' = '好友練習賽結束了';
    v_msg := v_msg || case when n = 4 then '✅' else '🔴' end || format(' ④ 結算通知 %s／4 則（好友練習賽結束了）', n) || E'\n';

    -- ⑤ LINE 結算卡
    select id into nid from app_notifications where ref_id = sid and type = 'settle' and member_id = m[1];
    f := public._push_settle_fields(nid);
    ok := (f ->> 'friendly')::boolean and f ->> 'rating' is null and f ->> 'store' is null
      and f ->> 'url' like '%go=friendly' and f ->> 'kind_label' = '好友練習賽'
      and public._push_settle_flex(nid) ->> 'altText' like '%好友練習賽結束！第 1 名'
      and public._push_settle_flex(nid)::text not like '%段位分%'
      and public._push_settle_text(nid) like '%類型：好友練習賽%';
    v_msg := v_msg || case when ok then '✅' else '🔴 ' || coalesce(f::text, 'null') end || ' ⑤ LINE 結算卡：類型好友練習賽、沒有段位分與門市、按鈕連好友練習賽頁' || E'\n';

    -- ⑥ 成績頁沒有、好友練習賽頁有
    perform set_config('request.jwt.claims', json_build_object('sub', l[1], 'role', 'authenticated')::text, true);
    r := public.get_my_friendly_tx() -> 'stats';
    ok := jsonb_array_length(public.get_my_games_tx(org, m[1], 200)) = v_games
      and (r ->> 'games')::int >= 1 and (r ->> 'hands')::int >= 2 and (r ->> 'tsumo')::int >= 1
      and (r ->> 'best_score')::int >= 150
      and exists (select 1 from jsonb_array_elements(r -> 'records') x where x ->> 'kind' = 'friendly');
    v_msg := v_msg || case when ok then '✅' else '🔴 ' || coalesce(r::text, 'null') end
                   || ' ⑥ 成績頁紀錄沒有多這一場；好友練習賽的數據（場數、局數、自摸、單場最多）與紀錄有' || E'\n';

    -- ⑦ 常去門市沒有變成虛擬門市
    v_msg := v_msg || case when public._member_home_store(m[1]) is not distinct from v_home then '✅' else '🔴' end
                   || ' ⑦ 常去門市沒有被好友練習賽改掉' || E'\n';

    -- ⑧ 不能按讚
    begin
      perform public.like_player_tx(org, m[1], m[2], true, sid);
      v_msg := v_msg || '🔴 ⑧ 好友練習賽竟然按得了讚' || E'\n';
    exception when others then
      v_msg := v_msg || case when sqlerrm like '%好友練習賽不做評價%' then '✅' else '🔴 ' || sqlerrm end || ' ⑧ 好友練習賽不能按讚' || E'\n';
    end;

    -- ⑨ 打完 15 分鐘 ⇒ 排程收場次
    update friendly_games set ended_at = now() - interval '20 minutes' where id = gid;
    perform public.sweep_friendly_tx();
    select count(*) into n from session_players where session_id = sid and left_at is not null and device_id is null;
    ok := (select status from table_sessions where id = sid) = 'completed' and n = 4;
    v_msg := v_msg || case when ok then '✅' else '🔴' end || ' ⑨ 打完 15 分鐘：場次收掉、四人離座、虛擬桌空出來' || E'\n';

    -- 第二場：湊滿之後
    perform set_config('request.jwt.claims', json_build_object('sub', l[1], 'role', 'authenticated')::text, true);
    r := public.create_friendly_game_tx(sk, now() + interval '2 hours');
    g2 := (r ->> 'game_id')::uuid; tok := r ->> 'token';
    for i in 2..4 loop
      perform set_config('request.jwt.claims', json_build_object('sub', l[i], 'role', 'authenticated')::text, true);
      perform public.join_friendly_game_tx(tok);
    end loop;
    select session_id into sid2 from friendly_games where id = g2;
    ok := (select table_id from table_sessions where id = sid2) = (select table_id from table_sessions where id = sid);
    v_msg := v_msg || case when ok then '✅' else '⚪' end || ' （第二場重用了同一張虛擬桌）' || E'\n';

    -- ⑩ 換人上桌：座位 4 換成第五個帳號 ⇒ 名單跟著換
    if m5 is null then
      v_msg := v_msg || '⚪ ⑩ 沒有第五個帳號，這一格測不了' || E'\n';
    else
      update session_players set member_id = m5 where session_id = sid2 and member_id = m[4];
      ok := exists (select 1 from friendly_game_players where game_id = g2 and member_id = m5 and left_at is null)
        and not exists (select 1 from friendly_game_players where game_id = g2 and member_id = m[4] and left_at is null);
      v_msg := v_msg || case when ok then '✅' else '🔴' end || ' ⑩ 換人上桌：好友練習賽名單跟著換' || E'\n';
    end if;

    -- ⑪ 開打 6 小時沒有任何一局 ⇒ 作廢、通知
    update friendly_games set started_at = now() - interval '7 hours' where id = g2;
    perform public.sweep_friendly_tx();
    ok := (select status = 'cancelled' and cancel_reason = 'stale' from friendly_games where id = g2)
      and (select status from table_sessions where id = sid2) = 'voided'
      and (select count(*) from app_notifications where ref_id = g2 and type = 'friendly_out') >= 3;
    v_msg := v_msg || case when ok then '✅' else '🔴' end || ' ⑪ 開打 6 小時沒記分：作廢、通知';

    raise exception 'migi_rollback';
  exception when others then
    if sqlerrm = 'migi_rollback' then
      perform set_config('migi.x', v_msg || E'\n（以上全部退回，資料庫沒有留下任何一筆）', true);
    else
      perform set_config('migi.x', v_msg || E'\n🔴 中途出錯：' || sqlerrm, true);
    end if;
  end;
end $$;
select coalesce(nullif(current_setting('migi.x', true), ''), '🔴 沒有訊息') as "好友練習賽結算與排除 · 行為測試";
