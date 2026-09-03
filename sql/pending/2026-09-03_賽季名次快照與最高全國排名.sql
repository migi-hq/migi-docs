/* ============================================================
   賽季結算時存下每個人的最終名次 → 個人的「最高全國排名」
   2026-09-03 · MIGI

   ── 為什麼需要它 ────────────────────────────────
   成績頁的歷史累積有一格「最高全國排名」，而資料庫**從來沒有存過
   任何歷史排名** —— `season_champions` 只記**冠軍一個人**。
   ⇒ 沒有這一批，那一格永遠只能是 `—`。

   ── 🔴 這一份最重要的一件事：排名只能有一個定義 ──────────
   「現場排名」（成績頁的全國排名）與「結算排名」（存進歷史的）
   **如果各寫一份 SQL，它們一定會在某次調整時分岔** ——
   而症狀是「他明明看到自己第 3 名，歷史卻記成第 5 名」，
   **沒有任何錯誤訊息**。
   ✅ 所以先抽出 `season_rank_rows_tx(org, from, to)`，
     `get_my_stats_tx` 與 `reset_season_ratings_tx` **都呼叫它**。
   📌 同 `migi_slot_of()` / `rating_window_start_tx()` 那兩次的做法。

   ── 🎯 為什麼「用段位分比較」在大師熊以上仍然有效（使用者指出）──
   `apply_session_rounds_tx` 的 `top` 段（865 以上）是 `+30/+5/−20/−40`，
   而那支函式**只有下限沒有上限**（低段 `greatest(v_new, v_floor)`，
   沒有任何 `least(...)`）。
   ⇒ **大師熊之後段位分還會一直長**，所以拿它排名在榜首附近依然分得出高下。
   ⚠ 這一份的驗證段有一格真的跑一次去確認「沒有上限」——
     哪天有人加了封頂，排行榜會從那天起變成一堆並列而**不會報錯**。

   ── ⚠ 冠軍 ≠ 榜首，兩者刻意不同 ──────────────────────
   `season_champions` 的判準是「**是大師熊**而且分數最高」
   （`member_rank_tx(id) = 大師熊`，也就是要滿足 50 位不同對手）。
   `season_standings` 的第 1 名只看**分數最高**。
   ⇒ **沒有人到大師熊的那一季，冠軍是 null 但榜首有人。**
     那是對的：雀神熊是頒給達標者的，排行榜是排所有人的。
   🔴 所以驗證段**不可以**驗「冠軍＝榜首」。
   ============================================================ */

-- ── ① 名次快照表 ───────────────────────────────────────
create table if not exists public.season_standings (
  org_id      uuid        not null,
  season      text        not null,
  member_id   uuid        not null references public.members(id),
  rating      int         not null,
  rank_no     int         not null,
  games       int         not null,
  recorded_at timestamptz not null default now(),
  primary key (org_id, season, member_id)
);

comment on table public.season_standings is
  '每一季結算時的最終名次快照（由 reset_season_ratings_tx 在降階之前寫入）。個人的「最高全國排名」＝ min(rank_no)。⚠ 榜首不等於雀神：冠軍要求是大師熊，榜首只看分數。';
comment on column public.season_standings.rank_no is
  '當季最終名次。排名規則由 season_rank_rows_tx 產生 —— 與成績頁的即時全國排名同一份定義。';

/* 個人查「最高全國排名」用的路徑。
   ⚠ PK 是 (org_id, season, member_id)，前綴不含 member_id ⇒ 查一個人要另一個索引。 */
create index if not exists ix_season_standings_member
  on public.season_standings (org_id, member_id, rank_no);

/* RLS：**開啟但不給 policy** —— 跟 `rank_tiers` / `rank_points` /
   `rank_seasons` / `season_champions` 一致（2026-09-03 查證：那四張都是
   `relrowsecurity = true` 且 0 條 policy）。
   🎯 也就是「誰都不能直接讀，只有 SECURITY DEFINER 的函式讀得到」——
     這張表裝的是**全體會員的分數與名次**，不該讓前端直接查。 */
alter table public.season_standings enable row level security;


