-- =====================================================================
-- MIGI 牌譜 / 成績資料中台 — 完整 DDL
-- 狀態:PENDING(尚未在 Supabase 執行,原型/規劃階段抽出的 schema)
-- 對應文件:docs/10-牌譜與AI辨識/牌譜成績資料中台技術設計.md(v0.4)
-- 部署方式:一律走 Supabase Dashboard 操作流程執行(不用 CLI/本地部署)
-- 部署順序:enum 型別 → games/game_players/hands → paipu_events(含分區)
--          → 聚合表 → materialized view → Edge Function(聚合/評等,另行開發)
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. 對局(games) — 一場對局 = 一桌一個 session,通常一將/一場
-- ---------------------------------------------------------------------
create type game_status as enum ('live', 'finished', 'void');

create table games (
  id          bigint generated always as identity primary key,
  store_id    bigint not null,
  table_id    bigint not null,
  game_type   text   not null,                  -- 4P_16 / 4P_13 / 3P_16 ...
  ruleset     text   not null default 'tw16',    -- tw16(台灣16張,現行) / jp13(保留未來擴充,暫不使用)
  is_official boolean not null default false,    -- 賽事級(高精度、可公開)
  is_ranked   boolean not null default true,     -- 是否計入評等
  status      game_status not null default 'live',
  started_at  timestamptz not null default now(),
  ended_at    timestamptz
);


-- ---------------------------------------------------------------------
-- 2. 座位與會員綁定(game_players) — 對局四座位是誰、最終結果
--    座位→會員綁定為必要人工步驟(鏡頭只認座位不認人),見架構文件 §10.5
-- ---------------------------------------------------------------------
create table game_players (
  game_id     bigint   not null references games(id) on delete cascade,
  seat        smallint not null,                 -- 1..4
  member_id   bigint   references members(id),   -- 可為 null(匿名/訪客,不歸戶會員成績)
  final_rank  smallint,                           -- 1..4 名次
  final_score integer,                            -- 點數/台數結算
  primary key (game_id, seat)
);


-- ---------------------------------------------------------------------
-- 3. 局(hands) — 東1局、南2局...
-- ---------------------------------------------------------------------
create type hand_result as enum ('tsumo', 'ron', 'draw', 'abort');
-- tsumo=自摸 / ron=胡牌(放槍) / draw=流局(臭莊) / abort=中止

create table hands (
  id           bigint generated always as identity primary key,
  game_id      bigint   not null references games(id) on delete cascade,
  round_wind   text     not null,                -- E/S/W/N(東南西北場)
  hand_no      smallint not null,                -- 第幾局
  renzhuang    smallint not null default 0,      -- 連莊數(連N拉N;台麻莊家連莊計數)
  dealer_seat  smallint not null,                -- 莊家座位
  result       hand_result,
  winner_seat  smallint,                          -- 胡牌者(流局 null)
  deal_in_seat smallint,                          -- 放槍者(自摸/流局 null)
  score_delta  jsonb,                             -- {"1":48,"2":-16,...} 各座位增減
  started_at   timestamptz not null default now(),
  ended_at     timestamptz,
  unique (game_id, round_wind, hand_no, renzhuang)
);

-- 【旗艦/賽事桌選配】牌山序路線需要的骰子欄位,一般營業桌不用(見 hardware/RFID 相關文件)
-- alter table hands add column dice_roll smallint;   -- 骰子點數(決定開門位置)


-- ---------------------------------------------------------------------
-- 4. 逐筆牌譜事件(paipu_events) — 核心表,append-only,按月分區
--    事件溯源(Event Sourcing):每個動作 = 一筆不可變、只追加的事件
-- ---------------------------------------------------------------------
create type event_source as enum ('table_feed', 'cv', 'operator', 'online');

create type event_action as enum (
  'deal', 'draw', 'discard', 'chi', 'pon', 'kan_open', 'kan_closed', 'kan_added',
  'flower', 'replace_flower', 'tsumo', 'ron', 'ryuukyoku',
  'riichi', 'dora_reveal'   -- ⚠ 日麻專用:引進日麻規則集(ruleset='jp13')時才啟用;台麻不使用
);

