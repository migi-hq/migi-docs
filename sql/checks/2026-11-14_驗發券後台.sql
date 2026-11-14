/* 行為測試：發券後台（sql/pending/2026-11-14_發券後台.sql 跑完之後跑）
   整段在交易裡做、最後故意回滾（raise 'migi_rollback'）⇒ 不留任何東西。結果印在最後那支 SELECT。
   身分：總部（admin@migi.tw 的 auth uid，role=hq）；負對照用一個不存在的使用者。
   樣本：兩位測試帳號（is_test）、一個可折扣的餐飲商品、一個檯費商品 —— 都從資料庫撈，不寫死 id。
   🎯 最重要的一格是 ⓗ：後台發出去的券，結帳的計價核心真的折得到錢（不然整個後台發的都是廢紙）。 */
do $$
declare
  v_msg text := ''; ln text := E'\n';
  v_hq text := '{"sub":"2485579b-966f-4da6-8ccd-d3adb7ba084b","role":"authenticated"}';
  v_nobody text := '{"sub":"00000000-0000-0000-0000-000000000001","role":"authenticated"}';
  v_org uuid := '11111111-1111-1111-1111-111111111111';
  v_m1 uuid; v_m2 uuid; v_fnb uuid; v_fee uuid;
  v_r jsonb; v_cid uuid; v_mc uuid; v_n int; v_by text; v_exp timestamptz;
