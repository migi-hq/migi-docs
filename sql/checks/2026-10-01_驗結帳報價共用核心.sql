/* ============================================================
   行為測試：結帳報價共用核心（交易內，**全部回滾**）
   2026-10-01 · 配 sql/pending/2026-10-01_結帳報價共用核心.sql（先跑那份）

   做法：把**改之前**的 checkout_tx 與 join_session_tx 原封不動複製成暫時函式（pg_temp.*_old），
   同一批情境新舊各跑一次（每一次都在子交易裡跑完就退回），逐項比對：
     ⓐ 結帳 96 案：4 個會員等級 × 3 種購物車 × 8 種用券組合
        比對：小計、不可折扣額、券折抵、等級、等級折扣、應付、扣點、尚需支付、
              每張券記下的折抵額與狀態、訂單品項數與合計；失敗的案例比對錯誤訊息
     ⓑ 報價 ＝ 實收：同樣 96 案，pos_quote_tx（快速結帳模式）的應付必須等於新版結帳的應付；
        結帳失敗的案例，報價要回 ok:false 而且訊息一樣
     ⓒ 入座 7 案（A1 那一場，交易內先把原本四位請離座）：新舊 join_session_tx 逐項比對
        （份數、單價、代付、暢打、入座紀錄、訂單應付），並比對報價的檯費份數與應付
   ⚠ 故意 raise 回滾（硬規則 1.8 的例外），訊息設在 exception handler 裡（硬規則 3.9）
   ============================================================ */

-- ── 改之前的 checkout_tx（2026-10-01 從線上撈的全文，只改名字）──
create or replace function pg_temp.checkout_tx_old(p_member_id uuid, p_store_id uuid, p_items jsonb, p_coupon_ids uuid[],
  p_points_used bigint, p_payments jsonb, p_idempotency_key text, p_staff_id uuid)
returns jsonb language plpgsql as $old$
declare
  v_org uuid; v_order_id uuid; v_order_no text; v_tier text; v_pct int;
  v_sub bigint := 0; v_fee bigint := 0; v_fnb bigint := 0; v_goods bigint := 0; v_nodisc bigint := 0;
  v_coupon_cut bigint := 0; v_tier_cut bigint := 0; v_payable bigint; v_pts bigint; v_cash_due bigint;
  v_pay_sum bigint := 0; v_bal bigint; v_txn uuid; it jsonb; cp record; pay jsonb;
  rem_fee bigint; rem_fnb bigint; rem_goods bigint; cap bigint; cut bigint;
