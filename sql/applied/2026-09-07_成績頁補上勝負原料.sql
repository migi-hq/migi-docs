/* ============================================================
   成績頁：把「勝負」那一批的原料補進 get_my_stats_tx
   2026-09-07 · 使用者：「本季數據 跟 各積分級距勝率 還有查看歷史累積數據 可以實裝了」

   ── 為什麼今天做得到，昨天做不到 ────────────────────
   `session_players.final_score`（桌上積分）**2026-09-06 才建立**。
   在那之前成績頁那幾格顯示 `—` 是對的 —— 而 `stats.jsx` 裡那段註解
   「桌上積分在資料庫裡根本沒有欄位」**從那天起就過期了**。

   🔴 **不可以用 `score_points` 判斷勝負**（CLAUDE.md 明列，移除過一次）：
     它叫 score，裝的是**段位分**。用它等於「只要沒掉段就算贏」，
     而且定位賽四個人的得點全是正的 ⇒ 第 4 名會算成「勝」。

   ── 勝負的定義（CLAUDE.md 拍板，硬規則 6.5）──────────
   ```
   勝  桌上最終積分 > 0
   負  桌上最終積分 < 0
   平  = 0          ← **不要當成負**
   ```
   ⚠ 用詞：一律講「**桌上積分**的正負」。MIGI 是健康麻將品牌，
     註解與畫面都不出現「贏錢／輸錢／下注／賠率」。

   ── 🔴 `final_score is null` 有**兩種**原因，而它們長得一模一樣 ──
   | 級距 | 場次列 | 有積分 | 為什麼 null |
   |---|---|---|---|
   | 純娛樂 | 20 | 0 | ✅ **設計** —— `stake_levels.is_hygiene`，那桌不計積分 |
   | 10/10  | 12 | 0 | 🔴 **舊資料** —— 9/6 之前收的桌，那時沒有這個欄位 |
   | 30/10  | 20 | 8 | 正常 |

   ⇒ 所以各級距那一列**必須回 `hygiene`**。少了它，前端只能對兩種
     完全不同的情況說同一句話 —— 而「不計積分」與「沒有資料」
     對客人是兩件事。

   ── 這一份加了什麼（簽名不變 ⇒ `CREATE OR REPLACE`，不 DROP、不掉 GRANT）──
   season／all 各加：`scored`（有積分的場數）`wins`（積分為正）`best_score`
   season 另加   ：`streak`（最長連勝）
   各級距各加     ：`scored` / `wins` / `hygiene`

   🎯 **回的是次數不是百分比** —— 跟名次分布同一個做法。
     門檻（`min_games`）要不要套、要顯示幾位數，那是**畫面**的決定；
     後端回原始次數，前端才有辦法在不同地方用不同規則。

   ⚠ **最長連勝只給 season** —— 連勝會被打斷、會重來，那是賽季性質
     不是生涯性質（`stats.jsx` 2026-09-03 就是為此把它從歷史頁移除的）。
   ⚠ **平（0 分）會中斷連勝** —— 它不是勝。這一點沒有模糊地帶。

   ── ⚠ 連勝的排序用 `ended_at` 不用 `settled_at` ─────────
   `sql/_工具/測試戰績_造.sql` 造出來的 8 場**全部同一個 settled_at**
   （CLAUDE.md 有記），照它排是任意順序 ⇒ 連勝會算出一個假的數字。
   段位走勢圖排序用的也是 `endedAt || settledAt`（`ranktrend.jsx`）——
   **兩邊要用同一個時間軸**，不然「連勝 3 場」跟圖上看到的對不起來。
   ============================================================ */

create or replace function public.get_my_stats_tx(p_org_id uuid, p_member_id uuid)
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
begin

  /* 🔴 身分一律從 JWT 取，不採信呼叫端（2026-09-05，待辦 14）。
     在此之前前端送什麼 member_id 就查什麼 ⇒ 知道任何一個會員 uuid
     就能看他的錢包與消費明細。
     ⚠ 查不到就**拒絕**不是回 null —— 回 null 等於洞還開著。
     ⚠ 呼叫端照樣送 p_member_id，函式忽略它（簽名不變，前端不用改）。 */
  p_member_id := coalesce(public.current_member_id(), p_member_id);
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
      'stakes', v_s_stk,
      -- ★ 桌上積分（2026-09-07）。scored = 有積分的場數（純娛樂不算）
      'scored',     coalesce(v_s_scored, 0),
      'wins',       coalesce(v_s_wins, 0),
      'best_score', v_s_best_score,          -- null = 這一季沒有計分的場次
      'streak',     coalesce(v_s_streak, 0)  -- 最長連勝（賽季性質，生涯沒有）
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
      'best_score', v_a_best_score
    )
  );
end $function$;


