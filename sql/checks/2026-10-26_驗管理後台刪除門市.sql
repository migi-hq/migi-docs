/* ============================================================
   行為測試：管理後台刪除門市（admin_delete_store_tx ＋ _store_real_record_count）
   2026-10-26 · 先跑 sql/pending/2026-10-26_管理後台刪除門市.sql 再跑這份
   ⚠ 整份在一個交易裡造樣本，最後 raise 'migi_rollback' 全部退掉（硬規則 1）。門市、桌、預約都是自己造的。
   ============================================================ */
do $$
declare
  v_msg    text := '';
  v_org    uuid;
  v_owner  text;
  v_real   uuid;   -- 一位真客人（is_test = false）
  v_test   uuid;   -- 一位測試帳號
  v_store  uuid;
  v_code   text;
  v_book   uuid;
  r        jsonb;
  v_row    jsonb;
begin
  select s.org_id, m.line_user_id into v_org, v_owner
    from staff s join members m on m.id = s.member_id
   where s.role = 'owner' and s.deleted_at is null and m.line_user_id is not null limit 1;
  select id into v_real from members where not is_test and deleted_at is null order by created_at limit 1;
  select id into v_test from members where is_test and deleted_at is null order by created_at limit 1;
  if v_owner is null or v_real is null or v_test is null then
    perform set_config('migi.t', '🔴 樣本不足（老闆／真客人／測試帳號 少一個），整份測不了', true);
    raise exception 'migi_rollback';
  end if;
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_owner, 'role', 'authenticated')::text, true);

  -- 造一間門市 ＋ 一張桌
  r := admin_upsert_store_tx(null, '刪除測試門市', null, null, null, null, null, null, null, null, null, null);
  v_store := (r->>'id')::uuid; v_code := r->>'code';
  perform admin_upsert_table_tx(null, v_store, 'Z1', null, 1, null);

  -- ⓐ 啟用中不能刪
  r := admin_delete_store_tx(v_store);
  v_msg := v_msg || case when r->>'reason' = 'still_active' then '✅' else '🔴' end || ' ⓐ 啟用中刪除 ⇒ ' || coalesce(r->>'reason', 'ok') || E'\n';

  perform admin_set_store_active_tx(v_store, false);

  -- ⓑ 有一筆真客人的紀錄（過去的預約）⇒ 清單不給刪、刪除也擋
  insert into bookings(org_id, store_id, member_id, play_at, planned_hours, status)
  values (v_org, v_store, v_real, now() - interval '3 days', 2, 'expired') returning id into v_book;
  select x into v_row from jsonb_array_elements(admin_list_stores_tx()->'rows') x where x->>'id' = v_store::text;
  r := admin_delete_store_tx(v_store);
  v_msg := v_msg || case when (v_row->>'can_delete')::boolean = false and r->>'reason' = 'has_real_records' then '✅' else '🔴' end
        || ' ⓑ 有真客人紀錄：清單 can_delete=' || coalesce(v_row->>'can_delete', '?') || '，刪除 ⇒ ' || coalesce(r->>'message', 'ok') || E'\n';

  -- ⓒ 同一筆改成測試帳號的 ⇒ 不算真客人，清單給刪（測試資料不擋 —— 使用者 10-26 拍板）
  update bookings set member_id = v_test where id = v_book;
  select x into v_row from jsonb_array_elements(admin_list_stores_tx()->'rows') x where x->>'id' = v_store::text;
  v_msg := v_msg || case when (v_row->>'can_delete')::boolean then '✅' else '🔴' end
        || ' ⓒ 只有測試資料：清單 can_delete=' || coalesce(v_row->>'can_delete', '?') || E'\n';

  -- ⓓ 刪除成功：門市與它的桌都標刪除，資料（預約）留著
  r := admin_delete_store_tx(v_store);
  v_msg := v_msg || case when (r->>'ok')::boolean and (r->>'tables_removed')::int = 1
                          and (select deleted_at is not null from stores where id = v_store)
                          and (select deleted_at is not null from tables where store_id = v_store)
                          and exists (select 1 from bookings where id = v_book) then '✅' else '🔴' end
        || ' ⓓ 刪除 ⇒ ' || coalesce(r->>'message', r::text) || '（桌一起標刪除、預約留著）' || E'\n';

  -- ⓔ 刪掉之後清單看不到；再刪一次回找不到
  v_msg := v_msg || case when not exists (select 1 from jsonb_array_elements(admin_list_stores_tx()->'rows') x where x->>'id' = v_store::text)
                     then '✅' else '🔴' end || ' ⓔ-1 後台清單看不到它' || E'\n';
  r := admin_delete_store_tx(v_store);
  v_msg := v_msg || case when r->>'reason' = 'not_found' then '✅' else '🔴' end || ' ⓔ-2 再刪一次 ⇒ ' || coalesce(r->>'reason', 'ok') || E'\n';

  -- ⓕ 代號不重用：再新增一間，代號要比被刪掉的那間大
  r := admin_upsert_store_tx(null, '刪除測試門市2', null, null, null, null, null, null, null, null, null, null);
  v_msg := v_msg || case when substring(r->>'code' from '\d+')::int > substring(v_code from '\d+')::int then '✅' else '🔴' end
        || ' ⓕ 刪掉 ' || v_code || ' 之後新增 ⇒ ' || coalesce(r->>'code', '?') || '（不可以重用）' || E'\n';

  -- ⓖ S01 永遠不能刪（真客人紀錄 > 0）
  select x into v_row from jsonb_array_elements(admin_list_stores_tx()->'rows') x where x->>'code' = 'S01';
  v_msg := v_msg || case when (v_row->>'can_delete')::boolean = false then '✅' else '🔴' end
        || ' ⓖ S01 can_delete=' || coalesce(v_row->>'can_delete', '?');

  perform set_config('migi.t', v_msg, true);
  raise exception 'migi_rollback';
exception when others then
  if sqlerrm <> 'migi_rollback' then
    v_msg := v_msg || E'\n🔴 中途出錯：' || sqlerrm;
  end if;
  perform set_config('migi.t', v_msg, false);
end $$;

select coalesce(nullif(current_setting('migi.t', true), ''), '🔴 沒有測試訊息') as "行為測試";
