-- ════════════════════════════════════════════════════════════════════
-- 2026-09-23 上線前，排行榜與全國排名把測試帳號也排進去（使用者拍板）
--
-- 起點：「玩家成績排名現在還是空的」—— 線上 5 個會員全部 is_test，
--   而 season_rank_rows_tx 排除測試帳號 ⇒ 排行榜、全國排名永遠空到第一個真客人出現。
--
-- 做法：排名邏輯收成一份核心，「看」與「結算」各包一層
--   _season_rank_rows_core(org, from, to, include_test)   ← 唯一一份規則
--   season_rank_rows_tx          include_test = false       ← **結算用，行為完全不變**
--   season_rank_rows_display_tx  include_test = 還沒上線     ← 排行榜、全國排名用
--
-- 🔴 **結算刻意不跟著改**：reset_season_ratings_tx 用它決定賽季冠軍，
--   而冠軍拿到的「<年> <季>季雀神熊」是**永久稱號**。若結算也算測試帳號，
--   2027-01-01 還沒上線的話，會有測試帳號永久拿到「2026 秋季雀神熊」而且拿不掉。
-- 🎯 「還沒上線」＝ orgs.live_from 是 null 或還沒到 —— 跟 get_my_profile_tx 的 live
--   同一個事實。**上線那天設 live_from，測試帳號自動從榜上消失**，不用有人記得關。
-- ⚠ 名人堂（season_champions）不動：它來自結算，本來就另外擋測試帳號。
-- ════════════════════════════════════════════════════════════════════

-- ── A. 唯一一份規則 ────────────────────────────────────────────────
create or replace function public._season_rank_rows_core(
  p_org_id uuid, p_from timestamptz, p_to timestamptz, p_include_test boolean)
returns table(member_id uuid, rating integer, rank_no integer, games integer)
language sql stable security definer set search_path to 'public'
as $$
  /* 母體：這個視窗內至少打過一場「已結算」牌局的會員。
     🔴 **不能拿全部會員排** —— `members.rating` 是 `NOT NULL DEFAULT 0`，
       沒打過的人也有 0 分，那樣分母會變成「開過帳號的人數」。
     ⚠ `p_to` 為 null = 沒有上限（現場排名用）。結算時要給那一季的
       `ends_at` —— 否則**結算晚了幾天，那幾天的牌局會被算進上一季**。
     ⚠ 測試帳號排不排由呼叫端決定（`p_include_test`），不要在這裡判斷上線了沒 ——
       結算與顯示要的答案不一樣。 */
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
$$;

-- ── B. 結算用：簽名不變、行為不變 ──────────────────────────────────
create or replace function public.season_rank_rows_tx(
  p_org_id uuid, p_from timestamptz, p_to timestamptz default null)
returns table(member_id uuid, rating integer, rank_no integer, games integer)
language sql stable security definer set search_path to 'public'
as $$
  /* 🔴 **結算用：永遠排除測試帳號**（2026-09-23 起規則搬到 _season_rank_rows_core）。
     reset_season_ratings_tx 用它決定賽季冠軍，而冠軍稱號是永久的 ——
     這裡**不可以**跟著「上線前顯示測試帳號」一起放寬。 */
  select * from public._season_rank_rows_core(p_org_id, p_from, p_to, false)
$$;

-- ── C. 顯示用：上線前把測試帳號也排進去 ───────────────────────────
create or replace function public.season_rank_rows_display_tx(
  p_org_id uuid, p_from timestamptz, p_to timestamptz default null)
returns table(member_id uuid, rating integer, rank_no integer, games integer)
language sql stable security definer set search_path to 'public'
as $$
  /* 排行榜與成績頁「全國排名」用。**只用在「看」，不可以拿去結算。**
     上線前（live_from 未設或未到）連測試帳號一起排，讓畫面有東西可以看；
     上線那一刻自動變回只排真客人。 */
  select * from public._season_rank_rows_core(
    p_org_id, p_from, p_to,
    not exists (select 1 from orgs o where o.id = p_org_id
                 and o.live_from is not null and now() >= o.live_from))
$$;

revoke execute on function public._season_rank_rows_core(uuid, timestamptz, timestamptz, boolean) from public;
revoke execute on function public._season_rank_rows_core(uuid, timestamptz, timestamptz, boolean) from anon, authenticated;
grant  execute on function public._season_rank_rows_core(uuid, timestamptz, timestamptz, boolean) to service_role;
revoke execute on function public.season_rank_rows_display_tx(uuid, timestamptz, timestamptz) from public;
revoke execute on function public.season_rank_rows_display_tx(uuid, timestamptz, timestamptz) from anon, authenticated;
grant  execute on function public.season_rank_rows_display_tx(uuid, timestamptz, timestamptz) to service_role;

