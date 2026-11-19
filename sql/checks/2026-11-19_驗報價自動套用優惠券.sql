/* ============================================================
   2026-11-19 · 驗：報價自動套用優惠券（行為測試，跑完整筆回滾，什麼都不留）
   要先跑 sql/pending/2026-11-19_報價自動套用優惠券.sql。

   在交易裡自己造樣本（硬規則 3.57：不借線上的券）：
     會員    測試03（電話 0910000003），暫時把等級設成提拉米蘇（檯費 9 折，會員折扣 10%）
     券      檯費 5%（輸給會員折扣，不該被挑）／檯費 50%（該被挑）
             餐飲免費 ×2（5 天後、20 天後到期 ⇒ 只挑 5 天那張）
             餐飲免費、明天才能用、1 天後到期（最早到期，但還不能用 ⇒ 不該被挑）
             生日券（送當日暢打）
             通用券 generic（不在自動範圍 ⇒ 不該被挑）
     商品    檯費 SVC-TBL-M3（150）、紅茶 FNB-DRK-BLCK（50）、當日暢打 SVC-TBL-DAY（300）
   ============================================================ */
do $$
declare
  v_msg text := '';
  v_m uuid; v_org uuid;
  p_fee uuid; p_tea uuid; p_day uuid;
  c_fee5 uuid; c_fee50 uuid; c_fnb uuid; c_bday uuid; c_gen uuid;
  m_fee5 uuid; m_fee50 uuid; m_fnbA uuid; m_fnbB uuid; m_future uuid; m_bday uuid; m_gen uuid;
  items_a jsonb; items_fee jsonb; items_day jsonb; items_tea jsonb;
  j jsonb; q jsonb; ids uuid[]; pay bigint;
