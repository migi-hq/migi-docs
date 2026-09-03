/* ============================================================
   成績頁補三樣：名次分布・平均得點・樣本數門檻
   2026-09-03 · MIGI

   `create or replace`、**簽名沒變** ⇒ 不用 DROP、不會掉 GRANT、不用部署順序。

   ── ① 名次分布（1/2/3/4 位各幾次）────────────────────
   🔴 **平均順位單獨看不出人**：`2.5` 同時是
     「永遠 2、3 名」與「一半第一、一半第四」的答案 ——
     前者穩、後者賭，而平均順位對這兩個人給同一個數字。
   🎯 天鳳／雀魂的個人頁**頭條就是這個分布**，平均順位反而是附註。
   🎯 對 MIGI 還有一個更硬的理由：**段位規則裡第 4 名扣最多**
     （鑽石以上 −30／−40）⇒ 「4 位率」直接就是「我為什麼掉分」的答案。

   ── ② 平均得點 ──────────────────────────────────
   現在的「勝率」只說**贏幾次**，沒說**贏多大**。
   勝率 50% 但平均 −20 = 贏小輸大，而畫面上完全看不出來。
   ⚠ 分母是**有登記分數的場次**（`score_points` 可能是 null：
     已結算但沒登記分數）。今天 12/12 都有值，但別假設將來也是。

   ── ③ 樣本數門檻（這一項最急）────────────────────
   🔴 畫面上現在會出現 **「100% · 3 場」** —— 那不是成績是噪音。
   天鳳、雀魂、Chess.com Insights **全部都有樣本數門檻**。
   ✅ 做法：**後端在場數不足時把 `pct` 回成 null**，
     而不是讓前端自己判斷 —— 那樣門檻會變成第二份規則，
     而且下一個加百分比的地方一定會忘記套。
   📌 門檻值一併回傳（`min_games`），前端才講得出
     「再 N 場就看得到勝率」而不用自己寫死一個 5。

   ⚠ **名次分布不套門檻**：它回的是**次數**（1 位 3 次）不是百分比，
     次數在任何場數下都是事實。百分比由前端在達標時才畫。
   ============================================================ */

create or replace function public.get_my_stats_tx(
  p_org_id    uuid,
  p_member_id uuid
) returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $function$
declare
  /* 🎯 **樣本數門檻只有這一個定義。** 要調就調這裡。
     5 是刻意的低標：低到「來過兩三次的客人也看得到」，
     但高到「一場 100%」不會出現。 */
  v_min_games constant int := 5;

  v_win     timestamptz;
  v_s_games int; v_s_avg numeric; v_s_score numeric;
  v_a_games int; v_a_avg numeric; v_a_score numeric;
  v_s_ranks jsonb; v_a_ranks jsonb;
  v_rank    int; v_total int;
  v_s_stk   jsonb; v_a_stk jsonb;
