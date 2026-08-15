-- 【M0・已執行】訂單對外單號（order_no）的自動產生機制。
-- ============================================================
-- MIGI M0 修正包 v1.0 — 對外單號體系
-- 在 Supabase Dashboard → SQL Editor 貼上執行（可重複跑，冪等）
--
-- 修正三件事：
--   ① orders 加對外單號 order_no（消費，前綴 MG-）
--   ② 新增 topup_orders 儲值單（前綴 TP-，與消費分表，預收款 vs 收入不混）
--   ③ member_coupons 加券號 code（客人出示、店員掃碼）
-- 附帶：stores 加店碼 code（單號要帶店別，連鎖必要）
--
-- 原則：wallet_txns 不加單號（流水指向來源，維持 append-only）
--       table_sessions 不加單號（配桌無金流）
-- ============================================================

-- ------------------------------------------------------------
-- 0. stores 加店碼
-- ------------------------------------------------------------
alter table stores add column if not exists code text;

-- backfill：沒店碼的依建立順序給 S01, S02...
do $$
begin
  update stores s
     set code = t.newcode
    from (
      select id,
             'S' || lpad((row_number() over (partition by org_id order by created_at))::text, 2, '0') as newcode
        from stores
       where code is null
    ) t
   where s.id = t.id and s.code is null;
end $$;

alter table stores alter column code set not null;
create unique index if not exists stores_org_code_uq on stores(org_id, code);

comment on column stores.code is '店碼，用於單號（如 S01）。可手動改成有意義的碼，例如 FZ=自由店';


-- ------------------------------------------------------------
-- 1. 單號計數器（每店每類每日一個流水）
-- ------------------------------------------------------------
create table if not exists doc_counters (
  org_id    uuid not null references orgs(id) on delete restrict,
  store_id  uuid not null references stores(id) on delete restrict,
  doc_type  text not null,            -- 'order' | 'topup' | 'coupon' | 'shift'
  doc_date  date not null,
  last_no   integer not null default 0,
  primary key (org_id, store_id, doc_type, doc_date)
);

comment on table doc_counters is '對外單號的每日流水計數器。不要手動改。';


-- ------------------------------------------------------------
-- 2. 產號函式：回傳如 MG-S01-260709-0142
-- ------------------------------------------------------------
create or replace function next_doc_no(
  p_org_id   uuid,
  p_store_id uuid,
  p_doc_type text
) returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_prefix   text;
  v_store    text;
  v_date     date := (now() at time zone 'Asia/Taipei')::date;
  v_seq      integer;
begin
  v_prefix := case p_doc_type
                when 'order'  then 'MG'   -- 消費（實現收入）
                when 'topup'  then 'TP'   -- 儲值（預收款）
                when 'coupon' then 'CP'   -- 券
                when 'shift'  then 'SH'   -- 交班
                else 'XX'
              end;

  select code into v_store from stores where id = p_store_id;
  if v_store is null then
    raise exception 'store % 沒有店碼', p_store_id;
  end if;

  insert into doc_counters (org_id, store_id, doc_type, doc_date, last_no)
       values (p_org_id, p_store_id, p_doc_type, v_date, 1)
  on conflict (org_id, store_id, doc_type, doc_date)
    do update set last_no = doc_counters.last_no + 1
  returning last_no into v_seq;

  return v_prefix || '-' || v_store || '-'
         || to_char(v_date, 'YYMMDD') || '-'
         || lpad(v_seq::text, 4, '0');
end $$;


-- ------------------------------------------------------------
-- 3. orders 加對外單號
-- ------------------------------------------------------------
alter table orders add column if not exists order_no text;

-- backfill 既有資料（依建立時間補號，不呼叫產號函式以免污染計數器）
do $$
begin
  update orders o
     set order_no = t.newno
    from (
      select id,
             'MG-LEGACY-'
             || to_char(created_at at time zone 'Asia/Taipei', 'YYMMDD') || '-'
             || lpad((row_number() over (
                  partition by store_id, (created_at at time zone 'Asia/Taipei')::date
                  order by created_at))::text, 4, '0') as newno
        from orders
       where order_no is null
    ) t
   where o.id = t.id and o.order_no is null;
end $$;

create unique index if not exists orders_org_no_uq on orders(org_id, order_no);

-- 新單自動產號
create or replace function trg_orders_set_no()
returns trigger language plpgsql as $$
begin
  if new.order_no is null then
    new.order_no := next_doc_no(new.org_id, new.store_id, 'order');
  end if;
  return new;
end $$;

drop trigger if exists trg_orders_no on orders;
create trigger trg_orders_no
  before insert on orders
  for each row execute function trg_orders_set_no();

comment on column orders.order_no is '對外消費單號 MG-店碼-YYMMDD-流水。發票／退款／客訴引用。';


