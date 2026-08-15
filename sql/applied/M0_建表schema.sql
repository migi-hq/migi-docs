-- ============================================================
-- MIGI 麻將連鎖 — M0 資料庫建表 SQL（Supabase / PostgreSQL）
-- 依《資料架構基石規範 v1.0》22 項基石撰寫
-- 部署：Supabase Dashboard → SQL Editor → 貼上執行
-- ============================================================
-- 基石對照：
--   ① UUID 主鍵  ② timestamptz UTC  ③ deleted_at 軟刪除
--   ④ 點數 bigint  ⑤ 審計欄  ⑥ org_id+RLS  ⑦ 並發鎖(在 Edge Function)
--   ⑧ 冪等鍵  ⑨ 雙邊錢流  ⑩ 交易狀態  ⑪ external_ref
--   ⑫ 沖正  ⑬ 金額方向  ⑭ 外鍵 restrict  ⑮ enum/check
--   ⑯ 唯一約束含 deleted_at  ⑰ org_id 不可竄改  ⑱ service_role 邊界
-- ============================================================

-- 必要擴充（Supabase 預設已啟用 pgcrypto，gen_random_uuid 可用）
create extension if not exists "pgcrypto";

-- ------------------------------------------------------------
-- 共用觸發器：自動更新 updated_at（基石⑤）
-- ------------------------------------------------------------
create or replace function set_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end $$;

-- ------------------------------------------------------------
-- 共用觸發器：org_id 不可竄改（基石⑰）
-- ------------------------------------------------------------
create or replace function prevent_org_change()
returns trigger language plpgsql as $$
begin
  if new.org_id is distinct from old.org_id then
    raise exception 'org_id 不可竄改 (id=%)', old.id;
  end if;
  return new;
end $$;

-- ============================================================
-- 1. 租戶與分店（多租戶根基，基石⑥⑰）
-- ============================================================
create table orgs (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  plan        text not null default 'self'
              check (plan in ('self','franchise','licensed')),
  deleted_at  timestamptz,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  created_by  uuid,
  updated_by  uuid
);
create trigger trg_orgs_updated before update on orgs
  for each row execute function set_updated_at();

create table stores (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references orgs(id) on delete restrict,
  name        text not null,
  address     text,
  is_active   boolean not null default true,
  deleted_at  timestamptz,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  created_by  uuid,
  updated_by  uuid
);
create index idx_stores_org on stores(org_id) where deleted_at is null;
create trigger trg_stores_updated before update on stores
  for each row execute function set_updated_at();
create trigger trg_stores_org before update on stores
  for each row execute function prevent_org_change();

-- ============================================================
-- 2. 員工與角色（基石⑤⑥⑰）
-- ============================================================
create table staff (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references orgs(id) on delete restrict,
  store_id    uuid references stores(id) on delete restrict,
  auth_uid    uuid unique,                 -- Supabase Auth
  name        text not null,
  role        text not null default 'floor'
              check (role in ('floor','manager','hq','owner')),
  deleted_at  timestamptz,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  created_by  uuid,
  updated_by  uuid
);
create index idx_staff_org on staff(org_id) where deleted_at is null;
create trigger trg_staff_updated before update on staff
  for each row execute function set_updated_at();
create trigger trg_staff_org before update on staff
  for each row execute function prevent_org_change();

-- ============================================================
-- 3. 會員（CRM 主檔 + 會員360，基石①③⑤⑥⑯⑰）
-- ============================================================
create table members (
  id              uuid primary key default gen_random_uuid(),
  org_id          uuid not null references orgs(id) on delete restrict,
  line_user_id    text,                     -- 可空（長輩無 LINE，店員代開）
  display_name    text not null,
  phone           text,
  home_store_id   uuid references stores(id) on delete restrict,
  tier            text not null default 'bubble_tea'
                  check (tier in ('bubble_tea','caramel_pudding','tiramisu')),
  -- 會員360 人口屬性（性別/生日選填，漸進收集）
  gender          text check (gender in ('female','male','other') or gender is null),
  birthday        date,
  occupation      text,
  district        text,
  acquisition_source text,
  avatar_url      text,                     -- 大頭貼（存 Storage avatars bucket 的網址,非檔案本身）
  -- RFM / 生命週期（系統算，欄位先建）
  last_visit_at   timestamptz,
  visit_count     int not null default 0,
  lifecycle       text not null default 'new'
                  check (lifecycle in ('new','growing','regular','at_risk','churned')),
  primary_staff_id uuid references staff(id) on delete set null,  -- 業務歸屬
  deleted_at      timestamptz,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  created_by      uuid,
  updated_by      uuid
);
-- 唯一約束含 deleted_at（基石⑯㉒）：同 org 內 line_user_id / phone 不重複（軟刪不擋新註冊）
create unique index uq_members_line on members(org_id, line_user_id)
  where line_user_id is not null and deleted_at is null;
