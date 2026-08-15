-- 【這是什麼】埋點後端已上線：app_events 表（append-only）、log_app_event_tx / mark_app_active_tx、日活視圖。
-- 【何時讀】要新增追蹤事件、查行為數據、或排查 app_error 時。已執行。
-- ============================================================
-- MIGI M0 修正：APP 事件埋點（app_events）  v1.0
-- Supabase Dashboard → SQL Editor（整段貼上執行，冪等）
--
-- 【目的】
--   會員 App 的行為追蹤落地：滲透率（多少會員在用 App）、
--   功能使用率（按讚/牌咖邀請/配桌漏斗）。
--   前端已埋好 track()（src/lib/analytics.js），此包開通後端。
--
-- 【基石對照】
--   ① uuid 主鍵 ② 只存 UTC 原始值（營業日報表才套）
--   ⑥ org_id + RLS Day 1 ⑮ event 名稱 check 約束
--   ⑱ 寫入只走 SECURITY DEFINER RPC，anon 不能直接碰表
--   append-only：事件不可改刪（比照 wallet_txns / order_payments）
--
-- 【設計說明】
--   - 不用 member_interactions（那是 CRM 互動：care/birthday/winback，
--     語意不同，混用會污染店員的客訴/關懷紀錄）
--   - member_id 可 null：未登入前的事件（如註冊漏斗）也要記
--   - 伺服器 created_at 為準；client_ts 僅參考（手機時鐘不可信）
-- ============================================================


-- ------------------------------------------------------------
-- PART A：app_events 事件表
-- ------------------------------------------------------------
create table if not exists app_events (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references orgs(id) on delete restrict,
  member_id   uuid references members(id) on delete restrict,  -- null=未登入事件
  event       text not null check (event ~ '^[a-z][a-z0-9_]{0,49}$'),  -- 小寫蛇底式，防髒資料（基石⑮）
  props       jsonb not null default '{}'::jsonb
              check (pg_column_size(props) <= 8192),           -- 防超大 payload 灌爆
  client_ts   timestamptz,                                     -- 前端時間（參考用，不做報表依據）
  created_at  timestamptz not null default now()               -- 伺服器 UTC 為準（基石②）
);

-- 報表主查詢：某段時間的事件量 / 某事件的趨勢 / 某會員的行為軌跡
create index if not exists idx_app_events_org_time  on app_events(org_id, created_at);
create index if not exists idx_app_events_org_event on app_events(org_id, event, created_at);
create index if not exists idx_app_events_member    on app_events(member_id, created_at)
  where member_id is not null;

comment on table app_events is
  'App 行為事件（append-only）。寫入只走 log_app_event_tx，前端不可直接 insert。
   事件字典見前端 src/lib/analytics.js：app_open / page_view / notif_open /
   like_player / buddy_invite_sent(from) / buddy_invite_accepted / rejected /
   table_invite_sent(mode) / accepted / rejected / match_join(store,stake)。';

-- append-only：不可刪改（比照 order_payments 模式）
create or replace function app_events_no_mutate() returns trigger
language plpgsql as $$
begin
  raise exception 'app_events 為 append-only，不可刪改';
end $$;

drop trigger if exists trg_app_events_no_mutate on app_events;
create trigger trg_app_events_no_mutate before delete or update on app_events
  for each row execute function app_events_no_mutate();


-- ------------------------------------------------------------
-- PART B：RLS — 前端讀寫全擋，只有 RPC 進得去
-- ------------------------------------------------------------
alter table app_events enable row level security;
-- 不建任何 policy = authenticated/anon 都讀不到（比照 doc_counters 做法）
-- 總部後台要看報表：service_role 繞過 RLS，或日後開 hq 專用 select policy
revoke all on app_events from anon;
revoke all on app_events from authenticated;


-- ------------------------------------------------------------
-- PART C：members 加 App 活躍欄位（滲透率快取）
--   註：last_visit_at 是「到店」，last_app_active_at 是「開 App」，
--       語意不同，不共用。精確日活請查 app_events（event='app_open'）。
-- ------------------------------------------------------------
alter table members
  add column if not exists last_app_active_at timestamptz;

comment on column members.last_app_active_at is
  '最後一次開啟會員 App 的時間（mark_app_active_tx 更新）。
   滲透率 = count(last_app_active_at 在期間內) / count(會員)。';


-- ------------------------------------------------------------
-- PART D：RPC — 前端唯二入口（SECURITY DEFINER，基石⑥教訓：帶 search_path）
-- ------------------------------------------------------------

-- D1. 記錄事件
create or replace function log_app_event_tx(
  p_org_id    uuid,
  p_member_id uuid,      -- 可 null（未登入）
  p_event     text,
  p_props     jsonb default '{}'::jsonb,
  p_client_ts timestamptz default null
) returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  -- 防跨租戶塞資料：member 必須屬於該 org（有帶才驗）
  if p_member_id is not null and not exists (
    select 1 from members
     where id = p_member_id and org_id = p_org_id and deleted_at is null
  ) then
    raise exception 'member 不屬於此 org 或不存在';
  end if;

  insert into app_events (org_id, member_id, event, props, client_ts)
  values (p_org_id, p_member_id, p_event, coalesce(p_props, '{}'::jsonb), p_client_ts);
end $$;

-- D2. 標記 App 活躍（滲透率）
create or replace function mark_app_active_tx(
  p_org_id    uuid,
  p_member_id uuid
) returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update members
     set last_app_active_at = now()
   where id = p_member_id and org_id = p_org_id and deleted_at is null;
end $$;

-- 註冊前就會發事件（app_open），所以 anon 也要能呼叫
grant execute on function log_app_event_tx(uuid, uuid, text, jsonb, timestamptz) to anon, authenticated;
grant execute on function mark_app_active_tx(uuid, uuid) to anon, authenticated;

-- ⚠️ 上線前補強（現階段 demo 可接受，先記著）：
--   anon 可呼叫 = 理論上可被灌垃圾事件。正式上線前擇一：
--   a) 接 LINE 真登入後改只給 authenticated；b) Edge Function 加 rate limit。
--   event 名稱 check + props 大小上限已擋掉最粗暴的濫用。


-- ------------------------------------------------------------
-- PART E：日活/滲透率報表視圖（示範基石②：營業日查詢時才套 +08）
-- ------------------------------------------------------------
create or replace view v_app_daily_active as
select
  org_id,
  (created_at at time zone 'Asia/Taipei')::date as biz_date,   -- 營業日：查詢才套，不寫死進資料
  count(distinct member_id)                     as active_members,
  count(*) filter (where event = 'app_open')    as app_opens
from app_events
where member_id is not null
group by org_id, (created_at at time zone 'Asia/Taipei')::date;

comment on view v_app_daily_active is
  '每日 App 活躍會員數（DAU）。滲透率 = active_members / 當日有效會員總數。';


-- ============================================================
-- 驗證（跑完執行檢查）
-- ============================================================
select count(*) as app_events_table from information_schema.tables where table_name='app_events';
select column_name from information_schema.columns
 where table_name='members' and column_name='last_app_active_at';
-- 手動測一筆（org id 換成實際值）：
-- select log_app_event_tx('11111111-1111-1111-1111-111111111111', null, 'test_event', '{"ok":true}'::jsonb);
-- select * from app_events limit 5;  -- 需 service_role 才看得到
