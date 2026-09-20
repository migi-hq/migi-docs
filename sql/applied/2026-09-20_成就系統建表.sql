-- ============================================================
-- 成就系統 · 第一步：建表（不含 RPC、不含 seed）
-- 2026-09-20
--
-- 📄 清單      docs/03-會員App與社交/成就系統企劃.md（300 枚 ＋ 旗艦 2）
-- 📄 接線指南  docs/03-會員App與社交/成就與稱號設計.md（九個要改的問題）
--
-- 🔴 **這不是照抄 `sql/_設計稿未落地/成就系統_建表與RPC.sql`**。
--   那份的架構是好的（事件驅動、四種 struct、tiers、冪等鍵），
--   但它有九個問題，這一份修掉其中與建表有關的五個：
--
--   ⑥ motivation CHECK 只有 6 種      → 十種（含 habit／expression／story／consumption）
--   ⑦ RLS 是 org 級                   → member_achievements 只能讀自己的
--   ⑧ 沒有稀有度欄位                  → rarity 四級（普通／稀有／史詩／傳說）
--   ＋ is_hidden 與 visibility 並存    → **只留 visibility**
--   ＋ 畫面分類無法從 group_key 推導   → **ui_category 逐枚指定**
--
--   其餘四個（grant_points_tx 不存在／revoke／security definer／
--   會員 id 由呼叫端指定／assert_ach_admin／ach_pin_tx 寫死 3 枚）
--   屬於 RPC，在下一份處理。
--
-- 【刻意不建的欄位 —— 每一個都是「建了沒人讀」的候選】
--   repeat_cycle    once/monthly/quarterly：**沒有任何 RPC 會讀它**
--                   要做每月可重複的成就時再加
--   rarity_cached   實際解鎖率：要有定時 job 才有意義，而那個 job 不存在
--                   🔴 而且它與 rarity 是**兩件事**，不可以共用一欄
--                     （rarity 是設計時指定的，rarity_cached 是養出來的結果）
--   is_hidden       被 visibility 取代。兩個都留一定會漂
--
-- 【reward_points 建欄位但這一批不發點數】
--   🔴 `grant_points_tx` **不存在**（2026-09-19 實查）⇒ 發放那段會在 runtime 炸。
--   而 §8.5 的鐵則本來就是「成就給徽章與稱號，點數是最克制的那一層」。
--   ⇒ 欄位留著（日後要用），但 RPC 那一份**不會有發點數的程式碼**。
-- ============================================================

-- ---------- ① 定義表 ----------
create table if not exists achievements (
  id             uuid primary key default gen_random_uuid(),
  org_id         uuid not null references orgs(id) on delete restrict,

  -- 🔴 code 與 name 一定要分家（同 member_tiers 的教訓）：
  --   中文名日後會改，而歷史達成紀錄不可以跟著變
  code           text not null,
  name           text not null,
  description    text,                    -- 客人看到的說明
  condition_text text,                    -- 解鎖條件（給人看的那一句）

  -- 🎯 兩種分類是不同的東西，不可以互相推導
  --   group_key   企劃的 23 區，按「什麼時候發生」分（A 新手引導、C 牌型收藏…）
  --   ui_category 成就牆的六個 tab，按「關於什麼」分
  --   ⚠ 例：「第一杯飲料」的 group_key 是新手引導，ui_category 是餐飲
  group_key      text,
  ui_category    text not null
                 check (ui_category in ('onboarding','game','social','fnb','explore','special')),

  struct         text not null
                 check (struct in ('specific','cumulative','streak','prestige')),
  motivation     text not null
                 check (motivation in ('completion','competition','social','exploration',
                                       'collection','prestige','expression','story',
                                       'consumption','habit')),
  rarity         text not null default 'norm'
                 check (rarity in ('norm','rare','epic','legend')),
  visibility     text not null default 'visible'
                 check (visibility in ('visible','silhouette','hidden')),

  -- 事件驅動：{"event":"migi_win","count":1}
  trigger        jsonb,
  requires_code  text,                    -- 前置成就的 code（要先解鎖才觸發）

  grants_title   text,                    -- 🎯 成就 → 稱號那條線
  is_signature   boolean not null default false,   -- 品牌旗艦（＝咪幾那兩枚）
  reward_points  bigint  not null default 0,       -- ⚠ 欄位在，這一批不發（見檔頭）

  valid_from     timestamptz,             -- 限時檔期；null ＝ 永久
  valid_to       timestamptz,
  is_active      boolean not null default true,    -- 功能還沒做的先 false
  sort           int not null default 0,

  deleted_at     timestamptz,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);

create unique index if not exists uq_ach_code
  on achievements(org_id, code) where deleted_at is null;

create index if not exists idx_ach_trigger_event
  on achievements((trigger->>'event')) where is_active and deleted_at is null;

comment on column achievements.code is
  '穩定識別碼，**不可改** —— member_achievements 靠它記歷史。中文名改 name 那一欄。';