-- ------------------------------------------------------------
-- 4. topup_orders 儲值單（新表）
--    與 orders 分開：儲值＝預收款(負債)，消費＝實現收入
-- ------------------------------------------------------------
create table if not exists topup_orders (
  id              uuid primary key default gen_random_uuid(),
  org_id          uuid not null references orgs(id) on delete restrict,
  store_id        uuid not null references stores(id) on delete restrict,
  member_id       uuid not null references members(id) on delete restrict,
  topup_no        text,                                    -- TP-店碼-YYMMDD-流水

  points          bigint not null check (points > 0),      -- 儲值點數（1點=1元）
  bonus_points    bigint not null default 0 check (bonus_points >= 0), -- 贈點
  amount_twd      bigint not null check (amount_twd > 0),  -- 實收金額（元）

  pay_method      text not null
                  check (pay_method in ('cash','credit_card','line_pay','jko','other')),
  status          text not null default 'paid'
                  check (status in ('pending','paid','void','refunded')),

  -- 對帳與冪等
  external_ref    text,                                    -- 金流商交易序號
  idempotency_key text,

  -- 開票（法規：預收款）
  invoice_no      text,
  invoice_at      timestamptz,

  -- 結果：實際入點的那筆流水
  wallet_txn_id   uuid references wallet_txns(id) on delete restrict,

  staff_id        uuid references staff(id) on delete set null,
  note            text,
  created_at      timestamptz not null default now(),
  created_by      uuid
);

create unique index if not exists topup_orders_org_no_uq
  on topup_orders(org_id, topup_no);
create unique index if not exists topup_orders_idem_uq
  on topup_orders(org_id, idempotency_key) where idempotency_key is not null;
create index if not exists topup_orders_member_idx
  on topup_orders(member_id, created_at desc);

create or replace function trg_topup_set_no()
returns trigger language plpgsql as $$
begin
  if new.topup_no is null then
    new.topup_no := next_doc_no(new.org_id, new.store_id, 'topup');
  end if;
  return new;
end $$;

drop trigger if exists trg_topup_no on topup_orders;
create trigger trg_topup_no
  before insert on topup_orders
  for each row execute function trg_topup_set_no();

alter table topup_orders enable row level security;

comment on table topup_orders is '儲值單（預收款）。與 orders(消費/收入) 分表，帳務性質不同，勿合併。';
comment on column topup_orders.points is '儲值點數。實際入點寫在 wallet_txns(type=topup)，此表記錄「單」。';


-- ------------------------------------------------------------
-- 5. member_coupons 加券號
-- ------------------------------------------------------------
alter table member_coupons add column if not exists code text;

-- backfill：既有券補號
do $$
begin
  update member_coupons mc
     set code = 'CP-LEGACY-' || upper(substr(replace(mc.id::text,'-',''), 1, 10))
   where mc.code is null;
end $$;

create unique index if not exists member_coupons_org_code_uq
  on member_coupons(org_id, code);

-- 新券自動產號（券不綁店，用發放時的隨機碼；避免可預測被猜）
create or replace function trg_coupon_set_code()
returns trigger language plpgsql as $$
begin
  if new.code is null then
    new.code := 'CP-' || upper(substr(replace(gen_random_uuid()::text,'-',''), 1, 10));
  end if;
  return new;
end $$;

drop trigger if exists trg_coupon_code on member_coupons;
create trigger trg_coupon_code
  before insert on member_coupons
  for each row execute function trg_coupon_set_code();

comment on column member_coupons.code is '券號 CP-XXXXXXXXXX。客人出示、店員掃碼核銷。隨機不可猜。';


-- ------------------------------------------------------------
-- 6. topup_orders 的 RLS policy（跟其他表同一套 org 隔離）
--    註：只開 select。寫入一律走 SECURITY DEFINER 的 RPC，
--        前端拿 anon key 不能直接 insert 儲值單（錢的事不給前端寫）。
-- ------------------------------------------------------------
drop policy if exists topup_org on topup_orders;
create policy topup_org on topup_orders for select
  using (org_id = current_org_id());

-- doc_counters：內部計數器，前端完全不需要讀
alter table doc_counters enable row level security;
-- 不建任何 policy = 前端讀不到；只有 SECURITY DEFINER 的 next_doc_no() 進得去


-- ============================================================
-- 驗證（跑完可執行這幾行檢查）
-- ============================================================
-- select id, name, code from stores;
-- select order_no, status, total_points, created_at from orders order by created_at desc limit 5;
-- select topup_no, points, bonus_points, amount_twd, pay_method from topup_orders order by created_at desc limit 5;
-- select code, status from member_coupons limit 5;
-- select * from doc_counters;
-- select tablename, policyname from pg_policies where tablename in ('topup_orders','doc_counters');