-- ── D. 排行榜與全國排名改叫顯示用那支 ──────────────────────────────
-- ⚠ 只換「public.season_rank_rows_tx(」這個呼叫形狀 —— 註解裡的名字不帶 public.，不會被換到
do $$
declare v_old text; v_new text; v_n int;
begin
  -- 全國排名：應該換到 2 處
  v_old := pg_get_functiondef('public.get_my_stats_tx'::regproc);
  v_n   := (select count(*) from regexp_matches(v_old, 'public\.season_rank_rows_tx\(', 'g'));
  if v_n <> 2 then raise exception 'get_my_stats_tx 預期 2 處呼叫，實際 % 處，整份回滾', v_n; end if;
  v_new := replace(v_old, 'public.season_rank_rows_tx(', 'public.season_rank_rows_display_tx(');
  execute v_new;

  -- 排行榜：應該換到 1 處
  v_old := pg_get_functiondef('public.get_season_leaderboard_tx'::regproc);
  v_n   := (select count(*) from regexp_matches(v_old, 'public\.season_rank_rows_tx\(', 'g'));
  if v_n <> 1 then raise exception 'get_season_leaderboard_tx 預期 1 處呼叫，實際 % 處，整份回滾', v_n; end if;
  v_new := replace(v_old, 'public.season_rank_rows_tx(', 'public.season_rank_rows_display_tx(');
  execute v_new;
end $$;

-- ════════════════════════════════════════════════════════════════════
-- 驗證（單一 SELECT，不 raise —— 硬規則 1.8）
-- ════════════════════════════════════════════════════════════════════
select * from (
  -- 算式：線上 5 人全是測試帳號、本季都打過 ⇒ 顯示 5、結算 0
  select 1 as n, '① 顯示用：上線前排得出人（正對照，預期 5）' as 項目,
         case when (select count(*) from public.season_rank_rows_display_tx(
                      (select id from orgs limit 1), (select starts_at from rank_seasons where code = '2026H2'), null)) = 5
              then '✅' else '🔴' end as 結果,
         (select string_agg(m.display_name || ' ' || r.rating || '（第 ' || r.rank_no || '）', '、' order by r.rank_no)
            from public.season_rank_rows_display_tx((select id from orgs limit 1),
                   (select starts_at from rank_seasons where code = '2026H2'), null) r
            join members m on m.id = r.member_id) as 細節
  union all
  select 2, '② 結算用：仍然排除測試帳號（預期 0）',
         case when (select count(*) from public.season_rank_rows_tx(
                      (select id from orgs limit 1), (select starts_at from rank_seasons where code = '2026H2'), null)) = 0
              then '✅' else '🔴' end, null
  union all
  select 3, '③ 全國排名改叫顯示用（2 處）、舊的 0 處',
         case when (select count(*) from regexp_matches(pg_get_functiondef('public.get_my_stats_tx'::regproc), 'public\.season_rank_rows_display_tx\(', 'g')) = 2
               and (select count(*) from regexp_matches(pg_get_functiondef('public.get_my_stats_tx'::regproc), 'public\.season_rank_rows_tx\(', 'g')) = 0
              then '✅' else '🔴' end, null
  union all
  select 4, '④ 排行榜改叫顯示用（1 處）、舊的 0 處',
         case when (select count(*) from regexp_matches(pg_get_functiondef('public.get_season_leaderboard_tx'::regproc), 'public\.season_rank_rows_display_tx\(', 'g')) = 1
               and (select count(*) from regexp_matches(pg_get_functiondef('public.get_season_leaderboard_tx'::regproc), 'public\.season_rank_rows_tx\(', 'g')) = 0
              then '✅' else '🔴' end, null
  union all
  select 5, '⑤ 結算（reset_season_ratings_tx）還是叫結算用那支',
         case when pg_get_functiondef('public.reset_season_ratings_tx'::regproc) ~ 'public\.season_rank_rows_tx\('
               and pg_get_functiondef('public.reset_season_ratings_tx'::regproc) !~ 'season_rank_rows_display_tx'
              then '✅' else '🔴' end, null
  union all
  select 6, '⑥ 名人堂仍然擋測試帳號（沒被誤改）',
         case when pg_get_functiondef('public.get_season_leaderboard_tx'::regproc) ~ 'm\.is_test = false'
              then '✅' else '🔴' end, null
  union all
  select 7, '⑦ 兩支新函式前端叫不動（明確 ＋ PUBLIC）',
         case when not exists (select 1 from pg_proc p, aclexplode(p.proacl) a
                                where p.proname in ('_season_rank_rows_core', 'season_rank_rows_display_tx')
                                  and p.pronamespace = 'public'::regnamespace
                                  and a.privilege_type = 'EXECUTE'
                                  and a.grantee in (0, 'anon'::regrole::oid, 'authenticated'::regrole::oid))
              then '✅' else '🔴' end, null
  union all
  select 8, '⑧ 前端那兩支還叫得動',
         case when has_function_privilege('authenticated', 'public.get_my_stats_tx'::regproc, 'execute')
               and has_function_privilege('authenticated', 'public.get_season_leaderboard_tx'::regproc, 'execute')
              then '✅' else '🔴' end, null
  union all
  select 9, '⑨ 每支都只有一個版本（沒有長出多載）',
         case when (select count(*) from pg_proc where pronamespace = 'public'::regnamespace
                     and proname in ('season_rank_rows_tx', 'season_rank_rows_display_tx', '_season_rank_rows_core',
                                     'get_my_stats_tx', 'get_season_leaderboard_tx')) = 5
              then '✅' else '🔴' end, null
) v order by n;
