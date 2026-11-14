/* ============================================================================
   2026-11-14 修正：檯費優惠擇優 —— 鎖住檯費那一輪，「券從檯費扣了多少」要是 0
   ----------------------------------------------------------------------------
   接在 sql/applied/2026-11-14_檯費優惠擇優與生日券計價.sql 之後（那一份已跑過，**不要重跑**：
   它會把會員券清單的欄位再加一次）。

   行為測試 ⓖ 抓到的錯（我寫錯的）：
     全品項折 30 的券 ＋ 牌咖團 50，檯費 150、牛肉麵 160
     第一輪券從檯費扣 30，沒有比 50 多 ⇒ 第二輪鎖住檯費、券改扣牛肉麵 ✅
     但算「券從檯費扣了多少」時，拿「一開始可折的 150」減「鎖住後的 0」⇒ 算成 150
     ⇒ 系統以為券贏了，拿掉牌咖團的 50（應付 280，應該是 230）
   修法：鎖住檯費那一輪，券根本碰不到檯費 ⇒ 直接記 0。
   影響範圍：只有「同時涵蓋檯費與其他品項的券」而且輸給牌咖團或會員折扣時。
     線上這種券現在 0 張（只有飲料券與檯費 9 折測試券），沒有任何一筆結帳算錯過。

   其餘跟上一份完全一樣（簽名不變，CREATE OR REPLACE 不會丟授權）。
   行為測試：再跑一次 sql/checks/2026-11-14_驗檯費優惠擇優與生日券計價.sql
   ============================================================================ */

create or replace function public._cart_pricing(p_org uuid, p_member_id uuid, p_items jsonb, p_coupon_ids uuid[], p_advisor_cut bigint default 0)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'public'
as $function$
declare
  v_tier text; v_pct int := 0;
  v_sub bigint := 0; v_fee bigint := 0; v_fnb bigint := 0; v_goods bigint := 0;
  v_nodisc bigint := 0;   -- 不參與折扣的金額（只為驗算與回傳，不進任何桶）
  v_coupon_cut bigint := 0; v_tier_cut bigint := 0; v_adv_cut bigint := 0; v_payable bigint;
  v_coupons jsonb := '[]'::jsonb;
  -- 每一個品項：商品、營收類別、子分類、扣的順序（檯費 1、餐飲 2、其餘 3）、可不可折、單價、一開始可折多少
  l_pid uuid[] := '{}'; l_rt text[] := '{}'; l_sub text[] := '{}'; l_ord int[] := '{}';
  l_disc boolean[] := '{}'; l_unit bigint[] := '{}'; l_rem0 bigint[] := '{}'; n int := 0;
  l_rem bigint[]; l_gift boolean[];
  v_match boolean[]; v_has_scope boolean; v_fee_hit boolean;
  -- 檯費的三個選項
  v_opt_tier bigint := 0; v_opt_adv bigint := 0; v_best bigint; v_best_label text;
  v_coupon_fee bigint := 0; v_lock_fee boolean := false; v_choice text; v_pass int;
  it jsonb; cp record; cap bigint; cut bigint; r bigint; d bigint; i int; k int;
