-- 驗：線上好友房資料表的擋牆（2026-11-11）
-- 在 Supabase SQL Editor 跑（會寫入，所以不能走唯讀 MCP）；樣本全部自己造，最後整段回滾，一列都不會留下
-- 對象：sql/pending/2026-11-11_線上好友房_資料表.sql 跑完之後

do $$
declare
  v_org uuid; v_store uuid; v_tbl uuid; v_sid uuid; v_rid uuid; v_h uuid; v_h2 uuid;
  v_msg text := '';
begin
  select org_id, id into v_org, v_store from public.stores where is_virtual and deleted_at is null limit 1;
  if v_store is null then
    v_msg := '⚪ 找不到好友練習賽的虛擬門市，測不了';
    raise exception 'migi_rollback';
  end if;

  -- 自己造一張桌、一場、一將（硬規則 3.57：不借線上的資料）
  insert into public.tables (org_id, store_id, label, is_active, seats, sort_order, auto_assign, note)
  values (v_org, v_store, '驗證用 ' || gen_random_uuid()::text, false, 4, 9999, false, '驗證用，會回滾')
  returning id into v_tbl;
  insert into public.table_sessions (org_id, store_id, table_id, mode, status, planned_rounds, game_type, flower)
  values (v_org, v_store, v_tbl, 'friendly', 'open', 1, '台麻', '無花')
  returning id into v_sid;
  insert into public.session_rounds (org_id, session_id, round_no, first_dealer_seat, seat_ring)
  values (v_org, v_sid, 1, 2, '{2,3,4,1}')
  returning id into v_rid;

  -- ① 正對照：正常建一局（第一局帶定座位那一擲）
  begin
    insert into public.online_hands (org_id, session_id, round_id, hand_no, seed, dice, seat_dice, dealer_seat, state, phase)
    values (v_org, v_sid, v_rid, 1, 12345, '{3,3,3}', '{5,2,4}', 2, '{}', 'baozi')
    returning id into v_h;
    v_msg := v_msg || '✅ ① 正常建一局';
  exception when others then
    v_msg := v_msg || '🔴 ① 正常的一局建不起來：' || sqlerrm;
    raise exception 'migi_rollback';
  end;

  -- ② 骰子不合法要擋（0 點、只有兩顆）
  begin
    insert into public.online_hands (org_id, session_id, round_id, hand_no, seed, dice, dealer_seat, state, phase, status)
    values (v_org, v_sid, v_rid, 2, 1, '{0,1,2}', 2, '{}', 'discard', 'finished');
    v_msg := v_msg || E'\n🔴 ② 骰子 0 點竟然寫得進去';
  exception when check_violation then v_msg := v_msg || E'\n✅ ② 骰子 0 點擋下';
  end;
  begin
    insert into public.online_hands (org_id, session_id, round_id, hand_no, seed, dice, dealer_seat, state, phase, status)
    values (v_org, v_sid, v_rid, 2, 1, '{1,2}', 2, '{}', 'discard', 'finished');
    v_msg := v_msg || E'\n🔴 ③ 只有兩顆骰子竟然寫得進去';
  exception when check_violation then v_msg := v_msg || E'\n✅ ③ 只有兩顆骰子擋下';
  end;

  -- ④ 同一場第一局還在打，第二局建不起來
  begin
    insert into public.online_hands (org_id, session_id, round_id, hand_no, seed, dice, dealer_seat, state, phase)
    values (v_org, v_sid, v_rid, 2, 2, '{1,2,3}', 2, '{}', 'discard');
    v_msg := v_msg || E'\n🔴 ④ 同一場兩局同時在打';
  exception when unique_violation then v_msg := v_msg || E'\n✅ ④ 同一場只能一局在打';
  end;

  -- ⑤ 正對照：第一局打完，第二局就建得起來（不然 ④ 的綠燈可能只是什麼都擋）
  update public.online_hands set status = 'finished', ended_at = now() where id = v_h;
  begin
    insert into public.online_hands (org_id, session_id, round_id, hand_no, seed, dice, dealer_seat, state, phase)
    values (v_org, v_sid, v_rid, 2, 2, '{1,2,3}', 3, '{}', 'discard')
    returning id into v_h2;
    v_msg := v_msg || E'\n✅ ⑤ 上一局打完，下一局建得起來';
  exception when others then v_msg := v_msg || E'\n🔴 ⑤ 上一局打完了，下一局還是建不起來：' || sqlerrm;
  end;

  -- ⑥ 動作紀錄：寫得進去、改不了、刪不了、同一個版本號只能一筆
  insert into public.online_actions (org_id, online_hand_id, version, seat, actor, action)
  values (v_org, v_h, 1, 2, 'player', '{"t":"discard","tile":"3m"}');
  v_msg := v_msg || E'\n✅ ⑥ 動作紀錄寫得進去';
  begin
    update public.online_actions set action = '{}' where online_hand_id = v_h;
    v_msg := v_msg || E'\n🔴 ⑦ 動作紀錄竟然改得了';
  exception when others then
    v_msg := v_msg || case when sqlerrm like '%只能新增%' then E'\n✅ ⑦ 動作紀錄改不了'
                           else E'\n🔴 ⑦ 改動作紀錄失敗，但原因不對：' || sqlerrm end;
  end;
  begin
    delete from public.online_actions where online_hand_id = v_h;
    v_msg := v_msg || E'\n🔴 ⑧ 動作紀錄竟然刪得掉';
  exception when others then
    v_msg := v_msg || case when sqlerrm like '%只能新增%' then E'\n✅ ⑧ 動作紀錄刪不掉'
                           else E'\n🔴 ⑧ 刪動作紀錄失敗，但原因不對：' || sqlerrm end;
  end;
  begin
    insert into public.online_actions (org_id, online_hand_id, version, seat, actor, action)
    values (v_org, v_h, 1, 3, 'player', '{"t":"pon"}');
    v_msg := v_msg || E'\n🔴 ⑨ 同一個版本號寫了兩筆（兩支手機同時按會兩個都算）';
  exception when unique_violation then v_msg := v_msg || E'\n✅ ⑨ 同一個版本號只能一筆';
  end;
  begin
    insert into public.online_actions (org_id, online_hand_id, version, seat, actor, action)
    values (v_org, v_h, 2, 3, 'robot', '{}');
    v_msg := v_msg || E'\n🔴 ⑩ actor 寫了不認識的值';
  exception when check_violation then v_msg := v_msg || E'\n✅ ⑩ actor 只收 player／auto／system';
  end;

  -- ⑪ 在線狀態：同一場同一個座位只有一列
  insert into public.online_seats (session_id, seat, org_id, last_seen_at) values (v_sid, 2, v_org, now());
  begin
    insert into public.online_seats (session_id, seat, org_id, last_seen_at) values (v_sid, 2, v_org, now());
    v_msg := v_msg || E'\n🔴 ⑪ 同一個座位兩列';
  exception when unique_violation then v_msg := v_msg || E'\n✅ ⑪ 同一個座位只有一列';
  end;

  raise exception 'migi_rollback';
exception when others then
  -- 訊息設在這裡才留得住（硬規則 3.9）；上面寫的東西全部隨這個例外退掉
  perform set_config('migi.chk', v_msg ||
    case when sqlerrm = 'migi_rollback' then '' else E'\n🔴 意外錯誤：' || sqlerrm end, true);
end $$;

select coalesce(nullif(current_setting('migi.chk', true), ''), '🔴 沒有訊息') as "驗證（應該 11 格全綠）";
