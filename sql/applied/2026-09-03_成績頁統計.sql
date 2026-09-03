/* ============================================================
   成績頁：本季／歷史累積 的平均順位・全國排名・各積分級距勝率
   2026-09-03 · MIGI

   ── 這一支要回答的三件事 ────────────────────────────
   ① **平均順位** —— `session_players.finish_rank` 的平均
   ② **全國排名** —— 本季在這個 org 排第幾
   ③ **各積分級距勝率** —— 依 `stake_levels` 分組

   而且**同時回本季與歷史累積兩份**（畫面上那顆「查看歷史累積數據」）。

   🔴 **胡牌率與放槍率不在這裡，而且今天做不出來。**
     不是「難做」是**資料完全不存在** —— 2026-09-03 掃過
     `information_schema.tables`，符合 `hand|round|tile|replay|discard|win|record`
     的表**一張都沒有**。那兩個數字要等牌譜辨識（M5+）。
     ⚠ 所以前端那兩格會是 `—`。**不要為了讓四格看起來完整而估算它們** ——
       一個編出來的「放槍率 11.2%」跟旁邊一個真的平均順位並排，
       客人分不出哪個是真的，而那比兩個都假更糟。

   ── 🎯 為什麼是後端算不是前端算 ──────────────────────
   `get_my_games_tx` 有 `p_limit`（預設 20）。前端拿前 N 筆自己加總的話，
   **打超過 N 場的人統計會是錯的，而且畫面上看不出來** ——
   同 CLAUDE.md 待辦 1 的「累積消費」那個教訓：
   **分頁的清單前 N 筆加總不是總額。**

   ── 🎯 為什麼本季與歷史在同一支、同一次掃描 ──────────
   分成兩支（或同一支跑兩次）就會有**兩份「勝」的定義**，
   而它們一定會在某次調整時只改到一邊 —— 那是這個專案一再踩的病
   （`TIER_LABEL`、大師熊的 20 位、分類前綴⋯）。
   ✅ 這裡用 `filter (where in_season)`：**一次掃描、一份定義、兩組數字**。

   ── 「勝」的定義（2026-09-03 使用者拍板）─────────────
   ```
   勝 = session_players.score_points > 0        ← 桌上積分為正
   ```
   🔴 **是桌上積分不是 MIGI 段位積分。** 那是兩個不同的東西：
     · `score_points`  這一場在桌上贏了多少（可正可負）
     · `rating_after`  打完之後的段位積分（＝ MIGI 積分）
     拿 rating 來判斷「贏」會變成「只要沒掉段就算贏」，意思完全不同。
   ⚠ `> 0` 不是 `>= 0` —— 剛好打平不是贏。
   ⚠ 期望值約 50%（不是四人桌的 25%）—— 這是刻意的：
     台灣麻將講輸贏通常是講錢，「今天有沒有賺」比「有沒有拿第一」貼近直覺。

   ── 級距只回打過的（2026-09-03 使用者拍板）──────────
   主檔有 **7 個**（`300/100 200/50 100/20 50/20 30/10 10/10 純娛樂`），
   全部畫出來的話新客人會看到七行 0。
   ⚠ 所以回傳的長度**隨人而異**，前端不可以假設有幾行。
   ⚠ 本季與歷史的長度也**不一樣**（本季沒打過但以前打過的，只出現在歷史那份）。

   ── 全國排名的母體（只有本季有）──────────────────
   ```
   本季至少打過一場「已結算」牌局　且　members.is_test = false
   ```
   🔴 **不能拿全部會員排** —— `members.rating` 是 `NOT NULL DEFAULT 0`，
     每一個沒打過牌的人都有 0 分。那樣排出來的分母是「開過帳號的人數」，
     而畫面上寫的是「全國排名」。
   🔴 **歷史累積刻意沒有全國排名** —— `rating` 每季歸零（換季降 2 個段位），
     所以「歷代總排名」在這個制度下沒有意義。
     歷史那一格改放**打了幾場**（沿用排行榜卡片上同一個詞）。
   ⚠ **測試帳號自己不會有名次**（回 null → 前端顯示 `—`）。
     今天所有帳號都是 `is_test`，所以這一格現在一定是 `—` ——
     **那是對的**，不是壞了。上線後標記一拿掉它就自己會有數字。

   ── 本季怎麼算 ────────────────────────────────
   用既有的 `rating_window_start_tx(org)`，**不要再寫第二份「本季」**
   （CLAUDE.md 記過三次「一個名字兩種意思」的病）。
   ⚠ 它可能回 null（一季都還沒建）→ 那時**本季＝全部**，兩份會一樣。
     「忘記建下一季」不該讓所有人的統計變成空的。
   ============================================================ */

