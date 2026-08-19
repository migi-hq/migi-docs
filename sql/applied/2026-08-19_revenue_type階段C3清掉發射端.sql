-- 【待執行】revenue_type 階段 C-3：清掉雙軌發射端，並修好三道失效的擋牆
-- ============================================================
-- 🔴 這支是修 bug，不是整理。階段 B 上線之後 join_session_tx 的品項白名單是
--       coalesce(it ->> 'kind', '') not in ('fee','fnb','goods')
--    而 POS 送的是 revenue_type，`it->>'kind'` 是 null → '' → 不在白名單
--    → **入座時只要帶任何品項就會被拒**（買暢打、開桌同時點餐飲）。
--    不帶品項的入座（純收檯費）因為 v_extra = 0 跳過驗證，所以還是好的
--    —— 這就是為什麼沒有人立刻發現。
--    pos_addon_checkout_tx 沒有品項驗證（直接委派 checkout_tx），加購不受影響。
--
-- 【為什麼改用完整 CREATE OR REPLACE】
--   join_session_tx 裡跟 kind 有關的有六行、三種語意：
--     暢打偵測的註解 / 場地費擋牆 / 儲值擋牆 / 品項白名單。
--   前一版本檔用 DO 單點替換只換掉其中兩處，被自己的
--   「仍有 kind 殘留就 raise」擋下並整支回滾 —— 那個 guard 做對了事。
--   同一支函式一天內判斷錯兩次之後，繼續猜錨點是在賭。
--   簽名完全未變，所以 CREATE OR REPLACE 不需要先 DROP（硬規則 2 不適用）。
--   線上定義於 2026-08-19 以 pg_get_functiondef 撈出，本檔只改該改的行。
--
-- 【三道擋牆的新樣子】
--   ① 場地費   it->>'revenue_type' = 'venue_fee'，暢打（SVC-TBL-DAY）例外放行
--   ② 儲值     改看 is_topup 旗標。儲值不是收入桶所以沒有 revenue_type 可比，
--              前端也改用獨立旗標了（階段 B）。順帶接住誤填 'topup' 的情況。
--   ③ 白名單   fnb / retail / other，暢打例外放行。
--              原本的訊息寫「類別為 fnb 或 goods」而條件其實也放行 fee，
--              訊息與條件本來就對不上，一併修正。
--
-- 🔴🔴 checkout_tx 的分桶也壞了，而且是無聲的（2026-08-20 撈全文才發現）
--   品項迴圈裡是：
--       l_kind text := it->>'kind';                              -- 現在是 NULL
--       if l_kind not in ('fee','fnb','goods') then raise ...;   -- ← 不會觸發
--   **`NULL not in (...)` 的結果是 NULL 不是 TRUE**，所以這個檢查在 kind
--   消失之後完全不擋。接著分桶：
--       if l_kind = 'fee' ... elsif l_kind = 'fnb' ... else v_goods ...
--   NULL 比較全部為 false → **所有品項都掉進 goods 桶**。
--   後果：rem_fee 恆為 0 → 等級折扣恆為 0；
--         檯費券的 cap = rem_fee = 0 → 一律被判「不適用於本次品項」。
--   金額不會爆、結帳會成功，只有折扣默默不見。
--
--   沒有寫出壞資料純屬運氣 —— join_session_tx 那道白名單先把入座路徑擋死了。
--
--   → 真正的教訓不是「漏改一處」，是**那道防護寫成 `not in` 而不是
--     `is null or not in`**。它存在的目的就是擋不合法的值，
--     結果遇到 null 直接放行。新版一律先判 null。
--
-- 【四個桶對應三個變數】
--   venue_fee → v_fee、fnb → v_fnb、retail 與 other → v_goods。
--   券的 applies_to 仍是 table_fee/fnb（那是券自己的詞彙，待辦 0.8 才動），
--   所以這裡維持三個桶，不為了對齊而改券的邏輯。
--
-- 【list_products_tx / list_daypass_tx 只是拿掉死碼】
--   兩支不再回傳 kind（POS 已改讀 revenue_type）。
--   跑完請在 POS 按一次重新整理 —— 舊 bundle 讀 p.kind 會拿到 undefined。
-- ============================================================