begin
  p_staff_id := (select staff_id from public.current_staff());
  if p_idempotency_key is null then raise exception 'idempotency_key 必填'; end if;
  select id, order_no into v_order_id, v_order_no from orders where idempotency_key = p_idempotency_key;
  if found then
    select balance into v_bal from wallets where member_id = p_member_id;
    return jsonb_build_object('idempotent', true, 'order_id', v_order_id, 'order_no', v_order_no, 'new_balance', v_bal);
  end if;
  select org_id into v_org from stores where id = p_store_id;
  if v_org is null then raise exception 'store % 不存在', p_store_id; end if;
  if p_items is null or jsonb_array_length(p_items) = 0 then raise exception '沒有可結帳的品項'; end if;
  for it in select * from jsonb_array_elements(p_items) loop
    declare
      l_pid uuid := nullif(it->>'product_id','')::uuid; l_qty int := (it->>'qty')::int;
      l_price bigint; l_name text; l_bucket text; l_disc boolean; l_line bigint;
    begin
      if l_pid is null then raise exception '品項缺少 product_id：%', coalesce(it->>'name', '(未命名)'); end if;
      select pr.unit_price, pr.name, pr.revenue_type, pr.discountable into l_price, l_name, l_bucket, l_disc
        from public.products pr where pr.id = l_pid and pr.org_id = v_org and pr.deleted_at is null;
      if not found then raise exception '商品不存在或不屬於本機構：%', l_pid; end if;
      if l_qty <= 0 then raise exception '品項數量不合法：%', l_qty; end if;
      if l_price < 0 then raise exception '商品 % 主檔單價為負', l_name; end if;
      if l_bucket not in ('venue_fee','fnb','retail','other') then
        raise exception '商品 % 的 revenue_type 尚未支援：%', l_name, l_bucket;
      end if;
      l_line := l_qty * l_price; v_sub := v_sub + l_line;
      if not l_disc then v_nodisc := v_nodisc + l_line;
      elsif l_bucket = 'venue_fee' then v_fee := v_fee + l_line;
      elsif l_bucket = 'fnb' then v_fnb := v_fnb + l_line;
      else v_goods := v_goods + l_line; end if;
    end;
  end loop;
  rem_fee := v_fee; rem_fnb := v_fnb; rem_goods := v_goods;
  if p_coupon_ids is not null and array_length(p_coupon_ids,1) > 0 then
    for cp in
      select mc.id as mc_id, c.name as c_name, c.applies_to, c.discount_type, c.discount_value,
             c.min_spend, c.max_discount, c.free_product_id, c.cost_bearer
        from member_coupons mc join coupons c on c.id = mc.coupon_id
       where mc.id = any(p_coupon_ids) and mc.member_id = p_member_id
       for update of mc
    loop
      perform 1 from member_coupons where id = cp.mc_id and used_at is null and coalesce(status,'') <> 'used'
        and (expires_at is null or expires_at > now());
      if not found then raise exception '券 % 已使用或已過期', cp.c_name; end if;
      cap := case cp.applies_to when 'table_fee' then rem_fee when 'fnb' then rem_fnb else 0 end;
      if cp.applies_to is null then cap := rem_fee + rem_fnb + rem_goods; end if;
      if cp.discount_type = 'free' and cp.free_product_id is not null then
        select coalesce(sum((it2->>'qty')::int * pr2.unit_price), 0) into cap
          from jsonb_array_elements(p_items) it2 join public.products pr2 on pr2.id = nullif(it2->>'product_id','')::uuid
         where pr2.id = cp.free_product_id and pr2.org_id = v_org and pr2.deleted_at is null and pr2.discountable;
        if cap <= 0 then raise exception '券 % 指定商品不在本次訂單中，或該商品不參與折扣', cp.c_name; end if;
      elsif cap <= 0 then raise exception '券 % 不適用於本次品項', cp.c_name;
      end if;
      if cp.min_spend is not null and cap < cp.min_spend then
        raise exception '券 % 需最低消費 %（本次適用範圍僅 %）', cp.c_name, cp.min_spend, cap;
      end if;
      cut := case cp.discount_type when 'free' then cap
               when 'percent' then round(cap * coalesce(cp.discount_value,0) / 100.0)
               else least(coalesce(cp.discount_value,0), cap) end;
      if cp.max_discount is not null and cut > cp.max_discount then cut := cp.max_discount; end if;
      cut := least(cut, cap);
      if cut <= 0 then raise exception '券 % 折抵金額為 0', cp.c_name; end if;
      v_coupon_cut := v_coupon_cut + cut;
      update member_coupons set discounted_amount = cut, cost_bearer = cp.cost_bearer where id = cp.mc_id;
      if cp.applies_to = 'table_fee' then rem_fee := rem_fee - cut;
      elsif cp.applies_to = 'fnb' then rem_fnb := rem_fnb - cut;
      else
        declare r bigint := cut; d bigint;
        begin
          d := least(r, rem_fee); rem_fee := rem_fee - d; r := r - d;
          d := least(r, rem_fnb); rem_fnb := rem_fnb - d; r := r - d;
          d := least(r, rem_goods); rem_goods := rem_goods - d;
        end;
      end if;
    end loop;
  end if;
  select coalesce(tier_override, tier) into v_tier from members where id = p_member_id;
  select coalesce(t.discount_pct, 0) into v_pct from member_tiers t where t.code = v_tier and t.is_active;
  v_pct := coalesce(v_pct, 0);
  v_tier_cut := round(rem_fee * v_pct / 100.0);
  v_payable := v_sub - v_coupon_cut - v_tier_cut;
  if v_payable < 0 then raise exception '應付金額為負，折扣計算有誤'; end if;
  select balance into v_bal from wallets where member_id = p_member_id for update;
  if v_bal is null then raise exception 'member % 沒有錢包', p_member_id; end if;
  v_pts := greatest(0, least(coalesce(p_points_used,0), least(v_bal, v_payable)));
  v_cash_due := v_payable - v_pts;
  if p_payments is not null then
    for pay in select * from jsonb_array_elements(p_payments) loop v_pay_sum := v_pay_sum + (pay->>'amount')::bigint; end loop;
  end if;
  if v_pay_sum <> v_cash_due then raise exception '收款金額 % 與尚需支付 % 不符', v_pay_sum, v_cash_due; end if;
  insert into orders(id, org_id, store_id, member_id, status, subtotal, coupon_discount, tier_discount, payable, points_used, cash_due,
                     tier_at_order, tier_discount_pct, idempotency_key, created_by, paid_at)
  values (gen_random_uuid(), v_org, p_store_id, p_member_id, 'paid', v_sub, v_coupon_cut, v_tier_cut, v_payable, v_pts, v_cash_due,
          v_tier, v_pct, p_idempotency_key, p_staff_id, now())
  returning id, order_no into v_order_id, v_order_no;
  insert into order_items(org_id, order_id, product_id, name, spec, revenue_type, qty, unit_price, line_total)
  select v_org, v_order_id, pr.id, pr.name, pr.spec, pr.revenue_type, (it2->>'qty')::int, pr.unit_price, (it2->>'qty')::int * pr.unit_price
    from jsonb_array_elements(p_items) it2 join public.products pr on pr.id = nullif(it2->>'product_id','')::uuid
   where pr.org_id = v_org and pr.deleted_at is null;
  if v_pts > 0 then
    insert into wallet_txns(org_id, store_id, member_id, type, amount, status, counter_account, idempotency_key, ref_table, ref_id, staff_id, note)
    values (v_org, p_store_id, p_member_id, 'spend', -v_pts, 'completed', 'liability', p_idempotency_key || ':spend',
            'orders', v_order_id, p_staff_id, '消費扣點 ' || v_order_no)
    returning id into v_txn;
    update wallets set balance = balance - v_pts where member_id = p_member_id;
    update orders set wallet_txn_id = v_txn where id = v_order_id;
  end if;
  if p_payments is not null then
    for pay in select * from jsonb_array_elements(p_payments) loop
      insert into order_payments(org_id, store_id, order_id, method, amount, cash_received, change_given, ref_no, staff_id)
      values (v_org, p_store_id, v_order_id, pay->>'method', (pay->>'amount')::bigint,
              nullif(pay->>'cash_received','')::bigint, nullif(pay->>'change_given','')::bigint, nullif(pay->>'ref_no',''), p_staff_id);
    end loop;
  end if;
  if p_coupon_ids is not null and array_length(p_coupon_ids,1) > 0 then
    update member_coupons set used_at = now(), used_order = v_order_id, used_txn_id = v_txn, status = 'used'
     where id = any(p_coupon_ids) and member_id = p_member_id;
  end if;
  return jsonb_build_object('order_id', v_order_id, 'order_no', v_order_no, 'subtotal', v_sub, 'non_discountable', v_nodisc,
    'coupon_discount', v_coupon_cut, 'tier', v_tier, 'tier_discount_pct', v_pct, 'tier_discount', v_tier_cut,
    'payable', v_payable, 'points_used', v_pts, 'cash_due', v_cash_due, 'new_balance', v_bal - v_pts);