create or replace function public.get_my_stats_tx(
  p_org_id    uuid,
  p_member_id uuid
) returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $function$
declare
  v_win     timestamptz;
  v_s_games int; v_s_avg numeric;
  v_a_games int; v_a_avg numeric;
  v_rank    int; v_total int;
  v_s_stk   jsonb; v_a_stk jsonb;
begin
  v_win := public.rating_window_start_tx(p_org_id);

  /* ── 一次掃描，兩組數字 ──────────────────────────
     「已結算」＝ 有名次而且有結算時間。兩個都要：
     `finish_rank` 有值但 `settled_at` 是 null 的列在時間視窗裡會被漏掉，
     而那種列在資料庫裡是可能存在的（名次可以先登記）。 */
  with mine as (
    select sp.finish_rank, sp.score_points, s.stake_level_id,
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
         round(avg(finish_rank), 1)
    into v_s_games, v_s_avg, v_a_games, v_a_avg
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
           count(*) filter (where m.in_season)                            as s_games,
           count(*) filter (where m.in_season and m.score_points > 0)     as s_wins,
           count(*)                                                       as a_games,
           count(*) filter (where m.score_points > 0)                     as a_wins
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
      /* 百分比在後端算完再回，前端不要自己除 ——
         那會變成第二份四捨五入規則。 */
      'pct', round(s_wins * 100.0 / nullif(s_games, 0))::int
    ) order by sort_order, label) filter (where s_games > 0), '[]'::jsonb),
    coalesce(jsonb_agg(jsonb_build_object(
      'label', label, 'games', a_games, 'wins', a_wins,
      'pct', round(a_wins * 100.0 / nullif(a_games, 0))::int
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
    'season', jsonb_build_object(
      'games', coalesce(v_s_games, 0),
      /* ⚠ 沒有場次時 `avg_rank` 回 null 不要回 0 ——
           「平均順位 0」在四人桌是不可能的值，前端會照著印出來。 */
      'avg_rank', v_s_avg,
      'national_rank',  v_rank,     -- null = 不在榜上（測試帳號、或本季還沒打過）
      'national_total', coalesce(v_total, 0),
      'stakes', v_s_stk
    ),
    'all', jsonb_build_object(
      'games', coalesce(v_a_games, 0),
      'avg_rank', v_a_avg,
      -- 🔴 歷史沒有 national_rank，見檔頭：rating 每季歸零
      'stakes', v_a_stk
    )
  );
end $function$;

comment on function public.get_my_stats_tx(uuid, uuid) is
  '成績頁統計：本季與歷史累積各一份（場數、平均順位、各級距勝率），全國排名只有本季。勝＝桌上積分 score_points > 0。胡牌率／放槍率要等牌譜（M5+），不在這裡。';


-- ── 驗證 ───────────────────────────────────────────────
do $$
declare
  v_org uuid := '11111111-1111-1111-1111-111111111111';
  v_out text := ''; v_store uuid; v_tbl uuid; v_win timestamptz;
  me uuid; opp uuid; s uuid;
  sl_a uuid; sl_b uuid; sl_c uuid; n_all int;
  j jsonb; k jsonb;
begin
  begin
    select id into v_store from stores  where org_id = v_org limit 1;
    select id into v_tbl   from tables  where org_id = v_org limit 1;
    v_win := public.rating_window_start_tx(v_org);
    /* 🔴 期望值當場查，不要憑印象（硬規則 3.56 —— 9/1 一天錯四次都是這一類）。 */
    select count(*) into n_all from stake_levels where org_id = v_org;
    select id into sl_a from stake_levels where org_id = v_org order by sort_order, id limit 1;
    select id into sl_b from stake_levels where org_id = v_org order by sort_order, id offset 1 limit 1;
    select id into sl_c from stake_levels where org_id = v_org order by sort_order, id offset 2 limit 1;

    v_out := v_out || E'\n' || '① 函式存在且是 DEFINER' || E'\t' ||
      (select case when count(*) = 1 and bool_and(prosecdef)
                   then '✅ 一個版本、SECURITY DEFINER'
                   else '🔴 ' || count(*) || ' 個版本' end
         from pg_proc where pronamespace='public'::regnamespace and proname='get_my_stats_tx');

    /* 🔴 新建的函式吃 default privileges ⇒ 一建立就**明確**授權給 anon（硬規則 2.6b）。
       這一支**本來就該讓前端叫**，所以這裡驗的是「它在」，不是「它被收掉了」。
       ⚠ 用 aclexplode 不用 has_function_privilege —— 後者分不出
         「明確授權」與「從 PUBLIC 繼承」（硬規則 2.6）。 */
    v_out := v_out || E'\n' || '② anon 明確授權（前端要叫它）' || E'\t' ||
      (select case when exists (select 1 from aclexplode(p.proacl) a
                                 where a.grantee='anon'::regrole::oid and a.privilege_type='EXECUTE')
                   then '✅ 有' else '🔴 沒有 —— 前端會 permission denied' end
         from pg_proc p where p.pronamespace='public'::regnamespace and p.proname='get_my_stats_tx');

    ---- 造資料：一個非測試會員，本季三場 -----------------
    insert into members (org_id, display_name, rating, is_test)
      values (v_org, '測統計', 500, false) returning id into me;

    -- 級距 A：一場正分（贏）、一場負分（不算贏）
    insert into table_sessions (org_id, store_id, table_id, mode, status, ended_at, stake_level_id)
      values (v_org, v_store, v_tbl, 'private','completed', now(), sl_a) returning id into s;
    insert into session_players (org_id, session_id, member_id, finish_rank, score_points, settled_at)
      values (v_org, s, me, 1, 120, now());
    insert into table_sessions (org_id, store_id, table_id, mode, status, ended_at, stake_level_id)
      values (v_org, v_store, v_tbl, 'private','completed', now(), sl_a) returning id into s;
    insert into session_players (org_id, session_id, member_id, finish_rank, score_points, settled_at)
      values (v_org, s, me, 4, -80, now());
    -- 級距 B：一場剛好 0 分（🔴 平手不算贏）
    insert into table_sessions (org_id, store_id, table_id, mode, status, ended_at, stake_level_id)
      values (v_org, v_store, v_tbl, 'private','completed', now(), sl_b) returning id into s;
    insert into session_players (org_id, session_id, member_id, finish_rank, score_points, settled_at)
      values (v_org, s, me, 2, 0, now());

    j := public.get_my_stats_tx(v_org, me);

    v_out := v_out || E'\n' || '③ 本季：3 場、平均順位 (1+4+2)/3 = 2.3' || E'\t' ||
      case when (j->'season'->>'games')::int = 3 and (j->'season'->>'avg_rank')::numeric = 2.3
           then '✅ games=3 avg_rank=2.3'
           else '🔴 games=' || (j->'season'->>'games') || ' avg_rank=' || coalesce(j->'season'->>'avg_rank','null') end;

    /* 🎯 **只回打過的級距**。正對照：主檔有 n_all 個，這個人只打過 2 個。
       只驗「等於 2」的話，一支「永遠只回 2 個」的爛實作也會過 ——
       所以同時把主檔數量印出來，兩個數字要不一樣才有意義。 */
    v_out := v_out || E'\n' || '④ 🎯 級距只回打過的（主檔 ' || n_all || ' 個）' || E'\t' ||
      case when jsonb_array_length(j->'season'->'stakes') = 2 and n_all > 2
           then '✅ 回 2 個（主檔 ' || n_all || ' 個，沒打過的沒出現）'
           else '🔴 回 ' || jsonb_array_length(j->'season'->'stakes') || ' 個 / 主檔 ' || n_all || ' 個' end;

    ---- 勝的定義 ---------------------------------------
    select x into k from jsonb_array_elements(j->'season'->'stakes') x
      where x->>'label' = (select label from stake_levels where id = sl_a);
    v_out := v_out || E'\n' || '⑤ 級距 A：2 場 1 勝（負分不算贏）' || E'\t' ||
      case when (k->>'games')::int = 2 and (k->>'wins')::int = 1 and (k->>'pct')::int = 50
           then '✅ 2 場 1 勝 50%'
           else '🔴 ' || coalesce(k::text,'(找不到這個級距)') end;

    /* 🔴 **正對照：剛好 0 分不算贏。** 只驗「負分不算贏」的話，
       一個寫成 `>= 0` 的實作也會讓 ⑤ 變綠。 */
    select x into k from jsonb_array_elements(j->'season'->'stakes') x
      where x->>'label' = (select label from stake_levels where id = sl_b);
    v_out := v_out || E'\n' || '⑥ 🎯 正對照：剛好 0 分不算贏' || E'\t' ||
      case when (k->>'games')::int = 1 and (k->>'wins')::int = 0
           then '✅ 1 場 0 勝（>= 0 的寫法會在這裡紅）'
           else '🔴 ' || coalesce(k::text,'(找不到這個級距)') end;

    ---- 全國排名 ---------------------------------------
    v_out := v_out || E'\n' || '⑦ 非測試會員有名次、分母 ≥ 1' || E'\t' ||
      case when (j->'season'->>'national_rank') is not null and (j->'season'->>'national_total')::int >= 1
           then '✅ 第 ' || (j->'season'->>'national_rank') || ' / ' || (j->'season'->>'national_total') || ' 名'
           else '🔴 rank=' || coalesce(j->'season'->>'national_rank','null')
                || ' total=' || coalesce(j->'season'->>'national_total','null') end;

    /* 🔴 **正對照：把同一個人標成測試帳號，名次要消失。**
       只驗「有名次」的話，一支根本沒過濾 is_test 的實作也會讓 ⑦ 變綠 ——
       而那正是今天最容易寫錯的地方（所有帳號都是 is_test）。 */
    update members set is_test = true where id = me;
    j := public.get_my_stats_tx(v_org, me);
    v_out := v_out || E'\n' || '⑧ 🎯 正對照：測試帳號沒有名次' || E'\t' ||
      case when (j->'season'->>'national_rank') is null
           then '✅ null（前端顯示 —）'
           else '🔴 竟然還有名次 ' || (j->'season'->>'national_rank') || ' —— is_test 沒過濾到' end;
    update members set is_test = false where id = me;

    ---- 🎯 本季 vs 歷史累積 -----------------------------
    /* 🔴 這一段是這次新加的重點：塞一場**上一季**的（用第三個級距，
       本季完全沒打過），本季那份不可以動，歷史那份要多一場而且多一個級距。
       ⚠ 一季都還沒建時 `v_win` 是 null（那時本季＝全部）——
         那種情況下這一格不成立，所以要先判斷。 */
    if v_win is not null then
      insert into table_sessions (org_id, store_id, table_id, mode, status, ended_at, stake_level_id)
        values (v_org, v_store, v_tbl, 'private','completed', v_win - interval '10 days', sl_c)
        returning id into s;
      insert into session_players (org_id, session_id, member_id, finish_rank, score_points, settled_at)
        values (v_org, s, me, 1, 999, v_win - interval '10 days');
      j := public.get_my_stats_tx(v_org, me);

      v_out := v_out || E'\n' || '⑨ 🎯 上一季那場：本季不算、歷史要算' || E'\t' ||
        case when (j->'season'->>'games')::int = 3 and (j->'all'->>'games')::int = 4
             then '✅ 本季 3 場／歷史 4 場（本季起點 '
                  || to_char(v_win at time zone 'Asia/Taipei','YYYY/MM/DD') || '）'
             else '🔴 本季 ' || (j->'season'->>'games') || ' 場／歷史 ' || (j->'all'->>'games') || ' 場' end;

      /* 🔴 **正對照：級距數也要不一樣。** 只驗場數的話，
         一支「歷史直接複製本季」的實作在場數上也可能剛好對。 */
      v_out := v_out || E'\n' || '⑩ 🎯 本季 2 個級距／歷史 3 個' || E'\t' ||
        case when jsonb_array_length(j->'season'->'stakes') = 2
              and jsonb_array_length(j->'all'->'stakes') = 3
             then '✅ 2 / 3（本季沒打過的級距只出現在歷史那份）'
             else '🔴 本季 ' || jsonb_array_length(j->'season'->'stakes')
                  || ' / 歷史 ' || jsonb_array_length(j->'all'->'stakes') end;

      v_out := v_out || E'\n' || '⑪ 歷史平均順位 (1+4+2+1)/4 = 2.0' || E'\t' ||
        case when (j->'all'->>'avg_rank')::numeric = 2.0
             then '✅ 2.0（跟本季的 2.3 不同，證明兩份是分開算的）'
             else '🔴 ' || coalesce(j->'all'->>'avg_rank','null') end;

      v_out := v_out || E'\n' || '⑫ 歷史那份沒有 national_rank' || E'\t' ||
        case when not (j->'all' ? 'national_rank')
             then '✅ 沒有這個鍵（rating 每季歸零，歷代總排名沒有意義）'
             else '🔴 竟然有 —— 那個數字會是錯的' end;
    else
      v_out := v_out || E'\n' || '⑨–⑫ 本季 vs 歷史' || E'\t' || '⚠ 這個 org 沒有進行中的賽季，跳過（此時本季＝全部）';
    end if;

    ---- 沒打過的人 -------------------------------------
    /* ⚠ 空的形狀也要驗：`avg_rank` 必須是 null 不是 0
         —— 四人桌不可能有「平均順位 0」，而前端會照著印。 */
    insert into members (org_id, display_name) values (v_org, '測沒打過') returning id into opp;
    j := public.get_my_stats_tx(v_org, opp);
    v_out := v_out || E'\n' || '⑬ 沒打過的人：兩份都是 0 / null / []' || E'\t' ||
      case when (j->'season'->>'games')::int = 0 and (j->'season'->>'avg_rank') is null
                and jsonb_array_length(j->'season'->'stakes') = 0
                and (j->'all'->>'games')::int = 0 and (j->'all'->>'avg_rank') is null
                and jsonb_array_length(j->'all'->'stakes') = 0
           then '✅ 0 / null / []'
           else '🔴 ' || j::text end;

    raise exception 'migi_rollback';
  exception when others then
    if sqlerrm <> 'migi_rollback' then
      v_out := v_out || E'\n' || '🔴 測試自己炸了' || E'\t' || sqlerrm;
    end if;
    perform set_config('migi.stats', v_out, true);
  end;
end $$;

select split_part(x, E'\t', 1) as 測試,
       split_part(x, E'\t', 2) as 結果
  from unnest(string_to_array(current_setting('migi.stats', true), E'\n')) as x
 where coalesce(x,'') <> '';
