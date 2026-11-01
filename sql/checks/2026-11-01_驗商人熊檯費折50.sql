/* ============================================================
   驗商人熊（2026-11-01_牌咖團顧問_商人熊檯費折50.sql ＋ 2026-11-01_商人熊改成全有或全無_用券就不折.sql）
   唯讀效果：整段回滾
   ------------------------------------------------------------
   在交易裡自己造樣本（硬規則 3.57）：
     · 一個顧問是商人熊的團，團員＝測試01～04
     · S01 高雄自由（直營）兩張空桌各開一場配桌 2 將（每人檯費 100）
     · 一張檯費折 20 元的券給測試01
   最後 raise 'migi_rollback' ⇒ 什麼都不留下（這一份是故意不要提交的那一種，硬規則 1.8）。

   格子：
     ① 沒帶「這桌四位」：沒有顧問折抵、等級折扣照舊（舊行為沒被改到）
     ② 四位同團、商人熊、直營：一人付四份 ⇒ 折 200、等級折扣 0
     ③ 四位裡有一位不是團員 ⇒ 沒有
     ④ 那團的顧問是廚師熊 ⇒ 沒有
     ⑤ 門市不是直營 ⇒ 沒有
     ⑧ 付款人不在宣告的四位裡 ⇒ 沒有
     ⑪ 一人付四份但選了券 ⇒ 不折 50，券照常折、等級折扣照常（正常結帳）
     ⑥ 真的結帳：測試04 自己付 ⇒ 訂單折 50、記到那一團、等級折扣 0、記一筆、實收＝報價
     ⑩ 同一桌：測試04 剛在這桌用掉，測試01 替自己＋02、03 付 ⇒ 折 150（同一桌先結帳的不算用過）
     ⑨ 別桌：同四位到另一桌，測試04 今天在別桌用過 ⇒ 付四份也整桌沒有，等級折扣照常
     ⑫ 別桌：測試01 只付自己 ⇒ 一樣沒有（少一位就全部沒有）
   ============================================================ */
do $$
declare
  v_msg text := '';
  t1 uuid := 'd73fdac2-d6b9-4b8a-bcff-b19c2786056f';  -- 測試01（tiramisu）
  t2 uuid := '218378e1-fb6c-43fb-b642-99fdbf5c52b1';  -- 測試02
  t3 uuid := 'd0db928e-5a75-4535-90d4-93ede67790a8';  -- 測試03
  t4 uuid := '526aa8b9-cc93-4327-b878-6d21d399af8e';  -- 測試04
  outsider uuid := '69016205-afde-4036-95a6-5893c9d0e5fe';
  v_store uuid := '22222222-2222-2222-2222-222222222222';
  v_org uuid; v_team uuid; v_tbl uuid; v_tbl2 uuid; v_sess uuid; v_sess2 uuid; v_cp uuid; v_mc uuid;
  q jsonb; r jsonb; o record; v_pct int; v_n int;
  four uuid[];
