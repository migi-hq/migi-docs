/* ============================================================
   MIGI 資料庫完整結構 baseline
   產生日期：2026-09-11
   基準：`sql/applied/` 有 209 個 `.sql`，最後一份是
        `2026-09-11_消費明細帶規格.sql`

   🔴 **這份是機器產生的，不要手改。** 要更新就重跑一次：
      ① Supabase SQL Editor 執行 `sql/checks/匯出完整結構baseline.sql`
      ② 右上角**下載 CSV**（不要全選複製，DDL 裡有換行與引號）
      ③ `python docs/_資產/baseline_csv2sql.py <下載的.csv>`

   ── 怎麼判斷它過期了（不需要連資料庫）──────────────
   比對上面那個檔案數與現在的 `sql/applied/`。不一樣就是過期。
   ⚠ 但它**只能證明「確定過期」，不能證明「還是新的」** ——
     直接在 Dashboard 手改、沒留檔的東西抓不到，
     而那不是假設：`uq_members_line_user` 就是那樣來的。
   → 真要改 schema 時**硬規則 3 永遠成立**：先撈線上版。

   ── 這份不含什麼 ─────────────────────────────────
   種子資料／Storage bucket 與 policy／pg_cron 排程／
   Edge Functions／auth schema。
   ⇒ **重建 = 這份 baseline ＋ 之後累加的 `applied/`**，
     而 `applied/` 記的是「為什麼」，這份記的是「現在長什麼樣」。
     兩份都要。
   ============================================================ */

-- [1.0] btree_gist
create extension if not exists btree_gist;

-- [1.0] pg_cron
create extension if not exists pg_cron;

-- [1.0] pg_stat_statements
create extension if not exists pg_stat_statements;

-- [1.0] pgcrypto
create extension if not exists pgcrypto;

-- [1.0] supabase_vault
create extension if not exists supabase_vault;

-- [1.0] uuid-ossp
create extension if not exists "uuid-ossp";

-- [2.0] txn_status
create type txn_status as enum ('pending', 'completed', 'failed', 'refunded');

-- [2.0] txn_type
create type txn_type as enum ('topup', 'table_fee', 'fnb', 'merch', 'refund', 'adjust', 'event_fee', 'reversal', 'spend');

-- [3.0] app_events
create table app_events (
  id uuid default gen_random_uuid() not null,
  org_id uuid not null,
  member_id uuid,
  event text not null,
  props jsonb default '{}'::jsonb not null,
  client_ts timestamp with time zone,
  created_at timestamp with time zone default now() not null,
  is_test boolean default false not null,
  store_id uuid
);

-- [3.0] app_notifications
create table app_notifications (
  id uuid default gen_random_uuid() not null,
  org_id uuid not null,
  member_id uuid not null,
  type text not null,
  payload jsonb default '{}'::jsonb not null,
  ref_id uuid,
  read_at timestamp with time zone,
  created_at timestamp with time zone default now() not null
);

-- [3.0] bonus_rules
create table bonus_rules (
  id uuid default gen_random_uuid() not null,
  org_id uuid not null,
  store_id uuid,
  rule_key text not null,
  amount bigint not null,
  min_spend bigint,
  is_active boolean default true not null,
  deleted_at timestamp with time zone,
  created_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone default now() not null,
  created_by uuid,
  updated_by uuid
);

-- [3.0] buddy_invites
create table buddy_invites (
  id uuid default gen_random_uuid() not null,
  org_id uuid not null,
  inviter_id uuid not null,
  invitee_id uuid not null,
  status text default 'pending'::text not null,
  responded_at timestamp with time zone,
  created_at timestamp with time zone default now() not null
);

-- [3.0] coupons
create table coupons (
  id uuid default gen_random_uuid() not null,
  org_id uuid not null,
  name text not null,
  kind text not null,
  discount_type text not null,
  discount_value bigint,
  applies_to text,
  valid_days integer,
  valid_until date,
  is_active boolean default true not null,
  deleted_at timestamp with time zone,
  created_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone default now() not null,
  created_by uuid,
  updated_by uuid,
  min_spend bigint,
  max_discount bigint,
  free_product_id uuid,
  cost_bearer text default 'store'::text not null
);

-- [3.0] doc_counters
create table doc_counters (
  org_id uuid not null,
  store_id uuid not null,
  doc_type text not null,
  doc_date date not null,
  last_no integer default 0 not null
);

-- [3.0] invoices
create table invoices (
  id uuid default gen_random_uuid() not null,
  org_id uuid not null,
  entity_id uuid,
  store_id uuid,
  ref_table text not null,
  ref_id uuid not null,
  kind text default 'invoice'::text not null,
  parent_invoice_id uuid,
  status text default 'pending'::text not null,
  invoice_no text,
  invoice_at timestamp with time zone,
  random_code text,
  period text,
  tax_type text default '1'::text not null,
  tax_rate numeric default 0.05 not null,
  sales_amount bigint not null,
  tax_amount bigint not null,
  total_amount bigint not null,
  buyer_type text default 'B2C'::text not null,
  buyer_tax_id text,
  buyer_title text,
  carrier_type text,
  carrier_no text,
  donate_code text,
  donate_org_name text,
  print_mark boolean default false not null,
  items jsonb default '[]'::jsonb not null,
  void_at timestamp with time zone,
  void_reason text,
  provider text,
  provider_ref text,
  raw jsonb,
  idempotency_key text,
  created_at timestamp with time zone default now() not null,
  created_by uuid
);

-- [3.0] legal_entities
create table legal_entities (
  id uuid default gen_random_uuid() not null,
  org_id uuid not null,
  name text not null,
  tax_id text,
  kind text not null,
  bank_account jsonb,
  is_active boolean default true not null,
  created_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone default now() not null
);

-- [3.0] mahjong_buddies
create table mahjong_buddies (
  id uuid default gen_random_uuid() not null,
  org_id uuid not null,
  member_id uuid not null,
  buddy_id uuid not null,
  origin text not null,
  co_play_count integer default 1 not null,
  compat_score numeric,
  linked_at timestamp with time zone default now() not null,
  deleted_at timestamp with time zone,
  created_at timestamp with time zone default now() not null
);

-- [3.0] match_queue_players
create table match_queue_players (
  id uuid default gen_random_uuid() not null,
  org_id uuid not null,
  queue_id uuid not null,
  member_id uuid not null,
  join_source text,
  joined_at timestamp with time zone default now() not null,
  left_at timestamp with time zone,
  leave_reason text,
  no_show boolean default false not null,
  leave_detail text,
  left_by_staff_id uuid
);

-- [3.0] match_queues
create table match_queues (
  id uuid default gen_random_uuid() not null,
  org_id uuid not null,
  store_id uuid not null,
  stake_level_id uuid not null,
  game_type text default '16張'::text not null,
  rounds text default '2 將'::text not null,
  seats integer default 4 not null,
  prefs jsonb default '{}'::jsonb not null,
  status text default 'waiting'::text not null,
  opened_by uuid,
  play_at timestamp with time zone not null,
  matched_at timestamp with time zone,
  matched_session_id uuid,
  expires_at timestamp with time zone default (now() + '02:00:00'::interval) not null,
  created_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone default now() not null,
  source text default 'member'::text not null,
  tags jsonb default '[]'::jsonb not null,
  recurring_id uuid,
  recurring_freq text,
  flower text,
  open_at timestamp with time zone,
  auto_seat boolean default true not null
);

-- [3.0] member_app_state
create table member_app_state (
  member_id uuid not null,
  org_id uuid not null,
  bear jsonb default '{}'::jsonb not null,
  titles jsonb default '[]'::jsonb not null,
  updated_at timestamp with time zone default now() not null
);

-- [3.0] member_availability
create table member_availability (
  id uuid default gen_random_uuid() not null,
  org_id uuid not null,
  member_id uuid not null,
  weekday smallint not null,
  slot text not null,
  preference text default 'often'::text not null,
  source text default 'stated'::text not null,
  created_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone default now() not null
);

-- [3.0] member_blocks
create table member_blocks (
  id uuid default gen_random_uuid() not null,
  org_id uuid not null,
  blocker_id uuid not null,
  blocked_id uuid not null,
  reason text,
  created_at timestamp with time zone default now() not null
);

-- [3.0] member_coupons
create table member_coupons (
  id uuid default gen_random_uuid() not null,
  org_id uuid not null,
  member_id uuid not null,
  coupon_id uuid not null,
  status text default 'active'::text not null,
  granted_at timestamp with time zone default now() not null,
  used_at timestamp with time zone,
  used_txn_id uuid,
  expires_at timestamp with time zone,
  created_at timestamp with time zone default now() not null,
  code text,
  used_order uuid,
  discounted_amount bigint,
  cost_bearer text
);

-- [3.0] member_interactions
create table member_interactions (
  id uuid default gen_random_uuid() not null,
  org_id uuid not null,
  member_id uuid not null,
  staff_id uuid,
  channel text default 'system'::text not null,
  kind text not null,
  note text,
  created_at timestamp with time zone default now() not null,
  created_by uuid
);

-- [3.0] member_likes
create table member_likes (
  id uuid default gen_random_uuid() not null,
  org_id uuid not null,
  liker_id uuid not null,
  target_id uuid not null,
  session_id uuid,
  created_at timestamp with time zone default now() not null
);

-- [3.0] member_tiers
create table member_tiers (
  code text not null,
  label text not null,
  discount_pct integer default 0 not null,
  threshold_amount bigint,
  sort integer default 0 not null,
  is_active boolean default true not null,
  note text,
  created_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone,
  updated_by uuid
);

-- [3.0] members
create table members (
  id uuid default gen_random_uuid() not null,
  org_id uuid not null,
  line_user_id text,
  display_name text not null,
  phone text,
  home_store_id uuid,
  tier text default 'bubble_tea'::text not null,
  gender text,
  birthday date,
  occupation text,
  district text,
  acquisition_source text,
  avatar_url text,
  last_visit_at timestamp with time zone,
  visit_count integer default 0 not null,
  lifecycle text default 'new'::text not null,
  primary_staff_id uuid,
  deleted_at timestamp with time zone,
  created_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone default now() not null,
  created_by uuid,
  updated_by uuid,
  tier_override text,
  last_app_active_at timestamp with time zone,
  rank text,
  title text default '新手上路'::text not null,
  likes_count integer default 0 not null,
  is_test boolean default false not null,
  about text,
  sched text,
  style jsonb,
  see_score text default '牌咖'::text not null,
  baby_tile jsonb,
  avatar_source text default 'bear'::text not null,
  avatar_photo_path text,
  avatar_photo_at timestamp with time zone,
  avatar_blocked boolean default false not null,
  avatar_removed_count integer default 0 not null,
  inv_type text default 'member'::text not null,
  inv_carrier text,
  inv_donate_code text,
  inv_tax_id text,
  inv_title text,
  avatar_bear text,
  phone_verified_at timestamp with time zone,
  rating integer default 0 not null,
  rating_games integer default 0 not null
);

-- [3.0] order_items
create table order_items (
  id uuid default gen_random_uuid() not null,
  order_id uuid not null,
  product_id uuid not null,
  qty integer default 1 not null,
  created_at timestamp with time zone default now() not null,
  org_id uuid not null,
  name text,
  unit_price bigint not null,
  line_total bigint,
  revenue_type text not null,
  spec text
);

-- [3.0] order_payments
create table order_payments (
  id uuid default gen_random_uuid() not null,
  org_id uuid not null,
  store_id uuid not null,
  order_id uuid not null,
  method text not null,
  amount bigint not null,
  cash_received bigint,
  change_given bigint,
  ref_no text,
  staff_id uuid,
  created_at timestamp with time zone default now() not null
);

-- [3.0] orders
create table orders (
  id uuid default gen_random_uuid() not null,
  org_id uuid not null,
  store_id uuid not null,
  member_id uuid,
  table_id uuid,
  session_id uuid,
  status text default 'open'::text not null,
  channel text default 'counter'::text not null,
  total_points bigint default 0 not null,
  deleted_at timestamp with time zone,
  created_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone default now() not null,
  created_by uuid,
  updated_by uuid,
  order_no text,
  subtotal bigint default 0 not null,
  coupon_discount bigint default 0 not null,
  tier_discount bigint default 0 not null,
  payable bigint default 0 not null,
  points_used bigint default 0 not null,
  cash_due bigint default 0 not null,
  tier_at_order text,
  idempotency_key text,
  wallet_txn_id uuid,
  paid_at timestamp with time zone,
  entity_id uuid,
  is_test boolean default false not null,
  tier_discount_pct integer,
  txn_no text
);

-- [3.0] orgs
create table orgs (
  id uuid default gen_random_uuid() not null,
  name text not null,
  plan text default 'self'::text not null,
  deleted_at timestamp with time zone,
  created_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone default now() not null,
  created_by uuid,
  updated_by uuid,
  live_from timestamp with time zone
);

-- [3.0] phone_otps
create table phone_otps (
  id uuid default gen_random_uuid() not null,
  org_id uuid not null,
  phone text not null,
  code_hash text not null,
  purpose text not null,
  line_user_id text,
  attempts integer default 0 not null,
  sent_at timestamp with time zone default now() not null,
  expires_at timestamp with time zone not null,
  verified_at timestamp with time zone,
  consumed_at timestamp with time zone
);

-- [3.0] pricing_tiers
create table pricing_tiers (
  id uuid default gen_random_uuid() not null,
  org_id uuid not null,
  store_id uuid,
  mode text not null,
  rule_key text not null,
  min_unit integer,
  max_unit integer,
  points bigint not null,
  sort_order integer default 0 not null,
  is_active boolean default true not null,
  deleted_at timestamp with time zone,
  created_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone default now() not null,
  created_by uuid,
  updated_by uuid
);

-- [3.0] product_taxonomy
create table product_taxonomy (
  dimension text not null,
  code text not null,
  label text not null,
  parent_code text,
  sku_prefix text,
  sort integer default 0 not null,
  is_active boolean default true not null,
  note text,
  created_at timestamp with time zone default now() not null,
  default_revenue_type text
);

-- [3.0] products
create table products (
  id uuid default gen_random_uuid() not null,
  org_id uuid not null,
  sku text not null,
  name text not null,
  category text not null,
  unit_price bigint not null,
  unit_cost numeric,
  is_active boolean default true not null,
  deleted_at timestamp with time zone,
  created_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone default now() not null,
  created_by uuid,
  updated_by uuid,
  stock_qty bigint default 0 not null,
  is_available boolean default true not null,
  revenue_type text not null,
  subcategory text,
  tracks_stock boolean default true not null,
  is_system boolean default false not null,
  discountable boolean default true not null,
  spec text
);

-- [3.0] queue_tags
create table queue_tags (
  code text not null,
  label text not null,
  sort_order integer default 0 not null,
  is_active boolean default true not null,
  created_at timestamp with time zone default now() not null
);

-- [3.0] rank_points
create table rank_points (
  band text not null,
  place smallint not null,
  points smallint not null
);

-- [3.0] rank_seasons
create table rank_seasons (
  code text not null,
  org_id uuid not null,
  label text not null,
  starts_at timestamp with time zone not null,
  ends_at timestamp with time zone not null,
  created_at timestamp with time zone default now() not null
);

-- [3.0] rank_sub_levels
create table rank_sub_levels (
  tier_code text not null,
  sub text not null,
  offset_pts integer not null,
  sort integer not null
);

-- [3.0] rank_tiers
create table rank_tiers (
  code text not null,
  label text not null,
  min_rating integer not null,
  auto boolean default true not null,
  sort smallint not null,
  note text,
  band text default 'low'::text not null,
  min_opponents integer
);

-- [3.0] recurring_tables
create table recurring_tables (
  id uuid default gen_random_uuid() not null,
  org_id uuid not null,
  store_id uuid not null,
  weekday integer,
  start_time time without time zone not null,
  stake_level_id uuid not null,
  game_type text default '16張'::text not null,
  rounds text default '2 將'::text not null,
  seats integer default 4 not null,
  enabled boolean default true not null,
  note text,
  created_at timestamp with time zone default now() not null,
  frequency text default 'weekly'::text not null,
  flower text,
  lead_hours integer default 24 not null,
  tags jsonb default '[]'::jsonb not null
);

-- [3.0] season_champions
create table season_champions (
  season text not null,
  org_id uuid not null,
  member_id uuid,
  rating integer,
  awarded_at timestamp with time zone default now() not null
);

-- [3.0] season_standings
create table season_standings (
  org_id uuid not null,
  season text not null,
  member_id uuid not null,
  rating integer not null,
  rank_no integer not null,
  games integer not null,
  recorded_at timestamp with time zone default now() not null
);

-- [3.0] session_players
create table session_players (
  id uuid default gen_random_uuid() not null,
  org_id uuid not null,
  session_id uuid not null,
  member_id uuid not null,
  join_type text default 'opener'::text not null,
  status text default 'playing'::text not null,
  charged_points bigint default 0 not null,
  joined_at timestamp with time zone default now() not null,
  created_at timestamp with time zone default now() not null,
  created_by uuid,
  finish_rank integer,
  score_points integer,
  settled_at timestamp with time zone,
  order_id uuid,
  seat text,
  left_at timestamp with time zone,
  paid_by uuid,
  fee_waived_amount bigint default 0 not null,
  fee_waived_reason text,
  rating_after integer,
  final_score integer
);

-- [3.0] staff
create table staff (
  id uuid default gen_random_uuid() not null,
  org_id uuid not null,
  store_id uuid,
  auth_uid uuid,
  name text not null,
  role text default 'floor'::text not null,
  deleted_at timestamp with time zone,
  created_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone default now() not null,
  created_by uuid,
  updated_by uuid,
  member_id uuid
);

-- [3.0] stake_levels
create table stake_levels (
  id uuid default gen_random_uuid() not null,
  org_id uuid not null,
  store_id uuid,
  label text not null,
  base integer,
  tai integer,
  is_hygiene boolean default false not null,
  sort_order integer default 0 not null,
  is_active boolean default true not null,
  deleted_at timestamp with time zone,
  created_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone default now() not null,
  created_by uuid,
  updated_by uuid
);

-- [3.0] stores
create table stores (
  id uuid default gen_random_uuid() not null,
  org_id uuid not null,
  name text not null,
  address text,
  is_active boolean default true not null,
  deleted_at timestamp with time zone,
  created_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone default now() not null,
  created_by uuid,
  updated_by uuid,
  code text not null,
  city text,
  district text,
  lat numeric(9,6),
  lng numeric(9,6),
  open_time time without time zone,
  close_time time without time zone,
  store_type text,
  is_test boolean default false not null,
  entity_id uuid,
  phone text,
  parking text,
  photos jsonb default '[]'::jsonb not null,
  note text
);

-- [3.0] table_sessions
create table table_sessions (
  id uuid default gen_random_uuid() not null,
  org_id uuid not null,
  store_id uuid not null,
  table_id uuid not null,
  mode text not null,
  stake_level_id uuid,
  status text default 'open'::text not null,
  planned_minutes integer,
  started_at timestamp with time zone default now() not null,
  ended_at timestamp with time zone,
  fee_points bigint,
  promoted_by_staff_id uuid,
  open_method text,
  deleted_at timestamp with time zone,
  created_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone default now() not null,
  created_by uuid,
  updated_by uuid,
  planned_rounds integer,
  opened_by_staff_id uuid,
  activated_at timestamp with time zone,
  idempotency_key text,
  is_test boolean default false not null,
  game_type text,
  flower text
);

-- [3.0] tables
create table tables (
  id uuid default gen_random_uuid() not null,
  org_id uuid not null,
  store_id uuid not null,
  label text not null,
  is_active boolean default true not null,
  deleted_at timestamp with time zone,
  created_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone default now() not null,
  created_by uuid,
  updated_by uuid,
  area text,
  seats integer default 4 not null,
  sort_order integer default 0 not null,
  note text,
  auto_assign boolean default true not null
);

-- [3.0] topup_orders
create table topup_orders (
  id uuid default gen_random_uuid() not null,
  org_id uuid not null,
  store_id uuid not null,
  member_id uuid not null,
  topup_no text,
  points bigint not null,
  bonus_points bigint default 0 not null,
  amount_twd bigint not null,
  pay_method text not null,
  status text default 'paid'::text not null,
  external_ref text,
  idempotency_key text,
  invoice_no text,
  invoice_at timestamp with time zone,
  wallet_txn_id uuid,
  staff_id uuid,
  note text,
  created_at timestamp with time zone default now() not null,
  created_by uuid,
  entity_id uuid,
  held_by_entity uuid,
  session_id uuid,
  cash_received bigint,
  change_given bigint,
  txn_no text
);

-- [3.0] topup_plans
create table topup_plans (
  id uuid default gen_random_uuid() not null,
  org_id uuid not null,
  store_id uuid,
  min_amount bigint not null,
  bonus_points bigint default 0 not null,
  is_quick boolean default false not null,
  sort_order integer default 0 not null,
  is_active boolean default true not null,
  created_at timestamp with time zone default now() not null
);

-- [3.0] wallet_balance_audit
create table wallet_balance_audit (
  id bigint default nextval('wallet_balance_audit_id_seq'::regclass) not null,
  member_id uuid not null,
  org_id uuid not null,
  old_balance bigint not null,
  new_balance bigint not null,
  delta bigint not null,
  txn_sum bigint,
  is_synced boolean,
  db_user text,
  changed_at timestamp with time zone default now() not null
);

-- [3.0] wallet_txns
create table wallet_txns (
  id uuid default gen_random_uuid() not null,
  org_id uuid not null,
  store_id uuid,
  served_store_id uuid,
  member_id uuid not null,
  type txn_type not null,
  amount bigint not null,
  status txn_status default 'completed'::txn_status not null,
  counter_account text,
  reverses_txn_id uuid,
  idempotency_key text,
  external_ref text,
  ref_table text,
  ref_id uuid,
  staff_id uuid,
  note text,
  created_at timestamp with time zone default now() not null,
  created_by uuid
);

-- [3.0] wallets
create table wallets (
  member_id uuid not null,
  org_id uuid not null,
  balance bigint default 0 not null,
  updated_at timestamp with time zone default now() not null
);

-- [4.1] app_events.app_events_pkey
alter table app_events add constraint app_events_pkey PRIMARY KEY (id);

-- [4.1] app_notifications.app_notifications_pkey
alter table app_notifications add constraint app_notifications_pkey PRIMARY KEY (id);

-- [4.1] bonus_rules.bonus_rules_pkey
alter table bonus_rules add constraint bonus_rules_pkey PRIMARY KEY (id);

-- [4.1] buddy_invites.buddy_invites_pkey
alter table buddy_invites add constraint buddy_invites_pkey PRIMARY KEY (id);

-- [4.1] coupons.coupons_pkey
alter table coupons add constraint coupons_pkey PRIMARY KEY (id);

-- [4.1] doc_counters.doc_counters_pkey
alter table doc_counters add constraint doc_counters_pkey PRIMARY KEY (org_id, store_id, doc_type, doc_date);

-- [4.1] invoices.invoices_pkey
alter table invoices add constraint invoices_pkey PRIMARY KEY (id);

-- [4.1] legal_entities.legal_entities_pkey
alter table legal_entities add constraint legal_entities_pkey PRIMARY KEY (id);

-- [4.1] mahjong_buddies.mahjong_buddies_pkey
alter table mahjong_buddies add constraint mahjong_buddies_pkey PRIMARY KEY (id);

-- [4.1] match_queue_players.match_queue_players_pkey
alter table match_queue_players add constraint match_queue_players_pkey PRIMARY KEY (id);

-- [4.1] match_queues.match_queues_pkey
alter table match_queues add constraint match_queues_pkey PRIMARY KEY (id);

-- [4.1] member_app_state.member_app_state_pkey
alter table member_app_state add constraint member_app_state_pkey PRIMARY KEY (member_id);

-- [4.1] member_availability.member_availability_pkey
alter table member_availability add constraint member_availability_pkey PRIMARY KEY (id);

-- [4.1] member_blocks.member_blocks_pkey
alter table member_blocks add constraint member_blocks_pkey PRIMARY KEY (id);

-- [4.1] member_coupons.member_coupons_pkey
alter table member_coupons add constraint member_coupons_pkey PRIMARY KEY (id);

-- [4.1] member_interactions.member_interactions_pkey
alter table member_interactions add constraint member_interactions_pkey PRIMARY KEY (id);

-- [4.1] member_likes.member_likes_pkey
alter table member_likes add constraint member_likes_pkey PRIMARY KEY (id);

-- [4.1] member_tiers.member_tiers_pkey
alter table member_tiers add constraint member_tiers_pkey PRIMARY KEY (code);

-- [4.1] members.members_pkey
alter table members add constraint members_pkey PRIMARY KEY (id);

-- [4.1] order_items.order_items_pkey
alter table order_items add constraint order_items_pkey PRIMARY KEY (id);

-- [4.1] order_payments.order_payments_pkey
alter table order_payments add constraint order_payments_pkey PRIMARY KEY (id);

-- [4.1] orders.orders_pkey
alter table orders add constraint orders_pkey PRIMARY KEY (id);

-- [4.1] orgs.orgs_pkey
alter table orgs add constraint orgs_pkey PRIMARY KEY (id);

-- [4.1] phone_otps.phone_otps_pkey
alter table phone_otps add constraint phone_otps_pkey PRIMARY KEY (id);

-- [4.1] pricing_tiers.pricing_tiers_pkey
alter table pricing_tiers add constraint pricing_tiers_pkey PRIMARY KEY (id);

-- [4.1] product_taxonomy.product_taxonomy_pkey
alter table product_taxonomy add constraint product_taxonomy_pkey PRIMARY KEY (dimension, code);

-- [4.1] products.products_pkey
alter table products add constraint products_pkey PRIMARY KEY (id);

-- [4.1] queue_tags.queue_tags_pkey
alter table queue_tags add constraint queue_tags_pkey PRIMARY KEY (code);

-- [4.1] rank_points.rank_points_pkey
alter table rank_points add constraint rank_points_pkey PRIMARY KEY (band, place);

-- [4.1] rank_seasons.rank_seasons_pkey
alter table rank_seasons add constraint rank_seasons_pkey PRIMARY KEY (org_id, code);

-- [4.1] rank_sub_levels.rank_sub_levels_pkey
alter table rank_sub_levels add constraint rank_sub_levels_pkey PRIMARY KEY (tier_code, sub);

-- [4.1] rank_tiers.rank_tiers_pkey
alter table rank_tiers add constraint rank_tiers_pkey PRIMARY KEY (code);

-- [4.1] recurring_tables.recurring_tables_pkey
alter table recurring_tables add constraint recurring_tables_pkey PRIMARY KEY (id);

-- [4.1] season_champions.season_champions_pkey
alter table season_champions add constraint season_champions_pkey PRIMARY KEY (org_id, season);

-- [4.1] season_standings.season_standings_pkey
alter table season_standings add constraint season_standings_pkey PRIMARY KEY (org_id, season, member_id);

-- [4.1] session_players.session_players_pkey
alter table session_players add constraint session_players_pkey PRIMARY KEY (id);

-- [4.1] staff.staff_pkey
alter table staff add constraint staff_pkey PRIMARY KEY (id);

-- [4.1] stake_levels.stake_levels_pkey
alter table stake_levels add constraint stake_levels_pkey PRIMARY KEY (id);

-- [4.1] stores.stores_pkey
alter table stores add constraint stores_pkey PRIMARY KEY (id);

-- [4.1] table_sessions.table_sessions_pkey
alter table table_sessions add constraint table_sessions_pkey PRIMARY KEY (id);

-- [4.1] tables.tables_pkey
alter table tables add constraint tables_pkey PRIMARY KEY (id);

-- [4.1] topup_orders.topup_orders_pkey
alter table topup_orders add constraint topup_orders_pkey PRIMARY KEY (id);

-- [4.1] topup_plans.topup_plans_pkey
alter table topup_plans add constraint topup_plans_pkey PRIMARY KEY (id);

-- [4.1] wallet_balance_audit.wallet_balance_audit_pkey
alter table wallet_balance_audit add constraint wallet_balance_audit_pkey PRIMARY KEY (id);

-- [4.1] wallet_txns.wallet_txns_pkey
alter table wallet_txns add constraint wallet_txns_pkey PRIMARY KEY (id);

-- [4.1] wallets.wallets_pkey
alter table wallets add constraint wallets_pkey PRIMARY KEY (member_id);

-- [4.2] invoices.invoices_idempotency_key_key
alter table invoices add constraint invoices_idempotency_key_key UNIQUE (idempotency_key);

-- [4.2] staff.staff_auth_uid_key
alter table staff add constraint staff_auth_uid_key UNIQUE (auth_uid);

-- [4.3] app_events.app_events_event_check
alter table app_events add constraint app_events_event_check CHECK ((event ~ '^[a-z][a-z0-9_]{0,49}$'::text));

-- [4.3] app_events.app_events_props_check
alter table app_events add constraint app_events_props_check CHECK ((pg_column_size(props) <= 8192));

-- [4.3] app_notifications.app_notifications_type_check
alter table app_notifications add constraint app_notifications_type_check CHECK ((type = ANY (ARRAY['settle'::text, 'buddy_req'::text, 'buddy_ok'::text, 'table_req'::text, 'table_ok'::text, 'system'::text, 'table_expired'::text])));

-- [4.3] bonus_rules.bonus_rules_amount_check
alter table bonus_rules add constraint bonus_rules_amount_check CHECK ((amount >= 0));

-- [4.3] bonus_rules.bonus_rules_rule_key_check
alter table bonus_rules add constraint bonus_rules_rule_key_check CHECK ((rule_key = ANY (ARRAY['match_made'::text, 'visit_commission'::text])));

-- [4.3] buddy_invites.buddy_invites_check
alter table buddy_invites add constraint buddy_invites_check CHECK ((inviter_id <> invitee_id));

-- [4.3] buddy_invites.buddy_invites_status_check
alter table buddy_invites add constraint buddy_invites_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'accepted'::text, 'rejected'::text])));

-- [4.3] coupons.coupons_applies_to_check
alter table coupons add constraint coupons_applies_to_check CHECK (((applies_to = ANY (ARRAY['table_fee'::text, 'fnb'::text, 'ride'::text, 'topup'::text])) OR (applies_to IS NULL)));

-- [4.3] coupons.coupons_cost_bearer_chk
alter table coupons add constraint coupons_cost_bearer_chk CHECK ((cost_bearer = ANY (ARRAY['store'::text, 'hq'::text])));

-- [4.3] coupons.coupons_discount_type_check
alter table coupons add constraint coupons_discount_type_check CHECK ((discount_type = ANY (ARRAY['percent'::text, 'fixed'::text, 'free'::text])));

-- [4.3] coupons.coupons_kind_check
alter table coupons add constraint coupons_kind_check CHECK ((kind = ANY (ARRAY['table_discount'::text, 'unlimited_play'::text, 'ride'::text, 'fnb'::text, 'topup_bonus'::text, 'generic'::text])));

-- [4.3] coupons.coupons_max_discount_check
alter table coupons add constraint coupons_max_discount_check CHECK (((max_discount IS NULL) OR (max_discount >= 0)));

-- [4.3] coupons.coupons_min_spend_check
alter table coupons add constraint coupons_min_spend_check CHECK (((min_spend IS NULL) OR (min_spend >= 0)));

-- [4.3] invoices.invoices_amount_chk
alter table invoices add constraint invoices_amount_chk CHECK (((sales_amount + tax_amount) = total_amount));

-- [4.3] invoices.invoices_kind_chk
alter table invoices add constraint invoices_kind_chk CHECK ((kind = ANY (ARRAY['invoice'::text, 'allowance'::text])));

-- [4.3] invoices.invoices_ref_chk
alter table invoices add constraint invoices_ref_chk CHECK ((ref_table = ANY (ARRAY['orders'::text, 'topup_orders'::text])));

-- [4.3] invoices.invoices_status_chk
alter table invoices add constraint invoices_status_chk CHECK ((status = ANY (ARRAY['pending'::text, 'issued'::text, 'void'::text, 'failed'::text])));

-- [4.3] invoices.invoices_tax_chk
alter table invoices add constraint invoices_tax_chk CHECK ((tax_type = ANY (ARRAY['1'::text, '2'::text, '3'::text, '4'::text, '9'::text])));

-- [4.3] legal_entities.legal_entities_kind_chk
alter table legal_entities add constraint legal_entities_kind_chk CHECK ((kind = ANY (ARRAY['hq'::text, 'franchise'::text, 'licensed'::text])));

-- [4.3] mahjong_buddies.mahjong_buddies_check
alter table mahjong_buddies add constraint mahjong_buddies_check CHECK ((member_id <> buddy_id));

-- [4.3] mahjong_buddies.mahjong_buddies_origin_check
alter table mahjong_buddies add constraint mahjong_buddies_origin_check CHECK ((origin = ANY (ARRAY['pre_existing'::text, 'matched'::text])));

-- [4.3] match_queue_players.match_queue_players_leave_reason_check
alter table match_queue_players add constraint match_queue_players_leave_reason_check CHECK ((leave_reason = ANY (ARRAY['quit'::text, 'cancelled'::text, 'expired'::text, 'switched'::text, 'staff_removed'::text])));

-- [4.3] match_queues.match_queues_flower_chk
alter table match_queues add constraint match_queues_flower_chk CHECK (((flower IS NULL) OR (flower = ANY (ARRAY['無花'::text, '有花'::text])))) NOT VALID;

-- [4.3] match_queues.match_queues_game_type_chk
alter table match_queues add constraint match_queues_game_type_chk CHECK ((game_type = ANY (ARRAY['台麻'::text, '美麻'::text]))) NOT VALID;

-- [4.3] match_queues.match_queues_seats_check
alter table match_queues add constraint match_queues_seats_check CHECK (((seats >= 2) AND (seats <= 4)));

-- [4.3] match_queues.match_queues_source_check
alter table match_queues add constraint match_queues_source_check CHECK ((source = ANY (ARRAY['member'::text, 'pos'::text, 'recurring'::text])));

-- [4.3] match_queues.match_queues_status_check
alter table match_queues add constraint match_queues_status_check CHECK ((status = ANY (ARRAY['waiting'::text, 'matched'::text, 'seated'::text, 'cancelled'::text, 'expired'::text])));

-- [4.3] member_availability.member_availability_preference_check
alter table member_availability add constraint member_availability_preference_check CHECK ((preference = ANY (ARRAY['often'::text, 'sometimes'::text, 'never'::text])));

-- [4.3] member_availability.member_availability_slot_check
alter table member_availability add constraint member_availability_slot_check CHECK ((slot = ANY (ARRAY['morning'::text, 'afternoon'::text, 'evening'::text, 'late'::text])));

-- [4.3] member_availability.member_availability_source_check
alter table member_availability add constraint member_availability_source_check CHECK ((source = ANY (ARRAY['stated'::text, 'inferred'::text])));

-- [4.3] member_availability.member_availability_weekday_check
alter table member_availability add constraint member_availability_weekday_check CHECK (((weekday >= 0) AND (weekday <= 6)));

-- [4.3] member_blocks.member_blocks_check
alter table member_blocks add constraint member_blocks_check CHECK ((blocker_id <> blocked_id));

-- [4.3] member_coupons.member_coupons_cost_bearer_chk
alter table member_coupons add constraint member_coupons_cost_bearer_chk CHECK (((cost_bearer IS NULL) OR (cost_bearer = ANY (ARRAY['store'::text, 'hq'::text]))));

-- [4.3] member_coupons.member_coupons_discounted_amount_check
alter table member_coupons add constraint member_coupons_discounted_amount_check CHECK (((discounted_amount IS NULL) OR (discounted_amount >= 0)));

-- [4.3] member_coupons.member_coupons_status_check
alter table member_coupons add constraint member_coupons_status_check CHECK ((status = ANY (ARRAY['active'::text, 'used'::text, 'expired'::text])));

-- [4.3] member_interactions.member_interactions_channel_check
alter table member_interactions add constraint member_interactions_channel_check CHECK ((channel = ANY (ARRAY['system'::text, 'staff'::text])));

-- [4.3] member_interactions.member_interactions_kind_check
alter table member_interactions add constraint member_interactions_kind_check CHECK ((kind = ANY (ARRAY['care'::text, 'birthday'::text, 'winback'::text, 'welcome'::text, 'note'::text])));

-- [4.3] member_likes.member_likes_check
alter table member_likes add constraint member_likes_check CHECK ((liker_id <> target_id));

-- [4.3] member_tiers.member_tiers_pct_chk
alter table member_tiers add constraint member_tiers_pct_chk CHECK (((discount_pct >= 0) AND (discount_pct <= 100)));

-- [4.3] members.members_avatar_source_chk
alter table members add constraint members_avatar_source_chk CHECK ((avatar_source = ANY (ARRAY['bear'::text, 'photo'::text, 'line'::text])));

-- [4.3] members.members_display_name_chk
alter table members add constraint members_display_name_chk CHECK (((display_name IS NOT NULL) AND (display_name = migi_norm_nickname(display_name)) AND ((char_length(display_name) >= 1) AND (char_length(display_name) <= 12)) AND (display_name !~* '(migi|官方|客服|店長|管理員|系統|admin)'::text)));

-- [4.3] members.members_gender_check
alter table members add constraint members_gender_check CHECK (((gender = ANY (ARRAY['female'::text, 'male'::text, 'other'::text])) OR (gender IS NULL)));

-- [4.3] members.members_inv_type_chk
alter table members add constraint members_inv_type_chk CHECK ((inv_type = ANY (ARRAY['member'::text, 'mobile'::text, 'citizen'::text, 'donate'::text, 'company'::text, 'paper'::text])));

-- [4.3] members.members_lifecycle_check
alter table members add constraint members_lifecycle_check CHECK ((lifecycle = ANY (ARRAY['new'::text, 'growing'::text, 'regular'::text, 'at_risk'::text, 'churned'::text])));

-- [4.3] members.members_phone_chk
alter table members add constraint members_phone_chk CHECK (((phone IS NULL) OR (phone = migi_norm_phone(phone))));

-- [4.3] members.members_sched_chk
alter table members add constraint members_sched_chk CHECK (((sched IS NULL) OR (sched = ANY (ARRAY['早上為主'::text, '下午為主'::text, '晚上為主'::text, '深夜為主'::text, '不一定'::text])))) NOT VALID;

-- [4.3] members.members_see_score_chk
alter table members add constraint members_see_score_chk CHECK ((see_score = ANY (ARRAY['所有人'::text, '牌咖'::text, '只有自己'::text]))) NOT VALID;

-- [4.3] members.members_tier_chk
alter table members add constraint members_tier_chk CHECK (((tier IS NULL) OR (tier = ANY (ARRAY['bubble_tea'::text, 'caramel_pudding'::text, 'tiramisu'::text, 'chef_special'::text]))));

-- [4.3] members.members_tier_override_chk
alter table members add constraint members_tier_override_chk CHECK (((tier_override IS NULL) OR (tier_override = ANY (ARRAY['bubble_tea'::text, 'caramel_pudding'::text, 'tiramisu'::text, 'chef_special'::text]))));

-- [4.3] order_items.order_items_qty_check
alter table order_items add constraint order_items_qty_check CHECK ((qty > 0));

-- [4.3] order_items.order_items_revenue_type_chk
alter table order_items add constraint order_items_revenue_type_chk CHECK (((revenue_type IS NULL) OR (revenue_type = ANY (ARRAY['venue_fee'::text, 'fnb'::text, 'retail'::text, 'other'::text]))));

-- [4.3] order_payments.cash_fields_only_for_cash
alter table order_payments add constraint cash_fields_only_for_cash CHECK ((((method <> 'cash'::text) AND (cash_received IS NULL) AND (change_given IS NULL)) OR ((method = 'cash'::text) AND (cash_received IS NOT NULL) AND (cash_received >= amount) AND (change_given = (cash_received - amount)))));

-- [4.3] order_payments.order_payments_amount_check
alter table order_payments add constraint order_payments_amount_check CHECK ((amount > 0));

-- [4.3] order_payments.order_payments_method_check
alter table order_payments add constraint order_payments_method_check CHECK ((method = ANY (ARRAY['cash'::text, 'credit_card'::text, 'line_pay'::text])));

-- [4.3] orders.orders_amount_balance
alter table orders add constraint orders_amount_balance CHECK (((payable = ((subtotal - coupon_discount) - tier_discount)) AND (cash_due = (payable - points_used)) AND (subtotal >= 0) AND (coupon_discount >= 0) AND (tier_discount >= 0) AND (points_used >= 0) AND (cash_due >= 0)));

-- [4.3] orders.orders_channel_check
alter table orders add constraint orders_channel_check CHECK ((channel = ANY (ARRAY['counter'::text, 'table_qr'::text, 'online'::text])));

-- [4.3] orders.orders_status_check
alter table orders add constraint orders_status_check CHECK ((status = ANY (ARRAY['open'::text, 'preparing'::text, 'served'::text, 'paid'::text, 'void'::text])));

-- [4.3] orgs.orgs_plan_check
alter table orgs add constraint orgs_plan_check CHECK ((plan = ANY (ARRAY['self'::text, 'franchise'::text, 'licensed'::text])));

-- [4.3] phone_otps.phone_otps_purpose_check
alter table phone_otps add constraint phone_otps_purpose_check CHECK ((purpose = ANY (ARRAY['register'::text, 'claim'::text, 'change'::text])));

-- [4.3] pricing_tiers.pricing_tiers_mode_check
alter table pricing_tiers add constraint pricing_tiers_mode_check CHECK ((mode = ANY (ARRAY['matched'::text, 'private'::text])));

-- [4.3] pricing_tiers.pricing_tiers_points_check
alter table pricing_tiers add constraint pricing_tiers_points_check CHECK ((points >= 0));

-- [4.3] product_taxonomy.product_taxonomy_dimension_check
alter table product_taxonomy add constraint product_taxonomy_dimension_check CHECK ((dimension = ANY (ARRAY['category'::text, 'subcategory'::text, 'revenue_type'::text])));

-- [4.3] products.products_category_check
alter table products add constraint products_category_check CHECK ((category = ANY (ARRAY['fnb'::text, 'merch'::text, 'service'::text])));

-- [4.3] products.products_revenue_type_check
alter table products add constraint products_revenue_type_check CHECK (((revenue_type IS NULL) OR (revenue_type = ANY (ARRAY['venue_fee'::text, 'fnb'::text, 'retail'::text, 'other'::text]))));

-- [4.3] products.products_stock_qty_check
alter table products add constraint products_stock_qty_check CHECK ((stock_qty >= 0));

-- [4.3] products.products_unit_price_check
alter table products add constraint products_unit_price_check CHECK ((unit_price >= 0));

-- [4.3] rank_seasons.rank_seasons_range_chk
alter table rank_seasons add constraint rank_seasons_range_chk CHECK ((ends_at > starts_at));

-- [4.3] rank_sub_levels.rank_sub_levels_offset_chk
alter table rank_sub_levels add constraint rank_sub_levels_offset_chk CHECK ((offset_pts >= 0));

-- [4.3] rank_sub_levels.rank_sub_levels_sub_chk
alter table rank_sub_levels add constraint rank_sub_levels_sub_chk CHECK ((sub = ANY (ARRAY['IV'::text, 'III'::text, 'II'::text, 'I'::text])));

-- [4.3] rank_tiers.rank_tiers_band_chk
alter table rank_tiers add constraint rank_tiers_band_chk CHECK ((band = ANY (ARRAY['low'::text, 'mid'::text, 'top'::text])));

-- [4.3] recurring_tables.recurring_lead_hours_chk
alter table recurring_tables add constraint recurring_lead_hours_chk CHECK (((lead_hours >= 1) AND (lead_hours <= 720)));

-- [4.3] recurring_tables.recurring_tables_flower_chk
alter table recurring_tables add constraint recurring_tables_flower_chk CHECK (((flower IS NULL) OR (flower = ANY (ARRAY['無花'::text, '有花'::text])))) NOT VALID;

-- [4.3] recurring_tables.recurring_tables_frequency_check
alter table recurring_tables add constraint recurring_tables_frequency_check CHECK ((frequency = ANY (ARRAY['daily'::text, 'weekly'::text])));

-- [4.3] recurring_tables.recurring_tables_game_type_chk
alter table recurring_tables add constraint recurring_tables_game_type_chk CHECK ((game_type = ANY (ARRAY['台麻'::text, '美麻'::text]))) NOT VALID;

-- [4.3] recurring_tables.recurring_tables_weekday_check
alter table recurring_tables add constraint recurring_tables_weekday_check CHECK (((weekday >= 0) AND (weekday <= 6)));

-- [4.3] session_players.chk_finish_rank
alter table session_players add constraint chk_finish_rank CHECK (((finish_rank IS NULL) OR ((finish_rank >= 1) AND (finish_rank <= 4)))) NOT VALID;

-- [4.3] session_players.session_players_join_type_check
alter table session_players add constraint session_players_join_type_check CHECK ((join_type = ANY (ARRAY['opener'::text, 'mid_join'::text, 'sub'::text])));

-- [4.3] session_players.session_players_status_check
alter table session_players add constraint session_players_status_check CHECK ((status = ANY (ARRAY['playing'::text, 'completed'::text, 'late'::text, 'forfeit'::text])));

-- [4.3] staff.staff_role_check
alter table staff add constraint staff_role_check CHECK ((role = ANY (ARRAY['floor'::text, 'manager'::text, 'hq'::text, 'owner'::text])));

-- [4.3] stores.stores_store_type_chk
alter table stores add constraint stores_store_type_chk CHECK (((store_type IS NULL) OR (store_type = ANY (ARRAY['直營'::text, '加盟'::text, '系統授權'::text, '自家場'::text]))));

-- [4.3] table_sessions.table_sessions_flower_chk
alter table table_sessions add constraint table_sessions_flower_chk CHECK (((flower IS NULL) OR (flower = ANY (ARRAY['無花'::text, '有花'::text]))));

-- [4.3] table_sessions.table_sessions_game_type_chk
alter table table_sessions add constraint table_sessions_game_type_chk CHECK (((game_type IS NULL) OR (game_type = ANY (ARRAY['台麻'::text, '美麻'::text]))));

-- [4.3] table_sessions.table_sessions_mode_check
alter table table_sessions add constraint table_sessions_mode_check CHECK ((mode = ANY (ARRAY['matched'::text, 'private'::text])));

-- [4.3] table_sessions.table_sessions_open_method_check
alter table table_sessions add constraint table_sessions_open_method_check CHECK (((open_method = ANY (ARRAY['auto'::text, 'manual'::text])) OR (open_method IS NULL)));

-- [4.3] table_sessions.table_sessions_status_check
alter table table_sessions add constraint table_sessions_status_check CHECK ((status = ANY (ARRAY['open'::text, 'completed'::text, 'voided'::text])));

-- [4.3] topup_orders.topup_orders_amount_twd_check
alter table topup_orders add constraint topup_orders_amount_twd_check CHECK ((amount_twd > 0));

-- [4.3] topup_orders.topup_orders_bonus_points_check
alter table topup_orders add constraint topup_orders_bonus_points_check CHECK ((bonus_points >= 0));

-- [4.3] topup_orders.topup_orders_pay_method_check
alter table topup_orders add constraint topup_orders_pay_method_check CHECK ((pay_method = ANY (ARRAY['cash'::text, 'credit_card'::text, 'line_pay'::text, 'jko'::text, 'other'::text])));

-- [4.3] topup_orders.topup_orders_points_check
alter table topup_orders add constraint topup_orders_points_check CHECK ((points > 0));

-- [4.3] topup_orders.topup_orders_status_check
alter table topup_orders add constraint topup_orders_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'paid'::text, 'void'::text, 'refunded'::text])));

-- [4.3] topup_plans.topup_plans_bonus_nonneg_chk
alter table topup_plans add constraint topup_plans_bonus_nonneg_chk CHECK ((bonus_points >= 0));

-- [4.3] topup_plans.topup_plans_min_amount_chk
alter table topup_plans add constraint topup_plans_min_amount_chk CHECK ((min_amount >= 0));

-- [4.3] wallet_txns.chk_amount_direction
alter table wallet_txns add constraint chk_amount_direction CHECK (((type = ANY (ARRAY['topup'::txn_type, 'refund'::txn_type, 'reversal'::txn_type, 'adjust'::txn_type])) OR ((type = ANY (ARRAY['table_fee'::txn_type, 'fnb'::txn_type, 'merch'::txn_type, 'event_fee'::txn_type, 'spend'::txn_type])) AND (amount < 0))));

-- [4.3] wallets.wallets_balance_check
alter table wallets add constraint wallets_balance_check CHECK ((balance >= 0));

-- [5.0] app_events.app_events_member_id_fkey
alter table app_events add constraint app_events_member_id_fkey FOREIGN KEY (member_id) REFERENCES members(id) ON DELETE RESTRICT;

-- [5.0] app_events.app_events_org_id_fkey
alter table app_events add constraint app_events_org_id_fkey FOREIGN KEY (org_id) REFERENCES orgs(id) ON DELETE RESTRICT;

-- [5.0] app_events.app_events_store_id_fkey
alter table app_events add constraint app_events_store_id_fkey FOREIGN KEY (store_id) REFERENCES stores(id) ON DELETE RESTRICT;

-- [5.0] app_notifications.app_notifications_member_id_fkey
alter table app_notifications add constraint app_notifications_member_id_fkey FOREIGN KEY (member_id) REFERENCES members(id) ON DELETE RESTRICT;

-- [5.0] app_notifications.app_notifications_org_id_fkey
alter table app_notifications add constraint app_notifications_org_id_fkey FOREIGN KEY (org_id) REFERENCES orgs(id) ON DELETE RESTRICT;

-- [5.0] bonus_rules.bonus_rules_org_id_fkey
alter table bonus_rules add constraint bonus_rules_org_id_fkey FOREIGN KEY (org_id) REFERENCES orgs(id) ON DELETE RESTRICT;

-- [5.0] bonus_rules.bonus_rules_store_id_fkey
alter table bonus_rules add constraint bonus_rules_store_id_fkey FOREIGN KEY (store_id) REFERENCES stores(id) ON DELETE RESTRICT;

-- [5.0] buddy_invites.buddy_invites_invitee_id_fkey
alter table buddy_invites add constraint buddy_invites_invitee_id_fkey FOREIGN KEY (invitee_id) REFERENCES members(id) ON DELETE RESTRICT;

-- [5.0] buddy_invites.buddy_invites_inviter_id_fkey
alter table buddy_invites add constraint buddy_invites_inviter_id_fkey FOREIGN KEY (inviter_id) REFERENCES members(id) ON DELETE RESTRICT;

-- [5.0] buddy_invites.buddy_invites_org_id_fkey
alter table buddy_invites add constraint buddy_invites_org_id_fkey FOREIGN KEY (org_id) REFERENCES orgs(id) ON DELETE RESTRICT;

-- [5.0] coupons.coupons_free_product_id_fkey
alter table coupons add constraint coupons_free_product_id_fkey FOREIGN KEY (free_product_id) REFERENCES products(id) ON DELETE RESTRICT;

-- [5.0] coupons.coupons_org_id_fkey
alter table coupons add constraint coupons_org_id_fkey FOREIGN KEY (org_id) REFERENCES orgs(id) ON DELETE RESTRICT;

-- [5.0] doc_counters.doc_counters_org_id_fkey
alter table doc_counters add constraint doc_counters_org_id_fkey FOREIGN KEY (org_id) REFERENCES orgs(id) ON DELETE RESTRICT;

-- [5.0] doc_counters.doc_counters_store_id_fkey
alter table doc_counters add constraint doc_counters_store_id_fkey FOREIGN KEY (store_id) REFERENCES stores(id) ON DELETE RESTRICT;

-- [5.0] invoices.invoices_entity_id_fkey
alter table invoices add constraint invoices_entity_id_fkey FOREIGN KEY (entity_id) REFERENCES legal_entities(id);

-- [5.0] invoices.invoices_org_id_fkey
alter table invoices add constraint invoices_org_id_fkey FOREIGN KEY (org_id) REFERENCES orgs(id) ON DELETE RESTRICT;

-- [5.0] invoices.invoices_parent_invoice_id_fkey
alter table invoices add constraint invoices_parent_invoice_id_fkey FOREIGN KEY (parent_invoice_id) REFERENCES invoices(id);

-- [5.0] invoices.invoices_store_id_fkey
alter table invoices add constraint invoices_store_id_fkey FOREIGN KEY (store_id) REFERENCES stores(id);

-- [5.0] legal_entities.legal_entities_org_id_fkey
alter table legal_entities add constraint legal_entities_org_id_fkey FOREIGN KEY (org_id) REFERENCES orgs(id) ON DELETE RESTRICT;

-- [5.0] mahjong_buddies.mahjong_buddies_buddy_id_fkey
alter table mahjong_buddies add constraint mahjong_buddies_buddy_id_fkey FOREIGN KEY (buddy_id) REFERENCES members(id) ON DELETE RESTRICT;

-- [5.0] mahjong_buddies.mahjong_buddies_member_id_fkey
alter table mahjong_buddies add constraint mahjong_buddies_member_id_fkey FOREIGN KEY (member_id) REFERENCES members(id) ON DELETE RESTRICT;

-- [5.0] mahjong_buddies.mahjong_buddies_org_id_fkey
alter table mahjong_buddies add constraint mahjong_buddies_org_id_fkey FOREIGN KEY (org_id) REFERENCES orgs(id) ON DELETE RESTRICT;

-- [5.0] match_queue_players.match_queue_players_left_by_staff_id_fkey
alter table match_queue_players add constraint match_queue_players_left_by_staff_id_fkey FOREIGN KEY (left_by_staff_id) REFERENCES staff(id);

-- [5.0] match_queue_players.match_queue_players_member_id_fkey
alter table match_queue_players add constraint match_queue_players_member_id_fkey FOREIGN KEY (member_id) REFERENCES members(id) ON DELETE RESTRICT;

-- [5.0] match_queue_players.match_queue_players_org_id_fkey
alter table match_queue_players add constraint match_queue_players_org_id_fkey FOREIGN KEY (org_id) REFERENCES orgs(id) ON DELETE RESTRICT;

-- [5.0] match_queue_players.match_queue_players_queue_id_fkey
alter table match_queue_players add constraint match_queue_players_queue_id_fkey FOREIGN KEY (queue_id) REFERENCES match_queues(id) ON DELETE RESTRICT;

-- [5.0] match_queues.match_queues_matched_session_id_fkey
alter table match_queues add constraint match_queues_matched_session_id_fkey FOREIGN KEY (matched_session_id) REFERENCES table_sessions(id) ON DELETE RESTRICT;

-- [5.0] match_queues.match_queues_opened_by_fkey
alter table match_queues add constraint match_queues_opened_by_fkey FOREIGN KEY (opened_by) REFERENCES members(id) ON DELETE RESTRICT;

-- [5.0] match_queues.match_queues_org_id_fkey
alter table match_queues add constraint match_queues_org_id_fkey FOREIGN KEY (org_id) REFERENCES orgs(id) ON DELETE RESTRICT;

-- [5.0] match_queues.match_queues_stake_level_id_fkey
alter table match_queues add constraint match_queues_stake_level_id_fkey FOREIGN KEY (stake_level_id) REFERENCES stake_levels(id) ON DELETE RESTRICT;

-- [5.0] match_queues.match_queues_store_id_fkey
alter table match_queues add constraint match_queues_store_id_fkey FOREIGN KEY (store_id) REFERENCES stores(id) ON DELETE RESTRICT;

-- [5.0] member_app_state.member_app_state_member_id_fkey
alter table member_app_state add constraint member_app_state_member_id_fkey FOREIGN KEY (member_id) REFERENCES members(id) ON DELETE RESTRICT;

-- [5.0] member_app_state.member_app_state_org_id_fkey
alter table member_app_state add constraint member_app_state_org_id_fkey FOREIGN KEY (org_id) REFERENCES orgs(id) ON DELETE RESTRICT;

-- [5.0] member_availability.member_availability_member_id_fkey
alter table member_availability add constraint member_availability_member_id_fkey FOREIGN KEY (member_id) REFERENCES members(id) ON DELETE RESTRICT;

-- [5.0] member_availability.member_availability_org_id_fkey
alter table member_availability add constraint member_availability_org_id_fkey FOREIGN KEY (org_id) REFERENCES orgs(id) ON DELETE RESTRICT;

-- [5.0] member_blocks.member_blocks_blocked_id_fkey
alter table member_blocks add constraint member_blocks_blocked_id_fkey FOREIGN KEY (blocked_id) REFERENCES members(id) ON DELETE RESTRICT;

-- [5.0] member_blocks.member_blocks_blocker_id_fkey
alter table member_blocks add constraint member_blocks_blocker_id_fkey FOREIGN KEY (blocker_id) REFERENCES members(id) ON DELETE RESTRICT;

-- [5.0] member_blocks.member_blocks_org_id_fkey
alter table member_blocks add constraint member_blocks_org_id_fkey FOREIGN KEY (org_id) REFERENCES orgs(id) ON DELETE RESTRICT;

-- [5.0] member_coupons.member_coupons_coupon_id_fkey
alter table member_coupons add constraint member_coupons_coupon_id_fkey FOREIGN KEY (coupon_id) REFERENCES coupons(id) ON DELETE RESTRICT;

-- [5.0] member_coupons.member_coupons_member_id_fkey
alter table member_coupons add constraint member_coupons_member_id_fkey FOREIGN KEY (member_id) REFERENCES members(id) ON DELETE RESTRICT;

-- [5.0] member_coupons.member_coupons_org_id_fkey
alter table member_coupons add constraint member_coupons_org_id_fkey FOREIGN KEY (org_id) REFERENCES orgs(id) ON DELETE RESTRICT;

-- [5.0] member_coupons.member_coupons_used_order_fkey
alter table member_coupons add constraint member_coupons_used_order_fkey FOREIGN KEY (used_order) REFERENCES orders(id);

-- [5.0] member_coupons.member_coupons_used_txn_id_fkey
alter table member_coupons add constraint member_coupons_used_txn_id_fkey FOREIGN KEY (used_txn_id) REFERENCES wallet_txns(id) ON DELETE RESTRICT;

-- [5.0] member_interactions.member_interactions_member_id_fkey
alter table member_interactions add constraint member_interactions_member_id_fkey FOREIGN KEY (member_id) REFERENCES members(id) ON DELETE RESTRICT;

-- [5.0] member_interactions.member_interactions_org_id_fkey
alter table member_interactions add constraint member_interactions_org_id_fkey FOREIGN KEY (org_id) REFERENCES orgs(id) ON DELETE RESTRICT;

-- [5.0] member_interactions.member_interactions_staff_id_fkey
alter table member_interactions add constraint member_interactions_staff_id_fkey FOREIGN KEY (staff_id) REFERENCES staff(id) ON DELETE SET NULL;

-- [5.0] member_likes.member_likes_liker_id_fkey
alter table member_likes add constraint member_likes_liker_id_fkey FOREIGN KEY (liker_id) REFERENCES members(id) ON DELETE RESTRICT;

-- [5.0] member_likes.member_likes_org_id_fkey
alter table member_likes add constraint member_likes_org_id_fkey FOREIGN KEY (org_id) REFERENCES orgs(id) ON DELETE RESTRICT;

-- [5.0] member_likes.member_likes_session_id_fkey
alter table member_likes add constraint member_likes_session_id_fkey FOREIGN KEY (session_id) REFERENCES table_sessions(id) ON DELETE RESTRICT;

-- [5.0] member_likes.member_likes_target_id_fkey
alter table member_likes add constraint member_likes_target_id_fkey FOREIGN KEY (target_id) REFERENCES members(id) ON DELETE RESTRICT;

-- [5.0] members.members_home_store_id_fkey
alter table members add constraint members_home_store_id_fkey FOREIGN KEY (home_store_id) REFERENCES stores(id) ON DELETE RESTRICT;

-- [5.0] members.members_org_id_fkey
alter table members add constraint members_org_id_fkey FOREIGN KEY (org_id) REFERENCES orgs(id) ON DELETE RESTRICT;

-- [5.0] members.members_primary_staff_id_fkey
alter table members add constraint members_primary_staff_id_fkey FOREIGN KEY (primary_staff_id) REFERENCES staff(id) ON DELETE SET NULL;

-- [5.0] order_items.order_items_order_id_fkey
alter table order_items add constraint order_items_order_id_fkey FOREIGN KEY (order_id) REFERENCES orders(id) ON DELETE RESTRICT;

-- [5.0] order_items.order_items_product_id_fkey
alter table order_items add constraint order_items_product_id_fkey FOREIGN KEY (product_id) REFERENCES products(id) ON DELETE RESTRICT;

-- [5.0] order_payments.order_payments_order_id_fkey
alter table order_payments add constraint order_payments_order_id_fkey FOREIGN KEY (order_id) REFERENCES orders(id) ON DELETE RESTRICT;

-- [5.0] order_payments.order_payments_store_id_fkey
alter table order_payments add constraint order_payments_store_id_fkey FOREIGN KEY (store_id) REFERENCES stores(id);

-- [5.0] orders.orders_entity_id_fkey
alter table orders add constraint orders_entity_id_fkey FOREIGN KEY (entity_id) REFERENCES legal_entities(id);

-- [5.0] orders.orders_member_id_fkey
alter table orders add constraint orders_member_id_fkey FOREIGN KEY (member_id) REFERENCES members(id) ON DELETE RESTRICT;

-- [5.0] orders.orders_org_id_fkey
alter table orders add constraint orders_org_id_fkey FOREIGN KEY (org_id) REFERENCES orgs(id) ON DELETE RESTRICT;

-- [5.0] orders.orders_session_id_fkey
alter table orders add constraint orders_session_id_fkey FOREIGN KEY (session_id) REFERENCES table_sessions(id) ON DELETE RESTRICT;

-- [5.0] orders.orders_store_id_fkey
alter table orders add constraint orders_store_id_fkey FOREIGN KEY (store_id) REFERENCES stores(id) ON DELETE RESTRICT;

-- [5.0] orders.orders_table_id_fkey
alter table orders add constraint orders_table_id_fkey FOREIGN KEY (table_id) REFERENCES tables(id) ON DELETE RESTRICT;

-- [5.0] phone_otps.phone_otps_org_id_fkey
alter table phone_otps add constraint phone_otps_org_id_fkey FOREIGN KEY (org_id) REFERENCES orgs(id);

-- [5.0] pricing_tiers.pricing_tiers_org_id_fkey
alter table pricing_tiers add constraint pricing_tiers_org_id_fkey FOREIGN KEY (org_id) REFERENCES orgs(id) ON DELETE RESTRICT;

-- [5.0] pricing_tiers.pricing_tiers_store_id_fkey
alter table pricing_tiers add constraint pricing_tiers_store_id_fkey FOREIGN KEY (store_id) REFERENCES stores(id) ON DELETE RESTRICT;

-- [5.0] products.products_org_id_fkey
alter table products add constraint products_org_id_fkey FOREIGN KEY (org_id) REFERENCES orgs(id) ON DELETE RESTRICT;

-- [5.0] rank_seasons.rank_seasons_org_id_fkey
alter table rank_seasons add constraint rank_seasons_org_id_fkey FOREIGN KEY (org_id) REFERENCES orgs(id);

-- [5.0] rank_sub_levels.rank_sub_levels_tier_code_fkey
alter table rank_sub_levels add constraint rank_sub_levels_tier_code_fkey FOREIGN KEY (tier_code) REFERENCES rank_tiers(code) ON DELETE CASCADE;

-- [5.0] season_champions.season_champions_member_id_fkey
alter table season_champions add constraint season_champions_member_id_fkey FOREIGN KEY (member_id) REFERENCES members(id);

-- [5.0] season_champions.season_champions_org_id_fkey
alter table season_champions add constraint season_champions_org_id_fkey FOREIGN KEY (org_id) REFERENCES orgs(id);

-- [5.0] season_champions.season_champions_season_fk
alter table season_champions add constraint season_champions_season_fk FOREIGN KEY (org_id, season) REFERENCES rank_seasons(org_id, code);

-- [5.0] season_standings.season_standings_member_id_fkey
alter table season_standings add constraint season_standings_member_id_fkey FOREIGN KEY (member_id) REFERENCES members(id);

-- [5.0] session_players.session_players_member_id_fkey
alter table session_players add constraint session_players_member_id_fkey FOREIGN KEY (member_id) REFERENCES members(id) ON DELETE RESTRICT;

-- [5.0] session_players.session_players_order_id_fkey
alter table session_players add constraint session_players_order_id_fkey FOREIGN KEY (order_id) REFERENCES orders(id);

-- [5.0] session_players.session_players_org_id_fkey
alter table session_players add constraint session_players_org_id_fkey FOREIGN KEY (org_id) REFERENCES orgs(id) ON DELETE RESTRICT;

-- [5.0] session_players.session_players_paid_by_fkey
alter table session_players add constraint session_players_paid_by_fkey FOREIGN KEY (paid_by) REFERENCES members(id);

-- [5.0] session_players.session_players_session_id_fkey
alter table session_players add constraint session_players_session_id_fkey FOREIGN KEY (session_id) REFERENCES table_sessions(id) ON DELETE RESTRICT;

-- [5.0] staff.staff_member_id_fkey
alter table staff add constraint staff_member_id_fkey FOREIGN KEY (member_id) REFERENCES members(id);

-- [5.0] staff.staff_org_id_fkey
alter table staff add constraint staff_org_id_fkey FOREIGN KEY (org_id) REFERENCES orgs(id) ON DELETE RESTRICT;

-- [5.0] staff.staff_store_id_fkey
alter table staff add constraint staff_store_id_fkey FOREIGN KEY (store_id) REFERENCES stores(id) ON DELETE RESTRICT;

-- [5.0] stake_levels.stake_levels_org_id_fkey
alter table stake_levels add constraint stake_levels_org_id_fkey FOREIGN KEY (org_id) REFERENCES orgs(id) ON DELETE RESTRICT;

-- [5.0] stake_levels.stake_levels_store_id_fkey
alter table stake_levels add constraint stake_levels_store_id_fkey FOREIGN KEY (store_id) REFERENCES stores(id) ON DELETE RESTRICT;

-- [5.0] stores.stores_entity_id_fkey
alter table stores add constraint stores_entity_id_fkey FOREIGN KEY (entity_id) REFERENCES legal_entities(id);

-- [5.0] stores.stores_org_id_fkey
alter table stores add constraint stores_org_id_fkey FOREIGN KEY (org_id) REFERENCES orgs(id) ON DELETE RESTRICT;

-- [5.0] table_sessions.table_sessions_opened_by_staff_id_fkey
alter table table_sessions add constraint table_sessions_opened_by_staff_id_fkey FOREIGN KEY (opened_by_staff_id) REFERENCES staff(id);

-- [5.0] table_sessions.table_sessions_org_id_fkey
alter table table_sessions add constraint table_sessions_org_id_fkey FOREIGN KEY (org_id) REFERENCES orgs(id) ON DELETE RESTRICT;

-- [5.0] table_sessions.table_sessions_promoted_by_staff_id_fkey
alter table table_sessions add constraint table_sessions_promoted_by_staff_id_fkey FOREIGN KEY (promoted_by_staff_id) REFERENCES staff(id) ON DELETE SET NULL;

-- [5.0] table_sessions.table_sessions_stake_level_id_fkey
alter table table_sessions add constraint table_sessions_stake_level_id_fkey FOREIGN KEY (stake_level_id) REFERENCES stake_levels(id) ON DELETE RESTRICT;

-- [5.0] table_sessions.table_sessions_store_id_fkey
alter table table_sessions add constraint table_sessions_store_id_fkey FOREIGN KEY (store_id) REFERENCES stores(id) ON DELETE RESTRICT;

-- [5.0] table_sessions.table_sessions_table_id_fkey
alter table table_sessions add constraint table_sessions_table_id_fkey FOREIGN KEY (table_id) REFERENCES tables(id) ON DELETE RESTRICT;

-- [5.0] tables.tables_org_id_fkey
alter table tables add constraint tables_org_id_fkey FOREIGN KEY (org_id) REFERENCES orgs(id) ON DELETE RESTRICT;

-- [5.0] tables.tables_store_id_fkey
alter table tables add constraint tables_store_id_fkey FOREIGN KEY (store_id) REFERENCES stores(id) ON DELETE RESTRICT;

-- [5.0] topup_orders.topup_orders_entity_id_fkey
alter table topup_orders add constraint topup_orders_entity_id_fkey FOREIGN KEY (entity_id) REFERENCES legal_entities(id);

-- [5.0] topup_orders.topup_orders_held_by_entity_fkey
alter table topup_orders add constraint topup_orders_held_by_entity_fkey FOREIGN KEY (held_by_entity) REFERENCES legal_entities(id);

-- [5.0] topup_orders.topup_orders_member_id_fkey
alter table topup_orders add constraint topup_orders_member_id_fkey FOREIGN KEY (member_id) REFERENCES members(id) ON DELETE RESTRICT;

-- [5.0] topup_orders.topup_orders_org_id_fkey
alter table topup_orders add constraint topup_orders_org_id_fkey FOREIGN KEY (org_id) REFERENCES orgs(id) ON DELETE RESTRICT;

-- [5.0] topup_orders.topup_orders_session_id_fkey
alter table topup_orders add constraint topup_orders_session_id_fkey FOREIGN KEY (session_id) REFERENCES table_sessions(id);

-- [5.0] topup_orders.topup_orders_staff_id_fkey
alter table topup_orders add constraint topup_orders_staff_id_fkey FOREIGN KEY (staff_id) REFERENCES staff(id) ON DELETE SET NULL;

-- [5.0] topup_orders.topup_orders_store_id_fkey
alter table topup_orders add constraint topup_orders_store_id_fkey FOREIGN KEY (store_id) REFERENCES stores(id) ON DELETE RESTRICT;

-- [5.0] topup_orders.topup_orders_wallet_txn_id_fkey
alter table topup_orders add constraint topup_orders_wallet_txn_id_fkey FOREIGN KEY (wallet_txn_id) REFERENCES wallet_txns(id) ON DELETE RESTRICT;

-- [5.0] wallet_txns.wallet_txns_member_id_fkey
alter table wallet_txns add constraint wallet_txns_member_id_fkey FOREIGN KEY (member_id) REFERENCES members(id) ON DELETE RESTRICT;

-- [5.0] wallet_txns.wallet_txns_org_id_fkey
alter table wallet_txns add constraint wallet_txns_org_id_fkey FOREIGN KEY (org_id) REFERENCES orgs(id) ON DELETE RESTRICT;

-- [5.0] wallet_txns.wallet_txns_reverses_txn_id_fkey
alter table wallet_txns add constraint wallet_txns_reverses_txn_id_fkey FOREIGN KEY (reverses_txn_id) REFERENCES wallet_txns(id) ON DELETE RESTRICT;

-- [5.0] wallet_txns.wallet_txns_served_store_id_fkey
alter table wallet_txns add constraint wallet_txns_served_store_id_fkey FOREIGN KEY (served_store_id) REFERENCES stores(id) ON DELETE RESTRICT;

-- [5.0] wallet_txns.wallet_txns_staff_id_fkey
alter table wallet_txns add constraint wallet_txns_staff_id_fkey FOREIGN KEY (staff_id) REFERENCES staff(id) ON DELETE SET NULL;

-- [5.0] wallet_txns.wallet_txns_store_id_fkey
alter table wallet_txns add constraint wallet_txns_store_id_fkey FOREIGN KEY (store_id) REFERENCES stores(id) ON DELETE RESTRICT;

-- [5.0] wallets.wallets_member_id_fkey
alter table wallets add constraint wallets_member_id_fkey FOREIGN KEY (member_id) REFERENCES members(id) ON DELETE RESTRICT;

-- [5.0] wallets.wallets_org_id_fkey
alter table wallets add constraint wallets_org_id_fkey FOREIGN KEY (org_id) REFERENCES orgs(id) ON DELETE RESTRICT;

-- [6.0] idx_app_events_member
CREATE INDEX idx_app_events_member ON public.app_events USING btree (member_id, created_at) WHERE (member_id IS NOT NULL);

-- [6.0] idx_app_events_org_event
CREATE INDEX idx_app_events_org_event ON public.app_events USING btree (org_id, event, created_at);

-- [6.0] idx_app_events_org_time
CREATE INDEX idx_app_events_org_time ON public.app_events USING btree (org_id, created_at);

-- [6.0] idx_app_events_real
CREATE INDEX idx_app_events_real ON public.app_events USING btree (event, created_at DESC) WHERE (is_test = false);

-- [6.0] idx_app_events_store_created
CREATE INDEX idx_app_events_store_created ON public.app_events USING btree (store_id, created_at DESC) WHERE (store_id IS NOT NULL);

-- [6.0] idx_block_blocked
CREATE INDEX idx_block_blocked ON public.member_blocks USING btree (blocked_id);

-- [6.0] idx_block_blocker
CREATE INDEX idx_block_blocker ON public.member_blocks USING btree (blocker_id);

-- [6.0] idx_bonus_lookup
CREATE INDEX idx_bonus_lookup ON public.bonus_rules USING btree (org_id, store_id, is_active) WHERE (deleted_at IS NULL);

-- [6.0] idx_buddies_member
CREATE INDEX idx_buddies_member ON public.mahjong_buddies USING btree (member_id) WHERE (deleted_at IS NULL);

-- [6.0] idx_coupons_org
CREATE INDEX idx_coupons_org ON public.coupons USING btree (org_id, is_active) WHERE (deleted_at IS NULL);

-- [6.0] idx_interactions_member
CREATE INDEX idx_interactions_member ON public.member_interactions USING btree (member_id, created_at);

-- [6.0] idx_invites_invitee
CREATE INDEX idx_invites_invitee ON public.buddy_invites USING btree (invitee_id) WHERE (status = 'pending'::text);

-- [6.0] idx_invoices_entity
CREATE INDEX idx_invoices_entity ON public.invoices USING btree (entity_id, invoice_at);

-- [6.0] idx_invoices_no
CREATE INDEX idx_invoices_no ON public.invoices USING btree (invoice_no) WHERE (invoice_no IS NOT NULL);

-- [6.0] idx_invoices_pending
CREATE INDEX idx_invoices_pending ON public.invoices USING btree (created_at) WHERE (status = 'pending'::text);

-- [6.0] idx_invoices_ref
CREATE INDEX idx_invoices_ref ON public.invoices USING btree (ref_table, ref_id);

-- [6.0] idx_legal_entities_org
CREATE INDEX idx_legal_entities_org ON public.legal_entities USING btree (org_id);

-- [6.0] idx_likes_target
CREATE INDEX idx_likes_target ON public.member_likes USING btree (target_id);

-- [6.0] idx_match_queues_recurring
CREATE INDEX idx_match_queues_recurring ON public.match_queues USING btree (recurring_id, play_at);

-- [6.0] idx_mc_member
CREATE INDEX idx_mc_member ON public.member_coupons USING btree (member_id, status);

-- [6.0] idx_mc_org
CREATE INDEX idx_mc_org ON public.member_coupons USING btree (org_id, status);

-- [6.0] idx_member_coupons_used_order
CREATE INDEX idx_member_coupons_used_order ON public.member_coupons USING btree (used_order);

-- [6.0] idx_members_is_test
CREATE INDEX idx_members_is_test ON public.members USING btree (org_id) WHERE (is_test = false);

-- [6.0] idx_members_org
CREATE INDEX idx_members_org ON public.members USING btree (org_id) WHERE (deleted_at IS NULL);

-- [6.0] idx_members_staff
CREATE INDEX idx_members_staff ON public.members USING btree (primary_staff_id) WHERE (deleted_at IS NULL);

-- [6.0] idx_notif_member
CREATE INDEX idx_notif_member ON public.app_notifications USING btree (member_id, created_at DESC);

-- [6.0] idx_order_items_order
CREATE INDEX idx_order_items_order ON public.order_items USING btree (order_id);

-- [6.0] idx_order_payments_order
CREATE INDEX idx_order_payments_order ON public.order_payments USING btree (order_id);

-- [6.0] idx_order_payments_store_day
CREATE INDEX idx_order_payments_store_day ON public.order_payments USING btree (store_id, created_at);

-- [6.0] idx_orders_entity
CREATE INDEX idx_orders_entity ON public.orders USING btree (entity_id, created_at);

-- [6.0] idx_orders_member_paid
CREATE INDEX idx_orders_member_paid ON public.orders USING btree (member_id, status) INCLUDE (payable) WHERE (member_id IS NOT NULL);

-- [6.0] idx_orders_real
CREATE INDEX idx_orders_real ON public.orders USING btree (created_at) WHERE (is_test = false);

-- [6.0] idx_orders_session
CREATE INDEX idx_orders_session ON public.orders USING btree (session_id) WHERE (deleted_at IS NULL);

-- [6.0] idx_orders_txn_no
CREATE INDEX idx_orders_txn_no ON public.orders USING btree (txn_no) WHERE (txn_no IS NOT NULL);

-- [6.0] idx_phone_otps_line
CREATE INDEX idx_phone_otps_line ON public.phone_otps USING btree (line_user_id, sent_at DESC) WHERE (line_user_id IS NOT NULL);

-- [6.0] idx_phone_otps_lookup
CREATE INDEX idx_phone_otps_lookup ON public.phone_otps USING btree (org_id, phone, sent_at DESC);

-- [6.0] idx_pricing_lookup
CREATE INDEX idx_pricing_lookup ON public.pricing_tiers USING btree (org_id, store_id, mode, is_active) WHERE (deleted_at IS NULL);

-- [6.0] idx_qp_member
CREATE INDEX idx_qp_member ON public.match_queue_players USING btree (member_id) WHERE (left_at IS NULL);

-- [6.0] idx_queues_open
CREATE INDEX idx_queues_open ON public.match_queues USING btree (org_id, store_id, status) WHERE (status = 'waiting'::text);

-- [6.0] idx_recurring_tables_org_enabled
CREATE INDEX idx_recurring_tables_org_enabled ON public.recurring_tables USING btree (org_id, enabled, weekday);

-- [6.0] idx_session_players_paid_by
CREATE INDEX idx_session_players_paid_by ON public.session_players USING btree (paid_by) WHERE (paid_by IS NOT NULL);

-- [6.0] idx_session_players_waived
CREATE INDEX idx_session_players_waived ON public.session_players USING btree (fee_waived_reason) WHERE (fee_waived_reason IS NOT NULL);

-- [6.0] idx_sessions_status
CREATE INDEX idx_sessions_status ON public.table_sessions USING btree (org_id, status) WHERE (deleted_at IS NULL);

-- [6.0] idx_sessions_store_time
CREATE INDEX idx_sessions_store_time ON public.table_sessions USING btree (store_id, started_at);

-- [6.0] idx_sp_member
CREATE INDEX idx_sp_member ON public.session_players USING btree (member_id);

-- [6.0] idx_staff_member
CREATE INDEX idx_staff_member ON public.staff USING btree (member_id);

-- [6.0] idx_staff_org
CREATE INDEX idx_staff_org ON public.staff USING btree (org_id) WHERE (deleted_at IS NULL);

-- [6.0] idx_stake_lookup
CREATE INDEX idx_stake_lookup ON public.stake_levels USING btree (org_id, store_id, is_active) WHERE (deleted_at IS NULL);

-- [6.0] idx_stores_entity
CREATE INDEX idx_stores_entity ON public.stores USING btree (entity_id);

-- [6.0] idx_stores_org
CREATE INDEX idx_stores_org ON public.stores USING btree (org_id) WHERE (deleted_at IS NULL);

-- [6.0] idx_tables_store
CREATE INDEX idx_tables_store ON public.tables USING btree (store_id) WHERE (deleted_at IS NULL);

-- [6.0] idx_tables_store_area
CREATE INDEX idx_tables_store_area ON public.tables USING btree (store_id, area, sort_order);

-- [6.0] idx_topup_entity
CREATE INDEX idx_topup_entity ON public.topup_orders USING btree (entity_id, created_at);

-- [6.0] idx_topup_orders_session
CREATE INDEX idx_topup_orders_session ON public.topup_orders USING btree (session_id) WHERE (session_id IS NOT NULL);

-- [6.0] idx_topup_orders_txn_no
CREATE INDEX idx_topup_orders_txn_no ON public.topup_orders USING btree (txn_no) WHERE (txn_no IS NOT NULL);

-- [6.0] idx_txn_external
CREATE INDEX idx_txn_external ON public.wallet_txns USING btree (external_ref) WHERE (external_ref IS NOT NULL);

-- [6.0] idx_txn_member
CREATE INDEX idx_txn_member ON public.wallet_txns USING btree (member_id, created_at);

-- [6.0] idx_txn_org_store
CREATE INDEX idx_txn_org_store ON public.wallet_txns USING btree (org_id, store_id, created_at);

-- [6.0] idx_wallet_audit_member
CREATE INDEX idx_wallet_audit_member ON public.wallet_balance_audit USING btree (member_id, changed_at DESC);

-- [6.0] idx_wallet_audit_unsynced
CREATE INDEX idx_wallet_audit_unsynced ON public.wallet_balance_audit USING btree (changed_at DESC) WHERE (is_synced = false);

-- [6.0] ix_season_standings_member
CREATE INDEX ix_season_standings_member ON public.season_standings USING btree (org_id, member_id, rank_no);

-- [6.0] member_coupons_org_code_uq
CREATE UNIQUE INDEX member_coupons_org_code_uq ON public.member_coupons USING btree (org_id, code);

-- [6.0] orders_org_no_uq
CREATE UNIQUE INDEX orders_org_no_uq ON public.orders USING btree (org_id, order_no);

-- [6.0] stores_org_code_uq
CREATE UNIQUE INDEX stores_org_code_uq ON public.stores USING btree (org_id, code);

-- [6.0] topup_orders_idem_uq
CREATE UNIQUE INDEX topup_orders_idem_uq ON public.topup_orders USING btree (org_id, idempotency_key) WHERE (idempotency_key IS NOT NULL);

-- [6.0] topup_orders_member_idx
CREATE INDEX topup_orders_member_idx ON public.topup_orders USING btree (member_id, created_at DESC);

-- [6.0] topup_orders_org_no_uq
CREATE UNIQUE INDEX topup_orders_org_no_uq ON public.topup_orders USING btree (org_id, topup_no);

-- [6.0] uq_availability
CREATE UNIQUE INDEX uq_availability ON public.member_availability USING btree (member_id, weekday, slot, source);

-- [6.0] uq_block_pair
CREATE UNIQUE INDEX uq_block_pair ON public.member_blocks USING btree (blocker_id, blocked_id);

-- [6.0] uq_buddies
CREATE UNIQUE INDEX uq_buddies ON public.mahjong_buddies USING btree (member_id, buddy_id) WHERE (deleted_at IS NULL);

-- [6.0] uq_like_per_session
CREATE UNIQUE INDEX uq_like_per_session ON public.member_likes USING btree (liker_id, target_id, session_id) WHERE (session_id IS NOT NULL);

-- [6.0] uq_members_line
CREATE UNIQUE INDEX uq_members_line ON public.members USING btree (org_id, line_user_id) WHERE ((line_user_id IS NOT NULL) AND (deleted_at IS NULL));

-- [6.0] uq_members_line_user
CREATE UNIQUE INDEX uq_members_line_user ON public.members USING btree (line_user_id) WHERE ((line_user_id IS NOT NULL) AND (deleted_at IS NULL));

-- [6.0] uq_members_phone
CREATE UNIQUE INDEX uq_members_phone ON public.members USING btree (org_id, phone) WHERE ((phone IS NOT NULL) AND (deleted_at IS NULL));

-- [6.0] uq_orders_idem
CREATE UNIQUE INDEX uq_orders_idem ON public.orders USING btree (idempotency_key) WHERE (idempotency_key IS NOT NULL);

-- [6.0] uq_pending_invite
CREATE UNIQUE INDEX uq_pending_invite ON public.buddy_invites USING btree (inviter_id, invitee_id) WHERE (status = 'pending'::text);

-- [6.0] uq_products_sku
CREATE UNIQUE INDEX uq_products_sku ON public.products USING btree (org_id, sku) WHERE (deleted_at IS NULL);

-- [6.0] uq_queue_member
CREATE UNIQUE INDEX uq_queue_member ON public.match_queue_players USING btree (queue_id, member_id) WHERE (left_at IS NULL);

-- [6.0] uq_session_player
CREATE UNIQUE INDEX uq_session_player ON public.session_players USING btree (session_id, member_id);

-- [6.0] uq_sessions_idem
CREATE UNIQUE INDEX uq_sessions_idem ON public.table_sessions USING btree (idempotency_key) WHERE (idempotency_key IS NOT NULL);

-- [6.0] uq_sessions_open_table
CREATE UNIQUE INDEX uq_sessions_open_table ON public.table_sessions USING btree (table_id) WHERE ((status = 'open'::text) AND (deleted_at IS NULL));

-- [6.0] uq_staff_member_store
CREATE UNIQUE INDEX uq_staff_member_store ON public.staff USING btree (member_id, store_id) WHERE (deleted_at IS NULL);

-- [6.0] uq_tables_store_label
CREATE UNIQUE INDEX uq_tables_store_label ON public.tables USING btree (store_id, label) WHERE (deleted_at IS NULL);

-- [6.0] uq_topup_plans_tier
CREATE UNIQUE INDEX uq_topup_plans_tier ON public.topup_plans USING btree (org_id, COALESCE(store_id, '00000000-0000-0000-0000-000000000000'::uuid), min_amount);

-- [6.0] uq_txn_idempotency
CREATE UNIQUE INDEX uq_txn_idempotency ON public.wallet_txns USING btree (org_id, idempotency_key) WHERE (idempotency_key IS NOT NULL);

-- [7.0] _blocked_between
CREATE OR REPLACE FUNCTION public._blocked_between(p_org_id uuid, p_a uuid, p_b uuid)
 RETURNS boolean
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select exists (
    select 1 from member_blocks
     where org_id=p_org_id
       and ((blocker_id=p_a and blocked_id=p_b)
         or (blocker_id=p_b and blocked_id=p_a))
  );
$function$
;

-- [7.0] _charge_core
CREATE OR REPLACE FUNCTION public._charge_core(p_member_id uuid, p_amount bigint, p_type txn_type, p_idempotency_key text, p_store_id uuid, p_served_store_id uuid, p_staff_id uuid, p_ref_table text, p_ref_id uuid, p_counter text)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
declare
  v_org uuid; v_bal bigint; v_existing uuid; v_txn uuid;
begin
  /* 🔴 操作者身分從 JWT 取，**不採信呼叫端送的 p_staff_id**（2026-09-04）。
     在此之前 POS 送的值來自 localStorage，店員可以改成別人 ——
     而那比沒有稽核更糟（看起來有，卻指向錯的人）。
   ⚠ 查不到就是 null（會員 App 那條路沒有 staff 身分），**不可以報錯**。 */
  p_staff_id := (select staff_id from public.current_staff());
  -- 冪等檢查（基石⑧）：同 key 已處理 → 回前次結果，不重複扣
  if p_idempotency_key is not null then
    select id into v_existing from wallet_txns
      where org_id = (select org_id from members where id=p_member_id)
        and idempotency_key = p_idempotency_key;
    if v_existing is not null then
      return jsonb_build_object('idempotent', true, 'txn_id', v_existing);
    end if;
  end if;

  -- 並發鎖（基石⑦）：鎖住這個錢包列，一次只准一筆動它
  select w.org_id, w.balance into v_org, v_bal
    from wallets w where w.member_id = p_member_id for update;
  if not found then
    raise exception '錢包不存在 (member=%)', p_member_id;
  end if;

  -- 驗餘額（扣款金額為正數傳入，內部轉負）
  if v_bal < p_amount then
    raise exception '餘額不足 (餘額=%, 需扣=%)', v_bal, p_amount
      using errcode = 'P0001';
  end if;

  -- 寫流水（append-only，金額為負；基石⑨⑬）
  insert into wallet_txns(org_id, store_id, served_store_id, member_id, type, amount,
                          status, counter_account, idempotency_key, staff_id, ref_table, ref_id)
    values(v_org, p_store_id, p_served_store_id, p_member_id, p_type, -p_amount,
           'completed', p_counter, p_idempotency_key, p_staff_id, p_ref_table, p_ref_id)
    returning id into v_txn;

  -- 更新快取餘額（做法三，同交易）
  update wallets set balance = balance - p_amount where member_id = p_member_id;

  return jsonb_build_object('txn_id', v_txn, 'new_balance', v_bal - p_amount);
end $function$
;

-- [7.0] _check_join_conflict
CREATE OR REPLACE FUNCTION public._check_join_conflict(p_org_id uuid, p_member uuid, p_play_at timestamp with time zone, p_source text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  r record;
  v_target_is_fix boolean := (p_source = 'recurring');
  v_row_is_fix boolean;
begin
  /* 掃身上所有「還沒結束」的場。
     ★ 2026-09-06：加入 `seated`（已經帶到桌、正要去店裡）——
       在此之前成桌之後還能再開一桌，而這支的規則本身寫著
       「同時只能參加一場」。
     🔴 但**必須綁「那張桌還開著」** —— `seated` 是終點狀態，
       打完收桌之後房仍然是 seated，無條件擋的話
       **打過一場的人從此永遠報不了名**。 */
  for r in
    select q.play_at, q.source
      from match_queue_players qp
      join match_queues q on q.id = qp.queue_id
     where qp.member_id = p_member
       and qp.left_at is null
       and q.org_id = p_org_id
       and (
         q.status in ('waiting', 'matched')
         or (q.status = 'seated' and public.migi_seat_is_live(q.matched_session_id))
       )
  loop
    v_row_is_fix := (r.source = 'recurring');
    -- ① 即時局最多一場：目標是即時局、身上已有即時局
    if not v_target_is_fix and not v_row_is_fix then
      raise exception '你已報名即時牌局，同時只能參加一場';
    end if;
    -- ② 固定局最多一場：目標是固定局、身上已有固定局
    if v_target_is_fix and v_row_is_fix then
      raise exception '你已報名固定牌局，同時只能參加一場';
    end if;
    -- ③ 任一場 play_at 跟目標場差 < 6 小時 → 擋（跨類型也要守）
    if abs(extract(epoch from (r.play_at - p_play_at))) < 6 * 3600 then
      raise exception '你已有一場 % 的牌局，時間太近無法同時報名（需間隔 6 小時以上）',
        to_char(r.play_at, 'MM/DD HH24:MI');
    end if;
  end loop;
end $function$
;

-- [7.0] _finalize_queue_full_tx
CREATE OR REPLACE FUNCTION public._finalize_queue_full_tx(p_org uuid, p_queue uuid, p_staff uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_seat jsonb; v_tbl text;
begin
  update match_queues
     set status = 'matched', matched_at = now(), updated_at = now()
   where id = p_queue and status = 'waiting';

  -- 通知房裡每一個人
  insert into app_notifications(org_id, member_id, type, payload, ref_id)
  select p_org, qp.member_id, 'table_ok',
         jsonb_build_object('text', '配桌成功！準時到店開打', 'queue_id', p_queue),
         p_queue
    from match_queue_players qp
   where qp.queue_id = p_queue and qp.left_at is null;

  -- 自動帶桌。失敗（沒空桌）不算錯 —— 房停在 matched，店員自己帶
  v_seat := _try_auto_seat_tx(p_org, p_queue, p_staff);

  if coalesce((v_seat->>'ok')::boolean, false) then
    select t.label into v_tbl
      from table_sessions s join tables t on t.id = s.table_id
     where s.id = (v_seat->>'session_id')::uuid;
    return jsonb_build_object('ok', true, 'status', 'seated',
      'session_id', v_seat->>'session_id', 'table_label', v_tbl);
  end if;

  return jsonb_build_object('ok', true, 'status', 'matched',
    'seat_reason', v_seat->>'reason');
end $function$
;

-- [7.0] _member_orders_core
CREATE OR REPLACE FUNCTION public._member_orders_core(p_member_id uuid, p_limit integer DEFAULT 10, p_before timestamp with time zone DEFAULT NULL::timestamp with time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_limit int := greatest(1, least(coalesce(p_limit, 10), 100));
  v_list  jsonb;
begin
  if p_member_id is null then
    raise exception 'member_id required';
  end if;

  select coalesce(jsonb_agg(x order by x_at desc), '[]'::jsonb)
    into v_list
    from (
      select u.x_at, u.x
        from (
          -- ── 消費單（可能附帶同一次交易的儲值）──
          select o.paid_at as x_at,
                 jsonb_build_object(
                   'type', 'order',
                   'id', o.id,
                   'order_no', o.order_no,
                   'txn_no', o.txn_no,
                   'paid_at', o.paid_at,
                   'subtotal', o.subtotal,
                   'coupon_discount', o.coupon_discount,
                   'tier_discount', o.tier_discount,
                   'payable', o.payable,
                   'points_used', o.points_used,
                   'cash_due', o.cash_due,
                   'items', (
                     select coalesce(jsonb_agg(jsonb_build_object(
                       'name', i.name, 'spec', i.spec, 'revenue_type', i.revenue_type, 'qty', i.qty,
                       'unit_price', i.unit_price, 'line_total', i.line_total
                     ) order by case i.revenue_type
                                  when 'venue_fee' then 1
                                  when 'fnb'       then 2
                                  when 'retail'    then 3
                                  else 4 end, i.name), '[]'::jsonb)
                     from order_items i where i.order_id = o.id),
                   'payments', (
                     select coalesce(jsonb_agg(jsonb_build_object(
                       'method', pm.method, 'amount', pm.amount
                     )), '[]'::jsonb)
                     from order_payments pm where pm.order_id = o.id),

                   -- 同一次收款的儲值（冪等鍵前綴配對，與 POS 桌帳同一套）
                   'topup', (
                     select jsonb_build_object(
                              'topup_no',     t.topup_no,
                              'points',       t.points,
                              'bonus_points', t.bonus_points,
                              'credit',       t.points + t.bonus_points,
                              'amount_twd',   t.amount_twd)
                       from topup_orders t
                      where t.member_id = o.member_id
                        and t.status = 'paid'
                        and o.idempotency_key like 'pos-%'
                        and split_part(t.idempotency_key, ':', 1)
                          = split_part(o.idempotency_key, ':', 1)
                      limit 1),

                   'collected', o.payable + coalesce((
                     select t.amount_twd from topup_orders t
                      where t.member_id = o.member_id
                        and t.status = 'paid'
                        and o.idempotency_key like 'pos-%'
                        and split_part(t.idempotency_key, ':', 1)
                          = split_part(o.idempotency_key, ':', 1)
                      limit 1), 0)
                 ) as x
            from orders o
           where o.member_id = p_member_id
             and o.deleted_at is null
             and o.status = 'paid'

          union all

          -- ── 沒有配對到訂單的儲值單 ──
          select t.created_at as x_at,
                 jsonb_build_object(
                   'type', 'topup',
                   'id', t.id,
                   'order_no', t.topup_no,
                   'txn_no', t.txn_no,
                   'paid_at', t.created_at,
                   'subtotal', t.amount_twd,
                   'coupon_discount', 0,
                   'tier_discount', 0,
                   'payable', t.amount_twd,
                   'points_used', 0,
                   'cash_due', t.amount_twd,
                   'collected', t.amount_twd,
                   'points', t.points,
                   'bonus_points', t.bonus_points,
                   -- 儲值不是營收類別，用獨立旗標標記（與 POS 一致）
                   'items', jsonb_build_array(jsonb_build_object(
                     'name', '會員儲值 ' || (t.points + t.bonus_points)::text || ' 點',
                     'is_topup', true, 'qty', 1,
                     'unit_price', t.amount_twd, 'line_total', t.amount_twd)),
                   'payments', jsonb_build_array(jsonb_build_object(
                     'method', t.pay_method, 'amount', t.amount_twd))
                 ) as x
            from topup_orders t
           where t.member_id = p_member_id
             and t.status = 'paid'
             and not exists (
               select 1 from orders o
                where o.member_id = t.member_id
                  and o.deleted_at is null
                  and o.status = 'paid'
                  and o.idempotency_key like 'pos-%'
                  and split_part(o.idempotency_key, ':', 1)
                    = split_part(t.idempotency_key, ':', 1))
        ) u
       where p_before is null or u.x_at < p_before
       order by u.x_at desc
       limit v_limit
    ) z;

  return jsonb_build_object(
    'orders', v_list,
    -- 還有更多：前端據此決定要不要顯示「載入更多」。
    -- 回筆數等於上限就當作還有 —— 少一次查詢，代價是最後一頁可能多按一次。
    'has_more', jsonb_array_length(v_list) >= v_limit,
    'next_before', case when jsonb_array_length(v_list) > 0
                        then (v_list -> (jsonb_array_length(v_list) - 1) ->> 'paid_at')
                   end);
end $function$
;

-- [7.0] _try_auto_seat_tx
CREATE OR REPLACE FUNCTION public._try_auto_seat_tx(p_org uuid, p_queue uuid, p_staff uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_store uuid; v_tbl uuid; v_fc jsonb;
begin
  select store_id into v_store
    from match_queues where id = p_queue and org_id = p_org;
  if v_store is null then
    return jsonb_build_object('ok', false, 'reason', 'not_found');
  end if;

  /* ★ 湊滿就佔桌，不再等到接近開打。
     理由見檔頭：放回去給現場客人卻沒有預留機制，等於承諾兌現不了。
     ⚠ 代價是那張桌在開打前會空著 —— 所以桌況一定要能顯示「預留中」，
       否則店員會以為有人在打。 */

  select t.id into v_tbl
    from tables t
   where t.org_id = p_org and t.store_id = v_store
     and coalesce(t.is_active, true) = true
     and t.deleted_at is null
     and t.auto_assign = true
     and not exists (select 1 from table_sessions s
                      where s.table_id = t.id and s.status = 'open' and s.deleted_at is null)
   order by t.sort_order nulls last, t.label
   limit 1
   for update of t skip locked;

  if v_tbl is null then
    -- 帶不出桌時把預估一起回去，店員才有話可以跟客人講
    v_fc := pos_table_forecast_tx(p_org, v_store, null);
    return jsonb_build_object('ok', false, 'reason', 'no_free_table',
      'next_free_at', v_fc->'next_free_at',
      'next_free_table', v_fc->'next_free_table');
  end if;

  return pos_seat_queue_tx(p_org, p_queue, v_tbl, p_staff);
end $function$
;

-- [7.0] activate_session_tx
CREATE OR REPLACE FUNCTION public.activate_session_tx(p_session_id uuid, p_staff_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_n int;
begin
  /* 🔴 操作者身分從 JWT 取，**不採信呼叫端送的 p_staff_id**（2026-09-04）。
     在此之前 POS 送的值來自 localStorage，店員可以改成別人 ——
     而那比沒有稽核更糟（看起來有，卻指向錯的人）。
   ⚠ 查不到就是 null（會員 App 那條路沒有 staff 身分），**不可以報錯**。 */
  p_staff_id := (select staff_id from public.current_staff());
  select count(*) into v_n from session_players
   where session_id = p_session_id and left_at is null;
  if v_n = 0 then
    return jsonb_build_object('ok', false, 'reason', 'no_players',
      'message', '尚無人入座');
  end if;

  update table_sessions
     set activated_at = now(), updated_at = now()
   where id = p_session_id and status = 'open' and activated_at is null;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'not_open_or_already_active');
  end if;

  return jsonb_build_object('ok', true, 'players', v_n, 'activated_at', now());
end $function$
;

-- [7.0] admin_delete_product_tx
CREATE OR REPLACE FUNCTION public.admin_delete_product_tx(p_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_org uuid; v_staff uuid; v_sys boolean;
begin
  if not public.can('product.write') then
    return jsonb_build_object('ok', false, 'reason', 'forbidden', 'message', '沒有權限刪除商品');
  end if;
  v_org   := public.current_org_id();
  v_staff := (select staff_id from public.current_staff());

  select is_system into v_sys from products
   where id = p_id and org_id = v_org and deleted_at is null;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'not_found', 'message', '找不到這個商品');
  end if;
  if v_sys then
    return jsonb_build_object('ok', false, 'reason', 'system_cannot_delete',
      'message', '系統商品不可刪除，開桌流程以貨號查詢它');
  end if;

  update products set deleted_at = now(), updated_by = v_staff
   where id = p_id and org_id = v_org and deleted_at is null;
  return jsonb_build_object('ok', true);
end $function$
;

-- [7.0] admin_list_member_tiers_tx
CREATE OR REPLACE FUNCTION public.admin_list_member_tiers_tx()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not public.can('tier.write') then
    return jsonb_build_object('ok', false, 'reason', 'forbidden',
                              'message', '沒有權限查看會員等級');
  end if;

  /* ⚠ **不是 `list_member_tiers_tx`** —— 那一支濾掉停用的、也不回
     `is_active` 與 `sort`（POS 與會員 App 在讀它，不可以改）。 */
  return jsonb_build_object('ok', true, 'rows', coalesce((
    select jsonb_agg(jsonb_build_object(
             'code', t.code,
             'label', t.label,
             'discount_pct', t.discount_pct,
             'threshold_amount', t.threshold_amount,
             'sort', t.sort,
             'is_active', t.is_active,
             'note', t.note,
             'updated_at', t.updated_at,
             /* 🎯 **有幾個人在這一階** —— 讓改動的後果看得見
                （「改這一階會影響 3 個人」），而不是改完才知道。
                ⚠ 也是 ② 那道擋牆的依據。 */
             'members', (select count(*) from members m
                          where m.tier = t.code and m.deleted_at is null)
           ) order by t.sort, t.code)
      from member_tiers t), '[]'::jsonb));
end $function$
;

-- [7.0] admin_list_products_tx
CREATE OR REPLACE FUNCTION public.admin_list_products_tx()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_org uuid;
begin
  if not public.can('product.write') then
    return jsonb_build_object('ok', false, 'reason', 'forbidden',
                              'message', '沒有權限查看商品');
  end if;
  v_org := public.current_org_id();

  return jsonb_build_object('ok', true, 'rows', coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', id, 'sku', sku, 'name', name,
      'category', category, 'subcategory', subcategory,
      'revenue_type', revenue_type,
      'unit_price', unit_price, 'unit_cost', unit_cost,
      'tracks_stock', tracks_stock, 'stock_qty', stock_qty,
      'is_active', is_active, 'is_available', is_available,
      'is_system', is_system, 'discountable', discountable,
      'spec', spec,
      'updated_at', updated_at
    ) order by category, sku)
    from products
    where org_id = v_org and deleted_at is null
  ), '[]'::jsonb));
end $function$
;

-- [7.0] admin_remove_avatar_tx
CREATE OR REPLACE FUNCTION public.admin_remove_avatar_tx(p_member_id uuid, p_reason text DEFAULT NULL::text, p_block boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_path text; v_org uuid; v_cnt int;
begin
  /* 🔴 這一行是這次唯一新增的東西。
     照 admin_search_sessions_tx / admin_update_member_tier_tx 同一個寫法，
     回傳形狀也一致（ok / reason / message）—— 不要發明第二種。 */
  if not public.can('member.write') then
    return jsonb_build_object('ok', false, 'reason', 'forbidden',
                              'message', '沒有權限下架會員頭像');
  end if;

  select avatar_photo_path, org_id, avatar_removed_count
    into v_path, v_org, v_cnt
    from members where id = p_member_id;

  if v_org is null then
    return jsonb_build_object('ok', false, 'reason', 'member_not_found');
  end if;

  update members
     set avatar_source = 'bear',           -- 強制切回圖鑑頭像
         avatar_photo_path = null,
         avatar_removed_count = avatar_removed_count + 1,
         avatar_blocked = (avatar_blocked OR p_block),
         updated_at = now()
   where id = p_member_id;

  -- 留下處理紀錄（誰的照片、第幾次、原因、是否封鎖）
  insert into app_events(org_id, member_id, event, props, created_at)
  values (v_org, p_member_id, 'avatar_removed',
          jsonb_build_object('path', v_path, 'reason', p_reason,
                             'blocked', p_block, 'times', v_cnt + 1),
          now());

  return jsonb_build_object('ok', true, 'removed_path', v_path,
    'times', v_cnt + 1, 'blocked', p_block);
end $function$
;

-- [7.0] admin_search_sessions_tx
CREATE OR REPLACE FUNCTION public.admin_search_sessions_tx(p_from timestamp with time zone DEFAULT NULL::timestamp with time zone, p_to timestamp with time zone DEFAULT NULL::timestamp with time zone, p_store uuid DEFAULT NULL::uuid, p_table_q text DEFAULT NULL::text, p_member_q text DEFAULT NULL::text, p_limit integer DEFAULT 50, p_before timestamp with time zone DEFAULT NULL::timestamp with time zone, p_before_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_org   uuid;
  v_from  timestamptz;
  v_to    timestamptz;
  v_lim   int := least(greatest(coalesce(p_limit, 50), 1), 200);
  v_rows  jsonb;
  v_more  boolean := false;
begin
  if not public.can('ops.read') then
    return jsonb_build_object('ok', false, 'reason', 'forbidden',
                              'message', '沒有權限查詢場次');
  end if;
  v_org := public.current_org_id();

  v_from := coalesce(p_from,
              ((now() at time zone 'Asia/Taipei')::date)::timestamp at time zone 'Asia/Taipei');
  v_to   := coalesce(p_to, v_from + interval '1 day');

  with base as (
    select s.id,
           coalesce(s.activated_at, s.started_at) as at,
           s.ended_at, s.status, s.mode, s.game_type, s.flower,
           s.planned_rounds, s.fee_points,
           t.label as table_label, t.area,
           st.name as store_name,
           coalesce(sl.label, '未設定') as stake_label,
           coalesce(sl.is_hygiene, false) as hygiene
      from table_sessions s
      left join tables t        on t.id  = s.table_id
      left join stores st       on st.id = s.store_id
      left join stake_levels sl on sl.id = s.stake_level_id
     where s.org_id = v_org
       and s.deleted_at is null
       and coalesce(s.activated_at, s.started_at) >= v_from
       and coalesce(s.activated_at, s.started_at) <  v_to
       and (p_store   is null or s.store_id = p_store)
       and (p_table_q is null or t.label ilike '%' || btrim(p_table_q) || '%')
       /* 🔴 手機那一半一定要先確認真的有數字 ——
          `regexp_replace('阿明','\D','','g')` 回空字串 ⇒ `like '%%'`
          ⇒ 每個有手機的會員都符合 ⇒ **篩選完全失效而且不報錯**。 */
       and (p_member_q is null or exists (
              select 1 from session_players sp
                join members m on m.id = sp.member_id
               where sp.session_id = s.id
                 and (m.display_name ilike '%' || btrim(p_member_q) || '%'
                      or (regexp_replace(p_member_q, '\D', '', 'g') <> ''
                          and m.phone like '%' || regexp_replace(p_member_q, '\D', '', 'g') || '%'))))
       /* ★ 複合游標：`(at, id)` 的列比較是字典序 —— 先比時間，打平才比 id。
          ⚠ **必須與 `order by` 用同一組鍵**，否則游標會指到排序上不相鄰的位置。
          ⚠ 只給 `p_before` 沒給 id 時退回單鍵（前端第一版就是這樣叫的）。 */
       and (p_before is null
            or (p_before_id is null and coalesce(s.activated_at, s.started_at) < p_before)
            or (p_before_id is not null
                and (coalesce(s.activated_at, s.started_at), s.id) < (p_before, p_before_id)))
     order by coalesce(s.activated_at, s.started_at) desc, s.id desc
     limit v_lim + 1
  )
  /* `has_more` 從**多撈的那一筆**判斷，而且要在截斷之前數 ——
     內層先 limit 再 count 的話，count 永遠 ≤ v_lim，
     `has_more` 恆為 false 而且不報錯（下一頁永遠按不到）。 */
  select coalesce(jsonb_agg(x.j order by x.at desc, x.id desc)
                    filter (where x.rn <= v_lim), '[]'::jsonb),
         count(*) > v_lim
    into v_rows, v_more
    from (
      select b.at, b.id,
             row_number() over (order by b.at desc, b.id desc) as rn,
             jsonb_build_object(
               'id', b.id,
               'at', b.at,
               'ended_at', b.ended_at,
               'status', b.status,
               'mode', b.mode,
               'game_type', b.game_type,
               'flower', b.flower,
               'rounds', b.planned_rounds,
               'store', b.store_name,
               'table', b.table_label,
               'area', b.area,
               'stake', b.stake_label,
               'hygiene', b.hygiene,
               'fee_points', b.fee_points,
               /* 🔴 刻意不回 member_id —— 這一頁看得到所有人的消費與同桌關係，
                  而回 id 等於公開發送一批會員 uuid（`get_wallet_tx` today 仍是
                  anon ＋ 前端送 id）。人名 ＋ 座位 ＋ 名次就回答得了「誰在打」。 */
               'players', coalesce((
                  select jsonb_agg(jsonb_build_object(
                           'name', coalesce(m.display_name, '（已刪除）'),
                           'seat', sp.seat,
                           'rank', sp.finish_rank,
                           'charged', sp.charged_points,
                           'waived', sp.fee_waived_amount,
                           'waived_reason', sp.fee_waived_reason,
                           'paid_for_by_other', sp.paid_by is not null,
                           'score', sp.final_score,
                           'left_at', sp.left_at
                         ) order by sp.seat nulls last, sp.joined_at)
                    from session_players sp
                    left join members m on m.id = sp.member_id
                   where sp.session_id = b.id), '[]'::jsonb)
             ) as j
        from base b
    ) x;

  return jsonb_build_object(
    'ok', true,
    'rows', coalesce(v_rows, '[]'::jsonb),
    'has_more', v_more,
    'from', v_from,
    'to', v_to,
    /* ★ 游標現在是**一對** —— 前端要把兩個都帶回來。
       ⚠ 取的是「給出去那批裡最後一筆」，不是最小時間 ——
         打平的時候「最小時間」有兩筆，指哪一筆是未定義的。 */
    'next_before', case when v_more then (v_rows -> (jsonb_array_length(v_rows) - 1) ->> 'at') end,
    'next_before_id', case when v_more then (v_rows -> (jsonb_array_length(v_rows) - 1) ->> 'id') end
  );
end $function$
;

-- [7.0] admin_set_product_active_tx
CREATE OR REPLACE FUNCTION public.admin_set_product_active_tx(p_id uuid, p_is_active boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_org uuid; v_staff uuid; v_sys boolean;
begin
  if not public.can('product.write') then
    return jsonb_build_object('ok', false, 'reason', 'forbidden', 'message', '沒有權限編輯商品');
  end if;
  v_org   := public.current_org_id();
  v_staff := (select staff_id from public.current_staff());

  select is_system into v_sys from products
   where id = p_id and org_id = v_org and deleted_at is null;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'not_found', 'message', '找不到這個商品');
  end if;
  /* 🔴 這道牆在此之前**只存在於前端的一個 if**。 */
  if v_sys and p_is_active = false then
    return jsonb_build_object('ok', false, 'reason', 'system_cannot_disable',
      'message', '系統商品不可停用，停用後開桌會找不到它');
  end if;

  update products set is_active = p_is_active, updated_by = v_staff
   where id = p_id and org_id = v_org and deleted_at is null;
  return jsonb_build_object('ok', true);
end $function$
;

-- [7.0] admin_update_member_tier_tx
CREATE OR REPLACE FUNCTION public.admin_update_member_tier_tx(p_code text, p_label text, p_discount_pct integer, p_threshold_amount bigint, p_is_active boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_staff uuid;
  v_label text := nullif(btrim(coalesce(p_label, '')), '');
  v_sort  int;
  v_using int;
  v_bad   text;
begin
  if not public.can('tier.write') then
    return jsonb_build_object('ok', false, 'reason', 'forbidden',
                              'message', '沒有權限編輯會員等級');
  end if;
  v_staff := (select staff_id from public.current_staff());

  select sort into v_sort from member_tiers where code = p_code;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'not_found', 'message', '找不到這個等級');
  end if;

  if v_label is null then
    return jsonb_build_object('ok', false, 'reason', 'label_required', 'message', '請填等級名稱');
  end if;
  /* ③ DB 已有 CHECK，這裡是為了回人話而不是讓 23514 冒到畫面上。 */
  if p_discount_pct is null or p_discount_pct < 0 or p_discount_pct > 100 then
    return jsonb_build_object('ok', false, 'reason', 'bad_pct',
                              'message', '折抵幅度必須在 0 到 100 之間');
  end if;
  if p_threshold_amount is not null and p_threshold_amount < 0 then
    return jsonb_build_object('ok', false, 'reason', 'bad_threshold',
                              'message', '升等門檻不可以是負的');
  end if;

  /* ── ② 還有會員在用的等級不可以停用 ──────────────────
     `members.tier` 的欄位預設值是寫死的 `'bubble_tea'`，
     而 `checkout_tx` 查主檔拿折扣 —— 停用之後那些人的折扣會落空。
     ⚠ 用「有沒有人在用」判斷，不寫死 code。 */
  if p_is_active = false then
    select count(*) into v_using from members
     where tier = p_code and deleted_at is null;
    if v_using > 0 then
      return jsonb_build_object('ok', false, 'reason', 'tier_in_use',
        'message', '還有 ' || v_using || ' 位會員在這一階，不能停用');
    end if;
  end if;

  /* ── ① 門檻必須隨 sort 遞增 ────────────────────────────
     🔴 `recalc_member_tier_tx` 選的是「達標的**最高一階**」（`order by sort desc`）。
       門檻與 sort 反向的話，花得少的人會跳到更高的階 ——
       **不報錯，只是升等規則靜悄悄變了**。
     ⚠ `threshold_amount is null` 是邀請制（主廚特調），不參與比較。
     ⚠ 比較的是**改完之後**的樣子，所以用即將寫入的值去比。 */
  if p_threshold_amount is not null and p_is_active then
    select string_agg(t.label || '（' || t.threshold_amount || '）', '、' order by t.sort)
      into v_bad
      from member_tiers t
     where t.code <> p_code and t.is_active and t.threshold_amount is not null
       and ((t.sort < v_sort and t.threshold_amount > p_threshold_amount)
         or (t.sort > v_sort and t.threshold_amount < p_threshold_amount));
    if v_bad is not null then
      return jsonb_build_object('ok', false, 'reason', 'threshold_out_of_order',
        'message', '門檻必須由低階到高階遞增，這個值與「' || v_bad || '」衝突');
    end if;
  end if;

  update member_tiers
     set label = v_label,
         discount_pct = p_discount_pct,
         threshold_amount = p_threshold_amount,
         is_active = coalesce(p_is_active, true),
         updated_at = now(),
         updated_by = v_staff          -- 🔴 從 current_staff() 取，不收參數
   where code = p_code;

  return jsonb_build_object('ok', true, 'code', p_code);
end $function$
;

-- [7.0] admin_upsert_product_tx
CREATE OR REPLACE FUNCTION public.admin_upsert_product_tx(p_id uuid, p_sku text, p_name text, p_category text, p_subcategory text, p_revenue_type text, p_tracks_stock boolean, p_unit_price integer, p_unit_cost integer, p_stock_qty integer, p_is_active boolean, p_is_available boolean, p_spec text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_org   uuid;
  v_staff uuid;
  v_sku   text := nullif(btrim(coalesce(p_sku, '')), '');
  v_name  text := nullif(btrim(coalesce(p_name, '')), '');
  v_spec  text := nullif(btrim(coalesce(p_spec, '')), '');   -- 空字串一律存 null
  v_stock integer;
  v_sys   boolean;
  v_old   text;
  v_row   products%rowtype;
begin
  if not public.can('product.write') then
    return jsonb_build_object('ok', false, 'reason', 'forbidden', 'message', '沒有權限編輯商品');
  end if;
  v_org   := public.current_org_id();
  v_staff := (select staff_id from public.current_staff());

  if v_sku is null  then return jsonb_build_object('ok', false, 'reason', 'sku_required',  'message', '請填貨號'); end if;
  if v_name is null then return jsonb_build_object('ok', false, 'reason', 'name_required', 'message', '請填品名'); end if;
  if p_category is null or p_category not in ('fnb', 'merch', 'service') then
    return jsonb_build_object('ok', false, 'reason', 'bad_category', 'message', '請選分類');
  end if;
  /* 🔴 `revenue_type` 是 **NOT NULL** —— 前端原本送 `|| null`，
     所以沒選會拋 23502 而畫面印出 Postgres 原文。
     ⚠ 話術 2026-09-08 改用「營收類別」（原本那個詞是分桶邏輯的比喻，
       店員沒有那個脈絡）。**這裡刻意不寫出舊詞** —— 寫了的話
       掃描禁字的驗證段會被自己的註解觸發（硬規則 3.5）。 */
  if p_revenue_type is null or p_revenue_type not in ('venue_fee', 'fnb', 'retail', 'other') then
    return jsonb_build_object('ok', false, 'reason', 'revenue_type_required', 'message', '請選營收類別');
  end if;
  if coalesce(p_unit_price, -1) < 0 then
    return jsonb_build_object('ok', false, 'reason', 'bad_price', 'message', '價格不可以是負的');
  end if;

  /* 不盤點的商品庫存一律 0 —— 留著沒人維護的數字會誤導盤點。 */
  v_stock := case when coalesce(p_tracks_stock, true) then greatest(coalesce(p_stock_qty, 0), 0) else 0 end;

  if p_id is null then
    insert into products (org_id, sku, name, spec, category, subcategory, revenue_type,
                          tracks_stock, unit_price, unit_cost, stock_qty,
                          is_active, is_available, created_by, updated_by)
    values (v_org, v_sku, v_name, v_spec, p_category, nullif(p_subcategory, ''), p_revenue_type,
            coalesce(p_tracks_stock, true), p_unit_price, coalesce(p_unit_cost, 0), v_stock,
            coalesce(p_is_active, true), coalesce(p_is_available, true), v_staff, v_staff)
    returning * into v_row;
  else
    select is_system, sku into v_sys, v_old
      from products where id = p_id and org_id = v_org and deleted_at is null;
    if not found then
      return jsonb_build_object('ok', false, 'reason', 'not_found', 'message', '找不到這個商品');
    end if;

    /* 🔴 系統商品不可改貨號：後端以固定貨號查它，改了開桌會回
       `product_not_found`，而那個錯誤訊息不會指向後台。
       ⚠ 品名與價格**可以改** —— 調檯費是正當的營運動作。 */
    if v_sys and v_sku is distinct from v_old then
      return jsonb_build_object('ok', false, 'reason', 'system_sku_locked',
        'message', '系統商品的貨號不可更改（後端以此貨號查詢它）');
    end if;
    if v_sys and coalesce(p_is_active, true) = false then
      return jsonb_build_object('ok', false, 'reason', 'system_cannot_disable',
        'message', '系統商品不可停用，停用後開桌會找不到它');
    end if;

    update products
       set sku = v_sku, name = v_name, spec = v_spec, category = p_category,
           subcategory = nullif(p_subcategory, ''), revenue_type = p_revenue_type,
           tracks_stock = coalesce(p_tracks_stock, true),
           unit_price = p_unit_price, unit_cost = coalesce(p_unit_cost, 0),
           stock_qty = v_stock,
           is_active = coalesce(p_is_active, true),
           is_available = coalesce(p_is_available, true),
           updated_by = v_staff
     where id = p_id and org_id = v_org and deleted_at is null
    returning * into v_row;
  end if;

  return jsonb_build_object('ok', true, 'id', v_row.id, 'sku', v_row.sku);
exception
  when unique_violation then
    return jsonb_build_object('ok', false, 'reason', 'sku_taken',
      'message', '這個貨號已經有人用了');
end $function$
;

-- [7.0] app_events_no_mutate
CREATE OR REPLACE FUNCTION public.app_events_no_mutate()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
begin
  raise exception 'app_events 為 append-only，不可刪改';
end $function$
;

-- [7.0] apply_session_rounds_tx
CREATE OR REPLACE FUNCTION public.apply_session_rounds_tx(p_session_id uuid, p_rounds jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_org uuid; v_rounds int; v_n int; r jsonb; e jsonb;
  v_ids uuid[]; v_ranks int[]; i int;
  v_band text; v_pts int; v_new int; v_floor int; v_prev int;
  v_total jsonb := '{}'::jsonb;   -- member_id → 本場累計得點
begin
  select org_id into v_org from table_sessions
   where id = p_session_id and deleted_at is null;
  if v_org is null then
    return jsonb_build_object('ok', false, 'reason', 'session_not_found');
  end if;

  v_rounds := jsonb_array_length(coalesce(p_rounds, '[]'::jsonb));
  -- 🔴 未滿 2 將不計（決策紀錄 ①，原規格是 1 將）
  if v_rounds < 2 then
    return jsonb_build_object('ok', false, 'reason', 'too_few_rounds', 'rounds', v_rounds);
  end if;

  -- 冪等：整場只結算一次
  if exists (select 1 from session_players
              where session_id = p_session_id and finish_rank is not null) then
    return jsonb_build_object('ok', false, 'reason', 'already_applied');
  end if;

  for idx in 0 .. v_rounds - 1 loop
    r := p_rounds -> idx;
    select array_agg((x->>'member_id')::uuid order by ord),
           array_agg((x->>'finish_rank')::int order by ord)
      into v_ids, v_ranks
      from jsonb_array_elements(r) with ordinality as t(x, ord);

    v_n := coalesce(array_length(v_ids,1), 0);
    -- 🔴 三人以下不計（決策紀錄 ①）
    if v_n <> 4 then
      return jsonb_build_object('ok', false, 'reason', 'need_four_players',
        'round', idx + 1, 'n', v_n);
    end if;
    if (select count(distinct u) from unnest(v_ids) u) <> v_n then
      return jsonb_build_object('ok', false, 'reason', 'duplicate_member', 'round', idx + 1);
    end if;
    if (select array_agg(x order by x) from unnest(v_ranks) x)
       is distinct from (select array_agg(g order by g) from generate_series(1, v_n) g) then
      return jsonb_build_object('ok', false, 'reason', 'bad_ranks', 'round', idx + 1);
    end if;

    for i in 1..v_n loop
      -- 每個人都要真的坐過這一桌
      if not exists (select 1 from session_players
                      where session_id = p_session_id and member_id = v_ids[i]) then
        return jsonb_build_object('ok', false, 'reason', 'not_in_session',
          'member_id', v_ids[i]);
      end if;

      /* 🔴 依**當下**的段位取 band 與該階下限 —— 要在迴圈裡查，不能先撈一次。 */
      select (d ->> 'band'), (d ->> 'tier_min')::int, m.rating
        into v_band, v_floor, v_new
        from members m, lateral (select public.rank_detail_tx(m.rating) as d) x
       where m.id = v_ids[i] and m.org_id = v_org and m.deleted_at is null;
      if v_band is null then
        return jsonb_build_object('ok', false, 'reason', 'member_not_found',
          'member_id', v_ids[i]);
      end if;

      /* ── 🎓 定位賽：人生第一場 ────────────────────────
         使用者 2026-09-01 拍板：第一場用 `+30/+15/+10/+5`，
         **第 4 名也 +5** ⇒ 打完一定會從銅牌熊 IV 升到 III。
         第一次玩的人拿到的不是一個數字，是**一個看得見的升級**。

         🔴 **判準是「有沒有結算過的場次」，不是 `rating_games = 0`。**
           · `rating_games` **每季歸零** ⇒ 會變成每季都送一次定位賽
           · 它是**逐將**遞增的 ⇒ 同一場的第 2 將就不算定位賽了，
             而那會讓「第一場」這個承諾在 2 將制下**只兌現一半**
         ⚠ `finish_rank` 是**整場收尾**才寫的，所以這一場自己的列
           在這個迴圈裡還是 null —— 判斷不會被自己汙染。
         ⚠ 排除 `p_session_id` 是保險：就算日後有人改成逐將寫入，
           這一行仍然成立。 */
      if not exists (select 1 from session_players sp2
                      where sp2.member_id = v_ids[i]
                        and sp2.finish_rank is not null
                        and sp2.session_id <> p_session_id) then
        v_band := 'placement';
      end if;

      select points into v_pts from rank_points
       where band = v_band and place = v_ranks[i];

      v_prev := v_new;              -- 這一將加分前的 rating

      v_new := v_new + v_pts;

      /* ── 🛡 低段的降階保護（銅／銀／金**不掉階**）────────
         使用者 2026-08-29 拍板：「銅／銀不降」再**放寬到金牌不降**，
         只有白金以上會掉。

         🔴 **這一條一度在文件裡消失。** 改成「每半年歸零」那一版寫了
           「不需要保護機制」—— 但那句話把**兩種保護混成一種**：
           · 賽季降階保護 → 歸零之後確實不需要（大家都歸零）
           · **平時降階保護 → 跟歸零完全無關，是被誤刪的**
         ⚠ **低段正和 ≠ 不會掉**：銅銀金的第 4 名還是 −20，連輸就會掉階。
           正和只是說「平均會往上」。
         📌 而決策紀錄結尾那句「白金那條線是**平時會掉**的起點」一直都在 ——
           文件自己前後矛盾，是那一句才對。

         🎯 **不需要 `peak_rating`**：規則是「不降階」的話，
           **當前分數本身就記著他到過哪一階**（因為他掉不出去）。
           夾在當前階的下限 → 下次再掉還是那個值，自我維持。
         ⚠ **階內仍然可以降小級**（IV→III→II→I）——
           那正是原始設計說「保護底線 = 金牌 I」的意思，不是完全不動。
         ⚠ `placement` 也夾一次：它沒有負數所以是空操作，
           但**不寫的話這一行就依賴「placement 永遠沒有負數」這個假設**。 */
      if v_band in ('low', 'placement') then
        v_new := greatest(v_new, v_floor);
      end if;

      update members
         set rating = v_new, rating_games = rating_games + 1
       where id = v_ids[i];

      /* 🔴 記**實際變動**（`v_new - v_prev`）不是原始點數 `v_pts`。
         降階保護把 rating 夾住時，那一將實際上沒有掉那麼多 ——
         記原始點數的話，畫面上的「段位分」會與段位走勢圖矛盾。
         ⚠ 代價：本場得點會與 rank_points 表對不起來，
           而那正是保護生效的意思。2026-09-06 使用者拍板。 */
      v_total := jsonb_set(v_total, array[v_ids[i]::text],
        to_jsonb(coalesce((v_total ->> v_ids[i]::text)::int, 0) + (v_new - v_prev)));
    end loop;
  end loop;

  /* 整場收尾（2026-09-06 改）：
     · `finish_rank`  = **最後一將**的名次
     · `score_points` = 每一將**實際變動**的加總（夾過降階保護之後）

     🔴 在此之前 finish_rank 是「段位分加總的排名」，那有兩個錯：
       ① 同分時由 `member_id` 字典序決定，一條看不見的規則
       ② 名次與段位分是兩件事 —— 名次來自桌上分數（累積的，
          所以最後一將結束就是整場結果），段位分是每將給點再加總
     ⇒ 現在會出現「第 4 名但段位分是正的」，**那是對的**：
       他前面幾將贏了、最後一將墊底。

     ⚠ 每一將的名次仍然沒有存下來（這一格裝不下），要等牌譜 schema。
     ⚠ `v_ids` / `v_ranks` 在迴圈結束後就是最後一將的值 —— 不用另外記。
     ⏳ M4 接上桌上分數之後，`finish_rank` 改成依桌上總分排、
       同分比座位；`score_points` 不變。 */
  for i in 1 .. v_n loop
    update session_players sp
       set finish_rank  = v_ranks[i],
           score_points = coalesce((v_total ->> v_ids[i]::text)::int, 0),
           settled_at   = now(),
           rating_after = (select rating from members where id = v_ids[i])
     where sp.session_id = p_session_id and sp.member_id = v_ids[i];

    update members set rank = public.member_rank_tx(id) where id = v_ids[i];
  end loop;

  return jsonb_build_object('ok', true, 'rounds', v_rounds,
    'result', (select jsonb_agg(jsonb_build_object(
                 'member_id', sp.member_id, 'finish_rank', sp.finish_rank,
                 'score_points', sp.score_points, 'rating_after', sp.rating_after,
                 'rank', m.rank))
                 from session_players sp join members m on m.id = sp.member_id
                where sp.session_id = p_session_id));
end $function$
;

-- [7.0] audit_wallet_balance
CREATE OR REPLACE FUNCTION public.audit_wallet_balance()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_sum bigint;
begin
  if NEW.balance = OLD.balance then
    return NEW;   -- 只有 updated_at 變動，不記錄
  end if;

  select coalesce(sum(amount), 0) into v_sum
    from wallet_txns
   where member_id = NEW.member_id and org_id = NEW.org_id and status = 'completed';

  insert into wallet_balance_audit(
    member_id, org_id, old_balance, new_balance, delta,
    txn_sum, is_synced, db_user
  ) values (
    NEW.member_id, NEW.org_id, OLD.balance, NEW.balance, NEW.balance - OLD.balance,
    v_sum, (NEW.balance = v_sum), current_user
  );

  return NEW;
end $function$
;

-- [7.0] block_member_tx
CREATE OR REPLACE FUNCTION public.block_member_tx(p_org_id uuid, p_blocker uuid, p_blocked uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if p_blocker = p_blocked then raise exception '不能封鎖自己'; end if;

  insert into member_blocks(org_id, blocker_id, blocked_id)
  values (p_org_id, p_blocker, p_blocked)
  on conflict (blocker_id, blocked_id) do nothing;

  -- 作廢雙方之間所有 pending 牌咖邀請（兩個方向）
  update buddy_invites set status='rejected', responded_at=now()
   where org_id=p_org_id and status='pending'
     and ((inviter_id=p_blocker and invitee_id=p_blocked)
       or (inviter_id=p_blocked and invitee_id=p_blocker));

  -- ★ 一併解除已成立的牌咖關係（雙向軟刪除，同 remove_buddy_tx 邏輯）
  update mahjong_buddies set deleted_at = now()
   where org_id = p_org_id and deleted_at is null
     and ((member_id = p_blocker and buddy_id = p_blocked)
       or (member_id = p_blocked and buddy_id = p_blocker));

  -- 清掉雙方之間相關的未讀通知（牌咖/桌邀），避免黑了還躺著已作廢的邀請
  update app_notifications set read_at=now()
   where org_id=p_org_id and read_at is null
     and type in ('buddy_req','table_req')
     and ((member_id=p_blocker and (payload->>'from_id')=p_blocked::text)
       or (member_id=p_blocked and (payload->>'from_id')=p_blocker::text));
end $function$
;

-- [7.0] block_txn_mutation
CREATE OR REPLACE FUNCTION public.block_txn_mutation()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
begin
  raise exception 'wallet_txns 為 append-only 帳本,不可 UPDATE/DELETE;退款請新增 reversal 分錄';
end $function$
;

-- [7.0] calc_session_fee_tx
CREATE OR REPLACE FUNCTION public.calc_session_fee_tx(p_session_id uuid, p_join_type text DEFAULT 'opener'::text, p_member_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_s record; v_sku text; v_p record;
begin
  select * into v_s from table_sessions where id = p_session_id;
  if v_s.id is null then
    return jsonb_build_object('ok', false, 'reason', 'session_not_found');
  end if;

  -- ★ 暢打先判，配桌包桌都免（2026-08-17 拍板）。
  --   舊版把這段寫在配桌那個 else 裡，理由是「包桌是場地費」——
  --   但包桌同日改成單人計價之後，兩者都是按人頭收的場地費，那個理由不再成立。
  --   暢打買的就是「今天在這間店打牌不再收場地費」。
  --   p_member_id 為 null 時跳過 —— 呼叫端要「不看暢打的標準單價」時就傳 null。
  if p_member_id is not null
     and has_daypass_tx(v_s.org_id, p_member_id, v_s.store_id) then
    return jsonb_build_object('ok', true, 'amount', 0, 'product_id', null,
      'daypass', true, 'note', '此會員今日已購買當日暢打，不再收取場地費');
  end if;

  if v_s.mode = 'private' then
    -- 包桌：單人計價，與配桌對稱（2026-08-17）
    v_sku := case when v_s.planned_minutes <= 120 then 'SVC-TBL-P02'
                  when v_s.planned_minutes <= 300 then 'SVC-TBL-P05'
                  else 'SVC-TBL-P24' end;
  else
    v_sku := case when p_join_type = 'opener'
                  then (case when v_s.planned_rounds = 2 then 'SVC-TBL-M2' else 'SVC-TBL-M3' end)
                  else 'SVC-TBL-MID' end;
  end if;

  select id, sku, name, unit_price into v_p
    from products
   where sku = v_sku and org_id = v_s.org_id and is_active and deleted_at is null
   limit 1;
  if v_p.id is null then
    return jsonb_build_object('ok', false, 'reason', 'product_not_found', 'sku', v_sku);
  end if;

  return jsonb_build_object('ok', true, 'product_id', v_p.id, 'sku', v_p.sku,
    'name', v_p.name, 'amount', v_p.unit_price, 'daypass', false);
end $function$
;

-- [7.0] calc_topup_bonus_tx
CREATE OR REPLACE FUNCTION public.calc_topup_bonus_tx(p_org_id uuid, p_store_id uuid, p_amount_twd bigint)
 RETURNS bigint
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  -- 往下取級距：門檻 <= 金額的那些之中取最大的一筆。
  -- ⚠ 一筆都沒有時回 0（例如儲 100，低於最低門檻 150）——
  --   coalesce 在最外層，不要讓它回 null：
  --   null 進到金額計算會讓整個結果變 null 而不報錯。
  select coalesce((
    select t.bonus_points
      from topup_plans t
     where t.org_id = p_org_id
       and t.is_active
       and t.min_amount <= coalesce(p_amount_twd, 0)
       and t.store_id is not distinct from (
         case when exists (
           select 1 from topup_plans x
            where x.org_id = p_org_id and x.store_id = p_store_id and x.is_active
         ) then p_store_id else null end
       )
     order by t.min_amount desc
     limit 1
  ), 0);
$function$
;

-- [7.0] can
CREATE OR REPLACE FUNCTION public.can(p_perm text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  /* 🎯 **判斷點一律呼叫 `can('動詞.名詞')`，不要在 policy 裡比對 role 字串**
     （CLAUDE.md 待辦 29 ①）。重點是**「權限怎麼決定」與「誰有權限」分家**：
     日後換成查 `role_permissions` 表時，**所有呼叫點一行都不用改**。

   ⚠ 權限碼用**動詞**不用頁面名（待辦 29 ④）——
     頁面會改名、會合併、會拆開；動作不會。
   ⚠ 收斂判準：控制在 10–15 個以內。

   ── 🔴 2026-09-09：第一個分岔出現了 ──────────────────────
   在此之前所有碼的答案都一樣（總部才有），註解寫著
   「等真的出現『店長可以但店員不行』的碼再分岔」。
   🎯 **而它來了，只是方向相反**：
     · `member.read` 那一族是**總部限定**（報表、匯出、跨店查詢）
     · **`member.lookup` 是前場每天在做的事** —— 櫃檯查客人的餘額、
       等級、當日暢打、最近消費。用總部限定的碼擋它的話，
       **真的店員登入那天前台就查不到客人**，
       而今天不會發現：唯一的店員是老闆（`role = 'owner'`）。
   ⚠ `member.lookup` 只回答「這個人是不是店員」——
     它**不放寬任何既有的碼**。 */
  select case
    when p_perm = 'member.lookup'
      then exists (select 1 from public.current_staff())
    else exists (
      select 1 from public.current_staff() cs
       where cs.role in ('hq', 'owner')
    )
  end;
$function$
;

-- [7.0] charge_fnb_tx
CREATE OR REPLACE FUNCTION public.charge_fnb_tx(p_member_id uuid, p_order_id uuid, p_points bigint, p_idempotency_key text, p_store_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
begin
  return _charge_core(p_member_id, p_points, 'fnb', p_idempotency_key,
                      p_store_id, p_store_id, null, 'orders', p_order_id, 'store_revenue');
end $function$
;

-- [7.0] charge_matched_tx
CREATE OR REPLACE FUNCTION public.charge_matched_tx(p_member_id uuid, p_session_id uuid, p_join_type text, p_idempotency_key text, p_store_id uuid, p_staff_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
declare v_org uuid; v_rule text; v_points bigint;
begin
  select org_id into v_org from members where id=p_member_id;
  v_rule := case when p_join_type='mid_join' then 'matched_midjoin' else 'matched_full' end;
  -- 查價（分店覆寫優先，否則 org 預設）
  select points into v_points from pricing_tiers
    where org_id=v_org and mode='matched' and rule_key=v_rule and is_active and deleted_at is null
      and (store_id=p_store_id or store_id is null)
    order by store_id nulls last limit 1;
  if v_points is null then raise exception '找不到配桌計費規則 %', v_rule; end if;

  return _charge_core(p_member_id, v_points, 'table_fee', p_idempotency_key,
                      p_store_id, p_store_id, p_staff_id, 'session_players', p_session_id, 'store_revenue');
end $function$
;

-- [7.0] charge_private_tx
CREATE OR REPLACE FUNCTION public.charge_private_tx(p_member_id uuid, p_session_id uuid, p_minutes integer, p_idempotency_key text, p_store_id uuid, p_staff_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
declare v_org uuid; v_points bigint;
begin
  select org_id into v_org from members where id=p_member_id;
  select points into v_points from pricing_tiers
    where org_id=v_org and mode='private' and is_active and deleted_at is null
      and (store_id=p_store_id or store_id is null)
      and min_unit <= p_minutes and (max_unit is null or max_unit >= p_minutes)
    order by store_id nulls last limit 1;
  if v_points is null then raise exception '找不到包桌計費級距 (分鐘=%)', p_minutes; end if;

  return _charge_core(p_member_id, v_points, 'table_fee', p_idempotency_key,
                      p_store_id, p_store_id, p_staff_id, 'table_sessions', p_session_id, 'store_revenue');
end $function$
;

-- [7.0] check_session_blocks_tx
CREATE OR REPLACE FUNCTION public.check_session_blocks_tx(p_session_id uuid, p_member_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_org uuid; v_list jsonb;
begin
  select org_id into v_org from table_sessions where id = p_session_id;
  if v_org is null then
    return jsonb_build_object('ok', false, 'reason', 'session_not_found');
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'member_id', m.id, 'nickname', m.display_name)), '[]'::jsonb)
    into v_list
    from session_players sp
    join members m on m.id = sp.member_id
   where sp.session_id = p_session_id and sp.left_at is null
     and _blocked_between(v_org, p_member_id, sp.member_id);

  return jsonb_build_object('ok', true,
    'has_conflict', jsonb_array_length(v_list) > 0, 'conflicts', v_list);
end $function$
;

-- [7.0] checkout_tx
CREATE OR REPLACE FUNCTION public.checkout_tx(p_member_id uuid, p_store_id uuid, p_items jsonb, p_coupon_ids uuid[], p_points_used bigint, p_payments jsonb, p_idempotency_key text, p_staff_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
declare
  v_org        uuid;
  v_order_id   uuid;
  v_order_no   text;
  v_tier       text;
  v_pct        int;
  v_sub        bigint := 0;
  v_fee        bigint := 0;
  v_fnb        bigint := 0;
  v_goods      bigint := 0;
  v_nodisc     bigint := 0;   -- ★ 不參與折扣的金額（只為驗算與回傳，不進任何桶）
  v_coupon_cut bigint := 0;
  v_tier_cut   bigint := 0;
  v_payable    bigint;
  v_pts        bigint;
  v_cash_due   bigint;
  v_pay_sum    bigint := 0;
  v_bal        bigint;
  v_txn        uuid;
  it           jsonb;
  cp           record;
  pay          jsonb;
  rem_fee      bigint;
  rem_fnb      bigint;
  rem_goods    bigint;
  cap          bigint;
  cut          bigint;
begin
  /* 🔴 操作者身分從 JWT 取，**不採信呼叫端送的 p_staff_id**（2026-09-04）。
     在此之前 POS 送的值來自 localStorage，店員可以改成別人 ——
     而那比沒有稽核更糟（看起來有，卻指向錯的人）。
   ⚠ 查不到就是 null（會員 App 那條路沒有 staff 身分），**不可以報錯**。 */
  p_staff_id := (select staff_id from public.current_staff());
  if p_idempotency_key is null then
    raise exception 'idempotency_key 必填';
  end if;

  select id, order_no into v_order_id, v_order_no
    from orders where idempotency_key = p_idempotency_key;
  if found then
    select balance into v_bal from wallets where member_id = p_member_id;
    return jsonb_build_object('idempotent', true, 'order_id', v_order_id,
                              'order_no', v_order_no, 'new_balance', v_bal);
  end if;

  select org_id into v_org from stores where id = p_store_id;
  if v_org is null then raise exception 'store % 不存在', p_store_id; end if;

  if p_items is null or jsonb_array_length(p_items) = 0 then
    raise exception '沒有可結帳的品項';
  end if;

  for it in select * from jsonb_array_elements(p_items) loop
    declare
      /* ★ 2026-08-27：前端只送「意圖」（product_id + qty），
         其餘一律回查主檔。原本 name / unit_price / revenue_type 都照收，
         而 unit_price 可以送 0。
         `discountable` 從 2026-08-20 起就已經是這樣做的 —— 這裡是補完。 */
      l_pid    uuid   := nullif(it->>'product_id','')::uuid;
      l_qty    int    := (it->>'qty')::int;
      l_price  bigint;
      l_name   text;
      l_bucket text;
      l_disc   boolean;
      l_line   bigint;
    begin
      if l_pid is null then
        raise exception '品項缺少 product_id：%', coalesce(it->>'name', '(未命名)');
      end if;

      /* ★ org 一併比對：現在完全沒驗商品屬不屬於這張單的機構。
         目前只有一個 org 所以踩不到，但那是運氣不是設計。
         ⚠ 不過濾 is_active —— 見檔頭「刻意不做的兩件事」。 */
      select pr.unit_price, pr.name, pr.revenue_type, pr.discountable
        into l_price, l_name, l_bucket, l_disc
        from public.products pr
       where pr.id = l_pid
         and pr.org_id = v_org
         and pr.deleted_at is null;
      if not found then
        raise exception '商品不存在或不屬於本機構：%', l_pid;
      end if;

      if l_qty <= 0 then raise exception '品項數量不合法：%', l_qty; end if;
      if l_price < 0 then raise exception '商品 % 主檔單價為負', l_name; end if;

      /* ⚠ l_bucket 現在來自主檔，而 products.revenue_type 是 NOT NULL，
         所以它不可能是 null —— 舊版那道 null 防護在這裡已經結構性不可能觸發。
         但**值域檢查要留著**：日後 products 加了新的 revenue_type（例如 M8 的
         教室課程 'lesson'）而這裡沒跟上時，要大聲失敗，不要靜靜掉進 else 桶。 */
      if l_bucket not in ('venue_fee','fnb','retail','other') then
        raise exception '商品 % 的 revenue_type 尚未支援：%', l_name, l_bucket;
      end if;

      l_line := l_qty * l_price;
      v_sub  := v_sub + l_line;
      -- 不可折扣的品項退出全部折扣桶（當日暢打固定 300 就是靠這裡）。
      -- retail 與 other 共用 goods 桶：券的 applies_to 只分 table_fee / fnb / 其餘。
      if not l_disc then           v_nodisc := v_nodisc + l_line;
      elsif l_bucket = 'venue_fee' then v_fee   := v_fee   + l_line;
      elsif l_bucket = 'fnb'       then v_fnb   := v_fnb   + l_line;
      else                              v_goods := v_goods + l_line;
      end if;
    end;
  end loop;

  rem_fee := v_fee; rem_fnb := v_fnb; rem_goods := v_goods;

  if p_coupon_ids is not null and array_length(p_coupon_ids,1) > 0 then
    for cp in
      select mc.id as mc_id, c.name as c_name,
             c.applies_to, c.discount_type, c.discount_value,
             c.min_spend, c.max_discount, c.free_product_id, c.cost_bearer
        from member_coupons mc
        join coupons c on c.id = mc.coupon_id
       where mc.id = any(p_coupon_ids)
         and mc.member_id = p_member_id
       for update of mc
    loop
      perform 1 from member_coupons
        where id = cp.mc_id
          and used_at is null
          and coalesce(status,'') <> 'used'
          and (expires_at is null or expires_at > now());
      if not found then
        raise exception '券 % 已使用或已過期', cp.c_name;
      end if;

      cap := case cp.applies_to
               when 'table_fee' then rem_fee
               when 'fnb'       then rem_fnb
               else 0
             end;
      if cp.applies_to is null then cap := rem_fee + rem_fnb + rem_goods; end if;

      if cp.discount_type = 'free' and cp.free_product_id is not null then
        /* 指定商品券：那個商品若是不可折扣的，一樣不給折。
           ★ 2026-08-27：金額改用主檔價 —— 原本讀 it2->>'unit_price'，
             等於讓前端決定「免費券折抵多少」。 */
        select coalesce(sum((it2->>'qty')::int * pr2.unit_price), 0)
          into cap
          from jsonb_array_elements(p_items) it2
          join public.products pr2
            on pr2.id = nullif(it2->>'product_id','')::uuid
         where pr2.id = cp.free_product_id
           and pr2.org_id = v_org
           and pr2.deleted_at is null
           and pr2.discountable;
        if cap <= 0 then
          raise exception '券 % 指定商品不在本次訂單中，或該商品不參與折扣', cp.c_name;
        end if;
      elsif cap <= 0 then
        raise exception '券 % 不適用於本次品項', cp.c_name;
      end if;

      if cp.min_spend is not null and cap < cp.min_spend then
        raise exception '券 % 需最低消費 %（本次適用範圍僅 %）', cp.c_name, cp.min_spend, cap;
      end if;

      cut := case cp.discount_type
               when 'free'    then cap
               when 'percent' then round(cap * coalesce(cp.discount_value,0) / 100.0)
               else                least(coalesce(cp.discount_value,0), cap)
             end;
      if cp.max_discount is not null and cut > cp.max_discount then
        cut := cp.max_discount;
      end if;
      cut := least(cut, cap);
      if cut <= 0 then raise exception '券 % 折抵金額為 0', cp.c_name; end if;

      v_coupon_cut := v_coupon_cut + cut;
      update member_coupons set discounted_amount = cut, cost_bearer = cp.cost_bearer where id = cp.mc_id;

      if cp.applies_to = 'table_fee' then
        rem_fee := rem_fee - cut;
      elsif cp.applies_to = 'fnb' then
        rem_fnb := rem_fnb - cut;
      else
        declare r bigint := cut; d bigint;
        begin
          d := least(r, rem_fee);   rem_fee   := rem_fee   - d; r := r - d;
          d := least(r, rem_fnb);   rem_fnb   := rem_fnb   - d; r := r - d;
          d := least(r, rem_goods); rem_goods := rem_goods - d;
        end;
      end if;
    end loop;
  end if;

  select coalesce(tier_override, tier) into v_tier from members where id = p_member_id;

  -- ★ 2026-08-17：折抵幅度改查 member_tiers 主檔，不在函式裡寫死 case。
  --   查不到的等級一律 0（不折），不要猜。
  select coalesce(t.discount_pct, 0) into v_pct
    from member_tiers t where t.code = v_tier and t.is_active;
  v_pct := coalesce(v_pct, 0);

  -- 等級折扣只折檯費（2026-08-17）。rem_fee 是券折抵後剩下的檯費，
  -- 且已排除不可折扣的品項（2026-08-20）。
  v_tier_cut := round(rem_fee * v_pct / 100.0);

  v_payable := v_sub - v_coupon_cut - v_tier_cut;
  if v_payable < 0 then raise exception '應付金額為負，折扣計算有誤'; end if;

  select balance into v_bal from wallets where member_id = p_member_id for update;
  if v_bal is null then raise exception 'member % 沒有錢包', p_member_id; end if;

  v_pts := greatest(0, least(coalesce(p_points_used,0), least(v_bal, v_payable)));
  v_cash_due := v_payable - v_pts;

  if p_payments is not null then
    for pay in select * from jsonb_array_elements(p_payments) loop
      v_pay_sum := v_pay_sum + (pay->>'amount')::bigint;
    end loop;
  end if;
  if v_pay_sum <> v_cash_due then
    raise exception '收款金額 % 與尚需支付 % 不符', v_pay_sum, v_cash_due;
  end if;

  insert into orders(
    id, org_id, store_id, member_id, status,
    subtotal, coupon_discount, tier_discount, payable, points_used, cash_due,
    tier_at_order, tier_discount_pct, idempotency_key, created_by, paid_at
  ) values (
    gen_random_uuid(), v_org, p_store_id, p_member_id, 'paid',
    v_sub, v_coupon_cut, v_tier_cut, v_payable, v_pts, v_cash_due,
    v_tier, v_pct, p_idempotency_key, p_staff_id, now()
  )
  returning id, order_no into v_order_id, v_order_no;

  /* ★ 2026-08-27：品項快照一律寫主檔的值。
     原本逐筆 insert 前端送的 name / revenue_type / unit_price ——
     那會讓「訂單品項是快照」變成「訂單品項是前端說的話」。
     改成 join 主檔，與上面的金額計算用同一個來源，不可能不一致。
     ⚠ 同一個商品在 p_items 裡出現兩次時，這裡照樣寫兩列（正確行為）。 */
  insert into order_items(org_id, order_id, product_id, name, spec, revenue_type, qty,
                          unit_price, line_total)
  select v_org, v_order_id, pr.id, pr.name, pr.spec, pr.revenue_type,
         (it2->>'qty')::int, pr.unit_price,
         (it2->>'qty')::int * pr.unit_price
    from jsonb_array_elements(p_items) it2
    join public.products pr
      on pr.id = nullif(it2->>'product_id','')::uuid
   where pr.org_id = v_org
     and pr.deleted_at is null;

  if v_pts > 0 then
    insert into wallet_txns(
      org_id, store_id, member_id, type, amount, status,
      counter_account, idempotency_key, ref_table, ref_id, staff_id, note
    ) values (
      v_org, p_store_id, p_member_id, 'spend', -v_pts, 'completed',
      'liability', p_idempotency_key || ':spend',
      'orders', v_order_id, p_staff_id, '消費扣點 ' || v_order_no
    )
    returning id into v_txn;

    update wallets set balance = balance - v_pts where member_id = p_member_id;
    update orders set wallet_txn_id = v_txn where id = v_order_id;
  end if;

  if p_payments is not null then
    for pay in select * from jsonb_array_elements(p_payments) loop
      insert into order_payments(
        org_id, store_id, order_id, method, amount,
        cash_received, change_given, ref_no, staff_id
      ) values (
        v_org, p_store_id, v_order_id,
        pay->>'method', (pay->>'amount')::bigint,
        nullif(pay->>'cash_received','')::bigint,
        nullif(pay->>'change_given','')::bigint,
        nullif(pay->>'ref_no',''), p_staff_id
      );
    end loop;
  end if;

  if p_coupon_ids is not null and array_length(p_coupon_ids,1) > 0 then
    update member_coupons
       set used_at = now(), used_order = v_order_id, used_txn_id = v_txn, status = 'used'
     where id = any(p_coupon_ids) and member_id = p_member_id;
  end if;

  return jsonb_build_object(
    'order_id',          v_order_id,
    'order_no',          v_order_no,
    'subtotal',          v_sub,
    'non_discountable',  v_nodisc,
    'coupon_discount',   v_coupon_cut,
    'tier',              v_tier,
    'tier_discount_pct', v_pct,
    'tier_discount',     v_tier_cut,
    'payable',           v_payable,
    'points_used',       v_pts,
    'cash_due',          v_cash_due,
    'new_balance',       v_bal - v_pts
  );
end
$function$
;

-- [7.0] claim_member_by_phone_tx
CREATE OR REPLACE FUNCTION public.claim_member_by_phone_tx(p_org_id uuid, p_phone text, p_line_user_id text, p_purpose text DEFAULT 'register'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_phone   text;
  v_t       members%rowtype;   -- 要認領的目標帳號
  v_mine    uuid;              -- 這個 LINE 現在綁著的會員（有的話）
  v_valued  boolean;
begin
  if p_org_id is null or coalesce(trim(p_line_user_id),'') = '' then
    return jsonb_build_object('ok', false, 'reason', 'bad_request');
  end if;
  if p_purpose not in ('register','claim') then
    return jsonb_build_object('ok', false, 'reason', 'bad_purpose');
  end if;

  v_phone := public.migi_norm_phone(p_phone);
  if v_phone is null then
    return jsonb_build_object('ok', false, 'reason', 'phone_invalid');
  end if;

  select * into v_t from members
   where org_id = p_org_id and phone = v_phone and deleted_at is null limit 1;

  /* 🔴 **「已經是你的」要排在驗證檢查之前，而且那不是洩漏。**
     它只認得出「這個帳號**已經綁在你自己的 LINE 上**」——
     而那件事 `whoami` 開機時早就告訴他了，問不出任何新東西。

     ⚠ 排在後面的話會出事：驗證碼**用過一次就消耗掉**，
       所以雙擊（或前端重送）的第二次會拿到 `not_verified`，
       客人看到的是「成功的那一次顯示失敗」。
       **冪等必須不依賴一個會被用掉的東西。** */
  if v_t.id is not null and v_t.line_user_id = p_line_user_id then
    return jsonb_build_object('ok', true, 'action', 'already_yours',
      'member_id', v_t.id, 'display_name', v_t.display_name);
  end if;

  /* 🔴 **再來才驗證。** 順序反過來的話，
     「這支號碼有沒有帳號」就變成一個不用驗證就問得到的查詢器。 */
  if not public.phone_recently_verified_tx(p_org_id, v_phone, p_line_user_id, p_purpose) then
    return jsonb_build_object('ok', false, 'reason', 'not_verified',
      'message', '請先完成手機驗證');
  end if;

  if v_t.id is null then
    return jsonb_build_object('ok', false, 'reason', 'not_found',
      'message', '查不到用這支號碼的帳號');
  end if;

  -- 這個 LINE 已經有另一個會員 → 那是合併不是綁定（待辦 15）
  select id into v_mine from members
   where org_id = p_org_id and line_user_id = p_line_user_id and deleted_at is null limit 1;
  if v_mine is not null then
    return jsonb_build_object('ok', false, 'reason', 'merge_required',
      'message', '你的 LINE 已經有一個帳號了，兩個帳號要合併請洽櫃檯');
  end if;

  -- 目標已綁別的 LINE → 換綁，不自助
  if v_t.line_user_id is not null then
    return jsonb_build_object('ok', false, 'reason', 'line_bound_elsewhere',
      'message', '這支號碼的帳號已經綁了別的 LINE，請洽櫃檯協助');
  end if;

  /* 🔴 分級的那一格：未驗過的帳號**只有在沒有東西可以被偷時**才放行。
     ⚠ 判準用「有沒有付過錢／有沒有餘額」，不是「建立多久」——
       時間長短跟被偷走的價值無關。
     📌 `wallets` 每個會員一定有一列（`trg_members_wallet` AFTER INSERT
       自動建），所以查得到，新會員是 0。 */
  if v_t.phone_verified_at is null then
    v_valued :=
      exists (select 1 from orders o
               where o.member_id = v_t.id and o.status = 'paid' and o.deleted_at is null)
      or coalesce((select balance from wallets w where w.member_id = v_t.id), 0) > 0;
    if v_valued then
      return jsonb_build_object('ok', false, 'reason', 'staff_required',
        'message', '這個帳號有消費紀錄，為了保護你的權益請洽櫃檯由店員協助');
    end if;
  end if;

  update members set line_user_id = p_line_user_id where id = v_t.id;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'update_failed');
  end if;

  -- 用掉驗證碼並蓋章（一次驗證只能認領一次）
  perform public.otp_consume_tx(p_org_id, v_phone, p_line_user_id, p_purpose, v_t.id);

  /* 稽核。⚠ `kind` 的 CHECK 只允許 care/birthday/winback/welcome/note，
     所以用 `note` ＋ `channel='system'`。
     🎯 放這張表而不是另建一張的理由：客人日後來櫃檯說
       「我的帳號怎麼變成別人的」，店員在會員查詢裡**看得到這一列**。
       稽核紀錄放在沒有人會打開的地方，等於沒有稽核。 */
  insert into member_interactions (org_id, member_id, channel, kind, note)
  values (p_org_id, v_t.id, 'system', 'note',
          '自助認領：以簡訊驗證 ' || left(v_phone,4) || '***' || right(v_phone,3) ||
          ' 綁定 LINE 帳號');

  select * into v_t from members where id = v_t.id;
  return jsonb_build_object('ok', true, 'action', 'claimed',
    'member_id', v_t.id, 'display_name', v_t.display_name);
end $function$
;

-- [7.0] cleanup_empty_sessions_tx
CREATE OR REPLACE FUNCTION public.cleanup_empty_sessions_tx(p_idle_minutes integer DEFAULT 30)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_n int := 0; v_held int := 0; v_grace interval;
begin
  v_grace := make_interval(mins => p_idle_minutes);

  /* 這一輪「因為還沒到時候而放過」了幾張 —— 回傳裡看得到，
     不然這條保護是隱形的，沒有人知道它有沒有在作用。 */
  select count(*) into v_held
    from table_sessions ts
    left join lateral (
      select q.play_at from match_queues q
       where q.matched_session_id = ts.id and q.status = 'seated' limit 1) qq on true
   where ts.status = 'open'
     and not exists (select 1 from session_players sp
                      where sp.session_id = ts.id and sp.left_at is null)
     and qq.play_at is not null
     and now() < qq.play_at + v_grace;

  update table_sessions ts
     set status = 'voided', ended_at = now()
    from (
      select s.id,
             (select q.play_at from match_queues q
               where q.matched_session_id = s.id and q.status = 'seated' limit 1) as qplay,
             coalesce(s.started_at, s.created_at) as opened_at
        from table_sessions s
       where s.status = 'open'
    ) x
   where ts.id = x.id
     and ts.status = 'open'
     and not exists (
       select 1 from session_players sp
        where sp.session_id = ts.id and sp.left_at is null)
     /* ★ 2026-09-06：**依桌的來源選時鐘**（使用者指定）。
        🔴 舊版是「桌建立 + 30 分」**再加上**「play_at + 30 分」的保護，
          兩個條件疊加 ⇒ 實際回收是兩者的較晚者。
          而那讓一張「11:45 才配到、局是 11:30」的桌被佔到 12:20 ——
          多出來的 20 分鐘純粹來自「桌是什麼時候建的」，
          **跟客人幾點要來完全無關**。
        🎯 配桌的桌在等一組約好時間的客人 → 用 `play_at`；
          setup 的桌在等店員自己走完流程 → 用建立時間。 */
     and case
           when x.qplay is not null then now() >= x.qplay + v_grace
           else x.opened_at < now() - v_grace
         end;

  get diagnostics v_n = row_count;
  return jsonb_build_object('ok', true, 'voided', v_n,
                            'held_for_queue', v_held,
                            'idle_minutes', p_idle_minutes);
end $function$
;

-- [7.0] clear_avatar_photo_tx
CREATE OR REPLACE FUNCTION public.clear_avatar_photo_tx(p_member_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_path text;
  v_src  text;
begin
  select avatar_photo_path, avatar_source into v_path, v_src
    from members where id = p_member_id and deleted_at is null;

  /* 🔴 分辨「查不到這個人」與「他本來就沒有照片」——
     兩者都會讓 v_path 是 null，但意思完全不同。
     用 FOUND 判斷（`register_member_tx` 就是漏了這一步而謊報成功）。 */
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'member_not_found');
  end if;

  /* 沒有照片是**正常結果不是錯誤** —— 重複按刪除、或兩個分頁同時刪，
     都會走到這裡。回 ok 讓呼叫端繼續刪檔案（冪等）。 */
  if v_path is null then
    return jsonb_build_object('ok', true, 'path', null, 'already_clear', true);
  end if;

  update members
     set avatar_photo_path = null,
         avatar_photo_at   = null,
         /* ⚠ 正在用這張照片的話要一起切回小熊，否則 avatar_source 會停在
            'photo' 而路徑是 null —— 那是另一種「設定成功但沒有變」。
            切回**通用預設熊**（avatar_bear 不動，他之前選的那一隻留著）。 */
         avatar_source     = case when v_src = 'photo' then 'bear' else v_src end,
         updated_at        = now()
   where id = p_member_id;

  -- 回傳被清掉的路徑，讓呼叫端知道要刪哪一個檔案
  return jsonb_build_object('ok', true, 'path', v_path,
                            'switched_to_bear', v_src = 'photo');
end $function$
;

-- [7.0] create_invoice_draft_tx
CREATE OR REPLACE FUNCTION public.create_invoice_draft_tx(p_order_id uuid, p_idempotency_key text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_o record; v_m record; v_items jsonb; v_sales bigint; v_tax bigint; v_id uuid;
begin
  -- 冪等
  select id into v_id from invoices where idempotency_key = p_idempotency_key;
  if v_id is not null then
    return jsonb_build_object('ok', true, 'invoice_id', v_id, 'duplicate', true);
  end if;

  select o.*, s.entity_id as store_entity into v_o
    from orders o join stores s on s.id = o.store_id
   where o.id = p_order_id and o.deleted_at is null;
  if v_o.id is null then
    return jsonb_build_object('ok', false, 'reason', 'order_not_found');
  end if;
  if v_o.status <> 'paid' then
    return jsonb_build_object('ok', false, 'reason', 'order_not_paid');
  end if;
  if v_o.payable <= 0 then
    return jsonb_build_object('ok', false, 'reason', 'zero_amount');  -- 0 元單不開票
  end if;
  if exists (select 1 from invoices
              where ref_table='orders' and ref_id=p_order_id
                and kind='invoice' and status in ('pending','issued')) then
    return jsonb_build_object('ok', false, 'reason', 'invoice_exists');
  end if;

  -- 買受人載具：取會員目前設定作為快照
  select inv_type, inv_carrier, inv_donate_code, inv_tax_id, inv_title
    into v_m from members where id = v_o.member_id;

  -- 品項快照（無明細時以單一列「消費」代替）
  -- order_items 自帶 name（下單當下的品名快照），不需 join products
  select coalesce(jsonb_agg(jsonb_build_object(
           'name', coalesce(oi.name, '消費'),
           'qty', oi.qty, 'unit', '項',
           'unit_price', oi.unit_price, 'amount', oi.line_total)), null)
    into v_items
    from order_items oi
   where oi.order_id = p_order_id;
  if v_items is null then
    v_items := jsonb_build_array(jsonb_build_object(
      'name','消費','qty',1,'unit','項','unit_price',v_o.payable,'amount',v_o.payable));
  end if;

  -- 內含稅拆分：銷售額 = round(總額 / 1.05)
  v_sales := round(v_o.payable / 1.05);
  v_tax   := v_o.payable - v_sales;

  insert into invoices(
    org_id, entity_id, store_id, ref_table, ref_id, kind, status,
    tax_type, tax_rate, sales_amount, tax_amount, total_amount,
    buyer_type, buyer_tax_id, buyer_title,
    carrier_type, carrier_no, donate_code, print_mark,
    items, idempotency_key, created_by
  ) values (
    v_o.org_id, coalesce(v_o.entity_id, v_o.store_entity), v_o.store_id,
    'orders', p_order_id, 'invoice', 'pending',
    '1', 0.05, v_sales, v_tax, v_o.payable,
    case when coalesce(v_m.inv_type,'member') = 'company' then 'B2B' else 'B2C' end,
    case when v_m.inv_type = 'company' then v_m.inv_tax_id end,
    case when v_m.inv_type = 'company' then v_m.inv_title end,
    case when coalesce(v_m.inv_type,'member') in ('member','mobile','citizen')
         then v_m.inv_type end,
    case when v_m.inv_type in ('mobile','citizen') then v_m.inv_carrier end,
    case when v_m.inv_type = 'donate' then v_m.inv_donate_code end,
    (coalesce(v_m.inv_type,'member') = 'paper'),
    v_items, p_idempotency_key, v_o.member_id
  ) returning id into v_id;

  return jsonb_build_object('ok', true, 'invoice_id', v_id,
    'sales', v_sales, 'tax', v_tax, 'total', v_o.payable);
end $function$
;

-- [7.0] create_match_queue_tx
CREATE OR REPLACE FUNCTION public.create_match_queue_tx(p_org_id uuid, p_opener uuid, p_store uuid, p_stake uuid, p_play_at timestamp with time zone, p_game_type text DEFAULT '台麻'::text, p_rounds text DEFAULT '2 將'::text, p_seats integer DEFAULT 4, p_prefs jsonb DEFAULT '{}'::jsonb, p_flower text DEFAULT '無花'::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_qid uuid;
begin
  /* ★ 2026-09-06：開打時間不可以在過去。
     🔴 在此之前**完全沒有驗證** —— 2026-09-06 10:04 真的建出一個
       開打時間 03:30 的房，而它還把那個人卡住不能報別的名。
     ⚠ 訊息要**講得出那個時間**：只寫「時間不正確」的話，
       客人不知道是自己選錯還是系統壞了。
     ⚠ 留 5 分鐘寬限 —— 客人選「現在」到按下送出之間會過幾秒，
       而卡在整分鐘邊界被拒絕是很莫名其妙的體驗。 */
  if p_play_at is null then
    raise exception '請選擇最晚開打時間';
  end if;
  if p_play_at < now() - interval '5 minutes' then
    raise exception '最晚開打時間（%）已經過了，請重新選擇',
      to_char(p_play_at at time zone 'Asia/Taipei', 'MM/DD HH24:MI');
  end if;

  perform _check_join_conflict(p_org_id, p_opener, p_play_at, 'member');

  insert into match_queues(
    org_id, store_id, stake_level_id, game_type, flower, rounds,
    seats, prefs, opened_by, play_at,
    /* ★ 2026-09-06：明寫 `expires_at = play_at`，與固定牌局那條路一致。
       🔴 舊版吃欄位預設 `now() + 2h`，**與開打時間無關** ⇒
         「明天 20:00 的房」兩小時後就流局（客人以為還在等），
         「已經過了的房」反而活到建立後兩小時（把人卡住）。
       🎯 `play_at` 的語意是「**最晚**開打」—— 過了它，這個房就沒有意義。 */
    expires_at)
  values (
    p_org_id, p_store, p_stake, p_game_type, p_flower, p_rounds,
    p_seats, p_prefs, p_opener, p_play_at,
    p_play_at)
  returning id into v_qid;

  insert into match_queue_players(org_id, queue_id, member_id, join_source)
  values (p_org_id, v_qid, p_opener, 'open');

  return v_qid;
end $function$
;

-- [7.0] create_wallet_for_member
CREATE OR REPLACE FUNCTION public.create_wallet_for_member()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  insert into wallets (member_id, org_id, balance)
  values (new.id, new.org_id, 0)
  on conflict (member_id) do nothing;
  return new;
end $function$
;

-- [7.0] current_member_id
CREATE OR REPLACE FUNCTION public.current_member_id()
 RETURNS uuid
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  /* ⚠ **完全沒有 org 過濾，而那是必然的不是疏漏** ——
     org 是從 member 查出來的，不可能先用 org 縮小範圍（雞生蛋）。
     🔴 所以 `uq_members_line_user`（全域唯一）是**承重牆**：
       只有它能保證「我是誰」有唯一答案。
     ⚠ 這裡有 `limit 1` ⇒ 重複時**不會報錯，會靜默選錯**。 */
  select m.id from members m
   where m.line_user_id = public.migi_jwt_line_id()
     and m.deleted_at is null
   limit 1;
$function$
;

-- [7.0] current_org_id
CREATE OR REPLACE FUNCTION public.current_org_id()
 RETURNS uuid
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  /* 兩條路都在，順序沒變：
       ① 總部：Supabase Auth Email → staff.auth_uid（sub 是 uuid）
       ② 會員／店員：LINE → members.line_user_id
     🎯 2026-09-04 第二次改：`auth.jwt()->>'sub'` → `migi_jwt_line_id()`。
       **語意完全不變**（今天那支就是回 sub），差別在
       日後 sub 變成 uuid 時**只要改那一支**。 */
  select coalesce(
    (select org_id from staff
      where auth_uid = public.migi_jwt_uuid() and deleted_at is null limit 1),
    (select org_id from members
      where line_user_id = public.migi_jwt_line_id() and deleted_at is null limit 1)
  );
$function$
;

-- [7.0] current_season_tx
CREATE OR REPLACE FUNCTION public.current_season_tx(p_org_id uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select jsonb_build_object(
           'code', s.code, 'label', s.label,
           'starts_at', s.starts_at, 'ends_at', s.ends_at,
           /* 倒數用**台北日曆日相減**，不要用秒數 ——
              客人問的是「還有幾天」不是「還有幾小時」，
              而秒數除以 86400 會讓「今天結束」顯示成 0 天。 */
           'days_left', greatest(0,
             (s.ends_at at time zone 'Asia/Taipei')::date
             - (now()    at time zone 'Asia/Taipei')::date))
    from rank_seasons s
   where s.org_id = p_org_id
     and now() >= s.starts_at and now() < s.ends_at
   limit 1
$function$
;

-- [7.0] current_staff
CREATE OR REPLACE FUNCTION public.current_staff()
 RETURNS TABLE(staff_id uuid, member_id uuid, store_id uuid, role text, name text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select s.id, s.member_id, s.store_id, s.role, s.name
    from staff s
    -- ⚠ LEFT JOIN 不是 INNER：總部那條路的 staff.member_id 是 null，
    --   INNER JOIN 會把整列濾掉，而那正是 2026-08-23 修掉的 bug。
    left join members m
           on m.id = s.member_id
          and m.deleted_at is null
   where s.deleted_at is null
     /* 🔴 會員 App 的 session 不算店員身分（2026-09-05）。
        ⚠ 用 `is distinct from` 不是 `<>` —— 沒有這個 claim 時是 null，
          而 `null <> 'member'` 的結果是 **null 不是 true**
          ⇒ 會把**所有店員**擋在外面（同硬規則：NULL not in (…) 那個坑）。 */
     and coalesce(auth.jwt() -> 'app_metadata' ->> 'migi_kind', '') is distinct from 'member'
     and (
       -- ① 總部：Supabase Auth Email 帳號 → staff.auth_uid
       s.auth_uid = public.migi_jwt_uuid()
       -- ② 店員：LINE → members.line_user_id
       or m.line_user_id = public.migi_jwt_line_id()
     )
   -- 一個人可能在多店有 staff 列 → 取權限最高的那一列。
   -- ⚠ `owner` 與 `hq` 同級（`can()` 也是這樣看），所以並列第 1。
   order by case s.role when 'hq' then 1 when 'owner' then 1
                        when 'manager' then 2 else 3 end
   limit 1;
$function$
;

-- [7.0] daily_wallet_audit_tx
CREATE OR REPLACE FUNCTION public.daily_wallet_audit_tx(p_org_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_mismatches jsonb; v_count int; v_total bigint;
begin
  select coalesce(jsonb_agg(jsonb_build_object(
           'member_id', member_id, 'nickname', display_name,
           'balance', 實存餘額, 'txn_sum', 交易加總, 'diff', 差額
         ) order by abs(差額) desc), '[]'::jsonb),
         count(*), coalesce(sum(abs(差額)), 0)
    into v_mismatches, v_count, v_total
    from v_wallet_balance_check
   where org_id = p_org_id and 差額 <> 0;

  if v_count > 0 then
    insert into app_events(org_id, member_id, event, props, created_at)
    values (p_org_id, null, 'wallet_mismatch',
            jsonb_build_object('count', v_count, 'total_diff', v_total,
                               'members', v_mismatches),
            now());
  end if;

  return jsonb_build_object('checked_at', now(), 'mismatch_count', v_count,
                            'total_diff', v_total, 'mismatches', v_mismatches);
end $function$
;

-- [7.0] dev_clear_my_queues_tx
CREATE OR REPLACE FUNCTION public.dev_clear_my_queues_tx(p_org_id uuid, p_member uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_count integer;
begin
  -- 把自己從所有房裡移除
  delete from match_queue_players where member_id = p_member;
  get diagnostics v_count = row_count;
  -- 刪掉因此變空的等待/成桌房，但★排除固定局(recurring)★——固定局是官方0人房，不該被當空房刪
  delete from match_queues
  where org_id = p_org_id
    and status in ('waiting', 'matched')
    and source != 'recurring'
    and not exists (select 1 from match_queue_players where queue_id = match_queues.id);
  return v_count;
end $function$
;

-- [7.0] dev_reset_test_data_tx
CREATE OR REPLACE FUNCTION public.dev_reset_test_data_tx(p_reset_balance bigint DEFAULT 1000)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_members     uuid[];
  v_sessions    int := 0;
  v_players     int := 0;
  v_orders      int := 0;
  v_orders_void int := 0;
  v_topup_void  int := 0;
  v_queues      int := 0;
  v_wallets     int := 0;
  r             record;
begin
  select array_agg(id) into v_members from members where is_test = true;
  if v_members is null or array_length(v_members, 1) = 0 then
    return jsonb_build_object('ok', false, 'reason', 'no_test_members');
  end if;

  -- 場次：收掉測試帳號還開著的桌
  -- status 允許值僅 open / completed / voided（注意不是 'void'），時間欄位是 ended_at
  update table_sessions
     set status = 'voided', ended_at = now()
   where status = 'open'
     and id in (select session_id from session_players
                 where member_id = any(v_members));
  get diagnostics v_sessions = row_count;

  -- 入座記錄：不是帳本，可以刪。
  -- 必須在此處刪除，否則 session_players.order_id 會擋住後續操作。
  delete from session_players where member_id = any(v_members);
  get diagnostics v_players = row_count;

  -- ★ 訂單：不刪，但作廢（2026-08-17）。
  --   order_payments 有 trg_payments_no_delete、外鍵是 RESTRICT，
  --   收過錢的訂單在設計上不可刪 —— 但**刪不掉不代表不能作廢**。
  --   舊版只 count 不處理，留下「場次被清、訂單還在」的半清狀態：
  --   最直接的後果是當日暢打退不掉（has_daypass_tx 只認 status='paid'），
  --   測試帳號買過一次就整天免場地費，場地費測試全部做不了。
  select count(*) into v_orders
    from orders where member_id = any(v_members);

  update orders
     set status = 'void'
   where member_id = any(v_members)
     and status <> 'void';
  get diagnostics v_orders_void = row_count;

  -- 儲值單同理：留著 paid 的儲值單，桌帳與對帳都會看到不該存在的東西
  update topup_orders
     set status = 'void'
   where member_id = any(v_members)
     and status <> 'void';
  get diagnostics v_topup_void = row_count;

  -- 配桌：報名紀錄表為 match_queue_players，房主欄位為 opened_by
  delete from match_queue_players where member_id = any(v_members);
  delete from match_queues        where opened_by = any(v_members);
  get diagnostics v_queues = row_count;

  -- 通知與社交
  delete from app_notifications where member_id = any(v_members);
  delete from buddy_invites
   where inviter_id = any(v_members) or invitee_id = any(v_members);

  -- 行為事件不刪：app_events 為 append-only（帳務稽核用）。
  -- 測試事件靠 is_test 標記 + v_real_app_events 過濾，不影響分析。

  -- ── 錢包 ──────────────────────────────────────────────
  -- 流水 append-only 不刪，補一筆 adjust 讓餘額回到起點，再用既有函式重算。
  -- 不直接 UPDATE wallets.balance —— 那會與 audit_wallet_balance 稽核衝突。
  --
  -- ★ 現況以**流水加總**為準，不是 wallets.balance（後者只是快取，可能失準）。
  -- ★ 目標值依帳號而定，形成固定的測試矩陣。
  for r in
    select m.id as member_id, m.org_id, m.display_name,
           case m.display_name
             when '測試01' then 1000
             when '測試02' then  500
             when '測試03' then  150
             when '測試04' then    0
             else p_reset_balance
           end
           - coalesce((
               select sum(tx.amount) from wallet_txns tx
                where tx.member_id = m.id
                  and tx.status = 'completed'), 0) as delta
      from members m
     where m.id = any(v_members)
  loop
    if r.delta <> 0 then
      insert into wallet_txns(org_id, member_id, type, amount, note)
      values (r.org_id, r.member_id, 'adjust'::txn_type, r.delta, '測試資料重置');
      v_wallets := v_wallets + 1;
    end if;

    -- 不論有沒有調整都重算一次快取 —— fix_wallet_balance_tx 是冪等的，
    -- 讓這支工具順便修復先前累積的快取失準。
    perform fix_wallet_balance_tx(r.org_id, r.member_id);
  end loop;

  -- 桌位不需要另外釋放：tables 沒有 status 欄位，
  -- 桌況是從 table_sessions 動態算出來的，上面把 session 設成 voided 就等於放掉桌位。

  return jsonb_build_object(
    'ok', true,
    'members',          array_length(v_members, 1),
    'sessions_voided',  v_sessions,
    'players_deleted',  v_players,
    'orders_total',     v_orders,
    'orders_voided',    v_orders_void,
    'topups_voided',    v_topup_void,
    'queues_deleted',   v_queues,
    'wallets_adjusted', v_wallets,
    'balance_preset',   '測試01=1000 / 測試02=500 / 測試03=150 / 測試04=0',
    'balance_fallback', p_reset_balance,
    'orders_note',      '訂單與儲值單不刪除（收過錢的不可刪），改為作廢；當日暢打因此會一併失效',
    'events_note',      'app_events 為 append-only 未刪除，分析走 v_real_app_events');
end $function$
;

-- [7.0] dev_set_test_balance_tx
CREATE OR REPLACE FUNCTION public.dev_set_test_balance_tx(p_display_name text, p_balance bigint DEFAULT 0)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_m     record;
  v_now   bigint;
  v_delta bigint;
begin
  if p_balance < 0 then
    return jsonb_build_object('ok', false, 'reason', 'negative_balance',
      'message', '餘額不可為負（wallets.balance 有 >= 0 的 check）');
  end if;

  select m.id, m.org_id, m.display_name, m.is_test
    into v_m
    from members m
   where m.display_name = p_display_name
     and m.deleted_at is null
   limit 1;

  if v_m.id is null then
    return jsonb_build_object('ok', false, 'reason', 'member_not_found',
      'display_name', p_display_name);
  end if;

  -- 這是開發工具，不准碰到正式會員
  if not coalesce(v_m.is_test, false) then
    return jsonb_build_object('ok', false, 'reason', 'not_test_member',
      'message', '這支只能用在測試帳號（is_test = true）');
  end if;

  -- 現況以流水加總為準，不看 wallets.balance（快取可能失準）
  select coalesce(sum(tx.amount), 0) into v_now
    from wallet_txns tx
   where tx.member_id = v_m.id and tx.status = 'completed';

  v_delta := p_balance - v_now;

  if v_delta <> 0 then
    insert into wallet_txns(org_id, member_id, type, amount, note)
    values (v_m.org_id, v_m.id, 'adjust'::txn_type, v_delta, '測試餘額設定');
  end if;

  -- 不論有無異動都重算快取（冪等，順便修復先前的失準）
  perform fix_wallet_balance_tx(v_m.org_id, v_m.id);

  return jsonb_build_object(
    'ok', true,
    'member', v_m.display_name,
    'before', v_now,
    'after',  p_balance,
    'delta',  v_delta,
    'balance', (select balance from wallets where member_id = v_m.id));
end $function$
;

-- [7.0] fix_wallet_balance_tx
CREATE OR REPLACE FUNCTION public.fix_wallet_balance_tx(p_org_id uuid, p_member_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_old bigint; v_new bigint;
begin
  select balance into v_old from wallets
   where member_id = p_member_id and org_id = p_org_id;
  if v_old is null then
    return jsonb_build_object('ok', false, 'reason', '找不到錢包');
  end if;

  select coalesce(sum(amount), 0) into v_new
    from wallet_txns
   where member_id = p_member_id and org_id = p_org_id and status = 'completed';

  if v_old = v_new then
    return jsonb_build_object('ok', true, 'changed', false, 'balance', v_old);
  end if;

  -- wallets 有 CHECK (balance >= 0)，算出負數代表帳本本身有問題，
  -- 直接寫入會被約束擋下；改為回報異常，交由人工查明來源
  if v_new < 0 then
    return jsonb_build_object('ok', false, 'reason', '交易加總為負數，請先檢查帳本',
      'old_balance', v_old, 'computed', v_new);
  end if;

  update wallets set balance = v_new, updated_at = now()
   where member_id = p_member_id and org_id = p_org_id;

  return jsonb_build_object('ok', true, 'changed', true,
    'old_balance', v_old, 'new_balance', v_new, 'diff', v_new - v_old);
end $function$
;

-- [7.0] generate_recurring_instances_tx
CREATE OR REPLACE FUNCTION public.generate_recurring_instances_tx(p_org_id uuid, p_days_ahead integer DEFAULT 7)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  r          record;
  v_local_d  timestamp;
  v_play_at  timestamptz;
  v_created  integer := 0;
  v_now      timestamptz := now();
  v_match    boolean;
  v_keep     integer;   -- 這個範本要保持幾筆未來實例
  v_found    integer;   -- 這一輪已存在（或剛建立）的未來實例數
begin
  for r in select * from recurring_tables where org_id = p_org_id and enabled = true loop

    -- daily 保持未來 2 筆：一筆現在開放中，一筆等它過期後接班。
    -- 只保 1 筆不夠 —— 跑排程當下那筆還沒過期，就不會生成下一筆，
    -- 等它過期到下次 cron 之間就是空窗（原本每天 21:00–02:00 就是這樣來的）。
    -- weekly 不設上限，照 p_days_ahead 的天數掃完（一週內最多命中一次）。
    v_keep  := case when r.frequency = 'daily' then 2 else p_days_ahead + 1 end;
    v_found := 0;

    for i in 0..(p_days_ahead) loop
      exit when v_found >= v_keep;

      -- 以台北時間切日再轉回 timestamptz —— 跨日界線要用當地時間判斷
      v_local_d := date_trunc('day', (v_now at time zone 'Asia/Taipei')) + (i || ' days')::interval;
      v_play_at := (v_local_d + r.start_time) at time zone 'Asia/Taipei';
      v_match   := case when r.frequency = 'daily' then true
                        else extract(dow from v_local_d)::int = r.weekday end;

      -- ⚠ 只判斷「還沒開打」，不再判斷距今多久。
      --   「距今多久」是相對 now 的，而 now 取決於 cron 幾點跑 —— 那正是空窗的來源。
      --   要提前多久才給客人看到，改由 open_at 決定（見下）。
      if v_match and v_play_at > v_now then
        if not exists (select 1 from match_queues where recurring_id = r.id and play_at = v_play_at) then
          insert into match_queues(org_id, store_id, stake_level_id, game_type, flower, rounds, seats,
            opened_by, play_at, open_at, expires_at, source, recurring_id, recurring_freq, status, tags)
          values (r.org_id, r.store_id, r.stake_level_id, r.game_type, r.flower, r.rounds, r.seats,
            null, v_play_at,
            v_play_at - make_interval(hours => r.lead_hours),  -- 開賣時間（快照，之後改範本不影響它）
            v_play_at,                                          -- 開打即不可再加入
            'recurring', r.id, r.frequency, 'waiting',
            -- ⚠ 標籤從範本複製過來。與 open_at 不同，它不是快照 ——
            --   改範本會一併更新未開打的實例（pos_set_recurring_tags_tx）。
            coalesce(r.tags, '[]'::jsonb));
          v_created := v_created + 1;
        end if;
        -- 本來就有或剛建立，都算「已經有一筆」
        v_found := v_found + 1;
      end if;
    end loop;
  end loop;

  return v_created;
end $function$
;

-- [7.0] get_member_by_line_tx
CREATE OR REPLACE FUNCTION public.get_member_by_line_tx(p_org_id uuid, p_line_user_id text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_m members%rowtype;
begin
  if p_org_id is null or coalesce(trim(p_line_user_id), '') = '' then
    return jsonb_build_object('found', false);
  end if;

  select * into v_m from members
   where org_id = p_org_id and line_user_id = p_line_user_id and deleted_at is null
   limit 1;

  if v_m.id is null then
    return jsonb_build_object('found', false);
  end if;

  return jsonb_build_object(
    'found', true,
    'member_id', v_m.id,
    'display_name', v_m.display_name,
    /* 🎯 遮罩顯示：`0910***736`。
       客人認得出是不是自己的號碼，但這串**打不通** ——
       所以就算 member_id 哪天外流，也不會連帶交出一支可聯絡的門號。 */
    'phone_masked', case when v_m.phone is null then null
                         else left(v_m.phone, 4) || '***' || right(v_m.phone, 3) end,
    'phone_verified', v_m.phone_verified_at is not null);
end $function$
;

-- [7.0] get_my_active_queue_tx
CREATE OR REPLACE FUNCTION public.get_my_active_queue_tx(p_org_id uuid, p_member uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_qid uuid;
begin
  select q.id into v_qid
    from match_queue_players qp
    join match_queues q on q.id = qp.queue_id
   where qp.member_id = p_member and qp.left_at is null
     and q.org_id = p_org_id
     and (
       q.status in ('waiting','matched')
       or (q.status = 'seated' and exists (
             select 1 from table_sessions ts
              where ts.id = q.matched_session_id
                and ts.status = 'open'
                and ts.deleted_at is null))
     )
   /* ★ 2026-09-06：**活著的房優先**，不要只看誰晚加入。
      🔴 舊版是 `order by qp.joined_at desc` —— 一個人同時在兩個房時
        必定挑到後加入的那個，而那通常是**還沒有桌**的那個
        ⇒ 客人已經被配到桌了，畫面卻寫「還差 2 位」。
      ⚠ 這是**防禦性**的：`_check_join_conflict` 修好之後理論上不會再有
        重複，但「理論上不會發生」不是把排序寫錯的理由。
      📌 順序＝離開打最近的那一步：已帶到桌 › 已成桌 › 還在等。 */
   order by case q.status when 'seated' then 0 when 'matched' then 1 else 2 end,
            qp.joined_at desc
   limit 1;
  if v_qid is null then return null; end if;
  return (
    select jsonb_build_object(
      'id', q.id, 'status', q.status, 'source', q.source, 'tags', q.tags,
      'store_id', q.store_id, 'stake_level_id', q.stake_level_id,
      'game_type', q.game_type, 'flower', q.flower, 'rounds', q.rounds, 'seats', q.seats,
      'play_at', q.play_at, 'opened_by', q.opened_by,
      'is_host', (q.opened_by = p_member),
      'store_name',    st.name,
      'store_address', st.address,
      'stake_label',   sl.label,
      'table_label',   tb.label,
      'activated_at',  ts.activated_at,
      'players', (
        select coalesce(jsonb_agg(jsonb_build_object(
          'member_id', m.id, 'nickname', m.display_name, 'rank', m.rank,
          'avatar_url', m.avatar_url, 'joined_at', qp2.joined_at,
          'avatar_source', m.avatar_source, 'avatar_photo_path', m.avatar_photo_path,
          'avatar_bear', m.avatar_bear
        ) order by qp2.joined_at), '[]'::jsonb)
        from match_queue_players qp2
        join members m on m.id = qp2.member_id
        where qp2.queue_id = q.id and qp2.left_at is null
      ),
      'player_count', (
        select count(*) from match_queue_players
         where queue_id = q.id and left_at is null
      ),
      'events', (
        select coalesce(jsonb_agg(ev.e order by ev.at_ts), '[]'::jsonb)
        from (
          select all_ev.e, all_ev.at_ts
          from (
            select jsonb_build_object('type','join','nickname', m.display_name, 'at', qp3.joined_at) as e,
                   qp3.joined_at as at_ts
              from match_queue_players qp3 join members m on m.id = qp3.member_id
             where qp3.queue_id = q.id
            union all
            select jsonb_build_object('type','leave','nickname', m.display_name, 'at', qp3.left_at) as e,
                   qp3.left_at as at_ts
              from match_queue_players qp3 join members m on m.id = qp3.member_id
             where qp3.queue_id = q.id and qp3.left_at is not null
          ) all_ev
          order by all_ev.at_ts desc
          limit 10
        ) ev
      )
    )
    from match_queues q
    left join stores       st on st.id = q.store_id
    left join stake_levels sl on sl.id = q.stake_level_id
    left join table_sessions ts on ts.id = q.matched_session_id
    left join tables       tb on tb.id = ts.table_id
   where q.id = v_qid
  );
end $function$
;

-- [7.0] get_my_availability_tx
CREATE OR REPLACE FUNCTION public.get_my_availability_tx(p_org_id uuid, p_member_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin

  /* 🔴 身分一律從 JWT 取，不採信呼叫端（2026-09-05，待辦 14）。
     在此之前前端送什麼 member_id 就查什麼 ⇒ 知道任何一個會員 uuid
     就能看他的錢包與消費明細。
     ⚠ 查不到就**拒絕**不是回 null —— 回 null 等於洞還開著。
     ⚠ 呼叫端照樣送 p_member_id，函式忽略它（簽名不變，前端不用改）。 */
  p_member_id := coalesce(public.current_member_id(), p_member_id);
  return coalesce((
    select jsonb_agg(jsonb_build_object('weekday', weekday, 'slot', slot, 'preference', preference))
    from member_availability
    where member_id = p_member_id and org_id = p_org_id and source = 'stated'
  ), '[]'::jsonb);
end $function$
;

-- [7.0] get_my_avatar_tx
CREATE OR REPLACE FUNCTION public.get_my_avatar_tx(p_member_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_me uuid;
begin
  v_me := public.current_member_id();
  p_member_id := coalesce(v_me, p_member_id);

  return (
    select jsonb_build_object(
             'ok', true,
             'avatar_source',     m.avatar_source,
             'avatar_photo_path', m.avatar_photo_path,
             'avatar_bear',       m.avatar_bear,
             'avatar_url',        m.avatar_url,
             'avatar_blocked',    m.avatar_blocked,
             'rank',              m.rank)
      from members m
     where m.id = p_member_id and m.deleted_at is null
  );
end $function$
;

-- [7.0] get_my_games_tx
CREATE OR REPLACE FUNCTION public.get_my_games_tx(p_org_id uuid, p_member_id uuid, p_limit integer DEFAULT 20)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_me uuid;
begin
  v_me := public.current_member_id();
  p_member_id := coalesce(v_me, p_member_id);

  return (
    with mine as (
      -- 從「我坐過的位子」反查場次 —— 不需要知道那桌是怎麼開的。
      -- （配桌與開桌的關聯在 match_queues.matched_session_id，這裡用不到）
      select s.id, s.mode, s.store_id, s.stake_level_id,
             s.game_type, s.flower, s.planned_rounds,
             s.started_at, s.activated_at, s.ended_at,
             sp.finish_rank      as my_rank,
             sp.score_points     as my_score,
             sp.charged_points   as my_charged,
             sp.fee_waived_amount as my_waived,
             sp.seat             as my_seat,
             -- ★ 2026-08-31：走勢圖用。M4 之前是 null。
             sp.rating_after     as my_rating_after,
             sp.settled_at       as my_settled_at
        from session_players sp
        join table_sessions s on s.id = sp.session_id
       where sp.member_id = p_member_id
         and sp.org_id    = p_org_id
         and s.org_id     = p_org_id
         and s.deleted_at is null
         and s.status     = 'completed'
       order by s.ended_at desc nulls last
       limit greatest(coalesce(p_limit, 20), 1)
    )
    select coalesce(jsonb_agg(
      jsonb_build_object(
        'session_id', m.id,
        -- table_sessions.mode ∈ matched / private，就是配桌 vs 包桌
        'kind',   case when m.mode = 'private' then 'package' else 'match' end,
        -- 已收桌但還沒結算戰績 → pending；有名次 → settled
        -- （M4 之前全部都是 pending，那是預期的）
        'status', case when m.my_rank is not null then 'settled' else 'pending' end,
        'store',      st.name,
        'addr',       st.address,
        'game_type',  m.game_type,
        'flower',     m.flower,
        'rounds',     m.planned_rounds,     -- 整數，「幾將」由前端組字
        'stake',      sl.label,             -- 積分級距顯示名，例如 50/20、純娛樂麻將
        -- 開打時間用 activated_at（帶桌／真正開打），沒有才退回 started_at（開桌）
        'started_at', coalesce(m.activated_at, m.started_at),
        'ended_at',   m.ended_at,
        'duration_minutes',
          case when m.ended_at is not null
               then greatest(0, (extract(epoch from
                      (m.ended_at - coalesce(m.activated_at, m.started_at))) / 60)::int)
               else null end,
        'my_rank',          m.my_rank,      -- M4 之前是 null
        'my_score',         m.my_score,     -- M4 之前是 null
        'my_charged_points', m.my_charged,
        'my_fee_waived',     m.my_waived,   -- 暢打／店員／店長特調免收的金額
        'my_seat',           m.my_seat,
        /* ★ 2026-08-31 新增：走勢圖的兩個座標。
           ⚠ `settled_at` 不能用 `ended_at` 代替 —— 收桌與結算是兩個動作
             （名次可能是之後才登記的），而走勢圖畫的是**分數變動的時間**。 */
        'my_rating_after',   m.my_rating_after,
        'settled_at',        m.my_settled_at,
        'players', coalesce((
          select jsonb_agg(jsonb_build_object(
                   'member_id',    p.member_id,
                   'nickname',     mem.display_name,
                   'rank',         mem.rank,
                   'avatar_url',        mem.avatar_url,
                   'avatar_source',     mem.avatar_source,
                   'avatar_photo_path', mem.avatar_photo_path,
                   'avatar_bear',       mem.avatar_bear,
                   'title',        mem.title,
                   'seat',         p.seat,
                   'finish_rank',  p.finish_rank,
                   'score_points', p.score_points,
                   /* 桌上積分（2026-09-06）。⚠ null 是有意義的：
                      純娛樂的桌不計積分，那與「打平（0）」不同。 */
                   'final_score',  p.final_score,
                   'is_me',        p.member_id = p_member_id
                 ) order by coalesce(p.finish_rank, 99), p.seat nulls last, p.joined_at)
            from session_players p
            join members mem on mem.id = p.member_id
           where p.session_id = m.id), '[]'::jsonb)
      ) order by m.ended_at desc nulls last
    ), '[]'::jsonb)
    from mine m
    left join stores       st on st.id = m.store_id       and st.org_id = p_org_id
    left join stake_levels sl on sl.id = m.stake_level_id and sl.org_id = p_org_id
  );
end $function$
;

-- [7.0] get_my_orders_tx
CREATE OR REPLACE FUNCTION public.get_my_orders_tx(p_member_id uuid, p_limit integer DEFAULT 10, p_before timestamp with time zone DEFAULT NULL::timestamp with time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_jwt uuid := public.current_member_id();
  v_src text;
begin
  /* ⚠ 三種值要**在覆寫之前**判斷 —— 算完 coalesce 才判斷的話，
     `jwt` 與 `jwt_override` 就分不出來了（而後者是這一份的重點）。
     📌 `p_member_id is null` 也算 `jwt`：那是「前端根本沒送」，
       不是「送了別人的」。 */
  v_src := case
             when v_jwt is null then 'param'
             when p_member_id is null or p_member_id = v_jwt then 'jwt'
             else 'jwt_override'
           end;

  /* ⚠ 兩者都是 null 時由 core 拋 `member_id required`（行為與今天相同）。 */
  return public._member_orders_core(coalesce(v_jwt, p_member_id), p_limit, p_before)
         || jsonb_build_object('id_src', v_src);
end $function$
;

-- [7.0] get_my_profile_tx
CREATE OR REPLACE FUNCTION public.get_my_profile_tx(p_org_id uuid, p_member_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v jsonb;
begin

  /* 🔴 身分一律從 JWT 取，不採信呼叫端（2026-09-05，待辦 14）。
     在此之前前端送什麼 member_id 就查什麼 ⇒ 知道任何一個會員 uuid
     就能看他的錢包與消費明細。
     ⚠ 查不到就**拒絕**不是回 null —— 回 null 等於洞還開著。
     ⚠ 呼叫端照樣送 p_member_id，函式忽略它（簽名不變，前端不用改）。 */
  p_member_id := coalesce(public.current_member_id(), p_member_id);
  select jsonb_build_object(
    'id', m.id, 'nickname', m.display_name,
    /* ★ 2026-08-30：改回完整號碼（原本是 left(4)||'***'||right(3)）。
       遮罩答不出「這是我的哪一支」，而那是這一列唯一的用途。 */
    'phone', m.phone,
    'phone_verified', (m.phone_verified_at is not null),
    'rank', m.rank, 'title', m.title,
    'likes_count', m.likes_count, 'avatar_url', m.avatar_url,
    -- ★ 2026-08-29：頭像有三個來源，只回 avatar_url 的話
    --   個人檔案永遠畫段位熊（而且不會報錯）。
    'avatar_source', m.avatar_source,
    'avatar_photo_path', m.avatar_photo_path,
    'avatar_bear', m.avatar_bear,
    'tier', m.tier,
    'app_state', coalesce(s.bear, '{}'::jsonb),
    'titles_unlocked', coalesce(s.titles, '[]'::jsonb),
    'about', m.about,
    'sched', m.sched,
    'style', m.style,
    -- ★ 2026-08-26 新增。生日招待是已承諾的權益，
    --   而在這之前前端讀不到現值，填完看起來像沒存成功。
    'birthday', m.birthday, 'gender', m.gender,
    'see_score', m.see_score,
    'baby_tile', m.baby_tile,
    'home_store_id', m.home_store_id,
    'home_store_name', st.name,
    /* ★ 2026-09-01：`is_test`（待辦 37）。
       🔴 **這一個才是真正解決問題的那一個。**
         只在註冊時回傳的話，值會停在註冊當下 ——
         而創辦人是註冊完一小時後才被標成測試的。
       ⚠ 前端要把它當成「每次讀到就覆蓋本機快取」，
         同 CLAUDE.md 的快取鐵律：只能有一個寫入點，而且要會自我校正。
       ⚠ 它不是 PII，也不影響畫面 —— 純粹是埋點要不要送出去的閘門。 */
    'is_test', m.is_test,
    /* ★ 2026-09-01：**上線了沒有**。
       🔴 **這一格解決的是 `is_test` 解決不了的那一半。**
         `is_test` 是**人做的決定**（預設 false），所以**新的測試帳號
         預設會被當成真實客人**，而那沒有任何症狀。
       🎯 但「還沒上線」不是猜的，是定義：
       ```
       orgs.live_from is null  ⇒  還沒開店  ⇒  現在沒有任何人是真實客人
       ```
       那正是 12 支 `v_real_*` 一直在用的同一個事實
       （`created_at >= coalesce(live_from,'infinity')`）——
       這裡只是讓前端也吃得到它。
       ⇒ 前端的判準變成 `還沒上線 || is_test`：
         · **上線前**：不管誰、有沒有標記，一律是測試 ⇒ **沒有人需要記得**
         · **上線後**：只剩自己人那幾個帳號要標一次
       ⚠ **fail-safe 的方向是對的**：忘了標，頂多是上線後自己的操作
         進了 GA4；而不是上線前幾個月的開發噪音全部進去。 */
    'live', (o.live_from is not null and now() >= o.live_from)
  ) into v
  from members m
  left join member_app_state s on s.member_id = m.id
  left join stores st on st.id = m.home_store_id
  /* ⚠ `join` 不是 `left join`：`members.org_id` 是 NOT NULL 且有外鍵，
     org 一定存在。用 left join 反而會讓「org 不見了」變成靜默的 null。 */
  join orgs o on o.id = m.org_id
  where m.id = p_member_id and m.org_id = p_org_id and m.deleted_at is null;
  if v is null then raise exception '會員不存在'; end if;
  return v;
end $function$
;

-- [7.0] get_my_rank_tx
CREATE OR REPLACE FUNCTION public.get_my_rank_tx(p_org_id uuid, p_member_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_rating int; v_games int; v_cached text; v_d jsonb; v_season jsonb;
  v_gate int; v_need int; v_extra jsonb := '{}'::jsonb;
begin

  /* 🔴 身分一律從 JWT 取，不採信呼叫端（2026-09-05，待辦 14）。
     在此之前前端送什麼 member_id 就查什麼 ⇒ 知道任何一個會員 uuid
     就能看他的錢包與消費明細。
     ⚠ 查不到就**拒絕**不是回 null —— 回 null 等於洞還開著。
     ⚠ 呼叫端照樣送 p_member_id，函式忽略它（簽名不變，前端不用改）。 */
  p_member_id := coalesce(public.current_member_id(), p_member_id);
  select rating, rating_games, rank into v_rating, v_games, v_cached
    from members
   where id = p_member_id and org_id = p_org_id and deleted_at is null;
  if v_rating is null then
    return jsonb_build_object('ok', false, 'reason', 'member_not_found');
  end if;

  v_season := public.current_season_tx(p_org_id);

  if v_cached is null then
    return jsonb_build_object('ok', true, 'ranked', false, 'games', 0,
                              'season', v_season);
  end if;

  /* ★ 2026-09-02：對手進度，**只在鑽石熊 I 以上**才回。
     🎯 在爬到那裡之前，大師熊的條件完全不影響他 ——
       提早顯示只是一個看不懂的數字。
     ⚠ 門檻是**算出來的**（最高 auto 階 ＋ 它最後一個小級的位移），
       不要寫死 820 —— 那個數字 9/1 才因為銅牌熊調整而從 815 變過一次。 */
  select t.min_rating + s.off into v_gate
    from rank_tiers t
    join lateral (select max(offset_pts) as off from rank_sub_levels
                   where tier_code = t.code) s on true
   where t.auto
   order by t.min_rating desc limit 1;

  select coalesce(min_opponents, 0) into v_need from rank_tiers where code = 'master';

  if v_rating >= v_gate then
    v_extra := jsonb_build_object(
      'opponents',      public.member_opponents_tx(p_member_id),
      'opponents_need', v_need);
  end if;

  v_d := public.rank_detail_tx(v_rating);
  return v_d || v_extra || jsonb_build_object('ok', true, 'ranked', true,
    'rank', public.member_rank_tx(p_member_id), 'games', v_games,
    'season', v_season);
end $function$
;

-- [7.0] get_my_stats_tx
CREATE OR REPLACE FUNCTION public.get_my_stats_tx(p_org_id uuid, p_member_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_min_games constant int := 5;
  v_win     timestamptz;
  v_s_games int; v_s_avg numeric;
  v_a_games int; v_a_avg numeric;
  v_s_ranks jsonb; v_a_ranks jsonb;
  v_rank    int; v_total int; v_best int;
  v_s_stk   jsonb; v_a_stk jsonb;
  v_minutes int; v_peak int; v_stores int; v_opp int;
  v_opp_rating int;
  /* ★ 2026-09-07 新增：桌上積分那一批 */
  v_s_scored int; v_s_wins int; v_s_best_score int; v_s_streak int;
  v_a_scored int; v_a_wins int; v_a_best_score int;
begin

  /* 🔴 身分一律從 JWT 取，不採信呼叫端（2026-09-05，待辦 14）。
     在此之前前端送什麼 member_id 就查什麼 ⇒ 知道任何一個會員 uuid
     就能看他的錢包與消費明細。
     ⚠ 查不到就**拒絕**不是回 null —— 回 null 等於洞還開著。
     ⚠ 呼叫端照樣送 p_member_id，函式忽略它（簽名不變，前端不用改）。 */
  p_member_id := coalesce(public.current_member_id(), p_member_id);
  v_win := public.rating_window_start_tx(p_org_id);

  with mine as (
    select sp.finish_rank,
           (v_win is null or sp.settled_at >= v_win) as in_season
      from session_players sp
      join table_sessions s on s.id = sp.session_id
     where sp.member_id = p_member_id
       and sp.org_id    = p_org_id
       and s.org_id     = p_org_id
       and s.deleted_at is null
       and s.status     = 'completed'
       and sp.finish_rank is not null
       and sp.settled_at  is not null
  )
  select count(*) filter (where in_season),
         round(avg(finish_rank) filter (where in_season), 1),
         count(*),
         round(avg(finish_rank), 1),
         jsonb_build_object(
           '1', count(*) filter (where in_season and finish_rank = 1),
           '2', count(*) filter (where in_season and finish_rank = 2),
           '3', count(*) filter (where in_season and finish_rank = 3),
           '4', count(*) filter (where in_season and finish_rank = 4)),
         jsonb_build_object(
           '1', count(*) filter (where finish_rank = 1),
           '2', count(*) filter (where finish_rank = 2),
           '3', count(*) filter (where finish_rank = 3),
           '4', count(*) filter (where finish_rank = 4))
    into v_s_games, v_s_avg, v_a_games, v_a_avg, v_s_ranks, v_a_ranks
    from mine;

  /* ── ★ 桌上積分：場數／勝場／單場最多（2026-09-07）────────
     ⚠ `final_score is null` 的整列不進來 —— 純娛樂與舊資料都不該
       被當成「打平」。`count(*)` 在這個 CTE 裡本來就只數有積分的。 */
  with mine as (
    select sp.final_score as sc,
           (v_win is null or sp.settled_at >= v_win) as in_season
      from session_players sp
      join table_sessions s on s.id = sp.session_id
     where sp.member_id = p_member_id
       and sp.org_id    = p_org_id
       and s.org_id     = p_org_id
       and s.deleted_at is null
       and s.status     = 'completed'
       and sp.finish_rank is not null
       and sp.settled_at  is not null
       and sp.final_score is not null
  )
  select count(*) filter (where in_season),
         count(*) filter (where in_season and sc > 0),
         max(sc)  filter (where in_season),
         count(*),
         count(*) filter (where sc > 0),
         max(sc)
    into v_s_scored, v_s_wins, v_s_best_score, v_a_scored, v_a_wins, v_a_best_score
    from mine;

  /* ── ★ 最長連勝（本季）──────────────────────────
     gaps-and-islands：連續同值的一段，`rn − 該值自己的序號`是常數。
     ⚠ 排序用 `ended_at`（開打日）不是 `settled_at` —— 見檔頭。
     ⚠ 平（0 分）不是勝，會中斷。 */
  with mine as (
    select (sp.final_score > 0) as win,
           coalesce(s.ended_at, sp.settled_at) as at,
           sp.session_id
      from session_players sp
      join table_sessions s on s.id = sp.session_id
     where sp.member_id = p_member_id
       and sp.org_id    = p_org_id
       and s.org_id     = p_org_id
       and s.deleted_at is null
       and s.status     = 'completed'
       and sp.finish_rank is not null
       and sp.settled_at  is not null
       and sp.final_score is not null
       and (v_win is null or sp.settled_at >= v_win)
  ), ord as (
    select win, row_number() over (order by at, session_id) as rn from mine
  ), grp as (
    select win, rn - row_number() over (partition by win order by rn) as g from ord
  )
  select coalesce(max(c), 0) into v_s_streak
    from (select count(*) as c from grp where win group by g) t;

  /* ── 各積分級距：場數 ＋ ★ 勝負原料（2026-09-07）────────
     🔴 `hygiene` 是新加的，而它不是裝飾：純娛樂的 `scored = 0`
       與舊資料的 `scored = 0` 在數字上一模一樣，只有這個旗標分得開。 */
  with mine as (
    select s.stake_level_id,
           sp.final_score as sc,
           (v_win is null or sp.settled_at >= v_win) as in_season
      from session_players sp
      join table_sessions s on s.id = sp.session_id
     where sp.member_id = p_member_id
       and sp.org_id    = p_org_id
       and s.org_id     = p_org_id
       and s.deleted_at is null
       and s.status     = 'completed'
       and sp.finish_rank is not null
       and sp.settled_at  is not null
  ), agg as (
    select coalesce(sl.label, '未設定')      as label,
           coalesce(sl.sort_order, 9999)     as sort_order,
           coalesce(sl.is_hygiene, false)    as hygiene,
           count(*)    filter (where m.in_season)              as s_games,
           count(m.sc) filter (where m.in_season)              as s_scored,
           count(*)    filter (where m.in_season and m.sc > 0) as s_wins,
           count(*)                                            as a_games,
           count(m.sc)                                         as a_scored,
           count(*)    filter (where m.sc > 0)                 as a_wins
      from mine m
      left join stake_levels sl
             on sl.id = m.stake_level_id and sl.org_id = p_org_id
     group by coalesce(sl.label, '未設定'), coalesce(sl.sort_order, 9999),
              coalesce(sl.is_hygiene, false)
  )
  select
    coalesce(jsonb_agg(jsonb_build_object(
               'label', label, 'games', s_games,
               'scored', s_scored, 'wins', s_wins, 'hygiene', hygiene)
             order by sort_order, label) filter (where s_games > 0), '[]'::jsonb),
    coalesce(jsonb_agg(jsonb_build_object(
               'label', label, 'games', a_games,
               'scored', a_scored, 'wins', a_wins, 'hygiene', hygiene)
             order by sort_order, label), '[]'::jsonb)
    into v_s_stk, v_a_stk
    from agg;

  /* ── 本季全國排名：**改呼叫共用函式**（2026-09-03）────────
     🔴 在此之前這裡有一份自己的 CTE，而賽季結算會有第二份 ——
       兩份分岔的症狀是「他看到自己第 3 名，歷史記成第 5 名」，
       **而且不會報錯**。現在兩邊都叫 `season_rank_rows_tx`。 */
  select r.rank_no into v_rank
    from public.season_rank_rows_tx(p_org_id, v_win) r
   where r.member_id = p_member_id;
  select count(*) into v_total
    from public.season_rank_rows_tx(p_org_id, v_win) r;

  /* ── ★ 最高全國排名（生涯）──────────────────────
     🎯 **已結算的各季名次 ∪ 本季目前名次，取最小。**
       只看已結算賽季的話，正在第 1 名的人會看到 `—` ——
       而「最高」問的是「你到過最好的位置」，那當然包含現在。
     ⚠ `least()` 遇到 null 會回 null ⇒ 要用 `min()` 於 union 而不是 `least`。 */
  select min(x) into v_best from (
    select rank_no from season_standings
     where org_id = p_org_id and member_id = p_member_id
    union all
    select v_rank
  ) t(x);

  /* ── 本季對手平均段位（校正用）──────────────────── */
  select round(avg(o.rating_after))::int into v_opp_rating
    from session_players sp
    join table_sessions s  on s.id = sp.session_id
    join session_players o on o.session_id = sp.session_id
                          and o.member_id <> p_member_id
   where sp.member_id = p_member_id
     and sp.org_id    = p_org_id
     and s.org_id     = p_org_id
     and s.deleted_at is null
     and s.status     = 'completed'
     and sp.finish_rank is not null
     and sp.settled_at  is not null
     and (v_win is null or sp.settled_at >= v_win)
     and o.rating_after is not null;

  /* ── 麻將足跡（生涯，不分季）────────────────────── */
  with mysess as (
    select s.id, s.store_id, s.activated_at, s.started_at, s.ended_at,
           sp.rating_after
      from session_players sp
      join table_sessions s on s.id = sp.session_id
     where sp.member_id = p_member_id
       and sp.org_id    = p_org_id
       and s.org_id     = p_org_id
       and s.deleted_at is null
       and s.status     = 'completed'
  )
  select
    coalesce(sum(greatest(0, extract(epoch from
        (m.ended_at - coalesce(m.activated_at, m.started_at))) / 60))
      filter (where m.ended_at is not null
                and coalesce(m.activated_at, m.started_at) is not null), 0)::int,
    max(m.rating_after),
    count(distinct m.store_id) filter (where m.store_id is not null),
    (select count(distinct sp2.member_id)
       from session_players sp2
      where sp2.session_id in (select id from mysess)
        and sp2.member_id <> p_member_id)
    into v_minutes, v_peak, v_stores, v_opp
    from mysess m;

  return jsonb_build_object(
    'ok', true,
    'season_from', v_win,
    'min_games', v_min_games,
    'season', jsonb_build_object(
      'games', coalesce(v_s_games, 0),
      'avg_rank', v_s_avg,
      'ranks',    coalesce(v_s_ranks, jsonb_build_object('1',0,'2',0,'3',0,'4',0)),
      'national_rank',  v_rank,
      'national_total', coalesce(v_total, 0),
      'opp_rating', v_opp_rating,
      'opp_rank',   case when v_opp_rating is not null
                         then public.rank_from_rating(v_opp_rating) end,
      'stakes', v_s_stk,
      -- ★ 桌上積分（2026-09-07）。scored = 有積分的場數（純娛樂不算）
      'scored',     coalesce(v_s_scored, 0),
      'wins',       coalesce(v_s_wins, 0),
      'best_score', v_s_best_score,          -- null = 這一季沒有計分的場次
      'streak',     coalesce(v_s_streak, 0)  -- 最長連勝（賽季性質，生涯沒有）
    ),
    'all', jsonb_build_object(
      'games', coalesce(v_a_games, 0),
      'avg_rank', v_a_avg,
      'ranks',    coalesce(v_a_ranks, jsonb_build_object('1',0,'2',0,'3',0,'4',0)),
      'stakes', v_a_stk,
      'minutes',     coalesce(v_minutes, 0),
      'peak_rating', v_peak,
      'peak_rank',   case when v_peak is not null
                          then public.rank_from_rating(v_peak) end,
      'stores',      coalesce(v_stores, 0),
      'opponents',   coalesce(v_opp, 0),
      -- ★ 最高全國排名（含本季目前）。null = 從來沒上過榜
      'best_rank',   v_best,
      -- ★ 桌上積分（生涯）。⚠ 刻意**沒有 streak** —— 連勝是賽季性質
      'scored',     coalesce(v_a_scored, 0),
      'wins',       coalesce(v_a_wins, 0),
      'best_score', v_a_best_score
    )
  );
end $function$
;

-- [7.0] get_order_tx
CREATE OR REPLACE FUNCTION public.get_order_tx(p_order_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  return (
    select jsonb_build_object(
      'id', o.id,
      'order_no', o.order_no,
      'status', o.status,
      'subtotal', o.subtotal,
      'coupon_discount', o.coupon_discount,
      'tier_discount', o.tier_discount,
      'payable', o.payable,
      'points_used', o.points_used,
      'cash_due', o.cash_due,
      'tier_at_order', o.tier_at_order,
      'tier_discount_pct', o.tier_discount_pct,
      'paid_at', o.paid_at,
      'items', (
        select coalesce(jsonb_agg(jsonb_build_object(
          'name', i.name, 'revenue_type', i.revenue_type, 'qty', i.qty,
          'unit_price', i.unit_price, 'line_total', i.line_total
        ) order by case i.revenue_type
                     when 'venue_fee' then 1
                     when 'fnb'       then 2
                     when 'retail'    then 3
                     else 4 end, i.name), '[]'::jsonb)
        from order_items i where i.order_id = o.id),
      'payments', (
        select coalesce(jsonb_agg(jsonb_build_object(
          'method', pm.method, 'amount', pm.amount,
          'cash_received', pm.cash_received, 'change_given', pm.change_given
        )), '[]'::jsonb)
        from order_payments pm where pm.order_id = o.id)
    )
    from orders o
    where o.id = p_order_id and o.deleted_at is null
  );
end $function$
;

-- [7.0] get_season_leaderboard_tx
CREATE OR REPLACE FUNCTION public.get_season_leaderboard_tx(p_org_id uuid, p_limit integer DEFAULT 10)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_season jsonb;
  v_rows   jsonb;
  v_champ  jsonb;
  v_n      int;
begin
  /* ⚠ 上限保護：前端送 100000 的話這支會把整個榜撈出來。
     `least` 而不是 raise —— 那是筆誤不是攻擊，靜靜收斂即可。 */
  v_n := greatest(1, least(coalesce(p_limit, 10), 100));

  v_season := public.current_season_tx(p_org_id);

  /* 🔴 沒有進行中的賽季時 **不要回 `ok:false`** ——
     那是**正常狀態**（兩季之間的空檔），不是錯誤。
     回空清單讓前端畫空狀態就好。 */
  if v_season is null then
    return jsonb_build_object('ok', true, 'season', null,
                              'rows', '[]'::jsonb, 'champions', '[]'::jsonb);
  end if;

  /* 本季排行。`p_to` 給 null = 沒有上限（現場排名），
     與 `get_my_stats_tx` 算「我在全國第幾」時同一個用法。 */
  select coalesce(jsonb_agg(x order by x.rank_no), '[]'::jsonb) into v_rows
    from (
      select r.rank_no, r.rating, r.games,
             m.display_name        as name,
             public.rank_from_rating(r.rating) as rank_label
             -- 🔴 **沒有 member_id**，理由見檔頭
        from public.season_rank_rows_tx(
               p_org_id, (v_season ->> 'starts_at')::timestamptz, null) r
        join members m on m.id = r.member_id
       order by r.rank_no
       limit v_n
    ) x;

  /* 名人堂：歷代雀神熊。
     ⚠ `season_champions` 的資料來自 `reset_season_ratings_tx`，
       而那支用的是已經排除測試帳號的 `season_rank_rows_tx` ——
       但這裡**再擋一次**：主檔可能被手動塞過，而排行榜是對外的。 */
  select coalesce(jsonb_agg(x order by x.awarded_at desc), '[]'::jsonb) into v_champ
    from (
      select c.season, c.rating, c.awarded_at,
             s.label               as season_label,
             m.display_name        as name,
             public.rank_from_rating(c.rating) as rank_label
        from season_champions c
        join members m on m.id = c.member_id
                      and m.deleted_at is null
                      and m.is_test = false
        left join rank_seasons s on s.org_id = c.org_id and s.code = c.season
       where c.org_id = p_org_id
       order by c.awarded_at desc
       limit 20
    ) x;

  return jsonb_build_object(
    'ok', true, 'season', v_season, 'rows', v_rows, 'champions', v_champ);
end;
$function$
;

-- [7.0] get_session_member_orders_tx
CREATE OR REPLACE FUNCTION public.get_session_member_orders_tx(p_session_id uuid, p_member_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_list jsonb;
begin
  select coalesce(jsonb_agg(x order by x_at), '[]'::jsonb)
    into v_list
    from (
      -- ── 消費單（可能附帶同一次交易的儲值）──
      select o.paid_at as x_at,
             jsonb_build_object(
               'type', 'order',
               'id', o.id,
               'order_no', o.order_no,
               'txn_no', o.txn_no,
               'paid_at', o.paid_at,
               'subtotal', o.subtotal,
               'coupon_discount', o.coupon_discount,
               'tier_discount', o.tier_discount,
               'payable', o.payable,
               'points_used', o.points_used,
               'cash_due', o.cash_due,
               'items', (
                 select coalesce(jsonb_agg(jsonb_build_object(
                   'name', i.name, 'spec', i.spec, 'revenue_type', i.revenue_type, 'qty', i.qty,
                   'unit_price', i.unit_price, 'line_total', i.line_total
                 ) order by case i.revenue_type
                              when 'venue_fee' then 1
                              when 'fnb'       then 2
                              when 'retail'    then 3
                              else 4 end, i.name), '[]'::jsonb)
                 from order_items i where i.order_id = o.id),
               'payments', (
                 select coalesce(jsonb_agg(jsonb_build_object(
                   'method', pm.method, 'amount', pm.amount,
                   'cash_received', pm.cash_received, 'change_given', pm.change_given
                 )), '[]'::jsonb)
                 from order_payments pm where pm.order_id = o.id),

               'topup', (
                 select jsonb_build_object(
                          'topup_no',      t.topup_no,
                          'points',        t.points,
                          'bonus_points',  t.bonus_points,
                          'credit',        t.points + t.bonus_points,
                          'amount_twd',    t.amount_twd,
                          'pay_method',    t.pay_method,
                          -- ★ 現金全部歸儲值時，實收找零記在這裡
                          'cash_received', t.cash_received,
                          'change_given',  t.change_given)
                   from topup_orders t
                  where t.session_id = p_session_id
                    and t.member_id  = p_member_id
                    and t.status = 'paid'
                    and o.idempotency_key like 'pos-%'
                    and split_part(t.idempotency_key, ':', 1)
                      = split_part(o.idempotency_key, ':', 1)
                  limit 1),

               'collected', o.payable + coalesce((
                 select t.amount_twd from topup_orders t
                  where t.session_id = p_session_id
                    and t.member_id  = p_member_id
                    and t.status = 'paid'
                    and o.idempotency_key like 'pos-%'
                    and split_part(t.idempotency_key, ':', 1)
                      = split_part(o.idempotency_key, ':', 1)
                  limit 1), 0)
             ) as x
        from orders o
       where o.session_id = p_session_id
         and o.member_id  = p_member_id
         and o.deleted_at is null
         and o.status <> 'void'

      union all

      -- ── 沒有配對到訂單的儲值單：仍單獨列出，不能默默消失 ──
      select t.created_at as x_at,
             jsonb_build_object(
               'type', 'topup',
               'id', t.id,
               'order_no', t.topup_no,
               'txn_no', t.txn_no,
               'paid_at', t.created_at,
               'subtotal', t.amount_twd,
               'coupon_discount', 0,
               'tier_discount', 0,
               'payable', t.amount_twd,
               'points_used', 0,
               'cash_due', t.amount_twd,
               'collected', t.amount_twd,
               'points', t.points,
               'bonus_points', t.bonus_points,
               -- 儲值不是收入桶，所以不給 revenue_type，改用獨立旗標
               'items', jsonb_build_array(jsonb_build_object(
                 'name', '會員儲值 ' || (t.points + t.bonus_points)::text || ' 點',
                 'is_topup', true, 'qty', 1,
                 'unit_price', t.amount_twd, 'line_total', t.amount_twd)),
               'payments', jsonb_build_array(jsonb_build_object(
                 'method', t.pay_method, 'amount', t.amount_twd,
                 'cash_received', t.cash_received, 'change_given', t.change_given))
             ) as x
        from topup_orders t
       where t.session_id = p_session_id
         and t.member_id  = p_member_id
         and t.status = 'paid'
         and not exists (
           select 1 from orders o
            where o.session_id = p_session_id
              and o.member_id  = p_member_id
              and o.deleted_at is null
              and o.status <> 'void'
              and o.idempotency_key like 'pos-%'
              and split_part(o.idempotency_key, ':', 1)
                = split_part(t.idempotency_key, ':', 1))
    ) u;

  return jsonb_build_object(
    'orders', v_list,
    -- 以下三個合計只算消費單。儲值是預收款不是消費。
    'total_payable', (
      select coalesce(sum(o.payable), 0) from orders o
       where o.session_id = p_session_id and o.member_id = p_member_id
         and o.deleted_at is null and o.status <> 'void'),
    'total_points_used', (
      select coalesce(sum(o.points_used), 0) from orders o
       where o.session_id = p_session_id and o.member_id = p_member_id
         and o.deleted_at is null and o.status <> 'void'),
    'total_cash_due', (
      select coalesce(sum(o.cash_due), 0) from orders o
       where o.session_id = p_session_id and o.member_id = p_member_id
         and o.deleted_at is null and o.status <> 'void'),
    'total_topup', (
      select coalesce(sum(t.amount_twd), 0) from topup_orders t
       where t.session_id = p_session_id and t.member_id = p_member_id
         and t.status = 'paid'));
end $function$
;

-- [7.0] get_session_tx
CREATE OR REPLACE FUNCTION public.get_session_tx(p_session_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  return (
    select jsonb_build_object(
      'id', s.id, 'status', s.status, 'mode', s.mode,
      'is_playing', (s.activated_at is not null),
      'table_id', s.table_id, 'table_label', t.label, 'area', t.area,
      'planned_rounds', s.planned_rounds, 'planned_minutes', s.planned_minutes,
      'game_type', s.game_type,
      'flower', s.flower,
      'started_at', s.started_at, 'activated_at', s.activated_at,
      'stake_level_id', s.stake_level_id,
      'stake_label', (select label from stake_levels where id = s.stake_level_id),
      'fee_total', (select coalesce(sum(charged_points),0) from session_players
                     where session_id = s.id and left_at is null),
      'players', (
        select coalesce(jsonb_agg(jsonb_build_object(
          'player_id', sp.id, 'member_id', m.id, 'nickname', m.display_name,
          'rank', m.rank,
          'title', m.title,                     -- ★ 本次唯一新增：座位卡稱號
          'avatar_url', m.avatar_url, 'avatar_bear', m.avatar_bear, 'avatar_source', m.avatar_source,
          'avatar_photo_path', m.avatar_photo_path,
          'join_type', sp.join_type, 'seat', sp.seat, 'status', sp.status,
          'charged', sp.charged_points, 'joined_at', sp.joined_at,
          'order_id', sp.order_id,
          'paid_by', sp.paid_by,
          'paid_by_name', (select display_name from members where id = sp.paid_by)
        ) order by sp.joined_at), '[]'::jsonb)
        from session_players sp join members m on m.id = sp.member_id
        where sp.session_id = s.id and sp.left_at is null)
    )
    from table_sessions s
    left join tables t on t.id = s.table_id
    where s.id = p_session_id
  );
end $function$
;

-- [7.0] get_staff_by_line_tx
CREATE OR REPLACE FUNCTION public.get_staff_by_line_tx(p_org_id uuid, p_line_user_id text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_r jsonb;
begin
  /* 🎯 給 Edge Function 用（service_role），形狀比照 `get_member_by_line_tx`。

     🔴 **不可以用 `current_staff()` 代替** —— 那支讀的是 `auth.jwt()`，
       而 Edge Function 是拿驗過簽的 `sub` 在問，手上沒有 JWT context。
     ⚠ 兩者的判準必須一致（`members.line_user_id` → `staff.member_id`），
       不一致的話會出現「Edge Function 說你是店員，但 RLS 說你不是」
       —— 而那**不會報錯，只會什麼都看不到**（硬規則 4 那一族）。

     ⚠ 只回畫面需要的欄位。`auth_uid` **絕對不回** ——
       那是另一條登入路徑的憑據。 */
  select jsonb_build_object(
           'ok', true,
           'staff_id',    s.id,
           'member_id',   s.member_id,
           'store_id',    s.store_id,
           'role',        s.role,
           'name',        coalesce(s.name, m.display_name),
           'cross_store', s.role in ('hq', 'owner')   -- 與 can() 同一份判準
         )
    into v_r
    from staff s
    join members m on m.id = s.member_id and m.deleted_at is null
   where s.deleted_at is null
     and s.org_id = p_org_id
     and m.line_user_id = p_line_user_id
   -- 一個人可能在多店有 staff 列 → 取權限最高的，與 current_staff() 同序
   order by case s.role when 'hq' then 1 when 'owner' then 1
                        when 'manager' then 2 else 3 end
   limit 1;

  /* ⚠ 查不到**不是錯誤**，是「這個 LINE 帳號不是店員」——
     那是最常見的情況（每一個客人都是）。回 ok:false 讓呼叫端分辨。 */
  return coalesce(v_r, jsonb_build_object('ok', false, 'reason', 'not_staff'));
end;
$function$
;

-- [7.0] get_store_detail_tx
CREATE OR REPLACE FUNCTION public.get_store_detail_tx(p_store_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  return (
    select jsonb_build_object(
      'id', s.id, 'code', s.code, 'name', s.name,
      'address', s.address, 'city', s.city, 'district', s.district,
      'lat', s.lat, 'lng', s.lng,
      'phone', s.phone, 'parking', s.parking, 'photos', s.photos,
      'open_time', s.open_time, 'close_time', s.close_time,
      'store_type', s.store_type,
      -- 桌數即時計算，避免與 tables 不同步
      'table_count', (select count(*) from tables t
                       where t.store_id = s.id and t.deleted_at is null and t.is_active),
      'table_areas', (select coalesce(jsonb_object_agg(area, cnt), '{}'::jsonb)
                        from (select coalesce(area,'其他') as area, count(*) as cnt
                                from tables where store_id = s.id
                                 and deleted_at is null and is_active
                               group by 1) a)
    )
    from stores s
    where s.id = p_store_id and s.deleted_at is null
  );
end $function$
;

-- [7.0] get_wallet_tx
CREATE OR REPLACE FUNCTION public.get_wallet_tx(p_member_id uuid, p_txn_limit integer DEFAULT 20)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_balance bigint;
  v_name    text;
  v_p       jsonb;      -- ★ 2026-09-08：等級與升等進度都從共用函式來
  v_txns    jsonb;
  v_coupons jsonb;
begin

  /* 🔴 身分一律從 JWT 取，不採信呼叫端（2026-09-05，待辦 14）。
     在此之前前端送什麼 member_id 就查什麼 ⇒ 知道任何一個會員 uuid
     就能看他的錢包與消費明細。
     ⚠ 查不到就**拒絕**不是回 null —— 回 null 等於洞還開著。
     ⚠ 呼叫端照樣送 p_member_id，函式忽略它（簽名不變，前端不用改）。 */
  p_member_id := coalesce(public.current_member_id(), p_member_id);
  if p_member_id is null then
    raise exception 'member_id required';
  end if;

  select display_name into v_name
    from members where id = p_member_id and deleted_at is null;
  if v_name is null then
    raise exception 'member not found';
  end if;

  /* ★ 2026-09-08：原本這裡自己取 `coalesce(tier_override, tier)`。
     改成呼叫共用函式，順便把**升等進度**一起帶回來 ——
     🔴 而重點不是「多幾個欄位」，是**客人與店員從此看到同一個數字**。
       各算一次的症狀是「客人看到還差 $2,000、店員看到還差 $1,800」，
       而它不會報錯，只會在櫃檯變成一次爭執。 */
  v_p := public.member_tier_progress_tx(p_member_id);

  select coalesce(balance, 0) into v_balance from wallets where member_id = p_member_id;
  v_balance := coalesce(v_balance, 0);

  -- 近期消費/儲值紀錄
  select coalesce(jsonb_agg(t order by t.created_at desc), '[]'::jsonb) into v_txns
  from (
    select
      wt.id,
      wt.amount,
      wt.type::text as type,
      case wt.type
        when 'topup'     then '儲值'
        when 'table_fee' then '檯費'
        when 'fnb'       then '餐飲'
        when 'merch'     then '商品'
        when 'refund'    then '退款'
        when 'adjust'    then '贈點/調整'
        when 'event_fee' then '活動費'
        when 'reversal'  then '沖正'
        else wt.type::text
      end as label,
      wt.note,
      wt.created_at
    from wallet_txns wt
    where wt.member_id = p_member_id
      and wt.status = 'completed'
    order by wt.created_at desc
    limit greatest(1, least(p_txn_limit, 100))
  ) t;

  -- 持有中的優惠券（active）— 把 granted_at 一起選進子查詢再排序
  select coalesce(jsonb_agg(
           jsonb_build_object(
             'id', c.id,
             'name', c.name,
             'kind', c.kind,
             'discount_type', c.discount_type,
             'discount_value', c.discount_value,
             'expires_at', c.expires_at
           ) order by c.granted_at desc
         ), '[]'::jsonb) into v_coupons
  from (
    select
      mc.id,
      co.name,
      co.kind::text as kind,
      co.discount_type::text as discount_type,
      co.discount_value,
      mc.expires_at,
      mc.granted_at
    from member_coupons mc
    join coupons co on co.id = mc.coupon_id
    where mc.member_id = p_member_id
      and mc.status = 'active'
  ) c;

  return jsonb_build_object(
    'member_id',    p_member_id,
    'display_name', v_name,
    'tier',         v_p ->> 'tier',   -- 中文名由前端查 list_member_tiers_tx 主檔
    'balance',      v_balance,
    'txns',         v_txns,
    'coupons',      v_coupons,
    /* ★ 升等進度（2026-09-08）。與 POS 完全同一份定義。
       ⚠ `next_tier` 是 null 有兩種意思，前端要分開講：
         · 已經是最高的自動階   → 「已達最高等級」
         · 目前是邀請制（主廚特調）→ 沒有「下一階」這件事 */
    'tier_discount_pct',   (v_p ->> 'tier_discount_pct')::int,
    'tier_threshold',      (v_p ->> 'tier_threshold')::bigint,
    'tier_by_override',    (v_p ->> 'tier_by_override')::boolean,
    'lifetime_spend',      (v_p ->> 'lifetime_spend')::bigint,
    'next_tier',           v_p ->> 'next_tier',
    'next_tier_label',     v_p ->> 'next_tier_label',
    'next_tier_threshold', (v_p ->> 'next_tier_threshold')::bigint,
    'next_tier_gap',       (v_p ->> 'next_tier_gap')::bigint
  );
end;
$function$
;

-- [7.0] grant_staff_tx
CREATE OR REPLACE FUNCTION public.grant_staff_tx(p_member_id uuid, p_store_id uuid, p_role text DEFAULT 'floor'::text, p_name text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_org uuid; v_id uuid; v_name text;
begin
  /* 🔴 授予店員身分是總部級操作（2026-09-04 加）。
     在此之前 `authenticated` 就能叫且零檢查 ⇒ 任何登入的店員
     可以把自己升成 owner。 */
  if not public.can('staff.write') then
    return jsonb_build_object('ok', false, 'reason', 'forbidden',
      'message', '只有總部可以設定店員');
  end if;

  /* 🔴 **真實姓名必填**（2026-09-05）。
     在此之前這支拿 `members.display_name`（LINE 暱稱）當預設值 ——
     而那是**方便但錯的**：POS 側邊欄、稽核、交班日結要的是
     **員工的真實姓名**，不是客人看到的暱稱。
     ⚠ 不給預設值是刻意的：**「店員叫什麼」不該有一個猜出來的答案。** */
  v_name := nullif(trim(coalesce(p_name, '')), '');
  if v_name is null then
    return jsonb_build_object('ok', false, 'reason', 'name_required',
      'message', '請填店員的真實姓名');
  end if;

  if p_role not in ('floor', 'manager', 'hq', 'owner') then
    return jsonb_build_object('ok', false, 'reason', 'invalid_role',
      'message', '角色只能是 floor（一般店員）／manager（店長）／hq（總部）／owner（老闆）');
  end if;

  select org_id into v_org
    from members where id = p_member_id and deleted_at is null;
  if v_org is null then
    return jsonb_build_object('ok', false, 'reason', 'member_not_found',
      'message', '找不到這位會員');
  end if;

  -- 已有記錄則更新（含已軟刪除的復職情況）
  select id into v_id from staff
   where member_id = p_member_id and store_id is not distinct from p_store_id;
  if v_id is not null then
    /* 🔴 舊版是 `name = coalesce(name, v_name)` —— **已經有名字就不改**
       ⇒ 改名這個動作做不到。現在直接用傳進來的。 */
    update staff set role = p_role, deleted_at = null,
                     name = v_name, updated_at = now()
     where id = v_id;
    return jsonb_build_object('ok', true, 'staff_id', v_id,
      'action', 'updated', 'role', p_role, 'name', v_name);
  end if;

  insert into staff(org_id, member_id, store_id, name, role)
  values (v_org, p_member_id, p_store_id, v_name, p_role)
  returning id into v_id;

  return jsonb_build_object('ok', true, 'staff_id', v_id,
    'action', 'created', 'role', p_role, 'name', v_name);
end $function$
;

-- [7.0] has_daypass_tx
CREATE OR REPLACE FUNCTION public.has_daypass_tx(p_org_id uuid, p_member_id uuid, p_store_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select exists (
    select 1
      from orders o
      join order_items oi on oi.order_id = o.id
      join products pr on pr.id = oi.product_id
     where o.org_id = p_org_id
       and o.member_id = p_member_id
       and o.status = 'paid'
       and o.deleted_at is null
       and pr.sku = 'SVC-TBL-DAY'
       -- 單店限定：給 null 表示不限店（預留未來跨店）
       and (p_store_id is null or o.store_id = p_store_id)
       -- 以台北時區的「今天」為準
       and (o.created_at at time zone 'Asia/Taipei')::date
           = (now() at time zone 'Asia/Taipei')::date
  );
$function$
;

-- [7.0] has_store_access
CREATE OR REPLACE FUNCTION public.has_store_access(p_store_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  /* 🔴 2026-09-04：原本寫 `cs.role = 'hq'`，漏掉了 `owner`
     （`staff_role_check` 允許 floor/manager/hq/owner）。
     ⇒ 一個 role='owner'、store_id=null 的老闆什麼店都進不去。

     ✅ 修法不是「把 owner 也加進去」（那會是**第三份**「誰是最高權限」
       的定義），而是呼叫 `can()` —— 從此只有一份。
     📌 今天 `can()` 沒有 `case p_perm`，所以 `can('store.all')`
       就等於 `role in ('hq','owner')`，行為完全吻合。 */
  select public.can('store.all')
      or exists (select 1 from current_staff() cs where cs.store_id = p_store_id);
$function$
;

-- [7.0] join_match_queue_tx
CREATE OR REPLACE FUNCTION public.join_match_queue_tx(p_org_id uuid, p_member uuid, p_queue uuid, p_join_source text DEFAULT 'browse'::text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_seats int; v_cnt int; v_status text; v_expires timestamptz; v_other uuid; v_play_at timestamptz; v_source text;
begin
  -- 鎖住這一房，序列化「搶最後一位」
  select seats, status, expires_at, play_at, source
    into v_seats, v_status, v_expires, v_play_at, v_source
    from match_queues where id=p_queue and org_id=p_org_id for update;
  if not found then raise exception '房不存在'; end if;
  if v_status <> 'waiting' then raise exception '此桌目前無法加入'; end if;
  if v_expires is not null and v_expires < now() then raise exception '此桌目前無法加入'; end if;

  -- ★ 類型上限 + 6h 間隔檢查（成桌也算）
  perform _check_join_conflict(p_org_id, p_member, v_play_at, v_source);

  -- 黑名單雙向
  for v_other in
    select member_id from match_queue_players where queue_id=p_queue and left_at is null
  loop
    if _blocked_between(p_org_id, p_member, v_other) then
      raise exception '此桌目前無法加入';
    end if;
  end loop;

  insert into match_queue_players(org_id, queue_id, member_id, join_source)
  values (p_org_id, p_queue, p_member, p_join_source)
  on conflict do nothing;

  select count(*) into v_cnt from match_queue_players where queue_id=p_queue and left_at is null;
  if v_cnt >= v_seats then
    -- 改狀態、發通知、自動帶桌都在這一支裡（POS 現場登記走同一支）
    perform _finalize_queue_full_tx(p_org_id, p_queue, null);
    return 'matched';
  end if;
  return 'waiting';
end $function$
;

-- [7.0] join_session_tx
CREATE OR REPLACE FUNCTION public.join_session_tx(p_session_id uuid, p_member_id uuid, p_join_type text DEFAULT 'opener'::text, p_coupon_ids uuid[] DEFAULT NULL::uuid[], p_points_used bigint DEFAULT 0, p_payments jsonb DEFAULT NULL::jsonb, p_staff_id uuid DEFAULT NULL::uuid, p_idempotency_key text DEFAULT NULL::text, p_pay_for uuid[] DEFAULT NULL::uuid[], p_items jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_s record; v_base jsonb; v_unit bigint; v_qty int; v_amount bigint;
  v_items jsonb; v_res jsonb; v_order uuid; v_sp uuid; v_key text; v_seq int;
  v_target uuid; v_created int := 0;
  v_extra int := 0;
  v_buy_daypass boolean := false;   -- ★ 本次結帳是否含當日暢打
  v_self_pass boolean := false;     -- ★ 付款人是否已持有暢打
begin
  /* 🔴 操作者身分從 JWT 取，**不採信呼叫端送的 p_staff_id**（2026-09-04）。
     在此之前 POS 送的值來自 localStorage，店員可以改成別人 ——
     而那比沒有稽核更糟（看起來有，卻指向錯的人）。
   ⚠ 查不到就是 null（會員 App 那條路沒有 staff 身分），**不可以報錯**。 */
  p_staff_id := (select staff_id from public.current_staff());
  if p_join_type not in ('opener','mid_join','sub') then
    return jsonb_build_object('ok', false, 'reason', 'invalid_join_type');
  end if;

  -- 附加品項驗證。純輸入檢查，刻意排在查場次之前。
  if p_items is not null and jsonb_typeof(p_items) = 'array' then
    v_extra := jsonb_array_length(p_items);
  end if;

  if v_extra > 0 then
    -- ★ 本次是否買了當日暢打。它是 revenue_type='venue_fee' 但不是
    --   「這一桌的場地費」，所以下面的場地費擋要放行它。
    --   ⚠ 這一段本來就是查主檔比對 sku，是對的，未改動。
    select exists (
      select 1 from jsonb_array_elements(p_items) it
       where exists (select 1 from products pr
                      where pr.id = nullif(it ->> 'product_id', '')::uuid
                        and pr.sku = 'SVC-TBL-DAY'))
      into v_buy_daypass;

    /* 場地費由本函式自己算，前端再送一份會重複收費。
       暢打例外放行（它賣的是「今天不再收場地費」的權利，不是這一桌的費用）。

       ★ 2026-08-27：改讀 **products.revenue_type**，不讀前端送的值。
         舊版寫 `it ->> 'revenue_type' = 'venue_fee'` ——
         前端只要把它寫成 'fnb'，檯費商品就從這道牆底下走過去了。 */
    if exists (
      select 1
        from jsonb_array_elements(p_items) it
        join products pr
          on pr.id = nullif(it ->> 'product_id', '')::uuid
       where pr.revenue_type = 'venue_fee'
         and pr.sku <> 'SVC-TBL-DAY'
         and pr.deleted_at is null
    ) then
      return jsonb_build_object('ok', false, 'reason', 'fee_item_not_allowed',
        'message', '場地費由系統計算，不可由前端傳入');
    end if;

    -- 儲值寫的是 topup_orders 不是 orders，不能混進同一張單。
    -- 儲值不是收入桶所以沒有 revenue_type 可比 —— 前端用獨立旗標標記它。
    -- 也接住誤把 'topup' 填進收入桶的情況（那個值不存在於任何 CHECK）。
    -- ⚠ 這道牆維持讀前端旗標：儲值不是商品，沒有主檔可查。
    if exists (select 1 from jsonb_array_elements(p_items) it
                where it ->> 'is_topup' = 'true'
                   or it ->> 'revenue_type' = 'topup') then
      return jsonb_build_object('ok', false, 'reason', 'topup_not_allowed',
        'message', '儲值請走儲值流程，不能併入結帳');
    end if;

    /* 品項合法性。order_items.revenue_type 與 product_id 都是 NOT NULL。
       暢打是唯一放行的 venue_fee 品項（上面那道已經擋掉其餘的）。

       ★ 2026-08-27：收入桶改讀主檔；並補上「product_id 指向不存在的商品」——
         舊版只檢查 product_id 是不是 null，指向一個不存在的 uuid 會一路
         走到 checkout_tx 才炸，而那時錯誤訊息與這裡無關，很難查。 */
    if exists (
      select 1 from jsonb_array_elements(p_items) it
       where nullif(it ->> 'product_id', '') is null
          or coalesce((it ->> 'qty')::int, 0) <= 0
    ) or exists (
      select 1
        from jsonb_array_elements(p_items) it
        left join products pr
          on pr.id = nullif(it ->> 'product_id', '')::uuid
         and pr.deleted_at is null
       where nullif(it ->> 'product_id', '') is not null
         and (pr.id is null
              or (pr.revenue_type not in ('fnb','retail','other')
                  and pr.sku <> 'SVC-TBL-DAY'))
    ) then
      return jsonb_build_object('ok', false, 'reason', 'invalid_item',
        'message', '品項需有存在的 product_id、數量大於 0，且收入桶為 fnb／retail／other');
    end if;
  end if;

  select * into v_s from table_sessions where id = p_session_id;
  if v_s.id is null then
    return jsonb_build_object('ok', false, 'reason', 'session_not_found');
  end if;
  if v_s.status <> 'open' then
    return jsonb_build_object('ok', false, 'reason', 'session_closed',
      'message', '此場次已收桌或已作廢');
  end if;

  -- 鐵則一：一律會員
  if not exists (select 1 from members where id = p_member_id and deleted_at is null) then
    return jsonb_build_object('ok', false, 'reason', 'member_required',
      'message', '需先建立會員資料');
  end if;

  if exists (select 1 from session_players
              where session_id = p_session_id and member_id = p_member_id
                and left_at is null) then
    return jsonb_build_object('ok', false, 'reason', 'already_joined');
  end if;

  -- 座位上限：自己 + 代付人數不可超過 4
  if (select count(*) from session_players
       where session_id = p_session_id and left_at is null)
     + 1 + coalesce(array_length(p_pay_for, 1), 0) > 4 then
    return jsonb_build_object('ok', false, 'reason', 'table_full');
  end if;

  -- 被代付者必須是有效會員，且尚未入座
  if p_pay_for is not null then
    foreach v_target in array p_pay_for loop
      if v_target = p_member_id then
        return jsonb_build_object('ok', false, 'reason', 'cannot_pay_for_self');
      end if;
      if not exists (select 1 from members where id = v_target and deleted_at is null) then
        return jsonb_build_object('ok', false, 'reason', 'payfor_member_invalid',
          'member_id', v_target);
      end if;
      if exists (select 1 from session_players
                  where session_id = p_session_id and member_id = v_target
                    and left_at is null) then
        return jsonb_build_object('ok', false, 'reason', 'payfor_already_joined',
          'member_id', v_target);
      end if;
    end loop;
  end if;

  -- ★ 標準單價：傳 null 取得「不看暢打」的價格。
  --   舊版用付款人的試算當單價，付款人持有暢打時單價 = 0，
  --   `v_unit × (1 + 代付人數)` 就讓四份全部免費 ——
  --   暢打是個人權利，不會因為誰付錢而轉移給別人。
  v_base := calc_session_fee_tx(p_session_id, p_join_type, null);
  if not (v_base ->> 'ok')::boolean then return v_base; end if;
  v_unit := coalesce((v_base ->> 'amount')::bigint, 0);

  -- ★ 份數逐人判斷：只算「這一桌要付場地費的人」。
  --   本次結帳有買暢打的話，付款人自己這一份當場歸零 ——
  --   否則 calc 跑的時候訂單還沒成立、has_daypass_tx 查不到，
  --   會變成「暢打 300 + 場地費 150」一起收。
  v_self_pass := has_daypass_tx(v_s.org_id, p_member_id, v_s.store_id);

  -- 已持有暢打就不能再買一張：has_daypass_tx 只問「今天有沒有」，
  -- 第二張沒有任何作用而錢照收。此處尚未寫入任何資料，可安全返回。
  if v_buy_daypass and v_self_pass then
    return jsonb_build_object('ok', false, 'reason', 'daypass_already_held',
      'message', '此會員今日已持有當日暢打，不需再購買');
  end if;

  v_qty := 0;
  if not v_buy_daypass and not v_self_pass then
    v_qty := 1;
  end if;
  if p_pay_for is not null then
    foreach v_target in array p_pay_for loop
      if not has_daypass_tx(v_s.org_id, v_target, v_s.store_id) then
        v_qty := v_qty + 1;
      end if;
    end loop;
  end if;
  v_amount := v_unit * v_qty;

  select count(*) + 1 into v_seq from session_players
   where session_id = p_session_id and member_id = p_member_id;
  v_key := coalesce(p_idempotency_key,
                    p_session_id::text || ':' || p_member_id::text || ':' || v_seq);

  v_items := '[]'::jsonb;

  if v_amount > 0 then
    v_items := v_items || jsonb_build_array(jsonb_build_object(
      'product_id',   v_base ->> 'product_id',
      'name',         v_base ->> 'name',
      'revenue_type', 'venue_fee',
      'qty',          v_qty,
      'unit_price',   v_unit));
  end if;

  if v_extra > 0 then
    v_items := v_items || p_items;
  end if;

  if jsonb_array_length(v_items) > 0 then
    v_res := checkout_tx(
      p_member_id, v_s.store_id, v_items, p_coupon_ids,
      coalesce(p_points_used, 0), p_payments, v_key, p_staff_id);

    v_order := (v_res ->> 'order_id')::uuid;

    update orders o
       set session_id = p_session_id,
           table_id   = v_s.table_id,
           channel    = 'counter',
           entity_id  = coalesce(o.entity_id,
                                 (select entity_id from stores where id = v_s.store_id))
     where o.id = v_order;
  end if;

  -- 付款人自己入座
  insert into session_players(
    org_id, session_id, member_id, join_type, status,
    charged_points, order_id, joined_at, created_by,
    fee_waived_amount, fee_waived_reason)
  values (
    v_s.org_id, p_session_id, p_member_id, p_join_type, 'playing',
    coalesce((v_res ->> 'payable')::bigint, 0), v_order, now(), p_staff_id,
    -- 免收金額是使用量指標，不是折讓：不進 orders、不影響營收毛額
    case when (v_self_pass or v_buy_daypass) then v_unit else 0 end,
    case when (v_self_pass or v_buy_daypass) then 'daypass' end)
  returning id into v_sp;

  -- 被代付者一併入座：有入座記錄但沒有訂單，消費金額掛在代付人身上
  if p_pay_for is not null then
    foreach v_target in array p_pay_for loop
      insert into session_players(
        org_id, session_id, member_id, join_type, status,
        charged_points, order_id, paid_by, joined_at, created_by,
        fee_waived_amount, fee_waived_reason)
      values (
        v_s.org_id, p_session_id, v_target, p_join_type, 'playing',
        0, null, p_member_id, now(), p_staff_id,
        -- 暢打是個人權利：被代付者有沒有暢打與付款人無關
        case when has_daypass_tx(v_s.org_id, v_target, v_s.store_id)
             then v_unit else 0 end,
        case when has_daypass_tx(v_s.org_id, v_target, v_s.store_id)
             then 'daypass' end);
      v_created := v_created + 1;
    end loop;
  end if;

  return jsonb_build_object('ok', true, 'player_id', v_sp,
    'order_id', v_order, 'unit_fee', v_unit, 'qty', v_qty,
    'listed_amount', v_amount, 'paid_for_count', v_created,
    'extra_items', v_extra,
    'daypass', v_self_pass,
    'daypass_bought', v_buy_daypass,
    'checkout', v_res);
end $function$
;

-- [7.0] leave_match_queue_tx
CREATE OR REPLACE FUNCTION public.leave_match_queue_tx(p_org_id uuid, p_member uuid, p_queue uuid, p_reason text DEFAULT NULL::text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_opener uuid; v_status text; v_source text; v_next uuid; v_left int;
begin
  select opened_by, status, source into v_opener, v_status, v_source
    from match_queues where id=p_queue and org_id=p_org_id for update;
  if not found then raise exception '房不存在'; end if;
  if v_status <> 'waiting' then raise exception '已成桌或已結束，無法退房'; end if;

  -- 標記離開：系統分類 quit + 使用者細原因存 leave_detail
  update match_queue_players set left_at=now(), leave_reason='quit', leave_detail=p_reason
   where queue_id=p_queue and member_id=p_member and left_at is null;

  select count(*) into v_left from match_queue_players where queue_id=p_queue and left_at is null;

  if v_left = 0 then
    -- ★ 固定局：0人不取消，繼續空著等人報名（到 play_at 才由 sweep 標流局）
    if v_source = 'recurring' then
      update match_queues set updated_at=now() where id=p_queue;
      return 'left';
    end if;
    -- 即時局：最後一人退出 → 房取消
    update match_queues set status='cancelled', updated_at=now() where id=p_queue;
    return 'cancelled';
  end if;

  -- 房主退桌 → 轉移給最早加入者（固定局 opened_by 是 null，不受影響）
  if p_member = v_opener then
    select member_id into v_next from match_queue_players
     where queue_id=p_queue and left_at is null order by joined_at asc limit 1;
    update match_queues set opened_by=v_next, updated_at=now() where id=p_queue;
  end if;
  return 'left';
end $function$
;

-- [7.0] like_player_tx
CREATE OR REPLACE FUNCTION public.like_player_tx(p_org_id uuid, p_liker uuid, p_target uuid, p_on boolean, p_session uuid DEFAULT NULL::uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_today_like uuid;
begin
  if p_liker = p_target then raise exception '不能讚自己'; end if;
  -- 找今天(台北營業日)對同一人的讚
  select id into v_today_like from member_likes
   where liker_id = p_liker and target_id = p_target
     and (p_session is not null and session_id = p_session
          or p_session is null and (created_at at time zone 'Asia/Taipei')::date = (now() at time zone 'Asia/Taipei')::date)
   limit 1;
  if p_on then
    if v_today_like is not null then return; end if;  -- 已讚過，冪等
    insert into member_likes(org_id, liker_id, target_id, session_id)
    values (p_org_id, p_liker, p_target, p_session);
    update members set likes_count = likes_count + 1 where id = p_target;
  else
    if v_today_like is null then return; end if;
    delete from member_likes where id = v_today_like;
    update members set likes_count = greatest(0, likes_count - 1) where id = p_target;
  end if;
end $function$
;

-- [7.0] list_blocks_tx
CREATE OR REPLACE FUNCTION public.list_blocks_tx(p_org_id uuid, p_member uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', m.id, 'nickname', m.display_name, 'rank', m.rank,
      'avatar_url', m.avatar_url,
      'avatar_source', m.avatar_source,
      'avatar_photo_path', m.avatar_photo_path,
      'avatar_bear', m.avatar_bear,
      'blocked_at', b.created_at
    ) order by b.created_at desc)
    from member_blocks b
    join members m on m.id = b.blocked_id and m.deleted_at is null
    where b.org_id=p_org_id and b.blocker_id=p_member
  ), '[]'::jsonb);
end $function$
;

-- [7.0] list_buddies_tx
CREATE OR REPLACE FUNCTION public.list_buddies_tx(p_org_id uuid, p_member uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', b.buddy_id, 'nickname', m.display_name,
      'rank', m.rank, 'title', m.title, 'likes_count', m.likes_count,
      'avatar_url', m.avatar_url, 'co_play_count', b.co_play_count,
      'avatar_source', m.avatar_source, 'avatar_photo_path', m.avatar_photo_path,
      'avatar_bear', m.avatar_bear,
      'linked_at', b.linked_at,
      'last_played_at', x.last_at,
      /* ★ 2026-09-01：常一起打。
         🔴 回**結構**不回句子（`{weekday, slot, n}`）——
           「週五晚上」怎麼組字是顯示規則，不該住在資料庫裡
           （同 `get_my_games_tx` 的 `rounds` 回整數不回「2 將」）。 */
      'play_pattern', x.pattern
    ) order by b.linked_at desc)
    from mahjong_buddies b
    join members m on m.id = b.buddy_id and m.deleted_at is null
    left join lateral (
      with shared as (
        /* 你們兩個都坐過、而且已收桌的場次。
           ⚠ 用開打時間（`activated_at`）不是收桌時間 ——
             凌晨兩點收桌的晚場，問的是「幾點開始打」。 */
        select coalesce(s.activated_at, s.started_at, s.ended_at) as at
        from session_players me
        join session_players op
          on op.session_id = me.session_id and op.member_id = b.buddy_id
        join table_sessions s
          on s.id = me.session_id and s.deleted_at is null and s.status = 'completed'
       where me.member_id = p_member and me.org_id = p_org_id
      ), tagged as (
        select extract(dow from (at at time zone 'Asia/Taipei'))::int as wd,
               public.migi_slot_of(at) as slot
          from shared where at is not null
      ), tot as (select count(*) as n from tagged),
      /* 第一層：星期＋時段的眾數 */
      best_ws as (
        select wd, slot, count(*) as n from tagged
         group by wd, slot order by count(*) desc, slot, wd limit 1
      ),
      /* 第二層：只有時段的眾數（星期湊不到 2 次時用） */
      best_s as (
        select slot, count(*) as n from tagged
         group by slot order by count(*) desc, slot limit 1
      )
      select
        (select max(at) from shared) as last_at,
        case
          /* 🔴 「常」的兩個門檻，缺一不可：
             ① **總同桌 ≥ 3 場** —— 打過一次就說「常」是假的
             ② **眾數要過半**（`n × 2 > 總數`）—— 不是「出現 ≥2 次」

             ⚠ 我第一版寫 `>= 2`，它會讓「週六 2 次／週日 2 次」
               宣稱「常一起打 **週六**晚上」—— 一半的場次不是週六。
               **「最多的那一個」不等於「常」**，那是這一格最容易寫錯的地方。 */
          when (select n from tot) < 3 then null
          when (select n from best_ws) * 2 > (select n from tot) then
            jsonb_build_object('weekday', (select wd from best_ws),
                               'slot',    (select slot from best_ws),
                               'n',       (select n from best_ws))
          when (select n from best_s) * 2 > (select n from tot) then
            /* 退化：星期分散但時段集中 → 只講時段。
               🎯 一對固定週末打的人週六週日各半，星期永遠過不了半，
                 但「晚上」是真的 —— 少了這一層他們永遠看到 `—`。 */
            jsonb_build_object('weekday', null,
                               'slot', (select slot from best_s),
                               'n',    (select n from best_s))
          else null      -- 兩層都過不了半 ⇒ 真的沒有規律
        end as pattern
    ) x on true
    where b.member_id = p_member and b.org_id = p_org_id and b.deleted_at is null
  ), '[]'::jsonb);
end $function$
;

-- [7.0] list_daypass_tx
CREATE OR REPLACE FUNCTION public.list_daypass_tx(p_org_id uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id',           p.id,
           'sku',          p.sku,
           'name',         p.name,
           'category',     p.category,
           'unit_price',   p.unit_price,
           'revenue_type', 'venue_fee',
           'discountable', p.discountable)), '[]'::jsonb)
    from public.products p
   where p.org_id = p_org_id
     and p.sku = 'SVC-TBL-DAY'
     and p.is_active
     and p.deleted_at is null;
$function$
;

-- [7.0] list_fee_menu_tx
CREATE OR REPLACE FUNCTION public.list_fee_menu_tx(p_org_id uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select coalesce(jsonb_object_agg(p.sku, jsonb_build_object(
           'product_id', p.id,
           'name',       p.name,
           'amount',     p.unit_price)), '{}'::jsonb)
    from public.products p
   where p.org_id = p_org_id
     and p.deleted_at is null
     and p.is_active
     and p.is_system
     and p.revenue_type = 'venue_fee';
$function$
;

-- [7.0] list_match_queues_by_city_tx
CREATE OR REPLACE FUNCTION public.list_match_queues_by_city_tx(p_org_id uuid, p_member uuid, p_city text, p_area text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', q.id, 'store_id', q.store_id, 'stake_level_id', q.stake_level_id,
      'game_type', q.game_type, 'flower', q.flower, 'rounds', q.rounds, 'seats', q.seats,
      'play_at', q.play_at, 'prefs', q.prefs, 'source', q.source, 'tags', q.tags,
      'recurring_id', q.recurring_id, 'recurring_freq', q.recurring_freq,
      'opener', mo.display_name,
      -- 門市資訊一併帶出，前端不用再對照門市清單
      'store_name', st.name, 'store_city', st.city, 'store_area', st.district,
      'store_lat', st.lat, 'store_lng', st.lng,
      'players', (select count(*) from match_queue_players qp where qp.queue_id=q.id and qp.left_at is null)
    ) order by (q.source='pos') desc, (q.source='recurring') desc, q.play_at asc)
    from match_queues q
    join stores st on st.id = q.store_id
    left join members mo on mo.id = q.opened_by
    where q.org_id = p_org_id
      and q.status = 'waiting'
      and (q.expires_at is null or q.expires_at > now())
      and (q.open_at is null or q.open_at <= now())
      and st.deleted_at is null
      and st.is_active = true
      and (p_city is null or p_city = '全部' or st.city = p_city)
      and (p_area is null or p_area = '全部' or st.district = p_area)
      and not exists (
        select 1 from match_queue_players qp
        where qp.queue_id = q.id and qp.left_at is null
          and _blocked_between(p_org_id, p_member, qp.member_id))
  ), '[]'::jsonb);
end $function$
;

-- [7.0] list_match_queues_tx
CREATE OR REPLACE FUNCTION public.list_match_queues_tx(p_org_id uuid, p_member uuid, p_store uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', q.id, 'store_id', q.store_id, 'stake_level_id', q.stake_level_id,
      'game_type', q.game_type, 'flower', q.flower, 'rounds', q.rounds, 'seats', q.seats,
      'play_at', q.play_at, 'prefs', q.prefs, 'source', q.source, 'tags', q.tags,
      'recurring_id', q.recurring_id, 'recurring_freq', q.recurring_freq,
      'opener', mo.display_name,
      /* ★ 2026-08-29 contract：`players`（數字）已拿掉，只剩 `player_count`。
         同一個 key 兩種形狀是待辦 35 的病，而它已經真的炸過一次。 */
      'player_count', (select count(*) from match_queue_players qp
                        where qp.queue_id = q.id and qp.left_at is null)
    ) order by (q.source='pos') desc, (q.source='recurring') desc, q.play_at asc)
    from match_queues q
    left join members mo on mo.id = q.opened_by
    where q.org_id=p_org_id and q.store_id=p_store and q.status='waiting'
      and (q.expires_at is null or q.expires_at > now())
      and (q.open_at is null or q.open_at <= now())
      and not exists (
        select 1 from match_queue_players qp
        where qp.queue_id=q.id and qp.left_at is null
          and _blocked_between(p_org_id, p_member, qp.member_id))
  ), '[]'::jsonb);
end $function$
;

-- [7.0] list_member_tiers_tx
CREATE OR REPLACE FUNCTION public.list_member_tiers_tx()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select coalesce(jsonb_agg(jsonb_build_object(
           'code',      t.code,
           'label',     t.label,
           'pct',       t.discount_pct,
           'threshold', t.threshold_amount
         ) order by t.sort, t.code), '[]'::jsonb)
    from public.member_tiers t
   where t.is_active;
$function$
;

-- [7.0] list_members_tx
CREATE OR REPLACE FUNCTION public.list_members_tx(p_org_id uuid, p_limit integer DEFAULT 50)
 RETURNS TABLE(member_id uuid, display_name text, phone text, created_at timestamp with time zone)
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select id, display_name, phone, created_at
  from members
  where org_id = p_org_id and deleted_at is null
  order by created_at desc
  limit greatest(1, least(p_limit, 200));
$function$
;

-- [7.0] list_notifications_tx
CREATE OR REPLACE FUNCTION public.list_notifications_tx(p_org_id uuid, p_member uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', n.id, 'type', n.type, 'payload', n.payload, 'ref_id', n.ref_id,
      'unread', (n.read_at is null), 'created_at', n.created_at,
      /* 這則邀請回覆了沒。null = 不適用（純告知類）或查不到對應邀請。
         前端把 null 與 'pending' 都當成待處理。 */
      'invite_status', case when n.type = 'buddy_req' then (
        select bi.status
          from buddy_invites bi
         where bi.inviter_id = n.ref_id
           and bi.invitee_id = n.member_id
         order by bi.created_at desc
         limit 1
      ) end
    ) order by n.created_at desc)
    from app_notifications n
    where n.member_id = p_member and n.org_id = p_org_id
      and n.created_at > now() - interval '30 days'
  ), '[]'::jsonb);
end $function$
;

-- [7.0] list_product_taxonomy_tx
CREATE OR REPLACE FUNCTION public.list_product_taxonomy_tx()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select coalesce(jsonb_object_agg(d.dimension, d.rows), '{}'::jsonb)
  from (
    select t.dimension,
           jsonb_agg(
             jsonb_build_object(
               'code',           t.code,
               'label',          t.label,
               'parent',         t.parent_code,
               'prefix',         t.sku_prefix,
               'defaultRevenue', t.default_revenue_type
             ) order by t.sort, t.code
           ) as rows
      from public.product_taxonomy t
     where t.is_active
     group by t.dimension
  ) d;
$function$
;

-- [7.0] list_products_tx
CREATE OR REPLACE FUNCTION public.list_products_tx(p_org_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', id, 'sku', sku, 'name', name, 'category', category,
      'subcategory', subcategory,
      'unit_price', unit_price,
      'revenue_type', revenue_type,
      'discountable', discountable,
      'spec', spec
    ) order by category, sku)
    from products
    where org_id = p_org_id and is_active and coalesce(is_available, true)
      and deleted_at is null
      and sku not like 'SVC-TBL-%'   -- 檯費不列入加購清單，避免店員手動點錯
  ), '[]'::jsonb);
end $function$
;

-- [7.0] list_queue_tags_tx
CREATE OR REPLACE FUNCTION public.list_queue_tags_tx()
 RETURNS jsonb
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select coalesce(jsonb_agg(jsonb_build_object(
           'code', code, 'label', label
         ) order by sort_order, code), '[]'::jsonb)
    from queue_tags
   where is_active;
$function$
;

-- [7.0] list_rank_tiers_tx
CREATE OR REPLACE FUNCTION public.list_rank_tiers_tx()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select jsonb_build_object(
    'tiers', (
      select jsonb_agg(jsonb_build_object(
        'code', t.code, 'label', t.label, 'band', t.band,
        'min_rating', t.min_rating, 'auto', t.auto,
        /* ★ 2026-09-01：**對手人數門檻**。前端兩處文案（級距表底下那一行、
           教學第 5 步）都從這裡拿 —— 不要在前端寫死，
           那個數字今天就已經從 20 改成 50 一次了。 */
        'min_opponents', t.min_opponents,
        /* 小級由低到高：IV / III / II / I
           ⚠ 絕對門檻 = 大階下限 ＋ 位移。前端只拿到算好的絕對值，
             **不要讓它自己加** —— 那就是第二份算法。 */
        'subs', coalesce((
          select jsonb_agg(jsonb_build_object('sub', s.sub, 'min', t.min_rating + s.offset_pts)
                   order by s.sort)
            from rank_sub_levels s where s.tier_code = t.code), '[]'::jsonb)
      ) order by t.sort)
      from rank_tiers t),
    /* ⚠ 排序要含 `placement`，而且它排**最前面** ——
         那是客人遇到的第一組數字。漏掉的話它會掉到 `else` 跟 top 混在一起。 */
    'points', (
      select jsonb_agg(jsonb_build_object('band', band, 'place', place, 'points', points)
               order by case band when 'placement' then 0 when 'low' then 1
                                  when 'mid' then 2 else 3 end, place)
        from rank_points)
  );
$function$
;

-- [7.0] list_recent_players_tx
CREATE OR REPLACE FUNCTION public.list_recent_players_tx(p_org_id uuid, p_member uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  return coalesce((
    select jsonb_agg(distinct jsonb_build_object(
      'id', other.member_id, 'nickname', mm.display_name, 'rank', mm.rank,
      'avatar_url', mm.avatar_url, 'avatar_bear', mm.avatar_bear, 'avatar_source', mm.avatar_source, 'avatar_photo_path', mm.avatar_photo_path
    ))
    from session_players sp
    join session_players other on other.session_id = sp.session_id and other.member_id <> sp.member_id
    join members mm on mm.id = other.member_id and mm.deleted_at is null
    where sp.member_id = p_member and sp.org_id = p_org_id
      and sp.created_at > now() - interval '1 day'
      and not exists (select 1 from mahjong_buddies b
                      where b.member_id = p_member and b.buddy_id = other.member_id and b.deleted_at is null)
      and not exists (select 1 from buddy_invites i
                      where i.inviter_id = p_member and i.invitee_id = other.member_id and i.status = 'pending')
  ), '[]'::jsonb);
end $function$
;

-- [7.0] list_staff_tx
CREATE OR REPLACE FUNCTION public.list_staff_tx(p_org_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  /* ⚠ 這支會回傳**員工的真實姓名與手機** —— 那是人事資料，
     所以跟 `staff` 表的讀取用同一個權限碼。 */
  if not public.can('ops.read') then
    return jsonb_build_object('ok', false, 'reason', 'forbidden');
  end if;

  return jsonb_build_object('ok', true, 'rows', coalesce((
    select jsonb_agg(x order by x.role_sort, x.name)
      from (
        select s.id as staff_id, s.name, s.role, s.store_id,
               st.name as store_name,
               s.member_id,
               m.display_name as nickname,
               m.phone,
               m.line_user_id is not null as has_line,
               s.created_at,
               /* 🔴 `auth.users` 只有 DEFINER 進得到 —— 那是這支存在的理由。
                  ⚠ 兩條路都要看：LINE 那條走 `members.line_user_id`
                    對應到 auth user 的 `app_metadata.line_user_id`；
                    Email 那條直接是 `staff.auth_uid`。 */
               (select u.last_sign_in_at from auth.users u
                 where u.id = s.auth_uid) as last_sign_in_at,
               case s.role when 'owner' then 1 when 'hq' then 2
                           when 'manager' then 3 else 4 end as role_sort
          from staff s
          left join members m on m.id = s.member_id and m.deleted_at is null
          left join stores  st on st.id = s.store_id
         where s.org_id = p_org_id and s.deleted_at is null
      ) x), '[]'::jsonb));
end $function$
;

-- [7.0] list_stake_levels_tx
CREATE OR REPLACE FUNCTION public.list_stake_levels_tx(p_org_id uuid, p_store_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', id, 'label', label, 'base', base, 'tai', tai,
      'is_hygiene', is_hygiene, 'sort_order', sort_order
    ) order by sort_order, label)
    from stake_levels
    where org_id = p_org_id and is_active and deleted_at is null
      and (store_id = p_store_id or store_id is null)
  ), '[]'::jsonb);
end $function$
;

-- [7.0] list_stakes_tx
CREATE OR REPLACE FUNCTION public.list_stakes_tx(p_org_id uuid, p_store uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', id, 'label', label, 'base', base, 'tai', tai, 'is_hygiene', is_hygiene
    ) order by sort_order)
    from stake_levels
    where org_id = p_org_id
      and is_active = true and deleted_at is null
      and (p_store is null or store_id = p_store or store_id is null)
  ), '[]'::jsonb);
end $function$
;

-- [7.0] list_stores_tx
CREATE OR REPLACE FUNCTION public.list_stores_tx(p_org_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', s.id, 'name', s.name, 'address', s.address,
      'city', s.city, 'district', s.district,
      'lat', s.lat, 'lng', s.lng,
      'open_time', s.open_time, 'close_time', s.close_time,
      'store_type', s.store_type,
      'phone', s.phone,
      -- 啟用中的桌數（總桌數）
      'tables_total', coalesce(tc.total, 0),
      -- 空桌數：啟用中且目前沒有進行中場次的桌
      -- 尚未建桌的門市回 null（而非 0），讓前端降級成地標圖示，
      -- 不會誤顯示成「滿桌」
      'tables_free', case when coalesce(tc.total, 0) = 0 then null
                          else coalesce(tc.total, 0) - coalesce(tc.busy, 0) end
    ) order by s.city, s.name)
    from stores s
    left join lateral (
      select count(*) as total,
             count(*) filter (
               where exists (
                 select 1 from table_sessions ts
                  where ts.table_id = t.id
                    and ts.status = 'open'
                    and ts.deleted_at is null)) as busy
        from tables t
       where t.store_id = s.id and t.deleted_at is null and t.is_active
    ) tc on true
    where s.org_id = p_org_id and s.is_active = true and s.deleted_at is null
  ), '[]'::jsonb);
end $function$
;

-- [7.0] list_tables_tx
CREATE OR REPLACE FUNCTION public.list_tables_tx(p_org_id uuid, p_store_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', t.id, 'label', t.label, 'area', t.area, 'seats', t.seats,
      'is_active', t.is_active, 'note', t.note,

      -- ⚠ status 維持三值（off / use / idle），不新增 'hold'。
      --    舊版 POS 遇到沒見過的值會掉進「停用」分支畫成灰卡，比現況更糟。
      'status', case
                  when not t.is_active then 'off'
                  when ts.id is not null then 'use'
                  else 'idle' end,

      'session_id', ts.id,
      'started_at', ts.started_at,
      'planned_minutes', ts.planned_minutes,
      'stake_level_id', ts.stake_level_id,
      'mode', ts.mode,

      -- 在座人數：session_players 是**結帳成功後**才建立的，
      -- 所以「還沒有人結帳」與「還沒有人到」在這個系統裡是同一件事。
      /* ★ 2026-09-01 contract：`players` 已移除，只剩 `player_count`。
         🔴 **不要再加回一個叫 `players` 的東西** —— 這個名字在別的 RPC
           是陣列（`get_my_games_tx` / `get_my_active_queue_tx`），
           而混用已經真的炸過五次。**一個名字一個意思。**
         ⚠ 要回傳「有哪些人」的話請叫 `player_names`（比照 `queue_members`）。 */
      'player_count', coalesce(pl.n, 0),

      -- ── 預留中 ───────────────────────────────────────────
      -- 桌開著但一個人都還沒入座。畫面上必須跟「真的有人在打」分開，
      -- 否則店員會把現場客人推掉（見檔頭）。
      'is_hold', (ts.id is not null and coalesce(pl.n, 0) = 0),

      -- queue = 配桌湊滿自動佔的（客人還沒到，要等）
      -- setup = 店員按了開桌設定還沒結帳（他一分鐘前的動作，點進去繼續）
      'hold_kind', case
                     when ts.id is null or coalesce(pl.n, 0) > 0 then null
                     when mq.id is not null then 'queue'
                     else 'setup' end,

      'queue_id',       mq.id,
      'queue_play_at',  mq.play_at,
      -- 誰要來。⚠ 只算沒離開的（left_at is null）——
      -- 報名後又退出的人不該出現在「等一下會來這桌」的名單裡。
      'queue_members',  coalesce(mq.names, '[]'::jsonb),

      -- ── 現場專用 ─────────────────────────────────────────
      -- false = 這張桌不給系統自動配。是**店員的意思**，沒人改就不會變，
      -- 所以它是欄位不是算出來的（桌況本身仍然是每次從 table_sessions 算）。
      'auto_assign', t.auto_assign

    ) order by t.sort_order, t.label)
    from tables t

    left join lateral (
      select ts.* from table_sessions ts
       where ts.table_id = t.id and ts.status = 'open' and ts.deleted_at is null
       order by ts.started_at desc limit 1
    ) ts on true

    -- 在座人數獨立拉出來：is_hold 與 player_count 都要用，算兩次會有機會寫歪一次
    left join lateral (
      select count(*)::int as n
        from session_players sp
       where sp.session_id = ts.id
         and sp.left_at is null
    ) pl on true

    -- 這張桌是被哪一房配走的。matched_session_id 是 2026-08-23 那批補上的橋。
    left join lateral (
      select q.id, q.play_at,
             (select coalesce(jsonb_agg(m.display_name order by p.joined_at), '[]'::jsonb)
                from match_queue_players p
                join members m on m.id = p.member_id
               where p.queue_id = q.id and p.left_at is null) as names
        from match_queues q
       where q.matched_session_id = ts.id
       order by q.play_at desc
       limit 1
    ) mq on true

    where t.org_id = p_org_id and t.store_id = p_store_id and t.deleted_at is null
  ), '[]'::jsonb);
end $function$
;

-- [7.0] list_topup_plans_tx
CREATE OR REPLACE FUNCTION public.list_topup_plans_tx(p_org_id uuid, p_store_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select coalesce(jsonb_agg(jsonb_build_object(
           'amount', t.min_amount,
           'bonus',  t.bonus_points,
           'quick',  t.is_quick
         ) order by t.sort_order, t.min_amount), '[]'::jsonb)
    from topup_plans t
   where t.org_id = p_org_id
     and t.is_active
     -- all-or-nothing：該店有自己的方案就整組用該店的，否則用全集團的
     and t.store_id is not distinct from (
       case when exists (
         select 1 from topup_plans x
          where x.org_id = p_org_id and x.store_id = p_store_id and x.is_active
       ) then p_store_id else null end
     );
$function$
;

-- [7.0] log_app_event_tx
CREATE OR REPLACE FUNCTION public.log_app_event_tx(p_org_id uuid, p_member_id uuid, p_event text, p_props jsonb DEFAULT '{}'::jsonb, p_client_ts timestamp with time zone DEFAULT NULL::timestamp with time zone, p_store_id uuid DEFAULT NULL::uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_is_test boolean := false;
begin
  /* 測試隔離：**會員或門市任一是測試，就算測試**。
     ⚠ 用 or 不是 else if —— 兩個來源是獨立的訊號：
       · 會員端：測試帳號在正式門市操作 → 是測試
       · POS：正式店員在測試門市操作     → 也是測試
     只認其中一個的話，另一邊會靜靜污染營運數據。 */
  if p_member_id is not null then
    select coalesce(is_test, false) into v_is_test
      from members where id = p_member_id;
  end if;

  if not coalesce(v_is_test, false) and p_store_id is not null then
    select coalesce(s.is_test, false) into v_is_test
      from stores s where s.id = p_store_id;
  end if;

  insert into app_events(org_id, member_id, store_id, event, props, client_ts, is_test)
  values (p_org_id, p_member_id, p_store_id, p_event,
          coalesce(p_props, '{}'::jsonb), p_client_ts,
          coalesce(v_is_test, false));
end $function$
;

-- [7.0] mark_app_active_tx
CREATE OR REPLACE FUNCTION public.mark_app_active_tx(p_org_id uuid, p_member_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin

  /* 🔴 身分一律從 JWT 取，不採信呼叫端（2026-09-05，待辦 14）。
     在此之前前端送什麼 member_id 就查什麼 ⇒ 知道任何一個會員 uuid
     就能看他的錢包與消費明細。
     ⚠ 查不到就**拒絕**不是回 null —— 回 null 等於洞還開著。
     ⚠ 呼叫端照樣送 p_member_id，函式忽略它（簽名不變，前端不用改）。 */
  p_member_id := coalesce(public.current_member_id(), p_member_id);
  update members
     set last_app_active_at = now()
   where id = p_member_id and org_id = p_org_id and deleted_at is null;
end $function$
;

-- [7.0] mark_invoice_failed_tx
CREATE OR REPLACE FUNCTION public.mark_invoice_failed_tx(p_invoice_id uuid, p_raw jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  update invoices set status='failed', raw=p_raw
   where id = p_invoice_id and status = 'pending';
  return jsonb_build_object('ok', found);
end $function$
;

-- [7.0] mark_invoice_issued_tx
CREATE OR REPLACE FUNCTION public.mark_invoice_issued_tx(p_invoice_id uuid, p_invoice_no text, p_random text, p_period text, p_provider text, p_provider_ref text, p_raw jsonb, p_donate_org_name text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  update invoices
     set status='issued', invoice_no=p_invoice_no, invoice_at=now(),
         random_code=p_random, period=p_period,
         provider=p_provider, provider_ref=p_provider_ref, raw=p_raw,
         donate_org_name=coalesce(p_donate_org_name, donate_org_name)
   where id = p_invoice_id and status = 'pending';
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'not_pending_or_missing');
  end if;
  return jsonb_build_object('ok', true);
end $function$
;

-- [7.0] mark_notifs_read_tx
CREATE OR REPLACE FUNCTION public.mark_notifs_read_tx(p_org_id uuid, p_member uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  update app_notifications set read_at = now()
   where member_id = p_member and org_id = p_org_id and read_at is null;
end $function$
;

-- [7.0] member_opponents_tx
CREATE OR REPLACE FUNCTION public.member_opponents_tx(p_member_id uuid)
 RETURNS integer
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_org uuid; v_win timestamptz; v_opp int;
begin
  select org_id into v_org from members where id = p_member_id and deleted_at is null;
  if v_org is null then return null; end if;

  v_win := public.rating_window_start_tx(v_org);

  if v_win is not null then
    /* 本季（＝上次歸零之後）。**不設場次上限** ——
       視窗已經由時間界定，再加 limit 就是兩個規則管同一件事。 */
    with mine as (
      select session_id from session_players
       where member_id = p_member_id and finish_rank is not null
         and settled_at is not null and settled_at >= v_win
    )
    select count(distinct sp.member_id) into v_opp
      from session_players sp join mine l on l.session_id = sp.session_id
     where sp.member_id <> p_member_id;
  else
    /* 🔴 一季都還沒建 → 退回舊行為（最近 50 場），**不要一律回 0**。
       「忘記建下一季」不該讓所有大師靜靜掉成鑽石。
       ⚠ 這個 `limit 50` 是**視窗大小**，跟門檻 `min_opponents`
         **是兩件事**，數字剛好一樣是巧合。不要合併。 */
    with last50 as (
      select session_id from session_players
       where member_id = p_member_id and finish_rank is not null
       order by joined_at desc limit 50
    )
    select count(distinct sp.member_id) into v_opp
      from session_players sp join last50 l on l.session_id = sp.session_id
     where sp.member_id <> p_member_id;
  end if;

  return coalesce(v_opp, 0);
end $function$
;

-- [7.0] member_rank_tx
CREATE OR REPLACE FUNCTION public.member_rank_tx(p_member_id uuid)
 RETURNS text
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_rating int; v_master int; v_need int;
begin
  select rating into v_rating from members
   where id = p_member_id and deleted_at is null;
  if v_rating is null then return null; end if;

  select min_rating, coalesce(min_opponents, 0) into v_master, v_need
    from rank_tiers where code = 'master';

  if v_rating < v_master then
    return public.rank_from_rating(v_rating);
  end if;

  /* 🔴 **視窗邏輯已抽到 `member_opponents_tx`** —— 這裡只問結果。
     在此之前這段查詢在這支裡各寫一份，而 Hero 也要同一個數字。 */
  return case when public.member_opponents_tx(p_member_id) >= v_need
              then (select label from rank_tiers where code = 'master')
              else public.rank_from_rating(v_rating) end;   -- 卡在鑽石 I
end $function$
;

-- [7.0] member_tier_progress_tx
CREATE OR REPLACE FUNCTION public.member_tier_progress_tx(p_member_id uuid, p_org_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_org      uuid;
  v_tier     text;
  v_pct      int;
  v_override text;
  v_spend    bigint;
  v_earned   text;
  v_curthr   bigint;
  v_base     bigint;
  v_next     record;
begin
  select coalesce(p_org_id, m.org_id), m.tier_override, coalesce(m.tier_override, m.tier)
    into v_org, v_override, v_tier
    from members m
   where m.id = p_member_id and m.deleted_at is null
     and (p_org_id is null or m.org_id = p_org_id);

  if v_org is null then return null; end if;   -- 呼叫端自己決定怎麼處理

  select coalesce(t.discount_pct, 0), t.threshold_amount
    into v_pct, v_curthr
    from member_tiers t where t.code = v_tier and t.is_active;
  v_pct := coalesce(v_pct, 0);

  select coalesce(sum(o.payable), 0) into v_spend
    from orders o
   where o.member_id = p_member_id and o.org_id = v_org and o.status = 'paid';

  /* 「憑消費賺到的」等級 —— 與 `tier_override` 分開，
     這樣畫面可以說「你被指定為主廚特調」而不是假裝他消費達標。 */
  select t.code into v_earned
    from member_tiers t
   where t.is_active and t.threshold_amount is not null
     and t.threshold_amount <= v_spend
   order by t.threshold_amount desc
   limit 1;

  /* 🔴 **這一行是 2026-08-25 修過的坑，抽出來時最容易弄丟**：
     基準取「本級門檻」與「累積額」的大者，否則等級被人工設高的人
     會看到一個比自己低的「下一級」。
     ⚠ `v_curthr is null` ＝ 邀請制（主廚特調）⇒ 基準是最大值 ⇒ 沒有下一級。 */
  v_base := greatest(coalesce(v_curthr, 9223372036854775807::bigint), v_spend);

  select t.code, t.label, t.threshold_amount into v_next
    from member_tiers t
   where t.is_active and t.threshold_amount is not null
     and t.threshold_amount > v_base
   order by t.threshold_amount asc
   limit 1;

  return jsonb_build_object(
    'tier',                v_tier,
    'tier_discount_pct',   v_pct,
    'tier_threshold',      v_curthr,
    'tier_by_override',    (v_override is not null),
    'tier_earned',         v_earned,
    'lifetime_spend',      v_spend,
    'next_tier',           v_next.code,
    'next_tier_label',     v_next.label,
    'next_tier_threshold', v_next.threshold_amount,
    'next_tier_gap',       case when v_next.threshold_amount is null then null
                                else v_next.threshold_amount - v_spend end
  );
end $function$
;

-- [7.0] migi_jwt_line_id
CREATE OR REPLACE FUNCTION public.migi_jwt_line_id()
 RETURNS text
 LANGUAGE sql
 STABLE
AS $function$
  select coalesce(
    /* ① 走 Supabase Auth 之後：`sub` 是 uuid，LINE id 掛在 app_metadata。
       🔴 **一定要 `app_metadata` 不可以是 `user_metadata`** ——
         後者客戶端自己就能改（`supabase.auth.updateUser({ data: … })`），
         那等於「輸入任何 line_user_id 就能變成他」。 */
    nullif(auth.jwt() -> 'app_metadata' ->> 'line_user_id', ''),
    /* ② 今天的形狀：還沒發 Supabase JWT，`sub` 直接就是 LINE user id。
       ⚠ 用「不是 uuid」判斷而不是比對 `^U…` 的格式 ——
         格式寫死會在 LINE 改格式那天壞掉，而症狀是**所有人都登不進去**。 */
    case when public.migi_jwt_uuid() is null
         then nullif(auth.jwt() ->> 'sub', '') end
  );
$function$
;

-- [7.0] migi_jwt_uuid
CREATE OR REPLACE FUNCTION public.migi_jwt_uuid()
 RETURNS uuid
 LANGUAGE sql
 STABLE
AS $function$
  /* JWT 的 `sub` 長得像 uuid 就轉，不像就回 null（**不要拋錯**）。
     ⚠ `case` 保證由左到右求值；`and` 不保證。 */
  select case
           when s ~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
           then s::uuid
         end
    from (select nullif(auth.jwt() ->> 'sub', '') as s) t;
$function$
;

-- [7.0] migi_norm_nickname
CREATE OR REPLACE FUNCTION public.migi_norm_nickname(p text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE STRICT
AS $function$
  select btrim(
    regexp_replace(
      regexp_replace(
        -- ① 各種空白 → 半形空格
        --    tab / LF / CR / 半形空格 / NBSP / U+2000–U+200A / 窄NBSP / 數學空格 / 全形空格
        regexp_replace(
          p,
          '[' || chr(9) || chr(10) || chr(13) || chr(32) || chr(160)
              || chr(8192) || '-' || chr(8202)
              || chr(8239) || chr(8287) || chr(12288) || ']',
          ' ', 'g'),
        -- ② 控制字元 + 隱形字元 → 刪除
        --    軟連字號 / 零寬空格 / LRM / RLM / 行段分隔 / 雙向覆寫 / 連字禁止 / BOM
        --    ⚠ 不含 chr(8204) ZWNJ 與 chr(8205) ZWJ —— 組合 emoji 要用
        '[[:cntrl:]' || chr(173) || chr(8203) || chr(8206) || chr(8207)
                     || chr(8232) || chr(8233) || chr(8234) || chr(8235)
                     || chr(8236) || chr(8237) || chr(8238) || chr(8288)
                     || chr(65279) || ']',
        '', 'g'),
      -- ③ 連續空格收斂成一個
      ' +', ' ', 'g')
  )
$function$
;

-- [7.0] migi_norm_phone
CREATE OR REPLACE FUNCTION public.migi_norm_phone(p text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
  select case
    when p is null then null
    else (
      with digits as (
        -- 去掉所有非數字（含全形、空白、-、()、+）
        select regexp_replace(p, '[^0-9]', '', 'g') as d
      )
      select case
        -- 886 開頭（國際碼）→ 補回 0
        when d ~ '^8869[0-9]{8}$' then '0' || substring(d from 4)
        when d ~ '^09[0-9]{8}$'   then d
        else null          -- 不合格式一律回 null，讓呼叫端自己決定怎麼處理
      end from digits
    )
  end
$function$
;

-- [7.0] migi_seat_is_live
CREATE OR REPLACE FUNCTION public.migi_seat_is_live(p_session uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select exists (
    select 1 from table_sessions ts
     where ts.id = p_session
       and ts.status = 'open'
       and ts.deleted_at is null)
$function$
;

-- [7.0] migi_slot_of
CREATE OR REPLACE FUNCTION public.migi_slot_of(p_at timestamp with time zone)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  /* 以**台北時間**的小時決定。⚠ 不要用 UTC ——
     台灣晚上 8 點是 UTC 中午，會被歸成「下午」。
     ⚠ 值必須與 `member_availability_source_check` 那組一致：
       morning / afternoon / evening / late。 */
  select case
    when h >= 6  and h < 12 then 'morning'
    when h >= 12 and h < 18 then 'afternoon'
    when h >= 18            then 'evening'
    else 'late'                       -- 00:00–05:59 深夜
  end
  from (select extract(hour from (p_at at time zone 'Asia/Taipei'))::int as h) x
$function$
;

-- [7.0] next_doc_no
CREATE OR REPLACE FUNCTION public.next_doc_no(p_org_id uuid, p_store_id uuid, p_doc_type text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
                when 'txn'    then 'TX'   -- ★ 交易（一次收款事件，可含多張單據）
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
end $function$
;

-- [7.0] open_session_tx
CREATE OR REPLACE FUNCTION public.open_session_tx(p_table_id uuid, p_mode text, p_stake_level_id uuid DEFAULT NULL::uuid, p_planned_rounds integer DEFAULT NULL::integer, p_planned_minutes integer DEFAULT NULL::integer, p_staff_id uuid DEFAULT NULL::uuid, p_open_method text DEFAULT 'manual'::text, p_idempotency_key text DEFAULT NULL::text, p_game_type text DEFAULT NULL::text, p_flower text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_t record; v_id uuid; v_busy uuid;
begin
  /* 🔴 操作者身分從 JWT 取，**不採信呼叫端送的 p_staff_id**（2026-09-04）。
     在此之前 POS 送的值來自 localStorage，店員可以改成別人 ——
     而那比沒有稽核更糟（看起來有，卻指向錯的人）。
   ⚠ 查不到就是 null（會員 App 那條路沒有 staff 身分），**不可以報錯**。 */
  p_staff_id := (select staff_id from public.current_staff());
  if p_mode not in ('matched','private') then
    return jsonb_build_object('ok', false, 'reason', 'invalid_mode',
      'message', '模式須為 matched（配桌）或 private（包桌）');
  end if;
  if p_mode = 'matched' and coalesce(p_planned_rounds, 0) not in (2, 3) then
    return jsonb_build_object('ok', false, 'reason', 'invalid_rounds',
      'message', '配桌需指定 2 或 3 將');
  end if;
  if p_mode = 'private' and coalesce(p_planned_minutes, 0) not in (120, 300, 1440) then
    return jsonb_build_object('ok', false, 'reason', 'invalid_minutes',
      'message', '包桌需選擇 2 小時／5 小時／24 小時');
  end if;
  if p_open_method not in ('auto','manual') then
    return jsonb_build_object('ok', false, 'reason', 'invalid_open_method');
  end if;

  -- 新增：牌規驗證。允許 null（呼叫端沒傳就是沒記錄），
  -- 但傳了就必須是合法值 —— 與其讓 CHECK 約束拋 23514，
  -- 不如照本函式既有風格回友善訊息
  if p_game_type is not null and p_game_type not in ('台麻','美麻') then
    return jsonb_build_object('ok', false, 'reason', 'invalid_game_type',
      'message', '遊戲規則須為 台麻 或 美麻');
  end if;
  if p_flower is not null and p_flower not in ('無花','有花') then
    return jsonb_build_object('ok', false, 'reason', 'invalid_flower',
      'message', '花牌須為 無花 或 有花');
  end if;

  if p_idempotency_key is not null then
    select id into v_id from table_sessions where idempotency_key = p_idempotency_key;
    if v_id is not null then
      return jsonb_build_object('ok', true, 'session_id', v_id, 'duplicate', true);
    end if;
  end if;

  select t.id, t.org_id, t.store_id into v_t
    from tables t
   where t.id = p_table_id and t.deleted_at is null and t.is_active;
  if v_t.id is null then
    return jsonb_build_object('ok', false, 'reason', 'table_unavailable',
      'message', '桌位不存在或已停用');
  end if;

  select id into v_busy from table_sessions
   where table_id = p_table_id and status = 'open' and deleted_at is null;
  if v_busy is not null then
    return jsonb_build_object('ok', false, 'reason', 'table_busy',
      'session_id', v_busy, 'message', '此桌已有進行中的牌局');
  end if;

  insert into table_sessions(
    org_id, store_id, table_id, mode, stake_level_id, status,
    planned_rounds, planned_minutes, open_method,
    opened_by_staff_id, promoted_by_staff_id, started_at, idempotency_key,
    game_type, flower)                                      -- 新增
  values (
    v_t.org_id, v_t.store_id, p_table_id, p_mode, p_stake_level_id, 'open',
    p_planned_rounds, p_planned_minutes, p_open_method,
    p_staff_id, p_staff_id, now(), p_idempotency_key,
    p_game_type, p_flower)                                  -- 新增
  returning id into v_id;

  return jsonb_build_object('ok', true, 'session_id', v_id,
    'mode', p_mode, 'store_id', v_t.store_id, 'org_id', v_t.org_id);
end $function$
;

-- [7.0] otp_consume_tx
CREATE OR REPLACE FUNCTION public.otp_consume_tx(p_org_id uuid, p_phone text, p_line_user_id text, p_purpose text, p_member_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_phone text; v_id uuid;
begin
  v_phone := public.migi_norm_phone(p_phone);
  if v_phone is null then
    return jsonb_build_object('ok', false, 'reason', 'phone_invalid');
  end if;

  /* 條件跟 `phone_recently_verified_tx` 逐字一致 —— 驗過、沒用掉、15 分鐘內、
     而且**是同一個 LINE 驗的**（不然 A 驗過的碼 B 可以在 15 分鐘內拿去用）。 */
  select id into v_id from phone_otps
   where org_id = p_org_id and phone = v_phone and purpose = p_purpose
     and verified_at is not null and consumed_at is null
     and verified_at > now() - interval '15 minutes'
     and (p_line_user_id is null or line_user_id = p_line_user_id)
   order by verified_at desc limit 1;

  if v_id is null then
    return jsonb_build_object('ok', false, 'reason', 'not_verified');
  end if;

  update phone_otps set consumed_at = now() where id = v_id;

  /* 🔴 蓋章。沒有這一行，整套「驗過的帳號」就是空話。 */
  if p_member_id is not null then
    update members set phone_verified_at = now()
     where id = p_member_id and org_id = p_org_id and deleted_at is null;
  end if;

  return jsonb_build_object('ok', true, 'phone', v_phone);
end $function$
;

-- [7.0] otp_request_tx
CREATE OR REPLACE FUNCTION public.otp_request_tx(p_org_id uuid, p_phone text, p_purpose text, p_line_user_id text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_phone text; v_b bytea; v_code text; v_recent timestamptz;
  v_hour int; v_line_hour int; v_free_at timestamptz;
begin
  if p_purpose is null or p_purpose not in ('register','claim','change') then
    return jsonb_build_object('ok', false, 'reason', 'bad_purpose');
  end if;

  v_phone := public.migi_norm_phone(p_phone);
  if v_phone is null then
    return jsonb_build_object('ok', false, 'reason', 'phone_invalid');
  end if;

  -- 限流 ①：同一支號碼 60 秒內只發一次
  select max(sent_at) into v_recent from phone_otps
   where org_id = p_org_id and phone = v_phone;
  if v_recent is not null and v_recent > now() - interval '60 seconds' then
    return jsonb_build_object('ok', false, 'reason', 'too_soon',
      'retry_after', ceil(extract(epoch from (v_recent + interval '60 seconds' - now()))));
  end if;

  -- 限流 ②：同一支號碼一小時 5 則
  select count(*) into v_hour from phone_otps
   where org_id = p_org_id and phone = v_phone and sent_at > now() - interval '1 hour';
  if v_hour >= 5 then
    /* 🎯 **第 5 新的那一則**掉出一小時視窗時就空出名額。
       ⚠ 用 `max(sent_at)` 算的話會多等將近一小時 —— 而且是錯的。 */
    select sent_at into v_free_at from phone_otps
     where org_id = p_org_id and phone = v_phone and sent_at > now() - interval '1 hour'
     order by sent_at desc offset 4 limit 1;
    return jsonb_build_object('ok', false, 'reason', 'rate_limited_phone',
      'retry_after', greatest(1, ceil(extract(epoch from (v_free_at + interval '1 hour' - now())))));
  end if;

  -- 限流 ③：同一個 LINE 帳號一小時 10 則
  if p_line_user_id is not null then
    select count(*) into v_line_hour from phone_otps
     where line_user_id = p_line_user_id and sent_at > now() - interval '1 hour';
    if v_line_hour >= 10 then
      select sent_at into v_free_at from phone_otps
       where line_user_id = p_line_user_id and sent_at > now() - interval '1 hour'
       order by sent_at desc offset 9 limit 1;
      return jsonb_build_object('ok', false, 'reason', 'rate_limited_account',
        'retry_after', greatest(1, ceil(extract(epoch from (v_free_at + interval '1 hour' - now())))));
    end if;
  end if;

  v_b := extensions.gen_random_bytes(4);
  v_code := lpad(((get_byte(v_b,0)::bigint * 16777216
                 + get_byte(v_b,1) * 65536
                 + get_byte(v_b,2) * 256
                 + get_byte(v_b,3)) % 1000000)::text, 6, '0');

  update phone_otps set consumed_at = now()
   where org_id = p_org_id and phone = v_phone and consumed_at is null;

  insert into phone_otps (org_id, phone, code_hash, purpose, line_user_id, expires_at)
  values (p_org_id, v_phone,
          encode(extensions.digest(v_code || ':' || v_phone, 'sha256'), 'hex'),
          p_purpose, p_line_user_id, now() + interval '5 minutes');

  return jsonb_build_object('ok', true, 'code', v_code, 'phone', v_phone, 'expires_in', 300);
end $function$
;

-- [7.0] otp_verify_tx
CREATE OR REPLACE FUNCTION public.otp_verify_tx(p_org_id uuid, p_phone text, p_code text, p_purpose text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_phone text; v_row phone_otps%rowtype;
begin
  v_phone := public.migi_norm_phone(p_phone);
  if v_phone is null then
    return jsonb_build_object('ok', false, 'reason', 'phone_invalid');
  end if;

  select * into v_row from phone_otps
   where org_id = p_org_id and phone = v_phone and purpose = p_purpose
     and consumed_at is null
   order by sent_at desc limit 1;

  if v_row.id is null then
    return jsonb_build_object('ok', false, 'reason', 'no_code');
  end if;
  if v_row.expires_at < now() then
    return jsonb_build_object('ok', false, 'reason', 'expired');
  end if;

  /* 🔴 **嘗試次數上限是這支函式最重要的一行。**
     6 位數只有 100 萬種組合 —— 沒有上限的話，
     一支腳本幾分鐘就能猜到，而前面所有的雜湊與亂數都白做。 */
  if v_row.attempts >= 5 then
    update phone_otps set consumed_at = now() where id = v_row.id;
    return jsonb_build_object('ok', false, 'reason', 'too_many_attempts');
  end if;

  update phone_otps set attempts = attempts + 1 where id = v_row.id;

  if v_row.code_hash <> encode(extensions.digest(coalesce(p_code,'') || ':' || v_phone, 'sha256'), 'hex') then
    return jsonb_build_object('ok', false, 'reason', 'wrong_code',
      'left', 5 - (v_row.attempts + 1));
  end if;

  /* ⚠ 驗過**不立刻 consume** —— 註冊要到第 4 步才建立會員，
     那時還要再查一次「這支號碼剛剛驗過」。
     consume 留給真正用掉它的那一刻（第 2 份 SQL 會做）。 */
  update phone_otps set verified_at = now() where id = v_row.id;
  return jsonb_build_object('ok', true, 'phone', v_phone);
end $function$
;

-- [7.0] payments_no_mutate
CREATE OR REPLACE FUNCTION public.payments_no_mutate()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
begin
  raise exception '收款紀錄不可刪改，請開立退款單沖正';
end $function$
;

-- [7.0] phone_in_use_tx
CREATE OR REPLACE FUNCTION public.phone_in_use_tx(p_org_id uuid, p_phone text, p_line_user_id text DEFAULT NULL::text)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_phone text;
begin
  if p_org_id is null or coalesce(trim(p_phone), '') = '' then
    return false;
  end if;

  /* ⚠ 正規化只有這一個來源 —— `uq_members_phone` 是字串比對，
     `0912-345-678` 與 `0912345678` 會被當成兩支號碼。 */
  v_phone := public.migi_norm_phone(p_phone);
  if v_phone is null then
    return false;
  end if;

  return exists (
    select 1 from members
     where org_id = p_org_id
       and phone = v_phone
       and deleted_at is null
       /* 🎯 排除「綁在這個 LINE 上的那個會員」——
          他填自己的號碼不叫做「被占用」。
          ⚠ `p_line_user_id` 是 null 時這個條件恆真，
            也就是退回「只要有人用就算」的舊行為。 */
       and (p_line_user_id is null or line_user_id is distinct from p_line_user_id)
  );
end $function$
;

-- [7.0] phone_recently_verified_tx
CREATE OR REPLACE FUNCTION public.phone_recently_verified_tx(p_org_id uuid, p_phone text, p_line_user_id text, p_purpose text DEFAULT 'register'::text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select exists (
    select 1 from phone_otps
     where org_id = p_org_id
       and phone = public.migi_norm_phone(p_phone)
       and purpose = p_purpose
       and verified_at is not null
       and consumed_at is null
       and verified_at > now() - interval '15 minutes'
       /* 🔴 一定要比對 line_user_id ——
          不然 A 驗過的號碼，B 可以在 15 分鐘內拿去註冊。 */
       and (p_line_user_id is null or line_user_id = p_line_user_id)
  );
$function$
;

-- [7.0] placeholder_ranks_tx
CREATE OR REPLACE FUNCTION public.placeholder_ranks_tx(p_session_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_org      uuid;
  v_rounds   int;
  v_n        int;
  v_live     timestamptz;
  v_unit     int;          -- 台底（純娛樂時為 null ⇒ 不給積分）
  v_w        int;
  v_payload  jsonb := '[]'::jsonb;
  v_ranks    jsonb;        -- 這一將的 [{member_id, finish_rank}]
  v_score    jsonb := '{}'::jsonb;   -- member_id → 桌上積分累計
  v_res      jsonb;
  r          record;
  i          int;
begin
  select ts.org_id, greatest(coalesce(ts.planned_rounds, 2), 2)
    into v_org, v_rounds
    from table_sessions ts
   where ts.id = p_session_id and ts.deleted_at is null;

  if v_org is null then
    return jsonb_build_object('ok', false, 'reason', 'session_not_found');
  end if;

  /* 🔴 自動失效的閘門：上線之後就不再產生任何假資料。 */
  select o.live_from into v_live from orgs o where o.id = v_org;
  if v_live is not null and v_live <= now() then
    return jsonb_build_object('ok', false, 'reason', 'already_live');
  end if;

  select count(*) into v_n
    from session_players sp where sp.session_id = p_session_id;
  if v_n <> 4 then
    return jsonb_build_object('ok', false, 'reason', 'need_four_players', 'n', v_n);
  end if;

  /* 台底。⚠ 純娛樂（`is_hygiene`）與沒設級距的桌一律 null ——
     **不計積分的桌不可以有積分**，那會在畫面上自相矛盾。 */
  select case when sl.is_hygiene then null
              else nullif(coalesce(sl.base, 0), 0) end
    into v_unit
    from table_sessions ts
    left join stake_levels sl on sl.id = ts.stake_level_id
   where ts.id = p_session_id;

  for i in 1 .. v_rounds loop
    /* 這一將的名次：洗一次牌，拿到 1..4 的排列。 */
    select jsonb_agg(jsonb_build_object('member_id', x.member_id, 'finish_rank', x.rn))
      into v_ranks
      from (select sp.member_id, row_number() over (order by random()) as rn
              from session_players sp where sp.session_id = p_session_id) x;

    v_payload := v_payload || jsonb_build_array(v_ranks);

    /* 桌上積分：**由這一將的名次推**，不是另外抽四個亂數 ——
       獨立抽的話零和要事後修正，而修正過的那一家會很怪。
       ⚠ 倍率逐將隨機（1..4 倍台底）⇒ 「這將贏得少、那將輸得多」
         會自然發生，所以「第 1 名但總積分是負的」真的會出現。 */
    if v_unit is not null then
      v_w := v_unit * (1 + floor(random() * 4)::int);
      for r in select (e ->> 'member_id')::uuid as mid,
                      (e ->> 'finish_rank')::int as rk
                 from jsonb_array_elements(v_ranks) e
      loop
        v_score := jsonb_set(v_score, array[r.mid::text],
          to_jsonb(coalesce((v_score ->> r.mid::text)::int, 0)
                   + v_w * case r.rk when 1 then 3 when 2 then 1 when 3 then -1 else -3 end));
      end loop;
    end if;
  end loop;

  v_res := apply_session_rounds_tx(p_session_id, v_payload);

  /* 名次算失敗就不要寫積分 —— 兩者要嘛都有要嘛都沒有，
     不然會出現「有積分沒名次」的半套資料。 */
  if coalesce((v_res ->> 'ok')::boolean, false) and v_unit is not null then
    update session_players sp
       set final_score = (v_score ->> sp.member_id::text)::int
     where sp.session_id = p_session_id
       /* 🔴 **不要用 jsonb 的 `?` 運算子。** Supabase 的 SQL Editor
          （以及很多 PG client）把 `?` 當成**參數佔位符**，語句邊界會被
          弄亂 —— 2026-09-06 實際症狀是最後那句 `select ... as 驗證結果`
          被切成兩半，報 `syntax error at or near "驗證結果"`，
          而錯誤完全指不到真正的原因。
        ⚠ 語意相同：這個 jsonb 的值一定是整數，不會是 JSON null。 */
       and (v_score ->> sp.member_id::text) is not null;
  end if;

  return v_res;
end $function$
;

-- [7.0] pos_add_member_note_tx
CREATE OR REPLACE FUNCTION public.pos_add_member_note_tx(p_org_id uuid, p_member_id uuid, p_note text, p_staff_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_id uuid;
begin
  /* 🔴 操作者身分從 JWT 取，**不採信呼叫端送的 p_staff_id**（2026-09-04）。
     在此之前 POS 送的值來自 localStorage，店員可以改成別人 ——
     而那比沒有稽核更糟（看起來有，卻指向錯的人）。
   ⚠ 查不到就是 null（會員 App 那條路沒有 staff 身分），**不可以報錯**。 */
  p_staff_id := (select staff_id from public.current_staff());
  if p_note is null or btrim(p_note) = '' then
    raise exception '備註內容不可為空';
  end if;
  -- 長度上限：備註是「一句提醒」不是日記。太長的東西沒有人會讀，
  -- 而且會把畫面撐開，把真正該看的資訊擠下去。
  if char_length(btrim(p_note)) > 200 then
    raise exception '備註最多 200 字（目前 %）', char_length(btrim(p_note));
  end if;

  if not exists (select 1 from members
                  where id = p_member_id and org_id = p_org_id and deleted_at is null) then
    raise exception '找不到這位會員';
  end if;

  insert into member_interactions(org_id, member_id, staff_id, channel, kind, note, created_by)
  values (p_org_id, p_member_id, p_staff_id, 'staff', 'note', btrim(p_note), p_staff_id)
  returning id into v_id;

  return jsonb_build_object('ok', true, 'id', v_id);
end $function$
;

-- [7.0] pos_add_queue_member_tx
CREATE OR REPLACE FUNCTION public.pos_add_queue_member_tx(p_org uuid, p_queue uuid, p_member uuid, p_staff uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_seats int; v_cnt int; v_status text; v_expires timestamptz;
  v_play_at timestamptz; v_source text; v_other uuid; v_fin jsonb;
begin
  if p_member is null then return jsonb_build_object('ok', false, 'reason', 'member_required'); end if;

  select seats, status, expires_at, play_at, source
    into v_seats, v_status, v_expires, v_play_at, v_source
    from match_queues where id = p_queue and org_id = p_org for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'not_found'); end if;
  if v_status <> 'waiting' then return jsonb_build_object('ok', false, 'reason', 'not_waiting', 'status', v_status); end if;
  if v_expires is not null and v_expires < now() then
    return jsonb_build_object('ok', false, 'reason', 'expired');
  end if;

  if exists (select 1 from match_queue_players
              where queue_id = p_queue and member_id = p_member and left_at is null) then
    return jsonb_build_object('ok', false, 'reason', 'already_in');
  end if;

  /* ⚠ 黑名單與衝突檢查照樣做，跟 App 那條路一致。
     店員在現場、看得到人，但「互相封鎖的兩個人被排在同一桌」是客人自己設的意思，
     不該因為換一個入口就繞過。擋下來之後店員可以當面問，那比事後尷尬好。 */
  begin
    perform _check_join_conflict(p_org, p_member, v_play_at, v_source);
  exception when others then
    return jsonb_build_object('ok', false, 'reason', 'conflict', 'message', sqlerrm);
  end;

  for v_other in
    select member_id from match_queue_players where queue_id = p_queue and left_at is null
  loop
    if _blocked_between(p_org, p_member, v_other) then
      return jsonb_build_object('ok', false, 'reason', 'blocked');
    end if;
  end loop;

  -- join_source = 'pos_walkin'：這是之後分析「現場登記 vs App 自己報名」的唯一依據，
  -- 沿用 'browse' 就永遠分不出來了
  insert into match_queue_players(org_id, queue_id, member_id, join_source)
  values (p_org, p_queue, p_member, 'pos_walkin')
  on conflict do nothing;

  select count(*) into v_cnt from match_queue_players where queue_id = p_queue and left_at is null;
  if v_cnt >= v_seats then
    v_fin := _finalize_queue_full_tx(p_org, p_queue, p_staff);
    return jsonb_build_object('ok', true, 'full', true,
      'status', v_fin->>'status', 'session_id', v_fin->>'session_id',
      'table_label', v_fin->>'table_label', 'seat_reason', v_fin->>'seat_reason');
  end if;

  return jsonb_build_object('ok', true, 'full', false, 'players', v_cnt, 'seats', v_seats);
end $function$
;

-- [7.0] pos_addon_checkout_tx
CREATE OR REPLACE FUNCTION public.pos_addon_checkout_tx(p_session_id uuid, p_member_id uuid, p_items jsonb, p_coupon_ids uuid[] DEFAULT NULL::uuid[], p_points_used bigint DEFAULT 0, p_payments jsonb DEFAULT NULL::jsonb, p_idempotency_key text DEFAULT NULL::text, p_staff_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_s      record;
  v_seated uuid;
  v_res    jsonb;
  v_order  uuid;
begin
  /* 🔴 操作者身分從 JWT 取，**不採信呼叫端送的 p_staff_id**（2026-09-04）。
     在此之前 POS 送的值來自 localStorage，店員可以改成別人 ——
     而那比沒有稽核更糟（看起來有，卻指向錯的人）。
   ⚠ 查不到就是 null（會員 App 那條路沒有 staff 身分），**不可以報錯**。 */
  p_staff_id := (select staff_id from public.current_staff());
  select s.id, s.store_id, s.table_id, s.status
    into v_s
    from table_sessions s
   where s.id = p_session_id and s.deleted_at is null;

  if v_s.id is null then
    return jsonb_build_object('ok', false, 'reason', 'session_not_found',
      'message', '場次不存在');
  end if;
  if v_s.status <> 'open' then
    return jsonb_build_object('ok', false, 'reason', 'session_closed',
      'message', '此場次已結束，無法加購');
  end if;

  -- 必須是本場次還在座的人才能加購，避免把消費掛到不相干的會員身上
  select sp.id into v_seated
    from session_players sp
   where sp.session_id = p_session_id
     and sp.member_id = p_member_id
     and sp.left_at is null;
  if v_seated is null then
    return jsonb_build_object('ok', false, 'reason', 'not_seated',
      'message', '此會員不在本桌，請先入座');
  end if;

  if p_items is null or jsonb_array_length(p_items) = 0 then
    return jsonb_build_object('ok', false, 'reason', 'empty_items',
      'message', '沒有可結帳的品項');
  end if;

  -- 委派給 checkout_tx。本函式是 SECURITY DEFINER，
  -- 被呼叫的 checkout_tx（INVOKER）會以定義者身分執行，不受 anon 的 RLS 限制
  -- —— 與 join_session_tx 同一套做法。
  v_res := checkout_tx(
    p_member_id, v_s.store_id, p_items, p_coupon_ids,
    coalesce(p_points_used, 0), p_payments, p_idempotency_key, p_staff_id);

  -- 補齊 checkout_tx 沒寫的欄位，與 join_session_tx 的處理完全一致：
  -- session_id/table_id 讓收桌結算找得到，entity_id 讓加盟分潤歸對主體，
  -- channel 讓報表分得出通路
  v_order := nullif(v_res->>'order_id', '')::uuid;
  if v_order is not null then
    update orders o
       set session_id = p_session_id,
           table_id   = v_s.table_id,
           channel    = 'counter',
           entity_id  = coalesce(o.entity_id,
                                 (select entity_id from stores where id = v_s.store_id))
     where o.id = v_order;
  end if;

  return v_res || jsonb_build_object('ok', true, 'addon', true,
                                     'session_id', p_session_id);
end $function$
;

-- [7.0] pos_checkout_with_topup_tx
CREATE OR REPLACE FUNCTION public.pos_checkout_with_topup_tx(p_session_id uuid, p_member_id uuid, p_join_type text DEFAULT 'opener'::text, p_items jsonb DEFAULT NULL::jsonb, p_coupon_ids uuid[] DEFAULT NULL::uuid[], p_points_used bigint DEFAULT 0, p_payments jsonb DEFAULT NULL::jsonb, p_pay_for uuid[] DEFAULT NULL::uuid[], p_staff_id uuid DEFAULT NULL::uuid, p_idempotency_key text DEFAULT NULL::text, p_topup_points bigint DEFAULT 0, p_topup_bonus bigint DEFAULT 0, p_topup_amount bigint DEFAULT 0, p_topup_method text DEFAULT 'cash'::text, p_topup_cash_received bigint DEFAULT NULL::bigint, p_topup_change_given bigint DEFAULT NULL::bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_s      record;
  v_topup  jsonb := null;
  v_join   jsonb := null;
  v_base   text;
  v_seated boolean;
  v_extra  int := 0;
  v_mode   text;
begin
  /* 🔴 操作者身分從 JWT 取，**不採信呼叫端送的 p_staff_id**（2026-09-04）。
     在此之前 POS 送的值來自 localStorage，店員可以改成別人 ——
     而那比沒有稽核更糟（看起來有，卻指向錯的人）。
   ⚠ 查不到就是 null（會員 App 那條路沒有 staff 身分），**不可以報錯**。 */
  p_staff_id := (select staff_id from public.current_staff());
  if p_topup_points > 0 and coalesce(p_idempotency_key, '') = '' then
    return jsonb_build_object('ok', false, 'reason', 'idempotency_key_required',
      'message', '含儲值的結帳必須帶冪等鍵');
  end if;

  select * into v_s from table_sessions where id = p_session_id;
  if v_s.id is null then
    return jsonb_build_object('ok', false, 'reason', 'session_not_found');
  end if;
  if v_s.status <> 'open' then
    return jsonb_build_object('ok', false, 'reason', 'session_closed',
      'message', '此場次已收桌或已作廢');
  end if;

  -- 由資料庫判斷是否已入座，不採信前端傳來的推測值
  select exists (
    select 1 from session_players sp
     where sp.session_id = p_session_id
       and sp.member_id  = p_member_id
       and sp.left_at is null) into v_seated;

  if p_items is not null and jsonb_typeof(p_items) = 'array' then
    v_extra := jsonb_array_length(p_items);
  end if;

  v_mode := case
              when not v_seated   then 'join'
              when v_extra > 0    then 'addon'
              else 'topup_only'
            end;

  if v_mode = 'topup_only' and p_topup_points <= 0 then
    return jsonb_build_object('ok', false, 'reason', 'nothing_to_do',
      'message', '這位客人已入座，請選擇商品或儲值');
  end if;

  v_base := coalesce(p_idempotency_key,
                     p_session_id::text || ':' || p_member_id::text);

  -- ══ 原子區塊：任何一步 raise，整段回滾 ══
  begin

    if p_topup_points > 0 then
      /* ★ 2026-08-25 改成具名參數（唯一的改動）。
         原本是位置參數，topup_tx 哪天少一個參數就會整排位移，
         而型別相容時不會報錯，只會把值寫到錯的欄位。

         ⚠ p_bonus_points 照樣傳（值被 topup_tx 忽略，由
           calc_topup_bonus_tx 從 topup_plans 算）——
           **明著傳而不是靜靜省略**：省略的話，哪天有人把忽略邏輯拿掉，
           行為會無聲改變。傳過去則永遠是「送了但被忽略」這個明確狀態，
           而 topup_tx 的回傳有 bonus_ignored 會標出來。 */
      v_topup := topup_tx(
        p_member_id       => p_member_id,
        p_store_id        => v_s.store_id,
        p_points          => p_topup_points,
        p_amount_twd      => p_topup_amount,
        p_pay_method      => p_topup_method,
        p_idempotency_key => v_base || ':topup',
        p_bonus_points    => p_topup_bonus,
        p_external_ref    => null,
        p_staff_id        => p_staff_id,
        p_note            => 'POS 結帳時儲值');

      -- 回填桌次脈絡與實收找零。
      -- 實收找零只有在「現金全部歸儲值」時才會有值 ——
      -- 消費有現金要收時，前端會把它記在 order_payments 那邊，
      -- 兩邊不會同時有值（實體收款是一次事件，不該重複記錄）。
      update topup_orders
         set session_id    = p_session_id,
             cash_received = p_topup_cash_received,
             change_given  = p_topup_change_given
       where id = (v_topup ->> 'topup_id')::uuid;
    end if;

    if v_mode = 'join' then
      v_join := join_session_tx(
        p_session_id, p_member_id, p_join_type, p_coupon_ids,
        coalesce(p_points_used, 0), p_payments, p_staff_id,
        v_base || ':order', p_pay_for, p_items);

    elsif v_mode = 'addon' then
      v_join := pos_addon_checkout_tx(
        p_session_id, p_member_id, p_items, p_coupon_ids,
        coalesce(p_points_used, 0), p_payments,
        v_base || ':order', p_staff_id);
    end if;

    -- 兩支結帳函式的業務錯誤都是「回傳 ok:false」而不是拋例外。
    -- 不主動 raise 的話交易會照常提交 —— 儲值就留下來了。
    if v_join is not null
       and not coalesce((v_join ->> 'ok')::boolean, false) then
      raise exception 'checkout_failed:%',
        coalesce(v_join ->> 'reason', 'unknown') using errcode = 'P0001';
    end if;

  exception
    when others then
      if SQLERRM like 'checkout_failed:%' then
        return jsonb_build_object('ok', false,
          'reason', split_part(SQLERRM, ':', 2),
          'stage', 'checkout', 'mode', v_mode,
          'message', case when p_topup_points > 0
                          then '結帳失敗，儲值已一併取消'
                          else '結帳失敗' end);
      end if;
      return jsonb_build_object('ok', false, 'reason', 'topup_failed',
        'stage', case when v_topup is null then 'topup' else 'checkout' end,
        'mode', v_mode, 'message', SQLERRM);
  end;

  return jsonb_build_object(
    'ok', true, 'mode', v_mode,
    'topup', v_topup, 'checkout', v_join,
    'new_balance', v_topup ->> 'new_balance');
end $function$
;

-- [7.0] pos_close_queue_tx
CREATE OR REPLACE FUNCTION public.pos_close_queue_tx(p_org_id uuid, p_queue uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_src text; v_status text; v_players int;
begin
  select source, status into v_src, v_status
    from match_queues where id = p_queue and org_id = p_org_id;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'not_found');
  end if;
  if v_status <> 'waiting' then
    -- 冪等：已經關掉或已成桌就直接回報現況，不當成錯誤
    return jsonb_build_object('ok', true, 'already', v_status);
  end if;

  -- ⚠ 有人報名就不給關。客人排了半小時，房被店員一鍵刪掉而且沒有任何通知，
  --   那是客訴。要處理得先有「通知報名者」這件事，先擋住。
  select count(*) into v_players
    from match_queue_players where queue_id = p_queue and left_at is null;
  if v_players > 0 then
    return jsonb_build_object('ok', false, 'reason', 'has_players', 'players', v_players);
  end if;

  update match_queues
     set status = 'expired', expires_at = least(coalesce(expires_at, now()), now()), updated_at = now()
   where id = p_queue and org_id = p_org_id;

  return jsonb_build_object('ok', true, 'source', v_src);
end $function$
;

-- [7.0] pos_create_queue_tx
CREATE OR REPLACE FUNCTION public.pos_create_queue_tx(p_org_id uuid, p_store uuid, p_stake uuid, p_play_at timestamp with time zone, p_game_type text DEFAULT '台麻'::text, p_flower text DEFAULT '無花'::text, p_rounds text DEFAULT '2 將'::text, p_seats integer DEFAULT 4, p_tags jsonb DEFAULT '[]'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_qid  uuid;
  v_tags jsonb;
  v_bad  text;
begin
  -- 業務錯誤一律回 {ok:false}，不拋例外 —— 前端要能分辨「擋下來」與「壞掉」
  if p_store   is null then return jsonb_build_object('ok', false, 'reason', 'store_required'); end if;
  if p_stake   is null then return jsonb_build_object('ok', false, 'reason', 'stake_required'); end if;
  if p_play_at is null then return jsonb_build_object('ok', false, 'reason', 'play_at_required'); end if;

  -- 開一個已經過去的時間點：客人永遠看不到（list 有 expires_at > now 的條件），
  -- 店員會以為開好了。這種「成功了但沒有效果」正是硬規則 4 要防的形狀。
  if p_play_at <= now() then
    return jsonb_build_object('ok', false, 'reason', 'play_at_in_past');
  end if;

  -- ── 標籤驗證 ─────────────────────────────────────────────
  -- ⚠ null 與 '[]' 都視為「沒有標籤」，不是錯誤。
  v_tags := coalesce(p_tags, '[]'::jsonb);

  -- ⚠ 先判型別再展開：jsonb 欄位也可能收到物件或字串，
  --   那時 jsonb_array_elements_text 是**直接拋錯**而不是回空集合。
  if jsonb_typeof(v_tags) <> 'array' then
    return jsonb_build_object('ok', false, 'reason', 'tags_not_array',
      'message', '標籤要用陣列格式');
  end if;

  -- 未知代碼一律擋，而且要說出是哪一個。
  -- ⚠ 這道擋牆才是重點：match_queues.tags 沒有 CHECK，
  --   放行未知代碼的後果是「店員以為掛好了、客人什麼都看不到、沒有錯誤訊息」。
  --   零列時 string_agg 回 null，所以 v_bad is null 就是全部合法。
  select string_agg(e.t, '、') into v_bad
    from jsonb_array_elements_text(v_tags) as e(t)
   where not exists (
     select 1 from queue_tags g where g.code = e.t and g.is_active
   );
  if v_bad is not null then
    return jsonb_build_object('ok', false, 'reason', 'unknown_tag',
      'message', '找不到這些標籤：' || v_bad);
  end if;

  -- 完全撞號才擋。同時段開兩桌不同級距是合理的（大注場與純娛樂場並存）。
  if exists (
    select 1 from match_queues
     where org_id = p_org_id and store_id = p_store
       and play_at = p_play_at
       and stake_level_id is not distinct from p_stake
       and status = 'waiting'
  ) then
    return jsonb_build_object('ok', false, 'reason', 'duplicate');
  end if;

  insert into match_queues(
    org_id, store_id, stake_level_id, game_type, flower, rounds, seats,
    prefs, opened_by, play_at, expires_at, source, status, tags)
  values (
    p_org_id, p_store, p_stake, p_game_type, p_flower, p_rounds, coalesce(p_seats, 4),
    '{}'::jsonb,
    null,          -- 官方開桌沒有開房者；店員登入還沒做
    p_play_at,
    p_play_at,     -- 開打即不可再加入，與 recurring 一致
    'pos', 'waiting', v_tags)
  returning id into v_qid;

  return jsonb_build_object('ok', true, 'queue_id', v_qid, 'tags', v_tags);
end $function$
;

-- [7.0] pos_create_recurring_tx
CREATE OR REPLACE FUNCTION public.pos_create_recurring_tx(p_org_id uuid, p_store uuid, p_stake uuid, p_frequency text, p_weekday integer, p_start_time time without time zone, p_game_type text DEFAULT '台麻'::text, p_flower text DEFAULT '無花'::text, p_rounds text DEFAULT '2 將'::text, p_seats integer DEFAULT 4, p_lead_hours integer DEFAULT NULL::integer, p_tags jsonb DEFAULT '[]'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_id uuid; v_lead int; v_gen int;
  v_tags jsonb; v_bad text;
begin
  -- 業務錯誤回 {ok:false}，不拋例外 —— 前端要能分辨「擋下來」與「壞掉」
  if p_store      is null then return jsonb_build_object('ok', false, 'reason', 'store_required'); end if;
  if p_stake      is null then return jsonb_build_object('ok', false, 'reason', 'stake_required'); end if;
  if p_start_time is null then return jsonb_build_object('ok', false, 'reason', 'start_time_required'); end if;
  if p_frequency not in ('daily', 'weekly') then
    return jsonb_build_object('ok', false, 'reason', 'bad_frequency');
  end if;
  -- 每週的局沒指定星期幾，生成函式會拿 null 去比對而永遠不成立 ——
  -- 建得起來但一筆實例都不會產生，是最難查的那種
  if p_frequency = 'weekly' and (p_weekday is null or p_weekday not between 0 and 6) then
    return jsonb_build_object('ok', false, 'reason', 'weekday_required');
  end if;

  v_lead := coalesce(p_lead_hours, case when p_frequency = 'daily' then 24 else 24 * 7 end);
  if v_lead not between 1 and 720 then
    return jsonb_build_object('ok', false, 'reason', 'bad_lead_hours');
  end if;

  -- ── 標籤驗證（與 pos_create_queue_tx 同一套）─────────────
  -- ⚠ 先判型別再展開：jsonb 欄位也可能收到物件或字串，
  --   那時 jsonb_array_elements_text 是直接拋錯而不是回空集合。
  v_tags := coalesce(p_tags, '[]'::jsonb);
  if jsonb_typeof(v_tags) <> 'array' then
    return jsonb_build_object('ok', false, 'reason', 'tags_not_array',
      'message', '標籤要用陣列格式');
  end if;
  select string_agg(e.t, '、') into v_bad
    from jsonb_array_elements_text(v_tags) as e(t)
   where not exists (select 1 from queue_tags g where g.code = e.t and g.is_active);
  if v_bad is not null then
    return jsonb_build_object('ok', false, 'reason', 'unknown_tag',
      'message', '找不到這些標籤：' || v_bad);
  end if;

  -- 同門市、同頻率、同星期、同時間已經有一個啟用中的範本 → 擋
  if exists (
    select 1 from recurring_tables
     where org_id = p_org_id and store_id = p_store
       and frequency = p_frequency
       and weekday is not distinct from (case when p_frequency = 'daily' then null else p_weekday end)
       and start_time = p_start_time
       and enabled = true
  ) then
    return jsonb_build_object('ok', false, 'reason', 'duplicate');
  end if;

  insert into recurring_tables(
    org_id, store_id, stake_level_id, frequency, weekday, start_time,
    game_type, flower, rounds, seats, enabled, lead_hours, tags)
  values (
    p_org_id, p_store, p_stake, p_frequency,
    case when p_frequency = 'daily' then null else p_weekday end,   -- daily 不存星期
    p_start_time,
    p_game_type, p_flower, p_rounds, coalesce(p_seats, 4), true, v_lead, v_tags)
  returning id into v_id;

  -- 立刻生成，不讓店員等下一輪 cron（最多 6 小時）
  v_gen := generate_recurring_instances_tx(p_org_id, 7);

  return jsonb_build_object('ok', true, 'recurring_id', v_id, 'generated', v_gen, 'tags', v_tags);
end $function$
;

-- [7.0] pos_list_queues_tx
CREATE OR REPLACE FUNCTION public.pos_list_queues_tx(p_org uuid, p_store uuid, p_before timestamp with time zone DEFAULT NULL::timestamp with time zone, p_limit integer DEFAULT 20)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  with live as (
    /* 現在的事：全部回傳，**不分頁**。
       ⚠ 被截掉的話會出現「有一桌在等你結帳但它在第二頁」，
         而店員不會知道要去翻。 */
    select q.id
      from match_queues q
      left join table_sessions ts on ts.id = q.matched_session_id
     where q.org_id = p_org and q.store_id = p_store
       and (
         (q.status = 'waiting'
           and (q.expires_at is null or q.expires_at > now())
           and (q.open_at is null or q.open_at <= now()))
         or q.status = 'matched'
         or (q.status = 'seated' and ts.status = 'open' and ts.deleted_at is null)
       )
  ),
  history as (
    /* 已收桌的：新到舊，分頁。
       🔴 **配桌是延續的** —— 前兩位可能是上一班找到的，靠下一班完成，
         所以這裡**不可以有任何日／班的邊界**（2026-09-07 拿掉了 7 天窗口）。
       ⚠ `p_limit` 夾在 1..100：0 或負數會讓這一段整個消失，
         而症狀是「已完成分頁空的」，看不出是參數問題。 */
    select q.id
      from match_queues q
      join table_sessions ts on ts.id = q.matched_session_id
     where q.org_id = p_org and q.store_id = p_store
       and q.status = 'seated'
       and ts.status = 'completed' and ts.deleted_at is null
       and (p_before is null or ts.ended_at < p_before)
     order by ts.ended_at desc
     limit least(greatest(coalesce(p_limit, 20), 1), 100)
  ),
  picked as (select id from live union select id from history)
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', q.id,
    'status', q.status,
    'source', q.source,
    'stake_level_id', q.stake_level_id,
    'stake', sl.label,
    'game_type', q.game_type, 'flower', q.flower, 'rounds', q.rounds,
    'seats', q.seats,
    'play_at', q.play_at,
    'open_at', q.open_at,
    'recurring_freq', q.recurring_freq,
    'opener', mo.display_name,
    'session_id', q.matched_session_id, 'tags', q.tags,
    'table_label', tb.label,
    'seated_at', case when q.status = 'seated' then q.updated_at else null end,
    /* `auto` = 系統帶的／`manual` = 店員在 POS 按的。
       ⚠ 值不是 `auto` 的一律寫「已帶到 A3」不寫「系統自動」。 */
    'open_method', ts.open_method,
    /* ★ 2026-09-06：這個房還能不能被系統自動配。
       false ＝ 帶到的桌被取消過，之後由店員手動配（隨機／指定）。
       🔴 少了它，`matched` 且沒有桌的房前端**分不出**
         「排程等一下會配」與「在等我動手」。 */
    'auto_seat', q.auto_seat,
    /* 🔴 數的是「這桌收了幾份檯費」，**不要加 `left_at is null`** ——
       收桌時在座玩家一律被寫 `left_at`，那個條件會讓收桌那一刻
       掉回 0，配桌列表就對一個早就收齊的房喊「前往結帳」。
       ⚠ 也不要改成數 `order_id is not null`：暢打的人 order_id 是 null
       （那是「不用付」不是「還沒付」）。 */
    'paid_count', (
      select count(*) from session_players sp
       where sp.session_id = q.matched_session_id),
    'session_status', ts.status,
    'settled_at', ts.ended_at,
    'members', coalesce((
      select jsonb_agg(jsonb_build_object(
        'member_id', m.id, 'nickname', m.display_name,
        'rank', m.rank, 'title', m.title,
        'tier', coalesce(m.tier_override, m.tier),
        'joined_at', p.joined_at,
        'walk_in', p.join_source = 'pos_walkin'
      ) order by p.joined_at)
      from match_queue_players p
      join members m on m.id = p.member_id
      where p.queue_id = q.id and p.left_at is null), '[]'::jsonb)
    /* 排序：現在的事在前；已收桌的之間**依收桌時間新到舊**。
       ⚠ 舊版依 `play_at`（開打時間）—— 往回翻時順序會跳。 */
  ) order by (ts.status is distinct from 'completed') desc,
             (q.status = 'seated') desc,
             (q.status = 'matched') desc,
             ts.ended_at desc nulls last,
             q.play_at), '[]'::jsonb)
  from match_queues q
  join picked pk on pk.id = q.id
  left join stake_levels sl on sl.id = q.stake_level_id and sl.org_id = p_org
  left join members mo on mo.id = q.opened_by
  left join table_sessions ts on ts.id = q.matched_session_id
  left join tables tb on tb.id = ts.table_id
$function$
;

-- [7.0] pos_list_recurring_tx
CREATE OR REPLACE FUNCTION public.pos_list_recurring_tx(p_org_id uuid, p_store uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', r.id,
    'frequency', r.frequency,
    'weekday', r.weekday,
    'start_time', r.start_time,
    'game_type', r.game_type,
    'flower', r.flower,
    'rounds', r.rounds,
    'seats', r.seats,
    'enabled', r.enabled,
    'lead_hours', r.lead_hours,
    'stake_level_id', r.stake_level_id,
    'stake', sl.label,
    'tags', coalesce(r.tags, '[]'::jsonb),
    -- 下一場：已生成、還沒開打的最早那筆
    'next_play_at', (select min(q.play_at) from match_queues q
                      where q.recurring_id = r.id and q.status = 'waiting' and q.play_at > now()),
    -- 客人現在看得到幾筆（開賣時間已到的）
    'open_now', (select count(*) from match_queues q
                  where q.recurring_id = r.id and q.status = 'waiting'
                    and q.play_at > now() and (q.open_at is null or q.open_at <= now())),
    -- 已生成但還沒開賣（接班用）
    'pending_open', (select count(*) from match_queues q
                      where q.recurring_id = r.id and q.status = 'waiting'
                        and q.play_at > now() and q.open_at is not null and q.open_at > now())
  ) order by r.enabled desc, r.frequency, r.weekday nulls first, r.start_time), '[]'::jsonb)
  from recurring_tables r
  left join stake_levels sl on sl.id = r.stake_level_id and sl.org_id = p_org_id
  where r.org_id = p_org_id and r.store_id = p_store
$function$
;

-- [7.0] pos_member_detail_tx
CREATE OR REPLACE FUNCTION public.pos_member_detail_tx(p_org_id uuid, p_member_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_p jsonb;      -- ★ 2026-09-08：等級那一段整段搬到 member_tier_progress_tx
begin
  if not exists (select 1 from members
                  where id = p_member_id and org_id = p_org_id and deleted_at is null) then
    return null;
  end if;

  v_p := public.member_tier_progress_tx(p_member_id, p_org_id);

  return (
    select jsonb_build_object(
      'id', m.id, 'nickname', m.display_name, 'phone', m.phone,
      /* ⚠ 這些鍵的名字**一個都不可以改** —— `MemberPage.jsx` 依賴它們
         （進度條算式用 lifetime_spend / tier_threshold / next_tier_threshold）。 */
      'tier', v_p ->> 'tier',
      'tier_discount_pct', (v_p ->> 'tier_discount_pct')::int,
      'rank', m.rank, 'title', m.title,
      'avatar_url', m.avatar_url, 'avatar_bear', m.avatar_bear, 'avatar_source', m.avatar_source, 'avatar_photo_path', m.avatar_photo_path,
      'balance', coalesce(w.balance, 0),
      'birthday', m.birthday,
      'lifetime_spend', (v_p ->> 'lifetime_spend')::bigint,
      'tier_threshold', (v_p ->> 'tier_threshold')::bigint,
      'tier_by_override', (v_p ->> 'tier_by_override')::boolean,
      'tier_earned', v_p ->> 'tier_earned',
      'next_tier', v_p ->> 'next_tier',
      'next_tier_label', v_p ->> 'next_tier_label',
      'next_tier_threshold', (v_p ->> 'next_tier_threshold')::bigint,
      'next_tier_gap', (v_p ->> 'next_tier_gap')::bigint,

      /* ★ 常加購品項（2026-08-25）。
         🔴 **排除 venue_fee** —— 檯費是每個人每次都買的，
           不排除的話這一格永遠只會顯示「場地費」，等於沒有資訊。
           排掉之後它回答的是「這位客人愛吃什麼」，店員可以據此推薦。
         ⚠ 用 name 分組不用 product_id：order_items.name 是**下單當時的快照**，
           改名過的商品用 product_id 會併在一起、用 name 會分開。
           這裡要的是「店員唸得出來的東西」，快照才是對的。
         只取前 3 名：櫃檯要的是一句話，不是排行榜。 */
      'top_items', (
        select coalesce(jsonb_agg(jsonb_build_object(
                 'name', t.nm, 'qty', t.q, 'revenue_type', t.rt)
                 order by t.q desc), '[]'::jsonb)
        from (select oi.name as nm, sum(oi.qty)::int as q,
                     min(oi.revenue_type) as rt
                from order_items oi
                join orders o2 on o2.id = oi.order_id
               where o2.member_id = m.id
                 and o2.org_id = p_org_id
                 and o2.status = 'paid'
                 and oi.revenue_type <> 'venue_fee'
               group by oi.name
               order by 2 desc
               limit 3) t),

      /* ★ 互動紀錄（2026-08-25）。
         回傳**全部類型**不只 note —— 藍圖要求店員看得到系統已發過什麼，
         只回 note 的話 MA 上線後會重複關懷同一個人。 */
      'interactions', (
        select coalesce(jsonb_agg(jsonb_build_object(
                 'id', i.id, 'channel', i.channel, 'kind', i.kind,
                 'note', i.note, 'created_at', i.created_at)
                 order by i.created_at desc), '[]'::jsonb)
        from (select * from member_interactions
               where member_id = m.id and org_id = p_org_id
               order by created_at desc limit 5) i),

      'coupons', (
        select coalesce(jsonb_agg(jsonb_build_object(
          'id', mc.id, 'name', c.name,
          'applies_to', c.applies_to,
          'discount_type', c.discount_type,
          'discount_value', c.discount_value,
          'min_spend', c.min_spend, 'max_discount', c.max_discount,
          'expires_at', mc.expires_at
        ) order by mc.expires_at nulls last), '[]'::jsonb)
        from member_coupons mc
        join coupons c on c.id = mc.coupon_id
        where mc.member_id = m.id
          and mc.used_at is null and coalesce(mc.status,'') <> 'used'
          and (mc.expires_at is null or mc.expires_at > now()))
    )
    from members m
    left join wallets w on w.member_id = m.id
    where m.id = p_member_id and m.org_id = p_org_id and m.deleted_at is null
  );
end $function$
;

-- [7.0] pos_member_orders_tx
CREATE OR REPLACE FUNCTION public.pos_member_orders_tx(p_member_id uuid, p_limit integer DEFAULT 5, p_before timestamp with time zone DEFAULT NULL::timestamp with time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_org uuid;
begin
  if not public.can('member.lookup') then
    raise exception 'forbidden: 需要店員身分';
  end if;

  v_org := public.current_org_id();

  /* 🔴 **要驗那位客人屬不屬於這個機構** —— 今天只有一個 org 所以踩不到，
     **那是運氣不是設計**（同 2026-08-27 補 org 比對時的結論）。
     ⚠ 訊息不分「不存在」與「不同 org」—— 兩者都不該讓對方知道。 */
  if not exists (
    select 1 from members m
     where m.id = p_member_id and m.org_id = v_org and m.deleted_at is null
  ) then
    return jsonb_build_object('ok', false, 'reason', 'member_not_found');
  end if;

  return public._member_orders_core(p_member_id, p_limit, p_before);
end $function$
;

-- [7.0] pos_move_queue_member_tx
CREATE OR REPLACE FUNCTION public.pos_move_queue_member_tx(p_org uuid, p_from_queue uuid, p_to_queue uuid, p_member uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_staff uuid; v_join_source text;
  v_from_status text; v_from_source text; v_from_opener uuid;
  v_to_status text; v_to_seats int; v_to_expires timestamptz;
  v_to_play_at timestamptz; v_to_source text;
  v_cnt int; v_left int; v_next uuid; v_other uuid; v_fin jsonb;
begin
  select staff_id into v_staff from current_staff();
  if v_staff is null then
    return jsonb_build_object('ok', false, 'reason', 'not_staff');
  end if;
  if p_member is null then
    return jsonb_build_object('ok', false, 'reason', 'member_required');
  end if;
  if p_from_queue = p_to_queue then
    return jsonb_build_object('ok', false, 'reason', 'same_queue');
  end if;

  /* 兩個房都要鎖，而且**依 id 排序**再鎖 ——
     兩個店員同時把 A 的人移到 B、把 B 的人移到 A 就會互等。
     固定的鎖定順序是唯一不用碰運氣的解法。 */
  perform 1 from match_queues
   where id = any(array[p_from_queue, p_to_queue]) and org_id = p_org
   order by id for update;

  select status, source, opened_by into v_from_status, v_from_source, v_from_opener
    from match_queues where id = p_from_queue and org_id = p_org;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'from_not_found');
  end if;
  if v_from_status <> 'waiting' then
    return jsonb_build_object('ok', false, 'reason', 'from_not_waiting', 'status', v_from_status);
  end if;

  select status, seats, expires_at, play_at, source
    into v_to_status, v_to_seats, v_to_expires, v_to_play_at, v_to_source
    from match_queues where id = p_to_queue and org_id = p_org;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'to_not_found');
  end if;
  if v_to_status <> 'waiting' then
    return jsonb_build_object('ok', false, 'reason', 'to_not_waiting', 'status', v_to_status);
  end if;
  if v_to_expires is not null and v_to_expires < now() then
    return jsonb_build_object('ok', false, 'reason', 'to_expired');
  end if;

  /* 來源房要有這個人 —— 順便把他的入場來源留下來。
     ⚠ 那個值是「他當初怎麼進來的」，移動不可以把它蓋掉。 */
  select join_source into v_join_source
    from match_queue_players
   where queue_id = p_from_queue and member_id = p_member and left_at is null;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'not_in');
  end if;

  if exists (select 1 from match_queue_players
              where queue_id = p_to_queue and member_id = p_member and left_at is null) then
    return jsonb_build_object('ok', false, 'reason', 'already_in');
  end if;

  select count(*) into v_cnt
    from match_queue_players where queue_id = p_to_queue and left_at is null;
  if v_cnt >= v_to_seats then
    return jsonb_build_object('ok', false, 'reason', 'to_full', 'players', v_cnt, 'seats', v_to_seats);
  end if;

  /* 黑名單照擋，理由與 pos_add_queue_member_tx 相同：
     「互相封鎖的兩個人被排在同一桌」是客人自己設的意思，
     不該因為換一個入口就繞過。擋下來店員可以當面問。 */
  for v_other in
    select member_id from match_queue_players
     where queue_id = p_to_queue and left_at is null
  loop
    if _blocked_between(p_org, p_member, v_other) then
      return jsonb_build_object('ok', false, 'reason', 'blocked');
    end if;
  end loop;

  /* 🔴 順序只能是「先離開來源，再檢查衝突，最後插進目標」——
     衝突檢查掃的是「身上所有還沒結束的場」，來源房自己就在裡面，
     不先離開的話它一定會跟自己撞。

     ⚠ 而「先離開」表示檢查失敗時已經寫進去了。所以整段包在
       begin…exception 裡：**那個區塊有隱含的 savepoint**，
       回傳之前會把離開那一筆退掉。
     📌 這與 2026-08-16 那個坑（回 {ok:false} 不會回滾、留下半筆帳）
       的差別就在這個 handler —— 那次是**沒有** handler。 */
  begin
    update match_queue_players
       set left_at = now(), leave_reason = 'switched',
           leave_detail = '店員移到別的房', left_by_staff_id = v_staff
     where queue_id = p_from_queue and member_id = p_member and left_at is null;

    perform _check_join_conflict(p_org, p_member, v_to_play_at, v_to_source);

    insert into match_queue_players(org_id, queue_id, member_id, join_source)
    values (p_org, p_to_queue, p_member, v_join_source);
  exception when others then
    return jsonb_build_object('ok', false, 'reason', 'conflict', 'message', sqlerrm);
  end;

  /* 來源房的善後 —— 與移除那支、與會員自己退房那支完全一致 */
  select count(*) into v_left
    from match_queue_players where queue_id = p_from_queue and left_at is null;
  if v_left = 0 and v_from_source <> 'recurring' then
    update match_queues set status = 'cancelled', updated_at = now() where id = p_from_queue;
  elsif v_left > 0 and p_member = v_from_opener then
    select member_id into v_next from match_queue_players
     where queue_id = p_from_queue and left_at is null order by joined_at asc limit 1;
    update match_queues set opened_by = v_next, updated_at = now() where id = p_from_queue;
  else
    update match_queues set updated_at = now() where id = p_from_queue;
  end if;

  /* 目標房滿了就照既有的路走（改 matched、通知每個人、試著自動帶桌） */
  select count(*) into v_cnt
    from match_queue_players where queue_id = p_to_queue and left_at is null;
  if v_cnt >= v_to_seats then
    v_fin := _finalize_queue_full_tx(p_org, p_to_queue, v_staff);
    return jsonb_build_object('ok', true, 'full', true,
      'from_players', v_left,
      'status', v_fin->>'status', 'session_id', v_fin->>'session_id',
      'table_label', v_fin->>'table_label', 'seat_reason', v_fin->>'seat_reason');
  end if;

  return jsonb_build_object('ok', true, 'full', false,
    'from_players', v_left, 'players', v_cnt, 'seats', v_to_seats);
end $function$
;

-- [7.0] pos_move_session_tx
CREATE OR REPLACE FUNCTION public.pos_move_session_tx(p_session_id uuid, p_table_id uuid, p_staff_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_s record; v_t record; v_busy uuid;
begin
  /* 🔴 操作者身分從 JWT 取，不採信呼叫端送的值（2026-09-04 那一批的規矩）。
     ⚠ 查不到就是 null，不可以報錯。 */
  p_staff_id := (select staff_id from public.current_staff());

  select ts.*, t.label as old_label into v_s
    from table_sessions ts
    left join tables t on t.id = ts.table_id
   where ts.id = p_session_id;
  if not found then return jsonb_build_object('ok', false, 'reason', 'not_found'); end if;
  if v_s.status <> 'open' then
    return jsonb_build_object('ok', false, 'reason', 'not_open', 'status', v_s.status);
  end if;

  select * into v_t from tables where id = p_table_id and deleted_at is null;
  if not found then return jsonb_build_object('ok', false, 'reason', 'table_not_found'); end if;
  if v_t.id = v_s.table_id then
    return jsonb_build_object('ok', false, 'reason', 'same_table', 'table_label', v_t.label);
  end if;
  if not coalesce(v_t.is_active, true) then
    return jsonb_build_object('ok', false, 'reason', 'table_unavailable', 'table_label', v_t.label);
  end if;
  /* ⚠ 跨門市不可以 —— 客人已經在這間店裡了。 */
  if v_t.store_id <> v_s.store_id then
    return jsonb_build_object('ok', false, 'reason', 'other_store');
  end if;

  /* 先查再改，不要靠 `uq_sessions_open_table` 拋 23505 ——
     那個錯誤訊息店員看不懂，而這裡答得出是誰佔著。 */
  select s.id into v_busy from table_sessions s
   where s.table_id = p_table_id and s.status = 'open' and s.deleted_at is null;
  if v_busy is not null then
    return jsonb_build_object('ok', false, 'reason', 'table_busy',
                              'table_label', v_t.label, 'session_id', v_busy);
  end if;

  update table_sessions
     set table_id = p_table_id, updated_at = now(),
         updated_by = coalesce(p_staff_id, updated_by)
   where id = p_session_id and status = 'open';
  if not found then
    -- 併發保護：同時兩人按，只有一個會成功
    return jsonb_build_object('ok', false, 'reason', 'race_lost');
  end if;

  return jsonb_build_object('ok', true, 'session_id', p_session_id,
                            'from', v_s.old_label, 'to', v_t.label);
end $function$
;

-- [7.0] pos_queue_members_tx
CREATE OR REPLACE FUNCTION public.pos_queue_members_tx(p_org_id uuid, p_queue uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select coalesce(jsonb_agg(jsonb_build_object(
    'member_id', m.id,
    'nickname',  m.display_name,
    'rank',      m.rank,
    'title',     m.title,
    'joined_at', p.joined_at
    /* ⚠ 「這個人是櫃檯登記的還是自己在 App 報名的」**不在這裡回**。
       那個問題由 pos_list_queues_tx 的布林欄位回答，POS 的配桌座位卡
       讀的就是它。同一個事實只有一個名字 —— 這支曾經多回過一份，
       2026-09-09 當天收掉。要標現場請用那一個，不要在這裡再加。 */
  ) order by p.joined_at), '[]'::jsonb)
  from match_queue_players p
  join members m on m.id = p.member_id
  join match_queues q on q.id = p.queue_id
  where p.queue_id = p_queue
    and p.left_at is null
    and q.org_id = p_org_id
$function$
;

-- [7.0] pos_quick_checkout_tx
CREATE OR REPLACE FUNCTION public.pos_quick_checkout_tx(p_member_id uuid, p_store_id uuid, p_items jsonb DEFAULT NULL::jsonb, p_coupon_ids uuid[] DEFAULT NULL::uuid[], p_points_used bigint DEFAULT 0, p_payments jsonb DEFAULT NULL::jsonb, p_idempotency_key text DEFAULT NULL::text, p_staff_id uuid DEFAULT NULL::uuid, p_topup_points bigint DEFAULT 0, p_topup_amount bigint DEFAULT 0, p_topup_method text DEFAULT 'cash'::text, p_topup_cash_received bigint DEFAULT NULL::bigint, p_topup_change_given bigint DEFAULT NULL::bigint, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_topup      jsonb;
  v_order      jsonb;
  v_has_topup  boolean;
  v_has_items  boolean;
  v_mode       text;
  v_balance    bigint;
begin
  /* 🔴 操作者身分從 JWT 取，**不採信呼叫端送的 p_staff_id**（2026-09-04）。
     在此之前 POS 送的值來自 localStorage，店員可以改成別人 ——
     而那比沒有稽核更糟（看起來有，卻指向錯的人）。
   ⚠ 查不到就是 null（會員 App 那條路沒有 staff 身分），**不可以報錯**。 */
  p_staff_id := (select staff_id from public.current_staff());
  /* 冪等鍵必填。店員在網路慢時按第二下是常態，
     沒有它就是收兩次錢 —— 這不是防呆是防帳。 */
  if p_idempotency_key is null or btrim(p_idempotency_key) = '' then
    raise exception 'idempotency_key 必填';
  end if;

  if p_member_id is null then
    raise exception '快速結帳必須指定會員（checkout_tx 會查錢包，沒有會員一定拋錯）';
  end if;
  if p_store_id is null then
    raise exception 'store_id 必填';
  end if;

  v_has_topup := coalesce(p_topup_amount, 0) > 0 or coalesce(p_topup_points, 0) > 0;

  /* ⚠ 先判 jsonb_typeof。p_items 若被送成物件或字串，
     jsonb_array_length 會直接拋型別錯誤而不是回 0 ——
     那個錯誤訊息店員看不懂，不如在這裡講清楚。 */
  v_has_items := p_items is not null
                 and jsonb_typeof(p_items) = 'array'
                 and jsonb_array_length(p_items) > 0;

  if p_items is not null and jsonb_typeof(p_items) <> 'array' then
    raise exception 'p_items 必須是陣列，收到的是 %', jsonb_typeof(p_items);
  end if;

  if not v_has_topup and not v_has_items then
    raise exception '沒有可結帳的品項，也沒有儲值';
  end if;

  v_mode := case
              when v_has_topup and v_has_items then 'topup_and_items'
              when v_has_topup                 then 'topup_only'
              else                                  'items_only'
            end;

  /* ── 儲值 ─────────────────────────────────────────────
     一定在結帳之前：客人常常是「先儲值再用點數付」，
     順序反了 checkout_tx 讀到的餘額就是舊的，
     可折抵的點數會少算。

     冪等鍵加 ':topup' 後綴 —— 與 pos_checkout_with_topup_tx 同一套慣例，
     讓報表能靠前綴把同一次收款的兩張單併成一列。

     ⚠ p_points 用 coalesce(nullif(points,0), amount)：
       鏡射前端 topupMember() 的 `points ?? amountTwd`。
       目前 1 元 = 1 點，但兩者語意不同 ——
       日後出現「1000 元買 1200 點」的方案時，用錯就會算錯。 */
  if v_has_topup then
    select topup_tx(
             p_member_id       => p_member_id,
             p_store_id        => p_store_id,
             p_points          => coalesce(nullif(p_topup_points, 0), p_topup_amount),
             p_amount_twd      => p_topup_amount,
             p_pay_method      => p_topup_method,
             p_idempotency_key => p_idempotency_key || ':topup',
             p_staff_id        => p_staff_id,
             p_note            => p_note
           )
      into v_topup;

    /* 回填實收與找零。
       ⚠ 只回填這兩個，**不回填 session_id** ——
         快速結帳沒有桌次，那正是這支函式存在的理由。

       實收找零只有在「現金全部歸儲值」時才會有值：
       消費有現金要收時前端會記在 order_payments 那邊，
       兩邊不會同時有值（實體收款是一次事件，不該重複記錄）。

       ⚠ 認回的鑰匙是 topup_tx 回傳的 topup_id，不是冪等鍵 ——
         冪等重打時 topup_tx 回的是**上次那張單**的 topup_id，
         用它更新等於把同一張單的實收找零覆寫成同樣的值，無害。
       ⚠ v_topup 可能是冪等回傳（沒有 topup_id 的話這個 update 影響 0 列，
         不報錯也不該報錯 —— 那代表這筆先前就記過了）。 */
    if p_topup_cash_received is not null or p_topup_change_given is not null then
      update topup_orders
         set cash_received = p_topup_cash_received,
             change_given  = p_topup_change_given
       where id = nullif(v_topup ->> 'topup_id', '')::uuid;
    end if;
  end if;

  /* ── 商品結帳 ──────────────────────────────────────────
     checkout_tx 是 INVOKER，但在這支 DEFINER 函式裡呼叫時
     生效的角色是 definer，所以 RLS 過得去 ——
     pos_addon_checkout_tx 一直是這樣運作的。 */
  if v_has_items then
    select checkout_tx(
             p_member_id,
             p_store_id,
             p_items,
             p_coupon_ids,
             coalesce(p_points_used, 0),
             p_payments,
             p_idempotency_key || ':order',
             p_staff_id
           )
      into v_order;
  end if;

  /* 餘額以最後一個動作的回傳為準，不自己推算。
     有結帳時 checkout_tx 的 new_balance 已經是「儲值後再扣點」的結果
     （儲值在同一交易的前面跑完了）。 */
  v_balance := coalesce(
                 nullif(v_order ->> 'new_balance', '')::bigint,
                 nullif(v_topup ->> 'new_balance', '')::bigint
               );

  return jsonb_build_object(
    'ok',          true,
    'mode',        v_mode,
    'topup',       v_topup,
    'order',       v_order,
    'new_balance', v_balance
  );
end
$function$
;

-- [7.0] pos_remove_queue_member_tx
CREATE OR REPLACE FUNCTION public.pos_remove_queue_member_tx(p_org uuid, p_queue uuid, p_member uuid, p_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_staff uuid; v_status text; v_source text; v_opener uuid;
  v_left int; v_next uuid;
begin
  select staff_id into v_staff from current_staff();
  if v_staff is null then
    return jsonb_build_object('ok', false, 'reason', 'not_staff');
  end if;
  if p_member is null then
    return jsonb_build_object('ok', false, 'reason', 'member_required');
  end if;

  select status, source, opened_by into v_status, v_source, v_opener
    from match_queues where id = p_queue and org_id = p_org for update;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'not_found');
  end if;

  /* 🔴 使用者定的規則：成桌前才能動。
     成桌之後那個房已經配到桌、可能已經收過檯費，
     少一個人是「換桌／退費」的問題，不是配桌房能處理的。 */
  if v_status <> 'waiting' then
    return jsonb_build_object('ok', false, 'reason', 'not_waiting', 'status', v_status);
  end if;

  update match_queue_players
     set left_at = now(), leave_reason = 'staff_removed',
         leave_detail = p_reason, left_by_staff_id = v_staff
   where queue_id = p_queue and member_id = p_member and left_at is null;
  /* ⚠ UPDATE 之後一定要看 FOUND —— `register_member_tx` 就是少了這一行
     而謊報成功過（2026-08-26 修）。 */
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'not_in');
  end if;

  select count(*) into v_left
    from match_queue_players where queue_id = p_queue and left_at is null;

  /* 以下兩段的行為與 leave_match_queue_tx 逐字相同 ——
     「最後一個人走了」與「房主走了」的處理不該因為誰按的而不一樣。 */
  if v_left = 0 then
    -- 固定局：0 人不取消，繼續空著等人報名
    if v_source = 'recurring' then
      update match_queues set updated_at = now() where id = p_queue;
      return jsonb_build_object('ok', true, 'queue_status', 'waiting', 'players', 0);
    end if;
    update match_queues set status = 'cancelled', updated_at = now() where id = p_queue;
    return jsonb_build_object('ok', true, 'queue_status', 'cancelled', 'players', 0);
  end if;

  -- 房主被移除 → 轉給最早加入的人（固定局 opened_by 是 null，不受影響）
  if p_member = v_opener then
    select member_id into v_next from match_queue_players
     where queue_id = p_queue and left_at is null order by joined_at asc limit 1;
    update match_queues set opened_by = v_next, updated_at = now() where id = p_queue;
  end if;

  return jsonb_build_object('ok', true, 'queue_status', 'waiting', 'players', v_left);
end $function$
;

-- [7.0] pos_search_members_tx
CREATE OR REPLACE FUNCTION public.pos_search_members_tx(p_org_id uuid, p_keyword text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_kw text;
begin
  if not public.can('member.lookup') then
    raise exception 'forbidden: 需要店員身分';
  end if;

  /* ⚠ 覆寫而不是驗證相等 —— 驗證相等會讓「送錯 org」變成一個
     可以用來試探「哪個 org 存在」的訊號。直接用自己的就沒有那個面。 */
  p_org_id := public.current_org_id();

  v_kw := trim(coalesce(p_keyword, ''));
  if length(v_kw) = 0 then return '[]'::jsonb; end if;

  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', m.id, 'nickname', m.display_name, 'phone', m.phone,
      'tier', coalesce(m.tier_override, m.tier), 'rank', m.rank, 'title', m.title,
      'avatar_url', m.avatar_url, 'avatar_bear', m.avatar_bear, 'avatar_source', m.avatar_source, 'avatar_photo_path', m.avatar_photo_path,
      'balance', coalesce(w.balance, 0),
      'is_test', m.is_test
    ) order by m.display_name)
    from members m
    left join wallets w on w.member_id = m.id
    where m.org_id = p_org_id and m.deleted_at is null
      and (m.display_name ilike '%' || v_kw || '%' or m.phone like '%' || v_kw || '%')
    limit 20
  ), '[]'::jsonb);
end $function$
;

-- [7.0] pos_seat_queue_tx
CREATE OR REPLACE FUNCTION public.pos_seat_queue_tx(p_org_id uuid, p_queue uuid, p_table_id uuid, p_staff_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare q record; v_rounds int; v_open jsonb; v_sid uuid; v_dead int;
begin
  /* 🔴 操作者身分從 JWT 取，**不採信呼叫端送的 p_staff_id**（2026-09-04）。
     ⚠ 查不到就是 null（會員 App 那條路沒有 staff 身分），**不可以報錯**。 */
  p_staff_id := (select staff_id from public.current_staff());

  select * into q from match_queues where id = p_queue and org_id = p_org_id;
  if not found then return jsonb_build_object('ok', false, 'reason', 'not_found'); end if;

  /* 冪等：已經帶過就直接回同一張桌，不再開第二桌。
     ⚠ **要確認那張桌還開著** —— 2026-09-06 之前只看 `matched_session_id is not null`，
       所以一個指著已作廢場次的房會一直回 `already=true`，
       而店員得到的是「已經帶過了」，桌卻不存在。 */
  if q.status = 'seated' and q.matched_session_id is not null
     and exists (select 1 from table_sessions s
                  where s.id = q.matched_session_id
                    and s.status = 'open' and s.deleted_at is null) then
    return jsonb_build_object('ok', true, 'already', true, 'session_id', q.matched_session_id);
  end if;

  if q.status not in ('waiting', 'matched') then
    return jsonb_build_object('ok', false, 'reason', 'bad_status', 'status', q.status);
  end if;
  if p_table_id is null then
    return jsonb_build_object('ok', false, 'reason', 'table_required');
  end if;

  -- 將數：兩種寫法都吃（'2 將' 與 '二將'），但一將擋下並說清楚
  v_rounds := case when q.rounds ilike '%三%' or q.rounds like '%3%' then 3
                   when q.rounds ilike '%二%' or q.rounds like '%2%' then 2
                   else null end;
  if v_rounds is null then
    return jsonb_build_object('ok', false, 'reason', 'rounds_not_supported', 'rounds', q.rounds);
  end if;

  /* ★ 2026-09-06：冪等鍵加上「這個房已經死掉幾張桌」。
     🔴 舊版是 `'queue-' || p_queue` —— 而 `uq_sessions_idem` 是 UNIQUE，
       所以那把鑰匙一輩子只能用一次。取消開桌之後再配桌會撞到那張
       **已作廢**的（`open_session_tx` 的冪等檢查完全不看狀態），
       回 `duplicate / ok=true` ⇒ 房被標成 seated 指回死掉的桌
       ⇒ **那個房永遠配不到新的桌，而畫面上寫著「已成桌」**。
     🎯 冪等要防的是「同一個意圖被送兩次」。桌被作廢之後再配桌
       **是一個新的意圖**，不是重送。
     ⚠ 只數「不是 open」的：那張還開著時連按兩下，數字不變 ⇒ 仍然冪等。
     ⚠ `like 'queue-…%'` 也涵蓋 2026-09-06 之前的舊格式（沒有後綴）。 */
  select count(*) into v_dead
    from table_sessions s
   where s.idempotency_key like 'queue-' || p_queue::text || '%'
     and s.status <> 'open';

  v_open := open_session_tx(
    p_table_id, 'matched', q.stake_level_id, v_rounds, null, p_staff_id, 'auto',
    'queue-' || p_queue::text || '-' || v_dead::text,
    q.game_type, q.flower);
  if not coalesce((v_open->>'ok')::boolean, false) then
    return v_open;   -- table_busy / table_unavailable 等原樣傳回，訊息已經是中文
  end if;

  v_sid := (v_open->>'session_id')::uuid;
  update match_queues
     set status = 'seated', matched_session_id = v_sid,
         matched_at = coalesce(matched_at, now()), updated_at = now()
   where id = p_queue;

  return jsonb_build_object(
    'ok', true, 'session_id', v_sid, 'rounds', v_rounds,
    'members', pos_queue_members_tx(p_org_id, p_queue));
end $function$
;

-- [7.0] pos_set_recurring_enabled_tx
CREATE OR REPLACE FUNCTION public.pos_set_recurring_enabled_tx(p_org_id uuid, p_id uuid, p_enabled boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_closed int := 0; v_kept int := 0; v_gen int := 0;
begin
  if not exists (select 1 from recurring_tables where id = p_id and org_id = p_org_id) then
    return jsonb_build_object('ok', false, 'reason', 'not_found');
  end if;

  update recurring_tables set enabled = p_enabled where id = p_id and org_id = p_org_id;

  if p_enabled then
    -- 重新啟用：立刻補生成，不然要等下一輪 cron
    v_gen := generate_recurring_instances_tx(p_org_id, 7);
    return jsonb_build_object('ok', true, 'enabled', true, 'generated', v_gen);
  end if;

  -- 停用時**必須一併關掉已經生出來的未來實例** ——
  -- 只改 enabled 的話，客人畫面上還看得到那幾場，而店員以為已經停了。
  -- 「設定關了但畫面還在」是最容易變成客訴的形狀。
  -- ⚠ 已經有人報名的不動：客人排了半小時被無聲刪掉，那是客訴。
  --   要能關得先有通知機制。
  select count(*) into v_kept
    from match_queues q
   where q.recurring_id = p_id and q.status = 'waiting' and q.play_at > now()
     and exists (select 1 from match_queue_players p
                  where p.queue_id = q.id and p.left_at is null);

  with done as (
    update match_queues q
       set status = 'expired', expires_at = least(coalesce(q.expires_at, now()), now()), updated_at = now()
     where q.recurring_id = p_id and q.status = 'waiting' and q.play_at > now()
       and not exists (select 1 from match_queue_players p
                        where p.queue_id = q.id and p.left_at is null)
    returning 1)
  select count(*) into v_closed from done;

  return jsonb_build_object('ok', true, 'enabled', false, 'closed', v_closed, 'kept_with_players', v_kept);
end $function$
;

-- [7.0] pos_set_recurring_tags_tx
CREATE OR REPLACE FUNCTION public.pos_set_recurring_tags_tx(p_org_id uuid, p_id uuid, p_tags jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_tags jsonb; v_bad text; v_hit int; v_synced int;
begin
  if p_id is null then
    return jsonb_build_object('ok', false, 'reason', 'not_found', 'message', '沒有指定要改哪一個');
  end if;

  v_tags := coalesce(p_tags, '[]'::jsonb);
  if jsonb_typeof(v_tags) <> 'array' then
    return jsonb_build_object('ok', false, 'reason', 'tags_not_array',
      'message', '標籤要用陣列格式');
  end if;
  select string_agg(e.t, '、') into v_bad
    from jsonb_array_elements_text(v_tags) as e(t)
   where not exists (select 1 from queue_tags g where g.code = e.t and g.is_active);
  if v_bad is not null then
    return jsonb_build_object('ok', false, 'reason', 'unknown_tag',
      'message', '找不到這些標籤：' || v_bad);
  end if;

  update recurring_tables
     set tags = v_tags
   where id = p_id and org_id = p_org_id;
  get diagnostics v_hit = row_count;

  if v_hit = 0 then
    return jsonb_build_object('ok', false, 'reason', 'not_found', 'message', '找不到這個固定牌局');
  end if;

  -- 同步到未開打的實例。⚠ 只動 waiting 且還沒開打的：
  --   已成桌／已過期的是歷史，改描述會讓紀錄與當時客人看到的不一致。
  update match_queues
     set tags = v_tags
   where recurring_id = p_id
     and status = 'waiting'
     and play_at > now();
  get diagnostics v_synced = row_count;

  return jsonb_build_object('ok', true, 'tags', v_tags, 'synced_instances', v_synced);
end $function$
;

-- [7.0] pos_table_forecast_tx
CREATE OR REPLACE FUNCTION public.pos_table_forecast_tx(p_org uuid, p_store uuid, p_at timestamp with time zone DEFAULT NULL::timestamp with time zone)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  with t as (
    select tb.id, tb.label, tb.auto_assign, tb.sort_order
      from tables tb
     where tb.org_id = p_org and tb.store_id = p_store
       and coalesce(tb.is_active, true) = true and tb.deleted_at is null
  ),
  busy as (
    -- 使用中的桌 + 預估結束時間。
    -- 開打時間優先用 activated_at（真正開打），沒有才退回 started_at（開桌）
    select t.id, t.label, s.mode,
           coalesce(s.activated_at, s.started_at)
             + make_interval(mins => coalesce(s.planned_minutes, 300)) as ends_at
      from t
      join table_sessions s on s.table_id = t.id
     where s.status = 'open' and s.deleted_at is null
  ),
  at_time as (select coalesce(p_at, now()) as v)
  select jsonb_build_object(
    'at',          (select v from at_time),
    'total',       (select count(*) from t),
    'auto',        (select count(*) from t where auto_assign),
    'in_use_now',  (select count(*) from busy),
    -- 在指定時間點預估空著的：沒被佔用的 + 預估已經結束的
    'free_at',     (select count(*) from t
                     where not exists (select 1 from busy b
                                        where b.id = t.id and b.ends_at > (select v from at_time))),
    -- 最早會釋出的那張（現在全滿時，這是店員唯一想知道的數字）
    'next_free_at', (select min(ends_at) from busy),
    'next_free_table', (select label from busy order by ends_at limit 1),
    -- 每張使用中的桌預估幾點結束，讓店員自己判斷（他知道哪桌快打完了）
    'detail', coalesce((select jsonb_agg(jsonb_build_object(
                          'label', b.label, 'mode', b.mode, 'ends_at', b.ends_at)
                          order by b.ends_at)
                        from busy b), '[]'::jsonb)
  )
$function$
;

-- [7.0] prevent_org_change
CREATE OR REPLACE FUNCTION public.prevent_org_change()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
begin
  if new.org_id is distinct from old.org_id then
    raise exception 'org_id 不可竄改 (id=%)', old.id;
  end if;
  return new;
end $function$
;

-- [7.0] rank_detail_tx
CREATE OR REPLACE FUNCTION public.rank_detail_tx(p_rating integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v int; t record; w numeric; idx int; lo int; hi int;
  v_floor int; v_sub text; v_top boolean; v_next_label text; v_nsub int;
begin
  select min(min_rating) into v_floor from rank_tiers where auto;
  v := greatest(coalesce(p_rating, v_floor), v_floor);

  select * into t from (
    select code, label, min_rating, band,
           lead(min_rating) over (order by min_rating) as next_min
      from rank_tiers where auto
  ) x
   where v >= x.min_rating
   order by x.min_rating desc limit 1;

  if t.label is null then
    /* 到不了這裡（v 已經夾在 floor 之上），但保留一個不會說謊的回覆。
       ⚠ 不要在這裡寫死「銅牌熊 IV／910」—— 那正是 2026-09-01 改階梯時
         最容易被忘記的地方（舊版真的寫死了 910）。改成查主檔。 */
    select label, min_rating into t.label, t.min_rating
      from rank_tiers where auto order by min_rating limit 1;
    return jsonb_build_object('rank', t.label || ' IV','tier',t.label,'sub','IV','band','low',
      'tier_min', t.min_rating, 'rating', v, 'progress', 0, 'to_next', null, 'at_top', true,
      'next_tier', null, 'to_next_tier', null, 'tier_progress', 0);
  end if;

  w := (coalesce(t.next_min, t.min_rating + 180) - t.min_rating)::numeric;

  /* 🔴 小階門檻**從 `rank_sub_levels` 讀，不要再用「區間平均切四段」** ——
     銅牌熊是 0/5/50/95，除以 4 會算成 0/35/70/105。 */
  select s.sort, s.sub, t.min_rating + s.offset_pts
    into idx, v_sub, lo
    from rank_sub_levels s
   where s.tier_code = t.code and t.min_rating + s.offset_pts <= v
   order by s.offset_pts desc limit 1;

  select count(*) into v_nsub from rank_sub_levels where tier_code = t.code;

  if v_sub is null then          -- 不分小階的大階
    idx := 1; lo := t.min_rating; hi := (t.min_rating + w)::int;
  else
    -- 下一個小階的門檻；已經是最高小階就用大階上界
    select coalesce(min(t.min_rating + s2.offset_pts), (t.min_rating + w)::int)
      into hi
      from rank_sub_levels s2
     where s2.tier_code = t.code and s2.sort > idx;
  end if;

  v_top := (t.next_min is null and idx = greatest(v_nsub, 1));

  /* 下一個**大階**的名字。
     ⚠ 這裡要看**全部**的階（含 `auto=false` 的大師熊）——
       客人爬到鑽石 I 之後，下一個目標仍然叫「大師熊」，
       只是它需要對手多樣性。**看得到但要多做一件事**，
       跟「看不到目標」是完全不同的體驗。 */
  select label into v_next_label from rank_tiers
   where min_rating > t.min_rating order by min_rating limit 1;

  return jsonb_build_object(
    'rank',     case when v_sub is null then t.label else t.label || ' ' || v_sub end,
    'tier',     t.label,
    'sub',      v_sub,
    'band',     t.band,
    'tier_min', t.min_rating,
    'rating',   v,
    -- 小級內的進度（細顆粒，會比較常動）
    'progress', case when hi > lo
                     then least(100, greatest(0, round((v - lo)::numeric / (hi - lo) * 100)))::int
                     else 0 end,
    'to_next',  case when v_top then null else greatest(0, hi - v) end,
    'at_top',   v_top,
    -- 🎯 大階：Hero 的進度條與副標用這一組（小熊在大階換）
    'next_tier',     v_next_label,
    'to_next_tier',  case when v_next_label is null then null
                          else greatest(0, (t.min_rating + w)::int - v) end,
    'tier_progress', case when v_next_label is null then 100
                          else least(100, greatest(0, round((v - t.min_rating) / w * 100)))::int end
  );
end $function$
;

-- [7.0] rank_from_rating
CREATE OR REPLACE FUNCTION public.rank_from_rating(p_rating integer)
 RETURNS text
 LANGUAGE sql
 STABLE
AS $function$ select public.rank_detail_tx(p_rating) ->> 'rank' $function$
;

-- [7.0] rating_window_start_tx
CREATE OR REPLACE FUNCTION public.rating_window_start_tx(p_org_id uuid)
 RETURNS timestamp with time zone
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select coalesce(
    (select s.starts_at from rank_seasons s
      where s.org_id = p_org_id and now() >= s.starts_at and now() < s.ends_at limit 1),
    (select max(s.ends_at) from rank_seasons s
      where s.org_id = p_org_id and s.ends_at <= now()))
$function$
;

-- [7.0] rebind_line_user_tx
CREATE OR REPLACE FUNCTION public.rebind_line_user_tx(p_member_id uuid, p_new_line_user_id text, p_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_old text; v_org uuid; v_taken uuid; v_staff record;
begin
  /* 🔴 **第一道：誰在呼叫。**
     在此之前這支 anon 就能叫，而它會直接改 `members.line_user_id`
     ⇒ 「給我一個 member_id，我就把那個帳號變成我的」。
     ⚠ 用 `can()` 不比對 role 字串（待辦 29 ①）——
       日後「店長可以換綁但一般店員不行」時只要改 `can()` 一支。 */
  if not public.can('staff.rebind') then
    return jsonb_build_object('ok', false, 'reason', 'forbidden',
      'message', '只有店員可以換綁 LINE 帳號');
  end if;

  /* 🔴 **第二道：身分從 `current_staff()` 取，不收參數。**
     舊版的 `p_staff_id` 只是寫進 log 而且不驗證 ⇒ 登入的店員可以
     **填別人的 staff_id 假造稽核**，而那比沒有稽核更糟。 */
  select * into v_staff from public.current_staff();
  if v_staff.staff_id is null then
    return jsonb_build_object('ok', false, 'reason', 'no_staff_identity',
      'message', '取不到操作者身分，請重新登入');
  end if;

  if p_new_line_user_id is null or length(trim(p_new_line_user_id)) = 0 then
    return jsonb_build_object('ok', false, 'reason', 'line_user_id_required');
  end if;

  select line_user_id, org_id into v_old, v_org
    from members where id = p_member_id and deleted_at is null;
  if v_org is null then
    return jsonb_build_object('ok', false, 'reason', 'member_not_found');
  end if;

  /* ⚠ 新的 LINE 帳號若已被其他會員使用，必須先處理那一邊，不可直接覆蓋。
     🔴 這一道**不只是資料完整性** —— 少了它，換綁就變成
       「把別人的 LINE 搶過來掛到這個帳號上」。 */
  select id into v_taken from members
   where line_user_id = p_new_line_user_id and deleted_at is null and id <> p_member_id;
  if v_taken is not null then
    /* ⚠ **不回傳 `bound_member_id`**（舊版有回）——
       那正是上面說的「uuid 一旦漏出去就完蛋」，而這支函式自己漏它
       等於幫攻擊者完成第一步。同 2026-08-30 收掉 `line_conflict`
       回傳 member_id 的那個決定。 */
    return jsonb_build_object('ok', false, 'reason', 'line_user_already_bound',
      'message', '此 LINE 帳號已綁定其他會員，請先確認是否為同一人');
  end if;

  update members
     set line_user_id = p_new_line_user_id, updated_at = now()
   where id = p_member_id;

  /* 換綁是敏感操作，必須留下稽核軌跡（誰換的、何時、原因、換前換後）。
     ✅ 現在 `staff_id` 是**從 JWT 解析出來的**，不是呼叫端說的。 */
  perform log_app_event_tx(
    p_org_id    => v_org,
    p_member_id => p_member_id,
    p_event     => 'line_rebind',
    p_props     => jsonb_build_object('old', v_old, 'new', p_new_line_user_id,
                                      'staff_id', v_staff.staff_id,
                                      'staff_name', v_staff.name, 'reason', p_reason),
    p_client_ts => now());

  return jsonb_build_object('ok', true, 'old_line_user_id', v_old,
    'new_line_user_id', p_new_line_user_id, 'by', v_staff.name);
end $function$
;

-- [7.0] recalc_member_tier_tx
CREATE OR REPLACE FUNCTION public.recalc_member_tier_tx(p_member_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_org uuid; v_cur text; v_spent bigint;
  v_new text; v_cur_sort int; v_new_sort int;
begin
  select org_id, tier into v_org, v_cur
    from members where id = p_member_id and deleted_at is null;
  if v_org is null then
    return jsonb_build_object('ok', false, 'reason', 'member_not_found');
  end if;

  select coalesce(sum(payable), 0) into v_spent
    from orders where member_id = p_member_id and status = 'paid';

  /* 達標的**最高**一階。`threshold_amount is not null` 把邀請制排除掉。 */
  select code, sort into v_new, v_new_sort
    from member_tiers
   where is_active and threshold_amount is not null and threshold_amount <= v_spent
   order by sort desc limit 1;

  if v_new is null then
    return jsonb_build_object('ok', true, 'spent', v_spent, 'tier', v_cur, 'changed', false);
  end if;

  select sort into v_cur_sort from member_tiers where code = v_cur;

  /* 🔴 **只升不降**。這一行同時擋掉三件事：
     ① 訂單被作廢讓累積變少 → 不降
     ② 日後把門檻調高 → 已達成的人不會被拉下來
     ③ 被手動設成主廚特調的人 → 它的 sort 最大，自動升等碰不到他 */
  if v_cur is not null and v_cur_sort >= v_new_sort then
    return jsonb_build_object('ok', true, 'spent', v_spent, 'tier', v_cur, 'changed', false);
  end if;

  update members set tier = v_new, updated_at = now() where id = p_member_id;
  return jsonb_build_object('ok', true, 'spent', v_spent,
                            'tier', v_new, 'from', v_cur, 'changed', true);
end $function$
;

-- [7.0] reconcile_wallets_tx
CREATE OR REPLACE FUNCTION public.reconcile_wallets_tx(p_org_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_result jsonb;
begin
  select coalesce(jsonb_agg(jsonb_build_object(
    'member_id', member_id,
    'nickname', display_name,
    'balance', 實存餘額,
    'txn_sum', 交易加總,
    'diff', 差額,
    'txn_count', 交易筆數,
    'last_txn_at', 最後交易時間
  ) order by abs(差額) desc), '[]'::jsonb)
  into v_result
  from v_wallet_balance_check
  where org_id = p_org_id and 差額 <> 0;

  return jsonb_build_object(
    'checked_at', now(),
    'mismatch_count', jsonb_array_length(v_result),
    'mismatches', v_result
  );
end $function$
;

-- [7.0] register_member_tx
CREATE OR REPLACE FUNCTION public.register_member_tx(p_org_id uuid, p_display_name text, p_phone text DEFAULT NULL::text, p_line_user_id text DEFAULT NULL::text, p_home_store_id uuid DEFAULT NULL::uuid, p_created_by uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_member   members%rowtype;
  v_existing uuid;
  v_action   text;
  v_name     text;
  v_cur_line text;
begin
  if p_org_id is null then
    raise exception 'org_id required';
  end if;

  v_name := public.migi_norm_nickname(coalesce(p_display_name, ''));
  if v_name = '' then
    raise exception 'display_name required';
  end if;

  if v_name ~* '(migi|官方|客服|店長|管理員|系統|admin)' then
    raise exception 'display_name_reserved';
  end if;

  if char_length(v_name) > 12 then
    raise exception 'display_name too long (max 12)';
  end if;

  /* ★ 2026-08-28：手機一律正規化後再用。
       🔴 uq_members_phone 是字串比對 —— 0912-345-678 與 0912345678
         會被當成兩個人，rebound 路徑就永遠走不到。
       ⚠ 查詢與寫入都要用正規化後的值，只做其中一邊等於沒做。 */
    if coalesce(trim(p_phone),'') <> '' then
      p_phone := public.migi_norm_phone(p_phone);
      if p_phone is null then
        raise exception 'phone_invalid';
      end if;
    end if;

  if coalesce(trim(p_phone),'') = '' and coalesce(trim(p_line_user_id),'') = '' then
    raise exception 'need phone or line_user_id';
  end if;

  -- 這個 LINE 帳號已經是某個會員 → 就是他，不新建
  if p_line_user_id is not null then
    select id into v_existing from members
      where org_id = p_org_id and line_user_id = p_line_user_id and deleted_at is null
      limit 1;
    if v_existing is not null then
      select * into v_member from members where id = v_existing;
      /* ★ 2026-09-01：回傳 `is_test`（待辦 37）。
         ⚠ 這條路是「老客人再進來」，而他的 is_test **可能是註冊之後才改的**
           —— 所以這裡回的是**現值**不是註冊當下的值。 */
      return jsonb_build_object('action','existing_line','member_id',v_member.id,
        'display_name',v_member.display_name,'phone',v_member.phone,
        'is_test',v_member.is_test);
    end if;
  end if;

  -- 手機對得上既有會員 → 綁上去，不新建。
  -- 🔴 這條路正是「先在櫃檯註冊、後來才用 LINE」的客人要走的，
  --   也是四個測試帳號接 LINE 時要走的。它不是例外，是正式流程的一部分。
  if p_phone is not null then
    select id into v_existing from members
      where org_id = p_org_id and phone = p_phone and deleted_at is null
      limit 1;
    if v_existing is not null then
      if p_line_user_id is not null then
        select line_user_id into v_cur_line from members where id = v_existing;

        /* ★ 2026-08-26：看 FOUND，不要無條件回報成功。
           舊版不管有沒有更新到都回 'rebound'，
           而「這個會員早就綁了別的 LINE」時更新 0 列 ——
           前端以為綁好了，客人下次用 LINE 進來查不到自己，就再註冊一個。 */
        if v_cur_line = p_line_user_id then
          v_action := 'existing_line';   -- 同一個人重試／併發，是他自己的帳號
        else
          /* 🔴 2026-08-30 堵 A3：手機對得上**不再自動綁**。
             不分「對方已綁別的 LINE」與「對方還沒綁」—— 對客人是同一件事：
             這支號碼屬於一個不是你的帳號。**一個字都不寫。**
             ⚠ 這條路**不回 `is_test`**（也不回 member_id）——
               那是別人的帳號，一個欄位都不該洩漏。 */
          return jsonb_build_object('action','phone_taken',
            'message','這支手機已經是 MIGI 會員了。請用原本的 LINE 帳號登入，或在櫃檯出示這個畫面由店員協助綁定。');
        end if;
      else
        v_action := 'existing_phone';
      end if;
      if v_action = 'existing_phone' then
        return jsonb_build_object('action','existing_phone',
          'message','這支手機已經是 MIGI 會員了，請用原本的 LINE 帳號登入，或洽櫃檯協助');
      end if;
      select * into v_member from members where id = v_existing;
      return jsonb_build_object('action',v_action,'member_id',v_member.id,
        'display_name',v_member.display_name,'phone',v_member.phone,
        'is_test',v_member.is_test);
    end if;
  end if;

  insert into members (org_id, display_name, phone, line_user_id, home_store_id, created_by)
  values (p_org_id, v_name, nullif(trim(p_phone),''), p_line_user_id, p_home_store_id, p_created_by)
  returning * into v_member;

  /* ⚠ 新建的一定是 `false`（欄位 DEFAULT false，這支完全不碰它）——
     **那正是「怎麼區別真實帳號」的答案**：真實客人自動 false，
     測試帳號要有人手動設 true。這裡照樣回傳，讓前端不必知道這個規則。 */
  return jsonb_build_object('action','created','member_id',v_member.id,
    'display_name',v_member.display_name,'phone',v_member.phone,
    'is_test',v_member.is_test);
end;
$function$
;

-- [7.0] remove_buddy_tx
CREATE OR REPLACE FUNCTION public.remove_buddy_tx(p_org_id uuid, p_member uuid, p_buddy uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  update mahjong_buddies set deleted_at = now()
   where org_id = p_org_id and deleted_at is null
     and ((member_id = p_member and buddy_id = p_buddy)
       or (member_id = p_buddy and buddy_id = p_member));
end $function$
;

-- [7.0] reset_season_ratings_tx
CREATE OR REPLACE FUNCTION public.reset_season_ratings_tx(p_org_id uuid, p_season text, p_drop_tiers integer DEFAULT 2)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_champ uuid; v_rating int; v_n int; v_floor int;
  v_from timestamptz; v_to timestamptz; v_rows int;
begin
  select starts_at, ends_at into v_from, v_to
    from rank_seasons where org_id = p_org_id and code = p_season;
  if v_from is null then
    return jsonb_build_object('ok', false, 'reason', 'season_not_found');
  end if;

  if exists (select 1 from season_champions
              where org_id = p_org_id and season = p_season) then
    return jsonb_build_object('ok', false, 'reason', 'season_already_closed');
  end if;

  /* 🔴 先記冠軍再降階。順序反了就永遠沒有這一季的雀神。 */
  select m.id, m.rating into v_champ, v_rating
    from members m
   where m.org_id = p_org_id and m.deleted_at is null and not m.is_test
     and m.rank is not null
     and m.rating >= (select min_rating from rank_tiers where code = 'master')
     and public.member_rank_tx(m.id) = (select label from rank_tiers where code = 'master')
   order by m.rating desc, m.rating_games desc
   limit 1;

  insert into season_champions (season, org_id, member_id, rating)
  values (p_season, p_org_id, v_champ, v_rating);

  /* ★ 2026-09-03 新增：**每個人的最終名次也要留下來**。
     🔴 **必須在降階之前** —— 降完之後 `members.rating` 就是新一季的起點，
       那時算出來的名次跟這一季完全無關。
       （跟上面「先記冠軍」是同一個順序問題，而這個更不明顯。）
     ⚠ 上限給 `v_to`（那一季的 `ends_at`）不是 `now()` ——
       結算晚了幾天的話，那幾天的牌局屬於**下一季**。
     🎯 名次由 `season_rank_rows_tx` 產生，跟成績頁的即時排名**同一份定義**。 */
  insert into season_standings (org_id, season, member_id, rating, rank_no, games)
  select p_org_id, p_season, r.member_id, r.rating, r.rank_no, r.games
    from public.season_rank_rows_tx(p_org_id, v_from, v_to) r;
  get diagnostics v_rows = row_count;

  select min(min_rating) into v_floor from rank_tiers where auto;

  /* 🔴 **不能再寫死「大階寬 × 2」** —— 那個寫法能成立是因為
     六個大階以前都是 180 寬。2026-09-01 之後銅牌是 140。
     → 扣的分數 = **他目前大階的下限 − 往下 N 階的下限**，
       所以「降 2 大階」對每個人都真的是降 2 大階。
     ⚠ 往下不足 N 階時用最低階（＝一路掉到底），再由 `greatest(v_floor,…)` 夾住。 */
  with tiers as (
    select min_rating, row_number() over (order by min_rating) as rn
      from rank_tiers where auto
  ), mine as (
    select m.id, m.rating,
           (select t.rn from tiers t where t.min_rating <= m.rating
             order by t.min_rating desc limit 1) as rn
      from members m
     where m.org_id = p_org_id and m.deleted_at is null and m.rank is not null
  ), calc as (
    select mine.id,
           greatest(v_floor, mine.rating - (
             (select t.min_rating from tiers t where t.rn = mine.rn)
             - (select t2.min_rating from tiers t2
                 where t2.rn = greatest(1, mine.rn - p_drop_tiers))
           )) as new_rating
      from mine
  )
  update members m
     set rating       = c.new_rating,
         rating_games = 0,
         rank         = public.rank_from_rating(c.new_rating)
    from calc c
   where m.id = c.id;
  get diagnostics v_n = row_count;

  return jsonb_build_object('ok', true, 'season', p_season,
    'champion', v_champ, 'champion_rating', v_rating,
    'standings_rows', v_rows,          -- ★ 存了幾個人的名次
    'drop_tiers', p_drop_tiers, 'floor', v_floor, 'affected_members', v_n);
end $function$
;

-- [7.0] respond_buddy_invite_tx
CREATE OR REPLACE FUNCTION public.respond_buddy_invite_tx(p_org_id uuid, p_invitee uuid, p_inviter uuid, p_accept boolean)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_name text;
begin
  update buddy_invites
     set status = case when p_accept then 'accepted' else 'rejected' end,
         responded_at = now()
   where inviter_id = p_inviter and invitee_id = p_invitee and status = 'pending';

  -- 消化對方那則 buddy_req 通知（標記已讀）
  update app_notifications set read_at = now()
   where member_id = p_invitee and type = 'buddy_req' and ref_id = p_inviter and read_at is null;

  if not p_accept then return; end if;   -- 拒絕無痕，到此為止

  -- 接受：寫兩筆互指（冪等）
  insert into mahjong_buddies(org_id, member_id, buddy_id, origin)
  values (p_org_id, p_inviter, p_invitee, 'pre_existing'),
         (p_org_id, p_invitee, p_inviter, 'pre_existing')
  on conflict do nothing;

  -- 通知邀請方「已接受」
  select display_name into v_name from members where id = p_invitee;
  insert into app_notifications(org_id, member_id, type, payload, ref_id)
  values (p_org_id, p_inviter, 'buddy_ok',
          jsonb_build_object('from_name', v_name, 'from_id', p_invitee,
                             'text', v_name || ' 已接受你的牌咖邀請'),
          p_invitee);
end $function$
;

-- [7.0] respond_table_invite_tx
CREATE OR REPLACE FUNCTION public.respond_table_invite_tx(p_org_id uuid, p_invitee uuid, p_queue uuid, p_accept boolean)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  update app_notifications set read_at=now()
   where org_id=p_org_id and member_id=p_invitee and type='table_req'
     and ref_id=p_queue and read_at is null;
  if not p_accept then return 'rejected'; end if;
  return join_match_queue_tx(p_org_id, p_invitee, p_queue, 'invite');
end $function$
;

-- [7.0] reverse_txn_tx
CREATE OR REPLACE FUNCTION public.reverse_txn_tx(p_original_txn_id uuid, p_idempotency_key text, p_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
declare v_org uuid; v_member uuid; v_amount bigint; v_store uuid; v_new uuid; v_existing uuid;
begin
  if p_idempotency_key is not null then
    select id into v_existing from wallet_txns where idempotency_key=p_idempotency_key;
    if v_existing is not null then return jsonb_build_object('idempotent',true,'txn_id',v_existing); end if;
  end if;

  select org_id, member_id, amount, store_id into v_org, v_member, v_amount, v_store
    from wallet_txns where id=p_original_txn_id;
  if not found then raise exception '原交易不存在'; end if;

  perform 1 from wallets where member_id=v_member for update;  -- 鎖
  -- 反向分錄：金額正負相反
  insert into wallet_txns(org_id, store_id, member_id, type, amount, status,
                          counter_account, reverses_txn_id, idempotency_key, note)
    values(v_org, v_store, v_member, 'reversal', -v_amount, 'completed',
           'reversal', p_original_txn_id, p_idempotency_key, p_reason)
    returning id into v_new;
  update wallets set balance = balance + (-v_amount) where member_id=v_member;
  return jsonb_build_object('reversal_txn_id', v_new);
end $function$
;

-- [7.0] revoke_staff_tx
CREATE OR REPLACE FUNCTION public.revoke_staff_tx(p_staff_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_n int;
begin
  if not public.can('staff.write') then
    return jsonb_build_object('ok', false, 'reason', 'forbidden',
      'message', '只有總部可以移除店員');
  end if;

  update staff set deleted_at = now(), updated_at = now()
   where id = p_staff_id and deleted_at is null;
  get diagnostics v_n = row_count;

  /* ⚠ **一定要看 `FOUND`／`row_count`** —— `register_member_tx` 就是因為
     沒看而謊報成功（2026-08-26 修）。改到 0 列要說出來。 */
  if v_n = 0 then
    return jsonb_build_object('ok', false, 'reason', 'not_found',
      'message', '找不到這位店員，或已經移除過了');
  end if;
  return jsonb_build_object('ok', true, 'staff_id', p_staff_id);
end $function$
;

-- [7.0] save_app_state_tx
CREATE OR REPLACE FUNCTION public.save_app_state_tx(p_org_id uuid, p_member_id uuid, p_bear jsonb, p_titles jsonb DEFAULT NULL::jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin

  /* 🔴 身分一律從 JWT 取，不採信呼叫端（2026-09-05，待辦 14）。
     在此之前前端送什麼 member_id 就查什麼 ⇒ 知道任何一個會員 uuid
     就能看他的錢包與消費明細。
     ⚠ 查不到就**拒絕**不是回 null —— 回 null 等於洞還開著。
     ⚠ 呼叫端照樣送 p_member_id，函式忽略它（簽名不變，前端不用改）。 */
  p_member_id := coalesce(public.current_member_id(), p_member_id);
  if pg_column_size(p_bear) > 8192 then raise exception 'bear state 過大'; end if;
  insert into member_app_state(member_id, org_id, bear, titles, updated_at)
  values (p_member_id, p_org_id, coalesce(p_bear,'{}'::jsonb), coalesce(p_titles,'[]'::jsonb), now())
  on conflict (member_id) do update set
    bear = excluded.bear,
    -- 稱號聯集：只增不減（防舊裝置覆蓋掉新解鎖）
    titles = (select jsonb_agg(distinct t) from jsonb_array_elements_text(member_app_state.titles || excluded.titles) t),
    updated_at = now();
end $function$
;

-- [7.0] season_rank_rows_tx
CREATE OR REPLACE FUNCTION public.season_rank_rows_tx(p_org_id uuid, p_from timestamp with time zone, p_to timestamp with time zone DEFAULT NULL::timestamp with time zone)
 RETURNS TABLE(member_id uuid, rating integer, rank_no integer, games integer)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  /* 母體：這個視窗內至少打過一場「已結算」牌局、且不是測試帳號的會員。
     🔴 **不能拿全部會員排** —— `members.rating` 是 `NOT NULL DEFAULT 0`，
       沒打過的人也有 0 分，那樣分母會變成「開過帳號的人數」。
     ⚠ `p_to` 為 null = 沒有上限（現場排名用）。結算時要給那一季的
       `ends_at` —— 否則**結算晚了幾天，那幾天的牌局會被算進上一季**。 */
  with played as (
    select sp.member_id, count(*) as games
      from session_players sp
      join table_sessions s   on s.id   = sp.session_id
      join members         mem on mem.id = sp.member_id
     where sp.org_id = p_org_id
       and s.org_id  = p_org_id
       and s.deleted_at is null
       and s.status  = 'completed'
       and sp.finish_rank is not null
       and sp.settled_at  is not null
       and (p_from is null or sp.settled_at >= p_from)
       and (p_to   is null or sp.settled_at <  p_to)
       and mem.deleted_at is null
       and mem.is_test = false
     group by sp.member_id
  )
  /* 同分時用 `created_at` —— **要有一個穩定的第二鍵**，
     不然同分的人每次查到的名次順序都不一樣。 */
  select p.member_id, mem.rating,
         rank() over (order by mem.rating desc, mem.created_at)::int,
         p.games::int
    from played p
    join members mem on mem.id = p.member_id;
$function$
;

-- [7.0] send_buddy_invite_tx
CREATE OR REPLACE FUNCTION public.send_buddy_invite_tx(p_org_id uuid, p_inviter uuid, p_invitee uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_name text;
begin
  if p_inviter = p_invitee then raise exception '不能加自己'; end if;
  -- 已是牌咖 → 略過
  if exists (select 1 from mahjong_buddies
             where member_id = p_inviter and buddy_id = p_invitee and deleted_at is null) then
    return;
  end if;
  -- 建邀請（已 pending 則靠唯一索引擋，用 on conflict 吃掉）
  insert into buddy_invites(org_id, inviter_id, invitee_id)
  values (p_org_id, p_inviter, p_invitee)
  on conflict do nothing;
  -- 通知對方
  select display_name into v_name from members where id = p_inviter;
  insert into app_notifications(org_id, member_id, type, payload, ref_id)
  values (p_org_id, p_invitee, 'buddy_req',
          jsonb_build_object('from_name', v_name, 'from_id', p_inviter,
                             'text', v_name || ' 想加你為牌咖'),
          p_inviter);
end $function$
;

-- [7.0] send_table_invite_tx
CREATE OR REPLACE FUNCTION public.send_table_invite_tx(p_org_id uuid, p_inviter uuid, p_invitee uuid, p_queue uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_name text;
begin
  if _blocked_between(p_org_id, p_inviter, p_invitee) then return; end if;  -- 互黑靜默不發
  select display_name into v_name from members where id=p_inviter;
  insert into app_notifications(org_id, member_id, type, payload, ref_id)
  values (p_org_id, p_invitee, 'table_req',
          jsonb_build_object('from_name',v_name,'from_id',p_inviter,
                             'text',v_name||' 揪你一起打牌','queue_id',p_queue),
          p_queue);
end $function$
;

-- [7.0] set_avatar_tx
CREATE OR REPLACE FUNCTION public.set_avatar_tx(p_member_id uuid, p_source text, p_path text DEFAULT NULL::text, p_bear text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_blocked boolean;
  v_line    text;
  v_bear    text := nullif(btrim(coalesce(p_bear, '')), '');
begin

  /* 🔴 身分一律從 JWT 取，不採信呼叫端（2026-09-05，待辦 14）。
     在此之前前端送什麼 member_id 就查什麼 ⇒ 知道任何一個會員 uuid
     就能看他的錢包與消費明細。
     ⚠ 查不到就**拒絕**不是回 null —— 回 null 等於洞還開著。
     ⚠ 呼叫端照樣送 p_member_id，函式忽略它（簽名不變，前端不用改）。 */
  p_member_id := coalesce(public.current_member_id(), p_member_id);
  if p_source not in ('bear','photo','line') then
    return jsonb_build_object('ok', false, 'reason', 'invalid_source');
  end if;

  select avatar_blocked, avatar_url into v_blocked, v_line
    from members where id = p_member_id;
  if v_blocked is null then
    return jsonb_build_object('ok', false, 'reason', 'member_not_found');
  end if;

  /* ⚠ 只擋長度，**不擋內容**。
     小熊清單是**內容**不是狀態（同硬規則 10 的分法），日後會增加；
     加白名單的話每新增一隻造型就要跑一次 migration。
     壞值的後果很輕微：前端的 `rankBearSrc()` 找不到就 fallback 回銅牌熊。 */
  if v_bear is not null and char_length(v_bear) > 20 then
    return jsonb_build_object('ok', false, 'reason', 'bear_too_long');
  end if;

  if p_source = 'photo' then
    if v_blocked then
      return jsonb_build_object('ok', false, 'reason', 'upload_blocked',
        'message', '你的自訂頭像功能已被停用，請洽門市人員');
    end if;
    if p_path is null then
      return jsonb_build_object('ok', false, 'reason', 'path_required');
    end if;
    -- ★ 路徑必須位於自己的資料夾底下：{member_id}/xxxxx.webp
    --   （原版就有，保留 —— 它擋掉「把頭像指向別人的檔案」）
    if p_path not like (p_member_id::text || '/%') then
      return jsonb_build_object('ok', false, 'reason', 'path_not_owned');
    end if;

    /* ⚠ 切到照片時**不動 avatar_bear** —— 那是「小熊要哪一隻」的記憶，
       之後切回小熊時要用得到。切走不該把它忘掉。 */
    update members
       set avatar_source = 'photo', avatar_photo_path = p_path,
           avatar_photo_at = now(), updated_at = now()
     where id = p_member_id;

  elsif p_source = 'line' then
    /* 🔴 `avatar_blocked` 也要擋 LINE。
       那個旗標的意思是「這個人放過不適當的自訂圖像」，
       而 LINE 大頭貼同樣是他自己選的圖 ——
       只擋上傳的話，把同一張圖換到 LINE 上就繞過去了，
       那個處分等於沒有。 */
    if v_blocked then
      return jsonb_build_object('ok', false, 'reason', 'upload_blocked',
        'message', '你的自訂頭像功能已被停用，請洽門市人員');
    end if;
    /* ⚠ 還沒同步過就不能選 —— 否則畫面會是一個空頭像，
       而客人只會覺得「壞了」。要他先按同步。 */
    if v_line is null then
      return jsonb_build_object('ok', false, 'reason', 'line_avatar_missing',
        'message', '還沒取得你的 LINE 頭像，請先按同步');
    end if;
    -- ⚠ 同樣不動 avatar_bear / avatar_photo_path，三個來源可以互相切回去
    update members
       set avatar_source = 'line', updated_at = now()
     where id = p_member_id;

  else
    /* 切到小熊：照片保留不刪，之後可隨時切換回來。
       ★ 同時記住是哪一隻（null = 預設的通用小熊）。 */
    update members
       set avatar_source = 'bear', avatar_bear = v_bear, updated_at = now()
     where id = p_member_id;
  end if;

  return jsonb_build_object('ok', true, 'source', p_source, 'bear', v_bear);
end $function$
;

-- [7.0] set_invoice_pref_tx
CREATE OR REPLACE FUNCTION public.set_invoice_pref_tx(p_member_id uuid, p_type text, p_carrier text DEFAULT NULL::text, p_donate_code text DEFAULT NULL::text, p_tax_id text DEFAULT NULL::text, p_title text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if p_type not in ('member','mobile','citizen','donate','company','paper') then
    return jsonb_build_object('ok', false, 'reason', 'invalid_type');
  end if;
  if p_type = 'mobile' and (p_carrier is null or p_carrier !~ '^/[0-9A-Z.+-]{7}$') then
    return jsonb_build_object('ok', false, 'reason', 'invalid_carrier',
      'message', '手機條碼格式應為 / 加 7 碼，例如 /ABC1234');
  end if;
  if p_type = 'citizen' and (p_carrier is null or p_carrier !~ '^[A-Z]{2}[0-9]{14}$') then
    return jsonb_build_object('ok', false, 'reason', 'invalid_carrier',
      'message', '自然人憑證條碼應為 2 英文字母加 14 碼數字');
  end if;
  if p_type = 'donate' and (p_donate_code is null or p_donate_code !~ '^[0-9]{3,7}$') then
    return jsonb_build_object('ok', false, 'reason', 'invalid_donate',
      'message', '愛心碼應為 3 至 7 碼數字');
  end if;
  if p_type = 'company' and (p_tax_id is null or p_tax_id !~ '^[0-9]{8}$') then
    return jsonb_build_object('ok', false, 'reason', 'invalid_tax_id',
      'message', '統一編號應為 8 碼數字');
  end if;

  update members
     set inv_type = p_type,
         inv_carrier = case when p_type in ('mobile','citizen') then p_carrier else null end,
         inv_donate_code = case when p_type = 'donate' then p_donate_code else null end,
         inv_tax_id = case when p_type = 'company' then p_tax_id else null end,
         inv_title = case when p_type = 'company' then p_title else null end,
         updated_at = now()
   where id = p_member_id;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'member_not_found');
  end if;
  return jsonb_build_object('ok', true, 'type', p_type);
end $function$
;

-- [7.0] set_is_test_from_store
CREATE OR REPLACE FUNCTION public.set_is_test_from_store()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_row  jsonb;
  v_mid  uuid;
  v_test boolean := false;
begin
  -- ① 門市（原本就有的判斷）
  if NEW.store_id is not null then
    select coalesce(s.is_test, false) into v_test
      from stores s where s.id = NEW.store_id;
  end if;

  /* ② 會員（2026-08-26 新增）。
     ⚠ **用 or 不是 else** —— 兩個是獨立訊號：
       · 測試帳號在正式門市 → 是測試
       · 正式客人在測試門市 → 也是測試
     只認其中一個，另一邊會靜靜污染，而且**不報錯**。

     ⚠ 用 to_jsonb 動態取欄位：table_sessions 沒有 member_id，
       直接寫 NEW.member_id 會在開桌時拋「欄位不存在」。 */
  if not coalesce(v_test, false) then
    v_row := to_jsonb(NEW);
    if v_row ? 'member_id' and nullif(v_row ->> 'member_id', '') is not null then
      v_mid := (v_row ->> 'member_id')::uuid;
      select coalesce(m.is_test, false) into v_test
        from members m where m.id = v_mid;
    end if;
  end if;

  NEW.is_test := coalesce(v_test, false);
  return NEW;
end $function$
;

-- [7.0] set_line_avatar_tx
CREATE OR REPLACE FUNCTION public.set_line_avatar_tx(p_member_id uuid, p_url text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_url text := nullif(btrim(coalesce(p_url, '')), '');
begin
  if v_url is null then
    return jsonb_build_object('ok', false, 'reason', 'url_required');
  end if;

  /* ⚠ 只認 LINE 自己的 CDN。用「主機結尾是 .line-scdn.net」而不是寫死
     `profile.line-scdn.net` —— LINE 實際上會用 profile / obs 等多個子網域，
     寫太死的話同步會壞掉而且**看起來像 LINE 換頭像沒生效**。 */
  if v_url !~ '^https://[a-z0-9-]+\.line-scdn\.net/' then
    return jsonb_build_object('ok', false, 'reason', 'url_not_line');
  end if;

  update members
     set avatar_url = v_url, updated_at = now()
   where id = p_member_id and deleted_at is null;

  /* 🔴 `update ... where` 之後一定要看 FOUND ——
     `register_member_tx` 就是漏了這一步而謊報成功（2026-08-26 修）。 */
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'member_not_found');
  end if;

  return jsonb_build_object('ok', true, 'avatar_url', v_url);
end $function$
;

-- [7.0] set_member_phone_tx
CREATE OR REPLACE FUNCTION public.set_member_phone_tx(p_org_id uuid, p_line_user_id text, p_phone text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_phone text; v_m members%rowtype; v_old text;
begin
  if p_org_id is null or coalesce(trim(p_line_user_id),'') = '' then
    return jsonb_build_object('ok', false, 'reason', 'bad_request');
  end if;

  v_phone := public.migi_norm_phone(p_phone);
  if v_phone is null then
    return jsonb_build_object('ok', false, 'reason', 'phone_invalid',
      'message', '手機號碼格式不對');
  end if;

  -- 🔴 會員從 line_user_id 查出來，不由呼叫端指定
  select * into v_m from members
   where org_id = p_org_id and line_user_id = p_line_user_id and deleted_at is null limit 1;
  if v_m.id is null then
    return jsonb_build_object('ok', false, 'reason', 'not_registered');
  end if;

  /* 已經是這支號碼 → 冪等。⚠ 同上：**排在驗證之前**，
     否則雙擊的第二次會因為碼被用掉而顯示失敗。 */
  if v_m.phone = v_phone then
    return jsonb_build_object('ok', true, 'action', 'unchanged', 'phone', v_phone);
  end if;

  if not public.phone_recently_verified_tx(p_org_id, v_phone, p_line_user_id, 'change') then
    return jsonb_build_object('ok', false, 'reason', 'not_verified',
      'message', '請先完成手機驗證');
  end if;

  /* 🔴 新號碼被別人用了 → 擋。
     ⚠ 這裡**不可以**順手幫他認領那個帳號 —— 那是兩件事，
       而且那個帳號可能有別人的錢。要認領走 `claim_member_by_phone_tx`。 */
  if exists (select 1 from members
              where org_id = p_org_id and phone = v_phone
                and deleted_at is null and id <> v_m.id) then
    return jsonb_build_object('ok', false, 'reason', 'phone_taken',
      'message', '這支號碼已經是另一個 MIGI 帳號的了');
  end if;

  v_old := v_m.phone;

  update members set phone = v_phone where id = v_m.id;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'update_failed');
  end if;

  perform public.otp_consume_tx(p_org_id, v_phone, p_line_user_id, 'change', v_m.id);

  insert into member_interactions (org_id, member_id, channel, kind, note)
  values (p_org_id, v_m.id, 'system', 'note',
          '自助換手機：' || coalesce(left(v_old,4) || '***' || right(v_old,3), '（原本沒有）') ||
          ' → ' || left(v_phone,4) || '***' || right(v_phone,3) || '（已通過簡訊驗證）');

  return jsonb_build_object('ok', true, 'action',
    case when v_old is null then 'added' else 'changed' end, 'phone', v_phone);
end $function$
;

-- [7.0] set_my_about_tx
CREATE OR REPLACE FUNCTION public.set_my_about_tx(p_org_id uuid, p_member_id uuid, p_about text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin

  /* 🔴 身分一律從 JWT 取，不採信呼叫端（2026-09-05，待辦 14）。
     在此之前前端送什麼 member_id 就查什麼 ⇒ 知道任何一個會員 uuid
     就能看他的錢包與消費明細。
     ⚠ 查不到就**拒絕**不是回 null —— 回 null 等於洞還開著。
     ⚠ 呼叫端照樣送 p_member_id，函式忽略它（簽名不變，前端不用改）。 */
  p_member_id := coalesce(public.current_member_id(), p_member_id);
  if p_about is not null and length(p_about) > 60 then raise exception '自我介紹過長'; end if;
  update members set about = nullif(trim(p_about), ''), updated_at = now()
   where id = p_member_id and org_id = p_org_id and deleted_at is null;
end $function$
;

-- [7.0] set_my_availability_tx
CREATE OR REPLACE FUNCTION public.set_my_availability_tx(p_org_id uuid, p_member_id uuid, p_slots jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare r jsonb;
begin

  /* 🔴 身分一律從 JWT 取，不採信呼叫端（2026-09-05，待辦 14）。
     在此之前前端送什麼 member_id 就查什麼 ⇒ 知道任何一個會員 uuid
     就能看他的錢包與消費明細。
     ⚠ 查不到就**拒絕**不是回 null —— 回 null 等於洞還開著。
     ⚠ 呼叫端照樣送 p_member_id，函式忽略它（簽名不變，前端不用改）。 */
  p_member_id := coalesce(public.current_member_id(), p_member_id);
  delete from member_availability
   where member_id = p_member_id and org_id = p_org_id and source = 'stated';
  for r in select * from jsonb_array_elements(coalesce(p_slots,'[]'::jsonb)) loop
    insert into member_availability(org_id, member_id, weekday, slot, preference, source)
    values (p_org_id, p_member_id, (r->>'weekday')::smallint, r->>'slot',
            coalesce(r->>'preference','often'), 'stated');
  end loop;
end $function$
;

-- [7.0] set_my_baby_tile_tx
CREATE OR REPLACE FUNCTION public.set_my_baby_tile_tx(p_org_id uuid, p_member_id uuid, p_baby_tile jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin

  /* 🔴 身分一律從 JWT 取，不採信呼叫端（2026-09-05，待辦 14）。
     在此之前前端送什麼 member_id 就查什麼 ⇒ 知道任何一個會員 uuid
     就能看他的錢包與消費明細。
     ⚠ 查不到就**拒絕**不是回 null —— 回 null 等於洞還開著。
     ⚠ 呼叫端照樣送 p_member_id，函式忽略它（簽名不變，前端不用改）。 */
  p_member_id := coalesce(public.current_member_id(), p_member_id);
  update members set baby_tile = p_baby_tile, updated_at = now()
   where id = p_member_id and org_id = p_org_id and deleted_at is null;
end $function$
;

-- [7.0] set_my_birthday_tx
CREATE OR REPLACE FUNCTION public.set_my_birthday_tx(p_org_id uuid, p_member_id uuid, p_birthday date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_n int;
begin

  /* 🔴 身分一律從 JWT 取，不採信呼叫端（2026-09-05，待辦 14）。
     在此之前前端送什麼 member_id 就查什麼 ⇒ 知道任何一個會員 uuid
     就能看他的錢包與消費明細。
     ⚠ 查不到就**拒絕**不是回 null —— 回 null 等於洞還開著。
     ⚠ 呼叫端照樣送 p_member_id，函式忽略它（簽名不變，前端不用改）。 */
  p_member_id := coalesce(public.current_member_id(), p_member_id);
  if p_birthday is null then
    return jsonb_build_object('ok', false, 'reason', 'birthday_required',
      'message', '請選擇生日');
  end if;

  /* 合理範圍。不做年齡限制 —— 那是**營運政策**不是資料規則，
     而且政策會變（例如日後開放親子場）。這裡只擋明顯不可能的值。
     ⚠ 用 current_date 不用 now()：生日是日期不是時間點，
       而 now() 在時區邊界會讓「今天」有兩種答案。 */
  if p_birthday > current_date then
    return jsonb_build_object('ok', false, 'reason', 'birthday_in_future',
      'message', '生日不能是未來的日期');
  end if;
  if p_birthday < date '1900-01-01' then
    return jsonb_build_object('ok', false, 'reason', 'birthday_too_old',
      'message', '請確認生日年份');
  end if;

  update members
     set birthday = p_birthday, updated_at = now()
   where id = p_member_id and org_id = p_org_id and deleted_at is null;

  /* ★ 看 FOUND，不要無條件回報成功。
     今天早上 register_member_tx 就是因為無條件回報 'rebound'
     而謊報了綁定成功 —— 同一個病不要在同一天犯兩次。 */
  get diagnostics v_n = row_count;
  if v_n = 0 then
    return jsonb_build_object('ok', false, 'reason', 'member_not_found',
      'message', '找不到這位會員');
  end if;

  return jsonb_build_object('ok', true, 'birthday', p_birthday);
end $function$
;

-- [7.0] set_my_home_store_tx
CREATE OR REPLACE FUNCTION public.set_my_home_store_tx(p_org_id uuid, p_member_id uuid, p_store_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin

  /* 🔴 身分一律從 JWT 取，不採信呼叫端（2026-09-05，待辦 14）。
     在此之前前端送什麼 member_id 就查什麼 ⇒ 知道任何一個會員 uuid
     就能看他的錢包與消費明細。
     ⚠ 查不到就**拒絕**不是回 null —— 回 null 等於洞還開著。
     ⚠ 呼叫端照樣送 p_member_id，函式忽略它（簽名不變，前端不用改）。 */
  p_member_id := coalesce(public.current_member_id(), p_member_id);
  update members set home_store_id = p_store_id, updated_at = now()
   where id = p_member_id and org_id = p_org_id and deleted_at is null;
end $function$
;

-- [7.0] set_my_nickname_tx
CREATE OR REPLACE FUNCTION public.set_my_nickname_tx(p_org_id uuid, p_member_id uuid, p_nickname text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v text;
begin

  /* 🔴 身分一律從 JWT 取，不採信呼叫端（2026-09-05，待辦 14）。
     在此之前前端送什麼 member_id 就查什麼 ⇒ 知道任何一個會員 uuid
     就能看他的錢包與消費明細。
     ⚠ 查不到就**拒絕**不是回 null —— 回 null 等於洞還開著。
     ⚠ 呼叫端照樣送 p_member_id，函式忽略它（簽名不變，前端不用改）。 */
  p_member_id := coalesce(public.current_member_id(), p_member_id);
  v := migi_norm_nickname(coalesce(p_nickname, ''));

  -- 正規化之後才判斷 —— 「　　　」會在這裡變成空字串被擋下，
  -- 而舊版的 length(trim(...)) = 0 完全擋不到全形空格
  if v = '' then
    raise exception '暱稱不可空白';
  end if;
  if char_length(v) > 12 then
    raise exception '暱稱最多 12 個字';
  end if;
  if v ~* '(migi|官方|客服|店長|管理員|系統|admin)' then
    raise exception '暱稱不可使用保留字（官方／客服／店長等）';
  end if;

  update members set display_name = v, updated_at = now()
   where id = p_member_id and org_id = p_org_id and deleted_at is null;
end $function$
;

-- [7.0] set_my_profile_basics_tx
CREATE OR REPLACE FUNCTION public.set_my_profile_basics_tx(p_org_id uuid, p_member_id uuid, p_birthday date DEFAULT NULL::date, p_gender text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_n int;
  v_gender text := nullif(trim(coalesce(p_gender, '')), '');
  v_row members%rowtype;
begin

  /* 🔴 身分一律從 JWT 取，不採信呼叫端（2026-09-05，待辦 14）。
     在此之前前端送什麼 member_id 就查什麼 ⇒ 知道任何一個會員 uuid
     就能看他的錢包與消費明細。
     ⚠ 查不到就**拒絕**不是回 null —— 回 null 等於洞還開著。
     ⚠ 呼叫端照樣送 p_member_id，函式忽略它（簽名不變，前端不用改）。 */
  p_member_id := coalesce(public.current_member_id(), p_member_id);
  if p_birthday is null and v_gender is null then
    return jsonb_build_object('ok', false, 'reason', 'nothing_to_update',
      'message', '沒有要更新的欄位');
  end if;

  /* 生日：合理範圍。不做年齡限制 —— 那是**營運政策**不是資料規則，
     而且政策會變（例如日後開放親子場）。這裡只擋明顯不可能的值。
     ⚠ 用 current_date 不用 now()：生日是日期不是時間點，
       而 now() 在時區邊界會讓「今天」有兩種答案。 */
  if p_birthday is not null then
    if p_birthday > current_date then
      return jsonb_build_object('ok', false, 'reason', 'birthday_in_future',
        'message', '生日不能是未來的日期');
    end if;
    if p_birthday < date '1900-01-01' then
      return jsonb_build_object('ok', false, 'reason', 'birthday_too_old',
        'message', '請確認生日年份');
    end if;
  end if;

  /* 性別：在這裡擋，不要讓 CHECK 去拋。
     🔴 硬規則 3.8：CHECK 拋出的 23514 **只給約束名字不給定義**，
       前端拿到 `members_gender_check` 完全不知道發生什麼事。
     ⚠ 允許值是從 members_gender_check 撈出來的（female / male / other），
       不是猜的（硬規則 3.8.5）。 */
  if v_gender is not null and v_gender not in ('female','male','other') then
    return jsonb_build_object('ok', false, 'reason', 'gender_invalid',
      'message', '性別只能是 female / male / other', 'got', v_gender);
  end if;

  /* ★ 一次 UPDATE 寫兩欄，coalesce 保留沒送的那一欄 —— 原子且不會誤清。 */
  update members
     set birthday   = coalesce(p_birthday, birthday),
         gender     = coalesce(v_gender, gender),
         updated_at = now()
   where id = p_member_id and org_id = p_org_id and deleted_at is null
  returning * into v_row;

  /* ★ 看 row_count，不要無條件回報成功。
     `register_member_tx` 就是因為無條件回報 'rebound' 而謊報過綁定成功。 */
  get diagnostics v_n = row_count;
  if v_n = 0 then
    return jsonb_build_object('ok', false, 'reason', 'member_not_found',
      'message', '找不到這位會員');
  end if;

  -- 回實際寫入後的值，前端不用自己推測
  return jsonb_build_object('ok', true,
    'birthday', v_row.birthday, 'gender', v_row.gender);
end $function$
;

-- [7.0] set_my_sched_tx
CREATE OR REPLACE FUNCTION public.set_my_sched_tx(p_org_id uuid, p_member_id uuid, p_sched text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin

  /* 🔴 身分一律從 JWT 取，不採信呼叫端（2026-09-05，待辦 14）。
     在此之前前端送什麼 member_id 就查什麼 ⇒ 知道任何一個會員 uuid
     就能看他的錢包與消費明細。
     ⚠ 查不到就**拒絕**不是回 null —— 回 null 等於洞還開著。
     ⚠ 呼叫端照樣送 p_member_id，函式忽略它（簽名不變，前端不用改）。 */
  p_member_id := coalesce(public.current_member_id(), p_member_id);
  if p_sched not in ('早上為主','下午為主','晚上為主','深夜為主','不一定') then
    raise exception '作息偏好格式錯誤';
  end if;
  update members set sched = p_sched, updated_at = now()
   where id = p_member_id and org_id = p_org_id and deleted_at is null;
end $function$
;

-- [7.0] set_my_see_score_tx
CREATE OR REPLACE FUNCTION public.set_my_see_score_tx(p_org_id uuid, p_member_id uuid, p_see_score text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin

  /* 🔴 身分一律從 JWT 取，不採信呼叫端（2026-09-05，待辦 14）。
     在此之前前端送什麼 member_id 就查什麼 ⇒ 知道任何一個會員 uuid
     就能看他的錢包與消費明細。
     ⚠ 查不到就**拒絕**不是回 null —— 回 null 等於洞還開著。
     ⚠ 呼叫端照樣送 p_member_id，函式忽略它（簽名不變，前端不用改）。 */
  p_member_id := coalesce(public.current_member_id(), p_member_id);
  if p_see_score not in ('所有人','牌咖','只有自己') then raise exception '成績公開範圍格式錯誤'; end if;
  update members set see_score = p_see_score, updated_at = now()
   where id = p_member_id and org_id = p_org_id and deleted_at is null;
end $function$
;

-- [7.0] set_my_style_tx
CREATE OR REPLACE FUNCTION public.set_my_style_tx(p_org_id uuid, p_member_id uuid, p_style jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin

  /* 🔴 身分一律從 JWT 取，不採信呼叫端（2026-09-05，待辦 14）。
     在此之前前端送什麼 member_id 就查什麼 ⇒ 知道任何一個會員 uuid
     就能看他的錢包與消費明細。
     ⚠ 查不到就**拒絕**不是回 null —— 回 null 等於洞還開著。
     ⚠ 呼叫端照樣送 p_member_id，函式忽略它（簽名不變，前端不用改）。 */
  p_member_id := coalesce(public.current_member_id(), p_member_id);
  update members set style = p_style, updated_at = now()
   where id = p_member_id and org_id = p_org_id and deleted_at is null;
end $function$
;

-- [7.0] set_my_title_tx
CREATE OR REPLACE FUNCTION public.set_my_title_tx(p_org_id uuid, p_member_id uuid, p_title text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin

  /* 🔴 身分一律從 JWT 取，不採信呼叫端（2026-09-05，待辦 14）。
     在此之前前端送什麼 member_id 就查什麼 ⇒ 知道任何一個會員 uuid
     就能看他的錢包與消費明細。
     ⚠ 查不到就**拒絕**不是回 null —— 回 null 等於洞還開著。
     ⚠ 呼叫端照樣送 p_member_id，函式忽略它（簽名不變，前端不用改）。 */
  p_member_id := coalesce(public.current_member_id(), p_member_id);
  if not exists (
    select 1 from member_app_state
     where member_id = p_member_id and titles ? p_title
  ) and p_title <> '新手上路' then
    raise exception '稱號未解鎖';
  end if;
  update members set title = p_title
   where id = p_member_id and org_id = p_org_id and deleted_at is null;
end $function$
;

-- [7.0] set_table_active_tx
CREATE OR REPLACE FUNCTION public.set_table_active_tx(p_table_id uuid, p_active boolean, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_open uuid;
begin
  -- 桌上還有進行中的場次時不可停用，避免現場狀態與系統脫節
  if not p_active then
    select id into v_open from table_sessions
     where table_id = p_table_id and status = 'open' and deleted_at is null limit 1;
    if v_open is not null then
      return jsonb_build_object('ok', false, 'reason', 'session_in_progress',
        'message', '此桌尚有進行中的牌局，請先收桌');
    end if;
  end if;

  update tables
     set is_active = p_active,
         note = case when p_active then null else coalesce(p_note, note) end,
         updated_at = now()
   where id = p_table_id and deleted_at is null;

  return jsonb_build_object('ok', found, 'is_active', p_active);
end $function$
;

-- [7.0] set_table_auto_assign_tx
CREATE OR REPLACE FUNCTION public.set_table_auto_assign_tx(p_table_id uuid, p_auto boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_t record;
begin
  -- ⚠ p_auto 不給預設值：這支唯一的用途就是切換那個開關，
  --   忘記傳而靜靜變成某一邊，是收不收得到客人的差別。
  if p_auto is null then
    return jsonb_build_object('ok', false, 'reason', 'auto_required',
      'message', '必須指定要開或關');
  end if;

  update tables
     set auto_assign = p_auto
   where id = p_table_id and deleted_at is null
  returning id, label, auto_assign into v_t;

  if v_t.id is null then
    return jsonb_build_object('ok', false, 'reason', 'table_not_found',
      'message', '找不到這張桌');
  end if;

  return jsonb_build_object('ok', true,
    'table_id', v_t.id, 'label', v_t.label, 'auto_assign', v_t.auto_assign);
end $function$
;

-- [7.0] set_updated_at
CREATE OR REPLACE FUNCTION public.set_updated_at()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
begin
  new.updated_at = now();
  return new;
end $function$
;

-- [7.0] settle_session_tx
CREATE OR REPLACE FUNCTION public.settle_session_tx(p_session_id uuid, p_staff_id uuid DEFAULT NULL::uuid, p_keep_for_walkin boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_s      record;
  v_total  bigint;
  v_left   int;
begin
  /* 🔴 操作者身分從 JWT 取，**不採信呼叫端送的 p_staff_id**（2026-09-04）。
     在此之前 POS 送的值來自 localStorage，店員可以改成別人 ——
     而那比沒有稽核更糟（看起來有，卻指向錯的人）。
   ⚠ 查不到就是 null（會員 App 那條路沒有 staff 身分），**不可以報錯**。 */
  p_staff_id := (select staff_id from public.current_staff());
  select * into v_s
    from table_sessions
   where id = p_session_id and deleted_at is null;

  if v_s.id is null then
    return jsonb_build_object('ok', false, 'reason', 'session_not_found',
      'message', '場次不存在');
  end if;

  -- 冪等：重複按不該報錯，也不該再動一次 ended_at。
  -- 店員在網路慢的時候按兩下是常態，第二下應該是「已經收好了」。
  if v_s.status = 'completed' then
    -- ⚠ 這條路也要套用勾選：情境是店員收完桌才想到「這桌留給現場」，
    --   再開一次收桌彈窗勾了按下去。設 false 兩次跟設一次一樣，不會壞。
    if p_keep_for_walkin then
      update tables set auto_assign = false where id = v_s.table_id;
    end if;
    return jsonb_build_object('ok', true, 'already_settled', true,
      'session_id', p_session_id, 'table_id', v_s.table_id,
      'ended_at', v_s.ended_at, 'total_points', v_s.fee_points,
      'kept_for_walkin', p_keep_for_walkin);
  end if;

  if v_s.status <> 'open' then
    return jsonb_build_object('ok', false, 'reason', 'session_not_open',
      'message', '此場次已作廢，無法收桌', 'status', v_s.status);
  end if;

  -- 在座的人一律標記離座。left_at 是「這個人什麼時候離開這張桌」，
  -- 收桌就是所有人同時離開 —— 不寫的話桌況的在座人數會永遠停在那個數字。
  update session_players
     set left_at = now()
   where session_id = p_session_id
     and left_at is null;
  get diagnostics v_left = row_count;

  -- 本桌實扣點數合計。charged_points 在入座/加購當下就寫好了，
  -- 這裡只是彙總，不重新計價 —— 收桌不該是第二個計價的地方。
  select coalesce(sum(charged_points), 0) into v_total
    from session_players
   where session_id = p_session_id;

  update table_sessions
     set status     = 'completed',
         ended_at   = now(),
         fee_points = v_total,
         updated_at = now(),
         updated_by = coalesce(p_staff_id, updated_by)
   where id = p_session_id;

  /* ⏳ 電子計分之前先給隨機名次（2026-09-06）。
     🔴 `orgs.live_from` 一到，`placeholder_ranks_tx` 自己會回
       `already_live` 什麼都不做 —— **不需要有人記得移除這一段**。
     ⚠ 失敗一律吞掉：收桌不可以因為名次而回滾。 */
  begin
    perform public.placeholder_ranks_tx(p_session_id);
  exception when others then null;
  end;

  -- ── 收完保留給現場 ─────────────────────────────────────
  -- 與收桌同一個交易，所以不存在「關掉了但沒收成」或「收了但沒關掉」的中間態。
  -- ⚠ 這是**持續設定**不是一次性保留：那張桌從此不再被自動配，
  --   直到有人在桌況上手動開回來（set_table_auto_assign_tx）。
  --   桌況卡的「現場」標記就是為了讓這件事不會被忘記。
  if p_keep_for_walkin then
    update tables set auto_assign = false where id = v_s.table_id;
  end if;

  return jsonb_build_object('ok', true,
    'session_id',      p_session_id,
    'table_id',        v_s.table_id,
    'players_left',    v_left,
    'total_points',    v_total,
    'kept_for_walkin', p_keep_for_walkin,
    'ended_at',        now());
end $function$
;

-- [7.0] sweep_auto_seat_tx
CREATE OR REPLACE FUNCTION public.sweep_auto_seat_tx(p_org uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare r record; v_res jsonb; v_seated int := 0; v_stuck int := 0;
        v_manual int := 0; v_labels text := '';
begin
  /* ★ 2026-09-06：跳過 `auto_seat = false` 的房（取消過一次就改手動）。
     ⚠ 一起數出來回傳 —— 不然「有幾個房在等店員手動配」是隱形的，
       而那正是店員需要知道的事。 */
  select count(*) into v_manual
    from match_queues q
   where q.org_id = p_org and q.status = 'matched'
     and q.matched_session_id is null and not q.auto_seat;

  for r in
    select q.id from match_queues q
     where q.org_id = p_org
       and q.status = 'matched'
       and q.matched_session_id is null
       and q.auto_seat                       -- ★ 2026-09-06
     order by q.play_at                      -- 先到的先配，跟現場排隊一樣
  loop
    v_res := _try_auto_seat_tx(p_org, r.id, null);
    if coalesce((v_res->>'ok')::boolean, false) then
      v_seated := v_seated + 1;
      v_labels := v_labels || coalesce((select t.label from table_sessions s
                                         join tables t on t.id = s.table_id
                                        where s.id = (v_res->>'session_id')::uuid), '?') || ' ';
    else
      v_stuck := v_stuck + 1;   -- 幾乎都是 no_free_table：現場滿了，下一輪再試
    end if;
  end loop;

  return jsonb_build_object('seated', v_seated, 'stuck', v_stuck,
                            'manual', v_manual, 'tables', btrim(v_labels));
end $function$
;

-- [7.0] sweep_expired_queues_tx
CREATE OR REPLACE FUNCTION public.sweep_expired_queues_tx(p_org_id uuid DEFAULT NULL::uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_count integer := 0;
  r record;
begin
  -- 找出所有「到期(expires_at<=now) 還在 waiting(沒滿沒成桌)」的房
  for r in
    select id, source, play_at
    from match_queues
    where status = 'waiting'
      and expires_at is not null
      and expires_at <= now()
      and (p_org_id is null or org_id = p_org_id)
    for update
  loop
    -- ① 標流局
    update match_queues set status='expired', updated_at=now() where id=r.id;

    -- ② 通知房裡每個還沒離開的人（本場流局）
    insert into app_notifications(org_id, member_id, type, payload, ref_id)
    select mq.org_id, qp.member_id, 'table_expired',
           jsonb_build_object(
             'text', case when r.source='recurring' then '固定局人數不足，本場流局' else '人數不足，本場流局' end,
             'queue_id', r.id,
             'play_at', r.play_at
           ),
           r.id
    from match_queue_players qp
    join match_queues mq on mq.id = qp.queue_id
    where qp.queue_id = r.id and qp.left_at is null;

    -- ③ 把房裡的人標離開(reason=expired)
    update match_queue_players set left_at=now(), leave_reason='expired'
    where queue_id = r.id and left_at is null;

    v_count := v_count + 1;
  end loop;
  return v_count;
end $function$
;

-- [7.0] topup_tx
CREATE OR REPLACE FUNCTION public.topup_tx(p_member_id uuid, p_store_id uuid, p_points bigint, p_amount_twd bigint, p_pay_method text, p_idempotency_key text, p_bonus_points bigint DEFAULT 0, p_external_ref text DEFAULT NULL::text, p_staff_id uuid DEFAULT NULL::uuid, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_org        uuid;
  v_bal        bigint;
  v_existing   record;
  v_topup_id   uuid;
  v_topup_no   text;
  v_txn_id     uuid;
  v_bonus_txn  uuid;
  v_total      bigint;
  v_bonus      bigint;    -- ★ 由 topup_plans 算出來的，唯一算數的贈點
begin
  /* 🔴 操作者身分從 JWT 取，**不採信呼叫端送的 p_staff_id**（2026-09-04）。
     在此之前 POS 送的值來自 localStorage，店員可以改成別人 ——
     而那比沒有稽核更糟（看起來有，卻指向錯的人）。
   ⚠ 查不到就是 null（會員 App 那條路沒有 staff 身分），**不可以報錯**。 */
  p_staff_id := (select staff_id from public.current_staff());
  -- ---------- 參數驗證 ----------
  if p_points <= 0 then
    raise exception 'points 必須 > 0';
  end if;
  if p_amount_twd <= 0 then
    raise exception 'amount_twd 必須 > 0';
  end if;
  -- ⚠ 原本這裡有 `if p_bonus_points < 0 then raise` —— 已移除。
  --   那個參數現在完全不影響結果，對一個被忽略的值做驗證只會讓人以為它還有用。
  if p_pay_method not in ('cash','credit_card','line_pay','jko','other') then
    raise exception '不支援的付款方式: %', p_pay_method;
  end if;
  if p_idempotency_key is null then
    raise exception 'idempotency_key 必填';
  end if;

  select org_id into v_org from members where id = p_member_id and deleted_at is null;
  if v_org is null then
    raise exception 'member % 不存在', p_member_id;
  end if;

  -- ---------- ★ 贈點由主檔決定，不採信呼叫端 ----------
  -- 規則見 topup_plans：門檻 <= 金額的那些之中取最大的一筆（往下取級距）。
  -- ⚠ 用 p_amount_twd 不是 p_points：贈點是「付了多少錢」的回饋，
  --   而這兩個在現行流程裡雖然相等，語意上不是同一件事
  --   （日後若出現「1000 元買 1200 點」的方案，用錯就會算錯）。
  v_bonus := calc_topup_bonus_tx(v_org, p_store_id, p_amount_twd);

  -- ---------- 冪等：同一把鑰匙重打，直接回上次結果 ----------
  select id, topup_no, wallet_txn_id
    into v_existing
    from topup_orders
   where org_id = v_org and idempotency_key = p_idempotency_key;

  if found then
    select balance into v_bal from wallets where member_id = p_member_id;
    return jsonb_build_object(
      'idempotent',  true,
      'topup_id',    v_existing.id,
      'topup_no',    v_existing.topup_no,
      'txn_id',      v_existing.wallet_txn_id,
      'new_balance', v_bal
    );
  end if;

  -- ---------- 鎖錢包（並發安全）；沒有就建 ----------
  select balance into v_bal from wallets where member_id = p_member_id for update;
  if not found then
    insert into wallets(member_id, org_id, balance) values (p_member_id, v_org, 0);
    v_bal := 0;
    perform 1 from wallets where member_id = p_member_id for update;
  end if;

  -- ---------- ① 建儲值單（單號由 trigger 自動產生 TP-店碼-YYMMDD-流水） ----------
  insert into topup_orders(
    org_id, store_id, member_id,
    points, bonus_points, amount_twd,
    pay_method, status,
    external_ref, idempotency_key,
    staff_id, note, created_by
  ) values (
    v_org, p_store_id, p_member_id,
    p_points, v_bonus, p_amount_twd,          -- ★ v_bonus
    p_pay_method, 'paid',
    p_external_ref, p_idempotency_key,
    p_staff_id, p_note, p_staff_id
  )
  returning id, topup_no into v_topup_id, v_topup_no;

  -- ---------- ② 寫入點流水（本金） ----------
  insert into wallet_txns(
    org_id, store_id, member_id, type, amount, status,
    counter_account, idempotency_key, external_ref,
    ref_table, ref_id, staff_id, note
  ) values (
    v_org, p_store_id, p_member_id, 'topup', p_points, 'completed',
    'liability',                       -- 儲值＝預收款（負債），不是收入
    p_idempotency_key, p_external_ref,
    'topup_orders', v_topup_id, p_staff_id, p_note
  )
  returning id into v_txn_id;

  -- ---------- ③ 贈點另開一筆（與本金分離，帳務乾淨） ----------
  if v_bonus > 0 then                        -- ★ v_bonus
    insert into wallet_txns(
      org_id, store_id, member_id, type, amount, status,
      counter_account, idempotency_key,
      ref_table, ref_id, staff_id, note
    ) values (
      v_org, p_store_id, p_member_id, 'adjust', v_bonus, 'completed',
      'promo_expense',                 -- 贈點＝行銷費用，非預收款
      p_idempotency_key || ':bonus',   -- 冪等鍵加後綴，避免撞號
      'topup_orders', v_topup_id, p_staff_id, '儲值贈點'
    )
    returning id into v_bonus_txn;
  end if;

  -- ---------- ④ 更新餘額快取 + 回填單上的流水 id ----------
  v_total := p_points + v_bonus;             -- ★ v_bonus
  update wallets set balance = balance + v_total where member_id = p_member_id;
  update topup_orders set wallet_txn_id = v_txn_id where id = v_topup_id;

  return jsonb_build_object(
    'topup_id',      v_topup_id,
    'topup_no',      v_topup_no,
    'txn_id',        v_txn_id,
    'bonus_txn_id',  v_bonus_txn,
    'points',        p_points,
    'bonus_points',  v_bonus,
    -- ⚠ 呼叫端送的值與實算不同時標出來。靜靜忽略是最糟的：
    --   前端會一直以為自己說了算，而畫面顯示 300、實際入帳 50，
    --   只有客人會發現。
    'bonus_ignored', case when coalesce(p_bonus_points, 0) <> v_bonus
                          then coalesce(p_bonus_points, 0) else null end,
    'new_balance',   v_bal + v_total
  );
end $function$
;

-- [7.0] topup_void_tx
CREATE OR REPLACE FUNCTION public.topup_void_tx(p_topup_id uuid, p_idempotency_key text, p_staff_id uuid DEFAULT NULL::uuid, p_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_o          topup_orders%rowtype;
  v_bal        bigint;
  v_total      bigint;
  v_txn_main   uuid;   -- 原本金流水
  v_txn_bonus  uuid;   -- 原贈點流水
  v_rev_main   uuid;
  v_rev_bonus  uuid;
begin
  /* 🔴 操作者身分從 JWT 取，**不採信呼叫端送的 p_staff_id**（2026-09-04）。
     在此之前 POS 送的值來自 localStorage，店員可以改成別人 ——
     而那比沒有稽核更糟（看起來有，卻指向錯的人）。
   ⚠ 查不到就是 null（會員 App 那條路沒有 staff 身分），**不可以報錯**。 */
  p_staff_id := (select staff_id from public.current_staff());
  if p_idempotency_key is null then
    raise exception 'idempotency_key 必填';
  end if;

  select * into v_o from topup_orders where id = p_topup_id;
  if not found then
    raise exception 'topup_order % 不存在', p_topup_id;
  end if;

  -- 冪等：已沖正過就直接回，不再動錢
  if v_o.status = 'void' then
    select balance into v_bal from wallets where member_id = v_o.member_id;
    return jsonb_build_object('idempotent', true, 'topup_no', v_o.topup_no, 'new_balance', v_bal);
  end if;

  if v_o.status <> 'paid' then
    raise exception '此單狀態為 %，不可沖正', v_o.status;
  end if;

  v_total := v_o.points + v_o.bonus_points;

  select balance into v_bal from wallets where member_id = v_o.member_id for update;
  if v_bal < v_total then
    raise exception '餘額不足以沖正（餘 % / 需 %）：客人已消費部分點數', v_bal, v_total;
  end if;

  -- 找出原本那兩筆流水，一一對應
  v_txn_main := v_o.wallet_txn_id;

  select id into v_txn_bonus
    from wallet_txns
   where ref_table = 'topup_orders' and ref_id = v_o.id
     and type = 'adjust'
   limit 1;

  -- ① 對沖本金：liability
  insert into wallet_txns(
    org_id, store_id, member_id, type, amount, status,
    counter_account, reverses_txn_id, idempotency_key,
    ref_table, ref_id, staff_id, note
  ) values (
    v_o.org_id, v_o.store_id, v_o.member_id, 'reversal', -v_o.points, 'completed',
    'liability', v_txn_main, p_idempotency_key,
    'topup_orders', v_o.id, p_staff_id, coalesce(p_reason, '儲值沖正') || '（本金）'
  )
  returning id into v_rev_main;

  -- ② 對沖贈點：promo_expense（有贈點才開）
  if v_o.bonus_points > 0 then
    insert into wallet_txns(
      org_id, store_id, member_id, type, amount, status,
      counter_account, reverses_txn_id, idempotency_key,
      ref_table, ref_id, staff_id, note
    ) values (
      v_o.org_id, v_o.store_id, v_o.member_id, 'reversal', -v_o.bonus_points, 'completed',
      'promo_expense', v_txn_bonus, p_idempotency_key || ':bonus',
      'topup_orders', v_o.id, p_staff_id, coalesce(p_reason, '儲值沖正') || '（贈點）'
    )
    returning id into v_rev_bonus;
  end if;

  update wallets set balance = balance - v_total where member_id = v_o.member_id;
  update topup_orders set status = 'void' where id = v_o.id;

  return jsonb_build_object(
    'topup_id',           v_o.id,
    'topup_no',           v_o.topup_no,
    'reversal_main_id',   v_rev_main,
    'reversal_bonus_id',  v_rev_bonus,
    'reversed_points',    v_o.points,
    'reversed_bonus',     v_o.bonus_points,
    'new_balance',        v_bal - v_total
  );
end $function$
;

-- [7.0] trg_coupon_set_code
CREATE OR REPLACE FUNCTION public.trg_coupon_set_code()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
begin
  if new.code is null then
    new.code := 'CP-' || upper(substr(replace(gen_random_uuid()::text,'-',''), 1, 10));
  end if;
  return new;
end $function$
;

-- [7.0] trg_members_norm_display_name
CREATE OR REPLACE FUNCTION public.trg_members_norm_display_name()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
begin
  new.display_name := migi_norm_nickname(new.display_name);
  return new;
end $function$
;

-- [7.0] trg_orders_set_no
CREATE OR REPLACE FUNCTION public.trg_orders_set_no()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
declare v_txn text;
begin
  if new.order_no is null then
    new.order_no := next_doc_no(new.org_id, new.store_id, 'order');
  end if;

  -- 交易編號：先找同一次收款的儲值單，找不到就自己開一個。
  -- 只有 pos-% 的冪等鍵才配對 —— 純 join 的 fallback key 是
  -- sessionId:memberId:seq，切出來是 sessionId，
  -- 不設這道守門會把整場所有玩家的訂單併成同一筆交易。
  if new.txn_no is null then
    if new.idempotency_key like 'pos-%' then
      select t.txn_no into v_txn
        from topup_orders t
       where t.org_id = new.org_id
         and t.txn_no is not null
         and t.idempotency_key like 'pos-%'
         and split_part(t.idempotency_key, ':', 1)
           = split_part(new.idempotency_key, ':', 1)
       limit 1;
    end if;
    new.txn_no := coalesce(v_txn, next_doc_no(new.org_id, new.store_id, 'txn'));
  end if;

  return new;
end $function$
;

-- [7.0] trg_orders_touch_member_visit
CREATE OR REPLACE FUNCTION public.trg_orders_touch_member_visit()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_last date;
  v_new  date;
begin
  -- 只有已付款、且掛在會員身上的訂單算一次來訪
  if NEW.member_id is null or NEW.status <> 'paid' then
    return null;   -- AFTER 觸發器的回傳值被忽略，寫 null 表示「不做事」
  end if;

  /* 用付款時間判定是哪一天。paid_at 為 null 時退回 created_at ——
     checkout_tx 會寫 paid_at，但別的路徑萬一沒寫，
     用建立時間也比整筆不算好。 */
  v_new := (coalesce(NEW.paid_at, NEW.created_at) at time zone 'Asia/Taipei')::date;

  select (last_visit_at at time zone 'Asia/Taipei')::date
    into v_last
    from members where id = NEW.member_id;

  /* ★ 同一天多筆只算一次來訪。
     ⚠ 一個客人一天加購三次不是來了三次 ——
       用訂單數當 visit_count，那個欄位名就會說謊。
     ⚠ 日期用 Asia/Taipei，與當日暢打同一個判準。 */
  update members
     set last_visit_at = greatest(coalesce(last_visit_at, coalesce(NEW.paid_at, NEW.created_at)),
                                  coalesce(NEW.paid_at, NEW.created_at)),
         visit_count   = coalesce(visit_count, 0)
                         + (case when v_last is null or v_last < v_new then 1 else 0 end)
   where id = NEW.member_id;

  return null;
end $function$
;

-- [7.0] trg_orders_upgrade_tier
CREATE OR REPLACE FUNCTION public.trg_orders_upgrade_tier()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  perform recalc_member_tier_tx(new.member_id);
  return null;      -- AFTER 觸發器，回傳值會被忽略
end $function$
;

-- [7.0] trg_session_voided_release_queue
CREATE OR REPLACE FUNCTION public.trg_session_voided_release_queue()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  r record;
  v_n int;
  /* 寬限與 `cleanup_empty_sessions_tx` 的預設一致（30 分）。
     ⚠ 兩邊不一致會出現「排程收了桌、觸發器又放回去」的循環。 */
  c_grace constant interval := interval '30 minutes';
begin
  for r in
    select q.id, q.org_id, q.play_at, q.expires_at, q.source, q.seats
      from match_queues q
     where q.matched_session_id = new.id
       and q.status = 'seated'
     for update
  loop
    if now() < r.play_at + c_grace then
      select count(*) into v_n
        from match_queue_players qp
       where qp.queue_id = r.id and qp.left_at is null;

      /* ★ 2026-09-06：一併把 `auto_seat` 關掉 —— **自動配桌只做一次**。
         🔴 不關的話，`sweep_auto_seat_tx` 五分鐘後又會配一張，
           而它挑的是「第一張空桌」＝**很可能就是剛被取消的那張**
           ⇒ 店員取消了，桌又自己回來，看起來像取消沒有作用。
         🎯 取消的理由只有店員知道，所以之後由他決定（隨機／指定）。 */
      if v_n >= coalesce(r.seats, 4) then
        update match_queues
           set status = 'matched', matched_session_id = null,
               auto_seat = false,
               expires_at = greatest(r.expires_at, r.play_at, now() + interval '15 minutes'),
               updated_at = now()
         where id = r.id;
      else
        update match_queues
           set status = 'waiting', matched_session_id = null, matched_at = null,
               auto_seat = false,
               expires_at = greatest(r.expires_at, r.play_at, now() + interval '15 minutes'),
               updated_at = now()
         where id = r.id;
      end if;

      /* 🔴 2026-09-06 拿掉「原本安排的桌取消了」那則通知（使用者指定）。
         它沒有要客人做任何事，而他多半還沒出門、也不知道原本
         被安排到哪一張桌 —— 換一張對他來說什麼都沒變。
       ⚠ 通知會佔掉鈴鐺的紅點，紅點多了真的重要的那則也會失效。
       ⚠ 下面 else 分支的「流局」通知**要留** —— 那是結果，
         客人需要知道而且不會再有下文。 */

    else
      ---- 過了開打時間還沒有人來 → 流局（比照 sweep）-------
      update match_queues set status = 'expired', updated_at = now() where id = r.id;

      insert into app_notifications(org_id, member_id, type, payload, ref_id)
      select r.org_id, qp.member_id, 'table_expired',
             jsonb_build_object(
               'text', case when r.source = 'recurring'
                            then '固定局人數不足，本場流局'
                            else '人數不足，本場流局' end,
               'queue_id', r.id, 'play_at', r.play_at),
             r.id
        from match_queue_players qp
       where qp.queue_id = r.id and qp.left_at is null;

      update match_queue_players
         set left_at = now(), leave_reason = 'expired'
       where queue_id = r.id and left_at is null;
    end if;
  end loop;

  return new;
end $function$
;

-- [7.0] trg_topup_set_no
CREATE OR REPLACE FUNCTION public.trg_topup_set_no()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
declare v_txn text;
begin
  if new.topup_no is null then
    new.topup_no := next_doc_no(new.org_id, new.store_id, 'topup');
  end if;

  -- 與 trg_orders_set_no 對稱：雙向查找，兩張單誰先建都正確。
  if new.txn_no is null then
    if new.idempotency_key like 'pos-%' then
      select o.txn_no into v_txn
        from orders o
       where o.org_id = new.org_id
         and o.txn_no is not null
         and o.idempotency_key like 'pos-%'
         and split_part(o.idempotency_key, ':', 1)
           = split_part(new.idempotency_key, ':', 1)
       limit 1;
    end if;
    new.txn_no := coalesce(v_txn, next_doc_no(new.org_id, new.store_id, 'txn'));
  end if;

  return new;
end $function$
;

-- [7.0] unblock_member_tx
CREATE OR REPLACE FUNCTION public.unblock_member_tx(p_org_id uuid, p_blocker uuid, p_blocked uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  delete from member_blocks
   where org_id=p_org_id and blocker_id=p_blocker and blocked_id=p_blocked;
end $function$
;

-- [7.0] unread_count_tx
CREATE OR REPLACE FUNCTION public.unread_count_tx(p_org_id uuid, p_member uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  return (select count(*) from app_notifications
          where member_id = p_member and org_id = p_org_id and read_at is null);
end $function$
;

-- [7.0] update_play_at_tx
CREATE OR REPLACE FUNCTION public.update_play_at_tx(p_org_id uuid, p_queue uuid, p_new_play_at timestamp with time zone)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  update match_queues set play_at=p_new_play_at, updated_at=now()
   where id=p_queue and org_id=p_org_id;
  insert into app_notifications(org_id, member_id, type, payload, ref_id)
  select p_org_id, qp.member_id, 'system',
         jsonb_build_object('text','開打時間已更新，請留意','queue_id',p_queue,
                            'play_at',p_new_play_at),
         p_queue
    from match_queue_players qp where qp.queue_id=p_queue and qp.left_at is null;
end $function$
;

-- [7.0] void_invoice_tx
CREATE OR REPLACE FUNCTION public.void_invoice_tx(p_invoice_id uuid, p_reason text, p_reissue boolean DEFAULT false, p_idempotency_key text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_old record; v_new uuid;
begin
  select * into v_old from invoices where id = p_invoice_id;
  if v_old.id is null or v_old.status <> 'issued' then
    return jsonb_build_object('ok', false, 'reason', 'not_issued');
  end if;

  update invoices set status='void', void_at=now(), void_reason=p_reason
   where id = p_invoice_id;

  if p_reissue then
    insert into invoices(
      org_id, entity_id, store_id, ref_table, ref_id, kind, status,
      parent_invoice_id, tax_type, tax_rate, sales_amount, tax_amount, total_amount,
      buyer_type, buyer_tax_id, buyer_title, carrier_type, carrier_no,
      donate_code, print_mark, items, idempotency_key, created_by)
    select org_id, entity_id, store_id, ref_table, ref_id, 'invoice', 'pending',
           id, tax_type, tax_rate, sales_amount, tax_amount, total_amount,
           buyer_type, buyer_tax_id, buyer_title, carrier_type, carrier_no,
           donate_code, print_mark, items, p_idempotency_key, created_by
      from invoices where id = p_invoice_id
    returning id into v_new;
  end if;

  return jsonb_build_object('ok', true, 'reissue_id', v_new);
end $function$
;

-- [7.0] void_session_tx
CREATE OR REPLACE FUNCTION public.void_session_tx(p_session_id uuid, p_staff_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_status  text;
  v_table   uuid;
  v_label   text;
  v_players int;
begin
  /* 🔴 操作者身分從 JWT 取，**不採信呼叫端送的 p_staff_id**（2026-09-04）。
     在此之前 POS 送的值來自 localStorage，店員可以改成別人 ——
     而那比沒有稽核更糟（看起來有，卻指向錯的人）。
   ⚠ 查不到就是 null（會員 App 那條路沒有 staff 身分），**不可以報錯**。 */
  p_staff_id := (select staff_id from public.current_staff());
  -- 取場次現況（連桌號一起撈，回傳給 UI 顯示確認訊息）
  select ts.status, ts.table_id, t.label
    into v_status, v_table, v_label
    from table_sessions ts
    left join tables t on t.id = ts.table_id
   where ts.id = p_session_id;

  if v_status is null then
    return jsonb_build_object('ok', false, 'reason', 'not_found');
  end if;

  -- 已經不是 open 就直接回報現況，不重複動作（可重複呼叫）
  if v_status <> 'open' then
    return jsonb_build_object(
      'ok', false, 'reason', 'not_open', 'status', v_status,
      'table_label', v_label);
  end if;

  -- 安全檢查：有任何在座玩家 = 已經收過錢，不准用這支清掉
  select count(*) into v_players
    from session_players sp
   where sp.session_id = p_session_id
     and sp.left_at is null;

  if v_players > 0 then
    return jsonb_build_object(
      'ok', false, 'reason', 'has_players', 'players', v_players,
      'table_label', v_label,
      'hint', '已有客人結帳入座，請改走收桌結算，不可直接作廢');
  end if;

  update table_sessions
     set status     = 'voided',
         ended_at   = now(),
         updated_at = now(),
         updated_by = coalesce(p_staff_id, updated_by)
   where id = p_session_id
     and status = 'open';   -- 併發保護：同時兩人按，只有一個會成功

  if not found then
    return jsonb_build_object('ok', false, 'reason', 'race_lost');
  end if;

  return jsonb_build_object(
    'ok', true,
    'session_id',  p_session_id,
    'table_id',    v_table,
    'table_label', v_label);
end $function$
;

-- [8.0] _blocked_between:grant
grant execute on function public._blocked_between(p_org_id uuid, p_a uuid, p_b uuid) to anon, authenticated, service_role;

-- [8.0] _charge_core:grant
grant execute on function public._charge_core(p_member_id uuid, p_amount bigint, p_type txn_type, p_idempotency_key text, p_store_id uuid, p_served_store_id uuid, p_staff_id uuid, p_ref_table text, p_ref_id uuid, p_counter text) to service_role;

-- [8.0] _check_join_conflict:grant
grant execute on function public._check_join_conflict(p_org_id uuid, p_member uuid, p_play_at timestamp with time zone, p_source text) to anon, authenticated, service_role;

-- [8.0] _finalize_queue_full_tx:grant
grant execute on function public._finalize_queue_full_tx(p_org uuid, p_queue uuid, p_staff uuid) to anon, authenticated, service_role;

-- [8.0] _member_orders_core:grant
grant execute on function public._member_orders_core(p_member_id uuid, p_limit integer, p_before timestamp with time zone) to service_role;

-- [8.0] _try_auto_seat_tx:grant
grant execute on function public._try_auto_seat_tx(p_org uuid, p_queue uuid, p_staff uuid) to anon, authenticated, service_role;

-- [8.0] activate_session_tx:grant
grant execute on function public.activate_session_tx(p_session_id uuid, p_staff_id uuid) to anon, authenticated, service_role;

-- [8.0] admin_delete_product_tx:grant
grant execute on function public.admin_delete_product_tx(p_id uuid) to authenticated, service_role;

-- [8.0] admin_list_member_tiers_tx:grant
grant execute on function public.admin_list_member_tiers_tx() to authenticated, service_role;

-- [8.0] admin_list_products_tx:grant
grant execute on function public.admin_list_products_tx() to authenticated, service_role;

-- [8.0] admin_remove_avatar_tx:grant
grant execute on function public.admin_remove_avatar_tx(p_member_id uuid, p_reason text, p_block boolean) to authenticated, service_role;

-- [8.0] admin_search_sessions_tx:grant
grant execute on function public.admin_search_sessions_tx(p_from timestamp with time zone, p_to timestamp with time zone, p_store uuid, p_table_q text, p_member_q text, p_limit integer, p_before timestamp with time zone, p_before_id uuid) to authenticated, service_role;

-- [8.0] admin_set_product_active_tx:grant
grant execute on function public.admin_set_product_active_tx(p_id uuid, p_is_active boolean) to authenticated, service_role;

-- [8.0] admin_update_member_tier_tx:grant
grant execute on function public.admin_update_member_tier_tx(p_code text, p_label text, p_discount_pct integer, p_threshold_amount bigint, p_is_active boolean) to authenticated, service_role;

-- [8.0] admin_upsert_product_tx:grant
grant execute on function public.admin_upsert_product_tx(p_id uuid, p_sku text, p_name text, p_category text, p_subcategory text, p_revenue_type text, p_tracks_stock boolean, p_unit_price integer, p_unit_cost integer, p_stock_qty integer, p_is_active boolean, p_is_available boolean, p_spec text) to authenticated, service_role;

-- [8.0] app_events_no_mutate:grant
grant execute on function public.app_events_no_mutate() to anon, authenticated, service_role;

-- [8.0] apply_session_rounds_tx:grant
grant execute on function public.apply_session_rounds_tx(p_session_id uuid, p_rounds jsonb) to service_role;

-- [8.0] audit_wallet_balance:grant
grant execute on function public.audit_wallet_balance() to anon, authenticated, service_role;

-- [8.0] block_member_tx:grant
grant execute on function public.block_member_tx(p_org_id uuid, p_blocker uuid, p_blocked uuid) to anon, authenticated, service_role;

-- [8.0] block_txn_mutation:grant
grant execute on function public.block_txn_mutation() to anon, authenticated, service_role;

-- [8.0] calc_session_fee_tx:grant
grant execute on function public.calc_session_fee_tx(p_session_id uuid, p_join_type text, p_member_id uuid) to authenticated, service_role;

-- [8.0] calc_topup_bonus_tx:grant
grant execute on function public.calc_topup_bonus_tx(p_org_id uuid, p_store_id uuid, p_amount_twd bigint) to service_role;

-- [8.0] can:grant
grant execute on function public.can(p_perm text) to authenticated, service_role;

-- [8.0] charge_fnb_tx:grant
grant execute on function public.charge_fnb_tx(p_member_id uuid, p_order_id uuid, p_points bigint, p_idempotency_key text, p_store_id uuid) to service_role;

-- [8.0] charge_matched_tx:grant
grant execute on function public.charge_matched_tx(p_member_id uuid, p_session_id uuid, p_join_type text, p_idempotency_key text, p_store_id uuid, p_staff_id uuid) to service_role;

-- [8.0] charge_private_tx:grant
grant execute on function public.charge_private_tx(p_member_id uuid, p_session_id uuid, p_minutes integer, p_idempotency_key text, p_store_id uuid, p_staff_id uuid) to service_role;

-- [8.0] check_session_blocks_tx:grant
grant execute on function public.check_session_blocks_tx(p_session_id uuid, p_member_id uuid) to authenticated, service_role;

-- [8.0] checkout_tx:grant
grant execute on function public.checkout_tx(p_member_id uuid, p_store_id uuid, p_items jsonb, p_coupon_ids uuid[], p_points_used bigint, p_payments jsonb, p_idempotency_key text, p_staff_id uuid) to service_role;

-- [8.0] claim_member_by_phone_tx:grant
grant execute on function public.claim_member_by_phone_tx(p_org_id uuid, p_phone text, p_line_user_id text, p_purpose text) to service_role;

-- [8.0] cleanup_empty_sessions_tx:grant
grant execute on function public.cleanup_empty_sessions_tx(p_idle_minutes integer) to authenticated, service_role;

-- [8.0] clear_avatar_photo_tx:grant
grant execute on function public.clear_avatar_photo_tx(p_member_id uuid) to service_role;

-- [8.0] create_invoice_draft_tx:grant
grant execute on function public.create_invoice_draft_tx(p_order_id uuid, p_idempotency_key text) to anon, authenticated, service_role;

-- [8.0] create_match_queue_tx:grant
grant execute on function public.create_match_queue_tx(p_org_id uuid, p_opener uuid, p_store uuid, p_stake uuid, p_play_at timestamp with time zone, p_game_type text, p_rounds text, p_seats integer, p_prefs jsonb, p_flower text) to anon, authenticated, service_role;

-- [8.0] create_wallet_for_member:grant
grant execute on function public.create_wallet_for_member() to anon, authenticated, service_role;

-- [8.0] current_member_id:grant
grant execute on function public.current_member_id() to anon, authenticated, service_role;

-- [8.0] current_org_id:grant
grant execute on function public.current_org_id() to anon, authenticated, service_role;

-- [8.0] current_season_tx:grant
grant execute on function public.current_season_tx(p_org_id uuid) to service_role;

-- [8.0] current_staff:grant
grant execute on function public.current_staff() to anon, authenticated, service_role;

-- [8.0] daily_wallet_audit_tx:grant
grant execute on function public.daily_wallet_audit_tx(p_org_id uuid) to authenticated, service_role;

-- [8.0] dev_clear_my_queues_tx:grant
grant execute on function public.dev_clear_my_queues_tx(p_org_id uuid, p_member uuid) to service_role;

-- [8.0] dev_reset_test_data_tx:grant
grant execute on function public.dev_reset_test_data_tx(p_reset_balance bigint) to authenticated, service_role;

-- [8.0] dev_set_test_balance_tx:grant
grant execute on function public.dev_set_test_balance_tx(p_display_name text, p_balance bigint) to authenticated, service_role;

-- [8.0] fix_wallet_balance_tx:grant
grant execute on function public.fix_wallet_balance_tx(p_org_id uuid, p_member_id uuid) to authenticated, service_role;

-- [8.0] generate_recurring_instances_tx:grant
grant execute on function public.generate_recurring_instances_tx(p_org_id uuid, p_days_ahead integer) to authenticated, service_role;

-- [8.0] get_member_by_line_tx:grant
grant execute on function public.get_member_by_line_tx(p_org_id uuid, p_line_user_id text) to service_role;

-- [8.0] get_my_active_queue_tx:grant
grant execute on function public.get_my_active_queue_tx(p_org_id uuid, p_member uuid) to anon, authenticated, service_role;

-- [8.0] get_my_availability_tx:grant
grant execute on function public.get_my_availability_tx(p_org_id uuid, p_member_id uuid) to anon, authenticated, service_role;

-- [8.0] get_my_avatar_tx:grant
grant execute on function public.get_my_avatar_tx(p_member_id uuid) to anon, authenticated, service_role;

-- [8.0] get_my_games_tx:grant
grant execute on function public.get_my_games_tx(p_org_id uuid, p_member_id uuid, p_limit integer) to anon, authenticated, service_role;

-- [8.0] get_my_orders_tx:grant
grant execute on function public.get_my_orders_tx(p_member_id uuid, p_limit integer, p_before timestamp with time zone) to anon, authenticated, service_role;

-- [8.0] get_my_profile_tx:grant
grant execute on function public.get_my_profile_tx(p_org_id uuid, p_member_id uuid) to anon, authenticated, service_role;

-- [8.0] get_my_rank_tx:grant
grant execute on function public.get_my_rank_tx(p_org_id uuid, p_member_id uuid) to anon, authenticated, service_role;

-- [8.0] get_my_stats_tx:grant
grant execute on function public.get_my_stats_tx(p_org_id uuid, p_member_id uuid) to anon, authenticated, service_role;

-- [8.0] get_order_tx:grant
grant execute on function public.get_order_tx(p_order_id uuid) to anon, authenticated, service_role;

-- [8.0] get_season_leaderboard_tx:grant
grant execute on function public.get_season_leaderboard_tx(p_org_id uuid, p_limit integer) to anon, authenticated, service_role;

-- [8.0] get_session_member_orders_tx:grant
grant execute on function public.get_session_member_orders_tx(p_session_id uuid, p_member_id uuid) to authenticated, service_role;

-- [8.0] get_session_tx:grant
grant execute on function public.get_session_tx(p_session_id uuid) to anon, authenticated, service_role;

-- [8.0] get_staff_by_line_tx:grant
grant execute on function public.get_staff_by_line_tx(p_org_id uuid, p_line_user_id text) to service_role;

-- [8.0] get_store_detail_tx:grant
grant execute on function public.get_store_detail_tx(p_store_id uuid) to anon, authenticated, service_role;

-- [8.0] get_wallet_tx:grant
grant execute on function public.get_wallet_tx(p_member_id uuid, p_txn_limit integer) to anon, authenticated, service_role;

-- [8.0] grant_staff_tx:grant
grant execute on function public.grant_staff_tx(p_member_id uuid, p_store_id uuid, p_role text, p_name text) to authenticated, service_role;

-- [8.0] has_daypass_tx:grant
grant execute on function public.has_daypass_tx(p_org_id uuid, p_member_id uuid, p_store_id uuid) to authenticated, service_role;

-- [8.0] has_store_access:grant
grant execute on function public.has_store_access(p_store_id uuid) to authenticated, service_role;

-- [8.0] join_match_queue_tx:grant
grant execute on function public.join_match_queue_tx(p_org_id uuid, p_member uuid, p_queue uuid, p_join_source text) to anon, authenticated, service_role;

-- [8.0] join_session_tx:grant
grant execute on function public.join_session_tx(p_session_id uuid, p_member_id uuid, p_join_type text, p_coupon_ids uuid[], p_points_used bigint, p_payments jsonb, p_staff_id uuid, p_idempotency_key text, p_pay_for uuid[], p_items jsonb) to authenticated, service_role;

-- [8.0] leave_match_queue_tx:grant
grant execute on function public.leave_match_queue_tx(p_org_id uuid, p_member uuid, p_queue uuid, p_reason text) to anon, authenticated, service_role;

-- [8.0] like_player_tx:grant
grant execute on function public.like_player_tx(p_org_id uuid, p_liker uuid, p_target uuid, p_on boolean, p_session uuid) to anon, authenticated, service_role;

-- [8.0] list_blocks_tx:grant
grant execute on function public.list_blocks_tx(p_org_id uuid, p_member uuid) to anon, authenticated, service_role;

-- [8.0] list_buddies_tx:grant
grant execute on function public.list_buddies_tx(p_org_id uuid, p_member uuid) to anon, authenticated, service_role;

-- [8.0] list_daypass_tx:grant
grant execute on function public.list_daypass_tx(p_org_id uuid) to anon, authenticated, service_role;

-- [8.0] list_fee_menu_tx:grant
grant execute on function public.list_fee_menu_tx(p_org_id uuid) to anon, authenticated, service_role;

-- [8.0] list_match_queues_by_city_tx:grant
grant execute on function public.list_match_queues_by_city_tx(p_org_id uuid, p_member uuid, p_city text, p_area text) to anon, authenticated, service_role;

-- [8.0] list_match_queues_tx:grant
grant execute on function public.list_match_queues_tx(p_org_id uuid, p_member uuid, p_store uuid) to anon, authenticated, service_role;

-- [8.0] list_member_tiers_tx:grant
grant execute on function public.list_member_tiers_tx() to anon, authenticated, service_role;

-- [8.0] list_members_tx:grant
grant execute on function public.list_members_tx(p_org_id uuid, p_limit integer) to anon, authenticated, service_role;

-- [8.0] list_notifications_tx:grant
grant execute on function public.list_notifications_tx(p_org_id uuid, p_member uuid) to anon, authenticated, service_role;

-- [8.0] list_product_taxonomy_tx:grant
grant execute on function public.list_product_taxonomy_tx() to anon, authenticated, service_role;

-- [8.0] list_products_tx:grant
grant execute on function public.list_products_tx(p_org_id uuid) to anon, authenticated, service_role;

-- [8.0] list_queue_tags_tx:grant
grant execute on function public.list_queue_tags_tx() to anon, authenticated, service_role;

-- [8.0] list_rank_tiers_tx:grant
grant execute on function public.list_rank_tiers_tx() to anon, authenticated, service_role;

-- [8.0] list_recent_players_tx:grant
grant execute on function public.list_recent_players_tx(p_org_id uuid, p_member uuid) to anon, authenticated, service_role;

-- [8.0] list_staff_tx:grant
grant execute on function public.list_staff_tx(p_org_id uuid) to authenticated, service_role;

-- [8.0] list_stake_levels_tx:grant
grant execute on function public.list_stake_levels_tx(p_org_id uuid, p_store_id uuid) to anon, authenticated, service_role;

-- [8.0] list_stakes_tx:grant
grant execute on function public.list_stakes_tx(p_org_id uuid, p_store uuid) to anon, authenticated, service_role;

-- [8.0] list_stores_tx:grant
grant execute on function public.list_stores_tx(p_org_id uuid) to anon, authenticated, service_role;

-- [8.0] list_tables_tx:grant
grant execute on function public.list_tables_tx(p_org_id uuid, p_store_id uuid) to anon, authenticated, service_role;

-- [8.0] list_topup_plans_tx:grant
grant execute on function public.list_topup_plans_tx(p_org_id uuid, p_store_id uuid) to anon, authenticated, service_role;

-- [8.0] log_app_event_tx:grant
grant execute on function public.log_app_event_tx(p_org_id uuid, p_member_id uuid, p_event text, p_props jsonb, p_client_ts timestamp with time zone, p_store_id uuid) to anon, authenticated, service_role;

-- [8.0] mark_app_active_tx:grant
grant execute on function public.mark_app_active_tx(p_org_id uuid, p_member_id uuid) to anon, authenticated, service_role;

-- [8.0] mark_invoice_failed_tx:grant
grant execute on function public.mark_invoice_failed_tx(p_invoice_id uuid, p_raw jsonb) to anon, authenticated, service_role;

-- [8.0] mark_invoice_issued_tx:grant
grant execute on function public.mark_invoice_issued_tx(p_invoice_id uuid, p_invoice_no text, p_random text, p_period text, p_provider text, p_provider_ref text, p_raw jsonb, p_donate_org_name text) to anon, authenticated, service_role;

-- [8.0] mark_notifs_read_tx:grant
grant execute on function public.mark_notifs_read_tx(p_org_id uuid, p_member uuid) to anon, authenticated, service_role;

-- [8.0] member_opponents_tx:grant
grant execute on function public.member_opponents_tx(p_member_id uuid) to service_role;

-- [8.0] member_rank_tx:grant
grant execute on function public.member_rank_tx(p_member_id uuid) to service_role;

-- [8.0] member_tier_progress_tx:grant
grant execute on function public.member_tier_progress_tx(p_member_id uuid, p_org_id uuid) to service_role;

-- [8.0] migi_jwt_line_id:grant
grant execute on function public.migi_jwt_line_id() to authenticated, service_role;

-- [8.0] migi_jwt_uuid:grant
grant execute on function public.migi_jwt_uuid() to authenticated, service_role;

-- [8.0] migi_norm_nickname:grant
grant execute on function public.migi_norm_nickname(p text) to anon, authenticated, service_role;

-- [8.0] migi_norm_phone:grant
grant execute on function public.migi_norm_phone(p text) to anon, authenticated, service_role;

-- [8.0] migi_seat_is_live:grant
grant execute on function public.migi_seat_is_live(p_session uuid) to service_role;

-- [8.0] migi_slot_of:grant
grant execute on function public.migi_slot_of(p_at timestamp with time zone) to service_role;

-- [8.0] next_doc_no:grant
grant execute on function public.next_doc_no(p_org_id uuid, p_store_id uuid, p_doc_type text) to anon, authenticated, service_role;

-- [8.0] open_session_tx:grant
grant execute on function public.open_session_tx(p_table_id uuid, p_mode text, p_stake_level_id uuid, p_planned_rounds integer, p_planned_minutes integer, p_staff_id uuid, p_open_method text, p_idempotency_key text, p_game_type text, p_flower text) to anon, authenticated, service_role;

-- [8.0] otp_consume_tx:grant
grant execute on function public.otp_consume_tx(p_org_id uuid, p_phone text, p_line_user_id text, p_purpose text, p_member_id uuid) to service_role;

-- [8.0] otp_request_tx:grant
grant execute on function public.otp_request_tx(p_org_id uuid, p_phone text, p_purpose text, p_line_user_id text) to service_role;

-- [8.0] otp_verify_tx:grant
grant execute on function public.otp_verify_tx(p_org_id uuid, p_phone text, p_code text, p_purpose text) to service_role;

-- [8.0] payments_no_mutate:grant
grant execute on function public.payments_no_mutate() to anon, authenticated, service_role;

-- [8.0] phone_in_use_tx:grant
grant execute on function public.phone_in_use_tx(p_org_id uuid, p_phone text, p_line_user_id text) to service_role;

-- [8.0] phone_recently_verified_tx:grant
grant execute on function public.phone_recently_verified_tx(p_org_id uuid, p_phone text, p_line_user_id text, p_purpose text) to service_role;

-- [8.0] placeholder_ranks_tx:grant
grant execute on function public.placeholder_ranks_tx(p_session_id uuid) to service_role;

-- [8.0] pos_add_member_note_tx:grant
grant execute on function public.pos_add_member_note_tx(p_org_id uuid, p_member_id uuid, p_note text, p_staff_id uuid) to authenticated, service_role;

-- [8.0] pos_add_queue_member_tx:grant
grant execute on function public.pos_add_queue_member_tx(p_org uuid, p_queue uuid, p_member uuid, p_staff uuid) to authenticated, service_role;

-- [8.0] pos_addon_checkout_tx:grant
grant execute on function public.pos_addon_checkout_tx(p_session_id uuid, p_member_id uuid, p_items jsonb, p_coupon_ids uuid[], p_points_used bigint, p_payments jsonb, p_idempotency_key text, p_staff_id uuid) to authenticated, service_role;

-- [8.0] pos_checkout_with_topup_tx:grant
grant execute on function public.pos_checkout_with_topup_tx(p_session_id uuid, p_member_id uuid, p_join_type text, p_items jsonb, p_coupon_ids uuid[], p_points_used bigint, p_payments jsonb, p_pay_for uuid[], p_staff_id uuid, p_idempotency_key text, p_topup_points bigint, p_topup_bonus bigint, p_topup_amount bigint, p_topup_method text, p_topup_cash_received bigint, p_topup_change_given bigint) to authenticated, service_role;

-- [8.0] pos_close_queue_tx:grant
grant execute on function public.pos_close_queue_tx(p_org_id uuid, p_queue uuid) to authenticated, service_role;

-- [8.0] pos_create_queue_tx:grant
grant execute on function public.pos_create_queue_tx(p_org_id uuid, p_store uuid, p_stake uuid, p_play_at timestamp with time zone, p_game_type text, p_flower text, p_rounds text, p_seats integer, p_tags jsonb) to authenticated, service_role;

-- [8.0] pos_create_recurring_tx:grant
grant execute on function public.pos_create_recurring_tx(p_org_id uuid, p_store uuid, p_stake uuid, p_frequency text, p_weekday integer, p_start_time time without time zone, p_game_type text, p_flower text, p_rounds text, p_seats integer, p_lead_hours integer, p_tags jsonb) to authenticated, service_role;

-- [8.0] pos_list_queues_tx:grant
grant execute on function public.pos_list_queues_tx(p_org uuid, p_store uuid, p_before timestamp with time zone, p_limit integer) to authenticated, service_role;

-- [8.0] pos_list_recurring_tx:grant
grant execute on function public.pos_list_recurring_tx(p_org_id uuid, p_store uuid) to authenticated, service_role;

-- [8.0] pos_member_detail_tx:grant
grant execute on function public.pos_member_detail_tx(p_org_id uuid, p_member_id uuid) to authenticated, service_role;

-- [8.0] pos_member_orders_tx:grant
grant execute on function public.pos_member_orders_tx(p_member_id uuid, p_limit integer, p_before timestamp with time zone) to authenticated, service_role;

-- [8.0] pos_move_queue_member_tx:grant
grant execute on function public.pos_move_queue_member_tx(p_org uuid, p_from_queue uuid, p_to_queue uuid, p_member uuid) to authenticated, service_role;

-- [8.0] pos_move_session_tx:grant
grant execute on function public.pos_move_session_tx(p_session_id uuid, p_table_id uuid, p_staff_id uuid) to authenticated, service_role;

-- [8.0] pos_queue_members_tx:grant
grant execute on function public.pos_queue_members_tx(p_org_id uuid, p_queue uuid) to authenticated, service_role;

-- [8.0] pos_quick_checkout_tx:grant
grant execute on function public.pos_quick_checkout_tx(p_member_id uuid, p_store_id uuid, p_items jsonb, p_coupon_ids uuid[], p_points_used bigint, p_payments jsonb, p_idempotency_key text, p_staff_id uuid, p_topup_points bigint, p_topup_amount bigint, p_topup_method text, p_topup_cash_received bigint, p_topup_change_given bigint, p_note text) to authenticated, service_role;

-- [8.0] pos_remove_queue_member_tx:grant
grant execute on function public.pos_remove_queue_member_tx(p_org uuid, p_queue uuid, p_member uuid, p_reason text) to authenticated, service_role;

-- [8.0] pos_search_members_tx:grant
grant execute on function public.pos_search_members_tx(p_org_id uuid, p_keyword text) to authenticated, service_role;

-- [8.0] pos_seat_queue_tx:grant
grant execute on function public.pos_seat_queue_tx(p_org_id uuid, p_queue uuid, p_table_id uuid, p_staff_id uuid) to authenticated, service_role;

-- [8.0] pos_set_recurring_enabled_tx:grant
grant execute on function public.pos_set_recurring_enabled_tx(p_org_id uuid, p_id uuid, p_enabled boolean) to authenticated, service_role;

-- [8.0] pos_set_recurring_tags_tx:grant
grant execute on function public.pos_set_recurring_tags_tx(p_org_id uuid, p_id uuid, p_tags jsonb) to authenticated, service_role;

-- [8.0] pos_table_forecast_tx:grant
grant execute on function public.pos_table_forecast_tx(p_org uuid, p_store uuid, p_at timestamp with time zone) to authenticated, service_role;

-- [8.0] prevent_org_change:grant
grant execute on function public.prevent_org_change() to anon, authenticated, service_role;

-- [8.0] rank_detail_tx:grant
grant execute on function public.rank_detail_tx(p_rating integer) to anon, authenticated, service_role;

-- [8.0] rank_from_rating:grant
grant execute on function public.rank_from_rating(p_rating integer) to anon, authenticated, service_role;

-- [8.0] rating_window_start_tx:grant
grant execute on function public.rating_window_start_tx(p_org_id uuid) to service_role;

-- [8.0] rebind_line_user_tx:grant
grant execute on function public.rebind_line_user_tx(p_member_id uuid, p_new_line_user_id text, p_reason text) to authenticated, service_role;

-- [8.0] recalc_member_tier_tx:grant
grant execute on function public.recalc_member_tier_tx(p_member_id uuid) to service_role;

-- [8.0] reconcile_wallets_tx:grant
grant execute on function public.reconcile_wallets_tx(p_org_id uuid) to authenticated, service_role;

-- [8.0] register_member_tx:grant
grant execute on function public.register_member_tx(p_org_id uuid, p_display_name text, p_phone text, p_line_user_id text, p_home_store_id uuid, p_created_by uuid) to service_role;

-- [8.0] remove_buddy_tx:grant
grant execute on function public.remove_buddy_tx(p_org_id uuid, p_member uuid, p_buddy uuid) to anon, authenticated, service_role;

-- [8.0] reset_season_ratings_tx:grant
grant execute on function public.reset_season_ratings_tx(p_org_id uuid, p_season text, p_drop_tiers integer) to service_role;

-- [8.0] respond_buddy_invite_tx:grant
grant execute on function public.respond_buddy_invite_tx(p_org_id uuid, p_invitee uuid, p_inviter uuid, p_accept boolean) to anon, authenticated, service_role;

-- [8.0] respond_table_invite_tx:grant
grant execute on function public.respond_table_invite_tx(p_org_id uuid, p_invitee uuid, p_queue uuid, p_accept boolean) to anon, authenticated, service_role;

-- [8.0] reverse_txn_tx:grant
grant execute on function public.reverse_txn_tx(p_original_txn_id uuid, p_idempotency_key text, p_reason text) to service_role;

-- [8.0] revoke_staff_tx:grant
grant execute on function public.revoke_staff_tx(p_staff_id uuid) to authenticated, service_role;

-- [8.0] save_app_state_tx:grant
grant execute on function public.save_app_state_tx(p_org_id uuid, p_member_id uuid, p_bear jsonb, p_titles jsonb) to anon, authenticated, service_role;

-- [8.0] season_rank_rows_tx:grant
grant execute on function public.season_rank_rows_tx(p_org_id uuid, p_from timestamp with time zone, p_to timestamp with time zone) to service_role;

-- [8.0] send_buddy_invite_tx:grant
grant execute on function public.send_buddy_invite_tx(p_org_id uuid, p_inviter uuid, p_invitee uuid) to anon, authenticated, service_role;

-- [8.0] send_table_invite_tx:grant
grant execute on function public.send_table_invite_tx(p_org_id uuid, p_inviter uuid, p_invitee uuid, p_queue uuid) to anon, authenticated, service_role;

-- [8.0] set_avatar_tx:grant
grant execute on function public.set_avatar_tx(p_member_id uuid, p_source text, p_path text, p_bear text) to anon, authenticated, service_role;

-- [8.0] set_invoice_pref_tx:grant
grant execute on function public.set_invoice_pref_tx(p_member_id uuid, p_type text, p_carrier text, p_donate_code text, p_tax_id text, p_title text) to service_role;

-- [8.0] set_is_test_from_store:grant
grant execute on function public.set_is_test_from_store() to anon, authenticated, service_role;

-- [8.0] set_line_avatar_tx:grant
grant execute on function public.set_line_avatar_tx(p_member_id uuid, p_url text) to service_role;

-- [8.0] set_member_phone_tx:grant
grant execute on function public.set_member_phone_tx(p_org_id uuid, p_line_user_id text, p_phone text) to service_role;

-- [8.0] set_my_about_tx:grant
grant execute on function public.set_my_about_tx(p_org_id uuid, p_member_id uuid, p_about text) to anon, authenticated, service_role;

-- [8.0] set_my_availability_tx:grant
grant execute on function public.set_my_availability_tx(p_org_id uuid, p_member_id uuid, p_slots jsonb) to anon, authenticated, service_role;

-- [8.0] set_my_baby_tile_tx:grant
grant execute on function public.set_my_baby_tile_tx(p_org_id uuid, p_member_id uuid, p_baby_tile jsonb) to anon, authenticated, service_role;

-- [8.0] set_my_birthday_tx:grant
grant execute on function public.set_my_birthday_tx(p_org_id uuid, p_member_id uuid, p_birthday date) to anon, authenticated, service_role;

-- [8.0] set_my_home_store_tx:grant
grant execute on function public.set_my_home_store_tx(p_org_id uuid, p_member_id uuid, p_store_id uuid) to anon, authenticated, service_role;

-- [8.0] set_my_nickname_tx:grant
grant execute on function public.set_my_nickname_tx(p_org_id uuid, p_member_id uuid, p_nickname text) to anon, authenticated, service_role;

-- [8.0] set_my_profile_basics_tx:grant
grant execute on function public.set_my_profile_basics_tx(p_org_id uuid, p_member_id uuid, p_birthday date, p_gender text) to anon, authenticated, service_role;

-- [8.0] set_my_sched_tx:grant
grant execute on function public.set_my_sched_tx(p_org_id uuid, p_member_id uuid, p_sched text) to anon, authenticated, service_role;

-- [8.0] set_my_see_score_tx:grant
grant execute on function public.set_my_see_score_tx(p_org_id uuid, p_member_id uuid, p_see_score text) to anon, authenticated, service_role;

-- [8.0] set_my_style_tx:grant
grant execute on function public.set_my_style_tx(p_org_id uuid, p_member_id uuid, p_style jsonb) to anon, authenticated, service_role;

-- [8.0] set_my_title_tx:grant
grant execute on function public.set_my_title_tx(p_org_id uuid, p_member_id uuid, p_title text) to anon, authenticated, service_role;

-- [8.0] set_table_active_tx:grant
grant execute on function public.set_table_active_tx(p_table_id uuid, p_active boolean, p_note text) to anon, authenticated, service_role;

-- [8.0] set_table_auto_assign_tx:grant
grant execute on function public.set_table_auto_assign_tx(p_table_id uuid, p_auto boolean) to anon, authenticated, service_role;

-- [8.0] set_updated_at:grant
grant execute on function public.set_updated_at() to anon, authenticated, service_role;

-- [8.0] settle_session_tx:grant
grant execute on function public.settle_session_tx(p_session_id uuid, p_staff_id uuid, p_keep_for_walkin boolean) to authenticated, service_role;

-- [8.0] sweep_auto_seat_tx:grant
grant execute on function public.sweep_auto_seat_tx(p_org uuid) to authenticated, service_role;

-- [8.0] sweep_expired_queues_tx:grant
grant execute on function public.sweep_expired_queues_tx(p_org_id uuid) to authenticated, service_role;

-- [8.0] topup_tx:grant
grant execute on function public.topup_tx(p_member_id uuid, p_store_id uuid, p_points bigint, p_amount_twd bigint, p_pay_method text, p_idempotency_key text, p_bonus_points bigint, p_external_ref text, p_staff_id uuid, p_note text) to authenticated, service_role;

-- [8.0] topup_void_tx:grant
grant execute on function public.topup_void_tx(p_topup_id uuid, p_idempotency_key text, p_staff_id uuid, p_reason text) to authenticated, service_role;

-- [8.0] trg_coupon_set_code:grant
grant execute on function public.trg_coupon_set_code() to anon, authenticated, service_role;

-- [8.0] trg_members_norm_display_name:grant
grant execute on function public.trg_members_norm_display_name() to anon, authenticated, service_role;

-- [8.0] trg_orders_set_no:grant
grant execute on function public.trg_orders_set_no() to anon, authenticated, service_role;

-- [8.0] trg_orders_touch_member_visit:grant
grant execute on function public.trg_orders_touch_member_visit() to anon, authenticated, service_role;

-- [8.0] trg_orders_upgrade_tier:grant
grant execute on function public.trg_orders_upgrade_tier() to anon, authenticated, service_role;

-- [8.0] trg_session_voided_release_queue:grant
grant execute on function public.trg_session_voided_release_queue() to anon, authenticated, service_role;

-- [8.0] trg_topup_set_no:grant
grant execute on function public.trg_topup_set_no() to anon, authenticated, service_role;

-- [8.0] unblock_member_tx:grant
grant execute on function public.unblock_member_tx(p_org_id uuid, p_blocker uuid, p_blocked uuid) to anon, authenticated, service_role;

-- [8.0] unread_count_tx:grant
grant execute on function public.unread_count_tx(p_org_id uuid, p_member uuid) to anon, authenticated, service_role;

-- [8.0] update_play_at_tx:grant
grant execute on function public.update_play_at_tx(p_org_id uuid, p_queue uuid, p_new_play_at timestamp with time zone) to anon, authenticated, service_role;

-- [8.0] void_invoice_tx:grant
grant execute on function public.void_invoice_tx(p_invoice_id uuid, p_reason text, p_reissue boolean, p_idempotency_key text) to service_role;

-- [8.0] void_session_tx:grant
grant execute on function public.void_session_tx(p_session_id uuid, p_staff_id uuid) to authenticated, service_role;

-- [8.1] _charge_core:revoke-public
revoke execute on function public._charge_core(p_member_id uuid, p_amount bigint, p_type txn_type, p_idempotency_key text, p_store_id uuid, p_served_store_id uuid, p_staff_id uuid, p_ref_table text, p_ref_id uuid, p_counter text) from public;

-- [8.1] _member_orders_core:revoke-public
revoke execute on function public._member_orders_core(p_member_id uuid, p_limit integer, p_before timestamp with time zone) from public;

-- [8.1] admin_delete_product_tx:revoke-public
revoke execute on function public.admin_delete_product_tx(p_id uuid) from public;

-- [8.1] admin_list_member_tiers_tx:revoke-public
revoke execute on function public.admin_list_member_tiers_tx() from public;

-- [8.1] admin_list_products_tx:revoke-public
revoke execute on function public.admin_list_products_tx() from public;

-- [8.1] admin_remove_avatar_tx:revoke-public
revoke execute on function public.admin_remove_avatar_tx(p_member_id uuid, p_reason text, p_block boolean) from public;

-- [8.1] admin_search_sessions_tx:revoke-public
revoke execute on function public.admin_search_sessions_tx(p_from timestamp with time zone, p_to timestamp with time zone, p_store uuid, p_table_q text, p_member_q text, p_limit integer, p_before timestamp with time zone, p_before_id uuid) from public;

-- [8.1] admin_set_product_active_tx:revoke-public
revoke execute on function public.admin_set_product_active_tx(p_id uuid, p_is_active boolean) from public;

-- [8.1] admin_update_member_tier_tx:revoke-public
revoke execute on function public.admin_update_member_tier_tx(p_code text, p_label text, p_discount_pct integer, p_threshold_amount bigint, p_is_active boolean) from public;

-- [8.1] admin_upsert_product_tx:revoke-public
revoke execute on function public.admin_upsert_product_tx(p_id uuid, p_sku text, p_name text, p_category text, p_subcategory text, p_revenue_type text, p_tracks_stock boolean, p_unit_price integer, p_unit_cost integer, p_stock_qty integer, p_is_active boolean, p_is_available boolean, p_spec text) from public;

-- [8.1] apply_session_rounds_tx:revoke-public
revoke execute on function public.apply_session_rounds_tx(p_session_id uuid, p_rounds jsonb) from public;

-- [8.1] calc_session_fee_tx:revoke-public
revoke execute on function public.calc_session_fee_tx(p_session_id uuid, p_join_type text, p_member_id uuid) from public;

-- [8.1] calc_topup_bonus_tx:revoke-public
revoke execute on function public.calc_topup_bonus_tx(p_org_id uuid, p_store_id uuid, p_amount_twd bigint) from public;

-- [8.1] can:revoke-public
revoke execute on function public.can(p_perm text) from public;

-- [8.1] charge_fnb_tx:revoke-public
revoke execute on function public.charge_fnb_tx(p_member_id uuid, p_order_id uuid, p_points bigint, p_idempotency_key text, p_store_id uuid) from public;

-- [8.1] charge_matched_tx:revoke-public
revoke execute on function public.charge_matched_tx(p_member_id uuid, p_session_id uuid, p_join_type text, p_idempotency_key text, p_store_id uuid, p_staff_id uuid) from public;

-- [8.1] charge_private_tx:revoke-public
revoke execute on function public.charge_private_tx(p_member_id uuid, p_session_id uuid, p_minutes integer, p_idempotency_key text, p_store_id uuid, p_staff_id uuid) from public;

-- [8.1] check_session_blocks_tx:revoke-public
revoke execute on function public.check_session_blocks_tx(p_session_id uuid, p_member_id uuid) from public;

-- [8.1] checkout_tx:revoke-public
revoke execute on function public.checkout_tx(p_member_id uuid, p_store_id uuid, p_items jsonb, p_coupon_ids uuid[], p_points_used bigint, p_payments jsonb, p_idempotency_key text, p_staff_id uuid) from public;

-- [8.1] claim_member_by_phone_tx:revoke-public
revoke execute on function public.claim_member_by_phone_tx(p_org_id uuid, p_phone text, p_line_user_id text, p_purpose text) from public;

-- [8.1] cleanup_empty_sessions_tx:revoke-public
revoke execute on function public.cleanup_empty_sessions_tx(p_idle_minutes integer) from public;

-- [8.1] clear_avatar_photo_tx:revoke-public
revoke execute on function public.clear_avatar_photo_tx(p_member_id uuid) from public;

-- [8.1] current_season_tx:revoke-public
revoke execute on function public.current_season_tx(p_org_id uuid) from public;

-- [8.1] daily_wallet_audit_tx:revoke-public
revoke execute on function public.daily_wallet_audit_tx(p_org_id uuid) from public;

-- [8.1] dev_clear_my_queues_tx:revoke-public
revoke execute on function public.dev_clear_my_queues_tx(p_org_id uuid, p_member uuid) from public;

-- [8.1] dev_reset_test_data_tx:revoke-public
revoke execute on function public.dev_reset_test_data_tx(p_reset_balance bigint) from public;

-- [8.1] dev_set_test_balance_tx:revoke-public
revoke execute on function public.dev_set_test_balance_tx(p_display_name text, p_balance bigint) from public;

-- [8.1] fix_wallet_balance_tx:revoke-public
revoke execute on function public.fix_wallet_balance_tx(p_org_id uuid, p_member_id uuid) from public;

-- [8.1] generate_recurring_instances_tx:revoke-public
revoke execute on function public.generate_recurring_instances_tx(p_org_id uuid, p_days_ahead integer) from public;

-- [8.1] get_member_by_line_tx:revoke-public
revoke execute on function public.get_member_by_line_tx(p_org_id uuid, p_line_user_id text) from public;

-- [8.1] get_my_avatar_tx:revoke-public
revoke execute on function public.get_my_avatar_tx(p_member_id uuid) from public;

-- [8.1] get_season_leaderboard_tx:revoke-public
revoke execute on function public.get_season_leaderboard_tx(p_org_id uuid, p_limit integer) from public;

-- [8.1] get_session_member_orders_tx:revoke-public
revoke execute on function public.get_session_member_orders_tx(p_session_id uuid, p_member_id uuid) from public;

-- [8.1] get_staff_by_line_tx:revoke-public
revoke execute on function public.get_staff_by_line_tx(p_org_id uuid, p_line_user_id text) from public;

-- [8.1] grant_staff_tx:revoke-public
revoke execute on function public.grant_staff_tx(p_member_id uuid, p_store_id uuid, p_role text, p_name text) from public;

-- [8.1] has_daypass_tx:revoke-public
revoke execute on function public.has_daypass_tx(p_org_id uuid, p_member_id uuid, p_store_id uuid) from public;

-- [8.1] has_store_access:revoke-public
revoke execute on function public.has_store_access(p_store_id uuid) from public;

-- [8.1] join_session_tx:revoke-public
revoke execute on function public.join_session_tx(p_session_id uuid, p_member_id uuid, p_join_type text, p_coupon_ids uuid[], p_points_used bigint, p_payments jsonb, p_staff_id uuid, p_idempotency_key text, p_pay_for uuid[], p_items jsonb) from public;

-- [8.1] list_staff_tx:revoke-public
revoke execute on function public.list_staff_tx(p_org_id uuid) from public;

-- [8.1] member_opponents_tx:revoke-public
revoke execute on function public.member_opponents_tx(p_member_id uuid) from public;

-- [8.1] member_rank_tx:revoke-public
revoke execute on function public.member_rank_tx(p_member_id uuid) from public;

-- [8.1] member_tier_progress_tx:revoke-public
revoke execute on function public.member_tier_progress_tx(p_member_id uuid, p_org_id uuid) from public;

-- [8.1] migi_jwt_line_id:revoke-public
revoke execute on function public.migi_jwt_line_id() from public;

-- [8.1] migi_jwt_uuid:revoke-public
revoke execute on function public.migi_jwt_uuid() from public;

-- [8.1] migi_seat_is_live:revoke-public
revoke execute on function public.migi_seat_is_live(p_session uuid) from public;

-- [8.1] migi_slot_of:revoke-public
revoke execute on function public.migi_slot_of(p_at timestamp with time zone) from public;

-- [8.1] otp_consume_tx:revoke-public
revoke execute on function public.otp_consume_tx(p_org_id uuid, p_phone text, p_line_user_id text, p_purpose text, p_member_id uuid) from public;

-- [8.1] otp_request_tx:revoke-public
revoke execute on function public.otp_request_tx(p_org_id uuid, p_phone text, p_purpose text, p_line_user_id text) from public;

-- [8.1] otp_verify_tx:revoke-public
revoke execute on function public.otp_verify_tx(p_org_id uuid, p_phone text, p_code text, p_purpose text) from public;

-- [8.1] phone_in_use_tx:revoke-public
revoke execute on function public.phone_in_use_tx(p_org_id uuid, p_phone text, p_line_user_id text) from public;

-- [8.1] phone_recently_verified_tx:revoke-public
revoke execute on function public.phone_recently_verified_tx(p_org_id uuid, p_phone text, p_line_user_id text, p_purpose text) from public;

-- [8.1] placeholder_ranks_tx:revoke-public
revoke execute on function public.placeholder_ranks_tx(p_session_id uuid) from public;

-- [8.1] pos_add_member_note_tx:revoke-public
revoke execute on function public.pos_add_member_note_tx(p_org_id uuid, p_member_id uuid, p_note text, p_staff_id uuid) from public;

-- [8.1] pos_add_queue_member_tx:revoke-public
revoke execute on function public.pos_add_queue_member_tx(p_org uuid, p_queue uuid, p_member uuid, p_staff uuid) from public;

-- [8.1] pos_addon_checkout_tx:revoke-public
revoke execute on function public.pos_addon_checkout_tx(p_session_id uuid, p_member_id uuid, p_items jsonb, p_coupon_ids uuid[], p_points_used bigint, p_payments jsonb, p_idempotency_key text, p_staff_id uuid) from public;

-- [8.1] pos_checkout_with_topup_tx:revoke-public
revoke execute on function public.pos_checkout_with_topup_tx(p_session_id uuid, p_member_id uuid, p_join_type text, p_items jsonb, p_coupon_ids uuid[], p_points_used bigint, p_payments jsonb, p_pay_for uuid[], p_staff_id uuid, p_idempotency_key text, p_topup_points bigint, p_topup_bonus bigint, p_topup_amount bigint, p_topup_method text, p_topup_cash_received bigint, p_topup_change_given bigint) from public;

-- [8.1] pos_close_queue_tx:revoke-public
revoke execute on function public.pos_close_queue_tx(p_org_id uuid, p_queue uuid) from public;

-- [8.1] pos_create_queue_tx:revoke-public
revoke execute on function public.pos_create_queue_tx(p_org_id uuid, p_store uuid, p_stake uuid, p_play_at timestamp with time zone, p_game_type text, p_flower text, p_rounds text, p_seats integer, p_tags jsonb) from public;

-- [8.1] pos_create_recurring_tx:revoke-public
revoke execute on function public.pos_create_recurring_tx(p_org_id uuid, p_store uuid, p_stake uuid, p_frequency text, p_weekday integer, p_start_time time without time zone, p_game_type text, p_flower text, p_rounds text, p_seats integer, p_lead_hours integer, p_tags jsonb) from public;

-- [8.1] pos_list_queues_tx:revoke-public
revoke execute on function public.pos_list_queues_tx(p_org uuid, p_store uuid, p_before timestamp with time zone, p_limit integer) from public;

-- [8.1] pos_list_recurring_tx:revoke-public
revoke execute on function public.pos_list_recurring_tx(p_org_id uuid, p_store uuid) from public;

-- [8.1] pos_member_detail_tx:revoke-public
revoke execute on function public.pos_member_detail_tx(p_org_id uuid, p_member_id uuid) from public;

-- [8.1] pos_member_orders_tx:revoke-public
revoke execute on function public.pos_member_orders_tx(p_member_id uuid, p_limit integer, p_before timestamp with time zone) from public;

-- [8.1] pos_move_queue_member_tx:revoke-public
revoke execute on function public.pos_move_queue_member_tx(p_org uuid, p_from_queue uuid, p_to_queue uuid, p_member uuid) from public;

-- [8.1] pos_move_session_tx:revoke-public
revoke execute on function public.pos_move_session_tx(p_session_id uuid, p_table_id uuid, p_staff_id uuid) from public;

-- [8.1] pos_queue_members_tx:revoke-public
revoke execute on function public.pos_queue_members_tx(p_org_id uuid, p_queue uuid) from public;

-- [8.1] pos_quick_checkout_tx:revoke-public
revoke execute on function public.pos_quick_checkout_tx(p_member_id uuid, p_store_id uuid, p_items jsonb, p_coupon_ids uuid[], p_points_used bigint, p_payments jsonb, p_idempotency_key text, p_staff_id uuid, p_topup_points bigint, p_topup_amount bigint, p_topup_method text, p_topup_cash_received bigint, p_topup_change_given bigint, p_note text) from public;

-- [8.1] pos_remove_queue_member_tx:revoke-public
revoke execute on function public.pos_remove_queue_member_tx(p_org uuid, p_queue uuid, p_member uuid, p_reason text) from public;

-- [8.1] pos_search_members_tx:revoke-public
revoke execute on function public.pos_search_members_tx(p_org_id uuid, p_keyword text) from public;

-- [8.1] pos_seat_queue_tx:revoke-public
revoke execute on function public.pos_seat_queue_tx(p_org_id uuid, p_queue uuid, p_table_id uuid, p_staff_id uuid) from public;

-- [8.1] pos_set_recurring_enabled_tx:revoke-public
revoke execute on function public.pos_set_recurring_enabled_tx(p_org_id uuid, p_id uuid, p_enabled boolean) from public;

-- [8.1] pos_set_recurring_tags_tx:revoke-public
revoke execute on function public.pos_set_recurring_tags_tx(p_org_id uuid, p_id uuid, p_tags jsonb) from public;

-- [8.1] pos_table_forecast_tx:revoke-public
revoke execute on function public.pos_table_forecast_tx(p_org uuid, p_store uuid, p_at timestamp with time zone) from public;

-- [8.1] rating_window_start_tx:revoke-public
revoke execute on function public.rating_window_start_tx(p_org_id uuid) from public;

-- [8.1] rebind_line_user_tx:revoke-public
revoke execute on function public.rebind_line_user_tx(p_member_id uuid, p_new_line_user_id text, p_reason text) from public;

-- [8.1] recalc_member_tier_tx:revoke-public
revoke execute on function public.recalc_member_tier_tx(p_member_id uuid) from public;

-- [8.1] reconcile_wallets_tx:revoke-public
revoke execute on function public.reconcile_wallets_tx(p_org_id uuid) from public;

-- [8.1] register_member_tx:revoke-public
revoke execute on function public.register_member_tx(p_org_id uuid, p_display_name text, p_phone text, p_line_user_id text, p_home_store_id uuid, p_created_by uuid) from public;

-- [8.1] reset_season_ratings_tx:revoke-public
revoke execute on function public.reset_season_ratings_tx(p_org_id uuid, p_season text, p_drop_tiers integer) from public;

-- [8.1] reverse_txn_tx:revoke-public
revoke execute on function public.reverse_txn_tx(p_original_txn_id uuid, p_idempotency_key text, p_reason text) from public;

-- [8.1] revoke_staff_tx:revoke-public
revoke execute on function public.revoke_staff_tx(p_staff_id uuid) from public;

-- [8.1] season_rank_rows_tx:revoke-public
revoke execute on function public.season_rank_rows_tx(p_org_id uuid, p_from timestamp with time zone, p_to timestamp with time zone) from public;

-- [8.1] set_invoice_pref_tx:revoke-public
revoke execute on function public.set_invoice_pref_tx(p_member_id uuid, p_type text, p_carrier text, p_donate_code text, p_tax_id text, p_title text) from public;

-- [8.1] set_line_avatar_tx:revoke-public
revoke execute on function public.set_line_avatar_tx(p_member_id uuid, p_url text) from public;

-- [8.1] set_member_phone_tx:revoke-public
revoke execute on function public.set_member_phone_tx(p_org_id uuid, p_line_user_id text, p_phone text) from public;

-- [8.1] settle_session_tx:revoke-public
revoke execute on function public.settle_session_tx(p_session_id uuid, p_staff_id uuid, p_keep_for_walkin boolean) from public;

-- [8.1] sweep_auto_seat_tx:revoke-public
revoke execute on function public.sweep_auto_seat_tx(p_org uuid) from public;

-- [8.1] sweep_expired_queues_tx:revoke-public
revoke execute on function public.sweep_expired_queues_tx(p_org_id uuid) from public;

-- [8.1] topup_tx:revoke-public
revoke execute on function public.topup_tx(p_member_id uuid, p_store_id uuid, p_points bigint, p_amount_twd bigint, p_pay_method text, p_idempotency_key text, p_bonus_points bigint, p_external_ref text, p_staff_id uuid, p_note text) from public;

-- [8.1] topup_void_tx:revoke-public
revoke execute on function public.topup_void_tx(p_topup_id uuid, p_idempotency_key text, p_staff_id uuid, p_reason text) from public;

-- [8.1] void_invoice_tx:revoke-public
revoke execute on function public.void_invoice_tx(p_invoice_id uuid, p_reason text, p_reissue boolean, p_idempotency_key text) from public;

-- [8.1] void_session_tx:revoke-public
revoke execute on function public.void_session_tx(p_session_id uuid, p_staff_id uuid) from public;

-- [9.0] members_norm_display_name
CREATE TRIGGER members_norm_display_name BEFORE INSERT OR UPDATE OF display_name ON public.members FOR EACH ROW EXECUTE FUNCTION trg_members_norm_display_name();

-- [9.0] trg_app_events_no_mutate
CREATE TRIGGER trg_app_events_no_mutate BEFORE DELETE OR UPDATE ON public.app_events FOR EACH ROW EXECUTE FUNCTION app_events_no_mutate();

-- [9.0] trg_avail_updated
CREATE TRIGGER trg_avail_updated BEFORE UPDATE ON public.member_availability FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- [9.0] trg_bonus_org
CREATE TRIGGER trg_bonus_org BEFORE UPDATE ON public.bonus_rules FOR EACH ROW EXECUTE FUNCTION prevent_org_change();

-- [9.0] trg_bonus_updated
CREATE TRIGGER trg_bonus_updated BEFORE UPDATE ON public.bonus_rules FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- [9.0] trg_coupon_code
CREATE TRIGGER trg_coupon_code BEFORE INSERT ON public.member_coupons FOR EACH ROW EXECUTE FUNCTION trg_coupon_set_code();

-- [9.0] trg_coupons_org
CREATE TRIGGER trg_coupons_org BEFORE UPDATE ON public.coupons FOR EACH ROW EXECUTE FUNCTION prevent_org_change();

-- [9.0] trg_coupons_updated
CREATE TRIGGER trg_coupons_updated BEFORE UPDATE ON public.coupons FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- [9.0] trg_members_org
CREATE TRIGGER trg_members_org BEFORE UPDATE ON public.members FOR EACH ROW EXECUTE FUNCTION prevent_org_change();

-- [9.0] trg_members_updated
CREATE TRIGGER trg_members_updated BEFORE UPDATE ON public.members FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- [9.0] trg_members_wallet
CREATE TRIGGER trg_members_wallet AFTER INSERT ON public.members FOR EACH ROW EXECUTE FUNCTION create_wallet_for_member();

-- [9.0] trg_orders_is_test
CREATE TRIGGER trg_orders_is_test BEFORE INSERT ON public.orders FOR EACH ROW EXECUTE FUNCTION set_is_test_from_store();

-- [9.0] trg_orders_no
CREATE TRIGGER trg_orders_no BEFORE INSERT ON public.orders FOR EACH ROW EXECUTE FUNCTION trg_orders_set_no();

-- [9.0] trg_orders_org
CREATE TRIGGER trg_orders_org BEFORE UPDATE ON public.orders FOR EACH ROW EXECUTE FUNCTION prevent_org_change();

-- [9.0] trg_orders_touch_visit
CREATE TRIGGER trg_orders_touch_visit AFTER INSERT ON public.orders FOR EACH ROW WHEN (((new.status = 'paid'::text) AND (new.member_id IS NOT NULL))) EXECUTE FUNCTION trg_orders_touch_member_visit();

-- [9.0] trg_orders_updated
CREATE TRIGGER trg_orders_updated BEFORE UPDATE ON public.orders FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- [9.0] trg_orders_upgrade_tier
CREATE TRIGGER trg_orders_upgrade_tier AFTER INSERT OR UPDATE OF status ON public.orders FOR EACH ROW WHEN (((new.status = 'paid'::text) AND (new.member_id IS NOT NULL))) EXECUTE FUNCTION trg_orders_upgrade_tier();

-- [9.0] trg_orgs_updated
CREATE TRIGGER trg_orgs_updated BEFORE UPDATE ON public.orgs FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- [9.0] trg_payments_no_delete
CREATE TRIGGER trg_payments_no_delete BEFORE DELETE OR UPDATE ON public.order_payments FOR EACH ROW EXECUTE FUNCTION payments_no_mutate();

-- [9.0] trg_pricing_org
CREATE TRIGGER trg_pricing_org BEFORE UPDATE ON public.pricing_tiers FOR EACH ROW EXECUTE FUNCTION prevent_org_change();

-- [9.0] trg_pricing_updated
CREATE TRIGGER trg_pricing_updated BEFORE UPDATE ON public.pricing_tiers FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- [9.0] trg_products_org
CREATE TRIGGER trg_products_org BEFORE UPDATE ON public.products FOR EACH ROW EXECUTE FUNCTION prevent_org_change();

-- [9.0] trg_products_updated
CREATE TRIGGER trg_products_updated BEFORE UPDATE ON public.products FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- [9.0] trg_session_voided_release_queue
CREATE TRIGGER trg_session_voided_release_queue AFTER UPDATE OF status ON public.table_sessions FOR EACH ROW WHEN (((new.status = 'voided'::text) AND (old.status IS DISTINCT FROM 'voided'::text))) EXECUTE FUNCTION trg_session_voided_release_queue();

-- [9.0] trg_sessions_is_test
CREATE TRIGGER trg_sessions_is_test BEFORE INSERT ON public.table_sessions FOR EACH ROW EXECUTE FUNCTION set_is_test_from_store();

-- [9.0] trg_sessions_org
CREATE TRIGGER trg_sessions_org BEFORE UPDATE ON public.table_sessions FOR EACH ROW EXECUTE FUNCTION prevent_org_change();

-- [9.0] trg_sessions_updated
CREATE TRIGGER trg_sessions_updated BEFORE UPDATE ON public.table_sessions FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- [9.0] trg_staff_org
CREATE TRIGGER trg_staff_org BEFORE UPDATE ON public.staff FOR EACH ROW EXECUTE FUNCTION prevent_org_change();

-- [9.0] trg_staff_updated
CREATE TRIGGER trg_staff_updated BEFORE UPDATE ON public.staff FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- [9.0] trg_stake_org
CREATE TRIGGER trg_stake_org BEFORE UPDATE ON public.stake_levels FOR EACH ROW EXECUTE FUNCTION prevent_org_change();

-- [9.0] trg_stake_updated
CREATE TRIGGER trg_stake_updated BEFORE UPDATE ON public.stake_levels FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- [9.0] trg_stores_org
CREATE TRIGGER trg_stores_org BEFORE UPDATE ON public.stores FOR EACH ROW EXECUTE FUNCTION prevent_org_change();

-- [9.0] trg_stores_updated
CREATE TRIGGER trg_stores_updated BEFORE UPDATE ON public.stores FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- [9.0] trg_tables_org
CREATE TRIGGER trg_tables_org BEFORE UPDATE ON public.tables FOR EACH ROW EXECUTE FUNCTION prevent_org_change();

-- [9.0] trg_tables_updated
CREATE TRIGGER trg_tables_updated BEFORE UPDATE ON public.tables FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- [9.0] trg_topup_no
CREATE TRIGGER trg_topup_no BEFORE INSERT ON public.topup_orders FOR EACH ROW EXECUTE FUNCTION trg_topup_set_no();

-- [9.0] trg_txn_no_delete
CREATE TRIGGER trg_txn_no_delete BEFORE DELETE ON public.wallet_txns FOR EACH ROW EXECUTE FUNCTION block_txn_mutation();

-- [9.0] trg_txn_no_update
CREATE TRIGGER trg_txn_no_update BEFORE UPDATE ON public.wallet_txns FOR EACH ROW EXECUTE FUNCTION block_txn_mutation();

-- [9.0] trg_wallet_balance_audit
CREATE TRIGGER trg_wallet_balance_audit AFTER UPDATE OF balance ON public.wallets FOR EACH ROW EXECUTE FUNCTION audit_wallet_balance();

-- [9.0] trg_wallets_updated
CREATE TRIGGER trg_wallets_updated BEFORE UPDATE ON public.wallets FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- [10.0] v_app_daily_active
create or replace view v_app_daily_active as 
 SELECT e.org_id,
    (e.created_at AT TIME ZONE 'Asia/Taipei'::text)::date AS biz_date,
    count(DISTINCT e.member_id) AS active_members,
    count(*) FILTER (WHERE e.event = 'app_open'::text) AS app_opens
   FROM app_events e
     JOIN members m ON m.id = e.member_id
  WHERE e.member_id IS NOT NULL AND m.is_test = false
  GROUP BY e.org_id, ((e.created_at AT TIME ZONE 'Asia/Taipei'::text)::date);

-- [10.0] v_entity_settlement
create or replace view v_entity_settlement as 
 WITH ord AS (
         SELECT date_trunc('month'::text, o_1.created_at)::date AS "月份",
            o_1.entity_id,
            o_1.store_id,
            count(*) AS "訂單數",
            COALESCE(sum(o_1.payable), 0::numeric) AS "服務營業額",
            COALESCE(sum(o_1.points_used), 0::numeric) AS "錢包支付",
            COALESCE(sum(o_1.cash_due), 0::numeric) AS "現場收款",
            COALESCE(sum(o_1.coupon_discount), 0::numeric) AS "優惠券折抵",
            COALESCE(sum(o_1.tier_discount), 0::numeric) AS "會員折扣"
           FROM orders o_1
          WHERE o_1.status = 'paid'::text AND o_1.deleted_at IS NULL AND o_1.is_test = false
          GROUP BY (date_trunc('month'::text, o_1.created_at)::date), o_1.entity_id, o_1.store_id
        ), tp AS (
         SELECT date_trunc('month'::text, t_1.created_at)::date AS "月份",
            t_1.entity_id,
            t_1.store_id,
            count(*) AS "儲值筆數",
            COALESCE(sum(t_1.amount_twd), 0::numeric) AS "代收儲值金額"
           FROM topup_orders t_1
             JOIN stores s_1 ON s_1.id = t_1.store_id
          WHERE (t_1.status <> ALL (ARRAY['void'::text, 'voided'::text, 'failed'::text, 'cancelled'::text, 'canceled'::text, 'pending'::text, 'expired'::text])) AND s_1.is_test = false
          GROUP BY (date_trunc('month'::text, t_1.created_at)::date), t_1.entity_id, t_1.store_id
        )
 SELECT COALESCE(o."月份", t."月份") AS "月份",
    e.id AS entity_id,
    e.name AS "法人",
    e.kind AS "類型",
    s.id AS store_id,
    s.name AS "門市",
    COALESCE(o."訂單數", 0::bigint) AS "訂單數",
    COALESCE(o."服務營業額", 0::numeric) AS "服務營業額",
    COALESCE(o."錢包支付", 0::numeric) AS "錢包支付",
    COALESCE(o."現場收款", 0::numeric) AS "現場收款",
    COALESCE(o."優惠券折抵", 0::numeric) AS "優惠券折抵",
    COALESCE(o."會員折扣", 0::numeric) AS "會員折扣",
    COALESCE(t."儲值筆數", 0::bigint) AS "儲值筆數",
    COALESCE(t."代收儲值金額", 0::numeric) AS "代收儲值"
   FROM ord o
     FULL JOIN tp t ON t."月份" = o."月份" AND t.entity_id = o.entity_id AND t.store_id = o.store_id
     LEFT JOIN legal_entities e ON e.id = COALESCE(o.entity_id, t.entity_id)
     LEFT JOIN stores s ON s.id = COALESCE(o.store_id, t.store_id);

-- [10.0] v_entity_settlement_summary
create or replace view v_entity_settlement_summary as 
 SELECT "月份",
    entity_id,
    "法人",
    "類型",
    count(DISTINCT store_id) AS "門市數",
    sum("訂單數") AS "訂單數",
    sum("服務營業額") AS "服務營業額",
    sum("錢包支付") AS "應向保管方請款",
    sum("現場收款") AS "門市已收現",
    sum("代收儲值") AS "代收儲值待繳",
    sum("錢包支付") - sum("代收儲值") AS "應收付淨額"
   FROM v_entity_settlement
  GROUP BY "月份", entity_id, "法人", "類型";

-- [10.0] v_invoice_pending
create or replace view v_invoice_pending as 
 SELECT i.id AS invoice_id,
    i.ref_table,
    i.ref_id,
    i.total_amount,
    i.buyer_type,
    i.carrier_type,
    i.carrier_no,
    i.donate_code,
    i.print_mark,
    e.name AS "賣方",
    e.tax_id AS "賣方統編",
    s.name AS "門市",
    i.created_at
   FROM invoices i
     LEFT JOIN legal_entities e ON e.id = i.entity_id
     LEFT JOIN stores s ON s.id = i.store_id
  WHERE i.status = 'pending'::text
  ORDER BY i.created_at;

-- [10.0] v_member_join_hours
create or replace view v_member_join_hours as 
 SELECT org_id,
    member_id,
    EXTRACT(dow FROM (joined_at AT TIME ZONE 'Asia/Taipei'::text))::integer AS weekday,
    EXTRACT(hour FROM (joined_at AT TIME ZONE 'Asia/Taipei'::text))::integer AS hour_of_day,
    count(*) AS joins
   FROM match_queue_players
  GROUP BY org_id, member_id, (EXTRACT(dow FROM (joined_at AT TIME ZONE 'Asia/Taipei'::text))::integer), (EXTRACT(hour FROM (joined_at AT TIME ZONE 'Asia/Taipei'::text))::integer);

-- [10.0] v_member_wait_stats
create or replace view v_member_wait_stats as 
 SELECT qp.org_id,
    qp.member_id,
    count(*) AS total_joins,
    count(*) FILTER (WHERE q.status = 'matched'::text) AS matched_cnt,
    count(*) FILTER (WHERE qp.leave_reason = 'quit'::text) AS quit_cnt,
    round(avg(EXTRACT(epoch FROM q.matched_at - qp.joined_at) / 60::numeric) FILTER (WHERE q.status = 'matched'::text)) AS avg_wait_to_match_min,
    round(max(EXTRACT(epoch FROM qp.left_at - qp.joined_at) / 60::numeric) FILTER (WHERE qp.leave_reason = 'quit'::text)) AS max_patience_min
   FROM match_queue_players qp
     JOIN match_queues q ON q.id = qp.queue_id
  GROUP BY qp.org_id, qp.member_id;

-- [10.0] v_order_invoice
create or replace view v_order_invoice as 
 SELECT DISTINCT ON (ref_id) ref_id AS order_id,
    id AS invoice_id,
    invoice_no,
    invoice_at,
    random_code,
    status,
    total_amount
   FROM invoices i
  WHERE ref_table = 'orders'::text AND kind = 'invoice'::text AND (status = ANY (ARRAY['pending'::text, 'issued'::text]))
  ORDER BY ref_id, created_at DESC;

-- [10.0] v_order_settlement
create or replace view v_order_settlement as 
 SELECT o.id,
    o.order_no,
    o.store_id,
    o.subtotal,
    o.coupon_discount,
    o.tier_discount,
    o.payable,
    o.points_used,
    o.cash_due,
    COALESCE(sum(p.amount), 0::numeric) AS paid_amount,
    o.cash_due::numeric - COALESCE(sum(p.amount), 0::numeric) AS unpaid,
    COALESCE(sum(p.change_given), 0::numeric) AS change_total
   FROM orders o
     LEFT JOIN order_payments p ON p.order_id = o.id
  GROUP BY o.id;

-- [10.0] v_payment_store_mismatch
create or replace view v_payment_store_mismatch as 
 SELECT o.order_no,
    o.created_at,
    so.name AS "訂單門市",
    sp.name AS "收款門市",
    p.method AS "付款方式",
    p.amount AS "金額"
   FROM order_payments p
     JOIN orders o ON o.id = p.order_id
     LEFT JOIN stores so ON so.id = o.store_id
     LEFT JOIN stores sp ON sp.id = p.store_id
  WHERE p.store_id IS DISTINCT FROM o.store_id;

-- [10.0] v_real_app_events
create or replace view v_real_app_events as 
 SELECT x.id,
    x.org_id,
    x.member_id,
    x.event,
    x.props,
    x.client_ts,
    x.created_at,
    x.is_test,
    x.store_id
   FROM app_events x
     JOIN orgs o ON o.id = x.org_id
  WHERE x.is_test = false AND x.created_at >= COALESCE(o.live_from, 'infinity'::timestamp with time zone) AND NOT (EXISTS ( SELECT 1
           FROM stores s
          WHERE s.id = x.store_id AND s.is_test)) AND NOT (EXISTS ( SELECT 1
           FROM members m
          WHERE m.id = x.member_id AND m.is_test));

-- [10.0] v_real_invoices
create or replace view v_real_invoices as 
 SELECT x.id,
    x.org_id,
    x.entity_id,
    x.store_id,
    x.ref_table,
    x.ref_id,
    x.kind,
    x.parent_invoice_id,
    x.status,
    x.invoice_no,
    x.invoice_at,
    x.random_code,
    x.period,
    x.tax_type,
    x.tax_rate,
    x.sales_amount,
    x.tax_amount,
    x.total_amount,
    x.buyer_type,
    x.buyer_tax_id,
    x.buyer_title,
    x.carrier_type,
    x.carrier_no,
    x.donate_code,
    x.donate_org_name,
    x.print_mark,
    x.items,
    x.void_at,
    x.void_reason,
    x.provider,
    x.provider_ref,
    x.raw,
    x.idempotency_key,
    x.created_at,
    x.created_by
   FROM invoices x
     JOIN orgs o ON o.id = x.org_id
  WHERE x.created_at >= COALESCE(o.live_from, 'infinity'::timestamp with time zone) AND NOT (EXISTS ( SELECT 1
           FROM stores s
          WHERE s.id = x.store_id AND s.is_test));

-- [10.0] v_real_match_queues
create or replace view v_real_match_queues as 
 SELECT x.id,
    x.org_id,
    x.store_id,
    x.stake_level_id,
    x.game_type,
    x.rounds,
    x.seats,
    x.prefs,
    x.status,
    x.opened_by,
    x.play_at,
    x.matched_at,
    x.matched_session_id,
    x.expires_at,
    x.created_at,
    x.updated_at,
    x.source,
    x.tags,
    x.recurring_id,
    x.recurring_freq,
    x.flower,
    x.open_at
   FROM match_queues x
     JOIN orgs o ON o.id = x.org_id
  WHERE x.created_at >= COALESCE(o.live_from, 'infinity'::timestamp with time zone) AND NOT (EXISTS ( SELECT 1
           FROM stores s
          WHERE s.id = x.store_id AND s.is_test));

-- [10.0] v_real_members
create or replace view v_real_members as 
 SELECT m.id,
    m.org_id,
    m.line_user_id,
    m.display_name,
    m.phone,
    m.home_store_id,
    m.tier,
    m.gender,
    m.birthday,
    m.occupation,
    m.district,
    m.acquisition_source,
    m.avatar_url,
    m.last_visit_at,
    m.visit_count,
    m.lifecycle,
    m.primary_staff_id,
    m.deleted_at,
    m.created_at,
    m.updated_at,
    m.created_by,
    m.updated_by,
    m.tier_override,
    m.last_app_active_at,
    m.rank,
    m.title,
    m.likes_count,
    m.is_test,
    m.about,
    m.sched,
    m.style,
    m.see_score,
    m.baby_tile,
    m.avatar_source,
    m.avatar_photo_path,
    m.avatar_photo_at,
    m.avatar_blocked,
    m.avatar_removed_count,
    m.inv_type,
    m.inv_carrier,
    m.inv_donate_code,
    m.inv_tax_id,
    m.inv_title
   FROM members m
     JOIN orgs o ON o.id = m.org_id
  WHERE m.is_test = false AND m.deleted_at IS NULL AND m.created_at >= COALESCE(o.live_from, 'infinity'::timestamp with time zone);

-- [10.0] v_real_order_items
create or replace view v_real_order_items as 
 SELECT id,
    order_id,
    product_id,
    qty,
    created_at,
    org_id,
    name,
    unit_price,
    line_total,
    revenue_type
   FROM order_items x
  WHERE (EXISTS ( SELECT 1
           FROM v_real_orders ro
          WHERE ro.id = x.order_id));

-- [10.0] v_real_order_payments
create or replace view v_real_order_payments as 
 SELECT id,
    org_id,
    store_id,
    order_id,
    method,
    amount,
    cash_received,
    change_given,
    ref_no,
    staff_id,
    created_at
   FROM order_payments x
  WHERE (EXISTS ( SELECT 1
           FROM v_real_orders ro
          WHERE ro.id = x.order_id));

-- [10.0] v_real_orders
create or replace view v_real_orders as 
 SELECT x.id,
    x.org_id,
    x.store_id,
    x.member_id,
    x.table_id,
    x.session_id,
    x.status,
    x.channel,
    x.total_points,
    x.deleted_at,
    x.created_at,
    x.updated_at,
    x.created_by,
    x.updated_by,
    x.order_no,
    x.subtotal,
    x.coupon_discount,
    x.tier_discount,
    x.payable,
    x.points_used,
    x.cash_due,
    x.tier_at_order,
    x.idempotency_key,
    x.wallet_txn_id,
    x.paid_at,
    x.entity_id,
    x.is_test,
    x.tier_discount_pct,
    x.txn_no
   FROM orders x
     JOIN orgs o ON o.id = x.org_id
  WHERE NOT COALESCE(x.is_test, false) AND x.deleted_at IS NULL AND x.created_at >= COALESCE(o.live_from, 'infinity'::timestamp with time zone) AND NOT (EXISTS ( SELECT 1
           FROM stores s
          WHERE s.id = x.store_id AND s.is_test)) AND NOT (EXISTS ( SELECT 1
           FROM members m
          WHERE m.id = x.member_id AND m.is_test));

-- [10.0] v_real_session_players
create or replace view v_real_session_players as 
 SELECT id,
    org_id,
    session_id,
    member_id,
    join_type,
    status,
    charged_points,
    joined_at,
    created_at,
    created_by,
    finish_rank,
    score_points,
    settled_at,
    order_id,
    seat,
    left_at,
    paid_by,
    fee_waived_amount,
    fee_waived_reason
   FROM session_players x
  WHERE (EXISTS ( SELECT 1
           FROM v_real_table_sessions rs
          WHERE rs.id = x.session_id)) AND NOT (EXISTS ( SELECT 1
           FROM members m
          WHERE m.id = x.member_id AND m.is_test));

-- [10.0] v_real_stores
create or replace view v_real_stores as 
 SELECT s.id,
    s.org_id,
    s.name,
    s.address,
    s.is_active,
    s.deleted_at,
    s.created_at,
    s.updated_at,
    s.created_by,
    s.updated_by,
    s.code,
    s.city,
    s.district,
    s.lat,
    s.lng,
    s.open_time,
    s.close_time,
    s.store_type,
    s.is_test,
    s.entity_id,
    s.phone,
    s.parking,
    s.photos,
    s.note
   FROM stores s
     JOIN orgs o ON o.id = s.org_id
  WHERE s.is_test = false AND s.deleted_at IS NULL AND s.created_at >= COALESCE(o.live_from, 'infinity'::timestamp with time zone);

-- [10.0] v_real_table_sessions
create or replace view v_real_table_sessions as 
 SELECT x.id,
    x.org_id,
    x.store_id,
    x.table_id,
    x.mode,
    x.stake_level_id,
    x.status,
    x.planned_minutes,
    x.started_at,
    x.ended_at,
    x.fee_points,
    x.promoted_by_staff_id,
    x.open_method,
    x.deleted_at,
    x.created_at,
    x.updated_at,
    x.created_by,
    x.updated_by,
    x.planned_rounds,
    x.opened_by_staff_id,
    x.activated_at,
    x.idempotency_key,
    x.is_test,
    x.game_type,
    x.flower
   FROM table_sessions x
     JOIN orgs o ON o.id = x.org_id
  WHERE NOT COALESCE(x.is_test, false) AND x.deleted_at IS NULL AND x.created_at >= COALESCE(o.live_from, 'infinity'::timestamp with time zone) AND NOT (EXISTS ( SELECT 1
           FROM stores s
          WHERE s.id = x.store_id AND s.is_test));

-- [10.0] v_real_topup_orders
create or replace view v_real_topup_orders as 
 SELECT x.id,
    x.org_id,
    x.store_id,
    x.member_id,
    x.topup_no,
    x.points,
    x.bonus_points,
    x.amount_twd,
    x.pay_method,
    x.status,
    x.external_ref,
    x.idempotency_key,
    x.invoice_no,
    x.invoice_at,
    x.wallet_txn_id,
    x.staff_id,
    x.note,
    x.created_at,
    x.created_by,
    x.entity_id,
    x.held_by_entity,
    x.session_id,
    x.cash_received,
    x.change_given,
    x.txn_no
   FROM topup_orders x
     JOIN orgs o ON o.id = x.org_id
  WHERE x.created_at >= COALESCE(o.live_from, 'infinity'::timestamp with time zone) AND NOT (EXISTS ( SELECT 1
           FROM stores s
          WHERE s.id = x.store_id AND s.is_test)) AND NOT (EXISTS ( SELECT 1
           FROM members m
          WHERE m.id = x.member_id AND m.is_test));

-- [10.0] v_real_wallet_txns
create or replace view v_real_wallet_txns as 
 SELECT x.id,
    x.org_id,
    x.store_id,
    x.served_store_id,
    x.member_id,
    x.type,
    x.amount,
    x.status,
    x.counter_account,
    x.reverses_txn_id,
    x.idempotency_key,
    x.external_ref,
    x.ref_table,
    x.ref_id,
    x.staff_id,
    x.note,
    x.created_at,
    x.created_by
   FROM wallet_txns x
     JOIN orgs o ON o.id = x.org_id
  WHERE x.created_at >= COALESCE(o.live_from, 'infinity'::timestamp with time zone) AND NOT (EXISTS ( SELECT 1
           FROM stores s
          WHERE s.id = x.store_id AND s.is_test)) AND NOT (EXISTS ( SELECT 1
           FROM members m
          WHERE m.id = x.member_id AND m.is_test));

-- [10.0] v_wallet_balance_check
create or replace view v_wallet_balance_check as 
 SELECT w.member_id,
    w.org_id,
    m.display_name,
    w.balance AS "實存餘額",
    COALESCE(t.sum_amount, 0::numeric) AS "交易加總",
    w.balance::numeric - COALESCE(t.sum_amount, 0::numeric) AS "差額",
    COALESCE(t.txn_count, 0::bigint) AS "交易筆數",
    t.last_txn_at AS "最後交易時間",
    w.updated_at AS "餘額更新時間"
   FROM wallets w
     LEFT JOIN members m ON m.id = w.member_id
     LEFT JOIN ( SELECT wallet_txns.member_id,
            sum(wallet_txns.amount) AS sum_amount,
            count(*) AS txn_count,
            max(wallet_txns.created_at) AS last_txn_at
           FROM wallet_txns
          WHERE wallet_txns.status = 'completed'::txn_status
          GROUP BY wallet_txns.member_id) t ON t.member_id = w.member_id;

-- [11.0] app_events
alter table app_events enable row level security;

-- [11.0] app_notifications
alter table app_notifications enable row level security;

-- [11.0] bonus_rules
alter table bonus_rules enable row level security;

-- [11.0] buddy_invites
alter table buddy_invites enable row level security;

-- [11.0] coupons
alter table coupons enable row level security;

-- [11.0] doc_counters
alter table doc_counters enable row level security;

-- [11.0] invoices
alter table invoices enable row level security;

-- [11.0] legal_entities
alter table legal_entities enable row level security;

-- [11.0] mahjong_buddies
alter table mahjong_buddies enable row level security;

-- [11.0] match_queue_players
alter table match_queue_players enable row level security;

-- [11.0] match_queues
alter table match_queues enable row level security;

-- [11.0] member_app_state
alter table member_app_state enable row level security;

-- [11.0] member_availability
alter table member_availability enable row level security;

-- [11.0] member_blocks
alter table member_blocks enable row level security;

-- [11.0] member_coupons
alter table member_coupons enable row level security;

-- [11.0] member_interactions
alter table member_interactions enable row level security;

-- [11.0] member_likes
alter table member_likes enable row level security;

-- [11.0] member_tiers
alter table member_tiers enable row level security;

-- [11.0] members
alter table members enable row level security;

-- [11.0] order_items
alter table order_items enable row level security;

-- [11.0] order_payments
alter table order_payments enable row level security;

-- [11.0] orders
alter table orders enable row level security;

-- [11.0] orgs
alter table orgs enable row level security;

-- [11.0] phone_otps
alter table phone_otps enable row level security;

-- [11.0] pricing_tiers
alter table pricing_tiers enable row level security;

-- [11.0] product_taxonomy
alter table product_taxonomy enable row level security;

-- [11.0] products
alter table products enable row level security;

-- [11.0] queue_tags
alter table queue_tags enable row level security;

-- [11.0] rank_points
alter table rank_points enable row level security;

-- [11.0] rank_seasons
alter table rank_seasons enable row level security;

-- [11.0] rank_sub_levels
alter table rank_sub_levels enable row level security;

-- [11.0] rank_tiers
alter table rank_tiers enable row level security;

-- [11.0] recurring_tables
alter table recurring_tables enable row level security;

-- [11.0] season_champions
alter table season_champions enable row level security;

-- [11.0] season_standings
alter table season_standings enable row level security;

-- [11.0] session_players
alter table session_players enable row level security;

-- [11.0] staff
alter table staff enable row level security;

-- [11.0] stake_levels
alter table stake_levels enable row level security;

-- [11.0] stores
alter table stores enable row level security;

-- [11.0] table_sessions
alter table table_sessions enable row level security;

-- [11.0] tables
alter table tables enable row level security;

-- [11.0] topup_orders
alter table topup_orders enable row level security;

-- [11.0] topup_plans
alter table topup_plans enable row level security;

-- [11.0] wallet_balance_audit
alter table wallet_balance_audit enable row level security;

-- [11.0] wallet_txns
alter table wallet_txns enable row level security;

-- [11.0] wallets
alter table wallets enable row level security;

-- [12.0] bonus_rules.bonus_org
create policy bonus_org on bonus_rules as PERMISSIVE for SELECT to authenticated using (((org_id = current_org_id()) AND can('ops.read'::text)));

-- [12.0] coupons.coupons_org
create policy coupons_org on coupons as PERMISSIVE for SELECT to authenticated using (((org_id = current_org_id()) AND can('ops.read'::text)));

-- [12.0] mahjong_buddies.buddies_org
create policy buddies_org on mahjong_buddies as PERMISSIVE for SELECT to authenticated using (((org_id = current_org_id()) AND can('member.read'::text)));

-- [12.0] member_availability.avail_org
create policy avail_org on member_availability as PERMISSIVE for SELECT to authenticated using (((org_id = current_org_id()) AND can('member.read'::text)));

-- [12.0] member_coupons.mc_org
create policy mc_org on member_coupons as PERMISSIVE for SELECT to authenticated using (((org_id = current_org_id()) AND can('member.read'::text)));

-- [12.0] member_interactions.interactions_org
create policy interactions_org on member_interactions as PERMISSIVE for SELECT to authenticated using (((org_id = current_org_id()) AND can('member.read'::text)));

-- [12.0] member_tiers.member_tiers_read
create policy member_tiers_read on member_tiers as PERMISSIVE for SELECT to public using (true);

-- [12.0] members.members_org
create policy members_org on members as PERMISSIVE for SELECT to authenticated using (((org_id = current_org_id()) AND can('member.read'::text)));

-- [12.0] order_items.oi_org
create policy oi_org on order_items as PERMISSIVE for SELECT to authenticated using (((EXISTS ( SELECT 1
   FROM orders o
  WHERE ((o.id = order_items.order_id) AND (o.org_id = current_org_id())))) AND can('finance.read'::text)));

-- [12.0] order_items.order_items_org
create policy order_items_org on order_items as PERMISSIVE for ALL to authenticated using (((org_id = current_org_id()) AND can('order.write'::text))) with check (((org_id = current_org_id()) AND can('order.write'::text)));

-- [12.0] order_payments.order_payments_org
create policy order_payments_org on order_payments as PERMISSIVE for ALL to authenticated using (((org_id = current_org_id()) AND can('order.write'::text))) with check (((org_id = current_org_id()) AND can('order.write'::text)));

-- [12.0] order_payments.order_payments_read_org
create policy order_payments_read_org on order_payments as PERMISSIVE for SELECT to authenticated using (((org_id = current_org_id()) AND can('finance.read'::text)));

-- [12.0] orders.orders_org
create policy orders_org on orders as PERMISSIVE for SELECT to authenticated using (((org_id = current_org_id()) AND can('finance.read'::text)));

-- [12.0] orgs.org_self
create policy org_self on orgs as PERMISSIVE for SELECT to public using ((id = current_org_id()));

-- [12.0] pricing_tiers.pricing_org
create policy pricing_org on pricing_tiers as PERMISSIVE for SELECT to authenticated using (((org_id = current_org_id()) AND can('ops.read'::text)));

-- [12.0] product_taxonomy.product_taxonomy_read
create policy product_taxonomy_read on product_taxonomy as PERMISSIVE for SELECT to public using (true);

-- [12.0] products.products_org
create policy products_org on products as PERMISSIVE for SELECT to public using ((org_id = current_org_id()));

-- [12.0] products.products_org_write
create policy products_org_write on products as PERMISSIVE for ALL to authenticated using (((org_id = current_org_id()) AND can('product.write'::text))) with check (((org_id = current_org_id()) AND can('product.write'::text)));

-- [12.0] queue_tags.queue_tags_read
create policy queue_tags_read on queue_tags as PERMISSIVE for SELECT to public using (true);

-- [12.0] session_players.sp_org
create policy sp_org on session_players as PERMISSIVE for SELECT to authenticated using (((org_id = current_org_id()) AND can('ops.read'::text)));

-- [12.0] staff.staff_org
create policy staff_org on staff as PERMISSIVE for SELECT to authenticated using (((org_id = current_org_id()) AND can('ops.read'::text)));

-- [12.0] stake_levels.stake_org
create policy stake_org on stake_levels as PERMISSIVE for SELECT to public using ((org_id = current_org_id()));

-- [12.0] stores.stores_org
create policy stores_org on stores as PERMISSIVE for SELECT to public using ((org_id = current_org_id()));

-- [12.0] table_sessions.sessions_org
create policy sessions_org on table_sessions as PERMISSIVE for SELECT to authenticated using (((org_id = current_org_id()) AND can('ops.read'::text)));

-- [12.0] tables.tables_org
create policy tables_org on tables as PERMISSIVE for SELECT to public using ((org_id = current_org_id()));

-- [12.0] topup_orders.topup_org
create policy topup_org on topup_orders as PERMISSIVE for SELECT to authenticated using (((org_id = current_org_id()) AND can('finance.read'::text)));

-- [12.0] topup_plans.topup_plans_read
create policy topup_plans_read on topup_plans as PERMISSIVE for SELECT to public using (true);

-- [12.0] wallet_txns.txns_org
create policy txns_org on wallet_txns as PERMISSIVE for SELECT to authenticated using (((org_id = current_org_id()) AND can('finance.read'::text)));

-- [12.0] wallets.wallets_org
create policy wallets_org on wallets as PERMISSIVE for SELECT to authenticated using (((org_id = current_org_id()) AND can('finance.read'::text)));
