/* ============================================================
   結帳金額改由後端報價：把算法抽成共用核心
   2026-10-01 · MIGI 咪吉麻將
   行為測試：sql/checks/2026-10-01_驗結帳報價共用核心.sql（跑完這份再跑）

   ── 為什麼 ─────────────────────────────────────────────
   POS 結帳頁（OpenCheckoutPage.jsx）自己抄了一份券折抵與等級折扣的算法，
   註解寫「逐行鏡射後端」，而它已經落後兩處（CLAUDE.md 待辦 0.8）：
     · 指定商品免費券：後端只折那個商品，前端折整個適用範圍
     · 最低消費：後端擋，前端完全沒有
   另外檯費份數（暢打、代付）前端也抄了一份。
   正解不是替鏡射補測試（那會把重複固定下來），是**刪掉鏡射**：
   後端給報價，前端只負責畫（Stripe PaymentIntent／Shopify cart 的做法）。

   ── 🔴 不另外寫一份報價函式 ────────────────────────────
   那樣後端會有兩份折扣算法（報價一份、checkout_tx 一份），又是「兩份定義」。
   ⇒ 抽出共用核心，報價與實收叫**同一支**：
     ① _cart_pricing(org, 會員, 品項, 券)   純計算：小計、券折抵、等級折扣、應付。不寫入
     ② _join_plan(場次, 會員, 入座方式, 代付, 品項)
                                              入座前的全部檢查 ＋ 檯費那一行（份數、暢打、代付）
     ③ checkout_tx      改成叫 ①（簽名不變，前端與所有包裝一行不用改）
     ④ join_session_tx  改成叫 ②（簽名不變）
     ⑤ pos_quote_tx(場次, 會員, 入座方式, 代付, 品項, 券)   POS 的報價 ＝ ② ＋ ①

   ── 行為上唯一的改變 ─────────────────────────────────────
   · 同時用兩張以上的券時，套用順序改成「店員選的順序」（券 id 陣列的順序）。
     在此之前查詢沒有 order by，順序由資料庫決定 —— 前端鏡射照選的順序算，
     兩邊只有在剛好同序時才一樣。只影響「兩張都是不指定範圍」這種會互相搶額度的組合。
   其餘每一個數字、每一句錯誤訊息都與舊版相同（行為測試逐案比對新舊兩版）。
   ============================================================ */

-- ① 共用計價核心
create or replace function public._cart_pricing(p_org uuid, p_member_id uuid, p_items jsonb, p_coupon_ids uuid[])
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $fn$
declare
  v_tier text; v_pct int;
  v_sub bigint := 0; v_fee bigint := 0; v_fnb bigint := 0; v_goods bigint := 0;
  v_nodisc bigint := 0;   -- 不參與折扣的金額（只為驗算與回傳，不進任何桶）
  v_coupon_cut bigint := 0; v_tier_cut bigint; v_payable bigint;
  v_coupons jsonb := '[]'::jsonb;
  it jsonb; cp record;
  rem_fee bigint; rem_fnb bigint; rem_goods bigint; cap bigint; cut bigint;
