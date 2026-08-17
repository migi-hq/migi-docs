-- 【待執行】建立 member_tiers 主檔，折扣改存「折抵幅度」
-- ============================================================
-- 問題一：折扣率寫在兩支函式裡，各一份 case
--   checkout_tx          case tier when 'tiramisu' then 0.900 ...
--   pos_member_detail_tx case tier when 'tiramisu' then 0.900 ...   ← 一模一樣的第二份
--
--   pos_member_detail_tx 的註解自己寫著「折扣率與 checkout_tx 內的邏輯一致，
--   前端試算才不會與實際結帳金額有出入」——「一致」是靠人維護的。
--   改一邊忘另一邊，畫面顯示 88 折、實收 9 折，而且不會報錯。
--   這跟今天早上修掉的分類顯示名是同一個病（前端／後端各寫死一份）。
--
--   中文名（珍珠奶茶／焦糖布丁／提拉米蘇／主廚特調）則寫死在 migi-pos/src/shared.jsx
--   的 tierLabel —— 第三份。
--
-- 問題二：折扣有兩種相反的存法
--   coupons.discount_value  折抵幅度（9 折券填 10）  ← 2026-08-17 拍板
--   orders.tier_rate        保留比例（9 折存 0.900） ← 相反
--
--   世界級系統一律存折抵幅度：Shopify value+value_type、Square percentage、
--   Stripe percent_off、Oracle RPM / SAP 的 condition record 都是。
--   理由三個都很實際：
--     ① 折扣是會計科目（銷貨折讓），財報要的是「折了多少」，存保留比例每次都要 1 - x
--     ② 零值是自然的恆等元；保留比例的「沒折扣」是 100，加總平均累計都會出錯
--     ③ 折扣相加有意義，保留比例相加沒有
--
--   checkout_tx 裡那個 `* (1 - v_rate)` 就是在補償這件事。
--
-- 問題三：升等門檻沒有地方放
--   《待辦與未定案》的「會員等級門檻金額（暫定 0 / 10k / 50k）」目前無欄位可存。
--
-- 解法：一張 member_tiers 主檔，一次解決三件
--   等級碼 / 中文名 / 折抵幅度 / 升等門檻，三端都讀它。
--   比照 2026-08-17 的 product_taxonomy：無 org_id、無寫入政策 ——
--   折抵幅度寫進金流計算，讓單店自訂會讓金額無聲算錯。
--
-- 為什麼現在做
--   orders 全是測試資料，回填零成本。前端只有 3 處引用（全在 OpenCheckoutPage），
--   migi-web 與 migi-admin 零引用。晚一步就要帶著真實訂單遷移。
--
-- 安全性
--   三支函式簽名都未變，用 CREATE OR REPLACE，不需 DROP。
--   orders_amount_balance 恆等式只用金額欄位，不受本次影響。
--   執行順序刻意是「加欄位 → 回填 → 改函式 → 才 drop 舊欄位」，
--   中間任何一步失敗都不會留下讀不到欄位的函式。
-- ============================================================

-- ① 等級主檔
create table if not exists public.member_tiers (
  code             text    primary key,
  label            text    not null,
  discount_pct     int     not null default 0,
  threshold_amount bigint,
  sort             int     not null default 0,
  is_active        boolean not null default true,
  note             text,
  created_at       timestamptz not null default now(),
  constraint member_tiers_pct_chk check (discount_pct between 0 and 100)
);

comment on table public.member_tiers is
  '會員等級主檔（系統層，全租戶共用）。等級碼、中文名、折抵幅度、升等門檻的唯一來源；三端都讀 list_member_tiers_tx()，不得在程式碼裡再寫一份。';
comment on column public.member_tiers.discount_pct is
  '折抵幅度（%）。9 折存 10，不是 90 —— 與 coupons.discount_value 同一種慣例。顯示時才轉成台灣人講的折數。';
comment on column public.member_tiers.threshold_amount is
  '升等所需累積消費（元）。null = 不靠累積取得（邀請制）。';

alter table public.member_tiers enable row level security;
drop policy if exists member_tiers_read on public.member_tiers;
create policy member_tiers_read on public.member_tiers for select using (true);

