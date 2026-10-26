/* ============================================================
   管理後台「門市」頁的後端：門市清單／新增編輯／停用，桌位清單／新增改名／停用
   2026-10-23 · MIGI 咪吉麻將

   ── 起因 ────────────────────────────────────────────────
   使用者：「是不是要做管理後台新增門市」。查下去：
   · 後台側邊欄早就有「門市」一格（ready: false），按下去是空的；後端沒有任何新增或編輯門市、新增桌位的函式。
   · 🔴 7 間門市只有 S01 在營業，S02～S07 是 07-24 建的**範例**（使用者 10-23 確認），
     但 list_stores_tx 只看 is_active ⇒ **封測客人在會員 App 看得到全部 7 間**；
     S02 還有固定牌局範本每天自動開空房，客人在配桌列表看得到「前鎮店」有房。
   ⇒ 這一頁做好之後，在後台按「停用」就能把範例收起來。

   ── 規則 ────────────────────────────────────────────────
   · 權限：一律 can('store.write')（總部與老闆）；操作者從登入身分取，不收參數。
   · 新增門市：代號自動接下去（S08…），同一機構內用交易鎖避免兩人同時新增拿到同一號。
     正式／測試標記跟著上線狀態：orgs.live_from 還沒到 ⇒ 標成測試（跟現有 7 間一致），
     上線當天由那份既有的 SQL 統一改（docs/09-環境流程/上線當天要設的東西.md）。
   · 停用門市 ⇒ App 與 POS 的門市清單就看不到它。三道擋牆（擋下時講出原因與數量）：
       ① 還有沒收桌的牌局　② 還有人在的配桌房　③ 還有未來的包桌預約
     ＋ 不可以停用最後一間啟用中的門市。
     通過之後順手做兩件事（回傳數量）：
       · 那間店的固定牌局範本全部關掉（不然排程每天繼續開空房）
       · 那間店「沒有人的等待中配桌房」改成已取消
     重新啟用**不會**把固定牌局打開 —— 要哪幾個由店員在 POS 重新開，回傳訊息會講。
   · 桌位：桌號同一間店不可重複（既有唯一索引 uq_tables_store_label）；
     停用桌位直接叫 POS 那支 set_table_active_tx（有牌局在打不給停），**同一件事只有一份**。
     座位數不開放（麻將一律 4 人）。

   ── 刻意不做 ────────────────────────────────────────────
   · 刪除門市／桌位：被 20 幾張表參照（訂單、牌局、流水…），而且都是歷史。停用就夠。
   · 正式／測試標記、法人資料、經緯度、照片：上線當天一次性、或還沒有畫面要用。
   · 改代號：代號印在門市 QR 上（註冊時比對），改了舊 QR 就失效。
   ============================================================ */

-- ① 門市清單（含停用的）＋ 法人選單
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
        'recurring', (select count(*) from recurring_tables r where r.store_id = s.id and r.enabled)
      ) order by s.code)
        from stores s left join legal_entities e on e.id = s.entity_id
       where s.org_id = v_org and s.deleted_at is null), '[]'::jsonb),
    'entities', coalesce((
      select jsonb_agg(jsonb_build_object('id', le.id, 'name', le.name, 'kind', le.kind) order by le.kind, le.name)
        from legal_entities le where le.org_id = v_org and le.is_active), '[]'::jsonb));
end $$;

