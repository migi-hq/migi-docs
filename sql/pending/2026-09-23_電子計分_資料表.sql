-- ════════════════════════════════════════════════════════════════════
-- 2026-09-23 電子計分 · 第一批：資料表
-- 📄 設計：docs/02-POS與開桌/桌邊記分板設計.md
--
-- 這一份只建結構，不建任何 RPC（那是第二批）。
--   A. scoring_patterns   計台表主檔（27 項，照標準台麻補齊，2026-09-23 使用者拍板）
--   B. table_devices      平板（綁桌不綁座位；憑證只存雜湊）
--   C. session_players    seat 改成 1–4 的數字 ＋ 綁哪一台平板
--   D. table_sessions     score_channel：這一場的廣播頻道（只廣播「版本變了」）
--   E. session_rounds     一將
--   F. hands              一把（含牌型陣列 —— C 區牌型成就靠它，事後補不回來）
--
-- 🔴 命名：這個專案裡 round 一向是「將」（planned_rounds／apply_session_rounds_tx），
--   所以一將叫 session_rounds；**圈風叫 wind，不叫 round**，
--   否則 round 會同時代表「將」和「圈」（一個名字兩個意思）。
-- 🔴 新表全部 RLS 開啟、0 條 policy，並且收掉 anon／authenticated 的表權限：
--   平板與 App 一律走 SECURITY DEFINER 的 RPC（第二批）。
-- ════════════════════════════════════════════════════════════════════

-- ── A. 計台表 ──────────────────────────────────────────────────────
create table if not exists public.scoring_patterns (
  code              text primary key,
  label             text not null,
  tai               int  not null check (tai >= 0),
  max_count         smallint not null default 1 check (max_count between 1 and 4),
  group_key         text not null check (group_key in ('basic','honor','suit','flower','special')),
  needs_flower      boolean not null default false,
  result_only       text check (result_only in ('tsumo','ron')),
  dealer_only       boolean not null default false,
  conflicts         text[] not null default '{}',
  achievement_event text,
  sort              int  not null,
  is_active         boolean not null default true,
  note              text,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);
comment on table public.scoring_patterns is
  '計台表主檔。全台統一（有花／無花兩套由 table_sessions.flower 決定）。改台數改這裡，程式不用動。';
comment on column public.scoring_patterns.max_count is
  '同一把最多可以算幾次。例：三元牌每一組刻子各 1 台，最多 3 組；正花每張 1 台，最多 2 張。';
comment on column public.scoring_patterns.conflicts is
  '不能同時選的項目（雙向檢查，這裡只寫一邊即可）。例：門清自摸 取代 門清 ＋ 自摸。';
comment on column public.scoring_patterns.result_only is
  '只在這種胡法下可以選。null ＝ 自摸、放槍都可以。';
comment on column public.scoring_patterns.achievement_event is
  '這個牌型成立時發的成就事件（pattern_*）。null ＝ 不觸發牌型成就（例：自摸由 hand_tsumo 另外處理）。';

insert into public.scoring_patterns
  (code, label, tai, max_count, group_key, needs_flower, result_only, dealer_only, conflicts, achievement_event, sort, note)
