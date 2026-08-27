/* ============================================================
   checkout_tx：單價／名稱／收入桶一律回查商品主檔，不採信前端
   2026-08-27 · 待辦 2

   ── 問題 ────────────────────────────────────────────
   `l_price := (it->>'unit_price')::bigint` —— 價格由前端 JSON 決定，
   **可以送 0**。`name` 與 `revenue_type` 同樣照收。
   POS 是店員在用風險可控，但 KIOSK 或任何會員端能觸發結帳的路徑
   一出現，就是可竄改價格的漏洞。

   ── 這不是引入新模式，是把既有模式補完 ────────────────
   2026-08-20 做 `products.discountable` 時就已經寫下：
       「折不折扣一律由後端回查商品主檔，不採信前端送來的值。」
   這支 SQL 只是把同一件事從一個欄位擴大到 name / unit_price / revenue_type。

   ── 為什麼安全（2026-08-27 查證，不是推測）──────────
   ① **現有 202 筆品項，0 筆單價與主檔不符。** 覆寫是 no-op。
   ② 檯費不是例外：`join_session_tx` 的 `v_unit` 來自
      `calc_session_fee_tx(..., null)`，而那支回的就是 `products.unit_price`。
      🔴 **暢打是靠 `qty` 表達的（`v_qty` 從 0 起算），不是把單價改成 0** ——
        所以查主檔不會把暢打的客人收全額。這是動手前最需要確認的一點。
   ③ 萬一真的有落差，`checkout_tx` 既有的
      `if v_pay_sum <> v_cash_due then raise` 會**大聲失敗**，
      不會靜靜收錯錢。

   ── 順帶堵掉兩個洞 ──────────────────────────────────
   🔴 **偽裝收入桶**：`join_session_tx` 的三道擋牆讀的是前端送的
     `revenue_type`。前端可以送
     `{product_id: SVC-TBL-M2, revenue_type: 'fnb', unit_price: 0}`
     把檯費偽裝成餐飲，三道牆全部通過。
     改成用主檔的 `revenue_type` 分桶之後，這條路在 checkout_tx 這一層堵死。
     ⚠ **但 `join_session_tx` 那三道擋牆本身仍然讀前端的值** ——
       那是另一支函式，另一份 SQL 處理（見檔尾）。
   🔴 **跨 org 商品**：現在完全沒驗商品屬不屬於這張單的 org。
     目前只有一個 org 所以沒事，那是運氣不是設計。

   ── 為什麼是 CREATE OR REPLACE ──────────────────────
   ✅ **簽名完全不變**（`p_items` 仍是 jsonb）。不用 DROP、不會丟 GRANT、
     沒有部署順序問題。
   ✅ **前端完全不用改**：它照樣送 `unit_price`／`name`／`revenue_type`，
     後端忽略。之後要清掉那幾個欄位是另一批，隨時可做。

   ── 刻意不做的兩件事 ────────────────────────────────
   · **不過濾 `is_active`**：結帳是「已經發生的交易」，不是「決定要不要賣」。
     東西客人都吃了才在收錢那一刻擋下來，比讓它成立更糟。
     要擋銷售應該在 `list_products_tx`（不列出來）。
   · **不改簽名成 product_id + qty**：那要動四支包裝層與前端，
     而收益與這一版相同（前端送什麼都不算數了）。
   ============================================================ */