end $old$;

-- ── 改之前的 join_session_tx（只改名字，以及結帳改叫上面那支舊版）──
create or replace function pg_temp.join_session_tx_old(p_session_id uuid, p_member_id uuid, p_join_type text,
  p_coupon_ids uuid[], p_points_used bigint, p_payments jsonb, p_staff_id uuid, p_idempotency_key text, p_pay_for uuid[], p_items jsonb)
returns jsonb language plpgsql as $old$
declare
  v_s record; v_base jsonb; v_unit bigint; v_qty int; v_amount bigint; v_items jsonb; v_res jsonb; v_order uuid; v_sp uuid;
  v_key text; v_seq int; v_target uuid; v_created int := 0; v_extra int := 0;
  v_buy_daypass boolean := false; v_self_pass boolean := false;
begin
  p_staff_id := (select staff_id from public.current_staff());
  if p_join_type not in ('opener','mid_join','sub') then return jsonb_build_object('ok', false, 'reason', 'invalid_join_type'); end if;
  if p_items is not null and jsonb_typeof(p_items) = 'array' then v_extra := jsonb_array_length(p_items); end if;
  if v_extra > 0 then
    select exists (select 1 from jsonb_array_elements(p_items) it
                    where exists (select 1 from products pr where pr.id = nullif(it ->> 'product_id', '')::uuid and pr.sku = 'SVC-TBL-DAY'))
      into v_buy_daypass;
    if exists (select 1 from jsonb_array_elements(p_items) it join products pr on pr.id = nullif(it ->> 'product_id', '')::uuid
                where pr.revenue_type = 'venue_fee' and pr.sku <> 'SVC-TBL-DAY' and pr.deleted_at is null) then
      return jsonb_build_object('ok', false, 'reason', 'fee_item_not_allowed', 'message', '場地費由系統計算，不可由前端傳入');
    end if;
    if exists (select 1 from jsonb_array_elements(p_items) it where it ->> 'is_topup' = 'true' or it ->> 'revenue_type' = 'topup') then
      return jsonb_build_object('ok', false, 'reason', 'topup_not_allowed', 'message', '儲值請走儲值流程，不能併入結帳');
    end if;
    if exists (select 1 from jsonb_array_elements(p_items) it
                where nullif(it ->> 'product_id', '') is null or coalesce((it ->> 'qty')::int, 0) <= 0)
       or exists (select 1 from jsonb_array_elements(p_items) it
                    left join products pr on pr.id = nullif(it ->> 'product_id', '')::uuid and pr.deleted_at is null
                   where nullif(it ->> 'product_id', '') is not null
                     and (pr.id is null or (pr.revenue_type not in ('fnb','retail','other') and pr.sku <> 'SVC-TBL-DAY'))) then
      return jsonb_build_object('ok', false, 'reason', 'invalid_item',
        'message', '品項需有存在的 product_id、數量大於 0，且收入桶為 fnb／retail／other');
    end if;
  end if;
  select * into v_s from table_sessions where id = p_session_id;
  if v_s.id is null then return jsonb_build_object('ok', false, 'reason', 'session_not_found'); end if;
  if v_s.status <> 'open' then return jsonb_build_object('ok', false, 'reason', 'session_closed', 'message', '此場次已收桌或已作廢'); end if;
  if not exists (select 1 from members where id = p_member_id and deleted_at is null) then
    return jsonb_build_object('ok', false, 'reason', 'member_required', 'message', '需先建立會員資料');
  end if;
  if exists (select 1 from session_players where session_id = p_session_id and member_id = p_member_id and left_at is null) then
    return jsonb_build_object('ok', false, 'reason', 'already_joined');
  end if;
  if (select count(*) from session_players where session_id = p_session_id and left_at is null) + 1 + coalesce(array_length(p_pay_for, 1), 0) > 4 then
    return jsonb_build_object('ok', false, 'reason', 'table_full');
  end if;
  if p_pay_for is not null then
    foreach v_target in array p_pay_for loop
      if v_target = p_member_id then return jsonb_build_object('ok', false, 'reason', 'cannot_pay_for_self'); end if;
      if not exists (select 1 from members where id = v_target and deleted_at is null) then
        return jsonb_build_object('ok', false, 'reason', 'payfor_member_invalid', 'member_id', v_target);
      end if;
      if exists (select 1 from session_players where session_id = p_session_id and member_id = v_target and left_at is null) then
        return jsonb_build_object('ok', false, 'reason', 'payfor_already_joined', 'member_id', v_target);
      end if;
    end loop;
  end if;
  v_base := calc_session_fee_tx(p_session_id, p_join_type, null);
  if not (v_base ->> 'ok')::boolean then return v_base; end if;
  v_unit := coalesce((v_base ->> 'amount')::bigint, 0);
  v_self_pass := has_daypass_tx(v_s.org_id, p_member_id, v_s.store_id);
  if v_buy_daypass and v_self_pass then
    return jsonb_build_object('ok', false, 'reason', 'daypass_already_held', 'message', '此會員今日已持有當日暢打，不需再購買');
  end if;
  v_qty := 0;
  if not v_buy_daypass and not v_self_pass then v_qty := 1; end if;
  if p_pay_for is not null then
    foreach v_target in array p_pay_for loop
      if not has_daypass_tx(v_s.org_id, v_target, v_s.store_id) then v_qty := v_qty + 1; end if;
    end loop;
  end if;
  v_amount := v_unit * v_qty;
  select count(*) + 1 into v_seq from session_players where session_id = p_session_id and member_id = p_member_id;
  v_key := coalesce(p_idempotency_key, p_session_id::text || ':' || p_member_id::text || ':' || v_seq);
  v_items := '[]'::jsonb;
  if v_amount > 0 then
    v_items := v_items || jsonb_build_array(jsonb_build_object('product_id', v_base ->> 'product_id', 'name', v_base ->> 'name',
      'revenue_type', 'venue_fee', 'qty', v_qty, 'unit_price', v_unit));
  end if;
  if v_extra > 0 then v_items := v_items || p_items; end if;
  if jsonb_array_length(v_items) > 0 then
    v_res := pg_temp.checkout_tx_old(p_member_id, v_s.store_id, v_items, p_coupon_ids, coalesce(p_points_used, 0), p_payments, v_key, p_staff_id);
    v_order := (v_res ->> 'order_id')::uuid;
    update orders o set session_id = p_session_id, table_id = v_s.table_id, channel = 'counter',
           entity_id = coalesce(o.entity_id, (select entity_id from stores where id = v_s.store_id))
     where o.id = v_order;
  end if;
  insert into session_players(org_id, session_id, member_id, join_type, status, charged_points, order_id, joined_at, created_by,
                              fee_waived_amount, fee_waived_reason)
  values (v_s.org_id, p_session_id, p_member_id, p_join_type, 'playing', coalesce((v_res ->> 'payable')::bigint, 0), v_order, now(), p_staff_id,
          case when (v_self_pass or v_buy_daypass) then v_unit else 0 end, case when (v_self_pass or v_buy_daypass) then 'daypass' end)
  returning id into v_sp;
  if p_pay_for is not null then
    foreach v_target in array p_pay_for loop
      insert into session_players(org_id, session_id, member_id, join_type, status, charged_points, order_id, paid_by, joined_at, created_by,
                                  fee_waived_amount, fee_waived_reason)
      values (v_s.org_id, p_session_id, v_target, p_join_type, 'playing', 0, null, p_member_id, now(), p_staff_id,
              case when has_daypass_tx(v_s.org_id, v_target, v_s.store_id) then v_unit else 0 end,
              case when has_daypass_tx(v_s.org_id, v_target, v_s.store_id) then 'daypass' end);
      v_created := v_created + 1;
    end loop;
  end if;
  return jsonb_build_object('ok', true, 'player_id', v_sp, 'order_id', v_order, 'unit_fee', v_unit, 'qty', v_qty,
    'listed_amount', v_amount, 'paid_for_count', v_created, 'extra_items', v_extra,
    'daypass', v_self_pass, 'daypass_bought', v_buy_daypass, 'checkout', v_res);
