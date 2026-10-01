/* ============================================================
   包桌續時（收桌第二版）· 2026-10-01 · MIGI 咪吉麻將
   📄 規則來源：使用者 2026-10-01 拍板（見 docs/02-POS與開桌/包桌續時.md）

   ── 規則 ────────────────────────────────────────────────
   開始計時   智慧計分板「定好座位」那一刻 ＝ 第一將建立的時間（session_rounds.started_at）
   到期前 30 分鐘   計分板跳出提示：要續打請到櫃檯補檯費
   到期後 15 分鐘   還沒補完 ⇒ 計分板鎖定（後端擋送出新的一局、擋開新的一將）
   補多少     升到下一檔：2 小時 → 5 小時、5 小時 → 24 小時（24 小時封頂）
   誰付       各付各的：代付的由代付人補；入座時因當日暢打免收的人不用補
   解鎖       要付的人**全部**補完才算升檔（每一局本來就要四台都確認）

   ── 做法 ────────────────────────────────────────────────
   · 兩支「延長」商品，價格＝兩檔包桌檯費的差額，由觸發器自動跟著包桌檯費變（不會漂）
       SVC-TBL-PX05  包桌延長 · 2–5 小時      ＝ P05 − P02
       SVC-TBL-PX24  包桌延長 · 5 小時以上     ＝ P24 − P05
   · 「現在買到哪一檔」**不另外存**：每次從已付款的延長訂單算出來（唯一的事實來源是 orders）
     ⚠ 桌邊訂單的 session_id 是包裝函式事後回填的，所以不能用觸發器在下單那一刻升檔
   · _pkg_time(場次) 是**唯一一份**計時定義：計分板狀態、送出一局、開新一將、POS 桌況、收款全部問它
   · 收款走既有的加購結帳（pos_addon_checkout_tx → checkout_tx），**份數由後端算**，前端只送「誰要付」

   ⚠ 美麻桌：計分板目前只支援台麻 ⇒ 不會有「定好座位」⇒ 不計時（使用者 2026-10-01：全部桌都會有計分板）
   ⚠ 已知取捨：替別人代付、自己卻已經離座的人，加購結帳會擋 not_seated（要先請他回座位或由店員處理）
   ============================================================ */

-- ① 兩支延長商品（每個有包桌檯費的機構各一組；重跑不重複建）
insert into public.products (org_id, sku, name, category, subcategory, revenue_type,
                             unit_price, discountable, is_active, is_available, is_system,
                             tracks_stock, stock_qty, unit_cost)
select p05.org_id, x.sku, x.name, 'service', 'TBL', 'venue_fee',
       x.price, true, true, true, true, false, 0, 0
  from public.products p05
  join public.products p02 on p02.org_id = p05.org_id and p02.sku = 'SVC-TBL-P02' and p02.deleted_at is null
  join public.products p24 on p24.org_id = p05.org_id and p24.sku = 'SVC-TBL-P24' and p24.deleted_at is null
  cross join lateral (values
    ('SVC-TBL-PX05', '包桌延長 · 2–5 小時',  p05.unit_price - p02.unit_price),
    ('SVC-TBL-PX24', '包桌延長 · 5 小時以上', p24.unit_price - p05.unit_price)) as x(sku, name, price)
 where p05.sku = 'SVC-TBL-P05' and p05.deleted_at is null
   and not exists (select 1 from public.products e
                    where e.org_id = p05.org_id and e.sku = x.sku and e.deleted_at is null);

-- ② 延長商品的價格只能是差額：包桌檯費改價時自動跟著改，直接改延長商品的價格會被擋
create or replace function public._pkg_ext_expected(p_org uuid, p_sku text)
returns bigint language sql stable security definer set search_path to 'public' as $$
  select case p_sku
           when 'SVC-TBL-PX05' then
             (select unit_price from products where org_id = p_org and sku = 'SVC-TBL-P05' and deleted_at is null)
           - (select unit_price from products where org_id = p_org and sku = 'SVC-TBL-P02' and deleted_at is null)
           when 'SVC-TBL-PX24' then
             (select unit_price from products where org_id = p_org and sku = 'SVC-TBL-P24' and deleted_at is null)
           - (select unit_price from products where org_id = p_org and sku = 'SVC-TBL-P05' and deleted_at is null)
         end
