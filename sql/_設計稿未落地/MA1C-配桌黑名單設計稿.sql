-- 【這是什麼】MA1-C 設計稿（草案，非可執行完整版）：配桌等待層 match_queues、揪桌邀請、黑名單 member_blocks、作息/耐心分析視圖。
-- 【何時讀】開始做 C 塊配桌時當藍圖；需先依此產出正式可執行版再跑。
-- ============================================================
-- MIGI MA1 建表：會員 App 社交與配桌（草案 v1.1，供審查）
-- ※ 命名 MA=Member App 系列，與 POS 端 M 系列(M1=錢包已部署,
--   M2=開收桌, M3=CRM/MA, M4=段位Elo)平行不撞號
-- 範圍：A 會員資料擴充 / B 牌咖關係與通知 / C 配桌等待層 / F 黑名單 / G 分析視圖
--
-- 【與 M0 的關係】
--   M0 的 table_sessions = 已入座開打的「計費桌」（店員/POS 視角）
--   本包新增 match_queues = 開打前的「等待撮合房」（會員 App 視角）
--   銜接：App 成桌(matched) → 客人到店入座 → 店員開 table_sessions
--         → 回填 match_queues.matched_session_id 完成閉環
--
-- 【基石對照】uuid 主鍵①、UTC②、審計欄⑤、org_id+RLS⑥、
--   check 約束⑮、寫入只走 SECURITY DEFINER RPC⑱、軟刪除⑨
-- ============================================================


-- ------------------------------------------------------------
-- PART A：會員資料擴充（段位 / 稱號 / 獲讚）
-- ------------------------------------------------------------

-- A1. members 加三欄（avatar 用既有 avatar_url，不新增）
alter table members add column if not exists rank  text not null default '銅牌熊 I';
alter table members add column if not exists title text not null default '新手上路';
alter table members add column if not exists likes_count int not null default 0;

comment on column members.rank  is '目前段位（快取）。未來由賽季結算更新；格式如「金牌熊 II」';
comment on column members.title is '目前配戴的稱號，App 顯示為「稱號」';
comment on column members.likes_count is '累計獲讚數（快取，like_player_tx 維護）';

-- A2. 按讚紀錄（append-only；likes_count 是它的快取）
create table if not exists member_likes (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references orgs(id) on delete restrict,
  liker_id    uuid not null references members(id) on delete restrict,
  target_id   uuid not null references members(id) on delete restrict,
  session_id  uuid references table_sessions(id) on delete restrict,  -- 哪一局收桌時讚的（過渡期可 null）
  created_at  timestamptz not null default now(),
  check (liker_id <> target_id)
);
-- 同一局對同一人只能讚一次
create unique index if not exists uq_like_per_session
  on member_likes(liker_id, target_id, session_id) where session_id is not null;
create index if not exists idx_likes_target on member_likes(target_id);

alter table member_likes enable row level security;
revoke all on member_likes from anon, authenticated;


-- ------------------------------------------------------------
-- PART B：牌咖邀請 + App 通知
-- ------------------------------------------------------------

-- B1. 牌咖邀請（單向發起 → 對方確認制；拒絕無痕）
create table if not exists buddy_invites (
  id           uuid primary key default gen_random_uuid(),
  org_id       uuid not null references orgs(id) on delete restrict,
  inviter_id   uuid not null references members(id) on delete restrict,
  invitee_id   uuid not null references members(id) on delete restrict,
  status       text not null default 'pending'
               check (status in ('pending','accepted','rejected')),
  responded_at timestamptz,
  created_at   timestamptz not null default now(),
  check (inviter_id <> invitee_id)
);
-- 同一對象只能有一張待回覆邀請（被拒後可再邀？→ 先允許，防騷擾之後用冷卻期規則加強）
create unique index if not exists uq_pending_invite
  on buddy_invites(inviter_id, invitee_id) where status = 'pending';
create index if not exists idx_invites_invitee on buddy_invites(invitee_id) where status = 'pending';

alter table buddy_invites enable row level security;
revoke all on buddy_invites from anon, authenticated;

-- B2. M0 的 mahjong_buddies 補唯一鍵（原表只有 check，沒防重複配對）
create unique index if not exists uq_buddy_pair
  on mahjong_buddies(member_id, buddy_id) where deleted_at is null;
-- 關係模型：接受邀請時寫入「兩筆互指」（A→B 與 B→A），查詢單向即可

