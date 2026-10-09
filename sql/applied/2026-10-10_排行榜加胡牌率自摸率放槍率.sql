-- ============================================================
-- 全國排行頁加三張「每一局」數據排行：胡牌率／自摸率／放槍率，各取前 5 名
-- （2026-10-10 使用者：「參考職棒的數據，全國排行頁面的下面也要有胡牌率排行、自摸率排行、放槍率排行，都取前 5 名」）
--
-- 做法：get_season_leaderboard_tx 多回一包 hand_leaders，簽名不變（CREATE OR REPLACE，不丟 GRANT，舊版前端照常）。
--
-- 定義（跟成績頁 _member_stats_core「每一局」那一段逐字同一套，驗證段 ② 逐人比對）：
--   局     ＝ 已收桌、有名次、有座位的場次裡，已入帳的 胡／自摸／流局／包牌（咔啦碰、分紅不是一局）
--   胡牌率 ＝ 胡（含自摸）÷ 局　　自摸率 ＝ 自摸 ÷ 局　　放槍率 ＝ 放槍 ÷ 局
--   本季   ＝ current_season_tx 的開始時間（同上面的段位排行）
-- 名單母體：跟上面的段位排行**同一批人**（season_rank_rows_display_tx：上線前連測試帳號一起排，
--   固定的測試01～04 不上榜，上線那一刻自動只剩真客人）—— 不另外寫一份「誰算數」。
-- 規定局數：本季打滿 30 局才上榜（同職棒「規定打席」，不然打 3 局胡 2 局的人會排第一）。
-- 排序：胡牌率、自摸率高到低；**放槍率低到高**（同防禦率 —— 不公開排「最常放槍的人」）。
--   同率時局數多的在前；名次用 rank()，同率同名次。
-- ============================================================

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
       2026-09-04 拿掉它的理由（拿 id 就能看別人錢包）09-20 已經不成立 ——
       所有會員功能只認 JWT，前端送誰的 id 都沒用。 */
  select coalesce(jsonb_agg(x order by x.rank_no), '[]'::jsonb) into v_rows
    from (
      select r.rank_no, r.rating, r.games,
             r.member_id           as id,
             m.display_name        as name,
             public.rank_from_rating(r.rating) as rank_label
        from public.season_rank_rows_display_tx(p_org_id, v_from, null) r
        join members m on m.id = r.member_id
       order by r.rank_no
       limit v_n
    ) x;

  /* ★ 每一局的數據排行（2026-10-10）：胡牌率／自摸率／放槍率，各前 5 名。
     名單＝上面那一份段位排行的人（同一批，不另外判斷誰算數）；
     局數、胡、自摸、放槍的算法跟 _member_stats_core「每一局」那一段同一套。 */
  with pop as (
    select r.member_id, r.rating
      from public.season_rank_rows_display_tx(p_org_id, v_from, null) r
  ), mine as (
    select sp.member_id, sp.session_id, sp.seat
      from session_players sp
      join table_sessions s on s.id = sp.session_id
      join pop on pop.member_id = sp.member_id
     where sp.org_id    = p_org_id
       and s.org_id     = p_org_id
       and s.deleted_at is null
       and s.status     = 'completed'
       and sp.finish_rank is not null
       and sp.settled_at  is not null
       and sp.seat is not null
       and sp.settled_at >= v_from
  ), agg as (
    select m.member_id,
           count(*)                                                                   as hands,
           count(*) filter (where h.winner_seat = m.seat and h.result in ('tsumo', 'ron')) as hu,
           count(*) filter (where h.winner_seat = m.seat and h.result = 'tsumo')         as tsumo,
           count(*) filter (where h.deal_in_seat = m.seat and h.result = 'ron')          as deal_in
      from mine m
      join hands h on h.session_id = m.session_id
     where h.status = 'confirmed'
       and h.result in ('tsumo', 'ron', 'draw', 'bao')
     group by m.member_id
  ), q as (
    /* 規定局數以上才上榜 */
    select a.*, mb.display_name as name, mb.created_at,
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
                                       'rank_label', rank_label, 'hands', hands, 'n', n, 'rate', rate) as j
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
             public.rank_from_rating(c.rating) as rank_label
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

-- ── 驗證（單一 SELECT）──
-- ① 回傳有三張表、各最多 5 列
-- ② 逐人比對：排行榜上每一列的局數／次數，跟成績頁 _member_stats_core 算的本季數字一模一樣
-- ③ 胡牌率由高到低、放槍率由低到高
-- ④ 正對照：規定局數以下的人真的沒上榜（印出母體裡有幾人不到 30 局）
with lb as (
  select public.get_season_leaderboard_tx(o.id, 10) as j, o.id as org
    from orgs o
   where exists (select 1 from rank_seasons s where s.org_id = o.id and now() >= s.starts_at and now() < s.ends_at)
   limit 1
), rows_ as (
  select k, (e ->> 'id')::uuid as id, (e ->> 'hands')::int as hands, (e ->> 'n')::int as n,
         (e ->> 'rate')::numeric as rate, ord
    from lb, unnest(array['hu', 'tsumo', 'deal_in']) k,
         jsonb_array_elements(lb.j -> 'hand_leaders' -> k) with ordinality as a(e, ord)
), cmp as (
  select r.*, public._member_stats_core(lb.org, r.id) -> 'season' as s
    from rows_ r, lb
)
select
  (select '① 胡 ' || jsonb_array_length(j -> 'hand_leaders' -> 'hu') || ' 列 · 自摸 '
          || jsonb_array_length(j -> 'hand_leaders' -> 'tsumo') || ' 列 · 放槍 '
          || jsonb_array_length(j -> 'hand_leaders' -> 'deal_in') || ' 列 · 規定局數 '
          || (j -> 'hand_leaders' ->> 'min_hands') from lb)                                      as "①",
  (select case when count(*) = 0 then '⚪ 榜上沒人，比不了'
               when count(*) filter (where hands <> (s ->> 'hand_count')::int
                                        or n <> (s ->> case k when 'hu' then 'hu_count' when 'tsumo' then 'tsumo_count' else 'deal_in_count' end)::int) = 0
               then '✅ ' || count(*) || ' 列跟成績頁逐人相同'
               else '🔴 有 ' || count(*) filter (where hands <> (s ->> 'hand_count')::int) || ' 列對不上' end
     from cmp)                                                                                   as "②",
  (select case when bool_and(ok) is not false then '✅ 胡牌率高→低、自摸率高→低、放槍率低→高' else '🔴 排序不對' end
     from (select k, rate, ord,
                  case when k = 'deal_in' then rate >= lag(rate) over (partition by k order by ord)
                       else rate <= lag(rate) over (partition by k order by ord) end as ok
             from rows_) t)                                                                      as "③",
  (select '母體 ' || count(*) || ' 人，未滿 30 局 ' || count(*) filter (where coalesce(h, 0) < 30)
          || ' 人；上榜的人局數最少 ' || coalesce((select min(hands)::text from rows_), '—')
     from (select r.member_id, (public._member_stats_core(lb.org, r.member_id) -> 'season' ->> 'hand_count')::int as h
             from lb, public.season_rank_rows_display_tx(lb.org, (lb.j -> 'season' ->> 'starts_at')::timestamptz, null) r) t) as "④";