values
  -- 基本
  ('zimo',            '自摸',       1, 1, 'basic',   false, 'tsumo', false, '{}',                                   null,                     10, '自摸時系統自動帶入（選了門清自摸就換成門清自摸）'),
  ('menqing',         '門清',       1, 1, 'basic',   false, 'ron',   false, '{menqing_tsumo,quanqiuren}',           'pattern_menqing',        20, '門清而自摸時改選門清自摸'),
  ('menqing_tsumo',   '門清自摸',   3, 1, 'basic',   false, 'tsumo', false, '{menqing,zimo,quanqiuren}',            'pattern_menqing_tsumo',  30, '標準台麻：取代門清 1 ＋ 自摸 1，不重複計'),
  ('pinghu',          '平胡',       2, 1, 'basic',   false, null,    false, '{pengpenghu,sananke,sianke,wuanke,triplet_dragon,triplet_wind,ziyise}', 'pattern_pinghu', 40, null),
  ('duting',          '獨聽',       1, 1, 'basic',   false, null,    false, '{}',                                   'pattern_duting',         50, null),
  ('quanqiuren',      '全求',       2, 1, 'basic',   false, 'ron',   false, '{}',                                   'pattern_quanqiuren',     60, '全部吃碰、胡別人打的牌'),
  ('haidi',           '海底撈月',   1, 1, 'basic',   false, 'tsumo', false, '{}',                                   'pattern_haidi',          70, null),
  ('gangshang',       '槓上開花',   1, 1, 'basic',   false, 'tsumo', false, '{}',                                   'pattern_gangshang',      80, null),
  ('qianggang',       '搶槓',       1, 1, 'basic',   false, 'ron',   false, '{}',                                   'pattern_qianggang',      90, null),
  -- 字牌
  ('triplet_dragon',  '三元牌',     1, 3, 'honor',   false, null,    false, '{xiaosanyuan,dasanyuan}',              'pattern_triplet_dragon', 110, '中、發、白任一組刻子，每組 1 台'),
  ('triplet_wind',    '風牌',       1, 4, 'honor',   false, null,    false, '{xiaosixi,dasixi}',                    'pattern_triplet_wind',   120, 'MIGI 規則：任何風刻 ＝ 1 台，不分圈風門風（跟標準台麻不同）'),
  ('xiaosanyuan',     '小三元',     4, 1, 'honor',   false, null,    false, '{dasanyuan}',                          'pattern_xiaosanyuan',    130, '已含那兩組三元牌，不另計'),
  ('dasanyuan',       '大三元',     8, 1, 'honor',   false, null,    false, '{}',                                   'pattern_dasanyuan',      140, '已含三組三元牌，不另計'),
  ('xiaosixi',        '小四喜',     8, 1, 'honor',   false, null,    false, '{dasixi}',                             'pattern_xiaosixi',       150, '標準台麻：不另加風牌的台'),
  ('dasixi',          '大四喜',    16, 1, 'honor',   false, null,    false, '{}',                                   'pattern_dasixi',         160, '標準台麻：不另加風牌的台'),
  ('ziyise',          '字一色',    16, 1, 'honor',   false, null,    false, '{hunyise,qingyise}',                   'pattern_ziyise',         170, null),
  -- 花色與刻子
  ('hunyise',         '混一色',     4, 1, 'suit',    false, null,    false, '{qingyise}',                           'pattern_hunyise',        210, null),
  ('qingyise',        '清一色',     8, 1, 'suit',    false, null,    false, '{}',                                   'pattern_qingyise',       220, null),
  ('pengpenghu',      '碰碰胡',     4, 1, 'suit',    false, null,    false, '{}',                                   'pattern_pengpenghu',     230, null),
  ('sananke',         '三暗刻',     2, 1, 'suit',    false, null,    false, '{sianke,wuanke}',                      'pattern_sananke',        240, null),
  ('sianke',          '四暗刻',     5, 1, 'suit',    false, null,    false, '{wuanke}',                             'pattern_sianke',         250, null),
  ('wuanke',          '五暗刻',     8, 1, 'suit',    false, null,    false, '{}',                                   'pattern_wuanke',         260, null),
  -- 花牌（無花局不能選）
  ('zhenghua',        '正花',       1, 2, 'flower',  true,  null,    false, '{}',                                   'pattern_zhenghua',       310, '每張 1 台，最多 2 張（標準台麻）'),
  ('huagang',         '花槓',       2, 2, 'flower',  true,  null,    false, '{}',                                   'pattern_huagang',        320, '一門四張，每門 2 台（標準台麻）'),
  ('qiqiangyi',       '七搶一',     8, 1, 'flower',  true,  null,    false, '{zhenghua,huagang,baxian}',            'pattern_qiqiangyi',      330, '標準台麻 8 台'),
  ('baxian',          '八仙過海',   8, 1, 'flower',  true,  null,    false, '{zhenghua,huagang}',                   'pattern_baxian',         340, '標準台麻 8 台，已含花牌不另計'),
  -- 特殊
  ('tianhu',          '天胡',      24, 1, 'special', false, 'tsumo', true,  '{}',                                   'pattern_tianhu',         410, '標準台麻 24 台，只有莊家')