-- B3. App 通知（通知中心的資料來源）
create table if not exists app_notifications (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references orgs(id) on delete restrict,
  member_id   uuid not null references members(id) on delete restrict,  -- 收件人
  type        text not null check (type in
              ('settle','buddy_req','buddy_ok','table_req','table_ok','system')),
  payload     jsonb not null default '{}'::jsonb,   -- {from_name, queue_id, invite_id, text...}
  ref_id      uuid,                                 -- 關聯的邀請/局 id（回應時反查）
  read_at     timestamptz,
  created_at  timestamptz not null default now()
);
create index if not exists idx_notif_member on app_notifications(member_id, created_at desc);

alter table app_notifications enable row level security;
revoke all on app_notifications from anon, authenticated;


-- ------------------------------------------------------------
-- PART C：配桌等待層（App 撮合房，成桌後接 M0 table_sessions）
-- ------------------------------------------------------------

-- C1. 等待房
create table if not exists match_queues (
  id             uuid primary key default gen_random_uuid(),
  org_id         uuid not null references orgs(id) on delete restrict,
  store_id       uuid not null references stores(id) on delete restrict,
  stake_level_id uuid not null references stake_levels(id) on delete restrict,
  game_type      text not null default '16張',      -- 玩法（App 選項）
  rounds         text not null default '一將',      -- 局數（App 選項）
  seats          int  not null default 4 check (seats between 2 and 4),
  status         text not null default 'waiting'
                 check (status in ('waiting','matched','cancelled','expired')),
  opened_by      uuid not null references members(id) on delete restrict,  -- 誰開的房（事實，不變）
  host_id        uuid not null references members(id) on delete restrict,  -- 目前房主（房主退房→轉移給次早加入者）
  play_at        timestamptz not null,               -- ★預定開打時間（開房者指定，唯一的時間錨點）
                                                     --   waiting 到 play_at 未滿員 → expired
                                                     --   matched 後永不自動解散；爽約由店員標 no_show
  matched_at     timestamptz,
  matched_session_id uuid references table_sessions(id) on delete restrict,  -- 店員開局後回填
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);
create index if not exists idx_queues_open
  on match_queues(org_id, store_id, status) where status = 'waiting';

alter table match_queues enable row level security;
revoke all on match_queues from anon, authenticated;

-- C2. 房內玩家（含行為分析欄位：作息/耐心推斷的核心原料）
create table if not exists match_queue_players (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references orgs(id) on delete restrict,
  queue_id    uuid not null references match_queues(id) on delete restrict,
  member_id   uuid not null references members(id) on delete restrict,
  join_source text not null default 'browse'
              check (join_source in ('opened','browse','invited')),
              -- opened=自己開房(揪團核心客) browse=瀏覽加入 invited=受邀(跟隨者)
  joined_at   timestamptz not null default now(),
  left_at     timestamptz,                             -- null=還在房裡(或已成桌)
  leave_reason text check (leave_reason in ('quit','cancelled','expired','switched')),
              -- quit=自己放棄(耐心值只能用這個算!) cancelled=房被解散(無辜)
              -- expired=等到過期 switched=跳去別桌
  no_show     boolean not null default false            -- 成桌後爽約(店員回填)
);
-- 同房不能重複加入；同人同時只能在一個等待房（RPC 內檢查第二條）
create unique index if not exists uq_queue_member
  on match_queue_players(queue_id, member_id) where left_at is null;
create index if not exists idx_qp_member on match_queue_players(member_id) where left_at is null;

alter table match_queue_players enable row level security;
revoke all on match_queue_players from anon, authenticated;

-- C3. 揪桌邀請（邀牌咖進房；拒絕無痕、接受自動入房）
create table if not exists table_invites (
  id           uuid primary key default gen_random_uuid(),
  org_id       uuid not null references orgs(id) on delete restrict,
  queue_id     uuid not null references match_queues(id) on delete restrict,
  inviter_id   uuid not null references members(id) on delete restrict,
  invitee_id   uuid not null references members(id) on delete restrict,
  status       text not null default 'pending'
               check (status in ('pending','accepted','rejected','voided')),  -- voided=房已成桌/取消
  responded_at timestamptz,
  created_at   timestamptz not null default now(),
  check (inviter_id <> invitee_id)
);
create unique index if not exists uq_pending_table_invite
  on table_invites(queue_id, invitee_id) where status = 'pending';

alter table table_invites enable row level security;
revoke all on table_invites from anon, authenticated;