insert into public.member_tiers (code, label, discount_pct, threshold_amount, sort, note) values
  ('bubble_tea',      '珍珠奶茶', 0,  0,     10, '入會預設'),
  ('caramel_pudding', '焦糖布丁', 5,  10000, 20, null),
  ('tiramisu',        '提拉米蘇', 10, 50000, 30, null),
  ('chef_special',    '主廚特調', 10, null,  40, '邀請制，不靠累積消費取得')
on conflict (code) do nothing;

drop function if exists public.list_member_tiers_tx();

create or replace function public.list_member_tiers_tx()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'code',      t.code,
           'label',     t.label,
           'pct',       t.discount_pct,
           'threshold', t.threshold_amount
         ) order by t.sort, t.code), '[]'::jsonb)
    from public.member_tiers t
   where t.is_active;
$$;

comment on function public.list_member_tiers_tx() is
  '會員等級主檔。三端的等級中文名與折抵幅度唯一來源，前端不得再寫死 tierLabel 或折扣率。';

grant execute on function public.list_member_tiers_tx() to anon, authenticated;

-- ② orders 加折抵幅度欄位並回填（舊欄位稍後才 drop）
alter table public.orders
  add column if not exists tier_discount_pct int;

comment on column public.orders.tier_discount_pct is
  '成交當下的會員折抵幅度（%）快照。取代原本的 tier_rate（保留比例）—— 全系統統一存折抵幅度。';

update public.orders
   set tier_discount_pct = round((1 - coalesce(tier_rate, 1)) * 100)
 where tier_discount_pct is null;

-- ③ checkout_tx：折扣率改查主檔，寫入折抵幅度
create or replace function public.checkout_tx(
  p_member_id uuid,
  p_store_id uuid,
  p_items jsonb,
  p_coupon_ids uuid[],
  p_points_used bigint,
  p_payments jsonb,
  p_idempotency_key text,
  p_staff_id uuid)
returns jsonb
language plpgsql
as $function$
declare
  v_org        uuid;
  v_order_id   uuid;
  v_order_no   text;
  v_tier       text;
  v_pct        int;
  v_sub        bigint := 0;
  v_fee        bigint := 0;
  v_fnb        bigint := 0;
  v_goods      bigint := 0;
  v_coupon_cut bigint := 0;
  v_tier_cut   bigint := 0;
  v_payable    bigint;
  v_pts        bigint;
  v_cash_due   bigint;
  v_pay_sum    bigint := 0;
  v_bal        bigint;
  v_txn        uuid;
  it           jsonb;
  cp           record;
  pay          jsonb;
  rem_fee      bigint;
  rem_fnb      bigint;
  rem_goods    bigint;
  cap          bigint;
  cut          bigint;