begin
  /* 品項：前端只送「意圖」（product_id ＋ qty），其餘一律回查主檔（2026-08-27 起）。
     ⚠ 不過濾 is_active：結帳是已經發生的交易，不是決定要不要賣。 */
  if p_items is not null and jsonb_typeof(p_items) = 'array' then
    for it in select * from jsonb_array_elements(p_items) loop
      declare
        x_pid uuid := nullif(it->>'product_id','')::uuid;
        x_qty int := (it->>'qty')::int;
        x_price bigint; x_name text; x_bucket text; x_disc boolean; x_sub text; x_line bigint;
      begin
        if x_pid is null then
          raise exception '品項缺少 product_id：%', coalesce(it->>'name', '(未命名)');
        end if;
        select pr.unit_price, pr.name, pr.revenue_type, pr.discountable, pr.subcategory
          into x_price, x_name, x_bucket, x_disc, x_sub
          from public.products pr
         where pr.id = x_pid and pr.org_id = p_org and pr.deleted_at is null;
        if not found then
          raise exception '商品不存在或不屬於本機構：%', x_pid;
        end if;
        if x_qty <= 0 then raise exception '品項數量不合法：%', x_qty; end if;
        if x_price < 0 then raise exception '商品 % 主檔單價為負', x_name; end if;
        -- 值域檢查要留著：日後加了新的收入類別而這裡沒跟上時，要大聲失敗
        if x_bucket not in ('venue_fee','fnb','retail','other') then
          raise exception '商品 % 的 revenue_type 尚未支援：%', x_name, x_bucket;
        end if;
        x_line := x_qty * x_price;
        v_sub  := v_sub + x_line;
        if not x_disc then                v_nodisc := v_nodisc + x_line;
        elsif x_bucket = 'venue_fee' then v_fee    := v_fee    + x_line;
        elsif x_bucket = 'fnb'       then v_fnb    := v_fnb    + x_line;
        else                              v_goods  := v_goods  + x_line;
        end if;
        n := n + 1;
        l_pid[n] := x_pid; l_rt[n] := x_bucket; l_sub[n] := x_sub;
        l_ord[n] := case x_bucket when 'venue_fee' then 1 when 'fnb' then 2 else 3 end;
        l_disc[n] := x_disc; l_unit[n] := x_price;
        l_rem0[n] := case when x_disc then x_line else 0 end;   -- 不可折扣的品項從一開始就沒有可折的額度
      end;
    end loop;
  end if;

  /* 檯費的另外兩個選項（都只看可折的檯費、還沒被券碰過的金額）
     · 會員折扣：查不到的等級一律 0
     · 牌咖團優惠：金額由 _join_plan 算好傳進來，前端碰不到；不會折超過檯費 */
  select coalesce(tier_override, tier) into v_tier from members where id = p_member_id;
  select coalesce(t.discount_pct, 0) into v_pct from member_tiers t where t.code = v_tier and t.is_active;
  v_pct := coalesce(v_pct, 0);
  v_opt_tier := round(v_fee * v_pct / 100.0);
  v_opt_adv  := least(greatest(coalesce(p_advisor_cut, 0), 0), v_fee);
  if v_opt_adv > v_opt_tier then v_best := v_opt_adv;  v_best_label := '牌咖團優惠';
  else                           v_best := v_opt_tier; v_best_label := '會員折扣';
  end if;

  -- 券本身能不能用（用過、過期、還沒到可用日）只看一次
  if p_coupon_ids is not null and array_length(p_coupon_ids, 1) > 0 then
    for cp in
      select c.name as c_name, mc.used_at, mc.status, mc.expires_at, mc.valid_from
        from member_coupons mc join coupons c on c.id = mc.coupon_id
       where mc.id = any(p_coupon_ids) and mc.member_id = p_member_id
    loop
      if cp.used_at is not null or coalesce(cp.status, '') = 'used'
         or (cp.expires_at is not null and cp.expires_at <= now()) then
        raise exception '券 % 已使用或已過期', cp.c_name;
      end if;
      if cp.valid_from is not null and cp.valid_from > now() then
        raise exception '券 % 還沒到可用日（% 起才能用）', cp.c_name,
          to_char(cp.valid_from at time zone 'Asia/Taipei', 'FMMM/FMDD');
      end if;
    end loop;
  end if;

  /* 套券：最多兩輪。
     第一輪照舊套；券從檯費扣的沒有比另外兩個選項多 ⇒ 第二輪鎖住檯費再套一次。 */
  for v_pass in 1 .. 2 loop
    l_rem := l_rem0; l_gift := '{}'; v_coupon_cut := 0; v_coupons := '[]'::jsonb;
    if v_lock_fee then
      for i in 1 .. n loop
        if l_rt[i] = 'venue_fee' then l_rem[i] := 0; end if;
      end loop;
    end if;

    if p_coupon_ids is not null and array_length(p_coupon_ids, 1) > 0 then
      for cp in
        select mc.id as mc_id, c.id as coupon_id, c.name as c_name, c.kind, c.discount_type, c.discount_value,
               c.min_spend, c.max_discount, c.free_product_id, c.cost_bearer
          from member_coupons mc
          join coupons c on c.id = mc.coupon_id
         where mc.id = any(p_coupon_ids) and mc.member_id = p_member_id
         order by array_position(p_coupon_ids, mc.id)   -- 店員選的順序
      loop
        v_match := '{}'; cap := 0; v_fee_hit := false;

        if cp.kind = 'birthday' then
          /* 生日券：送一份指定商品（當日暢打）。那個商品不參與折扣也照送，只送一份。
             送的是暢打不是檯費優惠 ⇒ 不算進「券從檯費扣了多少」，不跟商人熊、會員折扣搶。 */
          for i in 1 .. n loop
            v_match[i] := false;
            if cap = 0 and l_pid[i] = cp.free_product_id and not coalesce(l_gift[i], false) then
              v_match[i] := true; cap := l_unit[i]; l_gift[i] := true;
            end if;
          end loop;
          if cap <= 0 then
            raise exception '券 % 要跟當日暢打一起結帳（先在檯費選當日暢打，再用這張券）', cp.c_name;
          end if;
          cut := cap;
        else
          -- 這張券涵蓋哪些品項
          v_has_scope := exists (select 1 from coupon_scopes s where s.coupon_id = cp.coupon_id);
          for i in 1 .. n loop
            if cp.discount_type = 'free' and cp.free_product_id is not null then
              v_match[i] := l_disc[i] and l_pid[i] = cp.free_product_id;          -- 指定商品免費券：只有那個商品
            elsif not v_has_scope then
              v_match[i] := l_disc[i];                                          -- 沒有規則：全部可折扣品項
            else
              v_match[i] := l_disc[i] and exists (
                select 1 from coupon_scopes s
                 where s.coupon_id = cp.coupon_id
                   and ((s.scope_type = 'revenue_type' and s.scope_value = l_rt[i])
                     or (s.scope_type = 'subcategory'  and s.scope_value = l_sub[i])
                     or (s.scope_type = 'product'      and s.scope_value = l_pid[i]::text)));
            end if;
            if v_match[i] then
              cap := cap + l_rem[i];
              if l_rt[i] = 'venue_fee' and l_rem0[i] > 0 then v_fee_hit := true; end if;
            end if;
          end loop;

          if cap <= 0 then
            if v_lock_fee and v_fee_hit then
              -- 只折檯費、而另一個選項比較多：結帳失敗才不會把券用掉
              raise exception '券 % 只折檯費，這次%折 $% 比較多，已經自動用了；這張券會留著下次用',
                cp.c_name, v_best_label, v_best;
            elsif cp.discount_type = 'free' and cp.free_product_id is not null then
              raise exception '券 % 指定商品不在本次訂單中，或該商品不參與折扣', cp.c_name;
            else
              raise exception '券 % 不適用於本次品項', cp.c_name;
            end if;
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

          -- 從涵蓋的品項扣：檯費 → 餐飲 → 其餘，同一類照品項順序
          r := cut;
          for k in 1 .. 3 loop
            for i in 1 .. n loop
              if v_match[i] and l_ord[i] = k and r > 0 then
                d := least(r, l_rem[i]); l_rem[i] := l_rem[i] - d; r := r - d;
              end if;
            end loop;
          end loop;
        end if;

        v_coupon_cut := v_coupon_cut + cut;
        v_coupons := v_coupons || jsonb_build_array(jsonb_build_object(
          'member_coupon_id', cp.mc_id, 'name', cp.c_name, 'kind', cp.kind,
          'scope_label', public._coupon_scope_label(cp.coupon_id),
          'cut', cut, 'cost_bearer', cp.cost_bearer));
      end loop;
    end if;

    /* 券從檯費扣了多少。
       🔴 2026-11-14 修正：鎖住檯費那一輪，券根本碰不到檯費 ⇒ 就是 0。
          不可以拿「一開始可折的」減「鎖住後的 0」—— 那會把整筆檯費算成券扣的。 */
    v_coupon_fee := 0;
    if not v_lock_fee then
      for i in 1 .. n loop
        if l_rt[i] = 'venue_fee' then v_coupon_fee := v_coupon_fee + (l_rem0[i] - l_rem[i]); end if;
      end loop;
    end if;

    if v_pass = 1 and v_coupon_fee > 0 and v_coupon_fee <= v_best then
      v_lock_fee := true;   -- 券沒有比較多 ⇒ 不准碰檯費，重算一次
    else
      exit;
    end if;
  end loop;

  /* 檯費只用一種：券／牌咖團優惠／會員折扣。
     沒用會員折扣時折扣率也記成 0，訂單上的快照才不會出現「9 折但折了 0 元」。 */
  if v_coupon_fee > 0 then
    v_choice := 'coupon';  v_pct := 0; v_tier_cut := 0; v_adv_cut := 0;
  elsif v_opt_adv > v_opt_tier then
    v_choice := 'advisor'; v_pct := 0; v_tier_cut := 0; v_adv_cut := v_opt_adv;
  elsif v_opt_tier > 0 then
    v_choice := 'tier';    v_tier_cut := v_opt_tier; v_adv_cut := 0;
  else
    v_choice := 'none';    v_tier_cut := 0; v_adv_cut := 0;
  end if;

  v_payable := v_sub - v_coupon_cut - v_tier_cut - v_adv_cut;
  if v_payable < 0 then raise exception '應付金額為負，折扣計算有誤'; end if;

  return jsonb_build_object(
    'subtotal', v_sub, 'non_discountable', v_nodisc,
    'fee', v_fee, 'fnb', v_fnb, 'goods', v_goods,
    'coupon_discount', v_coupon_cut, 'coupons', v_coupons,
    'tier', v_tier, 'tier_discount_pct', v_pct, 'tier_discount', v_tier_cut,
    'advisor_discount', v_adv_cut,
    -- 🆕 2026-11-14：檯費用了哪一種（coupon／advisor／tier／none），與另外兩個選項各折多少
    'fee_choice', v_choice,
    'fee_options', jsonb_build_object('tier', v_opt_tier, 'advisor', v_opt_adv, 'coupon', v_coupon_fee),
    'payable', v_payable);
end $function$;

-- ── 驗證（單一 SELECT，不 raise）──────────────────────────────────────────
select
  (select case when count(*) = 1 then '✅' else '🔴' end || ' ① _cart_pricing 版本數 ' || count(*)
     from pg_proc where pronamespace = 'public'::regnamespace and proname = '_cart_pricing') || E'\n' ||
  (select case when pg_get_functiondef(p.oid) like '%if not v_lock_fee then%' then '✅ ② 是修正版（鎖住檯費那一輪記 0）' else '🔴 ② 還是舊版' end
     from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = '_cart_pricing') || E'\n' ||
  (select case when not has_function_privilege('anon', 'public._cart_pricing(uuid,uuid,jsonb,uuid[],bigint)', 'execute')
                and not has_function_privilege('authenticated', 'public._cart_pricing(uuid,uuid,jsonb,uuid[],bigint)', 'execute')
               then '✅' else '🔴' end || ' ③ 計價核心前端還是叫不到')
  as "驗證";
