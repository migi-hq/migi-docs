/* ============================================================================
   2026-11-14 生日券：怎麼建、怎麼發、生日鎖住
   ----------------------------------------------------------------------------
   接在 2026-11-14_檯費優惠擇優與生日券計價.sql 之後（那一份讓生日券「能用」，這一份讓它「發得出去」）。

   使用者定案（2026-11-14，整合 POS 版本那一輪）：
     ③ 生日券先由總部手動發（後台「優惠券」→ 發券），生日鎖好再談自動
     ④ 效期是生日前後各 15 天（每個人都是 31 天，月底生日不吃虧）
     配套：每年一張、限本人、註冊滿 30 天而且來店消費過才發、生日填過就鎖

   這份做的事
     1. admin_upsert_coupon_tx：「免費」＋ 指定「當日暢打」＝ 生日券（kind = birthday）。
        其他不參與折扣的商品照舊不准做成免費券。生日券的效期由每個人的生日決定，
        後台填的「有效天數／到期日」不存。簽名不變。
     2. admin_grant_coupon_tx：發生日券時逐人算效期、逐人檢查資格，
        不符合的跳過並寫原因（skipped），符合的照發。簽名不變。
     3. set_my_birthday_tx（會員 App）：生日填過就不能自己改（同一天照回成功）
     4. 🆕 pos_set_member_birthday_tx：店員幫客人改生日，每一次都記在 member_birthday_changes
        （改了誰、從幾號改成幾號、哪位店員、什麼時候）。POS 畫面還沒做。
     5. admin_list_coupons_tx 多回 kind；admin_list_member_coupons_tx 多回 valid_from

   生日券的效期怎麼算（台北日期）
     生日 ＝ 今年的生日；今天已經過了「生日 ＋ 15 天」⇒ 改用明年的
     2/29 生日在平年當 2/28
     能用：生日 − 15 天 00:00 起　到期：生日 ＋ 15 天那天結束
     離「能用的第一天」還超過 60 天 ⇒ 不發（太早發的券會躺很久，客人也會忘）
   資格（任何一項不符就跳過）
     有填生日／註冊滿 30 天／來店過（有付款訂單，或在店裡坐過一場；好友練習賽不算）／
     那一年的生日券還沒發過（唯一索引擋，兩個人同時按也只會發一張）

   行為測試：sql/checks/2026-11-14_驗生日券發放與生日鎖.sql
   ============================================================================ */

-- ── 1. 改生日的紀錄 ────────────────────────────────────────────────────────
create table if not exists public.member_birthday_changes (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.orgs(id),
  member_id uuid not null references public.members(id),
  old_birthday date,
  new_birthday date not null,
  staff_id uuid references public.staff(id),
  created_at timestamptz not null default now()
);
comment on table public.member_birthday_changes is
  '店員替客人改生日的紀錄（2026-11-14）。客人自己第一次填不記 —— 那時 members.birthday 從 null 變成有值，本來就看得到';
alter table public.member_birthday_changes enable row level security;   -- 0 policy：只有後端函式進得去
create index if not exists idx_member_birthday_changes_member on public.member_birthday_changes (member_id, created_at desc);

