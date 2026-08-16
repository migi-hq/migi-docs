-- 【待執行】會員等級折扣改成只折檯費
-- ============================================================
-- 問題
--   《會員分級制度規格》寫的是「**桌時費** 95 折 / **桌時費** 9 折」，
--   但 checkout_tx 算的是整張單：
--
--     v_tier_cut := round((v_sub - v_coupon_cut) * (1 - v_rate));
--
--   實測（2026-08-16，測試01 提拉米蘇 9 折）：
--   檯費 150 + 水餃 80 → 折了 -$23（230 的 10%），照規格應為 -$15。
--
--   為什麼這件事要緊：**餐飲與商品有食材／進貨成本，檯費幾乎是純毛利。**
--   餐飲食材成本通常 30–40%，一個毛利 40% 的品項打 9 折，毛利直接掉四分之一。
--   檯費打 9 折則幾乎不痛 —— 桌子本來就在那，邊際成本趨近於零。
--   業界（星巴克、超商會員、旅館 elite）一律「折扣給產能，不給存貨」，
--   規格本身就是照這個原則寫的，是實作走偏了。
--
-- 改法：一行
--   checkout_tx 裡已經有一個現成的答案 —— `rem_fee`。
--   它是「檯費扣掉券折抵之後還剩多少」，券的分桶邏輯一路維護著它
--   （applies_to='table_fee' 的券會扣它，未指定範圍的券會依序吃掉三個桶）。
--   所以不需要自己重算，直接用它。
--
--     v_tier_cut := round(rem_fee * (1 - v_rate));
--
--   沒有券時 rem_fee = v_fee，行為就是「檯費 × 折數」。
--
-- 順帶：v_payable 不會變成負數
--   v_tier_cut ≤ rem_fee ≤ v_sub - v_coupon_cut，比舊版更安全。
--
-- 本檔**只改這一行**，其餘與線上版逐字相同（2026-08-17 以 pg_get_functiondef 撈出）。
--   簽名未變，不需 DROP。
--
-- ⚠ 刻意不動的兩件事（避免把安全性修改混進計價修改，出事時分不清是誰造成的）
--   ① checkout_tx **沒有 SECURITY DEFINER 也沒有 SET search_path**。
--      它靠 join_session_tx（DEFINER）呼叫才跑得動，POS 直接叫會被 RLS 擋。
--      缺 search_path 在「被 DEFINER 呼叫的函式」裡是安全面向的缺口，另案處理。
--   ② v_rate 的等級對照寫死在函式裡（caramel_pudding 0.950 / tiramisu 0.900 /
--      chef_special 0.900）。而 chef_special 目前根本寫不進 members
--      —— 兩條 tier CHECK 打架，見 CLAUDE.md 待辦 4。
--
-- ⚠ 硬規則 7：本檔跑完只代表 DDL 成功。
--   **必須在 POS 實際結一次帳**（測試01 提拉米蘇，檯費 + 餐飲各一筆），
--   確認折扣金額 = 檯費 × 10%，才算完成。
-- ============================================================

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
  v_rate       numeric(4,3);
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
  v_rate := case v_tier
              when 'caramel_pudding' then 0.950
              when 'tiramisu'        then 0.900
              when 'chef_special'    then 0.900
              else 1.000
            end;

  -- ★ 2026-08-17：會員等級折扣只折檯費，不折餐飲與商品。
  --   《會員分級制度規格》寫的就是「桌時費 95 折 / 桌時費 9 折」，
  --   舊版拿 (v_sub - v_coupon_cut) 當基數是把整張單都折了。
  --   rem_fee 是券折抵後剩下的檯費，正是這裡要的基數 —— 不需另外重算。
  --   餐飲與商品有食材／進貨成本，檯費幾乎純毛利；折扣給產能不給存貨。
  v_tier_cut := round(rem_fee * (1 - v_rate));

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
    tier_at_order, tier_rate, idempotency_key, created_by, paid_at
  ) values (
    gen_random_uuid(), v_org, p_store_id, p_member_id, 'paid',
    v_sub, v_coupon_cut, v_tier_cut, v_payable, v_pts, v_cash_due,
    v_tier, v_rate, p_idempotency_key, p_staff_id, now()
  )
  returning id, order_no into v_order_id, v_order_no;

  -- ★品項：只寫 unit_price（已淘汰 unit_points）
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
    'order_id',        v_order_id,
    'order_no',        v_order_no,
    'subtotal',        v_sub,
    'coupon_discount', v_coupon_cut,
    'tier',            v_tier,
    'tier_rate',       v_rate,
    'tier_discount',   v_tier_cut,
    'payable',         v_payable,
    'points_used',     v_pts,
    'cash_due',        v_cash_due,
    'new_balance',     v_bal - v_pts
  );
end
$function$;

comment on function public.checkout_tx(uuid, uuid, jsonb, uuid[], bigint, jsonb, text, uuid) is
  '結帳核心。券依 applies_to 分桶折抵；會員等級折扣**只折檯費**（基數為券折抵後的 rem_fee），不折餐飲與商品。寫入 orders / order_items / wallet_txns / order_payments / member_coupons。';

-- ============================================================
-- 驗證（單一 SELECT）
--   新算式存在 / 舊算式已移除 都應為 true；版本數 1。
--   最後兩欄是**今天已成立的訂單**裡，折扣是否只折了檯費 ——
--   本檔跑之前的舊訂單會是 false（那是歷史事實，不回頭改），
--   跑完之後在 POS 結一筆新的再看，新那筆應為 true。
--
--   ⚠ 硬規則 7：DDL 成功不等於功能正確。
--     必須在 POS 用測試01（提拉米蘇 9 折）結一筆「檯費 + 餐飲」的帳，
--     確認 tier_discount = 檯費 × 10%，才算完成。
-- ============================================================
select
  (select count(*) from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'checkout_tx')             as 版本數,
  (select pg_get_functiondef(p.oid) like '%round(rem_fee * (1 - v_rate))%'
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'checkout_tx'
      and p.prokind = 'f' limit 1)                                        as 新算式存在,
  (select pg_get_functiondef(p.oid) not like '%(v_sub - v_coupon_cut) * (1 - v_rate)%'
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'checkout_tx'
      and p.prokind = 'f' limit 1)                                        as 舊算式已移除,
  o.order_no                                                              as 最近訂單,
  o.subtotal                                                              as 小計,
  o.tier_discount                                                         as 等級折扣,
  (select coalesce(sum(oi.line_total), 0) from order_items oi
    where oi.order_id = o.id and oi.kind = 'fee')                         as 其中檯費,
  (o.tier_discount = round(
     (select coalesce(sum(oi.line_total), 0) from order_items oi
       where oi.order_id = o.id and oi.kind = 'fee')
     * (1 - o.tier_rate)))                                                as 折扣只折檯費
from public.orders o
where o.status = 'paid'
  and o.deleted_at is null
  and o.tier_discount > 0
order by o.created_at desc
limit 5;