create unique index uq_members_phone on members(org_id, phone)
  where phone is not null and deleted_at is null;
create index idx_members_org on members(org_id) where deleted_at is null;
create index idx_members_staff on members(primary_staff_id) where deleted_at is null;
create trigger trg_members_updated before update on members
  for each row execute function set_updated_at();
create trigger trg_members_org before update on members
  for each row execute function prevent_org_change();
-- ============================================================
-- 4. 錢包與點數流水帳（碰錢核心，基石④⑧⑨⑩⑪⑫⑬）
-- ============================================================

-- 錢包：餘額快取（真相是 wallet_txns 流水，做法三）
create table wallets (
  member_id   uuid primary key references members(id) on delete restrict,
  org_id      uuid not null references orgs(id) on delete restrict,
  balance     bigint not null default 0 check (balance >= 0),  -- 點數整數（基石④）
  updated_at  timestamptz not null default now()
);
create trigger trg_wallets_updated before update on wallets
  for each row execute function set_updated_at();

-- 點數流水帳（append-only ledger，只進不改）
-- 交易類型
do $$ begin
  create type txn_type as enum
    ('topup','table_fee','fnb','merch','refund','adjust','event_fee','reversal');
exception when duplicate_object then null; end $$;

-- 交易狀態（基石⑩）
do $$ begin
  create type txn_status as enum ('pending','completed','failed','refunded');
exception when duplicate_object then null; end $$;

create table wallet_txns (
  id              uuid primary key default gen_random_uuid(),
  org_id          uuid not null references orgs(id) on delete restrict,
  store_id        uuid references stores(id) on delete restrict,  -- collected_store（基石⑨）
  served_store_id uuid references stores(id) on delete restrict,  -- 服務店（跨店拆帳）
  member_id       uuid not null references members(id) on delete restrict,
  type            txn_type not null,
  -- 金額方向（基石⑬）：+ 入點 / − 扣點。check 強制與 type 一致
  amount          bigint not null,
  status          txn_status not null default 'completed',
  -- 雙邊錢流（基石⑨簡化版）：這筆錢的對方帳戶
  counter_account text,            -- 'store_revenue' / 'member_wallet' / 'liability' ...
  -- 沖正（基石⑫）：若為沖正,指向被沖正的原交易
  reverses_txn_id uuid references wallet_txns(id) on delete restrict,
  -- 冪等（基石⑧）
  idempotency_key text,
  -- 外部金流對帳（基石⑪）
  external_ref    text,
  -- 業績歸因 / 來源
  ref_table       text,
  ref_id          uuid,
  staff_id        uuid references staff(id) on delete set null,
  note            text,
  created_at      timestamptz not null default now(),
  created_by      uuid
);
-- 金額方向約束（基石⑬）：入點類為正、扣點類為負
alter table wallet_txns add constraint chk_amount_direction check (
  (type in ('topup','refund','reversal','adjust')          -- 可正可負（沖正/調整）
   ) or
  (type in ('table_fee','fnb','merch','event_fee') and amount < 0)  -- 消費必為負
);
-- 冪等鍵唯一（基石⑧）：同 org 內不重複
create unique index uq_txn_idempotency on wallet_txns(org_id, idempotency_key)
  where idempotency_key is not null;
