/* ============================================================
   行為測試：優惠券適用範圍規則表（交易內，**全部回滾**）
   2026-10-01 · 配 sql/pending/2026-10-01_優惠券適用範圍改成規則表.sql（先跑那份）

   ⓐ 舊寫法新舊一致：把**改之前**的計價核心原封不動複製成 pg_temp._cart_pricing_old，
      舊版讀 applies_to、新版讀 coupon_scopes（照搬家規則建好對應的規則），
      4 個等級 × 3 種購物車 × 10 種用券組合 ＝ 120 案，逐項比對（成功與失敗都要有）
   ⓑ 新寫法算得對（期望值手算）：子分類、指定商品、多條規則、都不適用、不可折扣品項、
      等級折扣的基數不受餐飲券影響、指定商品免費券只從那個商品扣（唯一刻意的行為改變）、顯示文字
   ⓒ 真的結帳一次：用子分類券走 checkout_tx，券記下的折抵額、狀態，以及報價＝實收
   ⚠ 故意 raise 回滾（硬規則 1.8 的例外），訊息設在 exception handler 裡（硬規則 3.9）
   ============================================================ */

-- ── 改之前的計價核心（2026-10-01 上一份 SQL 的全文，只改名字）──
create or replace function pg_temp._cart_pricing_old(p_org uuid, p_member_id uuid, p_items jsonb, p_coupon_ids uuid[])
returns jsonb language plpgsql as $old$
declare
  v_tier text; v_pct int;
  v_sub bigint := 0; v_fee bigint := 0; v_fnb bigint := 0; v_goods bigint := 0;
  v_nodisc bigint := 0; v_coupon_cut bigint := 0; v_tier_cut bigint; v_payable bigint;
  v_coupons jsonb := '[]'::jsonb; it jsonb; cp record;
  rem_fee bigint; rem_fnb bigint; rem_goods bigint; cap bigint; cut bigint;
begin
  if p_items is not null and jsonb_typeof(p_items) = 'array' then
    for it in select * from jsonb_array_elements(p_items) loop
      declare
        l_pid uuid := nullif(it->>'product_id','')::uuid; l_qty int := (it->>'qty')::int;
        l_price bigint; l_name text; l_bucket text; l_disc boolean; l_line bigint;
      begin
        if l_pid is null then raise exception '品項缺少 product_id：%', coalesce(it->>'name', '(未命名)'); end if;
        select pr.unit_price, pr.name, pr.revenue_type, pr.discountable into l_price, l_name, l_bucket, l_disc
          from public.products pr where pr.id = l_pid and pr.org_id = p_org and pr.deleted_at is null;
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
  end if;
  rem_fee := v_fee; rem_fnb := v_fnb; rem_goods := v_goods;
  if p_coupon_ids is not null and array_length(p_coupon_ids, 1) > 0 then
    for cp in
      select mc.id as mc_id, c.name as c_name, c.applies_to, c.discount_type, c.discount_value,
             c.min_spend, c.max_discount, c.free_product_id, c.cost_bearer
        from member_coupons mc join coupons c on c.id = mc.coupon_id
       where mc.id = any(p_coupon_ids) and mc.member_id = p_member_id
       order by array_position(p_coupon_ids, mc.id)
    loop
      perform 1 from member_coupons where id = cp.mc_id and used_at is null and coalesce(status,'') <> 'used'
        and (expires_at is null or expires_at > now());
      if not found then raise exception '券 % 已使用或已過期', cp.c_name; end if;
      cap := case cp.applies_to when 'table_fee' then rem_fee when 'fnb' then rem_fnb else 0 end;
      if cp.applies_to is null then cap := rem_fee + rem_fnb + rem_goods; end if;
      if cp.discount_type = 'free' and cp.free_product_id is not null then
        select coalesce(sum((it2->>'qty')::int * pr2.unit_price), 0) into cap
          from jsonb_array_elements(p_items) it2 join public.products pr2 on pr2.id = nullif(it2->>'product_id','')::uuid
         where pr2.id = cp.free_product_id and pr2.org_id = p_org and pr2.deleted_at is null and pr2.discountable;
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
      v_coupons := v_coupons || jsonb_build_array(jsonb_build_object(
        'member_coupon_id', cp.mc_id, 'name', cp.c_name, 'applies_to', cp.applies_to, 'cut', cut, 'cost_bearer', cp.cost_bearer));
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
  return jsonb_build_object('subtotal', v_sub, 'non_discountable', v_nodisc, 'fee', v_fee, 'fnb', v_fnb, 'goods', v_goods,
    'coupon_discount', v_coupon_cut, 'coupons', v_coupons, 'tier', v_tier, 'tier_discount_pct', v_pct,
    'tier_discount', v_tier_cut, 'payable', v_payable);
