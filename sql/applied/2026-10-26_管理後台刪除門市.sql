/* ============================================================
   管理後台刪除門市（只限「沒有真客人紀錄」的門市）
   2026-10-26 · MIGI 咪吉麻將

   ── 使用者拍板 ──────────────────────────────────────────
   「可以刪除門市嗎」→「但目前都是測試資料，也不能刪除嗎」
   ⇒ 能不能刪看的是**有沒有真客人的紀錄**，不是有沒有紀錄。
     S02 有 145 筆訂單、96 場牌局、42 筆儲值，但 10-26 查過**全部是測試帳號的**（真客人 0 筆）⇒ 可以刪。
     S01 有真客人 ⇒ 永遠只能停用。上線之後真客人去過的門市都一樣。

   ── 規則 ────────────────────────────────────────────────
   · 要先停用才能刪（停用時已經關掉固定牌局、取消空房、確認沒有進行中的牌局）。
   · 「真客人的紀錄」＝ 下面任何一種有一筆屬於 is_test = false 的會員：
       訂單、儲值單、錢包流水（store_id 或 served_store_id）、牌局座位、配桌房成員、包桌預約
     ⇒ 算式只有一份：_store_real_record_count(store)，清單（要不要畫刪除鈕）與刪除都叫它。
   · 還有店員掛在這間店（staff.store_id）⇒ 擋，先到店員管理移走。
   · 刪除 ＝ stores.deleted_at ＋ 它的桌位 deleted_at。**資料本身不刪**：
     那些測試訂單、牌局照樣在，參照它的 20 幾張表都不會斷。按錯了改回 deleted_at = null 就救得回來。
   · 代號不重用：新增門市的代號是「全部門市（含已刪除）最大號 ＋ 1」——
     印出去的門市 QR 帶的是代號，重用會讓舊 QR 指到新店（admin_upsert_store_tx 本來就這樣算，這份不動它）。
   ============================================================ */

-- ① 唯一一份「真客人紀錄」算式
create or replace function public._store_real_record_count(p_store_id uuid)
returns int
language sql
stable
security definer
set search_path = public
as $$
  select
    (select count(*) from orders o join members m on m.id = o.member_id
      where o.store_id = p_store_id and not m.is_test)::int
  + (select count(*) from topup_orders t join members m on m.id = t.member_id
      where t.store_id = p_store_id and not m.is_test)::int
  + (select count(*) from wallet_txns w join members m on m.id = w.member_id
      where (w.store_id = p_store_id or w.served_store_id = p_store_id) and not m.is_test)::int
  + (select count(*) from session_players sp join table_sessions ts on ts.id = sp.session_id
                                             join members m on m.id = sp.member_id
      where ts.store_id = p_store_id and not m.is_test)::int
  + (select count(*) from match_queue_players p join match_queues q on q.id = p.queue_id
                                                join members m on m.id = p.member_id
      where q.store_id = p_store_id and not m.is_test)::int
  + (select count(*) from bookings b join members m on m.id = b.member_id
      where b.store_id = p_store_id and not m.is_test)::int;
$$;

revoke execute on function public._store_real_record_count(uuid) from public, anon, authenticated;

-- ② 清單多回 can_delete（簽名不變，CREATE OR REPLACE 不掉授權）
create or replace function public.admin_list_stores_tx()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare v_org uuid;
begin
  if not public.can('store.write') then
    return jsonb_build_object('ok', false, 'reason', 'forbidden', 'message', '沒有權限管理門市');
  end if;
  v_org := public.current_org_id();

  return jsonb_build_object(
    'ok', true,
    'rows', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', s.id, 'code', s.code, 'name', s.name,
        'address', s.address, 'city', s.city, 'district', s.district,
        'phone', s.phone, 'parking', s.parking, 'note', s.note,
        'open_time', to_char(s.open_time, 'HH24:MI'), 'close_time', to_char(s.close_time, 'HH24:MI'),
        'store_type', s.store_type, 'entity_id', s.entity_id, 'entity_name', e.name,
        'is_active', s.is_active, 'is_test', s.is_test,
        'tables', (select count(*) from tables t where t.store_id = s.id and t.deleted_at is null),
        'tables_active', (select count(*) from tables t where t.store_id = s.id and t.deleted_at is null and t.is_active),
        'open_sessions', (select count(*) from table_sessions ts
                           where ts.store_id = s.id and ts.status = 'open' and ts.deleted_at is null),
        'sessions_14d', (select count(*) from table_sessions ts
                          where ts.store_id = s.id and ts.deleted_at is null and ts.created_at > now() - interval '14 days'),
        'recurring', (select count(*) from recurring_tables r where r.store_id = s.id and r.enabled),
        -- 🆕 2026-10-26：停用中、而且沒有真客人紀錄才給刪（畫面只在 true 時畫刪除鈕；後端刪除時會再檢查一次）
        'can_delete', (not s.is_active) and public._store_real_record_count(s.id) = 0
      ) order by s.code)
        from stores s left join legal_entities e on e.id = s.entity_id
       where s.org_id = v_org and s.deleted_at is null), '[]'::jsonb),
    'entities', coalesce((
      select jsonb_agg(jsonb_build_object('id', le.id, 'name', le.name, 'kind', le.kind) order by le.kind, le.name)
        from legal_entities le where le.org_id = v_org and le.is_active), '[]'::jsonb));
