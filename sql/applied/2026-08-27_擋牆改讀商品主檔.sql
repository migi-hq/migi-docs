/* ============================================================
   join_session_tx：品項擋牆改讀商品主檔，不採信前端的 revenue_type
   2026-08-27 · 待辦 2 的第二半

   ── 問題 ────────────────────────────────────────────
   這支有三道擋牆保護「場地費由後端算」這件事，但它們讀的是
   **前端送進來的 `revenue_type`**：

       where it ->> 'revenue_type' = 'venue_fee'          -- 讀前端送的
       where coalesce(it ->> 'revenue_type','') not in (...)

   🔴 所以前端只要把 `revenue_type` 寫成 `'fnb'`，檯費商品就能穿過去：

       { product_id: <SVC-TBL-M2>, revenue_type: 'fnb', qty: 1, unit_price: 0 }

   三道牆全部通過 → 檯費被收兩次（本函式自己算一份、偽裝的那筆一份）。

   ⚠ `checkout_tx` 已於同日改成「單價／名稱／收入桶一律回查主檔」，
     所以偽裝的那筆現在會被正確地算成 venue_fee 主檔價 ——
     **金額不會被竄改了，但「重複收費」這件事還在**。
     那正是這三道牆存在的理由，所以它們也要改。

   ── 改動範圍：只有兩處 ──────────────────────────────
   ① 場地費擋牆 → 改讀 `products.revenue_type`
   ② 品項合法性擋牆 → 同上，並順便擋掉「product_id 指向不存在的商品」

   ⚠ 其餘一字未動。`v_buy_daypass` 的偵測**本來就是查主檔**（比對 sku），
     那一段是對的，不要碰。
   ⚠ 儲值那道牆維持讀前端旗標 —— 儲值不是商品，沒有主檔可查。

   ── 為什麼撈全文重建而不是堆 DO 區塊 ────────────────
   CLAUDE.md 記過：**同一支要改三處以上就撈全文重建**，
   而我在**這一支**上就因為只看片段連續判斷錯兩次。
   這次雖然只改兩處，但它同時有暢打、代付、擋牆三種邏輯交纏，
   全文重建才看得出改動有沒有波及其他分支。

   ── 為什麼是 CREATE OR REPLACE ──────────────────────
   ✅ **簽名一字不變**（十個參數、預設值全同）→ 不用 DROP、不會丟 GRANT、
     沒有部署順序問題、前端完全不用改。
   ============================================================ */