-- ① join_session_tx（完整重建，只改與 kind 有關的四處）
create or replace function public.join_session_tx(
  p_session_id uuid, p_member_id uuid, p_join_type text default 'opener'::text,
  p_coupon_ids uuid[] default null::uuid[], p_points_used bigint default 0,
  p_payments jsonb default null::jsonb, p_staff_id uuid default null::uuid,
  p_idempotency_key text default null::text, p_pay_for uuid[] default null::uuid[],
  p_items jsonb default null::jsonb)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_s record; v_base jsonb; v_unit bigint; v_qty int; v_amount bigint;
  v_items jsonb; v_res jsonb; v_order uuid; v_sp uuid; v_key text; v_seq int;
  v_target uuid; v_created int := 0;
  v_extra int := 0;
  v_buy_daypass boolean := false;   -- ★ 本次結帳是否含當日暢打
  v_self_pass boolean := false;     -- ★ 付款人是否已持有暢打
begin
  if p_join_type not in ('opener','mid_join','sub') then
    return jsonb_build_object('ok', false, 'reason', 'invalid_join_type');
  end if;

  -- 附加品項驗證。純輸入檢查，刻意排在查資料庫之前。
  if p_items is not null and jsonb_typeof(p_items) = 'array' then
    v_extra := jsonb_array_length(p_items);
  end if;

  if v_extra > 0 then
    -- ★ 本次是否買了當日暢打。它是 revenue_type='venue_fee' 但不是
    --   「這一桌的場地費」，所以下面的場地費擋要放行它。
    select exists (
      select 1 from jsonb_array_elements(p_items) it
       where exists (select 1 from products pr
                      where pr.id = nullif(it ->> 'product_id', '')::uuid
                        and pr.sku = 'SVC-TBL-DAY'))
      into v_buy_daypass;

    -- 場地費由本函式自己算，前端再送一份會重複收費。
    -- 暢打例外放行（它賣的是「今天不再收場地費」的權利，不是這一桌的費用）。
    if exists (select 1 from jsonb_array_elements(p_items) it
                where it ->> 'revenue_type' = 'venue_fee'
                  and not exists (select 1 from products pr
                                   where pr.id = nullif(it ->> 'product_id', '')::uuid
                                     and pr.sku = 'SVC-TBL-DAY')) then
      return jsonb_build_object('ok', false, 'reason', 'fee_item_not_allowed',
        'message', '場地費由系統計算，不可由前端傳入');
    end if;

    -- 儲值寫的是 topup_orders 不是 orders，不能混進同一張單。
    -- 儲值不是收入桶所以沒有 revenue_type 可比 —— 前端用獨立旗標標記它。
    -- 也接住誤把 'topup' 填進收入桶的情況（那個值不存在於任何 CHECK）。
    if exists (select 1 from jsonb_array_elements(p_items) it
                where it ->> 'is_topup' = 'true'
                   or it ->> 'revenue_type' = 'topup') then
      return jsonb_build_object('ok', false, 'reason', 'topup_not_allowed',
        'message', '儲值請走儲值流程，不能併入結帳');
    end if;

    -- order_items.revenue_type 現在是 NOT NULL；product_id 也是。
    -- 暢打是唯一放行的 venue_fee 品項（上面那道已經擋掉其餘的）。
    if exists (select 1 from jsonb_array_elements(p_items) it
                where (coalesce(it ->> 'revenue_type', '') not in ('fnb','retail','other')
                       and not exists (select 1 from products pr
                                        where pr.id = nullif(it ->> 'product_id', '')::uuid
                                          and pr.sku = 'SVC-TBL-DAY'))
                   or it ->> 'product_id' is null
                   or coalesce((it ->> 'qty')::int, 0) <= 0) then
      return jsonb_build_object('ok', false, 'reason', 'invalid_item',
        'message', '品項需有 product_id、數量大於 0，且收入桶為 fnb／retail／other');
    end if;
  end if;

  select * into v_s from table_sessions where id = p_session_id;
  if v_s.id is null then
    return jsonb_build_object('ok', false, 'reason', 'session_not_found');
  end if;
  if v_s.status <> 'open' then
    return jsonb_build_object('ok', false, 'reason', 'session_closed',
      'message', '此場次已收桌或已作廢');
  end if;

  -- 鐵則一：一律會員
  if not exists (select 1 from members where id = p_member_id and deleted_at is null) then
    return jsonb_build_object('ok', false, 'reason', 'member_required',
      'message', '需先建立會員資料');
  end if;

  if exists (select 1 from session_players
              where session_id = p_session_id and member_id = p_member_id
                and left_at is null) then
    return jsonb_build_object('ok', false, 'reason', 'already_joined');
  end if;

  -- 座位上限：自己 + 代付人數不可超過 4
  if (select count(*) from session_players
       where session_id = p_session_id and left_at is null)
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
        return jsonb_build_object('ok', false, 'reason', 'payfor_member_invalid',
          'member_id', v_target);
      end if;
      if exists (select 1 from session_players
                  where session_id = p_session_id and member_id = v_target
                    and left_at is null) then
        return jsonb_build_object('ok', false, 'reason', 'payfor_already_joined',
          'member_id', v_target);
      end if;
    end loop;
  end if;

  -- ★ 標準單價：傳 null 取得「不看暢打」的價格。
  --   舊版用付款人的試算當單價，付款人持有暢打時單價 = 0，
  --   `v_unit × (1 + 代付人數)` 就讓四份全部免費 ——
  --   暢打是個人權利，不會因為誰付錢而轉移給別人。
  v_base := calc_session_fee_tx(p_session_id, p_join_type, null);
  if not (v_base ->> 'ok')::boolean then return v_base; end if;
  v_unit := coalesce((v_base ->> 'amount')::bigint, 0);

  -- ★ 份數逐人判斷：只算「這一桌要付場地費的人」。
  --   本次結帳有買暢打的話，付款人自己這一份當場歸零 ——
  --   否則 calc 跑的時候訂單還沒成立、has_daypass_tx 查不到，
  --   會變成「暢打 300 + 場地費 150」一起收。
  v_self_pass := has_daypass_tx(v_s.org_id, p_member_id, v_s.store_id);

  -- 已持有暢打就不能再買一張：has_daypass_tx 只問「今天有沒有」，
  -- 第二張沒有任何作用而錢照收。此處尚未寫入任何資料，可安全返回。
  if v_buy_daypass and v_self_pass then
    return jsonb_build_object('ok', false, 'reason', 'daypass_already_held',
      'message', '此會員今日已持有當日暢打，不需再購買');
  end if;

  v_qty := 0;
  if not v_buy_daypass and not v_self_pass then
    v_qty := 1;
  end if;
  if p_pay_for is not null then
    foreach v_target in array p_pay_for loop
      if not has_daypass_tx(v_s.org_id, v_target, v_s.store_id) then
        v_qty := v_qty + 1;
      end if;
    end loop;
  end if;
  v_amount := v_unit * v_qty;

  select count(*) + 1 into v_seq from session_players
   where session_id = p_session_id and member_id = p_member_id;
  v_key := coalesce(p_idempotency_key,
                    p_session_id::text || ':' || p_member_id::text || ':' || v_seq);

  v_items := '[]'::jsonb;

  if v_amount > 0 then
    v_items := v_items || jsonb_build_array(jsonb_build_object(
      'product_id',   v_base ->> 'product_id',
      'name',         v_base ->> 'name',
      'revenue_type', 'venue_fee',
      'qty',          v_qty,
      'unit_price',   v_unit));
  end if;

  if v_extra > 0 then
    v_items := v_items || p_items;
  end if;

  if jsonb_array_length(v_items) > 0 then
    v_res := checkout_tx(
      p_member_id, v_s.store_id, v_items, p_coupon_ids,
      coalesce(p_points_used, 0), p_payments, v_key, p_staff_id);

    v_order := (v_res ->> 'order_id')::uuid;

    update orders o
       set session_id = p_session_id,
           table_id   = v_s.table_id,
           channel    = 'counter',
           entity_id  = coalesce(o.entity_id,
                                 (select entity_id from stores where id = v_s.store_id))
     where o.id = v_order;
  end if;

  -- 付款人自己入座
  insert into session_players(
    org_id, session_id, member_id, join_type, status,
    charged_points, order_id, joined_at, created_by,
    fee_waived_amount, fee_waived_reason)
  values (
    v_s.org_id, p_session_id, p_member_id, p_join_type, 'playing',
    coalesce((v_res ->> 'payable')::bigint, 0), v_order, now(), p_staff_id,
    -- 免收金額是使用量指標，不是折讓：不進 orders、不影響營收毛額
    case when (v_self_pass or v_buy_daypass) then v_unit else 0 end,
    case when (v_self_pass or v_buy_daypass) then 'daypass' end)
  returning id into v_sp;

  -- 被代付者一併入座：有入座記錄但沒有訂單，消費金額掛在代付人身上
  if p_pay_for is not null then
    foreach v_target in array p_pay_for loop
      insert into session_players(
        org_id, session_id, member_id, join_type, status,
        charged_points, order_id, paid_by, joined_at, created_by,
        fee_waived_amount, fee_waived_reason)
      values (
        v_s.org_id, p_session_id, v_target, p_join_type, 'playing',
        0, null, p_member_id, now(), p_staff_id,
        -- 暢打是個人權利：被代付者有沒有暢打與付款人無關
        case when has_daypass_tx(v_s.org_id, v_target, v_s.store_id)
             then v_unit else 0 end,
        case when has_daypass_tx(v_s.org_id, v_target, v_s.store_id)
             then 'daypass' end);
      v_created := v_created + 1;
    end loop;
  end if;

  return jsonb_build_object('ok', true, 'player_id', v_sp,
    'order_id', v_order, 'unit_fee', v_unit, 'qty', v_qty,
    'listed_amount', v_amount, 'paid_for_count', v_created,
    'extra_items', v_extra,
    'daypass', v_self_pass,
    'daypass_bought', v_buy_daypass,
    'checkout', v_res);