on conflict (code) do nothing;

alter table public.scoring_patterns enable row level security;
revoke all on public.scoring_patterns from anon, authenticated;

-- ── B. 平板 ────────────────────────────────────────────────────────
create table if not exists public.table_devices (
  id                  uuid primary key default gen_random_uuid(),
  org_id              uuid not null references public.orgs(id),
  store_id            uuid not null references public.stores(id),
  table_id            uuid not null references public.tables(id),
  label               text not null,
  token_hash          text not null unique,
  is_active           boolean not null default true,
  last_seen_at        timestamptz,
  created_at          timestamptz not null default now(),
  created_by_staff_id uuid,
  revoked_at          timestamptz,
  revoked_by_staff_id uuid
);
comment on table public.table_devices is
  '桌邊平板。綁桌不綁座位 —— 座位是每一場開局時重新決定的（session_players.seat）。';
comment on column public.table_devices.label is
  '給人看的編號，例 A3-2。🔴 數字不代表座位，只是「A3 的第幾台」。';
comment on column public.table_devices.token_hash is
  '平板憑證的 SHA-256。明文只在配對當下回傳一次，存在平板的 localStorage，資料庫不存明文。';
comment on column public.table_devices.last_seen_at is
  '最後一次呼叫的時間。沒電或掉線的平板要在客人喊之前就知道。';
create index if not exists idx_table_devices_table on public.table_devices (table_id) where is_active;

alter table public.table_devices enable row level security;
revoke all on public.table_devices from anon, authenticated;

-- ── C. session_players：座位與平板 ────────────────────────────────
-- 🔴 v_real_session_players 直接包含 seat ⇒ 有檢視表依賴的欄位不能改型別。
--   先刪、改完照原定義重建（定義是 2026-09-23 用 pg_get_viewdef 撈的）。
--   ⚠ 檢視表的授權問題（anon 讀得到、繞過 RLS）另開任務處理，這裡不動。
drop view if exists public.v_real_session_players;

alter table public.session_players
  alter column seat type smallint using null::smallint;   -- 58 列全部是 null（查過）
alter table public.session_players
  add constraint session_players_seat_range check (seat between 1 and 4);
alter table public.session_players
  add column if not exists device_id uuid references public.table_devices(id);
comment on column public.session_players.seat is
  '下家鏈的序號 1–4，1 的下家是 2，4 的下家是 1。開局三次點擊填出來。🔴 不存風位 —— 風位跟著莊家輪動，由 hands.dealer_seat 推。';
comment on column public.session_players.device_id is
  '這個人這一場拿哪一台平板。確認機制靠它：A 胡了 B ⇒ 跳 B 的那一台。收桌時清掉。';
create unique index if not exists uq_session_players_seat
  on public.session_players (session_id, seat) where seat is not null;
create unique index if not exists uq_session_players_device
  on public.session_players (session_id, device_id) where device_id is not null;

create view public.v_real_session_players as
 SELECT id, org_id, session_id, member_id, join_type, status, charged_points, joined_at,
        created_at, created_by, finish_rank, score_points, settled_at, order_id, seat,
        left_at, paid_by, fee_waived_amount, fee_waived_reason, rating_after, final_score
   FROM session_players x
  WHERE ((EXISTS ( SELECT 1 FROM v_real_table_sessions rs WHERE (rs.id = x.session_id)))
    AND (NOT (EXISTS ( SELECT 1 FROM members m WHERE ((m.id = x.member_id) AND m.is_test)))));

-- ── D. 這一場的廣播頻道 ────────────────────────────────────────────
-- 資料庫只在這個頻道廣播「版本變了」，不帶任何分數或名字；
-- 平板收到後帶自己的憑證來拿資料。頻道名稱外流也看不到內容。
alter table public.table_sessions
  add column if not exists score_channel text not null
  default encode(extensions.gen_random_bytes(16), 'hex');
comment on column public.table_sessions.score_channel is
  '記分板的廣播頻道（隨機）。只廣播版本號，資料一律走帶憑證的 RPC。';