begin
  /* 品項：前端只送「意圖」（product_id ＋ qty），其餘一律回查主檔（2026-08-27 起）。
     ⚠ 不過濾 is_active：結帳是已經發生的交易，不是決定要不要賣。 */
  if p_items is not null and jsonb_typeof(p_items) = 'array' then
    for it in select * from jsonb_array_elements(p_items) loop
      declare
        l_pid uuid := nullif(it->>'product_id','')::uuid;
        l_qty int := (it->>'qty')::int;
        l_price bigint; l_name text; l_bucket text; l_disc boolean; l_line bigint;
      begin
        if l_pid is null then
          raise exception '品項缺少 product_id：%', coalesce(it->>'name', '(未命名)');
        end if;
        select pr.unit_price, pr.name, pr.revenue_type, pr.discountable
          into l_price, l_name, l_bucket, l_disc
          from public.products pr
         where pr.id = l_pid and pr.org_id = p_org and pr.deleted_at is null;
        if not found then
          raise exception '商品不存在或不屬於本機構：%', l_pid;
        end if;
        if l_qty <= 0 then raise exception '品項數量不合法：%', l_qty; end if;
        if l_price < 0 then raise exception '商品 % 主檔單價為負', l_name; end if;
        -- 值域檢查要留著：日後加了新的收入類別而這裡沒跟上時，要大聲失敗
        if l_bucket not in ('venue_fee','fnb','retail','other') then
          raise exception '商品 % 的 revenue_type 尚未支援：%', l_name, l_bucket;
        end if;
        l_line := l_qty * l_price;
        v_sub  := v_sub + l_line;
        -- 不可折扣的品項退出全部折扣桶（當日暢打固定 300 就是靠這裡）；retail 與 other 共用一桶
        if not l_disc then                v_nodisc := v_nodisc + l_line;
        elsif l_bucket = 'venue_fee' then v_fee    := v_fee    + l_line;
        elsif l_bucket = 'fnb'       then v_fnb    := v_fnb    + l_line;
        else                              v_goods  := v_goods  + l_line;
        end if;
      end;
    end loop;
  end if;

  rem_fee := v_fee; rem_fnb := v_fnb; rem_goods := v_goods;

  if p_coupon_ids is not null and array_length(p_coupon_ids, 1) > 0 then
    for cp in
      select mc.id as mc_id, c.name as c_name, c.applies_to, c.discount_type, c.discount_value,
             c.min_spend, c.max_discount, c.free_product_id, c.cost_bearer
        from member_coupons mc
        join coupons c on c.id = mc.coupon_id
       where mc.id = any(p_coupon_ids) and mc.member_id = p_member_id
       order by array_position(p_coupon_ids, mc.id)   -- 店員選的順序
    loop
      perform 1 from member_coupons
        where id = cp.mc_id and used_at is null and coalesce(status,'') <> 'used'
          and (expires_at is null or expires_at > now());
      if not found then
        raise exception '券 % 已使用或已過期', cp.c_name;
      end if;

      cap := case cp.applies_to when 'table_fee' then rem_fee when 'fnb' then rem_fnb else 0 end;
      if cp.applies_to is null then cap := rem_fee + rem_fnb + rem_goods; end if;

      if cp.discount_type = 'free' and cp.free_product_id is not null then
        -- 指定商品券：只折那個商品（主檔價 × 數量），而且那個商品要可折扣
        select coalesce(sum((it2->>'qty')::int * pr2.unit_price), 0) into cap
          from jsonb_array_elements(p_items) it2
          join public.products pr2 on pr2.id = nullif(it2->>'product_id','')::uuid
         where pr2.id = cp.free_product_id and pr2.org_id = p_org
           and pr2.deleted_at is null and pr2.discountable;
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
      if cp.max_discount is not null and cut > cp.max_discount then cut := cp.max_discount; end if;
      cut := least(cut, cap);
      if cut <= 0 then raise exception '券 % 折抵金額為 0', cp.c_name; end if;

      v_coupon_cut := v_coupon_cut + cut;
      v_coupons := v_coupons || jsonb_build_array(jsonb_build_object(
        'member_coupon_id', cp.mc_id, 'name', cp.c_name, 'applies_to', cp.applies_to,
        'cut', cut, 'cost_bearer', cp.cost_bearer));

      if cp.applies_to = 'table_fee' then rem_fee := rem_fee - cut;
      elsif cp.applies_to = 'fnb' then     rem_fnb := rem_fnb - cut;
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

  -- 等級折扣：只折檯費（券折抵後剩下、而且可折扣的那一部分）；查不到的等級一律 0
  select coalesce(tier_override, tier) into v_tier from members where id = p_member_id;
  select coalesce(t.discount_pct, 0) into v_pct from member_tiers t where t.code = v_tier and t.is_active;
  v_pct := coalesce(v_pct, 0);
  v_tier_cut := round(rem_fee * v_pct / 100.0);

  v_payable := v_sub - v_coupon_cut - v_tier_cut;
  if v_payable < 0 then raise exception '應付金額為負，折扣計算有誤'; end if;

  return jsonb_build_object(
    'subtotal', v_sub, 'non_discountable', v_nodisc,
    'fee', v_fee, 'fnb', v_fnb, 'goods', v_goods,
    'coupon_discount', v_coupon_cut, 'coupons', v_coupons,
    'tier', v_tier, 'tier_discount_pct', v_pct, 'tier_discount', v_tier_cut,
    'payable', v_payable);
end $fn$;
revoke execute on function public._cart_pricing(uuid, uuid, jsonb, uuid[]) from public, anon, authenticated;
grant  execute on function public._cart_pricing(uuid, uuid, jsonb, uuid[]) to service_role;