create or replace function public.checkout_tx(p_member_id uuid, p_store_id uuid, p_items jsonb, p_coupon_ids uuid[], p_points_used bigint, p_payments jsonb, p_idempotency_key text, p_staff_id uuid)
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
      /* ★ 2026-08-27：前端只送「意圖」（product_id + qty），
         其餘一律回查主檔。原本 name / unit_price / revenue_type 都照收，
         而 unit_price 可以送 0。
         `discountable` 從 2026-08-20 起就已經是這樣做的 —— 這裡是補完。 */
      l_pid    uuid   := nullif(it->>'product_id','')::uuid;
      l_qty    int    := (it->>'qty')::int;
      l_price  bigint;
      l_name   text;
      l_bucket text;
      l_disc   boolean;
      l_line   bigint;
    begin
      if l_pid is null then
        raise exception '品項缺少 product_id：%', coalesce(it->>'name', '(未命名)');
      end if;

      /* ★ org 一併比對：現在完全沒驗商品屬不屬於這張單的機構。
         目前只有一個 org 所以踩不到，但那是運氣不是設計。
         ⚠ 不過濾 is_active —— 見檔頭「刻意不做的兩件事」。 */
      select pr.unit_price, pr.name, pr.revenue_type, pr.discountable
        into l_price, l_name, l_bucket, l_disc
        from public.products pr
       where pr.id = l_pid
         and pr.org_id = v_org
         and pr.deleted_at is null;
      if not found then
        raise exception '商品不存在或不屬於本機構：%', l_pid;
      end if;

      if l_qty <= 0 then raise exception '品項數量不合法：%', l_qty; end if;
      if l_price < 0 then raise exception '商品 % 主檔單價為負', l_name; end if;

      /* ⚠ l_bucket 現在來自主檔，而 products.revenue_type 是 NOT NULL，
         所以它不可能是 null —— 舊版那道 null 防護在這裡已經結構性不可能觸發。
         但**值域檢查要留著**：日後 products 加了新的 revenue_type（例如 M8 的
         教室課程 'lesson'）而這裡沒跟上時，要大聲失敗，不要靜靜掉進 else 桶。 */
      if l_bucket not in ('venue_fee','fnb','retail','other') then
        raise exception '商品 % 的 revenue_type 尚未支援：%', l_name, l_bucket;
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
        /* 指定商品券：那個商品若是不可折扣的，一樣不給折。
           ★ 2026-08-27：金額改用主檔價 —— 原本讀 it2->>'unit_price'，
             等於讓前端決定「免費券折抵多少」。 */
        select coalesce(sum((it2->>'qty')::int * pr2.unit_price), 0)
          into cap
          from jsonb_array_elements(p_items) it2
          join public.products pr2
            on pr2.id = nullif(it2->>'product_id','')::uuid
         where pr2.id = cp.free_product_id
           and pr2.org_id = v_org
           and pr2.deleted_at is null
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

  /* ★ 2026-08-27：品項快照一律寫主檔的值。
     原本逐筆 insert 前端送的 name / revenue_type / unit_price ——
     那會讓「訂單品項是快照」變成「訂單品項是前端說的話」。
     改成 join 主檔，與上面的金額計算用同一個來源，不可能不一致。
     ⚠ 同一個商品在 p_items 裡出現兩次時，這裡照樣寫兩列（正確行為）。 */
  insert into order_items(org_id, order_id, product_id, name, revenue_type, qty,
                          unit_price, line_total)
  select v_org, v_order_id, pr.id, pr.name, pr.revenue_type,
         (it2->>'qty')::int, pr.unit_price,
         (it2->>'qty')::int * pr.unit_price
    from jsonb_array_elements(p_items) it2
    join public.products pr
      on pr.id = nullif(it2->>'product_id','')::uuid
   where pr.org_id = v_org
     and pr.deleted_at is null;

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

/* ============================================================
   實測：故意送錯的價格、名稱、收入桶，看它記下什麼
   ⚠ 交易內測試，最後 raise 回滾，不留任何資料。

   ── 這個測試為什麼有效 ──────────────────────────────
   `checkout_tx` 本來就有 `if v_pay_sum <> v_cash_due then raise`。
   所以：品項送 unit_price = 1，付款金額送**主檔價**。
     · 舊版（讀前端價）→ cash_due = 1，付款 = 主檔價 → **拋「收款金額不符」**
     · 新版（讀主檔價）→ cash_due = 主檔價 → 通過
   🎯 既有的收款驗證直接當成了這次改動的驗證器，不用另外造。

   ⚠ 硬規則 3.9：訊息一律設在 exception 處理器裡 ——
     set_config(..., true) 是交易內設定，寫在 raise 之前會跟著被回滾，
     最後印出空白。
   ============================================================ */
