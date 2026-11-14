/* 行為測試：檯費優惠擇優 ＋ 生日券計價（2026-11-14）
   ⚠ 要在 sql/pending/2026-11-14_檯費優惠擇優與生日券計價.sql 跑過之後才跑。
   全部在交易裡造樣本（測試01，提拉米蘇＝會員折扣 10%），最後故意 raise 'migi_rollback'，
   一列都不會留下 —— 這份是「故意不要提交」的那一種（硬規則 1.8）。

   商品：配桌檯費 3 將 150、牛肉麵 160、當日暢打 300（不參與折扣）
   每一格寫「以前會怎樣」，看得出哪些是規則改了、哪些是本來就一樣。 */
do $$
declare
  v_org uuid; v_mem uuid; v_store uuid;
  p_fee uuid; p_beef uuid; p_day uuid;
  c_pct uuid; c_fix80 uuid; c_beef uuid; c_gen30 uuid; c_bday uuid; c_late uuid;
  m_pct uuid; m_fix80 uuid; m_beef uuid; m_gen30 uuid; m_bday uuid; m_late uuid;
  v_fee jsonb; v_fee_beef jsonb; v_fee_day_beef jsonb; v_day_beef jsonb; v_beef jsonb; v_day jsonb;
  r jsonb; v_msg text := ''; v_ok int := 0; v_all int := 0; v_err text; v_line text;
  v_q jsonb; v_o jsonb; v_order uuid;