begin
  begin
    select id, org_id into v_m, v_org from members where phone = '0910000003' and is_test and deleted_at is null;
    if v_m is null then raise exception '找不到測試03'; end if;
    update members set tier_override = 'tiramisu' where id = v_m;
    -- 這位測試帳號原本若有沒用的券，先標成用過（一起回滾），樣本才乾淨
    update member_coupons set status = 'used', used_at = now() where member_id = v_m and status = 'active';

    select id into p_fee from products where org_id = v_org and sku = 'SVC-TBL-M3'   and deleted_at is null;
    select id into p_tea from products where org_id = v_org and sku = 'FNB-DRK-BLCK' and deleted_at is null;
    select id into p_day from products where org_id = v_org and sku = 'SVC-TBL-DAY'  and deleted_at is null;
    if p_fee is null or p_tea is null or p_day is null then raise exception '找不到測試用商品'; end if;

    insert into coupons (org_id, name, kind, discount_type, discount_value)
      values (v_org, '測試檯費95折', 'table_discount', 'percent', 5) returning id into c_fee5;
    insert into coupons (org_id, name, kind, discount_type, discount_value)
      values (v_org, '測試檯費5折', 'table_discount', 'percent', 50) returning id into c_fee50;
    insert into coupons (org_id, name, kind, discount_type)
      values (v_org, '測試飲料免費', 'fnb', 'free') returning id into c_fnb;
    insert into coupons (org_id, name, kind, discount_type, free_product_id)
      values (v_org, '測試生日券', 'birthday', 'free', p_day) returning id into c_bday;
    insert into coupons (org_id, name, kind, discount_type, discount_value)
      values (v_org, '測試通用折20', 'generic', 'fixed', 20) returning id into c_gen;
    insert into coupon_scopes (org_id, coupon_id, scope_type, scope_value) values
      (v_org, c_fee5,  'revenue_type', 'venue_fee'),
      (v_org, c_fee50, 'revenue_type', 'venue_fee'),
      (v_org, c_fnb,   'revenue_type', 'fnb');

    insert into member_coupons (org_id, member_id, coupon_id, expires_at) values (v_org, v_m, c_fee5,  now() + interval '3 days')  returning id into m_fee5;
    insert into member_coupons (org_id, member_id, coupon_id, expires_at) values (v_org, v_m, c_fee50, now() + interval '30 days') returning id into m_fee50;
    insert into member_coupons (org_id, member_id, coupon_id, expires_at) values (v_org, v_m, c_fnb,   now() + interval '5 days')  returning id into m_fnbA;
    insert into member_coupons (org_id, member_id, coupon_id, expires_at) values (v_org, v_m, c_fnb,   now() + interval '20 days') returning id into m_fnbB;
    insert into member_coupons (org_id, member_id, coupon_id, expires_at, valid_from)
      values (v_org, v_m, c_fnb, now() + interval '1 day 12 hours', now() + interval '1 day') returning id into m_future;
    insert into member_coupons (org_id, member_id, coupon_id, expires_at) values (v_org, v_m, c_bday, now() + interval '10 days') returning id into m_bday;
    insert into member_coupons (org_id, member_id, coupon_id, expires_at) values (v_org, v_m, c_gen,  now() + interval '2 days')  returning id into m_gen;

    items_a   := jsonb_build_array(jsonb_build_object('product_id', p_fee, 'qty', 1), jsonb_build_object('product_id', p_tea, 'qty', 1));
    items_fee := jsonb_build_array(jsonb_build_object('product_id', p_fee, 'qty', 1));
    items_day := jsonb_build_array(jsonb_build_object('product_id', p_day, 'qty', 1), jsonb_build_object('product_id', p_tea, 'qty', 1));
    items_tea := jsonb_build_array(jsonb_build_object('product_id', p_tea, 'qty', 1));

    -- ⓐ 檯費＋紅茶：挑檯費 5 折（贏過會員 9 折）＋最早到期、而且現在能用的那張飲料券
    j := public._auto_coupons(v_org, v_m, items_a, 0);
    ids := array(select jsonb_array_elements_text(j -> 'ids')::uuid);
    pay := (public._cart_pricing(v_org, v_m, items_a, ids, 0) ->> 'payable')::bigint;
    v_msg := v_msg || coalesce(case
      when ids @> array[m_fee50, m_fnbA] and ids <@ array[m_fee50, m_fnbA] and pay = 75
        then '✅ ⓐ 檯費＋紅茶：挑了檯費 5 折與 5 天到期的飲料券，應付 150−75＋50−50 = 75'
      else '🔴 ⓐ 挑到 ' || coalesce(j::text, 'null') || '　應付 ' || coalesce(pay::text, 'null') || '（期望 75）' end, '⚪ ⓐ 測不了');

    -- ⓑ 負對照：5% 檯費券輸給會員 9 折，不能出現；明天才能用的、通用券都不能出現
    v_msg := v_msg || E'\n' || coalesce(case
      when not (ids && array[m_fee5, m_future, m_gen, m_fnbB, m_bday])
        then '✅ ⓑ 沒挑：5% 檯費券（輸給會員折扣）、明天才能用的、通用券、第二張飲料券、生日券（單上沒有暢打）'
      else '🔴 ⓑ 挑到了不該挑的：' || j::text end, '⚪ ⓑ 測不了');

    -- ⓒ 檯費 5 折那張用掉了 ⇒ 檯費回到會員 9 折，只挑飲料券
    update member_coupons set status = 'used', used_at = now() where id = m_fee50;
    j := public._auto_coupons(v_org, v_m, items_a, 0);
    ids := array(select jsonb_array_elements_text(j -> 'ids')::uuid);
    pay := (public._cart_pricing(v_org, v_m, items_a, ids, 0) ->> 'payable')::bigint;
    v_msg := v_msg || E'\n' || coalesce(case
      when ids = array[m_fnbA] and pay = 135
        then '✅ ⓒ 沒有好的檯費券 ⇒ 只挑飲料券，檯費用會員 9 折：150−15＋50−50 = 135'
      else '🔴 ⓒ 挑到 ' || j::text || '　應付 ' || coalesce(pay::text, 'null') || '（期望 135）' end, '⚪ ⓒ 測不了');

    -- ⓓ 只有檯費 ⇒ 一張都不挑（飲料券沒東西可折）
    j := public._auto_coupons(v_org, v_m, items_fee, 0);
    v_msg := v_msg || E'\n' || coalesce(case
      when jsonb_array_length(j -> 'ids') = 0 then '✅ ⓓ 單上只有檯費 ⇒ 一張都沒挑'
      else '🔴 ⓓ 單上只有檯費卻挑了 ' || j::text end, '⚪ ⓓ 測不了');

    -- ⓔ 當日暢打＋紅茶 ⇒ 生日券送暢打、飲料券送紅茶，應付 0
    j := public._auto_coupons(v_org, v_m, items_day, 0);
    ids := array(select jsonb_array_elements_text(j -> 'ids')::uuid);
    pay := (public._cart_pricing(v_org, v_m, items_day, ids, 0) ->> 'payable')::bigint;
    v_msg := v_msg || E'\n' || coalesce(case
      when ids @> array[m_bday, m_fnbA] and ids <@ array[m_bday, m_fnbA] and pay = 0
        then '✅ ⓔ 暢打＋紅茶：自動用了生日券與飲料券，應付 0'
      else '🔴 ⓔ 挑到 ' || j::text || '　應付 ' || coalesce(pay::text, 'null') || '（期望 0）' end, '⚪ ⓔ 測不了');

    -- ⓕ 只有紅茶 ⇒ 生日券不挑（沒有暢打），只挑飲料券
    j := public._auto_coupons(v_org, v_m, items_tea, 0);
    ids := array(select jsonb_array_elements_text(j -> 'ids')::uuid);
    v_msg := v_msg || E'\n' || coalesce(case
      when ids = array[m_fnbA] then '✅ ⓕ 單上沒有暢打 ⇒ 生日券不挑，只挑飲料券'
      else '🔴 ⓕ 挑到 ' || j::text end, '⚪ ⓕ 測不了');

    -- ⓖ 報價：沒開自動 ⇒ 跟以前一樣不用任何券（舊版 POS 的行為不能變）
    q := public.pos_quote_tx(p_session_id := null, p_member_id := v_m, p_items := items_a);
    v_msg := v_msg || E'\n' || coalesce(case
      when (q ->> 'ok')::boolean and jsonb_array_length(q -> 'coupons') = 0
       and jsonb_array_length(q -> 'applied_coupon_ids') = 0 and q -> 'auto_coupons' = 'null'::jsonb
       and (q ->> 'payable')::bigint = 185
        then '✅ ⓖ 報價沒開自動 ⇒ 不用任何券，應付 150−15＋50 = 185（跟以前一樣）'
      else '🔴 ⓖ ' || left(q::text, 300) end, '⚪ ⓖ 測不了');

    -- ⓗ 報價：開自動 ⇒ 用的券、應付金額都跟挑券函式一致，而且回傳了 POS 結帳要送的那一份
    q := public.pos_quote_tx(p_session_id := null, p_member_id := v_m, p_items := items_a, p_auto_coupons := true);
    v_msg := v_msg || E'\n' || coalesce(case
      when (q ->> 'ok')::boolean
       and q -> 'applied_coupon_ids' = to_jsonb(array[m_fnbA])
       and jsonb_array_length(q -> 'auto_coupons') = 1
       and q -> 'auto_coupons' -> 0 ->> 'slot' = 'fnb'
       and (q ->> 'payable')::bigint = 135
        then '✅ ⓗ 報價開自動 ⇒ applied_coupon_ids 只有那張飲料券，應付 135'
      else '🔴 ⓗ ' || left(q::text, 300) end, '⚪ ⓗ 測不了');

    -- ⓘ 開自動時，店員送來的券要被忽略（全部交給系統挑）
    q := public.pos_quote_tx(p_session_id := null, p_member_id := v_m, p_items := items_a,
                             p_coupon_ids := array[m_gen], p_auto_coupons := true);
    v_msg := v_msg || E'\n' || coalesce(case
      when (q ->> 'ok')::boolean and q -> 'applied_coupon_ids' = to_jsonb(array[m_fnbA])
        then '✅ ⓘ 開自動時忽略店員送的券（通用券沒有被用）'
      else '🔴 ⓘ ' || left(q::text, 300) end, '⚪ ⓘ 測不了');

    -- ⓙ 正對照：關自動、店員自己選通用券 ⇒ 照樣能用（手動那條路沒壞）
    q := public.pos_quote_tx(p_session_id := null, p_member_id := v_m, p_items := items_a, p_coupon_ids := array[m_gen]);
    v_msg := v_msg || E'\n' || coalesce(case
      when (q ->> 'ok')::boolean and q -> 'applied_coupon_ids' = to_jsonb(array[m_gen])
       and (q ->> 'coupon_discount')::bigint = 20
        then '✅ ⓙ 手動選通用券照樣能用（折 20）'
      else '🔴 ⓙ ' || left(q::text, 300) end, '⚪ ⓙ 測不了');

    raise exception 'migi_rollback';
  exception when others then
    if sqlerrm = 'migi_rollback' then
      perform set_config('migi.t', v_msg, true);
    else
      perform set_config('migi.t', v_msg || E'\n🔴 中途出錯：' || sqlerrm, true);
    end if;
  end;
end $$;

select coalesce(nullif(current_setting('migi.t', true), ''), '🔴 沒有訊息') as "驗證";
