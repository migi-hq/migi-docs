/* ============================================================
   營運報表（2026-11-02，《ERP 輕量報表規格》12 個指標 ＋ 會員來源）
   給管理後台「報表」頁用：admin_ops_report_tx(p_from, p_to, p_store)

   ── 使用者拍板（2026-11-02）──────────────────────────────
   · 資料讀原始表，**只排除測試帳號**（members.is_test）——
     不讀 v_real_*：上線日（orgs.live_from）還沒設、高雄自由店還標成測試門市，
     v_real_* 全部是 0 筆，而封測已經有真客人。上線日與測試門市的設定不動。

   ── 定義（改之前先讀）─────────────────────────────────────
   · 「一天」＝ **營業日**：台北時間凌晨 6 點換日（店開到凌晨 2 點，凌晨 1 點結帳算前一天）
     ⚠ 跟當日暢打用日曆日不衝突：那是給客人的規則，這是給老闆看的帳。
   · 真的場次 ＝ 沒作廢、不是好友練習賽（虛擬門市）、而且至少有一位非測試會員
   · 營收 ＝ 已付款訂單的 payable（含點數付的；點數是預收款的履約）；分類用品項 line_total（折扣前）
   · 儲值是**預收款不是營收**，另列
   · 上座率 ＝ 實際桌時 ÷（啟用桌數 × 營業時數 × 天數）；場次算在開打那一天
   · 白跑率 ＝ 配桌時間到還沒湊滿、人還在房裡的報名 ÷（那些 ＋ 成桌的報名）
     （自己退出、被移到別房、被店員移除的不算白跑）
   · 會員來源：註冊在期間內的人，各來源「註冊 → 打過 1 場 → 打過 2 場」（場數算到今天）
     ⚠ 註冊沒有門市，這一區**不受門市篩選影響**
   · 三個指標回 null ＋ 原因：餐飲毛利率（商品成本全是 0）、庫存警示（沒有進銷存）、
     流失預警（會員生命週期沒有人在更新）

   ── 權限 ──────────────────────────────────────────────────
   can('ops.read')（總部／老闆）。看得到店員各自的數字與推薦人的名字。
   ============================================================ */

create or replace function public._biz_date(p_ts timestamptz)
returns date language sql stable as $$
  select ((p_ts at time zone 'Asia/Taipei') - interval '6 hours')::date
$$;
comment on function public._biz_date(timestamptz) is '營業日：台北時間凌晨 6 點換日（報表用）';
revoke execute on function public._biz_date(timestamptz) from public, anon, authenticated;

create or replace function public.admin_ops_report_tx(
  p_from date default null, p_to date default null, p_store uuid default null)
-- ⚠ 不能宣告 stable：裡面用暫存表整理資料（stable 函式不准寫入，連暫存表也不行）
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_org   uuid := public.current_org_id();
  v_today date := public._biz_date(now());
  v_to    date := coalesce(p_to, public._biz_date(now()));
  v_from  date := coalesce(p_from, coalesce(p_to, public._biz_date(now())));
  v_days  int;
  v_month_start date;
  r jsonb := '{}'::jsonb;
  v_rev bigint; v_visits int; v_mrev bigint; v_mdays int; v_mlen int;
  v_used numeric; v_cap numeric;