begin
  if p_idempotency_key is null then
    raise exception 'idempotency_key 必填';
  end if;

  select id, order_no into v_order_id, v_order_no
    from orders where idempotency_key = p_idempotency_key;
  if found then
    select balance into v_bal from wallets where member_id = p_member_id;
    return jsonb_build_object('idempotent', true, 'order_id', v_order_id,
                              'order_no', v_order_no, 'new_balance', v_bal);
  end if;

  select org_id into v_org from stores where id = p_store_id;
  if v_org is null then raise exception 'store % 不存在', p_store_id; end if;

  if p_items is null or jsonb_array_length(p_items) = 0 then
    raise exception '沒有可結帳的品項';
  end if;

  for it in select * from jsonb_array_elements(p_items) loop
    declare
      l_qty   int    := (it->>'qty')::int;
      l_price bigint := (it->>'unit_price')::bigint;
      l_kind  text   := it->>'kind';
      l_line  bigint;
    begin
      if l_qty <= 0 or l_price < 0 then raise exception '品項數量/單價不合法'; end if;
      if l_kind not in ('fee','fnb','goods') then raise exception '品項 kind 不合法：%', l_kind; end if;
      l_line := l_qty * l_price;
      v_sub  := v_sub + l_line;
      if    l_kind = 'fee'   then v_fee   := v_fee   + l_line;
      elsif l_kind = 'fnb'   then v_fnb   := v_fnb   + l_line;
      else                        v_goods := v_goods + l_line;
      end if;
    end;
  end loop;

  rem_fee := v_fee; rem_fnb := v_fnb; rem_goods := v_goods;

  if p_coupon_ids is not null and array_length(p_coupon_ids,1) > 0 then
    for cp in
      select mc.id as mc_id, c.name as c_name,
             c.applies_to, c.discount_type, c.discount_value,
             c.min_spend, c.max_discount, c.free_product_id
        from member_coupons mc
        join coupons c on c.id = mc.coupon_id
       where mc.id = any(p_coupon_ids)
         and mc.member_id = p_member_id
       for update of mc
    loop
      perform 1 from member_coupons
        where id = cp.mc_id
          and used_at is null
          and coalesce(status,'') <> 'used'
          and (expires_at is null or expires_at > now());
      if not found then
        raise exception '券 % 已使用或已過期', cp.c_name;
      end if;

      cap := case cp.applies_to
               when 'table_fee' then rem_fee
               when 'fnb'       then rem_fnb
               else 0
             end;
      if cp.applies_to is null then cap := rem_fee + rem_fnb + rem_goods; end if;

      if cp.discount_type = 'free' and cp.free_product_id is not null then
        select coalesce(sum((it2->>'qty')::int * (it2->>'unit_price')::bigint), 0)
          into cap
          from jsonb_array_elements(p_items) it2
         where nullif(it2->>'product_id','')::uuid = cp.free_product_id;
        if cap <= 0 then
          raise exception '券 % 指定商品不在本次訂單中', cp.c_name;
        end if;
      elsif cap <= 0 then
        raise exception '券 % 不適用於本次品項', cp.c_name;
      end if;

      if cp.min_spend is not null and cap < cp.min_spend then
        raise exception '券 % 需最低消費 %（本次適用範圍僅 %）', cp.c_name, cp.min_spend, cap;
      end if;

      cut := case cp.discount_type
               when 'free'    then cap
               when 'percent' then round(cap * coalesce(cp.discount_value,0) / 100.0)
               else                least(coalesce(cp.discount_value,0), cap)
             end;
      if cp.max_discount is not null and cut > cp.max_discount then
        cut := cp.max_discount;
      end if;
      cut := least(cut, cap);
      if cut <= 0 then raise exception '券 % 折抵金額為 0', cp.c_name; end if;

      v_coupon_cut := v_coupon_cut + cut;
      update member_coupons set discounted_amount = cut where id = cp.mc_id;

      if cp.applies_to = 'table_fee' then
        rem_fee := rem_fee - cut;
      elsif cp.applies_to = 'fnb' then
        rem_fnb := rem_fnb - cut;
      else
        declare r bigint := cut; d bigint;
        begin
          d := least(r, rem_fee);   rem_fee   := rem_fee   - d; r := r - d;
          d := least(r, rem_fnb);   rem_fnb   := rem_fnb   - d; r := r - d;
          d := least(r, rem_goods); rem_goods := rem_goods - d;
        end;
      end if;
    end loop;
  end if;

  select coalesce(tier_override, tier) into v_tier from members where id = p_member_id;

  -- ★ 2026-08-17：折抵幅度改查 member_tiers 主檔，不在函式裡寫死 case。
  --   查不到的等級一律 0（不折），不要猜。
  select coalesce(t.discount_pct, 0) into v_pct
    from member_tiers t where t.code = v_tier and t.is_active;
  v_pct := coalesce(v_pct, 0);

  -- 等級折扣只折檯費（2026-08-17）。rem_fee 是券折抵後剩下的檯費。
  v_tier_cut := round(rem_fee * v_pct / 100.0);

  v_payable := v_sub - v_coupon_cut - v_tier_cut;
  if v_payable < 0 then raise exception '應付金額為負，折扣計算有誤'; end if;

  select balance into v_bal from wallets where member_id = p_member_id for update;
  if v_bal is null then raise exception 'member % 沒有錢包', p_member_id; end if;

  v_pts := greatest(0, least(coalesce(p_points_used,0), least(v_bal, v_payable)));
  v_cash_due := v_payable - v_pts;

  if p_payments is not null then
    for pay in select * from jsonb_array_elements(p_payments) loop
      v_pay_sum := v_pay_sum + (pay->>'amount')::bigint;
    end loop;
  end if;
  if v_pay_sum <> v_cash_due then
    raise exception '收款金額 % 與尚需支付 % 不符', v_pay_sum, v_cash_due;
  end if;

  insert into orders(
    id, org_id, store_id, member_id, status,
    subtotal, coupon_discount, tier_discount, payable, points_used, cash_due,
    tier_at_order, tier_discount_pct, idempotency_key, created_by, paid_at
  ) values (
    gen_random_uuid(), v_org, p_store_id, p_member_id, 'paid',
    v_sub, v_coupon_cut, v_tier_cut, v_payable, v_pts, v_cash_due,
    v_tier, v_pct, p_idempotency_key, p_staff_id, now()
  )
  returning id, order_no into v_order_id, v_order_no;

  for it in select * from jsonb_array_elements(p_items) loop
    insert into order_items(org_id, order_id, product_id, name, kind, qty,
                            unit_price, line_total)
    values (v_org, v_order_id,
            nullif(it->>'product_id','')::uuid,
            it->>'name', it->>'kind',
            (it->>'qty')::int,
            (it->>'unit_price')::bigint,
            (it->>'qty')::int * (it->>'unit_price')::bigint);
  end loop;

  if v_pts > 0 then
    insert into wallet_txns(
      org_id, store_id, member_id, type, amount, status,
      counter_account, idempotency_key, ref_table, ref_id, staff_id, note
    ) values (
      v_org, p_store_id, p_member_id, 'spend', -v_pts, 'completed',
      'liability', p_idempotency_key || ':spend',
      'orders', v_order_id, p_staff_id, '消費扣點 ' || v_order_no
    )
    returning id into v_txn;

    update wallets set balance = balance - v_pts where member_id = p_member_id;
    update orders set wallet_txn_id = v_txn where id = v_order_id;
  end if;

  if p_payments is not null then
    for pay in select * from jsonb_array_elements(p_payments) loop
      insert into order_payments(
        org_id, store_id, order_id, method, amount,
        cash_received, change_given, ref_no, staff_id
      ) values (
        v_org, p_store_id, v_order_id,
        pay->>'method', (pay->>'amount')::bigint,
        nullif(pay->>'cash_received','')::bigint,
        nullif(pay->>'change_given','')::bigint,
        nullif(pay->>'ref_no',''), p_staff_id
      );
    end loop;
  end if;

  if p_coupon_ids is not null and array_length(p_coupon_ids,1) > 0 then
    update member_coupons
       set used_at = now(), used_order = v_order_id, used_txn_id = v_txn, status = 'used'
     where id = any(p_coupon_ids) and member_id = p_member_id;
  end if;

  return jsonb_build_object(
    'order_id',          v_order_id,
    'order_no',          v_order_no,
    'subtotal',          v_sub,
    'coupon_discount',   v_coupon_cut,
    'tier',              v_tier,
    'tier_discount_pct', v_pct,
    'tier_discount',     v_tier_cut,
    'payable',           v_payable,
    'points_used',       v_pts,
    'cash_due',          v_cash_due,
    'new_balance',       v_bal - v_pts
  );
