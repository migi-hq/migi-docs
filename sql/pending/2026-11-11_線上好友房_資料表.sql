-- ════════════════════════════════════════════════════════════════════
-- 線上好友房 · 第 ① 批：資料表（2026-11-11）
-- 規格：docs/03-會員App與社交/線上好友房.md
--
-- 接法：線上打 ＝ 好友練習賽的一種（play_mode = 'online'）。成桌照舊建 table_sessions（mode = 'friendly'）
--      ＋ session_players，每一將照舊一列 session_rounds；
--      🔴 每打完一局，往既有的 hands 寫一筆 status = 'confirmed' 的局 ⇒ 莊家、連莊、第幾圈、將打完沒
--        （_tbl_round_state）、自動結算、練習賽紀錄、牌局回放全部照舊，不另寫一份。
--      這一批只有資料表；寫入 hands、建局、每個動作的函式是下一批。
--
-- 這一批建的：
--   friendly_games.play_mode   'scoreboard'（四支手機記分，現在的樣子）／'online'（線上打）
--   online_hands               每一局的引擎完整狀態（四家手牌、牌山）—— 🔴 前端完全讀不到，只有後端（service_role）
--   online_actions             每一個動作的紀錄，只能新增（牌局回放、除錯、申訴都靠它）
--   online_seats               每個座位的在線狀態與「逾時被代打」；誰坐哪裡照舊看 session_players.seat，不另存一份
--
-- 座位：跟計分板一樣用 1～4（代表人，session_players.seat）。引擎內部的 0～3 是「這一將的出牌順序」，
--      對應 session_rounds.seat_ring（第 0 位 ＝ 這一將第一個莊家 ＝ 東），換算放在後端程式，不進資料庫。
-- ════════════════════════════════════════════════════════════════════

-- ① 好友練習賽要不要線上打
alter table public.friendly_games
  add column if not exists play_mode text not null default 'scoreboard'
  constraint friendly_games_play_mode_check check (play_mode in ('scoreboard', 'online'));
comment on column public.friendly_games.play_mode is
  '怎麼打：scoreboard ＝ 實體牌、四支手機計分板記分；online ＝ 線上好友房（電腦發牌、自動算台）';

-- ② 每一局
create table if not exists public.online_hands (
  id           uuid primary key default gen_random_uuid(),
  org_id       uuid not null references public.orgs(id) on delete restrict,
  session_id   uuid not null references public.table_sessions(id) on delete restrict,
  round_id     uuid not null references public.session_rounds(id) on delete restrict,
  hand_no      integer not null,                 -- 跟 hands.hand_no 同一個編號
  seed         bigint not null check (seed between 0 and 4294967295),   -- 引擎亂數是 32 位元；同一個 seed 洗出同一副牌
  dice         smallint[] not null
               check (array_length(dice, 1) = 3 and dice <@ '{1,2,3,4,5,6}'::smallint[]),
  seat_dice    smallint[]                        -- 只有每一將的第一局有：定座位那一擲（dice 就是定莊家那一擲）
               check (seat_dice is null or (array_length(seat_dice, 1) = 3 and seat_dice <@ '{1,2,3,4,5,6}'::smallint[])),
  dealer_seat  smallint not null check (dealer_seat between 1 and 4),
  renzhuang    smallint not null default 0 check (renzhuang >= 0),
  state        jsonb not null,                   -- 🔴 引擎完整狀態：四家手牌、牌山。只有後端讀，給前端的是每一家自己那一份
  version      integer not null default 0,       -- 每做一個動作 +1；寫回時比對版本，兩支手機同時按只有一個算數
  phase        text not null,                    -- 引擎的 phase（baozi／discard／claim／end …），排程找逾時用
  deadline_at  timestamptz,                      -- 這一步最晚幾點要做；過了由後端代打
  status       text not null default 'playing' check (status in ('playing', 'finished', 'aborted')),
  hand_id      uuid unique references public.hands(id) on delete restrict,   -- 打完寫進 hands 的那一筆
  started_at   timestamptz not null default now(),
  ended_at     timestamptz,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  constraint uq_online_hands_round_no unique (round_id, hand_no)
);
comment on table public.online_hands is
  '線上好友房每一局的引擎狀態（state 含四家手牌與牌山，前端讀不到）；打完寫一筆 hands，hand_id 指過去';

-- 同一場同時只能有一局在打
create unique index if not exists uq_online_hands_playing
  on public.online_hands (session_id) where status = 'playing';
-- 排程找「過了時間還沒動」的局
create index if not exists ix_online_hands_deadline
  on public.online_hands (deadline_at) where status = 'playing';

