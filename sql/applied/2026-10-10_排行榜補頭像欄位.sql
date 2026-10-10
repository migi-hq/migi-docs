-- ============================================================
-- 賽季排行榜補頭像欄位（2026-10-10 使用者：「全國排行榜 頭像沒更新」）
--
-- 原因：get_season_leaderboard_tx 從來沒回傳頭像（只有 id／name／段位），
--   前端只能每一列都畫預設小熊 —— 換了頭像、上傳照片，排行榜上都不會變。
-- 修法：段位排行（rows）、名人堂（champions）、數據排行（hand_leaders 三張）每一列都多回
--   avatar_source／avatar_url／avatar_photo_path／avatar_bear 四個欄位 ——
--   跟 list_buddies_tx、_game_row 等名單同一組，前端用同一個 <Avatar member={…}> 畫。
--   隱藏帳號的人 avatar_source 本來就是 'hidden'（硬規則待辦 46），前端會畫問號，不用另外判斷。
-- 簽名不變（CREATE OR REPLACE，不丟 GRANT）；其餘邏輯與 2026-10-10_排行榜加胡牌率自摸率放槍率.sql 逐字相同。
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

-- ── 驗證（單一 SELECT）──
-- ① 段位排行每一列的頭像欄位跟 members 表上的值逐列相同（正對照：印出有幾列是照片／LINE／小熊）
-- ② 數據排行每一列也帶了頭像欄位
-- ③ 其他欄位沒被動到：段位排行列數、數據排行三張的列數跟改之前一樣（4／4／4）
with lb as (
  select public.get_season_leaderboard_tx(o.id, 10) as j
    from orgs o
   where exists (select 1 from rank_seasons s where s.org_id = o.id and now() >= s.starts_at and now() < s.ends_at)
   limit 1
), r as (
  select (e ->> 'id')::uuid as id, e ->> 'avatar_source' as src, e ->> 'avatar_url' as url,
         e ->> 'avatar_photo_path' as ph, e ->> 'avatar_bear' as bear, e ? 'avatar_source' as has_key
    from lb, jsonb_array_elements(lb.j -> 'rows') e
)
select
  (select case when count(*) = 0 then '⚪ 榜上沒人'
               when count(*) filter (where not r.has_key
                                        or r.src is distinct from m.avatar_source
                                        or r.url is distinct from m.avatar_url
                                        or r.ph  is distinct from m.avatar_photo_path
                                        or r.bear is distinct from m.avatar_bear) = 0
               then '✅ ' || count(*) || ' 列跟會員資料相同（' || string_agg(distinct coalesce(r.src, 'null'), '／') || '）'
               else '🔴 有對不上的列' end
     from r join members m on m.id = r.id)                                                       as "① 段位排行頭像",
  (select case when count(*) = 0 then '⚪ 數據排行沒人'
               when bool_and(e ? 'avatar_source') then '✅ ' || count(*) || ' 列都有頭像欄位'
               else '🔴 有列缺頭像欄位' end
     from lb, unnest(array['hu', 'tsumo', 'deal_in']) k, jsonb_array_elements(lb.j -> 'hand_leaders' -> k) e) as "② 數據排行頭像",
  (select '段位排行 ' || jsonb_array_length(j -> 'rows') || ' 列 · 數據排行 '
          || jsonb_array_length(j -> 'hand_leaders' -> 'hu') || '／'
          || jsonb_array_length(j -> 'hand_leaders' -> 'tsumo') || '／'
          || jsonb_array_length(j -> 'hand_leaders' -> 'deal_in') || ' 列（改之前 4／4／4）' from lb) as "③";
