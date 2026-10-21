/* ============================================================
   排行榜回傳「我」與前後兩位（2026-10-21）
   ------------------------------------------------------------
   起因：使用者看過預覽（https://claude.ai/artifact/H38cqA1nwY2rMtHvLGCJx6）選了 B：
     賽季排行榜往下捲時，底部釘三列 —— 我的上一名、我、我的下一名，三列都寫段位分，不用膠囊。
   使用者：「只做 B」⇒ 這一批只做這一件（你附近、範圍分頁、約打都不做）。

   改什麼：get_season_leaderboard_tx 多回一個 around_me（陣列，最多三列，is_me 標出自己那一列）。
     · 我是誰一律 current_member_id()（JWT），不收參數 —— 沒登入就是空陣列
     · 還沒上榜（本季沒打過）也是空陣列 ⇒ 前端不畫
     · 我是第 1 名 ⇒ 只有兩列（我、下一名）；我是最後一名 ⇒ 只有兩列（上一名、我）
     · 名次與段位分讀 season_rank_rows_display_tx（跟上面的榜、成績頁的「全國排名」同一份），不另外算
     · 同分並列時用 rank_no、member_id 排出先後；上面的榜也改成同一個排法，兩邊的上一名、下一名才會一致

   ⚠ 簽名不變 ⇒ CREATE OR REPLACE，授權（anon、authenticated）照舊，不用補 grant。
   ⚠ 驗證段只讀不寫：用 set_config 模擬一位已上榜的真會員登入，算完就清掉；不 raise（硬規則 1.8）。
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
  v_min_hands constant int := 30;
  v_empty  jsonb;
  /* ★ 2026-10-21：我與前後兩位（底部釘住的那三列）。我是誰只看 JWT */
  v_me     uuid := public.current_member_id();
  v_around jsonb := '[]'::jsonb;
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

/* ── 驗證（只讀不寫、不 raise；結果用 set_config 傳給最後那一支 SELECT）── */
do $$
declare
  v_org   uuid := '11111111-1111-1111-1111-111111111111';
  v_from  timestamptz;
  v_mid   record;   -- 名次在中間的一位（應該拿到三列）
  v_top   record;   -- 第 1 名（應該只有兩列：自己＋下一名）
  v_a     jsonb;
  v_msg   text := '';
begin
  v_from := (public.current_season_tx(v_org) ->> 'starts_at')::timestamptz;

  -- ① 沒登入：around_me 是空陣列
  perform set_config('request.jwt.claims', '', true);
  v_a := public.get_season_leaderboard_tx(v_org, 10) -> 'around_me';
  v_msg := v_msg || case when v_a = '[]'::jsonb then '✅ ① 沒登入 around_me 是空陣列'
                         else '🔴 ① 沒登入卻回了：' || coalesce(v_a::text, 'null') end;

  -- 取樣：已上榜、有綁 LINE 的會員（名次排出先後，跟函式同一個排法）
  select x.member_id, x.rank_no, m.line_user_id, x.pos, x.total into v_mid
    from (select r.member_id, r.rank_no,
                 row_number() over (order by r.rank_no, r.member_id) as pos,
                 count(*) over () as total
            from public.season_rank_rows_display_tx(v_org, v_from, null) r) x
    join members m on m.id = x.member_id
   where m.line_user_id is not null and x.pos > 1 and x.pos < x.total
   order by x.pos limit 1;

  if v_mid.member_id is null then
    v_msg := v_msg || E'\n⚪ ② 找不到「已上榜、有綁 LINE、不是第一也不是最後」的會員，這一格測不了';
  else
    perform set_config('request.jwt.claims',
      jsonb_build_object('sub', v_mid.line_user_id, 'role', 'authenticated')::text, true);
    v_a := public.get_season_leaderboard_tx(v_org, 10) -> 'around_me';
    v_msg := v_msg || E'\n' || case
      when jsonb_array_length(v_a) = 3
       and (v_a -> 1 ->> 'is_me')::boolean
       and (v_a -> 1 ->> 'id')::uuid = v_mid.member_id
       and (v_a -> 1 ->> 'rank_no')::int = v_mid.rank_no
       and (v_a -> 0 ->> 'rank_no')::int <= v_mid.rank_no
       and (v_a -> 2 ->> 'rank_no')::int >= v_mid.rank_no
       and not (v_a -> 0 ->> 'is_me')::boolean and not (v_a -> 2 ->> 'is_me')::boolean
      then '✅ ② 第 ' || v_mid.rank_no || ' 名的會員拿到三列：#' || (v_a -> 0 ->> 'rank_no') || ' ' || (v_a -> 0 ->> 'rating')
           || '／我 #' || (v_a -> 1 ->> 'rank_no') || ' ' || (v_a -> 1 ->> 'rating')
           || '／#' || (v_a -> 2 ->> 'rank_no') || ' ' || (v_a -> 2 ->> 'rating')
      else '🔴 ② 第 ' || v_mid.rank_no || ' 名的會員拿到：' || coalesce(v_a::text, 'null') end;
  end if;

  -- ③ 第 1 名：只有兩列（自己＋下一名），自己在第一列
  select x.member_id, x.rank_no, m.line_user_id into v_top
    from (select r.member_id, r.rank_no,
                 row_number() over (order by r.rank_no, r.member_id) as pos
            from public.season_rank_rows_display_tx(v_org, v_from, null) r) x
    join members m on m.id = x.member_id
   where x.pos = 1 and m.line_user_id is not null;

  if v_top.member_id is null then
    v_msg := v_msg || E'\n⚪ ③ 第 1 名沒有綁 LINE，這一格測不了';
  else
    perform set_config('request.jwt.claims',
      jsonb_build_object('sub', v_top.line_user_id, 'role', 'authenticated')::text, true);
    v_a := public.get_season_leaderboard_tx(v_org, 10) -> 'around_me';
    v_msg := v_msg || E'\n' || case
      when jsonb_array_length(v_a) = 2 and (v_a -> 0 ->> 'is_me')::boolean
       and (v_a -> 0 ->> 'id')::uuid = v_top.member_id
      then '✅ ③ 第 1 名只有兩列（自己＋下一名）'
      else '🔴 ③ 第 1 名拿到：' || coalesce(v_a::text, 'null') end;
  end if;

  -- 清掉模擬的身分
  perform set_config('request.jwt.claims', '', true);
  perform set_config('migi.v', v_msg, true);
end $$;

select
  coalesce(nullif(current_setting('migi.v', true), ''), '🔴 驗證段沒有訊息') || E'\n' ||
  case when (select count(*) from pg_proc where pronamespace = 'public'::regnamespace
              and proname = 'get_season_leaderboard_tx') = 1
       then '✅ ④ get_season_leaderboard_tx 只有 1 個版本' else '🔴 ④ 出現多個版本' end || E'\n' ||
  case when exists (select 1 from pg_proc p, aclexplode(p.proacl) a
                     where p.oid = 'public.get_season_leaderboard_tx(uuid,integer)'::regprocedure
                       and a.grantee = 'anon'::regrole::oid and a.privilege_type = 'EXECUTE')
        and exists (select 1 from pg_proc p, aclexplode(p.proacl) a
                     where p.oid = 'public.get_season_leaderboard_tx(uuid,integer)'::regprocedure
                       and a.grantee = 'authenticated'::regrole::oid and a.privilege_type = 'EXECUTE')
       then '✅ ⑤ 授權照舊（anon、authenticated 都在）' else '🔴 ⑤ 授權不見了' end
  as "驗證";
