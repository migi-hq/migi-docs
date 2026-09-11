/* ============================================================
   牌咖團地基：三張表 ＋ 「一起打了幾場」的唯一定義
   2026-09-11 · 待辦 33 那批「純補後端」的第一個

   ── 這份只建結構，不建 RPC ──────────────────────────
   函式在下一份（`2026-09-11_牌咖團函式.sql`）。拆開的理由是
   **先讓場次判定被實際跑過一次**，再把十幾支函式疊在它上面。
   一支沒驗過的判定會讓每一支讀它的函式都繼承同一個錯（硬規則 7）。

   ⚠ 這份**要留下東西，所以一個字都不准 `raise`**（硬規則 1.8）。
     行為測試（造樣本、看它真的算對）在
     `sql/checks/2026-09-11_驗牌咖團場次判定.sql`，那一份才可以 raise 回滾。

   ── 牌咖團是公會，不是一桌四個人 ────────────────────
   使用者 2026-09-11 拍板：
   > 「牌咖團應該等同公會 可以多人加入」
   > 「實務上麻將館一半以上是包桌，要讓包桌跟 App 有深度連結」
   > 「包桌的人不一定固定 4 個人，可能是一群朋友 8 個人中每次來不同 4 個」

   🔴 所以前端 `buddies.jsx:136` 那個 `團員 · N/4` 是錯的，要拿掉。
     而 `:223` 熱門榜的「128 位團員」才是對的讀法。
     ⚠ 同一個畫面自己在說兩件事 —— 這個專案記過的同一族病，這次在設計層。

   ── 🔴 「一起打了 N 場」：整桌都是團員才算 ──────────
   使用者 2026-09-11 明確推翻我提的「兩位以上團員同桌」：
   > 「不行 一定要全員」

   而八個人的團坐不進一張四人桌 ⇒ **「全員」＝整桌都是團員**，
   不是全團到齊。兩個團員加兩個陌生人那桌不算，那是配桌不是團的活動。
   🎯 這正好對上包桌的語意：一整桌都是自己人。

   ```
   一場算進團的戰績  ⇔  該場次每一位在座玩家，坐下的那一刻都還在團裡
                    且  在座人數 ≥ 2
   ```

   ⚠ **下限放 2 不放 4**：只來三人的包桌是真的會發生（檯費就收三份，
     見 CLAUDE.md 待辦 3 那條「只來三人就收三份」）。硬要四人會把它漏掉。
     2 只是擋掉單人場次那種資料異常。

   ### 🔴 團員資格看「當時」不看「現在」，而那是這個決定的連帶結果
   原本兩人以上的寬鬆規則下，有人退團只是少算幾場。
   改成整桌都要是團員之後，**一個人退團會讓他參與過的每一場全部失效**
   ⇒ 團的總場數突然掉下來，而且沒有任何地方會說為什麼。
   ✅ 所以比對的是 `team_members.joined_at ~ left_at` 這個區間。
     那兩個欄位本來就要有，成本是零。

   ### 🎯 時間戳只用一個：`session_players.joined_at`
   它同時當兩件事用：**判斷當時在不在團裡**，以及**這場算哪個月**。
   🔴 刻意不用 `table_sessions.started_at` —— `sql/_工具/測試戰績_造.sql`
     造出來的 fixture 那一欄比 `ended_at` 還晚（CLAUDE.md 有記），
     而且用兩個時間戳就是「同一件事兩個答案」。
   ⚠ `joined_at` 萬一是 null 就退回 `table_sessions.created_at` ——
     退回的值兩處**必須一致**，所以寫在同一個運算式裡。

   ── 這份做了什麼 ──────────────────────────────────
   ① teams / team_members / team_requests 三張表
   ② app_notifications.type 白名單加 team_req / team_ok
   ③ `_team_session_ids(team)` —— 場次判定的**唯一**定義
   ============================================================ */


/* ─────────────────────────────────────────────────────────
   ① teams
   ───────────────────────────────────────────────────────── */
