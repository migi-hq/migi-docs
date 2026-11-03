/* ============================================================
   營運報表第二批（2026-11-03）
   📄 為什麼、對照誰：docs/05-埋點分析/報表優化_世界級對照.md 第五節「第二批」

   ① 作廢與取消記下「是誰、什麼時候」（不可回溯，最先做）
      table_sessions／orders／topup_orders 各加 voided_at、voided_by_staff_id、void_source
      做法是觸發器，不改任何一支作廢函式 ⇒ 之後新增的作廢路徑也自動記到
      · 有登入的店員 ⇒ staff；沒有身分（pg_cron 空桌回收）⇒ system
   ② 目標：report_targets（每間店每個月的營收目標、損益兩平上座率）＋ admin_set_report_target_tx
      兩平線沒填的月份沿用最近一次填的（房租水電不會每個月變）；營收目標只看當月
   ③ 報表拆兩層：_ops_report_core(org, from, to, store) 純計算、誰都叫不到；
      admin_ops_report_tx 先檢查權限再叫它 ⇒ 每天的排程也能用同一份算法（同一份定義，不會漂）
      新增：targets（本月目標、兩平線）、segments（依會員等級、段位）、lifetime（客人終身價值）、
            exceptions.void_by（誰作廢了幾筆）
   ④ 明細：admin_ops_detail_tx(from, to, store, kind) —— 點數字看是哪幾筆組成的
      kind ＝ sessions／orders／new_customers／rooms／voids，最多 500 筆
   ⑤ 每天早上 6:30（台北）用 LINE 推前一個營業日的精簡報表給老闆
      · 通知種類 daily_report；寫進去時就標成已讀已完成，會員 App 的通知清單也排除它（不會出現在鈴鐺）
      · 收件人：staff 角色 owner、有綁會員、沒被刪除（目前只有一位）。一個月約 30 則推播額度
      · admin_send_daily_report_tx()：後台按一下，立刻把昨天的日報傳到「自己」的 LINE（測試用，會吃 1 則）

   ⚠ 卡片顏色照既有的成桌／牌局結束卡片寫死色碼（LINE 讀不懂 CSS 變數；值取自 @migi/assets 的 token）
   ============================================================ */

-- ═══ ① 作廢稽核 ═══════════════════════════════════════════════
alter table public.table_sessions add column if not exists voided_at timestamptz;
alter table public.table_sessions add column if not exists voided_by_staff_id uuid references public.staff(id);
alter table public.table_sessions add column if not exists void_source text;
alter table public.orders         add column if not exists voided_at timestamptz;
alter table public.orders         add column if not exists voided_by_staff_id uuid references public.staff(id);
alter table public.orders         add column if not exists void_source text;
alter table public.topup_orders   add column if not exists voided_at timestamptz;
alter table public.topup_orders   add column if not exists voided_by_staff_id uuid references public.staff(id);
alter table public.topup_orders   add column if not exists void_source text;

alter table public.table_sessions drop constraint if exists table_sessions_void_source_chk;
alter table public.table_sessions add constraint table_sessions_void_source_chk check (void_source is null or void_source in ('staff', 'system'));
alter table public.orders drop constraint if exists orders_void_source_chk;
alter table public.orders add constraint orders_void_source_chk check (void_source is null or void_source in ('staff', 'system'));
alter table public.topup_orders drop constraint if exists topup_orders_void_source_chk;
alter table public.topup_orders add constraint topup_orders_void_source_chk check (void_source is null or void_source in ('staff', 'system'));

comment on column public.table_sessions.voided_by_staff_id is '按下作廢（取消開桌）的店員；系統自動回收是 null 且 void_source = system。2026-11-03 之前作廢的全是 null（沒有記）';
comment on column public.orders.voided_by_staff_id is '作廢這張訂單的店員；2026-11-03 之前作廢的全是 null（沒有記）';
comment on column public.topup_orders.voided_by_staff_id is '作廢這張儲值單的店員；2026-11-03 之前作廢的全是 null（沒有記）';

-- 狀態變成作廢的那一刻蓋章。身分從登入取（current_staff），不收任何參數 ⇒ 前端填不了別人
create or replace function public._audit_void()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_staff uuid;
begin
  if new.status in ('void', 'voided') and old.status is distinct from new.status then
    v_staff := (select staff_id from public.current_staff());
    new.voided_at := now();
    new.voided_by_staff_id := v_staff;
    new.void_source := case when v_staff is null then 'system' else 'staff' end;
  end if;
  return new;
end $$;
revoke execute on function public._audit_void() from public, anon, authenticated;

drop trigger if exists trg_table_sessions_audit_void on public.table_sessions;
create trigger trg_table_sessions_audit_void before update of status on public.table_sessions
  for each row execute function public._audit_void();
drop trigger if exists trg_orders_audit_void on public.orders;
create trigger trg_orders_audit_void before update of status on public.orders
  for each row execute function public._audit_void();
drop trigger if exists trg_topup_orders_audit_void on public.topup_orders;
create trigger trg_topup_orders_audit_void before update of status on public.topup_orders
  for each row execute function public._audit_void();

-- ═══ ② 目標 ═════════════════════════════════════════════════
create table if not exists public.report_targets (
  org_id              uuid not null references public.orgs(id),
  store_id            uuid not null references public.stores(id),
  month               date not null check (month = date_trunc('month', month)::date),
  revenue_target      bigint check (revenue_target is null or revenue_target >= 0),
  breakeven_occupancy numeric(5,4) check (breakeven_occupancy is null or (breakeven_occupancy > 0 and breakeven_occupancy <= 1)),
  updated_by_staff_id uuid references public.staff(id),
  updated_at          timestamptz not null default now(),
  primary key (store_id, month));
alter table public.report_targets enable row level security;   -- 0 policy：只有 DEFINER 函式進得去
comment on table public.report_targets is
  '報表的目標：每間店每個月的營收目標與損益兩平上座率（0～1）。兩平線沒填的月份沿用最近一次填的；營收目標只看當月';

create or replace function public.admin_set_report_target_tx(
  p_store uuid, p_month date, p_revenue_target bigint, p_breakeven numeric)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_org uuid := public.current_org_id(); v_m date := date_trunc('month', p_month)::date;