-- ── 2. 建券：免費 ＋ 當日暢打 ＝ 生日券 ────────────────────────────────────
create or replace function public.admin_upsert_coupon_tx(p_id uuid, p_name text, p_discount_type text, p_discount_value numeric, p_free_product_id uuid, p_scopes jsonb, p_min_spend numeric, p_max_discount numeric, p_valid_days integer, p_valid_until date, p_cost_bearer text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_org uuid; v_staff uuid; v_name text := nullif(btrim(coalesce(p_name, '')), '');
  v_scopes jsonb := coalesce(p_scopes, '[]'::jsonb); v_kind text; v_id uuid;
  v_old coupons%rowtype; v_issued bigint; v_old_scopes jsonb; v_new_scopes jsonb; s jsonb;
  v_bday boolean := false;   -- 🆕 2026-11-14：免費 ＋ 指定當日暢打 ＝ 生日券
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
    v_bday := exists (select 1 from products where id = p_free_product_id and sku = 'SVC-TBL-DAY');
    if not v_bday and not exists (select 1 from products where id = p_free_product_id and discountable) then
      return jsonb_build_object('ok', false, 'reason', 'not_discountable', 'message', '這個商品不參與折扣，不能做成免費券（當日暢打例外：那是生日券）');
    end if;
    if jsonb_array_length(v_scopes) > 0 then
      return jsonb_build_object('ok', false, 'reason', 'scope_with_free', 'message', '指定商品的免費券不用再選適用範圍');
    end if;
  end if;
  if v_bday and (p_min_spend is not null or p_max_discount is not null) then
    return jsonb_build_object('ok', false, 'reason', 'bad_birthday', 'message', '生日券不用填最低消費與折抵上限');
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
  -- 生日券的效期由每個人的生日算，後台填的有效天數、到期日不存（也不檢查）
  if v_bday then p_valid_days := null; p_valid_until := null; end if;
  if p_valid_days is not null and (p_valid_days < 1 or p_valid_days > 3650) then
    return jsonb_build_object('ok', false, 'reason', 'bad_days', 'message', '有效天數請填 1～3650');
  end if;
  if p_valid_until is not null and p_id is null and p_valid_until < (now() at time zone 'Asia/Taipei')::date then
    return jsonb_build_object('ok', false, 'reason', 'bad_until', 'message', '到期日不能是過去的日子');
  end if;
  if coalesce(p_cost_bearer, '') not in ('store', 'hq') then
    return jsonb_build_object('ok', false, 'reason', 'bad_bearer', 'message', '成本要選 門市負擔 或 總部負擔');
  end if;

  -- 分類由內容推：生日券 → birthday；只有檯費 → 檯費券；只有餐飲 → 餐飲券；其他 → 會員券
  v_kind := case
    when v_bday then 'birthday'
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
  return jsonb_build_object('ok', true, 'id', v_id, 'created', p_id is null, 'kind', v_kind,
                            'scope_label', public._coupon_scope_label(v_id));
exception when others then
  -- 適用範圍的值寫錯時，觸發器 trg_coupon_scopes_check 會講是哪一個；原話回給後台，整筆不留
  return jsonb_build_object('ok', false, 'reason', 'save_failed', 'message', sqlerrm);
end $function$;

-- ── 3. 發券：生日券逐人算效期、逐人檢查資格 ──────────────────────────────
create or replace function public.admin_grant_coupon_tx(p_coupon_id uuid, p_member_ids uuid[], p_qty integer, p_note text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_org uuid; v_staff uuid; c coupons%rowtype; v_exp timestamptz; v_n int; v_ok int; v_qty int := coalesce(p_qty, 1);
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
  -- 生日券用
  v_today date := (now() at time zone 'Asia/Taipei')::date;
  m record; v_y int; v_b date; v_from date; v_ins int; v_granted int := 0; v_skipped jsonb := '[]'::jsonb;
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

  /* 🆕 2026-11-14 生日券：每個人的效期不一樣，資格也逐人看；不符合的跳過並寫原因，其他人照發 */
  if c.kind = 'birthday' then
    if v_qty <> 1 then
      return jsonb_build_object('ok', false, 'reason', 'bad_qty', 'message', '生日券每人每年一張');
    end if;
    for m in
      select mm.id, mm.display_name, mm.birthday, mm.created_at
        from members mm where mm.id in (select distinct x from unnest(p_member_ids) x)
       order by mm.display_name
    loop
      if m.birthday is null then
        v_skipped := v_skipped || jsonb_build_array(jsonb_build_object('member_id', m.id, 'name', m.display_name, 'reason', 'no_birthday', 'message', '還沒填生日'));
        continue;
      end if;
      if m.created_at > now() - interval '30 days' then
        v_skipped := v_skipped || jsonb_build_array(jsonb_build_object('member_id', m.id, 'name', m.display_name, 'reason', 'too_new', 'message', '註冊還沒滿 30 天'));
        continue;
      end if;
      if not exists (select 1 from orders o where o.member_id = m.id and o.status = 'paid')
         and not exists (select 1 from session_players sp join table_sessions ts on ts.id = sp.session_id
                          where sp.member_id = m.id and ts.status <> 'voided' and ts.mode is distinct from 'friendly') then
        v_skipped := v_skipped || jsonb_build_array(jsonb_build_object('member_id', m.id, 'name', m.display_name, 'reason', 'no_visit', 'message', '還沒來店消費過'));
        continue;
      end if;
      -- 今年的生日；已經過了生日 ＋ 15 天就看明年的。2/29 在平年當 2/28
      v_y := extract(year from v_today)::int;
      v_b := make_date(v_y, extract(month from m.birthday)::int,
               case when extract(month from m.birthday) = 2 and extract(day from m.birthday) = 29
                         and not ((v_y % 4 = 0 and v_y % 100 <> 0) or v_y % 400 = 0) then 28
                    else extract(day from m.birthday)::int end);
      if v_today > v_b + 15 then
        v_y := v_y + 1;
        v_b := make_date(v_y, extract(month from m.birthday)::int,
                 case when extract(month from m.birthday) = 2 and extract(day from m.birthday) = 29
                           and not ((v_y % 4 = 0 and v_y % 100 <> 0) or v_y % 400 = 0) then 28
                      else extract(day from m.birthday)::int end);
      end if;
      v_from := v_b - 15;
      if v_from > v_today + 60 then
        v_skipped := v_skipped || jsonb_build_array(jsonb_build_object('member_id', m.id, 'name', m.display_name, 'reason', 'too_early',
          'message', '生日 ' || to_char(v_b, 'FMMM/FMDD') || '，' || to_char(v_from - 60, 'FMMM/FMDD') || ' 起才能發'));
        continue;
      end if;
      insert into member_coupons (org_id, member_id, coupon_id, status, valid_from, expires_at, birthday_year,
                                  cost_bearer, granted_by_staff_id, grant_note)
      values (v_org, m.id, c.id, 'active',
              v_from::timestamp at time zone 'Asia/Taipei', (v_b + 16)::timestamp at time zone 'Asia/Taipei', v_y,
              c.cost_bearer, v_staff, v_note)
      on conflict (member_id, birthday_year) where birthday_year is not null do nothing;
      get diagnostics v_ins = row_count;
      if v_ins = 0 then
        v_skipped := v_skipped || jsonb_build_array(jsonb_build_object('member_id', m.id, 'name', m.display_name, 'reason', 'already',
          'message', v_y || ' 年的生日券已經發過'));
      else
        v_granted := v_granted + 1;
      end if;
    end loop;
    return jsonb_build_object('ok', true, 'members', v_n, 'granted', v_granted, 'skipped', v_skipped, 'birthday', true);
  end if;

  -- 一般券：到期是發出後 N 天、到某一天（台北時間那天結束）兩個都有就取先到的；都沒有＝不限期限
  v_exp := nullif(least(
             coalesce(now() + make_interval(days => c.valid_days), 'infinity'::timestamptz),
             coalesce(((c.valid_until + 1)::timestamp at time zone 'Asia/Taipei'), 'infinity'::timestamptz)),
           'infinity'::timestamptz);
  if v_exp is not null and v_exp <= now() then
    return jsonb_build_object('ok', false, 'reason', 'already_expired', 'message', '這張券的到期日已經過了，發出去也不能用。先改到期日再發');
  end if;
  insert into member_coupons (org_id, member_id, coupon_id, status, expires_at, cost_bearer, granted_by_staff_id, grant_note)
  select v_org, m2.id, c.id, 'active', v_exp, c.cost_bearer, v_staff, v_note
    from (select distinct x as id from unnest(p_member_ids) x) m2, generate_series(1, v_qty);
  return jsonb_build_object('ok', true, 'members', v_n, 'granted', v_n * v_qty, 'expires_at', v_exp, 'skipped', '[]'::jsonb);
end $function$;

-- ── 4. 會員 App：生日填過就不能自己改 ─────────────────────────────────────
create or replace function public.set_my_birthday_tx(p_org_id uuid, p_member_id uuid, p_birthday date)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare v_n int; v_old date;
begin
  /* 🔴 身分一律從 JWT 取，不採信呼叫端（2026-09-05，待辦 14）。
     ⚠ 呼叫端照樣送 p_member_id，函式忽略它（簽名不變，前端不用改）。 */
  p_member_id := public.current_member_id();
  if p_member_id is null then raise exception '未登入或登入已過期，請重新開啟 App' using errcode = '28000'; end if;
  if p_birthday is null then
    return jsonb_build_object('ok', false, 'reason', 'birthday_required', 'message', '請選擇生日');
  end if;

  /* 合理範圍。不做年齡限制 —— 那是營運政策不是資料規則。
     ⚠ 用 current_date 不用 now()：生日是日期不是時間點。 */
  if p_birthday > current_date then
    return jsonb_build_object('ok', false, 'reason', 'birthday_in_future', 'message', '生日不能是未來的日期');
  end if;
  if p_birthday < date '1900-01-01' then
    return jsonb_build_object('ok', false, 'reason', 'birthday_too_old', 'message', '請確認生日年份');
  end if;

  select birthday into v_old from members where id = p_member_id and org_id = p_org_id and deleted_at is null;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'member_not_found', 'message', '找不到這位會員');
  end if;

  /* 🆕 2026-11-14 生日填過就鎖住：生日券每年一張，可以自己改生日就能一直換日子領。
     填錯的話到櫃檯請店員改（pos_set_member_birthday_tx，會留紀錄）。同一天照回成功。 */
  if v_old is not null then
    if v_old = p_birthday then
      return jsonb_build_object('ok', true, 'birthday', p_birthday);
    end if;
    return jsonb_build_object('ok', false, 'reason', 'birthday_locked',
      'message', '生日填好就不能自己改了；填錯的話請到櫃檯請店員幫忙');
  end if;

  update members set birthday = p_birthday, updated_at = now()
   where id = p_member_id and org_id = p_org_id and deleted_at is null and birthday is null;
  -- ★ 看 FOUND，不要無條件回報成功（register_member_tx 曾經這樣謊報）
  get diagnostics v_n = row_count;
  if v_n = 0 then
    return jsonb_build_object('ok', false, 'reason', 'birthday_locked',
      'message', '生日填好就不能自己改了；填錯的話請到櫃檯請店員幫忙');
  end if;
  return jsonb_build_object('ok', true, 'birthday', p_birthday);
end $function$;

-- ── 5. 店員幫客人改生日（留紀錄）──────────────────────────────────────────
create or replace function public.pos_set_member_birthday_tx(p_member_id uuid, p_birthday date)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare v_staff uuid; v_org uuid; v_old date;
begin
  /* 身分從登入取：一定要是店員；會員與前端說的「我是誰」都不算 */
  v_staff := (select staff_id from public.current_staff());   -- ⚠ current_staff() 沒有機構欄位，機構另外取
  v_org := public.current_org_id();
  if v_staff is null or v_org is null then
    return jsonb_build_object('ok', false, 'reason', 'not_staff', 'message', '只有店員可以改客人的生日');
  end if;
  if p_birthday is null then
    return jsonb_build_object('ok', false, 'reason', 'birthday_required', 'message', '請選擇生日');
  end if;
  if p_birthday > (now() at time zone 'Asia/Taipei')::date then
    return jsonb_build_object('ok', false, 'reason', 'birthday_in_future', 'message', '生日不能是未來的日期');
  end if;
  if p_birthday < date '1900-01-01' then
    return jsonb_build_object('ok', false, 'reason', 'birthday_too_old', 'message', '請確認生日年份');
  end if;
  select birthday into v_old from members where id = p_member_id and org_id = v_org and deleted_at is null for update;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'member_not_found', 'message', '找不到這位會員');
  end if;
  if v_old = p_birthday then
    return jsonb_build_object('ok', true, 'birthday', p_birthday, 'changed', false);
  end if;
  update members set birthday = p_birthday, updated_at = now() where id = p_member_id;
  insert into member_birthday_changes (org_id, member_id, old_birthday, new_birthday, staff_id)
  values (v_org, p_member_id, v_old, p_birthday, v_staff);
  return jsonb_build_object('ok', true, 'birthday', p_birthday, 'old_birthday', v_old, 'changed', true);
