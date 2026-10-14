-- ============================================================
-- 2026-10-14 歷史累積數據可以依日期篩選（本日／本週／本月／選日期）
-- ------------------------------------------------------------
-- 使用者：「成績頁的歷史紀錄 新增可以篩選日期 本日 本周 本月 跟日期篩選」
--         ⇒ 指的是成績頁「查看歷史累積數據 ›」那一頁（同日確認過）
--
-- 做法：**同一套算法只有一份** —— 不另寫一支「區間版」的統計。
-- ① _member_hand_counts：加 p_to（結束時間，不含）。不給 ＝ 跟現在一樣
-- ② _member_stats_core：加 p_from／p_to。**兩個都不給 ＝ 跟現在一模一樣**（成績頁、他人個人卡照舊）；
--    給了 ⇒ 每一段的場次都只算「結算時間在 [p_from, p_to)」的，'all' 那一份就是那段期間的數字。
--    · 最高全國排名（best_rank）是賽季名次，跟日期無關 ⇒ 有區間時回 null（前端那一格改成別的）
--    · 麻將足跡（時數、門市、交手過的人、最高段位）用 coalesce(結算時間, 收桌時間) 判斷在不在區間
-- ③ get_my_stats_range_tx(p_org_id, p_from, p_to)：前端歷史頁叫這支；身分一律 current_member_id()
--    回 { ok, min_games, from, to, all }，'all' 的形狀跟 get_my_stats_tx 的 'all' 完全相同
--
-- ⚠ ①② 改簽名 ⇒ DROP 重建。授權本來就只有 postgres／service_role（10-14 查 proacl），
--   2026-09-29 起新建的預設也是全關 ⇒ 重建後一樣；下面仍明寫一次。
-- ⚠ 呼叫它們的四支（get_my_stats_tx、get_member_card_tx、get_season_leaderboard_tx、_member_stats_core 自己）
--   都是位置參數、沒有傳新參數 ⇒ 新參數有預設值，照舊解析得到，不用改。
-- 函式本體照線上版（10-14 撈的 pg_get_functiondef）逐段搬，只加區間條件，其餘一字不改。
-- ============================================================

drop function if exists public._member_hand_counts(uuid, timestamptz, uuid[]);
drop function if exists public._member_stats_core(uuid, uuid);

