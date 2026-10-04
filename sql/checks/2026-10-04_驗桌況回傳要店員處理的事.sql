/* ============================================================
   驗桌況回傳「要店員處理的事」（行為測試，整段在交易裡跑完回滾，不留任何東西）· 2026-10-04
   配合 sql/applied/2026-10-04_桌況回傳要店員處理的事.sql（先跑那一份）

   在一張開著場次、四個人都有座位的桌上，**自己造**（不借線上現有的，硬規則 3.57）：
     一局等確認：要 2、3 號確認，2 號已按 ⇒ 該等的只有 3 號；送出時間設成 5 分鐘前
     一筆爆卡：4 號還沒決定
   ⓓ 造之前：pending_since 是 null、pending_waiting 是 []、bust_name 是 null —— 反向對照
   ⓐ pending_since ＝ 造的那個時間
   ⓑ pending_waiting ＝ 只有 3 號的名字（2 號按過了不可以列；1、4 號本來就不用確認）
   ⓕ 成績已經算完的場次：bust_name 是 null（跟平板同一個判斷 —— 算完就不再等決定）
   ⓒ 成績還沒算（交易裡暫時清掉名次）：bust_name ＝ 4 號的名字
   ⓔ 同一間店的空桌不受影響（四樣都是空的）
   📌 2026-10-04 線上只有一張桌是四人有座位（A1），而它已經打完、算過成績 ——
     所以取樣不限「正在打」，算過的就先驗 ⓕ、再暫時清掉名次驗 ⓒ（session_players 沒有觸發器，回滾就還原）。
   ⚠ 先造等確認、再造爆卡：觸發器會擋「已經有人爆卡待決定時再送新的一局」
   ⚠ 訊息一律寫在 exception 處理器裡（硬規則 3.9）；最後故意 raise 讓整段回滾（硬規則 1.8）
   ============================================================ */
do $$
declare
  v_msg text := ''; s record; v_round uuid; v_at timestamptz := now() - interval '5 minutes';
  v_n3 text; v_n4 text; v_x jsonb; v_before jsonb; v_idle jsonb; v_scored boolean;