end $old$;

-- ── 跑一次結帳、把結果整理成可比對的形狀，然後退回（變數不會跟著退回）──
create or replace function pg_temp.run_co(p_which text, p_member uuid, p_store uuid, p_items jsonb, p_coupons uuid[])
returns jsonb language plpgsql as $f$
declare r jsonb; v_out jsonb;
begin
  begin
    if p_which = 'old' then
      r := pg_temp.checkout_tx_old(p_member, p_store, p_items, p_coupons, 1000000000, null, 'migi-cmp-key', null);
    else
      r := public.checkout_tx(p_member, p_store, p_items, p_coupons, 1000000000, null, 'migi-cmp-key', null);
    end if;
    v_out := jsonb_build_object(
      'subtotal', r->'subtotal', 'non_discountable', r->'non_discountable', 'coupon_discount', r->'coupon_discount',
      'tier', r->'tier', 'tier_discount_pct', r->'tier_discount_pct', 'tier_discount', r->'tier_discount',
      'payable', r->'payable', 'points_used', r->'points_used', 'cash_due', r->'cash_due',
      'coupons', (select jsonb_agg(jsonb_build_object('n', c.name, 'd', mc.discounted_amount, 's', mc.status, 'cb', mc.cost_bearer) order by c.name)
                    from member_coupons mc join coupons c on c.id = mc.coupon_id where mc.id = any(p_coupons)),
      'items', (select jsonb_build_object('n', count(*), 's', sum(line_total)) from order_items where order_id = (r->>'order_id')::uuid));
    raise exception 'migi_undo';
  exception when others then
    if sqlerrm <> 'migi_undo' then v_out := jsonb_build_object('error', sqlerrm); end if;
  end;
  return v_out;
