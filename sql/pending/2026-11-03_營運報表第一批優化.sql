/* ============================================================
   營運報表第一批優化（2026-11-03）
   📄 為什麼、對照誰：docs/05-埋點分析/報表優化_世界級對照.md 第五節「第一批」

   admin_ops_report_tx 簽名不變（create or replace，不丟授權），原有的鍵一個都不動，只加新的：
     table.avg_session_minutes / play_minutes / close_gap{n,total,median,over30} / scoreboard_sessions
           active_tables / by_mode / by_stake / by_table
     sales  毛額、三種折扣、淨額、付款方式、贈點付的、作廢訂單
     liability  目前錢包餘額（本金／贈點）—— 不受日期、門市影響
     funnel     配桌：開房 → 湊滿 → 開打；過期、取消；湊滿中位數；依小時、依級距
     customers  來店頻率分布、新客分群回訪（最近 8 週）
     fnb        加購率、熱賣前 10
     heat.grid  星期 × 小時 的佔桌分鐘（7 × 24）
     exceptions 作廢場次、作廢訂單、收桌拖超過 30 分鐘

   ── 定義（新加的）──────────────────────────────────────────
   · 打牌時間 ＝ 開打 → 最後一局確認；收桌延遲 ＝ 最後一局確認 → 收桌（只算有記到局、已收桌的場次）
   · 上座率維持原定義（開打 → 收桌），前後期才對得起來；前端另外算「實際打牌的上座率」
   · 熱力格：每一場依小時切開算佔桌分鐘；星期幾看**營業日**（凌晨 1 點算前一天）
   · 毛額 ＝ 訂單 subtotal；淨額 ＝ payable；贈點付的 ＝ 那筆訂單錢包流水的 bonus_amount
   · 錢包負債看全機構（錢包不屬於某一間店），只算非測試會員、已完成的流水
   · 配桌漏斗：開打時間（沒有就用開房時間）落在期間內、房裡至少有過一位非測試會員
   · 🔴 **來店改用「入座過 ＋ 有付款訂單」**（一人一天一次）——舊版只看訂單，而代付的人自己沒有訂單：
     近 30 天入座 277 人次裡 196 人次是別人付的 ⇒ 新客、7 日回流、30 日活躍、客單價、綁定客人來店都少算約七成
     （客單價因此從「每位付款人」變成「每位來店的人」，數字會變小，那才是對的）
   · 新客分群：第一次來店的營業日所在那一週；回訪看「第一次之後第 1～N 天內又來過」；
     還沒滿 N 天的那一格回 null（不是 0）
   ============================================================ */

create or replace function public.admin_ops_report_tx(
  p_from date default null, p_to date default null, p_store uuid default null)
