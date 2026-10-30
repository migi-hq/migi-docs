/* ============================================================
   排行榜第一名的卡片：「打了幾場」改成「勝率」（2026-10-31 使用者）
   ------------------------------------------------------------
   做了什麼
   · get_season_leaderboard_tx 的 rows 第一列多三個鍵：scored、wins、min_games
     前端算 wins ÷ scored，scored 未滿 min_games 顯示 —（同成績頁）

   為什麼直接叫 _member_stats_core
   · 成績頁的勝率就是它算的（勝 ＝ 桌上積分 > 0、分母是有積分的場數、純娛樂不算）
     ⇒ 排行榜寫的數字跟第一名自己成績頁上那一格一定一樣，算法只有一份
   · sql/pending/2026-10-28_好友練習賽_結算與排除.sql 會改 _member_stats_core 排除練習賽，
     這裡跟著自動排除，不用再改一次
   · 只算第一名一個人（一次呼叫），其他列不需要

   隱私
   · 第一名把「誰能看我的成績」設成「只有自己」⇒ 三個鍵都不給，前端寫「不公開」
     （同 get_member_card_tx：see_score = '只有自己' 時不給成績）
   · 預設「牌咖」不擋：排行榜的胡牌率、自摸率本來就公開，勝率同一類

   簽名不變 ⇒ CREATE OR REPLACE，授權不會掉（anon／authenticated 照舊）
   ============================================================ */

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
  v_min_hands constant int := public._hand_min_count();
  v_empty  jsonb;
  /* ★ 2026-10-21：我與前後兩位（底部釘住的那三列）。我是誰只看 JWT */
  v_me     uuid := public.current_member_id();
  v_around jsonb := '[]'::jsonb;
  /* ★ 2026-10-31：第一名的勝率 */
  v_top_id uuid;
  v_top    jsonb;