begin
  if not public.can('target.write') then
    return jsonb_build_object('ok', false, 'reason', 'forbidden', 'message', '只有總部可以設定目標');
  end if;
  if not exists (select 1 from stores where id = p_store and org_id = v_org and deleted_at is null) then
    return jsonb_build_object('ok', false, 'reason', 'bad_store', 'message', '找不到這間門市');
  end if;
  if p_revenue_target is not null and p_revenue_target < 0 then
    return jsonb_build_object('ok', false, 'reason', 'bad_target', 'message', '營收目標不能是負的');
  end if;
  if p_breakeven is not null and (p_breakeven <= 0 or p_breakeven > 1) then
    return jsonb_build_object('ok', false, 'reason', 'bad_breakeven', 'message', '兩平上座率要在 0% 到 100% 之間');
  end if;
  insert into report_targets (org_id, store_id, month, revenue_target, breakeven_occupancy, updated_by_staff_id, updated_at)
  values (v_org, p_store, v_m, p_revenue_target, p_breakeven, (select staff_id from public.current_staff()), now())
  on conflict (store_id, month) do update
     set revenue_target = excluded.revenue_target, breakeven_occupancy = excluded.breakeven_occupancy,
         updated_by_staff_id = excluded.updated_by_staff_id, updated_at = now();
  return jsonb_build_object('ok', true);
end $$;
revoke execute on function public.admin_set_report_target_tx(uuid, date, bigint, numeric) from public, anon;
grant  execute on function public.admin_set_report_target_tx(uuid, date, bigint, numeric) to authenticated;

-- ═══ ③ 報表：計算層 ＋ 權限層 ═══════════════════════════════════
create or replace function public._ops_report_core(p_org uuid, p_from date, p_to date, p_store uuid)
-- ⚠ 不能宣告 stable：裡面用暫存表整理資料
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_org   uuid := p_org;
  v_today date := public._biz_date(now());
  v_to    date := coalesce(p_to, public._biz_date(now()));
  v_from  date := coalesce(p_from, coalesce(p_to, public._biz_date(now())));
  v_days  int;
  v_month_start date;
  r jsonb := '{}'::jsonb;
  v_rev bigint; v_visits int; v_mrev bigint; v_mdays int; v_mlen int;
  v_used numeric; v_cap numeric;
