/* ============================================================
   成績頁補「每一局」的統計：胡牌率／放槍率／自摸率／最長連莊／單局最大台 · 2026-10-04
   📄 使用者 2026-10-04（App 成績頁截圖）：「為何這些沒顯示，現在有記分板應該能統計了」
     那幾格的註解一直寫「等 M4 的 L0 電子計分（hands）」—— 計分板 9 月底上線之後 hands 已經有每一局，
     只是 _member_stats_core 從來沒去讀它。

   定義（照雀魂、天鳳這類平台的慣例；使用者 2026-10-04 照建議）：
     局        這個人在座、而且已確認的那幾把：胡、自摸、流局、包牌。咔啦碰不是一局（一把牌中途另外收分）
     胡牌      他是胡的那一家（胡或自摸）
     自摸      他自摸
     放槍      他放槍（別人胡、他是放槍的那一家）；包牌不算放槍
     胡牌率 ＝ 胡 ÷ 局　　放槍率 ＝ 放槍 ÷ 局　　自摸率 ＝ 自摸 ÷ 胡（前端算比例、套最少場數門檻）
     單局最大台  他胡的那幾局裡最大的台數 ＝ 牌型台 ＋ 莊台（使用者 2026-10-04：「要含莊台」）
                 莊台照平板上「莊 X 台」同一套規則（migi-table/src/lib/rules.js 的 handDealerTai）：
                   胡（別人放槍）：胡的人或放槍的人是莊家才有；自摸：一律有；莊台 ＝ 1 ＋ 2 × 連莊次數
     最長連莊    他當莊時出現過的最大「連 N」（跟平板上「莊家｜連 N」同一個數字）
   範圍跟這支函式其他統計一樣：已收桌、有名次的場次；本季看 settled_at 有沒有在賽季內。
   純娛樂的場次照算（這幾格講的是打牌，不是積分）。

   ⚠ 改的是線上全文（_member_stats_core，get_my_stats_tx 與他人個人卡都叫它），錨點各自必須剛好出現一次。
     CREATE OR REPLACE、簽名不變 ⇒ 授權不會掉。可重跑（改過就跳過）。
   ⚠ 鍵名用 *_count ／ max_*，不用 `hands` —— 那個字在別的地方是「一局一局的清單」，一個名字一個意思。
   ============================================================ */