-- ------------------------------------------------------------
-- PART D：RPC 清單（本包的前端唯一入口；簽名先審，實作在確認後的正式版）
-- ------------------------------------------------------------
-- 【A 會員】
--   get_my_profile_tx(p_org_id, p_member_id) → 段位/稱號/獲讚/頭像
--   set_my_avatar_tx(p_org_id, p_member_id, p_avatar)      -- 寫 avatar_url
--   set_my_title_tx(p_org_id, p_member_id, p_title)
--   like_player_tx(p_org_id, p_liker, p_target, p_session) -- 防重複＋likes_count+1
--
-- 【B 牌咖/通知】
--   send_buddy_invite_tx(...)      -- 建邀請＋寫對方 app_notifications(buddy_req)
--   respond_buddy_invite_tx(...)   -- 接受：invites→accepted、buddies 寫兩筆互指、
--                                  --   通知邀請方(buddy_ok)；拒絕：僅改狀態（無痕，不通知）
--   list_buddies_tx(...)           -- 我的牌咖（含段位/獲讚快照）
--   list_recent_players_tx(...)    -- 最近 1 天同桌（session_players 撈，排除已是牌咖/已邀）
--   list_notifications_tx(...) / mark_notifs_read_tx(...)
--
-- 【C 配桌】
--   list_match_queues_tx(p_org_id, p_store_id)   -- 等待中的房＋人數
--   open_match_queue_tx(...)                     -- 開房＋自己入房
--   join_match_queue_tx(p_queue_id, p_member_id, p_source) -- ★核心：SELECT ... FOR UPDATE 鎖房，
--                                                --   join_source: opened/browse/invited 必帶（行為分析）
--                                                --   檢查未滿/未過期/本人不在別房 → 入房；
--                                                --   滿員→status='matched'＋通知全員(table_ok)
--   leave_match_queue_tx(...)                    -- 退房 leave_reason='quit'
--                                                --   房主退→host 轉移給次早加入者（房不解散）
--                                                --   房內剩 0 人→房 cancelled
--                                                --   waiting 過 play_at→'expired'（讀取時懶處理）
--   set_my_availability_tx / get_my_availability_tx -- 「我的空檔時段」(member_availability stated)
--   update_play_at_tx(...)                       -- 店員/房主喬時間：改 play_at＋通知房內全員
--
-- ★人機協作模型：App 管撮合意圖，店員管現場執行——
--   店員可對未滿房強制成桌（代打補位，M2 POS 端操作，本結構不擋）；
--   代打局的店員成績 M4 結算時排除；被店員喬過的桌，M3 分析
--   「自然成桌速度」時需排除（避免店員越勤勞數據越失真）
--   send_table_invite_tx(...)                    -- 揪牌咖＋通知(table_req)
--   respond_table_invite_tx(...)                 -- 接受＝自動 join（複用鎖邏輯）；拒絕無痕
--
-- 全部 SECURITY DEFINER + set search_path，grant execute to anon, authenticated
-- （anon 過渡期；LINE 真登入後改 authenticated-only）


-- ------------------------------------------------------------
-- PART E：即時性策略（誠實標註取捨）
-- ------------------------------------------------------------
-- 等待卡「2/4 → 3/4」的即時更新：
--   正解是 Supabase Realtime 訂閱 match_queue_players，但 Realtime 走 RLS，
--   而本包依基石把 anon 全擋 → 現階段(模擬登入)用「輪詢」：App 每 5 秒呼叫
--   list_match_queues_tx 刷新。等接 LINE 真登入(authenticated)後，
--   開對應 select policy 換成 Realtime，前端只改訂閱層。
-- ------------------------------------------------------------
-- PART G：作息/耐心分析視圖（member_availability 的 inferred 原料）
-- ------------------------------------------------------------
-- 每人等待行為統計：平均/最大耐心、成桌率、放棄率
create or replace view v_member_wait_stats as
select
  qp.org_id,
  qp.member_id,
  count(*)                                                    as total_joins,
  count(*) filter (where q.status = 'matched')                as matched_cnt,
  count(*) filter (where qp.leave_reason = 'quit')            as quit_cnt,
  round(avg(extract(epoch from (q.matched_at - qp.joined_at)) / 60)
        filter (where q.status = 'matched'))                  as avg_wait_to_match_min,
  round(max(extract(epoch from (qp.left_at - qp.joined_at)) / 60)
        filter (where qp.leave_reason = 'quit'))              as max_patience_min,  -- 耐心上限(quit 前最久等待)
  round(avg(extract(epoch from (qp.left_at - qp.joined_at)) / 60)
        filter (where qp.leave_reason = 'quit'))              as avg_patience_min