$$;

create or replace function public._pkg_ext_guard()
returns trigger language plpgsql security definer set search_path to 'public' as $$
declare v_exp bigint;
begin
  v_exp := public._pkg_ext_expected(new.org_id, new.sku);
  if v_exp is not null and new.unit_price <> v_exp then
    raise exception '包桌延長的價格由包桌檯費自動算（應為 %），請改包桌檯費', v_exp
      using errcode = '23514';
  end if;
  return new;
end $$;

create or replace function public._pkg_tier_sync()
returns trigger language plpgsql security definer set search_path to 'public' as $$
begin
  update products p
     set unit_price = public._pkg_ext_expected(p.org_id, p.sku), updated_at = now()
   where p.org_id = new.org_id and p.deleted_at is null
     and p.sku in ('SVC-TBL-PX05', 'SVC-TBL-PX24')
     and p.unit_price is distinct from public._pkg_ext_expected(p.org_id, p.sku);
  return null;
end $$;

drop trigger if exists trg_products_pkg_ext_guard on public.products;
create trigger trg_products_pkg_ext_guard
  before insert or update of unit_price on public.products
  for each row when (new.sku in ('SVC-TBL-PX05', 'SVC-TBL-PX24'))
  execute function public._pkg_ext_guard();

drop trigger if exists trg_products_pkg_tier_sync on public.products;
create trigger trg_products_pkg_tier_sync
  after update of unit_price on public.products
  for each row when (new.sku in ('SVC-TBL-P02', 'SVC-TBL-P05', 'SVC-TBL-P24'))
  execute function public._pkg_tier_sync();

-- ③ 這一場誰要付幾份延長：付款人 ＝ 代付人或自己；入座時因暢打免收的不算；已離座的不算
create or replace function public._pkg_shares(p_session_id uuid)
returns table (payer uuid, shares int)
language sql stable security definer set search_path to 'public' as $$
  select coalesce(sp.paid_by, sp.member_id) as payer, count(*)::int as shares
    from session_players sp
   where sp.session_id = p_session_id
     and sp.member_id is not null
     and sp.left_at is null
     and coalesce(sp.fee_waived_reason, '') <> 'daypass'
   group by 1
$$;

-- ④ 唯一一份計時定義
create or replace function public._pkg_time(p_session_id uuid, p_with_ids boolean default true)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare
  s        public.table_sessions;
  v_base   int; v_eff int; v_next int; v_sku text; v_ok boolean;
  v_start  timestamptz; v_exp timestamptz; v_phase text; v_payers jsonb;
  c_warn   constant interval := interval '30 minutes';
  c_grace  constant interval := interval '15 minutes';