-- ── ② 排名的唯一定義 ──────────────────────────────────
create or replace function public.season_rank_rows_tx(
  p_org_id uuid,
  p_from   timestamptz,
  p_to     timestamptz default null
) returns table (member_id uuid, rating int, rank_no int, games int)
language sql stable security definer set search_path to 'public'
as $function$
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
$function$;

comment on function public.season_rank_rows_tx(uuid, timestamptz, timestamptz) is
  '一個視窗內的全國排名（母體＝該視窗打過已結算牌局且非測試的會員，依段位分排序）。成績頁的即時排名與賽季結算的名次快照都用它 —— 排名只能有一個定義。';

/* 🔴 **這一支不給前端叫。** 它會回**所有會員**的分數與名次。
   兩行都要寫（硬規則 2.6b）：
   · 舊函式的 anon 來自 `PUBLIC` 繼承 → `revoke from public`
   · **新建的函式**吃 default privileges，是**明確**授權給 anon → `revoke from anon`
   ⚠ 只收一邊的話症狀跟沒收一模一樣。 */
revoke execute on function public.season_rank_rows_tx(uuid, timestamptz, timestamptz) from public;
revoke execute on function public.season_rank_rows_tx(uuid, timestamptz, timestamptz) from anon, authenticated;
grant  execute on function public.season_rank_rows_tx(uuid, timestamptz, timestamptz) to service_role;


-- ── ③ 結算時寫入名次快照 ──────────────────────────────
create or replace function public.reset_season_ratings_tx(
  p_org_id uuid, p_season text, p_drop_tiers integer default 2
) returns jsonb
language plpgsql security definer set search_path to 'public'
as $function$
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
end $function$;


-- ── ④ get_my_stats_tx：即時排名改呼叫共用函式 ＋ 補最高全國排名 ──
create or replace function public.get_my_stats_tx(
  p_org_id    uuid,
  p_member_id uuid
) returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $function$
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
begin
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

  /* ── 各積分級距：只回場數（勝率停用到 M4）──────────── */
  with mine as (
    select s.stake_level_id,
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
    select coalesce(sl.label, '未設定')  as label,
           coalesce(sl.sort_order, 9999) as sort_order,
           count(*) filter (where m.in_season) as s_games,
           count(*)                            as a_games
      from mine m
      left join stake_levels sl
             on sl.id = m.stake_level_id and sl.org_id = p_org_id
     group by coalesce(sl.label, '未設定'), coalesce(sl.sort_order, 9999)
  )
  select
    coalesce(jsonb_agg(jsonb_build_object('label', label, 'games', s_games)
             order by sort_order, label) filter (where s_games > 0), '[]'::jsonb),
    coalesce(jsonb_agg(jsonb_build_object('label', label, 'games', a_games)
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
      'stakes', v_s_stk
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
      'best_rank',   v_best
    )
  );
end $function$;


-- ── 驗證 ───────────────────────────────────────────────
do $$
declare
  v_org uuid := '11111111-1111-1111-1111-111111111111';
  v_out text := ''; v_store uuid; v_tbl uuid;
  a uuid; b uuid; c uuid; d uuid; s uuid; i int;
  v_season text; v_from timestamptz; v_to timestamptz;
  j jsonb; r jsonb; v_before int; v_after int;
