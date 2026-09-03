/* ============================================================
   ① 各級距「勝率」停用到 M4　② 拿掉平均得點　③ 麻將足跡接真資料
   2026-09-03 · MIGI

   `create or replace`、**簽名沒變** ⇒ 不用 DROP、不會掉 GRANT、不用部署順序。

   ── 🔴 為什麼停用勝率：`score_points` 不是桌上積分 ──────────
   我今天早上做「各級距勝率」時把 `session_players.score_points`
   當成**桌上積分**，於是定義「勝 = score_points > 0」。
   **那是錯的。** 撈 `apply_session_rounds_tx` 的線上定義才發現：
   ```sql
   score_points = (e->>'pts')::int      -- pts 累加自 rank_points（段位積分）
   ```
   實測創辦人的九場，`score_points` 與段位分變動**逐列相同**
   （60 / 30 / 0 / −40 / 60 …）。

   ⇒ 「勝 = score_points > 0」實際上等於「**段位分有沒有上升**」——
     而那正是使用者明確講過**不要**的（「不是 MIGI 積分，是桌上積分要是正的」）。
     它的實際效果是「名次 ≤ 2 才算贏」（第 3 名 0 分不算），
     也就是日麻的**連對率**，不是輸贏。

   🔴 **桌上積分在資料庫裡根本沒有欄位。**
     `session_players` 只有 `charged_points`（檯費）、
     `score_points`（現在裝段位分）、`rating_after`。
     真正的桌上輸贏要等**電子計分（M4）**。

   ✅ 使用者 2026-09-03 選了最保守的一條：**勝率顯示 `—` 直到 M4**。
   → `stakes[]` 不再回 `wins` 與 `pct`，只回 `games`。
   ⚠ **不是把它算錯的值留著改個名字** —— 那個數字會被當成勝率讀。
   ⚠ `min_games` 保留：名次分布的比率仍然用它，而且 M4 接回勝率時要用同一個。

   📌 **`score_points` 這個欄位名本身是個陷阱**（一個名字兩種意思，
     CLAUDE.md 記過三次的病）。M4 做電子計分時要一起處理：
     真正的桌上分數另開欄位，或把這一欄正名成 `rating_delta`。
     **不要在那之前讓任何新功能讀它。**

   ── ② 拿掉 `avg_score` ──────────────────────────────
   前端的「平均得點」那一格已刪（同一個誤會：它印的是平均段位分，
   而段位走勢圖已經在講同一件事）。回了沒人讀就是下一個「建了沒人讀」。

   ── ③ 麻將足跡：四格全部接真資料 ──────────────────────
   個人檔案的「我的麻將足跡」四格在此之前**整排寫死**
   （`0 打了幾場 / 銅牌熊 生涯最高 / 1 造訪門市 / 0 交手過的人`）。
   使用者要把「打了幾場」換成「累積時數」——
   ✅ 順手把四格一起接真的：**只有一格是真的、旁邊三格是假的，
     比四格都假更危險**（客人分不出哪個能信，同 KPI 那次的判斷）。

   放在 `all` 底下是刻意的：足跡是**生涯**不是本季。
   · `minutes`     累積分鐘（`ended_at − activated_at` 的總和）
   · `peak_rating` 生涯最高分 ＋ `peak_rank` 那時的段位
     🎯 **不需要 `peak_rating` 欄位** —— `session_players.rating_after`
       每一場都記著，`max()` 就是生涯最高。（同 `apply_session_rounds_tx`
       裡「不需要 peak_rating」那段註解的精神。）
   · `stores`      造訪過幾間門市
   · `opponents`   生涯交手過幾個人（不含自己）
   ⚠ **`champions`（雀神次數）刻意沒有做** —— 前端那一格 2026-09-03
     被拿掉了，回一個沒人讀的鍵就是下一個「建了沒人讀」（同 `avg_score`）。
     `season_champions` 那張表在（`season / org_id / member_id / rating /
     awarded_at`，目前 0 列），名人堂接真資料時三行就補得回來。

   ── ④ 賽季 KPI 補「對手平均段位」──────────────────────
   `season.opp_rating` ＋ `opp_rank`。
   🎯 它是**校正用的**：平均順位 2.1 這個數字，在「對手都是銅牌」與
     「對手都是大師」之下意義完全不同 —— 少了這一格就分不出
     「我很強」與「我遇到的人很弱」。
   ⚠ 用對手當時的 `rating_after` 不是他們**現在**的 `members.rating` ——
     後者會一直漂，今天算出來的數字下週就變了，而那一季的事實不該變。

   ── 🎯 這一份的分工原則（盤點後定的）──────────────────
   ```
   足跡（生涯）     只增不減的「量」   → 總數・最高・第一次
   賽季 KPI（本季） 會上下的「率與位置」 → 比率・名次・排名
   ```
   🔴 放錯邊的代價很具體：把累計數字放進賽季，**換季那天全部歸零**，
     客人會以為紀錄不見了；把「率」放進足跡，那個數字十年不會動。
   ⚠ 所以 `minutes` / `stores` / `opponents` / `peak_*` 一律在 `all`，
     `opp_rating` / `national_rank` 一律在 `season`。**不要兩邊都放。**
   ============================================================ */