begin
  if not public.can('ops.read') then
    return jsonb_build_object('ok', false, 'reason', 'forbidden', 'message', '只有總部看得到報表');
  end if;
  if v_from > v_to then
    return jsonb_build_object('ok', false, 'reason', 'bad_range', 'message', '開始日期不能晚於結束日期');
  end if;
  if v_to - v_from > 366 then
    return jsonb_build_object('ok', false, 'reason', 'range_too_long', 'message', '一次最多查一年');
  end if;
  v_days := v_to - v_from + 1;
  v_month_start := date_trunc('month', v_to)::date;

  -- 範圍內的門市（不含好友練習賽的虛擬門市）
  create temp table if not exists _rs (id uuid primary key) on commit drop;
  truncate _rs;
  insert into _rs select s.id from stores s
   where s.org_id = v_org and s.deleted_at is null and not coalesce(s.is_virtual, false)
     and (p_store is null or s.id = p_store);

  -- 真的場次
  create temp table if not exists _ss (id uuid primary key, store_id uuid, d date, hr int, mins numeric) on commit drop;
  truncate _ss;
  insert into _ss
  select ts.id, ts.store_id, public._biz_date(ts.started_at),
         extract(hour from ts.started_at at time zone 'Asia/Taipei')::int,
         greatest(0, extract(epoch from (coalesce(ts.ended_at, now()) - coalesce(ts.activated_at, ts.started_at))) / 60.0)
    from table_sessions ts
   where ts.store_id in (select id from _rs)
     and ts.deleted_at is null and ts.status in ('open', 'completed')
     and public._biz_date(ts.started_at) between v_from and v_to
     and exists (select 1 from session_players sp join members m on m.id = sp.member_id
                  where sp.session_id = ts.id and not m.is_test);

  -- 真的已付款訂單
  create temp table if not exists _os (id uuid primary key, member_id uuid, d date, payable bigint,
                                      points bigint, discount bigint) on commit drop;
  truncate _os;
  insert into _os
  select o.id, o.member_id, public._biz_date(o.paid_at), o.payable, coalesce(o.points_used, 0),
         coalesce(o.coupon_discount, 0) + coalesce(o.tier_discount, 0) + coalesce(o.advisor_discount, 0)
    from orders o join members m on m.id = o.member_id
   where o.store_id in (select id from _rs) and o.status = 'paid' and o.deleted_at is null
     and not m.is_test and o.paid_at is not null
     and public._biz_date(o.paid_at) between least(v_from, v_month_start, v_to - 29) and v_to;
  -- ⚠ 撈的範圍比查詢期間大：本月累計與 30 日活躍也要用

  /* ── ① 成桌 ── */
  select coalesce(sum(mins), 0) into v_used from _ss;
  select coalesce(sum(
           (select count(*) from tables t where t.store_id = s.id and t.is_active and t.deleted_at is null)
           * case when s.open_time is null or s.close_time is null then 24
                  when s.close_time > s.open_time then extract(epoch from (s.close_time - s.open_time)) / 3600.0
                  else 24 + extract(epoch from (s.close_time - s.open_time)) / 3600.0 end
         ), 0) * 60 * v_days
    into v_cap
    from stores s where s.id in (select id from _rs);

  select coalesce(sum(payable), 0), count(distinct (member_id, d)) into v_rev, v_visits
    from _os where d between v_from and v_to;

  r := r || jsonb_build_object('table', jsonb_build_object(
    'occupancy', case when v_cap > 0 then round(v_used / v_cap, 4) end,
    'table_minutes', round(v_used),
    'capacity_minutes', round(v_cap),
    'sessions', (select count(*) from _ss),
    'revenue', v_rev,
    'revenue_by_type', coalesce((
        select jsonb_object_agg(revenue_type, amt) from (
          select oi.revenue_type, sum(oi.line_total) amt
            from order_items oi join _os on _os.id = oi.order_id
           where _os.d between v_from and v_to group by 1) z), '{}'::jsonb),
    'discount', (select coalesce(sum(discount), 0) from _os where d between v_from and v_to),
    'points_used', (select coalesce(sum(points), 0) from _os where d between v_from and v_to),
    'topup', (select coalesce(sum(t.amount_twd), 0) from topup_orders t join members m on m.id = t.member_id
               where t.store_id in (select id from _rs) and t.status = 'paid' and not m.is_test
                 and public._biz_date(t.created_at) between v_from and v_to),
    'no_table', (with q as (
        select p.leave_reason, q.status from match_queue_players p
          join match_queues q on q.id = p.queue_id
          join members m on m.id = p.member_id
         where q.store_id in (select id from _rs) and not m.is_test
           and q.status in ('expired', 'seated')
           and public._biz_date(coalesce(q.play_at, q.expires_at, q.created_at)) between v_from and v_to)
      select jsonb_build_object(
        'left_empty', count(*) filter (where status = 'expired' and coalesce(leave_reason, 'expired') = 'expired'),
        'seated',     count(*) filter (where status = 'seated' and coalesce(leave_reason, 'swapped') = 'swapped'))
        from q),
    'on_site', case when v_to = v_today then jsonb_build_object(
        'players', (select count(*) from session_players sp
                      join table_sessions ts on ts.id = sp.session_id
                      join members m on m.id = sp.member_id
                     where ts.store_id in (select id from _rs) and ts.status = 'open' and ts.deleted_at is null
                       and sp.left_at is null and not m.is_test),
        'capacity', (select coalesce(sum(coalesce(t.seats, 4)), 0) from tables t
                      where t.store_id in (select id from _rs) and t.is_active and t.deleted_at is null)) end
  ));

  /* ── ② 獲利 ── */
  select coalesce(sum(payable), 0) into v_mrev from _os where d between v_month_start and v_to;
  v_mdays := v_to - v_month_start + 1;
  v_mlen  := (date_trunc('month', v_to) + interval '1 month')::date - v_month_start;
  r := r || jsonb_build_object('profit', jsonb_build_object(
    'avg_ticket', case when v_visits > 0 then round(v_rev::numeric / v_visits) end,
    'visits', v_visits,
    'month_revenue', v_mrev,
    'month_forecast', round(v_mrev::numeric / v_mdays * v_mlen),
    'month_days', v_mdays, 'month_len', v_mlen,
    'fnb_margin', null, 'fnb_margin_reason', '商品成本還沒有填（全部是 0）'
  ));

  /* ── ③ 留存 ── */
  r := r || jsonb_build_object('retention', jsonb_build_object(
    'new_customers', (
        select count(*) from (
          select o.member_id, min(public._biz_date(o.paid_at)) first_d
            from orders o join members m on m.id = o.member_id
           where o.org_id = v_org and o.status = 'paid' and o.deleted_at is null and not m.is_test
           group by o.member_id) f
         where f.first_d between v_from and v_to
           and exists (select 1 from _os where _os.member_id = f.member_id and _os.d = f.first_d)),
    'return_7d', (with a as (select distinct member_id from _os where d between v_to - 13 and v_to - 7),
                       b as (select distinct member_id from _os where d between v_to - 6 and v_to)
                  select jsonb_build_object('base', (select count(*) from a),
                                            'returned', (select count(*) from a where member_id in (select member_id from b)))),
    'active_30d', (select count(distinct member_id) from _os where d between v_to - 29 and v_to),
    'at_risk', null, 'at_risk_reason', '會員生命週期還沒有自動更新（M3）'
  ));

  /* ── 會員來源（不受門市篩選）── */
  create temp table if not exists _nm (id uuid primary key, src text, channel text, campaign text,
                                       staff uuid, ref uuid, played int) on commit drop;
  truncate _nm;
  insert into _nm
  select m.id, coalesce(m.acquisition_source, 'before'), m.acquisition_channel, m.acquisition_campaign,
         m.referred_by_staff_id, m.referred_by_member_id,
         (select count(distinct sp.session_id)::int from session_players sp
            join table_sessions ts on ts.id = sp.session_id
           where sp.member_id = m.id and ts.deleted_at is null and ts.status in ('open', 'completed')
             and ts.store_id in (select s.id from stores s where s.org_id = v_org and not coalesce(s.is_virtual, false)))
    from members m
   where m.org_id = v_org and not m.is_test and m.deleted_at is null
     and public._biz_date(m.created_at) between v_from and v_to;

  r := r || jsonb_build_object('acquisition', jsonb_build_object(
    'by_source', coalesce((select jsonb_agg(jsonb_build_object('source', src, 'registered', n, 'played1', p1, 'played2', p2)
                                            order by array_position(array['staff','member','ad','other','none','before'], src))
                             from (select src, count(*) n, count(*) filter (where played >= 1) p1,
                                          count(*) filter (where played >= 2) p2 from _nm group by src) z), '[]'::jsonb),
    'by_channel', coalesce((select jsonb_agg(jsonb_build_object('source', src, 'channel', channel,
                                                                 'label', coalesce(ch.label, channel), 'campaign', campaign,
                                                                 'registered', n, 'played1', p1, 'played2', p2) order by n desc)
                              from (select src, channel, campaign, count(*) n, count(*) filter (where played >= 1) p1,
                                           count(*) filter (where played >= 2) p2
                                      from _nm where src in ('ad', 'other', 'member') group by 1, 2, 3) z
                              left join acquisition_channels ch on ch.code = z.channel and z.src <> 'member'), '[]'::jsonb),
    'top_members', coalesce((select jsonb_agg(jsonb_build_object('name', mm.display_name, 'registered', n, 'played1', p1, 'played2', p2)
                                              order by n desc, p1 desc)
                               from (select ref, count(*) n, count(*) filter (where played >= 1) p1,
                                            count(*) filter (where played >= 2) p2
                                       from _nm where ref is not null group by ref order by count(*) desc limit 10) z
                               join members mm on mm.id = z.ref), '[]'::jsonb)
  ));

  /* ── ④ 營運：店員 ── */
  r := r || jsonb_build_object('ops', jsonb_build_object(
    'inventory', null, 'inventory_reason', '進銷存還沒做',
    'staff', coalesce((
      select jsonb_agg(x order by (x->>'matched')::int desc, (x->>'brought')::int desc)
        from (select jsonb_build_object(
                'name', s.name, 'role', s.role,
                'matched', (select count(*) from match_queues q
                             where q.credited_staff_id = s.id and q.store_id in (select id from _rs)
                               and q.matched_at is not null and q.status in ('matched', 'seated')
                               and public._biz_date(q.matched_at) between v_from and v_to),
                'brought', (select count(*) from _nm where _nm.staff = s.id),
                'brought_played1', (select count(*) from _nm where _nm.staff = s.id and played >= 1),
                'brought_played2', (select count(*) from _nm where _nm.staff = s.id and played >= 2),
                'bound_visits', (select count(distinct (_os.member_id, _os.d)) from _os
                                   join members m on m.id = _os.member_id
                                  where m.primary_staff_id = s.id and _os.d between v_from and v_to)) x
                from staff s where s.org_id = v_org and s.deleted_at is null) y), '[]'::jsonb)
  ));

  /* ── 時段熱度（開桌數）── */
  r := r || jsonb_build_object('heat', jsonb_build_object(
    'by_hour', (select jsonb_agg(coalesce((select count(*) from _ss where hr = h), 0) order by h) from generate_series(0, 23) h),
    'by_dow',  (select jsonb_agg(coalesce((select count(*) from _ss where extract(dow from d)::int = w), 0) order by w) from generate_series(0, 6) w),
    'by_day',  coalesce((select jsonb_agg(jsonb_build_object('d', d, 'sessions', n, 'revenue',
                          (select coalesce(sum(payable), 0) from _os where _os.d = z.d)) order by d)
                           from (select g::date d, (select count(*) from _ss where _ss.d = g::date) n
                                   from generate_series(v_from, v_to, interval '1 day') g) z), '[]'::jsonb)
  ));

  return jsonb_build_object('ok', true, 'from', v_from, 'to', v_to, 'days', v_days,
                            'store', p_store, 'today', v_today) || r;
