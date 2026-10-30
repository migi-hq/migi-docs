-- ============================================================
-- 2026-10-30 行為測試：配桌揪桌（send／respond_table_invite_tx）＋ 配桌邀請連結（create／redeem_queue_invite_*）
-- 用測試帳號的真實身分（request.jwt.claims 的 sub ＝ 他的 LINE id）走一遍，最後整段退回、一筆都不留
--   測試02 開兩房（A、B，在 200 天後，不會跟任何真的牌局撞時間）；測試02、03 是牌咖，測試04 不是
--   揪桌：發 → 重發不重複 → 邀非牌咖擋 → 不在房裡的人發擋 → 03 拒絕 B 房 → 03 接受 A 房
--   連結：02 拿連結 → 再拿同一條 → 04 點了報名 → 04 再點不重複 → 房取消後點擋 → 取消的房拿連結擋 → 沒登入
-- 跑法：Supabase SQL Editor 整份執行，看最後那一格
-- ============================================================
do $$
declare
  v_msg text := '';
  m2 uuid; m3 uuid; m4 uuid; l2 text; l3 text; l4 text; org uuid;
  v_store uuid; v_stake uuid; qa uuid; qb uuid;
  r jsonb; tok text; tok2 text; n int; s text; v_err text;
  claims2 text; claims3 text; claims4 text;
