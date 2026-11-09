/* ============================================================
   約 2、3 將卻只打完 1 將就收桌 ⇒ 那 1 將也算段位分（照「約 1 將」的規則）
   2026-11-09 使用者：「這一場約定 2 將但只打了 1 將，1 將應該照算分」
     · 怎麼算：選「照約 1 將算」—— 一般人照 1 將給點；定位賽那一將加倍（+60／+30／+20／+10），
       新客人第 4 名照樣 +10 升銅牌熊 III（10-15 開放配桌 1 將時定的規則，判斷的本來就是「實際打完幾將」）
     · 舊的兩場要不要補：選「兩場都補」——
         11-09 A1（aeb6e45d…，約 2 將打完 1 將：柔柔、1、小張、李彥寬）
         11-06 A1（f9fdbdeb…，約 3 將打完 1 將：Y、米血、Amy、捲毛；米血是人生第一場 ⇒ 定位賽加倍）
   🗑 推翻 10-01／11-06 的「只打完 1 將 ⇒ 有名次、有桌上積分、沒有段位分」

   改三支（函式本體都以 2026-11-09 線上 pg_get_functiondef 為準，只改門檻那幾行）：
   ① apply_session_rounds_tx：擋「一將都沒打完」就好（原本擋「不滿 2 將、而且不是約 1 將」）
   ② _score_settle_tx：同一道門檻
   ③ _push_settle_fields（LINE 牌局結束卡）：拿掉「不計段位分」那句說明，段位分有就印
   ④ 補算：兩場的名次先清掉，再叫 _score_settle_tx 用新規則重跑
      ⚠ 重跑安全：牌局結算通知 on conflict do nothing（一場一人一則）⇒ 不會再推一次 LINE；
        廚師熊的餅乾有冪等鍵；胡牌成就的事件冪等鍵是局的 id ⇒ 都不會重複
   ⚠ 已知取捨：補算的段位分是「今天」加上去的 ⇒ 11-06 那場的 rating_after 是今天的值，
     那幾位的段位走勢圖上 11-06 那一點會跟之後的場次順序對不上（只影響走勢圖的那一個點）
   ============================================================ */

-- ① 段位分
create or replace function public.apply_session_rounds_tx(p_session_id uuid, p_rounds jsonb)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
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
  -- 一將都沒打完才不計（2026-11-09 使用者：約 2、3 將卻只打完 1 將也照算，照約 1 將的規則）
  --   🗑 2026-10-01～11-09 是「不滿 2 將不計（約 1 將除外）」
  if v_rounds < 1 then
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
      -- 只打完 1 將的定位賽加倍（2026-10-15 使用者）：第 4 名照樣 +10，第一場一定升到銅牌熊 III
      --   2026-11-09 起也涵蓋「約 2、3 將卻只打完 1 將」—— 這裡看的本來就是實際打完幾將（v_rounds）
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

