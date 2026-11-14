/* 行為測試：生日券發放與生日鎖（sql/pending/2026-11-14_生日券發放與生日鎖.sql 跑完之後跑）
   整段在交易裡做、最後故意回滾（raise 'migi_rollback'）⇒ 不留任何東西。結果印在最後那支 SELECT。
   身分：總部（admin@migi.tw，role=hq，同時是店員）；會員身分用測試01 的 LINE id。
   樣本：測試01（來店過）、測試03（沒填生日）、測試04（交易裡把註冊時間改成剛剛）。
   ⚪ 「沒來店過」這一格測不了：四個測試帳號都來店過，而這份不造會員。 */
do $$
declare
  v_msg text := ''; v_ok int := 0; v_all int := 0; v_line text;
  v_hq text := '{"sub":"2485579b-966f-4da6-8ccd-d3adb7ba084b","role":"authenticated"}';
  v_t1 uuid := 'd73fdac2-d6b9-4b8a-bcff-b19c2786056f';
  v_t3 uuid; v_t4 uuid; v_line_id text; v_member text;
  v_today date := (now() at time zone 'Asia/Taipei')::date; v_near date; v_far date; v_past date;
  v_day uuid; v_up uuid; v_cid uuid; r jsonb; v_mc record; v_old_bday date; v_n int; v_org uuid;
