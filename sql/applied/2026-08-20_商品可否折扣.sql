-- 【待執行】products.discountable：暢打固定 300，不參與任何折扣
-- ============================================================
-- 起點
--   2026-08-20 實測發現：提拉米蘇會員買當日暢打實收 270 不是 300。
--   暢打是 revenue_type='venue_fee' 商品，而規格是「等級折扣只折檯費」，
--   所以它被折了。邏輯沒錯，但**暢打本來就是為了讓人多打**，
--   再疊一層等級折扣是兩層優惠打在同一件事上。
--   → 決定：暢打固定 300。
--
-- 【範圍：不只擋等級折扣，券也折不到】
--   「固定 300」如果只擋等級折扣，一張檯費 9 折券還是能把它折成 270 ——
--   那就不是固定。本檔讓不可折扣的品項**退出全部三個折扣桶**，
--   金額仍計入 subtotal。
--   ⚠ 後果：日後要辦「暢打特價」不能發檯費券，要改售價或另開促銷品項。
--     那其實比較對 —— 券的成本歸屬是 store/hq，而調價不是折讓。
--
-- 【為什麼是欄位而不是在 checkout_tx 判斷 SKU】
--   「這個商品參不參與折扣」是**商品屬性**，不是金流函式的 if。
--   已知未來會用到同一件事的：禮券、寄杯（預收）、派車代收款、
--   以及任何「代收代付」性質的品項 —— 它們在會計上根本不是收入，
--   更不該被折。每多一種就改一次 checkout_tx，就是待辦 0.8 在講的病。
--   Square / Lightspeed 都是每個品項一個 discountable 旗標。
--
-- 【由後端查，不信前端】
--   checkout_tx 用 product_id 回查 products.discountable，
--   不讀前端送來的欄位。折不折扣是價格的一部分，
--   而 checkout_tx 的價格已經全部來自前端 JSON（待辦 2）——
--   不要再多一個可被竄改的折扣開關。
--   前端另外拿一份（list 函式回傳）只是為了讓畫面算得跟後端一樣。
-- ============================================================

alter table public.products
  add column if not exists discountable boolean not null default true;

comment on column public.products.discountable is
  '是否參與折扣（會員等級折扣與優惠券）。false 的品項退出全部折扣桶，金額仍計入 subtotal。用於固定價商品：當日暢打、禮券、預收與代收性質的項目。';

-- 當日暢打固定價
update public.products
   set discountable = false
 where sku = 'SVC-TBL-DAY';