create or replace function public.get_my_stats_tx(
  p_org_id    uuid,
  p_member_id uuid
) returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $function$
declare
  /* 🎯 **樣本數門檻只有這一個定義。** 名次分布的比率用它；
     M4 把勝率接回來時也要用同一個，不要另外挑一個數字。 */
  v_min_games constant int := 5;

  v_win     timestamptz;
  v_s_games int; v_s_avg numeric;
  v_a_games int; v_a_avg numeric;
  v_s_ranks jsonb; v_a_ranks jsonb;
  v_rank    int; v_total int;
  v_s_stk   jsonb; v_a_stk jsonb;
  v_minutes int; v_peak int; v_stores int; v_opp int;
  v_opp_rating int;
begin
  v_win := public.rating_window_start_tx(p_org_id);

  /* ── 一次掃描，本季與歷史兩組數字 ──────────────────
     「已結算」＝ 有名次而且有結算時間。兩個都要：
     `finish_rank` 有值但 `settled_at` 是 null 的列在時間視窗裡會被漏掉。 */
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
         /* 🎯 名次分布：**回次數不回百分比**。
            ⚠ 四個鍵一律都在（沒拿過第 3 名就是 `"3": 0`）——
              少一個鍵的話前端得寫 `?? 0`，那是第二份預設值。 */
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

  /* ── 各積分級距：**只回場數**（勝率停用到 M4，見檔頭）──── */
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
    /* ⚠ `stake_level_id` 可能是 null（沒設級距的場次）——
         那時 join 不到主檔，`label` 用「未設定」而不是整列消失：
         **場數對不起來比多一行更難查**。 */
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

  /* ── 全國排名（只有本季）──────────────────────── */
  with eligible as (
    select distinct sp.member_id
      from session_players sp
      join table_sessions s on s.id = sp.session_id
      join members mem      on mem.id = sp.member_id
     where sp.org_id = p_org_id
       and s.org_id  = p_org_id
       and s.deleted_at is null
       and s.status  = 'completed'
       and sp.finish_rank is not null
       and sp.settled_at  is not null
       and (v_win is null or sp.settled_at >= v_win)
       and mem.deleted_at is null
       and mem.is_test = false
  ), ranked as (
    select e.member_id,
           rank() over (order by mem.rating desc, mem.created_at) as rk
      from eligible e join members mem on mem.id = e.member_id
  )
  select (select rk from ranked where member_id = p_member_id),
         (select count(*) from ranked)
    into v_rank, v_total;

  /* ── 本季對手平均段位（校正用）────────────────────
     🎯 平均順位 2.1 在「對手都是銅牌」與「對手都是大師」之下意義完全不同。
     ⚠ 用對手**當時的** `rating_after`，不是他們現在的 `members.rating` ——
       後者會一直漂，今天算出來的數字下週就變了，而那一季的事實不該變。
     ⚠ 沒有對手或都沒有 `rating_after`（M4 之前）→ null → 前端顯示 `—`。 */
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
    /* 累積分鐘。⚠ 只算兩端時間都有的場次 —— `ended_at` 是 null 的
       （理論上 completed 不該有）會讓總和變成 null，那比少算幾分鐘更糟。
       ⚠ `greatest(...,0)`：資料髒掉時（結束早於開始）不要出現負的時數。 */
    coalesce(sum(greatest(0, extract(epoch from
        (m.ended_at - coalesce(m.activated_at, m.started_at))) / 60))
      filter (where m.ended_at is not null
                and coalesce(m.activated_at, m.started_at) is not null), 0)::int,
    /* 🎯 生涯最高分 = `max(rating_after)`。**不需要 peak_rating 欄位** ——
       每一場都記著，取最大就是。M4 之前是 null（那時顯示 —）。 */
    max(m.rating_after),
    count(distinct m.store_id) filter (where m.store_id is not null),
    /* 生涯交手過幾個人。⚠ 用 `distinct member_id` 不是 `count(*)` ——
       同一個人打過十次還是一個人。 */
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
    /* 🔴 **`stakes[]` 不再有 `wins` / `pct`**，`avg_score` 也拿掉了。
       兩個都是同一個誤會的產物（`score_points` 裝的是段位分不是桌上積分）。
       M4 電子計分之後再接回來，那時才有真正的桌上輸贏。 */
    'season', jsonb_build_object(
      'games', coalesce(v_s_games, 0),
      'avg_rank', v_s_avg,     -- null = 本季還沒打過（不要回 0）
      'ranks',    coalesce(v_s_ranks, jsonb_build_object('1',0,'2',0,'3',0,'4',0)),
      'national_rank',  v_rank,
      'national_total', coalesce(v_total, 0),
      -- 本季對手平均段位（校正用，見上）
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
      -- 🔴 歷史沒有 national_rank：rating 每季歸零，歷代總排名沒有意義
      -- ── 麻將足跡（個人檔案那四格）──
      'minutes',     coalesce(v_minutes, 0),
      'peak_rating', v_peak,
      'peak_rank',   case when v_peak is not null
                          then public.rank_from_rating(v_peak) end,
      'stores',      coalesce(v_stores, 0),
      'opponents',   coalesce(v_opp, 0)
    )
  );
