-- ============================================================
-- 2026-10-28 行為測試：好友練習賽地基（sql/pending/2026-10-28_好友練習賽_地基.sql 跑完之後）
-- 用四個測試帳號的真實身分（request.jwt.claims 的 sub ＝ 他的 LINE id）走一遍，最後整段退回、一筆都不留
--   ⓪ 先把四個人身上的配桌、正在打的場次、彼此的封鎖在交易裡清掉（每一格自己重建前提，硬規則 3.57）
--   ① 過了最晚開打時間沒湊滿 ⇒ 排程取消、通知
--   ② 開一場 ③ 同時開第二場被擋 ④ 點自己的連結 ⑤ 第二位加入
--   ⑥ 在好友練習賽裡報名配桌被擋 ⑦ 離開再回來
--   ⑧ 在配桌裡的人點連結 ⇒ 加入不了（in_match）
--   ⑨ 湊滿四人 ⇒ 開打：虛擬門市、虛擬桌、場次模式、四列玩家、座位空著
--   ⑩ 成桌通知四則、而且一則都沒有排進 LINE 推播
--   ⑪ 手機找得到這一場（同 _tbl_device 的查法）⑫ 第五位 ⇒ 已經滿了 ⑬ 開打後不能取消 ⑭ 沒登入
-- 跑法：Supabase SQL Editor 整份執行，看最後那一格
-- ============================================================
do $$
declare
  v_msg text := '';
  org uuid; st uuid; sk uuid; vstore uuid;
  m uuid[]; l text[]; m5 uuid; l5 text;
  r jsonb; tok text; gid uuid; g2 uuid; sid uuid; n int; ok boolean; t text;
  qid uuid;