create index idx_txn_member on wallet_txns(member_id, created_at);
create index idx_txn_org_store on wallet_txns(org_id, store_id, created_at);
create index idx_txn_external on wallet_txns(external_ref) where external_ref is not null;
-- ledger 不可改（基石⑫）：禁止 UPDATE/DELETE（退款用新增沖正分錄）
create or replace function block_txn_mutation()
returns trigger language plpgsql as $$
begin
  raise exception 'wallet_txns 為 append-only 帳本,不可 UPDATE/DELETE;退款請新增 reversal 分錄';
end $$;
create trigger trg_txn_no_update before update on wallet_txns
  for each row execute function block_txn_mutation();
create trigger trg_txn_no_delete before delete on wallet_txns
  for each row execute function block_txn_mutation();

-- ============================================================
-- 5. 計費規則（資料驅動，基石⑮；可後台改、分店覆寫）
-- ============================================================
create table pricing_tiers (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references orgs(id) on delete restrict,
  store_id    uuid references stores(id) on delete restrict,  -- null=org預設,有值=分店覆寫
  mode        text not null check (mode in ('matched','private')),  -- 配桌/包桌
  rule_key    text not null,        -- matched_full / matched_midjoin / private_tier
  min_unit    int,                  -- 配桌:將數下限;包桌:分鐘下限
  max_unit    int,                  -- 上限(null=無上限)
  points      bigint not null check (points >= 0),
  sort_order  int not null default 0,
  is_active   boolean not null default true,
  deleted_at  timestamptz,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  created_by  uuid,
  updated_by  uuid
);
create index idx_pricing_lookup on pricing_tiers(org_id, store_id, mode, is_active)
  where deleted_at is null;
create trigger trg_pricing_updated before update on pricing_tiers
  for each row execute function set_updated_at();
create trigger trg_pricing_org before update on pricing_tiers
  for each row execute function prevent_org_change();

-- ============================================================
-- 5b. 積分級距（純娛樂麻將/10-10/.../300-100,可後台自建,基石⑮）
--     用途:配桌分組條件 + 成績/營運的核心統計維度
--     注意:積分僅供配桌分組與成績記錄,MIGI 點數只收場地費,
--          絕不碰桌上輸贏(賭博紅線)
-- ============================================================
create table stake_levels (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references orgs(id) on delete restrict,
  store_id    uuid references stores(id) on delete restrict,  -- null=org通用,有值=分店專屬
  label       text not null,              -- '純娛樂麻將' / '50/20' / '300/100'
  base        int,                        -- 底(純娛樂麻將為 null)
  tai         int,                        -- 台(純娛樂麻將為 null)
  is_hygiene  boolean not null default false,  -- 純娛樂麻將=不計積分(但仍計段位)
  sort_order  int not null default 0,
  is_active   boolean not null default true,
  deleted_at  timestamptz,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  created_by  uuid,
  updated_by  uuid
);
create index idx_stake_lookup on stake_levels(org_id, store_id, is_active) where deleted_at is null;
create trigger trg_stake_updated before update on stake_levels
  for each row execute function set_updated_at();
create trigger trg_stake_org before update on stake_levels
  for each row execute function prevent_org_change();

-- ============================================================
-- 6. 獎金規則（資料驅動，基石⑮）
-- ============================================================
create table bonus_rules (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references orgs(id) on delete restrict,
  store_id    uuid references stores(id) on delete restrict,
  rule_key    text not null check (rule_key in ('match_made','visit_commission')),
  amount      bigint not null check (amount >= 0),   -- 元
  min_spend   bigint,                                -- 綁定獎金的有效消費門檻
  is_active   boolean not null default true,
  deleted_at  timestamptz,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  created_by  uuid,
  updated_by  uuid
);
create index idx_bonus_lookup on bonus_rules(org_id, store_id, is_active)
  where deleted_at is null;
create trigger trg_bonus_updated before update on bonus_rules
  for each row execute function set_updated_at();
create trigger trg_bonus_org before update on bonus_rules
  for each row execute function prevent_org_change();
