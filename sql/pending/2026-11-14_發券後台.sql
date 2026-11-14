/* ============================================================
   發券後台（管理後台「優惠券」頁）
   2026-11-14 · MIGI 咪吉麻將
   使用者：「發券照建議」—— 券的主檔（新增／編輯）、發給會員、看發出去的券
   行為測試：sql/checks/2026-11-14_驗發券後台.sql（跑完這份再跑）

   ── 盤點（動手前查線上）────────────────────────────────
   · 適用範圍 2026-10-01 就改成規則表 coupon_scopes（待辦 0.8），計價核心 _cart_pricing 照它算 ⇒ 這份不碰計價
   · 結帳時已經會擋：過期（member_coupons.expires_at）、用過、最低消費、折抵上限 ⇒ 這份也不碰結帳
   · 🔴 系統裡**沒有任何發券的函式** —— 之前 7 張都是直接寫資料庫的
   · 🔴 member_coupons **沒有欄位記「誰發的」** —— 稽核欄位不可回溯（硬規則 5.6），這份補上
   · coupons.kind（NOT NULL，舊的分類）只剩會員 App 錢包拿來畫小字；新券由後端照適用範圍推出來，不讓人選

   ── 規則 ─────────────────────────────────────────────
   折扣方式   percent 折抵幅度 1～99（10 ＝ 9 折，同 member_tiers，畫面一律顯示折數）
             fixed   折抵金額 1～100000（元）
             free    免費：指定商品 → 只免那一個商品一份；不指定 → 適用範圍內全免
   適用範圍   coupon_scopes：營收類別／子分類／指定商品，一張多條＝符合任一條；沒有任何一條＝全部可折扣品項
             （指定商品免費券不看適用範圍，有填就擋 —— 不然畫面寫的跟實際折的不一樣）
   期限       發出後 N 天（valid_days）或到某一天（valid_until，那天台北時間 23:59 為止）；兩個都填取先到的；都不填＝不限期限
   成本       store 門市負擔／hq 總部負擔（發券那一刻抄進 member_coupons.cost_bearer）
   🔴 已經發出去的券（不管用了沒）**不能再改折扣內容**（折扣方式、數值、範圍、指定商品、最低消費、折抵上限）——
     沒用過的那幾張會跟著變，客人拿到的跟看到的不一樣。要改請停用、另建一張。
     名稱、期限、成本負擔、啟用照樣能改：期限與成本在發券那一刻就抄進每一張了，改了只影響之後發的。
   停用       不能再發；**已經發出去的照樣能用**（_cart_pricing 不看 coupons.is_active）
   發券       一次最多 200 位會員、每人 1～10 張；電腦對手不發；要先啟用

   ── 新增／改的東西 ─────────────────────────────────────
   member_coupons.granted_by_staff_id、grant_note    新欄位（後端從登入身分填，前端指定不了）
   admin_list_coupons_tx()                          新
   admin_upsert_coupon_tx(...)                      新（新增與編輯共用）
   admin_set_coupon_active_tx(id, active)           新
   admin_grant_coupon_tx(coupon, members[], qty, note)  新
   admin_list_member_coupons_tx(coupon, status, limit)  新
   權限碼 coupon.write（can() 今天是總部與老闆）；全部只給 authenticated（硬規則 2.7）
   ============================================================ */

-- ① 稽核欄位
alter table public.member_coupons add column if not exists granted_by_staff_id uuid references public.staff(id);
alter table public.member_coupons add column if not exists grant_note text;
comment on column public.member_coupons.granted_by_staff_id is '誰發的（admin_grant_coupon_tx 從登入身分取，前端指定不了）；2026-11-14 之前發的是 null';
comment on column public.member_coupons.grant_note is '發券時的備註（例：客訴補償、活動名稱），只有後台看得到';

