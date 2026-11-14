/* ============================================================================
   2026-11-14 修正：發券函式整個壞掉（變數撞名）—— 🔴 越早跑越好
   ----------------------------------------------------------------------------
   sql/applied/2026-11-14_生日券發放與生日鎖.sql 讓 admin_grant_coupon_tx 多了一個叫 m 的 record 變數，
   而同一支函式「名單裡的人都存在嗎」那一句的表格別名也叫 m（from members m where m.id = …）。
   PL/pgSQL 把 m.id 當成那個變數 ⇒ 還沒指定值 ⇒ 拋「record "m" is not assigned yet」。
   ⇒ **從那一份跑完起，後台任何券都發不出去**（不只生日券）。
   驗證段沒抓到，因為它只看「新版內容在不在」，沒有真的發一次 —— 這一份的驗證段會真的發。

   修法：變數改名 bm（別名 m 不動）。其餘一字不變，簽名不變（CREATE OR REPLACE 不會丟授權）。
   ============================================================================ */

create or replace function public.admin_grant_coupon_tx(p_coupon_id uuid, p_member_ids uuid[], p_qty integer, p_note text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_org uuid; v_staff uuid; c coupons%rowtype; v_exp timestamptz; v_n int; v_ok int; v_qty int := coalesce(p_qty, 1);
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
  -- 生日券用（⚠ 變數不可以叫 m：下面查會員的那一句表格別名是 m，會撞名 —— 2026-11-14 踩過）
  v_today date := (now() at time zone 'Asia/Taipei')::date;
  bm record; v_y int; v_b date; v_from date; v_ins int; v_granted int := 0; v_skipped jsonb := '[]'::jsonb;
begin
  if not public.can('coupon.write') then
    return jsonb_build_object('ok', false, 'reason', 'forbidden', 'message', '沒有權限發券');
  end if;
  v_org := public.current_org_id();
  v_staff := (select staff_id from public.current_staff());
  select * into c from coupons where id = p_coupon_id and org_id = v_org and deleted_at is null;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'not_found', 'message', '找不到這張券');
  end if;
  if not c.is_active then
    return jsonb_build_object('ok', false, 'reason', 'inactive', 'message', '這張券停用中，先啟用才能發');
  end if;
  v_n := coalesce(array_length(p_member_ids, 1), 0);
  if v_n = 0 or v_n > 200 then
    return jsonb_build_object('ok', false, 'reason', 'bad_members', 'message', '一次發給 1～200 位會員');
  end if;
  if v_qty < 1 or v_qty > 10 then
    return jsonb_build_object('ok', false, 'reason', 'bad_qty', 'message', '每人 1～10 張');
  end if;
  if p_note is not null and char_length(p_note) > 100 then
    return jsonb_build_object('ok', false, 'reason', 'bad_note', 'message', '備註最多 100 個字');
  end if;
  select count(*) into v_ok from members m
   where m.id = any(p_member_ids) and m.org_id = v_org and m.deleted_at is null and not m.is_bot;
  if v_ok <> (select count(distinct x) from unnest(p_member_ids) x) then
    return jsonb_build_object('ok', false, 'reason', 'bad_members', 'message', '名單裡有找不到的會員，請重新選一次');
  end if;

  /* 🆕 2026-11-14 生日券：每個人的效期不一樣，資格也逐人看；不符合的跳過並寫原因，其他人照發 */
  if c.kind = 'birthday' then
    if v_qty <> 1 then
      return jsonb_build_object('ok', false, 'reason', 'bad_qty', 'message', '生日券每人每年一張');
    end if;
    for bm in
      select mm.id, mm.display_name, mm.birthday, mm.created_at
        from members mm where mm.id in (select distinct x from unnest(p_member_ids) x)
       order by mm.display_name
    loop
      if bm.birthday is null then
        v_skipped := v_skipped || jsonb_build_array(jsonb_build_object('member_id', bm.id, 'name', bm.display_name, 'reason', 'no_birthday', 'message', '還沒填生日'));
        continue;
      end if;
      if bm.created_at > now() - interval '30 days' then
        v_skipped := v_skipped || jsonb_build_array(jsonb_build_object('member_id', bm.id, 'name', bm.display_name, 'reason', 'too_new', 'message', '註冊還沒滿 30 天'));
        continue;
      end if;
      if not exists (select 1 from orders o where o.member_id = bm.id and o.status = 'paid')
         and not exists (select 1 from session_players sp join table_sessions ts on ts.id = sp.session_id
                          where sp.member_id = bm.id and ts.status <> 'voided' and ts.mode is distinct from 'friendly') then
        v_skipped := v_skipped || jsonb_build_array(jsonb_build_object('member_id', bm.id, 'name', bm.display_name, 'reason', 'no_visit', 'message', '還沒來店消費過'));
        continue;
      end if;
      -- 今年的生日；已經過了生日 ＋ 15 天就看明年的。2/29 在平年當 2/28
      v_y := extract(year from v_today)::int;
      v_b := make_date(v_y, extract(month from bm.birthday)::int,
               case when extract(month from bm.birthday) = 2 and extract(day from bm.birthday) = 29
                         and not ((v_y % 4 = 0 and v_y % 100 <> 0) or v_y % 400 = 0) then 28
                    else extract(day from bm.birthday)::int end);
      if v_today > v_b + 15 then
        v_y := v_y + 1;
        v_b := make_date(v_y, extract(month from bm.birthday)::int,
                 case when extract(month from bm.birthday) = 2 and extract(day from bm.birthday) = 29
                           and not ((v_y % 4 = 0 and v_y % 100 <> 0) or v_y % 400 = 0) then 28
                      else extract(day from bm.birthday)::int end);
      end if;
      v_from := v_b - 15;
      if v_from > v_today + 60 then
        v_skipped := v_skipped || jsonb_build_array(jsonb_build_object('member_id', bm.id, 'name', bm.display_name, 'reason', 'too_early',
          'message', '生日 ' || to_char(v_b, 'FMMM/FMDD') || '，' || to_char(v_from - 60, 'FMMM/FMDD') || ' 起才能發'));
        continue;
      end if;
      insert into member_coupons (org_id, member_id, coupon_id, status, valid_from, expires_at, birthday_year,
                                  cost_bearer, granted_by_staff_id, grant_note)
      values (v_org, bm.id, c.id, 'active',
              v_from::timestamp at time zone 'Asia/Taipei', (v_b + 16)::timestamp at time zone 'Asia/Taipei', v_y,
              c.cost_bearer, v_staff, v_note)
      on conflict (member_id, birthday_year) where birthday_year is not null do nothing;
      get diagnostics v_ins = row_count;
      if v_ins = 0 then
        v_skipped := v_skipped || jsonb_build_array(jsonb_build_object('member_id', bm.id, 'name', bm.display_name, 'reason', 'already',
          'message', v_y || ' 年的生日券已經發過'));
      else
        v_granted := v_granted + 1;
      end if;
    end loop;
    return jsonb_build_object('ok', true, 'members', v_n, 'granted', v_granted, 'skipped', v_skipped, 'birthday', true);
  end if;

  -- 一般券：到期是發出後 N 天、到某一天（台北時間那天結束）兩個都有就取先到的；都沒有＝不限期限
  v_exp := nullif(least(
             coalesce(now() + make_interval(days => c.valid_days), 'infinity'::timestamptz),
             coalesce(((c.valid_until + 1)::timestamp at time zone 'Asia/Taipei'), 'infinity'::timestamptz)),
           'infinity'::timestamptz);
  if v_exp is not null and v_exp <= now() then
    return jsonb_build_object('ok', false, 'reason', 'already_expired', 'message', '這張券的到期日已經過了，發出去也不能用。先改到期日再發');
  end if;
  insert into member_coupons (org_id, member_id, coupon_id, status, expires_at, cost_bearer, granted_by_staff_id, grant_note)
  select v_org, m2.id, c.id, 'active', v_exp, c.cost_bearer, v_staff, v_note
    from (select distinct x as id from unnest(p_member_ids) x) m2, generate_series(1, v_qty);
  return jsonb_build_object('ok', true, 'members', v_n, 'granted', v_n * v_qty, 'expires_at', v_exp, 'skipped', '[]'::jsonb);