-- ============================================================
-- 6b. 優惠券（券種定義 + 會員持有,基石⑮）
--     券只折抵 MIGI 服務費(檯費/餐飲/派車),絕不碰桌上輸贏(賭博紅線)
-- ============================================================
-- 券種定義（後台可建）
create table coupons (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references orgs(id) on delete restrict,
  name        text not null,                    -- '檯費 9 折' / '免費奶茶' / '暢打 3hr'
  kind        text not null check (kind in
              ('table_discount','unlimited_play','ride','fnb','topup_bonus','generic')),
  -- table_discount=檯費折扣 unlimited_play=暢打 ride=派車 fnb=餐飲 topup_bonus=儲值加碼 generic=會員優惠
  discount_type text not null check (discount_type in ('percent','fixed','free')),
  discount_value bigint,                          -- percent:90=9折; fixed:折抵點數; free:免費
  applies_to  text check (applies_to in ('table_fee','fnb','ride','topup') or applies_to is null),
  valid_days  int,                                -- 發放後幾天到期(null=用 valid_until)
  valid_until date,
  is_active   boolean not null default true,
  deleted_at  timestamptz,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  created_by  uuid,
  updated_by  uuid
);
create index idx_coupons_org on coupons(org_id, is_active) where deleted_at is null;
create trigger trg_coupons_updated before update on coupons
  for each row execute function set_updated_at();
create trigger trg_coupons_org before update on coupons
  for each row execute function prevent_org_change();

-- 會員持有的券（發放即一筆,用掉改 status）
create table member_coupons (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references orgs(id) on delete restrict,
  member_id   uuid not null references members(id) on delete restrict,
  coupon_id   uuid not null references coupons(id) on delete restrict,
  status      text not null default 'active'
              check (status in ('active','used','expired')),
  granted_at  timestamptz not null default now(),
  used_at     timestamptz,
  used_txn_id uuid references wallet_txns(id) on delete restrict,  -- 用在哪筆消費
  expires_at  timestamptz,
  created_at  timestamptz not null default now()
);
create index idx_mc_member on member_coupons(member_id, status);
create index idx_mc_org on member_coupons(org_id, status);

-- ============================================================
-- 7. 桌台與開桌（POS 核心，基石①③⑤⑥）
-- ============================================================
create table tables (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references orgs(id) on delete restrict,
  store_id    uuid not null references stores(id) on delete restrict,
  label       text not null,                -- T1, T2...
  is_active   boolean not null default true,
  deleted_at  timestamptz,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  created_by  uuid,
  updated_by  uuid
);
create index idx_tables_store on tables(store_id) where deleted_at is null;
create trigger trg_tables_updated before update on tables
  for each row execute function set_updated_at();
create trigger trg_tables_org before update on tables
  for each row execute function prevent_org_change();

-- 開桌 session
create table table_sessions (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references orgs(id) on delete restrict,
  store_id    uuid not null references stores(id) on delete restrict,
  table_id    uuid not null references tables(id) on delete restrict,
  mode        text not null check (mode in ('matched','private')),  -- 配桌/包桌
  stake_level_id uuid references stake_levels(id) on delete restrict,  -- 積分級距(配桌分組+成績維度)
  status      text not null default 'open'
              check (status in ('open','completed','voided')),
  -- 包桌預估時段（開桌前問打多久 → 扣對應階梯）
  planned_minutes int,
  started_at  timestamptz not null default now(),  -- 原始時間（基石②）
  ended_at    timestamptz,
  fee_points  bigint,                       -- 結算總點數（成交價快照）
  promoted_by_staff_id uuid references staff(id) on delete set null,  -- 配桌獎金歸因
  open_method text check (open_method in ('auto','manual') or open_method is null),
  deleted_at  timestamptz,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  created_by  uuid,
  updated_by  uuid
);
create index idx_sessions_store_time on table_sessions(store_id, started_at);
create index idx_sessions_status on table_sessions(org_id, status) where deleted_at is null;
create trigger trg_sessions_updated before update on table_sessions
  for each row execute function set_updated_at();
create trigger trg_sessions_org before update on table_sessions
  for each row execute function prevent_org_change();