end $old$;

-- 跑一次計價，整理成可比對的形狀（券只比 id、折多少、誰負擔 —— 顯示用的欄位新舊本來就不同）
create or replace function pg_temp.norm_price(p_which text, p_org uuid, p_member uuid, p_items jsonb, p_coupons uuid[])
returns jsonb language plpgsql as $f$
declare r jsonb;
begin
  begin
    if p_which = 'old' then r := pg_temp._cart_pricing_old(p_org, p_member, p_items, p_coupons);
    else r := public._cart_pricing(p_org, p_member, p_items, p_coupons); end if;
  exception when others then
    return jsonb_build_object('error', sqlerrm);
  end;
  return (r - 'coupons') || jsonb_build_object('coupons',
    (select coalesce(jsonb_agg(jsonb_build_object('mc', e->'member_coupon_id', 'cut', e->'cut', 'cb', e->'cost_bearer') order by ord), '[]'::jsonb)
       from jsonb_array_elements(r->'coupons') with ordinality t(e, ord)));
end $f$;

do $$
declare
  x uuid := '526aa8b9-cc93-4327-b878-6d21d399af8e';   -- 測試04
  v_org uuid := '11111111-1111-1111-1111-111111111111';
  v_store uuid := '22222222-2222-2222-2222-222222222222';
  p_fee uuid; p_tea uuid; p_lt uuid; p_day uuid; p_rt uuid; p_des uuid; p_meal uuid; v_des bigint;
  c1 uuid; c2 uuid; c3 uuid; c4 uuid; c5 uuid; c6 uuid; v_cp uuid;
  s1 uuid; s2 uuid; s3 uuid; s4 uuid; s5 uuid; s7 uuid; v_s1cp uuid; v_s2cp uuid; v_s3cp uuid; v_nocp uuid; v_s7cp uuid;
  v_tier text; v_items jsonb; v_combo uuid[]; v_old jsonb; v_new jsonb; r jsonb; v_q jsonb;
  v_n int := 0; v_same int := 0; v_okc int := 0; v_errc int := 0; v_bad text := '';
  v_msg text := ''; v_b text := ''; v_bok int := 0; v_ball int := 0;