-- ③ 每一個動作（只能新增）
create table if not exists public.online_actions (
  id              bigint generated always as identity primary key,
  org_id          uuid not null references public.orgs(id) on delete restrict,
  online_hand_id  uuid not null references public.online_hands(id) on delete restrict,
  version         integer not null,              -- 做完這個動作之後的版本號
  seat            smallint check (seat between 1 and 4),   -- null ＝ 系統（發牌、流局）
  actor           text not null check (actor in ('player', 'auto', 'system')),   -- auto ＝ 逾時或斷線代打
  action          jsonb not null,
  created_at      timestamptz not null default now(),
  constraint uq_online_actions_version unique (online_hand_id, version)
);
comment on table public.online_actions is
  '線上好友房每一個動作的紀錄（只能新增）；牌局回放、除錯、申訴都靠它';

create or replace function public._online_actions_no_mutate()
returns trigger language plpgsql set search_path = public as $$
begin
  raise exception 'online_actions 只能新增，不能修改或刪除';
end $$;
drop trigger if exists trg_online_actions_no_mutate on public.online_actions;
create trigger trg_online_actions_no_mutate
  before update or delete on public.online_actions
  for each row execute function public._online_actions_no_mutate();

-- ④ 每個座位的在線狀態
create table if not exists public.online_seats (
  session_id    uuid not null references public.table_sessions(id) on delete restrict,
  seat          smallint not null check (seat between 1 and 4),
  org_id        uuid not null references public.orgs(id) on delete restrict,
  last_seen_at  timestamptz,                     -- 這支手機最後一次跟後端說話
  auto_since    timestamptz,                     -- 逾時被代打的時間；本人再按任何一個動作就清掉
  primary key (session_id, seat)
);
comment on table public.online_seats is
  '線上好友房每個座位的在線狀態；誰坐哪裡看 session_players.seat，這裡不另存一份';

-- ⑤ 權限：三張表只有後端（Edge Function 用 service_role）讀寫；前端一律走函式
alter table public.online_hands   enable row level security;
alter table public.online_actions enable row level security;
alter table public.online_seats   enable row level security;
revoke all on public.online_hands, public.online_actions, public.online_seats from public, anon, authenticated;
grant select, insert, update on public.online_hands, public.online_seats to service_role;
grant select, insert on public.online_actions to service_role;
-- 新建的表一出生 service_role 就有全部權限（預設權限）⇒ 動作紀錄要明確收掉改與刪，觸發器之外再一道
revoke update, delete, truncate on public.online_actions from service_role;

-- ════════════════════════════════════════════════════════════════════
-- 驗證（單一 SELECT；不 raise —— 硬規則 1.8）
-- 行為（骰子擋、同一場只能一局、動作只能新增）另外跑：sql/checks/2026-11-11_驗線上好友房資料表.sql
-- ════════════════════════════════════════════════════════════════════
with t(n) as (values ('online_hands'), ('online_actions'), ('online_seats')),
c(item, ok) as (
  select '① friendly_games.play_mode 預設 scoreboard',
         coalesce((select column_default like '%scoreboard%' from information_schema.columns
                    where table_schema = 'public' and table_name = 'friendly_games' and column_name = 'play_mode'), false)
  union all
  select '② 既有的好友練習賽全部是 scoreboard（' || (select count(*) from public.friendly_games) || ' 場）',
         not exists (select 1 from public.friendly_games where play_mode <> 'scoreboard')
  union all
  select '③ 三張表都在',
         (select count(*) from pg_class c join t on t.n = c.relname
           where c.relnamespace = 'public'::regnamespace and c.relkind = 'r') = 3
  union all
  select '④ 三張表都開了 RLS',
         coalesce((select bool_and(c.relrowsecurity) from pg_class c join t on t.n = c.relname
                    where c.relnamespace = 'public'::regnamespace), false)
  union all
  select '⑤ 沒有任何 policy（前端只能走函式）',
         (select count(*) from pg_policies p join t on t.n = p.tablename where p.schemaname = 'public') = 0
  union all
  select '⑥ anon、authenticated 一個權限都沒有',
         not exists (select 1 from t, unnest(array['anon', 'authenticated']) r
                      where has_table_privilege(r, 'public.' || t.n, 'select,insert,update,delete'))
  union all
  select '⑦ 正對照：service_role 讀寫得到（不然後端會當場壞）',
         (select bool_and(has_table_privilege('service_role', 'public.' || t.n, 'select')
                      and has_table_privilege('service_role', 'public.' || t.n, 'insert')) from t)
  union all
  select '⑧ 動作紀錄：service_role 也不能改、不能刪（權限 ＋ 觸發器兩道）',
         not has_table_privilege('service_role', 'public.online_actions', 'update,delete')
         and exists (select 1 from pg_trigger where tgrelid = 'public.online_actions'::regclass
                      and tgname = 'trg_online_actions_no_mutate')
  union all
  select '⑨ 同一場只能有一局在打（部分唯一索引）',
         exists (select 1 from pg_indexes where schemaname = 'public' and indexname = 'uq_online_hands_playing')
)
select string_agg(case when ok then '✅ ' else '🔴 ' end || item, E'\n') as "驗證" from c;