-- ② 結算
create or replace function public._score_settle_tx(p_session_id uuid)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_seatmem jsonb; v_hyg boolean; v_payload jsonb := '[]'::jsonb; v_ranks jsonb;
  v_totals jsonb; v_res jsonb; v_rated boolean := false; v_mode text; v_nfin int; v_nhands int;
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

  select coalesce(sl.is_hygiene, false), ts.mode into v_hyg, v_mode
    from table_sessions ts left join stake_levels sl on sl.id = ts.stake_level_id
   where ts.id = p_session_id;

  -- ② 每一將的名次（只算打完的將）—— 給段位分用
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

  -- 整場每個座位的總分：**所有已確認的局都算**（含沒打完那一將、含咔啦碰與分紅）
  --   2026-11-06 使用者：「段位分只顯示打完的將，但積分要照實結算」
  --   🗑 2026-10-01～11-06 是「只算打完的將」，沒打完那一將的局記在計分板上卻不算進桌上積分
  select coalesce(jsonb_object_agg(k, tot), '{}'::jsonb) into v_totals
    from (select e2.key as k, sum(e2.value::int) as tot
            from hands h2, jsonb_each_text(h2.score_delta) e2
           where h2.session_id = p_session_id and h2.status = 'confirmed'
           group by 1) x;

  -- 段位分：打完至少 1 將就算（2026-11-09 使用者：約 2、3 將只打完 1 將也照算，照約 1 將的規則）
  --   🗑 2026-10-01～11-09 是「打完 2 將才算（約 1 將除外）」
  if v_mode is distinct from 'friendly' and v_nfin >= 1 then
    v_res := public.apply_session_rounds_tx(p_session_id, v_payload);
    v_rated := coalesce((v_res ->> 'ok')::boolean, false);
  end if;

  -- ③ 名次與桌上積分：打完 1 將就寫（2026-10-01）。段位分也是打完 1 將就算（上面那段，2026-11-09 起）
  --   整場名次看整場總分；2026-10-22 使用者：同分也並列（rank()，在此之前座位小的在前）
  --   一將都沒打完（v_nfin = 0）照舊不寫：成績不算（2026-11-06 使用者再確認一次）
  if v_nfin >= 1 then
    update session_players sp
       set finish_rank = x.rk,
           final_score = case when v_hyg then null else x.tot end
      from (select g.seat, coalesce((v_totals ->> g.seat::text)::int, 0) as tot,
                   rank() over (order by coalesce((v_totals ->> g.seat::text)::int, 0) desc) as rk
              from generate_series(1, 4) as g(seat)) x
     where sp.session_id = p_session_id and sp.seat = x.seat;
  end if;

  /* 🤝 好友練習賽（2026-10-28）：名次與桌上積分照寫（上面那段），段位分不算（上面那個 if）、成就不發（這裡就回去）。
     場次先不關 —— 手機還要看牌局結束卡，15 分鐘後由 sweep_friendly_tx 收掉 */
  if v_mode = 'friendly' then
    update friendly_games set status = 'finished', ended_at = now(), updated_at = now()
     where session_id = p_session_id and status = 'playing';
    return jsonb_build_object('ok', true, 'rated', false, 'friendly', true, 'rounds_finished', v_nfin,
                              'hands', v_nhands, 'fired', 0, 'hygiene', v_hyg);
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

-- ③ LINE 牌局結束卡：段位分有就印（拿掉那句說明）
create or replace function public._push_settle_fields(p_notif uuid)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'public'
as $function$
declare
  n app_notifications%rowtype;
  v_sid uuid;
  sp record;
  s record;
  v_done int;
  v_others text;
  v_game text;
  v_play text;
  v_end timestamptz;
  v_min int;