end $function$;
grant execute on function public.pos_set_member_birthday_tx(uuid, date) to authenticated;

-- ── 6. 後台清單多回 kind／valid_from（只加欄位，其餘一字不動）────────────
do $$
declare v_def text;
begin
  v_def := pg_get_functiondef('public.admin_list_coupons_tx()'::regprocedure);
  if (length(v_def) - length(replace(v_def, '''is_active'', c.is_active,', ''))) / length('''is_active'', c.is_active,') <> 1 then
    raise exception 'admin_list_coupons_tx：找不到唯一一處，整份不跑（線上版本跟預期不同）';
  end if;
  execute replace(v_def, '''is_active'', c.is_active,', '''is_active'', c.is_active, ''kind'', c.kind,');

  v_def := pg_get_functiondef('public.admin_list_member_coupons_tx(uuid,text,integer)'::regprocedure);
  if (length(v_def) - length(replace(v_def, 'mc.expires_at, mc.used_at', ''))) / length('mc.expires_at, mc.used_at') <> 1 then
    raise exception 'admin_list_member_coupons_tx：找不到唯一一處，整份不跑（線上版本跟預期不同）';
  end if;
  execute replace(v_def, 'mc.expires_at, mc.used_at', 'mc.expires_at, mc.valid_from, mc.used_at');
end $$;

-- ── 驗證（單一 SELECT，不 raise；行為在 checks 那一份）─────────────────────
select
  (select case when count(*) = 5 then '✅' else '🔴' end || ' ① 五支函式各一個版本（' || count(*) || '/5）'
     from pg_proc where pronamespace = 'public'::regnamespace
      and proname in ('admin_upsert_coupon_tx','admin_grant_coupon_tx','set_my_birthday_tx','pos_set_member_birthday_tx','admin_list_coupons_tx')) || E'\n' ||
  (select case when count(*) = 4 then '✅' else '🔴' end || ' ② 新版內容都在（' || count(*) || '/4：建券認得生日券、發券逐人算、生日鎖、店員改生日留紀錄）'
     from pg_proc p where p.pronamespace = 'public'::regnamespace and (
          (p.proname = 'admin_upsert_coupon_tx' and pg_get_functiondef(p.oid) like '%v_bday%')
       or (p.proname = 'admin_grant_coupon_tx'  and pg_get_functiondef(p.oid) like '%birthday_year%')
       or (p.proname = 'set_my_birthday_tx'     and pg_get_functiondef(p.oid) like '%birthday_locked%')
       or (p.proname = 'pos_set_member_birthday_tx' and pg_get_functiondef(p.oid) like '%member_birthday_changes%'))) || E'\n' ||
  (select case when count(*) = 2 then '✅' else '🔴' end || ' ③ 後台兩支清單多回 kind／valid_from（' || count(*) || '/2）'
     from pg_proc p where p.pronamespace = 'public'::regnamespace and (
          (p.proname = 'admin_list_coupons_tx' and pg_get_functiondef(p.oid) like '%''kind'', c.kind%')
       or (p.proname = 'admin_list_member_coupons_tx' and pg_get_functiondef(p.oid) like '%mc.valid_from%'))) || E'\n' ||
  (select case when relrowsecurity and not exists (select 1 from pg_policies where tablename = 'member_birthday_changes')
               then '✅' else '🔴' end || ' ④ 改生日紀錄表開了 RLS、0 policy（只有後端進得去）'
     from pg_class where oid = 'public.member_birthday_changes'::regclass) || E'\n' ||
  (select case when has_function_privilege('authenticated', 'public.pos_set_member_birthday_tx(uuid,date)', 'execute')
                and not has_function_privilege('anon', 'public.pos_set_member_birthday_tx(uuid,date)', 'execute')
                and has_function_privilege('authenticated', 'public.admin_grant_coupon_tx(uuid,uuid[],integer,text)', 'execute')
                and has_function_privilege('authenticated', 'public.set_my_birthday_tx(uuid,uuid,date)', 'execute')
               then '✅' else '🔴' end || ' ⑤ 授權：店員改生日只給登入的人；後台發券、App 填生日照樣叫得到')
  as "驗證";