begin
  /* 上限保護：前端送 100000 的話這支會把整個榜撈出來。least 而不是 raise。 */
  v_n := greatest(1, least(coalesce(p_limit, 10), 100));

  v_empty := jsonb_build_object('min_hands', v_min_hands,
               'hu', '[]'::jsonb, 'tsumo', '[]'::jsonb, 'deal_in', '[]'::jsonb,
               'dodge', '[]'::jsonb, 'max_tai', '[]'::jsonb, 'max_ren', '[]'::jsonb);

  v_season := public.current_season_tx(p_org_id);

  /* 沒有進行中的賽季時不要回 ok:false —— 那是正常狀態（兩季之間的空檔）。 */
  if v_season is null then
    return jsonb_build_object('ok', true, 'season', null,
                              'rows', '[]'::jsonb, 'champions', '[]'::jsonb,
                              'hand_leaders', v_empty, 'around_me', '[]'::jsonb);
  end if;
  v_from := (v_season ->> 'starts_at')::timestamptz;

  /* 本季排行。名次借 season_rank_rows_display_tx（與成績頁的「全國排名」同一份定義）。
     🔴 2026-09-30 加回 id：點進去的個人卡要靠它判斷「你們是不是牌咖」。
     ★ 2026-10-10 加頭像四欄（在此之前排行榜一律畫預設小熊）。
     ★ 2026-10-21 同分時再用 member_id 排先後，跟下面 around_me 同一個排法 */
  select coalesce(jsonb_agg(x order by x.rank_no, x.id), '[]'::jsonb) into v_rows
    from (
      select r.rank_no, r.rating, r.games,
             r.member_id           as id,
             m.display_name        as name,
             public.rank_from_rating(r.rating) as rank_label,
             m.avatar_source, m.avatar_url, m.avatar_photo_path, m.avatar_bear
        from public.season_rank_rows_display_tx(p_org_id, v_from, null) r
        join members m on m.id = r.member_id
       order by r.rank_no, r.member_id
       limit v_n
    ) x;

  /* ★ 2026-10-31 第一名卡片的勝率：問 _member_stats_core（成績頁同一支），只取本季的勝場與有積分場數。
     對方設「只有自己」看成績、而且看的人不是他自己 ⇒ 不給（同 get_member_card_tx）。 */
  if jsonb_array_length(v_rows) > 0 then
    v_top_id := (v_rows -> 0 ->> 'id')::uuid;
    if v_top_id = v_me
       or coalesce((select m.see_score from members m where m.id = v_top_id), '牌咖') <> '只有自己' then
      v_top := public._member_stats_core(p_org_id, v_top_id, null, null);
      v_rows := jsonb_set(v_rows, '{0}', (v_rows -> 0) || jsonb_build_object(
                  'scored',    v_top -> 'season' -> 'scored',
                  'wins',      v_top -> 'season' -> 'wins',
                  'min_games', v_top -> 'min_games'));
    else
      v_rows := jsonb_set(v_rows, '{0}', (v_rows -> 0) || jsonb_build_object('stats_private', true));
    end if;
  end if;

  /* ★ 2026-10-21 我與前後兩位：整份名次排好之後，取我那一列的位置 ±1。
     還沒上榜（不在名單裡）或沒登入 ⇒ 空陣列，前端不畫 */
  if v_me is not null then
    with r as (
      select x.rank_no, x.rating, x.games, x.member_id,
             row_number() over (order by x.rank_no, x.member_id) as pos
        from public.season_rank_rows_display_tx(p_org_id, v_from, null) x
    ), mine as (
      select r.pos from r where r.member_id = v_me
    )
    select coalesce(jsonb_agg(jsonb_build_object(
             'rank_no', r.rank_no, 'rating', r.rating, 'games', r.games,
             'id', r.member_id, 'name', m.display_name,
             'rank_label', public.rank_from_rating(r.rating),
             'avatar_source', m.avatar_source, 'avatar_url', m.avatar_url,
             'avatar_photo_path', m.avatar_photo_path, 'avatar_bear', m.avatar_bear,
             'is_me', r.member_id = v_me) order by r.pos), '[]'::jsonb)
      into v_around
      from r
      join mine on r.pos between mine.pos - 1 and mine.pos + 1
      join members m on m.id = r.member_id;
  end if;

  /* ★ 每一局的數據排行（2026-10-10）：胡牌率／自摸率／閃槍率（2026-10-15 取代放槍率），各前 5 名；
     ★ 2026-10-15 再加單局最大台數、單局最大連莊兩個紀錄榜，各前 5 名。
     名單＝上面那一份段位排行的人（同一批，不另外判斷誰算數）；
     局數、胡、自摸、放槍、最大台、最長連莊一律問 _member_hand_counts（跟成績頁同一支）。
     ⚠ 名單是空的時候傳空陣列不是 null —— null 在那支的意思是「所有人」。 */
  with pop as (
    select r.member_id, r.rating
      from public.season_rank_rows_display_tx(p_org_id, v_from, null) r
  ), agg as (
    select c.member_id, c.hands, c.hu, c.tsumo, c.deal_in, c.max_tai, c.max_renzhuang
      from public._member_hand_counts(
             p_org_id, v_from,
             (select coalesce(array_agg(pop.member_id), '{}'::uuid[]) from pop)) c
  ), q as (
    select a.*, mb.display_name as name, mb.created_at,
           mb.avatar_source, mb.avatar_url, mb.avatar_photo_path, mb.avatar_bear,
           public.rank_from_rating(pop.rating) as rank_label
      from agg a
      join pop on pop.member_id = a.member_id
      join members mb on mb.id = a.member_id
  ), board as (
    /* 比率榜：規定局數以上才上榜 */
    select k, x.*
      from (values ('hu'), ('tsumo'), ('deal_in'), ('dodge')) as kk(k)
      cross join lateral (
        select q.member_id, q.name, q.rank_label, q.hands, q.created_at,
               q.avatar_source, q.avatar_url, q.avatar_photo_path, q.avatar_bear,
               case kk.k when 'hu' then q.hu when 'tsumo' then q.tsumo
                         when 'deal_in' then q.deal_in else q.hands - q.deal_in end as n,
               round((case kk.k when 'hu' then q.hu when 'tsumo' then q.tsumo
                                when 'deal_in' then q.deal_in else q.hands - q.deal_in end)::numeric
                     / q.hands, 4) as rate
          from q
         where q.hands >= v_min_hands
      ) x
    union all
    /* 紀錄榜：不用打滿規定局數；沒胡過（null）、沒連莊過（0）的人不上榜 */
    select k, x.*
      from (values ('max_tai'), ('max_ren')) as kk(k)
      cross join lateral (
        select q.member_id, q.name, q.rank_label, q.hands, q.created_at,
               q.avatar_source, q.avatar_url, q.avatar_photo_path, q.avatar_bear,
               case kk.k when 'max_tai' then q.max_tai else q.max_renzhuang end as n,
               null::numeric as rate
          from q
         where coalesce(case kk.k when 'max_tai' then q.max_tai else q.max_renzhuang end, 0) > 0
      ) x
  ), ranked as (
    /* 排序：放槍率由低到高；其餘一律由高到低（比率榜比 rate，紀錄榜比 n） */
    select b.*,
           rank() over (partition by b.k
                        order by case when b.k = 'deal_in' then b.rate
                                      when b.rate is null then -b.n
                                      else -b.rate end) as rank_no,
           row_number() over (partition by b.k
                              order by case when b.k = 'deal_in' then b.rate
                                            when b.rate is null then -b.n
                                            else -b.rate end,
                                       b.hands desc, b.created_at) as rn
      from board b
  )
  select jsonb_build_object(
           'min_hands', v_min_hands,
           'hu',      coalesce(jsonb_agg(j order by rn) filter (where k = 'hu'),      '[]'::jsonb),
           'tsumo',   coalesce(jsonb_agg(j order by rn) filter (where k = 'tsumo'),   '[]'::jsonb),
           'deal_in', coalesce(jsonb_agg(j order by rn) filter (where k = 'deal_in'), '[]'::jsonb),
           'dodge',   coalesce(jsonb_agg(j order by rn) filter (where k = 'dodge'),   '[]'::jsonb),
           'max_tai', coalesce(jsonb_agg(j order by rn) filter (where k = 'max_tai'), '[]'::jsonb),
           'max_ren', coalesce(jsonb_agg(j order by rn) filter (where k = 'max_ren'), '[]'::jsonb))
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
    'hand_leaders', coalesce(v_hands, v_empty), 'around_me', v_around);
