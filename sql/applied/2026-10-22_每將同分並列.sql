/* ============================================================
   每一將同分就並列（2026-10-22 使用者：「同分就並列」）

   改之前   每一將的名次依那一將的積分排，同分時「座位號小的在前」
            ⇒ 兩人都 +120，坐 1 號拿第 2、坐 3 號拿第 3，段位分差一截
   改之後   同分拿同一個名次，後面跳號（+120、+120、0、−240 ⇒ 1、1、3、4）
            段位分：並列的人**都拿較高那個名次的分數**（使用者同日選的，不取平均）
              低段兩人並列第 1  ⇒ 兩人都 +30
              高段兩人並列第 2  ⇒ 兩人都 +5
              四人全部同分      ⇒ 四人都拿第 1 名的分數
            ⚠ 代價：每次並列，段位分整體會多發一些（使用者知道並同意）
            整場的「第 N 名」（finish_rank）也一樣同分並列（使用者同日拍板）

   改兩支，都是 CREATE OR REPLACE、簽名不變（不用 DROP、不丟 GRANT）：
   ① _score_settle_tx         每一將的名次、整場的名次都改用 rank()（同分同名次），不再拿座位號分高下
   ② apply_session_rounds_tx  名次檢查改成「合法的並列名次」（1,1,3,4 可以；1,2,2,3 不行）；
                              段位分照名次查表 —— 並列的人名次就是較高那個，所以本來就拿較高的分數
   ⚠ placeholder_ranks_tx（上線前的隨機名次）送的是 1–4 各一個，新的檢查照樣接受。
   📄 行為測試：sql/checks/2026-10-22_驗每將同分並列.sql
   ============================================================ */

