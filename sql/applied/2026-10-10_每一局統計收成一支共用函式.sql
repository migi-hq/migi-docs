-- ============================================================
-- 「每一局」的統計收成一支共用函式：_member_hand_counts
-- （2026-10-10。起點：CLAUDE.md 待辦 33 記著「目前是兩份逐字相同的抄寫」）
--
-- 在此之前，「一局怎麼算」寫在兩個地方，一字不差：
--   _member_stats_core         成績頁 KPI（本季＋生涯的局數、胡、自摸、放槍、單局最大台、最長連莊）
--   get_season_leaderboard_tx  賽季排行榜的數據排行（本季每人的局數、胡、自摸、放槍）
-- 改其中一份時另一份不會跟著變，而且不報錯 —— 成績頁說胡牌率 25%、排行榜說 27%，兩邊都不算 bug。
--
-- 現在：
--   _member_hand_counts(org, 從何時起, 哪些人)  ← 全系統唯一一份
--     · 從何時起 null ＝ 生涯（不限時間）；哪些人 null ＝ 這個機構所有人
--     · 回每人一列：局數、胡（含自摸）、自摸、放槍、單局最大台（含莊台）、最長連莊
--     · 一局都沒有的人不會出現（呼叫端照舊 coalesce 成 0）
--   _member_stats_core         本季、生涯各叫一次
--   get_season_leaderboard_tx  傳段位排行那一批人的名單進去
--
-- 兩支既有函式簽名不變（CREATE OR REPLACE，不丟 GRANT，前端不用改）。
-- 新函式不給前端叫：只有 service_role（硬規則 2.7）。兩支呼叫它的都是 DEFINER，進去之後身分是 owner，鏈路不斷。
--
-- 驗證：改之前先把兩支舊函式「每位會員／每個機構的整份回傳」存進暫存表當對照組，
--       替換之後逐人比對整份 jsonb，一個字都不能差（不只比那幾個數字）。
--   ⚠ 驗證段不 raise（硬規則 1.8）—— 這份要留下東西。
-- ============================================================


-- ── ⓪ 對照組：改之前的兩支函式，在同一個交易裡跑一次存起來 ──
drop table if exists pg_temp._hc_before_stats;
drop table if exists pg_temp._hc_before_board;

create temp table _hc_before_stats as
  select m.org_id, m.id as member_id, public._member_stats_core(m.org_id, m.id) as j
    from members m;

create temp table _hc_before_board as
  select o.id as org_id, public.get_season_leaderboard_tx(o.id, 100) as j
    from orgs o;


-- ── ① 唯一一份「一局怎麼算」──
create or replace function public._member_hand_counts(
  p_org_id     uuid,
  p_from       timestamptz default null,
  p_member_ids uuid[]      default null)
 returns table(member_id uuid, hands int, hu int, tsumo int, deal_in int, max_tai int, max_renzhuang int)
 language sql
 stable security definer
 set search_path to 'public'