begin
  select * into s from table_sessions where id = p_session_id and deleted_at is null;
  if s.id is null or s.mode <> 'private' then return null; end if;
  if s.status <> 'open' then return jsonb_build_object('phase', 'closed'); end if;

  v_base := case when coalesce(s.planned_minutes, 0) <= 120 then 120
                 when s.planned_minutes <= 300 then 300 else 1440 end;

  -- 已經補完的延長段：每一段都要「所有該付的份數」付清才算升檔
  v_eff := v_base;
  while v_eff < 1440 loop
    v_next := case v_eff when 120 then 300 else 1440 end;
    v_sku  := case v_next when 300 then 'SVC-TBL-PX05' else 'SVC-TBL-PX24' end;
    select coalesce(bool_and(coalesce(pd.qty, 0) >= sh.shares), true) into v_ok
      from public._pkg_shares(s.id) sh
      left join lateral (
        select sum(oi.qty) as qty
          from orders o
          join order_items oi on oi.order_id = o.id
          join products p     on p.id = oi.product_id
         where o.session_id = s.id and o.status = 'paid'
           and o.member_id = sh.payer and p.sku = v_sku) pd on true;
    exit when not v_ok;
    v_eff := v_next;
  end loop;

  if v_eff >= 1440 then
    v_next := null; v_sku := null;
  else
    v_next := case v_eff when 120 then 300 else 1440 end;
    v_sku  := case v_next when 300 then 'SVC-TBL-PX05' else 'SVC-TBL-PX24' end;
    select jsonb_agg(jsonb_build_object(
             'name',   coalesce(m.display_name, '會員'),
             'shares', sh.shares,
             'paid',   least(coalesce(pd.qty, 0), sh.shares),
             'owed',   greatest(sh.shares - coalesce(pd.qty, 0), 0))
           || case when p_with_ids then jsonb_build_object('member_id', sh.payer) else '{}'::jsonb end
           order by greatest(sh.shares - coalesce(pd.qty, 0), 0) desc, m.display_name)
      into v_payers
      from public._pkg_shares(s.id) sh
      left join members m on m.id = sh.payer
      left join lateral (
        select sum(oi.qty)::int as qty
          from orders o
          join order_items oi on oi.order_id = o.id
          join products p     on p.id = oi.product_id
         where o.session_id = s.id and o.status = 'paid'
           and o.member_id = sh.payer and p.sku = v_sku) pd on true;
  end if;

  select min(r.started_at) into v_start
    from session_rounds r where r.session_id = s.id and r.status <> 'voided';

  if v_eff >= 1440 then
    v_phase := 'capped';
  elsif v_start is null then
    v_phase := 'not_started';
  else
    v_exp := v_start + make_interval(mins => v_eff);
    v_phase := case when now() <  v_exp - c_warn  then 'ok'
                    when now() <  v_exp           then 'warn'
                    when now() <  v_exp + c_grace then 'grace'
                    else 'locked' end;
  end if;

  return jsonb_build_object(
    'phase',        v_phase,
    'locked',       v_phase = 'locked',
    'now',          now(),
    'started_at',   v_start,
    'base_minutes', v_base,
    'tier_minutes', v_eff,
    'expires_at',   v_exp,
    'warn_at',      v_exp - c_warn,
    'lock_at',      v_exp + c_grace,
    'next_minutes', v_next,
    'next_sku',     v_sku,
    'payers',       coalesce(v_payers, '[]'::jsonb),
    'owed_shares',  coalesce((select sum((e ->> 'owed')::int) from jsonb_array_elements(v_payers) e), 0));
end $$;

-- ⑤ POS：某位付款人這一次要補多少（份數由後端算，金額走唯一的計價核心，等級折扣一致）
create or replace function public.pos_pkg_quote_tx(p_session_id uuid, p_member_id uuid)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_pkg jsonb; v_owed int; v_pid uuid; v_org uuid; v_items jsonb; v_price jsonb;
begin
  perform public._api_staff_only();
  v_pkg := public._pkg_time(p_session_id, true);
  if v_pkg is null then
    return jsonb_build_object('ok', false, 'reason', 'not_private', 'message', '這一場不是包桌');
  end if;
  if v_pkg ->> 'phase' = 'closed' then
    return jsonb_build_object('ok', false, 'reason', 'session_closed', 'message', '這一場已經收桌');
  end if;
  if v_pkg ->> 'phase' = 'capped' then
    return jsonb_build_object('ok', false, 'reason', 'capped', 'message', '已經是最高時數，不用再補');
  end if;

  select (e ->> 'owed')::int into v_owed
    from jsonb_array_elements(v_pkg -> 'payers') e
   where (e ->> 'member_id')::uuid = p_member_id;
  if coalesce(v_owed, 0) <= 0 then
    return jsonb_build_object('ok', false, 'reason', 'nothing_owed', 'message', '這位客人不用補檯費',
                              'pkg', v_pkg);
  end if;

  select org_id into v_org from table_sessions where id = p_session_id;
  select id into v_pid from products
   where org_id = v_org and sku = v_pkg ->> 'next_sku' and deleted_at is null limit 1;
  if v_pid is null then
    return jsonb_build_object('ok', false, 'reason', 'product_not_found', 'message', '找不到包桌延長商品');
  end if;

  v_items := jsonb_build_array(jsonb_build_object('product_id', v_pid, 'qty', v_owed));
  v_price := public._cart_pricing(v_org, p_member_id, v_items, null);
  return jsonb_build_object('ok', true, 'owed', v_owed, 'next_minutes', (v_pkg ->> 'next_minutes')::int,
    'items', v_items, 'amount', (v_price ->> 'payable')::bigint, 'pricing', v_price, 'pkg', v_pkg);
end $$;