end $$;

-- ③ 刪除
create or replace function public.admin_delete_store_tx(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org   uuid;
  v_staff uuid;
  v_s     record;
  v_n     int;
  v_t     int;
begin
  if not public.can('store.write') then
    return jsonb_build_object('ok', false, 'reason', 'forbidden', 'message', '沒有權限管理門市');
  end if;
  v_org   := public.current_org_id();
  v_staff := (select staff_id from public.current_staff());

  select id, name, is_active into v_s from stores
   where id = p_id and org_id = v_org and deleted_at is null for update;
  if v_s.id is null then
    return jsonb_build_object('ok', false, 'reason', 'not_found', 'message', '找不到這間門市（可能已經刪除了）');
  end if;
  if v_s.is_active then
    return jsonb_build_object('ok', false, 'reason', 'still_active', 'message', '「' || v_s.name || '」還在啟用中，要先停用才能刪除');
  end if;

  v_n := public._store_real_record_count(p_id);
  if v_n > 0 then
    return jsonb_build_object('ok', false, 'reason', 'has_real_records', 'count', v_n,
      'message', '「' || v_s.name || '」有 ' || v_n || ' 筆真客人的紀錄（訂單、牌局、儲值等），只能停用，不能刪除');
  end if;

  select count(*) into v_n from staff where store_id = p_id and deleted_at is null;
  if v_n > 0 then
    return jsonb_build_object('ok', false, 'reason', 'has_staff', 'count', v_n,
      'message', '「' || v_s.name || '」還有 ' || v_n || ' 位店員掛在這間店，請先到店員管理移走');
  end if;

  update tables set deleted_at = now(), updated_at = now(), updated_by = v_staff
   where store_id = p_id and deleted_at is null;
  get diagnostics v_t = row_count;

  update stores set deleted_at = now(), updated_at = now(), updated_by = v_staff where id = p_id;

  return jsonb_build_object('ok', true, 'id', p_id, 'tables_removed', v_t,
    'message', '已刪除「' || v_s.name || '」' || case when v_t > 0 then '（連同 ' || v_t || ' 張桌位）' else '' end || '。');
end $$;

revoke execute on function public.admin_delete_store_tx(uuid) from public, anon;
grant  execute on function public.admin_delete_store_tx(uuid) to authenticated;

-- ============================================================
-- 驗證（單一 SELECT；不用 raise —— 硬規則 1.8）。行為測試在 sql/checks/2026-10-26_驗管理後台刪除門市.sql
-- ============================================================
do $$
declare
  v_msg text := '';
  v_n   int;
begin
  -- ① 三支都在
  select count(*) into v_n from pg_proc where pronamespace = 'public'::regnamespace
     and proname in ('_store_real_record_count', 'admin_list_stores_tx', 'admin_delete_store_tx');
  v_msg := v_msg || case when v_n = 3 then '✅' else '🔴' end || ' ① 函式 ' || v_n || E' 支（要 3）\n';

  -- ② 授權：刪除與清單給登入的人；算式前端叫不到；三支 anon／PUBLIC 都叫不到
  select count(*) into v_n from pg_proc p where p.pronamespace = 'public'::regnamespace
     and p.proname in ('admin_list_stores_tx', 'admin_delete_store_tx') and has_function_privilege('authenticated', p.oid, 'EXECUTE');
  v_msg := v_msg || case when v_n = 2 then '✅' else '🔴' end || ' ② 清單與刪除，登入的人叫得到 ' || v_n || E' 支（要 2）\n';
  select count(*) into v_n
    from pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
   where p.pronamespace = 'public'::regnamespace
     and p.proname in ('_store_real_record_count', 'admin_list_stores_tx', 'admin_delete_store_tx')
     and a.privilege_type = 'EXECUTE'
     and (a.grantee in (0, 'anon'::regrole::oid)
          or (p.proname = '_store_real_record_count' and a.grantee = 'authenticated'::regrole::oid));
  v_msg := v_msg || case when v_n = 0 then '✅' else '🔴' end || ' ③ 不該叫得到的 ' || v_n || E' 個（要 0）\n';

  -- ④ 正對照與負對照：S01 有真客人紀錄（要 > 0），S02 沒有（要 0）
  select public._store_real_record_count(id) into v_n from stores where code = 'S01';
  v_msg := v_msg || case when v_n > 0 then '✅' else '🔴' end || ' ④-1 S01 真客人紀錄 ' || v_n || E' 筆（要 > 0，永遠不能刪）\n';
  select public._store_real_record_count(id) into v_n from stores where code = 'S02';
  v_msg := v_msg || case when v_n = 0 then '✅' else '🔴' end || ' ④-2 S02 真客人紀錄 ' || v_n || ' 筆（要 0，停用後可以刪）';

  perform set_config('migi.v', v_msg, true);
end $$;

select coalesce(nullif(current_setting('migi.v', true), ''), '🔴 驗證段沒有跑到') as "驗證";