CREATE OR REPLACE FUNCTION public._score_settle_tx(p_session_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_seatmem jsonb; v_hyg boolean; v_payload jsonb := '[]'::jsonb; v_ranks jsonb;
  v_totals jsonb; v_res jsonb; v_rated boolean := false; v_nfin int; v_nhands int;
  r record; h record; e record; v_winner uuid; v_idem text; v_fired int := 0;
begin
  /* ⑤ 放掉平板：2026-09-29 搬到收桌（settle_session_tx）。結算現在在最後一將打完時自動跑，那時平板還要看牌局結束卡。 */

  /* ① 還在確認中的那一局：桌都收了，不會有人再按。
       已經有人確認 ⇒ 照已確認的部分收尾（那幾份早就入帳了）；一個都沒有 ⇒ 撤銷 */
  update hands set status = case when cardinality(confirmed_seats) > 0 then 'confirmed' else 'undone' end,
                   confirmed_at = case when cardinality(confirmed_seats) > 0 then now() end,
                   undone_at    = case when cardinality(confirmed_seats) > 0 then null else now() end
   where session_id = p_session_id and status = 'pending';

  select count(*) into v_nhands from hands
   where session_id = p_session_id and status = 'confirmed' and result not in ('kala', 'bonus');
  if v_nhands = 0 then
    return jsonb_build_object('ok', false, 'reason', 'no_hands');
  end if;

  select jsonb_object_agg(seat::text, member_id) into v_seatmem
    from session_players where session_id = p_session_id and seat is not null;
  if coalesce((select count(*) from jsonb_object_keys(v_seatmem)), 0) <> 4 then
    return jsonb_build_object('ok', false, 'reason', 'no_seats');
  end if;

  select coalesce(sl.is_hygiene, false) into v_hyg
    from table_sessions ts left join stake_levels sl on sl.id = ts.stake_level_id
   where ts.id = p_session_id;

  -- ② 每一將的名次（只算打完的將）
  --   2026-10-22 使用者：同分就並列 ⇒ 用 rank()，同分拿同一個名次、後面跳號（1,1,3,4）。
  --   在此之前同分由座位號決定先後；並列的人段位分都拿較高那個名次的分數
  for r in select id from session_rounds
            where session_id = p_session_id and status = 'finished' order by round_no
  loop
    select jsonb_agg(jsonb_build_object('member_id', v_seatmem ->> x.seat::text, 'finish_rank', x.rk) order by x.rk, x.seat)
      into v_ranks
      from (select g.seat, rank() over (order by coalesce(t.tot, 0) desc) as rk
              from generate_series(1, 4) as g(seat)
              left join (select e2.key::int as seat, sum(e2.value::int) as tot
                           from hands h2, jsonb_each_text(h2.score_delta) e2
                          where h2.round_id = r.id and h2.status = 'confirmed'
                          group by 1) t on t.seat = g.seat) x;
    v_payload := v_payload || jsonb_build_array(v_ranks);
  end loop;
  v_nfin := jsonb_array_length(v_payload);

  -- 整場每個座位的總分：只算打完的將（含咔啦碰）；沒打完的那一將不算（2026-10-01 使用者拍板）
  select coalesce(jsonb_object_agg(k, tot), '{}'::jsonb) into v_totals
    from (select e2.key as k, sum(e2.value::int) as tot
            from hands h2, jsonb_each_text(h2.score_delta) e2
           where h2.session_id = p_session_id and h2.status = 'confirmed'
             and exists (select 1 from session_rounds rr where rr.id = h2.round_id and rr.status = 'finished')
           group by 1) x;

  -- 段位分：未滿 2 將由 apply_session_rounds_tx 自己擋（too_few_rounds）
  if v_nfin >= 2 or (v_nfin = 1 and (select planned_rounds from table_sessions where id = p_session_id) = 1) then
    v_res := public.apply_session_rounds_tx(p_session_id, v_payload);
    v_rated := coalesce((v_res ->> 'ok')::boolean, false);
  end if;

  -- ③ 名次與桌上積分：打完 1 將就寫（2026-10-01）。段位分仍要 2 將（上面那段），
  --   所以只打完 1 將的場次會「有名次、有桌上積分、沒有段位分」—— 那是拍板的結果，不是寫壞
  --   整場名次看整場總分；2026-10-22 使用者：同分也並列（rank()，在此之前座位小的在前）
  if v_nfin >= 1 then
    update session_players sp
       set finish_rank = x.rk,
           final_score = case when v_hyg then null else x.tot end
      from (select g.seat, coalesce((v_totals ->> g.seat::text)::int, 0) as tot,
                   rank() over (order by coalesce((v_totals ->> g.seat::text)::int, 0) desc) as rk
              from generate_series(1, 4) as g(seat)) x
     where sp.session_id = p_session_id and sp.seat = x.seat;
  end if;

  -- ④ 成就（整段吞例外：名次已經算好了，成就失敗不可以把名次一起回滾）
  begin
    for h in select * from hands where session_id = p_session_id and status = 'confirmed' order by created_at loop
      v_idem := 'hand:' || h.id::text;
      /* 只有胡與自摸算「胡牌」；咔啦碰的收款人、包牌的收款人都不是胡牌 */
      if h.result in ('ron', 'tsumo') then
        v_winner := (v_seatmem ->> h.winner_seat::text)::uuid;
        perform public.fire_event_tx(v_winner, 'hand_won', 1, null, v_idem);
        v_fired := v_fired + 1;
        if h.result = 'tsumo' then
          perform public.fire_event_tx(v_winner, 'hand_tsumo', 1, null, v_idem);
        end if;
        -- 「第一次胡出可計台的牌型」：自摸那 1 台不算牌型
        if exists (select 1 from jsonb_array_elements(h.patterns) x where x ->> 'code' <> 'zimo') then
          perform public.fire_event_tx(v_winner, 'hand_pattern_any', 1, null, v_idem);
        end if;
        /* 每個牌型各自的事件（主檔 achievement_event）。
           MIGI 成就也走這裡：牌型 migi 的事件就是 MIGI 成就聽的那一個（2026-09-25 起，
           不再用「牌型台數加總」判斷） */
        for e in select distinct sp.achievement_event as ev
                   from jsonb_array_elements(h.patterns) x
                   join scoring_patterns sp on sp.code = x ->> 'code'
                  where sp.achievement_event is not null
        loop
          perform public.fire_event_tx(v_winner, e.ev, 1, null, v_idem);
        end loop;
      end if;
      -- 連莊：這一局開打時莊家已經在連莊（咔啦碰不是一局）
      if h.renzhuang >= 1 and h.result not in ('kala', 'bonus') then
        perform public.fire_event_tx((v_seatmem ->> h.dealer_seat::text)::uuid, 'renzhuang', 1, null, v_idem);
      end if;
    end loop;
  exception when others then
    null;
  end;

  return jsonb_build_object('ok', true, 'rated', v_rated, 'rounds_finished', v_nfin,
                            'hands', v_nhands, 'fired', v_fired, 'hygiene', v_hyg);
end $function$;


CREATE OR REPLACE FUNCTION public.apply_session_rounds_tx(p_session_id uuid, p_rounds jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_org uuid; v_rounds int; v_n int; r jsonb; e jsonb;
  v_ids uuid[]; v_ranks int[]; v_sorted int[]; i int; k int;
  v_band text; v_pts int; v_new int; v_floor int; v_prev int;
  v_total jsonb := '{}'::jsonb;   -- member_id → 本場累計得點
begin
  select org_id into v_org from table_sessions
   where id = p_session_id and deleted_at is null;
  if v_org is null then
    return jsonb_build_object('ok', false, 'reason', 'session_not_found');
  end if;

  v_rounds := jsonb_array_length(coalesce(p_rounds, '[]'::jsonb));
  -- 🔴 未滿 2 將不計（決策紀錄 ①，原規格是 1 將）
  if v_rounds < 2 and not (v_rounds = 1 and (select planned_rounds from table_sessions where id = p_session_id) = 1) then
    return jsonb_build_object('ok', false, 'reason', 'too_few_rounds', 'rounds', v_rounds);
  end if;

  -- 冪等：整場只結算一次
  if exists (select 1 from session_players
              where session_id = p_session_id and finish_rank is not null) then
    return jsonb_build_object('ok', false, 'reason', 'already_applied');
  end if;

  for idx in 0 .. v_rounds - 1 loop
    r := p_rounds -> idx;
    select array_agg((x->>'member_id')::uuid order by ord),
           array_agg((x->>'finish_rank')::int order by ord)
      into v_ids, v_ranks
      from jsonb_array_elements(r) with ordinality as t(x, ord);

    v_n := coalesce(array_length(v_ids,1), 0);
    -- 🔴 三人以下不計（決策紀錄 ①）
    if v_n <> 4 then
      return jsonb_build_object('ok', false, 'reason', 'need_four_players',
        'round', idx + 1, 'n', v_n);
    end if;
    if (select count(distinct u) from unnest(v_ids) u) <> v_n then
      return jsonb_build_object('ok', false, 'reason', 'duplicate_member', 'round', idx + 1);
    end if;
    /* 名次要是合法的並列名次（2026-10-22 使用者：同分就並列）：
       由小到大排好之後，第一個是 1，之後每一個不是跟前一個一樣（並列），就是剛好等於它的位置（跳號）。
       ⇒ 1,2,3,4／1,1,3,4／1,2,2,4／1,1,1,1 可以；1,2,2,3、2,2,3,4 不行 */
    select array_agg(x order by x) into v_sorted from unnest(v_ranks) x;
    if v_sorted is null or v_sorted[1] is distinct from 1 then
      return jsonb_build_object('ok', false, 'reason', 'bad_ranks', 'round', idx + 1);
    end if;
    for k in 2 .. v_n loop
      if v_sorted[k] is null or not (v_sorted[k] = v_sorted[k - 1] or v_sorted[k] = k) then
        return jsonb_build_object('ok', false, 'reason', 'bad_ranks', 'round', idx + 1);
      end if;
    end loop;

    for i in 1..v_n loop
      -- 每個人都要真的坐過這一桌
      if not exists (select 1 from session_players
                      where session_id = p_session_id and member_id = v_ids[i]) then
        return jsonb_build_object('ok', false, 'reason', 'not_in_session',
          'member_id', v_ids[i]);
      end if;

      /* 🔴 依**當下**的段位取 band 與該階下限 —— 要在迴圈裡查，不能先撈一次。 */
      select (d ->> 'band'), (d ->> 'tier_min')::int, m.rating
        into v_band, v_floor, v_new
        from members m, lateral (select public.rank_detail_tx(m.rating) as d) x
       where m.id = v_ids[i] and m.org_id = v_org and m.deleted_at is null;
      if v_band is null then
        return jsonb_build_object('ok', false, 'reason', 'member_not_found',
          'member_id', v_ids[i]);
      end if;

      /* ── 🎓 定位賽：人生第一場 ────────────────────────
         使用者 2026-09-01 拍板：第一場用 `+30/+15/+10/+5`，
         **第 4 名也 +5** ⇒ 打完一定會從銅牌熊 IV 升到 III。
         第一次玩的人拿到的不是一個數字，是**一個看得見的升級**。

         🔴 **判準是「有沒有結算過的場次」，不是 `rating_games = 0`。**
           · `rating_games` **每季歸零** ⇒ 會變成每季都送一次定位賽
           · 它是**逐將**遞增的 ⇒ 同一場的第 2 將就不算定位賽了，
             而那會讓「第一場」這個承諾在 2 將制下**只兌現一半**
         ⚠ `finish_rank` 是**整場收尾**才寫的，所以這一場自己的列
           在這個迴圈裡還是 null —— 判斷不會被自己汙染。
         ⚠ 排除 `p_session_id` 是保險：就算日後有人改成逐將寫入，
           這一行仍然成立。 */
      if not exists (select 1 from session_players sp2
                      where sp2.member_id = v_ids[i]
                        and sp2.finish_rank is not null
                        and sp2.session_id <> p_session_id) then
        v_band := 'placement';
      end if;

      /* 並列（2026-10-22 使用者：同分就並列，都拿較高那個名次的分數）：
         並列的人名次本來就是較高那個（rank() 給 1,1,3,4），直接照名次查表即可 */
      select points into v_pts from rank_points
       where band = v_band and place = v_ranks[i];
      -- 只打 1 將的定位賽加倍（2026-10-15 使用者）：第 4 名照樣 +10，第一場一定升到銅牌熊 III
      if v_band = 'placement' and v_rounds = 1 then v_pts := v_pts * 2; end if;

      v_prev := v_new;              -- 這一將加分前的 rating

      v_new := v_new + v_pts;

      /* ── 🛡 低段的降階保護（銅／銀／金**不掉階**）────────
         使用者 2026-08-29 拍板：「銅／銀不降」再**放寬到金牌不降**，
         只有白金以上會掉。

         🔴 **這一條一度在文件裡消失。** 改成「每半年歸零」那一版寫了
           「不需要保護機制」—— 但那句話把**兩種保護混成一種**：
           · 賽季降階保護 → 歸零之後確實不需要（大家都歸零）
           · **平時降階保護 → 跟歸零完全無關，是被誤刪的**
         ⚠ **低段正和 ≠ 不會掉**：銅銀金的第 4 名還是 −20，連輸就會掉階。
           正和只是說「平均會往上」。
         📌 而決策紀錄結尾那句「白金那條線是**平時會掉**的起點」一直都在 ——
           文件自己前後矛盾，是那一句才對。

         🎯 **不需要 `peak_rating`**：規則是「不降階」的話，
           **當前分數本身就記著他到過哪一階**（因為他掉不出去）。
           夾在當前階的下限 → 下次再掉還是那個值，自我維持。
         ⚠ **階內仍然可以降小級**（IV→III→II→I）——
           那正是原始設計說「保護底線 = 金牌 I」的意思，不是完全不動。
         ⚠ `placement` 也夾一次：它沒有負數所以是空操作，
           但**不寫的話這一行就依賴「placement 永遠沒有負數」這個假設**。 */
      if v_band in ('low', 'placement') then
        if v_band = 'low' and v_new < v_floor then
          begin
            perform public.fire_event_tx(v_ids[i], 'rank_protected', 1, null, 'protect:' || p_session_id::text);
          exception when others then null;
          end;
        end if;
        v_new := greatest(v_new, v_floor);
      end if;

      update members
         set rating = v_new, rating_games = rating_games + 1
       where id = v_ids[i];

      /* 🔴 記**實際變動**（`v_new - v_prev`）不是原始點數 `v_pts`。
         降階保護把 rating 夾住時，那一將實際上沒有掉那麼多 ——
         記原始點數的話，畫面上的「段位分」會與段位走勢圖矛盾。
         ⚠ 代價：本場得點會與 rank_points 表對不起來，
           而那正是保護生效的意思。2026-09-06 使用者拍板。 */
      v_total := jsonb_set(v_total, array[v_ids[i]::text],
        to_jsonb(coalesce((v_total ->> v_ids[i]::text)::int, 0) + (v_new - v_prev)));
    end loop;
  end loop;

  /* 整場收尾（2026-09-06 改）：
     · `finish_rank`  = **最後一將**的名次
     · `score_points` = 每一將**實際變動**的加總（夾過降階保護之後）

     🔴 在此之前 finish_rank 是「段位分加總的排名」，那有兩個錯：
       ① 同分時由 `member_id` 字典序決定，一條看不見的規則
       ② 名次與段位分是兩件事 —— 名次來自桌上分數（累積的，
          所以最後一將結束就是整場結果），段位分是每將給點再加總
     ⇒ 現在會出現「第 4 名但段位分是正的」，**那是對的**：
       他前面幾將贏了、最後一將墊底。

     ⚠ 每一將的名次仍然沒有存下來（這一格裝不下），要等牌譜 schema。
     ⚠ `v_ids` / `v_ranks` 在迴圈結束後就是最後一將的值 —— 不用另外記。
     ⚠ 由 _score_settle_tx 呼叫時，這裡寫的 finish_rank 隨即會被整場名次蓋過（那一支的第 ③ 段）。
     ⏳ M4 接上桌上分數之後，`finish_rank` 改成依桌上總分排、
       同分比座位；`score_points` 不變。 */
  for i in 1 .. v_n loop
    update session_players sp
       set finish_rank  = v_ranks[i],
           score_points = coalesce((v_total ->> v_ids[i]::text)::int, 0),
           settled_at   = now(),
           rating_after = (select rating from members where id = v_ids[i])
     where sp.session_id = p_session_id and sp.member_id = v_ids[i];

    update members set rank = public.member_rank_tx(id) where id = v_ids[i];
  end loop;

  return jsonb_build_object('ok', true, 'rounds', v_rounds,
    'result', (select jsonb_agg(jsonb_build_object(
                 'member_id', sp.member_id, 'finish_rank', sp.finish_rank,
                 'score_points', sp.score_points, 'rating_after', sp.rating_after,
                 'rank', m.rank))
                 from session_players sp join members m on m.id = sp.member_id
                where sp.session_id = p_session_id));
end $function$;


/* ── 驗證（單一 SELECT；不用 raise，硬規則 1.8）──
   掃的是「真的拿來算」的寫法，不是註解裡提到的字（硬規則 3.5） */
select n, 項目, case when ok then '✅' else '🔴' end as 結果, 說明 from (
  select 1 as n, '① 每將名次改用 rank()' as 項目,
         pg_get_functiondef('public._score_settle_tx'::regproc) ~ 'rank\(\) over \(order by coalesce\(t\.tot, 0\) desc\)' as ok,
         '同分同名次，不再拿座位號分高下' as 說明
  union all
  select 2, '② 整場名次也改用 rank()',
         pg_get_functiondef('public._score_settle_tx'::regproc) ~ 'rank\(\) over \(order by coalesce\(\(v_totals'
         and pg_get_functiondef('public._score_settle_tx'::regproc) !~ 'row_number\(\) over',
         '整場「第 N 名」同分並列，座位號不再分高下'
  union all
  select 3, '③ 段位分照名次查表（並列拿較高名次的分數）',
         pg_get_functiondef('public.apply_session_rounds_tx'::regproc) ~ 'where band = v_band and place = v_ranks\[i\]',
         '並列的人名次就是較高那個'
  union all
  select 4, '④ 名次檢查接受並列',
         pg_get_functiondef('public.apply_session_rounds_tx'::regproc) ~ 'v_sorted\[k\] = v_sorted\[k - 1\] or v_sorted\[k\] = k',
         '1,1,3,4 可以；1,2,2,3 不行'
  union all
  select 5, '⑤ 兩支都只有一個版本',
         (select count(*) from pg_proc where pronamespace = 'public'::regnamespace
             and proname in ('_score_settle_tx', 'apply_session_rounds_tx')) = 2,
         '沒有長出多載'
  union all
  select 6, '⑥ 權限沒變（前端都叫不到）',
         not has_function_privilege('anon', 'public.apply_session_rounds_tx(uuid,jsonb)', 'EXECUTE')
         and not has_function_privilege('anon', 'public._score_settle_tx(uuid)', 'EXECUTE'),
         'CREATE OR REPLACE 不改授權'
) t order by n;