-- ⑥ POS：收這位付款人的延長檯費（走既有加購結帳；冪等鍵沿用 checkout_tx 的）
create or replace function public.pos_pkg_extend_tx(p_session_id uuid, p_member_id uuid,
  p_points_used bigint default 0, p_payments jsonb default null, p_idempotency_key text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_q jsonb; v_res jsonb;
begin
  perform public._api_staff_only();
  v_q := public.pos_pkg_quote_tx(p_session_id, p_member_id);
  if not coalesce((v_q ->> 'ok')::boolean, false) then return v_q; end if;

  v_res := public.pos_addon_checkout_tx(p_session_id, p_member_id, v_q -> 'items', null,
             coalesce(p_points_used, 0), p_payments, p_idempotency_key, null);
  if not coalesce((v_res ->> 'ok')::boolean, false) then return v_res; end if;

  perform public._tbl_ping(p_session_id);   -- 讓計分板馬上重新拿狀態（提示消失、解鎖）
  return v_res || jsonb_build_object('pkg', public._pkg_time(p_session_id, true));
end $$;

-- ⑦ 把計時接進既有函式（錨點必須剛好出現一次；已經接過就跳過，可重跑）
create or replace function pg_temp.patch(p_fn regprocedure, p_marker text, p_anchor text, p_new text)
returns text language plpgsql as $$
declare v_def text; v_n int;
begin
  v_def := pg_get_functiondef(p_fn);
  if position(p_marker in v_def) > 0 then return p_fn::text || ' 已經接過'; end if;
  v_n := (length(v_def) - length(replace(v_def, p_anchor, ''))) / length(p_anchor);
  if v_n <> 1 then
    raise exception '% 的錨點出現 % 次（要剛好 1 次），整份不執行', p_fn, v_n;
  end if;
  execute replace(v_def, p_anchor, p_new);
  return p_fn::text || ' 已接上';
end $$;

select pg_temp.patch('public.tbl_submit_hand_tx(text,text,smallint,jsonb)'::regprocedure,
  'pkg_locked',
  $a$  if coalesce(s.game_type, '台麻') <> '台麻' then$a$,
  $b$  /* ⏰ 包桌續時（2026-10-01）：到期後 15 分鐘還沒補完檯費就不能再記分，要先到櫃檯補 */
  if (public._pkg_time(s.id, false) ->> 'phase') = 'locked' then
    return jsonb_build_object('ok', false, 'reason', 'pkg_locked', 'message', '包桌時間已到，請到櫃檯補檯費');
  end if;
  if coalesce(s.game_type, '台麻') <> '台麻' then$b$);

select pg_temp.patch('public.tbl_start_round_tx(text,smallint,smallint,smallint)'::regprocedure,
  'pkg_locked',
  $a$  if p_dealer_seat not between 1 and 4 then$a$,
  $b$  /* ⏰ 包桌續時（2026-10-01）：鎖定時也不能開新的一將 */
  if (public._pkg_time(s.id, false) ->> 'phase') = 'locked' then
    return jsonb_build_object('ok', false, 'reason', 'pkg_locked', 'message', '包桌時間已到，請到櫃檯補檯費');
  end if;
  if p_dealer_seat not between 1 and 4 then$b$);

select pg_temp.patch('public.tbl_state_tx(text)'::regprocedure,
  '''pkg'', public._pkg_time',
  $a$'rating_delta', (select jsonb_object_agg$a$,
  $b$'pkg', public._pkg_time(s.id, false),   /* ⏰ 包桌續時（2026-10-01）：不含會員 id */
    'rating_delta', (select jsonb_object_agg$b$);

select pg_temp.patch('public.list_tables_tx(uuid,uuid)'::regprocedure,
  'pkg_phase',
  $a$'mode', ts.mode,$a$,
  $b$'mode', ts.mode,
      'pkg_phase', (public._pkg_time(ts.id, false) ->> 'phase'),   /* ⏰ 包桌續時（2026-10-01） */$b$);

-- ⑧ 授權：內部函式前端叫不到；POS 的兩支只給登入的人
revoke execute on function public._pkg_ext_expected(uuid, text) from public, anon, authenticated;
revoke execute on function public._pkg_ext_guard()             from public, anon, authenticated;
revoke execute on function public._pkg_tier_sync()             from public, anon, authenticated;
revoke execute on function public._pkg_shares(uuid)            from public, anon, authenticated;
revoke execute on function public._pkg_time(uuid, boolean)     from public, anon, authenticated;
revoke execute on function public.pos_pkg_quote_tx(uuid, uuid) from public, anon;
revoke execute on function public.pos_pkg_extend_tx(uuid, uuid, bigint, jsonb, text) from public, anon;
grant  execute on function public.pos_pkg_quote_tx(uuid, uuid) to authenticated;
grant  execute on function public.pos_pkg_extend_tx(uuid, uuid, bigint, jsonb, text) to authenticated;

-- ⑨ 驗證（只讀狀態、不寫東西，不用 raise —— 硬規則 1.8）
do $$
declare
  v_msg text := ''; v_ok boolean; v_n int; v_s text;
  fn_anon boolean; fn_auth boolean;
begin
  -- ① 兩支延長商品存在，價格＝差額
  select count(*) = 2 and bool_and(p.unit_price = public._pkg_ext_expected(p.org_id, p.sku)),
         string_agg(p.sku || '=' || p.unit_price, '、' order by p.sku)
    into v_ok, v_s
    from products p where p.sku in ('SVC-TBL-PX05', 'SVC-TBL-PX24') and p.deleted_at is null;
  v_msg := v_msg || case when v_ok then '✅' else '🔴' end || ' ① 延長商品：' || coalesce(v_s, '沒有') || E'\n';

  -- ② 兩個觸發器在
  select count(*) into v_n from pg_trigger
   where tgrelid = 'public.products'::regclass and not tgisinternal
     and tgname in ('trg_products_pkg_ext_guard', 'trg_products_pkg_tier_sync');
  v_msg := v_msg || case when v_n = 2 then '✅' else '🔴' end || ' ② 價格觸發器 ' || v_n || '/2' || E'\n';

  -- ③ 四支既有函式都接上了，而且各只有一個版本
  select count(*) into v_n from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
     and ((p.proname in ('tbl_submit_hand_tx', 'tbl_start_round_tx') and pg_get_functiondef(p.oid) ~ 'pkg_locked')
       or (p.proname = 'tbl_state_tx'   and pg_get_functiondef(p.oid) ~ '''pkg'', public\._pkg_time')
       or (p.proname = 'list_tables_tx' and pg_get_functiondef(p.oid) ~ 'pkg_phase'));
  select count(*) into v_s from pg_proc
   where pronamespace = 'public'::regnamespace
     and proname in ('tbl_submit_hand_tx', 'tbl_start_round_tx', 'tbl_state_tx', 'list_tables_tx');
  v_msg := v_msg || case when v_n = 4 and v_s = '4' then '✅' else '🔴' end
        || ' ③ 接上 ' || v_n || '/4，版本數 ' || v_s || '（應為 4）' || E'\n';

  -- ④ 授權：POS 兩支只有 authenticated（明確授權與 PUBLIC 都看）；計時函式前端叫不到
  select bool_and(not has_function_privilege('anon', p.oid, 'execute')
                  and has_function_privilege('authenticated', p.oid, 'execute'))
    into fn_auth from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.proname in ('pos_pkg_quote_tx', 'pos_pkg_extend_tx');
  select bool_or(has_function_privilege('authenticated', p.oid, 'execute')
              or has_function_privilege('anon', p.oid, 'execute'))
    into fn_anon from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.proname in ('_pkg_time', '_pkg_shares', '_pkg_ext_expected');
  v_msg := v_msg || case when fn_auth and not fn_anon then '✅' else '🔴' end
        || ' ④ 授權：POS 兩支只給登入的人 ' || coalesce(fn_auth::text, '?')
        || '／內部函式前端叫得到 ' || coalesce(fn_anon::text, '?') || E'\n';

  -- ⑤ 計時函式對非包桌回 null（正對照在 checks 那份）
  select count(*) into v_n from table_sessions ts
   where ts.mode = 'matched' and ts.status = 'open' and public._pkg_time(ts.id) is not null;
  v_msg := v_msg || case when v_n = 0 then '✅' else '🔴' end || ' ⑤ 配桌場次不計時：被計時的配桌場次 ' || v_n || ' 筆（應為 0）';

  perform set_config('migi.pkg', v_msg, true);
end $$;

select coalesce(nullif(current_setting('migi.pkg', true), ''), '🔴 沒有驗證訊息') as "驗證";