end $f$;

create or replace function pg_temp.run_join(p_which text, p_session uuid, p_member uuid, p_type text, p_pay_for uuid[], p_items jsonb)
returns jsonb language plpgsql as $f$
declare r jsonb; v_out jsonb;
begin
  begin
    if p_which = 'old' then
      r := pg_temp.join_session_tx_old(p_session, p_member, p_type, null, 1000000000, null, null, 'migi-cmp-join', p_pay_for, p_items);
    else
      r := public.join_session_tx(p_session, p_member, p_type, null, 1000000000, null, null, 'migi-cmp-join', p_pay_for, p_items);
    end if;
    v_out := (r - 'player_id' - 'order_id' - 'checkout') || jsonb_build_object(
      'payable', r->'checkout'->'payable', 'subtotal', r->'checkout'->'subtotal', 'tier_discount', r->'checkout'->'tier_discount',
      'seated', (select jsonb_agg(jsonb_build_object('w', sp.fee_waived_amount, 'r', sp.fee_waived_reason, 'c', sp.charged_points,
                                                     'payer', sp.paid_by is not null) order by sp.member_id)
                   from session_players sp where sp.session_id = p_session and sp.left_at is null));
    raise exception 'migi_undo';
  exception when others then
    if sqlerrm <> 'migi_undo' then v_out := jsonb_build_object('error', sqlerrm); end if;
  end;
  return v_out;
end $f$;