end $function$;

/* ── 驗證：真的用總部身分發一次（一般券一張、生日券一張），發完退回 ─────────
   退回靠內層區塊的例外處理（只退到那個子交易），上面的函式修改照樣提交 —— 不是硬規則 1.8 那種
   「raise 一路往上拋把整份回滾」。訊息在例外處理器裡寫（硬規則 3.9）。 */
do $$
declare
  v_msg text := '';
  v_hq text := '{"sub":"2485579b-966f-4da6-8ccd-d3adb7ba084b","role":"authenticated"}';
  v_t1 uuid := 'd73fdac2-d6b9-4b8a-bcff-b19c2786056f';
  v_org uuid; v_day uuid; v_c1 uuid; v_c2 uuid; r1 jsonb; r2 jsonb;
begin
  begin
    select org_id into v_org from members where id = v_t1;
    select id into v_day from products where org_id = v_org and sku = 'SVC-TBL-DAY' and deleted_at is null;
    insert into coupons (org_id, name, kind, discount_type, discount_value) values (v_org, '驗·一般券', 'generic', 'fixed', 10) returning id into v_c1;
    insert into coupons (org_id, name, kind, discount_type, free_product_id) values (v_org, '驗·生日券', 'birthday', 'free', v_day) returning id into v_c2;
    perform set_config('request.jwt.claims', v_hq, true);
    execute 'set local role authenticated';
    r1 := public.admin_grant_coupon_tx(v_c1, array[v_t1], 1, null);
    r2 := public.admin_grant_coupon_tx(v_c2, array[v_t1], 1, null);
    v_msg := case when (r1->>'ok')::boolean and (r1->>'granted')::int = 1 then '✅' else '🔴' end
             || ' ① 一般券發得出去（' || coalesce(r1->>'granted', r1->>'message', r1::text) || ' 張）' || E'\n'
          || case when (r2->>'ok')::boolean then '✅' else '🔴' end
             || ' ② 生日券跑得完（發出 ' || coalesce(r2->>'granted', '?') || '，跳過原因 '
             || coalesce((select string_agg(s->>'message', '、') from jsonb_array_elements(r2->'skipped') s), '無')
             || coalesce('；錯誤 ' || (r2->>'message'), '') || '）';
    raise exception 'migi_rollback';
  exception when others then
    if sqlerrm <> 'migi_rollback' then v_msg := v_msg || '🔴 中途出錯：' || sqlerrm; end if;
    perform set_config('migi.fix', v_msg, true);
  end;
end $$;

select
  (select case when count(*) = 1 then '✅' else '🔴' end || ' ⓪ 發券函式版本數 ' || count(*)
     from pg_proc where pronamespace = 'public'::regnamespace and proname = 'admin_grant_coupon_tx') || E'\n' ||
  coalesce(nullif(current_setting('migi.fix', true), ''), '🔴 沒有訊息') || E'\n' ||
  (select case when pg_get_functiondef(p.oid) like '%bm record%' then '✅' else '🔴' end || ' ③ 線上是修正版（變數叫 bm）'
     from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = 'admin_grant_coupon_tx')
  as "驗證";