begin
  select id into v_m1 from public.members where is_test and not is_bot and deleted_at is null order by created_at limit 1;
  select id into v_m2 from public.members where is_test and not is_bot and deleted_at is null and id <> v_m1 order by created_at limit 1;
  select id into v_fnb from public.products where sku = 'FNB-DES-BSKQ' and deleted_at is null;     -- 巴斯克乳酪 90
  select id into v_fee from public.products where sku = 'SVC-TBL-M2' and deleted_at is null;       -- 配桌檯費 2 將
  if v_m1 is null or v_m2 is null or v_fnb is null or v_fee is null then
    perform set_config('migi.coupon_test', '🔴 找不到樣本（測試帳號兩位、巴斯克、配桌檯費 2 將）', true);
    return;
  end if;

  begin
    perform set_config('request.jwt.claims', v_hq, true);
    execute 'set local role authenticated';

    -- ⓐ 建一張「餐飲 85 折」，範圍只有餐飲
    v_r := public.admin_upsert_coupon_tx(null, '測試 餐飲85折', 'percent', 15, null,
             '[{"type":"revenue_type","value":"fnb"}]'::jsonb, null, null, 30, null, 'hq');
    v_cid := (v_r->>'id')::uuid;
    v_msg := v_msg || case when (v_r->>'ok')::boolean and v_r->>'scope_label' = '限餐飲' then '✅' else '🔴' end
             || ' ⓐ 新增券：' || coalesce(v_r->>'scope_label', v_r->>'message') || ln;
    v_msg := v_msg || case when (select kind from public.coupons where id = v_cid) = 'fnb' then '✅' else '🔴' end
             || ' ⓐ-2 舊分類由範圍推出來：' || coalesce((select kind from public.coupons where id = v_cid), 'null') || ln;

    -- ⓑ 打折填 100 要擋（100 是免費，要選免費）
    v_r := public.admin_upsert_coupon_tx(null, 'x', 'percent', 100, null, '[]', null, null, null, null, 'store');
    v_msg := v_msg || case when v_r->>'reason' = 'bad_value' then '✅' else '🔴' end || ' ⓑ 打折 100 被擋' || ln;
    -- ⓒ 指定商品免費券又選範圍要擋
    v_r := public.admin_upsert_coupon_tx(null, 'x', 'free', null, v_fnb, '[{"type":"revenue_type","value":"fnb"}]', null, null, null, null, 'store');
    v_msg := v_msg || case when v_r->>'reason' = 'scope_with_free' then '✅' else '🔴' end || ' ⓒ 免費商品券又選範圍被擋' || ln;
    -- ⓓ 範圍值寫錯：觸發器的原話回來，而且整筆不留（券也不會建出來）
    v_n := (select count(*) from public.coupons);
    v_r := public.admin_upsert_coupon_tx(null, '測試 壞範圍', 'fixed', 50, null, '[{"type":"subcategory","value":"NOPE"}]', null, null, null, null, 'store');
    v_msg := v_msg || case when v_r->>'reason' = 'save_failed' and v_r->>'message' like '%不存在%' and (select count(*) from public.coupons) = v_n
                           then '✅' else '🔴' end || ' ⓓ 範圍值寫錯被擋、券沒建出來：' || coalesce(v_r->>'message', '') || ln;

    -- ⓔ 發給兩位、每人 2 張
    v_r := public.admin_grant_coupon_tx(v_cid, array[v_m1, v_m2], 2, '測試發券');
    select count(*), max(s.name), max(mc.expires_at) into v_n, v_by, v_exp
      from public.member_coupons mc left join public.staff s on s.id = mc.granted_by_staff_id where mc.coupon_id = v_cid;
    v_msg := v_msg || case when (v_r->>'granted')::int = 4 and v_n = 4 and v_by is not null
                                and v_exp between now() + interval '29 days 23 hours' and now() + interval '30 days 1 hour'
                           then '✅' else '🔴' end
             || ' ⓔ 發出 4 張、記了誰發的（' || coalesce(v_by, 'null') || '）、30 天後到期' || ln;

    -- ⓕ 發出去之後不能改折扣內容；只改名字可以
    v_r := public.admin_upsert_coupon_tx(v_cid, '測試 餐飲8折', 'percent', 20, null, '[{"type":"revenue_type","value":"fnb"}]', null, null, 30, null, 'hq');
    v_msg := v_msg || case when v_r->>'reason' = 'issued_locked' then '✅' else '🔴' end || ' ⓕ 發出去之後改折數被擋' || ln;
    v_r := public.admin_upsert_coupon_tx(v_cid, '測試 餐飲85折（改名）', 'percent', 15, null, '[{"type":"revenue_type","value":"fnb"}]', null, null, 30, null, 'hq');
    v_msg := v_msg || case when (v_r->>'ok')::boolean and (select name from public.coupons where id = v_cid) = '測試 餐飲85折（改名）'
                           then '✅' else '🔴' end || ' ⓕ-2 只改名字可以：' || coalesce(v_r->>'message', 'ok') || ln;

    -- ⓖ 發出去的清單
    v_r := public.admin_list_member_coupons_tx(v_cid, 'unused', 50);
    v_msg := v_msg || case when jsonb_array_length(v_r->'rows') = 4 and v_r->'rows'->0->>'granted_by' is not null then '✅' else '🔴' end
             || ' ⓖ 清單列出 4 張未使用' || ln;
    v_r := public.admin_list_coupons_tx();
    v_msg := v_msg || case when exists (select 1 from jsonb_array_elements(v_r->'rows') x where (x->>'id')::uuid = v_cid
                                          and (x->>'issued')::int = 4 and (x->>'unused')::int = 4) then '✅' else '🔴' end
             || ' ⓖ-2 券清單的發出／未使用數字對' || ln;

    -- ⓘ 停用之後不能再發
    v_r := public.admin_set_coupon_active_tx(v_cid, false);
    v_r := public.admin_grant_coupon_tx(v_cid, array[v_m1], 1, null);
    v_msg := v_msg || case when v_r->>'reason' = 'inactive' then '✅' else '🔴' end || ' ⓘ 停用之後發券被擋' || ln;

    -- ⓙ 沒有權限的人：清單、新增、發券都擋
    perform set_config('request.jwt.claims', v_nobody, true);
    v_msg := v_msg || case when public.admin_list_coupons_tx()->>'reason' = 'forbidden'
                            and public.admin_grant_coupon_tx(v_cid, array[v_m1], 1, null)->>'reason' = 'forbidden'
                            and public.admin_upsert_coupon_tx(null, 'x', 'fixed', 10, null, '[]', null, null, null, null, 'store')->>'reason' = 'forbidden'
                           then '✅' else '🔴' end || ' ⓙ 沒權限的人全部被擋' || ln;

    execute 'reset role';

    -- ⓗ 正對照：發出去的券真的折得到錢（停用不影響已發出的）
    select id into v_mc from public.member_coupons where coupon_id = v_cid and member_id = v_m1 limit 1;
    v_r := public._cart_pricing(v_org, v_m1, jsonb_build_array(jsonb_build_object('product_id', v_fnb, 'qty', 2)), array[v_mc], 0);
    v_msg := v_msg || case when (v_r->>'coupon_discount')::bigint = 27 then '✅' else '🔴' end
             || ' ⓗ 結帳計價：巴斯克 90×2＝180，85 折折抵 ' || coalesce(v_r->>'coupon_discount', 'null') || '（期望 27，停用中仍可用）' || ln;
    -- ⓗ-2 負對照：只買檯費，餐飲券不適用
    begin
      v_r := public._cart_pricing(v_org, v_m1, jsonb_build_array(jsonb_build_object('product_id', v_fee, 'qty', 1)), array[v_mc], 0);
      v_msg := v_msg || '🔴 ⓗ-2 只買檯費卻用得了餐飲券' || ln;
    exception when others then
      v_msg := v_msg || case when sqlerrm like '%不適用%' then '✅' else '🔴' end || ' ⓗ-2 只買檯費時被擋：' || sqlerrm || ln;
    end;

    raise exception 'migi_rollback';
  exception when others then
    if sqlerrm <> 'migi_rollback' then v_msg := v_msg || '🔴 中途出錯：' || sqlerrm; end if;
    perform set_config('migi.coupon_test', v_msg, true);
  end;
end $$;
select coalesce(nullif(current_setting('migi.coupon_test', true), ''), '🔴 沒有測試訊息') as "發券後台（行為）";