begin
  -- 四個測試帳號（有 LINE id、沒隱藏）＋ 第五個（有的話）
  select array_agg(id order by created_at), array_agg(line_user_id order by created_at), min(org_id::text)::uuid
    into m, l, org
    from (select id, line_user_id, org_id, created_at from members
           where is_test and deleted_at is null and hidden_at is null and line_user_id is not null
           order by created_at limit 4) x;
  if coalesce(array_length(m, 1), 0) < 4 then
    perform set_config('migi.x', '⚪ 有 LINE id 的測試帳號不到 4 個，測不了', true); return;
  end if;
  select id, line_user_id into m5, l5 from members
   where deleted_at is null and hidden_at is null and line_user_id is not null and org_id = org and not (id = any(m))
   order by is_test desc, created_at limit 1;
  select id into sk from stake_levels where org_id = org and label = '50/20' and is_active and deleted_at is null;
  select id into vstore from stores where org_id = org and is_virtual;
  select s.id into st from stores s where s.org_id = org and not s.is_virtual and s.is_active and s.deleted_at is null
     and exists (select 1 from tables t where t.store_id = s.id) order by s.code limit 1;

  begin
    -- ⓪ 前提：四個人（＋第五個）身上沒有配桌、沒有正在打的場次、彼此沒有封鎖
    update match_queue_players set left_at = now(), leave_reason = 'quit'
     where member_id = any(m || m5) and left_at is null;
    update session_players sp set left_at = now()
      from table_sessions ts where ts.id = sp.session_id and ts.status = 'open'
       and sp.member_id = any(m || m5) and sp.left_at is null;
    delete from member_blocks where blocker_id = any(m || m5) and blocked_id = any(m || m5);

    -- ① 測試04 開一場，把最晚開打時間改到過去，排程取消
    perform set_config('request.jwt.claims', json_build_object('sub', l[4], 'role', 'authenticated')::text, true);
    g2 := (public.create_friendly_game_tx(sk, now() + interval '1 hour') ->> 'game_id')::uuid;
    update friendly_games set play_at = now() - interval '1 minute' where id = g2;
    perform public.sweep_friendly_tx();
    select status = 'cancelled' and cancel_reason = 'expired' into ok from friendly_games where id = g2;
    v_msg := v_msg || case when ok and public._friendly_active_game(m[4]) is null
                             and exists (select 1 from app_notifications where member_id = m[4] and type = 'friendly_out' and ref_id = g2)
                      then '✅' else '🔴' end || ' ① 過了最晚開打時間沒湊滿：排程取消、通知、人放出來' || E'\n';

    -- ② 測試01 開一場
    perform set_config('request.jwt.claims', json_build_object('sub', l[1], 'role', 'authenticated')::text, true);
    r := public.create_friendly_game_tx(sk, now() + interval '3 hours', '台麻', '有花', '2 將', '{}'::jsonb);
    gid := (r ->> 'game_id')::uuid; tok := r ->> 'token';
    v_msg := v_msg || case when (r ->> 'ok')::boolean and tok ~ '^[0-9a-f]{32}$'
                             and (select status = 'waiting' and rounds = 2 and flower = '有花' from friendly_games where id = gid)
                             and (select count(*) from friendly_game_players where game_id = gid and left_at is null) = 1
                      then '✅' else '🔴 ' || r::text end || ' ② 開一場：等朋友、2 將有花、只有自己' || E'\n';

    -- ③ 同時開第二場
    begin
      perform public.create_friendly_game_tx(sk, now() + interval '3 hours');
      v_msg := v_msg || '🔴 ③ 同時開第二場竟然成功' || E'\n';
    exception when others then
      v_msg := v_msg || case when sqlerrm like '%同時只能參加一場%' then '✅' else '🔴 ' || sqlerrm end || ' ③ 同時開第二場被擋' || E'\n';
    end;

    -- ④ 點自己的連結
    r := public.join_friendly_game_tx(tok);
    v_msg := v_msg || case when (r ->> 'already')::boolean then '✅' else '🔴 ' || r::text end || ' ④ 點自己的連結：直接回去、不重複加' || E'\n';

    -- ⑤ 測試02 加入
    perform set_config('request.jwt.claims', json_build_object('sub', l[2], 'role', 'authenticated')::text, true);
    r := public.join_friendly_game_tx(tok);
    v_msg := v_msg || case when (r ->> 'ok')::boolean and not (r ->> 'started')::boolean
                             and r -> 'host' ->> 'member_id' = m[1]::text
                      then '✅' else '🔴 ' || r::text end || ' ⑤ 第二位加入（回傳開局的人是誰）' || E'\n';

    -- ⑥ 在好友練習賽裡報名配桌 ⇒ 擋
    if st is null then
      v_msg := v_msg || '⚪ ⑥ 找不到有桌的門市，這一格測不了' || E'\n';
    else
      begin
        perform public.create_match_queue_tx(org, m[2], st, sk, now() + interval '1 day');
        v_msg := v_msg || '🔴 ⑥ 在好友練習賽裡竟然開得了配桌' || E'\n';
      exception when others then
        v_msg := v_msg || case when sqlerrm like '%好友練習賽%' then '✅' else '🔴 ' || sqlerrm end || ' ⑥ 在好友練習賽裡開配桌被擋' || E'\n';
      end;
    end if;

    -- ⑦ 離開再回來
    perform public.leave_friendly_game_tx(gid);
    ok := public._friendly_active_game(m[2]) is null;
    r := public.join_friendly_game_tx(tok);
    v_msg := v_msg || case when ok and (r ->> 'ok')::boolean then '✅' else '🔴 ' || r::text end || ' ⑦ 離開之後可以再加入' || E'\n';

    -- ⑧ 測試03 先開一個配桌，再點連結 ⇒ in_match；退掉配桌
    perform set_config('request.jwt.claims', json_build_object('sub', l[3], 'role', 'authenticated')::text, true);
    if st is null then
      v_msg := v_msg || '⚪ ⑧ 找不到有桌的門市，這一格測不了' || E'\n';
    else
      qid := public.create_match_queue_tx(org, m[3], st, sk, now() + interval '1 day');
      r := public.join_friendly_game_tx(tok);
      v_msg := v_msg || case when r ->> 'reason' = 'in_match' then '✅' else '🔴 ' || r::text end || ' ⑧ 在配桌裡點連結：加入不了（in_match）' || E'\n';
      update match_queue_players set left_at = now(), leave_reason = 'quit' where queue_id = qid and left_at is null;
    end if;

    -- ⑨ 測試03、04 加入 ⇒ 湊滿開打
    r := public.join_friendly_game_tx(tok);
    perform set_config('request.jwt.claims', json_build_object('sub', l[4], 'role', 'authenticated')::text, true);
    r := public.join_friendly_game_tx(tok);
    select session_id into sid from friendly_games where id = gid;
    select ts.mode = 'friendly' and ts.store_id = vstore and ts.status = 'open' and ts.planned_rounds = 2
           and ts.flower = '有花' and ts.stake_level_id = sk
           and (select t2.store_id = vstore and t2.label like 'F%' from tables t2 where t2.id = ts.table_id)
      into ok from table_sessions ts where ts.id = sid;
    select count(*) into n from session_players where session_id = sid and seat is null and member_id = any(m) and left_at is null;
    v_msg := v_msg || case when (r ->> 'started')::boolean and coalesce(ok, false) and n = 4
                             and (select status from friendly_games where id = gid) = 'playing'
                      then '✅' else '🔴 ' || r::text || ' 玩家 ' || n end
                   || ' ⑨ 湊滿四人開打：虛擬門市的虛擬桌、模式 friendly、四人座位空著' || E'\n';

    -- ⑩ 成桌通知四則、沒有任何一則排進 LINE 推播
    select count(*) into n from app_notifications where ref_id = gid and type = 'friendly_ok';
    select not exists (select 1 from notification_deliveries d
                         join app_notifications a on a.id = d.notification_id
                        where a.ref_id = gid) into ok;
    v_msg := v_msg || case when n = 4 and ok then '✅' else '🔴' end || format(' ⑩ 成桌通知 %s 則、LINE 推播 %s', n, case when ok then '0 則' else '有排進去' end) || E'\n';

    -- ⑪ 手機找得到這一場（_tbl_device 對手機的查法：這個人坐在哪一場開著的場次）
    select ts.id = sid into ok
      from session_players sp join table_sessions ts on ts.id = sp.session_id
     where sp.member_id = m[3] and sp.left_at is null and ts.status = 'open' and ts.deleted_at is null
     order by ts.created_at desc limit 1;
    v_msg := v_msg || case when coalesce(ok, false) then '✅' else '🔴' end || ' ⑪ 手機用「這個人坐在哪一場」找得到這一場' || E'\n';

    -- ⑫ 第五位 ⇒ 已經滿了
    if m5 is null then
      v_msg := v_msg || '⚪ ⑫ 沒有第五個帳號，這一格測不了' || E'\n';
    else
      perform set_config('request.jwt.claims', json_build_object('sub', l5, 'role', 'authenticated')::text, true);
      r := public.join_friendly_game_tx(tok);
      v_msg := v_msg || case when r ->> 'reason' = 'full' then '✅' else '🔴 ' || r::text end || ' ⑫ 開打後別人再點連結：已經滿了' || E'\n';
    end if;

    -- ⑬ 開打後開局的人不能取消
    perform set_config('request.jwt.claims', json_build_object('sub', l[1], 'role', 'authenticated')::text, true);
    begin
      perform public.cancel_friendly_game_tx(gid);
      v_msg := v_msg || '🔴 ⑬ 開打後竟然取消得了' || E'\n';
    exception when others then
      v_msg := v_msg || case when sqlerrm like '%已經開打%' then '✅' else '🔴 ' || sqlerrm end || ' ⑬ 開打後不能取消' || E'\n';
    end;

    -- ⑭ 我的好友練習賽（開局的人看到的樣子）
    r := public.get_my_friendly_tx() -> 'game';
    v_msg := v_msg || case when r ->> 'status' = 'playing' and (r ->> 'player_count')::int = 4
                             and (r ->> 'is_host')::boolean and r ->> 'stake_label' = '50/20'
                             and jsonb_array_length(r -> 'players') = 4
                      then '✅' else '🔴 ' || coalesce(r::text, 'null') end || ' ⑭ 我的好友練習賽：在打、四人、我是開局的人' || E'\n';

    -- ⑮ 沒登入
    perform set_config('request.jwt.claims', '{}', true);
    r := public.join_friendly_game_tx(tok);
    v_msg := v_msg || case when r ->> 'reason' = 'not_logged_in' then '✅' else '🔴 ' || r::text end || ' ⑮ 沒登入叫不動';

    raise exception 'migi_rollback';
  exception when others then
    if sqlerrm = 'migi_rollback' then
      perform set_config('migi.x', v_msg || E'\n（以上全部退回，資料庫沒有留下任何一筆）', true);
    else
      perform set_config('migi.x', v_msg || E'\n🔴 中途出錯：' || sqlerrm, true);
    end if;
  end;
end $$;
select coalesce(nullif(current_setting('migi.x', true), ''), '🔴 沒有訊息') as "好友練習賽地基 · 行為測試";