end $function$;

comment on function public.join_session_tx(uuid, uuid, text, uuid[], bigint, jsonb, uuid, text, uuid[], jsonb) is
  '入座並收費。場地費份數**逐人判斷**：只算沒有當日暢打的人（暢打是個人權利，不因誰付錢而轉移）。p_items 可帶餐飲/商品，以及當日暢打（唯一放行的 venue_fee 品項）；本次買暢打時付款人自己那份場地費當場歸零。';

-- ② list_products_tx：不再回傳 kind
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
      'revenue_type', revenue_type
    ) order by category, sku)
    from products
    where org_id = p_org_id and is_active and coalesce(is_available, true)
      and deleted_at is null
      and sku not like 'SVC-TBL-%'   -- 檯費不列入加購清單，避免店員手動點錯
  ), '[]'::jsonb);
end $function$;

-- ③ list_daypass_tx：不再回傳 kind
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
           'revenue_type', 'venue_fee')), '[]'::jsonb)
    from public.products p
   where p.org_id = p_org_id
     and p.sku = 'SVC-TBL-DAY'
     and p.is_active
     and p.deleted_at is null;
$$;

grant execute on function public.list_daypass_tx(uuid) to anon, authenticated;

-- ④ checkout_tx（完整重建：分桶改用 revenue_type，並修好 null 放行的防護）
--    ⚠ 這支是 SECURITY INVOKER 且不設 search_path —— 維持原樣，不要順手加。
--      它一律由 DEFINER 的呼叫端（join_session_tx / pos_addon_checkout_tx）委派，
--      加上 DEFINER 會改變權限模型。
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
      -- retail 與 other 共用 goods 桶：券的 applies_to 只分 table_fee / fnb / 其餘
      if    l_bucket = 'venue_fee' then v_fee   := v_fee   + l_line;
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