begin
  begin
    select id into v_store from stores where org_id = v_org limit 1;
    select id into v_tbl   from tables where org_id = v_org limit 1;

    v_out := v_out || E'\n' || '① 表建好 · RLS 開著 · 0 條 policy（同其他段位表）' || E'\t' ||
      (select case when c2.relrowsecurity
                    and (select count(*) from pg_policies
                          where schemaname='public' and tablename='season_standings') = 0
                   then '✅ RLS 開、沒有 policy（只有 DEFINER 讀得到）'
                   else '🔴 RLS=' || c2.relrowsecurity end
         from pg_class c2 join pg_namespace n on n.oid=c2.relnamespace
        where n.nspname='public' and c2.relname='season_standings');

    /* 🔴 兩個方向都要驗（硬規則 2.6b）：明確授權沒有、PUBLIC 也沒有。
       只印 `has_function_privilege` 的話，這兩種分不出來。 */
    v_out := v_out || E'\n' || '② 🎯 season_rank_rows_tx 前端叫不到（兩個方向都收）' || E'\t' ||
      (select case when not has_anon and not has_public
                   then '✅ anon 沒有、PUBLIC 也沒有'
                   else '🔴 anon=' || has_anon || ' public=' || has_public end
         from (select
                 exists (select 1 from aclexplode(p.proacl) a2
                          where a2.grantee='anon'::regrole::oid and a2.privilege_type='EXECUTE') as has_anon,
                 (p.proacl is null or exists (select 1 from aclexplode(p.proacl) a3
                          where a3.grantee = 0 and a3.privilege_type='EXECUTE')) as has_public
                 from pg_proc p where p.pronamespace='public'::regnamespace
                  and p.proname='season_rank_rows_tx') z);

    ---- 造四個非測試會員，分數 400 / 300 / 200 / 100 -----
    insert into members (org_id, display_name, rating, rank, is_test)
      values (v_org,'測甲',400, public.rank_from_rating(400), false) returning id into a;
    insert into members (org_id, display_name, rating, rank, is_test)
      values (v_org,'測乙',300, public.rank_from_rating(300), false) returning id into b;
    insert into members (org_id, display_name, rating, rank, is_test)
      values (v_org,'測丙',200, public.rank_from_rating(200), false) returning id into c;
    /* 🎯 測丁是**測試帳號** —— 分數最高，但不該出現在榜上。 */
    insert into members (org_id, display_name, rating, rank, is_test)
      values (v_org,'測丁',999, public.rank_from_rating(999), true) returning id into d;

    insert into table_sessions (org_id, store_id, table_id, mode, status, ended_at)
      values (v_org, v_store, v_tbl, 'private','completed', now()) returning id into s;
    insert into session_players (org_id, session_id, member_id, finish_rank, settled_at)
      values (v_org,s,a,1,now()), (v_org,s,b,2,now()),
             (v_org,s,c,3,now()), (v_org,s,d,4,now());

    v_out := v_out || E'\n' || '③ 🎯 測試帳號不上榜（分數最高的測丁被排除）' || E'\t' ||
      (select case when count(*) = 3 and bool_and(member_id <> d)
                   then '✅ 榜上 3 人，999 分的測試帳號不在'
                   else '🔴 ' || count(*) || ' 人' end
         from public.season_rank_rows_tx(v_org, null));

    /* 🔴 **一致性：這是這一份最重要的一格。**
       `get_my_stats_tx` 的 national_rank 必須等於共用函式算出來的 rank_no。
       兩邊各寫一份的話這一格會紅 —— 而在真實資料上它不會紅，
       只會靜靜對不上。 */
    j := public.get_my_stats_tx(v_org, b);
    v_out := v_out || E'\n' || '④ 🎯 即時排名與共用函式一致（測乙）' || E'\t' ||
      (select case when (j->'season'->>'national_rank')::int = r2.rank_no
                   then '✅ 兩邊都是第 ' || r2.rank_no || ' 名'
                   else '🔴 stats=' || (j->'season'->>'national_rank')
                        || ' rows=' || r2.rank_no end
         from public.season_rank_rows_tx(v_org, null) r2 where r2.member_id = b);

    /* 本季目前第 2 名 ⇒ 還沒結算任何一季時，最高排名就是 2。 */
    v_out := v_out || E'\n' || '⑤ 最高排名含「本季目前」（還沒結算過也有值）' || E'\t' ||
      case when (j->'all'->>'best_rank')::int = 2
           then '✅ 2（只看已結算賽季的話這裡會是 null）'
           else '🔴 ' || coalesce(j->'all'->>'best_rank','null') end;

    ---- 結算一季 ---------------------------------------
    /* 用一個**過去**的賽季來測 —— 現在這一季還沒結束，
       而 `reset_season_ratings_tx` 不檢查「是否已到期」（那是排程的事）。 */
    v_season := '_migi_test_season';
    insert into rank_seasons (org_id, code, label, starts_at, ends_at)
      values (v_org, v_season, '測試季', now() - interval '2 days', now() + interval '1 day');

    r := public.reset_season_ratings_tx(v_org, v_season, 2);
    v_out := v_out || E'\n' || '⑥ 結算成功且寫了 3 列名次' || E'\t' ||
      case when (r->>'ok')::boolean and (r->>'standings_rows')::int = 3
           then '✅ standings_rows=3'
           else '🔴 ' || r::text end;

    /* 🔴 **正對照：名次是「降階之前」的。**
       結算會把大家降 2 大階；如果快照寫在降階之後，
       存下來的 rating 會是新一季的起點（測甲 400 → 更低）。 */
    v_out := v_out || E'\n' || '⑦ 🎯 快照存的是降階前的分數（測甲 400）' || E'\t' ||
      (select case when rating = 400 and rank_no = 1
                   then '✅ 400 · 第 1 名（寫在降階之後會是降完的分數）'
                   else '🔴 rating=' || rating || ' rank=' || rank_no end
         from season_standings
        where org_id = v_org and season = v_season and member_id = a);

    /* 冠軍：這一季沒有人是大師熊（最高 400）⇒ champion 是 null，
       但 standings 有第 1 名。**兩者刻意不同，不要驗相等。** */
    v_out := v_out || E'\n' || '⑧ 🎯 沒人到大師熊 → 冠軍 null，但榜首有人' || E'\t' ||
      case when (r->>'champion') is null
           then '✅ champion=null／榜首=測甲（雀神是頒給達標者，榜單是排所有人）'
           else '🔴 竟然有冠軍 ' || (r->>'champion') end;

    -- 冪等
    r := public.reset_season_ratings_tx(v_org, v_season, 2);
    v_out := v_out || E'\n' || '⑨ 冪等：重跑回 season_already_closed' || E'\t' ||
      case when r->>'reason' = 'season_already_closed' then '✅ 擋住了'
           else '🔴 ' || r::text end;

    ---- 🎯 大師熊以上沒有上限 ---------------------------
    /* 使用者指出「大師熊以上仍可以持續增加段位分」——
       這一格真的跑一次去確認。哪天有人加了封頂，
       排行榜會從那天起變成一堆並列而**不會報錯**。 */
    update members set rating = 900, rank = public.rank_from_rating(900),
                       rating_games = 0 where id in (a,b,c,d);
    select rating into v_before from members where id = a;
    insert into table_sessions (org_id, store_id, table_id, mode, status, ended_at)
      values (v_org, v_store, v_tbl, 'private','completed', now()) returning id into s;
    insert into session_players (org_id, session_id, member_id)
      values (v_org,s,a), (v_org,s,b), (v_org,s,c), (v_org,s,d);
    r := public.apply_session_rounds_tx(s, jsonb_build_array(
      jsonb_build_array(
        jsonb_build_object('member_id',a,'finish_rank',1),
        jsonb_build_object('member_id',b,'finish_rank',2),
        jsonb_build_object('member_id',c,'finish_rank',3),
        jsonb_build_object('member_id',d,'finish_rank',4)),
      jsonb_build_array(
        jsonb_build_object('member_id',a,'finish_rank',1),
        jsonb_build_object('member_id',b,'finish_rank',2),
        jsonb_build_object('member_id',c,'finish_rank',3),
        jsonb_build_object('member_id',d,'finish_rank',4))));
    select rating into v_after from members where id = a;
    /* 900 ＋ top 段第 1 名 30 × 2 將 = 960 */
    v_out := v_out || E'\n' || '⑩ 🎯 大師熊以上還會繼續加分（900 → 960）' || E'\t' ||
      case when v_after = 960
           then '✅ 960（有人加封頂的話這一格會紅，而排行榜會靜靜變成一堆並列）'
           else '🔴 ' || v_before || ' → ' || v_after
                || '（top 段第 1 名應該是 +30 ×2 將）' end;

    raise exception 'migi_rollback';
  exception when others then
    if sqlerrm <> 'migi_rollback' then
      v_out := v_out || E'\n' || '🔴 測試自己炸了' || E'\t' || sqlerrm;
    end if;
    perform set_config('migi.std', v_out, true);
  end;
end $$;

select split_part(x, E'\t', 1) as 測試,
       split_part(x, E'\t', 2) as 結果
  from unnest(string_to_array(current_setting('migi.std', true), E'\n')) as x
 where coalesce(x,'') <> '';
