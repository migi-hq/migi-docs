/* ============================================================
   行為測試：管理後台門市與桌位（6 支 admin_*_store／table_tx）
   2026-10-23 · 先跑 sql/pending/2026-10-23_管理後台門市與桌位.sql 再跑這份
   ⚠ 整份在一個交易裡造樣本，最後 raise 'migi_rollback' 全部退掉（硬規則 1）。
     新門市、新桌、預約、配桌房都是自己造的，不借線上資料（硬規則 3.57）。
   身分：模擬老闆登入（JWT 的 sub ＝ 老闆的 LINE id），以及一位不是店員的測試會員。
   ============================================================ */
do $$
declare
  v_msg     text := '';
  v_org     uuid;
  v_owner   text;      -- 老闆的 LINE id
  v_plain   text;      -- 一位不是店員的測試會員的 LINE id
  v_member  uuid;      -- 拿來當預約人／配桌房成員的測試會員
  v_stake   uuid;
  v_before  int;
  v_code    text;
  v_store   uuid;
  v_table   uuid;
  v_queue   uuid;
  v_book    uuid;
  r         jsonb;
begin
  -- 換身分的方式：把 JWT 寫進 request.jwt.claims（auth.jwt() 讀的就是它）
  select s.org_id, m.line_user_id into v_org, v_owner
    from staff s join members m on m.id = s.member_id
   where s.role = 'owner' and s.deleted_at is null and m.line_user_id is not null limit 1;
  select m.line_user_id, m.id into v_plain, v_member
    from members m
   where m.is_test and m.deleted_at is null and m.line_user_id is not null
     and not exists (select 1 from staff s where s.member_id = m.id and s.deleted_at is null)
   order by m.created_at limit 1;
  select id into v_stake from stake_levels where org_id = v_org and deleted_at is null and is_active order by sort_order nulls last limit 1;
  if v_owner is null or v_plain is null or v_stake is null then
    perform set_config('migi.t', '🔴 樣本不足（老闆 LINE ' || coalesce(v_owner, '無') || '／測試會員 ' || coalesce(v_plain, '無')
      || '／級距 ' || coalesce(v_stake::text, '無') || '），整份測不了', true);
    raise exception 'migi_rollback';
  end if;

  -- ⓐ 沒有身分 ⇒ 擋
  perform set_config('request.jwt.claims', '', true);
  r := admin_list_stores_tx();
  v_msg := v_msg || case when r->>'reason' = 'forbidden' then '✅' else '🔴' end || ' ⓐ 沒登入 ⇒ ' || coalesce(r->>'reason', 'ok') || E'\n';

  -- ⓑ 一般會員（不是店員）⇒ 擋
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_plain, 'role', 'authenticated')::text, true);
  r := admin_upsert_store_tx(null, '不該建出來', null, null, null, null, null, null, null, null, null, null);
  v_msg := v_msg || case when r->>'reason' = 'forbidden' then '✅' else '🔴' end || ' ⓑ 一般會員新增門市 ⇒ ' || coalesce(r->>'reason', 'ok') || E'\n';

  -- 以下都用老闆的身分
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_owner, 'role', 'authenticated')::text, true);

  -- ⓒ 清單（正對照：老闆讀得到）
  r := admin_list_stores_tx();
  v_before := jsonb_array_length(r->'rows');
  v_msg := v_msg || case when (r->>'ok')::boolean and v_before > 0 and jsonb_array_length(r->'entities') > 0 then '✅' else '🔴' end
        || ' ⓒ 老闆讀清單：門市 ' || v_before || ' 間、法人 ' || jsonb_array_length(coalesce(r->'entities', '[]')) || E' 個\n';

  -- ⓓ 新增門市：代號自動接下去、上線前標成測試
  select 'S' || lpad((max(substring(code from '^S(\d+)$')::int) + 1)::text, 2, '0') into v_code from stores where org_id = v_org;
  r := admin_upsert_store_tx(null, '行為測試門市', '測試路 1 號', '高雄市', '前金區', '07-0000000', null,
                             '14:00', '02:00', '直營', null, null);
  v_store := (r->>'id')::uuid;
  v_msg := v_msg || case when (r->>'ok')::boolean and r->>'code' = v_code
                          and (select is_test from stores where id = v_store) then '✅' else '🔴' end
        || ' ⓓ 新增門市 ⇒ ' || coalesce(r->>'code', r->>'message') || '（要 ' || v_code || '，標成測試）' || E'\n';

  -- ⓔ 同名擋下、營業時間格式錯擋下
  r := admin_upsert_store_tx(null, '行為測試門市', null, null, null, null, null, null, null, null, null, null);
  v_msg := v_msg || case when r->>'reason' = 'dup_name' then '✅' else '🔴' end || ' ⓔ-1 同名 ⇒ ' || coalesce(r->>'reason', 'ok') || E'\n';
  r := admin_upsert_store_tx(v_store, '行為測試門市', null, null, null, null, null, '25:99', null, null, null, null);
  v_msg := v_msg || case when r->>'reason' = 'bad_time' then '✅' else '🔴' end || ' ⓔ-2 營業時間 25:99 ⇒ ' || coalesce(r->>'reason', 'ok') || E'\n';

  -- ⓕ 編輯：改地址，代號不變
  r := admin_upsert_store_tx(v_store, '行為測試門市', '測試路 2 號', '高雄市', '前金區', null, '路邊', '13:00', '01:00', '直營', null, '備註');
  v_msg := v_msg || case when (r->>'ok')::boolean and r->>'code' = v_code
                          and (select address from stores where id = v_store) = '測試路 2 號' then '✅' else '🔴' end
        || ' ⓕ 編輯門市（代號不變）' || E'\n';

  -- ⓖ 桌位：新增 A1、重複擋下、清單看得到
  r := admin_upsert_table_tx(null, v_store, 'A1', '一樓', 1, null);
  v_table := (r->>'id')::uuid;
  v_msg := v_msg || case when (r->>'ok')::boolean then '✅' else '🔴' end || ' ⓖ-1 新增桌 A1 ⇒ ' || coalesce(r->>'message', 'ok') || E'\n';
  r := admin_upsert_table_tx(null, v_store, 'A1', null, 2, null);
  v_msg := v_msg || case when r->>'reason' = 'dup_label' then '✅' else '🔴' end || ' ⓖ-2 再新增 A1 ⇒ ' || coalesce(r->>'reason', 'ok') || E'\n';
  r := admin_list_tables_tx(v_store);
  v_msg := v_msg || case when jsonb_array_length(r->'rows') = 1 then '✅' else '🔴' end
        || ' ⓖ-3 桌位清單 ' || jsonb_array_length(coalesce(r->'rows', '[]')) || E' 張（要 1）\n';

  -- ⓗ 停用再啟用桌位（交給 POS 那支）
  r := admin_set_table_active_tx(v_table, false);
  v_msg := v_msg || case when (r->>'ok')::boolean and not (select is_active from tables where id = v_table) then '✅' else '🔴' end
        || ' ⓗ-1 停用桌位' || E'\n';
  r := admin_set_table_active_tx(v_table, true);
  v_msg := v_msg || case when (r->>'ok')::boolean and (select is_active from tables where id = v_table) then '✅' else '🔴' end
        || ' ⓗ-2 啟用桌位' || E'\n';

  -- ⓘ 正對照：停用前，會員 App 的門市清單看得到它
  v_msg := v_msg || case when list_stores_tx(v_org) @> jsonb_build_array(jsonb_build_object('id', v_store)) then '✅' else '🔴' end
        || ' ⓘ 停用前 App 看得到新門市' || E'\n';

  -- ⓙ 擋牆①：未來的包桌預約
  insert into bookings(org_id, store_id, member_id, play_at, planned_hours)
  values (v_org, v_store, v_member, now() + interval '3 days', 2) returning id into v_book;
  r := admin_set_store_active_tx(v_store, false);
  v_msg := v_msg || case when r->>'reason' = 'future_bookings' then '✅' else '🔴' end || ' ⓙ 有未來預約 ⇒ ' || coalesce(r->>'message', 'ok') || E'\n';
  update bookings set status = 'cancelled', cancelled_reason = '行為測試' where id = v_book;

  -- ⓚ 擋牆②：配桌房裡有人
  insert into match_queues(org_id, store_id, stake_level_id, play_at)
  values (v_org, v_store, v_stake, now() + interval '1 day') returning id into v_queue;
  insert into match_queue_players(org_id, queue_id, member_id) values (v_org, v_queue, v_member);
  r := admin_set_store_active_tx(v_store, false);
  v_msg := v_msg || case when r->>'reason' = 'queues_with_players' then '✅' else '🔴' end || ' ⓚ 配桌房有人 ⇒ ' || coalesce(r->>'message', 'ok') || E'\n';

  -- ⓛ 人離開了 ⇒ 可以停用，空房順手取消
  update match_queue_players set left_at = now() where queue_id = v_queue;
  r := admin_set_store_active_tx(v_store, false);
  v_msg := v_msg || case when (r->>'ok')::boolean and (r->>'queues_cancelled')::int = 1
                          and (select status from match_queues where id = v_queue) = 'cancelled' then '✅' else '🔴' end
        || ' ⓛ 停用 ⇒ ' || r::text || '（取消的空房要 1）' || E'\n';

  -- ⓜ 停用後會員 App 的門市清單看不到它（負對照，與 ⓘ 成對）
  v_msg := v_msg || case when not (list_stores_tx(v_org) @> jsonb_build_array(jsonb_build_object('id', v_store))) then '✅' else '🔴' end
        || ' ⓜ 停用後 App 看不到新門市' || E'\n';

  -- ⓝ 重新啟用
  r := admin_set_store_active_tx(v_store, true);
  v_msg := v_msg || case when (r->>'ok')::boolean and (select is_active from stores where id = v_store) then '✅' else '🔴' end
        || ' ⓝ 重新啟用 ⇒ ' || coalesce(r->>'message', r::text) || E'\n';

  -- ⓞ 原本那幾間的資料沒被這份測試碰到（數量回到 ⓒ ＋ 1）
  r := admin_list_stores_tx();
  v_msg := v_msg || case when jsonb_array_length(r->'rows') = v_before + 1 then '✅' else '🔴' end
        || ' ⓞ 清單 ' || jsonb_array_length(r->'rows') || ' 間（要 ' || (v_before + 1) || '）';

  perform set_config('migi.t', v_msg, true);
  raise exception 'migi_rollback';
exception when others then
  if sqlerrm <> 'migi_rollback' then
    v_msg := v_msg || E'\n🔴 中途出錯：' || sqlerrm;
  end if;
  perform set_config('migi.t', v_msg, false);
end $$;

select coalesce(nullif(current_setting('migi.t', true), ''), '🔴 沒有測試訊息') as "行為測試";