create table if not exists public.teams (
  id            uuid primary key default gen_random_uuid(),
  org_id        uuid not null references public.orgs(id),

  name          text not null,
  intro         text,

  /* 團徽兩種來源，照片優先。
     🔴 `crest_path` 是 Storage 路徑，**由伺服器決定**（同頭像那條路：
       Edge Function 發簽名上傳網址，前端沒有機會指定路徑）。
     ⚠ 使用者 2026-09-11 決定**團徽不審核**。那是他的決定，照做 ——
       但「不審核」不等於「不能下架」，所以留 `crest_blocked`，
       比照 `members.avatar_blocked` 與 `admin_remove_avatar_tx`。
       不留的話，真的出事時唯一的辦法是直接改資料庫。 */
  crest_emoji   text,
  crest_path    text,
  crest_blocked boolean not null default false,

  /* 主場門市。找團那頁的「推薦給你 · 你常去自由店」靠它比對。
     可以是 null（沒有固定主場的團）。 */
  home_store_id uuid references public.stores(id),

  /* 🔴 三態不是兩態（2026-09-11 使用者指定，我上一版漏了）。
     部落衝突那一族的公會都是三態，而**八個朋友的團最常見的狀態
     就是「不要陌生人」** —— 少了 closed，那種團只能把申請一直擋掉。 */
  join_policy   text not null default 'approval',

  /* 本月目標場數。
     🔴 假畫面寫死 50，那個數字對三個人的團不可能、對三十人的團沒有意義。
     ⚠ 而且「整桌都是團員」讓門檻更高：一週包一到兩次桌 ≈ 一個月十場。
       所以預設 10，團長可以自己改。 */
  monthly_goal  int  not null default 10,

  /* 公會不設產品層的人數上限（使用者指定「可以多人加入」）。
     這一欄純粹是技術護欄，防止有人灌出一個讓畫面與統計爆掉的團。 */
  member_limit  int  not null default 200,

  created_by    uuid not null references public.members(id),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  deleted_at    timestamptz
);

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'teams_join_policy_check') then
    alter table public.teams add constraint teams_join_policy_check
      check (join_policy in ('open', 'approval', 'closed'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'teams_name_len_check') then
    alter table public.teams add constraint teams_name_len_check
      check (char_length(btrim(name)) between 2 and 20);
  end if;
  if not exists (select 1 from pg_constraint where conname = 'teams_intro_len_check') then
    alter table public.teams add constraint teams_intro_len_check
      check (intro is null or char_length(intro) <= 200);
  end if;
  if not exists (select 1 from pg_constraint where conname = 'teams_crest_emoji_len_check') then
    /* emoji 可能是好幾個碼位組起來的（膚色、ZWJ），所以不是 1。
       8 夠用，同時擋掉「把一整句話塞進團徽」。 */
    alter table public.teams add constraint teams_crest_emoji_len_check
      check (crest_emoji is null or char_length(crest_emoji) <= 8);
  end if;
  if not exists (select 1 from pg_constraint where conname = 'teams_monthly_goal_check') then
    alter table public.teams add constraint teams_monthly_goal_check
      check (monthly_goal between 1 and 999);
  end if;
  if not exists (select 1 from pg_constraint where conname = 'teams_member_limit_check') then
    alter table public.teams add constraint teams_member_limit_check
      check (member_limit between 4 and 500);
  end if;
end $$;

/* 🔴 團名同 org 內唯一。
   找團唯一的入口就是搜尋團名，兩個「週末班」會讓那一頁失去意義
   —— 遊戲的公會名也都是唯一的。
   ⚠ 比對用 `lower(btrim(...))`，不然「週末班」與「週末班 」是兩個。
   ⚠ 已刪除的團不佔名字。 */
create unique index if not exists uq_teams_name
  on public.teams (org_id, lower(btrim(name))) where deleted_at is null;

create index if not exists ix_teams_home_store
  on public.teams (org_id, home_store_id) where deleted_at is null;


/* ─────────────────────────────────────────────────────────
   ② team_members
   ───────────────────────────────────────────────────────── */
create table if not exists public.team_members (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references public.orgs(id),
  team_id     uuid not null references public.teams(id),
  member_id   uuid not null references public.members(id),

  /* 🔴 只有兩級，不做副團長（硬規則 5.7 角色繼承那一族）。
     團長失聯的單點失效改用**自動接管**解決，不是加一個階級 ——
     那是手遊業的答案，而且 `members.last_app_active_at` 與
     `last_visit_at` 今天就是活的（待辦 24），規則跑得動。 */
  role        text not null default 'member',

  joined_at   timestamptz not null default now(),
  left_at     timestamptz,
  left_reason text,

  created_at  timestamptz not null default now()
);

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'team_members_role_check') then
    alter table public.team_members add constraint team_members_role_check
      check (role in ('leader', 'member'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'team_members_left_reason_check') then
    /* ⚠ 每一個值講的是**不同的事**，不要為了省事共用一個。
       `quit` 說「他自己走的」，店員／團長把人移除卻寫 quit，
       那個欄位就在說一件沒發生的事 —— 同 2026-09-10 配桌那批的決定。 */
    alter table public.team_members add constraint team_members_left_reason_check
      check (left_reason is null
             or left_reason in ('quit', 'kicked', 'disband'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'team_members_left_shape_check') then
    /* 走了就一定要有理由，沒走就一定不能有理由。
       少了這一條，`left_at` 有值而 `left_reason` 是 null 的列會慢慢長出來，
       而那種列在流失分析裡是永遠查不出原因的一格。 */
    alter table public.team_members add constraint team_members_left_shape_check
      check ((left_at is null) = (left_reason is null));
  end if;
end $$;

/* 同一個人在同一個團，同時只能有一列「還在團裡」。
   ⚠ 退團再加入會是**新的一列**，而那是刻意的 —— `joined_at` 區間
     是場次判定的依據，覆寫舊列會讓他退團那段期間的場次被算回來。 */
create unique index if not exists uq_team_member_active
  on public.team_members (team_id, member_id) where left_at is null;

/* 一個團同時只有一個團長。
   🔴 這是轉讓團長那支函式唯一的守衛 —— 少了它，寫錯順序會安靜地
     生出兩個團長，而畫面上兩個人都會看到團長的按鈕。 */
create unique index if not exists uq_team_one_leader
  on public.team_members (team_id) where role = 'leader' and left_at is null;

create index if not exists ix_team_members_member
  on public.team_members (member_id) where left_at is null;


/* ─────────────────────────────────────────────────────────
   ③ team_requests —— 申請與邀請同一張表
   ───────────────────────────────────────────────────────── */
/* 🔴 兩個方向**刻意不分兩張表**。
   它們是同一個事實（「這個人與這個團正在談加入」）的兩個方向，
   分兩張表就要維護兩套狀態機、兩套通知、兩套過期規則，
   而且「同時有一筆申請與一筆邀請」這種荒謬狀態會擋不住。
   ⇒ 一張表 ＋ `kind`，再用一個部分唯一索引保證同時只有一筆在談。

   ⚠ `created_by` 是**動作的人**：`apply` 時等於 `member_id`，
     `invite` 時是團長。它不是冗餘 —— 邀請可能由不同團長發出，
     而稽核要答得出「是誰邀的」。 */
create table if not exists public.team_requests (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references public.orgs(id),
  team_id     uuid not null references public.teams(id),
  member_id   uuid not null references public.members(id),

  kind        text not null,
  status      text not null default 'pending',

  created_by  uuid not null references public.members(id),
  decided_by  uuid references public.members(id),
  decided_at  timestamptz,

  /* 🔴 會過期，而且**不靠排程**。
     團長不再出現時，申請如果永遠掛著，那個人既加不進來也不知道被拒絕。
     ⚠ 但不開 pg_cron —— 「要有人看告警」的東西這個專案不做（硬規則 5.5）。
       改成**列出與再次申請時順手把過期的收掉**，那是一個一定會發生的動作。 */
  expires_at  timestamptz not null default (now() + interval '14 days'),
  created_at  timestamptz not null default now()
);

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'team_requests_kind_check') then
    alter table public.team_requests add constraint team_requests_kind_check
      check (kind in ('apply', 'invite'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'team_requests_status_check') then
    alter table public.team_requests add constraint team_requests_status_check
      check (status in ('pending', 'accepted', 'rejected', 'cancelled', 'expired'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'team_requests_decided_shape_check') then
    alter table public.team_requests add constraint team_requests_decided_shape_check
      check ((status = 'pending') = (decided_at is null));
  end if;
end $$;

/* 同一個人對同一個團，同時只能有一筆在談（不分方向）。 */
create unique index if not exists uq_team_request_pending
  on public.team_requests (team_id, member_id) where status = 'pending';

create index if not exists ix_team_requests_member
  on public.team_requests (member_id, status);


/* ─────────────────────────────────────────────────────────
   ④ RLS：開啟，但**一條 policy 都不加**
   ───────────────────────────────────────────────────────── */
/* 🎯 這是這個系統裡最安全的狀態，不是漏掉的意思 ——
   46 張表裡有 20 張就是這樣（CLAUDE.md 待辦 21 第 ③ 步查證過）。
   所有存取一律走 SECURITY DEFINER 的 RPC，前端永遠不直接查這三張表。
   ⚠ 日後真的要讓總部讀（做後台），那是**加一條 `can('ops.read')`**，
     不是把 RLS 關掉。 */
alter table public.teams          enable row level security;
alter table public.team_members   enable row level security;
alter table public.team_requests  enable row level security;


/* ─────────────────────────────────────────────────────────
   ⑤ app_notifications 的型別白名單
   ───────────────────────────────────────────────────────── */
/* 🔴 那是白名單不是格式檢查（已撈出定義確認，不是猜的）——
   不加值的話，第一次有人申請加入就會插入失敗，
   **而通知是靜默的，那一筆會直接消失**（同 `app_events` 那個坑）。
   命名跟著既有的 `buddy_req`／`buddy_ok`／`table_req`／`table_ok` 走，
   讓區分是結構不是一份要維護的清單。 */
do $$
begin
  alter table public.app_notifications drop constraint if exists app_notifications_type_check;
  alter table public.app_notifications add constraint app_notifications_type_check
    check (type in ('settle', 'buddy_req', 'buddy_ok', 'table_req', 'table_ok',
                    'system', 'table_expired',
                    'team_req', 'team_ok'));
end $$;


/* ─────────────────────────────────────────────────────────
   ⑥ 🔴 場次判定：整個系統只有這一份定義
   ───────────────────────────────────────────────────────── */
/* 寫成函式而不是在每支 RPC 裡各抄一次，理由就是這個專案記過八次的病：
   **手抄的東西只會抄「當下需要的」**，兩份遲早會漂，而漂掉不會報錯，
   只會讓「團總場數」與「我的本月貢獻」對不起來。

   回傳每一場的 id 與 `played_at`（那一桌最早有人坐下的時間）。
   月份篩選一律用 `played_at`，不要另外挑一個時間欄位。

   ⚠ 效能：這支會掃過 `session_players` 全表再分組。今天 118 場，
     完全不是問題。團變多、場次上萬之後才需要物化 —— 那時再說，
     不要現在先建一張會漂的統計表（同待辦 1 的 B 案：從事實表算）。 */
create or replace function public._team_session_ids(p_team_id uuid)
returns table (session_id uuid, played_at timestamptz)
language sql
stable
as $$
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
$$;

/* 內部用，前端永遠不該叫得到它。
   ⚠ 兩個方向都要收（硬規則 2.6b）：新建的函式是**明確授權**給 anon，
     而舊的管理函式是從 PUBLIC 繼承 —— 只收一邊的症狀跟沒收一模一樣。 */
revoke execute on function public._team_session_ids(uuid) from public;
revoke execute on function public._team_session_ids(uuid) from anon, authenticated;


/* ============================================================
   驗證
   🔴 這一份要留下 DDL，所以**整段不准 raise**（硬規則 1.8）——
     raise 會把上面那些 create table 一起回滾，而訊息照樣印出來，
     六格全綠而資料庫一張表都沒有。
   ⚠ 行為測試（造樣本、確認它真的算對）不在這裡，在
     `sql/checks/2026-09-11_驗牌咖團場次判定.sql`。
     那一份會 raise，因為它**不該留下任何東西**。
   ============================================================ */
do $$
declare
  v_msg   text := '';
  v_n     int;
  v_types int;
  v_probe int;
begin
  /* ① 三張表 */
  select count(*) into v_n from information_schema.tables
   where table_schema = 'public' and table_name in ('teams','team_members','team_requests');
  v_msg := v_msg || case when v_n = 3
    then '① ✅ 三張表都在'
    else '① 🔴 只建出 ' || v_n || ' 張（預期 3）' end;

  /* ② CHECK 約束
     期望值算式：teams 6（政策／團名長度／簡介長度／團徽長度／目標／人數上限）
                ＋ team_members 3（角色／離開理由／離開形狀）
                ＋ team_requests 3（方向／狀態／決定形狀）  ＝ 12 */
  select count(*) into v_n
    from pg_constraint c join pg_class r on r.oid = c.conrelid
   where c.contype = 'c' and r.relname in ('teams','team_members','team_requests');
  v_msg := v_msg || E'\n' || case when v_n = 12
    then '② ✅ CHECK 12 條（teams 6 ＋ team_members 3 ＋ team_requests 3）'
    else '② 🔴 CHECK ' || v_n || ' 條，預期 12 —— 先看是哪一張表少了' end;

  /* ③ 四個唯一索引，每一個都擋一種「不會報錯的錯」 */
  select count(*) into v_n from pg_indexes
   where schemaname = 'public'
     and indexname in ('uq_teams_name','uq_team_member_active',
                       'uq_team_one_leader','uq_team_request_pending');
  v_msg := v_msg || E'\n' || case when v_n = 4
    then '③ ✅ 四個唯一索引都在（團名／在團中／一團一團長／同時只談一筆）'
    else '③ 🔴 只有 ' || v_n || ' 個，預期 4' end;

  /* ④ 通知型別白名單 7 → 9
     🔴 期望值當場查出來，不要憑印象（硬規則 3.56 那一族）。 */
  select count(*) into v_types
    from pg_constraint c
    cross join lateral regexp_matches(pg_get_constraintdef(c.oid), '''([a-z_]+)''::text', 'g') m
   where c.conname = 'app_notifications_type_check';
  v_msg := v_msg || E'\n' || case when v_types = 9
    then '④ ✅ 通知型別 9 個（原本 7 ＋ team_req ＋ team_ok）'
    else '④ 🔴 通知型別 ' || v_types || ' 個，預期 9（原本 7 ＋ 這批 2）' end;

  /* ⑤ RLS 開了而且零 policy —— 兩件事要一起驗。
     只驗「開了 RLS」的話，一條寬鬆的 policy 也會讓它變綠。 */
  select count(*) into v_n from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relname in ('teams','team_members','team_requests')
     and c.relrowsecurity;
  select count(*) into v_probe from pg_policies
   where schemaname = 'public' and tablename in ('teams','team_members','team_requests');
  v_msg := v_msg || E'\n' || case when v_n = 3 and v_probe = 0
    then '⑤ ✅ 三張表都開了 RLS 且 0 條 policy（＝完全鎖死，只有 DEFINER 進得去）'
    else '⑤ 🔴 開了 RLS 的 ' || v_n || '/3，policy ' || v_probe || ' 條（預期 0）' end;

  /* ⑥ 場次判定**實際執行一次**（硬規則 7）。
     ⚠ 這一格只證明「函式跑得動、欄位名都對得上」——
       它回 0 列是必然的（還沒有任何團），所以標 ⚪ 不標 ✅。
       **「整桌都是團員」到底算不算得對，要看 checks/ 那一份的正對照**
       （硬規則 3.55：只驗「應該是空的」那一半等於沒驗）。 */
  begin
    select count(*) into v_probe
      from public._team_session_ids('00000000-0000-0000-0000-000000000000'::uuid);
    v_msg := v_msg || E'\n⑥ ⚪ 場次判定跑得動，回 ' || v_probe
                   || ' 列（還沒有團，本來就該是 0）'
                   || E'\n     🔴 它算得對不對要跑 sql/checks/2026-09-11_驗牌咖團場次判定.sql';
  exception when others then
    v_msg := v_msg || E'\n⑥ 🔴 場次判定執行失敗：' || sqlerrm;
  end;

  /* ⑦ 授權：內部函式不可以讓前端叫得到。
     🔴 兩種來源要分開印（硬規則 2.6）—— `has_function_privilege`
       分不出「明確授權」與「從 PUBLIC 繼承」，收錯方向時
       看到的症狀跟沒收一模一樣。 */
  select count(*) into v_n
    from pg_proc p
    left join lateral aclexplode(p.proacl) a on true
   where p.pronamespace = 'public'::regnamespace
     and p.proname = '_team_session_ids'
     and (a.grantee = 'anon'::regrole::oid or a.grantee = 0)
     and a.privilege_type = 'EXECUTE';
  v_msg := v_msg || E'\n' || case when v_n = 0
    then '⑦ ✅ 場次判定：anon 沒有明確授權，PUBLIC 也沒有'
    else '⑦ 🔴 前端叫得到它（' || v_n || ' 筆授權還在）' end;

  /* ⑧ 負對照：確認 ⑦ 那個掃描器是活的。
     🔴 只驗「查不到」的話，一支永遠回 0 的查詢也會全綠 ——
       拿一支**本來就該給 anon 叫**的函式對照。 */
  select count(*) into v_n
    from pg_proc p
    left join lateral aclexplode(p.proacl) a on true
   where p.pronamespace = 'public'::regnamespace
     and p.proname = 'list_product_taxonomy_tx'
     and (a.grantee = 'anon'::regrole::oid or a.grantee = 0)
     and a.privilege_type = 'EXECUTE';
  v_msg := v_msg || E'\n' || case when v_n > 0
    then '⑧ ✅ 負對照：掃描器是活的（list_product_taxonomy_tx 查得到 ' || v_n || ' 筆授權）'
    else '⑧ 🔴 負對照失敗 —— ⑦ 的綠燈不算數，那支掃描器什麼都查不到' end;

  perform set_config('migi.chk', v_msg, true);
end $$;

select coalesce(nullif(current_setting('migi.chk', true), ''), '🔴 沒有訊息') as "驗證";