comment on column achievements.ui_category is
  '成就牆的六個 tab。🔴 不可以從 group_key 推導 —— A 區（新手引導）會散到多個 tab。';
comment on column achievements.rarity is
  '設計時指定的稀有度。⚠ 與「實際解鎖率」是兩件事，日後要做那個請另開欄位。';


-- ---------- ② 分級（累積／連續型用） ----------
create table if not exists achievement_tiers (
  id             uuid primary key default gen_random_uuid(),
  org_id         uuid not null references orgs(id) on delete restrict,
  achievement_id uuid not null references achievements(id) on delete cascade,
  tier_level     int  not null,            -- 1=I 2=II 3=III 4=IV
  tier_name      text not null,
  threshold      bigint not null,
  reward_points  bigint not null default 0,
  created_at     timestamptz not null default now(),
  unique (achievement_id, tier_level)
);

-- 🔴 門檻必須隨級數遞增，否則「跨過第幾級」會算出矛盾的答案
create index if not exists idx_acht_ach on achievement_tiers(achievement_id, threshold);


-- ---------- ③ 會員進度 ----------
create table if not exists member_achievements (
  id             uuid primary key default gen_random_uuid(),
  org_id         uuid not null references orgs(id) on delete restrict,
  member_id      uuid not null references members(id) on delete restrict,
  achievement_id uuid not null references achievements(id) on delete restrict,

  status         text not null default 'locked'
                 check (status in ('locked','in_progress','unlocked')),
  current_value  bigint not null default 0,   -- 累積／連續的計數
  current_tier   int    not null default 0,
  last_period    text,                        -- 連續型：最後達成的日／週／月鍵

  -- 🔴 展示櫃只放 **1 枚**（2026-09-20 拍板）
  --   那個唯一索引是機制：靠前端擋不住「兩台同時按」
  pinned         boolean not null default false,

  unlocked_at    timestamptz,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  unique (member_id, achievement_id)
);

create index if not exists idx_ma_member on member_achievements(org_id, member_id);

-- 🎯 一個人同時只能釘 1 枚（部分唯一索引）
--   ⚠ 用索引不用 CHECK —— CHECK 管不到「跨列」的唯一性
create unique index if not exists uq_ma_pinned
  on member_achievements(member_id) where pinned;

comment on column member_achievements.pinned is
  '個人檔案的「我的招牌」，**同時只能有 1 枚**（uq_ma_pinned 擋著）。
   釘新的要先取消舊的 —— RPC 那一份會做成切換語意，不要叫客人先取下。';


-- ---------- ④ RLS ----------
alter table achievements        enable row level security;
alter table achievement_tiers   enable row level security;
alter table member_achievements enable row level security;

do $$ begin
  -- 主檔：人人可讀（成就牆要列出全部，包含還沒解鎖的）
  create policy p_ach_sel  on achievements
    for select using (org_id = public.current_org_id());
  create policy p_acht_sel on achievement_tiers
    for select using (org_id = public.current_org_id());

  -- 🔴 進度是個資（誰解鎖了什麼）—— org 級會讓每個會員看得到所有人的
  --   同待辦 21 那批把 17 條讀取收緊到總部的做法
  create policy p_ma_self on member_achievements
    for select using (member_id = public.current_member_id());
  create policy p_ma_hq   on member_achievements
    for select using (org_id = public.current_org_id() and public.can('member.read'));
exception when duplicate_object then null; end $$;

-- ⚠ **刻意沒有 insert／update／delete policy** ——
--   寫入一律走 SECURITY DEFINER 的 RPC（下一份）。
--   0 policy 對寫入就是全擋，而那是這個系統裡最安全的狀態。


-- ============================================================
-- 驗證（🔴 不可以用 raise —— 這一份要留下 DDL，硬規則 1.8）
-- ============================================================
do $$
declare
  v_msg text := '';
  v_n   int;
  v_t   text;