begin
  -- 樣本：開著場次、4 個人都有座位、有一將可以掛（那一將沒有等確認）、這一場沒有爆卡待決定
  select ts.id, ts.org_id, t.store_id, t.id as table_id into s
    from table_sessions ts join tables t on t.id = ts.table_id
   where ts.status = 'open' and ts.deleted_at is null
     and (select count(distinct sp.seat) from session_players sp
           where sp.session_id = ts.id and sp.left_at is null and sp.seat between 1 and 4) = 4
     and exists (select 1 from session_rounds r where r.session_id = ts.id and r.status <> 'voided'
                    and not exists (select 1 from hands h where h.round_id = r.id and h.status = 'pending'))
     and not exists (select 1 from session_busts b where b.session_id = ts.id and b.decision = 'pending')
   limit 1;
  if s.id is null then
    v_msg := '⚪ 找不到「開著、四人有座位、有一將、沒有爆卡待決定」的場次，這份測不了';
    raise exception 'migi_rollback';
  end if;
  select r.id into v_round from session_rounds r
   where r.session_id = s.id and r.status <> 'voided'
     and not exists (select 1 from hands h where h.round_id = r.id and h.status = 'pending')
   order by r.round_no desc limit 1;
  select m.display_name into v_n3 from session_players sp join members m on m.id = sp.member_id
   where sp.session_id = s.id and sp.seat = 3 and sp.left_at is null;
  select m.display_name into v_n4 from session_players sp join members m on m.id = sp.member_id
   where sp.session_id = s.id and sp.seat = 4 and sp.left_at is null;
  v_scored := public._session_scored(s.id);

  -- ⓓ 造之前
  select x into v_before from jsonb_array_elements(public.list_tables_tx(s.org_id, s.store_id)) x
   where (x ->> 'id')::uuid = s.table_id;
  v_msg := case when v_before ->> 'pending_since' is null and jsonb_array_length(v_before -> 'pending_waiting') = 0
                 and v_before ->> 'bust_name' is null
            then '✅ ⓓ 造之前（' || (v_before ->> 'label') || '）：沒有等確認、沒有爆卡'
            else '🔴 ⓓ 造之前就有值：' || (v_before - 'queue_members')::text end;

  -- 造一局等確認 ＋ 一筆爆卡
  insert into hands (org_id, session_id, round_id, hand_no, wind, dealer_seat, result, winner_seat, deal_in_seat,
                     status, need_confirm, confirmed_seats, created_at)
  values (s.org_id, s.id, v_round, 99, 1, 1, 'ron', 1, 2, 'pending', '{2,3}', '{2}', v_at);
  insert into session_busts (org_id, session_id, seat, decision) values (s.org_id, s.id, 4, 'pending');

  select x into v_x from jsonb_array_elements(public.list_tables_tx(s.org_id, s.store_id)) x
   where (x ->> 'id')::uuid = s.table_id;
  v_msg := v_msg || E'\n' || case when (v_x ->> 'pending_since')::timestamptz = v_at
    then '✅ ⓐ pending_since ＝ 送出時間（5 分鐘前）' else '🔴 ⓐ pending_since ＝ ' || coalesce(v_x ->> 'pending_since', 'null') end;
  v_msg := v_msg || E'\n' || case when v_x -> 'pending_waiting' = jsonb_build_array(v_n3)
    then '✅ ⓑ pending_waiting 只有 3 號（' || v_n3 || '）—— 2 號按過了沒列、1／4 號不用確認'
    else '🔴 ⓑ pending_waiting ＝ ' || coalesce((v_x -> 'pending_waiting')::text, 'null') || '，應為 ["' || v_n3 || '"]' end;

  -- ⓕ 成績已算完 ⇒ 不再等爆卡決定；之後暫時清掉名次 ⇒ ⓒ
  if v_scored then
    v_msg := v_msg || E'\n' || case when v_x ->> 'bust_name' is null
      then '✅ ⓕ 成績已算完：bust_name 是 null（算完就不再等決定）' else '🔴 ⓕ 成績已算完卻還回 ' || (v_x ->> 'bust_name') end;
    update session_players set finish_rank = null where session_id = s.id;
    select x into v_x from jsonb_array_elements(public.list_tables_tx(s.org_id, s.store_id)) x
     where (x ->> 'id')::uuid = s.table_id;
  else
    v_msg := v_msg || E'\n⚪ ⓕ 樣本成績還沒算，這一格測不了（ⓒ 照樣驗）';
  end if;
  v_msg := v_msg || E'\n' || case when v_x ->> 'bust_name' = v_n4
    then '✅ ⓒ 成績還沒算：bust_name ＝ 4 號（' || v_n4 || '）' else '🔴 ⓒ bust_name ＝ ' || coalesce(v_x ->> 'bust_name', 'null') end;

  -- ⓔ 同一間店的一張空桌
  select x into v_idle from jsonb_array_elements(public.list_tables_tx(s.org_id, s.store_id)) x
   where x ->> 'session_id' is null limit 1;
  v_msg := v_msg || E'\n' || case
    when v_idle is null then '⚪ ⓔ 這間店沒有空桌，這一格測不了'
    when v_idle ->> 'pending_since' is null and jsonb_array_length(v_idle -> 'pending_waiting') = 0
         and v_idle ->> 'bust_name' is null and jsonb_array_length(v_idle -> 'device_seen') = 0
      then '✅ ⓔ 空桌（' || (v_idle ->> 'label') || '）四樣都是空的'
    else '🔴 ⓔ 空桌有值：' || v_idle::text end;

  raise exception 'migi_rollback';
exception when others then
  perform set_config('migi.alert_test', v_msg || case when sqlerrm = 'migi_rollback' then '' else E'\n🔴 中途出錯：' || sqlerrm end, true);
end $$;

select coalesce(nullif(current_setting('migi.alert_test', true), ''), '🔴 沒有測試訊息') as "桌況回傳要店員處理的事（已回滾）";