-- ── E. 一將 ────────────────────────────────────────────────────────
create table if not exists public.session_rounds (
  id                uuid primary key default gen_random_uuid(),
  org_id            uuid not null references public.orgs(id),
  session_id        uuid not null references public.table_sessions(id),
  round_no          smallint not null check (round_no >= 1),
  first_dealer_seat smallint not null check (first_dealer_seat between 1 and 4),
  status            text not null default 'playing' check (status in ('playing','finished','voided')),
  started_at        timestamptz not null default now(),
  finished_at       timestamptz,
  created_at        timestamptz not null default now(),
  unique (session_id, round_no)
);
comment on table public.session_rounds is '一將。一將 ＝ 東南西北四圈，每圈四個莊家。';
create unique index if not exists uq_session_rounds_playing
  on public.session_rounds (session_id) where status = 'playing';

alter table public.session_rounds enable row level security;
revoke all on public.session_rounds from anon, authenticated;

-- ── F. 一把 ────────────────────────────────────────────────────────
create table if not exists public.hands (
  id                  uuid primary key default gen_random_uuid(),
  org_id              uuid not null references public.orgs(id),
  session_id          uuid not null references public.table_sessions(id),
  round_id            uuid not null references public.session_rounds(id),
  hand_no             int  not null check (hand_no >= 1),
  wind                smallint not null check (wind between 1 and 4),
  dealer_seat         smallint not null check (dealer_seat between 1 and 4),
  renzhuang           smallint not null default 0 check (renzhuang >= 0),
  result              text not null check (result in ('tsumo','ron','draw')),
  winner_seat         smallint check (winner_seat between 1 and 4),
  deal_in_seat        smallint check (deal_in_seat between 1 and 4),
  patterns            jsonb not null default '[]'::jsonb,
  tai_pattern         int  not null default 0 check (tai_pattern >= 0),
  manual_tai          boolean not null default false,
  base                int,
  tai_unit            int,
  score_delta         jsonb not null default '{}'::jsonb,
  status              text not null default 'pending'
                      check (status in ('pending','confirmed','rejected','undone')),
  need_confirm        smallint[] not null default '{}',
  confirmed_seats     smallint[] not null default '{}',
  submitted_seat      smallint check (submitted_seat between 1 and 4),
  submitted_device_id uuid references public.table_devices(id),
  rejected_seat       smallint check (rejected_seat between 1 and 4),
  created_at          timestamptz not null default now(),
  confirmed_at        timestamptz,
  undone_at           timestamptz,
  constraint hands_result_shape check (
       (result = 'ron'   and winner_seat is not null and deal_in_seat is not null and winner_seat <> deal_in_seat)
    or (result = 'tsumo' and winner_seat is not null and deal_in_seat is null)
    or (result = 'draw'  and winner_seat is null     and deal_in_seat is null)
  )
);
comment on table public.hands is '一把。客人在平板上記的每一把，確認之後才算數。';
comment on column public.hands.wind is '圈風 1 東 2 南 3 西 4 北。🔴 不叫 round —— round 在這個專案是「將」。';
comment on column public.hands.patterns is
  '牌型陣列 [{"code":"pengpenghu","n":1}, …]。🔴 C 區牌型成就靠它，事後補不回來。直接輸台數那一把是空陣列。';
comment on column public.hands.tai_pattern is
  '牌型台數（不含莊家附加台）。🔴 咪幾與台數成就看這個，不看總台數。';
comment on column public.hands.manual_tai is '這一把是直接輸入台數（沒有牌型資料，不觸發牌型成就）。';
comment on column public.hands.base is '底（記下當時的級距，之後改級距不影響已記的分）。';
comment on column public.hands.tai_unit is '每台多少（同上，快照）。';
comment on column public.hands.score_delta is
  '每個座位這一把的得失 {"1":620,"2":-200,…}，四家加總為 0。莊家附加台 ＝ 1 ＋ renzhuang，由莊家承擔。';
comment on column public.hands.need_confirm is '要誰確認：放槍 ＝ 放槍者；自摸 ＝ 其餘三家；流局 ＝ 不用確認。';