-- ⓐ＋ⓑ 結帳 96 案
do $$
declare
  x uuid := '526aa8b9-cc93-4327-b878-6d21d399af8e';   -- 測試04
  v_org uuid := '11111111-1111-1111-1111-111111111111';
  v_store uuid; p_fee uuid; p_dk uuid; p_lt uuid; p_day uuid; p_rt uuid;
  c1 uuid; c2 uuid; c3 uuid; c4 uuid; c5 uuid; c6 uuid; v_cp uuid;
  v_tier text; v_items jsonb; v_combo uuid[]; v_old jsonb; v_new jsonb; v_q jsonb;
  v_n int := 0; v_same int := 0; v_qn int := 0; v_qsame int := 0; v_ok_cases int := 0; v_err_cases int := 0;
  v_bad text := ''; v_qbad text := ''; v_msg text;
begin
  select store_id into v_store from public.table_sessions where id = '1ea984c6-e15e-4888-a4d6-9f99f0860120';
  if v_store is null then raise exception '🔴 找不到 A1 那一場，這份測不了'; end if;
  select id into p_fee from public.products where sku = 'SVC-TBL-M3' and org_id = v_org and deleted_at is null;
  select id into p_dk  from public.products where sku = 'FNB-DRK-BLCK' and org_id = v_org and deleted_at is null;
  select id into p_lt  from public.products where sku = 'FNB-DRK-LATT' and org_id = v_org and deleted_at is null;
  select id into p_day from public.products where sku = 'SVC-TBL-DAY' and org_id = v_org and deleted_at is null;
  insert into public.products (org_id, sku, name, category, unit_price, revenue_type)
  values (v_org, 'ZZ-TEST-RETAIL', '測試周邊', 'merch', 120, 'retail') returning id into p_rt;
  if p_fee is null or p_dk is null or p_lt is null or p_day is null then raise exception '🔴 樣本商品找不到'; end if;

  update public.wallets set balance = 1000000000 where member_id = x;
  update public.members set tier_override = null where id = x;

  -- 六張券：檯費 9 折、不指定範圍折 100（上限 60）、指定紅茶免費、餐飲滿 500 折 30、已過期、指定拿鐵免費
  insert into public.coupons (org_id, name, kind, discount_type, discount_value, applies_to) values (v_org, 'ZZ1 檯費九折', 'generic', 'percent', 10, 'table_fee') returning id into v_cp;
  insert into public.member_coupons (org_id, member_id, coupon_id) values (v_org, x, v_cp) returning id into c1;
  insert into public.coupons (org_id, name, kind, discount_type, discount_value, applies_to, max_discount) values (v_org, 'ZZ2 折一百', 'generic', 'fixed', 100, null, 60) returning id into v_cp;
  insert into public.member_coupons (org_id, member_id, coupon_id) values (v_org, x, v_cp) returning id into c2;
  insert into public.coupons (org_id, name, kind, discount_type, applies_to, free_product_id, cost_bearer) values (v_org, 'ZZ3 紅茶免費', 'generic', 'free', 'fnb', p_dk, 'hq') returning id into v_cp;
  insert into public.member_coupons (org_id, member_id, coupon_id) values (v_org, x, v_cp) returning id into c3;
  insert into public.coupons (org_id, name, kind, discount_type, discount_value, applies_to, min_spend) values (v_org, 'ZZ4 滿五百折三十', 'generic', 'fixed', 30, 'fnb', 500) returning id into v_cp;
  insert into public.member_coupons (org_id, member_id, coupon_id) values (v_org, x, v_cp) returning id into c4;
  insert into public.coupons (org_id, name, kind, discount_type, discount_value, applies_to) values (v_org, 'ZZ5 過期券', 'generic', 'percent', 50, null) returning id into v_cp;
  insert into public.member_coupons (org_id, member_id, coupon_id, expires_at) values (v_org, x, v_cp, now() - interval '1 day') returning id into c5;
  insert into public.coupons (org_id, name, kind, discount_type, applies_to, free_product_id) values (v_org, 'ZZ6 拿鐵免費', 'generic', 'free', 'fnb', p_lt) returning id into v_cp;
  insert into public.member_coupons (org_id, member_id, coupon_id) values (v_org, x, v_cp) returning id into c6;

  foreach v_tier in array array['bubble_tea','caramel_pudding','tiramisu','chef_special'] loop
    update public.members set tier = v_tier where id = x;
    for v_items in select * from (values
        (jsonb_build_array(jsonb_build_object('product_id', p_fee, 'qty', 2), jsonb_build_object('product_id', p_dk, 'qty', 1))),
        (jsonb_build_array(jsonb_build_object('product_id', p_fee, 'qty', 1), jsonb_build_object('product_id', p_rt, 'qty', 2),
                           jsonb_build_object('product_id', p_day, 'qty', 1), jsonb_build_object('product_id', p_lt, 'qty', 1))),
        (jsonb_build_array(jsonb_build_object('product_id', p_dk, 'qty', 3)))) t(i)
    loop
      foreach v_combo slice 1 in array array[
          array[null,null]::uuid[], array[c1,null], array[c2,null], array[c3,null],
          array[c4,null], array[c5,null], array[c6,null], array[c1,c3]] loop
        v_combo := array_remove(v_combo, null);
        v_old := pg_temp.run_co('old', x, v_store, v_items, case when cardinality(v_combo) = 0 then null else v_combo end);
        v_new := pg_temp.run_co('new', x, v_store, v_items, case when cardinality(v_combo) = 0 then null else v_combo end);
        v_n := v_n + 1;
        if v_old = v_new then v_same := v_same + 1;
        elsif length(v_bad) < 1500 then
          v_bad := v_bad || E'\n    ✗ ' || v_tier || ' 券' || cardinality(v_combo) || '張 舊 ' || v_old::text || E'\n      新 ' || v_new::text;
        end if;
        if v_new ? 'error' then v_err_cases := v_err_cases + 1; else v_ok_cases := v_ok_cases + 1; end if;

        -- ⓑ 報價 ＝ 實收
        v_q := public.pos_quote_tx(null, x, 'opener', null, v_items, case when cardinality(v_combo) = 0 then null else v_combo end);
        v_qn := v_qn + 1;
        if (v_new ? 'error' and not (v_q ->> 'ok')::boolean and v_q ->> 'message' = v_new ->> 'error')
           or (not v_new ? 'error' and (v_q ->> 'ok')::boolean
               and (v_q -> 'payable') = (v_new -> 'payable') and (v_q -> 'coupon_discount') = (v_new -> 'coupon_discount')
               and (v_q -> 'tier_discount') = (v_new -> 'tier_discount') and (v_q -> 'subtotal') = (v_new -> 'subtotal')) then
          v_qsame := v_qsame + 1;
        elsif length(v_qbad) < 1000 then
          v_qbad := v_qbad || E'\n    ✗ 報價 ' || v_q::text || E'\n      實收 ' || v_new::text;
        end if;
      end loop;
    end loop;
  end loop;

  v_msg := case when v_same = v_n and v_n = 96 then '✅' else '🔴' end
        || ' ⓐ 結帳新舊一致 ' || v_same || ' / ' || v_n || '（成功 ' || v_ok_cases || ' 案、失敗 ' || v_err_cases || ' 案，兩種都要有）' || v_bad || E'\n'
        || case when v_qsame = v_qn and v_qn = 96 then '✅' else '🔴' end
        || ' ⓑ 報價與實收一致 ' || v_qsame || ' / ' || v_qn || v_qbad || E'\n';
  if v_ok_cases = 0 or v_err_cases = 0 then v_msg := v_msg || '🔴 成功或失敗的案例有一種是 0 —— 這樣比對不出東西' || E'\n'; end if;
  raise exception 'migi_rollback';