begin
  select * into n from app_notifications where id = p_notif;
  if n.id is null or n.type <> 'settle' then return null; end if;
  v_sid := coalesce((n.payload ->> 'session_id')::uuid, n.ref_id);

  select p.finish_rank, p.final_score, p.score_points into sp
    from session_players p
   where p.session_id = v_sid and p.member_id = n.member_id;
  if sp.finish_rank is null then return null; end if;   -- 沒有名次（一將都沒打完）⇒ 不送

  select ts.mode, ts.game_type, ts.flower, ts.planned_rounds,
         coalesce(ts.activated_at, ts.started_at) as began,
         st.name as store, t.label as tbl,
         sl.label as stake, coalesce(sl.is_hygiene, false) as hyg,
         m.display_name as my_name, m.rank as my_rank
    into s
    from table_sessions ts
    left join stores       st on st.id = ts.store_id
    left join tables       t  on t.id  = ts.table_id
    left join stake_levels sl on sl.id = ts.stake_level_id
    left join members      m  on m.id  = n.member_id
   where ts.id = v_sid;

  select count(*) into v_done
    from session_rounds where session_id = v_sid and status = 'finished';
  /* 有名次卻沒有任何逐將紀錄 ⇒ 成績是一次給的（隨機名次），照約定將數算 */
  if v_done = 0 then
    v_done := coalesce(s.planned_rounds, 2);
  end if;

  -- 隱藏的會員名字已經是「隱藏的會員」（隱藏時就換掉了），這裡不用另外判斷
  select string_agg(m.display_name, '、' order by p.seat nulls last) into v_others
    from session_players p join members m on m.id = p.member_id
   where p.session_id = v_sid and p.member_id <> n.member_id;

  -- 玩法：打滿約定將數寫「3 將」；提早收桌寫「3 將（打完 2 將）」；計分桌補上級距，純娛樂不寫（桌上積分那一列已經寫了）
  v_game := concat_ws(' · ', s.game_type, s.flower,
              case when s.planned_rounds is null or v_done >= s.planned_rounds then v_done || ' 將'
                   else s.planned_rounds || ' 將（打完 ' || v_done || ' 將）' end,
              case when not s.hyg and s.stake is not null then '積分 ' || s.stake end);
  -- 🆕 新版的「玩法」一列不帶積分（積分自己一列）
  v_play := concat_ws(' · ', s.game_type, s.flower,
              case when s.planned_rounds is null or v_done >= s.planned_rounds then v_done || ' 將'
                   else s.planned_rounds || ' 將（打完 ' || v_done || ' 將）' end);

  -- 🆕 花費時間：開打（平板定好座位）到最後一局確認。沒有用計分板打的（沒有確認過的局）算不出來 ⇒ 不畫
  select max(h.confirmed_at) into v_end
    from hands h where h.session_id = v_sid and h.status = 'confirmed';
  if s.began is not null and v_end is not null and v_end > s.began then
    v_min := round(extract(epoch from (v_end - s.began)) / 60.0);
  end if;

  return jsonb_build_object(
    'test',    n.payload ->> 'test' = 'true',
    'style',   n.payload ->> 'style',
    'name',    s.my_name,
    'rank_no', sp.finish_rank,
    -- 桌上積分：純娛樂寫「純娛樂」（那一欄是 null 不是 0）
    'score',   case when s.hyg then '純娛樂'
                    when sp.final_score is not null then _push_signed(sp.final_score) end,
    -- 段位分：有就印（2026-11-09 起打完 1 將就算；在此之前未滿 2 將會印一句說明）
    'rating',  case when sp.score_points is not null then _push_signed(sp.score_points) end,
    'rating_short', case when sp.score_points is not null then _push_signed(sp.score_points) end,
    'tier',    s.my_rank,
    'place',   coalesce(s.store, 'MIGI') || coalesce(' · ' || s.tbl || ' 桌', ''),
    'game',    nullif(v_game, ''),
    'others',  v_others,
    -- 🆕 新版細項用的鍵
    'hyg',     s.hyg,
    'store',   coalesce(s.store, 'MIGI'),
    'table',   s.tbl,
    'play',    nullif(v_play, ''),
    'stake_label', s.stake,
    'duration', case when v_min is null then null
                     when v_min >= 60 then (v_min / 60) || ' 小時' || case when v_min % 60 > 0 then ' ' || (v_min % 60) || ' 分' else '' end
                     else v_min || ' 分' end,
    'url',     'https://liff.line.me/2011312117-Zuul0Ndo?tab=stats&settle=' || v_sid)
    /* 🤝 好友練習賽（2026-10-28）：沒有段位分、目前段位、門市、桌號；多一列類型；按鈕連到 App 的好友練習賽頁 */
    || case when s.mode = 'friendly' then jsonb_build_object(
         'friendly', true, 'kind_label', '好友練習賽',
         'rating', null, 'rating_short', null, 'tier', null,
         'store', null, 'table', null, 'place', '好友練習賽',
         'url', 'https://liff.line.me/2011312117-Zuul0Ndo?go=friendly')
       else '{}'::jsonb end;   -- ?tab=stats：App 打開直接到成績頁；settle：還沒評完先開「給同桌評價」
end $function$;

-- ④ 補算兩場：名次先清掉（apply_session_rounds_tx 以「已經有名次」當作已結算），再用新規則重跑結算
update public.session_players set finish_rank = null
 where session_id in ('aeb6e45d-4d78-40b0-b468-b6c4cf7c66f2', 'f9fdbdeb-88ef-4466-8447-89c750c679e4');
select public._score_settle_tx('aeb6e45d-4d78-40b0-b468-b6c4cf7c66f2');
select public._score_settle_tx('f9fdbdeb-88ef-4466-8447-89c750c679e4');