begin
  four := array[t1, t2, t3, t4];
  select org_id into v_org from stores where id = v_store;
  select t.id into v_tbl from tables t where t.store_id = v_store and t.deleted_at is null
     and not exists (select 1 from table_sessions s where s.table_id = t.id and s.status = 'open' and s.deleted_at is null)
   order by t.id limit 1;
  select t.id into v_tbl2 from tables t where t.store_id = v_store and t.deleted_at is null and t.id <> v_tbl
     and not exists (select 1 from table_sessions s where s.table_id = t.id and s.status = 'open' and s.deleted_at is null)
   order by t.id limit 1;
  if v_tbl is null or v_tbl2 is null then raise exception '找不到兩張空桌，測不了'; end if;

  insert into teams (org_id, name, created_by, advisor, advisor_set_at, advisor_set_by)
  values (v_org, '驗商人熊' || substr(gen_random_uuid()::text, 1, 6), t1, 'merchant', now(), t1)
  returning id into v_team;
  insert into team_members (org_id, team_id, member_id, role)
  select v_org, v_team, x, case when x = t1 then 'leader' else 'member' end from unnest(four) x;

  insert into coupons (org_id, name, kind, discount_type, discount_value)
  values (v_org, '驗商人熊用的券', 'table_discount', 'fixed', 20) returning id into v_cp;
  insert into member_coupons (org_id, member_id, coupon_id, status) values (v_org, t1, v_cp, 'active') returning id into v_mc;

  insert into table_sessions (org_id, store_id, table_id, mode, planned_rounds, game_type, is_test)
  values (v_org, v_store, v_tbl, 'matched', 2, '台麻', true) returning id into v_sess;
  insert into table_sessions (org_id, store_id, table_id, mode, planned_rounds, game_type, is_test)
  values (v_org, v_store, v_tbl2, 'matched', 2, '台麻', true) returning id into v_sess2;
  select coalesce(t.discount_pct, 0) into v_pct from members m join member_tiers t on t.code = coalesce(m.tier_override, m.tier) where m.id = t1;

  -- ① 沒帶四位
  q := public.pos_quote_tx(v_sess, t1, 'opener', null, null, null, null);
  v_msg := v_msg || E'\n① ' || case when (q->>'ok')::boolean and q->'advisor' = 'null'::jsonb
                                     and (q->>'advisor_discount')::bigint = 0
                                     and (q->>'tier_discount')::bigint = round((q->'fee_line'->>'amount')::bigint * v_pct / 100.0)
                                then '✅ 沒帶四位：沒有顧問折抵，等級折扣 ' || (q->>'tier_discount') || '（' || v_pct || '%）照舊'
                                else '🔴 ' || q::text end;

  -- ② 四位同團
  q := public.pos_quote_tx(v_sess, t1, 'opener', array[t2, t3, t4], null, null, four);
  v_msg := v_msg || E'\n② ' || case when (q->>'advisor_discount')::bigint = 200 and (q->>'tier_discount')::bigint = 0
                                     and (q->'advisor'->>'count')::int = 4 and (q->>'payable')::bigint = (q->'fee_line'->>'amount')::bigint - 200
                                then '✅ 一人付四份：折 200、等級折扣 0、應付 ' || (q->>'payable')
                                else '🔴 ' || q::text end;

  -- ③ 有一位不是團員
  q := public.pos_quote_tx(v_sess, t1, 'opener', array[t2, t3, outsider], null, null, array[t1, t2, t3, outsider]);
  v_msg := v_msg || E'\n③ ' || case when coalesce((q->>'advisor_discount')::bigint, -1) = 0 then '✅ 有一位不是團員：沒有' else '🔴 ' || q::text end;

  -- ④ 顧問是廚師熊
  update teams set advisor = 'chef' where id = v_team;
  q := public.pos_quote_tx(v_sess, t1, 'opener', array[t2, t3, t4], null, null, four);
  v_msg := v_msg || E'\n④ ' || case when coalesce((q->>'advisor_discount')::bigint, -1) = 0 then '✅ 廚師熊的團：檯費不折' else '🔴 ' || q::text end;
  update teams set advisor = 'merchant' where id = v_team;

  -- ⑤ 不是直營
  update stores set store_type = '加盟' where id = v_store;
  q := public.pos_quote_tx(v_sess, t1, 'opener', array[t2, t3, t4], null, null, four);
  v_msg := v_msg || E'\n⑤ ' || case when coalesce((q->>'advisor_discount')::bigint, -1) = 0 then '✅ 加盟店：沒有' else '🔴 ' || q::text end;
  update stores set store_type = '直營' where id = v_store;

  -- ⑧ 付款人不在宣告的四位裡
  q := public.pos_quote_tx(v_sess, t1, 'opener', array[t2, t3, t4], null, null, array[t2, t3, t4, outsider]);
  v_msg := v_msg || E'\n⑧ ' || case when coalesce((q->>'advisor_discount')::bigint, -1) = 0 then '✅ 付款人不在四位裡：沒有' else '🔴 ' || q::text end;

  -- ⑪ 選了券
  q := public.pos_quote_tx(v_sess, t1, 'opener', array[t2, t3, t4], null, array[v_mc], four);
  v_msg := v_msg || E'\n⑪ ' || case when (q->>'advisor_discount')::bigint = 0 and q->'advisor' = 'null'::jsonb
                                     and (q->>'coupon_discount')::bigint = 20
                                     and (q->>'tier_discount')::bigint = round(((q->'fee_line'->>'amount')::bigint - 20) * v_pct / 100.0)
                                then '✅ 選了券：不折 50，券折 20、等級折扣 ' || (q->>'tier_discount') || ' 照常'
                                else '🔴 ' || q::text end;

  -- ⑥ 真的結帳：測試04 自己付
  q := public.pos_quote_tx(v_sess, t4, 'opener', null, null, null, four);
  r := public.join_session_tx(v_sess, t4, 'opener', null, 0,
         jsonb_build_array(jsonb_build_object('method', 'cash', 'amount', (q->>'payable')::bigint,
                                              'cash_received', (q->>'payable')::bigint, 'change_given', 0)),
         null, 'test-merchant-' || v_sess::text, null, null, four);
  select * into o from orders where id = (r->>'order_id')::uuid;
  select count(*) into v_n from advisor_perk_uses where order_id = o.id and team_id = v_team;
  v_msg := v_msg || E'\n⑥ ' || case when (r->>'ok')::boolean and o.advisor_discount = 50 and o.advisor_team_id = v_team
                                     and o.tier_discount = 0 and o.tier_discount_pct = 0 and v_n = 1
                                     and o.payable = (q->>'payable')::bigint
                                then '✅ 實收：測試04 折 50、記到那一團、等級折扣 0、記一筆、實收 ' || o.payable || ' ＝ 報價'
                                else '🔴 r=' || r::text || ' 記錄數=' || v_n end;

  -- ⑩ 同一桌：測試04 剛在這桌用掉，測試01 替自己＋02、03 付 ⇒ 不受影響，折 150
  q := public.pos_quote_tx(v_sess, t1, 'opener', array[t2, t3], null, null, four);
  v_msg := v_msg || E'\n⑩ ' || case when (q->>'advisor_discount')::bigint = 150 and (q->>'tier_discount')::bigint = 0
                                then '✅ 同一桌先結帳的人用掉的不算：後面三位折 150' else '🔴 ' || q::text end;

  -- ⑨ 別桌：同樣四位到另一桌，測試04 今天已經在別桌用過 ⇒ 這桌四個人全部沒有（付四份）
  q := public.pos_quote_tx(v_sess2, t1, 'opener', array[t2, t3, t4], null, null, four);
  v_msg := v_msg || E'\n⑨ ' || case when coalesce((q->>'advisor_discount')::bigint, -1) = 0
                                     and (q->>'tier_discount')::bigint = round((q->'fee_line'->>'amount')::bigint * v_pct / 100.0)
                                then '✅ 有一位今天在別桌用過：整桌沒有，等級折扣 ' || (q->>'tier_discount') || ' 照常'
                                else '🔴 ' || q::text end;

  -- ⑫ 別桌：測試01 只付自己（他今天沒用過）⇒ 一樣沒有（少一位就全部沒有）
  q := public.pos_quote_tx(v_sess2, t1, 'opener', null, null, null, four);
  v_msg := v_msg || E'\n⑫ ' || case when coalesce((q->>'advisor_discount')::bigint, -1) = 0
                                then '✅ 少一位就全部沒有：測試01 自己付也沒有' else '🔴 ' || q::text end;

  raise exception 'migi_rollback';
exception when others then
  if sqlerrm = 'migi_rollback' then
    perform set_config('migi.t', v_msg, false);
  else
    perform set_config('migi.t', coalesce(v_msg, '') || E'\n🔴 中途拋錯：' || sqlerrm, false);
  end if;
end $$;

select coalesce(nullif(current_setting('migi.t', true), ''), '🔴 沒有訊息') as "驗商人熊（整段已回滾）";