-- 一將裡同時只能有一把在等確認
create unique index if not exists uq_hands_one_pending
  on public.hands (round_id) where status = 'pending';
-- 已確認的把數不重號
create unique index if not exists uq_hands_confirmed_no
  on public.hands (round_id, hand_no) where status = 'confirmed';
create index if not exists idx_hands_session on public.hands (session_id, created_at);

alter table public.hands enable row level security;
revoke all on public.hands from anon, authenticated;

-- ════════════════════════════════════════════════════════════════════
-- 驗證（單一 SELECT，不 raise —— 硬規則 1.8）
-- ⚠ 驗的是交易內的狀態；跑完之後 Claude 會另外查一次線上。
-- ════════════════════════════════════════════════════════════════════
select * from (
  -- 算式：基本 9 ＋ 字牌 7 ＋ 花色刻子 6 ＋ 花牌 4 ＋ 特殊 1 ＝ 27
  select 1 as n, '① 計台表 27 項' as 項目,
         case when (select count(*) from scoring_patterns) = 27 then '✅' else '🔴' end as 結果,
         (select count(*)::text from scoring_patterns) as 細節
  union all
  -- 結構性掃描：每一枚「牌型成就」的事件都要有一個計台項目會發它
  select 2, '② 每一枚牌型成就都接得到（正對照）',
         case when not exists (
                select 1 from achievements a
                 where a.deleted_at is null and a.is_active
                   and a.trigger ->> 'event' like 'pattern\_%' escape '\'
                   and not exists (select 1 from scoring_patterns p where p.achievement_event = a.trigger ->> 'event'))
              then '✅' else '🔴' end,
         (select count(*)::text || ' 枚牌型成就' from achievements a
           where a.deleted_at is null and a.is_active and a.trigger ->> 'event' like 'pattern\_%' escape '\')
  union all
  select 3, '③ 互斥清單裡沒有寫錯的代碼',
         case when not exists (select 1 from scoring_patterns p, unnest(p.conflicts) c
                                where not exists (select 1 from scoring_patterns q where q.code = c))
              then '✅' else '🔴' end, null
  union all
  select 4, '④ seat 改成數字、58 列都還在',
         case when (select data_type from information_schema.columns
                     where table_schema = 'public' and table_name = 'session_players' and column_name = 'seat') = 'smallint'
               and (select count(*) from session_players) = 58
              then '✅' else '🔴' end,
         (select count(*)::text || ' 列' from session_players)
  union all
  select 5, '⑤ v_real_session_players 重建了，欄位 21 個',
         case when (select count(*) from information_schema.columns
                     where table_schema = 'public' and table_name = 'v_real_session_players') = 21
              then '✅' else '🔴' end, null
  union all
  select 6, '⑥ 每一場都有廣播頻道（舊的場次也補上了）',
         case when not exists (select 1 from table_sessions where score_channel is null or length(score_channel) <> 32)
               and (select count(distinct score_channel) from table_sessions) = (select count(*) from table_sessions)
              then '✅' else '🔴' end,
         (select count(*)::text || ' 場' from table_sessions)
  union all
  select 7, '⑦ 新表都開了 RLS',
         case when (select count(*) from pg_class
                     where relnamespace = 'public'::regnamespace
                       and relname in ('scoring_patterns','table_devices','session_rounds','hands')
                       and relrowsecurity) = 4
              then '✅' else '🔴' end, null
  union all
  select 8, '⑧ 新表前端直接查不到（anon／authenticated 沒有表權限）',
         case when not exists (select 1 from unnest(array['scoring_patterns','table_devices','session_rounds','hands']) t,
                                     unnest(array['anon','authenticated']) r
                                where has_table_privilege(r, 'public.' || t, 'select'))
              then '✅' else '🔴' end, null
  union all
  -- 正對照：擋牆會擋（負對照在第二批的行為測試）
  select 9, '⑨ 放槍的形狀檢查存在',
         case when exists (select 1 from pg_constraint where conname = 'hands_result_shape') then '✅' else '🔴' end, null
) v order by n;