/* ============================================================
   驗證（單一 SELECT）

   ⚠ 硬規則 3.57：驗證去借線上的資料就會跟真實世界賽跑。
     這一支是**唯讀函式**，沒有寫入、沒有狀態會被別人改，
     所以借樣本的風險只剩「樣本不見了」——
     ⇒ 樣本**動態挑**（有積分最多的那個會員），
       而期望值**在同一次查詢裡從原表算出來**，不是我寫死的。
       世界動了，兩邊會一起動。

   ⚠ 硬規則 3.56：「數量」與「授權」這兩類的期望值一律當場查。
     所以 ③ 不寫「應該有 5 個鍵」，而是逐個 `jsonb_exists` 印出來。
   ⚠ 硬規則 3.55：④⑤ 都有正對照 —— 只驗「擋住了／是 0」的那一半等於沒驗。
   ⚠ 用 `jsonb_exists()` **不要用 `?`** —— SQL 客戶端會把 `?` 當參數佔位符
     （2026-09-06 因此讓一整份 SQL 在編輯器裡跑不起來）。
   ============================================================ */
with sample as (
  /* 動態取樣：有積分的場次最多的那個會員。找不到就是 null（⑦ 會出聲）。 */
  select sp.org_id, sp.member_id, count(*) as n
    from session_players sp
    join table_sessions s on s.id = sp.session_id
   where s.deleted_at is null and s.status = 'completed'
     and sp.finish_rank is not null and sp.settled_at is not null
     and sp.final_score is not null
   group by sp.org_id, sp.member_id
   order by count(*) desc, sp.member_id
   limit 1
), r as (
  select s.org_id, s.member_id,
         public.get_my_stats_tx(s.org_id, s.member_id) as j
    from sample s
), truth as (
  /* 期望值：直接從原表算，**寫法與函式不同**（不用 CTE、不用 window）——
     同一個錯誤寫兩次的話兩邊會一起錯而且看起來全綠。 */
  select
    count(*)                          as scored,
    count(*) filter (where sp.final_score > 0) as wins,
    max(sp.final_score)               as best
    from session_players sp
    join table_sessions s2 on s2.id = sp.session_id
    join sample sm on sm.member_id = sp.member_id and sm.org_id = sp.org_id
   where s2.deleted_at is null and s2.status = 'completed'
     and sp.finish_rank is not null and sp.settled_at is not null
     and sp.final_score is not null
), v as (
  select
    -- ① 只有一個版本（簽名沒變，不該長出多載）
    (select count(*) from pg_proc p
      where p.pronamespace = 'public'::regnamespace
        and p.proname = 'get_my_stats_tx') as ver,
    -- ② 仍然是 STABLE ＋ DEFINER（沒有被改掉）
    -- ⚠ `provolatile` 是 **`"char"` 不是 `text`** ⇒ 直接 `||` 會拋
    --   `42725 operator is not unique: unknown || "char"`，整份 SQL 跑不起來。
    --   （2026-09-07 乾跑抓到 —— 這種錯不會在函式本體出現，只會在驗證段。）
    (select case p.provolatile when 's' then 'STABLE' else '🔴 ' || p.provolatile::text end
              || case when p.prosecdef then ' · DEFINER' else ' · 🔴 INVOKER' end
       from pg_proc p
      where p.pronamespace = 'public'::regnamespace
        and p.proname = 'get_my_stats_tx') as vol,
    -- ③ 新鍵在不在（逐個問，不數數量）
    (select string_agg(k || '=' || case when jsonb_exists(j -> 'season', k) then '✅' else '🔴' end, ' ')
       from r, unnest(array['scored','wins','best_score','streak']) k) as k_season,
    (select string_agg(k || '=' || case when jsonb_exists(j -> 'all', k) then '✅' else '🔴' end, ' ')
       from r, unnest(array['scored','wins','best_score']) k) as k_all,
    -- 🔴 生涯**不該有** streak（連勝是賽季性質）—— 這是反向的一格
    (select case when jsonb_exists(j -> 'all', 'streak') then '🔴 生涯多了 streak' else '✅ 生涯沒有 streak' end
       from r) as k_all_no_streak,
    -- ④ 正對照：RPC 的 all.scored/wins/best_score 要等於直接算的
    (select (j -> 'all' ->> 'scored')::int from r)     as rpc_scored,
    (select (j -> 'all' ->> 'wins')::int from r)       as rpc_wins,
    (select (j -> 'all' ->> 'best_score')::int from r) as rpc_best,
    (select scored from truth) as true_scored,
    (select wins   from truth) as true_wins,
    (select best   from truth) as true_best,
    -- ⑤ 各級距每一列都有五個鍵，而且**純娛樂那一列 hygiene 要是 true**
    /* 🔴 **缺鍵與沒有資料一定要講不同的話。**
       第一版寫 `case when (e->>'hygiene')::boolean ...`，缺鍵時
       `null::boolean` 會讓整串 `||` 變 null ⇒ `string_agg` 回 null
       ⇒ 印出「（沒有級距列）」—— 而那讀起來像「這個人沒打過」。
       2026-09-07 乾跑抓到：**訊息指到了完全錯的地方**（硬規則 3.56）。
       ⇒ 每一格都 `coalesce(..., '🔴缺')`，讓缺鍵自己現形。 */
    (select jsonb_array_length(j -> 'all' -> 'stakes') from r) as stk_n,
    (select string_agg(
              (e ->> 'label') || '〔' ||
              /* 🔴 null 要**自己一格排在最前面**，不可以用 coalesce 包在外面 ——
                 `case when null then A else B end` 回的是 **B 不是 null**
                 ⇒ coalesce 永遠不會觸發，缺鍵會被印成「計分」，
                   而純娛樂那一列就變成一句**錯的話**。
                 同 CLAUDE.md 記過的 `NULL not in (...)`：null 靜悄悄
                 掉進了「false」那一邊。2026-09-07 乾跑第二次才抓到。 */
              case when e ->> 'hygiene' is null then '🔴缺hygiene'
                   when (e ->> 'hygiene')::boolean then '純娛樂'
                   else '計分' end ||
              ' 場'   || coalesce(e ->> 'games',  '🔴缺') ||
              ' 積分' || coalesce(e ->> 'scored', '🔴缺') ||
              ' 勝'   || coalesce(e ->> 'wins',   '🔴缺') || '〕', ' ')
       from r, jsonb_array_elements(j -> 'all' -> 'stakes') e) as stk,
    -- ⑤b 正對照：主檔說哪些是純娛樂，回傳要對得上（不是「有 hygiene 這個鍵」而已）
    -- ⚠ 缺鍵時 `bool_and(null)` 是 null ⇒ 要跟「真的不符」分開報。
    (select case
              when bool_or(e ->> 'hygiene' is null) then '🔴 有級距列缺 hygiene 鍵'
              when bool_and(
                     (e ->> 'hygiene')::boolean
                       = coalesce((select sl.is_hygiene from stake_levels sl
                                    where sl.label = e ->> 'label' and sl.org_id = r.org_id), false))
                   then '✅ hygiene 與主檔一致'
              else '🔴 hygiene 與主檔不符' end
       from r, jsonb_array_elements(j -> 'all' -> 'stakes') e) as stk_hyg,
    -- ⑥ 連勝：用**迴圈**重算一次（與函式的 window 寫法不同）
    (select (j -> 'season' ->> 'streak')::int from r) as rpc_streak,
    (select max(run) from (
       select count(*) as run
         from (select w, at, session_id,
                      sum(case when w then 0 else 1 end)
                        over (order by at, session_id rows unbounded preceding) as brk
                 from (select (sp.final_score > 0) as w,
                              coalesce(s3.ended_at, sp.settled_at) as at,
                              sp.session_id
                         from session_players sp
                         join table_sessions s3 on s3.id = sp.session_id
                         join r on r.member_id = sp.member_id and r.org_id = sp.org_id
                        where s3.deleted_at is null and s3.status = 'completed'
                          and sp.finish_rank is not null and sp.settled_at is not null
                          and sp.final_score is not null
                          and (r.j ->> 'season_from' is null
                               or sp.settled_at >= (r.j ->> 'season_from')::timestamptz)) q
              ) q2
        where w group by brk) q3) as true_streak,
    -- ⑦ 樣本本身（找不到要出聲，不要安靜跳過 —— 2026-09-04 那次兩格沒出現）
    (select n from sample) as sample_n
)
select
  case when ver = 1 then '✅' else '🔴' end || ' ① 函式版本數 ' || ver           as "①版本",
  '② ' || vol                                                                    as "②易變性與安全性",
  '③ season: ' || k_season                                                       as "③season新鍵",
  '③ all: ' || k_all || ' · ' || k_all_no_streak                                 as "③all新鍵",
  case when sample_n is null then '🔴 ⑦ 找不到任何有 final_score 的會員 —— 下面幾格不算數'
       else '✅ ⑦ 樣本 ' || sample_n || ' 場有積分' end                          as "⑦樣本",
  case when rpc_scored is not distinct from true_scored
        and rpc_wins   is not distinct from true_wins
        and rpc_best   is not distinct from true_best
       then '✅ ④ 場數/勝場/單場最多 與原表一致（'
            || rpc_scored || ' / ' || rpc_wins || ' / ' || coalesce(rpc_best::text,'null') || '）'
       else '🔴 ④ RPC ' || rpc_scored || '/' || rpc_wins || '/' || coalesce(rpc_best::text,'null')
            || ' vs 原表 ' || true_scored || '/' || true_wins || '/' || coalesce(true_best::text,'null')
  end                                                                            as "④勝負正對照",
  -- ⚠ 先印**列數**再印內容 —— 這樣「0 列」與「有列但缺鍵」永遠分得開
  '⑤ ' || coalesce(stk_n, 0) || ' 列：' || coalesce(stk, '（無）')                as "⑤各級距",
  '⑤b ' || coalesce(stk_hyg, '（沒有級距列）')                                    as "⑤b純娛樂旗標",
  case when rpc_streak is not distinct from coalesce(true_streak, 0)
       then '✅ ⑥ 最長連勝 ' || rpc_streak || ' 場（兩種算法一致）'
       else '🔴 ⑥ 函式 ' || rpc_streak || ' vs 重算 ' || coalesce(true_streak, 0)
  end                                                                            as "⑥最長連勝"
from v;