from match_queue_players qp
join match_queues q on q.id = qp.queue_id
group by qp.org_id, qp.member_id;

-- 每人加入時段分佈（黃金時段；營業日 +08 查詢時才套，基石②）
create or replace view v_member_join_hours as
select
  org_id, member_id,
  extract(dow  from (joined_at at time zone 'Asia/Taipei'))::int as weekday,   -- 0=日
  extract(hour from (joined_at at time zone 'Asia/Taipei'))::int as hour_of_day,
  count(*) as joins
from match_queue_players
group by 1, 2, 3, 4;

-- ★行銷黃金訊號（未來 M3 用）：status='expired' 的房 = 「某人某時段想打但沒人」
--   → 隔週同時段主動推播「今晚開一桌？」精準命中
-- ★路程推斷（未來 M3）：每人×每店的慣性到店時間 =
--   M2 實際報到時間 vs play_at/matched_at 之差，累積取中位數。
--   應用：臨時湊桌只推播給「時段有空＋來得及到店」的會員（派單邏輯），
--   不問地址、純行為推斷，會員無感。


-- ------------------------------------------------------------
-- PART F：黑名單機制（單向紀錄、雙向生效、隱私模糊化）
-- ------------------------------------------------------------
-- 原則：
--   1. A 黑 B → 雙向隔離（互看不到對方的房、互進不去）
--   2. 被擋者永遠不知道原因：訊息一律中性（「此桌已無法加入」），
--      與桌滿/解散同語氣，絕不洩漏黑名單存在（實體店防衝突）
--   3. 四道防線：列表過濾 → 加入鎖內檢查(時間差最終防線) →
--      邀請時檢查 → 接受邀請時再檢查
--   4. 黑掉牌咖 → 自動解除牌咖關係＋作廢未回覆邀請

create table if not exists member_blocks (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references orgs(id) on delete restrict,
  blocker_id  uuid not null references members(id) on delete restrict,
  blocked_id  uuid not null references members(id) on delete restrict,
  reason      text,                      -- 選填（僅本人與總部可見）
  deleted_at  timestamptz,               -- 解除黑名單=軟刪（保留歷史）
  created_at  timestamptz not null default now(),
  check (blocker_id <> blocked_id)
);
create unique index if not exists uq_block_pair
  on member_blocks(blocker_id, blocked_id) where deleted_at is null;
create index if not exists idx_blocks_blocked on member_blocks(blocked_id) where deleted_at is null;

alter table member_blocks enable row level security;
revoke all on member_blocks from anon, authenticated;

-- 雙向檢查的共用邏輯（各 RPC 內使用）：
--   exists (select 1 from member_blocks
--           where deleted_at is null
--             and ((blocker_id = X and blocked_id = Y)
--               or (blocker_id = Y and blocked_id = X)))
--
-- RPC 增補：
--   block_member_tx(p_org_id, p_blocker, p_blocked, p_reason)
--     → 建紀錄＋軟刪 mahjong_buddies 兩筆互指＋void 雙方 pending 邀請
--   unblock_member_tx(...)   -- 軟刪解除
--   list_my_blocks_tx(...)   -- 我的黑名單（設定頁管理用）
--
-- 防線落點：
--   list_match_queues_tx  → not exists(房內任一人與我互黑) 過濾
--   join_match_queue_tx   → FOR UPDATE 鎖內雙向檢查 → 擋:「此桌已無法加入」
--   send_table_invite_tx  → 受邀者 vs 房內全員檢查 → 擋:「無法邀請此牌咖」
--   respond_table_invite_tx → 接受時複用 join 檢查（邀請後房內可能進了互黑者）
--   send_buddy_invite_tx  → 互黑者不能發牌咖邀請（同樣模糊回應）


-- ============================================================
-- 【已拍板】FOR UPDATE 鎖✅ / 5秒輪詢過渡✅ / 不加冷卻期✅
-- 【新增待確認】黑名單：
--   a. 雙向生效（A黑B → 互相隔離）
--   b. 被擋訊息一律中性模糊（不洩漏黑名單存在）
--   c. 黑掉牌咖 → 自動解除牌咖關係
-- ============================================================