-- ============================================================
-- 驗證（單一 SELECT）
--   第一欄應該只剩三支：create_invoice_draft_tx / get_wallet_tx / void_invoice_tx
--   （它們的 kind 是 invoices.kind 與 coupons.kind，本來就不該動）。
--   第二、三欄是修好的擋牆；第四欄確認 join_session_tx 只有一個版本。
-- ============================================================
with fns as (
  select p.proname, p.prosecdef, pg_get_functiondef(p.oid) as def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.prokind = 'f'
)
select
  (select jsonb_agg(proname order by proname)
     from fns where def ~ '\ykind\y')                                     as 仍提到kind的函式,
  (select bool_or(def like '%''revenue_type'' = ''venue_fee''%')
     from fns where proname = 'join_session_tx')                          as 場地費擋牆已改,
  (select bool_or(def like '%not in (''fnb'',''retail'',''other'')%')
     from fns where proname = 'join_session_tx')                          as 白名單已改,
  (select bool_or(def like '%l_bucket is null%')
     from fns where proname = 'checkout_tx')                              as 分桶已先判null,
  (select count(*) from fns where proname in ('join_session_tx','checkout_tx'))
                                                                          as 兩支的版本數,
  (select bool_and(prosecdef) from fns where proname = 'join_session_tx') as join是DEFINER,
  (select bool_or(not prosecdef) from fns where proname = 'checkout_tx')  as checkout仍是INVOKER,
  (select jsonb_object_agg(revenue_type, n)
     from (select revenue_type, count(*) as n from public.order_items
            group by revenue_type) t)                                     as 收入桶分布;
