-- ============================================================
-- 2026-10-15 賽季排行榜：放槍率 → 閃槍率；新增單局最大台數、單局最大連莊（各前 5 名）
-- 使用者：「排行榜的放槍率改成閃槍率。新增統計：單局最大台數排行、單局最大連莊排行，都取前 5」
--
-- hand_leaders 多三個鍵（舊的 deal_in 先留著 —— 正式站舊版 App 在新版上線前還在讀它，之後再收掉）：
--   dodge     閃槍率 ＝（局數 − 放槍）÷ 局數，越高越前面；規定局數以上才上榜（同胡牌率、自摸率）
--             名次跟原本「放槍率由低到高」完全一樣，只是數字換成「躲過幾成」
--   max_tai   單局最大台數 ＝ 本季胡過最大的一把（牌型台 ＋ 莊台），越大越前面
--   max_ren   單局最大連莊 ＝ 本季當莊時連莊最多的一次，越多越前面
--   🔴 max_tai／max_ren 都直接用 _member_hand_counts 的 max_tai／max_renzhuang ——
--     跟成績頁「單局最大台」「最長連莊」同一個算法，不在這裡另寫一份
--   ⚠ 這兩個是「紀錄」不是「比率」，不用打滿規定局數；沒胡過（null）、沒連莊過（0）的人不上榜
-- 名單照舊：上面那份段位排行的人（同一批，不另外判斷誰算數）
-- 簽名不變 ⇒ create or replace，GRANT 不會丟
--
-- 跑法：Supabase SQL Editor 整份執行，看最後那一格
-- ============================================================

CREATE OR REPLACE FUNCTION public.get_season_leaderboard_tx(p_org_id uuid, p_limit integer DEFAULT 10)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_season jsonb;
  v_rows   jsonb;
  v_champ  jsonb;
  v_hands  jsonb;
  v_n      int;
  v_from   timestamptz;
  /* 規定局數（同職棒規定打席）。要調整改這一個數字；前端讀回傳的 min_hands，不自己寫一份 */
  v_min_hands constant int := 30;
  v_empty  jsonb;
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
                              'hand_leaders', v_empty);
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
    'hand_leaders', coalesce(v_hands, v_empty));
end;
$function$;

-- ============================================================
-- 驗證（單一 SELECT；不 raise，提交後另外查線上）
-- ============================================================
with o as (select id from orgs order by created_at limit 1),
lb as (select public.get_season_leaderboard_tx((select id from o), 10) -> 'hand_leaders' as h),
-- 正對照：同一批人用 _member_hand_counts 直接算，閃槍率第一名的比率要等於 1 − 放槍率最低的那位
chk as (
  select (h -> 'dodge' -> 0 ->> 'rate')::numeric as dodge1,
         (h -> 'deal_in' -> 0 ->> 'rate')::numeric as deal1,
         (h -> 'max_tai' -> 0 ->> 'n')::int as tai1,
         (h -> 'max_ren' -> 0 ->> 'n')::int as ren1,
         jsonb_array_length(h -> 'dodge') nd, jsonb_array_length(h -> 'max_tai') nt, jsonb_array_length(h -> 'max_ren') nr,
         jsonb_array_length(h -> 'deal_in') ndi
    from lb)
select concat_ws(E'\n',
  case when (select count(*) from pg_proc where pronamespace = 'public'::regnamespace and proname = 'get_season_leaderboard_tx') = 1
       then '✅' else '🔴' end || ' ① 排行榜函式只有一個版本',
  case when has_function_privilege('authenticated', 'public.get_season_leaderboard_tx(uuid,integer)', 'execute')
       then '✅' else '🔴' end || ' ② 會員 App（authenticated）還叫得動',
  (select case when (select h from lb) ?& array['hu','tsumo','deal_in','dodge','max_tai','max_ren','min_hands']
               then '✅ ③ 六個榜都在（舊的放槍率也還在）' else '🔴 ③ 少了榜：' || (select h::text from lb) end),
  (select case when nd = 0 and ndi = 0 then '⚪ ④ 本季還沒有人打滿規定局數，閃槍率測不了'
               when dodge1 = 1 - deal1 then '✅ ④ 閃槍率第一名 ' || round(dodge1 * 100, 1) || '% ＝ 1 − 放槍率最低 ' || round(deal1 * 100, 1) || '%'
               else '🔴 ④ 閃槍率第一名 ' || dodge1 || '，放槍率最低 ' || deal1 end from chk),
  (select case when nt = 0 then '⚪ ⑤ 本季還沒有人胡過，最大台數榜是空的'
               else '✅ ⑤ 最大台數榜 ' || nt || ' 人，第一名 ' || tai1 || ' 台' end from chk),
  (select case when nr = 0 then '⚪ ⑥ 本季還沒有人連莊過，最大連莊榜是空的'
               else '✅ ⑥ 最大連莊榜 ' || nr || ' 人，第一名連 ' || ren1 end from chk),
  -- 負對照：紀錄榜不可以出現 0 或 null（沒胡過、沒連莊過的人不上榜）
  (select case when not exists (select 1 from jsonb_array_elements(h -> 'max_tai') e where coalesce((e ->> 'n')::int, 0) <= 0)
                and not exists (select 1 from jsonb_array_elements(h -> 'max_ren') e where coalesce((e ->> 'n')::int, 0) <= 0)
               then '✅ ⑦ 紀錄榜裡沒有 0 或空的' else '🔴 ⑦ 紀錄榜裡出現 0 或空的' end from lb)
) as "排行榜閃槍率與單局紀錄 · 驗證";