begin
  -- ① 三張表都在
  select count(*) into v_n from information_schema.tables
  where table_schema='public' and table_name in
        ('achievements','achievement_tiers','member_achievements');
  v_msg := v_msg || case when v_n = 3
    then '✅ ① 三張表都建好了' else '🔴 ① 只有 ' || v_n || ' 張' end;

  -- ② 刻意不建的欄位真的沒建（建了就是「建了沒人讀」）
  select coalesce(string_agg(column_name, '、'), '(沒有)') into v_t
  from information_schema.columns
  where table_schema='public' and table_name='achievements'
    and column_name in ('repeat_cycle','rarity_cached','is_hidden');
  v_msg := v_msg || E'\n' || case when v_t = '(沒有)'
    then '✅ ② repeat_cycle／rarity_cached／is_hidden 都沒建（刻意的）'
    else '🔴 ② 不該建的建了：' || v_t end;

  -- ③ 稀有度是四級
  select count(*) into v_n
  from pg_constraint
  where conrelid='public.achievements'::regclass
    and pg_get_constraintdef(oid) ~ 'rarity'
    and pg_get_constraintdef(oid) ~ 'epic'
    and pg_get_constraintdef(oid) ~ 'legend';
  v_msg := v_msg || E'\n' || case when v_n = 1
    then '✅ ③ rarity 四級（含 epic 與 legend）'
    else '🔴 ③ rarity 的 CHECK 不對' end;

  -- ④ motivation 是十種（v2.3 的 SQL 只有 6 種，匯不進企劃）
  select count(*) into v_n
  from pg_constraint
  where conrelid='public.achievements'::regclass
    and pg_get_constraintdef(oid) ~ 'motivation'
    and pg_get_constraintdef(oid) ~ 'habit'
    and pg_get_constraintdef(oid) ~ 'expression'
    and pg_get_constraintdef(oid) ~ 'story'
    and pg_get_constraintdef(oid) ~ 'consumption';
  v_msg := v_msg || E'\n' || case when v_n = 1
    then '✅ ④ motivation 十種（四個新的都在）'
    else '🔴 ④ motivation 的 CHECK 少了新增的那四種' end;

  -- ⑤ 展示櫃只能放 1 枚
  select count(*) into v_n from pg_indexes
  where schemaname='public' and indexname='uq_ma_pinned'
    and indexdef ~ 'UNIQUE' and indexdef ~ 'WHERE pinned';
  v_msg := v_msg || E'\n' || case when v_n = 1
    then '✅ ⑤ 展示櫃只能放 1 枚（部分唯一索引擋著）'
    else '🔴 ⑤ uq_ma_pinned 沒建或定義不對' end;

  -- ⑥ RLS 開了，而且進度表**不是** org 級
  select count(*) into v_n from pg_policies
  where schemaname='public' and tablename='member_achievements';
  select coalesce(string_agg(policyname || '：' || qual, E'\n     '), '(沒有)') into v_t
  from pg_policies where schemaname='public' and tablename='member_achievements';
  v_msg := v_msg || E'\n' || case when v_n = 2
    then '✅ ⑥ 進度表 2 條 select policy（自己 ＋ 總部），不是 org 級'
    else '🔴 ⑥ 進度表有 ' || v_n || ' 條 policy，應為 2' end
    || E'\n     ' || v_t;

  -- ⑦ 🔴 負對照：寫入 policy 必須是 0 條（寫入只能走 RPC）
  select count(*) into v_n from pg_policies
  where schemaname='public'
    and tablename in ('achievements','achievement_tiers','member_achievements')
    and cmd <> 'SELECT';
  v_msg := v_msg || E'\n' || case when v_n = 0
    then '✅ ⑦ 三張表都沒有寫入 policy（寫入只能走 DEFINER 的 RPC）'
    else '🔴 ⑦ 有 ' || v_n || ' 條寫入 policy —— 那等於開了一條繞過 RPC 的路' end;

  -- ⑧ ✅ 正對照：真的插得進去嗎（只驗「擋住了」等於沒驗，硬規則 3.55）
  --    ⚠ 這一份是 DDL 不能回滾，所以樣本自己刪掉
  begin
    insert into achievements(org_id, code, name, ui_category, struct, motivation, rarity)
    values ((select id from orgs limit 1), '_smoke_test', '煙霧測試',
            'onboarding', 'specific', 'completion', 'legend');

    select count(*) into v_n from achievements where code = '_smoke_test';
    delete from achievements where code = '_smoke_test';

    v_msg := v_msg || E'\n' || case when v_n = 1
      then '✅ ⑧ 正對照：插得進去也刪得掉（樣本已清除）'
      else '🔴 ⑧ 插進去了卻查不到' end;
  exception when others then
    v_msg := v_msg || E'\n' || '🔴 ⑧ 插入失敗：' || sqlstate || ' ' || sqlerrm;
  end;

  -- ⑨ 🔴 負對照：不合法的值要被擋下來
  begin
    insert into achievements(org_id, code, name, ui_category, struct, motivation, rarity)
    values ((select id from orgs limit 1), '_smoke_bad', '壞值測試',
            'onboarding', 'specific', 'completion', '超級稀有');
    delete from achievements where code = '_smoke_bad';
    v_msg := v_msg || E'\n' || '🔴 ⑨ 不合法的 rarity 竟然插得進去 —— CHECK 沒有生效';
  exception when check_violation then
    v_msg := v_msg || E'\n' || '✅ ⑨ 負對照：不合法的 rarity 被 CHECK 擋下';
  when others then
    v_msg := v_msg || E'\n' || '⚠ ⑨ 被擋下但不是 check_violation：' || sqlstate;
  end;

  perform set_config('migi.verify', v_msg, true);
end $$;

select coalesce(nullif(current_setting('migi.verify', true), ''), '🔴 沒有驗證訊息') as "驗證";