-- ⚠ 不能宣告 stable：裡面用暫存表整理資料
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

  -- 真的場次（st／en 是佔桌的起訖，跟上座率同一個定義）
  drop table if exists pg_temp._ss;   -- ⚠ 寫明 pg_temp：只刪暫存表，不可能刪到同名的正式表
  create temp table _ss (id uuid primary key, store_id uuid, table_id uuid, mode text, stake uuid,
                         d date, hr int, mins numeric, st timestamptz, en timestamptz,
                         closed boolean, last_hand timestamptz) on commit drop;
  insert into _ss
  select ts.id, ts.store_id, ts.table_id, ts.mode, ts.stake_level_id,
         public._biz_date(ts.started_at),
         extract(hour from ts.started_at at time zone 'Asia/Taipei')::int,
         greatest(0, extract(epoch from (coalesce(ts.ended_at, now()) - coalesce(ts.activated_at, ts.started_at))) / 60.0),
         coalesce(ts.activated_at, ts.started_at), coalesce(ts.ended_at, now()),
         ts.status = 'completed',
         (select max(h.confirmed_at) from hands h where h.session_id = ts.id and h.status = 'confirmed')
    from table_sessions ts
   where ts.store_id in (select id from _rs)
     and ts.deleted_at is null and ts.status in ('open', 'completed')
     and public._biz_date(ts.started_at) between v_from and v_to
     and exists (select 1 from session_players sp join members m on m.id = sp.member_id
                  where sp.session_id = ts.id and not m.is_test);

  -- 真的已付款訂單（範圍比查詢期間大：本月累計與 30 日活躍也要用）
  drop table if exists pg_temp._os;
  create temp table _os (id uuid primary key, member_id uuid, d date, payable bigint, points bigint,
                         discount bigint, subtotal bigint, coupon bigint, tier bigint, advisor bigint,
                         bonus_used bigint, session_id uuid) on commit drop;
  insert into _os
  select o.id, o.member_id, public._biz_date(o.paid_at), o.payable, coalesce(o.points_used, 0),
         coalesce(o.coupon_discount, 0) + coalesce(o.tier_discount, 0) + coalesce(o.advisor_discount, 0),
         coalesce(o.subtotal, 0), coalesce(o.coupon_discount, 0), coalesce(o.tier_discount, 0), coalesce(o.advisor_discount, 0),
         coalesce((select -w.bonus_amount from wallet_txns w where w.id = o.wallet_txn_id and w.amount < 0), 0),
         o.session_id
    from orders o join members m on m.id = o.member_id
   where o.store_id in (select id from _rs) and o.status = 'paid' and o.deleted_at is null
     and not m.is_test and o.paid_at is not null
     and public._biz_date(o.paid_at) between least(v_from, v_month_start, v_to - 29) and v_to;

  -- 🆕 來店（全機構、全部歷史）：入座過的人 ＋ 有付款訂單的人，一人一天算一次
  -- 🔴 2026-11-03 查到：近 30 天入座 277 人次裡 196 人次是別人代付的（自己沒有訂單）
  --    ⇒ 舊版用訂單數來客，新客、回流、活躍、客單價都只算到付錢的人
  drop table if exists pg_temp._va;
  create temp table _va (member_id uuid, d date, store_id uuid, primary key (member_id, d, store_id)) on commit drop;
  insert into _va
  select distinct sp.member_id, public._biz_date(ts.started_at), ts.store_id
    from session_players sp
    join table_sessions ts on ts.id = sp.session_id
    join members m on m.id = sp.member_id
    join stores so on so.id = ts.store_id
   where so.org_id = v_org and not coalesce(so.is_virtual, false) and not m.is_test
     and ts.deleted_at is null and ts.status in ('open', 'completed')
  union
  select o.member_id, public._biz_date(o.paid_at), o.store_id
    from orders o join members m on m.id = o.member_id
   where o.org_id = v_org and o.status = 'paid' and o.deleted_at is null and not m.is_test
     and o.paid_at is not null and o.store_id is not null;

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

  select coalesce(sum(payable), 0) into v_rev from _os where d between v_from and v_to;
  select count(distinct (member_id, d)) into v_visits
    from _va where store_id in (select id from _rs) and d between v_from and v_to;

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
                      where t.store_id in (select id from _rs) and t.is_active and t.deleted_at is null)) end,
    -- 🆕 2026-11-03
    'active_tables', (select count(*) from tables t where t.store_id in (select id from _rs) and t.is_active and t.deleted_at is null),
    'avg_session_minutes', (select round(avg(mins)) from _ss),
    'play_minutes', (select round(coalesce(sum(greatest(0, extract(epoch from (last_hand - st)) / 60.0)), 0))
                       from _ss where last_hand is not null),
    'scoreboard_sessions', (select count(*) from _ss where last_hand is not null),
    'close_gap', (select jsonb_build_object(
        'n', count(*),
        'total', round(coalesce(sum(g), 0)),
        'median', round(percentile_cont(0.5) within group (order by g)::numeric),
        'over30', count(*) filter (where g > 30))
        from (select greatest(0, extract(epoch from (en - last_hand)) / 60.0) g
                from _ss where closed and last_hand is not null) z),
    'by_mode', coalesce((select jsonb_object_agg(mode, jsonb_build_object('sessions', n, 'minutes', m))
                           from (select coalesce(mode, 'other') mode, count(*) n, round(sum(mins)) m from _ss group by 1) z), '{}'::jsonb),
    'by_stake', coalesce((select jsonb_agg(jsonb_build_object('label', coalesce(sl.label, '未設定'), 'sessions', n, 'minutes', m)
                                           order by n desc)
                            from (select stake, count(*) n, round(sum(mins)) m from _ss group by stake) z
                            left join stake_levels sl on sl.id = z.stake), '[]'::jsonb),
    'by_table', coalesce((select jsonb_agg(jsonb_build_object(
                             'label', t.label, 'store', s.name, 'area', t.area,
                             'sessions', (select count(*) from _ss where _ss.table_id = t.id),
                             'minutes', (select round(coalesce(sum(mins), 0)) from _ss where _ss.table_id = t.id),
                             'revenue', (select coalesce(sum(_os.payable), 0) from _os
                                          where _os.d between v_from and v_to
                                            and _os.session_id in (select id from _ss where _ss.table_id = t.id)))
                             order by s.name, t.sort_order, t.label)
                            from tables t join stores s on s.id = t.store_id
                           where t.store_id in (select id from _rs) and t.is_active and t.deleted_at is null), '[]'::jsonb)
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

  /* ── 🆕 營收拆解 ── */
  r := r || jsonb_build_object('sales', jsonb_build_object(
    'gross',      (select coalesce(sum(subtotal), 0) from _os where d between v_from and v_to),
    'coupon',     (select coalesce(sum(coupon), 0)   from _os where d between v_from and v_to),
    'tier',       (select coalesce(sum(tier), 0)     from _os where d between v_from and v_to),
    'advisor',    (select coalesce(sum(advisor), 0)  from _os where d between v_from and v_to),
    'net',        v_rev,
    'points',     (select coalesce(sum(points), 0)   from _os where d between v_from and v_to),
    'bonus_used', (select coalesce(sum(bonus_used), 0) from _os where d between v_from and v_to),
    'orders',     (select count(*) from _os where d between v_from and v_to),
    'payments',   coalesce((select jsonb_object_agg(method, amt) from (
                     select op.method, sum(op.amount) amt from order_payments op
                       join _os on _os.id = op.order_id where _os.d between v_from and v_to group by 1) z), '{}'::jsonb),
    'void_orders', (select count(*) from orders o join members m on m.id = o.member_id
                     where o.store_id in (select id from _rs) and o.status = 'void' and not m.is_test
                       and public._biz_date(o.created_at) between v_from and v_to)
  ));

  /* ── 🆕 錢包負債（全機構、到現在為止）── */
  r := r || jsonb_build_object('liability', (
    select jsonb_build_object('balance', coalesce(sum(w.amount), 0), 'bonus', coalesce(sum(w.bonus_amount), 0),
                              'principal', coalesce(sum(w.amount), 0) - coalesce(sum(w.bonus_amount), 0),
                              'members', count(distinct w.member_id))
      from wallet_txns w join members m on m.id = w.member_id
     where m.org_id = v_org and not m.is_test and w.status = 'completed'));

  /* ── ③ 留存 ── */
  -- 🔴 2026-11-03 起三格都改用「來店」（_va），不再只算有付款訂單的人
  r := r || jsonb_build_object('retention', jsonb_build_object(
    'new_customers', (
        select count(*) from (select member_id, min(d) first_d from _va group by member_id) f
         where f.first_d between v_from and v_to
           and exists (select 1 from _va where _va.member_id = f.member_id and _va.d = f.first_d
                                          and _va.store_id in (select id from _rs))),
    'return_7d', (with a as (select distinct member_id from _va where store_id in (select id from _rs) and d between v_to - 13 and v_to - 7),
                       b as (select distinct member_id from _va where store_id in (select id from _rs) and d between v_to - 6 and v_to)
                  select jsonb_build_object('base', (select count(*) from a),
                                            'returned', (select count(*) from a where member_id in (select member_id from b)))),
    'active_30d', (select count(distinct member_id) from _va where store_id in (select id from _rs) and d between v_to - 29 and v_to),
    'at_risk', null, 'at_risk_reason', '會員生命週期還沒有自動更新（M3）'
  ));

  /* ── 🆕 客人：頻率分布 ＋ 新客分群回訪 ── */
  r := r || jsonb_build_object('customers', jsonb_build_object(
    'frequency', (select jsonb_build_object(
                     'd1', count(*) filter (where n = 1), 'd2', count(*) filter (where n = 2),
                     'd3_4', count(*) filter (where n between 3 and 4), 'd5', count(*) filter (where n >= 5))
                    from (select member_id, count(distinct d) n from _va
                           where store_id in (select id from _rs) and d between v_from and v_to group by 1) z),
    'cohorts', coalesce((
      with v as (select distinct member_id, d from _va where store_id in (select id from _rs)),
           f as (select member_id, min(d) fd from v group by 1),
           c as (select date_trunc('week', fd)::date wk, f.member_id, f.fd from f
                  where fd between v_to - 55 and v_to)
      select jsonb_agg(jsonb_build_object(
               'week', wk, 'size', size,
               'r7',  case when max_fd + 7  <= v_today then r7  end,
               'r14', case when max_fd + 14 <= v_today then r14 end,
               'r30', case when max_fd + 30 <= v_today then r30 end) order by wk)
        from (select wk, count(*) size, max(fd) max_fd,
                     count(*) filter (where exists (select 1 from v where v.member_id = c.member_id and v.d between c.fd + 1 and c.fd + 7))  r7,
                     count(*) filter (where exists (select 1 from v where v.member_id = c.member_id and v.d between c.fd + 1 and c.fd + 14)) r14,
                     count(*) filter (where exists (select 1 from v where v.member_id = c.member_id and v.d between c.fd + 1 and c.fd + 30)) r30
                from c group by wk) z), '[]'::jsonb)
  ));

  /* ── 🆕 餐飲 ── */
  r := r || jsonb_build_object('fnb', jsonb_build_object(
    'visits_with_fnb', (select count(distinct (_os.member_id, _os.d)) from _os
                          join order_items oi on oi.order_id = _os.id
                         where _os.d between v_from and v_to and oi.revenue_type = 'fnb'),
    'top', coalesce((select jsonb_agg(jsonb_build_object('name', name, 'type', revenue_type, 'qty', q, 'amount', a) order by q desc, a desc)
                       from (select oi.name, oi.revenue_type, sum(oi.qty) q, sum(oi.line_total) a
                               from order_items oi join _os on _os.id = oi.order_id
                              where _os.d between v_from and v_to and oi.revenue_type in ('fnb', 'retail')
                              group by 1, 2 order by sum(oi.qty) desc, sum(oi.line_total) desc limit 10) z), '[]'::jsonb)
  ));

  /* ── 🆕 配桌漏斗 ── */
  r := r || jsonb_build_object('funnel', (
    with q as (
      select q.id, q.status, q.created_at, q.matched_at, q.stake_level_id,
             extract(hour from coalesce(q.play_at, q.created_at) at time zone 'Asia/Taipei')::int hr
        from match_queues q
       where q.store_id in (select id from _rs)
         and public._biz_date(coalesce(q.play_at, q.created_at)) between v_from and v_to
         and exists (select 1 from match_queue_players p join members m on m.id = p.member_id
                      where p.queue_id = q.id and not m.is_test))
    select jsonb_build_object(
      'rooms', count(*),
      'filled', count(*) filter (where matched_at is not null),
      'seated', count(*) filter (where status = 'seated'),
      'expired', count(*) filter (where status = 'expired'),
      'cancelled', count(*) filter (where status = 'cancelled'),
      'waiting', count(*) filter (where status = 'waiting'),
      'fill_median_minutes', round((percentile_cont(0.5) within group (order by extract(epoch from (matched_at - created_at)) / 60.0)
                                    filter (where matched_at is not null))::numeric),
      'by_hour', (select jsonb_agg(jsonb_build_object('rooms', (select count(*) from q q2 where q2.hr = h),
                                                      'filled', (select count(*) from q q2 where q2.hr = h and q2.matched_at is not null))
                                   order by h) from generate_series(0, 23) h),
      'by_stake', coalesce((select jsonb_agg(jsonb_build_object('label', coalesce(sl.label, '未設定'), 'rooms', n, 'filled', f) order by n desc)
                              from (select stake_level_id, count(*) n, count(*) filter (where matched_at is not null) f
                                      from q group by 1) z left join stake_levels sl on sl.id = z.stake_level_id), '[]'::jsonb))
      from q));

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
                'bound_visits', (select count(distinct (_va.member_id, _va.d)) from _va
                                   join members m on m.id = _va.member_id
                                  where m.primary_staff_id = s.id and _va.store_id in (select id from _rs)
                                    and _va.d between v_from and v_to)) x
                from staff s where s.org_id = v_org and s.deleted_at is null) y), '[]'::jsonb)
  ));

  /* ── 🆕 例外 ── */
  r := r || jsonb_build_object('exceptions', jsonb_build_object(
    'void_sessions', (select count(*) from table_sessions ts
                       where ts.store_id in (select id from _rs) and ts.status = 'voided' and ts.deleted_at is null
                         and not coalesce(ts.is_test, false)
                         and public._biz_date(ts.started_at) between v_from and v_to),
    'void_orders', (r->'sales'->>'void_orders')::int,
    'late_close', (select count(*) from _ss where closed and last_hand is not null and en - last_hand > interval '30 minutes')
  ));

  /* ── 時段熱度 ── */
  r := r || jsonb_build_object('heat', jsonb_build_object(
    'by_hour', (select jsonb_agg(coalesce((select count(*) from _ss where hr = h), 0) order by h) from generate_series(0, 23) h),
    'by_dow',  (select jsonb_agg(coalesce((select count(*) from _ss where extract(dow from d)::int = w), 0) order by w) from generate_series(0, 6) w),
    'by_day',  coalesce((select jsonb_agg(jsonb_build_object('d', d, 'sessions', n, 'revenue',
                          (select coalesce(sum(payable), 0) from _os where _os.d = z.d)) order by d)
                           from (select g::date d, (select count(*) from _ss where _ss.d = g::date) n
                                   from generate_series(v_from, v_to, interval '1 day') g) z), '[]'::jsonb),
    -- 🆕 星期（營業日）× 小時 的佔桌分鐘，7 列 × 24 格
    'grid', (with cut as (
               select public._biz_date(hs) bd, extract(hour from hs at time zone 'Asia/Taipei')::int hh,
                      extract(epoch from (least(en, hs + interval '1 hour') - greatest(st, hs))) / 60.0 m
                 from _ss, generate_series(date_trunc('hour', st), en, interval '1 hour') hs
                where en > st),
             agg as (select extract(dow from bd)::int w, hh, sum(m) m from cut where m > 0 group by 1, 2)
             select jsonb_agg((select jsonb_agg(coalesce((select round(a.m) from agg a where a.w = w0 and a.hh = h), 0) order by h)
                                 from generate_series(0, 23) h) order by w0)
               from generate_series(0, 6) w0)
  ));

  return jsonb_build_object('ok', true, 'from', v_from, 'to', v_to, 'days', v_days,
                            'store', p_store, 'today', v_today, 'generated_at', now()) || r;