end;
$function$;


/* ── 驗證（單一 SELECT，不 raise）──────────────────────────
   ① 版本數 1
   ② 授權沒掉：anon、authenticated 都叫得動
   ③ 第一名那一列有勝率三個鍵（或因為「只有自己」標了不公開）
   ④ 數字跟 _member_stats_core 直接問的一樣（正對照：證明不是寫死或抓錯人）
   ⑤ 其他列沒有多出這些鍵（只算第一名） */
with r as (
  select public.get_season_leaderboard_tx('11111111-1111-1111-1111-111111111111'::uuid, 10) as j
), top as (
  select j -> 'rows' -> 0 as t, jsonb_array_length(j -> 'rows') as n from r
), core as (
  select public._member_stats_core('11111111-1111-1111-1111-111111111111'::uuid,
                                   (t ->> 'id')::uuid, null, null) as c
    from top where t is not null
)
select concat_ws(E'\n',
  case when (select count(*) from pg_proc where proname = 'get_season_leaderboard_tx'
               and pronamespace = 'public'::regnamespace) = 1
       then '✅ ① 版本數 1' else '🔴 ① 版本數不是 1' end,
  case when has_function_privilege('anon', 'public.get_season_leaderboard_tx(uuid,integer)', 'execute')
        and has_function_privilege('authenticated', 'public.get_season_leaderboard_tx(uuid,integer)', 'execute')
       then '✅ ② anon、authenticated 都叫得動' else '🔴 ② 授權掉了' end,
  coalesce((select case
      when t is null then '⚪ ③ 榜上沒人，這一格測不了'
      when t ? 'stats_private' then '✅ ③ 第一名（' || (t ->> 'name') || '）設了只有自己 ⇒ 不公開'
      when t ? 'wins' and t ? 'scored' and t ? 'min_games'
        then '✅ ③ 第一名（' || (t ->> 'name') || '）勝 ' || (t ->> 'wins') || ' / ' || (t ->> 'scored')
             || ' 場（門檻 ' || (t ->> 'min_games') || ' 場）'
      else '🔴 ③ 第一名那一列沒有勝率的鍵' end from top), '🔴 ③ 沒有回傳'),
  coalesce((select case
      when t ? 'stats_private' then '⚪ ④ 不公開，這一格測不了'
      when (t -> 'wins') = (c -> 'season' -> 'wins') and (t -> 'scored') = (c -> 'season' -> 'scored')
        then '✅ ④ 跟成績頁同一支算出來的一樣'
      else '🔴 ④ 跟 _member_stats_core 對不上' end from top, core), '⚪ ④ 榜上沒人，這一格測不了'),
  coalesce((select case
      when n <= 1 then '⚪ ⑤ 榜上只有一人，這一格測不了'
      when exists (select 1 from r, jsonb_array_elements(j -> 'rows') with ordinality e(v, i)
                    where i > 1 and (v ? 'wins' or v ? 'scored' or v ? 'stats_private'))
        then '🔴 ⑤ 第二名以後也多了鍵'
      else '✅ ⑤ 只有第一名多了勝率' end from top), '⚪ ⑤ 測不了')
) as "驗證";