begin
  select id, line_user_id, org_id into m2, l2, org from members where display_name = '測試02' and is_test and deleted_at is null;
  select id, line_user_id into m3, l3 from members where display_name = '測試03' and is_test and deleted_at is null;
  select id, line_user_id into m4, l4 from members where display_name = '測試04' and is_test and deleted_at is null;
  if m2 is null or m3 is null or m4 is null or l2 is null or l3 is null or l4 is null then
    perform set_config('migi.x', '⚪ 找不到測試02／03／04 或他們沒有 LINE id，測不了', true); return;
  end if;
  claims2 := json_build_object('sub', l2, 'role', 'authenticated')::text;
  claims3 := json_build_object('sub', l3, 'role', 'authenticated')::text;
  claims4 := json_build_object('sub', l4, 'role', 'authenticated')::text;
  select id into v_store from stores where org_id = org and deleted_at is null and not is_virtual order by created_at limit 1;
  select id into v_stake from stake_levels where org_id = org and deleted_at is null order by created_at limit 1;
  if v_store is null or v_stake is null then
    perform set_config('migi.x', '⚪ 找不到門市或積分級距，測不了', true); return;
  end if;

  begin
    -- 樣本：測試02 開 A、B 兩房（直接寫，不走開房函式 —— 那會擋同一人兩房）；02 與 03 互為牌咖、04 不是
    insert into match_queues (org_id, store_id, stake_level_id, play_at, opened_by, expires_at)
    values (org, v_store, v_stake, now() + interval '200 days', m2, now() + interval '200 days') returning id into qa;
    insert into match_queues (org_id, store_id, stake_level_id, play_at, opened_by, expires_at)
    values (org, v_store, v_stake, now() + interval '210 days', m2, now() + interval '210 days') returning id into qb;
    insert into match_queue_players (org_id, queue_id, member_id, join_source) values (org, qa, m2, 'open'), (org, qb, m2, 'open');
    -- 舊的那一列可能是刪除狀態（唯一索引不一定排除已刪除的）⇒ 先救回來，沒有才新增
    update mahjong_buddies set deleted_at = null
     where (member_id = m2 and buddy_id = m3) or (member_id = m3 and buddy_id = m2);
    insert into mahjong_buddies (org_id, member_id, buddy_id, origin)
    select org, m2, m3, 'pre_existing' where not exists (select 1 from mahjong_buddies where member_id = m2 and buddy_id = m3);
    insert into mahjong_buddies (org_id, member_id, buddy_id, origin)
    select org, m3, m2, 'pre_existing' where not exists (select 1 from mahjong_buddies where member_id = m3 and buddy_id = m2);
    update mahjong_buddies set deleted_at = now()
     where deleted_at is null and ((member_id = m2 and buddy_id = m4) or (member_id = m4 and buddy_id = m2));
    delete from member_blocks where (blocker_id in (m2, m3, m4) and blocked_id in (m2, m3, m4));
    -- 這兩房是新的 ⇒ 不會有舊通知；但 03／04 身上可能有別的房，先讓他們離開（交易內，最後退回）
    update match_queue_players set left_at = now() where member_id in (m3, m4) and left_at is null;

    -- ① 02 揪 03 進 A 房：03 收到一則待處理
    perform set_config('request.jwt.claims', claims2, true);
    perform public.send_table_invite_tx(org, null, m3, qa);
    perform set_config('request.jwt.claims', claims3, true);
    select x ->> 'invite_status' into s from jsonb_array_elements(public.list_notifications_tx(org, null)) x
     where x ->> 'type' = 'table_req' and x ->> 'ref_id' = qa::text;
    v_msg := v_msg || case when s = 'pending' then '✅' else '🔴 ' || coalesce(s, 'null') end || ' ① 揪桌送出，對方看到待處理' || E'\n';

    -- ② 再揪一次：還是一則
    perform set_config('request.jwt.claims', claims2, true);
    perform public.send_table_invite_tx(org, null, m3, qa);
    select count(*) into n from app_notifications where member_id = m3 and type = 'table_req' and ref_id = qa;
    v_msg := v_msg || case when n = 1 then '✅' else '🔴 ' || n || ' 則' end || ' ② 同一房同一人只發一則' || E'\n';

    -- ③ 揪不是牌咖的 04：擋
    v_err := null;
    begin perform public.send_table_invite_tx(org, null, m4, qa); exception when others then v_err := sqlerrm; end;
    v_msg := v_msg || case when v_err = '只能邀請你的牌咖' then '✅' else '🔴 ' || coalesce(v_err, '沒擋') end || ' ③ 不是牌咖不能揪' || E'\n';

    -- ④ 不在房裡的 03 想揪 02 進 A 房：擋（03 還沒接受）
    perform set_config('request.jwt.claims', claims3, true);
    v_err := null;
    begin perform public.send_table_invite_tx(org, null, m2, qa); exception when others then v_err := sqlerrm; end;
    v_msg := v_msg || case when v_err like '你不在這一房裡%' then '✅' else '🔴 ' || coalesce(v_err, '沒擋') end || ' ④ 不在房裡的人不能揪' || E'\n';

    -- ⑤ 02 揪 03 進 B 房，03 拒絕：記 done_at、看到已拒絕、沒有進 B 房
    perform set_config('request.jwt.claims', claims2, true);
    perform public.send_table_invite_tx(org, null, m3, qb);
    perform set_config('request.jwt.claims', claims3, true);
    s := public.respond_table_invite_tx(org, null, qb, false);
    select x ->> 'invite_status' into tok2 from jsonb_array_elements(public.list_notifications_tx(org, null)) x
     where x ->> 'type' = 'table_req' and x ->> 'ref_id' = qb::text;
    v_msg := v_msg || case when s = 'rejected' and tok2 = 'rejected'
                             and not exists (select 1 from match_queue_players where queue_id = qb and member_id = m3)
                      then '✅' else '🔴 ' || s || ' / ' || coalesce(tok2, 'null') end || ' ⑤ 拒絕：看到已拒絕、沒進房' || E'\n';

    -- ⑥ 03 接受 A 房：報名（來源 invite、invited_by ＝ 02）、看到已接受
    s := public.respond_table_invite_tx(org, null, qa, true);
    select x ->> 'invite_status' into tok2 from jsonb_array_elements(public.list_notifications_tx(org, null)) x
     where x ->> 'type' = 'table_req' and x ->> 'ref_id' = qa::text;
    v_msg := v_msg || case when s = 'waiting' and tok2 = 'accepted'
                             and exists (select 1 from match_queue_players where queue_id = qa and member_id = m3 and left_at is null
                                          and join_source = 'invite' and invited_by = m2)
                      then '✅' else '🔴 ' || s || ' / ' || coalesce(tok2, 'null') end || ' ⑥ 接受：報名、記是誰揪的、看到已接受' || E'\n';

    -- ⑦ 沒被揪過的房按接受：擋
    perform set_config('request.jwt.claims', claims4, true);
    v_err := null;
    begin s := public.respond_table_invite_tx(org, null, qa, true); exception when others then v_err := sqlerrm; end;
    v_msg := v_msg || case when v_err = '找不到這則邀請' then '✅' else '🔴 ' || coalesce(v_err, '沒擋') end || ' ⑦ 沒被揪不能用接受報名' || E'\n';

    -- ⑧ 02 拿 A 房連結；再拿一次是同一條
    perform set_config('request.jwt.claims', claims2, true);
    r := public.create_queue_invite_link_tx(qa); tok := r ->> 'token';
    tok2 := public.create_queue_invite_link_tx(qa) ->> 'token';
    v_msg := v_msg || case when (r ->> 'ok')::boolean and tok ~ '^[0-9a-f]{32}$' and tok2 = tok and r ->> 'store_name' is not null
                      then '✅' else '🔴 ' || r::text end || ' ⑧ 拿連結；同一人同一房是同一條；帶門市名' || E'\n';

    -- ⑨ 04（不是牌咖）點連結：報名（來源 link、invited_by ＝ 02）
    perform set_config('request.jwt.claims', claims4, true);
    r := public.redeem_queue_invite_tx(tok);
    v_msg := v_msg || case when (r ->> 'joined')::boolean
                             and exists (select 1 from match_queue_players where queue_id = qa and member_id = m4 and left_at is null
                                          and join_source = 'link' and invited_by = m2)
                      then '✅' else '🔴 ' || r::text end || ' ⑨ 點連結就報名、記是誰的連結' || E'\n';

    -- ⑩ 04 再點：不重複報名
    r := public.redeem_queue_invite_tx(tok);
    select count(*) into n from match_queue_players where queue_id = qa and member_id = m4 and left_at is null;
    v_msg := v_msg || case when (r ->> 'already')::boolean and n = 1 then '✅' else '🔴 ' || r::text end || ' ⑩ 已經在房裡再點：不重複' || E'\n';

    -- ⑪ 02 拿 B 房連結 → B 房取消 → 04 點：擋；02 再拿 B 房連結：擋
    perform set_config('request.jwt.claims', claims2, true);
    tok2 := public.create_queue_invite_link_tx(qb) ->> 'token';
    update match_queues set status = 'cancelled' where id = qb;
    perform set_config('request.jwt.claims', claims4, true);
    r := public.redeem_queue_invite_tx(tok2);
    v_msg := v_msg || case when r ->> 'reason' = 'closed'
                             and not exists (select 1 from match_queue_players where queue_id = qb and member_id = m4)
                      then '✅' else '🔴 ' || r::text end || ' ⑪ 房取消了點連結：擋、說明原因' || E'\n';
    perform set_config('request.jwt.claims', claims2, true);
    r := public.create_queue_invite_link_tx(qb);
    v_msg := v_msg || case when r ->> 'reason' = 'closed' then '✅' else '🔴 ' || r::text end || ' ⑫ 取消的房拿不到連結' || E'\n';

    -- ⑬ 04 已經在 A 房，又用另一條連結想進另一房：被「同時只能一場」擋，原話回來不是系統錯誤
    update match_queues set status = 'waiting' where id = qb;
    tok2 := public.create_queue_invite_link_tx(qb) ->> 'token';
    perform set_config('request.jwt.claims', claims4, true);
    r := public.redeem_queue_invite_tx(tok2);
    v_msg := v_msg || case when r ->> 'reason' = 'cannot_join' and r ->> 'message' like '%同時只能參加一場%' then '✅' else '🔴 ' || r::text end
                   || ' ⑬ 已經在別房：報名擋牆的原話回來（正對照：⑨ 同一支是會通的）' || E'\n';

    -- ⑭ 沒登入
    perform set_config('request.jwt.claims', '{}', true);
    r := public.redeem_queue_invite_tx(tok);
    v_msg := v_msg || case when r ->> 'reason' = 'not_logged_in' then '✅' else '🔴 ' || r::text end || ' ⑭ 沒登入叫不動';
    raise exception 'migi_rollback';
  exception when others then
    if sqlerrm = 'migi_rollback' then
      perform set_config('migi.x', v_msg || E'\n（以上全部退回，資料庫沒有留下任何一筆）', true);
    else
      perform set_config('migi.x', v_msg || E'\n🔴 中途出錯：' || sqlerrm, true);
    end if;
  end;
end $$;
select coalesce(nullif(current_setting('migi.x', true), ''), '🔴 沒有訊息') as "配桌揪桌與邀請連結 · 行為測試";
