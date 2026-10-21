-- ════════════════════════════════════════════════════════════════
-- 行為測試：店員取消配桌房（配合 sql/applied/2026-10-21_店員取消配桌房.sql）
-- 在交易裡自己造房、換成真的店員身分去叫，最後 raise 'migi_rollback' 整段回滾 ⇒ 一筆都不留。
-- ⚠ 要在 Supabase SQL Editor 跑（唯讀 MCP 不能切換角色）。
--   ⓐ 已湊滿的房（matched，2 人）取消 ⇒ 房 cancelled、2 人都標離開 cancelled ＋ 記店員、每人一則 App 通知、沒有任何 LINE 寄件
--   ⓑ 再取消一次 ⇒ 冪等，回 already
--   ⓒ 已帶到桌（seated）的房 ⇒ 擋下（seated），房不變
--   ⓓ 沒登入 ⇒ 被拒絕
-- ════════════════════════════════════════════════════════════════
do $$
declare
  v_msg text := '';
  v_staff record; v_a uuid; v_b uuid; v_store uuid; v_stake uuid;
  v_q uuid; v_q2 uuid; r jsonb; v_n int; v_m int; v_d int; v_st text;
  v_claims text;
begin
  select s.id, s.auth_uid, s.org_id into v_staff
    from staff s where s.deleted_at is null and s.auth_uid is not null order by s.created_at limit 1;
  select m.id into v_a from members m
   where m.org_id = v_staff.org_id and m.is_test and m.deleted_at is null and m.hidden_at is null order by m.created_at limit 1;
  select m.id into v_b from members m
   where m.org_id = v_staff.org_id and m.is_test and m.deleted_at is null and m.hidden_at is null and m.id <> v_a order by m.created_at limit 1;
  select id into v_store from stores where org_id = v_staff.org_id order by created_at limit 1;
  select id into v_stake from stake_levels where org_id = v_staff.org_id order by created_at limit 1;
  if v_staff.id is null or v_a is null or v_b is null or v_store is null then
    v_msg := '⚪ 找不到店員、兩位測試會員或門市，測不了';
    raise exception 'migi_rollback';
  end if;
  v_claims := json_build_object('sub', v_staff.auth_uid, 'role', 'authenticated')::text;

  -- 自己造兩間房：一間 matched（2 人）、一間 seated
  insert into match_queues (org_id, store_id, stake_level_id, game_type, flower, rounds, seats, play_at, expires_at, source, status)
  values (v_staff.org_id, v_store, v_stake, '台麻', '無花', 2, 2, now() + interval '3 hours', now() + interval '3 hours', 'pos', 'matched')
  returning id into v_q;
  insert into match_queue_players (org_id, queue_id, member_id, join_source) values
    (v_staff.org_id, v_q, v_a, 'pos_walkin'), (v_staff.org_id, v_q, v_b, 'pos_walkin');
  insert into match_queues (org_id, store_id, stake_level_id, game_type, flower, rounds, seats, play_at, expires_at, source, status)
  values (v_staff.org_id, v_store, v_stake, '台麻', '無花', 2, 2, now() + interval '3 hours', now() + interval '3 hours', 'pos', 'seated')
  returning id into v_q2;

  -- ⓐ 取消已湊滿的房
  perform set_config('request.jwt.claims', v_claims, true);
  set local role authenticated;
  r := public.pos_cancel_queue_tx(v_staff.org_id, v_q, '測試取消');
  reset role;
  select status into v_st from match_queues where id = v_q;
  select count(*) into v_n from match_queue_players
   where queue_id = v_q and left_at is not null and leave_reason = 'cancelled' and left_by_staff_id = v_staff.id;
  select count(*) into v_m from app_notifications where ref_id = v_q and type = 'table_expired' and payload->>'text' like '店家取消了%測試取消';
  select count(*) into v_d from notification_deliveries d join app_notifications n on n.id = d.notification_id where n.ref_id = v_q;
  v_msg := v_msg || case when (r->>'ok')::boolean and v_st = 'cancelled' and v_n = 2 and v_m = 2 and v_d = 0
                         then '✅ ⓐ 已湊滿的房取消：房 cancelled、2 人標離開並記店員、2 則 App 通知、0 則 LINE'
                         else '🔴 ⓐ 回傳 ' || r::text || '　房 ' || coalesce(v_st, '?') || '　標離開 ' || v_n || '　通知 ' || v_m || '　LINE ' || v_d end;

  -- ⓑ 再取消一次
  set local role authenticated;
  r := public.pos_cancel_queue_tx(v_staff.org_id, v_q, null);
  reset role;
  select count(*) into v_m from app_notifications where ref_id = v_q;
  v_msg := v_msg || E'\n' || case when r->>'already' = 'cancelled' and v_m = 2
                                  then '✅ ⓑ 再取消一次：冪等（回 already），沒有多發通知'
                                  else '🔴 ⓑ 回傳 ' || r::text || '　通知數 ' || v_m end;

  -- ⓒ 已帶到桌的房
  set local role authenticated;
  r := public.pos_cancel_queue_tx(v_staff.org_id, v_q2, null);
  reset role;
  select status into v_st from match_queues where id = v_q2;
  v_msg := v_msg || E'\n' || case when r->>'reason' = 'seated' and v_st = 'seated'
                                  then '✅ ⓒ 已帶到桌的房被擋下（seated），房沒動'
                                  else '🔴 ⓒ 回傳 ' || r::text || '　房 ' || coalesce(v_st, '?') end;

  -- ⓓ 沒登入
  perform set_config('request.jwt.claims', '{"role":"anon"}', true);
  begin
    set local role anon;
    r := public.pos_cancel_queue_tx(v_staff.org_id, v_q2, null);
    reset role;
    v_msg := v_msg || E'\n🔴 ⓓ 沒登入也叫得動：' || r::text;
  exception when others then
    v_msg := v_msg || E'\n✅ ⓓ 沒登入被拒絕（' || sqlstate || '）';
  end;

  raise exception 'migi_rollback';
exception when others then
  perform set_config('migi.t',
    case when sqlerrm = 'migi_rollback' then v_msg
         else coalesce(nullif(v_msg, ''), '') || E'\n🔴 中途出錯：' || sqlerrm end, true);
end $$;
select coalesce(nullif(current_setting('migi.t', true), ''), '🔴 沒有訊息') as "行為測試";