-- ② 券清單
create or replace function public.admin_list_coupons_tx()
returns jsonb language plpgsql stable security definer set search_path to 'public' as $fn$
declare v_org uuid;
begin
  if not public.can('coupon.write') then
    return jsonb_build_object('ok', false, 'reason', 'forbidden', 'message', '沒有權限管理優惠券');
  end if;
  v_org := public.current_org_id();
  return jsonb_build_object('ok', true, 'rows', coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', c.id, 'name', c.name, 'discount_type', c.discount_type, 'discount_value', c.discount_value,
      'min_spend', c.min_spend, 'max_discount', c.max_discount,
      'free_product_id', c.free_product_id,
      'free_product_name', (select p.name from products p where p.id = c.free_product_id),
      'valid_days', c.valid_days, 'valid_until', c.valid_until, 'cost_bearer', c.cost_bearer,
      'is_active', c.is_active, 'created_at', c.created_at,
      'scope_label', public._coupon_scope_label(c.id),
      'scopes', coalesce((select jsonb_agg(jsonb_build_object('type', s.scope_type, 'value', s.scope_value) order by s.created_at)
                            from coupon_scopes s where s.coupon_id = c.id), '[]'::jsonb),
      'issued',  (select count(*) from member_coupons mc where mc.coupon_id = c.id),
      'used',    (select count(*) from member_coupons mc where mc.coupon_id = c.id and (mc.used_at is not null or mc.status = 'used')),
      'expired', (select count(*) from member_coupons mc where mc.coupon_id = c.id and mc.used_at is null and coalesce(mc.status, '') <> 'used'
                     and (mc.status = 'expired' or (mc.expires_at is not null and mc.expires_at <= now()))),
      'unused',  (select count(*) from member_coupons mc where mc.coupon_id = c.id and mc.used_at is null and coalesce(mc.status, 'active') = 'active'
                     and (mc.expires_at is null or mc.expires_at > now()))
    ) order by c.is_active desc, c.created_at desc)
    from coupons c where c.org_id = v_org and c.deleted_at is null), '[]'::jsonb));
end $fn$;
revoke execute on function public.admin_list_coupons_tx() from public, anon;
grant execute on function public.admin_list_coupons_tx() to authenticated;

-- ③ 新增／編輯
create or replace function public.admin_upsert_coupon_tx(
  p_id uuid, p_name text, p_discount_type text, p_discount_value numeric,
  p_free_product_id uuid, p_scopes jsonb, p_min_spend numeric, p_max_discount numeric,
  p_valid_days integer, p_valid_until date, p_cost_bearer text)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare
  v_org uuid; v_staff uuid; v_name text := nullif(btrim(coalesce(p_name, '')), '');
  v_scopes jsonb := coalesce(p_scopes, '[]'::jsonb); v_kind text; v_id uuid;
  v_old coupons%rowtype; v_issued bigint; v_old_scopes jsonb; v_new_scopes jsonb; s jsonb;