create or replace function public.join_session_tx(p_session_id uuid, p_member_id uuid, p_join_type text default 'opener'::text, p_coupon_ids uuid[] default null::uuid[], p_points_used bigint default 0, p_payments jsonb default null::jsonb, p_staff_id uuid default null::uuid, p_idempotency_key text default null::text, p_pay_for uuid[] default null::uuid[], p_items jsonb default null::jsonb)
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

  -- 附加品項驗證。純輸入檢查，刻意排在查場次之前。
  if p_items is not null and jsonb_typeof(p_items) = 'array' then
    v_extra := jsonb_array_length(p_items);
  end if;

  if v_extra > 0 then
    -- ★ 本次是否買了當日暢打。它是 revenue_type='venue_fee' 但不是
    --   「這一桌的場地費」，所以下面的場地費擋要放行它。
    --   ⚠ 這一段本來就是查主檔比對 sku，是對的，未改動。
    select exists (
      select 1 from jsonb_array_elements(p_items) it
       where exists (select 1 from products pr
                      where pr.id = nullif(it ->> 'product_id', '')::uuid
                        and pr.sku = 'SVC-TBL-DAY'))
      into v_buy_daypass;

    /* 場地費由本函式自己算，前端再送一份會重複收費。
       暢打例外放行（它賣的是「今天不再收場地費」的權利，不是這一桌的費用）。

       ★ 2026-08-27：改讀 **products.revenue_type**，不讀前端送的值。
         舊版寫 `it ->> 'revenue_type' = 'venue_fee'` ——
         前端只要把它寫成 'fnb'，檯費商品就從這道牆底下走過去了。 */
    if exists (
      select 1
        from jsonb_array_elements(p_items) it
        join products pr
          on pr.id = nullif(it ->> 'product_id', '')::uuid
       where pr.revenue_type = 'venue_fee'
         and pr.sku <> 'SVC-TBL-DAY'
         and pr.deleted_at is null
    ) then
      return jsonb_build_object('ok', false, 'reason', 'fee_item_not_allowed',
        'message', '場地費由系統計算，不可由前端傳入');
    end if;

    -- 儲值寫的是 topup_orders 不是 orders，不能混進同一張單。
    -- 儲值不是收入桶所以沒有 revenue_type 可比 —— 前端用獨立旗標標記它。
    -- 也接住誤把 'topup' 填進收入桶的情況（那個值不存在於任何 CHECK）。
    -- ⚠ 這道牆維持讀前端旗標：儲值不是商品，沒有主檔可查。
    if exists (select 1 from jsonb_array_elements(p_items) it
                where it ->> 'is_topup' = 'true'
                   or it ->> 'revenue_type' = 'topup') then
      return jsonb_build_object('ok', false, 'reason', 'topup_not_allowed',
        'message', '儲值請走儲值流程，不能併入結帳');
    end if;

    /* 品項合法性。order_items.revenue_type 與 product_id 都是 NOT NULL。
       暢打是唯一放行的 venue_fee 品項（上面那道已經擋掉其餘的）。

       ★ 2026-08-27：收入桶改讀主檔；並補上「product_id 指向不存在的商品」——
         舊版只檢查 product_id 是不是 null，指向一個不存在的 uuid 會一路
         走到 checkout_tx 才炸，而那時錯誤訊息與這裡無關，很難查。 */
    if exists (
      select 1 from jsonb_array_elements(p_items) it
       where nullif(it ->> 'product_id', '') is null
          or coalesce((it ->> 'qty')::int, 0) <= 0
    ) or exists (
      select 1
        from jsonb_array_elements(p_items) it
        left join products pr
          on pr.id = nullif(it ->> 'product_id', '')::uuid
         and pr.deleted_at is null
       where nullif(it ->> 'product_id', '') is not null
         and (pr.id is null
              or (pr.revenue_type not in ('fnb','retail','other')
                  and pr.sku <> 'SVC-TBL-DAY'))
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

/* ============================================================
   實測

   🎯 **不需要建任何測試場次。**
   品項擋牆刻意排在查 `table_sessions` 之前，所以用一個
   **不存在的 session_id** 就能單獨測到擋牆：

     · 舊版：偽裝的檯費穿過三道牆 → 才去查場次 → 回 session_not_found
     · 新版：主檔說它是 venue_fee → 回 fee_item_not_allowed

   而且全程**沒有任何寫入**（兩條路都在 return 之前），不用回滾。

   ⚠ 三個子測試缺一不可：
     ① 偽裝的檯費要被擋
     ② 正常餐飲**不可以**被誤擋（過度阻擋跟沒擋一樣糟，而且更難發現）
     ③ 暢打要照樣放行（它是 venue_fee 但必須通過）
   ============================================================ */
do $$
declare
  v_m uuid; v_org uuid;
  v_fee_pid uuid; v_fnb_pid uuid; v_day_pid uuid;
  v_fake uuid := gen_random_uuid();
  r1 text; r2 text; r3 text;
  function_result jsonb;
begin
  select s.org_id into v_org from stores s limit 1;
  select m.id into v_m from members m where m.deleted_at is null limit 1;
  select p.id into v_fee_pid from products p
   where p.org_id = v_org and p.sku = 'SVC-TBL-M2' and p.deleted_at is null limit 1;
  select p.id into v_fnb_pid from products p
   where p.org_id = v_org and p.revenue_type = 'fnb' and p.deleted_at is null limit 1;
  select p.id into v_day_pid from products p
   where p.org_id = v_org and p.sku = 'SVC-TBL-DAY' and p.deleted_at is null limit 1;

  if v_m is null or v_fee_pid is null or v_fnb_pid is null or v_day_pid is null then
    perform set_config('migi.jw',
      '⚠ 跳過：缺會員／SVC-TBL-M2／fnb 商品／SVC-TBL-DAY', true);
    return;
  end if;

  -- ① 把檯費偽裝成 fnb
  function_result := join_session_tx(v_fake, v_m, 'opener', null, 0, null, null, null, null,
    jsonb_build_array(jsonb_build_object(
      'product_id', v_fee_pid, 'revenue_type', 'fnb', 'qty', 1, 'unit_price', 0)));
  r1 := function_result ->> 'reason';

  -- ② 正常餐飲（誠實標示）—— 應該通過擋牆，然後才因為場次不存在而失敗
  function_result := join_session_tx(v_fake, v_m, 'opener', null, 0, null, null, null, null,
    jsonb_build_array(jsonb_build_object(
      'product_id', v_fnb_pid, 'revenue_type', 'fnb', 'qty', 1, 'unit_price', 60)));
  r2 := function_result ->> 'reason';

  -- ③ 當日暢打 —— 是 venue_fee，但必須放行
  function_result := join_session_tx(v_fake, v_m, 'opener', null, 0, null, null, null, null,
    jsonb_build_array(jsonb_build_object(
      'product_id', v_day_pid, 'revenue_type', 'venue_fee', 'qty', 1, 'unit_price', 300)));
  r3 := function_result ->> 'reason';

  perform set_config('migi.jw',
    '① 偽裝成 fnb 的檯費　→ ' || coalesce(r1,'null') ||
      case when r1 = 'fee_item_not_allowed' then '　✅ 擋下' else '　🔴 穿過去了' end ||
    E'\n② 正常餐飲　　　　　→ ' || coalesce(r2,'null') ||
      case when r2 = 'session_not_found' then '　✅ 沒被誤擋' else '　🔴 被誤擋' end ||
    E'\n③ 當日暢打　　　　　→ ' || coalesce(r3,'null') ||
      case when r3 = 'session_not_found' then '　✅ 照樣放行' else '　🔴 被擋住' end,
    true);
end $$;

/* 驗證（單一 SELECT） */
select 序, 項目, 內容 from (

  select 1 as 序, '① join_session_tx 版本數' as 項目, count(*)::text as 內容
    from pg_proc p
   where p.pronamespace = 'public'::regnamespace
     and p.prokind = 'f' and p.proname = 'join_session_tx'

  union all
  /* ② 確認新寫法在裡面。
     ⚠ 硬規則 3.5：不掃「revenue_type 有沒有消失」——
       那個詞在我自己的註解裡到處都是。改成確認**新的那一段語法**在。 */
  select 2, '② 擋牆是否改讀主檔',
         case when (select pg_get_functiondef(p.oid) from pg_proc p
                     where p.pronamespace = 'public'::regnamespace
                       and p.prokind = 'f' and p.proname = 'join_session_tx' limit 1)
                   like '%where pr.revenue_type = ''venue_fee''%'
              then '✅ 是' else '🔴 否，改動沒生效' end

  union all
  select 3, '③ 三個子測試',
         coalesce(current_setting('migi.jw', true), '🔴 DO 區塊沒執行')

  union all
  select 4, '④ 場次玩家數（確認沒寫入任何東西）',
         (select count(*)::text || ' 列' from session_players)

) x order by 序, 項目;