begin
  select org_id into v_org from members where id = v_t1;
  select id into v_t3 from members where is_test and display_name = '測試03' and deleted_at is null;
  select id into v_t4 from members where is_test and display_name = '測試04' and deleted_at is null;
  select line_user_id, birthday into v_line_id, v_old_bday from members where id = v_t1;
  select id into v_day from products where sku = 'SVC-TBL-DAY'   and deleted_at is null;
  select id into v_up  from products where sku = 'SVC-TBL-DAYUP' and deleted_at is null;
  if v_t3 is null or v_t4 is null or v_line_id is null or v_day is null or v_up is null then
    raise exception '樣本不齊';
  end if;
  v_member := json_build_object('sub', v_line_id, 'role', 'authenticated')::text;

  -- 生日的月日，年份用 2000（閏年，2/29 也排得出來）
  v_near := make_date(2000, extract(month from v_today + 5)::int, extract(day from v_today + 5)::int);
  v_far  := make_date(2000, extract(month from v_today + 120)::int, extract(day from v_today + 120)::int);
  v_past := make_date(2000, extract(month from v_today - 20)::int, extract(day from v_today - 20)::int);

  update members set birthday = null where id = v_t3;
  update members set birthday = v_near, created_at = now() where id = v_t4;
  update members set birthday = v_far where id = v_t1;

  perform set_config('request.jwt.claims', v_hq, true);
  execute 'set local role authenticated';

  -- ⓐ 免費 ＋ 當日暢打 ⇒ 建成生日券
  v_all := v_all + 1;
  r := public.admin_upsert_coupon_tx(null, '測·生日暢打', 'free', null, v_day, '[]'::jsonb, null, null, 30, null, 'hq');
  v_cid := (r->>'id')::uuid;
  v_line := format('ⓐ 建生日券：ok %s、分類 %s、有效天數存了 %s', r->>'ok', r->>'kind',
                   coalesce((select valid_days::text from coupons where id = v_cid), '（沒存）'));
  if (r->>'ok')::boolean and r->>'kind' = 'birthday' and (select valid_days from coupons where id = v_cid) is null
  then v_ok := v_ok + 1; v_line := '✅ ' || v_line; else v_line := '🔴 ' || v_line || ' ' || coalesce(r->>'message', ''); end if;
  v_msg := v_msg || v_line || E'\n';

  -- ⓑ 免費 ＋ 其他不參與折扣的商品（暢打補差價）⇒ 照舊擋
  v_all := v_all + 1;
  r := public.admin_upsert_coupon_tx(null, '測·補差價免費', 'free', null, v_up, '[]'::jsonb, null, null, 30, null, 'hq');
  v_line := 'ⓑ 其他不參與折扣的商品不能做免費券：' || coalesce(r->>'reason', r::text);
  if r->>'reason' = 'not_discountable' then v_ok := v_ok + 1; v_line := '✅ ' || v_line; else v_line := '🔴 ' || v_line; end if;
  v_msg := v_msg || v_line || E'\n';

  -- ⓒ 一次發給三位：測試01 生日還很久、測試03 沒填生日、測試04 註冊未滿 30 天 ⇒ 都跳過，原因各自寫對
  v_all := v_all + 1;
  r := public.admin_grant_coupon_tx(v_cid, array[v_t1, v_t3, v_t4], 1, '測試');
  select string_agg(s->>'name' || '：' || (s->>'reason'), '、' order by s->>'name') into v_line from jsonb_array_elements(r->'skipped') s;
  v_line := format('ⓒ 三位都不符合：發出 %s、跳過 %s', r->>'granted', v_line);
  if (r->>'granted')::int = 0
     and exists (select 1 from jsonb_array_elements(r->'skipped') s where (s->>'member_id')::uuid = v_t1 and s->>'reason' = 'too_early')
     and exists (select 1 from jsonb_array_elements(r->'skipped') s where (s->>'member_id')::uuid = v_t3 and s->>'reason' = 'no_birthday')
     and exists (select 1 from jsonb_array_elements(r->'skipped') s where (s->>'member_id')::uuid = v_t4 and s->>'reason' = 'too_new')
  then v_ok := v_ok + 1; v_line := '✅ ' || v_line; else v_line := '🔴 ' || v_line; end if;
  v_msg := v_msg || v_line || E'\n';

  -- ⓓ 生日剛過 20 天 ⇒ 今年的過期了，看明年的 ⇒ 還很久，跳過（不可以發今年那張已經過期的）
  v_all := v_all + 1;
  reset role;
  update members set birthday = v_past where id = v_t1;
  execute 'set local role authenticated';
  r := public.admin_grant_coupon_tx(v_cid, array[v_t1], 1, null);
  v_line := format('ⓓ 生日剛過：發出 %s、跳過原因 %s', r->>'granted', r->'skipped'->0->>'message');
  if (r->>'granted')::int = 0 and r->'skipped'->0->>'reason' = 'too_early' then v_ok := v_ok + 1; v_line := '✅ ' || v_line; else v_line := '🔴 ' || v_line; end if;
  v_msg := v_msg || v_line || E'\n';

  -- ⓔ 生日在 5 天後 ⇒ 發出；可用日 ＝ 生日前 15 天零時、到期 ＝ 生日後 15 天那天結束、年份對
  v_all := v_all + 1;
  reset role;
  update members set birthday = v_near where id = v_t1;
  execute 'set local role authenticated';
  r := public.admin_grant_coupon_tx(v_cid, array[v_t1], 1, null);
  reset role;
  select valid_from, expires_at, birthday_year into v_mc from member_coupons where coupon_id = v_cid and member_id = v_t1;
  v_line := format('ⓔ 生日在 5 天後：發出 %s、可用 %s、到期 %s、年份 %s', r->>'granted',
                   to_char(v_mc.valid_from at time zone 'Asia/Taipei', 'MM/DD HH24:MI'),
                   to_char(v_mc.expires_at at time zone 'Asia/Taipei', 'MM/DD HH24:MI'), v_mc.birthday_year);
  if (r->>'granted')::int = 1
     and v_mc.valid_from = ((v_today + 5 - 15)::timestamp at time zone 'Asia/Taipei')
     and v_mc.expires_at = ((v_today + 5 + 16)::timestamp at time zone 'Asia/Taipei')
     and v_mc.birthday_year = extract(year from v_today + 5)::int
  then v_ok := v_ok + 1; v_line := '✅ ' || v_line; else v_line := '🔴 ' || v_line; end if;
  v_msg := v_msg || v_line || E'\n';

  -- ⓕ 再發一次 ⇒ 今年的已經發過，不會有第二張
  v_all := v_all + 1;
  execute 'set local role authenticated';
  r := public.admin_grant_coupon_tx(v_cid, array[v_t1], 1, null);
  reset role;
  select count(*) into v_n from member_coupons where coupon_id = v_cid and member_id = v_t1;
  v_line := format('ⓕ 再發一次：發出 %s、原因 %s、手上共 %s 張', r->>'granted', r->'skipped'->0->>'reason', v_n);
  if (r->>'granted')::int = 0 and r->'skipped'->0->>'reason' = 'already' and v_n = 1 then v_ok := v_ok + 1; v_line := '✅ ' || v_line; else v_line := '🔴 ' || v_line; end if;
  v_msg := v_msg || v_line || E'\n';

  -- ⓖ 生日券一次發兩張 ⇒ 擋
  v_all := v_all + 1;
  execute 'set local role authenticated';
  r := public.admin_grant_coupon_tx(v_cid, array[v_t1], 2, null);
  v_line := 'ⓖ 生日券每人兩張：' || coalesce(r->>'reason', r::text);
  if r->>'reason' = 'bad_qty' then v_ok := v_ok + 1; v_line := '✅ ' || v_line; else v_line := '🔴 ' || v_line; end if;
  v_msg := v_msg || v_line || E'\n';

  -- ⓗ 店員幫客人改生日 ⇒ 改成功、留紀錄（誰改的、從幾號改成幾號）
  v_all := v_all + 1;
  r := public.pos_set_member_birthday_tx(v_t1, date '1985-06-12');
  reset role;
  v_line := format('ⓗ 店員改生日：ok %s、紀錄 %s 筆', r->>'ok',
                   (select count(*) from member_birthday_changes where member_id = v_t1 and new_birthday = date '1985-06-12' and old_birthday = v_near and staff_id is not null));
  if (r->>'ok')::boolean and (r->>'changed')::boolean
     and exists (select 1 from member_birthday_changes where member_id = v_t1 and new_birthday = date '1985-06-12' and old_birthday = v_near and staff_id is not null)
  then v_ok := v_ok + 1; v_line := '✅ ' || v_line; else v_line := '🔴 ' || v_line || ' ' || coalesce(r->>'message', ''); end if;
  v_msg := v_msg || v_line || E'\n';

  -- ⓘ 會員自己改已經填過的生日 ⇒ 擋；填一樣的日子 ⇒ 照回成功；沒填過的人 ⇒ 可以填
  v_all := v_all + 1;
  perform set_config('request.jwt.claims', v_member, true);
  execute 'set local role authenticated';
  r := public.set_my_birthday_tx(v_org, null, date '1990-01-01');
  v_line := 'ⓘ 會員改生日：改別天 ' || coalesce(r->>'reason', 'ok');
  if r->>'reason' = 'birthday_locked' then
    r := public.set_my_birthday_tx(v_org, null, date '1985-06-12');
    v_line := v_line || '／填一樣的 ' || coalesce(r->>'ok', '?');
    if (r->>'ok')::boolean then
      reset role;
      update members set birthday = null where id = v_t1;   -- 模擬還沒填過
      execute 'set local role authenticated';
      r := public.set_my_birthday_tx(v_org, null, date '1985-06-12');
      v_line := v_line || '／沒填過 ' || coalesce(r->>'ok', '?');
      if (r->>'ok')::boolean then v_ok := v_ok + 1; v_line := '✅ ' || v_line; else v_line := '🔴 ' || v_line; end if;
    else v_line := '🔴 ' || v_line; end if;
  else v_line := '🔴 ' || v_line; end if;
  v_msg := v_msg || v_line || E'\n';

  -- ⓙ 會員身分叫店員改生日 ⇒ 擋（負對照：不是店員）
  v_all := v_all + 1;
  r := public.pos_set_member_birthday_tx(v_t1, date '1990-01-01');
  reset role;
  v_line := 'ⓙ 會員叫店員改生日：' || coalesce(r->>'reason', 'ok');
  if r->>'reason' = 'not_staff' and (select birthday from members where id = v_t1) = date '1985-06-12'
  then v_ok := v_ok + 1; v_line := '✅ ' || v_line; else v_line := '🔴 ' || v_line; end if;
  v_msg := v_msg || v_line || E'\n';

  v_msg := case when v_ok = v_all then '✅ 全部通過 ' else '🔴 有沒過的 ' end || v_ok || '/' || v_all
           || '（⚪ 沒來店過那一格測不了）' || E'\n' || v_msg;
  raise exception 'migi_rollback';
exception when others then
  if sqlerrm = 'migi_rollback' then
    perform set_config('migi.t', v_msg, true);
  else
    perform set_config('migi.t', '🔴 中途中斷：' || sqlerrm || E'\n' || coalesce(v_msg, ''), true);
  end if;
end $$;
select coalesce(nullif(current_setting('migi.t', true), ''), '🔴 沒有訊息') as "行為測試";