begin
  select id, org_id into v_mem, v_org from members where id = 'd73fdac2-d6b9-4b8a-bcff-b19c2786056f';
  if v_mem is null then raise exception '找不到測試01'; end if;
  update members set tier_override = 'tiramisu' where id = v_mem;     -- 固定 10%，不受線上設定影響
  select id into v_store from stores where org_id = v_org and store_type = '直營' and deleted_at is null order by code limit 1;
  select id into p_fee  from products where org_id = v_org and sku = 'SVC-TBL-M3'    and deleted_at is null;
  select id into p_beef from products where org_id = v_org and sku = 'FNB-MEAL-BEEF' and deleted_at is null;
  select id into p_day  from products where org_id = v_org and sku = 'SVC-TBL-DAY'   and deleted_at is null;
  if v_store is null or p_fee is null or p_beef is null or p_day is null then
    raise exception '樣本不齊：門市 % 檯費 % 牛肉麵 % 暢打 %', v_store, p_fee, p_beef, p_day;
  end if;

  v_fee          := jsonb_build_array(jsonb_build_object('product_id', p_fee, 'qty', 1));
  v_beef         := jsonb_build_array(jsonb_build_object('product_id', p_beef, 'qty', 1));
  v_day          := jsonb_build_array(jsonb_build_object('product_id', p_day, 'qty', 1));
  v_fee_beef     := v_fee || v_beef;
  v_day_beef     := v_day || v_beef;
  v_fee_day_beef := v_fee || v_day || v_beef;

  -- 造券
  insert into coupons (org_id, name, kind, discount_type, discount_value) values (v_org, '測·檯費9折', 'table_discount', 'percent', 10) returning id into c_pct;
  insert into coupon_scopes (org_id, coupon_id, scope_type, scope_value) values (v_org, c_pct, 'revenue_type', 'venue_fee');
  insert into coupons (org_id, name, kind, discount_type, discount_value) values (v_org, '測·檯費折80', 'table_discount', 'fixed', 80) returning id into c_fix80;
  insert into coupon_scopes (org_id, coupon_id, scope_type, scope_value) values (v_org, c_fix80, 'revenue_type', 'venue_fee');
  insert into coupons (org_id, name, kind, discount_type, free_product_id) values (v_org, '測·牛肉麵免費', 'fnb', 'free', p_beef) returning id into c_beef;
  insert into coupons (org_id, name, kind, discount_type, discount_value) values (v_org, '測·全品項折30', 'generic', 'fixed', 30) returning id into c_gen30;
  insert into coupons (org_id, name, kind, discount_type, free_product_id) values (v_org, '測·生日暢打', 'birthday', 'free', p_day) returning id into c_bday;
  insert into coupons (org_id, name, kind, discount_type, discount_value) values (v_org, '測·還沒到', 'generic', 'fixed', 10) returning id into c_late;
  insert into member_coupons (org_id, member_id, coupon_id) values (v_org, v_mem, c_pct)   returning id into m_pct;
  insert into member_coupons (org_id, member_id, coupon_id) values (v_org, v_mem, c_fix80) returning id into m_fix80;
  insert into member_coupons (org_id, member_id, coupon_id) values (v_org, v_mem, c_beef)  returning id into m_beef;
  insert into member_coupons (org_id, member_id, coupon_id) values (v_org, v_mem, c_gen30) returning id into m_gen30;
  insert into member_coupons (org_id, member_id, coupon_id, valid_from, expires_at, birthday_year)
    values (v_org, v_mem, c_bday, now() - interval '1 day', now() + interval '20 days', 2099) returning id into m_bday;
  insert into member_coupons (org_id, member_id, coupon_id, valid_from) values (v_org, v_mem, c_late, now() + interval '3 days') returning id into m_late;

  -- ⓐ 只有檯費、沒券、沒牌咖團 ⇒ 會員折扣 15                         （以前一樣）
  v_all := v_all + 1;
  r := public._cart_pricing(v_org, v_mem, v_fee, null, 0);
  v_line := format('ⓐ 只有會員折扣：折 %s、應付 %s、用了 %s', r->>'tier_discount', r->>'payable', r->>'fee_choice');
  if (r->>'tier_discount')::int = 15 and (r->>'payable')::int = 135 and r->>'fee_choice' = 'tier' then v_ok := v_ok + 1; v_line := '✅ ' || v_line; else v_line := '🔴 ' || v_line; end if;
  v_msg := v_msg || v_line || E'\n';

  -- ⓑ 牌咖團 50 vs 會員 15 ⇒ 牌咖團 50、會員折扣率記 0                 （以前一樣）
  v_all := v_all + 1;
  r := public._cart_pricing(v_org, v_mem, v_fee, null, 50);
  v_line := format('ⓑ 牌咖團比較多：牌咖團 %s、會員 %s（率 %s）、應付 %s', r->>'advisor_discount', r->>'tier_discount', r->>'tier_discount_pct', r->>'payable');
  if (r->>'advisor_discount')::int = 50 and (r->>'tier_discount')::int = 0 and (r->>'tier_discount_pct')::int = 0 and (r->>'payable')::int = 100 then v_ok := v_ok + 1; v_line := '✅ ' || v_line; else v_line := '🔴 ' || v_line; end if;
  v_msg := v_msg || v_line || E'\n';

  -- ⓒ 檯費 9 折券 15 vs 會員 15 一樣大 ⇒ 券不用，結帳失敗並說明        （以前：券 15 ＋ 會員 14 疊在一起）
  v_all := v_all + 1;
  begin
    r := public._cart_pricing(v_org, v_mem, v_fee, array[m_pct], 0);
    v_line := '🔴 ⓒ 檯費券跟會員折扣一樣多卻用了券：券 ' || (r->>'coupon_discount') || '、會員 ' || (r->>'tier_discount');
  exception when others then
    if sqlerrm like '%只折檯費%會員折扣%15%' then v_ok := v_ok + 1; v_line := '✅ ⓒ 檯費券沒有比較多 ⇒ 擋下：' || sqlerrm;
    else v_line := '🔴 ⓒ 錯誤訊息不對：' || sqlerrm; end if;
  end;
  v_msg := v_msg || v_line || E'\n';

  -- ⓓ 檯費折 80 券 vs 牌咖團 50 ⇒ 用券 80，牌咖團與會員都不算          （以前：用了券牌咖團就歸零，會員再折 7）
  v_all := v_all + 1;
  r := public._cart_pricing(v_org, v_mem, v_fee, array[m_fix80], 50);
  v_line := format('ⓓ 檯費券比較多：券 %s、牌咖團 %s、會員 %s、應付 %s', r->>'coupon_discount', r->>'advisor_discount', r->>'tier_discount', r->>'payable');
  if (r->>'coupon_discount')::int = 80 and (r->>'advisor_discount')::int = 0 and (r->>'tier_discount')::int = 0 and (r->>'payable')::int = 70 and r->>'fee_choice' = 'coupon' then v_ok := v_ok + 1; v_line := '✅ ' || v_line; else v_line := '🔴 ' || v_line; end if;
  v_msg := v_msg || v_line || E'\n';

  -- ⓔ 牛肉麵免費券 ＋ 牌咖團 50 ⇒ 兩個都拿                              （以前：用了券牌咖團就歸零 ⇒ 應付 135）
  v_all := v_all + 1;
  r := public._cart_pricing(v_org, v_mem, v_fee_beef, array[m_beef], 50);
  v_line := format('ⓔ 餐飲券不影響牌咖團：券 %s、牌咖團 %s、應付 %s', r->>'coupon_discount', r->>'advisor_discount', r->>'payable');
  if (r->>'coupon_discount')::int = 160 and (r->>'advisor_discount')::int = 50 and (r->>'payable')::int = 100 then v_ok := v_ok + 1; v_line := '✅ ' || v_line; else v_line := '🔴 ' || v_line; end if;
  v_msg := v_msg || v_line || E'\n';

  -- ⓕ 牛肉麵免費券 ＋ 會員折扣 ⇒ 兩個都拿                              （以前一樣）
  v_all := v_all + 1;
  r := public._cart_pricing(v_org, v_mem, v_fee_beef, array[m_beef], 0);
  v_line := format('ⓕ 餐飲券＋會員折扣：券 %s、會員 %s、應付 %s', r->>'coupon_discount', r->>'tier_discount', r->>'payable');
  if (r->>'coupon_discount')::int = 160 and (r->>'tier_discount')::int = 15 and (r->>'payable')::int = 135 then v_ok := v_ok + 1; v_line := '✅ ' || v_line; else v_line := '🔴 ' || v_line; end if;
  v_msg := v_msg || v_line || E'\n';

  -- ⓖ 全品項折 30 ＋ 牌咖團 50：從檯費扣 30 沒比較多 ⇒ 改扣牛肉麵，牌咖團照拿   （以前：券扣檯費、牌咖團歸零）
  v_all := v_all + 1;
  r := public._cart_pricing(v_org, v_mem, v_fee_beef, array[m_gen30], 50);
  v_line := format('ⓖ 全品項券改折餐飲：券 %s、牌咖團 %s、應付 %s、券從檯費扣 %s', r->>'coupon_discount', r->>'advisor_discount', r->>'payable', r->'fee_options'->>'coupon');
  if (r->>'coupon_discount')::int = 30 and (r->>'advisor_discount')::int = 50 and (r->>'payable')::int = 230 and (r->'fee_options'->>'coupon')::int = 0 then v_ok := v_ok + 1; v_line := '✅ ' || v_line; else v_line := '🔴 ' || v_line; end if;
  v_msg := v_msg || v_line || E'\n';

  -- ⓗ 生日券 ＋ 當日暢打 ＋ 牛肉麵 ⇒ 暢打 0 元，牛肉麵照收                  （以前：暢打不參與折扣 ⇒ 結帳失敗）
  v_all := v_all + 1;
  r := public._cart_pricing(v_org, v_mem, v_day_beef, array[m_bday], 0);
  v_line := format('ⓗ 生日券換暢打：券 %s、應付 %s', r->>'coupon_discount', r->>'payable');
  if (r->>'coupon_discount')::int = 300 and (r->>'payable')::int = 160 then v_ok := v_ok + 1; v_line := '✅ ' || v_line; else v_line := '🔴 ' || v_line; end if;
  v_msg := v_msg || v_line || E'\n';

  -- ⓘ 生日券但沒選暢打 ⇒ 失敗並說明
  v_all := v_all + 1;
  begin
    r := public._cart_pricing(v_org, v_mem, v_beef, array[m_bday], 0);
    v_line := '🔴 ⓘ 沒有暢打卻用了生日券：券 ' || (r->>'coupon_discount');
  exception when others then
    if sqlerrm like '%當日暢打%' then v_ok := v_ok + 1; v_line := '✅ ⓘ 沒選暢打 ⇒ 擋下：' || sqlerrm;
    else v_line := '🔴 ⓘ 錯誤訊息不對：' || sqlerrm; end if;
  end;
  v_msg := v_msg || v_line || E'\n';

  -- ⓙ 還沒到可用日的券 ⇒ 失敗並寫幾號起
  v_all := v_all + 1;
  begin
    r := public._cart_pricing(v_org, v_mem, v_beef, array[m_late], 0);
    v_line := '🔴 ⓙ 還沒到可用日卻用了：券 ' || (r->>'coupon_discount');
  exception when others then
    if sqlerrm like '%還沒到可用日%起才能用%' then v_ok := v_ok + 1; v_line := '✅ ⓙ 還沒到可用日 ⇒ 擋下：' || sqlerrm;
    else v_line := '🔴 ⓙ 錯誤訊息不對：' || sqlerrm; end if;
  end;
  v_msg := v_msg || v_line || E'\n';

  -- ⓚ 壽星替別人付檯費：生日券送自己的暢打，別人的檯費照拿牌咖團 50（第 5 題）
  v_all := v_all + 1;
  r := public._cart_pricing(v_org, v_mem, v_fee_day_beef, array[m_bday], 50);
  v_line := format('ⓚ 生日券不擋牌咖團：券 %s、牌咖團 %s、應付 %s', r->>'coupon_discount', r->>'advisor_discount', r->>'payable');
  if (r->>'coupon_discount')::int = 300 and (r->>'advisor_discount')::int = 50 and (r->>'payable')::int = 260 then v_ok := v_ok + 1; v_line := '✅ ' || v_line; else v_line := '🔴 ' || v_line; end if;
  v_msg := v_msg || v_line || E'\n';

  -- ⓛ POS 報價的 coupon_options：9 折券灰掉、折 80 券可用且省 65、牛肉麵券在沒有牛肉麵時灰掉
  v_all := v_all + 1;
  v_q := public.pos_quote_tx(null, v_mem, 'opener', null, v_fee, null, null);
  select jsonb_object_agg(o->>'member_coupon_id', o) into v_o from jsonb_array_elements(v_q->'coupon_options') o;
  v_line := format('ⓛ 報價的券清單：9折 %s／折80 %s 省 %s／牛肉麵 %s／還沒到 %s',
    v_o->m_pct::text->>'ok', v_o->m_fix80::text->>'ok', v_o->m_fix80::text->>'saves', v_o->m_beef::text->>'ok', v_o->m_late::text->>'ok');
  if (v_o->m_pct::text->>'ok')::boolean = false and (v_o->m_fix80::text->>'ok')::boolean = true
     and (v_o->m_fix80::text->>'saves')::int = 65 and (v_o->m_beef::text->>'ok')::boolean = false
     and (v_o->m_late::text->>'ok')::boolean = false then v_ok := v_ok + 1; v_line := '✅ ' || v_line; else v_line := '🔴 ' || v_line; end if;
  v_msg := v_msg || v_line || E'\n';

  -- ⓜ 正對照：真的結一次帳（生日券換暢打）⇒ 訂單 0 元、券標成用掉、今天就算有暢打
  v_all := v_all + 1;
  r := public.checkout_tx(v_mem, v_store, v_day, array[m_bday], 0, null, 'test-bday-' || gen_random_uuid(), null, null);
  v_order := (r->>'order_id')::uuid;
  v_line := format('ⓜ 真的結帳：應付 %s、券折 %s、券已用 %s、今天有暢打 %s', r->>'payable', r->>'coupon_discount',
    (select (used_order = v_order)::text from member_coupons where id = m_bday),
    public.has_daypass_tx_core(v_org, v_mem, v_store)::text);
  if (r->>'payable')::int = 0 and (r->>'coupon_discount')::int = 300
     and (select used_order = v_order from member_coupons where id = m_bday)
     and public.has_daypass_tx_core(v_org, v_mem, v_store) then v_ok := v_ok + 1; v_line := '✅ ' || v_line; else v_line := '🔴 ' || v_line; end if;
  v_msg := v_msg || v_line || E'\n';

  v_msg := case when v_ok = v_all then '✅ 全部通過 ' else '🔴 有沒過的 ' end || v_ok || '/' || v_all || E'\n' || v_msg;
  raise exception 'migi_rollback';
exception when others then
  if sqlerrm = 'migi_rollback' then
    perform set_config('migi.t', v_msg, true);
  else
    perform set_config('migi.t', '🔴 中途中斷：' || sqlerrm || E'\n' || coalesce(v_msg, ''), true);
  end if;
end $$;
select coalesce(nullif(current_setting('migi.t', true), ''), '🔴 沒有訊息') as "行為測試";
