-- ============================================================================
-- 2026-10-13 行為測試：手機計分（配對碼、手機選人、每人一台、斷線接手、平板發碼、只限這一場）
-- 整段在交易裡自己造樣本（一張空桌、一場牌局、一台測試平板、兩位測試會員），
-- 最後 raise 'migi_rollback' 全部退掉 —— 一筆都不會留下（硬規則 1：這一份是故意不提交的那一種）。
-- 結果由 exception 處理器裡的 set_config 帶出來（硬規則 3.9），最後一支 SELECT 讀。
-- ============================================================================
do $$
declare
  v_msg text := '';
  v_org uuid; v_store uuid; v_table uuid; v_a uuid; v_b uuid; v_sess uuid; v_pa uuid; v_pb uuid;
  v_tab_token text := repeat('ab', 32); v_tab uuid;
  v_code text; v_code2 text; r jsonb; v_phone text; v_phone2 text; v_n int; v_ok boolean;
  ck text;  -- 每一格的結果
begin
  -- 樣本：測試會員兩位、一張現在沒有牌局的桌
  select id, org_id into v_a, v_org from members where is_test and deleted_at is null and hidden_at is null order by created_at limit 1;
  select id into v_b from members where is_test and deleted_at is null and hidden_at is null and id <> v_a order by created_at limit 1;
  select t.id, t.store_id into v_table, v_store from tables t
   where t.org_id = v_org and t.deleted_at is null
     and not exists (select 1 from table_sessions s where s.table_id = t.id and s.status = 'open' and s.deleted_at is null)
   order by t.label limit 1;
  if v_a is null or v_b is null or v_table is null then
    raise exception '🔴 找不到樣本（要兩位測試會員、一張沒有牌局的桌）';   -- 找不到要出聲（硬規則 3.57）
  end if;
  -- 這兩位現在不能在任何一場牌局裡（不然手機會被帶到那一場）
  if exists (select 1 from session_players sp join table_sessions s on s.id = sp.session_id
              where sp.member_id in (v_a, v_b) and sp.left_at is null and s.status = 'open' and s.deleted_at is null) then
    raise exception '🔴 樣本會員現在有牌局，換一天再跑';
  end if;

  insert into table_devices (org_id, store_id, table_id, label, token_hash, last_seen_at)
  values (v_org, v_store, v_table, '測試平板', public._tbl_hash(v_tab_token), now()) returning id into v_tab;

  -- ① 配對碼：格式不對、碼不對、對的、同一組再用一次
  v_code := public._tbl_new_phone_code(v_org, v_a, null, null, null, now() + interval '1 hour');
  r := public.tbl_phone_redeem_tx('12345');
  ck := case when r->>'reason' = 'bad_code' then '✅' else '🔴 ' || r::text end;
  v_msg := v_msg || E'\n① 5 位數 → 擋下 ' || ck;
  r := public.tbl_phone_redeem_tx(case when v_code = '000000' then '000001' else '000000' end);
  ck := case when r->>'reason' = 'bad_code' then '✅' else '🔴 ' || r::text end;
  v_msg := v_msg || E'\n① 不存在的碼 → 擋下 ' || ck;
  r := public.tbl_phone_redeem_tx(v_code);
  v_phone := r->>'token';
  ck := case when (r->>'ok')::boolean and v_phone is not null and not (r->>'this_game_only')::boolean
              and exists (select 1 from table_devices where token_hash = public._tbl_hash(v_phone) and kind = 'phone' and member_id = v_a and bound_session_id is null)
             then '✅' else '🔴 ' || r::text end;
  v_msg := v_msg || E'\n① 對的碼 → 手機配好、記住是誰的（正對照） ' || ck;
  r := public.tbl_phone_redeem_tx(v_code);
  ck := case when r->>'reason' = 'bad_code' then '✅' else '🔴 ' || r::text end;
  v_msg := v_msg || E'\n① 同一組再用一次 → 擋下 ' || ck;

  -- ② 還沒入座：手機狀態是「沒有牌局」，認得出是手機、是誰的
  r := public.tbl_state_tx(v_phone);
  ck := case when r->'session' = 'null'::jsonb and r->'device'->>'kind' = 'phone' and r->'device'->>'owner' is not null
             then '✅' else '🔴 ' || left(r::text, 200) end;
  v_msg := v_msg || E'\n② 沒入座 → 沒有牌局、kind=phone、有主人名字 ' || ck;

  -- ③ 開一場，兩位入座 ⇒ 手機自動找到這一桌
  insert into table_sessions (org_id, store_id, table_id, mode, status, is_test)
  values (v_org, v_store, v_table, 'private', 'open', true) returning id into v_sess;
  insert into session_players (org_id, session_id, member_id, join_type, status, seat)
  values (v_org, v_sess, v_a, 'opener', 'playing', 1) returning id into v_pa;
  insert into session_players (org_id, session_id, member_id, join_type, status, seat)
  values (v_org, v_sess, v_b, 'opener', 'playing', 2) returning id into v_pb;
  r := public.tbl_state_tx(v_phone);
  ck := case when r->'session' <> 'null'::jsonb
              and exists (select 1 from jsonb_array_elements(r->'players') p where (p->>'player_id')::uuid = v_pa and (p->>'is_mine')::boolean)
             then '✅' else '🔴 ' || left(r::text, 200) end;
  v_msg := v_msg || E'\n③ 入座之後 → 手機找到這一桌、認得自己那一格 ' || ck;

  -- ④ 手機只能選自己
  r := public.tbl_claim_seat_tx(v_phone, v_pb);
  ck := case when r->>'reason' = 'not_yours' then '✅' else '🔴 ' || r::text end;
  v_msg := v_msg || E'\n④ 手機選別人 → 擋下 ' || ck;

  -- ⑤ 每人一台：平板先選了 A，手機選 A 被擋（平板沒斷線）
  r := public.tbl_claim_seat_tx(v_tab_token, v_pa);
  ck := case when (r->>'ok')::boolean then '✅' else '🔴 ' || r::text end;
  v_msg := v_msg || E'\n⑤ 平板選 A → 成功（正對照） ' || ck;
  r := public.tbl_claim_seat_tx(v_phone, v_pa);
  ck := case when r->>'reason' = 'taken' then '✅' else '🔴 ' || r::text end;
  v_msg := v_msg || E'\n⑤ 平板還在線，手機選 A → 擋下 ' || ck;

  -- ⑥ 平板斷線（最後上線 1 分鐘前）⇒ 手機可以接手
  update table_devices set last_seen_at = now() - interval '1 minute' where id = v_tab;
  r := public.tbl_state_tx(v_phone);
  ck := case when exists (select 1 from jsonb_array_elements(r->'players') p
                           where (p->>'player_id')::uuid = v_pa and (p->>'stale')::boolean and p->>'device_label' = '測試平板')
             then '✅' else '🔴 ' || left(r::text, 200) end;
  v_msg := v_msg || E'\n⑥ 狀態看得出 A 的平板斷線了 ' || ck;
  r := public.tbl_claim_seat_tx(v_phone, v_pa);
  ck := case when (r->>'ok')::boolean and (r->>'took_over')::boolean
              and (select device_id from session_players where id = v_pa) = (select id from table_devices where token_hash = public._tbl_hash(v_phone))
             then '✅' else '🔴 ' || r::text end;
  v_msg := v_msg || E'\n⑥ 手機接手 A ' || ck;

  -- ⑦ 平板「改用手機計分」：沒有位置時擋下；選了 B 之後發碼 ⇒ 兌換的那一刻 B 的位置交給新手機、只限這一場
  update table_devices set last_seen_at = now() where id = v_tab;
  r := public.tbl_phone_code_tx(v_tab_token);
  ck := case when r->>'reason' = 'no_seat' then '✅' else '🔴 ' || r::text end;
  v_msg := v_msg || E'\n⑦ 平板沒有位置 → 不發碼 ' || ck;
  r := public.tbl_claim_seat_tx(v_tab_token, v_pb);
  r := public.tbl_phone_code_tx(v_tab_token);
  v_code2 := r->>'code';
  r := public.tbl_phone_redeem_tx(v_code2);
  v_phone2 := r->>'token';
  ck := case when (r->>'ok')::boolean and (r->>'this_game_only')::boolean
              and (select device_id from session_players where id = v_pb) = (select id from table_devices where token_hash = public._tbl_hash(v_phone2))
              and not exists (select 1 from session_players where session_id = v_sess and device_id = v_tab)
             then '✅' else '🔴 ' || r::text end;
  v_msg := v_msg || E'\n⑦ 平板發碼、手機兌換 → B 的位置交給手機、平板讓出 ' || ck;

  -- ⑧ 成桌通知一建立就發一組碼
  insert into app_notifications (org_id, member_id, type, payload)
  values (v_org, v_a, 'table_ok', jsonb_build_object('text', '測試', 'test', 'true'));
  select count(*) into v_n from table_phone_codes pc join app_notifications n on n.id = pc.notification_id
   where n.member_id = v_a and n.type = 'table_ok' and n.created_at >= now() - interval '1 second';
  ck := case when v_n = 1 then '✅' else '🔴 筆數 ' || v_n end;
  v_msg := v_msg || E'\n⑧ 成桌通知 → 發一組配對碼 ' || ck;

  -- ⑨ 只限這一場：收桌之後平板發的那支手機就不能用；記住的那支照常（回「沒有牌局」）
  update table_sessions set status = 'completed', ended_at = now() where id = v_sess;
  begin
    perform public.tbl_state_tx(v_phone2);
    ck := '🔴 收桌之後還能用';
  exception when others then
    ck := case when sqlstate = '28000' then '✅' else '🔴 ' || sqlerrm end;
  end;
  v_msg := v_msg || E'\n⑨ 收桌之後，只限這一場的手機 → 失效 ' || ck;
  r := public.tbl_state_tx(v_phone);
  ck := case when r->'session' = 'null'::jsonb then '✅' else '🔴 ' || left(r::text, 200) end;
  v_msg := v_msg || E'\n⑨ 記住的那支 → 照常、回「沒有牌局」（正對照） ' || ck;

  raise exception 'migi_rollback';
exception when others then
  if sqlerrm = 'migi_rollback' then
    perform set_config('migi.phone_test', ltrim(v_msg, E'\n'), true);
  else
    perform set_config('migi.phone_test', coalesce(nullif(ltrim(v_msg, E'\n'), ''), '') || E'\n🔴 中途出錯：' || sqlerrm, true);
  end if;
end $$;

select coalesce(nullif(current_setting('migi.phone_test', true), ''), '🔴 沒有訊息') as "行為測試";