begin
  select id into p_fee  from products where sku = 'SVC-TBL-M3'   and org_id = v_org and deleted_at is null;
  select id into p_tea  from products where sku = 'FNB-DRK-BLCK' and org_id = v_org and deleted_at is null;
  select id into p_lt   from products where sku = 'FNB-DRK-LATT' and org_id = v_org and deleted_at is null;
  select id into p_day  from products where sku = 'SVC-TBL-DAY'  and org_id = v_org and deleted_at is null;
  select id, unit_price into p_des, v_des from products where subcategory = 'DES' and org_id = v_org and deleted_at is null and discountable order by sku limit 1;
  select id into p_meal from products where subcategory = 'MEAL' and org_id = v_org and deleted_at is null and discountable order by sku limit 1;
  if p_fee is null or p_tea is null or p_lt is null or p_day is null or p_des is null or p_meal is null then
    raise exception '🔴 樣本商品找不到（檯費 %／紅茶 %／拿鐵 %／暢打 %／甜點 %／主食 %）', p_fee, p_tea, p_lt, p_day, p_des, p_meal;
  end if;
  insert into products (org_id, sku, name, category, unit_price, revenue_type)
  values (v_org, 'ZZ-TEST-RETAIL', '測試周邊', 'merch', 120, 'retail') returning id into p_rt;
  update members set tier_override = null where id = x;

  -- ⓐ 舊寫法：暫時關掉凍結，造出帶 applies_to 的券，再照搬家規則補上對應的規則
  alter table public.coupons disable trigger trg_coupons_applies_to_frozen;
  insert into coupons (org_id, name, kind, discount_type, discount_value, applies_to) values (v_org, 'ZZ1 檯費九折', 'generic', 'percent', 10, 'table_fee') returning id into v_cp;
  insert into coupon_scopes (org_id, coupon_id, scope_type, scope_value) values (v_org, v_cp, 'revenue_type', 'venue_fee');
  insert into member_coupons (org_id, member_id, coupon_id) values (v_org, x, v_cp) returning id into c1;
  insert into coupons (org_id, name, kind, discount_type, discount_value, applies_to, max_discount) values (v_org, 'ZZ2 折一百', 'generic', 'fixed', 100, null, 60) returning id into v_cp;
  insert into member_coupons (org_id, member_id, coupon_id) values (v_org, x, v_cp) returning id into c2;
  insert into coupons (org_id, name, kind, discount_type, applies_to, free_product_id, cost_bearer) values (v_org, 'ZZ3 紅茶免費', 'generic', 'free', 'fnb', p_tea, 'hq') returning id into v_cp;
  insert into coupon_scopes (org_id, coupon_id, scope_type, scope_value) values (v_org, v_cp, 'revenue_type', 'fnb');
  insert into member_coupons (org_id, member_id, coupon_id) values (v_org, x, v_cp) returning id into c3;
  insert into coupons (org_id, name, kind, discount_type, discount_value, applies_to, min_spend) values (v_org, 'ZZ4 滿五百折三十', 'generic', 'fixed', 30, 'fnb', 500) returning id into v_cp;
  insert into coupon_scopes (org_id, coupon_id, scope_type, scope_value) values (v_org, v_cp, 'revenue_type', 'fnb');
  insert into member_coupons (org_id, member_id, coupon_id) values (v_org, x, v_cp) returning id into c4;
  insert into coupons (org_id, name, kind, discount_type, discount_value, applies_to) values (v_org, 'ZZ5 過期券', 'generic', 'percent', 50, null) returning id into v_cp;
  insert into member_coupons (org_id, member_id, coupon_id, expires_at) values (v_org, x, v_cp, now() - interval '1 day') returning id into c5;
  insert into coupons (org_id, name, kind, discount_type, applies_to, free_product_id) values (v_org, 'ZZ6 拿鐵免費', 'generic', 'free', 'fnb', p_lt) returning id into v_cp;
  insert into coupon_scopes (org_id, coupon_id, scope_type, scope_value) values (v_org, v_cp, 'revenue_type', 'fnb');
  insert into member_coupons (org_id, member_id, coupon_id) values (v_org, x, v_cp) returning id into c6;
  alter table public.coupons enable trigger trg_coupons_applies_to_frozen;

  foreach v_tier in array array['bubble_tea','caramel_pudding','tiramisu','chef_special'] loop
    update members set tier = v_tier where id = x;
    for v_items in select * from (values
        (jsonb_build_array(jsonb_build_object('product_id', p_fee, 'qty', 2), jsonb_build_object('product_id', p_tea, 'qty', 1))),
        (jsonb_build_array(jsonb_build_object('product_id', p_fee, 'qty', 1), jsonb_build_object('product_id', p_rt, 'qty', 2),
                           jsonb_build_object('product_id', p_day, 'qty', 1), jsonb_build_object('product_id', p_lt, 'qty', 1))),
        (jsonb_build_array(jsonb_build_object('product_id', p_tea, 'qty', 3)))) t(i)
    loop
      foreach v_combo slice 1 in array array[
          array[null,null]::uuid[], array[c1,null], array[c2,null], array[c3,null], array[c4,null],
          array[c5,null], array[c6,null], array[c1,c3], array[c2,c1], array[c1,c2]] loop
        v_combo := array_remove(v_combo, null);
        v_old := pg_temp.norm_price('old', v_org, x, v_items, case when cardinality(v_combo) = 0 then null else v_combo end);
        v_new := pg_temp.norm_price('new', v_org, x, v_items, case when cardinality(v_combo) = 0 then null else v_combo end);
        v_n := v_n + 1;
        if v_new ? 'error' then v_errc := v_errc + 1; else v_okc := v_okc + 1; end if;
        if v_old = v_new then v_same := v_same + 1;
        elsif length(v_bad) < 1500 then
          v_bad := v_bad || E'\n    ✗ ' || v_tier || ' 舊 ' || v_old::text || E'\n      新 ' || v_new::text;
        end if;
      end loop;
    end loop;
  end loop;
  v_msg := case when v_same = v_n and v_n = 120 and v_okc > 0 and v_errc > 0 then '✅' else '🔴' end
        || ' ⓐ 舊寫法新舊一致 ' || v_same || ' / ' || v_n || '（成功 ' || v_okc || '、失敗 ' || v_errc || '，兩種都要有）' || v_bad || E'\n';

  -- ⓑ 新寫法（期望值手算；會員等級先回到 0 折）
  update members set tier = 'bubble_tea' where id = x;
  insert into coupons (org_id, name, kind, discount_type, discount_value) values (v_org, 'ZZS1 飲料半價', 'generic', 'percent', 50) returning id into v_s1cp;
  insert into coupon_scopes (org_id, coupon_id, scope_type, scope_value) values (v_org, v_s1cp, 'subcategory', 'DRK');
  insert into member_coupons (org_id, member_id, coupon_id) values (v_org, x, v_s1cp) returning id into s1;
  insert into coupons (org_id, name, kind, discount_type, discount_value) values (v_org, 'ZZS2 拿鐵折三十', 'generic', 'fixed', 30) returning id into v_s2cp;
  insert into coupon_scopes (org_id, coupon_id, scope_type, scope_value) values (v_org, v_s2cp, 'product', p_lt::text);
  insert into member_coupons (org_id, member_id, coupon_id) values (v_org, x, v_s2cp) returning id into s2;
  insert into coupons (org_id, name, kind, discount_type, discount_value) values (v_org, 'ZZS3 飲料甜點全免', 'generic', 'fixed', 100000) returning id into v_s3cp;
  insert into coupon_scopes (org_id, coupon_id, scope_type, scope_value) values (v_org, v_s3cp, 'subcategory', 'DRK'), (v_org, v_s3cp, 'subcategory', 'DES');
  insert into member_coupons (org_id, member_id, coupon_id) values (v_org, x, v_s3cp) returning id into s3;
  insert into coupons (org_id, name, kind, discount_type, discount_value) values (v_org, 'ZZS4 炸物折二十', 'generic', 'fixed', 20) returning id into v_cp;
  insert into coupon_scopes (org_id, coupon_id, scope_type, scope_value) values (v_org, v_cp, 'subcategory', 'FRY');
  insert into member_coupons (org_id, member_id, coupon_id) values (v_org, x, v_cp) returning id into s4;
  insert into coupons (org_id, name, kind, discount_type, discount_value) values (v_org, 'ZZS5 檯費折五百', 'generic', 'fixed', 500) returning id into v_cp;
  insert into coupon_scopes (org_id, coupon_id, scope_type, scope_value) values (v_org, v_cp, 'revenue_type', 'venue_fee');
  insert into member_coupons (org_id, member_id, coupon_id) values (v_org, x, v_cp) returning id into s5;
  insert into coupons (org_id, name, kind, discount_type, free_product_id) values (v_org, 'ZZS7 紅茶免費（不指定範圍）', 'generic', 'free', p_tea) returning id into v_s7cp;
  insert into member_coupons (org_id, member_id, coupon_id) values (v_org, x, v_s7cp) returning id into s7;
  insert into coupons (org_id, name, kind, discount_type, discount_value) values (v_org, 'ZZS8 全品項', 'generic', 'fixed', 10) returning id into v_nocp;

  -- B1 子分類：紅茶 50 ＋ 拿鐵 80 ＋ 甜點 ⇒ 只折飲料 130 的一半 ＝ 65
  r := public._cart_pricing(v_org, x, jsonb_build_array(jsonb_build_object('product_id', p_tea, 'qty', 1),
         jsonb_build_object('product_id', p_lt, 'qty', 1), jsonb_build_object('product_id', p_des, 'qty', 1)), array[s1]);
  v_ball := v_ball + 1; if (r->>'coupon_discount')::int = 65 then v_bok := v_bok + 1; v_b := v_b || '✅'; else v_b := v_b || '🔴'; end if;
  v_b := v_b || ' B1 限飲料半價：折 ' || (r->>'coupon_discount') || '（期望 65）' || E'\n';

  -- B2 指定商品：紅茶 1 ＋ 拿鐵 2 ⇒ 折 30
  r := public._cart_pricing(v_org, x, jsonb_build_array(jsonb_build_object('product_id', p_tea, 'qty', 1),
         jsonb_build_object('product_id', p_lt, 'qty', 2)), array[s2]);
  v_ball := v_ball + 1; if (r->>'coupon_discount')::int = 30 then v_bok := v_bok + 1; v_b := v_b || '✅'; else v_b := v_b || '🔴'; end if;
  v_b := v_b || ' B2 限拿鐵折 30：折 ' || (r->>'coupon_discount') || '（期望 30）' || E'\n';

  -- B3 兩條規則（飲料或甜點）：紅茶 ＋ 甜點 ＋ 主食 ⇒ 折 紅茶＋甜點，主食不折
  r := public._cart_pricing(v_org, x, jsonb_build_array(jsonb_build_object('product_id', p_tea, 'qty', 1),
         jsonb_build_object('product_id', p_des, 'qty', 1), jsonb_build_object('product_id', p_meal, 'qty', 1)), array[s3]);
  v_ball := v_ball + 1; if (r->>'coupon_discount')::bigint = 50 + v_des then v_bok := v_bok + 1; v_b := v_b || '✅'; else v_b := v_b || '🔴'; end if;
  v_b := v_b || ' B3 限飲料或甜點全免：折 ' || (r->>'coupon_discount') || '（期望 ' || (50 + v_des) || '）' || E'\n';

  -- B4 都不適用
  begin
    r := public._cart_pricing(v_org, x, jsonb_build_array(jsonb_build_object('product_id', p_tea, 'qty', 1)), array[s4]);
    v_ball := v_ball + 1; v_b := v_b || '🔴 B4 限炸物的券用在只有紅茶的單上竟然沒被擋' || E'\n';
  exception when others then
    v_ball := v_ball + 1;
    if sqlerrm like '%不適用於本次品項%' then v_bok := v_bok + 1; v_b := v_b || '✅'; else v_b := v_b || '🔴'; end if;
    v_b := v_b || ' B4 限炸物的券用在只有紅茶的單上：' || sqlerrm || E'\n';
  end;

  -- B5 不可折扣品項不算進範圍：檯費 150 ＋ 暢打 300，限檯費折 500 ⇒ 只折 150
  r := public._cart_pricing(v_org, x, jsonb_build_array(jsonb_build_object('product_id', p_fee, 'qty', 1),
         jsonb_build_object('product_id', p_day, 'qty', 1)), array[s5]);
  v_ball := v_ball + 1; if (r->>'coupon_discount')::int = 150 then v_bok := v_bok + 1; v_b := v_b || '✅'; else v_b := v_b || '🔴'; end if;
  v_b := v_b || ' B5 暢打不被折：折 ' || (r->>'coupon_discount') || '（期望 150）' || E'\n';

  -- B6 飲料券不影響會員折扣的基數：提拉米蘇（檯費 9 折），檯費 150 ＋ 紅茶，飲料半價 ⇒ 券 25、會員 15
  update members set tier = 'tiramisu' where id = x;
  r := public._cart_pricing(v_org, x, jsonb_build_array(jsonb_build_object('product_id', p_fee, 'qty', 1),
         jsonb_build_object('product_id', p_tea, 'qty', 1)), array[s1]);
  v_ball := v_ball + 1;
  if (r->>'coupon_discount')::int = 25 and (r->>'tier_discount')::int = 15 then v_bok := v_bok + 1; v_b := v_b || '✅'; else v_b := v_b || '🔴'; end if;
  v_b := v_b || ' B6 券 ' || (r->>'coupon_discount') || '、會員 ' || (r->>'tier_discount') || '（期望 25、15）' || E'\n';

  -- B7 刻意的改變：指定商品免費券（不指定範圍）只從紅茶扣 ⇒ 會員折扣照樣是 15（舊版會先扣檯費，只剩 10）
  r := public._cart_pricing(v_org, x, jsonb_build_array(jsonb_build_object('product_id', p_fee, 'qty', 1),
         jsonb_build_object('product_id', p_tea, 'qty', 1)), array[s7]);
  v_old := pg_temp._cart_pricing_old(v_org, x, jsonb_build_array(jsonb_build_object('product_id', p_fee, 'qty', 1),
         jsonb_build_object('product_id', p_tea, 'qty', 1)), array[s7]);
  v_ball := v_ball + 1;
  if (r->>'coupon_discount')::int = 50 and (r->>'tier_discount')::int = 15 then v_bok := v_bok + 1; v_b := v_b || '✅'; else v_b := v_b || '🔴'; end if;
  v_b := v_b || ' B7 紅茶免費券：新版 券 ' || (r->>'coupon_discount') || '、會員 ' || (r->>'tier_discount')
        || '（期望 50、15）；舊版會員 ' || (v_old->>'tier_discount') || '（這就是修掉的那一格）' || E'\n';

  -- B8 顯示文字
  v_ball := v_ball + 1;
  if public._coupon_scope_label(v_s1cp) = '限飲料' and public._coupon_scope_label(v_s2cp) like '限%拿鐵%'
     and public._coupon_scope_label(v_s3cp) like '限%飲料%' and public._coupon_scope_label(v_s3cp) like '%甜點%'
     and public._coupon_scope_label(v_nocp) = '全品項' and public._coupon_scope_label(v_s7cp) like '限%紅茶%' then
    v_bok := v_bok + 1; v_b := v_b || '✅'; else v_b := v_b || '🔴'; end if;
  v_b := v_b || ' B8 顯示：' || public._coupon_scope_label(v_s1cp) || '｜' || public._coupon_scope_label(v_s2cp) || '｜'
        || public._coupon_scope_label(v_s3cp) || '｜' || public._coupon_scope_label(v_nocp) || '｜' || public._coupon_scope_label(v_s7cp) || E'\n';

  v_msg := v_msg || case when v_bok = v_ball then '✅' else '🔴' end || ' ⓑ 新寫法 ' || v_bok || ' / ' || v_ball || E'\n' || v_b;

  -- ⓒ 真的結帳一次：飲料半價券，紅茶 ×2；報價要等於實收，券要記下折抵額並標成已使用
  update members set tier = 'bubble_tea' where id = x;
  update wallets set balance = 1000000000 where member_id = x;
  v_q := public.pos_quote_tx(null, x, 'opener', null, jsonb_build_array(jsonb_build_object('product_id', p_tea, 'qty', 2)), array[s1]);
  r := public.checkout_tx(x, v_store, jsonb_build_array(jsonb_build_object('product_id', p_tea, 'qty', 2)), array[s1],
                          1000000000, null, 'migi-scope-test', null);
  v_msg := v_msg || case when (r->>'payable')::int = 50 and (v_q->>'payable')::int = 50
                          and (select discounted_amount from member_coupons where id = s1) = 50
                          and (select status from member_coupons where id = s1) = 'used'
                         then '✅' else '🔴' end
        || ' ⓒ 結帳：應付 ' || (r->>'payable') || '、報價 ' || (v_q->>'payable') || '、券記下折抵 '
        || (select discounted_amount from member_coupons where id = s1) || '、狀態 ' || (select status from member_coupons where id = s1)
        || '（期望 50、50、50、used）；報價上的券標示：' || coalesce(v_q->'coupons'->0->>'scope_label', '∅');

  raise exception 'migi_rollback';
exception when others then
  if sqlerrm = 'migi_rollback' then perform set_config('migi.a', v_msg, true);
  else perform set_config('migi.a', coalesce(v_msg, '') || E'\n🔴 中途出錯：' || sqlstate || ' ' || sqlerrm, true); end if;
end $$;

select coalesce(nullif(current_setting('migi.a', true), ''), '🔴 沒有訊息') as "行為測試";