-- ② 新增或編輯門市（p_id 是 null ＝ 新增）
create or replace function public.admin_upsert_store_tx(
  p_id uuid, p_name text, p_address text, p_city text, p_district text,
  p_phone text, p_parking text, p_open_time text, p_close_time text,
  p_store_type text, p_entity_id uuid, p_note text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org   uuid;
  v_staff uuid;
  v_name  text := nullif(btrim(coalesce(p_name, '')), '');
  v_open  time;
  v_close time;
  v_code  text;
  v_id    uuid;
  v_test  boolean;
begin
  if not public.can('store.write') then
    return jsonb_build_object('ok', false, 'reason', 'forbidden', 'message', '沒有權限管理門市');
  end if;
  v_org   := public.current_org_id();
  v_staff := (select staff_id from public.current_staff());   -- 🔴 操作者從登入身分取

  if v_name is null or char_length(v_name) > 40 then
    return jsonb_build_object('ok', false, 'reason', 'bad_name', 'message', '門市名稱要填，最多 40 個字');
  end if;
  if exists (select 1 from stores where org_id = v_org and deleted_at is null
              and name = v_name and id is distinct from p_id) then
    return jsonb_build_object('ok', false, 'reason', 'dup_name', 'message', '已經有一間門市叫「' || v_name || '」');
  end if;
  if p_store_type is not null and p_store_type not in ('直營', '加盟', '系統授權', '自家場') then
    return jsonb_build_object('ok', false, 'reason', 'bad_type', 'message', '門市類型只能是 直營／加盟／系統授權／自家場');
  end if;
  if p_entity_id is not null and not exists (select 1 from legal_entities where id = p_entity_id and org_id = v_org) then
    return jsonb_build_object('ok', false, 'reason', 'bad_entity', 'message', '找不到這個法人');
  end if;
  begin
    v_open  := nullif(btrim(coalesce(p_open_time, '')), '')::time;
    v_close := nullif(btrim(coalesce(p_close_time, '')), '')::time;
  exception when others then
    return jsonb_build_object('ok', false, 'reason', 'bad_time', 'message', '營業時間請寫成 14:00 這種格式');
  end;

  if p_id is null then
    -- 新增：同一機構一次只讓一個人拿代號
    perform pg_advisory_xact_lock(hashtext('migi_store_code:' || v_org::text));
    select 'S' || lpad((coalesce(max(substring(code from '^S(\d+)$')::int), 0) + 1)::text, 2, '0')
      into v_code from stores where org_id = v_org;
    -- 上線（orgs.live_from 到了）之前新增的門市跟現有 7 間一樣標成測試
    select (o.live_from is null or o.live_from > now()) into v_test from orgs o where o.id = v_org;

    insert into stores(org_id, code, name, address, city, district, phone, parking,
                       open_time, close_time, store_type, entity_id, note, is_test, created_by, updated_by)
    values (v_org, v_code, v_name, nullif(btrim(p_address), ''), nullif(btrim(p_city), ''), nullif(btrim(p_district), ''),
            nullif(btrim(p_phone), ''), nullif(btrim(p_parking), ''), v_open, v_close,
            p_store_type, p_entity_id, nullif(btrim(p_note), ''), coalesce(v_test, true), v_staff, v_staff)
    returning id into v_id;
    return jsonb_build_object('ok', true, 'id', v_id, 'code', v_code, 'created', true);
  end if;

  update stores
     set name = v_name,
         address = nullif(btrim(p_address), ''), city = nullif(btrim(p_city), ''), district = nullif(btrim(p_district), ''),
         phone = nullif(btrim(p_phone), ''), parking = nullif(btrim(p_parking), ''),
         open_time = v_open, close_time = v_close,
         store_type = p_store_type, entity_id = p_entity_id, note = nullif(btrim(p_note), ''),
         updated_at = now(), updated_by = v_staff
   where id = p_id and org_id = v_org and deleted_at is null
   returning code into v_code;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'not_found', 'message', '找不到這間門市');
  end if;
  return jsonb_build_object('ok', true, 'id', p_id, 'code', v_code, 'created', false);
end $$;

-- ③ 停用／啟用門市
create or replace function public.admin_set_store_active_tx(p_id uuid, p_active boolean)
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
  v_rec   int := 0;
  v_q     int := 0;
begin
  if not public.can('store.write') then
    return jsonb_build_object('ok', false, 'reason', 'forbidden', 'message', '沒有權限管理門市');
  end if;
  v_org   := public.current_org_id();
  v_staff := (select staff_id from public.current_staff());

  select id, name, is_active into v_s from stores
   where id = p_id and org_id = v_org and deleted_at is null for update;
  if v_s.id is null then
    return jsonb_build_object('ok', false, 'reason', 'not_found', 'message', '找不到這間門市');
  end if;
  if v_s.is_active = coalesce(p_active, false) then
    return jsonb_build_object('ok', true, 'is_active', v_s.is_active, 'unchanged', true);
  end if;

  if p_active then
    update stores set is_active = true, updated_at = now(), updated_by = v_staff where id = p_id;
    return jsonb_build_object('ok', true, 'is_active', true,
      'message', '「' || v_s.name || '」已啟用。之前關掉的固定牌局不會自動打開，要的話請在 POS 重新開。');
  end if;

  -- 停用的擋牆
  select count(*) into v_n from table_sessions
   where store_id = p_id and status = 'open' and deleted_at is null;
  if v_n > 0 then
    return jsonb_build_object('ok', false, 'reason', 'open_sessions', 'count', v_n,
      'message', '「' || v_s.name || '」還有 ' || v_n || ' 桌牌局沒收桌，收完才能停用');
  end if;

  select count(*) into v_n from match_queues q
   where q.store_id = p_id and q.status in ('waiting', 'matched')
     and exists (select 1 from match_queue_players p where p.queue_id = q.id and p.left_at is null);
  if v_n > 0 then
    return jsonb_build_object('ok', false, 'reason', 'queues_with_players', 'count', v_n,
      'message', '「' || v_s.name || '」還有 ' || v_n || ' 個配桌房裡面有人，請先在 POS 處理');
  end if;

  select count(*) into v_n from bookings
   where store_id = p_id and status = 'booked' and play_at > now();
  if v_n > 0 then
    return jsonb_build_object('ok', false, 'reason', 'future_bookings', 'count', v_n,
      'message', '「' || v_s.name || '」還有 ' || v_n || ' 筆未來的包桌預約，請先在 POS 取消');
  end if;

  if not exists (select 1 from stores where org_id = v_org and deleted_at is null and is_active and id <> p_id) then
    return jsonb_build_object('ok', false, 'reason', 'last_store', 'message', '這是最後一間啟用中的門市，不能停用');
  end if;

  -- 通過：關固定牌局、取消沒人的等待中配桌房、停用門市
  update recurring_tables set enabled = false where store_id = p_id and enabled;
  get diagnostics v_rec = row_count;

  update match_queues q set status = 'cancelled', updated_at = now()
   where q.store_id = p_id and q.status = 'waiting'
     and not exists (select 1 from match_queue_players p where p.queue_id = q.id and p.left_at is null);
  get diagnostics v_q = row_count;

  update stores set is_active = false, updated_at = now(), updated_by = v_staff where id = p_id;

  return jsonb_build_object('ok', true, 'is_active', false, 'recurring_off', v_rec, 'queues_cancelled', v_q);