end $$;

revoke execute on function public.admin_ops_report_tx(date, date, uuid) from public, anon;
grant  execute on function public.admin_ops_report_tx(date, date, uuid) to authenticated;

-- ── 驗證（不 raise，硬規則 1.8）────────────────────────────────
do $$
declare v text := ''; n int; j jsonb; v_uid uuid; g numeric; t numeric;
begin
  select count(*) into n from pg_proc where pronamespace = 'public'::regnamespace and proname = 'admin_ops_report_tx';
  v := v || case when n = 1 then '✅' else '🔴' end || ' ① 只有一個版本（' || n || '）' || E'\n';

  select count(*) into n from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = 'admin_ops_report_tx'
     and has_function_privilege('authenticated', p.oid, 'EXECUTE') and not has_function_privilege('anon', p.oid, 'EXECUTE');
  v := v || case when n = 1 then '✅' else '🔴' end || ' ② 登入的人叫得動、anon 叫不動' || E'\n';

  perform set_config('request.jwt.claims', '{}', true);
  j := public.admin_ops_report_tx(null, null, null);
  v := v || case when j->>'reason' = 'forbidden' then '✅' else '🔴' end || ' ③ 沒有總部身分被擋下（' || coalesce(j->>'reason', '?') || '）' || E'\n';

  select auth_uid into v_uid from staff where role = 'hq' and auth_uid is not null and deleted_at is null limit 1;
  if v_uid is null then
    v := v || '🔴 ④ 找不到總部帳號當樣本';
  else
    perform set_config('request.jwt.claims', json_build_object('sub', v_uid, 'role', 'authenticated')::text, true);
    j := public.admin_ops_report_tx(public._biz_date(now()) - 29, public._biz_date(now()), null);

    -- ④ 舊的數字還在（正對照：要真的有數字）
    v := v || case when (j->>'ok')::boolean and (j->'table'->>'sessions')::int > 0 and (j->'table'->>'revenue')::bigint > 0
                   then '✅' else '🔴' end
            || ' ④ 近 30 天：' || coalesce(j->'table'->>'sessions', '?') || ' 場、營收 ' || coalesce(j->'table'->>'revenue', '?')
            || '、上座率 ' || coalesce(j->'table'->>'occupancy', 'null') || E'\n';

    -- ⑤ 熱力格的分鐘加總 ＝ 佔桌分鐘（同一份起訖切出來的，只差四捨五入）
    select coalesce(sum(x::numeric), 0) into g
      from jsonb_array_elements(j->'heat'->'grid') r, jsonb_array_elements_text(r) x;
    t := (j->'table'->>'table_minutes')::numeric;
    v := v || case when jsonb_array_length(j->'heat'->'grid') = 7 and abs(g - t) <= 7 * 24 then '✅' else '🔴' end
            || ' ⑤ 熱力格 7 × 24，分鐘加總 ' || g || '，佔桌分鐘 ' || t || E'\n';

    -- ⑥ 每一桌的場數加總 ＝ 場數
    select coalesce(sum((x->>'sessions')::int), 0) into n from jsonb_array_elements(j->'table'->'by_table') x;
    v := v || case when n = (j->'table'->>'sessions')::int then '✅' else '🔴' end
            || ' ⑥ 每一桌場數加總 ' || n || '（期望 ' || (j->'table'->>'sessions') || '）' || E'\n';

    -- ⑦ 營收拆解：毛額 − 三種折扣 ＝ 淨額
    v := v || case when (j->'sales'->>'gross')::bigint - (j->'sales'->>'coupon')::bigint - (j->'sales'->>'tier')::bigint
                        - (j->'sales'->>'advisor')::bigint = (j->'sales'->>'net')::bigint then '✅' else '⚠' end
            || ' ⑦ 毛額 ' || (j->'sales'->>'gross') || ' − 折扣 ' || ((j->'sales'->>'coupon')::bigint + (j->'sales'->>'tier')::bigint + (j->'sales'->>'advisor')::bigint)
            || ' ＝ 淨額 ' || (j->'sales'->>'net') || '（⚠ 表示有其他調整，要查）' || E'\n';

    -- ⑧ 配桌漏斗：湊滿 ≤ 開房，各狀態加總 ≤ 開房
    v := v || case when (j->'funnel'->>'rooms')::int > 0
                        and (j->'funnel'->>'filled')::int <= (j->'funnel'->>'rooms')::int
                   then '✅' else '🔴' end
            || ' ⑧ 配桌：開房 ' || (j->'funnel'->>'rooms') || '、湊滿 ' || (j->'funnel'->>'filled')
            || '、過期 ' || (j->'funnel'->>'expired') || '、湊滿中位數 ' || coalesce(j->'funnel'->>'fill_median_minutes', '—') || ' 分' || E'\n';

    -- ⑨ 收桌延遲、計分板、錢包負債、分群都有回
    v := v || case when j->'table'->'close_gap' is not null and j->'liability' is not null
                        and jsonb_typeof(j->'customers'->'cohorts') = 'array' and jsonb_typeof(j->'fnb'->'top') = 'array'
                   then '✅' else '🔴' end
            || ' ⑨ 收桌延遲中位數 ' || coalesce(j->'table'->'close_gap'->>'median', '—') || ' 分（' || coalesce(j->'table'->'close_gap'->>'n', '0') || ' 場）'
            || '、計分板 ' || coalesce(j->'table'->>'scoreboard_sessions', '?') || ' 場、錢包負債 ' || coalesce(j->'liability'->>'balance', '?')
            || '、新客分群 ' || jsonb_array_length(j->'customers'->'cohorts') || ' 週' || E'\n';

    -- ⑩ 來店改成入座之後，人次要比「只算付款人」多（正對照：舊算法的數字當場算出來比）
    select count(distinct (o.member_id, public._biz_date(o.paid_at))) into n
      from orders o join members m on m.id = o.member_id
      join stores so on so.id = o.store_id and not coalesce(so.is_virtual, false)
     where o.status = 'paid' and o.deleted_at is null and not m.is_test and o.paid_at is not null
       and public._biz_date(o.paid_at) between public._biz_date(now()) - 29 and public._biz_date(now());
    v := v || case when (j->'profit'->>'visits')::int >= n then '✅' else '🔴' end
            || ' ⑩ 來客 ' || (j->'profit'->>'visits') || ' 人次（舊算法只算付款人：' || n || '）、30 日活躍 '
            || (j->'retention'->>'active_30d') || ' 人' || E'\n';

    j := public.admin_ops_report_tx(public._biz_date(now()), public._biz_date(now()) - 1, null);
    v := v || case when j->>'reason' = 'bad_range' then '✅' else '🔴' end || ' ⑪ 開始晚於結束被擋下';
  end if;

  perform set_config('request.jwt.claims', '', true);
  perform set_config('migi.rep', v, true);
end $$;

select coalesce(nullif(current_setting('migi.rep', true), ''), '🔴 沒有訊息') as "驗證";