-- ② 入座前的檢查 ＋ 檯費那一行（原本整段在 join_session_tx 裡，一字未改搬出來）
create or replace function public._join_plan(p_session_id uuid, p_member_id uuid, p_join_type text,
                                             p_pay_for uuid[], p_items jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $fn$
declare
  v_s record; v_base jsonb; v_unit bigint; v_qty int; v_amount bigint;
  v_items jsonb; v_target uuid; v_extra int := 0;
  v_buy_daypass boolean := false;   -- 本次結帳是否含當日暢打
  v_self_pass boolean := false;     -- 付款人是否已持有暢打
begin
  if p_join_type not in ('opener','mid_join','sub') then
    return jsonb_build_object('ok', false, 'reason', 'invalid_join_type');
  end if;

  -- 附加品項驗證。純輸入檢查，刻意排在查場次之前。
  if p_items is not null and jsonb_typeof(p_items) = 'array' then
    v_extra := jsonb_array_length(p_items);
  end if;

  if v_extra > 0 then
    select exists (
      select 1 from jsonb_array_elements(p_items) it
       where exists (select 1 from products pr
                      where pr.id = nullif(it ->> 'product_id', '')::uuid and pr.sku = 'SVC-TBL-DAY'))
      into v_buy_daypass;

    -- 場地費由系統自己算，前端再送一份會重複收費；暢打例外（它賣的是今天不再收場地費的權利）
    if exists (
      select 1 from jsonb_array_elements(p_items) it
        join products pr on pr.id = nullif(it ->> 'product_id', '')::uuid
       where pr.revenue_type = 'venue_fee' and pr.sku <> 'SVC-TBL-DAY' and pr.deleted_at is null
    ) then
      return jsonb_build_object('ok', false, 'reason', 'fee_item_not_allowed',
        'message', '場地費由系統計算，不可由前端傳入');
    end if;

    -- 儲值寫的是 topup_orders 不是 orders，不能混進同一張單（儲值不是商品，維持讀前端旗標）
    if exists (select 1 from jsonb_array_elements(p_items) it
                where it ->> 'is_topup' = 'true' or it ->> 'revenue_type' = 'topup') then
      return jsonb_build_object('ok', false, 'reason', 'topup_not_allowed',
        'message', '儲值請走儲值流程，不能併入結帳');
    end if;

    if exists (
      select 1 from jsonb_array_elements(p_items) it
       where nullif(it ->> 'product_id', '') is null or coalesce((it ->> 'qty')::int, 0) <= 0
    ) or exists (
      select 1 from jsonb_array_elements(p_items) it
        left join products pr on pr.id = nullif(it ->> 'product_id', '')::uuid and pr.deleted_at is null
       where nullif(it ->> 'product_id', '') is not null
         and (pr.id is null or (pr.revenue_type not in ('fnb','retail','other') and pr.sku <> 'SVC-TBL-DAY'))
    ) then
      return jsonb_build_object('ok', false, 'reason', 'invalid_item',
        'message', '品項需有存在的 product_id、數量大於 0，且收入桶為 fnb／retail／other');
    end if;
  end if;

  select * into v_s from table_sessions where id = p_session_id;
  if v_s.id is null then
    return jsonb_build_object('ok', false, 'reason', 'session_not_found');
  end if;
  if v_s.status <> 'open' then
    return jsonb_build_object('ok', false, 'reason', 'session_closed', 'message', '此場次已收桌或已作廢');
  end if;

  -- 鐵則一：一律會員
  if not exists (select 1 from members where id = p_member_id and deleted_at is null) then
    return jsonb_build_object('ok', false, 'reason', 'member_required', 'message', '需先建立會員資料');
  end if;

  if exists (select 1 from session_players
              where session_id = p_session_id and member_id = p_member_id and left_at is null) then
    return jsonb_build_object('ok', false, 'reason', 'already_joined');
  end if;

  -- 座位上限：自己 ＋ 代付人數不可超過 4
  if (select count(*) from session_players where session_id = p_session_id and left_at is null)
     + 1 + coalesce(array_length(p_pay_for, 1), 0) > 4 then
    return jsonb_build_object('ok', false, 'reason', 'table_full');
  end if;

  -- 被代付者必須是有效會員，且尚未入座
  if p_pay_for is not null then
    foreach v_target in array p_pay_for loop
      if v_target = p_member_id then
        return jsonb_build_object('ok', false, 'reason', 'cannot_pay_for_self');
      end if;
      if not exists (select 1 from members where id = v_target and deleted_at is null) then
        return jsonb_build_object('ok', false, 'reason', 'payfor_member_invalid', 'member_id', v_target);
      end if;
      if exists (select 1 from session_players
                  where session_id = p_session_id and member_id = v_target and left_at is null) then
        return jsonb_build_object('ok', false, 'reason', 'payfor_already_joined', 'member_id', v_target);
      end if;
    end loop;
  end if;

  -- 標準單價：會員傳 null 取得「不看暢打」的價格（暢打是個人權利，不因誰付錢而轉移）
  v_base := public.calc_session_fee_tx(p_session_id, p_join_type, null);
  if not (v_base ->> 'ok')::boolean then return v_base; end if;
  v_unit := coalesce((v_base ->> 'amount')::bigint, 0);

  v_self_pass := has_daypass_tx(v_s.org_id, p_member_id, v_s.store_id);
  if v_buy_daypass and v_self_pass then
    return jsonb_build_object('ok', false, 'reason', 'daypass_already_held',
      'message', '此會員今日已持有當日暢打，不需再購買');
  end if;

  -- 份數逐人判斷：本次買暢打的話付款人自己這份當場歸零
  v_qty := 0;
  if not v_buy_daypass and not v_self_pass then v_qty := 1; end if;
  if p_pay_for is not null then
    foreach v_target in array p_pay_for loop
      if not has_daypass_tx(v_s.org_id, v_target, v_s.store_id) then v_qty := v_qty + 1; end if;
    end loop;
  end if;
  v_amount := v_unit * v_qty;

  v_items := '[]'::jsonb;
  if v_amount > 0 then
    v_items := v_items || jsonb_build_array(jsonb_build_object(
      'product_id', v_base ->> 'product_id', 'name', v_base ->> 'name',
      'revenue_type', 'venue_fee', 'qty', v_qty, 'unit_price', v_unit));
  end if;
  if v_extra > 0 then v_items := v_items || p_items; end if;

  return jsonb_build_object('ok', true,
    'org_id', v_s.org_id, 'store_id', v_s.store_id, 'table_id', v_s.table_id,
    'unit_fee', v_unit, 'qty', v_qty, 'amount', v_amount,
    'fee_product_id', v_base ->> 'product_id', 'fee_name', v_base ->> 'name',
    'daypass', v_self_pass, 'daypass_bought', v_buy_daypass,
    'extra_items', v_extra, 'items', v_items);
end $fn$;
revoke execute on function public._join_plan(uuid, uuid, text, uuid[], jsonb) from public, anon, authenticated;
grant  execute on function public._join_plan(uuid, uuid, text, uuid[], jsonb) to service_role;

-- ③ checkout_tx 改叫共用核心（簽名、授權、回傳欄位都不變）
create or replace function public.checkout_tx(p_member_id uuid, p_store_id uuid, p_items jsonb, p_coupon_ids uuid[],
                                              p_points_used bigint, p_payments jsonb, p_idempotency_key text, p_staff_id uuid)
returns jsonb
language plpgsql
as $fn$
declare
  v_org uuid; v_order_id uuid; v_order_no text;
  v_price jsonb; v_tier text; v_pct int;
  v_sub bigint; v_nodisc bigint; v_coupon_cut bigint; v_tier_cut bigint; v_payable bigint;
  v_pts bigint; v_cash_due bigint; v_pay_sum bigint := 0; v_bal bigint; v_txn uuid;
  pay jsonb; cl jsonb;
begin
  /* 🔴 操作者身分從 JWT 取，不採信呼叫端送的 p_staff_id（2026-09-04）。
     ⚠ 查不到就是 null（會員 App 那條路沒有 staff 身分），不可以報錯。 */
  p_staff_id := (select staff_id from public.current_staff());
  if p_idempotency_key is null then
    raise exception 'idempotency_key 必填';
  end if;

  select id, order_no into v_order_id, v_order_no from orders where idempotency_key = p_idempotency_key;
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

  -- 先鎖住要用的券，再算錢（兩個店員同時用同一張券時，後到的會等前一個結束）
  if p_coupon_ids is not null and array_length(p_coupon_ids, 1) > 0 then
    perform 1 from member_coupons where id = any(p_coupon_ids) and member_id = p_member_id for update;
  end if;

  /* 🎯 2026-10-01：金額一律由共用核心算 —— POS 的報價（pos_quote_tx）叫的是同一支，
     畫面與實收不可能不一樣。算法本身（主檔價、三個桶、券、等級只折檯費）見 _cart_pricing。 */
  v_price      := public._cart_pricing(v_org, p_member_id, p_items, p_coupon_ids);
  v_sub        := (v_price ->> 'subtotal')::bigint;
  v_nodisc     := (v_price ->> 'non_discountable')::bigint;
  v_coupon_cut := (v_price ->> 'coupon_discount')::bigint;
  v_tier       := v_price ->> 'tier';
  v_pct        := (v_price ->> 'tier_discount_pct')::int;
  v_tier_cut   := (v_price ->> 'tier_discount')::bigint;
  v_payable    := (v_price ->> 'payable')::bigint;

  for cl in select * from jsonb_array_elements(v_price -> 'coupons') loop
    update member_coupons
       set discounted_amount = (cl ->> 'cut')::bigint, cost_bearer = cl ->> 'cost_bearer'
     where id = (cl ->> 'member_coupon_id')::uuid;
  end loop;

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

  -- 品項快照一律寫主檔的值（與上面的金額計算同一個來源）
  insert into order_items(org_id, order_id, product_id, name, spec, revenue_type, qty, unit_price, line_total)
  select v_org, v_order_id, pr.id, pr.name, pr.spec, pr.revenue_type,
         (it2->>'qty')::int, pr.unit_price, (it2->>'qty')::int * pr.unit_price
    from jsonb_array_elements(p_items) it2
    join public.products pr on pr.id = nullif(it2->>'product_id','')::uuid
   where pr.org_id = v_org and pr.deleted_at is null;

  if v_pts > 0 then
    insert into wallet_txns(
      org_id, store_id, member_id, type, amount, status,
      counter_account, idempotency_key, ref_table, ref_id, staff_id, note
    ) values (
      v_org, p_store_id, p_member_id, 'spend', -v_pts, 'completed',
      'liability', p_idempotency_key || ':spend', 'orders', v_order_id, p_staff_id, '消費扣點 ' || v_order_no
    )
    returning id into v_txn;
    update wallets set balance = balance - v_pts where member_id = p_member_id;
    update orders set wallet_txn_id = v_txn where id = v_order_id;
  end if;

  if p_payments is not null then
    for pay in select * from jsonb_array_elements(p_payments) loop
      insert into order_payments(
        org_id, store_id, order_id, method, amount, cash_received, change_given, ref_no, staff_id
      ) values (
        v_org, p_store_id, v_order_id, pay->>'method', (pay->>'amount')::bigint,
        nullif(pay->>'cash_received','')::bigint, nullif(pay->>'change_given','')::bigint,
        nullif(pay->>'ref_no',''), p_staff_id
      );
    end loop;
  end if;

  if p_coupon_ids is not null and array_length(p_coupon_ids, 1) > 0 then
    update member_coupons
       set used_at = now(), used_order = v_order_id, used_txn_id = v_txn, status = 'used'
     where id = any(p_coupon_ids) and member_id = p_member_id;
  end if;

  return jsonb_build_object(
    'order_id', v_order_id, 'order_no', v_order_no,
    'subtotal', v_sub, 'non_discountable', v_nodisc,
    'coupon_discount', v_coupon_cut, 'tier', v_tier, 'tier_discount_pct', v_pct,
    'tier_discount', v_tier_cut, 'payable', v_payable,
    'points_used', v_pts, 'cash_due', v_cash_due, 'new_balance', v_bal - v_pts);
end
$fn$;

-- ④ join_session_tx 改叫 _join_plan（簽名、授權、回傳欄位都不變）
create or replace function public.join_session_tx(p_session_id uuid, p_member_id uuid, p_join_type text DEFAULT 'opener'::text,
  p_coupon_ids uuid[] DEFAULT NULL::uuid[], p_points_used bigint DEFAULT 0, p_payments jsonb DEFAULT NULL::jsonb,
  p_staff_id uuid DEFAULT NULL::uuid, p_idempotency_key text DEFAULT NULL::text, p_pay_for uuid[] DEFAULT NULL::uuid[],
  p_items jsonb DEFAULT NULL::jsonb)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare
  v_plan jsonb; v_items jsonb; v_res jsonb; v_order uuid; v_sp uuid; v_key text; v_seq int;
  v_target uuid; v_created int := 0; v_unit bigint; v_self_pass boolean; v_buy_daypass boolean;
  v_org uuid; v_store uuid;
begin
  /* 🔴 操作者身分從 JWT 取，不採信呼叫端送的 p_staff_id（2026-09-04）。 */
  p_staff_id := (select staff_id from public.current_staff());

  /* 🎯 2026-10-01：入座前的全部檢查與檯費那一行搬到 _join_plan ——
     POS 的報價（pos_quote_tx）叫同一支，畫面上的檯費份數與實收不可能不一樣。 */
  v_plan := public._join_plan(p_session_id, p_member_id, p_join_type, p_pay_for, p_items);
  if not coalesce((v_plan ->> 'ok')::boolean, false) then return v_plan; end if;

  v_items       := v_plan -> 'items';
  v_unit        := (v_plan ->> 'unit_fee')::bigint;
  v_self_pass   := (v_plan ->> 'daypass')::boolean;
  v_buy_daypass := (v_plan ->> 'daypass_bought')::boolean;
  v_org         := (v_plan ->> 'org_id')::uuid;
  v_store       := (v_plan ->> 'store_id')::uuid;

  select count(*) + 1 into v_seq from session_players where session_id = p_session_id and member_id = p_member_id;
  v_key := coalesce(p_idempotency_key, p_session_id::text || ':' || p_member_id::text || ':' || v_seq);

  if jsonb_array_length(v_items) > 0 then
    v_res := checkout_tx(p_member_id, v_store, v_items, p_coupon_ids,
                         coalesce(p_points_used, 0), p_payments, v_key, p_staff_id);
    v_order := (v_res ->> 'order_id')::uuid;
    update orders o
       set session_id = p_session_id,
           table_id   = (v_plan ->> 'table_id')::uuid,
           channel    = 'counter',
           entity_id  = coalesce(o.entity_id, (select entity_id from stores where id = v_store))
     where o.id = v_order;
  end if;

  -- 付款人自己入座
  insert into session_players(
    org_id, session_id, member_id, join_type, status, charged_points, order_id, joined_at, created_by,
    fee_waived_amount, fee_waived_reason)
  values (
    v_org, p_session_id, p_member_id, p_join_type, 'playing',
    coalesce((v_res ->> 'payable')::bigint, 0), v_order, now(), p_staff_id,
    -- 免收金額是使用量指標，不是折讓：不進 orders、不影響營收毛額
    case when (v_self_pass or v_buy_daypass) then v_unit else 0 end,
    case when (v_self_pass or v_buy_daypass) then 'daypass' end)
  returning id into v_sp;

  -- 被代付者一併入座：有入座記錄但沒有訂單，消費金額掛在代付人身上
  if p_pay_for is not null then
    foreach v_target in array p_pay_for loop
      insert into session_players(
        org_id, session_id, member_id, join_type, status, charged_points, order_id, paid_by, joined_at, created_by,
        fee_waived_amount, fee_waived_reason)
      values (
        v_org, p_session_id, v_target, p_join_type, 'playing', 0, null, p_member_id, now(), p_staff_id,
        case when has_daypass_tx(v_org, v_target, v_store) then v_unit else 0 end,
        case when has_daypass_tx(v_org, v_target, v_store) then 'daypass' end);
      v_created := v_created + 1;
    end loop;
  end if;

  return jsonb_build_object('ok', true, 'player_id', v_sp,
    'order_id', v_order, 'unit_fee', v_unit, 'qty', (v_plan ->> 'qty')::int,
    'listed_amount', (v_plan ->> 'amount')::bigint, 'paid_for_count', v_created,
    'extra_items', (v_plan ->> 'extra_items')::int,
    'daypass', v_self_pass, 'daypass_bought', v_buy_daypass,
    'checkout', v_res);
end $fn$;

-- ⑤ POS 的報價
create or replace function public.pos_quote_tx(p_session_id uuid, p_member_id uuid, p_join_type text default 'opener',
                                               p_pay_for uuid[] default null, p_items jsonb default null,
                                               p_coupon_ids uuid[] default null)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $fn$
/* 給 POS 結帳頁畫金額用。**不寫入任何東西**。
   模式跟實際結帳走的那一支判斷方式一樣（由資料庫判斷，不採信前端的推測）：
     quick  沒有桌次                 ⇒ 只有購物車
     join   有桌次、這個人還沒入座   ⇒ 檯費那一行（_join_plan）＋ 購物車
     addon  有桌次、已經入座          ⇒ 只有購物車
   金額一律由 _cart_pricing 算 —— checkout_tx 叫的是同一支。
   錯誤一律回 {ok:false, reason, message}，不拋例外：畫面要能把那句話原樣顯示。 */
declare
  v_mode text; v_org uuid; v_items jsonb; v_plan jsonb := null; v_price jsonb; v_s record;
begin
  perform public._api_staff_only();
  if p_member_id is null then
    return jsonb_build_object('ok', false, 'reason', 'member_required', 'message', '請先選擇會員');
  end if;

  if p_session_id is null then
    v_mode := 'quick';
    select org_id into v_org from members where id = p_member_id and deleted_at is null;
    if v_org is null then
      return jsonb_build_object('ok', false, 'reason', 'member_required', 'message', '需先建立會員資料');
    end if;
    v_items := coalesce(p_items, '[]'::jsonb);
  else
    select id, org_id, status into v_s from table_sessions where id = p_session_id and deleted_at is null;
    if v_s.id is null then
      return jsonb_build_object('ok', false, 'reason', 'session_not_found', 'message', '場次不存在');
    end if;
    if exists (select 1 from session_players
                where session_id = p_session_id and member_id = p_member_id and left_at is null) then
      v_mode := 'addon';
      if v_s.status <> 'open' then
        return jsonb_build_object('ok', false, 'reason', 'session_closed', 'mode', v_mode, 'message', '此場次已結束，無法加購');
      end if;
      v_org := v_s.org_id;
      v_items := coalesce(p_items, '[]'::jsonb);
    else
      v_mode := 'join';
      v_plan := public._join_plan(p_session_id, p_member_id, coalesce(p_join_type, 'opener'), p_pay_for, p_items);
      if not coalesce((v_plan ->> 'ok')::boolean, false) then
        return v_plan || jsonb_build_object('mode', v_mode);
      end if;
      v_org := (v_plan ->> 'org_id')::uuid;
      v_items := v_plan -> 'items';
    end if;
  end if;

  begin
    v_price := public._cart_pricing(v_org, p_member_id, v_items, p_coupon_ids);
  exception when others then
    return jsonb_build_object('ok', false, 'reason', 'pricing', 'mode', v_mode, 'message', sqlerrm);
  end;

  return v_price || jsonb_build_object('ok', true, 'mode', v_mode,
    'fee_line', case when v_plan is null then null else jsonb_build_object(
      'product_id', v_plan ->> 'fee_product_id', 'name', v_plan ->> 'fee_name',
      'unit', (v_plan ->> 'unit_fee')::bigint, 'qty', (v_plan ->> 'qty')::int,
      'amount', (v_plan ->> 'amount')::bigint,
      'daypass', (v_plan ->> 'daypass')::boolean, 'daypass_bought', (v_plan ->> 'daypass_bought')::boolean) end);
end $fn$;
revoke execute on function public.pos_quote_tx(uuid, uuid, text, uuid[], jsonb, uuid[]) from public, anon;
grant  execute on function public.pos_quote_tx(uuid, uuid, text, uuid[], jsonb, uuid[]) to authenticated;

/* ============================================================
   驗證（不 raise —— 這份要留下東西）
   ============================================================ */
do $$
declare v_msg text := ''; v_n int; v_txt text; v_d text;
begin
  -- ① 五支都只有一個版本
  select string_agg(proname || ' ' || c, '、') into v_txt from (
    select proname, count(*) as c from pg_proc
     where pronamespace = 'public'::regnamespace
       and proname in ('_cart_pricing','_join_plan','checkout_tx','join_session_tx','pos_quote_tx')
     group by proname having count(*) <> 1) x;
  select count(distinct proname) into v_n from pg_proc
   where pronamespace = 'public'::regnamespace and proname in ('_cart_pricing','_join_plan','checkout_tx','join_session_tx','pos_quote_tx');
  v_msg := v_msg || case when v_txt is null and v_n = 5 then '✅' else '🔴' end
        || ' ① 五支都在而且只有一個版本（' || v_n || '/5' || coalesce('；多版本：' || v_txt, '') || '）' || E'\n';

  -- ② 授權：兩支核心前端叫不到；報價只給登入的人；checkout_tx／join_session_tx 跟改之前一樣
  v_msg := v_msg || case when
      not has_function_privilege('authenticated', 'public._cart_pricing(uuid,uuid,jsonb,uuid[])', 'execute')
      and not has_function_privilege('anon', 'public._cart_pricing(uuid,uuid,jsonb,uuid[])', 'execute')
      and not has_function_privilege('authenticated', 'public._join_plan(uuid,uuid,text,uuid[],jsonb)', 'execute')
      and not has_function_privilege('anon', 'public._join_plan(uuid,uuid,text,uuid[],jsonb)', 'execute')
      and has_function_privilege('authenticated', 'public.pos_quote_tx(uuid,uuid,text,uuid[],jsonb,uuid[])', 'execute')
      and not has_function_privilege('anon', 'public.pos_quote_tx(uuid,uuid,text,uuid[],jsonb,uuid[])', 'execute')
      and not has_function_privilege('authenticated', 'public.checkout_tx(uuid,uuid,jsonb,uuid[],bigint,jsonb,text,uuid)', 'execute')
      and has_function_privilege('authenticated', 'public.join_session_tx(uuid,uuid,text,uuid[],bigint,jsonb,uuid,text,uuid[],jsonb)', 'execute')
      and not has_function_privilege('anon', 'public.join_session_tx(uuid,uuid,text,uuid[],bigint,jsonb,uuid,text,uuid[],jsonb)', 'execute')
    then '✅' else '🔴' end
    || ' ② 授權：核心兩支前端叫不到、報價只給登入的人、checkout_tx 仍然只有後端、join_session_tx 仍然給登入的人' || E'\n';

  -- ③ 真的接上了：checkout_tx 叫核心、join_session_tx 叫 _join_plan、報價兩支都叫
  v_d := pg_get_functiondef('public.checkout_tx(uuid,uuid,jsonb,uuid[],bigint,jsonb,text,uuid)'::regprocedure);
  v_txt := pg_get_functiondef('public.join_session_tx(uuid,uuid,text,uuid[],bigint,jsonb,uuid,text,uuid[],jsonb)'::regprocedure);
  v_msg := v_msg || case when v_d ~ ':=\s*public\._cart_pricing\(' and v_txt ~ ':=\s*public\._join_plan\('
                          and pg_get_functiondef('public.pos_quote_tx(uuid,uuid,text,uuid[],jsonb,uuid[])'::regprocedure) ~ '_cart_pricing\(.*'
                          and pg_get_functiondef('public.pos_quote_tx(uuid,uuid,text,uuid[],jsonb,uuid[])'::regprocedure) ~ '_join_plan\('
                         then '✅' else '🔴' end || ' ③ checkout_tx → _cart_pricing、join_session_tx → _join_plan、報價兩支都叫' || E'\n';

  -- ④ 算法只剩一份：全庫只有一支函式在算「等級折扣只折檯費」、只有一支在算檯費份數
  select string_agg(p.proname, '、' order by p.proname) into v_txt from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
     and pg_get_functiondef(p.oid) ~ 'round\(rem_fee \* v_pct';
  select count(*) into v_n from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
     and pg_get_functiondef(p.oid) ~ 'v_base\s*:=\s*(public\.)?calc_session_fee_tx\(p_session_id, p_join_type, null\)';
  v_msg := v_msg || case when v_txt = '_cart_pricing' and v_n = 1 then '✅' else '🔴' end
        || ' ④ 算等級折扣的函式：' || coalesce(v_txt, '無') || '（期望只有 _cart_pricing）；算檯費份數的：' || v_n || ' 支（期望 1）' || E'\n';

  -- ⑤ 報價在沒有身分時照樣回得出話（SQL Editor 沒有 API 身分，_api_staff_only 放行）
  v_msg := v_msg || '　⑤ 報價（沒選會員）：' || (public.pos_quote_tx(null, null) ->> 'message');

  perform set_config('migi.v', v_msg, true);
end $$;
select coalesce(nullif(current_setting('migi.v', true), ''), '🔴 沒有驗證訊息') as "驗證";