CREATE FUNCTION public._member_hand_counts(p_org_id uuid, p_from timestamp with time zone DEFAULT NULL::timestamp with time zone, p_member_ids uuid[] DEFAULT NULL::uuid[], p_to timestamp with time zone DEFAULT NULL::timestamp with time zone)
 RETURNS TABLE(member_id uuid, hands integer, hu integer, tsumo integer, deal_in integer, max_tai integer, max_renzhuang integer)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  /* 每一局（電子計分）的唯一定義。成績頁與賽季排行榜都叫這一支，不要再在別處寫一份。
     場次：已收桌、有名次、有座位（座位號在一場裡代表同一個人）。
     局：只算已入帳、真的打完一把的 —— 胡、自摸、流局、包牌；咔啦碰與分紅是中途另外收分，不是一局。
     p_from     null ＝ 不限時間（生涯）；給值 ＝ 結算時間在那之後（本季）
     p_to       null ＝ 不限；給值 ＝ 結算時間在那之前（不含）—— 歷史累積數據依日期篩選用（2026-10-14）
     p_member_ids null ＝ 這個機構所有人 */
  with mine as (
    select sp.member_id, sp.session_id, sp.seat
      from session_players sp
      join table_sessions s on s.id = sp.session_id
     where sp.org_id    = p_org_id
       and s.org_id     = p_org_id
       and s.deleted_at is null
       and (s.status = 'completed' or sp.finish_rank is not null)
       and sp.finish_rank is not null
       and sp.settled_at  is not null
       and sp.seat is not null
       and (p_from is null or sp.settled_at >= p_from)
       and (p_to   is null or sp.settled_at <  p_to)
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

CREATE FUNCTION public._member_stats_core(p_org_id uuid, p_member_id uuid, p_from timestamp with time zone DEFAULT NULL::timestamp with time zone, p_to timestamp with time zone DEFAULT NULL::timestamp with time zone)
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
  /* ★ 2026-10-14 依日期篩選：p_from／p_to 都是 null ＝ 不限（跟之前一模一樣） */
  v_ranged boolean := (p_from is not null or p_to is not null);
begin

  /* 🔴 身分一律從 JWT 取，不採信呼叫端（2026-09-05，待辦 14）。
     在此之前前端送什麼 member_id 就查什麼 ⇒ 知道任何一個會員 uuid
     就能看他的錢包與消費明細。
     ⚠ 查不到就**拒絕**不是回 null —— 回 null 等於洞還開著。
     ⚠ 呼叫端照樣送 p_member_id，函式忽略它（簽名不變，前端不用改）。 */
  /* 身分由呼叫端決定：get_my_stats_tx 傳登入的本人，get_member_card_tx 傳要看的那個人，
     get_my_stats_range_tx 傳登入的本人 ＋ 區間（2026-10-14）。
     ⚠ 區間只看 'all' 那一份有意義；'season' 也會一起被篩，但有區間的呼叫端不讀它。 */
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
       and (s.status = 'completed' or sp.finish_rank is not null)
       and sp.finish_rank is not null
       and sp.settled_at  is not null
       and (p_from is null or sp.settled_at >= p_from)
       and (p_to   is null or sp.settled_at <  p_to)
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
       and (s.status = 'completed' or sp.finish_rank is not null)
       and sp.finish_rank is not null
       and sp.settled_at  is not null
       and sp.final_score is not null
       and (p_from is null or sp.settled_at >= p_from)
       and (p_to   is null or sp.settled_at <  p_to)
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
       and (s.status = 'completed' or sp.finish_rank is not null)
       and sp.finish_rank is not null
       and sp.settled_at  is not null
       and sp.final_score is not null
       and (v_win is null or sp.settled_at >= v_win)
       and (p_from is null or sp.settled_at >= p_from)
       and (p_to   is null or sp.settled_at <  p_to)
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
       and (s.status = 'completed' or sp.finish_rank is not null)
       and sp.finish_rank is not null
       and sp.settled_at  is not null
       and (p_from is null or sp.settled_at >= p_from)
       and (p_to   is null or sp.settled_at <  p_to)
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
     ⚠ 一局都沒有的人那支回 0 列 ⇒ 這裡的變數是 null，下面 return 照舊 coalesce 成 0。
     ⚠ 有區間時（2026-10-14）：本季那次取「賽季起點」與「區間起點」較晚的那個；生涯那次就是區間。 */
  select c.hands, c.hu, c.tsumo, c.deal_in, c.max_tai, c.max_renzhuang
    into v_s_hand, v_s_hu, v_s_tsumo, v_s_dealin, v_s_max_tai, v_s_max_ren
    from public._member_hand_counts(p_org_id, greatest(v_win, p_from), array[p_member_id], p_to) c;

  select c.hands, c.hu, c.tsumo, c.deal_in
    into v_a_hand, v_a_hu, v_a_tsumo, v_a_dealin
    from public._member_hand_counts(p_org_id, p_from, array[p_member_id], p_to) c;

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
     ⚠ `least()` 遇到 null 會回 null ⇒ 要用 `min()` 於 union 而不是 `least`。
     ⚠ 有區間時不算（2026-10-14）：那是賽季名次，跟「這段期間」對不起來 ⇒ null */
  if not v_ranged then
    select min(x) into v_best from (
      select rank_no from season_standings
       where org_id = p_org_id and member_id = p_member_id
      union all
      select v_rank
    ) t(x);
  end if;

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
     and (s.status = 'completed' or sp.finish_rank is not null)
     and sp.finish_rank is not null
     and sp.settled_at  is not null
     and (v_win is null or sp.settled_at >= v_win)
     and (p_from is null or sp.settled_at >= p_from)
     and (p_to   is null or sp.settled_at <  p_to)
     and o.rating_after is not null;

  /* ── 麻將足跡（生涯，不分季）──────────────────────
     有區間時（2026-10-14）用 coalesce(結算時間, 收桌時間) 判斷在不在區間 */
  with mysess as (
    select s.id, s.store_id, s.activated_at, s.started_at, s.ended_at,
           sp.rating_after
      from session_players sp
      join table_sessions s on s.id = sp.session_id
     where sp.member_id = p_member_id
       and sp.org_id    = p_org_id
       and s.org_id     = p_org_id
       and s.deleted_at is null
       and (s.status = 'completed' or sp.finish_rank is not null)
       and sp.hidden_from_history_at is null   -- 從本人紀錄藏起來的場次不算（2026-10-09）
       and (p_from is null or coalesce(sp.settled_at, s.ended_at) >= p_from)
       and (p_to   is null or coalesce(sp.settled_at, s.ended_at) <  p_to)
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
      -- ★ 最高全國排名（含本季目前）。null = 從來沒上過榜（有區間時一律 null）
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

revoke execute on function public._member_hand_counts(uuid, timestamptz, uuid[], timestamptz) from public, anon, authenticated;
grant  execute on function public._member_hand_counts(uuid, timestamptz, uuid[], timestamptz) to service_role;
revoke execute on function public._member_stats_core(uuid, uuid, timestamptz, timestamptz) from public, anon, authenticated;
grant  execute on function public._member_stats_core(uuid, uuid, timestamptz, timestamptz) to service_role;

-- ③ 前端歷史頁叫這支
CREATE OR REPLACE FUNCTION public.get_my_stats_range_tx(p_org_id uuid, p_from timestamp with time zone, p_to timestamp with time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_me uuid := public.current_member_id();
  v jsonb;
begin
  /* 歷史累積數據依日期篩選（2026-10-14 使用者）。身分只認登入的本人（同 get_my_stats_tx）。
     區間是 [p_from, p_to)，由前端照台北的日曆日算好（本日／本週一起算／本月一號起／選日期含頭尾）。
     算法一律走 _member_stats_core，不另寫一份；回傳的 'all' 跟 get_my_stats_tx 的 'all' 同一個形狀。 */
  if v_me is null then
    raise exception '未登入或登入已過期，請重新開啟 App' using errcode = '28000';
  end if;
  if p_from is null or p_to is null or p_to <= p_from then
    return jsonb_build_object('ok', false, 'reason', 'bad_range', 'message', '日期區間不正確');
  end if;
  v := public._member_stats_core(p_org_id, v_me, p_from, p_to);
  return jsonb_build_object('ok', true, 'min_games', v -> 'min_games',
                            'from', p_from, 'to', p_to, 'all', v -> 'all');
end $function$;

revoke execute on function public.get_my_stats_range_tx(uuid, timestamptz, timestamptz) from public, anon;
grant  execute on function public.get_my_stats_range_tx(uuid, timestamptz, timestamptz) to authenticated;

-- ============================================================
-- 驗證（單一 SELECT；不 raise，硬規則 1.8）
-- 樣本現場挑：在兩天以上都有已結算場次的會員裡，場數最多的那位（硬規則 3.57：不寫死）
-- ============================================================
with smp as (
  select sp.org_id, sp.member_id
    from session_players sp join table_sessions s on s.id = sp.session_id
   where s.deleted_at is null and sp.finish_rank is not null and sp.settled_at is not null
   group by 1, 2
  having count(distinct (sp.settled_at at time zone 'Asia/Taipei')::date) >= 2
   order by count(*) desc limit 1
), d as (   -- 樣本「最早那一天」台北時間的 [00:00, 隔天 00:00)
  select smp.*, ((min(sp.settled_at) at time zone 'Asia/Taipei')::date)::timestamp at time zone 'Asia/Taipei' as f
    from smp join session_players sp on sp.member_id = smp.member_id and sp.org_id = smp.org_id
    join table_sessions s on s.id = sp.session_id
   where s.deleted_at is null and sp.finish_rank is not null and sp.settled_at is not null
   group by smp.org_id, smp.member_id
), x as (
  select d.*, d.f + interval '1 day' as t,
         public._member_stats_core(d.org_id, d.member_id) as full_old_call,                 -- 兩個參數的舊呼叫法
         public._member_stats_core(d.org_id, d.member_id, '-infinity', 'infinity') as full_rng,
         public._member_stats_core(d.org_id, d.member_id, d.f, d.f + interval '1 day') as one_day,
         (select count(*) from session_players sp join table_sessions s on s.id = sp.session_id
           where sp.member_id = d.member_id and sp.org_id = d.org_id and s.org_id = d.org_id and s.deleted_at is null
             and (s.status = 'completed' or sp.finish_rank is not null)
             and sp.finish_rank is not null and sp.settled_at >= d.f and sp.settled_at < d.f + interval '1 day') as want_day
    from d
)
select
  case when (select count(*) from pg_proc where pronamespace = 'public'::regnamespace and proname = '_member_stats_core') = 1
        and (select count(*) from pg_proc where pronamespace = 'public'::regnamespace and proname = '_member_hand_counts') = 1
       then '✅' else '🔴' end || ' ① 兩支各只剩一個版本（沒有多載）' as "①",
  coalesce((select case when (full_old_call -> 'all') - 'best_rank' = (full_rng -> 'all') - 'best_rank'
                        then '✅ ② 不給區間 ＝ 給「無限大」區間（除了最高全國排名，all 逐鍵相同）'
                        else '🔴 ② 不一致：' || ((full_old_call -> 'all') - 'best_rank')::text || ' vs ' || ((full_rng -> 'all') - 'best_rank')::text end from x),
           '⚪ ② 沒有樣本') as "②",
  coalesce((select case when (one_day #>> '{all,games}')::int = want_day and want_day > 0
                         and (one_day #>> '{all,games}')::int < (full_old_call #>> '{all,games}')::int
                        then '✅ ③ 只算最早那一天：' || want_day || ' 場（全部 ' || (full_old_call #>> '{all,games}') || ' 場）'
                        else '🔴 ③ 一天的場數 ' || coalesce(one_day #>> '{all,games}', 'null') || '，應為 ' || want_day end from x),
           '⚪ ③ 沒有樣本') as "③",
  coalesce((select case when (one_day -> 'all' -> 'best_rank') = 'null'::jsonb then '✅' else '🔴' end
                   || ' ④ 有區間時最高全國排名是 null' from x), '⚪ ④ 沒有樣本') as "④",
  case when not exists (
         select 1 from (select member_id, hands, hu, tsumo, deal_in, max_tai, max_renzhuang
                          from public._member_hand_counts((select id from orgs limit 1), null, null)) a
         full join (select member_id, hands, hu, tsumo, deal_in, max_tai, max_renzhuang
                      from public._member_hand_counts((select id from orgs limit 1), null, null, 'infinity')) b using (member_id)
         where a is distinct from b)
       then '✅' else '🔴' end || ' ⑤ 每一局統計：不給結束時間 ＝ 給無限大（全機構逐人相同）' as "⑤",
  case when has_function_privilege('authenticated', 'public.get_my_stats_range_tx(uuid,timestamptz,timestamptz)', 'execute')
        and not has_function_privilege('anon', 'public.get_my_stats_range_tx(uuid,timestamptz,timestamptz)', 'execute')
        and not has_function_privilege('authenticated', 'public._member_stats_core(uuid,uuid,timestamptz,timestamptz)', 'execute')
       then '✅' else '🔴' end || ' ⑥ 新函式只給登入的人；核心函式前端叫不到' as "⑥";