end $$;

-- ④ 某間門市的桌位（含停用的）
create or replace function public.admin_list_tables_tx(p_store_id uuid)
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
  if not exists (select 1 from stores where id = p_store_id and org_id = v_org and deleted_at is null) then
    return jsonb_build_object('ok', false, 'reason', 'not_found', 'message', '找不到這間門市');
  end if;

  return jsonb_build_object('ok', true, 'rows', coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', t.id, 'label', t.label, 'area', t.area, 'sort_order', t.sort_order,
      'note', t.note, 'is_active', t.is_active, 'auto_assign', t.auto_assign,
      'busy', exists (select 1 from table_sessions ts
                       where ts.table_id = t.id and ts.status = 'open' and ts.deleted_at is null)
    ) order by t.sort_order, t.label)
      from tables t where t.store_id = p_store_id and t.deleted_at is null), '[]'::jsonb));
end $$;

-- ⑤ 新增或改名桌位（p_id 是 null ＝ 新增）
create or replace function public.admin_upsert_table_tx(
  p_id uuid, p_store_id uuid, p_label text, p_area text, p_sort_order int, p_note text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org   uuid;
  v_staff uuid;
  v_label text := nullif(btrim(coalesce(p_label, '')), '');
  v_id    uuid;
begin
  if not public.can('store.write') then
    return jsonb_build_object('ok', false, 'reason', 'forbidden', 'message', '沒有權限管理門市');
  end if;
  v_org   := public.current_org_id();
  v_staff := (select staff_id from public.current_staff());

  if v_label is null or char_length(v_label) > 10 then
    return jsonb_build_object('ok', false, 'reason', 'bad_label', 'message', '桌號要填，最多 10 個字');
  end if;

  begin
    if p_id is null then
      if not exists (select 1 from stores where id = p_store_id and org_id = v_org and deleted_at is null) then
        return jsonb_build_object('ok', false, 'reason', 'not_found', 'message', '找不到這間門市');
      end if;
      insert into tables(org_id, store_id, label, area, sort_order, note, created_by, updated_by)
      values (v_org, p_store_id, v_label, nullif(btrim(p_area), ''), coalesce(p_sort_order, 0),
              nullif(btrim(p_note), ''), v_staff, v_staff)
      returning id into v_id;
      return jsonb_build_object('ok', true, 'id', v_id, 'created', true);
    end if;

    update tables
       set label = v_label, area = nullif(btrim(p_area), ''), sort_order = coalesce(p_sort_order, sort_order),
           note = nullif(btrim(p_note), ''), updated_at = now(), updated_by = v_staff
     where id = p_id and org_id = v_org and deleted_at is null;
    if not found then
      return jsonb_build_object('ok', false, 'reason', 'not_found', 'message', '找不到這張桌');
    end if;
    return jsonb_build_object('ok', true, 'id', p_id, 'created', false);
  exception when unique_violation then
    return jsonb_build_object('ok', false, 'reason', 'dup_label', 'message', '這間門市已經有「' || v_label || '」這個桌號');
  end;
end $$;

-- ⑥ 停用／啟用桌位：權限檢查之後交給 POS 那支（有牌局在打不給停），規則只有一份
create or replace function public.admin_set_table_active_tx(p_id uuid, p_active boolean)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.can('store.write') then
    return jsonb_build_object('ok', false, 'reason', 'forbidden', 'message', '沒有權限管理門市');
  end if;
  if not exists (select 1 from tables where id = p_id and org_id = public.current_org_id() and deleted_at is null) then
    return jsonb_build_object('ok', false, 'reason', 'not_found', 'message', '找不到這張桌');
  end if;
  return public.set_table_active_tx(p_id, coalesce(p_active, false), null);
end $$;

-- 授權：登入的人才叫得到，身分由函式自己問（can）
revoke execute on function public.admin_list_stores_tx() from public, anon;
revoke execute on function public.admin_upsert_store_tx(uuid, text, text, text, text, text, text, text, text, text, uuid, text) from public, anon;
revoke execute on function public.admin_set_store_active_tx(uuid, boolean) from public, anon;
revoke execute on function public.admin_list_tables_tx(uuid) from public, anon;
revoke execute on function public.admin_upsert_table_tx(uuid, uuid, text, text, int, text) from public, anon;
revoke execute on function public.admin_set_table_active_tx(uuid, boolean) from public, anon;
grant execute on function public.admin_list_stores_tx() to authenticated;
grant execute on function public.admin_upsert_store_tx(uuid, text, text, text, text, text, text, text, text, text, uuid, text) to authenticated;
grant execute on function public.admin_set_store_active_tx(uuid, boolean) to authenticated;
grant execute on function public.admin_list_tables_tx(uuid) to authenticated;
grant execute on function public.admin_upsert_table_tx(uuid, uuid, text, text, int, text) to authenticated;
grant execute on function public.admin_set_table_active_tx(uuid, boolean) to authenticated;

-- ============================================================
-- 驗證（單一 SELECT；不用 raise —— 硬規則 1.8）。行為測試在 sql/checks/2026-10-23_驗管理後台門市與桌位.sql
-- ============================================================
do $$
declare
  v_msg text := '';
  v_n   int;
  v_names text[] := array['admin_list_stores_tx','admin_upsert_store_tx','admin_set_store_active_tx',
                          'admin_list_tables_tx','admin_upsert_table_tx','admin_set_table_active_tx'];
begin
  -- ① 六支都在、各一個版本、都是 DEFINER
  select count(*) into v_n from pg_proc
   where pronamespace = 'public'::regnamespace and proname = any(v_names) and prosecdef;
  v_msg := v_msg || case when v_n = 6 then '✅' else '🔴' end || ' ① 六支函式（DEFINER）' || v_n || E' 支（要 6）\n';

  -- ② 六支都授權給登入的人
  select count(*) into v_n from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.proname = any(v_names)
     and has_function_privilege('authenticated', p.oid, 'EXECUTE');
  v_msg := v_msg || case when v_n = 6 then '✅' else '🔴' end || ' ② 登入的人叫得到 ' || v_n || E' 支（要 6）\n';

  -- ③ 沒登入的叫不到：明確授權 anon 與 PUBLIC 都要是 0（硬規則 2.6）
  select count(*) into v_n
    from pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
   where p.pronamespace = 'public'::regnamespace and p.proname = any(v_names)
     and a.privilege_type = 'EXECUTE' and a.grantee in (0, 'anon'::regrole::oid);
  v_msg := v_msg || case when v_n = 0 then '✅' else '🔴' end || ' ③ anon／PUBLIC 叫得到的 ' || v_n || E' 個（要 0）\n';

  -- ④ 六支都真的拿權限去判斷（問「有沒有呼叫」，不是「有沒有提到」—— 硬規則 3.5）
  select count(*) into v_n from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.proname = any(v_names) and p.prokind = 'f'
     and pg_get_functiondef(p.oid) ~ 'if not public\.can\(';
  v_msg := v_msg || case when v_n = 6 then '✅' else '🔴' end || ' ④ 開頭有權限判斷的 ' || v_n || E' 支（要 6）\n';

  -- ⑤ 下一個門市代號（新增時會拿到的）
  v_msg := v_msg || '⚪ ⑤ 下一間門市的代號會是 '
        || coalesce((select 'S' || lpad((max(substring(code from '^S(\d+)$')::int) + 1)::text, 2, '0') from stores), '?');

  perform set_config('migi.v', v_msg, true);
end $$;

select coalesce(nullif(current_setting('migi.v', true), ''), '🔴 驗證段沒有跑到') as "驗證";