begin
  v_win := public.rating_window_start_tx(p_org_id);

  /* ── 一次掃描，本季與歷史兩組數字 ──────────────────
     「已結算」＝ 有名次而且有結算時間。兩個都要：
     `finish_rank` 有值但 `settled_at` 是 null 的列在時間視窗裡會被漏掉，
     而那種列在資料庫裡是可能存在的（名次可以先登記）。 */
  with mine as (
    select sp.finish_rank, sp.score_points,
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
         round(avg(finish_rank)  filter (where in_season), 1),
         /* ⚠ `avg` 自己會忽略 null ⇒ 分母是「有登記分數的場次」，
              不是「已結算的場次」。全部都沒登記時回 null（前端顯示 —）。 */
         round(avg(score_points) filter (where in_season), 1),
         count(*),
         round(avg(finish_rank), 1),
         round(avg(score_points), 1),
         /* 🎯 名次分布：**回次數不回百分比**（見檔頭 ③）。
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
    into v_s_games, v_s_avg, v_s_score, v_a_games, v_a_avg, v_a_score, v_s_ranks, v_a_ranks
    from mine;

  /* ── 各積分級距 ────────────────────────────────
     ⚠ `stake_level_id` 可能是 null（沒設級距的場次）——
       那時 join 不到主檔，`label` 用「未設定」而不是整列消失：
       **場數對不起來比多一行更難查**。
     ⚠ 排序照主檔的 `sort_order`，不要照場數排 ——
       照場數排的話同一個人這週跟下週看到的順序會不一樣。 */
  with mine as (
    select sp.score_points, s.stake_level_id,
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
    select coalesce(sl.label, '未設定')  as label,
           coalesce(sl.sort_order, 9999) as sort_order,
           /* 🎯 勝 = 桌上積分為正。`score_points` 可能是 null
              （已結算但沒登記分數）—— 那時不算贏也不算輸，但**仍然計入場數**，
              因為他確實打了那一場。 */
           count(*) filter (where m.in_season)                        as s_games,
           count(*) filter (where m.in_season and m.score_points > 0) as s_wins,
           count(*)                                                   as a_games,
           count(*) filter (where m.score_points > 0)                 as a_wins
      from mine m
      left join stake_levels sl
             on sl.id = m.stake_level_id and sl.org_id = p_org_id
     group by coalesce(sl.label, '未設定'), coalesce(sl.sort_order, 9999)
  )
  select
    /* ⚠ `filter (where s_games > 0)` 就是「只回打過的」——
         本季沒打過但以前打過的級距只會出現在歷史那一份。 */
    coalesce(jsonb_agg(jsonb_build_object(
      'label', label, 'games', s_games, 'wins', s_wins,
      /* 🔴 **未達門檻回 null，不是回 0 也不是回百分比。**
         回 0 會被讀成「一場都沒贏」；回百分比就是那個「100% · 3 場」的噪音。
         前端拿到 null 就只畫場數。 */
      'pct', case when s_games >= v_min_games
                  then round(s_wins * 100.0 / s_games)::int end
    ) order by sort_order, label) filter (where s_games > 0), '[]'::jsonb),
    coalesce(jsonb_agg(jsonb_build_object(
      'label', label, 'games', a_games, 'wins', a_wins,
      'pct', case when a_games >= v_min_games
                  then round(a_wins * 100.0 / a_games)::int end
    ) order by sort_order, label), '[]'::jsonb)
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

  return jsonb_build_object(
    'ok', true,
    'season_from', v_win,
    /* 🎯 門檻一併回傳 —— 前端才講得出「再 N 場就看得到勝率」，
       而且**不會在前端長出第二個 5**。 */
    'min_games', v_min_games,
    'season', jsonb_build_object(
      'games', coalesce(v_s_games, 0),
      /* ⚠ 沒有場次時 `avg_rank` 回 null 不要回 0 ——
           「平均順位 0」在四人桌是不可能的值，前端會照著印出來。 */
      'avg_rank',  v_s_avg,
      'avg_score', v_s_score,
      'ranks',     coalesce(v_s_ranks, jsonb_build_object('1',0,'2',0,'3',0,'4',0)),
      'national_rank',  v_rank,     -- null = 不在榜上（測試帳號、或本季還沒打過）
      'national_total', coalesce(v_total, 0),
      'stakes', v_s_stk
    ),
    'all', jsonb_build_object(
      'games', coalesce(v_a_games, 0),
      'avg_rank',  v_a_avg,
      'avg_score', v_a_score,
      'ranks',     coalesce(v_a_ranks, jsonb_build_object('1',0,'2',0,'3',0,'4',0)),
      -- 🔴 歷史沒有 national_rank：rating 每季歸零，歷代總排名沒有意義
      'stakes', v_a_stk
    )
  );
end $function$;

comment on function public.get_my_stats_tx(uuid, uuid) is
  '成績頁統計：本季與歷史累積各一份（場數、平均順位、平均得點、名次分布、各級距勝率），全國排名只有本季。勝＝桌上積分 score_points > 0；場數未達 min_games 時 pct 回 null。胡牌率／放槍率／自摸率要等牌譜（M5+），不在這裡。';


-- ── 驗證 ───────────────────────────────────────────────
do $$
declare
  v_org uuid := '11111111-1111-1111-1111-111111111111';
  v_out text := ''; v_store uuid; v_tbl uuid; v_win timestamptz;
  me uuid; me2 uuid; opp uuid; s uuid; i int;
  sl_a uuid; sl_b uuid; v_min int;
  j jsonb; k jsonb;
begin
  begin
    select id into v_store from stores where org_id = v_org limit 1;
    select id into v_tbl   from tables where org_id = v_org limit 1;
    v_win := public.rating_window_start_tx(v_org);
    /* 🔴 期望值當場查，不要憑印象（硬規則 3.56）。 */
    select id into sl_a from stake_levels where org_id = v_org order by sort_order, id limit 1;
    select id into sl_b from stake_levels where org_id = v_org order by sort_order, id offset 1 limit 1;

    v_out := v_out || E'\n' || '① 一個版本 · DEFINER · anon 明確授權' || E'\t' ||
      (select case when count(*) = 1 and bool_and(p.prosecdef)
                    and bool_and(exists (select 1 from aclexplode(p.proacl) a
                          where a.grantee='anon'::regrole::oid and a.privilege_type='EXECUTE'))
                   then '✅ 三項都對'
                   else '🔴 ' || count(*) || ' 個版本' end
         from pg_proc p where p.pronamespace='public'::regnamespace and p.proname='get_my_stats_tx');

    ---- 造：三場，名次 1 / 4 / 2，分數 120 / -80 / 0 ----
    insert into members (org_id, display_name, rating, is_test)
      values (v_org, '測分布', 500, false) returning id into me;
    for i in 1..3 loop
      insert into table_sessions (org_id, store_id, table_id, mode, status, ended_at, stake_level_id)
        values (v_org, v_store, v_tbl, 'private','completed', now(),
                case when i = 3 then sl_b else sl_a end) returning id into s;
      insert into session_players (org_id, session_id, member_id, finish_rank, score_points, settled_at)
        values (v_org, s, me,
                case i when 1 then 1 when 2 then 4 else 2 end,
                case i when 1 then 120 when 2 then -80 else 0 end,
                now());
    end loop;

    j := public.get_my_stats_tx(v_org, me);
    v_min := (j->>'min_games')::int;

    v_out := v_out || E'\n' || '② min_games 有回傳（前端要用它組字）' || E'\t' ||
      case when v_min is not null and v_min > 1 then '✅ ' || v_min
           else '🔴 ' || coalesce(j->>'min_games','(沒有這個鍵)') end;

    /* 🎯 名次 1 / 4 / 2 ⇒ 1 位 1 次、2 位 1 次、3 位 0 次、4 位 1 次。
       ⚠ **「3」那個鍵一定要在而且是 0** —— 沒拿過第 3 名不代表那個鍵可以不見。 */
    v_out := v_out || E'\n' || '③ 🎯 名次分布 {1:1, 2:1, 3:0, 4:1}' || E'\t' ||
      case when (j->'season'->'ranks'->>'1')::int = 1
            and (j->'season'->'ranks'->>'2')::int = 1
            and (j->'season'->'ranks'->>'3')::int = 0
            and (j->'season'->'ranks'->>'4')::int = 1
           then '✅ 1/1/0/1（沒拿過第 3 名 → 鍵在、值是 0）'
           else '🔴 ' || (j->'season'->'ranks')::text end;

    /* 平均得點 = (120 + (−80) + 0) / 3 = 40 / 3 = 13.333… → 13.3
       ⚠ 這個算式寫出來是刻意的（硬規則 3.56）：紅的時候看註解就知道哪一項變了。 */
    v_out := v_out || E'\n' || '④ 平均得點 (120−80+0)/3 = 13.3' || E'\t' ||
      case when (j->'season'->>'avg_score')::numeric = 13.3
           then '✅ 13.3'
           else '🔴 ' || coalesce(j->'season'->>'avg_score','null') end;

    /* 🔴 **樣本數門檻**：級距 A 只有 2 場、級距 B 只有 1 場，
       兩個都 < min_games ⇒ `pct` 必須是 null。 */
    v_out := v_out || E'\n' || '⑤ 🎯 未達門檻的級距 pct 是 null' || E'\t' ||
      (select case when count(*) = 2 and count(*) filter (where x->>'pct' is null) = 2
                   then '✅ 兩個級距（2 場／1 場）的 pct 都是 null'
                   else '🔴 ' || (j->'season'->'stakes')::text end
         from jsonb_array_elements(j->'season'->'stakes') x);

    /* 🔴 **正對照：達門檻就要有百分比。**
       只驗「未達門檻是 null」的話，一支**永遠回 null** 的實作也會讓 ⑤ 變綠。
       用第二個人保持期望值單純：級距 A 五場，四場正分 ⇒ 80%。 */
    insert into members (org_id, display_name, rating, is_test)
      values (v_org, '測門檻', 500, false) returning id into me2;
    for i in 1..5 loop
      insert into table_sessions (org_id, store_id, table_id, mode, status, ended_at, stake_level_id)
        values (v_org, v_store, v_tbl, 'private','completed', now(), sl_a) returning id into s;
      insert into session_players (org_id, session_id, member_id, finish_rank, score_points, settled_at)
        values (v_org, s, me2, 1, case when i = 5 then -50 else 10 end, now());
    end loop;
    j := public.get_my_stats_tx(v_org, me2);
    select x into k from jsonb_array_elements(j->'season'->'stakes') x
      where x->>'label' = (select label from stake_levels where id = sl_a);
    v_out := v_out || E'\n' || '⑥ 🎯 正對照：5 場（= 門檻）4 勝 → 80%' || E'\t' ||
      case when (k->>'games')::int = 5 and (k->>'wins')::int = 4 and (k->>'pct')::int = 80
           then '✅ 5 場 4 勝 80%（永遠回 null 的寫法會在這裡紅）'
           else '🔴 ' || coalesce(k::text,'(找不到這個級距)') end;

    /* 正對照：名次全是 1 ⇒ 分布是 {5,0,0,0}，平均順位 1.0。
       跟 ③ 的 {1,1,0,1} 不一樣才證明它真的在數這個人的名次。 */
    v_out := v_out || E'\n' || '⑦ 正對照：另一個人的分布不一樣' || E'\t' ||
      case when (j->'season'->'ranks'->>'1')::int = 5
            and (j->'season'->'ranks'->>'4')::int = 0
            and (j->'season'->>'avg_rank')::numeric = 1.0
           then '✅ {1:5, 4:0} 平均順位 1.0'
           else '🔴 ' || (j->'season'->'ranks')::text end;

    ---- 本季 vs 歷史（新欄位也要各自算）----------------
    if v_win is not null then
      insert into table_sessions (org_id, store_id, table_id, mode, status, ended_at, stake_level_id)
        values (v_org, v_store, v_tbl, 'private','completed', v_win - interval '10 days', sl_a)
        returning id into s;
      insert into session_players (org_id, session_id, member_id, finish_rank, score_points, settled_at)
        values (v_org, s, me, 3, 300, v_win - interval '10 days');
      j := public.get_my_stats_tx(v_org, me);

      /* 上一季那場是第 3 名 ⇒ 本季的 `"3"` 還是 0、歷史的是 1。
         那一格是這次新欄位有沒有分開算的**唯一**證據。 */
      v_out := v_out || E'\n' || '⑧ 🎯 分布也分本季／歷史' || E'\t' ||
        case when (j->'season'->'ranks'->>'3')::int = 0
              and (j->'all'->'ranks'->>'3')::int = 1
             then '✅ 本季 3 位 0 次／歷史 1 次'
             else '🔴 本季 ' || (j->'season'->'ranks'->>'3')
                  || '／歷史 ' || (j->'all'->'ranks'->>'3') end;

      /* 歷史平均得點 = (120 − 80 + 0 + 300) / 4 = 340 / 4 = 85.0
         本季仍是 13.3 —— 兩個不一樣才證明沒有互相汙染。 */
      v_out := v_out || E'\n' || '⑨ 🎯 平均得點也分開：本季 13.3／歷史 85.0' || E'\t' ||
        case when (j->'season'->>'avg_score')::numeric = 13.3
              and (j->'all'->>'avg_score')::numeric = 85.0
             then '✅ 13.3 / 85.0'
             else '🔴 ' || coalesce(j->'season'->>'avg_score','null')
                  || ' / ' || coalesce(j->'all'->>'avg_score','null') end;
    else
      v_out := v_out || E'\n' || '⑧–⑨ 本季 vs 歷史' || E'\t' || '⚠ 沒有進行中的賽季，跳過';
    end if;

    ---- 沒打過的人 -------------------------------------
    /* ⚠ 空的形狀：`avg_score` 是 null（不是 0 —— 0 分是一個真的成績），
         但 `ranks` 的四個鍵**要在而且是 0**（前端才不用自己補預設值）。 */
    insert into members (org_id, display_name) values (v_org, '測沒打過') returning id into opp;
    j := public.get_my_stats_tx(v_org, opp);
    v_out := v_out || E'\n' || '⑩ 沒打過：avg_score null、ranks 四個鍵都是 0' || E'\t' ||
      case when (j->'season'->>'avg_score') is null
                and (j->'season'->'ranks'->>'1')::int = 0
                and (j->'season'->'ranks'->>'4')::int = 0
                and jsonb_array_length(j->'season'->'stakes') = 0
           then '✅ null / {0,0,0,0} / []'
           else '🔴 ' || (j->'season')::text end;

    raise exception 'migi_rollback';
  exception when others then
    if sqlerrm <> 'migi_rollback' then
      v_out := v_out || E'\n' || '🔴 測試自己炸了' || E'\t' || sqlerrm;
    end if;
    perform set_config('migi.dist', v_out, true);
  end;
end $$;

select split_part(x, E'\t', 1) as 測試,
       split_part(x, E'\t', 2) as 結果
  from unnest(string_to_array(current_setting('migi.dist', true), E'\n')) as x
 where coalesce(x,'') <> '';