begin
  if not public.can('coupon.write') then
    return jsonb_build_object('ok', false, 'reason', 'forbidden', 'message', '沒有權限管理優惠券');
  end if;
  v_org := public.current_org_id();
  v_staff := (select staff_id from public.current_staff());

  if v_name is null or char_length(v_name) > 30 then
    return jsonb_build_object('ok', false, 'reason', 'bad_name', 'message', '券名要填，最多 30 個字');
  end if;
  if p_discount_type is null or p_discount_type not in ('percent', 'fixed', 'free') then
    return jsonb_build_object('ok', false, 'reason', 'bad_type', 'message', '折扣方式只能是 打折／折抵金額／免費');
  end if;
  if p_discount_type = 'percent' and (p_discount_value is null or p_discount_value <> trunc(p_discount_value) or p_discount_value < 1 or p_discount_value > 99) then
    return jsonb_build_object('ok', false, 'reason', 'bad_value', 'message', '打折請填 1～99 的整數（折抵幅度，例：9 折填 10）');
  end if;
  if p_discount_type = 'fixed' and (p_discount_value is null or p_discount_value <> trunc(p_discount_value) or p_discount_value < 1 or p_discount_value > 100000) then
    return jsonb_build_object('ok', false, 'reason', 'bad_value', 'message', '折抵金額請填 1～100000 的整數');
  end if;
  if p_discount_type <> 'free' and p_free_product_id is not null then
    return jsonb_build_object('ok', false, 'reason', 'bad_free', 'message', '只有「免費」的券可以指定免費商品');
  end if;
  if p_free_product_id is not null then
    if not exists (select 1 from products where id = p_free_product_id and org_id = v_org and deleted_at is null) then
      return jsonb_build_object('ok', false, 'reason', 'bad_product', 'message', '找不到這個商品');
    end if;
    if not exists (select 1 from products where id = p_free_product_id and discountable) then
      return jsonb_build_object('ok', false, 'reason', 'not_discountable', 'message', '這個商品不參與折扣（例如當日暢打），不能做成免費券');
    end if;
    if jsonb_array_length(v_scopes) > 0 then
      return jsonb_build_object('ok', false, 'reason', 'scope_with_free', 'message', '指定商品的免費券不用再選適用範圍');
    end if;
  end if;
  if jsonb_typeof(v_scopes) <> 'array' or jsonb_array_length(v_scopes) > 30 then
    return jsonb_build_object('ok', false, 'reason', 'bad_scopes', 'message', '適用範圍格式不對');
  end if;
  if p_min_spend is not null and (p_min_spend < 1 or p_min_spend <> trunc(p_min_spend)) then
    return jsonb_build_object('ok', false, 'reason', 'bad_min', 'message', '最低消費請填正整數，或留空');
  end if;
  if p_max_discount is not null and (p_discount_type <> 'percent' or p_max_discount < 1 or p_max_discount <> trunc(p_max_discount)) then
    return jsonb_build_object('ok', false, 'reason', 'bad_max', 'message', '折抵上限只用在打折的券，請填正整數或留空');
  end if;
  if p_valid_days is not null and (p_valid_days < 1 or p_valid_days > 3650) then
    return jsonb_build_object('ok', false, 'reason', 'bad_days', 'message', '有效天數請填 1～3650');
  end if;
  if p_valid_until is not null and p_id is null and p_valid_until < (now() at time zone 'Asia/Taipei')::date then
    return jsonb_build_object('ok', false, 'reason', 'bad_until', 'message', '到期日不能是過去的日子');
  end if;
  if coalesce(p_cost_bearer, '') not in ('store', 'hq') then
    return jsonb_build_object('ok', false, 'reason', 'bad_bearer', 'message', '成本要選 門市負擔 或 總部負擔');
  end if;

  -- 舊的分類欄位由適用範圍推出來（只剩會員 App 錢包拿來畫小字）：只有檯費 → 檯費券、只有餐飲 → 餐飲券、其他 → 會員券
  v_kind := case
    when p_free_product_id is null and jsonb_array_length(v_scopes) > 0
         and not exists (select 1 from jsonb_array_elements(v_scopes) x where not (x->>'type' = 'revenue_type' and x->>'value' = 'venue_fee'))
      then 'table_discount'
    when p_free_product_id is null and jsonb_array_length(v_scopes) > 0
         and not exists (select 1 from jsonb_array_elements(v_scopes) x where not (x->>'type' = 'revenue_type' and x->>'value' = 'fnb'))
      then 'fnb'
    else 'generic' end;
  -- 照固定順序排好，才能跟舊的比對「範圍有沒有改」
  select coalesce(jsonb_agg(x order by x->>'type', x->>'value'), '[]'::jsonb) into v_new_scopes
    from (select distinct jsonb_build_object('type', e->>'type', 'value', e->>'value') as x from jsonb_array_elements(v_scopes) e) y;

  if p_id is null then
    insert into coupons (org_id, name, kind, discount_type, discount_value, free_product_id, min_spend, max_discount,
                         valid_days, valid_until, cost_bearer, created_by, updated_by)
    values (v_org, v_name, v_kind, p_discount_type, case when p_discount_type = 'free' then null else p_discount_value end,
            p_free_product_id, p_min_spend, p_max_discount, p_valid_days, p_valid_until, p_cost_bearer, v_staff, v_staff)
    returning id into v_id;
  else
    select * into v_old from coupons where id = p_id and org_id = v_org and deleted_at is null for update;
    if not found then
      return jsonb_build_object('ok', false, 'reason', 'not_found', 'message', '找不到這張券');
    end if;
    v_issued := (select count(*) from member_coupons where coupon_id = p_id);
    select coalesce(jsonb_agg(jsonb_build_object('type', scope_type, 'value', scope_value) order by scope_type, scope_value), '[]'::jsonb)
      into v_old_scopes from coupon_scopes where coupon_id = p_id;
    if v_issued > 0 and (
         v_old.discount_type is distinct from p_discount_type
      or v_old.discount_value is distinct from (case when p_discount_type = 'free' then null else p_discount_value end)
      or v_old.free_product_id is distinct from p_free_product_id
      or v_old.min_spend is distinct from p_min_spend
      or v_old.max_discount is distinct from p_max_discount
      or v_old_scopes is distinct from v_new_scopes) then
      return jsonb_build_object('ok', false, 'reason', 'issued_locked',
        'message', '這張券已經發出 ' || v_issued || ' 張，不能再改折扣內容（沒用的那幾張會跟著變）。要改請停用這張、另建一張新的');
    end if;
    update coupons set name = v_name, kind = case when v_issued > 0 then kind else v_kind end,
           discount_type = p_discount_type,
           discount_value = case when p_discount_type = 'free' then null else p_discount_value end,
           free_product_id = p_free_product_id, min_spend = p_min_spend, max_discount = p_max_discount,
           valid_days = p_valid_days, valid_until = p_valid_until, cost_bearer = p_cost_bearer, updated_by = v_staff
     where id = p_id;
    v_id := p_id;
    if v_old_scopes is distinct from v_new_scopes then
      delete from coupon_scopes where coupon_id = p_id;
    end if;
  end if;

  if p_id is null or (select count(*) from coupon_scopes where coupon_id = v_id) = 0 then
    for s in select * from jsonb_array_elements(v_new_scopes) loop
      insert into coupon_scopes (org_id, coupon_id, scope_type, scope_value)
      values (v_org, v_id, s->>'type', s->>'value')
      on conflict (coupon_id, scope_type, scope_value) do nothing;
    end loop;
  end if;
  return jsonb_build_object('ok', true, 'id', v_id, 'created', p_id is null, 'scope_label', public._coupon_scope_label(v_id));