create table paipu_events (
  id           bigint generated always as identity,
  game_id      bigint   not null references games(id),
  hand_id      bigint   not null references hands(id),
  seat         smallint not null,
  turn_no      smallint,                          -- 第幾輪
  action       event_action not null,
  tile         text,                              -- 牌面編碼,見 docs/tile-encoding-reference.md
  meta         jsonb,                              -- 吃碰槓對象、所用牌組、from_draw 旗標等
  event_ts     timestamptz not null,
  source       event_source not null,
  confidence   numeric  not null default 1.0,     -- 0~1;AI 辨識帶信心
  is_corrected boolean  not null default false,   -- 經人工校正覆寫
  primary key (id, event_ts)
) partition by range (event_ts);

-- 月分區範例(每月建一張;建議另寫排程函式自動預建下個月分區)
create table paipu_events_2026_06 partition of paipu_events
  for values from ('2026-06-01') to ('2026-07-01');

create index on paipu_events (game_id, hand_id, seat, turn_no);
create index on paipu_events (game_id, action);


-- ---------------------------------------------------------------------
-- 5. 成績聚合(member_stats_agg) — 增量更新,member_rating 的上游
--    讀取原則:會員儀表板/配桌一律讀本表或 member_rating,不掃原始事件
-- ---------------------------------------------------------------------
create table member_stats_agg (
  member_id      bigint not null references members(id) on delete cascade,
  game_type      text   not null,
  period         text   not null,                 -- 'lifetime' / '2026-06' ...
  games          int    not null default 0,
  hands          int    not null default 0,
  win_count      int    not null default 0,       -- 胡牌數
  deal_in_count  int    not null default 0,       -- 放槍數
  riichi_count   int    not null default 0,       -- ⚠ 日麻專用指標:引進日麻時啟用;台麻不計(恆為0)
  call_count     int    not null default 0,       -- 吃碰槓數
  rank_sum       int    not null default 0,       -- 名次總和 → 平均順位
  win_points_sum bigint not null default 0,
  updated_at     timestamptz not null default now(),
  primary key (member_id, game_type, period)
);

-- 衍生指標(查詢時計算或另建 view 物化):
--   胡牌率   = win_count / nullif(hands, 0)
--   放槍率   = deal_in_count / nullif(hands, 0)
--   平均順位 = rank_sum / nullif(games, 0)
--   吃碰槓率 = call_count / nullif(hands, 0)


-- ---------------------------------------------------------------------
-- 6. 排名(rankings_national) — materialized view,定期刷新避免鎖表
--    店內排名需另 join 會員店籍表(member_store_membership,另定,不在本檔範圍)
-- ---------------------------------------------------------------------
create materialized view rankings_national as
select member_id,
       rating,
       rank() over (order by rating desc) as national_rank
from member_rating;   -- member_rating 由配桌引擎技術設計定義,非本檔範圍,此處僅示範查詢

-- 定期刷新(避免鎖表):
-- refresh materialized view concurrently rankings_national;


-- ---------------------------------------------------------------------
-- 7. 【旗艦/賽事桌選配】牌山序(wall_orders)
--    現階段暫不考慮(見 RFID/牌山序相關可行性文件),schema 保留供未來啟用
-- ---------------------------------------------------------------------
-- create table wall_orders (
--   hand_id    bigint primary key references hands(id) on delete cascade,
--   tiles      jsonb  not null,        -- 144 張依砌牌順序之牌面陣列
--   source     event_source not null,  -- table_feed / operator
--   confidence numeric not null default 1.0
-- );
-- 推導出的摸牌事件寫入 paipu_events(action='draw'),
-- source 標 'table_feed'(牌山推導)或 'cv'(攤牌反推),confidence 隨之。


-- =====================================================================
-- 部署備註
-- =====================================================================
-- 1. 前置依賴:members 表(會員主檔)、member_rating 表(配桌引擎技術設計定義)
--    須先存在,本檔的 references 才建得成功。
-- 2. 官方核心成績只採計「局結果」可靠的局(operator/table_feed 來源);
--    CV-only 的進階指標需 confidence >= 門檻(例如 0.9)才計入官方數字。
-- 3. 隱私:分析資料湖一律以假名 member_key 取代真實身分,身分對照表獨立存放、
--    嚴格權限。Supabase RLS:會員僅能讀自己的 member_stats_agg / member_rating
--    / 個人牌譜;聚合運算以 service role 後端執行。
-- =====================================================================
