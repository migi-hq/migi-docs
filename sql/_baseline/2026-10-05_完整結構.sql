/* ============================================================
   MIGI 資料庫完整結構 baseline
   產生日期：2026-10-05
   基準：`sql/applied/` 有 305 個 `.sql`，最後一份是
        `2026-10-04_桌況回傳要店員處理的事.sql`

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

/* 🔴 **不要在有資料的資料庫上跑這一份。**
   2026-09-19 真的發生過一次：有人把它整份貼進正式站的 SQL Editor 按下 Run，
   在第一個 `create type` 就炸（`42710: type "txn_status" already exists`）。
   🟢 當天零損害 —— Supabase 的 SQL Editor 是**單一交易**，整份回滾了。
   ⚠ **但那是運氣不是設計**：只要它跑得再深一點，
     後面全是 `create table` / `create policy`，
     而中途任何一個成功都可能改動正在營運的結構。

   ✅ 所以這道牆在這裡：`public` 只要已經有表就**什麼都不做**，
     而且訊息會告訴你現在有幾張。要重建就在**空的資料庫**上跑。
   📌 這不是提醒，是機制 —— 提醒需要有人記得，而那個人就是會忘的那個。 */
do $$
declare v_n int;
begin
  select count(*) into v_n
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind = 'r';
  if v_n > 0 then
    raise exception
      '🔴 這份是 baseline（現況快照），只能在**空的資料庫**上重建。目前 public 已經有 % 張表 —— 一行都沒有執行。', v_n;
  end if;
end $$;

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

-- [3.0] achievement_tiers
create table achievement_tiers (
  id uuid default gen_random_uuid() not null,
  org_id uuid not null,
  achievement_id uuid not null,
  tier_level integer not null,
  tier_name text not null,
  threshold bigint not null,
  reward_points bigint default 0 not null,
  created_at timestamp with time zone default now() not null
);

-- [3.0] achievements
create table achievements (
  id uuid default gen_random_uuid() not null,
  org_id uuid not null,
  code text not null,
  name text not null,
  description text,
  condition_text text,
  group_key text,
  ui_category text not null,
  struct text not null,
  motivation text not null,
  rarity text default 'norm'::text not null,
  visibility text default 'visible'::text not null,
  trigger jsonb,
  requires_code text,
  grants_title text,
  is_signature boolean default false not null,
  reward_points bigint default 0 not null,
  valid_from timestamp with time zone,
  valid_to timestamp with time zone,
  is_active boolean default true not null,
  sort integer default 0 not null,
  deleted_at timestamp with time zone,
  created_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone default now() not null,
  badge_path text
);

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

-- [3.0] bookings
create table bookings (
  id uuid default gen_random_uuid() not null,
  org_id uuid not null,
  store_id uuid not null,
  team_id uuid,
  member_id uuid not null,
  play_at timestamp with time zone not null,
  planned_hours integer not null,
  table_count integer default 1 not null,
  party_size integer,
  note text,
  status text default 'booked'::text not null,
  table_id uuid,
  seated_session_id uuid,
  cancelled_reason text,
  created_by_staff_id uuid,
  created_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone default now() not null,
  game_type text,
  flower text,
  stake_level_id uuid
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

-- [3.0] coupon_scopes
create table coupon_scopes (
  id uuid default gen_random_uuid() not null,
  org_id uuid not null,
  coupon_id uuid not null,
  scope_type text not null,
  scope_value text not null,
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

-- [3.0] hands
create table hands (
  id uuid default gen_random_uuid() not null,
  org_id uuid not null,
  session_id uuid not null,
  round_id uuid not null,
  hand_no integer not null,
  wind smallint not null,
  dealer_seat smallint not null,
  renzhuang smallint default 0 not null,
  result text not null,
  winner_seat smallint,
  deal_in_seat smallint,
  patterns jsonb default '[]'::jsonb not null,
  tai_pattern integer default 0 not null,
  base integer,
  tai_unit integer,
  score_delta jsonb default '{}'::jsonb not null,
  status text default 'pending'::text not null,
  need_confirm smallint[] default '{}'::smallint[] not null,
  confirmed_seats smallint[] default '{}'::smallint[] not null,
  submitted_seat smallint,
  submitted_device_id uuid,
  rejected_seat smallint,
  created_at timestamp with time zone default now() not null,
  confirmed_at timestamp with time zone,
  undone_at timestamp with time zone,
  proposed_delta jsonb,
  cancelled_seats smallint[] default '{}'::smallint[] not null
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
  game_type text default '台麻'::text not null,
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
  auto_seat boolean default true not null,
  credited_staff_id uuid
);

-- [3.0] member_achievements
create table member_achievements (
  id uuid default gen_random_uuid() not null,
  org_id uuid not null,
  member_id uuid not null,
  achievement_id uuid not null,
  status text default 'locked'::text not null,
  current_value bigint default 0 not null,
  current_tier integer default 0 not null,
  last_period text,
  pinned boolean default false not null,
  unlocked_at timestamp with time zone,
  created_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone default now() not null,
  last_idem text
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

-- [3.0] member_hidden
create table member_hidden (
  member_id uuid not null,
  org_id uuid not null,
  display_name text not null,
  avatar_source text not null,
  avatar_bear text,
  avatar_url text,
  avatar_photo_path text,
  about text,
  title text,
  style jsonb,
  baby_tile jsonb,
  sched text,
  hidden_at timestamp with time zone default now() not null
);

-- [3.0] member_hide_log
create table member_hide_log (
  id uuid default gen_random_uuid() not null,
  org_id uuid not null,
  member_id uuid not null,
  action text not null,
  source text not null,
  by_staff_id uuid,
  reason text,
  at timestamp with time zone default now() not null
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
  rating_games integer default 0 not null,
  hidden_at timestamp with time zone,
  best_rank_tier text
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

-- [3.0] scoring_patterns
create table scoring_patterns (
  code text not null,
  label text not null,
  tai integer not null,
  max_count smallint default 1 not null,
  group_key text not null,
  needs_flower boolean default false not null,
  result_only text,
  dealer_only boolean default false not null,
  conflicts text[] default '{}'::text[] not null,
  achievement_event text,
  sort integer not null,
  is_active boolean default true not null,
  note text,
  created_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone default now() not null
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

-- [3.0] season_start_ratings
create table season_start_ratings (
  org_id uuid not null,
  season text not null,
  member_id uuid not null,
  rating integer not null,
  created_at timestamp with time zone default now() not null
);

-- [3.0] session_busts
create table session_busts (
  id uuid default gen_random_uuid() not null,
  org_id uuid not null,
  session_id uuid not null,
  seat smallint not null,
  hand_id uuid,
  by_seat smallint,
  decision text default 'pending'::text not null,
  added_points integer,
  created_at timestamp with time zone default now() not null,
  decided_at timestamp with time zone
);

-- [3.0] session_extensions
create table session_extensions (
  id uuid default gen_random_uuid() not null,
  org_id uuid not null,
  session_id uuid not null,
  member_id uuid not null,
  to_minutes integer,
  paid_by uuid not null,
  order_id uuid,
  created_at timestamp with time zone default now() not null,
  created_by uuid,
  kind text default '2h'::text not null
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
  seat smallint,
  left_at timestamp with time zone,
  paid_by uuid,
  fee_waived_amount bigint default 0 not null,
  fee_waived_reason text,
  rating_after integer,
  final_score integer,
  device_id uuid
);

-- [3.0] session_rounds
create table session_rounds (
  id uuid default gen_random_uuid() not null,
  org_id uuid not null,
  session_id uuid not null,
  round_no smallint not null,
  first_dealer_seat smallint not null,
  status text default 'playing'::text not null,
  started_at timestamp with time zone default now() not null,
  finished_at timestamp with time zone,
  created_at timestamp with time zone default now() not null,
  seat_ring smallint[]
);

-- [3.0] snack_grants
create table snack_grants (
  id uuid default gen_random_uuid() not null,
  org_id uuid not null,
  member_id uuid not null,
  kind text not null,
  qty integer not null,
  reason text not null,
  ref_id uuid,
  idem_key text not null,
  created_at timestamp with time zone default now() not null
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
  updated_by uuid,
  start_points integer default 2000 not null
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
  note text,
  on_duty_staff_id uuid,
  on_duty_since timestamp with time zone
);

-- [3.0] table_devices
create table table_devices (
  id uuid default gen_random_uuid() not null,
  org_id uuid not null,
  store_id uuid not null,
  table_id uuid not null,
  label text not null,
  token_hash text not null,
  is_active boolean default true not null,
  last_seen_at timestamp with time zone,
  created_at timestamp with time zone default now() not null,
  created_by_staff_id uuid,
  revoked_at timestamp with time zone,
  revoked_by_staff_id uuid
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
  flower text,
  score_channel text default encode(gen_random_bytes(16), 'hex'::text) not null,
  closed_by_staff_id uuid
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

-- [3.0] team_invite_links
create table team_invite_links (
  id uuid default gen_random_uuid() not null,
  org_id uuid not null,
  team_id uuid not null,
  token text not null,
  created_by uuid not null,
  created_at timestamp with time zone default now() not null,
  expires_at timestamp with time zone default (now() + '7 days'::interval) not null,
  used_by uuid,
  used_at timestamp with time zone
);

-- [3.0] team_members
create table team_members (
  id uuid default gen_random_uuid() not null,
  org_id uuid not null,
  team_id uuid not null,
  member_id uuid not null,
  role text default 'member'::text not null,
  joined_at timestamp with time zone default now() not null,
  left_at timestamp with time zone,
  left_reason text,
  created_at timestamp with time zone default now() not null
);

-- [3.0] team_requests
create table team_requests (
  id uuid default gen_random_uuid() not null,
  org_id uuid not null,
  team_id uuid not null,
  member_id uuid not null,
  kind text not null,
  status text default 'pending'::text not null,
  created_by uuid not null,
  decided_by uuid,
  decided_at timestamp with time zone,
  expires_at timestamp with time zone default (now() + '14 days'::interval) not null,
  created_at timestamp with time zone default now() not null
);

-- [3.0] teams
create table teams (
  id uuid default gen_random_uuid() not null,
  org_id uuid not null,
  name text not null,
  intro text,
  crest_emoji text,
  crest_path text,
  crest_blocked boolean default false not null,
  home_store_id uuid,
  join_policy text default 'approval'::text not null,
  monthly_goal integer default 10 not null,
  member_limit integer default 200 not null,
  created_by uuid not null,
  created_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone default now() not null,
  deleted_at timestamp with time zone,
  crest_source text default 'default'::text not null
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

-- [4.1] achievement_tiers.achievement_tiers_pkey
alter table achievement_tiers add constraint achievement_tiers_pkey PRIMARY KEY (id);

-- [4.1] achievements.achievements_pkey
alter table achievements add constraint achievements_pkey PRIMARY KEY (id);

-- [4.1] app_events.app_events_pkey
alter table app_events add constraint app_events_pkey PRIMARY KEY (id);

-- [4.1] app_notifications.app_notifications_pkey
alter table app_notifications add constraint app_notifications_pkey PRIMARY KEY (id);

-- [4.1] bonus_rules.bonus_rules_pkey
alter table bonus_rules add constraint bonus_rules_pkey PRIMARY KEY (id);

-- [4.1] bookings.bookings_pkey
alter table bookings add constraint bookings_pkey PRIMARY KEY (id);

-- [4.1] buddy_invites.buddy_invites_pkey
alter table buddy_invites add constraint buddy_invites_pkey PRIMARY KEY (id);

-- [4.1] coupon_scopes.coupon_scopes_pkey
alter table coupon_scopes add constraint coupon_scopes_pkey PRIMARY KEY (id);

-- [4.1] coupons.coupons_pkey
alter table coupons add constraint coupons_pkey PRIMARY KEY (id);

-- [4.1] doc_counters.doc_counters_pkey
alter table doc_counters add constraint doc_counters_pkey PRIMARY KEY (org_id, store_id, doc_type, doc_date);

-- [4.1] hands.hands_pkey
alter table hands add constraint hands_pkey PRIMARY KEY (id);

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

-- [4.1] member_achievements.member_achievements_pkey
alter table member_achievements add constraint member_achievements_pkey PRIMARY KEY (id);

-- [4.1] member_app_state.member_app_state_pkey
alter table member_app_state add constraint member_app_state_pkey PRIMARY KEY (member_id);

-- [4.1] member_availability.member_availability_pkey
alter table member_availability add constraint member_availability_pkey PRIMARY KEY (id);

-- [4.1] member_blocks.member_blocks_pkey
alter table member_blocks add constraint member_blocks_pkey PRIMARY KEY (id);

-- [4.1] member_coupons.member_coupons_pkey
alter table member_coupons add constraint member_coupons_pkey PRIMARY KEY (id);

-- [4.1] member_hidden.member_hidden_pkey
alter table member_hidden add constraint member_hidden_pkey PRIMARY KEY (member_id);

-- [4.1] member_hide_log.member_hide_log_pkey
alter table member_hide_log add constraint member_hide_log_pkey PRIMARY KEY (id);

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

-- [4.1] scoring_patterns.scoring_patterns_pkey
alter table scoring_patterns add constraint scoring_patterns_pkey PRIMARY KEY (code);

-- [4.1] season_champions.season_champions_pkey
alter table season_champions add constraint season_champions_pkey PRIMARY KEY (org_id, season);

-- [4.1] season_standings.season_standings_pkey
alter table season_standings add constraint season_standings_pkey PRIMARY KEY (org_id, season, member_id);

-- [4.1] season_start_ratings.season_start_ratings_pkey
alter table season_start_ratings add constraint season_start_ratings_pkey PRIMARY KEY (org_id, season, member_id);

-- [4.1] session_busts.session_busts_pkey
alter table session_busts add constraint session_busts_pkey PRIMARY KEY (id);

-- [4.1] session_extensions.session_extensions_pkey
alter table session_extensions add constraint session_extensions_pkey PRIMARY KEY (id);

-- [4.1] session_players.session_players_pkey
alter table session_players add constraint session_players_pkey PRIMARY KEY (id);

-- [4.1] session_rounds.session_rounds_pkey
alter table session_rounds add constraint session_rounds_pkey PRIMARY KEY (id);

-- [4.1] snack_grants.snack_grants_pkey
alter table snack_grants add constraint snack_grants_pkey PRIMARY KEY (id);

-- [4.1] staff.staff_pkey
alter table staff add constraint staff_pkey PRIMARY KEY (id);

-- [4.1] stake_levels.stake_levels_pkey
alter table stake_levels add constraint stake_levels_pkey PRIMARY KEY (id);

-- [4.1] stores.stores_pkey
alter table stores add constraint stores_pkey PRIMARY KEY (id);

-- [4.1] table_devices.table_devices_pkey
alter table table_devices add constraint table_devices_pkey PRIMARY KEY (id);

-- [4.1] table_sessions.table_sessions_pkey
alter table table_sessions add constraint table_sessions_pkey PRIMARY KEY (id);

-- [4.1] tables.tables_pkey
alter table tables add constraint tables_pkey PRIMARY KEY (id);

-- [4.1] team_invite_links.team_invite_links_pkey
alter table team_invite_links add constraint team_invite_links_pkey PRIMARY KEY (id);

-- [4.1] team_members.team_members_pkey
alter table team_members add constraint team_members_pkey PRIMARY KEY (id);

-- [4.1] team_requests.team_requests_pkey
alter table team_requests add constraint team_requests_pkey PRIMARY KEY (id);

-- [4.1] teams.teams_pkey
alter table teams add constraint teams_pkey PRIMARY KEY (id);

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

-- [4.2] achievement_tiers.achievement_tiers_achievement_id_tier_level_k
alter table achievement_tiers add constraint achievement_tiers_achievement_id_tier_level_key UNIQUE (achievement_id, tier_level);

-- [4.2] coupon_scopes.coupon_scopes_coupon_id_scope_type_scope_value_ke
alter table coupon_scopes add constraint coupon_scopes_coupon_id_scope_type_scope_value_key UNIQUE (coupon_id, scope_type, scope_value);

-- [4.2] invoices.invoices_idempotency_key_key
alter table invoices add constraint invoices_idempotency_key_key UNIQUE (idempotency_key);

-- [4.2] member_achievements.member_achievements_member_id_achievement_i
alter table member_achievements add constraint member_achievements_member_id_achievement_id_key UNIQUE (member_id, achievement_id);

-- [4.2] staff.staff_auth_uid_key
alter table staff add constraint staff_auth_uid_key UNIQUE (auth_uid);

-- [4.2] table_devices.table_devices_token_hash_key
alter table table_devices add constraint table_devices_token_hash_key UNIQUE (token_hash);

-- [4.2] team_invite_links.team_invite_links_token_key
alter table team_invite_links add constraint team_invite_links_token_key UNIQUE (token);

-- [4.3] achievements.achievements_motivation_check
alter table achievements add constraint achievements_motivation_check CHECK ((motivation = ANY (ARRAY['completion'::text, 'competition'::text, 'social'::text, 'exploration'::text, 'collection'::text, 'prestige'::text, 'expression'::text, 'story'::text, 'consumption'::text, 'habit'::text])));

-- [4.3] achievements.achievements_rarity_check
alter table achievements add constraint achievements_rarity_check CHECK ((rarity = ANY (ARRAY['norm'::text, 'rare'::text, 'epic'::text, 'legend'::text])));

-- [4.3] achievements.achievements_struct_check
alter table achievements add constraint achievements_struct_check CHECK ((struct = ANY (ARRAY['specific'::text, 'cumulative'::text, 'streak'::text, 'prestige'::text])));

-- [4.3] achievements.achievements_ui_category_check
alter table achievements add constraint achievements_ui_category_check CHECK ((ui_category = ANY (ARRAY['onboarding'::text, 'game'::text, 'social'::text, 'fnb'::text, 'explore'::text, 'special'::text])));

-- [4.3] achievements.achievements_visibility_check
alter table achievements add constraint achievements_visibility_check CHECK ((visibility = ANY (ARRAY['visible'::text, 'silhouette'::text, 'hidden'::text])));

-- [4.3] app_events.app_events_event_check
alter table app_events add constraint app_events_event_check CHECK ((event ~ '^[a-z][a-z0-9_]{0,49}$'::text));

-- [4.3] app_events.app_events_props_check
alter table app_events add constraint app_events_props_check CHECK ((pg_column_size(props) <= 8192));

-- [4.3] app_notifications.app_notifications_type_check
alter table app_notifications add constraint app_notifications_type_check CHECK ((type = ANY (ARRAY['settle'::text, 'buddy_req'::text, 'buddy_ok'::text, 'table_req'::text, 'table_ok'::text, 'system'::text, 'table_expired'::text, 'team_req'::text, 'team_ok'::text, 'team_out'::text])));

-- [4.3] bonus_rules.bonus_rules_amount_check
alter table bonus_rules add constraint bonus_rules_amount_check CHECK ((amount >= 0));

-- [4.3] bonus_rules.bonus_rules_rule_key_check
alter table bonus_rules add constraint bonus_rules_rule_key_check CHECK ((rule_key = ANY (ARRAY['match_made'::text, 'visit_commission'::text])));

-- [4.3] bookings.bookings_cancel_shape_check
alter table bookings add constraint bookings_cancel_shape_check CHECK (((status <> 'cancelled'::text) OR (cancelled_reason IS NOT NULL)));

-- [4.3] bookings.bookings_flower_chk
alter table bookings add constraint bookings_flower_chk CHECK (((flower IS NULL) OR (flower = ANY (ARRAY['無花'::text, '有花'::text]))));

-- [4.3] bookings.bookings_game_type_chk
alter table bookings add constraint bookings_game_type_chk CHECK (((game_type IS NULL) OR (game_type = ANY (ARRAY['台麻'::text, '美麻'::text]))));

-- [4.3] bookings.bookings_hours_check
alter table bookings add constraint bookings_hours_check CHECK ((planned_hours = ANY (ARRAY[2, 5, 24])));

-- [4.3] bookings.bookings_party_size_check
alter table bookings add constraint bookings_party_size_check CHECK (((party_size IS NULL) OR ((party_size >= 1) AND (party_size <= 80))));

-- [4.3] bookings.bookings_seated_shape_check
alter table bookings add constraint bookings_seated_shape_check CHECK (((status <> 'seated'::text) OR (table_id IS NOT NULL)));

-- [4.3] bookings.bookings_status_check
alter table bookings add constraint bookings_status_check CHECK ((status = ANY (ARRAY['booked'::text, 'seated'::text, 'cancelled'::text, 'no_show'::text, 'expired'::text])));

-- [4.3] bookings.bookings_table_count_check
alter table bookings add constraint bookings_table_count_check CHECK (((table_count >= 1) AND (table_count <= 10)));

-- [4.3] buddy_invites.buddy_invites_check
alter table buddy_invites add constraint buddy_invites_check CHECK ((inviter_id <> invitee_id));

-- [4.3] buddy_invites.buddy_invites_status_check
alter table buddy_invites add constraint buddy_invites_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'accepted'::text, 'rejected'::text])));

-- [4.3] coupon_scopes.coupon_scopes_scope_type_check
alter table coupon_scopes add constraint coupon_scopes_scope_type_check CHECK ((scope_type = ANY (ARRAY['revenue_type'::text, 'subcategory'::text, 'product'::text])));

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

-- [4.3] hands.hands_deal_in_seat_check
alter table hands add constraint hands_deal_in_seat_check CHECK (((deal_in_seat >= 1) AND (deal_in_seat <= 4)));

-- [4.3] hands.hands_dealer_seat_check
alter table hands add constraint hands_dealer_seat_check CHECK (((dealer_seat >= 1) AND (dealer_seat <= 4)));

-- [4.3] hands.hands_hand_no_check
alter table hands add constraint hands_hand_no_check CHECK ((hand_no >= 1));

-- [4.3] hands.hands_rejected_seat_check
alter table hands add constraint hands_rejected_seat_check CHECK (((rejected_seat >= 1) AND (rejected_seat <= 4)));

-- [4.3] hands.hands_renzhuang_check
alter table hands add constraint hands_renzhuang_check CHECK ((renzhuang >= 0));

-- [4.3] hands.hands_result_check
alter table hands add constraint hands_result_check CHECK ((result = ANY (ARRAY['tsumo'::text, 'ron'::text, 'draw'::text, 'kala'::text, 'bao'::text])));

-- [4.3] hands.hands_result_shape
alter table hands add constraint hands_result_shape CHECK ((((result = 'ron'::text) AND (winner_seat IS NOT NULL) AND (deal_in_seat IS NOT NULL) AND (winner_seat <> deal_in_seat)) OR ((result = 'tsumo'::text) AND (winner_seat IS NOT NULL) AND (deal_in_seat IS NULL)) OR ((result = 'draw'::text) AND (winner_seat IS NULL) AND (deal_in_seat IS NULL)) OR ((result = 'kala'::text) AND (winner_seat IS NOT NULL) AND (deal_in_seat IS NOT NULL) AND (winner_seat <> deal_in_seat)) OR ((result = 'bao'::text) AND (winner_seat IS NULL) AND (deal_in_seat IS NOT NULL))));

-- [4.3] hands.hands_status_check
alter table hands add constraint hands_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'confirmed'::text, 'rejected'::text, 'undone'::text])));

-- [4.3] hands.hands_submitted_seat_check
alter table hands add constraint hands_submitted_seat_check CHECK (((submitted_seat >= 1) AND (submitted_seat <= 4)));

-- [4.3] hands.hands_tai_pattern_check
alter table hands add constraint hands_tai_pattern_check CHECK ((tai_pattern >= 0));

-- [4.3] hands.hands_wind_check
alter table hands add constraint hands_wind_check CHECK (((wind >= 1) AND (wind <= 4)));

-- [4.3] hands.hands_winner_seat_check
alter table hands add constraint hands_winner_seat_check CHECK (((winner_seat >= 1) AND (winner_seat <= 4)));

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

-- [4.3] member_achievements.member_achievements_status_check
alter table member_achievements add constraint member_achievements_status_check CHECK ((status = ANY (ARRAY['locked'::text, 'in_progress'::text, 'unlocked'::text])));

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

-- [4.3] member_hide_log.member_hide_log_action_check
alter table member_hide_log add constraint member_hide_log_action_check CHECK ((action = ANY (ARRAY['hide'::text, 'unhide'::text])));

-- [4.3] member_hide_log.member_hide_log_source_check
alter table member_hide_log add constraint member_hide_log_source_check CHECK ((source = ANY (ARRAY['self'::text, 'hq'::text])));

-- [4.3] member_interactions.member_interactions_channel_check
alter table member_interactions add constraint member_interactions_channel_check CHECK ((channel = ANY (ARRAY['system'::text, 'staff'::text])));

-- [4.3] member_interactions.member_interactions_kind_check
alter table member_interactions add constraint member_interactions_kind_check CHECK ((kind = ANY (ARRAY['care'::text, 'birthday'::text, 'winback'::text, 'welcome'::text, 'note'::text])));

-- [4.3] member_likes.member_likes_check
alter table member_likes add constraint member_likes_check CHECK ((liker_id <> target_id));

-- [4.3] member_tiers.member_tiers_pct_chk
alter table member_tiers add constraint member_tiers_pct_chk CHECK (((discount_pct >= 0) AND (discount_pct <= 100)));

-- [4.3] members.members_avatar_source_chk
alter table members add constraint members_avatar_source_chk CHECK ((avatar_source = ANY (ARRAY['bear'::text, 'photo'::text, 'line'::text, 'hidden'::text])));

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

-- [4.3] members.members_see_score_check
alter table members add constraint members_see_score_check CHECK ((see_score = ANY (ARRAY['牌咖'::text, '只有自己'::text])));

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

-- [4.3] scoring_patterns.scoring_patterns_group_key_check
alter table scoring_patterns add constraint scoring_patterns_group_key_check CHECK ((group_key = ANY (ARRAY['basic'::text, 'honor'::text, 'suit'::text, 'flower'::text, 'special'::text])));

-- [4.3] scoring_patterns.scoring_patterns_max_count_check
alter table scoring_patterns add constraint scoring_patterns_max_count_check CHECK (((max_count >= 1) AND (max_count <= 4)));

-- [4.3] scoring_patterns.scoring_patterns_result_only_check
alter table scoring_patterns add constraint scoring_patterns_result_only_check CHECK ((result_only = ANY (ARRAY['tsumo'::text, 'ron'::text])));

-- [4.3] scoring_patterns.scoring_patterns_tai_check
alter table scoring_patterns add constraint scoring_patterns_tai_check CHECK ((tai >= 0));

-- [4.3] session_busts.session_busts_added_ck
alter table session_busts add constraint session_busts_added_ck CHECK ((((decision = 'added'::text) = (added_points IS NOT NULL)) AND ((added_points IS NULL) OR (added_points > 0))));

-- [4.3] session_busts.session_busts_by_seat_check
alter table session_busts add constraint session_busts_by_seat_check CHECK (((by_seat >= 1) AND (by_seat <= 4)));

-- [4.3] session_busts.session_busts_decision_check
alter table session_busts add constraint session_busts_decision_check CHECK ((decision = ANY (ARRAY['pending'::text, 'added'::text, 'ended'::text, 'voided'::text])));

-- [4.3] session_busts.session_busts_seat_check
alter table session_busts add constraint session_busts_seat_check CHECK (((seat >= 1) AND (seat <= 4)));

-- [4.3] session_extensions.session_extensions_kind_check
alter table session_extensions add constraint session_extensions_kind_check CHECK ((((kind = '2h'::text) AND (to_minutes > 120) AND (to_minutes <= 1440)) OR ((kind = 'daypass'::text) AND (to_minutes IS NULL))));

-- [4.3] session_players.chk_finish_rank
alter table session_players add constraint chk_finish_rank CHECK (((finish_rank IS NULL) OR ((finish_rank >= 1) AND (finish_rank <= 4)))) NOT VALID;

-- [4.3] session_players.session_players_join_type_check
alter table session_players add constraint session_players_join_type_check CHECK ((join_type = ANY (ARRAY['opener'::text, 'mid_join'::text, 'sub'::text])));

-- [4.3] session_players.session_players_seat_range
alter table session_players add constraint session_players_seat_range CHECK (((seat >= 1) AND (seat <= 4)));

-- [4.3] session_players.session_players_status_check
alter table session_players add constraint session_players_status_check CHECK ((status = ANY (ARRAY['playing'::text, 'completed'::text, 'late'::text, 'forfeit'::text])));

-- [4.3] session_rounds.session_rounds_first_dealer_seat_check
alter table session_rounds add constraint session_rounds_first_dealer_seat_check CHECK (((first_dealer_seat >= 1) AND (first_dealer_seat <= 4)));

-- [4.3] session_rounds.session_rounds_round_no_check
alter table session_rounds add constraint session_rounds_round_no_check CHECK ((round_no >= 1));

-- [4.3] session_rounds.session_rounds_seat_ring_chk
alter table session_rounds add constraint session_rounds_seat_ring_chk CHECK (((seat_ring IS NULL) OR ((cardinality(seat_ring) = 4) AND (seat_ring @> '{1,2,3,4}'::smallint[]))));

-- [4.3] session_rounds.session_rounds_status_check
alter table session_rounds add constraint session_rounds_status_check CHECK ((status = ANY (ARRAY['playing'::text, 'finished'::text, 'voided'::text])));

-- [4.3] snack_grants.snack_grants_kind_check
alter table snack_grants add constraint snack_grants_kind_check CHECK ((kind = ANY (ARRAY['cookie'::text, 'milktea'::text, 'pudding'::text, 'tiramisu'::text])));

-- [4.3] snack_grants.snack_grants_qty_check
alter table snack_grants add constraint snack_grants_qty_check CHECK ((qty <> 0));

-- [4.3] snack_grants.snack_grants_reason_check
alter table snack_grants add constraint snack_grants_reason_check CHECK ((reason = ANY (ARRAY['like'::text, 'daily'::text, 'task'::text, 'draw'::text, 'admin'::text, 'feed'::text])));

-- [4.3] staff.staff_role_check
alter table staff add constraint staff_role_check CHECK ((role = ANY (ARRAY['floor'::text, 'manager'::text, 'hq'::text, 'owner'::text])));

-- [4.3] stake_levels.stake_levels_start_points_check
alter table stake_levels add constraint stake_levels_start_points_check CHECK ((start_points >= 0));

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

-- [4.3] team_invite_links.team_invite_links_used_pair
alter table team_invite_links add constraint team_invite_links_used_pair CHECK (((used_by IS NULL) = (used_at IS NULL)));

-- [4.3] team_members.team_members_left_reason_check
alter table team_members add constraint team_members_left_reason_check CHECK (((left_reason IS NULL) OR (left_reason = ANY (ARRAY['quit'::text, 'kicked'::text, 'disband'::text]))));

-- [4.3] team_members.team_members_left_shape_check
alter table team_members add constraint team_members_left_shape_check CHECK (((left_at IS NULL) = (left_reason IS NULL)));

-- [4.3] team_members.team_members_role_check
alter table team_members add constraint team_members_role_check CHECK ((role = ANY (ARRAY['leader'::text, 'co_leader'::text, 'member'::text])));

-- [4.3] team_requests.team_requests_decided_shape_check
alter table team_requests add constraint team_requests_decided_shape_check CHECK (((status = 'pending'::text) = (decided_at IS NULL)));

-- [4.3] team_requests.team_requests_kind_check
alter table team_requests add constraint team_requests_kind_check CHECK ((kind = ANY (ARRAY['apply'::text, 'invite'::text])));

-- [4.3] team_requests.team_requests_status_check
alter table team_requests add constraint team_requests_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'accepted'::text, 'rejected'::text, 'cancelled'::text, 'expired'::text])));

-- [4.3] teams.teams_crest_emoji_len_check
alter table teams add constraint teams_crest_emoji_len_check CHECK (((crest_emoji IS NULL) OR (char_length(crest_emoji) <= 8)));

-- [4.3] teams.teams_crest_source_check
alter table teams add constraint teams_crest_source_check CHECK ((crest_source = ANY (ARRAY['default'::text, 'photo'::text])));

-- [4.3] teams.teams_intro_len_check
alter table teams add constraint teams_intro_len_check CHECK (((intro IS NULL) OR (char_length(intro) <= 200)));

-- [4.3] teams.teams_join_policy_check
alter table teams add constraint teams_join_policy_check CHECK ((join_policy = ANY (ARRAY['open'::text, 'approval'::text, 'closed'::text])));

-- [4.3] teams.teams_member_limit_check
alter table teams add constraint teams_member_limit_check CHECK (((member_limit >= 4) AND (member_limit <= 500)));

-- [4.3] teams.teams_monthly_goal_check
alter table teams add constraint teams_monthly_goal_check CHECK (((monthly_goal >= 1) AND (monthly_goal <= 999)));

-- [4.3] teams.teams_name_len_check
alter table teams add constraint teams_name_len_check CHECK (((char_length(btrim(name)) >= 2) AND (char_length(btrim(name)) <= 20)));

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

-- [5.0] achievement_tiers.achievement_tiers_achievement_id_fkey
alter table achievement_tiers add constraint achievement_tiers_achievement_id_fkey FOREIGN KEY (achievement_id) REFERENCES achievements(id) ON DELETE CASCADE;

-- [5.0] achievement_tiers.achievement_tiers_org_id_fkey
alter table achievement_tiers add constraint achievement_tiers_org_id_fkey FOREIGN KEY (org_id) REFERENCES orgs(id) ON DELETE RESTRICT;

-- [5.0] achievements.achievements_org_id_fkey
alter table achievements add constraint achievements_org_id_fkey FOREIGN KEY (org_id) REFERENCES orgs(id) ON DELETE RESTRICT;

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

-- [5.0] bookings.bookings_created_by_staff_id_fkey
alter table bookings add constraint bookings_created_by_staff_id_fkey FOREIGN KEY (created_by_staff_id) REFERENCES staff(id);

-- [5.0] bookings.bookings_member_id_fkey
alter table bookings add constraint bookings_member_id_fkey FOREIGN KEY (member_id) REFERENCES members(id);

-- [5.0] bookings.bookings_org_id_fkey
alter table bookings add constraint bookings_org_id_fkey FOREIGN KEY (org_id) REFERENCES orgs(id);

-- [5.0] bookings.bookings_seated_session_id_fkey
alter table bookings add constraint bookings_seated_session_id_fkey FOREIGN KEY (seated_session_id) REFERENCES table_sessions(id);

-- [5.0] bookings.bookings_stake_level_id_fkey
alter table bookings add constraint bookings_stake_level_id_fkey FOREIGN KEY (stake_level_id) REFERENCES stake_levels(id);

-- [5.0] bookings.bookings_store_id_fkey
alter table bookings add constraint bookings_store_id_fkey FOREIGN KEY (store_id) REFERENCES stores(id);

-- [5.0] bookings.bookings_table_id_fkey
alter table bookings add constraint bookings_table_id_fkey FOREIGN KEY (table_id) REFERENCES tables(id);

-- [5.0] bookings.bookings_team_id_fkey
alter table bookings add constraint bookings_team_id_fkey FOREIGN KEY (team_id) REFERENCES teams(id);

-- [5.0] buddy_invites.buddy_invites_invitee_id_fkey
alter table buddy_invites add constraint buddy_invites_invitee_id_fkey FOREIGN KEY (invitee_id) REFERENCES members(id) ON DELETE RESTRICT;

-- [5.0] buddy_invites.buddy_invites_inviter_id_fkey
alter table buddy_invites add constraint buddy_invites_inviter_id_fkey FOREIGN KEY (inviter_id) REFERENCES members(id) ON DELETE RESTRICT;

-- [5.0] buddy_invites.buddy_invites_org_id_fkey
alter table buddy_invites add constraint buddy_invites_org_id_fkey FOREIGN KEY (org_id) REFERENCES orgs(id) ON DELETE RESTRICT;

-- [5.0] coupon_scopes.coupon_scopes_coupon_id_fkey
alter table coupon_scopes add constraint coupon_scopes_coupon_id_fkey FOREIGN KEY (coupon_id) REFERENCES coupons(id);

-- [5.0] coupon_scopes.coupon_scopes_org_id_fkey
alter table coupon_scopes add constraint coupon_scopes_org_id_fkey FOREIGN KEY (org_id) REFERENCES orgs(id);

-- [5.0] coupons.coupons_free_product_id_fkey
alter table coupons add constraint coupons_free_product_id_fkey FOREIGN KEY (free_product_id) REFERENCES products(id) ON DELETE RESTRICT;

-- [5.0] coupons.coupons_org_id_fkey
alter table coupons add constraint coupons_org_id_fkey FOREIGN KEY (org_id) REFERENCES orgs(id) ON DELETE RESTRICT;

-- [5.0] doc_counters.doc_counters_org_id_fkey
alter table doc_counters add constraint doc_counters_org_id_fkey FOREIGN KEY (org_id) REFERENCES orgs(id) ON DELETE RESTRICT;

-- [5.0] doc_counters.doc_counters_store_id_fkey
alter table doc_counters add constraint doc_counters_store_id_fkey FOREIGN KEY (store_id) REFERENCES stores(id) ON DELETE RESTRICT;

-- [5.0] hands.hands_org_id_fkey
alter table hands add constraint hands_org_id_fkey FOREIGN KEY (org_id) REFERENCES orgs(id);

-- [5.0] hands.hands_round_id_fkey
alter table hands add constraint hands_round_id_fkey FOREIGN KEY (round_id) REFERENCES session_rounds(id);

-- [5.0] hands.hands_session_id_fkey
alter table hands add constraint hands_session_id_fkey FOREIGN KEY (session_id) REFERENCES table_sessions(id);

-- [5.0] hands.hands_submitted_device_id_fkey
alter table hands add constraint hands_submitted_device_id_fkey FOREIGN KEY (submitted_device_id) REFERENCES table_devices(id);

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

-- [5.0] match_queues.match_queues_credited_staff_id_fkey
alter table match_queues add constraint match_queues_credited_staff_id_fkey FOREIGN KEY (credited_staff_id) REFERENCES staff(id);

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

-- [5.0] member_achievements.member_achievements_achievement_id_fkey
alter table member_achievements add constraint member_achievements_achievement_id_fkey FOREIGN KEY (achievement_id) REFERENCES achievements(id) ON DELETE RESTRICT;

-- [5.0] member_achievements.member_achievements_member_id_fkey
alter table member_achievements add constraint member_achievements_member_id_fkey FOREIGN KEY (member_id) REFERENCES members(id) ON DELETE RESTRICT;

-- [5.0] member_achievements.member_achievements_org_id_fkey
alter table member_achievements add constraint member_achievements_org_id_fkey FOREIGN KEY (org_id) REFERENCES orgs(id) ON DELETE RESTRICT;

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

-- [5.0] member_hidden.member_hidden_member_id_fkey
alter table member_hidden add constraint member_hidden_member_id_fkey FOREIGN KEY (member_id) REFERENCES members(id);

-- [5.0] member_hide_log.member_hide_log_by_staff_id_fkey
alter table member_hide_log add constraint member_hide_log_by_staff_id_fkey FOREIGN KEY (by_staff_id) REFERENCES staff(id);

-- [5.0] member_hide_log.member_hide_log_member_id_fkey
alter table member_hide_log add constraint member_hide_log_member_id_fkey FOREIGN KEY (member_id) REFERENCES members(id);

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

-- [5.0] members.members_best_rank_tier_fkey
alter table members add constraint members_best_rank_tier_fkey FOREIGN KEY (best_rank_tier) REFERENCES rank_tiers(code);

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

-- [5.0] season_start_ratings.season_start_ratings_member_id_fkey
alter table season_start_ratings add constraint season_start_ratings_member_id_fkey FOREIGN KEY (member_id) REFERENCES members(id);

-- [5.0] season_start_ratings.season_start_ratings_org_id_fkey
alter table season_start_ratings add constraint season_start_ratings_org_id_fkey FOREIGN KEY (org_id) REFERENCES orgs(id);

-- [5.0] session_busts.session_busts_hand_id_fkey
alter table session_busts add constraint session_busts_hand_id_fkey FOREIGN KEY (hand_id) REFERENCES hands(id);

-- [5.0] session_busts.session_busts_org_id_fkey
alter table session_busts add constraint session_busts_org_id_fkey FOREIGN KEY (org_id) REFERENCES orgs(id);

-- [5.0] session_busts.session_busts_session_id_fkey
alter table session_busts add constraint session_busts_session_id_fkey FOREIGN KEY (session_id) REFERENCES table_sessions(id);

-- [5.0] session_extensions.session_extensions_member_id_fkey
alter table session_extensions add constraint session_extensions_member_id_fkey FOREIGN KEY (member_id) REFERENCES members(id);

-- [5.0] session_extensions.session_extensions_order_id_fkey
alter table session_extensions add constraint session_extensions_order_id_fkey FOREIGN KEY (order_id) REFERENCES orders(id);

-- [5.0] session_extensions.session_extensions_paid_by_fkey
alter table session_extensions add constraint session_extensions_paid_by_fkey FOREIGN KEY (paid_by) REFERENCES members(id);

-- [5.0] session_extensions.session_extensions_session_id_fkey
alter table session_extensions add constraint session_extensions_session_id_fkey FOREIGN KEY (session_id) REFERENCES table_sessions(id);

-- [5.0] session_players.session_players_device_id_fkey
alter table session_players add constraint session_players_device_id_fkey FOREIGN KEY (device_id) REFERENCES table_devices(id);

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

-- [5.0] session_rounds.session_rounds_org_id_fkey
alter table session_rounds add constraint session_rounds_org_id_fkey FOREIGN KEY (org_id) REFERENCES orgs(id);

-- [5.0] session_rounds.session_rounds_session_id_fkey
alter table session_rounds add constraint session_rounds_session_id_fkey FOREIGN KEY (session_id) REFERENCES table_sessions(id);

-- [5.0] snack_grants.snack_grants_member_id_fkey
alter table snack_grants add constraint snack_grants_member_id_fkey FOREIGN KEY (member_id) REFERENCES members(id) ON DELETE RESTRICT;

-- [5.0] snack_grants.snack_grants_org_id_fkey
alter table snack_grants add constraint snack_grants_org_id_fkey FOREIGN KEY (org_id) REFERENCES orgs(id) ON DELETE RESTRICT;

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

-- [5.0] stores.stores_on_duty_staff_id_fkey
alter table stores add constraint stores_on_duty_staff_id_fkey FOREIGN KEY (on_duty_staff_id) REFERENCES staff(id);

-- [5.0] stores.stores_org_id_fkey
alter table stores add constraint stores_org_id_fkey FOREIGN KEY (org_id) REFERENCES orgs(id) ON DELETE RESTRICT;

-- [5.0] table_devices.table_devices_org_id_fkey
alter table table_devices add constraint table_devices_org_id_fkey FOREIGN KEY (org_id) REFERENCES orgs(id);

-- [5.0] table_devices.table_devices_store_id_fkey
alter table table_devices add constraint table_devices_store_id_fkey FOREIGN KEY (store_id) REFERENCES stores(id);

-- [5.0] table_devices.table_devices_table_id_fkey
alter table table_devices add constraint table_devices_table_id_fkey FOREIGN KEY (table_id) REFERENCES tables(id);

-- [5.0] table_sessions.table_sessions_closed_by_staff_id_fkey
alter table table_sessions add constraint table_sessions_closed_by_staff_id_fkey FOREIGN KEY (closed_by_staff_id) REFERENCES staff(id);

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

-- [5.0] team_invite_links.team_invite_links_created_by_fkey
alter table team_invite_links add constraint team_invite_links_created_by_fkey FOREIGN KEY (created_by) REFERENCES members(id);

-- [5.0] team_invite_links.team_invite_links_org_id_fkey
alter table team_invite_links add constraint team_invite_links_org_id_fkey FOREIGN KEY (org_id) REFERENCES orgs(id);

-- [5.0] team_invite_links.team_invite_links_team_id_fkey
alter table team_invite_links add constraint team_invite_links_team_id_fkey FOREIGN KEY (team_id) REFERENCES teams(id);

-- [5.0] team_invite_links.team_invite_links_used_by_fkey
alter table team_invite_links add constraint team_invite_links_used_by_fkey FOREIGN KEY (used_by) REFERENCES members(id);

-- [5.0] team_members.team_members_member_id_fkey
alter table team_members add constraint team_members_member_id_fkey FOREIGN KEY (member_id) REFERENCES members(id);

-- [5.0] team_members.team_members_org_id_fkey
alter table team_members add constraint team_members_org_id_fkey FOREIGN KEY (org_id) REFERENCES orgs(id);

-- [5.0] team_members.team_members_team_id_fkey
alter table team_members add constraint team_members_team_id_fkey FOREIGN KEY (team_id) REFERENCES teams(id);

-- [5.0] team_requests.team_requests_created_by_fkey
alter table team_requests add constraint team_requests_created_by_fkey FOREIGN KEY (created_by) REFERENCES members(id);

-- [5.0] team_requests.team_requests_decided_by_fkey
alter table team_requests add constraint team_requests_decided_by_fkey FOREIGN KEY (decided_by) REFERENCES members(id);

-- [5.0] team_requests.team_requests_member_id_fkey
alter table team_requests add constraint team_requests_member_id_fkey FOREIGN KEY (member_id) REFERENCES members(id);

-- [5.0] team_requests.team_requests_org_id_fkey
alter table team_requests add constraint team_requests_org_id_fkey FOREIGN KEY (org_id) REFERENCES orgs(id);

-- [5.0] team_requests.team_requests_team_id_fkey
alter table team_requests add constraint team_requests_team_id_fkey FOREIGN KEY (team_id) REFERENCES teams(id);

-- [5.0] teams.teams_created_by_fkey
alter table teams add constraint teams_created_by_fkey FOREIGN KEY (created_by) REFERENCES members(id);

-- [5.0] teams.teams_home_store_id_fkey
alter table teams add constraint teams_home_store_id_fkey FOREIGN KEY (home_store_id) REFERENCES stores(id);

-- [5.0] teams.teams_org_id_fkey
alter table teams add constraint teams_org_id_fkey FOREIGN KEY (org_id) REFERENCES orgs(id);

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

-- [6.0] idx_ach_trigger_event
CREATE INDEX idx_ach_trigger_event ON public.achievements USING btree (((trigger ->> 'event'::text))) WHERE (is_active AND (deleted_at IS NULL));

-- [6.0] idx_acht_ach
CREATE INDEX idx_acht_ach ON public.achievement_tiers USING btree (achievement_id, threshold);

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

-- [6.0] idx_hands_session
CREATE INDEX idx_hands_session ON public.hands USING btree (session_id, created_at);

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

-- [6.0] idx_ma_member
CREATE INDEX idx_ma_member ON public.member_achievements USING btree (org_id, member_id);

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

-- [6.0] idx_session_busts_session
CREATE INDEX idx_session_busts_session ON public.session_busts USING btree (session_id);

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

-- [6.0] idx_table_devices_table
CREATE INDEX idx_table_devices_table ON public.table_devices USING btree (table_id) WHERE is_active;

-- [6.0] idx_tables_store
CREATE INDEX idx_tables_store ON public.tables USING btree (store_id) WHERE (deleted_at IS NULL);

-- [6.0] idx_tables_store_area
CREATE INDEX idx_tables_store_area ON public.tables USING btree (store_id, area, sort_order);

-- [6.0] idx_team_invite_links_team
CREATE INDEX idx_team_invite_links_team ON public.team_invite_links USING btree (team_id) WHERE (used_at IS NULL);

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

-- [6.0] ix_bookings_member
CREATE INDEX ix_bookings_member ON public.bookings USING btree (member_id, play_at DESC);

-- [6.0] ix_bookings_store_time
CREATE INDEX ix_bookings_store_time ON public.bookings USING btree (store_id, play_at) WHERE (status = 'booked'::text);

-- [6.0] ix_bookings_table_window
CREATE INDEX ix_bookings_table_window ON public.bookings USING btree (store_id, table_id, play_at) WHERE ((status = 'booked'::text) AND (table_id IS NOT NULL));

-- [6.0] ix_bookings_team
CREATE INDEX ix_bookings_team ON public.bookings USING btree (team_id, play_at DESC) WHERE (team_id IS NOT NULL);

-- [6.0] ix_season_standings_member
CREATE INDEX ix_season_standings_member ON public.season_standings USING btree (org_id, member_id, rank_no);

-- [6.0] ix_snack_grants_member
CREATE INDEX ix_snack_grants_member ON public.snack_grants USING btree (member_id, created_at DESC);

-- [6.0] ix_team_members_member
CREATE INDEX ix_team_members_member ON public.team_members USING btree (member_id) WHERE (left_at IS NULL);

-- [6.0] ix_team_requests_member
CREATE INDEX ix_team_requests_member ON public.team_requests USING btree (member_id, status);

-- [6.0] ix_teams_home_store
CREATE INDEX ix_teams_home_store ON public.teams USING btree (org_id, home_store_id) WHERE (deleted_at IS NULL);

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

-- [6.0] uq_ach_code
CREATE UNIQUE INDEX uq_ach_code ON public.achievements USING btree (org_id, code) WHERE (deleted_at IS NULL);

-- [6.0] uq_availability
CREATE UNIQUE INDEX uq_availability ON public.member_availability USING btree (member_id, weekday, slot, source);

-- [6.0] uq_block_pair
CREATE UNIQUE INDEX uq_block_pair ON public.member_blocks USING btree (blocker_id, blocked_id);

-- [6.0] uq_buddies
CREATE UNIQUE INDEX uq_buddies ON public.mahjong_buddies USING btree (member_id, buddy_id) WHERE (deleted_at IS NULL);

-- [6.0] uq_hands_confirmed_no
CREATE UNIQUE INDEX uq_hands_confirmed_no ON public.hands USING btree (round_id, hand_no) WHERE ((status = 'confirmed'::text) AND (result <> 'kala'::text));

-- [6.0] uq_hands_one_pending
CREATE UNIQUE INDEX uq_hands_one_pending ON public.hands USING btree (round_id) WHERE (status = 'pending'::text);

-- [6.0] uq_like_per_session
CREATE UNIQUE INDEX uq_like_per_session ON public.member_likes USING btree (liker_id, target_id, session_id) WHERE (session_id IS NOT NULL);

-- [6.0] uq_ma_pinned
CREATE UNIQUE INDEX uq_ma_pinned ON public.member_achievements USING btree (member_id) WHERE pinned;

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

-- [6.0] uq_session_busts_pending
CREATE UNIQUE INDEX uq_session_busts_pending ON public.session_busts USING btree (session_id, seat) WHERE (decision = 'pending'::text);

-- [6.0] uq_session_extensions
CREATE UNIQUE INDEX uq_session_extensions ON public.session_extensions USING btree (session_id, member_id, to_minutes);

-- [6.0] uq_session_extensions_daypass
CREATE UNIQUE INDEX uq_session_extensions_daypass ON public.session_extensions USING btree (session_id, member_id) WHERE (kind = 'daypass'::text);

-- [6.0] uq_session_player
CREATE UNIQUE INDEX uq_session_player ON public.session_players USING btree (session_id, member_id);

-- [6.0] uq_session_players_device
CREATE UNIQUE INDEX uq_session_players_device ON public.session_players USING btree (session_id, device_id) WHERE (device_id IS NOT NULL);

-- [6.0] uq_session_players_seat
CREATE UNIQUE INDEX uq_session_players_seat ON public.session_players USING btree (session_id, seat) WHERE (seat IS NOT NULL);

-- [6.0] uq_session_rounds_no
CREATE UNIQUE INDEX uq_session_rounds_no ON public.session_rounds USING btree (session_id, round_no) WHERE (status <> 'voided'::text);

-- [6.0] uq_session_rounds_playing
CREATE UNIQUE INDEX uq_session_rounds_playing ON public.session_rounds USING btree (session_id) WHERE (status = 'playing'::text);

-- [6.0] uq_sessions_idem
CREATE UNIQUE INDEX uq_sessions_idem ON public.table_sessions USING btree (idempotency_key) WHERE (idempotency_key IS NOT NULL);

-- [6.0] uq_sessions_open_table
CREATE UNIQUE INDEX uq_sessions_open_table ON public.table_sessions USING btree (table_id) WHERE ((status = 'open'::text) AND (deleted_at IS NULL));

-- [6.0] uq_snack_grants_idem
CREATE UNIQUE INDEX uq_snack_grants_idem ON public.snack_grants USING btree (idem_key);

-- [6.0] uq_staff_member_store
CREATE UNIQUE INDEX uq_staff_member_store ON public.staff USING btree (member_id, store_id) WHERE (deleted_at IS NULL);

-- [6.0] uq_stake_label
CREATE UNIQUE INDEX uq_stake_label ON public.stake_levels USING btree (org_id, label) WHERE (deleted_at IS NULL);

-- [6.0] uq_tables_store_label
CREATE UNIQUE INDEX uq_tables_store_label ON public.tables USING btree (store_id, label) WHERE (deleted_at IS NULL);

-- [6.0] uq_team_member_active
CREATE UNIQUE INDEX uq_team_member_active ON public.team_members USING btree (team_id, member_id) WHERE (left_at IS NULL);

-- [6.0] uq_team_one_leader
CREATE UNIQUE INDEX uq_team_one_leader ON public.team_members USING btree (team_id) WHERE ((role = 'leader'::text) AND (left_at IS NULL));

-- [6.0] uq_team_request_pending
CREATE UNIQUE INDEX uq_team_request_pending ON public.team_requests USING btree (team_id, member_id) WHERE (status = 'pending'::text);

-- [6.0] uq_teams_name
CREATE UNIQUE INDEX uq_teams_name ON public.teams USING btree (org_id, lower(btrim(name))) WHERE (deleted_at IS NULL);

-- [6.0] uq_topup_plans_tier
CREATE UNIQUE INDEX uq_topup_plans_tier ON public.topup_plans USING btree (org_id, COALESCE(store_id, '00000000-0000-0000-0000-000000000000'::uuid), min_amount);

-- [6.0] uq_txn_idempotency
CREATE UNIQUE INDEX uq_txn_idempotency ON public.wallet_txns USING btree (org_id, idempotency_key) WHERE (idempotency_key IS NOT NULL);

-- [7.0] _ach_live
CREATE OR REPLACE FUNCTION public._ach_live(a achievements)
 RETURNS boolean
 LANGUAGE sql
 IMMUTABLE
AS $function$
  select a.is_active
     and a.deleted_at is null
     and (a.valid_from is null or now() >= a.valid_from)
     and (a.valid_to   is null or now() <  a.valid_to)
$function$
;

-- [7.0] _ach_season_close_events
CREATE OR REPLACE FUNCTION public._ach_season_close_events(p_org uuid, p_season text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_from timestamptz; v_to timestamptz; v_prev_code text;
  v_champ uuid; v_idem text := 'season:' || p_season;
  v_r record; v_start int; v_ev text[]; v_e text; v_fired int := 0;
  v_seq int[]; v_ok boolean; i int; v_months int; v_hit int;
begin
  select starts_at, ends_at into v_from, v_to from rank_seasons where org_id = p_org and code = p_season;
  if v_from is null then return jsonb_build_object('ok', false, 'reason', 'season_not_found'); end if;
  select member_id into v_champ from season_champions where org_id = p_org and season = p_season;

  -- 這一季有幾個月（台北時間）
  select count(*) into v_months
    from generate_series(date_trunc('month', v_from at time zone 'Asia/Taipei'),
                         (v_to at time zone 'Asia/Taipei') - interval '1 second', interval '1 month') g;

  for v_r in
    select st.member_id, st.rating as end_rating, st.rank_no, st.games
      from season_standings st
     where st.org_id = p_org and st.season = p_season
  loop
    v_ev := '{}';

    -- 起點：快照優先；沒有就用本季開始前最後一場結算後的段位分
    select s.rating into v_start from season_start_ratings s
     where s.org_id = p_org and s.season = p_season and s.member_id = v_r.member_id;
    if v_start is null then
      select sp.rating_after into v_start
        from session_players sp
       where sp.member_id = v_r.member_id and sp.settled_at is not null and sp.rating_after is not null
         and sp.settled_at < v_from
       order by sp.settled_at desc limit 1;
    end if;

    if v_r.rank_no <= 100 then v_ev := array_append(v_ev, 'season_top100'); end if;
    if v_r.rank_no <= 10  then v_ev := array_append(v_ev, 'season_top10');  end if;
    if v_champ = v_r.member_id then
      v_ev := array_append(v_ev, 'season_champion');
      if (select count(*) from season_champions c where c.org_id = p_org and c.member_id = v_r.member_id) >= 2 then
        v_ev := array_append(v_ev, 'season_champion_2');
      end if;
    end if;

    -- 賽季進步
    if v_start is not null and v_r.end_rating > v_start
       and public.rank_from_rating(v_r.end_rating) <> public.rank_from_rating(v_start) then
      v_ev := array_append(v_ev, 'season_progress');
    end if;

    -- 賽季全勤：每個月都結算過一場
    select count(distinct date_trunc('month', sp.settled_at at time zone 'Asia/Taipei')) into v_hit
      from session_players sp
     where sp.member_id = v_r.member_id and sp.settled_at >= v_from and sp.settled_at < v_to
       and sp.finish_rank is not null;
    if v_months > 0 and v_hit >= v_months then v_ev := array_append(v_ev, 'season_all_months'); end if;

    -- 整季不降階：至少 10 場
    if v_r.games >= 10 then
      select array_agg(x.r order by x.o) into v_seq
        from (select v_start as r, 0 as o where v_start is not null
              union all
              select sp.rating_after, row_number() over (order by sp.settled_at, sp.session_id)
                from session_players sp
               where sp.member_id = v_r.member_id and sp.settled_at >= v_from and sp.settled_at < v_to
                 and sp.rating_after is not null) x;
      v_ok := true;
      for i in 2 .. coalesce(array_length(v_seq, 1), 0) loop
        if v_seq[i] < v_seq[i-1] and public.rank_from_rating(v_seq[i]) <> public.rank_from_rating(v_seq[i-1]) then
          v_ok := false;
        end if;
      end loop;
      if v_ok then v_ev := array_append(v_ev, 'rank_no_drop_season'); end if;
    end if;

    foreach v_e in array v_ev loop
      perform public.fire_event_tx(v_r.member_id, v_e, 1, null, v_idem);
      v_fired := v_fired + 1;
    end loop;
  end loop;

  return jsonb_build_object('ok', true, 'season', p_season, 'fired', v_fired);
end $function$
;

-- [7.0] _ach_session_events
CREATE OR REPLACE FUNCTION public._ach_session_events(p_session_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_s      public.table_sessions;
  v_idem   text := 'settle2:' || p_session_id::text;
  v_end    timestamptz;
  v_day    date;
  v_p      record;
  v_ev     text[];
  v_e      text;
  v_fired  int := 0;
  v_n int; v_scored int; v_allpos boolean;
  v_arr    bigint[];
  v_g bigint[]; v_c bigint[]; v_k bigint[]; v_nr int; i int; v_ok boolean;
  v_big int; v_late int; v_dealin int; v_dwin int; v_dtsumo int; v_renz int; v_break int; v_hands int;
  v_finished int;
  v_prev_sid uuid; v_prev_seat smallint; v_prev_rating int;
  v_diamond int; v_master int;
begin
  select * into v_s from public.table_sessions where id = p_session_id;
  if not found or v_s.status <> 'completed' then
    return jsonb_build_object('ok', false, 'reason', 'not_completed');
  end if;
  v_end := coalesce(v_s.ended_at, now());
  v_day := (v_end at time zone 'Asia/Taipei')::date;
  select count(*) into v_finished from public.session_rounds where session_id = p_session_id and status = 'finished';
  select sort into v_diamond from public.rank_tiers where code = 'diamond';
  select sort into v_master  from public.rank_tiers where code = 'master';

  for v_p in
    select sp.member_id, sp.seat, sp.final_score, sp.finish_rank, sp.rating_after
      from public.session_players sp
     where sp.session_id = p_session_id and sp.member_id is not null
  loop
    v_ev := '{}';

    /* ── 同一天的場數（台北日曆日，與當日暢打同一個判準）── */
    select count(distinct ts.id),
           count(distinct ts.id) filter (where sp2.final_score is not null),
           coalesce(bool_and(sp2.final_score > 0) filter (where sp2.final_score is not null), false)
      into v_n, v_scored, v_allpos
      from public.session_players sp2
      join public.table_sessions ts on ts.id = sp2.session_id
     where sp2.member_id = v_p.member_id and ts.status = 'completed' and ts.deleted_at is null
       and (coalesce(ts.ended_at, now()) at time zone 'Asia/Taipei')::date = v_day;
    if v_n >= 2 then v_ev := array_append(v_ev, 'day_sessions_2'); end if;
    if v_n >= 3 then v_ev := array_append(v_ev, 'day_sessions_3'); end if;
    if v_scored >= 2 and v_allpos then v_ev := array_append(v_ev, 'day_all_positive'); end if;

    /* ── 連續為正：只看有記積分的場（純娛樂是 null，不算也不打斷）── */
    if coalesce(v_p.final_score, 0) > 0 then
      select array_agg(fs order by e desc) into v_arr
        from (select sp2.final_score::bigint as fs, ts.ended_at as e
                from public.session_players sp2
                join public.table_sessions ts on ts.id = sp2.session_id
               where sp2.member_id = v_p.member_id and ts.status = 'completed' and ts.deleted_at is null
                 and sp2.final_score is not null
                 and (ts.id = p_session_id or ts.ended_at <= v_end)
               order by ts.ended_at desc limit 5) z;
      if coalesce(array_length(v_arr, 1), 0) >= 3 and v_arr[1] > 0 and v_arr[2] > 0 and v_arr[3] > 0 then
        v_ev := array_append(v_ev, 'streak_positive_3');
      end if;
      if coalesce(array_length(v_arr, 1), 0) >= 5 and v_arr[1] > 0 and v_arr[2] > 0 and v_arr[3] > 0 and v_arr[4] > 0 and v_arr[5] > 0 then
        v_ev := array_append(v_ev, 'streak_positive_5');
      end if;
    end if;

    /* ── 名次 ── */
    if v_p.finish_rank = 1 then
      v_ev := array_append(v_ev, 'session_first_place');
      select array_agg(fr order by e desc) into v_arr
        from (select sp2.finish_rank::bigint as fr, ts.ended_at as e
                from public.session_players sp2
                join public.table_sessions ts on ts.id = sp2.session_id
               where sp2.member_id = v_p.member_id and ts.status = 'completed' and ts.deleted_at is null
                 and sp2.finish_rank is not null
                 and (ts.id = p_session_id or ts.ended_at <= v_end)
               order by ts.ended_at desc limit 2) z;
      if coalesce(array_length(v_arr, 1), 0) >= 2 and v_arr[1] = 1 and v_arr[2] = 1 then
        v_ev := array_append(v_ev, 'streak_first_2');
      end if;
    end if;

    /* ── 單場桌上積分 ── */
    if v_p.final_score is not null then
      if v_p.final_score >= 1000  then v_ev := array_append(v_ev, 'score_1000');  end if;
      if v_p.final_score >= 3000  then v_ev := array_append(v_ev, 'score_3000');  end if;
      if v_p.final_score >= 6000  then v_ev := array_append(v_ev, 'score_6000');  end if;
      if v_p.final_score >= 10000 then v_ev := array_append(v_ev, 'score_10000'); end if;
    end if;

    /* ── 每一局（電子計分）── */
    if v_p.seat is not null then
      select count(*) filter (where h.winner_seat = v_p.seat and h.result in ('ron','tsumo') and h.tai_pattern >= 8),
             count(*) filter (where h.winner_seat = v_p.seat and h.result in ('ron','tsumo') and h.tai_pattern >= 8
                                and public.migi_slot_of(h.created_at) = 'late'),
             count(*) filter (where h.deal_in_seat = v_p.seat and h.result in ('ron','bao')),
             count(*) filter (where h.winner_seat = v_p.seat and h.dealer_seat = v_p.seat and h.result in ('ron','tsumo')),
             count(*) filter (where h.winner_seat = v_p.seat and h.dealer_seat = v_p.seat and h.result = 'tsumo'),
             coalesce(max(h.renzhuang) filter (where h.dealer_seat = v_p.seat and h.result <> 'kala'), 0),
             count(*) filter (where h.renzhuang >= 1 and h.winner_seat = v_p.seat
                                and h.winner_seat <> h.dealer_seat and h.result in ('ron','tsumo')),
             count(*)
        into v_big, v_late, v_dealin, v_dwin, v_dtsumo, v_renz, v_break, v_hands
        from public.hands h
       where h.session_id = p_session_id and h.status = 'confirmed';

      if v_late >= 1 then v_ev := array_append(v_ev, 'big_hand_late'); end if;
      if v_big  >= 2 then v_ev := array_append(v_ev, 'big_hand_twice'); end if;
      if v_big  >= 1 then
        v_prev_sid := null; v_prev_seat := null;
        select ts.id, sp2.seat into v_prev_sid, v_prev_seat
          from public.session_players sp2
          join public.table_sessions ts on ts.id = sp2.session_id
         where sp2.member_id = v_p.member_id and ts.status = 'completed' and ts.deleted_at is null
           and ts.id <> p_session_id and ts.ended_at < v_end
         order by ts.ended_at desc limit 1;
        if v_prev_sid is not null and exists (
             select 1 from public.hands h
              where h.session_id = v_prev_sid and h.status = 'confirmed' and h.winner_seat = v_prev_seat
                and h.result in ('ron','tsumo') and h.tai_pattern >= 8) then
          v_ev := array_append(v_ev, 'big_hand_2_sessions');
        end if;
      end if;
      if v_hands > 0 and v_dealin = 0 and v_s.planned_rounds is not null and v_finished >= v_s.planned_rounds then
        v_ev := array_append(v_ev, 'no_deal_in');
      end if;
      if v_dwin   >= 1 then v_ev := array_append(v_ev, 'dealer_won'); end if;
      if v_dtsumo >= 1 then v_ev := array_append(v_ev, 'dealer_tsumo'); end if;
      if v_renz   >= 2 then v_ev := array_append(v_ev, 'renzhuang_2'); end if;
      if v_renz   >= 5 then v_ev := array_append(v_ev, 'renzhuang_5'); end if;
      if v_renz   >= 8 then v_ev := array_append(v_ev, 'renzhuang_8'); end if;
      if v_break  >= 1 then v_ev := array_append(v_ev, 'break_dealer'); end if;
    end if;

    /* ── 每一將結束的累積積分與名次（純娛樂不算）── */
    if v_p.final_score is not null and v_p.seat is not null then
      v_g := null; v_c := null; v_k := null;
      with rr as (select id, round_no from public.session_rounds
                   where session_id = p_session_id and status = 'finished'),
           dd as (select rr.round_no, e.key::int as seat, sum(e.value::numeric)::bigint as gain
                    from public.hands h
                    join rr on rr.id = h.round_id
                   cross join lateral jsonb_each_text(h.score_delta) e
                   where h.status = 'confirmed'
                   group by rr.round_no, e.key::int),
           cc as (select round_no, seat, gain,
                         (sum(gain) over (partition by seat order by round_no))::bigint as cum
                    from dd),
           kk as (select c1.round_no, c1.seat, c1.gain, c1.cum,
                         (1 + (select count(*) from cc c2 where c2.round_no = c1.round_no and c2.cum > c1.cum))::bigint as place
                    from cc c1)
      select array_agg(kk.gain order by kk.round_no), array_agg(kk.cum order by kk.round_no), array_agg(kk.place order by kk.round_no)
        into v_g, v_c, v_k
        from kk where kk.seat = v_p.seat;
      v_nr := coalesce(array_length(v_c, 1), 0);

      if v_nr >= 1 and v_c[1] > 0 and v_k[1] = 1 then v_ev := array_append(v_ev, 'swing_first_lead'); end if;
      if v_nr >= 2 and v_c[1] > 0 and v_c[2] > 0 then v_ev := array_append(v_ev, 'swing_hold_second'); end if;
      if v_nr = 3 and v_k[2] <> 1 and v_k[3] = 1 then v_ev := array_append(v_ev, 'swing_third_decides'); end if;
      if v_nr >= 2 then
        v_ok := false;
        for i in 2 .. v_nr loop
          if v_c[i-1] < 0 and v_c[i] > 0 then v_ok := true; end if;
        end loop;
        if v_ok then v_ev := array_append(v_ev, 'swing_neg_to_pos'); end if;
        v_ok := true;
        for i in 1 .. v_nr loop
          if v_k[i] <> 1 then v_ok := false; end if;
        end loop;
        if v_ok then v_ev := array_append(v_ev, 'swing_lead_all'); end if;
        v_ok := true;
        for i in 2 .. v_nr loop
          if v_g[i] <= v_g[i-1] then v_ok := false; end if;
        end loop;
        if v_ok then v_ev := array_append(v_ev, 'swing_steady'); end if;
      end if;
      if v_nr = 3 and v_c[1] <= 0 and v_c[2] <= 0 and v_c[3] > 0 then v_ev := array_append(v_ev, 'swing_last_boarding'); end if;
      if v_nr = 3 and v_k[2] = 4 and v_k[3] = 1 then v_ev := array_append(v_ev, 'swing_comeback'); end if;
      if v_nr = 3 and v_c[1] > 0 and v_c[2] > 0 and v_c[3] > 0 then v_ev := array_append(v_ev, 'rounds_all_positive'); end if;
    end if;

    /* ── 爆卡（純娛樂不算，同其他積分類；撤銷掉的那一局不算）── */
    if v_p.final_score is not null and v_p.seat is not null then
      if exists (select 1 from public.session_busts b
                  where b.session_id = p_session_id and b.seat = v_p.seat and b.decision <> 'voided') then
        v_ev := array_append(v_ev, 'bust');
      end if;
      if exists (select 1 from public.session_busts b
                  where b.session_id = p_session_id and b.by_seat = v_p.seat and b.decision <> 'voided') then
        v_ev := array_append(v_ev, 'bust_other');
      end if;
    end if;

    /* ── 單場段位分變動：跟自己上一場結算後的段位分比（第一場是定位賽，沒有上一場就不算）── */
    if v_p.rating_after is not null then
      v_prev_rating := null;
      select sp2.rating_after into v_prev_rating
        from public.session_players sp2
        join public.table_sessions ts on ts.id = sp2.session_id
       where sp2.member_id = v_p.member_id and ts.status = 'completed' and ts.deleted_at is null
         and ts.id <> p_session_id and sp2.rating_after is not null and ts.ended_at < v_end
       order by ts.ended_at desc limit 1;
      if v_prev_rating is not null and v_p.rating_after - v_prev_rating >= 30 then
        v_ev := array_append(v_ev, 'rating_jump_30');
      end if;
    end if;

    /* ── 同桌的人（看對方現在的段位；雀神看有沒有當過賽季冠軍）── */
    if exists (select 1 from public.session_players o
                 join public.members m on m.id = o.member_id
                 join public.rank_tiers t on t.code = public._rank_tier_of(m.rank)
                where o.session_id = p_session_id and o.member_id <> v_p.member_id and t.sort >= v_diamond) then
      v_ev := array_append(v_ev, 'table_with_diamond');
    end if;
    if exists (select 1 from public.session_players o
                 join public.members m on m.id = o.member_id
                 join public.rank_tiers t on t.code = public._rank_tier_of(m.rank)
                where o.session_id = p_session_id and o.member_id <> v_p.member_id and t.sort >= v_master) then
      v_ev := array_append(v_ev, 'table_with_master');
    end if;
    if exists (select 1 from public.session_players o
                 join public.season_champions c on c.member_id = o.member_id
                where o.session_id = p_session_id and o.member_id <> v_p.member_id) then
      v_ev := array_append(v_ev, 'table_with_champion');
    end if;

    /* ── 賽季首戰（2026-09-30）：本季以前打過，這是本季第一場 ── */
    if exists (select 1 from public.rank_seasons rs
                where rs.org_id = v_s.org_id and v_end >= rs.starts_at and v_end < rs.ends_at
                  and not exists (select 1 from public.session_players sp2
                                    join public.table_sessions ts on ts.id = sp2.session_id
                                   where sp2.member_id = v_p.member_id and ts.status = 'completed' and ts.deleted_at is null
                                     and ts.id <> p_session_id and ts.ended_at >= rs.starts_at and ts.ended_at < v_end)
                  and exists (select 1 from public.session_players sp2
                                join public.table_sessions ts on ts.id = sp2.session_id
                               where sp2.member_id = v_p.member_id and ts.status = 'completed' and ts.deleted_at is null
                                 and ts.ended_at < rs.starts_at)) then
      v_ev := array_append(v_ev, 'season_first_game');
    end if;

    foreach v_e in array v_ev loop
      perform public.fire_event_tx(v_p.member_id, v_e, 1, null, v_idem);
      v_fired := v_fired + 1;
    end loop;
  end loop;

  return jsonb_build_object('ok', true, 'fired', v_fired);
end $function$
;

-- [7.0] _api_staff_only
CREATE OR REPLACE FUNCTION public._api_staff_only()
 RETURNS void
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if (coalesce(current_setting('request.jwt.claims', true), '') <> ''
      or coalesce(current_setting('request.method', true), '') <> '')
     and not exists (select 1 from public.current_staff()) then
    raise exception '這個操作只有店員可以做' using errcode = '42501';
  end if;
end $function$
;

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

-- [7.0] _booking_capacity
CREATE OR REPLACE FUNCTION public._booking_capacity(p_store_id uuid, p_play_at timestamp with time zone, p_hours integer, p_exclude uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
AS $function$
  select jsonb_build_object(
    'total',  t.total,
    'booked', b.seated + b.loose,
    'free',   greatest(0, t.total - b.seated - b.loose))
  from (
    select count(*)::int as total
      from public.tables
     where store_id = p_store_id and is_active and deleted_at is null
  ) t,
  (
    select
      count(distinct k.table_id) filter (where k.table_id is not null)::int as seated,
      coalesce(sum(k.table_count) filter (where k.table_id is null), 0)::int as loose
      from public.bookings k
     where k.store_id = p_store_id
       and k.status = 'booked'
       and (p_exclude is null or k.id <> p_exclude)
       and p_play_at < k.play_at + make_interval(hours => k.planned_hours)
       and k.play_at < p_play_at + make_interval(hours => p_hours)
  ) b;
$function$
;

-- [7.0] _booking_expire
CREATE OR REPLACE FUNCTION public._booking_expire(p_store_id uuid DEFAULT NULL::uuid)
 RETURNS integer
 LANGUAGE plpgsql
AS $function$
declare v_n int;
begin
  update public.bookings
     set status = 'expired', updated_at = now()
   where status = 'booked'
     and play_at + make_interval(hours => planned_hours) < now()
     and (p_store_id is null or store_id = p_store_id);
  get diagnostics v_n = row_count;
  return v_n;
end $function$
;

-- [7.0] _booking_pick_table
CREATE OR REPLACE FUNCTION public._booking_pick_table(p_store_id uuid, p_play_at timestamp with time zone, p_hours integer, p_exclude uuid DEFAULT NULL::uuid)
 RETURNS uuid
 LANGUAGE sql
AS $function$
  select t.id
    from public.tables t
   where t.store_id = p_store_id
     and coalesce(t.is_active, true) = true
     and t.deleted_at is null
     and t.auto_assign = true
     and not exists (
       select 1 from public.bookings k
        where k.table_id = t.id
          and k.status = 'booked'
          and (p_exclude is null or k.id <> p_exclude)
          and p_play_at < k.play_at + make_interval(hours => k.planned_hours)
          and k.play_at < p_play_at + make_interval(hours => p_hours))
   order by t.sort_order nulls last, t.label
   limit 1
   for update of t skip locked;
$function$
;

-- [7.0] _booking_slots
CREATE OR REPLACE FUNCTION public._booking_slots(p_store_id uuid, p_day date, p_hours integer)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
AS $function$
  with s as (
    select open_time, close_time
      from public.stores
     where id = p_store_id and deleted_at is null
  ),
  win as (
    /* 跨午夜用日常寫法：11:00–02:00 的 02:00 屬於**隔天**。
       ⚠ `close = open` 視為 24 小時營業（今天沒有這種店，但寫法要撐得住）。 */
    select ((p_day + s.open_time) at time zone 'Asia/Taipei') as t0,
           ((case when s.close_time > s.open_time
                  then p_day + s.close_time
                  else (p_day + 1) + s.close_time end) at time zone 'Asia/Taipei') as t1
      from s
     where s.open_time is not null and s.close_time is not null
  ),
  g as (
    /* 最後一格是**打烊前最後一個半小時**。
       `t1 - 30 分鐘` 讓 02:00 打烊的店最後一格是 01:30，不是 02:00。 */
    select generate_series(w.t0, w.t1 - interval '30 minutes', interval '30 minutes') as at
      from win w
  )
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'at',    g.at,
        'label', to_char(g.at at time zone 'Asia/Taipei', 'HH24:MI'),
        /* 🔴 只有布林，**沒有任何數字**。
           後端當然要算桌數才知道滿沒滿，但算完就不要把數字送出去。 */
        'open',  (public._booking_capacity(p_store_id, g.at, p_hours) ->> 'free')::int >= 1
      ) order by g.at
    ),
    '[]'::jsonb)
  from g
  /* 兩道時間牆與 `create_booking_tx` **逐字相同**。
     🔴 太近／太遠的格子**整個不回**，不是回 `open = false` ——
       後者會讓客人讀成「那個時段滿了」，而那是一句錯的話
       （同「已收桌但沒名次」不可以說成「未成桌」）。
       時間過了本來就不在了，不需要解釋。 */
  where g.at >= now() + interval '30 minutes'
    and g.at <= now() + interval '90 days';
$function$
;

-- [7.0] _cart_pricing
CREATE OR REPLACE FUNCTION public._cart_pricing(p_org uuid, p_member_id uuid, p_items jsonb, p_coupon_ids uuid[])
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_tier text; v_pct int;
  v_sub bigint := 0; v_fee bigint := 0; v_fnb bigint := 0; v_goods bigint := 0;
  v_nodisc bigint := 0;   -- 不參與折扣的金額（只為驗算與回傳，不進任何桶）
  v_coupon_cut bigint := 0; v_tier_cut bigint; v_payable bigint;
  v_coupons jsonb := '[]'::jsonb;
  -- 每一個品項：商品、營收類別、子分類、扣的順序（檯費 1、餐飲 2、其餘 3）、可不可折、還剩多少可折
  l_pid uuid[] := '{}'; l_rt text[] := '{}'; l_sub text[] := '{}'; l_ord int[] := '{}';
  l_disc boolean[] := '{}'; l_rem bigint[] := '{}'; n int := 0;
  v_match boolean[]; v_has_scope boolean; v_rem_fee bigint;
  it jsonb; cp record; cap bigint; cut bigint; r bigint; d bigint; i int; k int;
begin
  /* 品項：前端只送「意圖」（product_id ＋ qty），其餘一律回查主檔（2026-08-27 起）。
     ⚠ 不過濾 is_active：結帳是已經發生的交易，不是決定要不要賣。 */
  if p_items is not null and jsonb_typeof(p_items) = 'array' then
    for it in select * from jsonb_array_elements(p_items) loop
      declare
        x_pid uuid := nullif(it->>'product_id','')::uuid;
        x_qty int := (it->>'qty')::int;
        x_price bigint; x_name text; x_bucket text; x_disc boolean; x_sub text; x_line bigint;
      begin
        if x_pid is null then
          raise exception '品項缺少 product_id：%', coalesce(it->>'name', '(未命名)');
        end if;
        select pr.unit_price, pr.name, pr.revenue_type, pr.discountable, pr.subcategory
          into x_price, x_name, x_bucket, x_disc, x_sub
          from public.products pr
         where pr.id = x_pid and pr.org_id = p_org and pr.deleted_at is null;
        if not found then
          raise exception '商品不存在或不屬於本機構：%', x_pid;
        end if;
        if x_qty <= 0 then raise exception '品項數量不合法：%', x_qty; end if;
        if x_price < 0 then raise exception '商品 % 主檔單價為負', x_name; end if;
        -- 值域檢查要留著：日後加了新的收入類別而這裡沒跟上時，要大聲失敗
        if x_bucket not in ('venue_fee','fnb','retail','other') then
          raise exception '商品 % 的 revenue_type 尚未支援：%', x_name, x_bucket;
        end if;
        x_line := x_qty * x_price;
        v_sub  := v_sub + x_line;
        if not x_disc then                v_nodisc := v_nodisc + x_line;
        elsif x_bucket = 'venue_fee' then v_fee    := v_fee    + x_line;
        elsif x_bucket = 'fnb'       then v_fnb    := v_fnb    + x_line;
        else                              v_goods  := v_goods  + x_line;
        end if;
        n := n + 1;
        l_pid[n] := x_pid; l_rt[n] := x_bucket; l_sub[n] := x_sub;
        l_ord[n] := case x_bucket when 'venue_fee' then 1 when 'fnb' then 2 else 3 end;
        l_disc[n] := x_disc;
        l_rem[n] := case when x_disc then x_line else 0 end;   -- 不可折扣的品項從一開始就沒有可折的額度
      end;
    end loop;
  end if;

  if p_coupon_ids is not null and array_length(p_coupon_ids, 1) > 0 then
    for cp in
      select mc.id as mc_id, c.id as coupon_id, c.name as c_name, c.discount_type, c.discount_value,
             c.min_spend, c.max_discount, c.free_product_id, c.cost_bearer
        from member_coupons mc
        join coupons c on c.id = mc.coupon_id
       where mc.id = any(p_coupon_ids) and mc.member_id = p_member_id
       order by array_position(p_coupon_ids, mc.id)   -- 店員選的順序
    loop
      perform 1 from member_coupons
        where id = cp.mc_id and used_at is null and coalesce(status,'') <> 'used'
          and (expires_at is null or expires_at > now());
      if not found then
        raise exception '券 % 已使用或已過期', cp.c_name;
      end if;

      -- 這張券涵蓋哪些品項
      v_has_scope := exists (select 1 from coupon_scopes s where s.coupon_id = cp.coupon_id);
      v_match := '{}'; cap := 0;
      for i in 1 .. n loop
        if cp.discount_type = 'free' and cp.free_product_id is not null then
          v_match[i] := l_disc[i] and l_pid[i] = cp.free_product_id;          -- 指定商品免費券：只有那個商品
        elsif not v_has_scope then
          v_match[i] := l_disc[i];                                          -- 沒有規則：全部可折扣品項
        else
          v_match[i] := l_disc[i] and exists (
            select 1 from coupon_scopes s
             where s.coupon_id = cp.coupon_id
               and ((s.scope_type = 'revenue_type' and s.scope_value = l_rt[i])
                 or (s.scope_type = 'subcategory'  and s.scope_value = l_sub[i])
                 or (s.scope_type = 'product'      and s.scope_value = l_pid[i]::text)));
        end if;
        if v_match[i] then cap := cap + l_rem[i]; end if;
      end loop;

      if cp.discount_type = 'free' and cp.free_product_id is not null then
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
      if cp.max_discount is not null and cut > cp.max_discount then cut := cp.max_discount; end if;
      cut := least(cut, cap);
      if cut <= 0 then raise exception '券 % 折抵金額為 0', cp.c_name; end if;

      v_coupon_cut := v_coupon_cut + cut;
      v_coupons := v_coupons || jsonb_build_array(jsonb_build_object(
        'member_coupon_id', cp.mc_id, 'name', cp.c_name, 'scope_label', public._coupon_scope_label(cp.coupon_id),
        'cut', cut, 'cost_bearer', cp.cost_bearer));

      -- 從涵蓋的品項扣：檯費 → 餐飲 → 其餘，同一類照品項順序
      r := cut;
      for k in 1 .. 3 loop
        for i in 1 .. n loop
          if v_match[i] and l_ord[i] = k and r > 0 then
            d := least(r, l_rem[i]); l_rem[i] := l_rem[i] - d; r := r - d;
          end if;
        end loop;
      end loop;
    end loop;
  end if;

  -- 等級折扣：只折檯費（券折抵後剩下、而且可折扣的那一部分）；查不到的等級一律 0
  v_rem_fee := 0;
  for i in 1 .. n loop
    if l_rt[i] = 'venue_fee' then v_rem_fee := v_rem_fee + l_rem[i]; end if;
  end loop;
  select coalesce(tier_override, tier) into v_tier from members where id = p_member_id;
  select coalesce(t.discount_pct, 0) into v_pct from member_tiers t where t.code = v_tier and t.is_active;
  v_pct := coalesce(v_pct, 0);
  v_tier_cut := round(v_rem_fee * v_pct / 100.0);

  v_payable := v_sub - v_coupon_cut - v_tier_cut;
  if v_payable < 0 then raise exception '應付金額為負，折扣計算有誤'; end if;

  return jsonb_build_object(
    'subtotal', v_sub, 'non_discountable', v_nodisc,
    'fee', v_fee, 'fnb', v_fnb, 'goods', v_goods,
    'coupon_discount', v_coupon_cut, 'coupons', v_coupons,
    'tier', v_tier, 'tier_discount_pct', v_pct, 'tier_discount', v_tier_cut,
    'payable', v_payable);
end $function$
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

-- [7.0] _coupon_scope_label
CREATE OR REPLACE FUNCTION public._coupon_scope_label(p_coupon_id uuid)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select case
    when c.free_product_id is not null then
      '限 ' || coalesce((select name from products where id = c.free_product_id), '指定商品')
    when not exists (select 1 from coupon_scopes s where s.coupon_id = c.id) then '全品項'
    else '限' || (
      select string_agg(x.lbl, '、' order by x.o, x.lbl) from (
        select case s.scope_type
                 when 'revenue_type' then (select t.label from product_taxonomy t where t.dimension = 'revenue_type' and t.code = s.scope_value)
                 when 'subcategory'  then (select t.label from product_taxonomy t where t.dimension = 'subcategory'  and t.code = s.scope_value)
                 else ' ' || (select p.name from products p where p.id::text = s.scope_value)
               end as lbl,
               case s.scope_type when 'revenue_type' then 1 when 'subcategory' then 2 else 3 end as o
          from coupon_scopes s where s.coupon_id = c.id) x)
  end
  from coupons c where c.id = p_coupon_id
$function$
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
  v_seat := _try_auto_seat_tx_core(p_org, p_queue, p_staff);

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

-- [7.0] _game_row
CREATE OR REPLACE FUNCTION public._game_row(p_org_id uuid, p_session_id uuid, p_member_id uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select jsonb_build_object(
    'session_id', m.id,
    -- table_sessions.mode ∈ matched / private，就是配桌 vs 包桌
    'kind',   case when m.mode = 'private' then 'package' else 'match' end,
    -- 已收桌但還沒結算戰績 → pending；有名次 → settled
    'status', case when sp.finish_rank is not null then 'settled' else 'pending' end,
    /* 這一場是從哪一種配桌房來的（member／pos／recurring，2026-09-18 加）。
       前端 `kindText` 用它分「即時牌局／固定牌局」。對不到房就是 null。 */
    'source',     q.source,
    'store',      st.name,
    'addr',       st.address,
    'game_type',  m.game_type,
    'flower',     m.flower,
    'rounds',     m.planned_rounds,     -- 整數，「幾將」由前端組字
    'stake',      sl.label,             -- 積分級距顯示名，例如 50/20、純娛樂麻將
    -- 開打時間用 activated_at（帶桌／真正開打），沒有才退回 started_at（開桌）
    'started_at', coalesce(m.activated_at, m.started_at),
    -- 結束時間：收桌時間；還沒收桌就用打完、成績算好的那一刻（2026-10-02）
    'ended_at',   coalesce(m.ended_at, sp.settled_at),
    'duration_minutes',
      case when coalesce(m.ended_at, sp.settled_at) is not null
           then greatest(0, (extract(epoch from
                  (coalesce(m.ended_at, sp.settled_at) - coalesce(m.activated_at, m.started_at))) / 60)::int)
           else null end,
    'my_rank',           sp.finish_rank,      -- M4 之前是 null
    'my_score',          sp.score_points,     -- M4 之前是 null
    'my_charged_points', sp.charged_points,
    'my_fee_waived',     sp.fee_waived_amount,  -- 暢打／店員／店長特調免收的金額
    'my_seat',           sp.seat,
    /* 走勢圖的兩個座標。⚠ `settled_at` 不能用 `ended_at` 代替 ——
       收桌與結算是兩個動作，而走勢圖畫的是**分數變動的時間**。 */
    'my_rating_after',   sp.rating_after,
    'settled_at',        sp.settled_at,
    'players', coalesce((
      select jsonb_agg(jsonb_build_object(
               'member_id',    p.member_id,
               'nickname',     mem.display_name,
               /* 段位是「那一場的事實」：打完時的段位（2026-10-02）。被隱藏的人不顯示；還在打就是現在的；
                  收了桌卻沒有段位分（只打 1 將）就不顯示 —— 不知道當時是什麼，不猜 */
               'rank',         case when mem.hidden_at is not null then null
                                    when p.rating_after is not null then public.rank_from_rating(p.rating_after)
                                    when m.status = 'open' then mem.rank
                                    else null end,
               'avatar_url',        mem.avatar_url,
               'avatar_source',     mem.avatar_source,
               'avatar_photo_path', mem.avatar_photo_path,
               'avatar_bear',       mem.avatar_bear,
               'title',        mem.title,
               'seat',         p.seat,
               'finish_rank',  p.finish_rank,
               'score_points', p.score_points,
               /* 桌上積分。⚠ null 是有意義的：純娛樂的桌不計積分，
                  那與「打平（0）」不同。 */
               'final_score',  p.final_score,
               'is_me',        p.member_id = p_member_id
             ) order by coalesce(p.finish_rank, 99), p.seat nulls last, p.joined_at)
        from session_players p
        join members mem on mem.id = p.member_id
       where p.session_id = m.id), '[]'::jsonb)
  )
  from table_sessions m
  join session_players sp
    on sp.session_id = m.id
   and sp.member_id  = p_member_id
   and sp.org_id     = p_org_id
  left join stores       st on st.id = m.store_id       and st.org_id = p_org_id
  left join stake_levels sl on sl.id = m.stake_level_id and sl.org_id = p_org_id
  /* ⚠ lateral ＋ limit 1：理論上一場只對到一個配桌房，
     但不假設它 —— 多對到一筆會讓整場資料變成兩列。 */
  left join lateral (
    select mq.source
      from match_queues mq
     where mq.matched_session_id = m.id
       and mq.org_id = p_org_id
     order by mq.created_at
     limit 1
  ) q on true
  where m.id = p_session_id
    and m.org_id = p_org_id
    and m.deleted_at is null
$function$
;

-- [7.0] _is_team_leader
CREATE OR REPLACE FUNCTION public._is_team_leader(p_team_id uuid, p_member_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE
AS $function$
  select exists (
    select 1 from public.team_members tm
     join public.teams t on t.id = tm.team_id and t.deleted_at is null
    where tm.team_id = p_team_id and tm.member_id = p_member_id
      and tm.left_at is null and tm.role = 'leader');
$function$
;

-- [7.0] _join_plan
CREATE OR REPLACE FUNCTION public._join_plan(p_session_id uuid, p_member_id uuid, p_join_type text, p_pay_for uuid[], p_items jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_s record; v_base jsonb; v_unit bigint; v_qty int; v_amount bigint;
  v_items jsonb; v_target uuid; v_extra int := 0;
  v_buy_daypass boolean := false;   -- 本次結帳是否含當日暢打
  v_self_pass boolean := false;     -- 付款人是否已持有暢打
begin
  if p_join_type not in ('opener','mid_join','sub') then
    return jsonb_build_object('ok', false, 'reason', 'invalid_join_type');
  end if;

  -- 附加品項驗證。純輸入檢查，刻意排在查場次之前。
  if p_items is not null and jsonb_typeof(p_items) = 'array' then
    v_extra := jsonb_array_length(p_items);
  end if;

  if v_extra > 0 then
    select exists (
      select 1 from jsonb_array_elements(p_items) it
       where exists (select 1 from products pr
                      where pr.id = nullif(it ->> 'product_id', '')::uuid and pr.sku = 'SVC-TBL-DAY'))
      into v_buy_daypass;

    -- 場地費由系統自己算，前端再送一份會重複收費；暢打例外（它賣的是今天不再收場地費的權利）
    if exists (
      select 1 from jsonb_array_elements(p_items) it
        join products pr on pr.id = nullif(it ->> 'product_id', '')::uuid
       where pr.revenue_type = 'venue_fee' and pr.sku <> 'SVC-TBL-DAY' and pr.deleted_at is null
    ) then
      return jsonb_build_object('ok', false, 'reason', 'fee_item_not_allowed',
        'message', '場地費由系統計算，不可由前端傳入');
    end if;

    -- 儲值寫的是 topup_orders 不是 orders，不能混進同一張單（儲值不是商品，維持讀前端旗標）
    if exists (select 1 from jsonb_array_elements(p_items) it
                where it ->> 'is_topup' = 'true' or it ->> 'revenue_type' = 'topup') then
      return jsonb_build_object('ok', false, 'reason', 'topup_not_allowed',
        'message', '儲值請走儲值流程，不能併入結帳');
    end if;

    if exists (
      select 1 from jsonb_array_elements(p_items) it
       where nullif(it ->> 'product_id', '') is null or coalesce((it ->> 'qty')::int, 0) <= 0
    ) or exists (
      select 1 from jsonb_array_elements(p_items) it
        left join products pr on pr.id = nullif(it ->> 'product_id', '')::uuid and pr.deleted_at is null
       where nullif(it ->> 'product_id', '') is not null
         and (pr.id is null or (pr.revenue_type not in ('fnb','retail','other') and pr.sku <> 'SVC-TBL-DAY'))
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
    return jsonb_build_object('ok', false, 'reason', 'session_closed', 'message', '此場次已收桌或已作廢');
  end if;

  -- 鐵則一：一律會員
  if not exists (select 1 from members where id = p_member_id and deleted_at is null) then
    return jsonb_build_object('ok', false, 'reason', 'member_required', 'message', '需先建立會員資料');
  end if;

  if exists (select 1 from session_players
              where session_id = p_session_id and member_id = p_member_id and left_at is null) then
    return jsonb_build_object('ok', false, 'reason', 'already_joined');
  end if;

  -- 座位上限：自己 ＋ 代付人數不可超過 4
  if (select count(*) from session_players where session_id = p_session_id and left_at is null)
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
        return jsonb_build_object('ok', false, 'reason', 'payfor_member_invalid', 'member_id', v_target);
      end if;
      if exists (select 1 from session_players
                  where session_id = p_session_id and member_id = v_target and left_at is null) then
        return jsonb_build_object('ok', false, 'reason', 'payfor_already_joined', 'member_id', v_target);
      end if;
    end loop;
  end if;

  -- 標準單價：會員傳 null 取得「不看暢打」的價格（暢打是個人權利，不因誰付錢而轉移）
  v_base := public.calc_session_fee_tx(p_session_id, p_join_type, null);
  if not (v_base ->> 'ok')::boolean then return v_base; end if;
  v_unit := coalesce((v_base ->> 'amount')::bigint, 0);

  v_self_pass := has_daypass_tx(v_s.org_id, p_member_id, v_s.store_id);
  if v_buy_daypass and v_self_pass then
    return jsonb_build_object('ok', false, 'reason', 'daypass_already_held',
      'message', '此會員今日已持有當日暢打，不需再購買');
  end if;

  -- 份數逐人判斷：本次買暢打的話付款人自己這份當場歸零
  v_qty := 0;
  if not v_buy_daypass and not v_self_pass then v_qty := 1; end if;
  if p_pay_for is not null then
    foreach v_target in array p_pay_for loop
      if not has_daypass_tx(v_s.org_id, v_target, v_s.store_id) then v_qty := v_qty + 1; end if;
    end loop;
  end if;
  v_amount := v_unit * v_qty;

  v_items := '[]'::jsonb;
  if v_amount > 0 then
    v_items := v_items || jsonb_build_array(jsonb_build_object(
      'product_id', v_base ->> 'product_id', 'name', v_base ->> 'name',
      'revenue_type', 'venue_fee', 'qty', v_qty, 'unit_price', v_unit));
  end if;
  if v_extra > 0 then v_items := v_items || p_items; end if;

  return jsonb_build_object('ok', true,
    'org_id', v_s.org_id, 'store_id', v_s.store_id, 'table_id', v_s.table_id,
    'unit_fee', v_unit, 'qty', v_qty, 'amount', v_amount,
    'fee_product_id', v_base ->> 'product_id', 'fee_name', v_base ->> 'name',
    'daypass', v_self_pass, 'daypass_bought', v_buy_daypass,
    'extra_items', v_extra, 'items', v_items);
end $function$
;

-- [7.0] _ma_row
CREATE OR REPLACE FUNCTION public._ma_row(p_member uuid, p_ach uuid, p_org uuid)
 RETURNS member_achievements
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare r member_achievements;
begin
  select * into r from member_achievements
   where member_id = p_member and achievement_id = p_ach
   for update;
  if not found then
    insert into member_achievements(org_id, member_id, achievement_id)
    values (p_org, p_member, p_ach)
    returning * into r;
  end if;
  return r;
end $function$
;

-- [7.0] _member_bear_unlocks
CREATE OR REPLACE FUNCTION public._member_bear_unlocks(p_member uuid)
 RETURNS text[]
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  select array(
           select t.code
             from public.rank_tiers t
            where t.sort <= coalesce(
                    (select bt.sort
                       from public.members m
                       join public.rank_tiers bt on bt.code = m.best_rank_tier
                      where m.id = p_member), 1)
            order by t.sort)
      || case when exists (select 1 from public.season_champions c where c.member_id = p_member)
              then array['quegod'] else array[]::text[] end
$function$
;

-- [7.0] _member_hide_core
CREATE OR REPLACE FUNCTION public._member_hide_core(p_member uuid, p_source text, p_staff uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_m members%rowtype;
  r   record;
begin
  select * into v_m from members
   where id = p_member and deleted_at is null
     for update;
  if v_m.id is null then
    return jsonb_build_object('ok', false, 'reason', 'not_found', 'message', '找不到這個會員');
  end if;
  if v_m.hidden_at is not null then
    return jsonb_build_object('ok', false, 'reason', 'already_hidden', 'message', '這個帳號已經是隱藏狀態');
  end if;

  /* 擋牆（全部在寫入之前）*/
  if exists (select 1 from staff s where s.member_id = p_member and s.deleted_at is null) then
    return jsonb_build_object('ok', false, 'reason', 'is_staff',
      'message', '這個帳號是店員，請總部先在「店員管理」移除店員身分');
  end if;
  if exists (select 1 from session_players sp
               join table_sessions ts on ts.id = sp.session_id
              where sp.member_id = p_member and sp.left_at is null
                and ts.status = 'open' and ts.deleted_at is null) then
    return jsonb_build_object('ok', false, 'reason', 'in_session',
      'message', '正在牌桌上，收桌之後才能隱藏帳號');
  end if;
  /* ⚠ 只看 matched 不看 seated：帶到桌之後房會一直停在 seated，
     看它的話打完的每一局都會永遠擋住。桌上有沒有人由上一格判斷。 */
  if exists (select 1 from match_queue_players qp
               join match_queues q on q.id = qp.queue_id
              where qp.member_id = p_member and qp.left_at is null and q.status = 'matched') then
    return jsonb_build_object('ok', false, 'reason', 'queue_matched',
      'message', '配桌已經成桌，這一局結束之後才能隱藏帳號');
  end if;
  if exists (select 1 from team_members tm
              where tm.member_id = p_member and tm.left_at is null and tm.role = 'leader'
                and exists (select 1 from team_members o
                             where o.team_id = tm.team_id and o.left_at is null
                               and o.member_id <> p_member)) then
    return jsonb_build_object('ok', false, 'reason', 'leader_must_transfer',
      'message', '你是牌咖團團長，請先把團長轉給其他團員');
  end if;

  /* 收掉「進行中」的東西 —— 能用既有函式的就用既有的（不寫第二份規則）*/
  for r in select q.id from match_queue_players qp
             join match_queues q on q.id = qp.queue_id
            where qp.member_id = p_member and qp.left_at is null and q.status = 'waiting'
  loop
    perform public.leave_match_queue_tx(v_m.org_id, p_member, r.id, '帳號隱藏');
  end loop;
  for r in select tm.team_id from team_members tm
            where tm.member_id = p_member and tm.left_at is null and tm.role = 'leader'
  loop
    perform public._team_disband(r.team_id, p_member);   -- 走到這裡一定是「團裡只剩自己」
  end loop;
  update team_members set left_at = now(), left_reason = 'quit'
   where member_id = p_member and left_at is null;
  update team_requests set status = 'cancelled', decided_at = now()
   where status = 'pending' and (member_id = p_member or created_by = p_member);
  update bookings set status = 'cancelled', cancelled_reason = '會員隱藏帳號', updated_at = now()
   where member_id = p_member and status = 'booked';
  delete from buddy_invites
   where status = 'pending' and (inviter_id = p_member or invitee_id = p_member);

  /* 對外顯示的欄位搬進保險箱，原位換成問號 */
  insert into member_hidden (member_id, org_id, display_name, avatar_source, avatar_bear,
                             avatar_url, avatar_photo_path, about, title, style, baby_tile, sched)
  values (v_m.id, v_m.org_id, v_m.display_name, v_m.avatar_source, v_m.avatar_bear,
          v_m.avatar_url, v_m.avatar_photo_path, v_m.about, v_m.title, v_m.style, v_m.baby_tile, v_m.sched);

  update members set
    display_name = '隱藏的會員',
    avatar_source = 'hidden', avatar_bear = null, avatar_url = null, avatar_photo_path = null,
    about = null, title = '新手上路', style = null, baby_tile = null, sched = null,
    hidden_at = now()
  where id = p_member;

  insert into member_hide_log (org_id, member_id, action, source, by_staff_id, reason)
  values (v_m.org_id, p_member, 'hide', p_source, p_staff, p_reason);

  return jsonb_build_object('ok', true, 'member_id', p_member);
end $function$
;

-- [7.0] _member_home_store
CREATE OR REPLACE FUNCTION public._member_home_store(p_member_id uuid)
 RETURNS uuid
 LANGUAGE sql
 STABLE
AS $function$
  with s as (
    select ts.store_id, count(*) as n
      from public.session_players sp
      join public.table_sessions ts on ts.id = sp.session_id
     where sp.member_id = p_member_id
       and ts.deleted_at is null
       and ts.store_id is not null
       /* ⚠ 時間用 `joined_at`（他真的坐下的那一刻），與牌咖團場次判定
          同一個時間戳 —— 系統裡不要有第二種「這場算哪一天」。 */
       and coalesce(sp.joined_at, ts.created_at) >= now() - interval '180 days'
     group by ts.store_id
  )
  select s.store_id from s
   where s.n >= 3                                  -- 最低門檻：三場
     and s.n * 2 > (select sum(x.n) from s x)      -- 過半（⇒ 答案必然唯一）
$function$
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

-- [7.0] _member_stats_core
CREATE OR REPLACE FUNCTION public._member_stats_core(p_org_id uuid, p_member_id uuid)
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
  /* ★ 2026-10-04 每一局（電子計分） */
  v_s_hand int; v_s_hu int; v_s_tsumo int; v_s_dealin int; v_s_max_tai int; v_s_max_ren int;
  v_a_hand int; v_a_hu int; v_a_tsumo int; v_a_dealin int;
begin

  /* 🔴 身分一律從 JWT 取，不採信呼叫端（2026-09-05，待辦 14）。
     在此之前前端送什麼 member_id 就查什麼 ⇒ 知道任何一個會員 uuid
     就能看他的錢包與消費明細。
     ⚠ 查不到就**拒絕**不是回 null —— 回 null 等於洞還開著。
     ⚠ 呼叫端照樣送 p_member_id，函式忽略它（簽名不變，前端不用改）。 */
  /* 身分由呼叫端決定：get_my_stats_tx 傳登入的本人，get_member_card_tx 傳要看的那個人。 */
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

  /* ── ★ 每一局（電子計分，2026-10-04）────────────────────
     局只算真的打完一把的（胡、自摸、流局、包牌）；咔啦碰是中途另外收分，不是一局。
     座位號在一場裡代表同一個人（session_players.seat）。 */
  with mine as (
    select sp.session_id, sp.seat,
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
       and sp.seat is not null
  ), hh as (
    select m.in_season, h.result, h.renzhuang,
           /* 這一局的台數 ＝ 牌型台 ＋ 莊台（跟平板「莊 X 台」同一套：放槍看胡與放槍兩家有沒有莊家，自摸一律有） */
           coalesce(h.tai_pattern, 0)
             + case when h.result = 'tsumo'
                      or (h.result = 'ron' and (h.winner_seat = h.dealer_seat or h.deal_in_seat = h.dealer_seat))
                    then 1 + 2 * coalesce(h.renzhuang, 0) else 0 end as tai_total,
           coalesce(h.winner_seat = m.seat, false)  as won,
           coalesce(h.deal_in_seat = m.seat, false) as dealt_in,
           coalesce(h.dealer_seat = m.seat, false)  as is_dealer
      from mine m
      join hands h on h.session_id = m.session_id
     where h.status = 'confirmed'
       and h.result in ('tsumo', 'ron', 'draw', 'bao')
  )
  select count(*) filter (where in_season),
         count(*) filter (where in_season and won and result in ('tsumo', 'ron')),
         count(*) filter (where in_season and won and result = 'tsumo'),
         count(*) filter (where in_season and dealt_in and result = 'ron'),
         max(tai_total)   filter (where in_season and won and result in ('tsumo', 'ron')),
         max(renzhuang)   filter (where in_season and is_dealer),
         count(*),
         count(*) filter (where won and result in ('tsumo', 'ron')),
         count(*) filter (where won and result = 'tsumo'),
         count(*) filter (where dealt_in and result = 'ron')
    into v_s_hand, v_s_hu, v_s_tsumo, v_s_dealin, v_s_max_tai, v_s_max_ren,
         v_a_hand, v_a_hu, v_a_tsumo, v_a_dealin
    from hh;

  /* ── 本季全國排名：**改呼叫共用函式**（2026-09-03）────────
     🔴 在此之前這裡有一份自己的 CTE，而賽季結算會有第二份 ——
       兩份分岔的症狀是「他看到自己第 3 名，歷史記成第 5 名」，
       **而且不會報錯**。現在兩邊都叫 `season_rank_rows_tx`。 */
  select r.rank_no into v_rank
    from public.season_rank_rows_display_tx(p_org_id, v_win) r
   where r.member_id = p_member_id;
  select count(*) into v_total
    from public.season_rank_rows_display_tx(p_org_id, v_win) r;

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
      'streak',     coalesce(v_s_streak, 0),
      /* 每一局（2026-10-04）：局數、胡、自摸、放槍、單局最大台（含莊台）、最長連莊（null ＝ 沒胡過／沒當過莊） */
      'hand_count', coalesce(v_s_hand, 0), 'hu_count', coalesce(v_s_hu, 0),
      'tsumo_count', coalesce(v_s_tsumo, 0), 'deal_in_count', coalesce(v_s_dealin, 0),
      'max_tai', v_s_max_tai, 'max_renzhuang', v_s_max_ren  -- 最長連勝（賽季性質，生涯沒有）
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
      'best_score', v_a_best_score,
      'hand_count', coalesce(v_a_hand, 0), 'hu_count', coalesce(v_a_hu, 0),
      'tsumo_count', coalesce(v_a_tsumo, 0), 'deal_in_count', coalesce(v_a_dealin, 0)
    )
  );
end $function$
;

-- [7.0] _member_titles
CREATE OR REPLACE FUNCTION public._member_titles(p_member uuid)
 RETURNS TABLE(title text, source text, got_at timestamp with time zone)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select distinct on (x.title) x.title, x.source, x.got_at
    from (
      /* 🔴 2026-09-22：新手上路不再無條件給 —— 它是成就「新手報到」的稱號，
         跟其他稱號走同一條路（下面這一段）。
         🔴 刻意不過濾 a.deleted_at / a.is_active：稱號永久（成就與稱號設計 §6.1），
         成就日後下架，已經拿到的人不應該被收回。 */
      select a.grants_title as title, '成就「' || a.name || '」' as source, ma.unlocked_at as got_at, 1 as pri
        from member_achievements ma
        join achievements a on a.id = ma.achievement_id
       where ma.member_id = p_member and ma.status = 'unlocked'
         and a.grants_title is not null and btrim(a.grants_title) <> ''

      union all
      /* 賽季名稱「2026 段位秋季賽」→ 稱號「2026 秋季雀神熊」、來源「2026 秋季賽冠軍」。
         ⚠ 從 rank_seasons.label 推，不另寫一份季別對照 ——
           兩份的話日後改賽季名稱，稱號會跟著漂。 */
      select case when s.label ~ '^\d{4} 段位.季賽$'
                  then regexp_replace(s.label, '^(\d{4}) 段位(.)季賽$', '\1 \2季雀神熊')
                  else coalesce(s.label, c.season) || ' 雀神熊' end,
             case when s.label ~ '^\d{4} 段位.季賽$'
                  then regexp_replace(s.label, '^(\d{4}) 段位(.)季賽$', '\1 \2季賽冠軍')
                  else coalesce(s.label, c.season) || ' 冠軍' end,
             c.awarded_at, 2
        from season_champions c
        left join rank_seasons s on s.org_id = c.org_id and s.code = c.season
       where c.member_id = p_member

      union all
      select t, '特別獲得', null::timestamptz, 3
        from member_app_state st, jsonb_array_elements_text(st.titles) t
       where st.member_id = p_member
    ) x
   order by x.title, x.pri, x.got_at nulls last
$function$
;

-- [7.0] _member_unhide_core
CREATE OR REPLACE FUNCTION public._member_unhide_core(p_member uuid, p_staff uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_h member_hidden%rowtype;
  v_at timestamptz;
begin
  select hidden_at into v_at from members where id = p_member and deleted_at is null for update;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'not_found', 'message', '找不到這個會員');
  end if;
  if v_at is null then
    return jsonb_build_object('ok', false, 'reason', 'not_hidden', 'message', '這個帳號沒有被隱藏');
  end if;
  select * into v_h from member_hidden where member_id = p_member;
  if v_h.member_id is null then
    /* 不應該發生（兩張表同一個交易寫的）—— 發生了就大聲說，不要把問號當成真名搬回去 */
    return jsonb_build_object('ok', false, 'reason', 'vault_missing',
      'message', '找不到這個帳號原本的資料，請聯絡系統管理員');
  end if;

  update members set
    display_name = v_h.display_name,
    avatar_source = v_h.avatar_source, avatar_bear = v_h.avatar_bear,
    avatar_url = v_h.avatar_url, avatar_photo_path = v_h.avatar_photo_path,
    about = v_h.about, title = v_h.title, style = v_h.style,
    baby_tile = v_h.baby_tile, sched = v_h.sched,
    hidden_at = null
  where id = p_member;
  delete from member_hidden where member_id = p_member;

  insert into member_hide_log (org_id, member_id, action, source, by_staff_id, reason)
  values (v_h.org_id, p_member, 'unhide', 'hq', p_staff, p_reason);

  return jsonb_build_object('ok', true, 'member_id', p_member);
end $function$
;

-- [7.0] _pair_history
CREATE OR REPLACE FUNCTION public._pair_history(p_org_id uuid, p_a uuid, p_b uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  /* 你們兩個都坐過、而且已收桌的場次（2026-09-30 從 list_buddies_tx 抽出，規則逐字不變）。
     ⚠ 用開打時間（activated_at）不是收桌時間 —— 凌晨兩點收桌的晚場，問的是「幾點開始打」。
     回傳 { n 同桌場數, last_at 上次同桌, pattern 常一起打 }，pattern 是結構不是句子。 */
  with shared as (
    select coalesce(s.activated_at, s.started_at, s.ended_at) as at
      from session_players me
      join session_players op on op.session_id = me.session_id and op.member_id = p_b
      join table_sessions s   on s.id = me.session_id and s.deleted_at is null and s.status = 'completed'
     where me.member_id = p_a and me.org_id = p_org_id
  ), tagged as (
    select extract(dow from (at at time zone 'Asia/Taipei'))::int as wd,
           public.migi_slot_of(at) as slot
      from shared where at is not null
  ), tot as (select count(*) as n from tagged),
  best_ws as (
    select wd, slot, count(*) as n from tagged
     group by wd, slot order by count(*) desc, slot, wd limit 1
  ),
  best_s as (
    select slot, count(*) as n from tagged
     group by slot order by count(*) desc, slot limit 1
  )
  select jsonb_build_object(
    'n',       (select count(*) from shared),
    'last_at', (select max(at) from shared),
    'pattern', case
      /* 「常」的兩個門檻，缺一不可：① 總同桌 ≥ 3 場 ② 眾數要過半（n × 2 > 總數）。
         「最多的那一個」不等於「常」。 */
      when (select n from tot) < 3 then null
      when (select n from best_ws) * 2 > (select n from tot) then
        jsonb_build_object('weekday', (select wd from best_ws), 'slot', (select slot from best_ws), 'n', (select n from best_ws))
      when (select n from best_s) * 2 > (select n from tot) then
        /* 退化：星期分散但時段集中 → 只講時段 */
        jsonb_build_object('weekday', null, 'slot', (select slot from best_s), 'n', (select n from best_s))
      else null
    end)
$function$
;

-- [7.0] _pkg_ext_expected
CREATE OR REPLACE FUNCTION public._pkg_ext_expected(p_org uuid, p_sku text)
 RETURNS bigint
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select case p_sku
           when 'SVC-TBL-PX02' then
             (select unit_price from products where org_id = p_org and sku = 'SVC-TBL-P02' and deleted_at is null)
           when 'SVC-TBL-DAYUP' then
             gcd(gcd((select unit_price from products where org_id = p_org and sku = 'SVC-TBL-DAY' and deleted_at is null),
                     (select unit_price from products where org_id = p_org and sku = 'SVC-TBL-P02' and deleted_at is null)),
                 (select unit_price from products where org_id = p_org and sku = 'SVC-TBL-P05' and deleted_at is null))
         end
$function$
;

-- [7.0] _pkg_ext_guard
CREATE OR REPLACE FUNCTION public._pkg_ext_guard()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_exp bigint;
begin
  v_exp := public._pkg_ext_expected(new.org_id, new.sku);
  if v_exp is not null and new.unit_price <> v_exp then
    raise exception '包桌延長的價格由包桌檯費自動算（應為 %），請改包桌檯費', v_exp
      using errcode = '23514';
  end if;
  return new;
end $function$
;

-- [7.0] _pkg_tier_sync
CREATE OR REPLACE FUNCTION public._pkg_tier_sync()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  update products p
     set unit_price = public._pkg_ext_expected(p.org_id, p.sku), updated_at = now()
   where p.org_id = new.org_id and p.deleted_at is null
     and p.sku in ('SVC-TBL-PX02', 'SVC-TBL-DAYUP')
     and p.unit_price is distinct from public._pkg_ext_expected(p.org_id, p.sku);
  return null;
end $function$
;

-- [7.0] _pkg_time
CREATE OR REPLACE FUNCTION public._pkg_time(p_session_id uuid, p_with_ids boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  s        public.table_sessions;
  v_base   int; v_eff int; v_base_price bigint; v_2h bigint; v_day bigint;
  v_start  timestamptz; v_exp timestamptz; v_phase text; v_rows jsonb; v_players jsonb; v_payers jsonb;
  c_warn   constant interval := interval '30 minutes';
  c_grace  constant interval := interval '15 minutes';
  c_cap    constant int := 1440;
begin
  select * into s from table_sessions where id = p_session_id and deleted_at is null;
  if s.id is null or s.mode <> 'private' then return null; end if;
  if s.status <> 'open' then return jsonb_build_object('phase', 'closed'); end if;

  -- 開桌那一段（24 小時那一檔已停用，舊場次照樣認）
  v_base := case when coalesce(s.planned_minutes, 0) <= 120 then 120
                 when s.planned_minutes <= 300 then 300 else c_cap end;
  select unit_price into v_base_price from products
   where org_id = s.org_id and deleted_at is null
     and sku = case v_base when 120 then 'SVC-TBL-P02' when 300 then 'SVC-TBL-P05' else 'SVC-TBL-P24' end;
  select unit_price into v_2h  from products where org_id = s.org_id and sku = 'SVC-TBL-PX02' and deleted_at is null;
  select unit_price into v_day from products where org_id = s.org_id and sku = 'SVC-TBL-DAY'  and deleted_at is null;

  select min(r.started_at) into v_start
    from session_rounds r where r.session_id = s.id and r.status <> 'voided';

  -- 每一位：自己的時數 ＝ 開桌那一段，或他最後一次加完的總時數（取大的）；
  --         升級暢打要補多少 ＝ 暢打價 −（開桌價 ＋ 加過幾次 2 小時 × 2 小時價），最少 0
  select jsonb_agg(jsonb_build_object(
           'seat', x.seat, 'name', x.name, 'member_id', x.member_id, 'dp', x.dp, 'mins', x.mins,
           'upgrade', greatest(coalesce(v_day, 0) - coalesce(v_base_price, 0) - x.n2h * coalesce(v_2h, 0), 0),
           'payer_name', x.payer_name)
         order by x.seat nulls last, x.name)
    into v_rows
    from (select sp.seat, sp.member_id, coalesce(m.display_name, '會員') as name,
                 (coalesce(sp.fee_waived_reason, '') = 'daypass'
                  or exists (select 1 from session_extensions d
                              where d.session_id = s.id and d.member_id = sp.member_id and d.kind = 'daypass')
                  or public.has_daypass_tx_core(s.org_id, sp.member_id, s.store_id)) as dp,
                 least(greatest(v_base, coalesce((select max(e.to_minutes) from session_extensions e
                                                   where e.session_id = s.id and e.member_id = sp.member_id
                                                     and e.kind = '2h'), 0)), c_cap) as mins,
                 (select count(*) from session_extensions e
                   where e.session_id = s.id and e.member_id = sp.member_id and e.kind = '2h') as n2h,
                 (select case when e.paid_by <> sp.member_id then coalesce(pm.display_name, '會員') end
                    from session_extensions e left join members pm on pm.id = e.paid_by
                   where e.session_id = s.id and e.member_id = sp.member_id
                   order by e.created_at desc limit 1) as payer_name
            from session_players sp
            left join members m on m.id = sp.member_id
           where sp.session_id = s.id and sp.member_id is not null and sp.left_at is null) x;

  -- 桌子的時數 ＝ 要計時的人裡最短的那一位；沒有人要計時（全是暢打）＝ 封頂
  select min((x ->> 'mins')::int) into v_eff
    from jsonb_array_elements(coalesce(v_rows, '[]'::jsonb)) x where not (x ->> 'dp')::boolean;
  v_eff := least(coalesce(v_eff, c_cap), c_cap);

  -- 對外的形狀：owed ＝ 他就是最早到期的那幾位；paid ＝ 加過、比桌子晚到期；daypass ＝ 不計時
  select jsonb_agg(jsonb_build_object(
           'seat', x -> 'seat', 'name', x ->> 'name',
           'status', case when (x ->> 'dp')::boolean then 'daypass'
                          when (x ->> 'mins')::int >= c_cap then 'capped'
                          when (x ->> 'mins')::int <= v_eff then 'owed'
                          else 'paid' end,
           'minutes', case when (x ->> 'dp')::boolean then null else (x ->> 'mins')::int end,
           'expires_at', case when (x ->> 'dp')::boolean or v_start is null then null
                              else v_start + make_interval(mins => (x ->> 'mins')::int) end,
           'upgrade_price', case when (x ->> 'dp')::boolean then null else (x ->> 'upgrade')::bigint end,
           'payer_name', x ->> 'payer_name')
         || case when p_with_ids then jsonb_build_object('member_id', x -> 'member_id') else '{}'::jsonb end
         order by ord)
    into v_players
    from jsonb_array_elements(coalesce(v_rows, '[]'::jsonb)) with ordinality t(x, ord);

  -- payers：最早到期、要加時間的人（POS 提示條、舊版平板的退回顯示用）
  select jsonb_agg(jsonb_build_object('name', x ->> 'name', 'shares', 1, 'paid', 0, 'owed', 1)
           || case when p_with_ids then jsonb_build_object('member_id', x -> 'member_id') else '{}'::jsonb end)
    into v_payers
    from jsonb_array_elements(coalesce(v_players, '[]'::jsonb)) x
   where x ->> 'status' = 'owed';

  if v_eff >= c_cap then
    v_phase := 'capped';
  elsif v_start is null then
    v_phase := 'not_started';
  else
    v_exp := v_start + make_interval(mins => v_eff);
    v_phase := case when now() <  v_exp - c_warn  then 'ok'
                    when now() <  v_exp           then 'warn'
                    when now() <  v_exp + c_grace then 'grace'
                    else 'locked' end;
  end if;

  return jsonb_build_object(
    'phase',        v_phase,
    'locked',       v_phase = 'locked',
    'now',          now(),
    'started_at',   v_start,
    'base_minutes', v_base,
    'tier_minutes', v_eff,
    'expires_at',   v_exp,
    'warn_at',      v_exp - c_warn,
    'lock_at',      v_exp + c_grace,
    'next_minutes', case when v_eff < c_cap then least(v_eff + 120, c_cap) end,   -- 舊版 POS 用；新版看 options
    'next_sku',     case when v_eff < c_cap then 'SVC-TBL-PX02' end,
    'two_hour_price', v_2h,
    'options',      jsonb_build_array(
                      jsonb_build_object('kind', '2h',      'label', '加 2 小時'),
                      jsonb_build_object('kind', 'daypass', 'label', '升級當日暢打')),
    'players',      coalesce(v_players, '[]'::jsonb),
    'payers',       coalesce(v_payers, '[]'::jsonb),
    'owed_shares',  coalesce(jsonb_array_length(v_payers), 0));
end $function$
;

-- [7.0] _rank_tier_of
CREATE OR REPLACE FUNCTION public._rank_tier_of(p_rank text)
 RETURNS text
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  select t.code
    from public.rank_tiers t
   where p_rank is not null
     and p_rank like t.label || '%'
   order by t.sort desc
   limit 1
$function$
;

-- [7.0] _score_settle_tx
CREATE OR REPLACE FUNCTION public._score_settle_tx(p_session_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_seatmem jsonb; v_hyg boolean; v_payload jsonb := '[]'::jsonb; v_ranks jsonb;
  v_totals jsonb; v_res jsonb; v_rated boolean := false; v_nfin int; v_nhands int;
  r record; h record; e record; v_winner uuid; v_idem text; v_fired int := 0;
begin
  /* ⑤ 放掉平板：2026-09-29 搬到收桌（settle_session_tx）。結算現在在最後一將打完時自動跑，那時平板還要看牌局結束卡。 */

  /* ① 還在確認中的那一局：桌都收了，不會有人再按。
       已經有人確認 ⇒ 照已確認的部分收尾（那幾份早就入帳了）；一個都沒有 ⇒ 撤銷 */
  update hands set status = case when cardinality(confirmed_seats) > 0 then 'confirmed' else 'undone' end,
                   confirmed_at = case when cardinality(confirmed_seats) > 0 then now() end,
                   undone_at    = case when cardinality(confirmed_seats) > 0 then null else now() end
   where session_id = p_session_id and status = 'pending';

  select count(*) into v_nhands from hands
   where session_id = p_session_id and status = 'confirmed' and result <> 'kala';
  if v_nhands = 0 then
    return jsonb_build_object('ok', false, 'reason', 'no_hands');
  end if;

  select jsonb_object_agg(seat::text, member_id) into v_seatmem
    from session_players where session_id = p_session_id and seat is not null;
  if coalesce((select count(*) from jsonb_object_keys(v_seatmem)), 0) <> 4 then
    return jsonb_build_object('ok', false, 'reason', 'no_seats');
  end if;

  select coalesce(sl.is_hygiene, false) into v_hyg
    from table_sessions ts left join stake_levels sl on sl.id = ts.stake_level_id
   where ts.id = p_session_id;

  -- ② 每一將的名次（只算打完的將；同分座位小的在前）
  for r in select id from session_rounds
            where session_id = p_session_id and status = 'finished' order by round_no
  loop
    select jsonb_agg(jsonb_build_object('member_id', v_seatmem ->> x.seat::text, 'finish_rank', x.rk) order by x.rk)
      into v_ranks
      from (select g.seat, row_number() over (order by coalesce(t.tot, 0) desc, g.seat) as rk
              from generate_series(1, 4) as g(seat)
              left join (select e2.key::int as seat, sum(e2.value::int) as tot
                           from hands h2, jsonb_each_text(h2.score_delta) e2
                          where h2.round_id = r.id and h2.status = 'confirmed'
                          group by 1) t on t.seat = g.seat) x;
    v_payload := v_payload || jsonb_build_array(v_ranks);
  end loop;
  v_nfin := jsonb_array_length(v_payload);

  -- 整場每個座位的總分：只算打完的將（含咔啦碰）；沒打完的那一將不算（2026-10-01 使用者拍板）
  select coalesce(jsonb_object_agg(k, tot), '{}'::jsonb) into v_totals
    from (select e2.key as k, sum(e2.value::int) as tot
            from hands h2, jsonb_each_text(h2.score_delta) e2
           where h2.session_id = p_session_id and h2.status = 'confirmed'
             and exists (select 1 from session_rounds rr where rr.id = h2.round_id and rr.status = 'finished')
           group by 1) x;

  -- 段位分：未滿 2 將由 apply_session_rounds_tx 自己擋（too_few_rounds）
  if v_nfin >= 2 then
    v_res := public.apply_session_rounds_tx(p_session_id, v_payload);
    v_rated := coalesce((v_res ->> 'ok')::boolean, false);
  end if;

  -- ③ 名次與桌上積分：打完 1 將就寫（2026-10-01）。段位分仍要 2 將（上面那段），
  --   所以只打完 1 將的場次會「有名次、有桌上積分、沒有段位分」—— 那是拍板的結果，不是寫壞
  if v_nfin >= 1 then
    update session_players sp
       set finish_rank = x.rk,
           final_score = case when v_hyg then null else x.tot end
      from (select g.seat, coalesce((v_totals ->> g.seat::text)::int, 0) as tot,
                   row_number() over (order by coalesce((v_totals ->> g.seat::text)::int, 0) desc, g.seat) as rk
              from generate_series(1, 4) as g(seat)) x
     where sp.session_id = p_session_id and sp.seat = x.seat;
  end if;

  -- ④ 成就（整段吞例外：名次已經算好了，成就失敗不可以把名次一起回滾）
  begin
    for h in select * from hands where session_id = p_session_id and status = 'confirmed' order by created_at loop
      v_idem := 'hand:' || h.id::text;
      /* 只有胡與自摸算「胡牌」；咔啦碰的收款人、包牌的收款人都不是胡牌 */
      if h.result in ('ron', 'tsumo') then
        v_winner := (v_seatmem ->> h.winner_seat::text)::uuid;
        perform public.fire_event_tx(v_winner, 'hand_won', 1, null, v_idem);
        v_fired := v_fired + 1;
        if h.result = 'tsumo' then
          perform public.fire_event_tx(v_winner, 'hand_tsumo', 1, null, v_idem);
        end if;
        -- 「第一次胡出可計台的牌型」：自摸那 1 台不算牌型
        if exists (select 1 from jsonb_array_elements(h.patterns) x where x ->> 'code' <> 'zimo') then
          perform public.fire_event_tx(v_winner, 'hand_pattern_any', 1, null, v_idem);
        end if;
        /* 每個牌型各自的事件（主檔 achievement_event）。
           MIGI 成就也走這裡：牌型 migi 的事件就是 MIGI 成就聽的那一個（2026-09-25 起，
           不再用「牌型台數加總」判斷） */
        for e in select distinct sp.achievement_event as ev
                   from jsonb_array_elements(h.patterns) x
                   join scoring_patterns sp on sp.code = x ->> 'code'
                  where sp.achievement_event is not null
        loop
          perform public.fire_event_tx(v_winner, e.ev, 1, null, v_idem);
        end loop;
      end if;
      -- 連莊：這一局開打時莊家已經在連莊（咔啦碰不是一局）
      if h.renzhuang >= 1 and h.result <> 'kala' then
        perform public.fire_event_tx((v_seatmem ->> h.dealer_seat::text)::uuid, 'renzhuang', 1, null, v_idem);
      end if;
    end loop;
  exception when others then
    null;
  end;

  return jsonb_build_object('ok', true, 'rated', v_rated, 'rounds_finished', v_nfin,
                            'hands', v_nhands, 'fired', v_fired, 'hygiene', v_hyg);
end $function$
;

-- [7.0] _season_rank_rows_core
CREATE OR REPLACE FUNCTION public._season_rank_rows_core(p_org_id uuid, p_from timestamp with time zone, p_to timestamp with time zone, p_include_test boolean)
 RETURNS TABLE(member_id uuid, rating integer, rank_no integer, games integer)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  /* 母體：這個視窗內至少打過一場「已結算」牌局的會員。
     🔴 **不能拿全部會員排** —— `members.rating` 是 `NOT NULL DEFAULT 0`，
       沒打過的人也有 0 分，那樣分母會變成「開過帳號的人數」。
     ⚠ `p_to` 為 null = 沒有上限（現場排名用）。結算時要給那一季的
       `ends_at` —— 否則**結算晚了幾天，那幾天的牌局會被算進上一季**。
     ⚠ 測試帳號排不排由呼叫端決定（`p_include_test`），不要在這裡判斷上線了沒 ——
       結算與顯示要的答案不一樣。
     🆕 2026-09-25：**隱藏中的會員不排**（使用者：隱藏後排名會消失）。
       ⚠ 這一支也是賽季結算用的 ⇒ 隱藏中的人不會拿到冠軍；恢復之後自然回到榜上。 */
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
       and mem.hidden_at is null
       and (p_include_test or mem.is_test = false)
     group by sp.member_id
  )
  /* 同分時用 `created_at` —— **要有一個穩定的第二鍵**，
     不然同分的人每次查到的名次順序都不一樣。 */
  select p.member_id, mem.rating,
         rank() over (order by mem.rating desc, mem.created_at)::int,
         p.games::int
    from played p
    join members mem on mem.id = p.member_id
$function$
;

-- [7.0] _session_scored
CREATE OR REPLACE FUNCTION public._session_scored(p_session_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select exists (select 1 from session_players
                  where session_id = p_session_id and finish_rank is not null);
$function$
;

-- [7.0] _tbl_balances
CREATE OR REPLACE FUNCTION public._tbl_balances(p_session_id uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select jsonb_object_agg(g.s::text, coalesce(st.sp, 0) + coalesce(x.extra, 0) + coalesce(y.tot, 0))
    from generate_series(1, 4) as g(s)
    cross join (select sl.start_points as sp
                  from public.table_sessions ts
                  left join public.stake_levels sl on sl.id = ts.stake_level_id
                 where ts.id = p_session_id) st
    left join (select b.seat, sum(b.added_points) as extra
                 from public.session_busts b
                where b.session_id = p_session_id and b.decision = 'added'
                group by b.seat) x on x.seat = g.s
    left join (select e.key::int as seat, sum(e.value::int) as tot
                 from public.hands h, jsonb_each_text(h.score_delta) e
                where h.session_id = p_session_id and h.status = 'confirmed'
                group by e.key::int) y on y.seat = g.s
$function$
;

-- [7.0] _tbl_device
CREATE OR REPLACE FUNCTION public._tbl_device(p_token text)
 RETURNS table_devices
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare d public.table_devices;
begin
  if p_token is null or length(p_token) < 32 then
    raise exception '這台平板還沒配對，請找店員' using errcode = '28000';
  end if;
  select * into d from table_devices
   where token_hash = public._tbl_hash(p_token) and is_active;
  if not found then
    raise exception '這台平板還沒配對或已停用，請找店員' using errcode = '28000';
  end if;
  /* 最後上線時間：一分鐘寫一次就好（平板每次收到廣播都會來拿狀態） */
  if d.last_seen_at is null or d.last_seen_at < now() - interval '1 minute' then
    update table_devices set last_seen_at = now() where id = d.id;
  end if;
  return d;
end $function$
;

-- [7.0] _tbl_hash
CREATE OR REPLACE FUNCTION public._tbl_hash(p_token text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public'
AS $function$ select encode(extensions.digest(p_token, 'sha256'), 'hex') $function$
;

-- [7.0] _tbl_ping
CREATE OR REPLACE FUNCTION public._tbl_ping(p_session_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_ch text;
begin
  select score_channel into v_ch from table_sessions where id = p_session_id;
  if v_ch is null then return; end if;
  begin
    perform realtime.send(
      jsonb_build_object('at', (extract(epoch from clock_timestamp()) * 1000)::bigint),
      'changed', 'score:' || v_ch, false);
  exception when others then
    null;
  end;
end $function$
;

-- [7.0] _tbl_round_state
CREATE OR REPLACE FUNCTION public._tbl_round_state(p_round_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_first smallint; v_dealer smallint; v_wind smallint := 1; v_ren smallint := 0;
  v_pass smallint := 0; v_n int := 0; v_fin boolean := false; h record; v_stay boolean;
  v_ring smallint[];
begin
  select first_dealer_seat, seat_ring into v_first, v_ring from session_rounds where id = p_round_id;
  if v_first is null then return null; end if;
  -- null ＝ 原本的 1→2→3→4（第一將、舊資料）
  v_ring := coalesce(v_ring, '{1,2,3,4}'::smallint[]);
  v_dealer := v_first;
  /* 只看已生效的局；咔啦碰不是一局（不推進局數、莊家、連莊） */
  for h in select result, winner_seat, deal_in_seat from hands
            where round_id = p_round_id and status = 'confirmed' and result <> 'kala'
            order by hand_no, created_at
  loop
    v_n := v_n + 1;
    /* 誰留莊：
         流局              莊家連莊
         胡／自摸          胡的人是莊家 ⇒ 連莊，否則換莊
         包牌（09-24 拍板）莊家包牌才下莊；閒家包牌莊家繼續連莊 */
    v_stay := case h.result
                when 'draw' then true
                when 'bao'  then h.deal_in_seat <> v_dealer
                else h.winner_seat = v_dealer
              end;
    if v_stay then
      v_ren := v_ren + 1;
    else
      -- 換莊：輪到這一將順序裡的下一位（2026-09-27 起不再寫死 1→2→3→4）
      v_dealer := v_ring[(array_position(v_ring, v_dealer) % 4) + 1];
      v_ren := 0;
      v_pass := v_pass + 1;
      if v_pass = 4 then
        v_pass := 0;
        v_wind := v_wind + 1;
        if v_wind > 4 then v_wind := 4; v_fin := true; exit; end if;
      end if;
    end if;
  end loop;
  return jsonb_build_object('wind', v_wind, 'dealer_seat', v_dealer, 'renzhuang', v_ren,
                            'hand_no', v_n + 1, 'finished', v_fin, 'confirmed_hands', v_n,
                            'seat_ring', to_jsonb(v_ring));
end $function$
;

-- [7.0] _tbl_state_for_device
CREATE OR REPLACE FUNCTION public._tbl_state_for_device(p_device table_devices)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  d public.table_devices; s public.table_sessions; v_table text; v_store text;
  v_my_seat smallint; v_my_player uuid; v_round public.session_rounds; v_state jsonb;
  v_players jsonb; v_pending jsonb; v_history jsonb; v_totals jsonb; v_round_totals jsonb;
  v_rounds jsonb; v_catalog jsonb; v_stake jsonb; v_last_reject jsonb; v_log jsonb;
begin
  d := p_device;   -- 平板由呼叫端給（tbl_state_tx 用憑證認、pos_tbl_watch_tx 由店員指定），其餘一字不改
  select t.label, st.name into v_table, v_store
    from tables t join stores st on st.id = t.store_id where t.id = d.table_id;

  select * into s from table_sessions
   where table_id = d.table_id and status = 'open' and deleted_at is null;
  if not found then
    return jsonb_build_object('ok', true,
      'device', jsonb_build_object('label', d.label, 'table', v_table, 'store', v_store),
      'session', null);
  end if;

  select sp.seat, sp.id into v_my_seat, v_my_player
    from session_players sp
   where sp.session_id = s.id and sp.device_id = d.id and sp.left_at is null;

  /* 不回 member_id —— 平板認人用的是 player_id（session_players.id），
     會員 uuid 不需要出現在一台四個陌生人碰一整晚的裝置上。 */
  select coalesce(jsonb_agg(jsonb_build_object(
           'player_id', sp.id, 'seat', sp.seat, 'name', m.display_name,
           'rank', m.rank, 'title', m.title,
           'avatar_url', m.avatar_url, 'avatar_source', m.avatar_source, 'avatar_bear', m.avatar_bear,
           'avatar_photo_path', m.avatar_photo_path,   -- 上傳照片的人要靠它才畫得出來（2026-09-25 補）
           'bound', sp.device_id is not null, 'is_me', sp.device_id = d.id)
         order by sp.seat nulls last, sp.joined_at), '[]'::jsonb)
    into v_players
    from session_players sp join members m on m.id = sp.member_id
   where sp.session_id = s.id and sp.left_at is null;

  select case when sl.id is null then null else jsonb_build_object(
           'label', sl.label, 'base', sl.base, 'tai', sl.tai, 'hygiene', sl.is_hygiene,
           'start_points', sl.start_points) end
    into v_stake
    from table_sessions ts left join stake_levels sl on sl.id = ts.stake_level_id
   where ts.id = s.id;

  select coalesce(jsonb_agg(jsonb_build_object(
           'code', p.code, 'label', p.label, 'tai', p.tai, 'max_count', p.max_count,
           'group', p.group_key, 'result_only', p.result_only, 'dealer_only', p.dealer_only,
           'conflicts', to_jsonb(p.conflicts)) order by p.sort), '[]'::jsonb)
    into v_catalog
    from scoring_patterns p
   where p.is_active and (not p.needs_flower or s.flower = '有花');

  select * into v_round from session_rounds
   where session_id = s.id and status <> 'voided' order by round_no desc limit 1;
  if found then v_state := public._tbl_round_state(v_round.id); end if;

  /* 分數：加 score_delta（＝已經生效的）。還在確認中的那一局，已經確認的那幾份也算進去
     —— 逐家確認的意思就是「確認了當場入帳」。 */
  select coalesce(jsonb_object_agg(k, tot), '{}'::jsonb) into v_totals
    from (select e.key as k, sum(e.value::int) as tot
            from hands h, jsonb_each_text(h.score_delta) e
           where h.session_id = s.id and h.status in ('confirmed', 'pending') group by e.key) x;
  if v_round.id is not null then
    select coalesce(jsonb_object_agg(k, tot), '{}'::jsonb) into v_round_totals
      from (select e.key as k, sum(e.value::int) as tot
              from hands h, jsonb_each_text(h.score_delta) e
             where h.round_id = v_round.id and h.status in ('confirmed', 'pending') group by e.key) x;

    select jsonb_build_object(
             'hand_id', h.id, 'result', h.result, 'winner_seat', h.winner_seat,
             'deal_in_seat', h.deal_in_seat, 'tai_pattern', h.tai_pattern,
             'patterns', h.patterns, 'score_delta', h.score_delta, 'proposed_delta', h.proposed_delta,
             'need_confirm', to_jsonb(h.need_confirm), 'confirmed_seats', to_jsonb(h.confirmed_seats),
             'cancelled_seats', to_jsonb(h.cancelled_seats),
             'submitted_seat', h.submitted_seat, 'hand_no', h.hand_no, 'wind', h.wind,
             'dealer_seat', h.dealer_seat, 'renzhuang', h.renzhuang, 'at', h.created_at,
             'i_must_confirm', v_my_seat = any(h.need_confirm)
                               and not (v_my_seat = any(h.confirmed_seats))
                               and not (v_my_seat = any(h.cancelled_seats)))
      into v_pending
      from hands h where h.round_id = v_round.id and h.status = 'pending';

    select jsonb_build_object('hand_id', h.id, 'rejected_seat', h.rejected_seat,
                              'submitted_seat', h.submitted_seat, 'at', h.created_at)
      into v_last_reject
      from hands h
     where h.round_id = v_round.id and h.status = 'rejected'
       and not exists (select 1 from hands h2 where h2.round_id = v_round.id
                        and h2.status in ('pending','confirmed') and h2.created_at > h.created_at)
     order by h.created_at desc limit 1;

    select coalesce(jsonb_agg(x.j order by x.hand_no desc), '[]'::jsonb) into v_history
      from (select h.hand_no, jsonb_build_object(
                     'hand_id', h.id, 'hand_no', h.hand_no, 'wind', h.wind, 'dealer_seat', h.dealer_seat,
                     'renzhuang', h.renzhuang, 'result', h.result, 'winner_seat', h.winner_seat,
                     'deal_in_seat', h.deal_in_seat, 'tai_pattern', h.tai_pattern,
                     'patterns', h.patterns, 'score_delta', h.score_delta) as j
              from hands h where h.round_id = v_round.id and h.status = 'confirmed' and h.result <> 'kala'
             order by h.hand_no desc limit 12) x;
  end if;

  /* 整場紀錄（牌局紀錄頁）：還在確認中、已生效、全部取消的都列，撤銷掉的不列 */
  select coalesce(jsonb_agg(x.j order by x.at desc), '[]'::jsonb) into v_log
    from (select h.created_at as at, jsonb_build_object(
                   'hand_id', h.id, 'round_no', r.round_no, 'wind', h.wind, 'hand_no', h.hand_no,
                   'dealer_seat', h.dealer_seat, 'renzhuang', h.renzhuang, 'result', h.result,
                   'winner_seat', h.winner_seat, 'deal_in_seat', h.deal_in_seat,
                   'submitted_seat', h.submitted_seat, 'patterns', h.patterns, 'tai_pattern', h.tai_pattern,
                   'proposed_delta', coalesce(h.proposed_delta, h.score_delta), 'score_delta', h.score_delta,
                   'need_confirm', to_jsonb(h.need_confirm), 'confirmed_seats', to_jsonb(h.confirmed_seats),
                   'cancelled_seats', to_jsonb(h.cancelled_seats), 'status', h.status, 'at', h.created_at) as j
            from hands h join session_rounds r on r.id = h.round_id
           where h.session_id = s.id and h.status in ('pending', 'confirmed', 'rejected')
           order by h.created_at desc limit 300) x;

  select coalesce(jsonb_agg(jsonb_build_object('round_no', r.round_no, 'status', r.status)
                            order by r.round_no), '[]'::jsonb)
    into v_rounds
    from session_rounds r where r.session_id = s.id and r.status <> 'voided';

  return jsonb_build_object('ok', true,
    'device', jsonb_build_object('label', d.label, 'table', v_table, 'store', v_store),
    'session', jsonb_build_object(
      'id', s.id, 'channel', s.score_channel, 'game_type', s.game_type, 'flower', s.flower,
      'planned_rounds', s.planned_rounds, 'stake', v_stake, 'started_at', s.started_at,
      'supported', coalesce(s.game_type, '台麻') = '台麻',
      /* 💥 爆卡不追加 ⇒ 整場提前結束（2026-09-30） */
      'ended_reason', case when exists (select 1 from public.session_busts b
                                         where b.session_id = s.id and b.decision = 'ended') then 'bust' end,
      'bust_seat', (select b.seat from public.session_busts b
                     where b.session_id = s.id and b.decision = 'ended' order by b.decided_at limit 1)),
    'players', v_players, 'my_seat', v_my_seat, 'my_player_id', v_my_player,
    'order_set', (select count(*) from session_players where session_id = s.id and left_at is null and seat is not null) = 4,
    'rounds', v_rounds,
    'round', case when v_round.id is null then null else
               jsonb_build_object('round_no', v_round.round_no, 'status', v_round.status,
                                  'first_dealer_seat', v_round.first_dealer_seat) || v_state end,
    'totals', coalesce(v_totals, '{}'::jsonb), 'round_totals', coalesce(v_round_totals, '{}'::jsonb),
    'pending', v_pending, 'last_reject', v_last_reject, 'history', coalesce(v_history, '[]'::jsonb),
    'log', coalesce(v_log, '[]'::jsonb), 'patterns', v_catalog,
    /* 💥 追加積分／不追加結束的紀錄（2026-09-30）：另開一個鍵，不混進 log（舊版平板會畫壞） */
    'bust_log', (select coalesce(jsonb_agg(jsonb_build_object(
                   'id', b.id, 'seat', b.seat, 'decision', b.decision, 'added_points', b.added_points,
                   'round_no', r.round_no, 'wind', h.wind, 'hand_no', h.hand_no, 'at', b.decided_at)
                   order by b.decided_at desc), '[]'::jsonb)
                   from public.session_busts b
                   left join public.hands h on h.id = b.hand_id
                   left join public.session_rounds r on r.id = h.round_id
                  where b.session_id = s.id and b.decision in ('added', 'ended')),
    /* 🆕 2026-09-29 段位分變動（座位 → 分數）：成績算完才有，沒算過是 null ⇒ 前端顯示「—」。
       score_points ＝ 每一將實際變動的加總（夾過降階保護之後），就是 App 牌局詳情的「段位分」 */
    /* 💥 追加（座位 → 總額）與「現在在等誰決定」；成績算完就不再等（2026-09-30） */
    'extras', (select coalesce(jsonb_object_agg(x.seat::text, x.tot), '{}'::jsonb)
                 from (select b.seat, sum(b.added_points) as tot from public.session_busts b
                        where b.session_id = s.id and b.decision = 'added' group by b.seat) x),
    'bust', case when public._session_scored(s.id) then null else
              (select jsonb_build_object('seat', b.seat, 'hand_id', b.hand_id)
                 from public.session_busts b
                where b.session_id = s.id and b.decision = 'pending' order by b.seat limit 1) end,
    'pkg', public._pkg_time(s.id, false),   /* ⏰ 包桌續時（2026-10-01）：不含會員 id */
    'rating_delta', (select jsonb_object_agg(sp.seat::text, sp.score_points)
                       from session_players sp
                      where sp.session_id = s.id and sp.seat is not null
                        and sp.finish_rank is not null and sp.score_points is not null));
end $function$
;

-- [7.0] _team_card
CREATE OR REPLACE FUNCTION public._team_card(p_team_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_t      record;
  v_from   timestamptz;
  v_played int;
  v_month  int;
  v_cnt    int;
  v_me     uuid := public.current_member_id();
  v_req    text;
begin
  select t.*, s.name as store_name
    into v_t
    from public.teams t
    left join public.stores s on s.id = t.home_store_id
   where t.id = p_team_id and t.deleted_at is null;
  if not found then return null; end if;

  /* 「本月」用台北日曆月，與當日暢打同一個判準 ——
     系統裡不要有第二種「這個月是哪一段」。 */
  v_from := (date_trunc('month', (now() at time zone 'Asia/Taipei')) at time zone 'Asia/Taipei');

  select count(*), count(*) filter (where played_at >= v_from)
    into v_played, v_month
    from public._team_session_ids(p_team_id);

  select count(*) into v_cnt
    from public.team_members where team_id = p_team_id and left_at is null;

  /* 我跟這個團之間還在談的那一筆是什麼。
     ⚠ 沒登入時 `v_me` 是 null ⇒ 這段查不到東西 ⇒ 回 null，那是對的。
     ⚠ 不需要 order by / limit：部分唯一索引保證同一人對同一團最多一筆在談。 */
  select r.kind into v_req
    from public.team_requests r
   where r.team_id = p_team_id and r.member_id = v_me
     and r.status = 'pending' and r.expires_at > now();

  return jsonb_build_object(
    'id',              v_t.id,
    'name',            v_t.name,
    'intro',           v_t.intro,
    'crest_emoji',     v_t.crest_emoji,
    /* 🔴 2026-09-17：`crest_path` 是**正在用的那張** —— source 是 photo 才給。
       所有畫團徽的地方（名冊、團卡、熱門榜、成功卡）都只讀這一欄，
       所以「照片存著但選用預設」時它們自動畫預設，一行都不用改。
       ⚠ 被總部下架（crest_blocked）時仍然一律 null。 */
    'crest_path',      case when v_t.crest_blocked or v_t.crest_source <> 'photo'
                            then null else v_t.crest_path end,
    /* 存著的那張（不管有沒有在用）—— 只有換團徽抽屜要讀。 */
    'crest_photo_path', case when v_t.crest_blocked then null else v_t.crest_path end,
    'crest_source',    v_t.crest_source,
    'join_policy',     v_t.join_policy,
    'home_store_id',   v_t.home_store_id,
    'home_store_name', v_t.store_name,
    'monthly_goal',    v_t.monthly_goal,
    'member_limit',    v_t.member_limit,
    'member_count',    v_cnt,
    'played',          v_played,
    'month_played',    v_month,
    'my_request',      v_req,
    'created_at',      v_t.created_at);
end $function$
;

-- [7.0] _team_claim_check
CREATE OR REPLACE FUNCTION public._team_claim_check(p_team_id uuid, p_member_id uuid)
 RETURNS text
 LANGUAGE plpgsql
 STABLE
AS $function$
declare
  v_lead  uuid;
  v_first uuid;
  v_seen  timestamptz;
  v_days  constant int := 60;   -- 失聯門檻
begin
  if not exists (select 1 from public.team_members tm
                  join public.teams t on t.id = tm.team_id and t.deleted_at is null
                 where tm.team_id = p_team_id and tm.member_id = p_member_id
                   and tm.left_at is null) then
    return 'not_member';
  end if;

  select tm.member_id into v_lead from public.team_members tm
   where tm.team_id = p_team_id and tm.role = 'leader' and tm.left_at is null;

  if v_lead = p_member_id then return 'already_leader'; end if;

  /* 🔴 2026-09-13：這裡原本是「年資最久的非團長成員」。
     改成**參與度最高**（使用者指定）——「誰在撐這個團」比「誰待最久」
     更接近團長該是誰，而一個三年沒來的元老不會是好團長。
     ⚠ 仍然不是「誰先按誰接任」：答案由資料決定且唯一，
       所以團長一失聯也不會被新人搶走。 */
  v_first := public._team_top_contributor(p_team_id, v_lead);

  if v_first is distinct from p_member_id then return 'not_eligible'; end if;

  /* 沒有團長（例如資料異常）就不用等 60 天，直接讓參與度最高的人接。 */
  if v_lead is null then return null; end if;

  /* ⚠ 兩個欄位取**較晚**的那一個。只看 App 的話，
     「常來店但不開 App」的團長會被誤判失聯，而那正是老闆型團長的樣子。 */
  select greatest(coalesce(m.last_app_active_at, 'epoch'::timestamptz),
                  coalesce(m.last_visit_at,      'epoch'::timestamptz))
    into v_seen
    from public.members m where m.id = v_lead;

  if v_seen > now() - make_interval(days => v_days) then return 'leader_active'; end if;

  return null;
end $function$
;

-- [7.0] _team_disband
CREATE OR REPLACE FUNCTION public._team_disband(p_team_id uuid, p_by uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_n    int;
  v_org  uuid;
  v_team text;
  v_mid  uuid;
begin
  update public.teams set deleted_at = now(), updated_at = now()
   where id = p_team_id and deleted_at is null;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'already_gone', 'message', '這個團已經解散了');
  end if;

  /* 🆕 通知要在**標記離開之前**送 —— 標完之後那些人就不在名單裡了，
     再去撈會一個都撈不到，而且不會報錯（同硬規則 4 那個形狀：
     濾成空陣列，看起來像「本來就沒人」）。 */
  select t.org_id, t.name into v_org, v_team
    from public.teams t where t.id = p_team_id;

  for v_mid in
    select tm.member_id from public.team_members tm
     where tm.team_id = p_team_id
       and tm.left_at is null
       /* 按下去的那個人不用通知他自己按了什麼。
          ⚠ 用 `is distinct from` 不用 `<>` —— 總部那條路 p_by 是 null，
            而 `任何值 <> null` 是 null 不是 true ⇒ 會變成一個都不通知
            （同硬規則 0.7：null 在運算式裡不是「沒有」，是會傳染）。 */
       and tm.member_id is distinct from p_by
  loop
    perform public._team_notify(v_org, v_mid, 'team_out', null,
              v_team || ' 已經解散了', p_team_id, v_team, null);
  end loop;

  update public.team_members
     set left_at = now(), left_reason = 'disband'
   where team_id = p_team_id and left_at is null;
  get diagnostics v_n = row_count;

  /* ⚠ `p_by` 可以是 null —— 總部那個帳號 `member_id` 是 null
     （Email 路徑的 staff 本來就不是會員）。`decided_by` 允許 null。 */
  update public.team_requests
     set status = 'cancelled', decided_by = p_by, decided_at = now()
   where team_id = p_team_id and status = 'pending';

  return jsonb_build_object('ok', true, 'left', v_n);
end $function$
;

-- [7.0] _team_expire_requests
CREATE OR REPLACE FUNCTION public._team_expire_requests(p_team_id uuid DEFAULT NULL::uuid)
 RETURNS integer
 LANGUAGE plpgsql
AS $function$
declare v_n int;
begin
  update public.team_requests
     set status = 'expired', decided_at = now()
   where status = 'pending' and expires_at <= now()
     and (p_team_id is null or team_id = p_team_id);
  get diagnostics v_n = row_count;
  return v_n;
end $function$
;

-- [7.0] _team_notify
CREATE OR REPLACE FUNCTION public._team_notify(p_org uuid, p_to uuid, p_type text, p_from_name text, p_text text, p_team_id uuid, p_team_name text, p_ref uuid)
 RETURNS void
 LANGUAGE sql
AS $function$
  insert into public.app_notifications (org_id, member_id, type, payload, ref_id)
  values (p_org, p_to, p_type,
          jsonb_build_object('from_name', p_from_name, 'text', p_text,
                             'team_id', p_team_id, 'team_name', p_team_name),
          p_ref);
$function$
;

-- [7.0] _team_session_ids
CREATE OR REPLACE FUNCTION public._team_session_ids(p_team_id uuid)
 RETURNS TABLE(session_id uuid, played_at timestamp with time zone)
 LANGUAGE sql
 STABLE
AS $function$
  with t as (select org_id from public.teams where id = p_team_id)
  select sp.session_id,
         min(coalesce(sp.joined_at, ts.created_at)) as played_at
    from public.session_players sp
    join public.table_sessions  ts on ts.id = sp.session_id
    join t on t.org_id = ts.org_id
   where ts.status <> 'voided'
     and ts.deleted_at is null
   group by sp.session_id
  having count(*) >= 2
     /* 🔴 「整桌都是團員」＝ 符合條件的人數 ＝ 在座人數。
        用 `count(*) filter` 比對兩個數字，而不是 `not exists 非團員` ——
        兩種寫法等價，但這一種在驗證時印得出「4 個裡有 3 個是團員」，
        而那正是紅掉時要看的東西。 */
     and count(*) = count(*) filter (
           where exists (
             select 1
               from public.team_members tm
              where tm.team_id   = p_team_id
                and tm.member_id = sp.member_id
                and tm.joined_at <= coalesce(sp.joined_at, ts.created_at)
                and (tm.left_at is null
                     or tm.left_at > coalesce(sp.joined_at, ts.created_at))))
$function$
;

-- [7.0] _team_top_contributor
CREATE OR REPLACE FUNCTION public._team_top_contributor(p_team_id uuid, p_exclude uuid DEFAULT NULL::uuid)
 RETURNS uuid
 LANGUAGE sql
 STABLE
AS $function$
  select tm.member_id
    from public.team_members tm
   where tm.team_id = p_team_id
     and tm.left_at is null
     and (p_exclude is null or tm.member_id <> p_exclude)
   order by
     /* 近 90 天在這個團打過幾場。與團詳情的「本月貢獻」同一個來源。 */
     (select count(*) from public._team_session_ids(p_team_id) ts
       where ts.played_at >= now() - interval '90 days'
         and exists (select 1 from public.session_players sp
                      where sp.session_id = ts.session_id
                        and sp.member_id = tm.member_id)) desc,
     tm.joined_at,          -- 平手：年資久的優先
     tm.member_id           -- 再平手：讓答案唯一
   limit 1;
$function$
;

-- [7.0] _try_auto_seat_tx
CREATE OR REPLACE FUNCTION public._try_auto_seat_tx(p_org uuid, p_queue uuid, p_staff uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
      begin
        -- 【身分 2026-09-29】從 API 進來的只有店員能叫；內部呼叫一律接 _try_auto_seat_tx_core
        perform public._api_staff_only();
        return public._try_auto_seat_tx_core(p_org, p_queue, p_staff);
      end $function$
;

-- [7.0] _try_auto_seat_tx_core
CREATE OR REPLACE FUNCTION public._try_auto_seat_tx_core(p_org uuid, p_queue uuid, p_staff uuid DEFAULT NULL::uuid)
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
    v_fc := pos_table_forecast_tx_core(p_org, v_store, null);
    return jsonb_build_object('ok', false, 'reason', 'no_free_table',
      'next_free_at', v_fc->'next_free_at',
      'next_free_table', v_fc->'next_free_table');
  end if;

  return pos_seat_queue_tx(p_org, p_queue, v_tbl, p_staff);
end $function$
;

-- [7.0] ach_meta_count_tx
CREATE OR REPLACE FUNCTION public.ach_meta_count_tx(p_member uuid, p_scope text, p_value text)
 RETURNS bigint
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select case when p_scope in ('ui_category','group_key') and p_value is not null then (
    select count(*)
      from member_achievements ma
      join achievements a2 on a2.id = ma.achievement_id
      join members m on m.id = ma.member_id
     where ma.member_id = p_member
       and ma.status = 'unlocked'
       and a2.org_id = m.org_id
       and a2.deleted_at is null
       and not coalesce(a2.trigger ? 'count', false)
       and case p_scope
             when 'ui_category' then a2.ui_category = p_value
             when 'group_key'   then a2.group_key   = p_value
             else false
           end
  ) end;
$function$
;

-- [7.0] ach_meta_tx
CREATE OR REPLACE FUNCTION public.ach_meta_tx(p_member uuid, p_idem text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_org     uuid;
  r         record;
  v_scope   text;
  v_value   text;
  v_need    bigint;
  v_got     bigint;
  v_one     jsonb;
  v_unlocked jsonb := '[]'::jsonb;
  v_skipped  jsonb := '[]'::jsonb;
  v_checked int := 0;
begin
  select org_id into v_org from members where id = p_member and deleted_at is null;
  if v_org is null then
    return jsonb_build_object('ok', false, 'reason', 'member_not_found');
  end if;

  for r in
    select id, code, trigger
      from achievements
     where org_id = v_org
       and deleted_at is null
       and is_active
       and trigger ? 'count'                       -- 🎯 有 count 就是 meta
       and (trigger->>'event') = 'achievement_unlocked'
       and (valid_from is null or now() >= valid_from)
       and (valid_to   is null or now() <  valid_to)
     order by sort, code
  loop
    v_checked := v_checked + 1;
    v_scope := r.trigger->>'scope';
    v_value := r.trigger->>'value';
    v_need  := nullif(r.trigger->>'count', '')::bigint;

    -- 🔴 認不得的 scope／缺值一律跳過並報出來，**不可以 fallback 成「算全部」**
    if v_scope is null or v_value is null or v_need is null or v_need <= 0 then
      v_skipped := v_skipped || jsonb_build_array(jsonb_build_object(
        'code', r.code, 'reason', 'bad_trigger', 'trigger', r.trigger));
      continue;
    end if;

    /* 🎯 計數改叫 `ach_meta_count_tx` —— 與讀取端（成就牆的進度條）同一支。
       各寫一份的症狀是「進度條說 4 / 15，而它在第 5 枚就解鎖了」，
       **而且兩邊都不會報錯**。 */
    v_got := public.ach_meta_count_tx(p_member, v_scope, v_value);

    -- null ＝ 那支函式認不得這個 scope ⇒ 與上面同一個處理，不可以當成 0
    if v_got is null then
      v_skipped := v_skipped || jsonb_build_array(jsonb_build_object(
        'code', r.code, 'reason', 'bad_trigger', 'trigger', r.trigger));
      continue;
    end if;

    -- 已經解鎖就不必再判（但上面的 count 仍然跑過，那是讀取端要的值）
    if exists (select 1 from member_achievements ma
                where ma.member_id = p_member and ma.achievement_id = r.id
                  and ma.status = 'unlocked') then
      continue;
    end if;

    if v_got >= v_need then
      v_one := public.ach_unlock_tx(
        p_member, r.code, coalesce(p_idem, 'meta') || ':' || r.code);
      v_unlocked := v_unlocked || jsonb_build_array(jsonb_build_object(
        'code', r.code, 'got', v_got, 'need', v_need, 'result', v_one));
    end if;
  end loop;

  return jsonb_build_object('ok', true, 'checked', v_checked,
                            'unlocked', v_unlocked, 'skipped', v_skipped);
end $function$
;

-- [7.0] ach_pin_tx
CREATE OR REPLACE FUNCTION public.ach_pin_tx(p_code text, p_on boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_me uuid; v_org uuid; a achievements; r member_achievements;
begin
  -- 🔴 身分一律從 JWT 取，不收 p_member_id（同 2026-09-20 那 21 支的通則）
  v_me := public.current_member_id();
  if v_me is null then
    raise exception '未登入或登入已過期，請重新開啟 App' using errcode = '28000';
  end if;
  select org_id into v_org from members where id = v_me;

  select * into a from achievements
   where org_id = v_org and code = p_code and deleted_at is null;
  if not found then return jsonb_build_object('ok', false, 'reason', 'achievement_not_found'); end if;

  select * into r from member_achievements
   where member_id = v_me and achievement_id = a.id for update;
  if not found or r.status <> 'unlocked' then
    return jsonb_build_object('ok', false, 'reason', 'not_unlocked');
  end if;

  if p_on then
    -- 🎯 切換語意：先把舊的取消，不要叫客人先取下再釘
    --   （把「最多 3 枚」改成「最多 1 枚」而不改語意的話，
    --     客人會遇到「展示櫃滿了」而那是一句沒有意義的話）
    update member_achievements
       set pinned = false, updated_at = now()
     where member_id = v_me and pinned and id <> r.id;
  end if;

  update member_achievements
     set pinned = p_on, updated_at = now()
   where id = r.id;

  return jsonb_build_object('ok', true, 'pinned', p_on, 'code', p_code);
end $function$
;

-- [7.0] ach_progress_tx
CREATE OR REPLACE FUNCTION public.ach_progress_tx(p_member uuid, p_code text, p_delta bigint DEFAULT 1, p_idem text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_org uuid; a achievements; r member_achievements;
  v_new bigint; v_tier int; v_max int;
begin
  select org_id into v_org from members where id = p_member and deleted_at is null;
  if v_org is null then return jsonb_build_object('ok', false, 'reason', 'member_not_found'); end if;

  select * into a from achievements
   where org_id = v_org and code = p_code and deleted_at is null;
  if not found then return jsonb_build_object('ok', false, 'reason', 'achievement_not_found'); end if;
  if a.struct not in ('cumulative','streak') then
    return jsonb_build_object('ok', false, 'reason', 'not_cumulative');
  end if;
  if not _ach_live(a) then return jsonb_build_object('ok', true, 'skipped', 'out_of_window'); end if;

  r := _ma_row(p_member, a.id, v_org);
  if r.status = 'unlocked' then
    return jsonb_build_object('ok', true, 'already', true, 'value', r.current_value);
  end if;

  -- 🔴 ⑩ 冪等：同一把鑰匙再送一次就跳過（設計稿漏掉的）
  if p_idem is not null and r.last_idem = p_idem then
    return jsonb_build_object('ok', true, 'dedup', true, 'value', r.current_value);
  end if;

  v_new := r.current_value + p_delta;
  select coalesce(max(tier_level), 0) into v_max
    from achievement_tiers where achievement_id = a.id;
  select coalesce(max(tier_level), 0) into v_tier
    from achievement_tiers where achievement_id = a.id and threshold <= v_new;

  update member_achievements
     set current_value = v_new,
         current_tier  = greatest(current_tier, v_tier),
         status = case when v_max > 0 and v_tier >= v_max then 'unlocked'
                       when v_new > 0 then 'in_progress' else 'locked' end,
         unlocked_at = case when v_max > 0 and v_tier >= v_max and unlocked_at is null
                            then now() else unlocked_at end,
         last_idem = coalesce(p_idem, last_idem),
         updated_at = now()
   where id = r.id;

  return jsonb_build_object('ok', true, 'value', v_new, 'tier', v_tier, 'max', v_max);
end $function$
;

-- [7.0] ach_streak_tx
CREATE OR REPLACE FUNCTION public.ach_streak_tx(p_member uuid, p_code text, p_period_key text, p_advance boolean DEFAULT true, p_idem text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_org uuid; a achievements; r member_achievements;
  v_new bigint; v_tier int; v_max int;
begin
  if p_period_key is null or p_period_key = '' then
    return jsonb_build_object('ok', false, 'reason', 'period_key_required');
  end if;

  select org_id into v_org from members where id = p_member and deleted_at is null;
  if v_org is null then return jsonb_build_object('ok', false, 'reason', 'member_not_found'); end if;

  select * into a from achievements
   where org_id = v_org and code = p_code and deleted_at is null;
  if not found then return jsonb_build_object('ok', false, 'reason', 'achievement_not_found'); end if;
  if a.struct <> 'streak' then return jsonb_build_object('ok', false, 'reason', 'not_streak'); end if;
  if not _ach_live(a) then return jsonb_build_object('ok', true, 'skipped', 'out_of_window'); end if;

  r := _ma_row(p_member, a.id, v_org);
  if r.status = 'unlocked' then
    return jsonb_build_object('ok', true, 'already', true, 'value', r.current_value);
  end if;

  -- 🎯 連續型天然冪等：同一個期間鍵重送不會重複計
  if r.last_period is not null and r.last_period = p_period_key then
    return jsonb_build_object('ok', true, 'dedup', true, 'value', r.current_value);
  end if;

  v_new := case when p_advance then r.current_value + 1 else 1 end;
  select coalesce(max(tier_level), 0) into v_max
    from achievement_tiers where achievement_id = a.id;
  select coalesce(max(tier_level), 0) into v_tier
    from achievement_tiers where achievement_id = a.id and threshold <= v_new;

  update member_achievements
     set current_value = v_new,
         current_tier  = greatest(current_tier, v_tier),
         last_period   = p_period_key,
         status = case when v_max > 0 and v_tier >= v_max then 'unlocked'
                       when v_new > 0 then 'in_progress' else 'locked' end,
         unlocked_at = case when v_max > 0 and v_tier >= v_max and unlocked_at is null
                            then now() else unlocked_at end,
         last_idem = coalesce(p_idem, last_idem),
         updated_at = now()
   where id = r.id;

  return jsonb_build_object('ok', true, 'value', v_new, 'tier', v_tier, 'max', v_max);
end $function$
;

-- [7.0] ach_unlock_tx
CREATE OR REPLACE FUNCTION public.ach_unlock_tx(p_member uuid, p_code text, p_idem text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_org uuid; a achievements; r member_achievements;
begin
  select org_id into v_org from members where id = p_member and deleted_at is null;
  if v_org is null then return jsonb_build_object('ok', false, 'reason', 'member_not_found'); end if;

  select * into a from achievements
   where org_id = v_org and code = p_code and deleted_at is null;
  if not found then return jsonb_build_object('ok', false, 'reason', 'achievement_not_found'); end if;
  if not _ach_live(a) then return jsonb_build_object('ok', true, 'skipped', 'out_of_window'); end if;

  r := _ma_row(p_member, a.id, v_org);
  if r.status = 'unlocked' then return jsonb_build_object('ok', true, 'already', true); end if;

  update member_achievements
     set status = 'unlocked', current_tier = 1, unlocked_at = now(),
         last_idem = coalesce(p_idem, last_idem), updated_at = now()
   where id = r.id;

  -- ⚠ 這裡**刻意不發點數**：那支發放函式今天不存在，而且 §8.5 的鐵則是
  --   「成就給徽章與稱號，點數是最克制的那一層」。reward_points 欄位留著，
  --   日後真的要發再接。
  --   🔴 這段話刻意不寫出那個函式的識別字 —— 寫了會觸發掃描（硬規則 3.5）
  return jsonb_build_object('ok', true, 'unlocked', true,
                            'code', p_code, 'title', a.grants_title);
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

-- [7.0] admin_find_members_tx
CREATE OR REPLACE FUNCTION public.admin_find_members_tx(p_phone text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_p text := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');
begin
  if not public.can('member.hide') then
    return jsonb_build_object('ok', false, 'reason', 'forbidden', 'message', '只有總部可以查詢');
  end if;
  if length(v_p) < 4 then
    return jsonb_build_object('ok', true, 'rows', '[]'::jsonb);
  end if;
  /* ⚠ limit 要放在子查詢裡 —— 寫在 jsonb_agg 那一層的話它限制的是
     「聚合完的那一列」，等於沒限制。 */
  return jsonb_build_object('ok', true, 'rows', coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', x.id,
             'name', x.name,
             'phone', x.phone,
             'line_bound', x.line_bound,
             'created_at', x.created_at,
             'hidden_at', x.hidden_at,
             'hidden_source', (select l.source from member_hide_log l
                                where l.member_id = x.id and l.action = 'hide'
                                order by l.at desc limit 1),
             'hidden_reason', (select l.reason from member_hide_log l
                                where l.member_id = x.id and l.action = 'hide'
                                order by l.at desc limit 1))
           order by x.created_at)
      from (
        select m.id, coalesce(h.display_name, m.display_name) as name, m.phone,
               m.line_user_id is not null as line_bound, m.created_at, m.hidden_at
          from members m
          left join member_hidden h on h.member_id = m.id
         where m.org_id = (select s.org_id from staff s
                            where s.id = (select staff_id from public.current_staff()))
           and m.deleted_at is null
           and m.phone like '%' || v_p || '%'
         order by m.created_at
         limit 20
      ) x), '[]'::jsonb));
end $function$
;

-- [7.0] admin_hide_member_tx
CREATE OR REPLACE FUNCTION public.admin_hide_member_tx(p_member_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not public.can('member.hide') then
    return jsonb_build_object('ok', false, 'reason', 'forbidden', 'message', '只有總部可以隱藏會員帳號');
  end if;
  if nullif(btrim(coalesce(p_reason, '')), '') is null then
    return jsonb_build_object('ok', false, 'reason', 'reason_required', 'message', '請寫下原因（例：客人來電要求）');
  end if;
  return public._member_hide_core(p_member_id, 'hq',
           (select staff_id from public.current_staff()), btrim(p_reason));
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

-- [7.0] admin_list_stake_levels_tx
CREATE OR REPLACE FUNCTION public.admin_list_stake_levels_tx()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_org uuid;
begin
  if not public.can('stake.write') then
    return jsonb_build_object('ok', false, 'reason', 'forbidden', 'message', '沒有權限查看積分級距');
  end if;
  v_org := public.current_org_id();
  return jsonb_build_object('ok', true, 'rows', coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', sl.id, 'label', sl.label, 'base', sl.base, 'tai', sl.tai,
             'is_hygiene', sl.is_hygiene, 'is_active', sl.is_active,
             'start_points', sl.start_points,
             'store', st.name,                 -- null ＝ 全部門市共用
             'open_tables', (select count(*) from public.table_sessions ts
                              where ts.stake_level_id = sl.id and ts.status = 'open' and ts.deleted_at is null),
             'updated_at', sl.updated_at)
           order by sl.sort_order, sl.label)
      from public.stake_levels sl
      left join public.stores st on st.id = sl.store_id
     where sl.org_id = v_org and sl.deleted_at is null), '[]'::jsonb));
end $function$
;

-- [7.0] admin_pair_table_device_tx
CREATE OR REPLACE FUNCTION public.admin_pair_table_device_tx(p_table_id uuid, p_label text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_staff uuid; t record; v_token text; v_id uuid;
begin
  v_staff := (select staff_id from public.current_staff());
  if v_staff is null then
    return jsonb_build_object('ok', false, 'reason', 'not_staff', 'message', '請先登入');
  end if;
  /* 🔴 權限一律問 can()，這支不自己比對角色欄位（待辦 29 ①）——
     「誰有權限」與「怎麼判斷」分家，之後改成查表時呼叫點一行都不用動。
     ⚠ 這段註解刻意不寫出那個比對的寫法：寫了會被驗證段的全文掃描命中
       （硬規則 3.5，2026-09-23 第五次踩到，就是這一支）。 */
  if not public.can('device.write') then
    return jsonb_build_object('ok', false, 'reason', 'forbidden',
                              'message', '平板配對是總部的權限，請聯絡總部');
  end if;

  select id, org_id, store_id, label into t from tables where id = p_table_id and deleted_at is null;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'table_not_found', 'message', '找不到這張桌');
  end if;
  if nullif(btrim(coalesce(p_label, '')), '') is null then
    return jsonb_build_object('ok', false, 'reason', 'label_required', 'message', '請輸入平板編號，例如 A3-1');
  end if;

  /* 明文只在這裡回傳一次（POS／後台做成 QR，平板掃了存進自己的 localStorage）。
     資料庫只留 SHA-256。 */
  v_token := encode(extensions.gen_random_bytes(32), 'hex');
  insert into table_devices (org_id, store_id, table_id, label, token_hash, created_by_staff_id)
  values (t.org_id, t.store_id, t.id, btrim(p_label), public._tbl_hash(v_token), v_staff)
  returning id into v_id;
  return jsonb_build_object('ok', true, 'device_id', v_id, 'token', v_token, 'table', t.label);
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

-- [7.0] admin_remove_team_crest_tx
CREATE OR REPLACE FUNCTION public.admin_remove_team_crest_tx(p_team_id uuid, p_reason text DEFAULT NULL::text, p_block boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_old text;
begin
  if not public.can('member.write') then
    return jsonb_build_object('ok', false, 'reason', 'forbidden', 'message', '沒有權限');
  end if;

  select t.crest_path into v_old from public.teams t
   where t.id = p_team_id and t.deleted_at is null;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'not_found', 'message', '找不到這個牌咖團');
  end if;

  /* 🔴 2026-09-17：source 一起切回 default（理由同 clear_team_crest_tx）。 */
  update public.teams
     set crest_path = null,
         crest_source = 'default',
         crest_blocked = coalesce(p_block, false) or crest_blocked,
         updated_at = now()
   where id = p_team_id;

  /* ⚠ 只回「本來有沒有照片」，不回路徑 —— 路徑是 Storage 的公開網址。 */
  return jsonb_build_object('ok', true, 'had_photo', v_old is not null,
                            'blocked', coalesce(p_block, false), 'reason_note', p_reason);
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

-- [7.0] admin_set_stake_start_points_tx
CREATE OR REPLACE FUNCTION public.admin_set_stake_start_points_tx(p_id uuid, p_start_points integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_org uuid; v_staff uuid; v_open int;
begin
  if not public.can('stake.write') then
    return jsonb_build_object('ok', false, 'reason', 'forbidden', 'message', '沒有權限修改起始積分');
  end if;
  v_org := public.current_org_id();
  v_staff := (select staff_id from public.current_staff());
  if p_start_points is null or p_start_points < 1 or p_start_points > 9999999 then
    return jsonb_build_object('ok', false, 'reason', 'bad_points', 'message', '起始積分要在 1 到 9,999,999 之間');
  end if;
  update public.stake_levels
     set start_points = p_start_points, updated_at = now(), updated_by = v_staff   -- 🔴 操作者從登入身分取
   where id = p_id and org_id = v_org and deleted_at is null;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'not_found', 'message', '找不到這個級距');
  end if;
  select count(*) into v_open from public.table_sessions
   where stake_level_id = p_id and status = 'open' and deleted_at is null;
  return jsonb_build_object('ok', true, 'id', p_id, 'start_points', p_start_points, 'open_tables', v_open);
end $function$
;

-- [7.0] admin_unhide_member_tx
CREATE OR REPLACE FUNCTION public.admin_unhide_member_tx(p_member_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not public.can('member.hide') then
    return jsonb_build_object('ok', false, 'reason', 'forbidden', 'message', '只有總部可以恢復會員帳號');
  end if;
  if nullif(btrim(coalesce(p_reason, '')), '') is null then
    return jsonb_build_object('ok', false, 'reason', 'reason_required', 'message', '請寫下原因（例：客人到櫃檯要求恢復）');
  end if;
  return public._member_unhide_core(p_member_id,
           (select staff_id from public.current_staff()), btrim(p_reason));
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
        if v_band = 'low' and v_new < v_floor then
          begin
            perform public.fire_event_tx(v_ids[i], 'rank_protected', 1, null, 'protect:' || p_session_id::text);
          exception when others then null;
          end;
        end if;
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

-- [7.0] apply_team_tx
CREATE OR REPLACE FUNCTION public.apply_team_tx(p_team_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_me     uuid := public.current_member_id();
  v_org    uuid := public.current_org_id();
  v_t      record;
  v_cnt    int;
  v_mine   text;
  v_req    uuid;
  v_leader uuid;
  v_name   text;
begin
  if v_me is null or v_org is null then
    return jsonb_build_object('ok', false, 'reason', 'not_logged_in', 'message', '請先登入');
  end if;

  select t.id, t.name, t.join_policy, t.member_limit into v_t
    from public.teams t where t.id = p_team_id and t.deleted_at is null and t.org_id = v_org;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'not_found', 'message', '找不到這個牌咖團');
  end if;

  if exists (select 1 from public.team_members tm
              where tm.team_id = p_team_id and tm.member_id = v_me and tm.left_at is null) then
    return jsonb_build_object('ok', false, 'reason', 'already_member', 'message', '你已經在這個團裡了');
  end if;

  select count(*) into v_cnt from public.team_members tm
    join public.teams t2 on t2.id = tm.team_id and t2.deleted_at is null
   where tm.member_id = v_me and tm.left_at is null;
  if v_cnt >= 10 then
    return jsonb_build_object('ok', false, 'reason', 'too_many_teams',
                              'message', '你已經加入 10 個牌咖團了');
  end if;

  select count(*) into v_cnt from public.team_members tm
   where tm.team_id = p_team_id and tm.left_at is null;
  if v_cnt >= v_t.member_limit then
    return jsonb_build_object('ok', false, 'reason', 'team_full', 'message', '這個團滿了');
  end if;

  perform public._team_expire_requests(p_team_id);
  select display_name into v_name from public.members where id = v_me;

  /* 🎯 團長已經邀過我 ⇒ 我按申請就是答應。不要跳「已經有一筆在談」。 */
  select r.id into v_req from public.team_requests r
   where r.team_id = p_team_id and r.member_id = v_me
     and r.status = 'pending' and r.kind = 'invite';
  if v_req is not null then
    update public.team_requests set status = 'accepted', decided_by = v_me, decided_at = now()
     where id = v_req;
    insert into public.team_members (org_id, team_id, member_id) values (v_org, p_team_id, v_me);
    return jsonb_build_object('ok', true, 'joined', true, 'via', 'invite',
                              'message', '已加入 ' || v_t.name);
  end if;

  if exists (select 1 from public.team_requests r
              where r.team_id = p_team_id and r.member_id = v_me and r.status = 'pending') then
    return jsonb_build_object('ok', false, 'reason', 'already_pending',
                              'message', '你的申請正在等團長審核');
  end if;

  if v_t.join_policy = 'closed' then
    /* ⚠ 這個團本來就不該出現在找團頁（`search_teams_tx` 已經濾掉），
       所以走到這裡通常是舊畫面。話術要講得出下一步。 */
    return jsonb_build_object('ok', false, 'reason', 'closed',
                              'message', '這個團不開放申請，要請團長邀請你');
  end if;

  select tm.member_id into v_leader from public.team_members tm
   where tm.team_id = p_team_id and tm.role = 'leader' and tm.left_at is null;

  if v_t.join_policy = 'open' then
    insert into public.team_members (org_id, team_id, member_id) values (v_org, p_team_id, v_me);
    if v_leader is not null then
      perform public._team_notify(v_org, v_leader, 'team_ok', v_name,
               v_name || ' 加入了 ' || v_t.name, p_team_id, v_t.name, null);
    end if;
    return jsonb_build_object('ok', true, 'joined', true, 'via', 'open',
                              'message', '已加入 ' || v_t.name);
  end if;

  insert into public.team_requests (org_id, team_id, member_id, kind, created_by)
  values (v_org, p_team_id, v_me, 'apply', v_me)
  returning id into v_req;

  if v_leader is not null then
    perform public._team_notify(v_org, v_leader, 'team_req', v_name,
             v_name || ' 想加入 ' || v_t.name, p_team_id, v_t.name, v_req);
  end if;

  return jsonb_build_object('ok', true, 'joined', false, 'request_id', v_req,
                            'message', '已送出申請，等團長審核');
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
  -- 【身分 2026-09-29】只認登入的本人，前端送的 id 一律忽略
  p_blocker := public.current_member_id();
  if p_blocker is null then raise exception '未登入或登入已過期，請重新開啟 App' using errcode = '28000'; end if;
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

-- [7.0] booking_capacity_tx
CREATE OR REPLACE FUNCTION public.booking_capacity_tx(p_store_id uuid, p_play_at timestamp with time zone, p_hours integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_me  uuid := public.current_member_id();
  v_org uuid := public.current_org_id();
begin
  if v_me is null or v_org is null then
    return jsonb_build_object('ok', false, 'reason', 'not_logged_in', 'message', '請先登入');
  end if;
  if p_hours not in (2, 5) then
    return jsonb_build_object('ok', false, 'reason', 'bad_hours', 'message', '時長只能選 2 或 5 小時（要打更久，當天在櫃檯加時間或升級當日暢打）');
  end if;
  if not exists (select 1 from public.stores s
                  where s.id = p_store_id and s.org_id = v_org and s.deleted_at is null) then
    return jsonb_build_object('ok', false, 'reason', 'bad_store', 'message', '找不到那間門市');
  end if;

  perform public._booking_expire(p_store_id);
  return jsonb_build_object('ok', true)
      || public._booking_capacity(p_store_id, p_play_at, p_hours);
end $function$
;

-- [7.0] booking_slots_tx
CREATE OR REPLACE FUNCTION public.booking_slots_tx(p_store_id uuid, p_day date, p_hours integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_me    uuid := public.current_member_id();
  v_org   uuid := public.current_org_id();
  v_open  time;
begin
  if v_me is null or v_org is null then
    return jsonb_build_object('ok', false, 'reason', 'not_logged_in', 'message', '請先登入');
  end if;
  if p_hours not in (2, 5) then
    return jsonb_build_object('ok', false, 'reason', 'bad_hours', 'message', '時長只能選 2 或 5 小時（要打更久，當天在櫃檯加時間或升級當日暢打）');
  end if;
  if p_day is null then
    return jsonb_build_object('ok', false, 'reason', 'bad_day', 'message', '請選一個日期');
  end if;

  select s.open_time into v_open
    from public.stores s
   where s.id = p_store_id and s.org_id = v_org and s.deleted_at is null;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'bad_store', 'message', '找不到那間門市');
  end if;

  /* ⚠ 「沒設營業時間」與「今天沒有時段了」是**兩件事**，
     回同一個空陣列的話，畫面只能對兩者說同一句話。 */
  if v_open is null then
    return jsonb_build_object('ok', false, 'reason', 'no_hours',
                              'message', '這間門市還沒有開放預約，請直接跟門市聯絡');
  end if;

  perform public._booking_expire(p_store_id);

  return jsonb_build_object(
    'ok',    true,
    'day',   p_day,
    'hours', p_hours,
    'slots', public._booking_slots(p_store_id, p_day, p_hours));
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
  -- 【身分 2026-09-29】從 API 進來的只有店員能叫（排程沒有 API 身分，照常）
  perform public._api_staff_only();
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

-- [7.0] cancel_booking_tx
CREATE OR REPLACE FUNCTION public.cancel_booking_tx(p_booking_id uuid, p_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_me uuid := public.current_member_id();
  v_b  record;
begin
  if v_me is null then
    return jsonb_build_object('ok', false, 'reason', 'not_logged_in', 'message', '請先登入');
  end if;

  select * into v_b from public.bookings where id = p_booking_id;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'not_found', 'message', '找不到這筆預約');
  end if;
  if v_b.status <> 'booked' then
    return jsonb_build_object('ok', false, 'reason', 'already_decided', 'status', v_b.status,
                              'message', case v_b.status
                                when 'seated'    then '這筆已經帶到桌了'
                                when 'cancelled' then '這筆已經取消過了'
                                when 'no_show'   then '這筆已經記成沒有出現'
                                else '這筆已經過期了' end);
  end if;

  /* 訂的人，或那個團的團長。
     🎯 團長也能取消是刻意的 —— 訂的人可能臨時聯絡不上，
       而一筆沒有人取消得掉的預約會一路佔著容量。 */
  if v_b.member_id <> v_me and not (
       v_b.team_id is not null and public._is_team_leader(v_b.team_id, v_me)) then
    return jsonb_build_object('ok', false, 'reason', 'not_yours', 'message', '只有訂位的人或團長可以取消');
  end if;

  /* 🔴 開始時間過了就不給客人自己取消 —— 那時它已經不是「取消」
     而是「沒有出現」，而那兩件事在報表上必須分得開（爽約率）。
     ⚠ 話術要講得出下一步，不要只說不行。 */
  if v_b.play_at <= now() then
    return jsonb_build_object('ok', false, 'reason', 'too_late',
                              'message', '已經過了預約時間，請直接跟門市說一聲');
  end if;

  update public.bookings
     set status = 'cancelled',
         cancelled_reason = coalesce(nullif(btrim(coalesce(p_reason, '')), ''), 'member'),
         updated_at = now()
   where id = p_booking_id;

  return jsonb_build_object('ok', true, 'message', '已取消預約');
end $function$
;

-- [7.0] cancel_team_request_tx
CREATE OR REPLACE FUNCTION public.cancel_team_request_tx(p_request_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_me uuid := public.current_member_id();
  v_r  record;
begin
  if v_me is null then
    return jsonb_build_object('ok', false, 'reason', 'not_logged_in', 'message', '請先登入');
  end if;

  select r.* into v_r from public.team_requests r where r.id = p_request_id;
  if not found or v_r.status <> 'pending' then
    return jsonb_build_object('ok', false, 'reason', 'not_found', 'message', '找不到這筆或已經處理過了');
  end if;
  /* ⚠ 只有**發起的人**能收回。邀請由團長收回、申請由本人收回，
     而 `created_by` 正是為了答得出這件事才存在的。 */
  if v_r.created_by <> v_me then
    return jsonb_build_object('ok', false, 'reason', 'not_yours', 'message', '這不是你發出的');
  end if;

  update public.team_requests set status = 'cancelled', decided_by = v_me, decided_at = now()
   where id = p_request_id;
  return jsonb_build_object('ok', true, 'message', '已收回');
end $function$
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
  -- 【身分 2026-09-29】從 API 進來的只有店員能叫（排程沒有 API 身分，照常）
  perform public._api_staff_only();
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
  v_org uuid; v_order_id uuid; v_order_no text;
  v_price jsonb; v_tier text; v_pct int;
  v_sub bigint; v_nodisc bigint; v_coupon_cut bigint; v_tier_cut bigint; v_payable bigint;
  v_pts bigint; v_cash_due bigint; v_pay_sum bigint := 0; v_bal bigint; v_txn uuid;
  pay jsonb; cl jsonb;
begin
  /* 🔴 操作者身分從 JWT 取，不採信呼叫端送的 p_staff_id（2026-09-04）。
     ⚠ 查不到就是 null（會員 App 那條路沒有 staff 身分），不可以報錯。 */
  p_staff_id := (select staff_id from public.current_staff());
  if p_idempotency_key is null then
    raise exception 'idempotency_key 必填';
  end if;

  select id, order_no into v_order_id, v_order_no from orders where idempotency_key = p_idempotency_key;
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

  -- 先鎖住要用的券，再算錢（兩個店員同時用同一張券時，後到的會等前一個結束）
  if p_coupon_ids is not null and array_length(p_coupon_ids, 1) > 0 then
    perform 1 from member_coupons where id = any(p_coupon_ids) and member_id = p_member_id for update;
  end if;

  /* 🎯 2026-10-01：金額一律由共用核心算 —— POS 的報價（pos_quote_tx）叫的是同一支，
     畫面與實收不可能不一樣。算法本身（主檔價、三個桶、券、等級只折檯費）見 _cart_pricing。 */
  v_price      := public._cart_pricing(v_org, p_member_id, p_items, p_coupon_ids);
  v_sub        := (v_price ->> 'subtotal')::bigint;
  v_nodisc     := (v_price ->> 'non_discountable')::bigint;
  v_coupon_cut := (v_price ->> 'coupon_discount')::bigint;
  v_tier       := v_price ->> 'tier';
  v_pct        := (v_price ->> 'tier_discount_pct')::int;
  v_tier_cut   := (v_price ->> 'tier_discount')::bigint;
  v_payable    := (v_price ->> 'payable')::bigint;

  for cl in select * from jsonb_array_elements(v_price -> 'coupons') loop
    update member_coupons
       set discounted_amount = (cl ->> 'cut')::bigint, cost_bearer = cl ->> 'cost_bearer'
     where id = (cl ->> 'member_coupon_id')::uuid;
  end loop;

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

  -- 品項快照一律寫主檔的值（與上面的金額計算同一個來源）
  insert into order_items(org_id, order_id, product_id, name, spec, revenue_type, qty, unit_price, line_total)
  select v_org, v_order_id, pr.id, pr.name, pr.spec, pr.revenue_type,
         (it2->>'qty')::int, pr.unit_price, (it2->>'qty')::int * pr.unit_price
    from jsonb_array_elements(p_items) it2
    join public.products pr on pr.id = nullif(it2->>'product_id','')::uuid
   where pr.org_id = v_org and pr.deleted_at is null;

  if v_pts > 0 then
    insert into wallet_txns(
      org_id, store_id, member_id, type, amount, status,
      counter_account, idempotency_key, ref_table, ref_id, staff_id, note
    ) values (
      v_org, p_store_id, p_member_id, 'spend', -v_pts, 'completed',
      'liability', p_idempotency_key || ':spend', 'orders', v_order_id, p_staff_id, '消費扣點 ' || v_order_no
    )
    returning id into v_txn;
    update wallets set balance = balance - v_pts where member_id = p_member_id;
    update orders set wallet_txn_id = v_txn where id = v_order_id;
  end if;

  if p_payments is not null then
    for pay in select * from jsonb_array_elements(p_payments) loop
      insert into order_payments(
        org_id, store_id, order_id, method, amount, cash_received, change_given, ref_no, staff_id
      ) values (
        v_org, p_store_id, v_order_id, pay->>'method', (pay->>'amount')::bigint,
        nullif(pay->>'cash_received','')::bigint, nullif(pay->>'change_given','')::bigint,
        nullif(pay->>'ref_no',''), p_staff_id
      );
    end loop;
  end if;

  if p_coupon_ids is not null and array_length(p_coupon_ids, 1) > 0 then
    update member_coupons
       set used_at = now(), used_order = v_order_id, used_txn_id = v_txn, status = 'used'
     where id = any(p_coupon_ids) and member_id = p_member_id;
  end if;

  return jsonb_build_object(
    'order_id', v_order_id, 'order_no', v_order_no,
    'subtotal', v_sub, 'non_discountable', v_nodisc,
    'coupon_discount', v_coupon_cut, 'tier', v_tier, 'tier_discount_pct', v_pct,
    'tier_discount', v_tier_cut, 'payable', v_payable,
    'points_used', v_pts, 'cash_due', v_cash_due, 'new_balance', v_bal - v_pts);
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

-- [7.0] claim_team_leader_tx
CREATE OR REPLACE FUNCTION public.claim_team_leader_tx(p_team_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_me   uuid := public.current_member_id();
  v_why  text;
  v_lead uuid;
  v_team text;
begin
  if v_me is null then
    return jsonb_build_object('ok', false, 'reason', 'not_logged_in', 'message', '請先登入');
  end if;

  v_why := public._team_claim_check(p_team_id, v_me);
  if v_why is not null then
    return jsonb_build_object('ok', false, 'reason', v_why, 'message', case v_why
      when 'not_member'     then '你不在這個團裡'
      when 'already_leader' then '你已經是團長了'
      when 'not_eligible'   then '要由團裡待最久的人接任'
      when 'leader_active'  then '團長還在活動中，不能接任'
      else '現在不能接任' end);
  end if;

  select tm.member_id into v_lead from public.team_members tm
   where tm.team_id = p_team_id and tm.role = 'leader' and tm.left_at is null;

  /* 🔴 先降級再升級。`uq_team_one_leader` 是不可延遲的部分唯一索引，
     一句 UPDATE 同時改兩列時 Postgres 不保證哪一列先寫。 */
  if v_lead is not null then
    update public.team_members set role = 'member'
     where team_id = p_team_id and member_id = v_lead and left_at is null;
  end if;
  update public.team_members set role = 'leader'
   where team_id = p_team_id and member_id = v_me and left_at is null;

  select t.name into v_team from public.teams t where t.id = p_team_id;
  return jsonb_build_object('ok', true, 'message', '你現在是 ' || v_team || ' 的團長了');
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
  -- 【身分 2026-09-29】從 API 進來的只有店員能叫（排程沒有 API 身分，照常）
  perform public._api_staff_only();
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

-- [7.0] clear_team_crest_tx
CREATE OR REPLACE FUNCTION public.clear_team_crest_tx(p_team_id uuid, p_member_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_old text;
begin
  if not public._is_team_leader(p_team_id, p_member_id) then
    return jsonb_build_object('ok', false, 'reason', 'not_leader', 'message', '只有團長可以換團徽');
  end if;

  select t.crest_path into v_old from public.teams t
   where t.id = p_team_id and t.deleted_at is null;

  /* 🔴 兩個欄位一起清才是「回到預設」。
     只清照片的話，設過圖示的團會退回那個圖示而不是預設團徽。
     🔴 2026-09-17：**source 也一起切回 default** —— 否則照片刪掉之後
       source 還停在 photo，下次一上傳就自動生效，繞過「套用」。
     ⚠ `crest_blocked` **不在這裡碰**：那是總部下架違規團徽用的旗標。 */
  update public.teams
     set crest_path = null, crest_emoji = null, crest_source = 'default', updated_at = now()
   where id = p_team_id and deleted_at is null;

  /* 回傳舊路徑讓 Edge Function 去刪 storage 的檔案 ——
     路徑由這裡給，不採信呼叫端送的。 */
  return jsonb_build_object('ok', true, 'path', v_old);
end $function$
;

-- [7.0] consume_snack_tx
CREATE OR REPLACE FUNCTION public.consume_snack_tx(p_org_id uuid, p_member_id uuid, p_kind text, p_qty integer DEFAULT 1, p_ref_id uuid DEFAULT NULL::uuid, p_idem_key text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_me    uuid;
  v_have  int;
  v_key   text;
  v_id    uuid;
  v_total int;
begin
  /* 🔴 身分從 JWT 取，不採信呼叫端（待辦 14 的通則）。
     ⚠ 這一支給前端叫得到，所以這道牆比發放那支更重要 ——
       沒有它就是「給我一個 member_id 就扣光他的點心」。 */
  v_me := public.current_member_id();
  if v_me is null then raise exception '未登入或登入已過期，請重新開啟 App' using errcode = '28000'; end if;
  if v_me is null then
    return jsonb_build_object('ok', false, 'reason', 'not_logged_in', 'message', '請先登入');
  end if;
  if p_kind is null or coalesce(p_qty, 0) <= 0 then
    return jsonb_build_object('ok', false, 'reason', 'bad_args');
  end if;

  /* 餘額是**帳本算出來的**，不是讀 `bear.snacks`
     —— 那一欄從今天起是顯示值，不是來源。 */
  select coalesce(sum(qty), 0) into v_have
    from snack_grants where member_id = v_me and kind = p_kind;

  if v_have < p_qty then
    return jsonb_build_object('ok', false, 'reason', 'insufficient',
      'message', '點心不夠', 'total', v_have);
  end if;

  /* 冪等鍵：呼叫端沒給就自己產一把。
     ⚠ 餵食是**刻意重複**的動作（連餵三個），所以預設不是「同一把鑰匙」；
       但網路重試時前端可以送同一把，避免扣兩次。 */
  v_key := coalesce(p_idem_key, 'feed:' || v_me::text || ':' || gen_random_uuid()::text);

  insert into snack_grants (org_id, member_id, kind, qty, reason, ref_id, idem_key)
  values (p_org_id, v_me, p_kind, -p_qty, 'feed', p_ref_id, v_key)
  on conflict (idem_key) do nothing
  returning id into v_id;

  if v_id is null then
    select coalesce(sum(qty), 0) into v_total from snack_grants where member_id = v_me and kind = p_kind;
    return jsonb_build_object('ok', true, 'spent', false, 'reason', 'already_spent', 'total', v_total);
  end if;

  update member_app_state set
    bear = jsonb_set(coalesce(bear, '{}'::jsonb), array['snacks', p_kind],
             to_jsonb(greatest(0, coalesce((bear -> 'snacks' ->> p_kind)::int, 0) - p_qty)), true),
    updated_at = now()
   where member_id = v_me;

  select coalesce(sum(qty), 0) into v_total from snack_grants where member_id = v_me and kind = p_kind;
  return jsonb_build_object('ok', true, 'spent', true, 'kind', p_kind, 'qty', p_qty, 'total', v_total);
end $function$
;

-- [7.0] create_booking_tx
CREATE OR REPLACE FUNCTION public.create_booking_tx(p_store_id uuid, p_play_at timestamp with time zone, p_hours integer, p_table_count integer DEFAULT 1, p_team_id uuid DEFAULT NULL::uuid, p_party_size integer DEFAULT NULL::integer, p_note text DEFAULT NULL::text, p_game_type text DEFAULT NULL::text, p_flower text DEFAULT NULL::text, p_stake_level_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_me    uuid := public.current_member_id();
  v_org   uuid := public.current_org_id();
  v_cap   jsonb;
  v_id    uuid;
  v_name  text;
  v_tbl   uuid;
  v_label text;
begin
  if v_me is null or v_org is null then
    return jsonb_build_object('ok', false, 'reason', 'not_logged_in', 'message', '請先登入');
  end if;
  if p_hours not in (2, 5) then
    return jsonb_build_object('ok', false, 'reason', 'bad_hours', 'message', '時長只能選 2 或 5 小時（要打更久，當天在櫃檯加時間或升級當日暢打）');
  end if;
  if coalesce(p_table_count, 1) < 1 or p_table_count > 10 then
    return jsonb_build_object('ok', false, 'reason', 'bad_count', 'message', '桌數請填 1 到 10');
  end if;
  /* ⚠ 兩個新值照 `match_queues` 的允許值擋，訊息講人話不講欄位名。 */
  if p_game_type is not null and p_game_type not in ('台麻', '美麻') then
    return jsonb_build_object('ok', false, 'reason', 'bad_game_type', 'message', '牌規只能選台麻或美麻');
  end if;
  if p_flower is not null and p_flower not in ('無花', '有花') then
    return jsonb_build_object('ok', false, 'reason', 'bad_flower', 'message', '花牌只能選無花或有花');
  end if;

  /* 🔴 兩道時間牆，兩個不同的理由：
     · 太近 —— 店員來不及看到那筆預約，客人到了櫃檯還是要現場處理，
       而畫面已經跟他說「預約成功」了。**那是一個做不到的承諾。**
     · 太遠 —— 三個月後的事誰都說不準，而它會一路佔著容量。 */
  if p_play_at is null or p_play_at < now() + interval '30 minutes' then
    return jsonb_build_object('ok', false, 'reason', 'too_soon',
                              'message', '請至少提前 30 分鐘預約，現在要用請直接到櫃檯');
  end if;
  if p_play_at > now() + interval '90 days' then
    return jsonb_build_object('ok', false, 'reason', 'too_far', 'message', '最多只能預約 90 天內');
  end if;

  select s.name into v_name from public.stores s
   where s.id = p_store_id and s.org_id = v_org and s.deleted_at is null;
  if v_name is null then
    return jsonb_build_object('ok', false, 'reason', 'bad_store', 'message', '找不到那間門市');
  end if;

  /* 🔴 **2026-09-17：條件對齊 `list_stakes_tx`（選單是那一支給的）。**
     舊版只認 `store_id = p_store_id`，而那一支**同時放行全連鎖的級距**
     （`store_id is null`）—— 線上七個級距全都是那一種
     ⇒ 選單上每一個都必定被擋，包桌整個訂不出來。

     ⚠ 這道牆本身是對的、要留著：它擋的是「換了門市卻沒重選級距」。
       錯的是它沒有照抄選項的定義。
     🎯 **判準一句話：擋牆要跟「這個選項是怎麼來的」用同一個條件。**
       兩邊各寫一份，寫下去的當下就是兩份。

     ✅ 順帶補 `org_id` —— 舊版完全沒驗，
       拿另一個 org 的級距 id 送進來會通過。今天只有一個 org
       所以踩不到，那是運氣不是設計。
     ⚠ 也補上 `is_active` 與 `deleted_at` —— 同樣是照抄那一支：
       停用的級距不該出現在選單上，也不該訂得出來。 */
  if p_stake_level_id is not null and not exists (
       select 1 from public.stake_levels sl
        where sl.id = p_stake_level_id
          and sl.org_id = v_org
          and sl.is_active = true
          and sl.deleted_at is null
          and (sl.store_id = p_store_id or sl.store_id is null)) then
    return jsonb_build_object('ok', false, 'reason', 'bad_stake',
                              'message', '那個積分級距不能用在這間門市');
  end if;

  /* 掛團的話，**我必須在那個團裡** —— 不然任何人都能用別人的團名訂位，
     而帳算在那個團頭上。 */
  if p_team_id is not null and not exists (
       select 1 from public.team_members tm
        join public.teams t on t.id = tm.team_id and t.deleted_at is null
       where tm.team_id = p_team_id and tm.member_id = v_me and tm.left_at is null) then
    return jsonb_build_object('ok', false, 'reason', 'not_member', 'message', '你不在那個牌咖團裡');
  end if;

  perform public._booking_expire(p_store_id);

  /* 🔴 同一組人同一個時段不要重複訂。
     判準是「同一個團」，沒有團就退回「同一個人」——
     而那正是 `team_id` 可空所帶來的兩種身分。 */
  if exists (
       select 1 from public.bookings k
        where k.store_id = p_store_id and k.status = 'booked'
          and (case when p_team_id is not null then k.team_id = p_team_id
                    else k.team_id is null and k.member_id = v_me end)
          and p_play_at < k.play_at + make_interval(hours => k.planned_hours)
          and k.play_at < p_play_at + make_interval(hours => p_hours)) then
    return jsonb_build_object('ok', false, 'reason', 'already_booked',
                              'message', '這個時段你已經有一筆預約了');
  end if;

  v_cap := public._booking_capacity(p_store_id, p_play_at, p_hours);
  if (v_cap->>'free')::int < p_table_count then
    return jsonb_build_object('ok', false, 'reason', 'no_capacity',
                              'message', '這個時段已經約滿了，換個時間試試');
  end if;

  /* 🔴 **訂的當下就配桌**（使用者 2026-09-16）。
     ⚠ 只有一桌才配 —— `bookings` 只有一個 `table_id` 欄位（見檔頭）。
     ⚠ 容量剛才已經確認夠了，所以正常情況一定挑得到；
       挑不到只會發生在「那一瞬間被別人拿走」，那時**不要失敗**，
       留 null 就好 —— 客人的預約仍然成立，桌號當天再安排。
       🎯 為了一個顯示用的欄位讓整筆預約失敗，是把次要的事當成主要的。 */
  if coalesce(p_table_count, 1) = 1 then
    v_tbl := public._booking_pick_table(p_store_id, p_play_at, p_hours);
  end if;

  insert into public.bookings (org_id, store_id, team_id, member_id,
                               play_at, planned_hours, table_count, party_size, note,
                               table_id, game_type, flower, stake_level_id)
  values (v_org, p_store_id, p_team_id, v_me,
          p_play_at, p_hours, coalesce(p_table_count, 1), p_party_size,
          nullif(btrim(coalesce(p_note, '')), ''),
          v_tbl, p_game_type, p_flower, p_stake_level_id)
  returning id into v_id;

  select tb.label into v_label from public.tables tb where tb.id = v_tbl;

  return jsonb_build_object('ok', true, 'booking_id', v_id, 'store_name', v_name,
                            'table_label', v_label,
                            'message', '已預約 ' || v_name);
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
  -- 【身分 2026-09-29】只認登入的本人，前端送的 id 一律忽略
  p_opener := public.current_member_id();
  if p_opener is null then raise exception '未登入或登入已過期，請重新開啟 App' using errcode = '28000'; end if;
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

-- [7.0] create_team_invite_link_tx
CREATE OR REPLACE FUNCTION public.create_team_invite_link_tx(p_team_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_me    uuid := public.current_member_id();
  v_org   uuid := public.current_org_id();
  v_team  record;
  v_open  int;
  v_token text;
  v_exp   timestamptz;
begin
  if v_me is null or v_org is null then
    return jsonb_build_object('ok', false, 'reason', 'not_logged_in', 'message', '請先登入');
  end if;
  select t.id, t.name into v_team from public.teams t
   where t.id = p_team_id and t.org_id = v_org and t.deleted_at is null;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'not_found', 'message', '找不到這個牌咖團');
  end if;
  -- 與 invite_to_team_tx 同一個判準：團長或副團長
  if not exists (select 1 from public.team_members tm
                  where tm.team_id = p_team_id and tm.member_id = v_me and tm.left_at is null
                    and tm.role in ('leader', 'co_leader')) then
    return jsonb_build_object('ok', false, 'reason', 'not_leader', 'message', '只有團長或副團長可以邀請');
  end if;
  select count(*) into v_open from public.team_invite_links l
   where l.team_id = p_team_id and l.used_at is null and l.expires_at > now();
  if v_open >= 20 then
    return jsonb_build_object('ok', false, 'reason', 'too_many_links',
      'message', '這個團還有很多條沒用掉的邀請連結，等朋友點完再發新的');
  end if;

  v_token := replace(gen_random_uuid()::text, '-', '');   -- 32 個 16 進位字元，122 位元隨機
  insert into public.team_invite_links (org_id, team_id, token, created_by)
  values (v_org, p_team_id, v_token, v_me)
  returning expires_at into v_exp;

  return jsonb_build_object('ok', true, 'token', v_token, 'expires_at', v_exp, 'team_name', v_team.name);
end $function$
;

-- [7.0] create_team_tx
CREATE OR REPLACE FUNCTION public.create_team_tx(p_name text, p_crest_emoji text DEFAULT NULL::text, p_intro text DEFAULT NULL::text, p_join_policy text DEFAULT 'approval'::text, p_home_store_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_me   uuid := public.current_member_id();
  v_org  uuid := public.current_org_id();
  v_name text := btrim(coalesce(p_name, ''));
  v_lead int;
  v_join int;
  v_id   uuid;
begin
  if v_me is null or v_org is null then
    return jsonb_build_object('ok', false, 'reason', 'not_logged_in', 'message', '請先登入');
  end if;

  if char_length(v_name) < 2 or char_length(v_name) > 20 then
    return jsonb_build_object('ok', false, 'reason', 'bad_name', 'message', '團名請取 2 到 20 個字');
  end if;
  if coalesce(p_join_policy, 'approval') not in ('open', 'approval', 'closed') then
    return jsonb_build_object('ok', false, 'reason', 'bad_policy', 'message', '加入方式不正確');
  end if;
  if p_home_store_id is not null and not exists (
       select 1 from public.stores s
        where s.id = p_home_store_id and s.org_id = v_org and s.deleted_at is null) then
    return jsonb_build_object('ok', false, 'reason', 'bad_store', 'message', '找不到那間門市');
  end if;

  /* 兩道護欄，都不是產品規則是防洗版。
     ⚠ 數字放在這裡而不是設定表 —— 今天沒有人要調它，
       建一張設定表就是第 N 個「建了沒人讀」。 */
  select count(*) into v_lead from public.team_members tm
    join public.teams t on t.id = tm.team_id and t.deleted_at is null
   where tm.member_id = v_me and tm.left_at is null and tm.role = 'leader';
  if v_lead >= 3 then
    return jsonb_build_object('ok', false, 'reason', 'too_many_leading',
                              'message', '你已經是 3 個牌咖團的團長了');
  end if;

  select count(*) into v_join from public.team_members tm
    join public.teams t on t.id = tm.team_id and t.deleted_at is null
   where tm.member_id = v_me and tm.left_at is null;
  if v_join >= 10 then
    return jsonb_build_object('ok', false, 'reason', 'too_many_teams',
                              'message', '你已經加入 10 個牌咖團了');
  end if;

  begin
    insert into public.teams (org_id, name, crest_emoji, intro, join_policy,
                              home_store_id, created_by)
    values (v_org, v_name, nullif(btrim(coalesce(p_crest_emoji, '')), ''),
            nullif(btrim(coalesce(p_intro, '')), ''),
            coalesce(p_join_policy, 'approval'), p_home_store_id, v_me)
    returning id into v_id;
  exception when unique_violation then
    /* 🔴 這一格靠 `uq_teams_name` 擋，不是靠先查一次再插入 ——
       先查再插有競態，兩個人同時建同名團會兩個都成功。 */
    return jsonb_build_object('ok', false, 'reason', 'name_taken',
                              'message', '已經有人用這個團名了，換一個吧');
  end;

  insert into public.team_members (org_id, team_id, member_id, role)
  values (v_org, v_id, v_me, 'leader');

  return jsonb_build_object('ok', true, 'team', public._team_card(v_id), 'my_role', 'leader');
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
     ⚠ 這裡有 `limit 1` ⇒ 重複時**不會報錯，會靜默選錯**。
     🆕 2026-09-25：**隱藏中的會員認不出來** ⇒ 所有會員端 RPC 都擋住他，
       就算他手上還有一張沒過期的 session。POS 用會員 id 結帳，不受影響。 */
  select m.id from members m
   where m.line_user_id = public.migi_jwt_line_id()
     and m.deleted_at is null
     and m.hidden_at is null
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

-- [7.0] disband_team_tx
CREATE OR REPLACE FUNCTION public.disband_team_tx(p_team_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  /* 🔴 不再問「你是不是團長」，改問「你是不是總部」。
     ⚠ 也不再要求 `current_member_id()` 有值 —— 總部那個帳號沒有會員身分，
       留著那道檢查會讓它在權限通過之後才被擋，訊息還是「請先登入」。 */
  if not public.can('team.disband') then
    return jsonb_build_object('ok', false, 'reason', 'forbidden',
                              'message', '只有總部可以解散牌咖團');
  end if;

  return public._team_disband(p_team_id, public.current_member_id());
end $function$
;

-- [7.0] fire_event_tx
CREATE OR REPLACE FUNCTION public.fire_event_tx(p_member uuid, p_event text, p_delta bigint DEFAULT 1, p_period_key text DEFAULT NULL::text, p_idem text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  r record; v_res jsonb := '[]'::jsonb; v_one jsonb; v_idem text; v_org uuid;
  v_meta jsonb;
begin
  select org_id into v_org from members where id = p_member and deleted_at is null;
  if v_org is null then return jsonb_build_object('ok', false, 'reason', 'member_not_found'); end if;

  for r in
    select code, struct, requires_code
      from achievements
     where org_id = v_org
       and deleted_at is null
       and is_active
       and (trigger->>'event') = p_event
       -- 🔴 2026-09-20 加的守衛，而它不是優化是前提：
       --   meta 的 struct 也是 specific／prestige，少了這一行，
       --   一次 'achievement_unlocked' 事件會把 27 枚 meta **無條件全開**
       --   （ach_unlock_tx 根本不看門檻），而且不會報錯。
       --   帶門檻的那一類一律走 ach_meta_tx，不走這個泛用分流。
       and not (trigger ? 'count')
       and (valid_from is null or now() >= valid_from)
       and (valid_to   is null or now() <  valid_to)
     order by sort, code
  loop
    -- 前置依賴：沒解鎖前置就跳過（系列成就不會跳級）
    if r.requires_code is not null then
      if not exists (
        select 1 from member_achievements ma
          join achievements a2 on a2.id = ma.achievement_id
         where ma.member_id = p_member
           and a2.code = r.requires_code
           and ma.status = 'unlocked')
      then continue; end if;
    end if;

    -- 每個成就各自一把冪等鍵：同一個來源事件不會把同一枚重複計
    v_idem := coalesce(p_idem, 'evt') || ':' || p_event || ':' || r.code;

    if r.struct in ('specific','prestige') then
      v_one := public.ach_unlock_tx(p_member, r.code, v_idem);
    elsif r.struct = 'cumulative' then
      v_one := public.ach_progress_tx(p_member, r.code, p_delta, v_idem);
    elsif r.struct = 'streak' then
      if p_period_key is null then
        v_one := jsonb_build_object('ok', false, 'reason', 'period_key_required');
      else
        v_one := public.ach_streak_tx(p_member, r.code, p_period_key, true, v_idem);
      end if;
    else
      continue;
    end if;

    v_res := v_res || jsonb_build_array(
      jsonb_build_object('code', r.code, 'struct', r.struct, 'result', v_one));
  end loop;

  -- 🎯 收尾對一次帳。放這裡而不是要每個發射端自己叫，理由是
  --   **發射端不該知道 meta 存在** —— 那 12 支裡有一半是金流函式。
  -- ✅ 不會遞迴：meta 不計入 meta（見 ach_meta_tx 的註解），
  --   所以解鎖一枚 meta 不可能改變任何計數，一趟就夠。
  v_meta := public.ach_meta_tx(p_member, coalesce(p_idem, 'evt') || ':' || p_event);

  return jsonb_build_object('ok', true, 'event', p_event,
                            'matched', v_res, 'meta', v_meta);
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

-- [7.0] get_game_tx
CREATE OR REPLACE FUNCTION public.get_game_tx(p_org_id uuid, p_session_id uuid, p_member_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_me  uuid;
  v_row jsonb;
begin
  /* JWT 優先、參數退回 —— 與其他 22 支會員 RPC 同一個寫法。
     ⏳ 待辦 14 收尾時三個地方一起拿掉退回，不要只改這裡。 */
  v_me := public.current_member_id();
  if v_me is null then raise exception '未登入或登入已過期，請重新開啟 App' using errcode = '28000'; end if;
  if v_me is null then
    return jsonb_build_object('ok', false, 'reason', 'not_logged_in', 'message', '請先登入');
  end if;

  v_row := public._game_row(p_org_id, p_session_id, v_me);

  if v_row is null then
    /* ⚠ 「不存在」與「不是你的」**回同一句話**：分開講等於告訴對方
       「這個 id 存在，只是不給你看」，那本身就是資訊。 */
    return jsonb_build_object('ok', false, 'reason', 'not_found', 'message', '找不到這場牌局');
  end if;

  return jsonb_build_object('ok', true, 'game', v_row);
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

  /* 🆕 2026-09-25：隱藏中 ⇒ 只回「找到了、但被隱藏」，其他什麼都不給。
     ⚠ 一定要是 found:true —— 回 found:false 的話 App 會把他丟進註冊，
       而註冊會用同一個 LINE 找回這個帳號，繞一圈又回到這裡。 */
  if v_m.hidden_at is not null then
    return jsonb_build_object('found', true, 'hidden', true, 'member_id', v_m.id);
  end if;

  return jsonb_build_object(
    'found', true,
    'hidden', false,
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

-- [7.0] get_member_card_tx
CREATE OR REPLACE FUNCTION public.get_member_card_tx(p_target uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_me    uuid := public.current_member_id();
  v_org   uuid;
  t       members%rowtype;
  v_rel   text;
  v_pair  jsonb;
  v_stats jsonb;
  v_core  jsonb;
  v_out   jsonb;
begin
  if v_me is null then raise exception '未登入或登入已過期，請重新開啟 App' using errcode = '28000'; end if;
  select org_id into v_org from members where id = v_me;

  select * into t from members where id = p_target and org_id = v_org and deleted_at is null;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'not_found', 'message', '找不到這位會員');
  end if;
  -- 任一方封鎖了另一方 ⇒ 看不到（不說是誰封鎖誰）
  if v_me <> p_target and public._blocked_between(v_org, v_me, p_target) then
    return jsonb_build_object('ok', false, 'reason', 'blocked', 'message', '看不到這位會員的資料');
  end if;

  v_rel := case
    when v_me = p_target then 'self'
    when t.hidden_at is not null then 'hidden'
    when exists (select 1 from mahjong_buddies b
                  where b.org_id = v_org and b.deleted_at is null
                    and ((b.member_id = v_me and b.buddy_id = p_target)
                      or (b.member_id = p_target and b.buddy_id = v_me))) then 'buddy'
    when exists (select 1 from team_members a
                   join team_members b on b.team_id = a.team_id
                   join teams tm on tm.id = a.team_id and tm.deleted_at is null
                  where a.member_id = v_me and b.member_id = p_target
                    and a.left_at is null and b.left_at is null) then 'team'
    else 'none' end;

  /* 公開的部分：所有人都看得到。
     ⚠ 隱藏中的會員，這些欄位本來就已經被換成問號（member_hidden 保險箱），這裡不必再判斷。 */
  v_out := jsonb_build_object(
    'ok', true, 'id', t.id, 'rel', v_rel,
    'name', t.display_name, 'title', t.title, 'rank', t.rank, 'likes', t.likes_count,
    'about', t.about,
    'avatar_source', t.avatar_source, 'avatar_bear', t.avatar_bear,
    'avatar_url', t.avatar_url, 'avatar_photo_path', t.avatar_photo_path,
    'locked', v_rel not in ('self', 'buddy', 'team'));

  if v_rel = 'none' then
    /* 🔴 只回「能不能邀」，不回同桌次數 —— 同桌次數本身是限牌咖的資料。
       規則照舊：同桌對局過才能加牌咖。 */
    v_out := v_out || jsonb_build_object('can_invite',
      exists (select 1 from session_players me
                join session_players op on op.session_id = me.session_id and op.member_id = p_target
                join table_sessions s   on s.id = me.session_id and s.deleted_at is null and s.status = 'completed'
               where me.member_id = v_me and me.org_id = v_org));
    return v_out;
  end if;
  if v_rel = 'hidden' then
    return v_out || jsonb_build_object('can_invite', false);
  end if;

  -- ── 以下只有本人、牌咖、同團成員拿得到 ──
  v_pair := public._pair_history(v_org, v_me, p_target);

  if t.see_score = '只有自己' and v_rel <> 'self' then
    v_stats := jsonb_build_object('private', true);
  else
    v_core := public._member_stats_core(v_org, p_target);
    /* 只拿個人卡要畫的幾格（本季）。min_games 一起給：未達門檻時前端顯示「—」，
       同成績頁的規則（「100% · 2 場」是誤導）。 */
    v_stats := jsonb_build_object(
      'private',    false,
      'min_games',  v_core -> 'min_games',
      'games',      v_core -> 'season' -> 'games',
      'avg_rank',   v_core -> 'season' -> 'avg_rank',
      'scored',     v_core -> 'season' -> 'scored',
      'wins',       v_core -> 'season' -> 'wins',
      'best_score', v_core -> 'season' -> 'best_score');
  end if;

  return v_out || jsonb_build_object(
    'can_invite', false,
    'style',      t.style,
    'sched',      t.sched,
    'baby_tile',  t.baby_tile,
    'together',   v_pair,
    'stats',      v_stats,
    /* 最近亮點（最大台的一手）要等電子計分的每一局資料（hands），接上之前一律 null。 */
    'highlight',  null);
end $function$
;

-- [7.0] get_my_achievements_tx
CREATE OR REPLACE FUNCTION public.get_my_achievements_tx()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_member uuid;
  v_org    uuid;
  v_rows   jsonb;
  v_total  int;
  v_done   int;
begin
  v_member := public.current_member_id();
  if v_member is null then
    raise exception '未登入，無法讀取成就' using errcode = '28000';
  end if;

  select org_id into v_org from members where id = v_member and deleted_at is null;
  if v_org is null then
    raise exception '會員不存在' using errcode = '28000';
  end if;

  select coalesce(jsonb_agg(x order by x.ord, x.code), '[]'::jsonb),
         count(*)::int,
         count(*) filter (where x.status = 'unlocked')::int
    into v_rows, v_total, v_done
  from (
    select
      a.code,
      case when a.visibility = 'silhouette'
                and coalesce(ma.status, 'locked') <> 'unlocked'
           then '？？？' else a.name end                          as name,
      case when a.visibility = 'silhouette'
                and coalesce(ma.status, 'locked') <> 'unlocked'
           then null else a.description end                       as description,
      case when a.visibility = 'silhouette'
                and coalesce(ma.status, 'locked') <> 'unlocked'
           then null else a.condition_text end                    as condition_text,
      a.ui_category                                               as category,
      a.rarity,
      a.group_key,
      a.is_signature                                              as signature,
      case when a.visibility = 'silhouette'
                and coalesce(ma.status, 'locked') <> 'unlocked'
           then null else a.grants_title end                      as grants_title,
      (a.visibility = 'silhouette'
        and coalesce(ma.status, 'locked') <> 'unlocked')          as masked,
      /* 徽章圖。遮蔽的成就照樣回傳 —— 前端本來就把未解鎖的圖畫成灰階剪影，
         行為與搬家前（圖寫死在前端）完全相同。 */
      a.badge_path                                                as badge_path,
      coalesce(ma.status, 'locked')                               as status,
      /* 🎯 **進度的分子**，兩種來源（不同機制）：
           cumulative  `ach_progress_tx` 一路累加，值就在 member_achievements
           meta        沒有人累加 ⇒ 當下數一次，與 ach_meta_tx 同一支函式 */
      case when a.trigger ? 'count'
           then coalesce(public.ach_meta_count_tx(
                  v_member, a.trigger->>'scope', a.trigger->>'value'), 0)
           else coalesce(ma.current_value, 0) end                 as current_value,
      /* 🔴 **分母也有兩種來源，而這是 2026-09-20 補的**：
           meta        `trigger->>'count'`
           cumulative  `achievement_tiers` 的最大 threshold（ach_progress_tx 讀的就是它）
         ⚠ 少了第二條，累積型成就的 target 是 null ⇒ **進度條畫不出來而且不報錯**。
           今天踩不到只是因為在此之前一枚 cumulative 都沒有。 */
      coalesce(
        case when a.trigger ? 'count' then (a.trigger->>'count')::int end,
        (select max(t.threshold)::int from achievement_tiers t
          where t.achievement_id = a.id)
      )                                                           as target,
      coalesce(ma.pinned, false)                                  as pinned,
      ma.unlocked_at,
      a.sort                                                      as ord
      from achievements a
      left join member_achievements ma
             on ma.achievement_id = a.id and ma.member_id = v_member
     where a.org_id = v_org
       and a.deleted_at is null
       and a.is_active
       and (a.valid_from is null or now() >= a.valid_from)
       and (a.valid_to   is null or now() <  a.valid_to)
       and not (a.visibility = 'hidden'
                and coalesce(ma.status, 'locked') <> 'unlocked')
  ) x;

  return jsonb_build_object(
    'ok', true,
    'total', v_total,
    'unlocked', v_done,
    'achievements', v_rows
  );
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
  -- 【身分 2026-09-29】只認登入的本人，前端送的 id 一律忽略
  p_member := public.current_member_id();
  if p_member is null then raise exception '未登入或登入已過期，請重新開啟 App' using errcode = '28000'; end if;
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
  p_member_id := public.current_member_id();
  if p_member_id is null then raise exception '未登入或登入已過期，請重新開啟 App' using errcode = '28000'; end if;
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
  if v_me is null then
    raise exception '未登入或登入已過期，請重新開啟 App' using errcode = '28000';
  end if;

  return (
    select jsonb_build_object(
             'ok', true,
             'avatar_source',     m.avatar_source,
             'avatar_photo_path', m.avatar_photo_path,
             'avatar_bear',       m.avatar_bear,
             'avatar_url',        m.avatar_url,
             'avatar_blocked',    m.avatar_blocked,
             'rank',              m.rank,
             /* 解鎖了哪幾隻段位熊（含雀神熊），前端的圖鑑與選頭像抽屜都讀這一份 */
             'unlocked_bears',    to_jsonb(public._member_bear_unlocks(m.id)))
      from members m
     where m.id = v_me and m.deleted_at is null
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
  /* 只認登入身分（2026-10-02）：沒登入就拒絕，前端傳的會員 id 一律忽略 */
  if v_me is null then
    raise exception '未登入或登入已過期，請重新開啟 App' using errcode = '28000';
  end if;
  p_member_id := v_me;

  return (
    with mine as (
      -- 從「我坐過的位子」反查場次 —— 不需要知道那桌是怎麼開的。
      select s.id, coalesce(s.ended_at, sp.settled_at) as ended_at
        from session_players sp
        join table_sessions s on s.id = sp.session_id
       where sp.member_id = p_member_id
         and sp.org_id    = p_org_id
         and s.org_id     = p_org_id
         and s.deleted_at is null
         -- 已收桌，或成績已經算好（打完最後一將就自動結算，不等店員收桌，2026-10-02）
         and (s.status = 'completed' or sp.finish_rank is not null)
       order by coalesce(s.ended_at, sp.settled_at) desc nulls last
       limit greatest(coalesce(p_limit, 20), 1)
    )
    select coalesce(
      jsonb_agg(public._game_row(p_org_id, m.id, p_member_id) order by m.ended_at desc nulls last),
      '[]'::jsonb)
    from mine m
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
  p_member_id := public.current_member_id();
  if p_member_id is null then raise exception '未登入或登入已過期，請重新開啟 App' using errcode = '28000'; end if;
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
    'titles_unlocked', (select coalesce(jsonb_agg(t.title order by t.got_at nulls last), '[]'::jsonb) from public._member_titles(m.id) t),
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
  p_member_id := public.current_member_id();
  if p_member_id is null then raise exception '未登入或登入已過期，請重新開啟 App' using errcode = '28000'; end if;
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
begin
  /* 🔴 身分一律從 JWT 取，不採信呼叫端（待辦 14）。前端照樣送 p_member_id，這裡忽略。
     算法在 _member_stats_core（2026-09-30 抽出，他人個人卡也叫同一支）。 */
  p_member_id := public.current_member_id();
  if p_member_id is null then raise exception '未登入或登入已過期，請重新開啟 App' using errcode = '28000'; end if;
  return public._member_stats_core(p_org_id, p_member_id);
end $function$
;

-- [7.0] get_my_titles_tx
CREATE OR REPLACE FUNCTION public.get_my_titles_tx()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_me uuid; v_org uuid; v_owned jsonb; v_locked jsonb; v_wear text;
begin
  v_me := public.current_member_id();
  if v_me is null then raise exception '未登入或登入已過期，請重新開啟 App' using errcode = '28000'; end if;
  select org_id, title into v_org, v_wear from members where id = v_me and deleted_at is null;

  select coalesce(jsonb_agg(jsonb_build_object('title', t.title, 'source', t.source, 'got_at', t.got_at)
                            order by (t.title = '新手上路') desc, t.got_at nulls last), '[]'::jsonb)
    into v_owned from public._member_titles(v_me) t;

  /* 還沒拿到的：只列**看得到**的成就。
     ⚠ silhouette 的成就不列 —— 列出稱號等於把隱藏條件講出來。 */
  select coalesce(jsonb_agg(jsonb_build_object('title', a.grants_title, 'achievement', a.name,
                                               'condition', a.condition_text)
                            order by a.sort, a.code), '[]'::jsonb)
    into v_locked
    from achievements a
   where a.org_id = v_org and a.deleted_at is null and a.is_active
     and a.grants_title is not null and btrim(a.grants_title) <> ''
     and a.visibility = 'visible'
     and not exists (select 1 from public._member_titles(v_me) t where t.title = a.grants_title);

  return jsonb_build_object('equipped', coalesce(v_wear, '新手上路'), 'owned', v_owned, 'locked', v_locked);
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
  /* 上限保護：前端送 100000 的話這支會把整個榜撈出來。least 而不是 raise。 */
  v_n := greatest(1, least(coalesce(p_limit, 10), 100));

  v_season := public.current_season_tx(p_org_id);

  /* 沒有進行中的賽季時不要回 ok:false —— 那是正常狀態（兩季之間的空檔）。 */
  if v_season is null then
    return jsonb_build_object('ok', true, 'season', null,
                              'rows', '[]'::jsonb, 'champions', '[]'::jsonb);
  end if;

  /* 本季排行。名次借 season_rank_rows_display_tx（與成績頁的「全國排名」同一份定義）。
     🔴 2026-09-30 加回 id：點進去的個人卡要靠它判斷「你們是不是牌咖」。
       2026-09-04 拿掉它的理由（拿 id 就能看別人錢包）09-20 已經不成立 ——
       所有會員功能只認 JWT，前端送誰的 id 都沒用。 */
  select coalesce(jsonb_agg(x order by x.rank_no), '[]'::jsonb) into v_rows
    from (
      select r.rank_no, r.rating, r.games,
             r.member_id           as id,
             m.display_name        as name,
             public.rank_from_rating(r.rating) as rank_label
        from public.season_rank_rows_display_tx(
               p_org_id, (v_season ->> 'starts_at')::timestamptz, null) r
        join members m on m.id = r.member_id
       order by r.rank_no
       limit v_n
    ) x;

  /* 名人堂：歷代雀神熊。再擋一次測試帳號與隱藏中的會員（冠軍紀錄保留，恢復之後回來）。 */
  select coalesce(jsonb_agg(x order by x.awarded_at desc), '[]'::jsonb) into v_champ
    from (
      select c.season, c.rating, c.awarded_at,
             c.member_id           as id,
             s.label               as season_label,
             m.display_name        as name,
             public.rank_from_rating(c.rating) as rank_label
        from season_champions c
        join members m on m.id = c.member_id
                      and m.deleted_at is null
                      and m.hidden_at is null
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
  -- 【身分 2026-09-29】從 API 進來的只有店員能叫（排程沒有 API 身分，照常）
  perform public._api_staff_only();
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
  -- 【身分 2026-09-29】從 API 進來的只有店員能叫（排程沒有 API 身分，照常）
  perform public._api_staff_only();
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

-- [7.0] get_team_tx
CREATE OR REPLACE FUNCTION public.get_team_tx(p_team_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_me      uuid := public.current_member_id();
  v_card    jsonb;
  v_role    text;
  v_from    timestamptz;
  v_members jsonb;
  v_pending int := 0;
begin
  if v_me is null then
    return jsonb_build_object('ok', false, 'reason', 'not_logged_in', 'message', '請先登入');
  end if;

  v_card := public._team_card(p_team_id);
  if v_card is null then
    return jsonb_build_object('ok', false, 'reason', 'not_found', 'message', '找不到這個牌咖團');
  end if;

  select tm.role into v_role
    from public.team_members tm
   where tm.team_id = p_team_id and tm.member_id = v_me and tm.left_at is null;

  if v_role is null then
    return jsonb_build_object('ok', true, 'team', v_card, 'my_role', null,
                              'members', '[]'::jsonb, 'can_claim_leader', false);
  end if;

  v_from := (date_trunc('month', (now() at time zone 'Asia/Taipei')) at time zone 'Asia/Taipei');

  /* 🔴 排序用**明寫的名次**不用字串序。
     `'co_leader' < 'leader' < 'member'` ⇒ 字串序會把副團長排到團長上面，
     而在這之前它「看起來是對的」只是因為 leader 剛好排在 member 前面。 */
  select coalesce(jsonb_agg(x order by (x->>'role_sort')::int, x->>'joined_at'), '[]'::jsonb)
    into v_members
    from (
      select jsonb_build_object(
               /* 🔴 只有團長拿得到 member_id —— 不需要身分就不要交出身分
                  （2026-09-04 排行榜定的原則）。只有他要按移除與轉讓。 */
               'member_id', case when v_role = 'leader' then tm.member_id else null end,
               'is_me',     tm.member_id = v_me,
               'nickname',  m.display_name,
               'rank',      m.rank,
               'title',     m.title,
               'role',      tm.role,
               'role_sort', case tm.role when 'leader' then 0 when 'co_leader' then 1 else 2 end,
               'joined_at', tm.joined_at,
               /* 🔴 名冊**不給「上次來店」** —— 手遊公會名冊都有那一欄，
                  但 2026-08-26 為常來時段畫的線擋著：對別人的單向側寫
                  不給客人看。本月貢獻是**共同事實**，所以可以。 */
               'month_contrib', (
                 select count(*) from public._team_session_ids(p_team_id) ts
                  where ts.played_at >= v_from
                    and exists (select 1 from public.session_players sp
                                 where sp.session_id = ts.session_id
                                   and sp.member_id = tm.member_id))) as x
        from public.team_members tm
        join public.members m on m.id = tm.member_id
       where tm.team_id = p_team_id and tm.left_at is null
    ) s;

  if v_role = 'leader' then
    select count(*) into v_pending
      from public.team_requests r
     where r.team_id = p_team_id and r.status = 'pending'
       and r.kind = 'apply' and r.expires_at > now();
  end if;

  return jsonb_build_object('ok', true, 'team', v_card, 'my_role', v_role,
                            'members', v_members, 'pending_count', v_pending,
                            /* ✅ 只回「我現在能不能接任」。三種不能的原因
                               都回 false，看不出是哪一種 —— 最小揭露。 */
                            'can_claim_leader',
                            public._team_claim_check(p_team_id, v_me) is null);
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
  p_member_id := public.current_member_id();
  if p_member_id is null then raise exception '未登入或登入已過期，請重新開啟 App' using errcode = '28000'; end if;
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
             'kind', c.kind, 'scope_label', public._coupon_scope_label(c.coupon_id),
             'discount_type', c.discount_type,
             'discount_value', c.discount_value,
             'expires_at', c.expires_at
           ) order by c.granted_at desc
         ), '[]'::jsonb) into v_coupons
  from (
    select
      mc.id,
      co.id as coupon_id,
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

-- [7.0] grant_snack_tx
CREATE OR REPLACE FUNCTION public.grant_snack_tx(p_org_id uuid, p_member_id uuid, p_kind text, p_qty integer, p_reason text, p_ref_id uuid, p_idem_key text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_id    uuid;
  v_total int;
begin
  if p_member_id is null or p_kind is null or coalesce(p_qty, 0) <= 0 then
    return jsonb_build_object('ok', false, 'reason', 'bad_args');
  end if;

  /* 冪等：同一把鑰匙只發一次。
     ⚠ 用 `on conflict do nothing` ＋ 看 `returning` 有沒有回值 ——
       先 select 再 insert 會在併發下發兩次（兩個請求同時查到「還沒發」）。 */
  insert into snack_grants (org_id, member_id, kind, qty, reason, ref_id, idem_key)
  values (p_org_id, p_member_id, p_kind, p_qty, p_reason, p_ref_id, p_idem_key)
  on conflict (idem_key) do nothing
  returning id into v_id;

  if v_id is null then
    return jsonb_build_object('ok', true, 'granted', false, 'reason', 'already_granted');
  end if;

  /* 點心的**顯示值**仍然住在 `member_app_state.bear.snacks`（前端在讀那裡）。
     🔴 但從今天起它是**帳本的結果**不是來源 —— 要對帳就數 `snack_grants`。
     ⏳ 下一步（另一份 SQL）是讓 `save_app_state_tx` 不再接受 snacks，
       否則前端仍然可以整包覆蓋掉這個值。**那一步才是真正關上門的一步。** */
  insert into member_app_state (member_id, org_id, bear, titles, updated_at)
  values (p_member_id, p_org_id,
          jsonb_build_object('snacks', jsonb_build_object(p_kind, p_qty)),
          '[]'::jsonb, now())
  on conflict (member_id) do update set
    bear = jsonb_set(
             coalesce(member_app_state.bear, '{}'::jsonb),
             array['snacks', p_kind],
             to_jsonb(
               coalesce((member_app_state.bear -> 'snacks' ->> p_kind)::int, 0) + p_qty
             ),
             true),
    updated_at = now();

  select coalesce((bear -> 'snacks' ->> p_kind)::int, 0) into v_total
    from member_app_state where member_id = p_member_id;

  return jsonb_build_object('ok', true, 'granted', true,
    'kind', p_kind, 'qty', p_qty, 'total', v_total);
end $function$
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
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
      begin
        -- 【身分 2026-09-29】從 API 進來的只有店員能叫；內部呼叫一律接 has_daypass_tx_core
        perform public._api_staff_only();
        return public.has_daypass_tx_core(p_org_id, p_member_id, p_store_id);
      end $function$
;

-- [7.0] has_daypass_tx_core
CREATE OR REPLACE FUNCTION public.has_daypass_tx_core(p_org_id uuid, p_member_id uuid, p_store_id uuid)
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
  ) or exists (
    -- 包桌加時間時補差價升級的（2026-10-01）
    select 1
      from session_extensions e
      join table_sessions ts on ts.id = e.session_id
      left join orders o on o.id = e.order_id
     where e.kind = 'daypass'
       and e.member_id = p_member_id
       and ts.org_id = p_org_id
       and (p_store_id is null or ts.store_id = p_store_id)
       and (e.order_id is null or (o.status = 'paid' and o.deleted_at is null))
       and (e.created_at at time zone 'Asia/Taipei')::date
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

-- [7.0] hide_my_account_tx
CREATE OR REPLACE FUNCTION public.hide_my_account_tx()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_me uuid := public.current_member_id();
begin
  if v_me is null then
    return jsonb_build_object('ok', false, 'reason', 'not_logged_in', 'message', '登入狀態已過期，請關閉 MIGI 再重新開啟');
  end if;
  return public._member_hide_core(v_me, 'self', null, null);
end $function$
;

-- [7.0] invite_to_team_tx
CREATE OR REPLACE FUNCTION public.invite_to_team_tx(p_team_id uuid, p_member_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_me   uuid := public.current_member_id();
  v_org  uuid := public.current_org_id();
  v_t    record;
  v_cnt  int;
  v_req  uuid;
  v_name text;
begin
  if v_me is null or v_org is null then
    return jsonb_build_object('ok', false, 'reason', 'not_logged_in', 'message', '請先登入');
  end if;
  if p_member_id is null or p_member_id = v_me then
    return jsonb_build_object('ok', false, 'reason', 'bad_target', 'message', '對象不正確');
  end if;
  /* 🆕 副團長也可以邀。**只有這一支放寬** —— 副團長不能審核、不能移除、
     不能改團，那些仍然是 `role = 'leader'`。 */
  if not exists (select 1 from public.team_members tm
                  where tm.team_id = p_team_id and tm.member_id = v_me
                    and tm.left_at is null and tm.role in ('leader', 'co_leader')) then
    return jsonb_build_object('ok', false, 'reason', 'not_leader', 'message', '只有團長或副團長可以邀請');
  end if;

  select t.id, t.name, t.member_limit into v_t
    from public.teams t where t.id = p_team_id and t.deleted_at is null;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'not_found', 'message', '找不到這個牌咖團');
  end if;

  if not exists (select 1 from public.members m
                  where m.id = p_member_id and m.org_id = v_org and m.deleted_at is null) then
    return jsonb_build_object('ok', false, 'reason', 'member_not_found', 'message', '找不到這個人');
  end if;
  if exists (select 1 from public.team_members tm
              where tm.team_id = p_team_id and tm.member_id = p_member_id and tm.left_at is null) then
    return jsonb_build_object('ok', false, 'reason', 'already_member', 'message', '他已經在團裡了');
  end if;

  select count(*) into v_cnt from public.team_members tm
   where tm.team_id = p_team_id and tm.left_at is null;
  if v_cnt >= v_t.member_limit then
    return jsonb_build_object('ok', false, 'reason', 'team_full', 'message', '這個團滿了');
  end if;

  perform public._team_expire_requests(p_team_id);

  /* 🎯 他已經申請過了 ⇒ 按邀請就是核准。
     ⚠ 這條路**副團長也走得到**，而那等於讓他核准了一筆申請 ——
       規格說副團長不能審核，但這裡是他主動去邀一個剛好也在申請的人，
       結果與「邀請成功」完全相同（那個人本來就想進來）。
       🔴 真正不給他的是**待審核清單**（`list_team_requests_tx` 仍是團長限定）
         ⇒ 他不會看到有誰在申請，也不能回絕任何人。 */
  select r.id into v_req from public.team_requests r
   where r.team_id = p_team_id and r.member_id = p_member_id
     and r.status = 'pending' and r.kind = 'apply';
  if v_req is not null then
    update public.team_requests set status = 'accepted', decided_by = v_me, decided_at = now()
     where id = v_req;
    insert into public.team_members (org_id, team_id, member_id)
    values (v_org, p_team_id, p_member_id);
    perform public._team_notify(v_org, p_member_id, 'team_ok', v_t.name,
             '你的申請通過了，歡迎加入 ' || v_t.name, p_team_id, v_t.name, null);
    return jsonb_build_object('ok', true, 'joined', true, 'via', 'apply',
                              'message', '他本來就在申請，已經直接加入了');
  end if;

  if exists (select 1 from public.team_requests r
              where r.team_id = p_team_id and r.member_id = p_member_id and r.status = 'pending') then
    return jsonb_build_object('ok', false, 'reason', 'already_pending', 'message', '已經邀請過了');
  end if;

  insert into public.team_requests (org_id, team_id, member_id, kind, created_by)
  values (v_org, p_team_id, p_member_id, 'invite', v_me)
  returning id into v_req;

  select display_name into v_name from public.members where id = v_me;
  perform public._team_notify(v_org, p_member_id, 'team_req', v_name,
           v_name || ' 邀請你加入 ' || v_t.name, p_team_id, v_t.name, v_req);

  return jsonb_build_object('ok', true, 'joined', false, 'request_id', v_req,
                            'message', '邀請已送出');
end $function$
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
  -- 【身分 2026-09-29】只認登入的本人，前端送的 id 一律忽略
  p_member := public.current_member_id();
  if p_member is null then raise exception '未登入或登入已過期，請重新開啟 App' using errcode = '28000'; end if;
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
  v_plan jsonb; v_items jsonb; v_res jsonb; v_order uuid; v_sp uuid; v_key text; v_seq int;
  v_target uuid; v_created int := 0; v_unit bigint; v_self_pass boolean; v_buy_daypass boolean;
  v_org uuid; v_store uuid;
begin
  /* 🔴 操作者身分從 JWT 取，不採信呼叫端送的 p_staff_id（2026-09-04）。 */
  p_staff_id := (select staff_id from public.current_staff());

  /* 🎯 2026-10-01：入座前的全部檢查與檯費那一行搬到 _join_plan ——
     POS 的報價（pos_quote_tx）叫同一支，畫面上的檯費份數與實收不可能不一樣。 */
  v_plan := public._join_plan(p_session_id, p_member_id, p_join_type, p_pay_for, p_items);
  if not coalesce((v_plan ->> 'ok')::boolean, false) then return v_plan; end if;

  v_items       := v_plan -> 'items';
  v_unit        := (v_plan ->> 'unit_fee')::bigint;
  v_self_pass   := (v_plan ->> 'daypass')::boolean;
  v_buy_daypass := (v_plan ->> 'daypass_bought')::boolean;
  v_org         := (v_plan ->> 'org_id')::uuid;
  v_store       := (v_plan ->> 'store_id')::uuid;

  select count(*) + 1 into v_seq from session_players where session_id = p_session_id and member_id = p_member_id;
  v_key := coalesce(p_idempotency_key, p_session_id::text || ':' || p_member_id::text || ':' || v_seq);

  if jsonb_array_length(v_items) > 0 then
    v_res := checkout_tx(p_member_id, v_store, v_items, p_coupon_ids,
                         coalesce(p_points_used, 0), p_payments, v_key, p_staff_id);
    v_order := (v_res ->> 'order_id')::uuid;
    update orders o
       set session_id = p_session_id,
           table_id   = (v_plan ->> 'table_id')::uuid,
           channel    = 'counter',
           entity_id  = coalesce(o.entity_id, (select entity_id from stores where id = v_store))
     where o.id = v_order;
  end if;

  -- 付款人自己入座
  insert into session_players(
    org_id, session_id, member_id, join_type, status, charged_points, order_id, joined_at, created_by,
    fee_waived_amount, fee_waived_reason)
  values (
    v_org, p_session_id, p_member_id, p_join_type, 'playing',
    coalesce((v_res ->> 'payable')::bigint, 0), v_order, now(), p_staff_id,
    -- 免收金額是使用量指標，不是折讓：不進 orders、不影響營收毛額
    case when (v_self_pass or v_buy_daypass) then v_unit else 0 end,
    case when (v_self_pass or v_buy_daypass) then 'daypass' end)
  returning id into v_sp;

  -- 被代付者一併入座：有入座記錄但沒有訂單，消費金額掛在代付人身上
  if p_pay_for is not null then
    foreach v_target in array p_pay_for loop
      insert into session_players(
        org_id, session_id, member_id, join_type, status, charged_points, order_id, paid_by, joined_at, created_by,
        fee_waived_amount, fee_waived_reason)
      values (
        v_org, p_session_id, v_target, p_join_type, 'playing', 0, null, p_member_id, now(), p_staff_id,
        case when has_daypass_tx(v_org, v_target, v_store) then v_unit else 0 end,
        case when has_daypass_tx(v_org, v_target, v_store) then 'daypass' end);
      v_created := v_created + 1;
    end loop;
  end if;

  return jsonb_build_object('ok', true, 'player_id', v_sp,
    'order_id', v_order, 'unit_fee', v_unit, 'qty', (v_plan ->> 'qty')::int,
    'listed_amount', (v_plan ->> 'amount')::bigint, 'paid_for_count', v_created,
    'extra_items', (v_plan ->> 'extra_items')::int,
    'daypass', v_self_pass, 'daypass_bought', v_buy_daypass,
    'checkout', v_res);
end $function$
;

-- [7.0] kick_team_member_tx
CREATE OR REPLACE FUNCTION public.kick_team_member_tx(p_team_id uuid, p_member_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_me   uuid := public.current_member_id();
  v_org  uuid;
  v_team text;
begin
  if v_me is null then
    return jsonb_build_object('ok', false, 'reason', 'not_logged_in', 'message', '請先登入');
  end if;
  if p_member_id = v_me then
    return jsonb_build_object('ok', false, 'reason', 'self',
                              'message', '要離開請用退團，不是移除自己');
  end if;
  if not exists (select 1 from public.team_members tm
                  where tm.team_id = p_team_id and tm.member_id = v_me
                    and tm.left_at is null and tm.role = 'leader') then
    return jsonb_build_object('ok', false, 'reason', 'not_leader', 'message', '只有團長可以移除團員');
  end if;

  /* 🔴 寫 `kicked` 不重用 `quit` —— `quit` 的意思是「他自己走的」，
     店員移除卻寫 quit 會讓那個欄位說一件沒發生的事（同 2026-09-10
     配桌那批的決定）。而且它不會報錯，只會讓日後的流失分析算錯。 */
  update public.team_members set left_at = now(), left_reason = 'kicked'
   where team_id = p_team_id and member_id = p_member_id and left_at is null;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'not_member', 'message', '他不在這個團裡');
  end if;

  /* 🆕 通知。org 取自 teams 不取 current_org_id() ——
     那支要有身分才回得出東西，而這支日後可能被排程或總部工具呼叫，
     那時它會回 null，而 app_notifications.org_id 是 NOT NULL
     ⇒ 症狀會是「移出成功、通知整筆炸掉」。teams.org_id 在任何情境都成立。
     ⚠ 放在擋牆全部通過、而且真的移掉一列之後 —— 上面每一個 return
       都不可以留下一則說謊的通知。 */
  select t.org_id, t.name into v_org, v_team
    from public.teams t where t.id = p_team_id;

  perform public._team_notify(v_org, p_member_id, 'team_out', null,
            '你已被移出 ' || v_team, p_team_id, v_team, null);

  return jsonb_build_object('ok', true, 'message', '已移除');
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
  -- 【身分 2026-09-29】店員可以代客人操作；其他人只認登入的本人
  if not exists (select 1 from public.current_staff()) then
    p_member := public.current_member_id();
    if p_member is null then raise exception '未登入或登入已過期，請重新開啟 App' using errcode = '28000'; end if;
  end if;
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

-- [7.0] leave_team_tx
CREATE OR REPLACE FUNCTION public.leave_team_tx(p_team_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_me   uuid := public.current_member_id();
  v_role text;
  v_cnt  int;
begin
  if v_me is null then
    return jsonb_build_object('ok', false, 'reason', 'not_logged_in', 'message', '請先登入');
  end if;

  select tm.role into v_role from public.team_members tm
   where tm.team_id = p_team_id and tm.member_id = v_me and tm.left_at is null;
  if v_role is null then
    return jsonb_build_object('ok', false, 'reason', 'not_member', 'message', '你不在這個團裡');
  end if;

  select count(*) into v_cnt from public.team_members tm
   where tm.team_id = p_team_id and tm.left_at is null;

  /* 🔴 話術改了：舊版在這裡還提供了第二條路（把團收掉），
     而那已經不是他做得到的事 —— 一句叫人去做做不到的事的提示
     比沒有提示更糟。現在只剩一條路，就只講那一條。
     ⚠ **這段註解刻意不寫出舊的那句話**：驗證段第 ⑤ 格掃的就是它，
       而 `pg_get_functiondef` 回的是含註解的全文（硬規則 3.5）——
       寫出來的話那一格會永遠紅，而函式其實是對的。 */
  if v_role = 'leader' and v_cnt > 1 then
    return jsonb_build_object('ok', false, 'reason', 'leader_must_transfer',
                              'message', '你是團長，請先把團長轉給其他團員');
  end if;

  /* 團長且只剩自己 ⇒ 這個團沒有人了，收掉它。
     🔴 走下面那支**收尾**函式，不走總部那道門 —— 那道門現在只認 hq/owner，
       經過它的話一人團的團長會被自己的團鎖住，而且訊息會說
       「只有總部可以解散」，跟他按的動作完全對不上。
     ⚠ 同上：**不寫出那道門的函式名**，第 ④ 格掃的就是它。 */
  if v_role = 'leader' then
    return public._team_disband(p_team_id, v_me);
  end if;

  update public.team_members set left_at = now(), left_reason = 'quit'
   where team_id = p_team_id and member_id = v_me and left_at is null;

  return jsonb_build_object('ok', true, 'message', '已退出這個牌咖團');
end $function$
;

-- [7.0] like_player_tx
CREATE OR REPLACE FUNCTION public.like_player_tx(p_org_id uuid, p_liker uuid, p_target uuid, p_on boolean, p_session uuid DEFAULT NULL::uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_today_like uuid;
  v_both       int;
begin
  -- 【身分 2026-09-29】只認登入的本人，前端送的 id 一律忽略
  p_liker := public.current_member_id();
  if p_liker is null then raise exception '未登入或登入已過期，請重新開啟 App' using errcode = '28000'; end if;
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

    /* 🆕 2026-09-19：按讚發小熊餅乾 1 個（使用者定的規則）。
       🔴 **兩道門，缺一不可**：
         ① 沒有 session 不發 —— 獎勵綁在一場牌局上，
            「同一場最多 3 個」這條規則才有意義。
         ② **兩個人都要真的坐過那一桌** —— 否則隨便送一個 session_id
            就能對任何人按讚換餅乾，而那是刷點心的門。
       ⚠ 上限 3 個是**自然結果**不是另外算的：一場只有另外三個人，
         而冪等鍵綁 (session, liker, target) ⇒ 每個人最多發一次。
       ⚠ 取消讚**不收回**（帳本 append-only）——
         收回會讓人學會不要按讚，而那顆讚的目的是鼓勵。
       ⚠ 發放失敗不可以讓按讚整個失敗：讚已經進去了，
         而客人看到的是「按了沒反應」。所以吞例外。 */
    if p_session is not null then
      select count(*) into v_both
        from session_players sp
       where sp.session_id = p_session
         and sp.member_id in (p_liker, p_target);
      if v_both = 2 then
        begin
          perform public.grant_snack_tx(
            p_org_id, p_liker, 'cookie', 1, 'like', p_session,
            'like:' || p_session::text || ':' || p_liker::text || ':' || p_target::text);
        exception when others then null;
        end;
      end if;
    end if;
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
  -- 【身分 2026-09-29】店員可以代客人操作；其他人只認登入的本人
  if not exists (select 1 from public.current_staff()) then
    p_member := public.current_member_id();
    if p_member is null then raise exception '未登入或登入已過期，請重新開啟 App' using errcode = '28000'; end if;
  end if;
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
  -- 【身分 2026-09-29】店員可以代客人操作；其他人只認登入的本人
  if not exists (select 1 from public.current_staff()) then
    p_member := public.current_member_id();
    if p_member is null then raise exception '未登入或登入已過期，請重新開啟 App' using errcode = '28000'; end if;
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', b.buddy_id, 'nickname', m.display_name,
      'rank', m.rank, 'title', m.title, 'likes_count', m.likes_count,
      'avatar_url', m.avatar_url, 'co_play_count', b.co_play_count,
      'avatar_source', m.avatar_source, 'avatar_photo_path', m.avatar_photo_path,
      'avatar_bear', m.avatar_bear,
      'linked_at', b.linked_at,
      'last_played_at', (h.v ->> 'last_at')::timestamptz,
      /* 常一起打：回結構不回句子。2026-09-30 起算法在 _pair_history（個人卡共用）。 */
      'play_pattern', h.v -> 'pattern'
    ) order by b.linked_at desc)
    from mahjong_buddies b
    /* 隱藏中的牌咖不列。關係列不刪，恢復之後自動回來。 */
    join members m on m.id = b.buddy_id and m.deleted_at is null and m.hidden_at is null
    cross join lateral (select public._pair_history(p_org_id, p_member, b.buddy_id) as v) h
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

-- [7.0] list_hot_teams_tx
CREATE OR REPLACE FUNCTION public.list_hot_teams_tx(p_limit integer DEFAULT 5)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_org  uuid := public.current_org_id();
  v_rows jsonb;
begin
  if v_org is null then
    return jsonb_build_object('ok', false, 'reason', 'not_logged_in', 'message', '請先登入');
  end if;

  select coalesce(jsonb_agg(card order by cnt desc, played desc, nm), '[]'::jsonb)
    into v_rows
    from (
      select public._team_card(t.id) as card,
             (select count(*) from public.team_members tm
               where tm.team_id = t.id and tm.left_at is null) as cnt,
             (select count(*) from public._team_session_ids(t.id)) as played,
             t.name as nm
        from public.teams t
       where t.org_id = v_org and t.deleted_at is null
       order by cnt desc, played desc, t.name
       limit greatest(1, least(coalesce(p_limit, 5), 20))
    ) s;

  return jsonb_build_object('ok', true, 'teams', v_rows);
end $function$
;

-- [7.0] list_match_queues_by_city_tx
CREATE OR REPLACE FUNCTION public.list_match_queues_by_city_tx(p_org_id uuid, p_member uuid, p_city text, p_area text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  -- 【身分 2026-09-29】清單本身公開；「我在不在房裡」只認登入的本人（店員照舊）
  if not exists (select 1 from public.current_staff()) then p_member := public.current_member_id(); end if;
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
  -- 【身分 2026-09-29】清單本身公開；「我在不在房裡」只認登入的本人（店員照舊）
  if not exists (select 1 from public.current_staff()) then p_member := public.current_member_id(); end if;
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

-- [7.0] list_my_bookings_tx
CREATE OR REPLACE FUNCTION public.list_my_bookings_tx()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_me   uuid := public.current_member_id();
  v_rows jsonb;
begin
  if v_me is null then
    return jsonb_build_object('ok', false, 'reason', 'not_logged_in', 'message', '請先登入');
  end if;

  perform public._booking_expire(null);

  /* ⚠ 過去的只留 30 天 —— 再久的預約紀錄客人不會看，
     而一個越來越長的清單會把「下一筆什麼時候」埋掉。 */
  select coalesce(jsonb_agg(x order by x->>'play_at'), '[]'::jsonb)
    into v_rows
    from (
      select jsonb_build_object(
               'booking_id',    k.id,
               'store_id',      k.store_id,
               'store_name',    s.name,
               /* 🆕 2026-09-17：抽屜的「地址」那一列（可點去導航）。 */
               'store_address', s.address,
               'team_id',       k.team_id,
               'team_name',     t.name,
               'play_at',       k.play_at,
               'hours',         k.planned_hours,
               'table_count',   k.table_count,
               'party_size',    k.party_size,
               'note',          k.note,
               'status',        k.status,
               'table_label',   tb.label,
               /* 🆕 2026-09-17：預約時就決定的牌規與積分（09-16 寫入端就有，讀出來這裡沒跟上）。 */
               'game_type',     k.game_type,
               'flower',        k.flower,
               'stake_label',   sl.label,
               'mine',          k.member_id = v_me) as x
        from public.bookings k
        join public.stores s on s.id = k.store_id
        left join public.teams  t  on t.id  = k.team_id
        left join public.tables tb on tb.id = k.table_id
        left join public.stake_levels sl on sl.id = k.stake_level_id
       where (k.member_id = v_me
              or (k.team_id is not null and exists (
                    select 1 from public.team_members tm
                     where tm.team_id = k.team_id and tm.member_id = v_me and tm.left_at is null)))
         and k.play_at > now() - interval '30 days'
    ) q;

  return jsonb_build_object('ok', true, 'bookings', v_rows);
end $function$
;

-- [7.0] list_my_teams_tx
CREATE OR REPLACE FUNCTION public.list_my_teams_tx()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_me   uuid := public.current_member_id();
  v_rows jsonb;
begin
  if v_me is null then
    return jsonb_build_object('ok', false, 'reason', 'not_logged_in', 'message', '請先登入');
  end if;

  select coalesce(jsonb_agg(x order by x->>'joined_at'), '[]'::jsonb)
    into v_rows
    from (
      select public._team_card(tm.team_id)
             || jsonb_build_object(
                  'my_role',   tm.role,
                  'joined_at', tm.joined_at,
                  /* 待審核筆數只有團長看得到 —— 一般團員看到一個數字
                     卻按不下去，那比沒有更糟。 */
                  'pending_count',
                  case when tm.role = 'leader' then (
                    select count(*) from public.team_requests r
                     where r.team_id = tm.team_id and r.status = 'pending'
                       and r.kind = 'apply' and r.expires_at > now())
                  else 0 end) as x
        from public.team_members tm
        join public.teams t on t.id = tm.team_id and t.deleted_at is null
       where tm.member_id = v_me and tm.left_at is null
    ) s;

  return jsonb_build_object('ok', true, 'teams', v_rows);
end $function$
;

-- [7.0] list_notifications_tx
CREATE OR REPLACE FUNCTION public.list_notifications_tx(p_org_id uuid, p_member uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  -- 【身分 2026-09-29】只認登入的本人，前端送的 id 一律忽略
  p_member := public.current_member_id();
  if p_member is null then raise exception '未登入或登入已過期，請重新開啟 App' using errcode = '28000'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', n.id, 'type', n.type, 'payload', n.payload, 'ref_id', n.ref_id,
      'unread', (n.read_at is null), 'created_at', n.created_at,
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
        end
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
  -- 【身分 2026-09-29】只認登入的本人，前端送的 id 一律忽略
  p_member := public.current_member_id();
  if p_member is null then raise exception '未登入或登入已過期，請重新開啟 App' using errcode = '28000'; end if;
  return coalesce((
    select jsonb_agg(distinct jsonb_build_object(
      'id', other.member_id, 'nickname', mm.display_name, 'rank', mm.rank,
      'avatar_url', mm.avatar_url, 'avatar_bear', mm.avatar_bear, 'avatar_source', mm.avatar_source, 'avatar_photo_path', mm.avatar_photo_path
    ))
    from session_players sp
    join session_players other on other.session_id = sp.session_id and other.member_id <> sp.member_id
    /* 🆕 2026-09-25：隱藏中的人不列 —— 這一塊是「加牌咖」的入口，
       加一個打不開 App 的人沒有意義（send_buddy_invite_tx 也會擋）。 */
    join members mm on mm.id = other.member_id and mm.deleted_at is null and mm.hidden_at is null
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

-- [7.0] list_table_devices_tx
CREATE OR REPLACE FUNCTION public.list_table_devices_tx(p_store_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if (select staff_id from public.current_staff()) is null then
    return jsonb_build_object('ok', false, 'reason', 'not_staff', 'message', '請先登入');
  end if;
  if not public.has_store_access(p_store_id) then
    return jsonb_build_object('ok', false, 'reason', 'forbidden', 'message', '你沒有這間店的權限');
  end if;
  return jsonb_build_object('ok', true, 'can_pair', public.can('device.write'), 'devices', coalesce((
    select jsonb_agg(jsonb_build_object(
             'device_id', dv.id, 'label', dv.label, 'table_id', dv.table_id, 'table', t.label,
             'is_active', dv.is_active, 'last_seen_at', dv.last_seen_at, 'created_at', dv.created_at,
             'in_use', exists (select 1 from session_players sp where sp.device_id = dv.id and sp.left_at is null))
           order by t.sort_order, t.label, dv.label)
      from table_devices dv join tables t on t.id = dv.table_id
     where dv.store_id = p_store_id and dv.is_active), '[]'::jsonb));
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
  -- 【身分 2026-09-29】從 API 進來的只有店員能叫（排程沒有 API 身分，照常）
  perform public._api_staff_only();
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
      'pkg_phase', (public._pkg_time(ts.id, false) ->> 'phase'),   /* ⏰ 包桌續時（2026-10-01） */
      /* 打完了、等店員收桌（2026-10-02）：這一場已經有人有名次。判斷只有 _session_scored 這一份 */
      'game_over', (ts.id is not null and public._session_scored(ts.id)),
      /* 要店員過去處理的事（2026-10-04）：只回事實，門檻（3 分鐘、1 分鐘）在 POS 那一份 */
      'pending_since', (select min(h.created_at) from hands h where h.session_id = ts.id and h.status = 'pending'),
      'pending_waiting', (select coalesce(jsonb_agg(m.display_name order by sp.seat), '[]'::jsonb)
                            from hands h
                            join session_players sp on sp.session_id = h.session_id and sp.left_at is null
                                 and sp.seat = any(coalesce(h.need_confirm, '{}'::smallint[]))
                                 and not (sp.seat = any(coalesce(h.confirmed_seats, '{}'::smallint[])))
                                 and not (sp.seat = any(coalesce(h.cancelled_seats, '{}'::smallint[])))
                            join members m on m.id = sp.member_id
                           where h.session_id = ts.id and h.status = 'pending'),
      'bust_name', case when ts.id is null or public._session_scored(ts.id) then null else
                     (select m.display_name from session_busts b
                        join session_players sp on sp.session_id = b.session_id and sp.seat = b.seat and sp.left_at is null
                        join members m on m.id = sp.member_id
                       where b.session_id = ts.id and b.decision = 'pending' order by b.seat limit 1) end,
      'device_seen', case when ts.id is null then '[]'::jsonb else
                       (select coalesce(jsonb_agg(jsonb_build_object('label', d.label, 'last_seen_at', d.last_seen_at)
                                                  order by d.label), '[]'::jsonb)
                          from table_devices d where d.table_id = t.id and d.is_active) end,

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

-- [7.0] list_team_requests_tx
CREATE OR REPLACE FUNCTION public.list_team_requests_tx(p_team_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_me   uuid := public.current_member_id();
  v_rows jsonb;
begin
  if v_me is null then
    return jsonb_build_object('ok', false, 'reason', 'not_logged_in', 'message', '請先登入');
  end if;
  if not exists (select 1 from public.team_members tm
                  where tm.team_id = p_team_id and tm.member_id = v_me
                    and tm.left_at is null and tm.role = 'leader') then
    return jsonb_build_object('ok', false, 'reason', 'not_leader', 'message', '只有團長看得到');
  end if;

  perform public._team_expire_requests(p_team_id);

  select coalesce(jsonb_agg(jsonb_build_object(
           'request_id', r.id,
           /* 🔴 這裡回 member_id 是刻意的 —— 團長要按核准，
              而核准吃的是 request_id。但名冊那邊的原則同樣適用：
              這一頁只有團長叫得動。 */
           'member_id',  r.member_id,
           'nickname',   m.display_name,
           'rank',       m.rank,
           'title',      m.title,
           'kind',       r.kind,
           'created_at', r.created_at,
           'expires_at', r.expires_at) order by r.created_at), '[]'::jsonb)
    into v_rows
    from public.team_requests r
    join public.members m on m.id = r.member_id
   where r.team_id = p_team_id and r.status = 'pending' and r.kind = 'apply';

  return jsonb_build_object('ok', true, 'requests', v_rows);
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
  /* 🔴 有會員 session 時一律以 JWT 為準（2026-09-11，待辦 14）。
     ⚠ **只在前端送了值的時候覆寫** —— null 在這一支是有意義的值
       （「這件事沒有會員」），不是「沒填」。
     🔴 無條件 coalesce 會把 POS 的事件全部掛到**登入中的店員**身上：
       店員本身是會員，所以 current_member_id() 回得出他的 member_id，
       而 POS 的埋點本來一律送 null。 */
  p_member_id := case when p_member_id is null then null
                      else coalesce(public.current_member_id(), p_member_id) end;

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
  p_member_id := public.current_member_id();
  if p_member_id is null then raise exception '未登入或登入已過期，請重新開啟 App' using errcode = '28000'; end if;
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
  -- 【身分 2026-09-29】只認登入的本人，前端送的 id 一律忽略
  p_member := public.current_member_id();
  if p_member is null then raise exception '未登入或登入已過期，請重新開啟 App' using errcode = '28000'; end if;
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
  if p_mode = 'private' and coalesce(p_planned_minutes, 0) not in (120, 300) then
    return jsonb_build_object('ok', false, 'reason', 'invalid_minutes',
      'message', '包桌需選擇 2 小時或 5 小時（要打更久，到時候加時間或升級當日暢打）');
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
  -- 【身分 2026-09-29】從 API 進來的只有店員能叫（排程沒有 API 身分，照常）
  perform public._api_staff_only();
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

-- [7.0] pos_clear_on_duty_tx
CREATE OR REPLACE FUNCTION public.pos_clear_on_duty_tx()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_n int;
begin
  /* 交班登出：只清「自己」—— 下一位如果已經先登入了（取代了我），不可以把他清掉 */
  update stores set on_duty_staff_id = null, on_duty_since = null
   where on_duty_staff_id in (select cs.staff_id from public.current_staff() cs);
  get diagnostics v_n = row_count;
  return jsonb_build_object('ok', true, 'cleared', v_n);
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
  -- 【身分 2026-09-29】從 API 進來的只有店員能叫（排程沒有 API 身分，照常）
  perform public._api_staff_only();
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
  -- 【身分 2026-09-29】從 API 進來的只有店員能叫（排程沒有 API 身分，照常）
  perform public._api_staff_only();
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
  -- 【身分 2026-09-29】從 API 進來的只有店員能叫（排程沒有 API 身分，照常）
  perform public._api_staff_only();
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

-- [7.0] pos_list_bookings_tx
CREATE OR REPLACE FUNCTION public.pos_list_bookings_tx(p_store_id uuid, p_day date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_staff uuid;
  v_day   date;
  v_from  timestamptz;
  v_rows  jsonb;
begin
  select staff_id into v_staff from public.current_staff();
  if v_staff is null then
    return jsonb_build_object('ok', false, 'reason', 'not_staff', 'message', '請先登入');
  end if;

  perform public._booking_expire(p_store_id);

  /* 日期用台北日曆日，與當日暢打同一個判準 —— 系統裡不要有第二種「今天」。 */
  v_day  := coalesce(p_day, (now() at time zone 'Asia/Taipei')::date);
  v_from := (v_day::timestamp at time zone 'Asia/Taipei');

  select coalesce(jsonb_agg(x order by x->>'play_at'), '[]'::jsonb)
    into v_rows
    from (
      select jsonb_build_object(
               'booking_id',  k.id,
               /* 🔴 回 `member_id` 是刻意的，而且**只有這一支回** ——
                  店員要能跳到會員查詢確認身分與聯絡。
                  ⚠ **不回手機**：POS 已經有會員查詢那條路，
                    在這裡多帶一份個資是白白擴大暴露面。 */
               'member_id',   k.member_id,
               'nickname',    m.display_name,
               'team_name',   t.name,
               'play_at',     k.play_at,
               'hours',       k.planned_hours,
               'table_count', k.table_count,
               'party_size',  k.party_size,
               'note',        k.note,
               'status',      k.status,
               'table_id',    k.table_id,
               'table_label', tb.label) as x
        from public.bookings k
        join public.members m on m.id = k.member_id
        left join public.teams  t  on t.id  = k.team_id
        left join public.tables tb on tb.id = k.table_id
       where k.store_id = p_store_id
         and k.play_at >= v_from
         and k.play_at <  v_from + interval '1 day'
    ) q;

  return jsonb_build_object('ok', true, 'day', v_day, 'bookings', v_rows);
end $function$
;

-- [7.0] pos_list_queues_tx
CREATE OR REPLACE FUNCTION public.pos_list_queues_tx(p_org uuid, p_store uuid, p_before timestamp with time zone DEFAULT NULL::timestamp with time zone, p_limit integer DEFAULT 20)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
      begin
        -- 【身分 2026-09-29】從 API 進來的只有店員能叫；內部呼叫一律接 pos_list_queues_tx_core
        perform public._api_staff_only();
        return public.pos_list_queues_tx_core(p_org, p_store, p_before, p_limit);
      end $function$
;

-- [7.0] pos_list_queues_tx_core
CREATE OR REPLACE FUNCTION public.pos_list_queues_tx_core(p_org uuid, p_store uuid, p_before timestamp with time zone DEFAULT NULL::timestamp with time zone, p_limit integer DEFAULT 20)
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
        'walk_in', p.join_source = 'pos_walkin',
        /* 頭像四欄（2026-09-26）：與 get_session_tx 同一組鍵，POS 的座位卡直接畫。
           少了它們，配桌列表上每個人都是通用小熊。 */
        'avatar_source', m.avatar_source,
        'avatar_photo_path', m.avatar_photo_path,
        'avatar_bear', m.avatar_bear,
        'avatar_url', m.avatar_url
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
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
      begin
        -- 【身分 2026-09-29】從 API 進來的只有店員能叫；內部呼叫一律接 pos_list_recurring_tx_core
        perform public._api_staff_only();
        return public.pos_list_recurring_tx_core(p_org_id, p_store);
      end $function$
;

-- [7.0] pos_list_recurring_tx_core
CREATE OR REPLACE FUNCTION public.pos_list_recurring_tx_core(p_org_id uuid, p_store uuid)
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

-- [7.0] pos_mark_booking_tx
CREATE OR REPLACE FUNCTION public.pos_mark_booking_tx(p_booking_id uuid, p_status text, p_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_staff uuid;
  v_b     record;
begin
  select staff_id into v_staff from public.current_staff();
  if v_staff is null then
    return jsonb_build_object('ok', false, 'reason', 'not_staff', 'message', '請先登入');
  end if;
  if p_status not in ('no_show', 'cancelled') then
    return jsonb_build_object('ok', false, 'reason', 'bad_status', 'message', '只能標記沒出現或取消');
  end if;

  select * into v_b from public.bookings where id = p_booking_id;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'not_found', 'message', '找不到這筆預約');
  end if;
  if v_b.status <> 'booked' then
    return jsonb_build_object('ok', false, 'reason', 'already_decided', 'status', v_b.status,
                              'message', '這筆已經處理過了');
  end if;

  update public.bookings
     set status = p_status,
         /* ⚠ `cancelled` 一定要有理由（CHECK 擋著）。這裡填 `staff`
            而不是空字串 —— 「誰取消的」在報表上分得開才有意義。 */
         cancelled_reason = case when p_status = 'cancelled'
                                 then coalesce(nullif(btrim(coalesce(p_reason, '')), ''), 'staff') end,
         updated_at = now()
   where id = p_booking_id;

  return jsonb_build_object('ok', true, 'message', case p_status
    when 'no_show' then '已記成沒有出現' else '已取消' end);
end $function$
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
  -- 【身分 2026-09-29】從 API 進來的只有店員能叫（排程沒有 API 身分，照常）
  perform public._api_staff_only();
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
          'applies_to', c.applies_to, 'scope_label', public._coupon_scope_label(c.id),
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

-- [7.0] pos_pkg_extend_tx
CREATE OR REPLACE FUNCTION public.pos_pkg_extend_tx(p_session_id uuid, p_member_id uuid, p_for uuid[] DEFAULT NULL::uuid[], p_kind text DEFAULT '2h'::text, p_points_used bigint DEFAULT 0, p_payments jsonb DEFAULT NULL::jsonb, p_idempotency_key text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_q jsonb; v_res jsonb; v_order uuid; v_org uuid; v_key text;
begin
  perform public._api_staff_only();
  v_q := public.pos_pkg_quote_tx(p_session_id, p_member_id, p_for, p_kind);
  if not coalesce((v_q ->> 'ok')::boolean, false) then return v_q; end if;
  select org_id into v_org from table_sessions where id = p_session_id;

  if jsonb_array_length(v_q -> 'items') > 0 then
    -- 沒給冪等鍵就照「誰付、替誰、拿到什麼」自己組（同一個人可以連加好幾次，鍵裡一定要有時數）
    select coalesce(p_idempotency_key,
             'pkgx-' || p_session_id || '-' || p_member_id || '-'
             || string_agg((c ->> 'member_id') || ':' || (c ->> 'result') || ':' || coalesce(c ->> 'to_minutes', ''),
                           ',' order by c ->> 'member_id'))
      into v_key
      from jsonb_array_elements(v_q -> 'cover') c;

    v_res := public.pos_addon_checkout_tx(p_session_id, p_member_id, v_q -> 'items', null,
               coalesce(p_points_used, 0), p_payments, v_key, null);
    if not coalesce((v_res ->> 'ok')::boolean, false) then return v_res; end if;

    v_order := nullif(v_res ->> 'order_id', '')::uuid;
    if v_order is null then
      -- 錢收了卻找不到訂單 ⇒ 記不了「加給誰」⇒ 整筆退回（例外會回滾收款），不留半筆帳
      raise exception '包桌加時：收款成功但找不到訂單，整筆取消';
    end if;

    -- 🔴 重送：同一把鍵回的是舊訂單，而那張訂單已經記過延長 ⇒ 不再加（否則沒收錢卻多加了一段）
    if exists (select 1 from session_extensions where order_id = v_order) then
      return v_res || jsonb_build_object('replayed', true, 'pkg', public._pkg_time(p_session_id, true));
    end if;
  else
    -- 差額剛好是 0（已經付滿暢打價）：不開訂單，直接記升級
    v_res := jsonb_build_object('ok', true, 'order_id', null, 'amount', 0);
  end if;

  insert into session_extensions (org_id, session_id, member_id, kind, to_minutes, paid_by, order_id, created_by)
  select v_org, p_session_id, (c ->> 'member_id')::uuid, c ->> 'result', (c ->> 'to_minutes')::int, p_member_id, v_order,
         (select staff_id from public.current_staff())
    from jsonb_array_elements(v_q -> 'cover') c
  on conflict do nothing;

  perform public._tbl_ping(p_session_id);   -- 讓計分板馬上重新拿狀態
  return v_res || jsonb_build_object('cover', v_q -> 'cover', 'pkg', public._pkg_time(p_session_id, true));
end $function$
;

-- [7.0] pos_pkg_quote_tx
CREATE OR REPLACE FUNCTION public.pos_pkg_quote_tx(p_session_id uuid, p_member_id uuid, p_for uuid[] DEFAULT NULL::uuid[], p_kind text DEFAULT '2h'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_pkg jsonb; v_cover uuid[]; v_bad text; v_org uuid; v_items jsonb := '[]'::jsonb; v_price jsonb;
        v_rows jsonb; v_2h bigint; v_unit bigint; v_n2h int; v_up bigint; v_pid uuid;
begin
  perform public._api_staff_only();
  if coalesce(p_kind, '') not in ('2h', 'daypass') then
    return jsonb_build_object('ok', false, 'reason', 'bad_kind', 'message', '加時間只有「加 2 小時」與「升級當日暢打」兩種');
  end if;
  v_pkg := public._pkg_time(p_session_id, true);
  if v_pkg is null then
    return jsonb_build_object('ok', false, 'reason', 'not_private', 'message', '這一場不是包桌');
  end if;
  if v_pkg ->> 'phase' = 'closed' then
    return jsonb_build_object('ok', false, 'reason', 'session_closed', 'message', '這一場已經收桌');
  end if;
  if v_pkg ->> 'phase' = 'capped' then
    return jsonb_build_object('ok', false, 'reason', 'capped', 'message', '這一桌都是當日暢打，不用再加', 'pkg', v_pkg);
  end if;
  if not exists (select 1 from session_players
                  where session_id = p_session_id and member_id = p_member_id and left_at is null) then
    return jsonb_build_object('ok', false, 'reason', 'not_seated', 'message', '付錢的人要在這一桌');
  end if;

  -- 替誰加：不給 ＝ 替自己；自己不用加（已經是暢打）就沒有東西可以收
  select array_agg(distinct x) into v_cover
    from unnest(coalesce(p_for, array[p_member_id])) x where x is not null;
  if p_for is null and not exists (
       select 1 from jsonb_array_elements(v_pkg -> 'players') e
        where (e ->> 'member_id')::uuid = p_member_id and e ->> 'status' in ('owed', 'paid')) then
    return jsonb_build_object('ok', false, 'reason', 'nothing_owed', 'message', '這位客人已經是當日暢打，不用再加', 'pkg', v_pkg);
  end if;
  if v_cover is null or cardinality(v_cover) = 0 then
    return jsonb_build_object('ok', false, 'reason', 'nothing_owed', 'message', '沒有選要替誰加', 'pkg', v_pkg);
  end if;

  -- 每一位都要是還要計時的人（在這一桌、不是暢打）
  select string_agg(coalesce(y.e ->> 'name', '有一位不在這一桌的人'), '、') into v_bad
    from unnest(v_cover) c
    left join lateral (select e from jsonb_array_elements(v_pkg -> 'players') e
                        where (e ->> 'member_id')::uuid = c) y on true
   where y.e is null or y.e ->> 'status' not in ('owed', 'paid');
  if v_bad is not null then
    return jsonb_build_object('ok', false, 'reason', 'not_owed', 'message', v_bad || ' 已經是當日暢打，不用再加', 'pkg', v_pkg);
  end if;

  select org_id into v_org from table_sessions where id = p_session_id;
  select unit_price into v_2h   from products where org_id = v_org and sku = 'SVC-TBL-PX02'  and deleted_at is null;
  select unit_price into v_unit from products where org_id = v_org and sku = 'SVC-TBL-DAYUP' and deleted_at is null;
  if v_2h is null or v_unit is null or v_unit <= 0 then
    return jsonb_build_object('ok', false, 'reason', 'product_not_found', 'message', '找不到包桌加時商品');
  end if;

  -- 每一位這次拿到什麼：加 2 小時，或升級暢打（自己選的、或加 2 小時會讓累計到暢打價 ⇒ 直接升級，只收差額）
  select jsonb_agg(jsonb_build_object(
           'member_id', c, 'name', y.e ->> 'name',
           'result',     case when p_kind = 'daypass' or (y.e ->> 'upgrade_price')::bigint <= v_2h then 'daypass' else '2h' end,
           'to_minutes', case when p_kind = 'daypass' or (y.e ->> 'upgrade_price')::bigint <= v_2h then null
                              else least((y.e ->> 'minutes')::int + 120, 1440) end,
           'list_amount', case when p_kind = 'daypass' or (y.e ->> 'upgrade_price')::bigint <= v_2h
                               then (y.e ->> 'upgrade_price')::bigint else v_2h end) order by c)
    into v_rows
    from unnest(v_cover) c
    join lateral (select e from jsonb_array_elements(v_pkg -> 'players') e
                   where (e ->> 'member_id')::uuid = c) y on true;

  select count(*) filter (where r ->> 'result' = '2h'),
         coalesce(sum((r ->> 'list_amount')::bigint) filter (where r ->> 'result' = 'daypass'), 0)
    into v_n2h, v_up
    from jsonb_array_elements(v_rows) r;
  if v_up % v_unit <> 0 then
    return jsonb_build_object('ok', false, 'reason', 'price_unit', 'message', '暢打補差價換算不出整數份，請檢查包桌與暢打的價格');
  end if;

  if v_n2h > 0 then
    select id into v_pid from products where org_id = v_org and sku = 'SVC-TBL-PX02' and deleted_at is null;
    v_items := v_items || jsonb_build_array(jsonb_build_object('product_id', v_pid, 'qty', v_n2h));
  end if;
  if v_up > 0 then
    select id into v_pid from products where org_id = v_org and sku = 'SVC-TBL-DAYUP' and deleted_at is null;
    v_items := v_items || jsonb_build_array(jsonb_build_object('product_id', v_pid, 'qty', v_up / v_unit));
  end if;

  if jsonb_array_length(v_items) > 0 then
    v_price := public._cart_pricing(v_org, p_member_id, v_items, null);   -- 等級折扣看付錢的人（升級暢打不參與折扣）
  end if;
  return jsonb_build_object('ok', true, 'kind', p_kind, 'owed', cardinality(v_cover), 'cover', v_rows,
    'cover_ids', to_jsonb(v_cover), 'items', v_items,
    'amount', coalesce((v_price ->> 'payable')::bigint, 0), 'pricing', v_price, 'pkg', v_pkg);
end $function$
;

-- [7.0] pos_pkg_state_tx
CREATE OR REPLACE FUNCTION public.pos_pkg_state_tx(p_session_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_pkg jsonb;
begin
  perform public._api_staff_only();   -- 從 API 進來的只有店員能叫
  v_pkg := public._pkg_time(p_session_id, true);
  if v_pkg is null then
    return jsonb_build_object('ok', false, 'reason', 'not_private', 'message', '這一場不是包桌');
  end if;
  return jsonb_build_object('ok', true) || v_pkg;
end $function$
;

-- [7.0] pos_queue_members_tx
CREATE OR REPLACE FUNCTION public.pos_queue_members_tx(p_org_id uuid, p_queue uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
      begin
        -- 【身分 2026-09-29】從 API 進來的只有店員能叫；內部呼叫一律接 pos_queue_members_tx_core
        perform public._api_staff_only();
        return public.pos_queue_members_tx_core(p_org_id, p_queue);
      end $function$
;

-- [7.0] pos_queue_members_tx_core
CREATE OR REPLACE FUNCTION public.pos_queue_members_tx_core(p_org_id uuid, p_queue uuid)
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

-- [7.0] pos_quote_tx
CREATE OR REPLACE FUNCTION public.pos_quote_tx(p_session_id uuid, p_member_id uuid, p_join_type text DEFAULT 'opener'::text, p_pay_for uuid[] DEFAULT NULL::uuid[], p_items jsonb DEFAULT NULL::jsonb, p_coupon_ids uuid[] DEFAULT NULL::uuid[])
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
/* 給 POS 結帳頁畫金額用。**不寫入任何東西**。
   模式跟實際結帳走的那一支判斷方式一樣（由資料庫判斷，不採信前端的推測）：
     quick  沒有桌次                 ⇒ 只有購物車
     join   有桌次、這個人還沒入座   ⇒ 檯費那一行（_join_plan）＋ 購物車
     addon  有桌次、已經入座          ⇒ 只有購物車
   金額一律由 _cart_pricing 算 —— checkout_tx 叫的是同一支。
   錯誤一律回 {ok:false, reason, message}，不拋例外：畫面要能把那句話原樣顯示。 */
declare
  v_mode text; v_org uuid; v_items jsonb; v_plan jsonb := null; v_price jsonb; v_s record;
begin
  perform public._api_staff_only();
  if p_member_id is null then
    return jsonb_build_object('ok', false, 'reason', 'member_required', 'message', '請先選擇會員');
  end if;

  if p_session_id is null then
    v_mode := 'quick';
    select org_id into v_org from members where id = p_member_id and deleted_at is null;
    if v_org is null then
      return jsonb_build_object('ok', false, 'reason', 'member_required', 'message', '需先建立會員資料');
    end if;
    v_items := coalesce(p_items, '[]'::jsonb);
  else
    select id, org_id, status into v_s from table_sessions where id = p_session_id and deleted_at is null;
    if v_s.id is null then
      return jsonb_build_object('ok', false, 'reason', 'session_not_found', 'message', '場次不存在');
    end if;
    if exists (select 1 from session_players
                where session_id = p_session_id and member_id = p_member_id and left_at is null) then
      v_mode := 'addon';
      if v_s.status <> 'open' then
        return jsonb_build_object('ok', false, 'reason', 'session_closed', 'mode', v_mode, 'message', '此場次已結束，無法加購');
      end if;
      v_org := v_s.org_id;
      v_items := coalesce(p_items, '[]'::jsonb);
    else
      v_mode := 'join';
      v_plan := public._join_plan(p_session_id, p_member_id, coalesce(p_join_type, 'opener'), p_pay_for, p_items);
      if not coalesce((v_plan ->> 'ok')::boolean, false) then
        return v_plan || jsonb_build_object('mode', v_mode);
      end if;
      v_org := (v_plan ->> 'org_id')::uuid;
      v_items := v_plan -> 'items';
    end if;
  end if;

  begin
    v_price := public._cart_pricing(v_org, p_member_id, v_items, p_coupon_ids);
  exception when others then
    return jsonb_build_object('ok', false, 'reason', 'pricing', 'mode', v_mode, 'message', sqlerrm);
  end;

  return v_price || jsonb_build_object('ok', true, 'mode', v_mode,
    'fee_line', case when v_plan is null then null else jsonb_build_object(
      'product_id', v_plan ->> 'fee_product_id', 'name', v_plan ->> 'fee_name',
      'unit', (v_plan ->> 'unit_fee')::bigint, 'qty', (v_plan ->> 'qty')::int,
      'amount', (v_plan ->> 'amount')::bigint,
      'daypass', (v_plan ->> 'daypass')::boolean, 'daypass_bought', (v_plan ->> 'daypass_bought')::boolean) end);
end $function$
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

-- [7.0] pos_seat_booking_tx
CREATE OR REPLACE FUNCTION public.pos_seat_booking_tx(p_booking_id uuid, p_table_id uuid, p_session_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_staff uuid;
  v_b     record;
  v_label text;
begin
  select staff_id into v_staff from public.current_staff();
  if v_staff is null then
    return jsonb_build_object('ok', false, 'reason', 'not_staff', 'message', '請先登入');
  end if;

  select * into v_b from public.bookings where id = p_booking_id;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'not_found', 'message', '找不到這筆預約');
  end if;
  if v_b.status <> 'booked' then
    return jsonb_build_object('ok', false, 'reason', 'bad_status', 'status', v_b.status,
                              'message', '這筆預約的狀態不能帶到桌');
  end if;

  /* 🔴 那張桌必須是**這間店**的。少了這道，店員在 A 店可以把
     B 店的桌指給這筆預約，而兩邊的桌況都會說謊。 */
  select tb.label into v_label from public.tables tb
   where tb.id = p_table_id and tb.store_id = v_b.store_id
     and tb.is_active and tb.deleted_at is null;
  if v_label is null then
    return jsonb_build_object('ok', false, 'reason', 'bad_table', 'message', '那張桌不屬於這間門市');
  end if;

  update public.bookings
     set status = 'seated', table_id = p_table_id,
         seated_session_id = p_session_id, updated_at = now()
   where id = p_booking_id;

  return jsonb_build_object('ok', true, 'table_label', v_label,
                            'message', '已帶到 ' || v_label);
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
    'members', pos_queue_members_tx_core(p_org_id, p_queue));
end $function$
;

-- [7.0] pos_set_on_duty_tx
CREATE OR REPLACE FUNCTION public.pos_set_on_duty_tx(p_store_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_staff uuid;
begin
  /* 身分從 JWT 取（current_staff），不收前端送的 staff_id —— 前端可填的歸屬比沒有更糟。
     同一個人可能有好幾列 staff（不同門市）：優先用「這間店」那一列；
     沒有的話，老闆／總部那一列（沒有門市）要有全部門市權限才算數。 */
  select cs.staff_id into v_staff
    from public.current_staff() cs
   where cs.store_id = p_store_id
      or (cs.store_id is null and public.can('store.all'))
   order by (cs.store_id = p_store_id) desc nulls last
   limit 1;
  if v_staff is null then
    return jsonb_build_object('ok', false, 'reason', 'not_staff_of_store', 'message', '你不是這間店的店員');
  end if;

  -- 一個人一次只在一間店當班：先把他從別間店拿掉
  update stores set on_duty_staff_id = null, on_duty_since = null
   where on_duty_staff_id in (select cs.staff_id from public.current_staff() cs)
     and id <> p_store_id;

  -- 已經是他就不動時間（POS 每次開機、切回來都會叫，不要讓「當班起點」一直往後跳）
  update stores set on_duty_staff_id = v_staff, on_duty_since = now()
   where id = p_store_id and on_duty_staff_id is distinct from v_staff;

  return jsonb_build_object('ok', true, 'staff_id', v_staff, 'store_id', p_store_id);
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
  -- 【身分 2026-09-29】從 API 進來的只有店員能叫（排程沒有 API 身分，照常）
  perform public._api_staff_only();
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
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
      begin
        -- 【身分 2026-09-29】從 API 進來的只有店員能叫；內部呼叫一律接 pos_table_forecast_tx_core
        perform public._api_staff_only();
        return public.pos_table_forecast_tx_core(p_org, p_store, p_at);
      end $function$
;

-- [7.0] pos_table_forecast_tx_core
CREATE OR REPLACE FUNCTION public.pos_table_forecast_tx_core(p_org uuid, p_store uuid, p_at timestamp with time zone DEFAULT NULL::timestamp with time zone)
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

-- [7.0] pos_tbl_watch_tx
CREATE OR REPLACE FUNCTION public.pos_tbl_watch_tx(p_table_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_store uuid; v_out jsonb;
begin
  /* 只有店員、而且要能看這間店。身分一律問 JWT（current_staff），不收前端傳的身分 */
  if (select staff_id from public.current_staff()) is null then
    return jsonb_build_object('ok', false, 'reason', 'not_staff', 'message', '只有店員可以看平板畫面');
  end if;
  select store_id into v_store from tables where id = p_table_id and deleted_at is null;
  if v_store is null then
    return jsonb_build_object('ok', false, 'reason', 'not_found', 'message', '找不到這張桌');
  end if;
  if not public.has_store_access(v_store) then
    return jsonb_build_object('ok', false, 'reason', 'forbidden', 'message', '你不能看這間店的平板');
  end if;
  /* 每一台還在用的平板，依標籤排（A1-1、A1-2…）；畫面資料跟那台平板自己讀到的是同一份核心 */
  select coalesce(jsonb_agg(jsonb_build_object(
           'device_id', d.id, 'label', d.label, 'last_seen_at', d.last_seen_at,
           'state', public._tbl_state_for_device(d)) order by d.label), '[]'::jsonb)
    into v_out
    from table_devices d
   where d.table_id = p_table_id and d.is_active;
  return jsonb_build_object('ok', true, 'devices', v_out);
end $function$
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

-- [7.0] redeem_team_invite_tx
CREATE OR REPLACE FUNCTION public.redeem_team_invite_tx(p_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_me     uuid := public.current_member_id();
  v_org    uuid := public.current_org_id();
  v_l      record;
  v_t      record;
  v_cnt    int;
  v_leader uuid;
  v_name   text;
begin
  if v_me is null or v_org is null then
    return jsonb_build_object('ok', false, 'reason', 'not_logged_in', 'message', '請先登入');
  end if;

  select l.* into v_l from public.team_invite_links l
   where l.token = p_token and l.org_id = v_org
   for update;                                   -- 兩個人同時點同一條：第二個等第一個做完
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'invalid', 'message', '這條邀請連結不存在，請團長重新傳一次');
  end if;

  select t.id, t.name, t.member_limit into v_t from public.teams t
   where t.id = v_l.team_id and t.deleted_at is null;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'team_gone', 'message', '這個牌咖團已經解散了');
  end if;

  -- 已經在團裡：成功，但**不消耗**連結（包含點了自己發的）
  if exists (select 1 from public.team_members tm
              where tm.team_id = v_t.id and tm.member_id = v_me and tm.left_at is null) then
    return jsonb_build_object('ok', true, 'joined', false, 'already_member', true,
      'team_id', v_t.id, 'team_name', v_t.name, 'message', '你已經在 ' || v_t.name || ' 裡了');
  end if;

  if v_l.used_at is not null then
    return jsonb_build_object('ok', false, 'reason', 'used', 'message', '這條邀請連結已經有人用過了，請團長再傳一次');
  end if;
  if v_l.expires_at <= now() then
    return jsonb_build_object('ok', false, 'reason', 'expired', 'message', '這條邀請連結已經過期了，請團長再傳一次');
  end if;

  select count(*) into v_cnt from public.team_members tm where tm.team_id = v_t.id and tm.left_at is null;
  if v_cnt >= v_t.member_limit then
    return jsonb_build_object('ok', false, 'reason', 'team_full', 'message', v_t.name || ' 滿了');
  end if;
  select count(*) into v_cnt from public.team_members tm
    join public.teams t2 on t2.id = tm.team_id and t2.deleted_at is null
   where tm.member_id = v_me and tm.left_at is null;
  if v_cnt >= 10 then
    return jsonb_build_object('ok', false, 'reason', 'too_many_teams', 'message', '你已經加入 10 個牌咖團了');
  end if;

  insert into public.team_members (org_id, team_id, member_id) values (v_org, v_t.id, v_me);
  update public.team_invite_links set used_by = v_me, used_at = now() where id = v_l.id;
  -- 懸著的邀請／申請一起了結，不要留一筆「等回覆」在通知裡
  update public.team_requests set status = 'accepted', decided_by = v_me, decided_at = now()
   where team_id = v_t.id and member_id = v_me and status = 'pending';

  select tm.member_id into v_leader from public.team_members tm
   where tm.team_id = v_t.id and tm.role = 'leader' and tm.left_at is null;
  select display_name into v_name from public.members where id = v_me;
  if v_leader is not null and v_leader <> v_me then
    perform public._team_notify(v_org, v_leader, 'team_ok', v_name,
             v_name || ' 用邀請連結加入了 ' || v_t.name, v_t.id, v_t.name, null);
  end if;

  return jsonb_build_object('ok', true, 'joined', true, 'team_id', v_t.id, 'team_name', v_t.name,
                            'message', '已加入 ' || v_t.name);
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
  -- 【身分 2026-09-29】只認登入的本人，前端送的 id 一律忽略
  p_member := public.current_member_id();
  if p_member is null then raise exception '未登入或登入已過期，請重新開啟 App' using errcode = '28000'; end if;
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
  -- 【身分 2026-09-29】只認登入的本人，前端送的 id 一律忽略
  p_invitee := public.current_member_id();
  if p_invitee is null then raise exception '未登入或登入已過期，請重新開啟 App' using errcode = '28000'; end if;
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
  -- 【身分 2026-09-29】只認登入的本人，前端送的 id 一律忽略
  p_invitee := public.current_member_id();
  if p_invitee is null then raise exception '未登入或登入已過期，請重新開啟 App' using errcode = '28000'; end if;
  update app_notifications set read_at=now()
   where org_id=p_org_id and member_id=p_invitee and type='table_req'
     and ref_id=p_queue and read_at is null;
  if not p_accept then return 'rejected'; end if;
  return join_match_queue_tx(p_org_id, p_invitee, p_queue, 'invite');
end $function$
;

-- [7.0] respond_team_request_tx
CREATE OR REPLACE FUNCTION public.respond_team_request_tx(p_request_id uuid, p_accept boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_me   uuid := public.current_member_id();
  v_org  uuid := public.current_org_id();
  v_r    record;
  v_t    record;
  v_cnt  int;
  v_lead uuid;
  v_name text;
begin
  if v_me is null or v_org is null then
    return jsonb_build_object('ok', false, 'reason', 'not_logged_in', 'message', '請先登入');
  end if;

  perform public._team_expire_requests(null);

  select r.* into v_r from public.team_requests r where r.id = p_request_id;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'not_found', 'message', '找不到這筆邀請');
  end if;
  if v_r.status <> 'pending' then
    /* ⚠ 話術要說出**它現在是什麼**，不要只說「已處理」——
       客人看到「已過期」與「已被拒絕」要做的事不一樣。 */
    return jsonb_build_object('ok', false, 'reason', 'already_decided', 'status', v_r.status,
                              'message', case v_r.status
                                when 'expired'   then '這筆邀請已經過期了'
                                when 'accepted'  then '這筆已經答應過了'
                                when 'rejected'  then '這筆已經回絕過了'
                                else '這筆已經處理過了' end);
  end if;

  select t.id, t.name, t.member_limit into v_t
    from public.teams t where t.id = v_r.team_id and t.deleted_at is null;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'team_gone', 'message', '這個團已經解散了');
  end if;

  if v_r.kind = 'apply' then
    if not exists (select 1 from public.team_members tm
                    where tm.team_id = v_r.team_id and tm.member_id = v_me
                      and tm.left_at is null and tm.role = 'leader') then
      return jsonb_build_object('ok', false, 'reason', 'not_leader', 'message', '只有團長可以審核');
    end if;
  else
    if v_r.member_id <> v_me then
      return jsonb_build_object('ok', false, 'reason', 'not_yours', 'message', '這不是給你的邀請');
    end if;
  end if;

  if not p_accept then
    update public.team_requests set status = 'rejected', decided_by = v_me, decided_at = now()
     where id = p_request_id;
    /* 🔴 刻意不發通知，理由見檔頭。 */
    return jsonb_build_object('ok', true, 'accepted', false, 'message', '已回絕');
  end if;

  if exists (select 1 from public.team_members tm
              where tm.team_id = v_r.team_id and tm.member_id = v_r.member_id and tm.left_at is null) then
    update public.team_requests set status = 'accepted', decided_by = v_me, decided_at = now()
     where id = p_request_id;
    return jsonb_build_object('ok', true, 'accepted', true, 'message', '他已經在團裡了');
  end if;

  select count(*) into v_cnt from public.team_members tm
   where tm.team_id = v_r.team_id and tm.left_at is null;
  if v_cnt >= v_t.member_limit then
    return jsonb_build_object('ok', false, 'reason', 'team_full', 'message', '這個團滿了');
  end if;

  select count(*) into v_cnt from public.team_members tm
    join public.teams t2 on t2.id = tm.team_id and t2.deleted_at is null
   where tm.member_id = v_r.member_id and tm.left_at is null;
  if v_cnt >= 10 then
    return jsonb_build_object('ok', false, 'reason', 'too_many_teams',
                              'message', '他已經加入 10 個牌咖團了');
  end if;

  update public.team_requests set status = 'accepted', decided_by = v_me, decided_at = now()
   where id = p_request_id;
  insert into public.team_members (org_id, team_id, member_id)
  values (v_org, v_r.team_id, v_r.member_id);

  /* 通知方向與 `kind` 相反：團長核准 → 通知申請人；本人答應邀請 → 通知團長。 */
  if v_r.kind = 'apply' then
    perform public._team_notify(v_org, v_r.member_id, 'team_ok', v_t.name,
             '你的申請通過了，歡迎加入 ' || v_t.name, v_t.id, v_t.name, null);
  else
    select tm.member_id into v_lead from public.team_members tm
     where tm.team_id = v_t.id and tm.role = 'leader' and tm.left_at is null;
    select display_name into v_name from public.members where id = v_r.member_id;
    if v_lead is not null then
      perform public._team_notify(v_org, v_lead, 'team_ok', v_name,
               v_name || ' 加入了 ' || v_t.name, v_t.id, v_t.name, null);
    end if;
  end if;

  return jsonb_build_object('ok', true, 'accepted', true, 'message', '已加入 ' || v_t.name);
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

-- [7.0] revoke_table_device_tx
CREATE OR REPLACE FUNCTION public.revoke_table_device_tx(p_device_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_staff uuid; v_store uuid;
begin
  v_staff := (select staff_id from public.current_staff());
  if v_staff is null then
    return jsonb_build_object('ok', false, 'reason', 'not_staff', 'message', '請先登入');
  end if;
  -- 配對與停用都是總部的事（2026-09-25 使用者拍板：POS 不管平板）
  if not public.can('device.write') then
    return jsonb_build_object('ok', false, 'reason', 'forbidden', 'message', '停用平板要請總部在後台處理');
  end if;
  select store_id into v_store from table_devices where id = p_device_id;
  if v_store is null then
    return jsonb_build_object('ok', false, 'reason', 'not_found', 'message', '找不到這台平板');
  end if;
  update table_devices set is_active = false, revoked_at = now(), revoked_by_staff_id = v_staff
   where id = p_device_id and is_active;
  -- 停用的平板手上還綁著人的話一起放掉
  update session_players set device_id = null where device_id = p_device_id;
  return jsonb_build_object('ok', true);
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
  /* 🔴 身分一律從 JWT 取，不採信呼叫端（2026-09-05，待辦 14）。 */
  p_member_id := public.current_member_id();
  if p_member_id is null then raise exception '未登入或登入已過期，請重新開啟 App' using errcode = '28000'; end if;
  if pg_column_size(p_bear) > 8192 then raise exception 'bear state 過大'; end if;

  /* 🔴 2026-09-19：`snacks` 一律忽略 —— 點心是獎勵，來源只有發放／消耗那兩支。
     🔴 2026-09-22：**稱號參數一律忽略**（待辦 40）。
       稱號是成就不是偏好，由 _member_titles 從事實算出來；
       這支只存小熊（他自己的選擇）。參數留在簽名裡只是為了舊版前端不 404。 */
  insert into member_app_state(member_id, org_id, bear, titles, updated_at)
  values (p_member_id, p_org_id, coalesce(p_bear, '{}'::jsonb) - 'snacks', '[]'::jsonb, now())
  on conflict (member_id) do update set
    bear = (coalesce(excluded.bear, '{}'::jsonb) - 'snacks')
           || jsonb_build_object('snacks', coalesce(member_app_state.bear -> 'snacks', '{}'::jsonb)),
    updated_at = now();
end $function$
;

-- [7.0] search_teams_tx
CREATE OR REPLACE FUNCTION public.search_teams_tx(p_q text DEFAULT NULL::text, p_limit integer DEFAULT 20)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_me    uuid := public.current_member_id();
  v_org   uuid := public.current_org_id();
  v_store uuid;
  v_name  text;
  v_q     text := nullif(btrim(coalesce(p_q, '')), '');
  v_rows  jsonb;
begin
  if v_me is null or v_org is null then
    return jsonb_build_object('ok', false, 'reason', 'not_logged_in', 'message', '請先登入');
  end if;

  /* 🔴 「常去」有門檻，答不出來就回 null —— 畫面那一行整個不畫。
     在此之前這裡是「依場次數遞減取第一名」，也就是**去過一次也算常去**。
     ⚠ 這段說明**刻意不寫出那個舊寫法的字面**（硬規則 3.5）——
       驗證段要掃「舊寫法還在不在」，而 `pg_get_functiondef` 回的是
       含註解的全文，寫出來會讓那一格**永遠是紅的**，
       而一個永遠紅的檢查會讓人學會忽略紅色。 */
  v_store := public._member_home_store(v_me);
  select s.name into v_name from public.stores s where s.id = v_store;

  select coalesce(jsonb_agg(card order by ord, cnt desc, nm), '[]'::jsonb)
    into v_rows
    from (
      select public._team_card(t.id) as card,
             case when v_store is not null and t.home_store_id = v_store then 0 else 1 end as ord,
             (select count(*) from public.team_members tm
               where tm.team_id = t.id and tm.left_at is null) as cnt,
             t.name as nm
        from public.teams t
       where t.org_id = v_org
         and t.deleted_at is null
         and t.join_policy <> 'closed'
         and not exists (select 1 from public.team_members tm
                          where tm.team_id = t.id and tm.member_id = v_me and tm.left_at is null)
         and (v_q is null or t.name ilike '%' || v_q || '%')
       limit greatest(1, least(coalesce(p_limit, 20), 50))
    ) s;

  return jsonb_build_object('ok', true, 'teams', v_rows,
                            'q', v_q,
                            'recommend_store_id',   case when v_q is null then v_store end,
                            'recommend_store_name', case when v_q is null then v_name end);
end $function$
;

-- [7.0] season_rank_rows_display_tx
CREATE OR REPLACE FUNCTION public.season_rank_rows_display_tx(p_org_id uuid, p_from timestamp with time zone, p_to timestamp with time zone DEFAULT NULL::timestamp with time zone)
 RETURNS TABLE(member_id uuid, rating integer, rank_no integer, games integer)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  /* 排行榜與成績頁「全國排名」用。**只用在「看」，不可以拿去結算。**
     上線前（live_from 未設或未到）連測試帳號一起排，讓畫面有東西可以看；
     上線那一刻自動變回只排真客人。 */
  select * from public._season_rank_rows_core(
    p_org_id, p_from, p_to,
    not exists (select 1 from orgs o where o.id = p_org_id
                 and o.live_from is not null and now() >= o.live_from))
$function$
;

-- [7.0] season_rank_rows_tx
CREATE OR REPLACE FUNCTION public.season_rank_rows_tx(p_org_id uuid, p_from timestamp with time zone, p_to timestamp with time zone DEFAULT NULL::timestamp with time zone)
 RETURNS TABLE(member_id uuid, rating integer, rank_no integer, games integer)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  /* 🔴 **結算用：永遠排除測試帳號**（2026-09-23 起規則搬到 _season_rank_rows_core）。
     reset_season_ratings_tx 用它決定賽季冠軍，而冠軍稱號是永久的 ——
     這裡**不可以**跟著「上線前顯示測試帳號」一起放寬。 */
  select * from public._season_rank_rows_core(p_org_id, p_from, p_to, false)
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
  -- 【身分 2026-09-29】只認登入的本人，前端送的 id 一律忽略
  p_inviter := public.current_member_id();
  if p_inviter is null then raise exception '未登入或登入已過期，請重新開啟 App' using errcode = '28000'; end if;
  if p_inviter = p_invitee then raise exception '不能加自己'; end if;
  /* 🆕 2026-09-25：隱藏中的會員收不到邀請（他打不開 App，邀請只會一直掛著） */
  if exists (select 1 from members where id = p_invitee and hidden_at is not null) then
    raise exception '這位會員目前無法加為牌咖';
  end if;
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
  -- 【身分 2026-09-29】只認登入的本人，前端送的 id 一律忽略
  p_inviter := public.current_member_id();
  if p_inviter is null then raise exception '未登入或登入已過期，請重新開啟 App' using errcode = '28000'; end if;
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
  p_member_id := public.current_member_id();
  if p_member_id is null then raise exception '未登入或登入已過期，請重新開啟 App' using errcode = '28000'; end if;
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
    /* 段位熊與雀神熊要已解鎖才能選（曾經升到過就永久保留，2026-09-30）。
       ⚠ 只管 rank_tiers 裡的那幾隻與雀神熊；其他造型鍵照舊不擋（見上面「只擋長度」那段）。 */
    if v_bear is not null
       and (v_bear = 'quegod' or exists (select 1 from public.rank_tiers t where t.code = v_bear))
       and not (v_bear = any (public._member_bear_unlocks(p_member_id))) then
      return jsonb_build_object('ok', false, 'reason', 'bear_locked',
        'message', '這隻小熊還沒解鎖');
    end if;
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
  p_member_id := public.current_member_id();
  if p_member_id is null then raise exception '未登入或登入已過期，請重新開啟 App' using errcode = '28000'; end if;
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
  p_member_id := public.current_member_id();
  if p_member_id is null then raise exception '未登入或登入已過期，請重新開啟 App' using errcode = '28000'; end if;
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
  p_member_id := public.current_member_id();
  if p_member_id is null then raise exception '未登入或登入已過期，請重新開啟 App' using errcode = '28000'; end if;
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
  p_member_id := public.current_member_id();
  if p_member_id is null then raise exception '未登入或登入已過期，請重新開啟 App' using errcode = '28000'; end if;
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
  p_member_id := public.current_member_id();
  if p_member_id is null then raise exception '未登入或登入已過期，請重新開啟 App' using errcode = '28000'; end if;
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
  p_member_id := public.current_member_id();
  if p_member_id is null then raise exception '未登入或登入已過期，請重新開啟 App' using errcode = '28000'; end if;
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
  p_member_id := public.current_member_id();
  if p_member_id is null then raise exception '未登入或登入已過期，請重新開啟 App' using errcode = '28000'; end if;
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
  p_member_id := public.current_member_id();
  if p_member_id is null then raise exception '未登入或登入已過期，請重新開啟 App' using errcode = '28000'; end if;
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
  /* 身分一律從 JWT 取，不採信呼叫端（待辦 14）。 */
  p_member_id := public.current_member_id();
  if p_member_id is null then raise exception '未登入或登入已過期，請重新開啟 App' using errcode = '28000'; end if;
  /* 2026-09-30 起只有兩個選項。舊版前端還可能送「所有人」⇒ 視同「牌咖」，不讓它報錯
     （成績本來就只給牌咖看，「所有人」已經沒有意義）。 */
  if p_see_score = '所有人' then p_see_score := '牌咖'; end if;
  if p_see_score not in ('牌咖','只有自己') then raise exception '成績公開範圍格式錯誤'; end if;
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
  p_member_id := public.current_member_id();
  if p_member_id is null then raise exception '未登入或登入已過期，請重新開啟 App' using errcode = '28000'; end if;
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
  /* 🔴 身分一律從 JWT 取，不採信呼叫端（2026-09-05，待辦 14）。 */
  p_member_id := public.current_member_id();
  if p_member_id is null then raise exception '未登入或登入已過期，請重新開啟 App' using errcode = '28000'; end if;
  /* 2026-09-22：擁有與否改問 _member_titles（事實算出來的），
     不再問前端寫進去的那份清單。「新手上路」也在那支裡面，不必另外放行。 */
  if not exists (select 1 from public._member_titles(p_member_id) t where t.title = p_title) then
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
  -- 【身分 2026-09-29】從 API 進來的只有店員能叫（排程沒有 API 身分，照常）
  perform public._api_staff_only();
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
  -- 【身分 2026-09-29】從 API 進來的只有店員能叫（排程沒有 API 身分，照常）
  perform public._api_staff_only();
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

-- [7.0] set_team_co_leader_tx
CREATE OR REPLACE FUNCTION public.set_team_co_leader_tx(p_team_id uuid, p_member_id uuid, p_on boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_me   uuid := public.current_member_id();
  v_org  uuid := public.current_org_id();
  v_role text;
  v_tname text;
  v_name text;
  v_n    int;
begin
  if v_me is null or v_org is null then
    return jsonb_build_object('ok', false, 'reason', 'not_logged_in', 'message', '請先登入');
  end if;
  if p_member_id is null or p_member_id = v_me then
    return jsonb_build_object('ok', false, 'reason', 'bad_target', 'message', '對象不正確');
  end if;

  /* 🔴 只有團長。副團長**不能**再任命副團長 ——
     那會讓「誰能給權限」有第二個答案，而收回權限的人只有一個。 */
  if not exists (select 1 from public.team_members tm
                  where tm.team_id = p_team_id and tm.member_id = v_me
                    and tm.left_at is null and tm.role = 'leader') then
    return jsonb_build_object('ok', false, 'reason', 'not_leader', 'message', '只有團長可以設定副團長');
  end if;

  select t.name into v_tname from public.teams t
   where t.id = p_team_id and t.deleted_at is null;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'not_found', 'message', '找不到這個牌咖團');
  end if;

  select tm.role into v_role from public.team_members tm
   where tm.team_id = p_team_id and tm.member_id = p_member_id and tm.left_at is null;
  if v_role is null then
    return jsonb_build_object('ok', false, 'reason', 'not_member', 'message', '他不在這個團裡');
  end if;
  /* 防守性的一格：呼叫者是團長而對象不是自己 ⇒ 走不到這裡
     （`uq_team_one_leader` 保證一團一個團長）。留著是因為那道索引
     哪天被改掉時，這裡要**大聲拒絕**而不是把團長降成副團長。 */
  if v_role = 'leader' then
    return jsonb_build_object('ok', false, 'reason', 'is_leader', 'message', '他是團長');
  end if;

  /* 冪等：已經是了就直接回成功，不要報錯。
     ⚠ 團長連按兩下、或兩台裝置各按一次都會走到這裡。 */
  if (p_on and v_role = 'co_leader') or (not p_on and v_role = 'member') then
    return jsonb_build_object('ok', true, 'changed', false, 'role', v_role,
                              'message', case when p_on then '他已經是副團長了' else '他本來就不是副團長' end);
  end if;

  update public.team_members
     set role = case when p_on then 'co_leader' else 'member' end
   where team_id = p_team_id and member_id = p_member_id and left_at is null;
  get diagnostics v_n = row_count;
  /* 🔴 `update … where` 之後一定要看有沒有真的改到 ——
     `register_member_tx` 就是漏了這一步而謊報成功過一次。 */
  if v_n = 0 then
    return jsonb_build_object('ok', false, 'reason', 'not_member', 'message', '他不在這個團裡');
  end if;

  /* 通知本人。升上去要講**他現在能做什麼**，不然他不會知道多了什麼。
     ⚠ 用既有的 `team_ok`（純告知、沒有按鈕），不要為此發明新的通知類型。 */
  select display_name into v_name from public.members where id = v_me;
  perform public._team_notify(v_org, p_member_id, 'team_ok', v_tname,
           case when p_on
                then '你成為 ' || v_tname || ' 的副團長了，可以邀請牌咖加入'
                else '你不再是 ' || v_tname || ' 的副團長了' end,
           p_team_id, v_tname, null);

  return jsonb_build_object('ok', true, 'changed', true,
                            'role', case when p_on then 'co_leader' else 'member' end,
                            'message', case when p_on then '已升為副團長' else '已取消副團長' end);
end $function$
;

-- [7.0] set_team_crest_source_tx
CREATE OR REPLACE FUNCTION public.set_team_crest_source_tx(p_team_id uuid, p_source text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_me   uuid := public.current_member_id();
  v_path text;
  v_blk  boolean;
begin
  /* 身分一律從 JWT 解析，不收 p_member_id（CLAUDE.md 待辦 14 的通則）。 */
  if v_me is null then
    return jsonb_build_object('ok', false, 'reason', 'not_logged_in', 'message', '請先登入');
  end if;
  if p_source is null or p_source not in ('default', 'photo') then
    return jsonb_build_object('ok', false, 'reason', 'bad_source', 'message', '團徽選項不正確');
  end if;
  if not public._is_team_leader(p_team_id, v_me) then
    return jsonb_build_object('ok', false, 'reason', 'not_leader', 'message', '只有團長可以換團徽');
  end if;

  select t.crest_path, t.crest_blocked into v_path, v_blk
    from public.teams t where t.id = p_team_id and t.deleted_at is null;
  if v_blk is null then
    return jsonb_build_object('ok', false, 'reason', 'not_found', 'message', '找不到這個牌咖團');
  end if;

  /* 選照片要**真的有一張**，而且沒被總部停用 ——
     否則會切到一個畫不出來的狀態（卡片退回預設，而抽屜顯示選了照片）。 */
  if p_source = 'photo' and v_path is null then
    return jsonb_build_object('ok', false, 'reason', 'no_photo', 'message', '還沒有上傳照片');
  end if;
  if p_source = 'photo' and v_blk then
    return jsonb_build_object('ok', false, 'reason', 'crest_blocked',
                              'message', '這個團的自訂團徽已停用');
  end if;

  update public.teams
     set crest_source = p_source, updated_at = now()
   where id = p_team_id and deleted_at is null;

  return jsonb_build_object('ok', true, 'team', public._team_card(p_team_id));
end $function$
;

-- [7.0] set_team_crest_tx
CREATE OR REPLACE FUNCTION public.set_team_crest_tx(p_team_id uuid, p_emoji text DEFAULT NULL::text, p_path text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_me    uuid := public.current_member_id();
  v_emoji text := nullif(btrim(coalesce(p_emoji, '')), '');
  v_path  text := nullif(btrim(coalesce(p_path,  '')), '');
  v_blk   boolean;
begin
  if v_me is null then
    return jsonb_build_object('ok', false, 'reason', 'not_logged_in', 'message', '請先登入');
  end if;
  if not public._is_team_leader(p_team_id, v_me) then
    return jsonb_build_object('ok', false, 'reason', 'not_leader', 'message', '只有團長可以換團徽');
  end if;

  if v_emoji is not null and char_length(v_emoji) > 8 then
    return jsonb_build_object('ok', false, 'reason', 'bad_emoji', 'message', '團徽圖示太長了');
  end if;

  select t.crest_blocked into v_blk from public.teams t
   where t.id = p_team_id and t.deleted_at is null;
  if v_blk is null then
    return jsonb_build_object('ok', false, 'reason', 'not_found', 'message', '找不到這個牌咖團');
  end if;
  if v_blk and v_path is not null then
    return jsonb_build_object('ok', false, 'reason', 'crest_blocked',
                              'message', '這個團的自訂團徽已停用，請改用圖示');
  end if;

  /* 🔴 路徑一定要**在這個團自己的資料夾底下**。
     少了這一道，前端可以送別的團的路徑進來
     ⇒ 「換自己的團徽」變成「把別人的圖掛到自己團上」，
     而且它不會報錯。Edge Function 產的路徑本來就是 `{team_id}/…`，
     所以這道牆對正常流程完全沒有感覺。 */
  if v_path is not null and v_path not like (p_team_id::text || '/%') then
    return jsonb_build_object('ok', false, 'reason', 'bad_path', 'message', '團徽路徑不正確');
  end if;

  update public.teams
     set crest_path  = case when v_emoji is not null then null else v_path end,
         crest_emoji = coalesce(v_emoji, crest_emoji),
         updated_at  = now()
   where id = p_team_id and deleted_at is null;

  return jsonb_build_object('ok', true, 'team', public._team_card(p_team_id));
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
  v_s        record;
  v_total    bigint;
  v_left     int;
  v_booking  boolean := false;   -- 🆕 這一場是不是來自一張包桌預約
  v_p        record;             -- 🆕 發成就事件用
  v_idem     text;  v_score    jsonb;   -- 🆕 2026-09-23 電子計分
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
    -- 🎯 成就事件**不在這條路重發**：`fire_event_tx` 本身對 specific 型
    --   是冪等的（已解鎖回 already），但累積型會被多加一次。
    --   而「已經收好了」本來就不該是第二次收桌。
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

  update session_players set device_id = null   /* 🆕 2026-09-29 放掉平板：從結算搬到收桌 */
   where session_id = p_session_id and device_id is not null;
  update table_sessions
     set closed_by_staff_id = p_staff_id,   /* 🆕 誰收的桌（獎金依據）；冪等那條路在前面就 return，第一次按的人為準 */
         status = 'completed',
         ended_at   = now(),
         fee_points = v_total,
         updated_at = now(),
         updated_by = coalesce(p_staff_id, updated_by)
   where id = p_session_id;

  /* ⏳ 電子計分之前先給隨機名次（2026-09-06）。
     🔴 `orgs.live_from` 一到，`placeholder_ranks_tx` 自己會回
       `already_live` 什麼都不做 —— **不需要有人記得移除這一段**。
     ⚠ 失敗一律吞掉：收桌不可以因為名次而回滾。
     🔴 **成就事件一定要排在這之後** —— `session_won` 看的是
       `final_score`，而那一欄就是這一步寫的。 */
  begin
    /* 🆕 2026-09-23：有電子計分就用真的分數；沒有（no_hands）才用隨機名次。 */
    /* 🆕 2026-09-29 成績在最後一將打完時就結算過了（trg_session_rounds_auto_score）⇒ 已經有名次就不再算
       （段位分算兩次會重複加）；沒打完約定將數就收桌的，仍然在這裡補算 */
    if public._session_scored(p_session_id) then
      v_score := jsonb_build_object('ok', true, 'already_scored', true);
    else
      v_score := public._score_settle_tx(p_session_id);
    end if;
    if not coalesce((v_score ->> 'ok')::boolean, false) then
      perform public.placeholder_ranks_tx(p_session_id);
    end if;
  exception when others then null;
  end;

  /* 🆕 2026-09-19：結算通知。
     🔴 在此之前**沒有任何地方寫過 `settle`**（CHECK 允許但 0 筆）
       ⇒ 收桌結算那一頁的唯一入口從來沒有出現過。
     ⚠ 一人一則，對象是真的坐過的人；`ref_id` 給前端拿去叫 `get_game_tx`。
     ⚠ payload 帶門市與積分，讓通知列不必自己猜
       （前端在此之前是寫死的 'MIGI 高雄自由店' / '50/20'）。
     ⚠ 整段吞例外：桌已經收了，通知失敗不可以回滾收桌。 */
  begin
    insert into app_notifications (org_id, member_id, type, payload, ref_id)
    select v_s.org_id, sp.member_id, 'settle',
           jsonb_build_object(
             'text',       '牌局結算完成',
             'session_id', p_session_id,
             'store',      st.name,
             'stake',      sl.label,
             'at',         coalesce(v_s.activated_at, v_s.started_at)),
           p_session_id
      from session_players sp
      left join stores       st on st.id = v_s.store_id        and st.org_id = v_s.org_id
      left join stake_levels sl on sl.id = v_s.stake_level_id  and sl.org_id = v_s.org_id
     where sp.session_id = p_session_id
       and sp.org_id     = v_s.org_id
       and sp.member_id is not null;
  exception when others then null;
  end;

  /* 🆕 2026-10-01：一將都沒打完就不發成就（成績不算 ⇒「完成一場牌局」也不算）。
     判準沿用唯一的定義 _session_scored()；下面兩段成就到「收完保留給現場」之前都包在這個 if 裡 */
  if public._session_scored(p_session_id) then
  /* 🆕 2026-09-20：成就事件（第 ③ 步）。
     📄 契約見《成就事件對照表_階段1》§1。
     ⚠ 整段吞例外，理由同上面兩塊：**桌已經收了，成就失敗不可以回滾收桌**。
     ⚠ 冪等鍵用 `settle:<session_id>` —— `fire_event_tx` 會再串上事件名與
       成就代碼，所以同一場不會把同一枚重複計。 */
  begin
    v_idem := 'settle:' || p_session_id::text;

    -- 包桌的關聯是**反方向**的：場次那一側沒有任何 booking 欄位
    select exists (select 1 from bookings b
                    where b.seated_session_id = p_session_id) into v_booking;

    for v_p in
      select sp.member_id, sp.final_score
        from session_players sp
       where sp.session_id = p_session_id
         and sp.member_id is not null
    loop
      perform public.fire_event_tx(v_p.member_id, 'session_finished', 1, null, v_idem);

      -- 🔴 「贏」看**桌上積分的正負**，不是名次（CLAUDE.md 拍板）——
      --   第 2 名照樣可能是負的，而定位賽四個人的得點全是正的。
      -- ⚠ 純娛樂的 final_score 是 **null 不是 0** ⇒ 不算贏也不算輸。
      if coalesce(v_p.final_score, 0) > 0 then
        perform public.fire_event_tx(v_p.member_id, 'session_won', 1, null, v_idem);
      end if;

      if v_s.mode = 'matched' then
        perform public.fire_event_tx(v_p.member_id, 'queue_session_done', 1, null, v_idem);
      end if;

      if v_booking then
        perform public.fire_event_tx(v_p.member_id, 'booking_session_done', 1, null, v_idem);
      end if;
    end loop;
  exception when others then null;
  end;

  /* 🆕 2026-09-30：成就第 2 批（牌局／局勢轉折／同桌／單場段位分）的判定。
     ⚠ 失敗不回滾收桌，但**不安靜吞掉**：寫一筆 ach_error 埋點，錯誤儀表看得到。 */
  begin
    perform public._ach_session_events(p_session_id);
  exception when others then
    begin
      perform public.log_app_event_tx(v_s.org_id, null, 'ach_error',
        jsonb_build_object('where', '_ach_session_events', 'session_id', p_session_id,
                           'code', sqlstate, 'message', left(sqlerrm, 300)),
        now(), v_s.store_id);
    exception when others then null;
    end;
  end;

  end if;   /* ↑ 2026-10-01：成就那兩段只在有名次時才跑 */

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
  -- 【身分 2026-09-29】從 API 進來的只有店員能叫（排程沒有 API 身分，照常）
  perform public._api_staff_only();
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
    v_res := _try_auto_seat_tx_core(p_org, r.id, null);
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

-- [7.0] sweep_season_close_tx
CREATE OR REPLACE FUNCTION public.sweep_season_close_tx()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_s record; v_res jsonb; v_out jsonb := '[]'::jsonb; v_next text; v_ach jsonb;
begin
  for v_s in
    select rs.org_id, rs.code, rs.ends_at
      from rank_seasons rs
     where rs.ends_at <= now()
       and not exists (select 1 from season_champions c where c.org_id = rs.org_id and c.season = rs.code)
     order by rs.ends_at
  loop
    begin
      v_res := public.reset_season_ratings_tx(v_s.org_id, v_s.code);
      if not coalesce((v_res ->> 'ok')::boolean, false) then
        raise exception 'reset_season_ratings_tx 回 %', v_res;
      end if;

      -- 下一季的起點 ＝ 剛降完階的段位分
      select rs2.code into v_next from rank_seasons rs2
       where rs2.org_id = v_s.org_id and rs2.starts_at >= v_s.ends_at
       order by rs2.starts_at limit 1;
      if v_next is not null then
        insert into season_start_ratings (org_id, season, member_id, rating)
        select m.org_id, v_next, m.id, m.rating
          from members m
         where m.org_id = v_s.org_id and m.deleted_at is null and m.rank is not null
        on conflict do nothing;
      end if;

      -- 成就失敗不影響結算（結算已經做完、不可重來）
      begin
        v_ach := public._ach_season_close_events(v_s.org_id, v_s.code);
      exception when others then
        v_ach := jsonb_build_object('ok', false, 'code', sqlstate, 'message', left(sqlerrm, 300));
        begin
          perform public.log_app_event_tx(v_s.org_id, null, 'ach_error',
            jsonb_build_object('where', '_ach_season_close_events', 'season', v_s.code,
                               'code', sqlstate, 'message', left(sqlerrm, 300)), now(), null);
        exception when others then null;
        end;
      end;

      v_out := v_out || jsonb_build_array(jsonb_build_object(
        'season', v_s.code, 'result', v_res, 'next_season', v_next, 'achievements', v_ach));
    exception when others then
      -- 這一季整個退回（沒有記冠軍 ⇒ 下一輪會再試），而且要讓人看得到
      v_out := v_out || jsonb_build_array(jsonb_build_object('season', v_s.code, 'error', left(sqlerrm, 300)));
      begin
        perform public.log_app_event_tx(v_s.org_id, null, 'season_close_error',
          jsonb_build_object('season', v_s.code, 'code', sqlstate, 'message', left(sqlerrm, 300)), now(), null);
      exception when others then null;
      end;
    end;
  end loop;
  return jsonb_build_object('ok', true, 'closed', v_out);
end $function$
;

-- [7.0] sweep_team_leaders_tx
CREATE OR REPLACE FUNCTION public.sweep_team_leaders_tx(p_org_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  r        record;
  v_new    uuid;
  v_why    text;
  v_n      int := 0;
  v_names  text[] := '{}';
  v_newnm  text;
begin
  for r in
    select t.id as team_id, t.name as team_name, t.org_id, tm.member_id as lead_id
      from public.teams t
      join public.team_members tm
        on tm.team_id = t.id and tm.role = 'leader' and tm.left_at is null
     where t.deleted_at is null
       and (p_org_id is null or t.org_id = p_org_id)
  loop
    /* 候選人先算出來，再拿他去問判準 ——
       判準會自己檢查「是不是他」「團長是不是真的失聯」。
       ⇒ 自動與手動走的是同一個檢查，不會有兩套結論。 */
    v_new := public._team_top_contributor(r.team_id, r.lead_id);
    if v_new is null then continue; end if;          -- 團裡只有團長一個人

    v_why := public._team_claim_check(r.team_id, v_new);
    if v_why is not null then continue; end if;      -- 團長還活著，或其他理由

    update public.team_members set role = 'member'
     where team_id = r.team_id and member_id = r.lead_id and left_at is null;
    update public.team_members set role = 'leader'
     where team_id = r.team_id and member_id = v_new and left_at is null;

    select display_name into v_newnm from public.members where id = v_new;

    /* 兩邊都要通知。舊團長那一則不是禮貌，是**他有權知道自己被換掉了** ——
       而且那可能正好把他叫回來。 */
    perform public._team_notify(r.org_id, v_new, 'team_ok', r.team_name,
             '團長很久沒出現，你已接任 ' || r.team_name || ' 的團長',
             r.team_id, r.team_name, null);
    perform public._team_notify(r.org_id, r.lead_id, 'team_ok', r.team_name,
             '你在 ' || r.team_name || ' 的團長已由 ' || coalesce(v_newnm, '團員') || ' 接任',
             r.team_id, r.team_name, null);

    v_n := v_n + 1;
    v_names := v_names || r.team_name;
  end loop;

  return jsonb_build_object('ok', true, 'changed', v_n, 'teams', to_jsonb(v_names));
end $function$
;

-- [7.0] tbl_bust_decide_tx
CREATE OR REPLACE FUNCTION public.tbl_bust_decide_tx(p_token text, p_amount integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  d public.table_devices; s public.table_sessions; v_me smallint; b public.session_busts;
begin
  d := public._tbl_device(p_token);
  select * into s from public.table_sessions
   where table_id = d.table_id and status = 'open' and deleted_at is null;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'no_session', 'message', '這桌還沒開桌');
  end if;
  select seat into v_me from public.session_players
   where session_id = s.id and device_id = d.id and left_at is null;
  if public._session_scored(s.id) then
    return jsonb_build_object('ok', false, 'reason', 'scored', 'message', '這場的成績已經結算');
  end if;

  select * into b from public.session_busts
   where session_id = s.id and decision = 'pending'
   order by seat limit 1 for update;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'no_bust', 'message', '現在沒有人爆卡');
  end if;
  if v_me is null or b.seat <> v_me then
    return jsonb_build_object('ok', false, 'reason', 'not_yours', 'message', '只有爆卡的人可以決定');
  end if;

  if coalesce(p_amount, 0) > 0 then
    if p_amount > 9999999 then
      return jsonb_build_object('ok', false, 'reason', 'bad_amount', 'message', '追加的積分太多了');
    end if;
    update public.session_busts
       set decision = 'added', added_points = p_amount, decided_at = now()
     where id = b.id;
    perform public._tbl_ping(s.id);
    return jsonb_build_object('ok', true, 'added', p_amount);
  end if;

  -- 不追加 ⇒ 整場結束
  update public.session_busts set decision = 'ended', decided_at = now() where id = b.id;
  update public.session_busts set decision = 'voided', decided_at = now()   -- 同一局一起歸零的其他人不用再決定
   where session_id = s.id and decision = 'pending';
  update public.session_rounds set status = 'finished', finished_at = now()
   where session_id = s.id and status = 'playing';
  -- 結算成績：規則同「打完自動結算」（約定 2 將以上才算；已經算過就不算）
  if coalesce(s.planned_rounds, 0) >= 2 and not public._session_scored(s.id) then
    begin
      perform public._score_settle_tx(s.id);
    exception when others then null;   -- 不可以讓結算失敗把「結束」一起回滾；收桌會補算
    end;
  end if;
  perform public._tbl_ping(s.id);
  return jsonb_build_object('ok', true, 'ended', true);
end $function$
;

-- [7.0] tbl_cancel_pending_tx
CREATE OR REPLACE FUNCTION public.tbl_cancel_pending_tx(p_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare d public.table_devices; v_session uuid; v_me smallint; v_n int;
begin
  d := public._tbl_device(p_token);
  select id into v_session from table_sessions
   where table_id = d.table_id and status = 'open' and deleted_at is null;
  select seat into v_me from session_players
   where session_id = v_session and device_id = d.id and left_at is null;
  update hands set status = 'undone', undone_at = now()
   where session_id = v_session and status = 'pending' and submitted_seat = v_me;
  get diagnostics v_n = row_count;
  if v_n = 0 then
    return jsonb_build_object('ok', false, 'reason', 'nothing', 'message', '沒有你送出、還在等確認的那一把');
  end if;
  perform public._tbl_ping(v_session);
  return jsonb_build_object('ok', true);
end $function$
;

-- [7.0] tbl_claim_seat_tx
CREATE OR REPLACE FUNCTION public.tbl_claim_seat_tx(p_token text, p_player_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare d public.table_devices; v_session uuid; v_owner uuid;
begin
  d := public._tbl_device(p_token);
  select id into v_session from table_sessions
   where table_id = d.table_id and status = 'open' and deleted_at is null;
  if v_session is null then
    return jsonb_build_object('ok', false, 'reason', 'no_session', 'message', '這桌還沒開桌');
  end if;

  select device_id into v_owner from session_players
   where id = p_player_id and session_id = v_session and left_at is null;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'not_in_session', 'message', '這個人不在這一桌');
  end if;
  if v_owner is not null and v_owner <> d.id then
    return jsonb_build_object('ok', false, 'reason', 'taken', 'message', '這個人已經在另一台平板上了');
  end if;

  -- 這台平板原本綁的是別人 ⇒ 先放掉
  update session_players set device_id = null
   where session_id = v_session and device_id = d.id and id <> p_player_id;
  begin
    update session_players set device_id = d.id where id = p_player_id;
  exception when unique_violation then
    -- 兩台同時按同一個人：資料庫擋下晚到的那一台
    return jsonb_build_object('ok', false, 'reason', 'taken', 'message', '這個人剛剛被另一台平板選走了');
  end;

  perform public._tbl_ping(v_session);
  return jsonb_build_object('ok', true);
end $function$
;

-- [7.0] tbl_confirm_hand_tx
CREATE OR REPLACE FUNCTION public.tbl_confirm_hand_tx(p_token text, p_hand_id uuid, p_accept boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
/* 確認與取消（2026-09-25 使用者拍板，取代 09-23／24 的「各付各的」）：
     **全有或全無** —— 任何一人取消 ⇒ 這次操作作廢、不推進，送出的人重送；
     全部確認 ⇒ 一次入帳（金額 ＝ 送出時提出的 proposed_delta）。 */
declare
  d public.table_devices; v_session uuid; v_me smallint; h public.hands;
  v_ok smallint[];
begin
  d := public._tbl_device(p_token);
  select id into v_session from table_sessions
   where table_id = d.table_id and status = 'open' and deleted_at is null;
  if v_session is null then
    return jsonb_build_object('ok', false, 'reason', 'no_session', 'message', '這桌還沒開桌');
  end if;
  select seat into v_me from session_players
   where session_id = v_session and device_id = d.id and left_at is null;

  select * into h from hands where id = p_hand_id and session_id = v_session for update;
  if not found or h.status <> 'pending' then
    return jsonb_build_object('ok', false, 'reason', 'not_pending', 'message', '這一局已經處理過了');
  end if;
  if v_me is null or not (v_me = any(h.need_confirm)) then
    return jsonb_build_object('ok', false, 'reason', 'not_yours', 'message', '這一局不需要你確認');
  end if;
  if v_me = any(h.confirmed_seats) or v_me = any(h.cancelled_seats) then
    return jsonb_build_object('ok', true, 'already', true);
  end if;

  /* ── 取消 ⇒ 這次操作作廢，立刻結束，不等其他人 ── */
  if not p_accept then
    update hands
       set cancelled_seats = h.cancelled_seats || v_me,
           -- 一分都不動（確認的當下本來就沒入帳，這裡保險再歸零一次）
           score_delta = (select coalesce(jsonb_object_agg(k, 0), '{}'::jsonb)
                            from jsonb_object_keys(h.proposed_delta) k),
           status = 'rejected', rejected_seat = v_me, confirmed_at = null
     where id = h.id;
    perform public._tbl_ping(v_session);
    return jsonb_build_object('ok', true, 'status', 'rejected', 'accepted', false, 'voided', true);
  end if;

  v_ok := h.confirmed_seats || v_me;

  -- 還有人沒確認 ⇒ 先記下「他確認了」，不入帳
  if exists (select 1 from unnest(h.need_confirm) x where not (x = any(v_ok))) then
    update hands set confirmed_seats = v_ok where id = h.id;
    perform public._tbl_ping(v_session);
    return jsonb_build_object('ok', true, 'status', 'pending', 'accepted', true);
  end if;

  -- 全部確認 ⇒ 一次入帳，就是當初提出的那一份
  update hands
     set score_delta = h.proposed_delta, confirmed_seats = v_ok,
         status = 'confirmed', confirmed_at = now()
   where id = h.id;
  if h.result <> 'kala' and (public._tbl_round_state(h.round_id) ->> 'finished')::boolean then
    update session_rounds set status = 'finished', finished_at = now() where id = h.round_id;
  end if;
  perform public._tbl_ping(v_session);
  return jsonb_build_object('ok', true, 'status', 'confirmed', 'accepted', true);
end $function$
;

-- [7.0] tbl_release_seat_tx
CREATE OR REPLACE FUNCTION public.tbl_release_seat_tx(p_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare d public.table_devices; v_session uuid;
begin
  d := public._tbl_device(p_token);
  select id into v_session from table_sessions
   where table_id = d.table_id and status = 'open' and deleted_at is null;
  if v_session is null then
    return jsonb_build_object('ok', false, 'reason', 'no_session', 'message', '這桌還沒開桌');
  end if;
  update session_players set device_id = null where session_id = v_session and device_id = d.id;
  perform public._tbl_ping(v_session);
  return jsonb_build_object('ok', true);
end $function$
;

-- [7.0] tbl_set_order_tx
CREATE OR REPLACE FUNCTION public.tbl_set_order_tx(p_token text, p_dealer uuid, p_next uuid, p_opposite uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare d public.table_devices; s public.table_sessions; v_n int; v_last uuid; v_round uuid;
begin
  d := public._tbl_device(p_token);
  select * into s from table_sessions
   where table_id = d.table_id and status = 'open' and deleted_at is null;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'no_session', 'message', '這桌還沒開桌');
  end if;
  if coalesce(s.game_type, '台麻') <> '台麻' then
    return jsonb_build_object('ok', false, 'reason', 'unsupported_game_type',
                              'message', '記分板目前只支援台麻');
  end if;

  select count(*) into v_n from session_players where session_id = s.id and left_at is null;
  if v_n <> 4 then
    return jsonb_build_object('ok', false, 'reason', 'need_four_players',
                              'message', '要四個人都入座才能開始', 'n', v_n);
  end if;
  if p_dealer is null or p_next is null or p_opposite is null
     or p_dealer = p_next or p_dealer = p_opposite or p_next = p_opposite then
    return jsonb_build_object('ok', false, 'reason', 'bad_order', 'message', '三個人要選不同的人');
  end if;
  if (select count(*) from session_players
       where session_id = s.id and left_at is null and id in (p_dealer, p_next, p_opposite)) <> 3 then
    return jsonb_build_object('ok', false, 'reason', 'not_in_session', 'message', '有人不在這一桌');
  end if;
  if exists (select 1 from hands where session_id = s.id and status = 'confirmed') then
    return jsonb_build_object('ok', false, 'reason', 'already_started',
                              'message', '已經開始記分了，座位不能再改');
  end if;

  select id into v_last from session_players
   where session_id = s.id and left_at is null and id not in (p_dealer, p_next, p_opposite);

  -- 先全部清掉再填，避開 (session_id, seat) 唯一索引的中間狀態
  update session_players set seat = null where session_id = s.id;
  update session_players set seat = 1 where id = p_dealer;
  update session_players set seat = 2 where id = p_next;
  update session_players set seat = 3 where id = p_opposite;
  update session_players set seat = 4 where id = v_last;

  -- 第一將：還沒有就建，有（而且一把都沒確認）就把莊家重設成 1
  select id into v_round from session_rounds
   where session_id = s.id and status = 'playing';
  if v_round is null then
    insert into session_rounds (org_id, session_id, round_no, first_dealer_seat)
    values (s.org_id, s.id, 1, 1);
  else
    update session_rounds set first_dealer_seat = 1 where id = v_round;
  end if;
  -- 還掛著的待確認（座位改了就沒意義）一律收掉
  update hands set status = 'undone', undone_at = now()
   where session_id = s.id and status = 'pending';

  perform public._tbl_ping(s.id);
  return jsonb_build_object('ok', true);
end $function$
;

-- [7.0] tbl_start_round_tx
CREATE OR REPLACE FUNCTION public.tbl_start_round_tx(p_token text, p_dealer_seat smallint DEFAULT 1, p_next_seat smallint DEFAULT NULL::smallint, p_opposite_seat smallint DEFAULT NULL::smallint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare d public.table_devices; s public.table_sessions; r public.session_rounds; v_ring smallint[]; v_last smallint;
begin
  d := public._tbl_device(p_token);
  select * into s from table_sessions
   where table_id = d.table_id and status = 'open' and deleted_at is null;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'no_session', 'message', '這桌還沒開桌');
  end if;
  /* ⏰ 包桌續時（2026-10-01）：鎖定時也不能開新的一將 */
  if (public._pkg_time(s.id, false) ->> 'phase') = 'locked' then
    return jsonb_build_object('ok', false, 'reason', 'pkg_locked', 'message', '包桌時間已到，請到櫃檯補檯費');
  end if;
  if p_dealer_seat not between 1 and 4 then
    return jsonb_build_object('ok', false, 'reason', 'bad_seat', 'message', '請選莊家');
  end if;
  -- 下家、對家要嘛都給、要嘛都不給（都不給 ＝ 舊版平板，照原本的 1→2→3→4）
  if (p_next_seat is null) <> (p_opposite_seat is null) then
    return jsonb_build_object('ok', false, 'reason', 'bad_order', 'message', '請選下家和對家');
  end if;
  if p_next_seat is not null then
    if p_next_seat not between 1 and 4 or p_opposite_seat not between 1 and 4
       or p_next_seat = p_dealer_seat or p_opposite_seat = p_dealer_seat or p_next_seat = p_opposite_seat then
      return jsonb_build_object('ok', false, 'reason', 'bad_order', 'message', '三個人要選不同的人');
    end if;
    select x into v_last from unnest('{1,2,3,4}'::smallint[]) x
     where x not in (p_dealer_seat, p_next_seat, p_opposite_seat);
    v_ring := array[p_dealer_seat, p_next_seat, p_opposite_seat, v_last];
  end if;
  if exists (select 1 from session_rounds where session_id = s.id and status = 'playing') then
    return jsonb_build_object('ok', false, 'reason', 'round_playing', 'message', '這一將還沒打完');
  end if;
  select * into r from session_rounds
   where session_id = s.id and status <> 'voided' order by round_no desc limit 1;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'no_order', 'message', '請先定好座位');
  end if;

  insert into session_rounds (org_id, session_id, round_no, first_dealer_seat, seat_ring)
  values (s.org_id, s.id, r.round_no + 1, p_dealer_seat, v_ring);
  perform public._tbl_ping(s.id);
  return jsonb_build_object('ok', true, 'round_no', r.round_no + 1, 'seat_ring', to_jsonb(v_ring));
end $function$
;

-- [7.0] tbl_state_tx
CREATE OR REPLACE FUNCTION public.tbl_state_tx(p_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  /* 2026-10-02 拆成共用核心：內容搬到 _tbl_state_for_device（一字不改），這裡只負責用憑證認出是哪一台平板
     （_tbl_device 也順便記最後上線時間）。POS 觀看走 pos_tbl_watch_tx，同一個核心 ⇒ 兩邊畫面不會漂 */
  return public._tbl_state_for_device(public._tbl_device(p_token));
end $function$
;

-- [7.0] tbl_submit_hand_tx
CREATE OR REPLACE FUNCTION public.tbl_submit_hand_tx(p_token text, p_result text, p_deal_in_seat smallint DEFAULT NULL::smallint, p_patterns jsonb DEFAULT '[]'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
/* p_result：
     ron    我胡了，p_deal_in_seat ＝ 放槍的人（要選牌型）
     tsumo  我自摸（要選牌型；沒選門清自摸就自動帶自摸 1 台）
     draw   流局：只有按的人確認，直接生效
     kala   咔啦碰：我直接付 p_deal_in_seat 那一家 1 台（不算底、不加莊家台），收的人確認
     bao    我包牌：我付另外三家各 1 底 3 台（莊家有牽涉再加莊家台），收的三家各自確認
   🔴 付錢的那一方永遠是「確認的人」以外的那一台：胡／自摸是別人付我、咔啦碰與包牌是我付別人。 */
declare
  d public.table_devices; s public.table_sessions; v_me smallint; v_round public.session_rounds;
  v_st jsonb; v_dealer smallint; v_ren smallint; v_base int; v_unit int;
  v_pats jsonb := '[]'::jsonb; v_codes text[] := '{}'; e jsonb; p public.scoring_patterns;
  v_n int; v_tai int := 0; v_extra int;
  v_delta jsonb; v_zero jsonb := '{"1":0,"2":0,"3":0,"4":0}'::jsonb;
  v_sum int := 0; v_pay int; v_payers smallint[]; i smallint;
  v_need smallint[] := '{}'; v_hand uuid; v_winner smallint;
  c_kala_tai constant int := 1;   -- 咔啦碰固定 1 台
  c_bao_tai  constant int := 3;   -- 包牌 1 底 3 台
begin
  d := public._tbl_device(p_token);
  select * into s from table_sessions
   where table_id = d.table_id and status = 'open' and deleted_at is null;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'no_session', 'message', '這桌還沒開桌');
  end if;
  /* ⏰ 包桌續時（2026-10-01）：到期後 15 分鐘還沒補完檯費就不能再記分，要先到櫃檯補 */
  if (public._pkg_time(s.id, false) ->> 'phase') = 'locked' then
    return jsonb_build_object('ok', false, 'reason', 'pkg_locked', 'message', '包桌時間已到，請到櫃檯補檯費');
  end if;
  if coalesce(s.game_type, '台麻') <> '台麻' then
    return jsonb_build_object('ok', false, 'reason', 'unsupported_game_type', 'message', '記分板目前只支援台麻');
  end if;

  select seat into v_me from session_players
   where session_id = s.id and device_id = d.id and left_at is null;
  if v_me is null then
    return jsonb_build_object('ok', false, 'reason', 'no_seat', 'message', '請先選「我是誰」並定好座位');
  end if;

  select * into v_round from session_rounds where session_id = s.id and status = 'playing';
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'no_round', 'message', '這一將已經結束，請先開始下一將');
  end if;
  if exists (select 1 from hands where round_id = v_round.id and status = 'pending') then
    return jsonb_build_object('ok', false, 'reason', 'pending_exists', 'message', '上一局還有人沒確認');
  end if;

  if p_result is null or p_result not in ('tsumo', 'ron', 'draw', 'kala', 'bao') then
    return jsonb_build_object('ok', false, 'reason', 'bad_result', 'message', '動作不對');
  end if;

  v_st := public._tbl_round_state(v_round.id);
  v_dealer := (v_st ->> 'dealer_seat')::smallint;
  v_ren := (v_st ->> 'renzhuang')::smallint;
  v_extra := 1 + 2 * v_ren;   -- 莊家台：連 N 拉 N（2026-09-23）

  select sl.base, sl.tai into v_base, v_unit
    from stake_levels sl where sl.id = s.stake_level_id;
  if v_base is null or v_unit is null then
    return jsonb_build_object('ok', false, 'reason', 'no_stake', 'message', '這桌沒有設定積分級距，請找店員');
  end if;

  -- ── 流局：只有按的人確認，直接生效 ──
  if p_result = 'draw' then
    insert into hands (org_id, session_id, round_id, hand_no, wind, dealer_seat, renzhuang,
                       result, base, tai_unit, score_delta, proposed_delta, status, need_confirm,
                       submitted_seat, submitted_device_id, confirmed_at)
    values (s.org_id, s.id, v_round.id, (v_st ->> 'hand_no')::int, (v_st ->> 'wind')::smallint,
            v_dealer, v_ren, 'draw', v_base, v_unit, v_zero, v_zero, 'confirmed', '{}', v_me, d.id, now())
    returning id into v_hand;
    if (public._tbl_round_state(v_round.id) ->> 'finished')::boolean then
      update session_rounds set status = 'finished', finished_at = now() where id = v_round.id;
    end if;
    perform public._tbl_ping(s.id);
    return jsonb_build_object('ok', true, 'hand_id', v_hand, 'status', 'confirmed');
  end if;

  -- ── 咔啦碰：我付那一家 1 台，他確認 ──
  if p_result = 'kala' then
    if p_deal_in_seat is null or p_deal_in_seat not between 1 and 4 or p_deal_in_seat = v_me then
      return jsonb_build_object('ok', false, 'reason', 'bad_target', 'message', '請選要付給誰');
    end if;
    v_pay := v_unit * c_kala_tai;
    v_delta := jsonb_set(jsonb_set(v_zero, array[p_deal_in_seat::text], to_jsonb(v_pay)),
                         array[v_me::text], to_jsonb(-v_pay));
    insert into hands (org_id, session_id, round_id, hand_no, wind, dealer_seat, renzhuang,
                       result, winner_seat, deal_in_seat, patterns, tai_pattern,
                       base, tai_unit, score_delta, proposed_delta, status, need_confirm,
                       submitted_seat, submitted_device_id)
    values (s.org_id, s.id, v_round.id, (v_st ->> 'hand_no')::int, (v_st ->> 'wind')::smallint,
            v_dealer, v_ren, 'kala', p_deal_in_seat, v_me, '[]'::jsonb, c_kala_tai,
            v_base, v_unit, v_zero, v_delta, 'pending', array[p_deal_in_seat], v_me, d.id)
    returning id into v_hand;
    perform public._tbl_ping(s.id);
    return jsonb_build_object('ok', true, 'hand_id', v_hand, 'status', 'pending',
                              'proposed_delta', v_delta, 'need_confirm', to_jsonb(array[p_deal_in_seat]));
  end if;

  -- ── 包牌：我付另外三家，三家各自確認 ──
  if p_result = 'bao' then
    v_payers := array(select g::smallint from generate_series(1, 4) g where g <> v_me);   -- 這裡是「收的人」
    v_delta := v_zero;
    foreach i in array v_payers loop
      v_pay := v_base + v_unit * (c_bao_tai + case when v_me = v_dealer or i = v_dealer then v_extra else 0 end);
      v_delta := jsonb_set(v_delta, array[i::text], to_jsonb(v_pay));
      v_sum := v_sum + v_pay;
    end loop;
    v_delta := jsonb_set(v_delta, array[v_me::text], to_jsonb(-v_sum));
    insert into hands (org_id, session_id, round_id, hand_no, wind, dealer_seat, renzhuang,
                       result, winner_seat, deal_in_seat, patterns, tai_pattern,
                       base, tai_unit, score_delta, proposed_delta, status, need_confirm,
                       submitted_seat, submitted_device_id)
    values (s.org_id, s.id, v_round.id, (v_st ->> 'hand_no')::int, (v_st ->> 'wind')::smallint,
            v_dealer, v_ren, 'bao', null, v_me, '[]'::jsonb, c_bao_tai,
            v_base, v_unit, v_zero, v_delta, 'pending', v_payers, v_me, d.id)
    returning id into v_hand;
    perform public._tbl_ping(s.id);
    return jsonb_build_object('ok', true, 'hand_id', v_hand, 'status', 'pending',
                              'proposed_delta', v_delta, 'need_confirm', to_jsonb(v_payers));
  end if;

  -- ── 胡／自摸：贏家一律是這台平板的座位 ──
  v_winner := v_me;
  if p_result = 'ron' then
    if p_deal_in_seat is null or p_deal_in_seat not between 1 and 4 or p_deal_in_seat = v_winner then
      return jsonb_build_object('ok', false, 'reason', 'bad_deal_in', 'message', '請選是誰放槍');
    end if;
  end if;

  /* 台數只能從牌型換算（2026-09-23 起沒有第二條路）。
     ⚠ 空陣列是合法的：放槍胡一手沒有任何台的雜牌只收底（畫面上的「沒台」）。 */
  for e in select * from jsonb_array_elements(coalesce(p_patterns, '[]'::jsonb)) loop
    select * into p from scoring_patterns where code = e ->> 'code' and is_active;
    if not found then
      return jsonb_build_object('ok', false, 'reason', 'unknown_pattern', 'message', '沒有這個牌型', 'code', e ->> 'code');
    end if;
    if p.code = any(v_codes) then
      return jsonb_build_object('ok', false, 'reason', 'duplicate_pattern', 'message', p.label || ' 選了兩次');
    end if;
    v_n := coalesce(nullif(e ->> 'n', '')::int, 1);
    if v_n < 1 or v_n > p.max_count then
      return jsonb_build_object('ok', false, 'reason', 'bad_count', 'message', p.label || ' 最多 ' || p.max_count);
    end if;
    if p.needs_flower and coalesce(s.flower, '無花') <> '有花' then
      return jsonb_build_object('ok', false, 'reason', 'no_flower', 'message', '這桌是無花，不能選 ' || p.label);
    end if;
    if p.result_only is not null and p.result_only <> p_result then
      return jsonb_build_object('ok', false, 'reason', 'wrong_result',
        'message', p.label || (case when p.result_only = 'tsumo' then ' 只有自摸才有' else ' 只有放槍才有' end));
    end if;
    if p.dealer_only and v_winner <> v_dealer then
      return jsonb_build_object('ok', false, 'reason', 'dealer_only', 'message', p.label || ' 只有莊家才有');
    end if;
    v_codes := v_codes || p.code;
    v_pats := v_pats || jsonb_build_array(jsonb_build_object('code', p.code, 'n', v_n));
    v_tai := v_tai + p.tai * v_n;
  end loop;

  -- 自摸：沒選門清自摸就自動帶自摸 1 台
  if p_result = 'tsumo' and not ('zimo' = any(v_codes)) and not ('menqing_tsumo' = any(v_codes)) then
    select * into p from scoring_patterns where code = 'zimo' and is_active;
    if found then
      v_codes := v_codes || p.code;
      v_pats := v_pats || jsonb_build_array(jsonb_build_object('code', p.code, 'n', 1));
      v_tai := v_tai + p.tai;
    end if;
  end if;

  -- 互斥（雙向）
  if exists (select 1 from scoring_patterns a, unnest(a.conflicts) c
              where a.code = any(v_codes) and c = any(v_codes)) then
    return jsonb_build_object('ok', false, 'reason', 'conflicting_patterns',
      'message', '有兩個牌型不能同時算：' ||
        (select string_agg(a.label || '／' || b.label, '、')
           from scoring_patterns a, unnest(a.conflicts) c, scoring_patterns b
          where a.code = any(v_codes) and c = any(v_codes) and b.code = c));
  end if;

  /* 每個付款人付：底 ＋ 台 ×（牌型台數 ＋ 莊家台）；莊家台只在「胡的人或付的人是莊家」時加 */
  if p_result = 'ron' then
    v_payers := array[p_deal_in_seat];
  else
    v_payers := array(select g::smallint from generate_series(1, 4) g where g <> v_winner);
  end if;
  v_need := v_payers;
  v_delta := v_zero;
  foreach i in array v_payers loop
    v_pay := v_base + v_unit * (v_tai + case when v_winner = v_dealer or i = v_dealer then v_extra else 0 end);
    v_delta := jsonb_set(v_delta, array[i::text], to_jsonb(-v_pay));
    v_sum := v_sum + v_pay;
  end loop;
  v_delta := jsonb_set(v_delta, array[v_winner::text], to_jsonb(v_sum));

  insert into hands (org_id, session_id, round_id, hand_no, wind, dealer_seat, renzhuang,
                     result, winner_seat, deal_in_seat, patterns, tai_pattern,
                     base, tai_unit, score_delta, proposed_delta, status, need_confirm, submitted_seat, submitted_device_id)
  values (s.org_id, s.id, v_round.id, (v_st ->> 'hand_no')::int, (v_st ->> 'wind')::smallint,
          v_dealer, v_ren, p_result, v_winner, case when p_result = 'ron' then p_deal_in_seat end,
          v_pats, v_tai, v_base, v_unit, v_zero, v_delta, 'pending', v_need, v_me, d.id)
  returning id into v_hand;

  perform public._tbl_ping(s.id);
  return jsonb_build_object('ok', true, 'hand_id', v_hand, 'status', 'pending',
                            'tai_pattern', v_tai, 'proposed_delta', v_delta, 'need_confirm', to_jsonb(v_need));
end $function$
;

-- [7.0] tbl_undo_last_tx
CREATE OR REPLACE FUNCTION public.tbl_undo_last_tx(p_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare d public.table_devices; v_session uuid; v_me smallint; r public.session_rounds; v_hand uuid;
begin
  d := public._tbl_device(p_token);
  select id into v_session from table_sessions
   where table_id = d.table_id and status = 'open' and deleted_at is null;
  if v_session is null then
    return jsonb_build_object('ok', false, 'reason', 'no_session', 'message', '這桌還沒開桌');
  end if;
  select seat into v_me from session_players
   where session_id = v_session and device_id = d.id and left_at is null;
  if v_me is null then
    return jsonb_build_object('ok', false, 'reason', 'no_seat', 'message', '請先選「我是誰」');
  end if;
  if exists (select 1 from hands where session_id = v_session and status = 'pending') then
    return jsonb_build_object('ok', false, 'reason', 'pending_exists', 'message', '上一局還有人沒確認，先處理那一局');
  end if;

  select * into r from session_rounds
   where session_id = v_session and status <> 'voided' order by round_no desc limit 1;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'nothing', 'message', '還沒有可以撤銷的');
  end if;

  -- 最新一將一局都沒打 ⇒ 作廢它，撤銷的對象變成上一將的最後一筆
  if not exists (select 1 from hands where round_id = r.id and status = 'confirmed') and r.round_no > 1 then
    update session_rounds set status = 'voided' where id = r.id;
    select * into r from session_rounds
     where session_id = v_session and status <> 'voided' order by round_no desc limit 1;
  end if;

  select id into v_hand from hands
   where round_id = r.id and status = 'confirmed' order by created_at desc limit 1;
  if v_hand is null then
    return jsonb_build_object('ok', false, 'reason', 'nothing', 'message', '還沒有可以撤銷的');
  end if;

  update hands set status = 'undone', undone_at = now() where id = v_hand;
  update session_rounds set status = 'playing', finished_at = null where id = r.id and status = 'finished';

  perform public._tbl_ping(v_session);
  return jsonb_build_object('ok', true, 'undone_hand_id', v_hand);
end $function$
;

-- [7.0] team_crest_guard_tx
CREATE OR REPLACE FUNCTION public.team_crest_guard_tx(p_team_id uuid, p_member_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_blk boolean;
begin
  select t.crest_blocked into v_blk from public.teams t
   where t.id = p_team_id and t.deleted_at is null;
  if v_blk is null then
    return jsonb_build_object('ok', false, 'reason', 'not_found', 'message', '找不到這個牌咖團');
  end if;
  if not public._is_team_leader(p_team_id, p_member_id) then
    return jsonb_build_object('ok', false, 'reason', 'not_leader', 'message', '只有團長可以換團徽');
  end if;
  if v_blk then
    return jsonb_build_object('ok', false, 'reason', 'crest_blocked',
                              'message', '這個團的自訂團徽已停用，請改用圖示');
  end if;
  return jsonb_build_object('ok', true);
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

-- [7.0] transfer_team_leader_tx
CREATE OR REPLACE FUNCTION public.transfer_team_leader_tx(p_team_id uuid, p_to_member_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_me   uuid := public.current_member_id();
  v_org  uuid := public.current_org_id();
  v_name text;
  v_team text;
begin
  if v_me is null or v_org is null then
    return jsonb_build_object('ok', false, 'reason', 'not_logged_in', 'message', '請先登入');
  end if;
  if p_to_member_id is null or p_to_member_id = v_me then
    return jsonb_build_object('ok', false, 'reason', 'bad_target', 'message', '對象不正確');
  end if;
  if not exists (select 1 from public.team_members tm
                  where tm.team_id = p_team_id and tm.member_id = v_me
                    and tm.left_at is null and tm.role = 'leader') then
    return jsonb_build_object('ok', false, 'reason', 'not_leader', 'message', '只有團長可以轉讓');
  end if;
  if not exists (select 1 from public.team_members tm
                  where tm.team_id = p_team_id and tm.member_id = p_to_member_id
                    and tm.left_at is null) then
    return jsonb_build_object('ok', false, 'reason', 'not_member', 'message', '他不在這個團裡');
  end if;

  update public.team_members set role = 'member'
   where team_id = p_team_id and member_id = v_me and left_at is null;
  update public.team_members set role = 'leader'
   where team_id = p_team_id and member_id = p_to_member_id and left_at is null;

  select t.name into v_team from public.teams t where t.id = p_team_id;
  select display_name into v_name from public.members where id = v_me;
  perform public._team_notify(v_org, p_to_member_id, 'team_ok', v_name,
           v_name || ' 把 ' || v_team || ' 的團長交給你了', p_team_id, v_team, null);

  return jsonb_build_object('ok', true, 'message', '已轉讓團長');
end $function$
;

-- [7.0] trg_buddies_achievements
CREATE OR REPLACE FUNCTION public.trg_buddies_achievements()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  begin
    perform public.fire_event_tx(new.member_id, 'buddy_added', 1, null,
                                 'buddy:' || new.id::text);
  exception when others then null;
  end;
  return null;
end $function$
;

-- [7.0] trg_coupon_scopes_check
CREATE OR REPLACE FUNCTION public.trg_coupon_scopes_check()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
begin
  if new.org_id is distinct from (select org_id from coupons where id = new.coupon_id) then
    raise exception '規則的機構與券不一致';
  end if;
  if new.scope_type = 'revenue_type' and not exists
       (select 1 from product_taxonomy where dimension = 'revenue_type' and code = new.scope_value) then
    raise exception '營收類別「%」不存在（可用：venue_fee／fnb／retail／other）', new.scope_value;
  elsif new.scope_type = 'subcategory' and not exists
       (select 1 from product_taxonomy where dimension = 'subcategory' and code = new.scope_value) then
    raise exception '子分類「%」不存在（見 product_taxonomy 的 subcategory）', new.scope_value;
  elsif new.scope_type = 'product' and not exists
       (select 1 from products where id::text = new.scope_value and org_id = new.org_id and deleted_at is null) then
    raise exception '指定商品「%」不存在或不屬於本機構', new.scope_value;
  end if;
  return new;
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

-- [7.0] trg_coupons_applies_to_frozen
CREATE OR REPLACE FUNCTION public.trg_coupons_applies_to_frozen()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
begin
  if (tg_op = 'INSERT' and new.applies_to is not null)
     or (tg_op = 'UPDATE' and new.applies_to is distinct from old.applies_to) then
    raise exception '券的適用範圍已改用 coupon_scopes 設定（coupons.applies_to 已凍結，2026-10-01）';
  end if;
  return new;
end $function$
;

-- [7.0] trg_hands_bust_clamp
CREATE OR REPLACE FUNCTION public.trg_hands_bust_clamp()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_bal jsonb; v_d jsonb; v_payers smallint[]; v_recvs smallint[];
  i smallint; j int; v_owe int; v_have int; v_pay int; v_got int; v_left int;
begin
  if exists (select 1 from public.session_busts b where b.session_id = new.session_id and b.decision = 'pending')
     and not public._session_scored(new.session_id) then
    raise exception '有人積分歸零，等待決定是否追加積分' using errcode = 'P0001';
  end if;
  if new.proposed_delta is null then return new; end if;

  v_bal := public._tbl_balances(new.session_id);
  v_d := new.proposed_delta;
  select coalesce(array_agg(k::smallint order by k) filter (where v < 0), '{}'),
         coalesce(array_agg(k::smallint order by k) filter (where v > 0), '{}')
    into v_payers, v_recvs
    from (select e.key as k, e.value::int as v from jsonb_each_text(v_d) e) z;

  if coalesce(array_length(v_recvs, 1), 0) = 1 then
    -- 一個收款人（胡／自摸／咔啦碰）：每個付的人最多付自己剩的，收的人拿實付合計
    v_got := 0;
    foreach i in array v_payers loop
      v_owe  := -((v_d ->> i::text)::int);
      v_have := greatest(0, coalesce((v_bal ->> i::text)::int, 0));
      v_pay  := least(v_owe, v_have);
      v_d := jsonb_set(v_d, array[i::text], to_jsonb(-v_pay));
      v_got := v_got + v_pay;
    end loop;
    v_d := jsonb_set(v_d, array[v_recvs[1]::text], to_jsonb(v_got));
  elsif coalesce(array_length(v_payers, 1), 0) = 1 and coalesce(array_length(v_recvs, 1), 0) > 1 then
    -- 包牌：一個人付三家；付不夠就照比例分，最後一家拿餘數（總和不差 1 分）
    i := v_payers[1];
    v_owe  := -((v_d ->> i::text)::int);
    v_have := greatest(0, coalesce((v_bal ->> i::text)::int, 0));
    if v_have < v_owe then
      v_left := v_have;
      for j in 1 .. array_length(v_recvs, 1) loop
        if j = array_length(v_recvs, 1) then
          v_pay := v_left;
        else
          v_pay := floor((v_d ->> v_recvs[j]::text)::numeric * v_have / v_owe)::int;
        end if;
        v_d := jsonb_set(v_d, array[v_recvs[j]::text], to_jsonb(v_pay));
        v_left := v_left - v_pay;
      end loop;
      v_d := jsonb_set(v_d, array[i::text], to_jsonb(-v_have));
    end if;
  end if;

  new.proposed_delta := v_d;
  if new.status = 'confirmed' then new.score_delta := v_d; end if;
  return new;
end $function$
;

-- [7.0] trg_hands_bust_detect
CREATE OR REPLACE FUNCTION public.trg_hands_bust_detect()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_bal jsonb; g int;
begin
  if new.status = 'confirmed' and old.status is distinct from 'confirmed' then
    v_bal := public._tbl_balances(new.session_id);
    for g in 1 .. 4 loop
      if coalesce((v_bal ->> g::text)::int, 1) <= 0
         and not exists (select 1 from public.session_busts b
                          where b.session_id = new.session_id and b.seat = g and b.decision = 'pending') then
        insert into public.session_busts (org_id, session_id, seat, hand_id, by_seat)
        values (new.org_id, new.session_id, g, new.id,
                case when new.result in ('ron', 'tsumo') and new.winner_seat is distinct from g then new.winner_seat end);
      end if;
    end loop;
  elsif old.status = 'confirmed' and new.status is distinct from 'confirmed' then
    update public.session_busts set decision = 'voided', decided_at = now()
     where hand_id = new.id and decision = 'pending';
  end if;
  return null;
end $function$
;

-- [7.0] trg_match_queues_credit
CREATE OR REPLACE FUNCTION public.trg_match_queues_credit()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if new.status = 'matched' and old.status = 'waiting' then
    -- 配桌完成的那一刻（_finalize_queue_full_tx）
    new.credited_staff_id := (select on_duty_staff_id from stores where id = new.store_id);
  elsif new.status = 'waiting' and old.status is distinct from 'waiting' then
    -- 取消開桌、人不夠退回等人 ⇒ 這次配桌不算數，下次湊滿再記
    new.credited_staff_id := null;
  end if;
  -- ⚠ seated → matched（取消開桌但人還夠）不動：配桌完成的那一刻沒變
  return new;
end $function$
;

-- [7.0] trg_member_likes_achievements
CREATE OR REPLACE FUNCTION public.trg_member_likes_achievements()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  begin
    perform public.fire_event_tx(new.liker_id, 'like_given', 1, null,
                                 'like:' || new.id::text);
  exception when others then null;
  end;
  begin
    perform public.fire_event_tx(new.target_id, 'like_received', 1, null,
                                 'like:' || new.id::text);
  exception when others then null;
  end;
  return null;
end $function$
;

-- [7.0] trg_members_achievements
CREATE OR REPLACE FUNCTION public.trg_members_achievements()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  begin
    perform public.fire_event_tx(new.id, 'member_registered', 1, null,
                                 'reg:' || new.id::text);
    -- 🔴 稱號是**註冊預設就有**（2026-09-20 拍板，members.title NOT NULL
    --    DEFAULT '新手上路'）⇒ 與註冊是同一個時刻。
    --    條件寫出來不是多餘：日後若拿掉 DEFAULT，這裡會自己停下來。
    if coalesce(new.title, '') <> '' then
      perform public.fire_event_tx(new.id, 'title_granted', 1, null,
                                   'reg:' || new.id::text);
    end if;
  exception when others then null;
  end;
  return null;
end $function$
;

-- [7.0] trg_members_best_rank
CREATE OR REPLACE FUNCTION public.trg_members_best_rank()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
declare
  v_new  text := public._rank_tier_of(new.rank);
  v_newo int;
  v_best int;
begin
  if v_new is null then return new; end if;
  select sort into v_newo from public.rank_tiers where code = v_new;
  select sort into v_best from public.rank_tiers where code = new.best_rank_tier;
  if v_best is null or v_newo > v_best then
    new.best_rank_tier := v_new;
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

-- [7.0] trg_members_rank_achievements
CREATE OR REPLACE FUNCTION public.trg_members_rank_achievements()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  begin
    perform public.fire_event_tx(new.id, 'rank_placed', 1, null,
                                 'rank:' || new.id::text);
  exception when others then null;
  end;
  return null;
end $function$
;

-- [7.0] trg_members_rank_events
CREATE OR REPLACE FUNCTION public.trg_members_rank_events()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_ot text; v_nt text; v_os int; v_ns int; v_bs int; v_ob int; v_nb int;
  v_idem text; t record;
begin
  if new.deleted_at is not null then return null; end if;
  begin
    v_ot := public._rank_tier_of(old.rank);
    v_nt := public._rank_tier_of(new.rank);
    select sort into v_os from public.rank_tiers where code = v_ot;
    select sort into v_ns from public.rank_tiers where code = v_nt;
    select sort into v_bs from public.rank_tiers where code = old.best_rank_tier;
    v_idem := 'rank:' || new.id::text || ':' || coalesce(new.rank, '') || ':' || coalesce(new.rating, 0)::text;

    -- 同階升級：級數 IV → III → II → I
    if v_ot is not null and v_ot = v_nt then
      v_ob := case when old.rank ~ ' IV$' then 1 when old.rank ~ ' III$' then 2 when old.rank ~ ' II$' then 3 when old.rank ~ ' I$' then 4 end;
      v_nb := case when new.rank ~ ' IV$' then 1 when new.rank ~ ' III$' then 2 when new.rank ~ ' II$' then 3 when new.rank ~ ' I$' then 4 end;
      if v_ob is not null and v_nb is not null and v_nb > v_ob then
        perform public.fire_event_tx(new.id, 'rank_band_up', 1, null, v_idem);
      end if;
    end if;

    -- 跨階：一次跳好幾階時，中間每一階都算到過
    if v_ns is not null and v_ns > coalesce(v_os, 0) then
      for t in select code from public.rank_tiers
                where sort > coalesce(v_os, 0) and sort <= v_ns and sort >= 2
                order by sort loop
        perform public.fire_event_tx(new.id, 'rank_reach_' || t.code, 1, null, v_idem);
      end loop;
    end if;

    -- 段位分門檻（達到就算，之後掉下去不收回）
    if coalesce(new.rating, 0) >= 300 then perform public.fire_event_tx(new.id, 'rating_300', 1, null, v_idem); end if;
    if coalesce(new.rating, 0) >= 600 then perform public.fire_event_tx(new.id, 'rating_600', 1, null, v_idem); end if;
    if coalesce(new.rating, 0) >= 900 then perform public.fire_event_tx(new.id, 'rating_900', 1, null, v_idem); end if;

    -- 回到巔峰：之前掉到最高階以下，這一次回到最高階
    if v_bs is not null and v_os is not null and v_ns is not null and v_os < v_bs and v_ns >= v_bs then
      perform public.fire_event_tx(new.id, 'rank_back_to_peak', 1, null, v_idem);
    end if;
  exception when others then null;   -- 成就失敗不可以擋住段位寫入
  end;
  return null;
end $function$
;

-- [7.0] trg_order_items_achievements
CREATE OR REPLACE FUNCTION public.trg_order_items_achievements()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare r record;
begin
  /* 🔴 整段吞例外：觸發器沒有呼叫端能替它包 ——
     不吞的話，成就寫入失敗會**回滾整筆結帳**。 */
  begin
    for r in
      select o.id as order_id, o.member_id,
             bool_or(pr.subcategory = 'DRK')                      as has_drink,
             bool_or(pr.subcategory in ('MEAL','FRY','SNK'))      as has_meal
        from new_items ni
        join orders   o  on o.id  = ni.order_id
        join products pr on pr.id = ni.product_id
       where o.status = 'paid'          -- ⚠ 未付款的單不算（作廢、草稿）
         and o.member_id is not null    -- ⚠ 匿名結帳沒有人可以發
       group by o.id, o.member_id
    loop
      -- ⚠ 冪等鍵帶 order_id：同一張單重送不會把累積型多加一次
      --   （A 區這兩枚是 specific，本來就冪等，但 M 區會有累積型）
      if r.has_drink then
        perform public.fire_event_tx(r.member_id, 'fnb_drink', 1, null,
                                     'oi:' || r.order_id::text);
      end if;
      if r.has_meal then
        perform public.fire_event_tx(r.member_id, 'fnb_meal', 1, null,
                                     'oi:' || r.order_id::text);
      end if;
    end loop;
  exception when others then null;
  end;
  return null;   -- AFTER 觸發器的回傳值會被忽略
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

-- [7.0] trg_session_rounds_auto_score
CREATE OR REPLACE FUNCTION public.trg_session_rounds_auto_score()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_planned int; v_status text;
begin
  if new.status = 'finished' and old.status is distinct from 'finished' then
    select planned_rounds, status into v_planned, v_status
      from table_sessions where id = new.session_id;
    /* 約定 2 將以上才自動算（1 將沒有段位分）；最後一將打完那一刻；還沒算過 */
    if v_status = 'open' and coalesce(v_planned, 0) >= 2 and new.round_no >= v_planned
       and not public._session_scored(new.session_id) then
      begin
        perform public._score_settle_tx(new.session_id);
      exception when others then
        null;   -- 🔴 不可以讓結算失敗把「確認最後一局」一起回滾；收桌會補算
      end;
    end if;
  end if;
  return new;
end $function$
;

-- [7.0] trg_session_rounds_guard
CREATE OR REPLACE FUNCTION public.trg_session_rounds_guard()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if tg_op = 'INSERT' then
    if public._session_scored(new.session_id) then
      raise exception '這場的成績已經結算，不能再開新的一將（請店員收桌）';
    end if;
  elsif old.status = 'finished' and new.status = 'playing'
        and public._session_scored(new.session_id) then
    raise exception '這場的成績已經結算，不能再撤銷（請店員處理）';
  end if;
  return new;
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

-- [7.0] trg_snack_achievements
CREATE OR REPLACE FUNCTION public.trg_snack_achievements()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  begin
    if new.qty > 0 then
      perform public.fire_event_tx(new.member_id, 'snack_granted', 1, null,
                                   'snack:' || new.id::text);
    elsif new.qty < 0 then
      perform public.fire_event_tx(new.member_id, 'snack_consumed', 1, null,
                                   'snack:' || new.id::text);
    end if;
  exception when others then null;
  end;
  return null;
end $function$
;

-- [7.0] trg_team_members_achievements
CREATE OR REPLACE FUNCTION public.trg_team_members_achievements()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  begin
    perform public.fire_event_tx(new.member_id, 'team_joined', 1, null,
                                 'tmjoin:' || new.id::text);
  exception when others then null;
  end;
  return null;
end $function$
;

-- [7.0] trg_teams_achievements
CREATE OR REPLACE FUNCTION public.trg_teams_achievements()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  begin
    perform public.fire_event_tx(new.created_by, 'team_created', 1, null,
                                 'team:' || new.id::text);
  exception when others then null;
  end;
  return null;
end $function$
;

-- [7.0] trg_topup_achievements
CREATE OR REPLACE FUNCTION public.trg_topup_achievements()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  begin
    perform public.fire_event_tx(new.member_id, 'topup', 1, null,
                                 'topup:' || new.id::text);
  exception when others then null;
  end;
  return null;
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
  -- 【身分 2026-09-29】只認登入的本人，前端送的 id 一律忽略
  p_blocker := public.current_member_id();
  if p_blocker is null then raise exception '未登入或登入已過期，請重新開啟 App' using errcode = '28000'; end if;
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
  -- 【身分 2026-09-29】只認登入的本人，前端送的 id 一律忽略
  p_member := public.current_member_id();
  if p_member is null then raise exception '未登入或登入已過期，請重新開啟 App' using errcode = '28000'; end if;
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
  -- 【身分 2026-09-29】只有開房的人或店員能改開打時間
  if not exists (select 1 from public.current_staff())
     and not exists (select 1 from public.match_queues q where q.id = p_queue and q.opened_by = public.current_member_id()) then
    raise exception '只有開房的人可以改開打時間' using errcode = '42501';
  end if;
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

-- [7.0] update_team_tx
CREATE OR REPLACE FUNCTION public.update_team_tx(p_team_id uuid, p_name text DEFAULT NULL::text, p_intro text DEFAULT NULL::text, p_join_policy text DEFAULT NULL::text, p_home_store_id uuid DEFAULT NULL::uuid, p_clear_store boolean DEFAULT false, p_monthly_goal integer DEFAULT NULL::integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_me   uuid := public.current_member_id();
  v_org  uuid := public.current_org_id();
  v_name text := nullif(btrim(coalesce(p_name, '')), '');
begin
  if v_me is null or v_org is null then
    return jsonb_build_object('ok', false, 'reason', 'not_logged_in', 'message', '請先登入');
  end if;
  if not exists (select 1 from public.team_members tm
                  where tm.team_id = p_team_id and tm.member_id = v_me
                    and tm.left_at is null and tm.role = 'leader') then
    return jsonb_build_object('ok', false, 'reason', 'not_leader', 'message', '只有團長可以修改');
  end if;

  if p_name is not null and (v_name is null or char_length(v_name) > 20 or char_length(v_name) < 2) then
    return jsonb_build_object('ok', false, 'reason', 'bad_name', 'message', '團名請取 2 到 20 個字');
  end if;
  if p_join_policy is not null and p_join_policy not in ('open', 'approval', 'closed') then
    return jsonb_build_object('ok', false, 'reason', 'bad_policy', 'message', '加入方式不正確');
  end if;
  if p_monthly_goal is not null and (p_monthly_goal < 1 or p_monthly_goal > 999) then
    return jsonb_build_object('ok', false, 'reason', 'bad_goal', 'message', '本月目標請填 1 到 999');
  end if;
  if p_home_store_id is not null and not exists (
       select 1 from public.stores s
        where s.id = p_home_store_id and s.org_id = v_org and s.deleted_at is null) then
    return jsonb_build_object('ok', false, 'reason', 'bad_store', 'message', '找不到那間門市');
  end if;

  begin
    update public.teams t
       set name          = coalesce(v_name, t.name),
           intro         = case when p_intro is null then t.intro
                                else nullif(btrim(p_intro), '') end,
           join_policy   = coalesce(p_join_policy, t.join_policy),
           home_store_id = case when p_clear_store then null
                                else coalesce(p_home_store_id, t.home_store_id) end,
           monthly_goal  = coalesce(p_monthly_goal, t.monthly_goal),
           updated_at    = now()
     where t.id = p_team_id and t.deleted_at is null;
  exception when unique_violation then
    return jsonb_build_object('ok', false, 'reason', 'name_taken',
                              'message', '已經有人用這個團名了，換一個吧');
  end;

  if not found then
    return jsonb_build_object('ok', false, 'reason', 'not_found', 'message', '找不到這個牌咖團');
  end if;

  return jsonb_build_object('ok', true, 'team', public._team_card(p_team_id));
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

-- [8.0] _ach_live:grant
grant execute on function public._ach_live(a achievements) to service_role;

-- [8.0] _ach_season_close_events:grant
grant execute on function public._ach_season_close_events(p_org uuid, p_season text) to service_role;

-- [8.0] _ach_session_events:grant
grant execute on function public._ach_session_events(p_session_id uuid) to service_role;

-- [8.0] _api_staff_only:grant
grant execute on function public._api_staff_only() to service_role;

-- [8.0] _blocked_between:grant
grant execute on function public._blocked_between(p_org_id uuid, p_a uuid, p_b uuid) to service_role;

-- [8.0] _booking_capacity:grant
grant execute on function public._booking_capacity(p_store_id uuid, p_play_at timestamp with time zone, p_hours integer, p_exclude uuid) to service_role;

-- [8.0] _booking_expire:grant
grant execute on function public._booking_expire(p_store_id uuid) to service_role;

-- [8.0] _booking_pick_table:grant
grant execute on function public._booking_pick_table(p_store_id uuid, p_play_at timestamp with time zone, p_hours integer, p_exclude uuid) to service_role;

-- [8.0] _booking_slots:grant
grant execute on function public._booking_slots(p_store_id uuid, p_day date, p_hours integer) to service_role;

-- [8.0] _cart_pricing:grant
grant execute on function public._cart_pricing(p_org uuid, p_member_id uuid, p_items jsonb, p_coupon_ids uuid[]) to service_role;

-- [8.0] _charge_core:grant
grant execute on function public._charge_core(p_member_id uuid, p_amount bigint, p_type txn_type, p_idempotency_key text, p_store_id uuid, p_served_store_id uuid, p_staff_id uuid, p_ref_table text, p_ref_id uuid, p_counter text) to service_role;

-- [8.0] _check_join_conflict:grant
grant execute on function public._check_join_conflict(p_org_id uuid, p_member uuid, p_play_at timestamp with time zone, p_source text) to service_role;

-- [8.0] _coupon_scope_label:grant
grant execute on function public._coupon_scope_label(p_coupon_id uuid) to service_role;

-- [8.0] _finalize_queue_full_tx:grant
grant execute on function public._finalize_queue_full_tx(p_org uuid, p_queue uuid, p_staff uuid) to service_role;

-- [8.0] _game_row:grant
grant execute on function public._game_row(p_org_id uuid, p_session_id uuid, p_member_id uuid) to service_role;

-- [8.0] _is_team_leader:grant
grant execute on function public._is_team_leader(p_team_id uuid, p_member_id uuid) to service_role;

-- [8.0] _join_plan:grant
grant execute on function public._join_plan(p_session_id uuid, p_member_id uuid, p_join_type text, p_pay_for uuid[], p_items jsonb) to service_role;

-- [8.0] _ma_row:grant
grant execute on function public._ma_row(p_member uuid, p_ach uuid, p_org uuid) to service_role;

-- [8.0] _member_bear_unlocks:grant
grant execute on function public._member_bear_unlocks(p_member uuid) to service_role;

-- [8.0] _member_home_store:grant
grant execute on function public._member_home_store(p_member_id uuid) to service_role;

-- [8.0] _member_orders_core:grant
grant execute on function public._member_orders_core(p_member_id uuid, p_limit integer, p_before timestamp with time zone) to service_role;

-- [8.0] _member_stats_core:grant
grant execute on function public._member_stats_core(p_org_id uuid, p_member_id uuid) to service_role;

-- [8.0] _member_titles:grant
grant execute on function public._member_titles(p_member uuid) to service_role;

-- [8.0] _pair_history:grant
grant execute on function public._pair_history(p_org_id uuid, p_a uuid, p_b uuid) to service_role;

-- [8.0] _pkg_ext_expected:grant
grant execute on function public._pkg_ext_expected(p_org uuid, p_sku text) to service_role;

-- [8.0] _pkg_ext_guard:grant
grant execute on function public._pkg_ext_guard() to service_role;

-- [8.0] _pkg_tier_sync:grant
grant execute on function public._pkg_tier_sync() to service_role;

-- [8.0] _pkg_time:grant
grant execute on function public._pkg_time(p_session_id uuid, p_with_ids boolean) to service_role;

-- [8.0] _rank_tier_of:grant
grant execute on function public._rank_tier_of(p_rank text) to service_role;

-- [8.0] _score_settle_tx:grant
grant execute on function public._score_settle_tx(p_session_id uuid) to service_role;

-- [8.0] _season_rank_rows_core:grant
grant execute on function public._season_rank_rows_core(p_org_id uuid, p_from timestamp with time zone, p_to timestamp with time zone, p_include_test boolean) to service_role;

-- [8.0] _session_scored:grant
grant execute on function public._session_scored(p_session_id uuid) to service_role;

-- [8.0] _tbl_balances:grant
grant execute on function public._tbl_balances(p_session_id uuid) to service_role;

-- [8.0] _tbl_device:grant
grant execute on function public._tbl_device(p_token text) to service_role;

-- [8.0] _tbl_hash:grant
grant execute on function public._tbl_hash(p_token text) to service_role;

-- [8.0] _tbl_ping:grant
grant execute on function public._tbl_ping(p_session_id uuid) to service_role;

-- [8.0] _tbl_round_state:grant
grant execute on function public._tbl_round_state(p_round_id uuid) to service_role;

-- [8.0] _tbl_state_for_device:grant
grant execute on function public._tbl_state_for_device(p_device table_devices) to service_role;

-- [8.0] _team_card:grant
grant execute on function public._team_card(p_team_id uuid) to service_role;

-- [8.0] _team_claim_check:grant
grant execute on function public._team_claim_check(p_team_id uuid, p_member_id uuid) to service_role;

-- [8.0] _team_disband:grant
grant execute on function public._team_disband(p_team_id uuid, p_by uuid) to service_role;

-- [8.0] _team_expire_requests:grant
grant execute on function public._team_expire_requests(p_team_id uuid) to service_role;

-- [8.0] _team_notify:grant
grant execute on function public._team_notify(p_org uuid, p_to uuid, p_type text, p_from_name text, p_text text, p_team_id uuid, p_team_name text, p_ref uuid) to service_role;

-- [8.0] _team_session_ids:grant
grant execute on function public._team_session_ids(p_team_id uuid) to service_role;

-- [8.0] _team_top_contributor:grant
grant execute on function public._team_top_contributor(p_team_id uuid, p_exclude uuid) to service_role;

-- [8.0] _try_auto_seat_tx:grant
grant execute on function public._try_auto_seat_tx(p_org uuid, p_queue uuid, p_staff uuid) to authenticated, service_role;

-- [8.0] _try_auto_seat_tx_core:grant
grant execute on function public._try_auto_seat_tx_core(p_org uuid, p_queue uuid, p_staff uuid) to service_role;

-- [8.0] ach_meta_count_tx:grant
grant execute on function public.ach_meta_count_tx(p_member uuid, p_scope text, p_value text) to service_role;

-- [8.0] ach_meta_tx:grant
grant execute on function public.ach_meta_tx(p_member uuid, p_idem text) to service_role;

-- [8.0] ach_pin_tx:grant
grant execute on function public.ach_pin_tx(p_code text, p_on boolean) to anon, authenticated, service_role;

-- [8.0] ach_progress_tx:grant
grant execute on function public.ach_progress_tx(p_member uuid, p_code text, p_delta bigint, p_idem text) to service_role;

-- [8.0] ach_streak_tx:grant
grant execute on function public.ach_streak_tx(p_member uuid, p_code text, p_period_key text, p_advance boolean, p_idem text) to service_role;

-- [8.0] ach_unlock_tx:grant
grant execute on function public.ach_unlock_tx(p_member uuid, p_code text, p_idem text) to service_role;

-- [8.0] activate_session_tx:grant
grant execute on function public.activate_session_tx(p_session_id uuid, p_staff_id uuid) to authenticated, service_role;

-- [8.0] admin_delete_product_tx:grant
grant execute on function public.admin_delete_product_tx(p_id uuid) to authenticated, service_role;

-- [8.0] admin_find_members_tx:grant
grant execute on function public.admin_find_members_tx(p_phone text) to authenticated, service_role;

-- [8.0] admin_hide_member_tx:grant
grant execute on function public.admin_hide_member_tx(p_member_id uuid, p_reason text) to authenticated, service_role;

-- [8.0] admin_list_member_tiers_tx:grant
grant execute on function public.admin_list_member_tiers_tx() to authenticated, service_role;

-- [8.0] admin_list_products_tx:grant
grant execute on function public.admin_list_products_tx() to authenticated, service_role;

-- [8.0] admin_list_stake_levels_tx:grant
grant execute on function public.admin_list_stake_levels_tx() to authenticated, service_role;

-- [8.0] admin_pair_table_device_tx:grant
grant execute on function public.admin_pair_table_device_tx(p_table_id uuid, p_label text) to authenticated, service_role;

-- [8.0] admin_remove_avatar_tx:grant
grant execute on function public.admin_remove_avatar_tx(p_member_id uuid, p_reason text, p_block boolean) to authenticated, service_role;

-- [8.0] admin_remove_team_crest_tx:grant
grant execute on function public.admin_remove_team_crest_tx(p_team_id uuid, p_reason text, p_block boolean) to authenticated, service_role;

-- [8.0] admin_search_sessions_tx:grant
grant execute on function public.admin_search_sessions_tx(p_from timestamp with time zone, p_to timestamp with time zone, p_store uuid, p_table_q text, p_member_q text, p_limit integer, p_before timestamp with time zone, p_before_id uuid) to authenticated, service_role;

-- [8.0] admin_set_product_active_tx:grant
grant execute on function public.admin_set_product_active_tx(p_id uuid, p_is_active boolean) to authenticated, service_role;

-- [8.0] admin_set_stake_start_points_tx:grant
grant execute on function public.admin_set_stake_start_points_tx(p_id uuid, p_start_points integer) to authenticated, service_role;

-- [8.0] admin_unhide_member_tx:grant
grant execute on function public.admin_unhide_member_tx(p_member_id uuid, p_reason text) to authenticated, service_role;

-- [8.0] admin_update_member_tier_tx:grant
grant execute on function public.admin_update_member_tier_tx(p_code text, p_label text, p_discount_pct integer, p_threshold_amount bigint, p_is_active boolean) to authenticated, service_role;

-- [8.0] admin_upsert_product_tx:grant
grant execute on function public.admin_upsert_product_tx(p_id uuid, p_sku text, p_name text, p_category text, p_subcategory text, p_revenue_type text, p_tracks_stock boolean, p_unit_price integer, p_unit_cost integer, p_stock_qty integer, p_is_active boolean, p_is_available boolean, p_spec text) to authenticated, service_role;

-- [8.0] app_events_no_mutate:grant
grant execute on function public.app_events_no_mutate() to anon, authenticated, service_role;

-- [8.0] apply_session_rounds_tx:grant
grant execute on function public.apply_session_rounds_tx(p_session_id uuid, p_rounds jsonb) to service_role;

-- [8.0] apply_team_tx:grant
grant execute on function public.apply_team_tx(p_team_id uuid) to authenticated, service_role;

-- [8.0] audit_wallet_balance:grant
grant execute on function public.audit_wallet_balance() to anon, authenticated, service_role;

-- [8.0] block_member_tx:grant
grant execute on function public.block_member_tx(p_org_id uuid, p_blocker uuid, p_blocked uuid) to anon, authenticated, service_role;

-- [8.0] block_txn_mutation:grant
grant execute on function public.block_txn_mutation() to anon, authenticated, service_role;

-- [8.0] booking_capacity_tx:grant
grant execute on function public.booking_capacity_tx(p_store_id uuid, p_play_at timestamp with time zone, p_hours integer) to authenticated, service_role;

-- [8.0] booking_slots_tx:grant
grant execute on function public.booking_slots_tx(p_store_id uuid, p_day date, p_hours integer) to authenticated, service_role;

-- [8.0] calc_session_fee_tx:grant
grant execute on function public.calc_session_fee_tx(p_session_id uuid, p_join_type text, p_member_id uuid) to authenticated, service_role;

-- [8.0] calc_topup_bonus_tx:grant
grant execute on function public.calc_topup_bonus_tx(p_org_id uuid, p_store_id uuid, p_amount_twd bigint) to service_role;

-- [8.0] can:grant
grant execute on function public.can(p_perm text) to authenticated, service_role;

-- [8.0] cancel_booking_tx:grant
grant execute on function public.cancel_booking_tx(p_booking_id uuid, p_reason text) to authenticated, service_role;

-- [8.0] cancel_team_request_tx:grant
grant execute on function public.cancel_team_request_tx(p_request_id uuid) to authenticated, service_role;

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

-- [8.0] claim_team_leader_tx:grant
grant execute on function public.claim_team_leader_tx(p_team_id uuid) to authenticated, service_role;

-- [8.0] cleanup_empty_sessions_tx:grant
grant execute on function public.cleanup_empty_sessions_tx(p_idle_minutes integer) to authenticated, service_role;

-- [8.0] clear_avatar_photo_tx:grant
grant execute on function public.clear_avatar_photo_tx(p_member_id uuid) to service_role;

-- [8.0] clear_team_crest_tx:grant
grant execute on function public.clear_team_crest_tx(p_team_id uuid, p_member_id uuid) to service_role;

-- [8.0] consume_snack_tx:grant
grant execute on function public.consume_snack_tx(p_org_id uuid, p_member_id uuid, p_kind text, p_qty integer, p_ref_id uuid, p_idem_key text) to anon, authenticated, service_role;

-- [8.0] create_booking_tx:grant
grant execute on function public.create_booking_tx(p_store_id uuid, p_play_at timestamp with time zone, p_hours integer, p_table_count integer, p_team_id uuid, p_party_size integer, p_note text, p_game_type text, p_flower text, p_stake_level_id uuid) to authenticated, service_role;

-- [8.0] create_invoice_draft_tx:grant
grant execute on function public.create_invoice_draft_tx(p_order_id uuid, p_idempotency_key text) to service_role;

-- [8.0] create_match_queue_tx:grant
grant execute on function public.create_match_queue_tx(p_org_id uuid, p_opener uuid, p_store uuid, p_stake uuid, p_play_at timestamp with time zone, p_game_type text, p_rounds text, p_seats integer, p_prefs jsonb, p_flower text) to anon, authenticated, service_role;

-- [8.0] create_team_invite_link_tx:grant
grant execute on function public.create_team_invite_link_tx(p_team_id uuid) to authenticated, service_role;

-- [8.0] create_team_tx:grant
grant execute on function public.create_team_tx(p_name text, p_crest_emoji text, p_intro text, p_join_policy text, p_home_store_id uuid) to authenticated, service_role;

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
grant execute on function public.daily_wallet_audit_tx(p_org_id uuid) to service_role;

-- [8.0] dev_clear_my_queues_tx:grant
grant execute on function public.dev_clear_my_queues_tx(p_org_id uuid, p_member uuid) to service_role;

-- [8.0] dev_reset_test_data_tx:grant
grant execute on function public.dev_reset_test_data_tx(p_reset_balance bigint) to service_role;

-- [8.0] dev_set_test_balance_tx:grant
grant execute on function public.dev_set_test_balance_tx(p_display_name text, p_balance bigint) to service_role;

-- [8.0] disband_team_tx:grant
grant execute on function public.disband_team_tx(p_team_id uuid) to authenticated, service_role;

-- [8.0] fire_event_tx:grant
grant execute on function public.fire_event_tx(p_member uuid, p_event text, p_delta bigint, p_period_key text, p_idem text) to service_role;

-- [8.0] fix_wallet_balance_tx:grant
grant execute on function public.fix_wallet_balance_tx(p_org_id uuid, p_member_id uuid) to service_role;

-- [8.0] generate_recurring_instances_tx:grant
grant execute on function public.generate_recurring_instances_tx(p_org_id uuid, p_days_ahead integer) to service_role;

-- [8.0] get_game_tx:grant
grant execute on function public.get_game_tx(p_org_id uuid, p_session_id uuid, p_member_id uuid) to anon, authenticated, service_role;

-- [8.0] get_member_by_line_tx:grant
grant execute on function public.get_member_by_line_tx(p_org_id uuid, p_line_user_id text) to service_role;

-- [8.0] get_member_card_tx:grant
grant execute on function public.get_member_card_tx(p_target uuid) to authenticated, service_role;

-- [8.0] get_my_achievements_tx:grant
grant execute on function public.get_my_achievements_tx() to authenticated, service_role;

-- [8.0] get_my_active_queue_tx:grant
grant execute on function public.get_my_active_queue_tx(p_org_id uuid, p_member uuid) to anon, authenticated, service_role;

-- [8.0] get_my_availability_tx:grant
grant execute on function public.get_my_availability_tx(p_org_id uuid, p_member_id uuid) to anon, authenticated, service_role;

-- [8.0] get_my_avatar_tx:grant
grant execute on function public.get_my_avatar_tx(p_member_id uuid) to authenticated, service_role;

-- [8.0] get_my_games_tx:grant
grant execute on function public.get_my_games_tx(p_org_id uuid, p_member_id uuid, p_limit integer) to authenticated, service_role;

-- [8.0] get_my_orders_tx:grant
grant execute on function public.get_my_orders_tx(p_member_id uuid, p_limit integer, p_before timestamp with time zone) to anon, authenticated, service_role;

-- [8.0] get_my_profile_tx:grant
grant execute on function public.get_my_profile_tx(p_org_id uuid, p_member_id uuid) to anon, authenticated, service_role;

-- [8.0] get_my_rank_tx:grant
grant execute on function public.get_my_rank_tx(p_org_id uuid, p_member_id uuid) to anon, authenticated, service_role;

-- [8.0] get_my_stats_tx:grant
grant execute on function public.get_my_stats_tx(p_org_id uuid, p_member_id uuid) to anon, authenticated, service_role;

-- [8.0] get_my_titles_tx:grant
grant execute on function public.get_my_titles_tx() to authenticated, service_role;

-- [8.0] get_order_tx:grant
grant execute on function public.get_order_tx(p_order_id uuid) to service_role;

-- [8.0] get_season_leaderboard_tx:grant
grant execute on function public.get_season_leaderboard_tx(p_org_id uuid, p_limit integer) to anon, authenticated, service_role;

-- [8.0] get_session_member_orders_tx:grant
grant execute on function public.get_session_member_orders_tx(p_session_id uuid, p_member_id uuid) to authenticated, service_role;

-- [8.0] get_session_tx:grant
grant execute on function public.get_session_tx(p_session_id uuid) to authenticated, service_role;

-- [8.0] get_staff_by_line_tx:grant
grant execute on function public.get_staff_by_line_tx(p_org_id uuid, p_line_user_id text) to service_role;

-- [8.0] get_store_detail_tx:grant
grant execute on function public.get_store_detail_tx(p_store_id uuid) to anon, authenticated, service_role;

-- [8.0] get_team_tx:grant
grant execute on function public.get_team_tx(p_team_id uuid) to authenticated, service_role;

-- [8.0] get_wallet_tx:grant
grant execute on function public.get_wallet_tx(p_member_id uuid, p_txn_limit integer) to anon, authenticated, service_role;

-- [8.0] grant_snack_tx:grant
grant execute on function public.grant_snack_tx(p_org_id uuid, p_member_id uuid, p_kind text, p_qty integer, p_reason text, p_ref_id uuid, p_idem_key text) to service_role;

-- [8.0] grant_staff_tx:grant
grant execute on function public.grant_staff_tx(p_member_id uuid, p_store_id uuid, p_role text, p_name text) to authenticated, service_role;

-- [8.0] has_daypass_tx:grant
grant execute on function public.has_daypass_tx(p_org_id uuid, p_member_id uuid, p_store_id uuid) to authenticated, service_role;

-- [8.0] has_daypass_tx_core:grant
grant execute on function public.has_daypass_tx_core(p_org_id uuid, p_member_id uuid, p_store_id uuid) to service_role;

-- [8.0] has_store_access:grant
grant execute on function public.has_store_access(p_store_id uuid) to authenticated, service_role;

-- [8.0] hide_my_account_tx:grant
grant execute on function public.hide_my_account_tx() to authenticated, service_role;

-- [8.0] invite_to_team_tx:grant
grant execute on function public.invite_to_team_tx(p_team_id uuid, p_member_id uuid) to authenticated, service_role;

-- [8.0] join_match_queue_tx:grant
grant execute on function public.join_match_queue_tx(p_org_id uuid, p_member uuid, p_queue uuid, p_join_source text) to anon, authenticated, service_role;

-- [8.0] join_session_tx:grant
grant execute on function public.join_session_tx(p_session_id uuid, p_member_id uuid, p_join_type text, p_coupon_ids uuid[], p_points_used bigint, p_payments jsonb, p_staff_id uuid, p_idempotency_key text, p_pay_for uuid[], p_items jsonb) to authenticated, service_role;

-- [8.0] kick_team_member_tx:grant
grant execute on function public.kick_team_member_tx(p_team_id uuid, p_member_id uuid) to authenticated, service_role;

-- [8.0] leave_match_queue_tx:grant
grant execute on function public.leave_match_queue_tx(p_org_id uuid, p_member uuid, p_queue uuid, p_reason text) to anon, authenticated, service_role;

-- [8.0] leave_team_tx:grant
grant execute on function public.leave_team_tx(p_team_id uuid) to authenticated, service_role;

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

-- [8.0] list_hot_teams_tx:grant
grant execute on function public.list_hot_teams_tx(p_limit integer) to authenticated, service_role;

-- [8.0] list_match_queues_by_city_tx:grant
grant execute on function public.list_match_queues_by_city_tx(p_org_id uuid, p_member uuid, p_city text, p_area text) to anon, authenticated, service_role;

-- [8.0] list_match_queues_tx:grant
grant execute on function public.list_match_queues_tx(p_org_id uuid, p_member uuid, p_store uuid) to anon, authenticated, service_role;

-- [8.0] list_member_tiers_tx:grant
grant execute on function public.list_member_tiers_tx() to anon, authenticated, service_role;

-- [8.0] list_members_tx:grant
grant execute on function public.list_members_tx(p_org_id uuid, p_limit integer) to service_role;

-- [8.0] list_my_bookings_tx:grant
grant execute on function public.list_my_bookings_tx() to authenticated, service_role;

-- [8.0] list_my_teams_tx:grant
grant execute on function public.list_my_teams_tx() to authenticated, service_role;

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

-- [8.0] list_table_devices_tx:grant
grant execute on function public.list_table_devices_tx(p_store_id uuid) to authenticated, service_role;

-- [8.0] list_tables_tx:grant
grant execute on function public.list_tables_tx(p_org_id uuid, p_store_id uuid) to authenticated, service_role;

-- [8.0] list_team_requests_tx:grant
grant execute on function public.list_team_requests_tx(p_team_id uuid) to authenticated, service_role;

-- [8.0] list_topup_plans_tx:grant
grant execute on function public.list_topup_plans_tx(p_org_id uuid, p_store_id uuid) to anon, authenticated, service_role;

-- [8.0] log_app_event_tx:grant
grant execute on function public.log_app_event_tx(p_org_id uuid, p_member_id uuid, p_event text, p_props jsonb, p_client_ts timestamp with time zone, p_store_id uuid) to anon, authenticated, service_role;

-- [8.0] mark_app_active_tx:grant
grant execute on function public.mark_app_active_tx(p_org_id uuid, p_member_id uuid) to anon, authenticated, service_role;

-- [8.0] mark_invoice_failed_tx:grant
grant execute on function public.mark_invoice_failed_tx(p_invoice_id uuid, p_raw jsonb) to service_role;

-- [8.0] mark_invoice_issued_tx:grant
grant execute on function public.mark_invoice_issued_tx(p_invoice_id uuid, p_invoice_no text, p_random text, p_period text, p_provider text, p_provider_ref text, p_raw jsonb, p_donate_org_name text) to service_role;

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
grant execute on function public.next_doc_no(p_org_id uuid, p_store_id uuid, p_doc_type text) to authenticated, service_role;

-- [8.0] open_session_tx:grant
grant execute on function public.open_session_tx(p_table_id uuid, p_mode text, p_stake_level_id uuid, p_planned_rounds integer, p_planned_minutes integer, p_staff_id uuid, p_open_method text, p_idempotency_key text, p_game_type text, p_flower text) to authenticated, service_role;

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

-- [8.0] pos_clear_on_duty_tx:grant
grant execute on function public.pos_clear_on_duty_tx() to authenticated, service_role;

-- [8.0] pos_close_queue_tx:grant
grant execute on function public.pos_close_queue_tx(p_org_id uuid, p_queue uuid) to authenticated, service_role;

-- [8.0] pos_create_queue_tx:grant
grant execute on function public.pos_create_queue_tx(p_org_id uuid, p_store uuid, p_stake uuid, p_play_at timestamp with time zone, p_game_type text, p_flower text, p_rounds text, p_seats integer, p_tags jsonb) to authenticated, service_role;

-- [8.0] pos_create_recurring_tx:grant
grant execute on function public.pos_create_recurring_tx(p_org_id uuid, p_store uuid, p_stake uuid, p_frequency text, p_weekday integer, p_start_time time without time zone, p_game_type text, p_flower text, p_rounds text, p_seats integer, p_lead_hours integer, p_tags jsonb) to authenticated, service_role;

-- [8.0] pos_list_bookings_tx:grant
grant execute on function public.pos_list_bookings_tx(p_store_id uuid, p_day date) to authenticated, service_role;

-- [8.0] pos_list_queues_tx:grant
grant execute on function public.pos_list_queues_tx(p_org uuid, p_store uuid, p_before timestamp with time zone, p_limit integer) to authenticated, service_role;

-- [8.0] pos_list_queues_tx_core:grant
grant execute on function public.pos_list_queues_tx_core(p_org uuid, p_store uuid, p_before timestamp with time zone, p_limit integer) to service_role;

-- [8.0] pos_list_recurring_tx:grant
grant execute on function public.pos_list_recurring_tx(p_org_id uuid, p_store uuid) to authenticated, service_role;

-- [8.0] pos_list_recurring_tx_core:grant
grant execute on function public.pos_list_recurring_tx_core(p_org_id uuid, p_store uuid) to service_role;

-- [8.0] pos_mark_booking_tx:grant
grant execute on function public.pos_mark_booking_tx(p_booking_id uuid, p_status text, p_reason text) to authenticated, service_role;

-- [8.0] pos_member_detail_tx:grant
grant execute on function public.pos_member_detail_tx(p_org_id uuid, p_member_id uuid) to authenticated, service_role;

-- [8.0] pos_member_orders_tx:grant
grant execute on function public.pos_member_orders_tx(p_member_id uuid, p_limit integer, p_before timestamp with time zone) to authenticated, service_role;

-- [8.0] pos_move_queue_member_tx:grant
grant execute on function public.pos_move_queue_member_tx(p_org uuid, p_from_queue uuid, p_to_queue uuid, p_member uuid) to authenticated, service_role;

-- [8.0] pos_move_session_tx:grant
grant execute on function public.pos_move_session_tx(p_session_id uuid, p_table_id uuid, p_staff_id uuid) to authenticated, service_role;

-- [8.0] pos_pkg_extend_tx:grant
grant execute on function public.pos_pkg_extend_tx(p_session_id uuid, p_member_id uuid, p_for uuid[], p_kind text, p_points_used bigint, p_payments jsonb, p_idempotency_key text) to authenticated, service_role;

-- [8.0] pos_pkg_quote_tx:grant
grant execute on function public.pos_pkg_quote_tx(p_session_id uuid, p_member_id uuid, p_for uuid[], p_kind text) to authenticated, service_role;

-- [8.0] pos_pkg_state_tx:grant
grant execute on function public.pos_pkg_state_tx(p_session_id uuid) to authenticated, service_role;

-- [8.0] pos_queue_members_tx:grant
grant execute on function public.pos_queue_members_tx(p_org_id uuid, p_queue uuid) to authenticated, service_role;

-- [8.0] pos_queue_members_tx_core:grant
grant execute on function public.pos_queue_members_tx_core(p_org_id uuid, p_queue uuid) to service_role;

-- [8.0] pos_quick_checkout_tx:grant
grant execute on function public.pos_quick_checkout_tx(p_member_id uuid, p_store_id uuid, p_items jsonb, p_coupon_ids uuid[], p_points_used bigint, p_payments jsonb, p_idempotency_key text, p_staff_id uuid, p_topup_points bigint, p_topup_amount bigint, p_topup_method text, p_topup_cash_received bigint, p_topup_change_given bigint, p_note text) to authenticated, service_role;

-- [8.0] pos_quote_tx:grant
grant execute on function public.pos_quote_tx(p_session_id uuid, p_member_id uuid, p_join_type text, p_pay_for uuid[], p_items jsonb, p_coupon_ids uuid[]) to authenticated, service_role;

-- [8.0] pos_remove_queue_member_tx:grant
grant execute on function public.pos_remove_queue_member_tx(p_org uuid, p_queue uuid, p_member uuid, p_reason text) to authenticated, service_role;

-- [8.0] pos_search_members_tx:grant
grant execute on function public.pos_search_members_tx(p_org_id uuid, p_keyword text) to authenticated, service_role;

-- [8.0] pos_seat_booking_tx:grant
grant execute on function public.pos_seat_booking_tx(p_booking_id uuid, p_table_id uuid, p_session_id uuid) to authenticated, service_role;

-- [8.0] pos_seat_queue_tx:grant
grant execute on function public.pos_seat_queue_tx(p_org_id uuid, p_queue uuid, p_table_id uuid, p_staff_id uuid) to authenticated, service_role;

-- [8.0] pos_set_on_duty_tx:grant
grant execute on function public.pos_set_on_duty_tx(p_store_id uuid) to authenticated, service_role;

-- [8.0] pos_set_recurring_enabled_tx:grant
grant execute on function public.pos_set_recurring_enabled_tx(p_org_id uuid, p_id uuid, p_enabled boolean) to authenticated, service_role;

-- [8.0] pos_set_recurring_tags_tx:grant
grant execute on function public.pos_set_recurring_tags_tx(p_org_id uuid, p_id uuid, p_tags jsonb) to service_role;

-- [8.0] pos_table_forecast_tx:grant
grant execute on function public.pos_table_forecast_tx(p_org uuid, p_store uuid, p_at timestamp with time zone) to authenticated, service_role;

-- [8.0] pos_table_forecast_tx_core:grant
grant execute on function public.pos_table_forecast_tx_core(p_org uuid, p_store uuid, p_at timestamp with time zone) to service_role;

-- [8.0] pos_tbl_watch_tx:grant
grant execute on function public.pos_tbl_watch_tx(p_table_id uuid) to authenticated, service_role;

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
grant execute on function public.reconcile_wallets_tx(p_org_id uuid) to service_role;

-- [8.0] redeem_team_invite_tx:grant
grant execute on function public.redeem_team_invite_tx(p_token text) to authenticated, service_role;

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

-- [8.0] respond_team_request_tx:grant
grant execute on function public.respond_team_request_tx(p_request_id uuid, p_accept boolean) to authenticated, service_role;

-- [8.0] reverse_txn_tx:grant
grant execute on function public.reverse_txn_tx(p_original_txn_id uuid, p_idempotency_key text, p_reason text) to service_role;

-- [8.0] revoke_staff_tx:grant
grant execute on function public.revoke_staff_tx(p_staff_id uuid) to authenticated, service_role;

-- [8.0] revoke_table_device_tx:grant
grant execute on function public.revoke_table_device_tx(p_device_id uuid) to authenticated, service_role;

-- [8.0] save_app_state_tx:grant
grant execute on function public.save_app_state_tx(p_org_id uuid, p_member_id uuid, p_bear jsonb, p_titles jsonb) to anon, authenticated, service_role;

-- [8.0] search_teams_tx:grant
grant execute on function public.search_teams_tx(p_q text, p_limit integer) to authenticated, service_role;

-- [8.0] season_rank_rows_display_tx:grant
grant execute on function public.season_rank_rows_display_tx(p_org_id uuid, p_from timestamp with time zone, p_to timestamp with time zone) to service_role;

-- [8.0] season_rank_rows_tx:grant
grant execute on function public.season_rank_rows_tx(p_org_id uuid, p_from timestamp with time zone, p_to timestamp with time zone) to service_role;

-- [8.0] send_buddy_invite_tx:grant
grant execute on function public.send_buddy_invite_tx(p_org_id uuid, p_inviter uuid, p_invitee uuid) to anon, authenticated, service_role;

-- [8.0] send_table_invite_tx:grant
grant execute on function public.send_table_invite_tx(p_org_id uuid, p_inviter uuid, p_invitee uuid, p_queue uuid) to anon, authenticated, service_role;

-- [8.0] set_avatar_tx:grant
grant execute on function public.set_avatar_tx(p_member_id uuid, p_source text, p_path text, p_bear text) to authenticated, service_role;

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
grant execute on function public.set_table_active_tx(p_table_id uuid, p_active boolean, p_note text) to authenticated, service_role;

-- [8.0] set_table_auto_assign_tx:grant
grant execute on function public.set_table_auto_assign_tx(p_table_id uuid, p_auto boolean) to authenticated, service_role;

-- [8.0] set_team_co_leader_tx:grant
grant execute on function public.set_team_co_leader_tx(p_team_id uuid, p_member_id uuid, p_on boolean) to authenticated, service_role;

-- [8.0] set_team_crest_source_tx:grant
grant execute on function public.set_team_crest_source_tx(p_team_id uuid, p_source text) to authenticated, service_role;

-- [8.0] set_team_crest_tx:grant
grant execute on function public.set_team_crest_tx(p_team_id uuid, p_emoji text, p_path text) to authenticated, service_role;

-- [8.0] set_updated_at:grant
grant execute on function public.set_updated_at() to anon, authenticated, service_role;

-- [8.0] settle_session_tx:grant
grant execute on function public.settle_session_tx(p_session_id uuid, p_staff_id uuid, p_keep_for_walkin boolean) to authenticated, service_role;

-- [8.0] sweep_auto_seat_tx:grant
grant execute on function public.sweep_auto_seat_tx(p_org uuid) to authenticated, service_role;

-- [8.0] sweep_expired_queues_tx:grant
grant execute on function public.sweep_expired_queues_tx(p_org_id uuid) to service_role;

-- [8.0] sweep_season_close_tx:grant
grant execute on function public.sweep_season_close_tx() to service_role;

-- [8.0] sweep_team_leaders_tx:grant
grant execute on function public.sweep_team_leaders_tx(p_org_id uuid) to service_role;

-- [8.0] tbl_bust_decide_tx:grant
grant execute on function public.tbl_bust_decide_tx(p_token text, p_amount integer) to anon, authenticated, service_role;

-- [8.0] tbl_cancel_pending_tx:grant
grant execute on function public.tbl_cancel_pending_tx(p_token text) to anon, authenticated, service_role;

-- [8.0] tbl_claim_seat_tx:grant
grant execute on function public.tbl_claim_seat_tx(p_token text, p_player_id uuid) to anon, authenticated, service_role;

-- [8.0] tbl_confirm_hand_tx:grant
grant execute on function public.tbl_confirm_hand_tx(p_token text, p_hand_id uuid, p_accept boolean) to anon, authenticated, service_role;

-- [8.0] tbl_release_seat_tx:grant
grant execute on function public.tbl_release_seat_tx(p_token text) to anon, authenticated, service_role;

-- [8.0] tbl_set_order_tx:grant
grant execute on function public.tbl_set_order_tx(p_token text, p_dealer uuid, p_next uuid, p_opposite uuid) to anon, authenticated, service_role;

-- [8.0] tbl_start_round_tx:grant
grant execute on function public.tbl_start_round_tx(p_token text, p_dealer_seat smallint, p_next_seat smallint, p_opposite_seat smallint) to anon, authenticated, service_role;

-- [8.0] tbl_state_tx:grant
grant execute on function public.tbl_state_tx(p_token text) to anon, authenticated, service_role;

-- [8.0] tbl_submit_hand_tx:grant
grant execute on function public.tbl_submit_hand_tx(p_token text, p_result text, p_deal_in_seat smallint, p_patterns jsonb) to anon, authenticated, service_role;

-- [8.0] tbl_undo_last_tx:grant
grant execute on function public.tbl_undo_last_tx(p_token text) to anon, authenticated, service_role;

-- [8.0] team_crest_guard_tx:grant
grant execute on function public.team_crest_guard_tx(p_team_id uuid, p_member_id uuid) to service_role;

-- [8.0] topup_tx:grant
grant execute on function public.topup_tx(p_member_id uuid, p_store_id uuid, p_points bigint, p_amount_twd bigint, p_pay_method text, p_idempotency_key text, p_bonus_points bigint, p_external_ref text, p_staff_id uuid, p_note text) to authenticated, service_role;

-- [8.0] topup_void_tx:grant
grant execute on function public.topup_void_tx(p_topup_id uuid, p_idempotency_key text, p_staff_id uuid, p_reason text) to authenticated, service_role;

-- [8.0] transfer_team_leader_tx:grant
grant execute on function public.transfer_team_leader_tx(p_team_id uuid, p_to_member_id uuid) to authenticated, service_role;

-- [8.0] trg_buddies_achievements:grant
grant execute on function public.trg_buddies_achievements() to service_role;

-- [8.0] trg_coupon_scopes_check:grant
grant execute on function public.trg_coupon_scopes_check() to service_role;

-- [8.0] trg_coupon_set_code:grant
grant execute on function public.trg_coupon_set_code() to anon, authenticated, service_role;

-- [8.0] trg_coupons_applies_to_frozen:grant
grant execute on function public.trg_coupons_applies_to_frozen() to service_role;

-- [8.0] trg_hands_bust_clamp:grant
grant execute on function public.trg_hands_bust_clamp() to service_role;

-- [8.0] trg_hands_bust_detect:grant
grant execute on function public.trg_hands_bust_detect() to service_role;

-- [8.0] trg_match_queues_credit:grant
grant execute on function public.trg_match_queues_credit() to service_role;

-- [8.0] trg_member_likes_achievements:grant
grant execute on function public.trg_member_likes_achievements() to service_role;

-- [8.0] trg_members_achievements:grant
grant execute on function public.trg_members_achievements() to service_role;

-- [8.0] trg_members_best_rank:grant
grant execute on function public.trg_members_best_rank() to service_role;

-- [8.0] trg_members_norm_display_name:grant
grant execute on function public.trg_members_norm_display_name() to anon, authenticated, service_role;

-- [8.0] trg_members_rank_achievements:grant
grant execute on function public.trg_members_rank_achievements() to service_role;

-- [8.0] trg_members_rank_events:grant
grant execute on function public.trg_members_rank_events() to service_role;

-- [8.0] trg_order_items_achievements:grant
grant execute on function public.trg_order_items_achievements() to service_role;

-- [8.0] trg_orders_set_no:grant
grant execute on function public.trg_orders_set_no() to anon, authenticated, service_role;

-- [8.0] trg_orders_touch_member_visit:grant
grant execute on function public.trg_orders_touch_member_visit() to anon, authenticated, service_role;

-- [8.0] trg_orders_upgrade_tier:grant
grant execute on function public.trg_orders_upgrade_tier() to anon, authenticated, service_role;

-- [8.0] trg_session_rounds_auto_score:grant
grant execute on function public.trg_session_rounds_auto_score() to service_role;

-- [8.0] trg_session_rounds_guard:grant
grant execute on function public.trg_session_rounds_guard() to service_role;

-- [8.0] trg_session_voided_release_queue:grant
grant execute on function public.trg_session_voided_release_queue() to anon, authenticated, service_role;

-- [8.0] trg_snack_achievements:grant
grant execute on function public.trg_snack_achievements() to service_role;

-- [8.0] trg_team_members_achievements:grant
grant execute on function public.trg_team_members_achievements() to service_role;

-- [8.0] trg_teams_achievements:grant
grant execute on function public.trg_teams_achievements() to service_role;

-- [8.0] trg_topup_achievements:grant
grant execute on function public.trg_topup_achievements() to service_role;

-- [8.0] trg_topup_set_no:grant
grant execute on function public.trg_topup_set_no() to anon, authenticated, service_role;

-- [8.0] unblock_member_tx:grant
grant execute on function public.unblock_member_tx(p_org_id uuid, p_blocker uuid, p_blocked uuid) to anon, authenticated, service_role;

-- [8.0] unread_count_tx:grant
grant execute on function public.unread_count_tx(p_org_id uuid, p_member uuid) to anon, authenticated, service_role;

-- [8.0] update_play_at_tx:grant
grant execute on function public.update_play_at_tx(p_org_id uuid, p_queue uuid, p_new_play_at timestamp with time zone) to anon, authenticated, service_role;

-- [8.0] update_team_tx:grant
grant execute on function public.update_team_tx(p_team_id uuid, p_name text, p_intro text, p_join_policy text, p_home_store_id uuid, p_clear_store boolean, p_monthly_goal integer) to authenticated, service_role;

-- [8.0] void_invoice_tx:grant
grant execute on function public.void_invoice_tx(p_invoice_id uuid, p_reason text, p_reissue boolean, p_idempotency_key text) to service_role;

-- [8.0] void_session_tx:grant
grant execute on function public.void_session_tx(p_session_id uuid, p_staff_id uuid) to authenticated, service_role;

-- [8.1] _ach_live:revoke-public
revoke execute on function public._ach_live(a achievements) from public;

-- [8.1] _ach_season_close_events:revoke-public
revoke execute on function public._ach_season_close_events(p_org uuid, p_season text) from public;

-- [8.1] _ach_session_events:revoke-public
revoke execute on function public._ach_session_events(p_session_id uuid) from public;

-- [8.1] _api_staff_only:revoke-public
revoke execute on function public._api_staff_only() from public;

-- [8.1] _blocked_between:revoke-public
revoke execute on function public._blocked_between(p_org_id uuid, p_a uuid, p_b uuid) from public;

-- [8.1] _booking_capacity:revoke-public
revoke execute on function public._booking_capacity(p_store_id uuid, p_play_at timestamp with time zone, p_hours integer, p_exclude uuid) from public;

-- [8.1] _booking_expire:revoke-public
revoke execute on function public._booking_expire(p_store_id uuid) from public;

-- [8.1] _booking_pick_table:revoke-public
revoke execute on function public._booking_pick_table(p_store_id uuid, p_play_at timestamp with time zone, p_hours integer, p_exclude uuid) from public;

-- [8.1] _booking_slots:revoke-public
revoke execute on function public._booking_slots(p_store_id uuid, p_day date, p_hours integer) from public;

-- [8.1] _cart_pricing:revoke-public
revoke execute on function public._cart_pricing(p_org uuid, p_member_id uuid, p_items jsonb, p_coupon_ids uuid[]) from public;

-- [8.1] _charge_core:revoke-public
revoke execute on function public._charge_core(p_member_id uuid, p_amount bigint, p_type txn_type, p_idempotency_key text, p_store_id uuid, p_served_store_id uuid, p_staff_id uuid, p_ref_table text, p_ref_id uuid, p_counter text) from public;

-- [8.1] _check_join_conflict:revoke-public
revoke execute on function public._check_join_conflict(p_org_id uuid, p_member uuid, p_play_at timestamp with time zone, p_source text) from public;

-- [8.1] _coupon_scope_label:revoke-public
revoke execute on function public._coupon_scope_label(p_coupon_id uuid) from public;

-- [8.1] _finalize_queue_full_tx:revoke-public
revoke execute on function public._finalize_queue_full_tx(p_org uuid, p_queue uuid, p_staff uuid) from public;

-- [8.1] _game_row:revoke-public
revoke execute on function public._game_row(p_org_id uuid, p_session_id uuid, p_member_id uuid) from public;

-- [8.1] _is_team_leader:revoke-public
revoke execute on function public._is_team_leader(p_team_id uuid, p_member_id uuid) from public;

-- [8.1] _join_plan:revoke-public
revoke execute on function public._join_plan(p_session_id uuid, p_member_id uuid, p_join_type text, p_pay_for uuid[], p_items jsonb) from public;

-- [8.1] _ma_row:revoke-public
revoke execute on function public._ma_row(p_member uuid, p_ach uuid, p_org uuid) from public;

-- [8.1] _member_bear_unlocks:revoke-public
revoke execute on function public._member_bear_unlocks(p_member uuid) from public;

-- [8.1] _member_hide_core:revoke-public
revoke execute on function public._member_hide_core(p_member uuid, p_source text, p_staff uuid, p_reason text) from public;

-- [8.1] _member_home_store:revoke-public
revoke execute on function public._member_home_store(p_member_id uuid) from public;

-- [8.1] _member_orders_core:revoke-public
revoke execute on function public._member_orders_core(p_member_id uuid, p_limit integer, p_before timestamp with time zone) from public;

-- [8.1] _member_stats_core:revoke-public
revoke execute on function public._member_stats_core(p_org_id uuid, p_member_id uuid) from public;

-- [8.1] _member_titles:revoke-public
revoke execute on function public._member_titles(p_member uuid) from public;

-- [8.1] _member_unhide_core:revoke-public
revoke execute on function public._member_unhide_core(p_member uuid, p_staff uuid, p_reason text) from public;

-- [8.1] _pair_history:revoke-public
revoke execute on function public._pair_history(p_org_id uuid, p_a uuid, p_b uuid) from public;

-- [8.1] _pkg_ext_expected:revoke-public
revoke execute on function public._pkg_ext_expected(p_org uuid, p_sku text) from public;

-- [8.1] _pkg_ext_guard:revoke-public
revoke execute on function public._pkg_ext_guard() from public;

-- [8.1] _pkg_tier_sync:revoke-public
revoke execute on function public._pkg_tier_sync() from public;

-- [8.1] _pkg_time:revoke-public
revoke execute on function public._pkg_time(p_session_id uuid, p_with_ids boolean) from public;

-- [8.1] _rank_tier_of:revoke-public
revoke execute on function public._rank_tier_of(p_rank text) from public;

-- [8.1] _score_settle_tx:revoke-public
revoke execute on function public._score_settle_tx(p_session_id uuid) from public;

-- [8.1] _season_rank_rows_core:revoke-public
revoke execute on function public._season_rank_rows_core(p_org_id uuid, p_from timestamp with time zone, p_to timestamp with time zone, p_include_test boolean) from public;

-- [8.1] _session_scored:revoke-public
revoke execute on function public._session_scored(p_session_id uuid) from public;

-- [8.1] _tbl_balances:revoke-public
revoke execute on function public._tbl_balances(p_session_id uuid) from public;

-- [8.1] _tbl_device:revoke-public
revoke execute on function public._tbl_device(p_token text) from public;

-- [8.1] _tbl_hash:revoke-public
revoke execute on function public._tbl_hash(p_token text) from public;

-- [8.1] _tbl_ping:revoke-public
revoke execute on function public._tbl_ping(p_session_id uuid) from public;

-- [8.1] _tbl_round_state:revoke-public
revoke execute on function public._tbl_round_state(p_round_id uuid) from public;

-- [8.1] _tbl_state_for_device:revoke-public
revoke execute on function public._tbl_state_for_device(p_device table_devices) from public;

-- [8.1] _team_card:revoke-public
revoke execute on function public._team_card(p_team_id uuid) from public;

-- [8.1] _team_claim_check:revoke-public
revoke execute on function public._team_claim_check(p_team_id uuid, p_member_id uuid) from public;

-- [8.1] _team_disband:revoke-public
revoke execute on function public._team_disband(p_team_id uuid, p_by uuid) from public;

-- [8.1] _team_expire_requests:revoke-public
revoke execute on function public._team_expire_requests(p_team_id uuid) from public;

-- [8.1] _team_notify:revoke-public
revoke execute on function public._team_notify(p_org uuid, p_to uuid, p_type text, p_from_name text, p_text text, p_team_id uuid, p_team_name text, p_ref uuid) from public;

-- [8.1] _team_session_ids:revoke-public
revoke execute on function public._team_session_ids(p_team_id uuid) from public;

-- [8.1] _team_top_contributor:revoke-public
revoke execute on function public._team_top_contributor(p_team_id uuid, p_exclude uuid) from public;

-- [8.1] _try_auto_seat_tx:revoke-public
revoke execute on function public._try_auto_seat_tx(p_org uuid, p_queue uuid, p_staff uuid) from public;

-- [8.1] _try_auto_seat_tx_core:revoke-public
revoke execute on function public._try_auto_seat_tx_core(p_org uuid, p_queue uuid, p_staff uuid) from public;

-- [8.1] ach_meta_count_tx:revoke-public
revoke execute on function public.ach_meta_count_tx(p_member uuid, p_scope text, p_value text) from public;

-- [8.1] ach_meta_tx:revoke-public
revoke execute on function public.ach_meta_tx(p_member uuid, p_idem text) from public;

-- [8.1] ach_pin_tx:revoke-public
revoke execute on function public.ach_pin_tx(p_code text, p_on boolean) from public;

-- [8.1] ach_progress_tx:revoke-public
revoke execute on function public.ach_progress_tx(p_member uuid, p_code text, p_delta bigint, p_idem text) from public;

-- [8.1] ach_streak_tx:revoke-public
revoke execute on function public.ach_streak_tx(p_member uuid, p_code text, p_period_key text, p_advance boolean, p_idem text) from public;

-- [8.1] ach_unlock_tx:revoke-public
revoke execute on function public.ach_unlock_tx(p_member uuid, p_code text, p_idem text) from public;

-- [8.1] activate_session_tx:revoke-public
revoke execute on function public.activate_session_tx(p_session_id uuid, p_staff_id uuid) from public;

-- [8.1] admin_delete_product_tx:revoke-public
revoke execute on function public.admin_delete_product_tx(p_id uuid) from public;

-- [8.1] admin_find_members_tx:revoke-public
revoke execute on function public.admin_find_members_tx(p_phone text) from public;

-- [8.1] admin_hide_member_tx:revoke-public
revoke execute on function public.admin_hide_member_tx(p_member_id uuid, p_reason text) from public;

-- [8.1] admin_list_member_tiers_tx:revoke-public
revoke execute on function public.admin_list_member_tiers_tx() from public;

-- [8.1] admin_list_products_tx:revoke-public
revoke execute on function public.admin_list_products_tx() from public;

-- [8.1] admin_list_stake_levels_tx:revoke-public
revoke execute on function public.admin_list_stake_levels_tx() from public;

-- [8.1] admin_pair_table_device_tx:revoke-public
revoke execute on function public.admin_pair_table_device_tx(p_table_id uuid, p_label text) from public;

-- [8.1] admin_remove_avatar_tx:revoke-public
revoke execute on function public.admin_remove_avatar_tx(p_member_id uuid, p_reason text, p_block boolean) from public;

-- [8.1] admin_remove_team_crest_tx:revoke-public
revoke execute on function public.admin_remove_team_crest_tx(p_team_id uuid, p_reason text, p_block boolean) from public;

-- [8.1] admin_search_sessions_tx:revoke-public
revoke execute on function public.admin_search_sessions_tx(p_from timestamp with time zone, p_to timestamp with time zone, p_store uuid, p_table_q text, p_member_q text, p_limit integer, p_before timestamp with time zone, p_before_id uuid) from public;

-- [8.1] admin_set_product_active_tx:revoke-public
revoke execute on function public.admin_set_product_active_tx(p_id uuid, p_is_active boolean) from public;

-- [8.1] admin_set_stake_start_points_tx:revoke-public
revoke execute on function public.admin_set_stake_start_points_tx(p_id uuid, p_start_points integer) from public;

-- [8.1] admin_unhide_member_tx:revoke-public
revoke execute on function public.admin_unhide_member_tx(p_member_id uuid, p_reason text) from public;

-- [8.1] admin_update_member_tier_tx:revoke-public
revoke execute on function public.admin_update_member_tier_tx(p_code text, p_label text, p_discount_pct integer, p_threshold_amount bigint, p_is_active boolean) from public;

-- [8.1] admin_upsert_product_tx:revoke-public
revoke execute on function public.admin_upsert_product_tx(p_id uuid, p_sku text, p_name text, p_category text, p_subcategory text, p_revenue_type text, p_tracks_stock boolean, p_unit_price integer, p_unit_cost integer, p_stock_qty integer, p_is_active boolean, p_is_available boolean, p_spec text) from public;

-- [8.1] apply_session_rounds_tx:revoke-public
revoke execute on function public.apply_session_rounds_tx(p_session_id uuid, p_rounds jsonb) from public;

-- [8.1] apply_team_tx:revoke-public
revoke execute on function public.apply_team_tx(p_team_id uuid) from public;

-- [8.1] booking_capacity_tx:revoke-public
revoke execute on function public.booking_capacity_tx(p_store_id uuid, p_play_at timestamp with time zone, p_hours integer) from public;

-- [8.1] booking_slots_tx:revoke-public
revoke execute on function public.booking_slots_tx(p_store_id uuid, p_day date, p_hours integer) from public;

-- [8.1] calc_session_fee_tx:revoke-public
revoke execute on function public.calc_session_fee_tx(p_session_id uuid, p_join_type text, p_member_id uuid) from public;

-- [8.1] calc_topup_bonus_tx:revoke-public
revoke execute on function public.calc_topup_bonus_tx(p_org_id uuid, p_store_id uuid, p_amount_twd bigint) from public;

-- [8.1] can:revoke-public
revoke execute on function public.can(p_perm text) from public;

-- [8.1] cancel_booking_tx:revoke-public
revoke execute on function public.cancel_booking_tx(p_booking_id uuid, p_reason text) from public;

-- [8.1] cancel_team_request_tx:revoke-public
revoke execute on function public.cancel_team_request_tx(p_request_id uuid) from public;

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

-- [8.1] claim_team_leader_tx:revoke-public
revoke execute on function public.claim_team_leader_tx(p_team_id uuid) from public;

-- [8.1] cleanup_empty_sessions_tx:revoke-public
revoke execute on function public.cleanup_empty_sessions_tx(p_idle_minutes integer) from public;

-- [8.1] clear_avatar_photo_tx:revoke-public
revoke execute on function public.clear_avatar_photo_tx(p_member_id uuid) from public;

-- [8.1] clear_team_crest_tx:revoke-public
revoke execute on function public.clear_team_crest_tx(p_team_id uuid, p_member_id uuid) from public;

-- [8.1] create_booking_tx:revoke-public
revoke execute on function public.create_booking_tx(p_store_id uuid, p_play_at timestamp with time zone, p_hours integer, p_table_count integer, p_team_id uuid, p_party_size integer, p_note text, p_game_type text, p_flower text, p_stake_level_id uuid) from public;

-- [8.1] create_invoice_draft_tx:revoke-public
revoke execute on function public.create_invoice_draft_tx(p_order_id uuid, p_idempotency_key text) from public;

-- [8.1] create_team_invite_link_tx:revoke-public
revoke execute on function public.create_team_invite_link_tx(p_team_id uuid) from public;

-- [8.1] create_team_tx:revoke-public
revoke execute on function public.create_team_tx(p_name text, p_crest_emoji text, p_intro text, p_join_policy text, p_home_store_id uuid) from public;

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

-- [8.1] disband_team_tx:revoke-public
revoke execute on function public.disband_team_tx(p_team_id uuid) from public;

-- [8.1] fire_event_tx:revoke-public
revoke execute on function public.fire_event_tx(p_member uuid, p_event text, p_delta bigint, p_period_key text, p_idem text) from public;

-- [8.1] fix_wallet_balance_tx:revoke-public
revoke execute on function public.fix_wallet_balance_tx(p_org_id uuid, p_member_id uuid) from public;

-- [8.1] generate_recurring_instances_tx:revoke-public
revoke execute on function public.generate_recurring_instances_tx(p_org_id uuid, p_days_ahead integer) from public;

-- [8.1] get_member_by_line_tx:revoke-public
revoke execute on function public.get_member_by_line_tx(p_org_id uuid, p_line_user_id text) from public;

-- [8.1] get_member_card_tx:revoke-public
revoke execute on function public.get_member_card_tx(p_target uuid) from public;

-- [8.1] get_my_achievements_tx:revoke-public
revoke execute on function public.get_my_achievements_tx() from public;

-- [8.1] get_my_avatar_tx:revoke-public
revoke execute on function public.get_my_avatar_tx(p_member_id uuid) from public;

-- [8.1] get_my_games_tx:revoke-public
revoke execute on function public.get_my_games_tx(p_org_id uuid, p_member_id uuid, p_limit integer) from public;

-- [8.1] get_my_titles_tx:revoke-public
revoke execute on function public.get_my_titles_tx() from public;

-- [8.1] get_order_tx:revoke-public
revoke execute on function public.get_order_tx(p_order_id uuid) from public;

-- [8.1] get_season_leaderboard_tx:revoke-public
revoke execute on function public.get_season_leaderboard_tx(p_org_id uuid, p_limit integer) from public;

-- [8.1] get_session_member_orders_tx:revoke-public
revoke execute on function public.get_session_member_orders_tx(p_session_id uuid, p_member_id uuid) from public;

-- [8.1] get_session_tx:revoke-public
revoke execute on function public.get_session_tx(p_session_id uuid) from public;

-- [8.1] get_staff_by_line_tx:revoke-public
revoke execute on function public.get_staff_by_line_tx(p_org_id uuid, p_line_user_id text) from public;

-- [8.1] get_team_tx:revoke-public
revoke execute on function public.get_team_tx(p_team_id uuid) from public;

-- [8.1] grant_snack_tx:revoke-public
revoke execute on function public.grant_snack_tx(p_org_id uuid, p_member_id uuid, p_kind text, p_qty integer, p_reason text, p_ref_id uuid, p_idem_key text) from public;

-- [8.1] grant_staff_tx:revoke-public
revoke execute on function public.grant_staff_tx(p_member_id uuid, p_store_id uuid, p_role text, p_name text) from public;

-- [8.1] has_daypass_tx:revoke-public
revoke execute on function public.has_daypass_tx(p_org_id uuid, p_member_id uuid, p_store_id uuid) from public;

-- [8.1] has_daypass_tx_core:revoke-public
revoke execute on function public.has_daypass_tx_core(p_org_id uuid, p_member_id uuid, p_store_id uuid) from public;

-- [8.1] has_store_access:revoke-public
revoke execute on function public.has_store_access(p_store_id uuid) from public;

-- [8.1] hide_my_account_tx:revoke-public
revoke execute on function public.hide_my_account_tx() from public;

-- [8.1] invite_to_team_tx:revoke-public
revoke execute on function public.invite_to_team_tx(p_team_id uuid, p_member_id uuid) from public;

-- [8.1] join_session_tx:revoke-public
revoke execute on function public.join_session_tx(p_session_id uuid, p_member_id uuid, p_join_type text, p_coupon_ids uuid[], p_points_used bigint, p_payments jsonb, p_staff_id uuid, p_idempotency_key text, p_pay_for uuid[], p_items jsonb) from public;

-- [8.1] kick_team_member_tx:revoke-public
revoke execute on function public.kick_team_member_tx(p_team_id uuid, p_member_id uuid) from public;

-- [8.1] leave_team_tx:revoke-public
revoke execute on function public.leave_team_tx(p_team_id uuid) from public;

-- [8.1] list_hot_teams_tx:revoke-public
revoke execute on function public.list_hot_teams_tx(p_limit integer) from public;

-- [8.1] list_members_tx:revoke-public
revoke execute on function public.list_members_tx(p_org_id uuid, p_limit integer) from public;

-- [8.1] list_my_bookings_tx:revoke-public
revoke execute on function public.list_my_bookings_tx() from public;

-- [8.1] list_my_teams_tx:revoke-public
revoke execute on function public.list_my_teams_tx() from public;

-- [8.1] list_staff_tx:revoke-public
revoke execute on function public.list_staff_tx(p_org_id uuid) from public;

-- [8.1] list_table_devices_tx:revoke-public
revoke execute on function public.list_table_devices_tx(p_store_id uuid) from public;

-- [8.1] list_tables_tx:revoke-public
revoke execute on function public.list_tables_tx(p_org_id uuid, p_store_id uuid) from public;

-- [8.1] list_team_requests_tx:revoke-public
revoke execute on function public.list_team_requests_tx(p_team_id uuid) from public;

-- [8.1] mark_invoice_failed_tx:revoke-public
revoke execute on function public.mark_invoice_failed_tx(p_invoice_id uuid, p_raw jsonb) from public;

-- [8.1] mark_invoice_issued_tx:revoke-public
revoke execute on function public.mark_invoice_issued_tx(p_invoice_id uuid, p_invoice_no text, p_random text, p_period text, p_provider text, p_provider_ref text, p_raw jsonb, p_donate_org_name text) from public;

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

-- [8.1] next_doc_no:revoke-public
revoke execute on function public.next_doc_no(p_org_id uuid, p_store_id uuid, p_doc_type text) from public;

-- [8.1] open_session_tx:revoke-public
revoke execute on function public.open_session_tx(p_table_id uuid, p_mode text, p_stake_level_id uuid, p_planned_rounds integer, p_planned_minutes integer, p_staff_id uuid, p_open_method text, p_idempotency_key text, p_game_type text, p_flower text) from public;

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

-- [8.1] pos_clear_on_duty_tx:revoke-public
revoke execute on function public.pos_clear_on_duty_tx() from public;

-- [8.1] pos_close_queue_tx:revoke-public
revoke execute on function public.pos_close_queue_tx(p_org_id uuid, p_queue uuid) from public;

-- [8.1] pos_create_queue_tx:revoke-public
revoke execute on function public.pos_create_queue_tx(p_org_id uuid, p_store uuid, p_stake uuid, p_play_at timestamp with time zone, p_game_type text, p_flower text, p_rounds text, p_seats integer, p_tags jsonb) from public;

-- [8.1] pos_create_recurring_tx:revoke-public
revoke execute on function public.pos_create_recurring_tx(p_org_id uuid, p_store uuid, p_stake uuid, p_frequency text, p_weekday integer, p_start_time time without time zone, p_game_type text, p_flower text, p_rounds text, p_seats integer, p_lead_hours integer, p_tags jsonb) from public;

-- [8.1] pos_list_bookings_tx:revoke-public
revoke execute on function public.pos_list_bookings_tx(p_store_id uuid, p_day date) from public;

-- [8.1] pos_list_queues_tx:revoke-public
revoke execute on function public.pos_list_queues_tx(p_org uuid, p_store uuid, p_before timestamp with time zone, p_limit integer) from public;

-- [8.1] pos_list_queues_tx_core:revoke-public
revoke execute on function public.pos_list_queues_tx_core(p_org uuid, p_store uuid, p_before timestamp with time zone, p_limit integer) from public;

-- [8.1] pos_list_recurring_tx:revoke-public
revoke execute on function public.pos_list_recurring_tx(p_org_id uuid, p_store uuid) from public;

-- [8.1] pos_list_recurring_tx_core:revoke-public
revoke execute on function public.pos_list_recurring_tx_core(p_org_id uuid, p_store uuid) from public;

-- [8.1] pos_mark_booking_tx:revoke-public
revoke execute on function public.pos_mark_booking_tx(p_booking_id uuid, p_status text, p_reason text) from public;

-- [8.1] pos_member_detail_tx:revoke-public
revoke execute on function public.pos_member_detail_tx(p_org_id uuid, p_member_id uuid) from public;

-- [8.1] pos_member_orders_tx:revoke-public
revoke execute on function public.pos_member_orders_tx(p_member_id uuid, p_limit integer, p_before timestamp with time zone) from public;

-- [8.1] pos_move_queue_member_tx:revoke-public
revoke execute on function public.pos_move_queue_member_tx(p_org uuid, p_from_queue uuid, p_to_queue uuid, p_member uuid) from public;

-- [8.1] pos_move_session_tx:revoke-public
revoke execute on function public.pos_move_session_tx(p_session_id uuid, p_table_id uuid, p_staff_id uuid) from public;

-- [8.1] pos_pkg_extend_tx:revoke-public
revoke execute on function public.pos_pkg_extend_tx(p_session_id uuid, p_member_id uuid, p_for uuid[], p_kind text, p_points_used bigint, p_payments jsonb, p_idempotency_key text) from public;

-- [8.1] pos_pkg_quote_tx:revoke-public
revoke execute on function public.pos_pkg_quote_tx(p_session_id uuid, p_member_id uuid, p_for uuid[], p_kind text) from public;

-- [8.1] pos_pkg_state_tx:revoke-public
revoke execute on function public.pos_pkg_state_tx(p_session_id uuid) from public;

-- [8.1] pos_queue_members_tx:revoke-public
revoke execute on function public.pos_queue_members_tx(p_org_id uuid, p_queue uuid) from public;

-- [8.1] pos_queue_members_tx_core:revoke-public
revoke execute on function public.pos_queue_members_tx_core(p_org_id uuid, p_queue uuid) from public;

-- [8.1] pos_quick_checkout_tx:revoke-public
revoke execute on function public.pos_quick_checkout_tx(p_member_id uuid, p_store_id uuid, p_items jsonb, p_coupon_ids uuid[], p_points_used bigint, p_payments jsonb, p_idempotency_key text, p_staff_id uuid, p_topup_points bigint, p_topup_amount bigint, p_topup_method text, p_topup_cash_received bigint, p_topup_change_given bigint, p_note text) from public;

-- [8.1] pos_quote_tx:revoke-public
revoke execute on function public.pos_quote_tx(p_session_id uuid, p_member_id uuid, p_join_type text, p_pay_for uuid[], p_items jsonb, p_coupon_ids uuid[]) from public;

-- [8.1] pos_remove_queue_member_tx:revoke-public
revoke execute on function public.pos_remove_queue_member_tx(p_org uuid, p_queue uuid, p_member uuid, p_reason text) from public;

-- [8.1] pos_search_members_tx:revoke-public
revoke execute on function public.pos_search_members_tx(p_org_id uuid, p_keyword text) from public;

-- [8.1] pos_seat_booking_tx:revoke-public
revoke execute on function public.pos_seat_booking_tx(p_booking_id uuid, p_table_id uuid, p_session_id uuid) from public;

-- [8.1] pos_seat_queue_tx:revoke-public
revoke execute on function public.pos_seat_queue_tx(p_org_id uuid, p_queue uuid, p_table_id uuid, p_staff_id uuid) from public;

-- [8.1] pos_set_on_duty_tx:revoke-public
revoke execute on function public.pos_set_on_duty_tx(p_store_id uuid) from public;

-- [8.1] pos_set_recurring_enabled_tx:revoke-public
revoke execute on function public.pos_set_recurring_enabled_tx(p_org_id uuid, p_id uuid, p_enabled boolean) from public;

-- [8.1] pos_set_recurring_tags_tx:revoke-public
revoke execute on function public.pos_set_recurring_tags_tx(p_org_id uuid, p_id uuid, p_tags jsonb) from public;

-- [8.1] pos_table_forecast_tx:revoke-public
revoke execute on function public.pos_table_forecast_tx(p_org uuid, p_store uuid, p_at timestamp with time zone) from public;

-- [8.1] pos_table_forecast_tx_core:revoke-public
revoke execute on function public.pos_table_forecast_tx_core(p_org uuid, p_store uuid, p_at timestamp with time zone) from public;

-- [8.1] pos_tbl_watch_tx:revoke-public
revoke execute on function public.pos_tbl_watch_tx(p_table_id uuid) from public;

-- [8.1] rating_window_start_tx:revoke-public
revoke execute on function public.rating_window_start_tx(p_org_id uuid) from public;

-- [8.1] rebind_line_user_tx:revoke-public
revoke execute on function public.rebind_line_user_tx(p_member_id uuid, p_new_line_user_id text, p_reason text) from public;

-- [8.1] recalc_member_tier_tx:revoke-public
revoke execute on function public.recalc_member_tier_tx(p_member_id uuid) from public;

-- [8.1] reconcile_wallets_tx:revoke-public
revoke execute on function public.reconcile_wallets_tx(p_org_id uuid) from public;

-- [8.1] redeem_team_invite_tx:revoke-public
revoke execute on function public.redeem_team_invite_tx(p_token text) from public;

-- [8.1] register_member_tx:revoke-public
revoke execute on function public.register_member_tx(p_org_id uuid, p_display_name text, p_phone text, p_line_user_id text, p_home_store_id uuid, p_created_by uuid) from public;

-- [8.1] reset_season_ratings_tx:revoke-public
revoke execute on function public.reset_season_ratings_tx(p_org_id uuid, p_season text, p_drop_tiers integer) from public;

-- [8.1] respond_team_request_tx:revoke-public
revoke execute on function public.respond_team_request_tx(p_request_id uuid, p_accept boolean) from public;

-- [8.1] reverse_txn_tx:revoke-public
revoke execute on function public.reverse_txn_tx(p_original_txn_id uuid, p_idempotency_key text, p_reason text) from public;

-- [8.1] revoke_staff_tx:revoke-public
revoke execute on function public.revoke_staff_tx(p_staff_id uuid) from public;

-- [8.1] revoke_table_device_tx:revoke-public
revoke execute on function public.revoke_table_device_tx(p_device_id uuid) from public;

-- [8.1] search_teams_tx:revoke-public
revoke execute on function public.search_teams_tx(p_q text, p_limit integer) from public;

-- [8.1] season_rank_rows_display_tx:revoke-public
revoke execute on function public.season_rank_rows_display_tx(p_org_id uuid, p_from timestamp with time zone, p_to timestamp with time zone) from public;

-- [8.1] season_rank_rows_tx:revoke-public
revoke execute on function public.season_rank_rows_tx(p_org_id uuid, p_from timestamp with time zone, p_to timestamp with time zone) from public;

-- [8.1] set_avatar_tx:revoke-public
revoke execute on function public.set_avatar_tx(p_member_id uuid, p_source text, p_path text, p_bear text) from public;

-- [8.1] set_invoice_pref_tx:revoke-public
revoke execute on function public.set_invoice_pref_tx(p_member_id uuid, p_type text, p_carrier text, p_donate_code text, p_tax_id text, p_title text) from public;

-- [8.1] set_line_avatar_tx:revoke-public
revoke execute on function public.set_line_avatar_tx(p_member_id uuid, p_url text) from public;

-- [8.1] set_member_phone_tx:revoke-public
revoke execute on function public.set_member_phone_tx(p_org_id uuid, p_line_user_id text, p_phone text) from public;

-- [8.1] set_table_active_tx:revoke-public
revoke execute on function public.set_table_active_tx(p_table_id uuid, p_active boolean, p_note text) from public;

-- [8.1] set_table_auto_assign_tx:revoke-public
revoke execute on function public.set_table_auto_assign_tx(p_table_id uuid, p_auto boolean) from public;

-- [8.1] set_team_co_leader_tx:revoke-public
revoke execute on function public.set_team_co_leader_tx(p_team_id uuid, p_member_id uuid, p_on boolean) from public;

-- [8.1] set_team_crest_source_tx:revoke-public
revoke execute on function public.set_team_crest_source_tx(p_team_id uuid, p_source text) from public;

-- [8.1] set_team_crest_tx:revoke-public
revoke execute on function public.set_team_crest_tx(p_team_id uuid, p_emoji text, p_path text) from public;

-- [8.1] settle_session_tx:revoke-public
revoke execute on function public.settle_session_tx(p_session_id uuid, p_staff_id uuid, p_keep_for_walkin boolean) from public;

-- [8.1] sweep_auto_seat_tx:revoke-public
revoke execute on function public.sweep_auto_seat_tx(p_org uuid) from public;

-- [8.1] sweep_expired_queues_tx:revoke-public
revoke execute on function public.sweep_expired_queues_tx(p_org_id uuid) from public;

-- [8.1] sweep_season_close_tx:revoke-public
revoke execute on function public.sweep_season_close_tx() from public;

-- [8.1] sweep_team_leaders_tx:revoke-public
revoke execute on function public.sweep_team_leaders_tx(p_org_id uuid) from public;

-- [8.1] tbl_bust_decide_tx:revoke-public
revoke execute on function public.tbl_bust_decide_tx(p_token text, p_amount integer) from public;

-- [8.1] team_crest_guard_tx:revoke-public
revoke execute on function public.team_crest_guard_tx(p_team_id uuid, p_member_id uuid) from public;

-- [8.1] topup_tx:revoke-public
revoke execute on function public.topup_tx(p_member_id uuid, p_store_id uuid, p_points bigint, p_amount_twd bigint, p_pay_method text, p_idempotency_key text, p_bonus_points bigint, p_external_ref text, p_staff_id uuid, p_note text) from public;

-- [8.1] topup_void_tx:revoke-public
revoke execute on function public.topup_void_tx(p_topup_id uuid, p_idempotency_key text, p_staff_id uuid, p_reason text) from public;

-- [8.1] transfer_team_leader_tx:revoke-public
revoke execute on function public.transfer_team_leader_tx(p_team_id uuid, p_to_member_id uuid) from public;

-- [8.1] trg_buddies_achievements:revoke-public
revoke execute on function public.trg_buddies_achievements() from public;

-- [8.1] trg_coupon_scopes_check:revoke-public
revoke execute on function public.trg_coupon_scopes_check() from public;

-- [8.1] trg_coupons_applies_to_frozen:revoke-public
revoke execute on function public.trg_coupons_applies_to_frozen() from public;

-- [8.1] trg_hands_bust_clamp:revoke-public
revoke execute on function public.trg_hands_bust_clamp() from public;

-- [8.1] trg_hands_bust_detect:revoke-public
revoke execute on function public.trg_hands_bust_detect() from public;

-- [8.1] trg_match_queues_credit:revoke-public
revoke execute on function public.trg_match_queues_credit() from public;

-- [8.1] trg_member_likes_achievements:revoke-public
revoke execute on function public.trg_member_likes_achievements() from public;

-- [8.1] trg_members_achievements:revoke-public
revoke execute on function public.trg_members_achievements() from public;

-- [8.1] trg_members_best_rank:revoke-public
revoke execute on function public.trg_members_best_rank() from public;

-- [8.1] trg_members_rank_achievements:revoke-public
revoke execute on function public.trg_members_rank_achievements() from public;

-- [8.1] trg_members_rank_events:revoke-public
revoke execute on function public.trg_members_rank_events() from public;

-- [8.1] trg_order_items_achievements:revoke-public
revoke execute on function public.trg_order_items_achievements() from public;

-- [8.1] trg_session_rounds_auto_score:revoke-public
revoke execute on function public.trg_session_rounds_auto_score() from public;

-- [8.1] trg_session_rounds_guard:revoke-public
revoke execute on function public.trg_session_rounds_guard() from public;

-- [8.1] trg_snack_achievements:revoke-public
revoke execute on function public.trg_snack_achievements() from public;

-- [8.1] trg_team_members_achievements:revoke-public
revoke execute on function public.trg_team_members_achievements() from public;

-- [8.1] trg_teams_achievements:revoke-public
revoke execute on function public.trg_teams_achievements() from public;

-- [8.1] trg_topup_achievements:revoke-public
revoke execute on function public.trg_topup_achievements() from public;

-- [8.1] update_team_tx:revoke-public
revoke execute on function public.update_team_tx(p_team_id uuid, p_name text, p_intro text, p_join_policy text, p_home_store_id uuid, p_clear_store boolean, p_monthly_goal integer) from public;

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

-- [9.0] trg_buddies_ach
CREATE TRIGGER trg_buddies_ach AFTER INSERT ON public.mahjong_buddies FOR EACH ROW WHEN ((new.deleted_at IS NULL)) EXECUTE FUNCTION trg_buddies_achievements();

-- [9.0] trg_coupon_code
CREATE TRIGGER trg_coupon_code BEFORE INSERT ON public.member_coupons FOR EACH ROW EXECUTE FUNCTION trg_coupon_set_code();

-- [9.0] trg_coupon_scopes_check
CREATE TRIGGER trg_coupon_scopes_check BEFORE INSERT OR UPDATE ON public.coupon_scopes FOR EACH ROW EXECUTE FUNCTION trg_coupon_scopes_check();

-- [9.0] trg_coupons_applies_to_frozen
CREATE TRIGGER trg_coupons_applies_to_frozen BEFORE INSERT OR UPDATE ON public.coupons FOR EACH ROW EXECUTE FUNCTION trg_coupons_applies_to_frozen();

-- [9.0] trg_coupons_org
CREATE TRIGGER trg_coupons_org BEFORE UPDATE ON public.coupons FOR EACH ROW EXECUTE FUNCTION prevent_org_change();

-- [9.0] trg_coupons_updated
CREATE TRIGGER trg_coupons_updated BEFORE UPDATE ON public.coupons FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- [9.0] trg_hands_bust_clamp
CREATE TRIGGER trg_hands_bust_clamp BEFORE INSERT ON public.hands FOR EACH ROW EXECUTE FUNCTION trg_hands_bust_clamp();

-- [9.0] trg_hands_bust_detect
CREATE TRIGGER trg_hands_bust_detect AFTER UPDATE OF status ON public.hands FOR EACH ROW EXECUTE FUNCTION trg_hands_bust_detect();

-- [9.0] trg_match_queues_credit
CREATE TRIGGER trg_match_queues_credit BEFORE UPDATE OF status ON public.match_queues FOR EACH ROW EXECUTE FUNCTION trg_match_queues_credit();

-- [9.0] trg_member_likes_ach
CREATE TRIGGER trg_member_likes_ach AFTER INSERT ON public.member_likes FOR EACH ROW EXECUTE FUNCTION trg_member_likes_achievements();

-- [9.0] trg_members_ach
CREATE TRIGGER trg_members_ach AFTER INSERT ON public.members FOR EACH ROW WHEN ((new.deleted_at IS NULL)) EXECUTE FUNCTION trg_members_achievements();

-- [9.0] trg_members_best_rank
CREATE TRIGGER trg_members_best_rank BEFORE INSERT OR UPDATE OF rank ON public.members FOR EACH ROW EXECUTE FUNCTION trg_members_best_rank();

-- [9.0] trg_members_org
CREATE TRIGGER trg_members_org BEFORE UPDATE ON public.members FOR EACH ROW EXECUTE FUNCTION prevent_org_change();

-- [9.0] trg_members_rank_ach
CREATE TRIGGER trg_members_rank_ach AFTER UPDATE OF rank ON public.members FOR EACH ROW WHEN (((old.rank IS NULL) AND (new.rank IS NOT NULL))) EXECUTE FUNCTION trg_members_rank_achievements();

-- [9.0] trg_members_rank_events
CREATE TRIGGER trg_members_rank_events AFTER UPDATE OF rank ON public.members FOR EACH ROW EXECUTE FUNCTION trg_members_rank_events();

-- [9.0] trg_members_updated
CREATE TRIGGER trg_members_updated BEFORE UPDATE ON public.members FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- [9.0] trg_members_wallet
CREATE TRIGGER trg_members_wallet AFTER INSERT ON public.members FOR EACH ROW EXECUTE FUNCTION create_wallet_for_member();

-- [9.0] trg_order_items_ach
CREATE TRIGGER trg_order_items_ach AFTER INSERT ON public.order_items REFERENCING NEW TABLE AS new_items FOR EACH STATEMENT EXECUTE FUNCTION trg_order_items_achievements();

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

-- [9.0] trg_products_pkg_ext_guard
CREATE TRIGGER trg_products_pkg_ext_guard BEFORE INSERT OR UPDATE OF unit_price ON public.products FOR EACH ROW WHEN ((new.sku = ANY (ARRAY['SVC-TBL-PX02'::text, 'SVC-TBL-DAYUP'::text]))) EXECUTE FUNCTION _pkg_ext_guard();

-- [9.0] trg_products_pkg_tier_sync
CREATE TRIGGER trg_products_pkg_tier_sync AFTER UPDATE OF unit_price ON public.products FOR EACH ROW WHEN ((new.sku = ANY (ARRAY['SVC-TBL-P02'::text, 'SVC-TBL-P05'::text, 'SVC-TBL-DAY'::text]))) EXECUTE FUNCTION _pkg_tier_sync();

-- [9.0] trg_products_updated
CREATE TRIGGER trg_products_updated BEFORE UPDATE ON public.products FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- [9.0] trg_session_rounds_auto_score
CREATE TRIGGER trg_session_rounds_auto_score AFTER UPDATE OF status ON public.session_rounds FOR EACH ROW EXECUTE FUNCTION trg_session_rounds_auto_score();

-- [9.0] trg_session_rounds_guard
CREATE TRIGGER trg_session_rounds_guard BEFORE INSERT OR UPDATE OF status ON public.session_rounds FOR EACH ROW EXECUTE FUNCTION trg_session_rounds_guard();

-- [9.0] trg_session_voided_release_queue
CREATE TRIGGER trg_session_voided_release_queue AFTER UPDATE OF status ON public.table_sessions FOR EACH ROW WHEN (((new.status = 'voided'::text) AND (old.status IS DISTINCT FROM 'voided'::text))) EXECUTE FUNCTION trg_session_voided_release_queue();

-- [9.0] trg_sessions_is_test
CREATE TRIGGER trg_sessions_is_test BEFORE INSERT ON public.table_sessions FOR EACH ROW EXECUTE FUNCTION set_is_test_from_store();

-- [9.0] trg_sessions_org
CREATE TRIGGER trg_sessions_org BEFORE UPDATE ON public.table_sessions FOR EACH ROW EXECUTE FUNCTION prevent_org_change();

-- [9.0] trg_sessions_updated
CREATE TRIGGER trg_sessions_updated BEFORE UPDATE ON public.table_sessions FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- [9.0] trg_snack_ach
CREATE TRIGGER trg_snack_ach AFTER INSERT ON public.snack_grants FOR EACH ROW EXECUTE FUNCTION trg_snack_achievements();

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

-- [9.0] trg_team_members_ach
CREATE TRIGGER trg_team_members_ach AFTER INSERT ON public.team_members FOR EACH ROW WHEN (((new.role <> 'leader'::text) AND (new.left_at IS NULL))) EXECUTE FUNCTION trg_team_members_achievements();

-- [9.0] trg_teams_ach
CREATE TRIGGER trg_teams_ach AFTER INSERT ON public.teams FOR EACH ROW WHEN ((new.deleted_at IS NULL)) EXECUTE FUNCTION trg_teams_achievements();

-- [9.0] trg_topup_ach
CREATE TRIGGER trg_topup_ach AFTER INSERT ON public.topup_orders FOR EACH ROW WHEN (((new.status = 'paid'::text) AND (new.member_id IS NOT NULL))) EXECUTE FUNCTION trg_topup_achievements();

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
    x.open_at,
    x.auto_seat,
    x.credited_staff_id
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
    m.inv_title,
    m.avatar_bear,
    m.phone_verified_at,
    m.rating,
    m.rating_games,
    m.hidden_at,
    m.best_rank_tier
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
    revenue_type,
    spec
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
    fee_waived_reason,
    rating_after,
    final_score,
    device_id
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
    s.note,
    s.on_duty_staff_id,
    s.on_duty_since
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
    x.flower,
    x.score_channel,
    x.closed_by_staff_id
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

-- [11.0] achievement_tiers
alter table achievement_tiers enable row level security;

-- [11.0] achievements
alter table achievements enable row level security;

-- [11.0] app_events
alter table app_events enable row level security;

-- [11.0] app_notifications
alter table app_notifications enable row level security;

-- [11.0] bonus_rules
alter table bonus_rules enable row level security;

-- [11.0] bookings
alter table bookings enable row level security;

-- [11.0] buddy_invites
alter table buddy_invites enable row level security;

-- [11.0] coupon_scopes
alter table coupon_scopes enable row level security;

-- [11.0] coupons
alter table coupons enable row level security;

-- [11.0] doc_counters
alter table doc_counters enable row level security;

-- [11.0] hands
alter table hands enable row level security;

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

-- [11.0] member_achievements
alter table member_achievements enable row level security;

-- [11.0] member_app_state
alter table member_app_state enable row level security;

-- [11.0] member_availability
alter table member_availability enable row level security;

-- [11.0] member_blocks
alter table member_blocks enable row level security;

-- [11.0] member_coupons
alter table member_coupons enable row level security;

-- [11.0] member_hidden
alter table member_hidden enable row level security;

-- [11.0] member_hide_log
alter table member_hide_log enable row level security;

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

-- [11.0] scoring_patterns
alter table scoring_patterns enable row level security;

-- [11.0] season_champions
alter table season_champions enable row level security;

-- [11.0] season_standings
alter table season_standings enable row level security;

-- [11.0] season_start_ratings
alter table season_start_ratings enable row level security;

-- [11.0] session_busts
alter table session_busts enable row level security;

-- [11.0] session_extensions
alter table session_extensions enable row level security;

-- [11.0] session_players
alter table session_players enable row level security;

-- [11.0] session_rounds
alter table session_rounds enable row level security;

-- [11.0] snack_grants
alter table snack_grants enable row level security;

-- [11.0] staff
alter table staff enable row level security;

-- [11.0] stake_levels
alter table stake_levels enable row level security;

-- [11.0] stores
alter table stores enable row level security;

-- [11.0] table_devices
alter table table_devices enable row level security;

-- [11.0] table_sessions
alter table table_sessions enable row level security;

-- [11.0] tables
alter table tables enable row level security;

-- [11.0] team_invite_links
alter table team_invite_links enable row level security;

-- [11.0] team_members
alter table team_members enable row level security;

-- [11.0] team_requests
alter table team_requests enable row level security;

-- [11.0] teams
alter table teams enable row level security;

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

-- [12.0] achievement_tiers.p_acht_sel
create policy p_acht_sel on achievement_tiers as PERMISSIVE for SELECT to public using ((org_id = current_org_id()));

-- [12.0] achievements.p_ach_sel
create policy p_ach_sel on achievements as PERMISSIVE for SELECT to public using ((org_id = current_org_id()));

-- [12.0] bonus_rules.bonus_org
create policy bonus_org on bonus_rules as PERMISSIVE for SELECT to authenticated using (((org_id = current_org_id()) AND can('ops.read'::text)));

-- [12.0] coupons.coupons_org
create policy coupons_org on coupons as PERMISSIVE for SELECT to authenticated using (((org_id = current_org_id()) AND can('ops.read'::text)));

-- [12.0] mahjong_buddies.buddies_org
create policy buddies_org on mahjong_buddies as PERMISSIVE for SELECT to authenticated using (((org_id = current_org_id()) AND can('member.read'::text)));

-- [12.0] member_achievements.p_ma_hq
create policy p_ma_hq on member_achievements as PERMISSIVE for SELECT to public using (((org_id = current_org_id()) AND can('member.read'::text)));

-- [12.0] member_achievements.p_ma_self
create policy p_ma_self on member_achievements as PERMISSIVE for SELECT to public using ((member_id = current_member_id()));

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