as $function$
  /* 每一局（電子計分）的唯一定義。成績頁與賽季排行榜都叫這一支，不要再在別處寫一份。
     場次：已收桌、有名次、有座位（座位號在一場裡代表同一個人）。
     局：只算已入帳、真的打完一把的 —— 胡、自摸、流局、包牌；咔啦碰與分紅是中途另外收分，不是一局。
     p_from     null ＝ 不限時間（生涯）；給值 ＝ 結算時間在那之後（本季）
     p_member_ids null ＝ 這個機構所有人 */
  with mine as (
    select sp.member_id, sp.session_id, sp.seat
      from session_players sp
      join table_sessions s on s.id = sp.session_id
     where sp.org_id    = p_org_id
       and s.org_id     = p_org_id
       and s.deleted_at is null
       and s.status     = 'completed'
       and sp.finish_rank is not null
       and sp.settled_at  is not null
       and sp.seat is not null
       and (p_from is null or sp.settled_at >= p_from)
       and (p_member_ids is null or sp.member_id = any(p_member_ids))
  ), hh as (
    select m.member_id, h.result, h.renzhuang,
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
  select hh.member_id,
         count(*)::int,
         (count(*) filter (where won and result in ('tsumo', 'ron')))::int,
         (count(*) filter (where won and result = 'tsumo'))::int,
         (count(*) filter (where dealt_in and result = 'ron'))::int,
         (max(tai_total) filter (where won and result in ('tsumo', 'ron')))::int,
         (max(renzhuang) filter (where is_dealer))::int
    from hh
   group by hh.member_id
$function$;

-- 不給前端叫（硬規則 2.6b／2.7：PUBLIC 與明確授權兩個方向都收）
revoke execute on function public._member_hand_counts(uuid, timestamptz, uuid[]) from public;
revoke execute on function public._member_hand_counts(uuid, timestamptz, uuid[]) from anon, authenticated;
grant  execute on function public._member_hand_counts(uuid, timestamptz, uuid[]) to service_role;


-- ── ② 成績頁：本季、生涯各叫一次（其餘段落與線上版逐字相同）──
create or replace function public._member_stats_core(p_org_id uuid, p_member_id uuid)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'public'
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
     2026-10-10 起「一局怎麼算」只寫在 _member_hand_counts，這裡本季、生涯各叫一次。
     ⚠ 一局都沒有的人那支回 0 列 ⇒ 這裡的變數是 null，下面 return 照舊 coalesce 成 0。 */
  select c.hands, c.hu, c.tsumo, c.deal_in, c.max_tai, c.max_renzhuang
    into v_s_hand, v_s_hu, v_s_tsumo, v_s_dealin, v_s_max_tai, v_s_max_ren
    from public._member_hand_counts(p_org_id, v_win, array[p_member_id]) c;

  select c.hands, c.hu, c.tsumo, c.deal_in
    into v_a_hand, v_a_hu, v_a_tsumo, v_a_dealin
    from public._member_hand_counts(p_org_id, null, array[p_member_id]) c;

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
       and sp.hidden_from_history_at is null   -- 從本人紀錄藏起來的場次不算（2026-10-09）
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
end $function$;


-- ── ③ 賽季排行榜：數據排行改傳名單給共用函式（其餘段落與線上版逐字相同）──
create or replace function public.get_season_leaderboard_tx(p_org_id uuid, p_limit integer default 10)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'public'
as $function$
declare
  v_season jsonb;
  v_rows   jsonb;
  v_champ  jsonb;
  v_hands  jsonb;
  v_n      int;
  v_from   timestamptz;
  /* 規定局數（同職棒規定打席）。要調整改這一個數字；前端讀回傳的 min_hands，不自己寫一份 */
  v_min_hands constant int := 30;
begin
  /* 上限保護：前端送 100000 的話這支會把整個榜撈出來。least 而不是 raise。 */
  v_n := greatest(1, least(coalesce(p_limit, 10), 100));

  v_season := public.current_season_tx(p_org_id);

  /* 沒有進行中的賽季時不要回 ok:false —— 那是正常狀態（兩季之間的空檔）。 */
  if v_season is null then
    return jsonb_build_object('ok', true, 'season', null,
                              'rows', '[]'::jsonb, 'champions', '[]'::jsonb,
                              'hand_leaders', jsonb_build_object('min_hands', v_min_hands,
                                'hu', '[]'::jsonb, 'tsumo', '[]'::jsonb, 'deal_in', '[]'::jsonb));
  end if;
  v_from := (v_season ->> 'starts_at')::timestamptz;

  /* 本季排行。名次借 season_rank_rows_display_tx（與成績頁的「全國排名」同一份定義）。
     🔴 2026-09-30 加回 id：點進去的個人卡要靠它判斷「你們是不是牌咖」。
     ★ 2026-10-10 加頭像四欄（在此之前排行榜一律畫預設小熊）。 */
  select coalesce(jsonb_agg(x order by x.rank_no), '[]'::jsonb) into v_rows
    from (
      select r.rank_no, r.rating, r.games,
             r.member_id           as id,
             m.display_name        as name,
             public.rank_from_rating(r.rating) as rank_label,
             m.avatar_source, m.avatar_url, m.avatar_photo_path, m.avatar_bear
        from public.season_rank_rows_display_tx(p_org_id, v_from, null) r
        join members m on m.id = r.member_id
       order by r.rank_no
       limit v_n
    ) x;

  /* ★ 每一局的數據排行（2026-10-10）：胡牌率／自摸率／放槍率，各前 5 名。
     名單＝上面那一份段位排行的人（同一批，不另外判斷誰算數）；
     局數、胡、自摸、放槍一律問 _member_hand_counts（跟成績頁同一支，2026-10-10 收成一份）。
     ⚠ 名單是空的時候傳空陣列不是 null —— null 在那支的意思是「所有人」。 */
  with pop as (
    select r.member_id, r.rating
      from public.season_rank_rows_display_tx(p_org_id, v_from, null) r
  ), agg as (
    select c.member_id, c.hands, c.hu, c.tsumo, c.deal_in
      from public._member_hand_counts(
             p_org_id, v_from,
             (select coalesce(array_agg(pop.member_id), '{}'::uuid[]) from pop)) c
  ), q as (
    /* 規定局數以上才上榜 */
    select a.*, mb.display_name as name, mb.created_at,
           mb.avatar_source, mb.avatar_url, mb.avatar_photo_path, mb.avatar_bear,
           public.rank_from_rating(pop.rating) as rank_label
      from agg a
      join pop on pop.member_id = a.member_id
      join members mb on mb.id = a.member_id
     where a.hands >= v_min_hands
  ), board as (
    select k, x.*
      from (values ('hu'), ('tsumo'), ('deal_in')) as kk(k)
      cross join lateral (
        select q.member_id, q.name, q.rank_label, q.hands, q.created_at,
               q.avatar_source, q.avatar_url, q.avatar_photo_path, q.avatar_bear,
               case kk.k when 'hu' then q.hu when 'tsumo' then q.tsumo else q.deal_in end as n,
               round((case kk.k when 'hu' then q.hu when 'tsumo' then q.tsumo else q.deal_in end)::numeric
                     / q.hands, 4) as rate
          from q
      ) x
  ), ranked as (
    select b.*,
           rank() over (partition by b.k
                        order by case when b.k = 'deal_in' then b.rate else -b.rate end) as rank_no,
           row_number() over (partition by b.k
                              order by case when b.k = 'deal_in' then b.rate else -b.rate end,
                                       b.hands desc, b.created_at) as rn
      from board b
  )
  select jsonb_build_object(
           'min_hands', v_min_hands,
           'hu',      coalesce(jsonb_agg(j order by rn) filter (where k = 'hu'),      '[]'::jsonb),
           'tsumo',   coalesce(jsonb_agg(j order by rn) filter (where k = 'tsumo'),   '[]'::jsonb),
           'deal_in', coalesce(jsonb_agg(j order by rn) filter (where k = 'deal_in'), '[]'::jsonb))
    into v_hands
    from (
      select k, rn, jsonb_build_object('rank_no', rank_no, 'id', member_id, 'name', name,
                                       'rank_label', rank_label, 'hands', hands, 'n', n, 'rate', rate,
                                       'avatar_source', avatar_source, 'avatar_url', avatar_url,
                                       'avatar_photo_path', avatar_photo_path, 'avatar_bear', avatar_bear) as j
        from ranked
       where rn <= 5
    ) t;

  /* 名人堂：歷代雀神熊。再擋一次測試帳號與隱藏中的會員（冠軍紀錄保留，恢復之後回來）。 */
  select coalesce(jsonb_agg(x order by x.awarded_at desc), '[]'::jsonb) into v_champ
    from (
      select c.season, c.rating, c.awarded_at,
             c.member_id           as id,
             s.label               as season_label,
             m.display_name        as name,
             public.rank_from_rating(c.rating) as rank_label,
             m.avatar_source, m.avatar_url, m.avatar_photo_path, m.avatar_bear
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
    'ok', true, 'season', v_season, 'rows', v_rows, 'champions', v_champ,
    'hand_leaders', coalesce(v_hands, jsonb_build_object('min_hands', v_min_hands,
                      'hu', '[]'::jsonb, 'tsumo', '[]'::jsonb, 'deal_in', '[]'::jsonb)));
end;
$function$;


-- ── 驗證（單一 SELECT，不 raise）──
-- ① 成績頁：每一位會員，改前改後 _member_stats_core 的整份回傳逐字相同
--      正對照：其中本季有局數的人數（2026-10-10 查過是 8 人，0 人的話這格比不出東西）
-- ② 排行榜：每個機構，改前改後 get_season_leaderboard_tx(…, 100) 的整份回傳逐字相同
--      正對照：數據排行三張表的列數（2026-10-10 查過 4 位真客人各 71 局，> 規定 30 局）
-- ③ 反對照：比對器分得出不同的人 —— 拿 A 的舊回傳去比 B 的新回傳，應該 0 對相同
-- ④ 共用函式的兩個篩選真的有作用（真資料在本季開始前沒有任何一局，本季／生涯分不開，所以這格補）：
--      不限時間不限人 = 8 列；從現在起 = 0 列；空名單 = 0 列；只給一個人 = 1 列
-- ⑤ 全庫只剩一支寫了「局的結果只算那四種」的條件，而且是 _member_hand_counts
-- ⑥ 兩支都改叫共用函式：成績頁 2 次（本季、生涯）、排行榜 1 次
-- ⑦ 授權：共用函式只有 service_role（anon／authenticated／PUBLIC 都沒有）；兩支既有函式的授權沒變
with st as (
  select b.member_id, b.j as before_j, public._member_stats_core(b.org_id, b.member_id) as after_j
    from _hc_before_stats b
), bd as (
  select b.org_id, b.j as before_j, public.get_season_leaderboard_tx(b.org_id, 100) as after_j
    from _hc_before_board b
), org1 as (
  select s.org_id from rank_seasons s where now() >= s.starts_at and now() < s.ends_at limit 1
), fn as (
  select p.oid, p.proname, pg_get_functiondef(p.oid) as def
    from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
), hc as (
  select p.oid, p.proacl from pg_proc p
   where p.oid = 'public._member_hand_counts(uuid, timestamptz, uuid[])'::regprocedure
)
select
  (select case when count(*) = 0 then '⚪ 沒有會員，比不了'
               when count(*) filter (where before_j is distinct from after_j) = 0
               then '✅ ' || count(*) || ' 位會員整份回傳相同（本季有局數的 '
                    || count(*) filter (where (after_j -> 'season' ->> 'hand_count')::int > 0) || ' 位）'
               else '🔴 ' || count(*) filter (where before_j is distinct from after_j) || ' 位對不上' end
     from st)                                                                                        as "①",
  (select case when count(*) = 0 then '⚪ 沒有機構，比不了'
               when count(*) filter (where before_j is distinct from after_j) = 0
               then '✅ ' || count(*) || ' 個機構整份回傳相同（數據排行 胡 '
                    || coalesce(max(jsonb_array_length(after_j -> 'hand_leaders' -> 'hu')), 0) || ' 列・自摸 '
                    || coalesce(max(jsonb_array_length(after_j -> 'hand_leaders' -> 'tsumo')), 0) || ' 列・放槍 '
                    || coalesce(max(jsonb_array_length(after_j -> 'hand_leaders' -> 'deal_in')), 0) || ' 列）'
               else '🔴 ' || count(*) filter (where before_j is distinct from after_j) || ' 個機構對不上' end
     from bd)                                                                                        as "②",
  (select case when count(*) = 0 then '✅ 不同人的回傳 0 對相同（比對器分得出差別）'
               else '🔴 ' || count(*) || ' 對不同人的回傳竟然相同，比對器可能是瞎的' end
     from st a join st b on a.member_id <> b.member_id
    where (a.after_j -> 'season' ->> 'hand_count')::int > 0
      and a.before_j = b.after_j)                                                                     as "③",
  (select coalesce(
            '不限 ' || (select count(*) from public._member_hand_counts(o.org_id, null, null))
            || ' 列・從現在起 ' || (select count(*) from public._member_hand_counts(o.org_id, now(), null))
            || ' 列・空名單 ' || (select count(*) from public._member_hand_counts(o.org_id, null, '{}'::uuid[]))
            || ' 列・一個人 ' || (select count(*) from public._member_hand_counts(o.org_id, null,
                                    array[(select h.member_id from public._member_hand_counts(o.org_id, null, null) h limit 1)]))
            || ' 列（期望 8／0／0／1）',
            '⚪ 沒有進行中的賽季，這格測不了')
     from org1 o)                                                                                    as "④",
  (select coalesce(string_agg(proname, '、' order by proname), '（一支都沒有）')
          || case when count(*) = 1 and bool_and(proname = '_member_hand_counts') then ' ✅ 只剩一份'
                  else ' 🔴 期望只有 _member_hand_counts' end
     from fn
    where def ~ 'result\s+in\s*\(\s*''tsumo''\s*,\s*''ron''\s*,\s*''draw''\s*,\s*''bao''\s*\)')       as "⑤",
  (select string_agg(proname || ' ' || n || ' 次', '・' order by proname)
          || case when bool_and(case proname when '_member_stats_core' then n = 2 else n = 1 end) and count(*) = 2
                  then ' ✅' else ' 🔴 期望 成績頁 2・排行榜 1' end
     from (select proname, (select count(*) from regexp_matches(def, '_member_hand_counts\(', 'g')) as n
             from fn where proname in ('_member_stats_core', 'get_season_leaderboard_tx')) t)        as "⑥",
  (select case when not exists (select 1 from hc, aclexplode(hc.proacl) a
                                 where a.privilege_type = 'EXECUTE'
                                   and a.grantee in (0, 'anon'::regrole::oid, 'authenticated'::regrole::oid))
                and exists (select 1 from hc, aclexplode(hc.proacl) a
                             where a.privilege_type = 'EXECUTE' and a.grantee = 'service_role'::regrole::oid)
                and (select proacl is not null from hc)
               then '✅ 共用函式只有 service_role' else '🔴 共用函式授權不對：' || coalesce((select proacl::text from hc), 'null（＝PUBLIC 有）') end
          || '・成績頁 ' || coalesce((select p.proacl::text from pg_proc p
                                       where p.oid = 'public._member_stats_core(uuid, uuid)'::regprocedure), 'null')
          || '・排行榜 ' || coalesce((select p.proacl::text from pg_proc p
                                       where p.oid = 'public.get_season_leaderboard_tx(uuid, integer)'::regprocedure), 'null')
  )                                                                                                  as "⑦";