do $$
declare
  v_m uuid; v_st uuid; v_org uuid;
  v_pid uuid; v_price bigint; v_pname text; v_ptype text;
  v_res jsonb; v_msg text;
  r_name text; r_price bigint; r_type text; r_line bigint;
begin
  select w.member_id into v_m
    from wallets w join members m on m.id = w.member_id
   where m.deleted_at is null
   limit 1;
  select s.id, s.org_id into v_st, v_org from stores s limit 1;
  select p.id, p.unit_price, p.name, p.revenue_type
    into v_pid, v_price, v_pname, v_ptype
    from products p
   where p.org_id = v_org and p.deleted_at is null
     and p.unit_price > 0 and p.revenue_type = 'fnb' and p.discountable
   limit 1;

  if v_m is null or v_st is null or v_pid is null then
    perform set_config('migi.px',
      '⚠ 跳過：缺會員錢包／門市／可折扣的 fnb 商品', true);
    return;
  end if;

  begin
    v_res := checkout_tx(
      v_m, v_st,
      jsonb_build_array(jsonb_build_object(
        'product_id',   v_pid,
        'name',         '前端亂寫的名字',   -- ★ 故意
        'revenue_type', 'other',            -- ★ 故意送錯桶
        'qty',          1,
        'unit_price',   1)),                -- ★ 故意送 1 元
      null, 0,
      -- 付款送**主檔價**：舊版會因為「收款金額不符」而失敗
      jsonb_build_array(jsonb_build_object('method','cash','amount', v_price)),
      'migi-price-test-' || gen_random_uuid()::text, null);

    select oi.name, oi.unit_price, oi.revenue_type, oi.line_total
      into r_name, r_price, r_type, r_line
      from order_items oi
     where oi.order_id = (v_res ->> 'order_id')::uuid
     limit 1;

    v_msg := case
      when r_price = v_price and r_name = v_pname and r_type = v_ptype
        then '✅ 記下的是主檔的值：' || r_name || '　$' || r_price::text ||
             '　' || r_type || '（前端送的是「前端亂寫的名字」/ other / $1）'
      else '🔴 仍採信前端：name=' || coalesce(r_name,'null') ||
           '　price=' || coalesce(r_price::text,'null') ||
           '　type=' || coalesce(r_type,'null')
      end;
    raise exception 'rollback_on_purpose';
  exception
    when others then
      if sqlerrm = 'rollback_on_purpose' then
        perform set_config('migi.px', v_msg, true);
      else
        perform set_config('migi.px', '🔴 測試拋錯：' || sqlerrm, true);
      end if;
  end;
end $$;

/* ============================================================
   驗證（單一 SELECT）
   ① 1（沒有多載）
   ② ✅ 品項迴圈已改成查主檔
   ③ ✅ 記下的是主檔的值
   ④ 訂單數不變（確認回滾乾淨）
   ============================================================ */
select 序, 項目, 內容 from (

  select 1 as 序, '① checkout_tx 版本數' as 項目, count(*)::text as 內容
    from pg_proc p
   where p.pronamespace = 'public'::regnamespace
     and p.prokind = 'f' and p.proname = 'checkout_tx'

  union all
  /* ② 確認新寫法在裡面。
     ⚠ 硬規則 3.5：不掃「unit_price 有沒有消失」——
       那個詞在我自己的註解裡到處都是，掃字串分不出程式碼與說明。
       改成確認**新的那一行**在（它是一段不會出現在說明文字裡的完整語法）。 */
  select 2, '② 品項是否回查主檔',
         case when (select pg_get_functiondef(p.oid) from pg_proc p
                     where p.pronamespace = 'public'::regnamespace
                       and p.prokind = 'f' and p.proname = 'checkout_tx' limit 1)
                   like '%into l_price, l_name, l_bucket, l_disc%'
              then '✅ 是' else '🔴 否，改動沒生效' end

  union all
  select 3, '③ 實測結果',
         coalesce(current_setting('migi.px', true), '🔴 DO 區塊沒執行')

  union all
  select 4, '④ 訂單數（確認回滾乾淨）',
         (select count(*)::text || ' 張' from orders)

) x order by 序, 項目;