exception when others then
  if sqlerrm = 'migi_rollback' then perform set_config('migi.a', v_msg, true);
  else perform set_config('migi.a', coalesce(v_msg, '') || '🔴 中途出錯：' || sqlstate || ' ' || sqlerrm, true); end if;
end $$;

-- ⓒ 入座 7 案
-- ⚠ 2026-10-01 第一次跑：借 A1 那一場，而測試01～04 都坐在那一場 ⇒ 同一場同一人只能有一筆入座紀錄，
--   四個「該成功」的案例新舊兩版**一起失敗**，於是「新舊一致」是假綠。
--   改成交易內在空桌 C2 開一場新的，並加上正對照：該成功的 4 案一定要真的成功。
do $$
declare
  v_sid uuid;
  x uuid := '526aa8b9-cc93-4327-b878-6d21d399af8e';   -- 測試04
  y uuid := '218378e1-fb6c-43fb-b642-99fdbf5c52b1';   -- 測試02
  z uuid := 'd0db928e-5a75-4535-90d4-93ede67790a8';   -- 測試03
  p uuid := '69016205-afde-4036-95a6-5893c9d0e5fe';   -- 咖勁凱
  v_org uuid := '11111111-1111-1111-1111-111111111111';
  p_fee uuid; p_dk uuid; p_day uuid;
  v_type text; v_pf uuid[]; v_items jsonb; v_old jsonb; v_new jsonb; v_q jsonb; v_case text;
  v_n int := 0; v_same int := 0; v_qn int := 0; v_qsame int := 0; v_bad text := ''; v_msg text; v_okn int := 0;