-- ① checkout_tx：不可折扣的品項退出三個桶
--    ⚠ 維持 SECURITY INVOKER 且不設 search_path（它一律由 DEFINER 呼叫端委派）
create or replace function public.checkout_tx(
  p_member_id uuid, p_store_id uuid, p_items jsonb, p_coupon_ids uuid[],
  p_points_used bigint, p_payments jsonb, p_idempotency_key text, p_staff_id uuid)
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
  v_nodisc     bigint := 0;   -- ★ 不參與折扣的金額（只為驗算與回傳，不進任何桶）
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
      l_qty    int    := (it->>'qty')::int;
      l_price  bigint := (it->>'unit_price')::bigint;
      l_bucket text   := it->>'revenue_type';
      l_line   bigint;
      -- ★ 折不折扣一律由後端回查商品主檔，不採信前端送來的值。
      --   查不到商品（理論上不會，product_id 是 NOT NULL）就當可折扣，
      --   寧可少擋一次也不要讓未知商品靜靜跳過折扣。
      l_disc   boolean := coalesce((select pr.discountable from public.products pr
                                     where pr.id = nullif(it->>'product_id','')::uuid), true);
    begin
      if l_qty <= 0 or l_price < 0 then raise exception '品項數量/單價不合法'; end if;
      -- ★ 一定要先判 null。舊版寫 `l_kind not in (...)`，
      --   而 `NULL not in (...)` 的結果是 NULL 不是 TRUE ——
      --   那道防護在欄位改名之後對 null 完全不擋，然後 null 一路掉進 else 桶。
      if l_bucket is null then
        raise exception '品項缺少 revenue_type：%', coalesce(it->>'name', '(未命名)');
      end if;
      if l_bucket not in ('venue_fee','fnb','retail','other') then
        raise exception '品項 revenue_type 不合法：%', l_bucket;
      end if;
      l_line := l_qty * l_price;
      v_sub  := v_sub + l_line;
      -- 不可折扣的品項退出全部折扣桶（當日暢打固定 300 就是靠這裡）。
      -- retail 與 other 共用 goods 桶：券的 applies_to 只分 table_fee / fnb / 其餘。
      if not l_disc then           v_nodisc := v_nodisc + l_line;
      elsif l_bucket = 'venue_fee' then v_fee   := v_fee   + l_line;
      elsif l_bucket = 'fnb'       then v_fnb   := v_fnb   + l_line;
      else                              v_goods := v_goods + l_line;
      end if;
    end;
  end loop;

  rem_fee := v_fee; rem_fnb := v_fnb; rem_goods := v_goods;

  if p_coupon_ids is not null and array_length(p_coupon_ids,1) > 0 then
    for cp in
      select mc.id as mc_id, c.name as c_name,
             c.applies_to, c.discount_type, c.discount_value,
             c.min_spend, c.max_discount, c.free_product_id, c.cost_bearer
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
        -- 指定商品券：那個商品若是不可折扣的，一樣不給折
        select coalesce(sum((it2->>'qty')::int * (it2->>'unit_price')::bigint), 0)
          into cap
          from jsonb_array_elements(p_items) it2
          join public.products pr2
            on pr2.id = nullif(it2->>'product_id','')::uuid
         where pr2.id = cp.free_product_id
           and pr2.discountable;
        if cap <= 0 then
          raise exception '券 % 指定商品不在本次訂單中，或該商品不參與折扣', cp.c_name;
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
      update member_coupons set discounted_amount = cut, cost_bearer = cp.cost_bearer where id = cp.mc_id;

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

  -- 等級折扣只折檯費（2026-08-17）。rem_fee 是券折抵後剩下的檯費，
  -- 且已排除不可折扣的品項（2026-08-20）。
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
    insert into order_items(org_id, order_id, product_id, name, revenue_type, qty,
                            unit_price, line_total)
    values (v_org, v_order_id,
            nullif(it->>'product_id','')::uuid,
            it->>'name',
            it->>'revenue_type',
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
    'non_discountable',  v_nodisc,
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

-- ② 兩支 list 函式回傳 discountable，讓前端算得跟後端一樣
create or replace function public.list_products_tx(p_org_id uuid)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'public'
as $function$
begin
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', id, 'sku', sku, 'name', name, 'category', category,
      'unit_price', unit_price,
      'revenue_type', revenue_type,
      'discountable', discountable
    ) order by category, sku)
    from products
    where org_id = p_org_id and is_active and coalesce(is_available, true)
      and deleted_at is null
      and sku not like 'SVC-TBL-%'   -- 檯費不列入加購清單，避免店員手動點錯
  ), '[]'::jsonb);
end $function$;

create or replace function public.list_daypass_tx(p_org_id uuid)
returns jsonb
language sql
stable
security definer
set search_path to public
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id',           p.id,
           'sku',          p.sku,
           'name',         p.name,
           'category',     p.category,
           'unit_price',   p.unit_price,
           'revenue_type', 'venue_fee',
           'discountable', p.discountable)), '[]'::jsonb)
    from public.products p
   where p.org_id = p_org_id
     and p.sku = 'SVC-TBL-DAY'
     and p.is_active
     and p.deleted_at is null;
$$;

grant execute on function public.list_daypass_tx(uuid) to anon, authenticated;

-- ============================================================
-- 驗證（單一 SELECT）
--   前四欄 true / 1。
--   最後一欄列出所有不可折扣的商品 —— 現在應該只有當日暢打。
-- ============================================================
with fns as (
  select p.proname, pg_get_functiondef(p.oid) as def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.prokind = 'f'
)
select
  (select count(*) = 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'products'
      and column_name = 'discountable' and is_nullable = 'NO')            as 欄位已建立,
  (select count(*) from public.products
    where sku = 'SVC-TBL-DAY' and discountable = false)                   as 暢打已設不可折,
  (select bool_or(def like '%l_disc%') from fns
    where proname = 'checkout_tx')                                        as checkout已讀旗標,
  (select count(*) from fns
    where proname in ('list_products_tx','list_daypass_tx')
      and def like '%discountable%')                                      as 兩支list已回傳,
  (select jsonb_agg(jsonb_build_object('sku', sku, 'name', name)
            order by sku)
     from public.products
    where discountable = false and deleted_at is null)                    as 不可折扣的商品;