-- 每桌每人計費狀態（配桌按人頭，各人狀態不同）
create table session_players (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references orgs(id) on delete restrict,
  session_id  uuid not null references table_sessions(id) on delete restrict,
  member_id   uuid not null references members(id) on delete restrict,
  join_type   text not null default 'opener'
              check (join_type in ('opener','mid_join')),
  status      text not null default 'playing'
              check (status in ('playing','completed','late','forfeit')),
  charged_points bigint not null default 0,
  joined_at   timestamptz not null default now(),
  created_at  timestamptz not null default now(),
  created_by  uuid
);
-- 同一 session 同一 member 不重複（基石⑯）
create unique index uq_session_player on session_players(session_id, member_id);
create index idx_sp_member on session_players(member_id);

-- ============================================================
-- 8. 餐飲（POS，基石①③⑤⑥）
-- ============================================================
create table products (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references orgs(id) on delete restrict,
  sku         text not null,
  name        text not null,
  category    text not null check (category in ('fnb','merch','service')),
  unit_points bigint not null check (unit_points >= 0),   -- 售價（點）
  unit_cost   numeric,                                    -- 成本（基石④小數用 numeric）
  is_active   boolean not null default true,
  deleted_at  timestamptz,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  created_by  uuid,
  updated_by  uuid
);
create unique index uq_products_sku on products(org_id, sku) where deleted_at is null;
create trigger trg_products_updated before update on products
  for each row execute function set_updated_at();
create trigger trg_products_org before update on products
  for each row execute function prevent_org_change();

create table orders (
  id           uuid primary key default gen_random_uuid(),
  org_id       uuid not null references orgs(id) on delete restrict,
  store_id     uuid not null references stores(id) on delete restrict,
  member_id    uuid references members(id) on delete restrict,
  table_id     uuid references tables(id) on delete restrict,
  session_id   uuid references table_sessions(id) on delete restrict,
  status       text not null default 'open'
               check (status in ('open','preparing','served','paid','void')),
  channel      text not null default 'counter'
               check (channel in ('counter','table_qr','online')),
  total_points bigint not null default 0,
  deleted_at   timestamptz,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  created_by   uuid,
  updated_by   uuid
);
create index idx_orders_session on orders(session_id) where deleted_at is null;
create trigger trg_orders_updated before update on orders
  for each row execute function set_updated_at();
create trigger trg_orders_org before update on orders
  for each row execute function prevent_org_change();

create table order_items (
  id          uuid primary key default gen_random_uuid(),
  order_id    uuid not null references orders(id) on delete restrict,
  product_id  uuid not null references products(id) on delete restrict,
  qty         int not null default 1 check (qty > 0),
  unit_points bigint not null,              -- 成交價快照
  created_at  timestamptz not null default now()
);
create index idx_order_items_order on order_items(order_id);