do $$
declare
  v_def text; v_new text; v_n int;
  a1 text := 'v_a_scored int; v_a_wins int; v_a_best_score int;';
  b1 text := 'v_a_scored int; v_a_wins int; v_a_best_score int;
  /* ★ 2026-10-04 每一局（電子計分） */
  v_s_hand int; v_s_hu int; v_s_tsumo int; v_s_dealin int; v_s_max_tai int; v_s_max_ren int;
  v_a_hand int; v_a_hu int; v_a_tsumo int; v_a_dealin int;';
  a2 text := '  /* ── 本季全國排名：**改呼叫共用函式**（2026-09-03）';
  b2 text := '  /* ── ★ 每一局（電子計分，2026-10-04）────────────────────
     局只算真的打完一把的（胡、自摸、流局、包牌）；咔啦碰是中途另外收分，不是一局。
     座位號在一場裡代表同一個人（session_players.seat）。 */
  with mine as (
    select sp.session_id, sp.seat,
           (v_win is null or sp.settled_at >= v_win) as in_season
      from session_players sp
      join table_sessions s on s.id = sp.session_id
     where sp.member_id = p_member_id
       and sp.org_id    = p_org_id
       and s.org_id     = p_org_id
       and s.deleted_at is null
       and s.status     = ''completed''
       and sp.finish_rank is not null
       and sp.settled_at  is not null
       and sp.seat is not null
  ), hh as (
    select m.in_season, h.result, h.renzhuang,
           /* 這一局的台數 ＝ 牌型台 ＋ 莊台（跟平板「莊 X 台」同一套：放槍看胡與放槍兩家有沒有莊家，自摸一律有） */
           coalesce(h.tai_pattern, 0)
             + case when h.result = ''tsumo''
                      or (h.result = ''ron'' and (h.winner_seat = h.dealer_seat or h.deal_in_seat = h.dealer_seat))
                    then 1 + 2 * coalesce(h.renzhuang, 0) else 0 end as tai_total,
           coalesce(h.winner_seat = m.seat, false)  as won,
           coalesce(h.deal_in_seat = m.seat, false) as dealt_in,
           coalesce(h.dealer_seat = m.seat, false)  as is_dealer
      from mine m
      join hands h on h.session_id = m.session_id
     where h.status = ''confirmed''
       and h.result in (''tsumo'', ''ron'', ''draw'', ''bao'')
  )
  select count(*) filter (where in_season),
         count(*) filter (where in_season and won and result in (''tsumo'', ''ron'')),
         count(*) filter (where in_season and won and result = ''tsumo''),
         count(*) filter (where in_season and dealt_in and result = ''ron''),
         max(tai_total)   filter (where in_season and won and result in (''tsumo'', ''ron'')),
         max(renzhuang)   filter (where in_season and is_dealer),
         count(*),
         count(*) filter (where won and result in (''tsumo'', ''ron'')),
         count(*) filter (where won and result = ''tsumo''),
         count(*) filter (where dealt_in and result = ''ron'')
    into v_s_hand, v_s_hu, v_s_tsumo, v_s_dealin, v_s_max_tai, v_s_max_ren,
         v_a_hand, v_a_hu, v_a_tsumo, v_a_dealin
    from hh;

  /* ── 本季全國排名：**改呼叫共用函式**（2026-09-03）';
  a3 text := '''streak'',     coalesce(v_s_streak, 0)';
  b3 text := '''streak'',     coalesce(v_s_streak, 0),
      /* 每一局（2026-10-04）：局數、胡、自摸、放槍、單局最大台（含莊台）、最長連莊（null ＝ 沒胡過／沒當過莊） */
      ''hand_count'', coalesce(v_s_hand, 0), ''hu_count'', coalesce(v_s_hu, 0),
      ''tsumo_count'', coalesce(v_s_tsumo, 0), ''deal_in_count'', coalesce(v_s_dealin, 0),
      ''max_tai'', v_s_max_tai, ''max_renzhuang'', v_s_max_ren';
  a4 text := '''best_score'', v_a_best_score';
  b4 text := '''best_score'', v_a_best_score,
      ''hand_count'', coalesce(v_a_hand, 0), ''hu_count'', coalesce(v_a_hu, 0),
      ''tsumo_count'', coalesce(v_a_tsumo, 0), ''deal_in_count'', coalesce(v_a_dealin, 0)';
begin
  v_def := pg_get_functiondef('public._member_stats_core(uuid,uuid)'::regprocedure);
  if position('v_s_hand' in v_def) > 0 then
    return;   -- 已經改過（可重跑）
  end if;
  foreach v_new in array array[a1, a2, a3, a4] loop
    v_n := (length(v_def) - length(replace(v_def, v_new, ''))) / length(v_new);
    if v_n <> 1 then
      raise exception '_member_stats_core 的錨點「%」出現 % 次（要剛好 1 次），整份不執行', left(v_new, 40), v_n;
    end if;
  end loop;
  v_new := replace(replace(replace(replace(v_def, a1, b1), a2, b2), a3, b3), a4, b4);
  execute v_new;
end $$;

/* ── 驗證（單一 SELECT；不用 raise，硬規則 1.8）──
   ③ 正對照：挑一位打過最多局的會員，函式回的生涯局數／胡／自摸／放槍，跟直接數 hands 一樣
     （只驗「鍵有出現」的話，一支永遠回 0 的寫法也會全綠）
   ④ 自摸 ≤ 胡 ≤ 局（三個數字之間的關係，寫錯欄位時最先壞的就是它） */
with
fn as (select count(*) as n from pg_proc where pronamespace = 'public'::regnamespace and proname = '_member_stats_core'),
df as (select pg_get_functiondef('public._member_stats_core(uuid,uuid)'::regprocedure) as d),
pick as (   -- 打過最多已確認局（胡／自摸／流局／包牌）的會員，只算已收桌、有名次的場次
  select sp.org_id, sp.member_id,
         count(*) as hand_n,
         count(*) filter (where h.winner_seat = sp.seat and h.result in ('tsumo','ron')) as hu_n,
         count(*) filter (where h.winner_seat = sp.seat and h.result = 'tsumo') as tsumo_n,
         count(*) filter (where h.deal_in_seat = sp.seat and h.result = 'ron') as dealin_n
    from session_players sp
    join table_sessions s on s.id = sp.session_id
    join hands h on h.session_id = sp.session_id and h.status = 'confirmed' and h.result in ('tsumo','ron','draw','bao')
   where s.status = 'completed' and s.deleted_at is null and sp.finish_rank is not null and sp.settled_at is not null and sp.seat is not null
   group by sp.org_id, sp.member_id
   order by count(*) desc limit 1),