begin
  if v_org is null then
    return jsonb_build_object('ok', false, 'reason', 'no_org', 'message', '找不到機構');
  end if;
  if v_from > v_to then
    return jsonb_build_object('ok', false, 'reason', 'bad_range', 'message', '開始日期不能晚於結束日期');
  end if;
  if v_to - v_from > 366 then
    return jsonb_build_object('ok', false, 'reason', 'range_too_long', 'message', '一次最多查一年');
  end if;
  v_days := v_to - v_from + 1;
  v_month_start := date_trunc('month', v_to)::date;

  -- 範圍內的門市（不含好友練習賽的虛擬門市）；每一間每天的可用桌分鐘一起算好
  drop table if exists pg_temp._rs;
  create temp table _rs (id uuid primary key, cap_day numeric) on commit drop;
  insert into _rs
  select s.id,
         (select count(*) from tables t where t.store_id = s.id and t.is_active and t.deleted_at is null)
         * case when s.open_time is null or s.close_time is null then 24
                when s.close_time > s.open_time then extract(epoch from (s.close_time - s.open_time)) / 3600.0
                else 24 + extract(epoch from (s.close_time - s.open_time)) / 3600.0 end * 60
    from stores s
   where s.org_id = v_org and s.deleted_at is null and not coalesce(s.is_virtual, false)
     and (p_store is null or s.id = p_store);

  -- 真的場次（st／en 是佔桌的起訖，跟上座率同一個定義）
  drop table if exists pg_temp._ss;
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

  -- 來店（全機構、全部歷史）：入座過的人 ＋ 有付款訂單的人，一人一天算一次
  -- 🔴 2026-11-03 查到：近 30 天入座 277 人次裡 196 人次是別人代付的（自己沒有訂單）
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
  select coalesce(sum(cap_day), 0) * v_days into v_cap from _rs;

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

  /* ── 🆕 目標（本月營收目標 ＋ 損益兩平上座率）── */
  r := r || jsonb_build_object('targets', (
    with t as (
      select rs.id store_id, s.name, rs.cap_day,
             (select rt.revenue_target from report_targets rt where rt.store_id = rs.id and rt.month = v_month_start) rev,
             (select rt.breakeven_occupancy from report_targets rt
               where rt.store_id = rs.id and rt.month <= v_month_start and rt.breakeven_occupancy is not null
               order by rt.month desc limit 1) be
        from _rs rs join stores s on s.id = rs.id)
    select jsonb_build_object(
      'month', v_month_start,
      'revenue_target', case when count(*) filter (where rev is not null) > 0 then sum(rev) end,
      'stores_missing_target', count(*) filter (where rev is null),
      -- 兩平線：多間店時依可用桌時加權（大店的線比較重）；有店沒填就不給，免得給一條不完整的線
      'breakeven', case when count(*) filter (where be is null) = 0 and sum(cap_day) > 0
                        then round(sum(be * cap_day) / sum(cap_day), 4) end,
      'stores', coalesce(jsonb_agg(jsonb_build_object('store_id', store_id, 'name', name,
                                                      'revenue_target', rev, 'breakeven', be) order by name), '[]'::jsonb))
      from t));

  /* ── 營收拆解 ── */
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
                       and public._biz_date(coalesce(o.voided_at, o.created_at)) between v_from and v_to)
  ));

  /* ── 錢包負債（全機構、到現在為止）── */
  r := r || jsonb_build_object('liability', (
    select jsonb_build_object('balance', coalesce(sum(w.amount), 0), 'bonus', coalesce(sum(w.bonus_amount), 0),
                              'principal', coalesce(sum(w.amount), 0) - coalesce(sum(w.bonus_amount), 0),
                              'members', count(distinct w.member_id))
      from wallet_txns w join members m on m.id = w.member_id
     where m.org_id = v_org and not m.is_test and w.status = 'completed'));

  /* ── ③ 留存 ── */
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

  /* ── 客人：頻率分布 ＋ 新客分群回訪 ── */
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

  /* ── 🆕 依會員等級、段位（期間內來店的人；營收是他們自己付的訂單）── */
  r := r || jsonb_build_object('segments', jsonb_build_object(
    'by_tier', coalesce((
      select jsonb_agg(jsonb_build_object('label', coalesce(mt.label, '未設定'), 'members', n, 'visits', v, 'revenue', rv)
                       order by mt.sort nulls last)
        from (select y.code, y.n, y.v,
                     (select coalesce(sum(o.payable), 0) from _os o join members m3 on m3.id = o.member_id
                       where o.d between v_from and v_to
                         and coalesce(m3.tier_override, m3.tier) is not distinct from y.code) rv
                from (select coalesce(m.tier_override, m.tier) code, count(distinct va.member_id) n, count(*) v
                        from _va va join members m on m.id = va.member_id
                       where va.store_id in (select id from _rs) and va.d between v_from and v_to
                       group by 1) y) z
        left join member_tiers mt on mt.code = z.code), '[]'::jsonb),
    'by_rank', coalesce((
      select jsonb_agg(jsonb_build_object('label', g, 'members', n, 'visits', v) order by
                       array_position(array['還沒有段位','銅牌熊','銀牌熊','金牌熊','白金熊','鑽石熊','大師熊'], g) nulls last)
        from (select coalesce(nullif(split_part(m.rank, ' ', 1), ''), '還沒有段位') g, count(distinct va.member_id) n, count(*) v
                from _va va join members m on m.id = va.member_id
               where va.store_id in (select id from _rs) and va.d between v_from and v_to
               group by 1) z), '[]'::jsonb)
  ));

  /* ── 🆕 客人終身價值（這幾間店、全部歷史）── */
  r := r || jsonb_build_object('lifetime', (
    with c as (select member_id, count(distinct d) days, min(d) first_d from _va
                where store_id in (select id from _rs) group by 1),
         p as (select o.member_id, sum(o.payable) amt from orders o join members m on m.id = o.member_id
                where o.store_id in (select id from _rs) and o.status = 'paid' and o.deleted_at is null and not m.is_test
                group by 1)
    select jsonb_build_object(
      'customers', count(*),
      'avg_days', round(avg(c.days)::numeric, 1),
      'repeat_rate', case when count(*) > 0 then round(count(*) filter (where c.days >= 2)::numeric / count(*), 4) end,
      'revenue', coalesce(sum(p.amt), 0),
      'avg_revenue', case when count(*) > 0 then round(coalesce(sum(p.amt), 0)::numeric / count(*)) end,
      'since', min(c.first_d))
      from c left join p on p.member_id = c.member_id));

  /* ── 餐飲 ── */
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

  /* ── 配桌漏斗 ── */
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
  drop table if exists pg_temp._nm;
  create temp table _nm (id uuid primary key, src text, channel text, campaign text,
                         staff uuid, ref uuid, played int) on commit drop;
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

  /* ── 例外 ＋ 🆕 誰作廢的 ── */
  r := r || jsonb_build_object('exceptions', jsonb_build_object(
    'void_sessions', (select count(*) from table_sessions ts
                       where ts.store_id in (select id from _rs) and ts.status = 'voided' and ts.deleted_at is null
                         and not coalesce(ts.is_test, false)
                         and public._biz_date(coalesce(ts.voided_at, ts.started_at)) between v_from and v_to),
    'void_orders', (r->'sales'->>'void_orders')::int,
    'late_close', (select count(*) from _ss where closed and last_hand is not null and en - last_hand > interval '30 minutes'),
    'void_by', coalesce((
      select jsonb_agg(jsonb_build_object('kind', kind, 'who', who, 'n', n) order by kind, n desc)
        from (select kind, case when src = 'system' then '系統（空桌自動回收）'
                                when src is null then '開始記錄之前（不知道是誰）'
                                else coalesce(st.name, '已刪除的店員') end who, count(*) n
                from (select 'session' kind, ts.void_source src, ts.voided_by_staff_id sid from table_sessions ts
                       where ts.store_id in (select id from _rs) and ts.status = 'voided' and ts.deleted_at is null
                         and not coalesce(ts.is_test, false)
                         and public._biz_date(coalesce(ts.voided_at, ts.started_at)) between v_from and v_to
                      union all
                      select 'order', o.void_source, o.voided_by_staff_id from orders o join members m on m.id = o.member_id
                       where o.store_id in (select id from _rs) and o.status = 'void' and not m.is_test
                         and public._biz_date(coalesce(o.voided_at, o.created_at)) between v_from and v_to
                      union all
                      select 'topup', t.void_source, t.voided_by_staff_id from topup_orders t join members m on m.id = t.member_id
                       where t.store_id in (select id from _rs) and t.status = 'void' and not m.is_test
                         and public._biz_date(coalesce(t.voided_at, t.created_at)) between v_from and v_to) v
                left join staff st on st.id = v.sid
               group by 1, 2) z), '[]'::jsonb)
  ));

  /* ── 時段熱度 ── */
  r := r || jsonb_build_object('heat', jsonb_build_object(
    'by_hour', (select jsonb_agg(coalesce((select count(*) from _ss where hr = h), 0) order by h) from generate_series(0, 23) h),
    'by_dow',  (select jsonb_agg(coalesce((select count(*) from _ss where extract(dow from d)::int = w), 0) order by w) from generate_series(0, 6) w),
    'by_day',  coalesce((select jsonb_agg(jsonb_build_object('d', d, 'sessions', n, 'revenue',
                          (select coalesce(sum(payable), 0) from _os where _os.d = z.d)) order by d)
                           from (select g::date d, (select count(*) from _ss where _ss.d = g::date) n
                                   from generate_series(v_from, v_to, interval '1 day') g) z), '[]'::jsonb),
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
revoke execute on function public._ops_report_core(uuid, date, date, uuid) from public, anon, authenticated;
comment on function public._ops_report_core(uuid, date, date, uuid) is
  '營運報表的唯一一份算法。前端叫不到：後台走 admin_ops_report_tx（先檢查權限），每天的 LINE 日報走排程';

create or replace function public.admin_ops_report_tx(
  p_from date default null, p_to date default null, p_store uuid default null)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not public.can('ops.read') then
    return jsonb_build_object('ok', false, 'reason', 'forbidden', 'message', '只有總部看得到報表');
  end if;
  return public._ops_report_core(public.current_org_id(), p_from, p_to, p_store);
end $$;
revoke execute on function public.admin_ops_report_tx(date, date, uuid) from public, anon;
grant  execute on function public.admin_ops_report_tx(date, date, uuid) to authenticated;

-- ═══ ④ 明細 ═════════════════════════════════════════════════
create or replace function public.admin_ops_detail_tx(
  p_from date, p_to date, p_store uuid default null, p_kind text default 'sessions')
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_org uuid := public.current_org_id(); v_rows jsonb; v_n int;
begin
  if not public.can('ops.read') then
    return jsonb_build_object('ok', false, 'reason', 'forbidden', 'message', '只有總部看得到報表');
  end if;
  if p_from is null or p_to is null or p_from > p_to or p_to - p_from > 366 then
    return jsonb_build_object('ok', false, 'reason', 'bad_range', 'message', '日期範圍不對（最多一年）');
  end if;

  if p_kind = 'sessions' then
    with s as (
      select ts.id, ts.started_at, coalesce(ts.activated_at, ts.started_at) st, ts.ended_at, ts.status, ts.mode,
             t.label tbl, so.name store, sl.label stake,
             (select max(h.confirmed_at) from hands h where h.session_id = ts.id and h.status = 'confirmed') last_hand
        from table_sessions ts
        join stores so on so.id = ts.store_id
        left join tables t on t.id = ts.table_id
        left join stake_levels sl on sl.id = ts.stake_level_id
       where so.org_id = v_org and not coalesce(so.is_virtual, false) and (p_store is null or so.id = p_store)
         and ts.deleted_at is null and ts.status in ('open', 'completed')
         and public._biz_date(ts.started_at) between p_from and p_to
         and exists (select 1 from session_players sp join members m on m.id = sp.member_id
                      where sp.session_id = ts.id and not m.is_test))
    select jsonb_agg(jsonb_build_object(
             '開打', to_char(st at time zone 'Asia/Taipei', 'MM-DD HH24:MI'),
             '門市', store, '桌', tbl,
             '模式', case mode when 'matched' then '配桌' when 'private' then '包桌' else mode end,
             '積分', stake,
             '最後一局', to_char(last_hand at time zone 'Asia/Taipei', 'MM-DD HH24:MI'),
             '收桌', case when status = 'open' then '還沒收' else to_char(ended_at at time zone 'Asia/Taipei', 'MM-DD HH24:MI') end,
             '佔桌分鐘', round(extract(epoch from (coalesce(ended_at, now()) - st)) / 60),
             '收桌延遲分鐘', case when status = 'completed' and last_hand is not null
                                 then round(greatest(0, extract(epoch from (ended_at - last_hand))) / 60) end,
             '玩家', (select string_agg(m.display_name, '、' order by sp.joined_at) from session_players sp
                       join members m on m.id = sp.member_id where sp.session_id = s.id),
             '營收', (select coalesce(sum(o.payable), 0) from orders o where o.session_id = s.id and o.status = 'paid'))
             order by st desc), count(*)
      into v_rows, v_n
      from (select * from s order by st desc limit 500) s;

  elsif p_kind = 'orders' then
    with o as (
      select o.*, so.name store, t.label tbl, m.display_name who
        from orders o
        join members m on m.id = o.member_id
        join stores so on so.id = o.store_id
        left join table_sessions ts on ts.id = o.session_id
        left join tables t on t.id = ts.table_id
       where so.org_id = v_org and not coalesce(so.is_virtual, false) and (p_store is null or so.id = p_store)
         and o.status = 'paid' and o.deleted_at is null and not m.is_test and o.paid_at is not null
         and public._biz_date(o.paid_at) between p_from and p_to)
    select jsonb_agg(jsonb_build_object(
             '時間', to_char(paid_at at time zone 'Asia/Taipei', 'MM-DD HH24:MI'),
             '單號', order_no, '門市', store, '桌', coalesce(tbl, '櫃檯'), '付款人', who,
             '品項', (select string_agg(i.name || ' ×' || i.qty, '、') from order_items i where i.order_id = o.id),
             '毛額', subtotal,
             '折扣', coalesce(coupon_discount, 0) + coalesce(tier_discount, 0) + coalesce(advisor_discount, 0),
             '淨額', payable, '點數', coalesce(points_used, 0))
             order by paid_at desc), count(*)
      into v_rows, v_n
      from (select * from o order by paid_at desc limit 500) o;

  elsif p_kind = 'new_customers' then
    with va as (
      select sp.member_id, public._biz_date(ts.started_at) d, ts.store_id
        from session_players sp join table_sessions ts on ts.id = sp.session_id join stores so on so.id = ts.store_id
       where so.org_id = v_org and not coalesce(so.is_virtual, false) and ts.deleted_at is null and ts.status in ('open', 'completed')
      union
      select o.member_id, public._biz_date(o.paid_at), o.store_id
        from orders o where o.org_id = v_org and o.status = 'paid' and o.deleted_at is null and o.paid_at is not null and o.store_id is not null),
    f as (select va.member_id, min(va.d) fd from va group by 1),
    n as (select f.member_id, f.fd from f
           where f.fd between p_from and p_to
             and exists (select 1 from va where va.member_id = f.member_id and va.d = f.fd
                                            and (p_store is null or va.store_id = p_store)))
    select jsonb_agg(jsonb_build_object(
             '第一次來店', n.fd, '會員', m.display_name,
             '來源', case coalesce(m.acquisition_source, 'before') when 'staff' then '店員推薦' when 'member' then '會員邀請'
                       when 'ad' then '廣告' when 'other' then '自有管道' when 'none' then '沒有標記' else '開始記錄之前' end,
             '之後又來幾天', (select count(distinct va.d) from va where va.member_id = n.member_id and va.d > n.fd),
             '到目前付了多少', (select coalesce(sum(o.payable), 0) from orders o where o.member_id = n.member_id and o.status = 'paid'))
             order by n.fd desc, m.display_name), count(*)
      into v_rows, v_n
      from (select * from n order by fd desc limit 500) n join members m on m.id = n.member_id
     where not m.is_test;

  elsif p_kind = 'rooms' then
    with q as (
      select q.*, so.name store, sl.label stake
        from match_queues q join stores so on so.id = q.store_id
        left join stake_levels sl on sl.id = q.stake_level_id
       where so.org_id = v_org and (p_store is null or so.id = p_store)
         and public._biz_date(coalesce(q.play_at, q.created_at)) between p_from and p_to
         and exists (select 1 from match_queue_players p join members m on m.id = p.member_id
                      where p.queue_id = q.id and not m.is_test))
    select jsonb_agg(jsonb_build_object(
             '開打時間', to_char(coalesce(play_at, created_at) at time zone 'Asia/Taipei', 'MM-DD HH24:MI'),
             '門市', store, '積分', stake, '玩法', game_type, '將數', rounds,
             '結果', case status when 'seated' then '已開打' when 'expired' then '過期沒湊滿'
                                 when 'cancelled' then '取消' when 'waiting' then '等人中' else status end,
             '開房', to_char(created_at at time zone 'Asia/Taipei', 'MM-DD HH24:MI'),
             '湊滿分鐘', case when matched_at is not null then round(extract(epoch from (matched_at - created_at)) / 60) end,
             '報名過的人', (select string_agg(m.display_name, '、' order by p.joined_at) from match_queue_players p
                            join members m on m.id = p.member_id where p.queue_id = q.id))
             order by coalesce(play_at, created_at) desc), count(*)
      into v_rows, v_n
      from (select * from q order by coalesce(play_at, created_at) desc limit 500) q;

  elsif p_kind = 'voids' then
    with v as (
      select '取消開桌' kind, coalesce(ts.voided_at, ts.started_at) at_, so.name store, t.label ref, ts.void_source src, ts.voided_by_staff_id sid
        from table_sessions ts join stores so on so.id = ts.store_id left join tables t on t.id = ts.table_id
       where so.org_id = v_org and (p_store is null or so.id = p_store) and ts.status = 'voided' and ts.deleted_at is null
         and not coalesce(ts.is_test, false) and public._biz_date(coalesce(ts.voided_at, ts.started_at)) between p_from and p_to
      union all
      select '作廢訂單', coalesce(o.voided_at, o.created_at), so.name, o.order_no, o.void_source, o.voided_by_staff_id
        from orders o join stores so on so.id = o.store_id join members m on m.id = o.member_id
       where so.org_id = v_org and (p_store is null or so.id = p_store) and o.status = 'void' and not m.is_test
         and public._biz_date(coalesce(o.voided_at, o.created_at)) between p_from and p_to
      union all
      select '作廢儲值', coalesce(tp.voided_at, tp.created_at), so.name, tp.topup_no, tp.void_source, tp.voided_by_staff_id
        from topup_orders tp join stores so on so.id = tp.store_id join members m on m.id = tp.member_id
       where so.org_id = v_org and (p_store is null or so.id = p_store) and tp.status = 'void' and not m.is_test
         and public._biz_date(coalesce(tp.voided_at, tp.created_at)) between p_from and p_to)
    select jsonb_agg(jsonb_build_object(
             '時間', to_char(at_ at time zone 'Asia/Taipei', 'MM-DD HH24:MI'), '種類', kind, '門市', store, '桌號或單號', ref,
             '誰', case when src = 'system' then '系統（空桌自動回收）' when src is null then '開始記錄之前（不知道是誰）'
                        else coalesce(st.name, '已刪除的店員') end)
             order by at_ desc), count(*)
      into v_rows, v_n
      from (select * from v order by at_ desc limit 500) v left join staff st on st.id = v.sid;

  else
    return jsonb_build_object('ok', false, 'reason', 'bad_kind', 'message', '不認得的明細種類');
  end if;

  return jsonb_build_object('ok', true, 'kind', p_kind, 'rows', coalesce(v_rows, '[]'::jsonb),
                            'truncated', coalesce(v_n, 0) >= 500);
end $$;
revoke execute on function public.admin_ops_detail_tx(date, date, uuid, text) from public, anon;
grant  execute on function public.admin_ops_detail_tx(date, date, uuid, text) to authenticated;

-- ═══ ⑤ 每天的 LINE 日報 ═══════════════════════════════════════
-- 卡片：照成桌／牌局結束卡片的樣式（粉色標題列、項目 → 內容、黑底按鈕）
create or replace function public._push_daily_flex(p_notif uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare f jsonb; v_rows jsonb; v_alt text;
begin
  select payload into f from app_notifications where id = p_notif and type = 'daily_report';
  if f is null then return null; end if;

  select jsonb_agg(jsonb_build_object('type', 'box', 'layout', 'baseline', 'spacing', 'md', 'contents', jsonb_build_array(
           jsonb_build_object('type', 'text', 'text', k, 'size', 'sm', 'color', '#8B8582', 'flex', 4),
           jsonb_build_object('type', 'text', 'text', v, 'size', 'sm', 'color', '#2E2B2C', 'wrap', true, 'flex', 6, 'align', 'end')))
         order by o)
    into v_rows
    from (values (1, '開桌', f ->> 'sessions_text'),
                 (2, '上座率', f ->> 'occupancy_text'),
                 (3, '來客', f ->> 'visits_text'),
                 (4, '新客', f ->> 'new_text'),
                 (5, '配桌', f ->> 'rooms_text'),
                 (6, '收桌延遲', f ->> 'gap_text'),
                 (7, '作廢', f ->> 'void_text'),
                 (8, '本月累計', f ->> 'month_text')) t(o, k, v)
   where v is not null;

  v_alt := case when (f ->> 'test')::boolean then '【測試】' else '' end
        || 'MIGI 日報 ' || (f ->> 'day_label') || '：營收 ' || (f ->> 'revenue_text');

  return jsonb_build_object(
    'type', 'flex', 'altText', left(v_alt, 400),
    'contents', jsonb_build_object(
      'type', 'bubble', 'size', 'kilo',
      'header', jsonb_build_object('type', 'box', 'layout', 'vertical', 'backgroundColor', '#FAD6DC', 'paddingAll', '14px',
        'contents', jsonb_build_array(
          jsonb_build_object('type', 'text', 'text', 'MIGI 日報', 'size', 'lg', 'weight', 'bold', 'color', '#2E2B2C', 'align', 'center'),
          jsonb_build_object('type', 'text', 'text', case when (f ->> 'test')::boolean then '測試 · ' else '' end || (f ->> 'day_label'),
                             'size', 'xxs', 'color', '#2E2B2C', 'align', 'center'))),
      'body', jsonb_build_object('type', 'box', 'layout', 'vertical', 'paddingAll', '18px',
        'contents', jsonb_build_array(
          jsonb_build_object('type', 'text', 'text', '營收', 'size', 'xs', 'color', '#8B8582'),
          jsonb_build_object('type', 'text', 'text', f ->> 'revenue_text', 'size', 'xxl', 'weight', 'bold', 'color', '#2E2B2C', 'margin', 'xs'),
          jsonb_build_object('type', 'text', 'text', f ->> 'revenue_cmp', 'size', 'xs', 'color', '#8B8582', 'wrap', true, 'margin', 'xs'),
          jsonb_build_object('type', 'separator', 'margin', 'lg', 'color', '#DED9D5'),
          jsonb_build_object('type', 'box', 'layout', 'vertical', 'spacing', 'sm', 'margin', 'lg',
                             'contents', coalesce(v_rows, '[]'::jsonb)))),
      'footer', jsonb_build_object('type', 'box', 'layout', 'vertical', 'paddingAll', '12px',
        'contents', jsonb_build_array(
          jsonb_build_object('type', 'button', 'style', 'primary', 'color', '#2E2B2C', 'height', 'sm',
            'action', jsonb_build_object('type', 'uri', 'label', '看完整報表', 'uri', f ->> 'url'))))));
end $$;
revoke execute on function public._push_daily_flex(uuid) from public, anon, authenticated;

create or replace function public._push_messages(p_notif uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_default text := 'card';          -- 🔴 2026-10-05 使用者選卡片版。要換就改這裡：'text'／'card'／'both'
  v_type text;
  v_style text;
  v_text text; v_flex jsonb;
begin
  select type, coalesce(nullif(payload ->> 'style', ''), v_default)
    into v_type, v_style
    from app_notifications where id = p_notif;

  -- 🆕 2026-11-03 日報只有卡片（給老闆看的，沒有純文字版的需求）
  if v_type = 'daily_report' then
    v_flex := _push_daily_flex(p_notif);
    return case when v_flex is null then null else jsonb_build_array(v_flex) end;
  end if;

  if v_type = 'settle' then
    v_text := _push_settle_text(p_notif);
    if v_text is null then return null; end if;
    v_flex := _push_settle_flex(p_notif);
  else
    v_text := _push_text(p_notif);
    if v_text is null then return null; end if;
    v_flex := _push_flex(p_notif);
  end if;

  return case v_style
    when 'card' then jsonb_build_array(v_flex)
    when 'both' then jsonb_build_array(jsonb_build_object('type', 'text', 'text', v_text), v_flex)
    else jsonb_build_array(jsonb_build_object('type', 'text', 'text', v_text))
  end;
end $$;

create or replace function public._push_enqueue()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_n int;
begin
  insert into notification_deliveries (org_id, notification_id, channel)
  select nr.org_id, nr.id, 'line'
    from new_rows nr
   where nr.type in ('table_ok', 'settle', 'daily_report')   -- 🔴 白名單：要推哪一種通知就加在這裡（每一種都吃免費則數）
  on conflict (notification_id, channel) do nothing;
  get diagnostics v_n = row_count;
  if v_n > 0 then
    perform _push_kick();
  end if;
  return null;
end $$;

-- 會員 App 的通知清單排除日報（它只是推播的載體，不是給會員看的通知）
create or replace function public.list_notifications_tx(p_org_id uuid, p_member uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  -- 【身分 2026-09-29】只認登入的本人，前端送的 id 一律忽略
  p_member := public.current_member_id();
  if p_member is null then raise exception '未登入或登入已過期，請重新開啟 App' using errcode = '28000'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', n.id, 'type', n.type, 'payload', n.payload, 'ref_id', n.ref_id,
      'unread', (n.read_at is null), 'done', (n.done_at is not null), 'created_at', n.created_at,
      /* 這則邀請回覆了沒。null = 不適用（純告知類）或查不到對應邀請。
         前端把 null 與 'pending' 都當成待處理。 */
      'invite_status', case
        when n.type = 'buddy_req' then (
          select bi.status
            from buddy_invites bi
           where bi.inviter_id = n.ref_id
             and bi.invitee_id = n.member_id
           order by bi.created_at desc
           limit 1)
        /* 🆕 團的申請與邀請。`ref_id` 直接就是 team_requests.id。
           ⚠ 過期的要說「過期」不要說「待處理」—— 清理是在別的動作
             順手做的（沒有排程），所以這裡一定會看到還沒被收掉的 pending。 */
        when n.type = 'team_req' then (
          select case when r.status = 'pending' and r.expires_at <= now()
                      then 'expired' else r.status end
            from team_requests r
           where r.id = n.ref_id)
        /* 🆕 2026-10-30 揪桌（ref_id ＝ 那一房）：這則通知之後他進過那一房 ⇒ 已接受；
           按過拒絕（done_at）⇒ 已拒絕；那一房已經不在等人 ⇒ 已過期；其餘 ⇒ 待處理 */
        when n.type = 'table_req' then (
          select case
                   when exists (select 1 from match_queue_players qp
                                 where qp.queue_id = n.ref_id and qp.member_id = n.member_id
                                   and qp.joined_at >= n.created_at) then 'accepted'
                   when n.done_at is not null then 'rejected'
                   when q.id is null or q.status <> 'waiting'
                        or (q.expires_at is not null and q.expires_at < now()) then 'expired'
                   else 'pending' end
            from (select 1) one
            left join match_queues q on q.id = n.ref_id)
        end,
      /* 2026-10-20：這則通知「是誰」的頭像（前端畫真的頭像，不再一律預設小熊）
           牌咖邀請 ref_id ＝ 邀請人；接受了你的牌咖邀請 ref_id ＝ 接受的人（2026-10-21 補）；
           入團申請（給團長）＝ 申請的人；入團邀請（給被邀的人）＝ 邀請的人；
           某某加入了團／用邀請連結加入了 ref_id ＝ 加入的人（2026-10-21 補，其他牌咖團告知類 ref_id 是 null）；
           邀你入桌 ＝ payload.from_id 的邀請人（ref_id 是那一房，2026-10-21 補）。
           其他類型沒有「誰」，回 null */
      'actor', (
        select jsonb_build_object('avatar_url', a.avatar_url, 'avatar_bear', a.avatar_bear,
                                  'avatar_source', a.avatar_source, 'avatar_photo_path', a.avatar_photo_path,
                                  'rank', a.rank)
          from members a
         where a.id = case
                 when n.type = 'buddy_req' then n.ref_id
                 when n.type = 'buddy_ok' then n.ref_id
                 when n.type = 'team_ok' then n.ref_id
                 when n.type = 'table_req' then (n.payload->>'from_id')::uuid
                 when n.type = 'team_req' then (
                   select case when r.kind = 'invite' then r.created_by else r.member_id end
                     from team_requests r where r.id = n.ref_id)
               end)
    ) order by n.created_at desc)
    from app_notifications n
    where n.member_id = p_member and n.org_id = p_org_id
      and n.created_at > now() - interval '30 days'
      and n.type <> 'daily_report'   -- 🆕 2026-11-03 日報只走 LINE，不進通知清單
  ), '[]'::jsonb);
end $$;

-- 組一份日報的內容（數字在寫進去那一刻就算好，卡片只負責畫）
create or replace function public._daily_report_payload(p_org uuid, p_day date, p_test boolean)
returns jsonb language plpgsql security definer set search_path = public as $$
declare j jsonb; p jsonb; v_cap numeric; v_gap jsonb; v_void int; v_tgt jsonb;
  fmt_money text := 'FM999,999,990';
begin
  j := public._ops_report_core(p_org, p_day, p_day, null);
  p := public._ops_report_core(p_org, p_day - 7, p_day - 7, null);   -- 比上週同一天
  if not coalesce((j ->> 'ok')::boolean, false) then return null; end if;
  v_gap := j -> 'table' -> 'close_gap';
  v_tgt := j -> 'targets';
  select coalesce(sum((x ->> 'n')::int), 0) into v_void from jsonb_array_elements(j -> 'exceptions' -> 'void_by') x;

  return jsonb_build_object(
    'day', p_day, 'test', p_test,
    'day_label', to_char(p_day, 'MM/DD') || '（週' || (array['日','一','二','三','四','五','六'])[extract(dow from p_day)::int + 1] || '）營業日',
    'revenue_text', '$' || to_char((j -> 'table' ->> 'revenue')::bigint, fmt_money),
    'revenue_cmp', '上週同一天 $' || to_char((p -> 'table' ->> 'revenue')::bigint, fmt_money)
                   || case when (p -> 'table' ->> 'revenue')::bigint > 0
                           then '（' || case when (j -> 'table' ->> 'revenue')::bigint >= (p -> 'table' ->> 'revenue')::bigint then '▲ ' else '▼ ' end
                                || round(abs((j -> 'table' ->> 'revenue')::numeric / (p -> 'table' ->> 'revenue')::numeric - 1) * 100) || '%）'
                           else '' end,
    'sessions_text', (j -> 'table' ->> 'sessions') || ' 場（上週 ' || (p -> 'table' ->> 'sessions') || ' 場）',
    'occupancy_text', coalesce(round((j -> 'table' ->> 'occupancy')::numeric * 100, 1) || '%', '—')
                      || coalesce('（兩平 ' || round((v_tgt ->> 'breakeven')::numeric * 100, 1) || '%）', ''),
    'visits_text', (j -> 'profit' ->> 'visits') || ' 人次',
    'new_text', (j -> 'retention' ->> 'new_customers') || ' 位',
    'rooms_text', case when (j -> 'funnel' ->> 'rooms')::int > 0
                       then '開 ' || (j -> 'funnel' ->> 'rooms') || ' 房、湊滿 ' || (j -> 'funnel' ->> 'filled') end,
    'gap_text', case when (v_gap ->> 'n')::int > 0
                     then '中位數 ' || (v_gap ->> 'median') || ' 分' || case when (v_gap ->> 'over30')::int > 0
                                                                            then '、超過 30 分 ' || (v_gap ->> 'over30') || ' 場' else '' end end,
    'void_text', case when v_void > 0 then v_void || ' 筆' end,
    'month_text', '$' || to_char((j -> 'profit' ->> 'month_revenue')::bigint, fmt_money)
                  || coalesce('／目標 $' || to_char((v_tgt ->> 'revenue_target')::bigint, fmt_money), ''),
    'url', 'https://hq.migi.tw/?nav=reports&d=' || p_day);
end $$;
revoke execute on function public._daily_report_payload(uuid, date, boolean) from public, anon, authenticated;

-- 排程：每天早上送前一個營業日（同一天同一人只送一份）
create or replace function public._daily_report_send()
returns int language plpgsql security definer set search_path = public as $$
declare v_day date := public._biz_date(now()) - 1; r record; v_payload jsonb; v_n int := 0;
begin
  for r in
    select distinct s.org_id, s.member_id from staff s join members m on m.id = s.member_id
     where s.role = 'owner' and s.deleted_at is null and m.deleted_at is null
  loop
    if exists (select 1 from app_notifications n where n.member_id = r.member_id and n.type = 'daily_report'
                and n.payload ->> 'day' = v_day::text and coalesce((n.payload ->> 'test')::boolean, false) = false) then
      continue;
    end if;
    v_payload := public._daily_report_payload(r.org_id, v_day, false);
    if v_payload is null then continue; end if;
    insert into app_notifications (org_id, member_id, type, payload, read_at, done_at)
    values (r.org_id, r.member_id, 'daily_report', v_payload, now(), now());
    v_n := v_n + 1;
  end loop;
  return v_n;
end $$;
revoke execute on function public._daily_report_send() from public, anon, authenticated;

-- 後台按一下：把昨天的日報傳到「自己」的 LINE（測試用）
create or replace function public.admin_send_daily_report_tx()
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_org uuid := public.current_org_id(); v_member uuid; v_payload jsonb;
begin
  if not public.can('ops.read') then
    return jsonb_build_object('ok', false, 'reason', 'forbidden', 'message', '只有總部可以傳日報');
  end if;
  select member_id into v_member from public.current_staff();
  if v_member is null then
    return jsonb_build_object('ok', false, 'reason', 'no_line', 'message', '這個帳號沒有綁 LINE（請用 LINE 登入後台再試）');
  end if;
  if exists (select 1 from app_notifications where member_id = v_member and type = 'daily_report'
              and created_at > now() - interval '1 minute') then
    return jsonb_build_object('ok', false, 'reason', 'too_fast', 'message', '剛剛才傳過，等一分鐘再試');
  end if;
  v_payload := public._daily_report_payload(v_org, public._biz_date(now()) - 1, true);
  insert into app_notifications (org_id, member_id, type, payload, read_at, done_at)
  values (v_org, v_member, 'daily_report', v_payload, now(), now());
  return jsonb_build_object('ok', true, 'day', v_payload ->> 'day');
end $$;
revoke execute on function public.admin_send_daily_report_tx() from public, anon;
grant  execute on function public.admin_send_daily_report_tx() to authenticated;

-- 每天台北 06:30（UTC 22:30）
do $$
begin
  if exists (select 1 from cron.job where jobname = 'daily-report') then
    perform cron.unschedule('daily-report');
  end if;
  perform cron.schedule('daily-report', '30 22 * * *', 'select public._daily_report_send()');
end $$;

-- ── 驗證（不 raise，硬規則 1.8）────────────────────────────────
do $$
declare v text := ''; n int; j jsonb; k jsonb; v_uid uuid; v_org uuid; p jsonb;
begin
  -- ① 函式各一個版本
  select count(*) into n from pg_proc where pronamespace = 'public'::regnamespace
     and proname in ('_ops_report_core','admin_ops_report_tx','admin_ops_detail_tx','admin_set_report_target_tx',
                     '_audit_void','_push_daily_flex','_daily_report_payload','_daily_report_send','admin_send_daily_report_tx');
  v := v || case when n = 9 then '✅' else '🔴' end || ' ① 九支函式各一個版本（' || n || '）' || E'\n';

  -- ② 授權：前端叫得動四支、叫不動內部的五支
  select count(*) into n from pg_proc p where p.pronamespace = 'public'::regnamespace
     and p.proname in ('admin_ops_report_tx','admin_ops_detail_tx','admin_set_report_target_tx','admin_send_daily_report_tx')
     and has_function_privilege('authenticated', p.oid, 'EXECUTE') and not has_function_privilege('anon', p.oid, 'EXECUTE');
  v := v || case when n = 4 then '✅' else '🔴' end || ' ② 後台的四支：登入的人叫得動、anon 叫不動（' || n || '/4）' || E'\n';
  select count(*) into n from pg_proc p where p.pronamespace = 'public'::regnamespace
     and p.proname in ('_ops_report_core','_audit_void','_push_daily_flex','_daily_report_payload','_daily_report_send')
     and (has_function_privilege('authenticated', p.oid, 'EXECUTE') or has_function_privilege('anon', p.oid, 'EXECUTE'));
  v := v || case when n = 0 then '✅' else '🔴' end || ' ③ 內部的五支前端叫不到（叫得到的 ' || n || ' 支）' || E'\n';

  -- ④ 三個觸發器 ＋ 排程
  select count(*) into n from pg_trigger where not tgisinternal
     and tgname in ('trg_table_sessions_audit_void','trg_orders_audit_void','trg_topup_orders_audit_void');
  v := v || case when n = 3 then '✅' else '🔴' end || ' ④ 作廢稽核觸發器 ' || n || '/3、日報排程 '
          || coalesce((select schedule from cron.job where jobname = 'daily-report' and active), '🔴 沒有') || E'\n';

  -- ⑤ 沒有總部身分被擋下（負對照）
  perform set_config('request.jwt.claims', '{}', true);
  j := public.admin_ops_report_tx(null, null, null);
  k := public.admin_ops_detail_tx(current_date, current_date, null, 'sessions');
  v := v || case when j->>'reason' = 'forbidden' and k->>'reason' = 'forbidden' then '✅' else '🔴' end
          || ' ⑤ 沒有總部身分：報表與明細都擋下' || E'\n';

  select auth_uid into v_uid from staff where role = 'hq' and auth_uid is not null and deleted_at is null limit 1;
  if v_uid is null then
    v := v || '🔴 ⑥ 找不到總部帳號當樣本';
  else
    perform set_config('request.jwt.claims', json_build_object('sub', v_uid, 'role', 'authenticated')::text, true);
    v_org := public.current_org_id();

    -- ⑥ 拆成兩層之後數字不變（正對照：第一批驗證時是 70 場、營收 41600、來客 260）
    j := public.admin_ops_report_tx(public._biz_date(now()) - 29, public._biz_date(now()), null);
    v := v || case when (j->>'ok')::boolean and (j->'table'->>'sessions')::int > 0 then '✅' else '🔴' end
            || ' ⑥ 近 30 天：' || (j->'table'->>'sessions') || ' 場、營收 ' || (j->'table'->>'revenue')
            || '、來客 ' || (j->'profit'->>'visits') || ' 人次（第一批驗證時 70／41600／260，日子往後移會小幅變動）' || E'\n';

    -- ⑦ 新區塊都在
    v := v || case when j->'targets' is not null and jsonb_typeof(j->'segments'->'by_tier') = 'array'
                        and j->'lifetime'->>'customers' is not null and jsonb_typeof(j->'exceptions'->'void_by') = 'array'
                   then '✅' else '🔴' end
            || ' ⑦ 目標、等級、段位、終身價值、誰作廢都有回：客人 ' || coalesce(j->'lifetime'->>'customers', '?')
            || ' 位、平均來 ' || coalesce(j->'lifetime'->>'avg_days', '?') || ' 天、等級 '
            || jsonb_array_length(j->'segments'->'by_tier') || ' 組、作廢來源 ' || jsonb_array_length(j->'exceptions'->'void_by') || ' 組' || E'\n';

    -- ⑧ 等級分組的人數加總 ＝ 30 日內… 這裡用期間內來店的人數比對
    select coalesce(sum((x->>'members')::int), 0) into n from jsonb_array_elements(j->'segments'->'by_tier') x;
    v := v || case when n = (select count(distinct member_id) from _va where store_id in (select id from _rs)
                                and d between public._biz_date(now()) - 29 and public._biz_date(now())) then '✅' else '🔴' end
            || ' ⑧ 各等級人數加總 ' || n || ' ＝ 期間內來店的人' || E'\n';

    -- ⑨ 明細：場次筆數 ＝ 報表的場數；五種都叫得動、不認得的種類被擋
    k := public.admin_ops_detail_tx(public._biz_date(now()) - 29, public._biz_date(now()), null, 'sessions');
    v := v || case when jsonb_array_length(k->'rows') = (j->'table'->>'sessions')::int then '✅' else '🔴' end
            || ' ⑨ 明細場次 ' || jsonb_array_length(k->'rows') || ' 筆（報表 ' || (j->'table'->>'sessions') || ' 場）、其他四種：';
    for p in select to_jsonb(x) from unnest(array['orders','new_customers','rooms','voids']) x loop
      k := public.admin_ops_detail_tx(public._biz_date(now()) - 29, public._biz_date(now()), null, p #>> '{}');
      v := v || (p #>> '{}') || ' ' || case when (k->>'ok')::boolean then jsonb_array_length(k->'rows')::text else '🔴' end || '　';
    end loop;
    k := public.admin_ops_detail_tx(current_date, current_date, null, 'xxx');
    v := v || case when k->>'reason' = 'bad_kind' then '／亂填的種類被擋 ✅' else '／🔴 亂填的種類沒被擋' end || E'\n';

    -- ⑩ 日報內容組得出來（不寫入、不推播）
    p := public._daily_report_payload(v_org, public._biz_date(now()) - 1, true);
    v := v || case when p->>'revenue_text' is not null and p->>'url' like 'https://hq.migi.tw/%' then '✅' else '🔴' end
            || ' ⑩ 日報：' || coalesce(p->>'day_label', '?') || ' 營收 ' || coalesce(p->>'revenue_text', '?') || '、' || coalesce(p->>'revenue_cmp', '') || E'\n';

    -- ⑪ 目標的擋牆：兩平線超過 100% 被擋
    k := public.admin_set_report_target_tx((select id from stores where org_id = v_org and not coalesce(is_virtual, false) limit 1),
                                           current_date, 100000, 1.5);
    v := v || case when k->>'reason' = 'bad_breakeven' then '✅' else '🔴' end || ' ⑪ 兩平線填 150% 被擋下（' || coalesce(k->>'reason', '?') || '）';
  end if;

  perform set_config('request.jwt.claims', '', true);
  perform set_config('migi.rep2', v, true);
end $$;

select coalesce(nullif(current_setting('migi.rep2', true), ''), '🔴 沒有訊息') as "驗證";