-- ============================================================
-- 驗證（單一 SELECT；不用 raise —— 硬規則 1.8）
-- ============================================================
select concat_ws(E'\n',
  case when (select count(*) from pg_proc where pronamespace = 'public'::regnamespace
              and proname in ('apply_session_rounds_tx', '_score_settle_tx', '_push_settle_fields')) = 3
       then '✅ ① 三支函式各一個版本' else '🔴 ① 函式版本數不對' end,
  case when pg_get_functiondef('public.apply_session_rounds_tx(uuid, jsonb)'::regprocedure) ~ 'if v_rounds < 1 then'
        and pg_get_functiondef('public._score_settle_tx(uuid)'::regprocedure) ~ 'and v_nfin >= 1 then'
       then '✅ ② 兩道門檻都改成「打完 1 將就算」' else '🔴 ② 門檻沒改到' end,
  /* ③ 兩場的四位都有段位分（正對照：在這之前四位都是空的） */
  case when (select count(*) from session_players
              where session_id in ('aeb6e45d-4d78-40b0-b468-b6c4cf7c66f2', 'f9fdbdeb-88ef-4466-8447-89c750c679e4')
                and score_points is not null and rating_after is not null and finish_rank is not null) = 8
       then '✅ ③ 兩場 8 位都有名次與段位分' else '🔴 ③ 有人沒補到' end,
  '④ 11-09 A1：' || coalesce((select string_agg('第' || sp.finish_rank || ' ' || m.display_name || ' 積分 ' || coalesce(sp.final_score::text, '—')
                                                || ' 段位分 ' || coalesce(sp.score_points::text, '—'), '、' order by sp.finish_rank, sp.seat)
                                from session_players sp join members m on m.id = sp.member_id
                               where sp.session_id = 'aeb6e45d-4d78-40b0-b468-b6c4cf7c66f2'), '（找不到）'),
  '⑤ 11-06 A1：' || coalesce((select string_agg('第' || sp.finish_rank || ' ' || m.display_name || ' 積分 ' || coalesce(sp.final_score::text, '—')
                                                || ' 段位分 ' || coalesce(sp.score_points::text, '—'), '、' order by sp.finish_rank, sp.seat)
                                from session_players sp join members m on m.id = sp.member_id
                               where sp.session_id = 'f9fdbdeb-88ef-4466-8447-89c750c679e4'), '（找不到）'),
  /* ⑥ 通知沒有重複：兩場每人仍然只有一則牌局結算通知 */
  case when not exists (select 1 from app_notifications
                         where type = 'settle' and ref_id in ('aeb6e45d-4d78-40b0-b468-b6c4cf7c66f2', 'f9fdbdeb-88ef-4466-8447-89c750c679e4')
                         group by member_id, ref_id having count(*) > 1)
       then '✅ ⑥ 結算通知沒有重複發' else '🔴 ⑥ 有人收到兩則結算通知' end,
  /* ⑥b LINE 不重發：LINE 只在「新增通知」時排進寄件匣（trg_app_notifications_push）。
     跑之前兩場各 4 則通知、4 筆寄送紀錄（2026-11-09 查過）⇒ 跑完必須仍然各 4 筆 */
  case when (select count(*) from notification_deliveries d join app_notifications a on a.id = d.notification_id
              where a.type = 'settle' and a.ref_id = 'aeb6e45d-4d78-40b0-b468-b6c4cf7c66f2') = 4
        and (select count(*) from notification_deliveries d join app_notifications a on a.id = d.notification_id
              where a.type = 'settle' and a.ref_id = 'f9fdbdeb-88ef-4466-8447-89c750c679e4') = 4
       then '✅ ⑥b LINE 沒有重發（兩場寄送紀錄仍然各 4 筆）' else '🔴 ⑥b LINE 寄送紀錄變多了' end,
  /* ⑦ 負對照：一將都沒打完的 10-09 A1 仍然沒有名次、沒有段位分 */
  case when not exists (select 1 from session_players where session_id = '279eba0d-2280-452e-9d12-cf2d6650bf66'
                          and (finish_rank is not null or score_points is not null))
       then '✅ ⑦ 一將都沒打完的 10-09 A1 仍然不算' else '🔴 ⑦ 10-09 A1 被算進去了' end,
  case when pg_get_functiondef('public._push_settle_fields(uuid)'::regprocedure) ~ '''rating'',\s+case when sp\.score_points is not null'
       then '✅ ⑧ LINE 牌局結束卡：段位分有就印' else '🔴 ⑧ LINE 卡片沒改到' end
) as "驗證";