end $function$;

comment on function public.get_my_stats_tx(uuid, uuid) is
  '成績頁統計 ＋ 個人檔案的麻將足跡。本季／歷史各一份（場數、平均順位、名次分布、各級距場數）；全國排名只有本季；足跡（累積分鐘・生涯最高・門市數・交手人數）在 all 底下。⚠ 各級距「勝率」停用到 M4：score_points 裝的是段位分不是桌上積分。胡牌率／放槍率／自摸率要等牌譜（M5+）。';


-- ── 驗證 ───────────────────────────────────────────────
do $$
declare
  v_org uuid := '11111111-1111-1111-1111-111111111111';
  v_out text := ''; v_store uuid; v_store2 uuid; v_tbl uuid; v_tbl2 uuid;
  me uuid; o1 uuid; o2 uuid; s uuid; i int;
  sl_a uuid; j jsonb;
begin
  begin
    select id into v_store from stores where org_id = v_org order by created_at limit 1;
    select id into v_store2 from stores where org_id = v_org and id <> v_store order by created_at limit 1;
    select id into v_tbl  from tables where org_id = v_org and store_id = v_store limit 1;
    select id into v_tbl2 from tables where org_id = v_org and store_id = coalesce(v_store2, v_store) limit 1;
    select id into sl_a from stake_levels where org_id = v_org order by sort_order, id limit 1;

    v_out := v_out || E'\n' || '① 一個版本 · DEFINER · anon 明確授權' || E'\t' ||
      (select case when count(*) = 1 and bool_and(p.prosecdef)
                    and bool_and(exists (select 1 from aclexplode(p.proacl) a
                          where a.grantee='anon'::regrole::oid and a.privilege_type='EXECUTE'))
                   then '✅ 三項都對' else '🔴 ' || count(*) || ' 個版本' end
         from pg_proc p where p.pronamespace='public'::regnamespace and p.proname='get_my_stats_tx');

    ---- 造：兩間門市、兩個對手、三場各 90 分鐘 ----------
    insert into members (org_id, display_name, rating, is_test)
      values (v_org, '測足跡', 500, false) returning id into me;
    insert into members (org_id, display_name) values (v_org, '測對手甲') returning id into o1;
    insert into members (org_id, display_name) values (v_org, '測對手乙') returning id into o2;

    for i in 1..3 loop
      insert into table_sessions (org_id, store_id, table_id, mode, status,
                                  activated_at, ended_at, stake_level_id)
        values (v_org,
                case when i = 3 then coalesce(v_store2, v_store) else v_store end,
                case when i = 3 then v_tbl2 else v_tbl end,
                'private','completed',
                now() - interval '90 minutes', now(), sl_a)
        returning id into s;
      insert into session_players (org_id, session_id, member_id, finish_rank, score_points, settled_at, rating_after)
        values (v_org, s, me, i, 0, now(), 100 * i),
               (v_org, s, o1, 4, 0, now(), 50);
      /* ⚠ 對手乙只出現在第 1 場 —— 這樣「交手過的人」才驗得出
           是 `distinct` 而不是 `count(*)`。 */
      if i = 1 then
        insert into session_players (org_id, session_id, member_id, finish_rank, score_points, settled_at, rating_after)
          values (v_org, s, o2, 3, 0, now(), 50);
      end if;
    end loop;

    j := public.get_my_stats_tx(v_org, me);

    /* 🔴 **這是這一份最重要的一格**：`stakes[]` 不可以再有 `wins` / `pct`。
       留著的話前端會繼續讀到一個「其實是連對率」的數字。 */
    v_out := v_out || E'\n' || '② 🎯 stakes 只剩 label / games（勝率停用）' || E'\t' ||
      (select case when bool_and(not (x ? 'pct') and not (x ? 'wins') and (x ? 'games'))
                   then '✅ 沒有 pct、沒有 wins、有 games'
                   else '🔴 ' || (j->'season'->'stakes')::text end
         from jsonb_array_elements(j->'season'->'stakes') x);

    v_out := v_out || E'\n' || '③ 🎯 avg_score 已移除（前端那一格已刪）' || E'\t' ||
      case when not (j->'season' ? 'avg_score') and not (j->'all' ? 'avg_score')
           then '✅ 兩份都沒有這個鍵'
           else '🔴 還在 —— 回了沒人讀' end;

    ---- 麻將足跡 --------------------------------------
    /* 三場各 90 分鐘 ⇒ 270 分鐘。
       ⚠ 期望值寫算式（硬規則 3.56）：3 × 90 = 270。 */
    v_out := v_out || E'\n' || '④ 累積分鐘 3 場 × 90 = 270' || E'\t' ||
      case when (j->'all'->>'minutes')::int = 270 then '✅ 270'
           else '🔴 ' || coalesce(j->'all'->>'minutes','null') end;

    /* rating_after 給了 100 / 200 / 300 ⇒ 生涯最高 300。 */
    v_out := v_out || E'\n' || '⑤ 生涯最高 = max(rating_after) = 300' || E'\t' ||
      case when (j->'all'->>'peak_rating')::int = 300
            and (j->'all'->>'peak_rank') = public.rank_from_rating(300)
           then '✅ 300 · ' || (j->'all'->>'peak_rank')
           else '🔴 ' || coalesce(j->'all'->>'peak_rating','null')
                || ' / ' || coalesce(j->'all'->>'peak_rank','null') end;

    v_out := v_out || E'\n' || '⑥ 造訪門市' || E'\t' ||
      case when v_store2 is null then
             case when (j->'all'->>'stores')::int = 1 then '⚠ 只有一間門市，回 1（對）'
                  else '🔴 ' || (j->'all'->>'stores') end
           when (j->'all'->>'stores')::int = 2 then '✅ 2 間（第 3 場換了門市）'
           else '🔴 ' || coalesce(j->'all'->>'stores','null') end;

    /* 🔴 **正對照：交手人數要是 2 不是 4。**
       對手甲出現 3 次、乙 1 次 ⇒ 用 `count(*)` 會得到 4。
       這一格就是在擋那個寫法。 */
    v_out := v_out || E'\n' || '⑦ 🎯 交手過的人 = 2（甲 3 次＋乙 1 次，去重）' || E'\t' ||
      case when (j->'all'->>'opponents')::int = 2
           then '✅ 2（count(*) 的寫法會得到 4，在這裡紅）'
           else '🔴 ' || coalesce(j->'all'->>'opponents','null') end;

    ---- 沒動到的東西 ----------------------------------
    /* 🎯 對手平均段位：對手甲三場都 `rating_after = 50`、乙一場 50
       ⇒ 四列全部 50 ⇒ 平均 50。
       🔴 **正對照的重點是「不等於我自己的分數」** —— 我的 rating_after
         是 100/200/300，如果實作不小心把自己算進去，平均會是 137 而不是 50。 */
    v_out := v_out || E'\n' || '⑦-2 🎯 對手平均段位 = 50（不含自己）' || E'\t' ||
      case when (j->'season'->>'opp_rating')::int = 50
            and (j->'season'->>'opp_rank') = public.rank_from_rating(50)
           then '✅ 50 · ' || (j->'season'->>'opp_rank') || '（把自己算進去會變 137）'
           else '🔴 ' || coalesce(j->'season'->>'opp_rating','null') end;

    /* 🗑 **`champions` 刻意不回**（前端那一格已拿掉）——
         驗的是「它真的不在」，不然又是一個回了沒人讀的鍵。 */
    v_out := v_out || E'\n' || '⑦-3 🎯 champions 沒有回（前端那一格已刪）' || E'\t' ||
      case when not (j->'all' ? 'champions') then '✅ 沒有這個鍵'
           else '🔴 還在 —— 回了沒人讀' end;

    v_out := v_out || E'\n' || '⑧ 名次分布沒被動到（1/2/3 各一次）' || E'\t' ||
      case when (j->'season'->'ranks'->>'1')::int = 1
            and (j->'season'->'ranks'->>'2')::int = 1
            and (j->'season'->'ranks'->>'3')::int = 1
            and (j->'season'->'ranks'->>'4')::int = 0
           then '✅ 1/1/1/0'
           else '🔴 ' || (j->'season'->'ranks')::text end;

    v_out := v_out || E'\n' || '⑨ min_games 還在（名次分布與 M4 都要用）' || E'\t' ||
      case when (j->>'min_games')::int = 5 then '✅ 5'
           else '🔴 ' || coalesce(j->>'min_games','(沒有這個鍵)') end;

    ---- 沒打過的人 ------------------------------------
    /* ⚠ 足跡的四格對新客人要是 `0 / null / 0 / 0`：
         時數與門市是 0（真的是零），**生涯最高是 null**
         （「還沒有最高」不是「最高是 0 分」）。 */
    insert into members (org_id, display_name) values (v_org, '測沒打過') returning id into o1;
    j := public.get_my_stats_tx(v_org, o1);
    v_out := v_out || E'\n' || '⑩ 沒打過：時數 0、生涯最高 null、門市 0、對手 0' || E'\t' ||
      case when (j->'all'->>'minutes')::int = 0
            and (j->'all'->>'peak_rating') is null
            and (j->'all'->>'stores')::int = 0
            and (j->'all'->>'opponents')::int = 0
           then '✅ 0 / null / 0 / 0'
           else '🔴 ' || (j->'all')::text end;

    raise exception 'migi_rollback';
  exception when others then
    if sqlerrm <> 'migi_rollback' then
      v_out := v_out || E'\n' || '🔴 測試自己炸了' || E'\t' || sqlerrm;
    end if;
    perform set_config('migi.foot', v_out, true);
  end;
end $$;

select split_part(x, E'\t', 1) as 測試,
       split_part(x, E'\t', 2) as 結果
  from unnest(string_to_array(current_setting('migi.foot', true), E'\n')) as x
 where coalesce(x,'') <> '';