end $$;

revoke execute on function public.admin_ops_report_tx(date, date, uuid) from public, anon;
grant  execute on function public.admin_ops_report_tx(date, date, uuid) to authenticated;

-- ── 驗證（不 raise，硬規則 1.8）────────────────────────────────
do $$
declare v text := ''; n int; j jsonb; v_uid uuid;
begin
  select count(*) into n from pg_proc where pronamespace = 'public'::regnamespace and proname = 'admin_ops_report_tx';
  v := v || case when n = 1 then '✅' else '🔴' end || ' ① 只有一個版本（' || n || '）' || E'\n';

  select count(*) into n from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = 'admin_ops_report_tx'
     and has_function_privilege('authenticated', p.oid, 'EXECUTE') and not has_function_privilege('anon', p.oid, 'EXECUTE');
  v := v || case when n = 1 then '✅' else '🔴' end || ' ② 登入的人叫得動、anon 叫不動' || E'\n';

  -- ③ 沒有身分 ⇒ 擋下（負對照）
  perform set_config('request.jwt.claims', '{}', true);
  j := public.admin_ops_report_tx(null, null, null);
  v := v || case when j->>'reason' = 'forbidden' then '✅' else '🔴' end || ' ③ 沒有總部身分被擋下（' || coalesce(j->>'reason', '?') || '）' || E'\n';

  -- ④ 用總部身分查近 30 天（正對照：要真的有數字）
  select auth_uid into v_uid from staff where role = 'hq' and auth_uid is not null and deleted_at is null limit 1;
  if v_uid is null then
    v := v || '🔴 ④ 找不到總部帳號當樣本' || E'\n';
  else
    perform set_config('request.jwt.claims', json_build_object('sub', v_uid, 'role', 'authenticated')::text, true);
    j := public.admin_ops_report_tx(public._biz_date(now()) - 29, public._biz_date(now()), null);
    v := v || case when (j->>'ok')::boolean and (j->'table'->>'sessions')::int > 0 and (j->'table'->>'revenue')::bigint > 0
                   then '✅' else '🔴' end
            || ' ④ 總部查近 30 天：' || coalesce(j->'table'->>'sessions', '?') || ' 場、營收 ' || coalesce(j->'table'->>'revenue', '?')
            || '、上座率 ' || coalesce(j->'table'->>'occupancy', 'null')
            || '、新註冊 ' || coalesce((select sum((x->>'registered')::int)::text from jsonb_array_elements(j->'acquisition'->'by_source') x), '0') || ' 位' || E'\n';
    v := v || case when jsonb_array_length(j->'heat'->'by_hour') = 24 and jsonb_array_length(j->'heat'->'by_dow') = 7
                        and jsonb_array_length(j->'heat'->'by_day') = 30
                   then '✅' else '🔴' end || ' ⑤ 時段熱度 24 小時／7 天／30 個營業日' || E'\n';
    -- ⑥ 測試帳號沒有混進來：只算測試帳號的訂單金額，應該跟報表無關（直接比對）
    v := v || '⚪ ⑥ 近 30 天測試帳號的訂單（報表不含）：'
            || (select count(*) from orders o join members m on m.id = o.member_id
                 where m.is_test and o.status = 'paid' and public._biz_date(o.paid_at) >= public._biz_date(now()) - 29) || ' 筆' || E'\n';
    j := public.admin_ops_report_tx(public._biz_date(now()), public._biz_date(now()) - 1, null);
    v := v || case when j->>'reason' = 'bad_range' then '✅' else '🔴' end || ' ⑦ 開始晚於結束被擋下';
  end if;

  perform set_config('request.jwt.claims', '', true);
  perform set_config('migi.rep', v, true);
end $$;

select coalesce(nullif(current_setting('migi.rep', true), ''), '🔴 沒有訊息') as "驗證";