exception when others then
  -- 適用範圍的值寫錯時，觸發器 trg_coupon_scopes_check 會講是哪一個；原話回給後台，整筆不留
  return jsonb_build_object('ok', false, 'reason', 'save_failed', 'message', sqlerrm);
end $fn$;
revoke execute on function public.admin_upsert_coupon_tx(uuid, text, text, numeric, uuid, jsonb, numeric, numeric, integer, date, text) from public, anon;
grant execute on function public.admin_upsert_coupon_tx(uuid, text, text, numeric, uuid, jsonb, numeric, numeric, integer, date, text) to authenticated;

-- ④ 啟用／停用
create or replace function public.admin_set_coupon_active_tx(p_id uuid, p_active boolean)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
begin
  if not public.can('coupon.write') then
    return jsonb_build_object('ok', false, 'reason', 'forbidden', 'message', '沒有權限管理優惠券');
  end if;
  update coupons set is_active = coalesce(p_active, false), updated_by = (select staff_id from public.current_staff())
   where id = p_id and org_id = public.current_org_id() and deleted_at is null;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'not_found', 'message', '找不到這張券');
  end if;
  return jsonb_build_object('ok', true);
end $fn$;
revoke execute on function public.admin_set_coupon_active_tx(uuid, boolean) from public, anon;
grant execute on function public.admin_set_coupon_active_tx(uuid, boolean) to authenticated;