end
$function$;

comment on function public.checkout_tx(uuid, uuid, jsonb, uuid[], bigint, jsonb, text, uuid) is
  '結帳核心。券依 applies_to 分桶折抵；會員等級折扣只折檯費，折抵幅度查 member_tiers 主檔（不在函式裡寫死）。寫入 orders / order_items / wallet_txns / order_payments / member_coupons。';

-- ④ pos_member_detail_tx：改查主檔並回傳折抵幅度
create or replace function public.pos_member_detail_tx(p_org_id uuid, p_member_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare v_tier text; v_pct int;
begin
  select coalesce(tier_override, tier) into v_tier
    from members where id = p_member_id and org_id = p_org_id and deleted_at is null;
  if v_tier is null and not exists (
       select 1 from members where id = p_member_id and org_id = p_org_id) then
    return null;
  end if;

  -- ★ 折抵幅度查 member_tiers，與 checkout_tx 同一個來源。
  --   原本這裡有一份跟 checkout_tx 一模一樣的 case，靠人維護「一致」——
  --   改一邊忘另一邊，畫面顯示與實收金額就會不同，而且不會報錯。
  select coalesce(t.discount_pct, 0) into v_pct
    from member_tiers t where t.code = v_tier and t.is_active;
  v_pct := coalesce(v_pct, 0);

  return (
    select jsonb_build_object(
      'id', m.id, 'nickname', m.display_name, 'phone', m.phone,
      'tier', v_tier, 'tier_discount_pct', v_pct, 'rank', m.rank, 'title', m.title,
      'avatar_source', m.avatar_source, 'avatar_photo_path', m.avatar_photo_path,
      'balance', coalesce(w.balance, 0),
      'coupons', (
        select coalesce(jsonb_agg(jsonb_build_object(
          'id', mc.id, 'name', c.name,
          'applies_to', c.applies_to,        -- table_fee / fnb / null(全品項)
          'discount_type', c.discount_type,  -- free / percent / fixed
          'discount_value', c.discount_value,
          'min_spend', c.min_spend, 'max_discount', c.max_discount,
          'expires_at', mc.expires_at
        ) order by mc.expires_at nulls last), '[]'::jsonb)
        from member_coupons mc
        join coupons c on c.id = mc.coupon_id
        where mc.member_id = m.id
          and mc.used_at is null and coalesce(mc.status,'') <> 'used'
          and (mc.expires_at is null or mc.expires_at > now()))
    )
    from members m
    left join wallets w on w.member_id = m.id
    where m.id = p_member_id and m.org_id = p_org_id and m.deleted_at is null
  );
end $function$;

-- ⑤ get_order_tx：回傳新欄位
create or replace function public.get_order_tx(p_order_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
begin
  return (
    select jsonb_build_object(
      'id', o.id,
      'order_no', o.order_no,
      'status', o.status,
      'subtotal', o.subtotal,
      'coupon_discount', o.coupon_discount,
      'tier_discount', o.tier_discount,
      'payable', o.payable,
      'points_used', o.points_used,
      'cash_due', o.cash_due,
      'tier_at_order', o.tier_at_order,
      'tier_discount_pct', o.tier_discount_pct,
      'paid_at', o.paid_at,
      'items', (
        select coalesce(jsonb_agg(jsonb_build_object(
          'name', i.name, 'kind', i.kind, 'qty', i.qty,
          'unit_price', i.unit_price, 'line_total', i.line_total
        ) order by i.kind, i.name), '[]'::jsonb)
        from order_items i where i.order_id = o.id),
      'payments', (
        select coalesce(jsonb_agg(jsonb_build_object(
          'method', pm.method, 'amount', pm.amount,
          'cash_received', pm.cash_received, 'change_given', pm.change_given
        )), '[]'::jsonb)
        from order_payments pm where pm.order_id = o.id)
    )
    from orders o
    where o.id = p_order_id and o.deleted_at is null
  );
end $function$;

-- ⑥ 三支函式都改完了，才移除舊欄位
alter table public.orders drop column if exists tier_rate;

-- ============================================================
-- 驗證（單一 SELECT）
--   等級數 4、舊欄位已移除 true、新欄位存在 true、
--   仍寫死折扣率的函式數 0（三支都改乾淨了）、
--   未回填的訂單 0。
--   逐列看四個等級的折抵幅度與門檻。
-- ============================================================
select
  t.code                                                           as 等級碼,
  t.label                                                          as 中文名,
  t.discount_pct                                                   as 折抵幅度,
  (100 - t.discount_pct)                                           as 顯示折數,
  t.threshold_amount                                               as 升等門檻,
  (select count(*) from public.member_tiers)                       as 等級數,
  (select count(*) = 0 from information_schema.columns
    where table_schema='public' and table_name='orders'
      and column_name='tier_rate')                                 as 舊欄位已移除,
  (select count(*) = 1 from information_schema.columns
    where table_schema='public' and table_name='orders'
      and column_name='tier_discount_pct')                         as 新欄位存在,
  (select count(*) from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where n.nspname='public' and p.prokind='f'
      and pg_get_functiondef(p.oid) ilike '%caramel_pudding%'
      and p.proname <> 'list_member_tiers_tx')                     as 仍寫死折扣率的函式數,
  (select count(*) from public.orders
    where tier_discount_pct is null and deleted_at is null)        as 未回填的訂單
from public.member_tiers t
order by t.sort;