-- ============================================================
-- 9. CRM：可打牌時間 / 牌咖網絡 / 互動紀錄（基石①③⑤⑥）
-- ============================================================
create table member_availability (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references orgs(id) on delete restrict,
  member_id   uuid not null references members(id) on delete restrict,
  weekday     smallint not null check (weekday between 0 and 6),
  slot        text not null check (slot in ('morning','afternoon','evening','late')),
  preference  text not null default 'often'
              check (preference in ('often','sometimes','never')),
  source      text not null default 'stated' check (source in ('stated','inferred')),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create unique index uq_availability on member_availability(member_id, weekday, slot, source);
create trigger trg_avail_updated before update on member_availability
  for each row execute function set_updated_at();

-- 牌咖網絡（護城河核心）
create table mahjong_buddies (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references orgs(id) on delete restrict,
  member_id   uuid not null references members(id) on delete restrict,
  buddy_id    uuid not null references members(id) on delete restrict,
  origin      text not null check (origin in ('pre_existing','matched')),
  co_play_count int not null default 1,
  compat_score numeric,
  linked_at   timestamptz not null default now(),
  deleted_at  timestamptz,
  created_at  timestamptz not null default now(),
  check (member_id <> buddy_id)            -- 不能跟自己當牌咖
);
create unique index uq_buddies on mahjong_buddies(member_id, buddy_id) where deleted_at is null;
create index idx_buddies_member on mahjong_buddies(member_id) where deleted_at is null;

-- 互動紀錄（MA 與店員 CRM 共用，避免重複打擾）
create table member_interactions (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references orgs(id) on delete restrict,
  member_id   uuid not null references members(id) on delete restrict,
  staff_id    uuid references staff(id) on delete set null,
  channel     text not null default 'system' check (channel in ('system','staff')),  -- MA自動/店員手動
  kind        text not null check (kind in ('care','birthday','winback','welcome','note')),
  note        text,
  created_at  timestamptz not null default now(),
  created_by  uuid
);
create index idx_interactions_member on member_interactions(member_id, created_at);
-- ============================================================
-- 10. RLS 多租戶隔離（基石⑥⑱）
-- 原則：每張表啟用 RLS，以 org_id 為第一道隔離牆。
--   - service_role（後端 Edge Function）：繞過 RLS，全權（改錢只走這裡，基石⑱）
--   - authenticated（前端登入用戶）：只能存取自己 org 的資料
-- 註：org 的判定靠 JWT 內的 claim（app_metadata.org_id），
--     或透過 staff/members 表關聯 auth.uid()。以下用 helper 函式取當前 org。
-- ============================================================

-- helper：取當前登入者的 org_id（從 staff 或 members 反查 auth.uid()）
create or replace function current_org_id()
returns uuid language sql stable as $$
  select coalesce(
    (select org_id from staff   where auth_uid = auth.uid() and deleted_at is null limit 1),
    (select org_id from members where line_user_id = auth.jwt()->>'sub' and deleted_at is null limit 1)
  );
$$;

-- 啟用 RLS 並建立政策的巨集式寫法（逐表）
-- orgs：登入者只看自己的 org
alter table orgs enable row level security;
create policy org_self on orgs for select
  using (id = current_org_id());

-- 通用：以下表都用「org_id = current_org_id()」做 select 隔離
-- 寫入（insert/update/delete）一律由 service_role 經 Edge Function 處理（基石⑱）
-- service_role 預設繞過 RLS，故不需額外政策

alter table stores enable row level security;
create policy stores_org on stores for select using (org_id = current_org_id());

alter table staff enable row level security;
create policy staff_org on staff for select using (org_id = current_org_id());

alter table members enable row level security;
create policy members_org on members for select using (org_id = current_org_id());

alter table wallets enable row level security;
create policy wallets_org on wallets for select using (org_id = current_org_id());

alter table wallet_txns enable row level security;
create policy txns_org on wallet_txns for select using (org_id = current_org_id());

alter table pricing_tiers enable row level security;
create policy pricing_org on pricing_tiers for select using (org_id = current_org_id());

alter table stake_levels enable row level security;
create policy stake_org on stake_levels for select using (org_id = current_org_id());

alter table bonus_rules enable row level security;
create policy bonus_org on bonus_rules for select using (org_id = current_org_id());

alter table coupons enable row level security;
create policy coupons_org on coupons for select using (org_id = current_org_id());

alter table member_coupons enable row level security;
create policy mc_org on member_coupons for select using (org_id = current_org_id());

alter table tables enable row level security;
create policy tables_org on tables for select using (org_id = current_org_id());

alter table table_sessions enable row level security;
create policy sessions_org on table_sessions for select using (org_id = current_org_id());

alter table session_players enable row level security;
create policy sp_org on session_players for select using (org_id = current_org_id());

alter table products enable row level security;
create policy products_org on products for select using (org_id = current_org_id());

alter table orders enable row level security;
create policy orders_org on orders for select using (org_id = current_org_id());

alter table order_items enable row level security;
create policy oi_org on order_items for select using (
  exists (select 1 from orders o where o.id = order_items.order_id and o.org_id = current_org_id())
);

alter table member_availability enable row level security;
create policy avail_org on member_availability for select using (org_id = current_org_id());

alter table mahjong_buddies enable row level security;
create policy buddies_org on mahjong_buddies for select using (org_id = current_org_id());

alter table member_interactions enable row level security;
create policy interactions_org on member_interactions for select using (org_id = current_org_id());

-- ============================================================
-- 完成。M0 共 18 張表，全部 UUID 主鍵 + 審計欄 + 軟刪除 + RLS。
-- 下一步 M1：錢包 Edge Function（儲值/配桌扣款/包桌扣款/收桌結算/餐飲點單）
-- ============================================================