-- ⑤ 發券
create or replace function public.admin_grant_coupon_tx(p_coupon_id uuid, p_member_ids uuid[], p_qty integer, p_note text)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare
  v_org uuid; v_staff uuid; c coupons%rowtype; v_exp timestamptz; v_n int; v_ok int; v_qty int := coalesce(p_qty, 1);
begin
  if not public.can('coupon.write') then
    return jsonb_build_object('ok', false, 'reason', 'forbidden', 'message', '沒有權限發券');
  end if;
  v_org := public.current_org_id();
  v_staff := (select staff_id from public.current_staff());
  select * into c from coupons where id = p_coupon_id and org_id = v_org and deleted_at is null;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'not_found', 'message', '找不到這張券');
  end if;
  if not c.is_active then
    return jsonb_build_object('ok', false, 'reason', 'inactive', 'message', '這張券停用中，先啟用才能發');
  end if;
  v_n := coalesce(array_length(p_member_ids, 1), 0);
  if v_n = 0 or v_n > 200 then
    return jsonb_build_object('ok', false, 'reason', 'bad_members', 'message', '一次發給 1～200 位會員');
  end if;
  if v_qty < 1 or v_qty > 10 then
    return jsonb_build_object('ok', false, 'reason', 'bad_qty', 'message', '每人 1～10 張');
  end if;
  if p_note is not null and char_length(p_note) > 100 then
    return jsonb_build_object('ok', false, 'reason', 'bad_note', 'message', '備註最多 100 個字');
  end if;
  select count(*) into v_ok from members m
   where m.id = any(p_member_ids) and m.org_id = v_org and m.deleted_at is null and not m.is_bot;
  if v_ok <> (select count(distinct x) from unnest(p_member_ids) x) then
    return jsonb_build_object('ok', false, 'reason', 'bad_members', 'message', '名單裡有找不到的會員，請重新選一次');
  end if;
  -- 到期：發出後 N 天、到某一天（台北時間那天結束）兩個都有就取先到的；都沒有＝不限期限
  v_exp := nullif(least(
             coalesce(now() + make_interval(days => c.valid_days), 'infinity'::timestamptz),
             coalesce(((c.valid_until + 1)::timestamp at time zone 'Asia/Taipei'), 'infinity'::timestamptz)),
           'infinity'::timestamptz);
  if v_exp is not null and v_exp <= now() then
    return jsonb_build_object('ok', false, 'reason', 'already_expired', 'message', '這張券的到期日已經過了，發出去也不能用。先改到期日再發');
  end if;
  insert into member_coupons (org_id, member_id, coupon_id, status, expires_at, cost_bearer, granted_by_staff_id, grant_note)
  select v_org, m.id, c.id, 'active', v_exp, c.cost_bearer, v_staff, nullif(btrim(coalesce(p_note, '')), '')
    from (select distinct x as id from unnest(p_member_ids) x) m, generate_series(1, v_qty);
  return jsonb_build_object('ok', true, 'members', v_n, 'granted', v_n * v_qty, 'expires_at', v_exp);
end $fn$;
revoke execute on function public.admin_grant_coupon_tx(uuid, uuid[], integer, text) from public, anon;
grant execute on function public.admin_grant_coupon_tx(uuid, uuid[], integer, text) to authenticated;