got as (select p.*, public._member_stats_core(p.org_id, p.member_id) -> 'all' as a,
                    public._member_stats_core(p.org_id, p.member_id) -> 'season' as se from pick p),
tai as (   -- 同一位會員本季胡過的局：直接用「牌型台 ＋ 莊台」算最大值，順便數有幾局真的加到莊台
  select max(coalesce(h.tai_pattern, 0)
             + case when h.result = 'tsumo' or (h.result = 'ron' and (h.winner_seat = h.dealer_seat or h.deal_in_seat = h.dealer_seat))
                    then 1 + 2 * coalesce(h.renzhuang, 0) else 0 end) as mx,
         count(*) filter (where h.result = 'tsumo' or h.winner_seat = h.dealer_seat or h.deal_in_seat = h.dealer_seat) as with_dealer
    from pick p
    join session_players sp on sp.member_id = p.member_id and sp.org_id = p.org_id
    join table_sessions s on s.id = sp.session_id
    join hands h on h.session_id = sp.session_id and h.status = 'confirmed' and h.result in ('tsumo','ron') and h.winner_seat = sp.seat
   where s.status = 'completed' and s.deleted_at is null and sp.finish_rank is not null and sp.settled_at is not null
     and (public.rating_window_start_tx(p.org_id) is null or sp.settled_at >= public.rating_window_start_tx(p.org_id)))
select concat_ws(E'\n',
  case when (select n from fn) = 1 then '✅ ① _member_stats_core 版本數 1' else '🔴 ① 版本數 ' || (select n from fn) end,
  case when (select d from df) ~ '''hand_count''' and (select d from df) ~ '''max_tai''' and (select d from df) ~ '''max_renzhuang'''
       then '✅ ② 函式體多了每一局的統計' else '🔴 ② 函式體沒有改到' end,
  coalesce((select case when (a ->> 'hand_count')::int = hand_n and (a ->> 'hu_count')::int = hu_n
                         and (a ->> 'tsumo_count')::int = tsumo_n and (a ->> 'deal_in_count')::int = dealin_n
       then '✅ ③ 打最多局的那位：函式回 局 ' || hand_n || '／胡 ' || hu_n || '／自摸 ' || tsumo_n || '／放槍 ' || dealin_n || '，跟直接數 hands 一樣'
       else '🔴 ③ 對不上：函式 ' || coalesce(a::text, 'null') || '；直接數 局 ' || hand_n || '／胡 ' || hu_n || '／自摸 ' || tsumo_n || '／放槍 ' || dealin_n end
     from got), '⚪ ③ 還沒有人打過「已收桌、有名次」的電子計分局，這一格測不了'),
  coalesce((select case when (a ->> 'tsumo_count')::int <= (a ->> 'hu_count')::int and (a ->> 'hu_count')::int <= (a ->> 'hand_count')::int
       then '✅ ④ 自摸 ≤ 胡 ≤ 局' else '🔴 ④ 三個數字的大小關係不對' end from got), '⚪ ④ 測不了'),
  coalesce((select case
       when t.mx is null then '⚪ ⑤ 那位本季沒胡過，單局最大台測不了'
       when (g.se ->> 'max_tai')::int = t.mx
         then '✅ ⑤ 單局最大台 ' || t.mx || ' 台，跟直接算「牌型台＋莊台」一樣（本季胡的局裡 ' || t.with_dealer || ' 局有莊台）'
       else '🔴 ⑤ 單局最大台：函式 ' || coalesce(g.se ->> 'max_tai', 'null') || '，直接算 ' || t.mx end
     from got g, tai t), '⚪ ⑤ 測不了')
) as "驗證";
