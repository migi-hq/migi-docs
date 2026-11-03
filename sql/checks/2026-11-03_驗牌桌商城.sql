/* ============================================================
   2026-11-03 · 行為測試：牌桌商城（會寫入，但整段回滾）
   先跑 sql/pending/2026-11-03_牌桌商城.sql，再跑這一份。
   借一位有 LINE 的會員，用他的身分（request.jwt.claims）叫三支會員函式；
   先在交易裡發他 45 個碎片（admin），測完 raise 'migi_rollback' 全部退掉。

   ⓐ 商城讀得到：兩款、熊熊星空擁有且使用中
   ⓑ 碎片夠 ⇒ 兌換櫻花成功、帳本記一筆 −40
   ⓒ 再兌換一次 ⇒ 擋下「已經兌換過」，碎片沒有再扣
   ⓓ 使用櫻花 ⇒ 計分板背景變櫻花（_member_table_bg）
   ⓔ 換回熊熊星空（預設款不用兌換）
   ⓕ 沒擁有的款不能用：在交易裡先下架、再上一款新的測
   ⓖ 碎片不夠 ⇒ 擋下並說還差幾個，帳本沒有多一筆
   ============================================================ */
do $$
declare
  v_m    uuid;
  v_line text;
  v_org  uuid;
  r      jsonb;
  v_b0   int;
  v_n    int;
  v_msg  text := '';
begin
  select id, line_user_id, org_id into v_m, v_line, v_org
    from members
   where line_user_id is not null and deleted_at is null and hidden_at is null
   order by is_test desc, created_at
   limit 1;
  if v_m is null then
    v_msg := '⚪ 找不到有 LINE 的會員，整份測不了';
    raise exception 'migi_rollback';
  end if;
  perform set_config('request.jwt.claims', json_build_object('sub', v_line, 'role', 'authenticated')::text, true);
  if public.current_member_id() is distinct from v_m then
    v_msg := '🔴 模擬身分失敗（current_member_id 認不出這位會員）';
    raise exception 'migi_rollback';
  end if;

  -- 先發 45 個（交易裡，最後回滾）
  insert into shard_grants (org_id, member_id, qty, reason, idem_key) values (v_org, v_m, 45, 'admin', 'test:shop:' || v_m);
  select coalesce(sum(qty), 0) into v_b0 from shard_grants where member_id = v_m;

  -- ⓐ
  r := public.get_my_shop_tx();
  v_msg := v_msg || case when jsonb_array_length(r -> 'items') = 2
                          and (r ->> 'shard')::int = v_b0
                          and exists (select 1 from jsonb_array_elements(r -> 'items') x
                                       where x ->> 'code' = 'starry' and (x ->> 'owned')::bool and (x ->> 'equipped')::bool)
    then '✅ ⓐ 商城讀得到兩款、碎片 ' || v_b0 || ' 個、熊熊星空擁有且使用中'
    else '🔴 ⓐ 商城回傳不對：' || r::text end;

  -- ⓑ
  r := public.buy_shop_item_tx('sakura');
  select count(*) into v_n from shard_grants where member_id = v_m and reason = 'shop' and qty = -40;
  v_msg := v_msg || E'\n' || case when (r ->> 'ok')::bool and (r ->> 'shard')::int = v_b0 - 40 and v_n = 1
    then '✅ ⓑ 兌換櫻花：帳本 −40，剩 ' || (r ->> 'shard') || ' 個'
    else '🔴 ⓑ 兌換結果不對：' || r::text end;

  -- ⓒ
  r := public.buy_shop_item_tx('sakura');
  select count(*) into v_n from shard_grants where member_id = v_m and reason = 'shop';
  v_msg := v_msg || E'\n' || case when not (r ->> 'ok')::bool and r ->> 'reason' = 'owned' and v_n = 1
    then '✅ ⓒ 再兌換一次 ⇒「' || (r ->> 'message') || '」，沒有再扣'
    else '🔴 ⓒ 重複兌換沒擋住：' || r::text || '（兌換筆數 ' || v_n || '）' end;

  -- ⓓ
  r := public.equip_shop_item_tx('sakura');
  v_msg := v_msg || E'\n' || case when (r ->> 'ok')::bool and public._member_table_bg(v_m) = 'sakura'
    then '✅ ⓓ 使用櫻花 ⇒ 計分板背景是櫻花'
    else '🔴 ⓓ 使用櫻花不對：' || r::text || ' / ' || public._member_table_bg(v_m) end;

  -- ⓔ
  r := public.equip_shop_item_tx('starry');
  v_msg := v_msg || E'\n' || case when (r ->> 'ok')::bool and public._member_table_bg(v_m) = 'starry'
    then '✅ ⓔ 換回熊熊星空（預設款不用兌換）'
    else '🔴 ⓔ 換回預設不對：' || r::text end;

  -- ⓕ 沒擁有的款不能用
  insert into shop_items (code, kind, name, tier, price, sort) values ('zz_test', 'table_bg', '測試款', 'basic', 10, 99);
  r := public.equip_shop_item_tx('zz_test');
  v_msg := v_msg || E'\n' || case when not (r ->> 'ok')::bool and r ->> 'reason' = 'not_owned'
    then '✅ ⓕ 沒兌換的款不能用 ⇒「' || (r ->> 'message') || '」'
    else '🔴 ⓕ 沒兌換也能用：' || r::text end;

  -- ⓖ 碎片不夠：現在剩 v_b0 − 40，上一款比剩下的多 1 個的
  update shop_items set price = (v_b0 - 40) + 1, tier = 'rare' where code = 'zz_test';
  r := public.buy_shop_item_tx('zz_test');
  select count(*) into v_n from shard_grants where member_id = v_m and reason = 'shop';
  v_msg := v_msg || E'\n' || case when not (r ->> 'ok')::bool and r ->> 'reason' = 'not_enough' and (r ->> 'need')::int = 1 and v_n = 1
    then '✅ ⓖ 碎片不夠 ⇒「' || (r ->> 'message') || '」，帳本沒有多一筆'
    else '🔴 ⓖ 碎片不夠沒擋住：' || r::text end;

  raise exception 'migi_rollback';
exception when others then
  perform set_config('migi.shop_test',
    v_msg || case when sqlerrm = 'migi_rollback' then E'\n（整段已回滾，一筆都沒留下）'
                  else E'\n🔴 中途出錯：' || sqlerrm end, true);
end $$;

select coalesce(nullif(current_setting('migi.shop_test', true), ''), '🔴 沒有訊息') as "行為測試";