begin
  select id into p_fee from public.products where sku = 'SVC-TBL-M3' and org_id = v_org and deleted_at is null;
  select id into p_dk  from public.products where sku = 'FNB-DRK-BLCK' and org_id = v_org and deleted_at is null;
  select id into p_day from public.products where sku = 'SVC-TBL-DAY' and org_id = v_org and deleted_at is null;
  -- 交易內在空桌開一場新的 3 將配桌（跟 A1 同一種，檯費 150、中途加入 100）
  insert into public.table_sessions (org_id, store_id, table_id, mode, planned_rounds)
  select v_org, t.store_id, t.id, 'matched', 3 from public.tables t
   where t.store_id = '22222222-2222-2222-2222-222222222222'
     and not exists (select 1 from public.table_sessions s where s.table_id = t.id and s.status = 'open' and s.deleted_at is null)
   order by t.label limit 1
  returning id into v_sid;
  if v_sid is null then raise exception '🔴 找不到空桌，這一段測不了'; end if;
  update public.wallets set balance = 1000000000 where member_id = x;

  for v_case, v_type, v_pf, v_items in select * from (values
      ('只有檯費',       'opener',  null::uuid[],  null::jsonb),
      ('代付一人＋飲料', 'opener',  array[y],      jsonb_build_array(jsonb_build_object('product_id', p_dk, 'qty', 1))),
      ('買暢打',         'mid_join', null::uuid[], jsonb_build_array(jsonb_build_object('product_id', p_day, 'qty', 1))),
      ('代付三人',       'opener',  array[y, z, p], null::jsonb),
      ('代付自己',       'opener',  array[x],      null::jsonb),
      ('前端送檯費',     'opener',  null::uuid[],  jsonb_build_array(jsonb_build_object('product_id', p_fee, 'qty', 1))),
      ('入座方式不對',   'bad',     null::uuid[],  null::jsonb)) t(a, b, c, d)
  loop
    v_old := pg_temp.run_join('old', v_sid, x, v_type, v_pf, v_items);
    v_new := pg_temp.run_join('new', v_sid, x, v_type, v_pf, v_items);
    v_n := v_n + 1;
    if coalesce((v_new ->> 'ok')::boolean, false) then v_okn := v_okn + 1; end if;
    if v_old = v_new then v_same := v_same + 1;
    else v_bad := v_bad || E'\n    ✗ ' || v_case || ' 舊 ' || v_old::text || E'\n      新 ' || v_new::text; end if;

    -- 報價：成功的案例份數與應付要一樣；失敗的案例原因要一樣
    v_q := public.pos_quote_tx(v_sid, x, v_type, v_pf, v_items, null);
    v_qn := v_qn + 1;
    if ((v_new ->> 'ok')::boolean and (v_q ->> 'ok')::boolean
         and (v_q -> 'fee_line' ->> 'qty')::int = (v_new ->> 'qty')::int
         and coalesce((v_q ->> 'payable')::bigint, 0) = coalesce((v_new ->> 'payable')::bigint, 0))
       or (not coalesce((v_new ->> 'ok')::boolean, false) and not (v_q ->> 'ok')::boolean and v_q ->> 'reason' = v_new ->> 'reason') then
      v_qsame := v_qsame + 1;
    else v_bad := v_bad || E'\n    ✗ 報價 ' || v_case || ' ' || v_q::text || E'\n      實收 ' || v_new::text; end if;
  end loop;

  v_msg := case when v_same = v_n and v_n = 7 and v_okn = 4 then '✅' else '🔴' end || ' ⓒ 入座新舊一致 ' || v_same || ' / ' || v_n
        || '（其中真的入座成功 ' || v_okn || ' 案，期望 4 —— 少了就是兩版一起失敗）' || E'\n'
        || case when v_qsame = v_qn and v_qn = 7 then '✅' else '🔴' end || ' ⓒ 入座的報價與實收一致 ' || v_qsame || ' / ' || v_qn
        || v_bad || E'\n';
  raise exception 'migi_rollback';
exception when others then
  if sqlerrm = 'migi_rollback' then perform set_config('migi.c', v_msg, true);
  else perform set_config('migi.c', coalesce(v_msg, '') || '🔴 中途出錯：' || sqlstate || ' ' || sqlerrm, true); end if;
end $$;

select coalesce(nullif(current_setting('migi.a', true), ''), '🔴 ⓐⓑ 沒有訊息') || E'\n'
    || coalesce(nullif(current_setting('migi.c', true), ''), '🔴 ⓒ 沒有訊息') as "行為測試";