-- ⑥ 發出去的券
create or replace function public.admin_list_member_coupons_tx(p_coupon_id uuid, p_status text, p_limit integer)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $fn$
declare v_org uuid; v_lim int := least(greatest(coalesce(p_limit, 200), 1), 500);
begin
  if not public.can('coupon.write') then
    return jsonb_build_object('ok', false, 'reason', 'forbidden', 'message', '沒有權限管理優惠券');
  end if;
  v_org := public.current_org_id();
  if not exists (select 1 from coupons where id = p_coupon_id and org_id = v_org) then
    return jsonb_build_object('ok', false, 'reason', 'not_found', 'message', '找不到這張券');
  end if;
  return jsonb_build_object('ok', true, 'rows', coalesce((
    select jsonb_agg(row_to_json(x)::jsonb order by x.granted_at desc) from (
      select mc.id, mc.code, mc.granted_at, mc.expires_at, mc.used_at, mc.grant_note,
             case when mc.used_at is not null or mc.status = 'used' then 'used'
                  when mc.status = 'expired' or (mc.expires_at is not null and mc.expires_at <= now()) then 'expired'
                  else 'unused' end as state,
             coalesce(h.display_name, m.display_name) as member_name, m.phone,
             (select s.name from staff s where s.id = mc.granted_by_staff_id) as granted_by,
             (select o.order_no from orders o where o.id = mc.used_order) as used_order_no
        from member_coupons mc
        join members m on m.id = mc.member_id
        left join member_hidden h on h.member_id = m.id
       where mc.coupon_id = p_coupon_id
         and (p_status is null or p_status = 'all'
              or p_status = case when mc.used_at is not null or mc.status = 'used' then 'used'
                                 when mc.status = 'expired' or (mc.expires_at is not null and mc.expires_at <= now()) then 'expired'
                                 else 'unused' end)
       order by mc.granted_at desc
       limit v_lim) x), '[]'::jsonb));
end $fn$;
revoke execute on function public.admin_list_member_coupons_tx(uuid, text, integer) from public, anon;
grant execute on function public.admin_list_member_coupons_tx(uuid, text, integer) to authenticated;

-- ── 驗證（單一 SELECT；不用 raise —— 那會回滾上面的 DDL，硬規則 1.8）──
select x.項目, x.結果 from (
  select 1 as n, '① 兩個稽核欄位都在' as 項目,
         case when (select count(*) from information_schema.columns where table_schema = 'public' and table_name = 'member_coupons'
                     and column_name in ('granted_by_staff_id', 'grant_note')) = 2 then '✅' else '🔴 少了' end as 結果
  union all
  select 2, '② 五支新函式都在、各一個版本',
         (select case when count(*) = 5 then '✅ 5 支' else '🔴 ' || count(*) || ' 支' end from pg_proc
           where pronamespace = 'public'::regnamespace and proname in
             ('admin_list_coupons_tx', 'admin_upsert_coupon_tx', 'admin_set_coupon_active_tx', 'admin_grant_coupon_tx', 'admin_list_member_coupons_tx'))
  union all
  select 3, '③ 授權：authenticated 叫得動、anon 叫不動',
         (select case when bool_and(has_function_privilege('authenticated', p.oid, 'EXECUTE'))
                       and not bool_or(has_function_privilege('anon', p.oid, 'EXECUTE')) then '✅' else '🔴 授權不對' end
            from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname in
             ('admin_list_coupons_tx', 'admin_upsert_coupon_tx', 'admin_set_coupon_active_tx', 'admin_grant_coupon_tx', 'admin_list_member_coupons_tx'))
  union all
  select 4, '④ 五支都有問權限（can 那一行真的在判斷）',
         (select case when count(*) = 5 then '✅ 5 支' else '🔴 只有 ' || count(*) || ' 支' end from pg_proc p
           where p.pronamespace = 'public'::regnamespace and p.prokind = 'f' and p.proname in
             ('admin_list_coupons_tx', 'admin_upsert_coupon_tx', 'admin_set_coupon_active_tx', 'admin_grant_coupon_tx', 'admin_list_member_coupons_tx')
             and pg_get_functiondef(p.oid) ~ 'if not public\.can\(''coupon\.write''\)')
  union all
  select 5, '⑤ 既有 7 張發出去的券沒被動到',
         (select case when count(*) = 7 then '✅ 7 張' else '⚠ ' || count(*) || ' 張（期望 7，有人另外發過就會不同）' end from member_coupons)
) x order by x.n;
