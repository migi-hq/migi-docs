-- ════════════════════════════════════════════════════════════════════
-- 2026-09-23 電子計分 · 第三批：收桌結算接上真的分數
-- 📄 設計：docs/02-POS與開桌/桌邊記分板設計.md（§8.5）
--
-- 在此之前：收桌時 placeholder_ranks_tx 給隨機名次（上線那天自己失效）。
-- 改成：
--   有電子計分 ⇒ _score_settle_tx 用真的分數產生名次與積分，**隨機名次不跑**
--   沒有      ⇒ 照舊交給 placeholder_ranks_tx（上線後它回 already_live，什麼都不做）
--
-- _score_settle_tx 做的事：
--   ① 收掉還在等確認的那一把（桌都收了，沒有人會再確認）
--   ② 每一將（只算**打完的**）依那一將的分數排名 → 交給既有的 apply_session_rounds_tx
--      （定位賽、降階保護、未滿 2 將不計，全部照既有規則，不另寫一份）
--   ③ 整場名次依總分排、同分座位小的在前；桌上積分寫進 final_score
--      ⚠ 純娛樂照舊寫 null —— get_my_stats_tx 是靠 final_score 為 null 排除純娛樂的
--        （設計文件 §4 那段），這一批不動那個判斷
--   ④ 成就：每一把確認過的 → 胡牌／自摸／牌型／咪幾／連莊（冪等鍵 hand:<id>）
--      🔴 咪幾只認「選牌型」的那一把，直接輸台數的不算 —— 招牌成就不能走捷徑拿
--   ⑤ 放掉四台平板的綁定（下一桌客人拿起來不該看到上一場的人）
-- ════════════════════════════════════════════════════════════════════

create or replace function public._score_settle_tx(p_session_id uuid)
returns jsonb language plpgsql security definer set search_path to 'public'
as $$
declare
  v_seatmem jsonb; v_hyg boolean; v_payload jsonb := '[]'::jsonb; v_ranks jsonb;
  v_totals jsonb; v_res jsonb; v_rated boolean := false; v_nfin int; v_nhands int;
  r record; h record; e record; v_winner uuid; v_idem text; v_fired int := 0;
begin
  -- ⑤ 先放掉平板（就算這桌一把都沒記也要放）
  update session_players set device_id = null
   where session_id = p_session_id and device_id is not null;

  -- ① 還在等確認的那一把：桌都收了，不會有人再確認
  update hands set status = 'undone', undone_at = now()
   where session_id = p_session_id and status = 'pending';

  select count(*) into v_nhands from hands where session_id = p_session_id and status = 'confirmed';
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

  -- ② 每一將的名次（只算打完的將；同分座位小的在前）
  for r in select id from session_rounds
            where session_id = p_session_id and status = 'finished' order by round_no
  loop
    select jsonb_agg(jsonb_build_object('member_id', v_seatmem ->> x.seat::text, 'finish_rank', x.rk) order by x.rk)
      into v_ranks
      from (select g.seat, row_number() over (order by coalesce(t.tot, 0) desc, g.seat) as rk
              from generate_series(1, 4) as g(seat)
              left join (select e2.key::int as seat, sum(e2.value::int) as tot
                           from hands h2, jsonb_each_text(h2.score_delta) e2
                          where h2.round_id = r.id and h2.status = 'confirmed'
                          group by 1) t on t.seat = g.seat) x;
    v_payload := v_payload || jsonb_build_array(v_ranks);
  end loop;
  v_nfin := jsonb_array_length(v_payload);

  -- 整場每個座位的總分（所有確認過的把，包含沒打完的那一將）
  select coalesce(jsonb_object_agg(k, tot), '{}'::jsonb) into v_totals
    from (select e2.key as k, sum(e2.value::int) as tot
            from hands h2, jsonb_each_text(h2.score_delta) e2
           where h2.session_id = p_session_id and h2.status = 'confirmed' group by 1) x;

  -- 段位分：未滿 2 將由 apply_session_rounds_tx 自己擋（too_few_rounds）
  if v_nfin >= 2 then
    v_res := public.apply_session_rounds_tx(p_session_id, v_payload);
    v_rated := coalesce((v_res ->> 'ok')::boolean, false);
  end if;

  -- ③ 名次與桌上積分：只在段位分真的算了才寫（兩者要嘛都有要嘛都沒有，同 placeholder）
  if v_rated then
    update session_players sp
       set finish_rank = x.rk,
           final_score = case when v_hyg then null else x.tot end
      from (select g.seat, coalesce((v_totals ->> g.seat::text)::int, 0) as tot,
                   row_number() over (order by coalesce((v_totals ->> g.seat::text)::int, 0) desc, g.seat) as rk
              from generate_series(1, 4) as g(seat)) x
     where sp.session_id = p_session_id and sp.seat = x.seat;
  end if;

  -- ④ 成就（整段吞例外：名次已經算好了，成就失敗不可以把名次一起回滾）
  begin
    for h in select * from hands where session_id = p_session_id and status = 'confirmed' order by created_at loop
      v_idem := 'hand:' || h.id::text;
      if h.winner_seat is not null then
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
        for e in select distinct sp.achievement_event as ev
                   from jsonb_array_elements(h.patterns) x
                   join scoring_patterns sp on sp.code = x ->> 'code'
                  where sp.achievement_event is not null
        loop
          perform public.fire_event_tx(v_winner, e.ev, 1, null, v_idem);
        end loop;
        -- 🔴 咪幾看**牌型台數**，而且只認選牌型的那一把
        if not h.manual_tai and h.tai_pattern >= 8 then
          perform public.fire_event_tx(v_winner, 'migi_hu', 1, null, v_idem);
        end if;
      end if;
      -- 連莊：這一把開打時莊家已經在連莊
      if h.renzhuang >= 1 then
        perform public.fire_event_tx((v_seatmem ->> h.dealer_seat::text)::uuid, 'renzhuang', 1, null, v_idem);
      end if;
    end loop;
  exception when others then
    null;
  end;

  return jsonb_build_object('ok', true, 'rated', v_rated, 'rounds_finished', v_nfin,
                            'hands', v_nhands, 'fired', v_fired, 'hygiene', v_hyg);
end $$;

revoke execute on function public._score_settle_tx(uuid) from public, anon, authenticated;

-- ── 收桌改成：有電子計分用真的，沒有才用隨機名次 ─────────────────
do $$
declare v_old text; v_new text;
begin
  v_old := pg_get_functiondef('public.settle_session_tx'::regproc);
  if v_old like '%_score_settle_tx%' then
    raise exception 'settle_session_tx 已經接過了，不要重跑這一段';
  end if;
  v_new := replace(v_old, 'v_idem     text;', 'v_idem     text;  v_score    jsonb;   -- 🆕 2026-09-23 電子計分');
  v_new := replace(v_new, '    perform public.placeholder_ranks_tx(p_session_id);',
    '    /* 🆕 2026-09-23：有電子計分就用真的分數；沒有（no_hands）才用隨機名次。 */
    v_score := public._score_settle_tx(p_session_id);
    if not coalesce((v_score ->> ''ok'')::boolean, false) then
      perform public.placeholder_ranks_tx(p_session_id);
    end if;');
  -- 兩處都要換到，少一處就整份回滾
  if v_new = v_old or v_new not like '%v_score    jsonb%' or v_new not like '%_score_settle_tx(p_session_id)%' then
    raise exception 'settle_session_tx 沒有換到預期的兩處，整份回滾';
  end if;
  execute v_new;
end $$;

-- ════════════════════════════════════════════════════════════════════
-- 驗證（單一 SELECT，不 raise —— 硬規則 1.8）
-- 行為在 sql/checks/2026-09-23_驗電子計分的收桌結算.sql（交易內造一整場、最後回滾）
-- ════════════════════════════════════════════════════════════════════
select * from (
  select 1 as n, '① 收桌先試真的分數、失敗才用隨機名次' as 項目,
         case when pg_get_functiondef('public.settle_session_tx'::regproc) ~ '_score_settle_tx\(p_session_id\)'
               and pg_get_functiondef('public.settle_session_tx'::regproc) ~ 'placeholder_ranks_tx\(p_session_id\)'
              then '✅' else '🔴' end as 結果
  union all
  select 2, '② 成就事件仍排在名次之後（session_won 讀 final_score）',
         case when position('_score_settle_tx(p_session_id)' in pg_get_functiondef('public.settle_session_tx'::regproc))
                 < position('''session_won''' in pg_get_functiondef('public.settle_session_tx'::regproc))
              then '✅' else '🔴' end
  union all
  select 3, '③ settle_session_tx 只有一個版本、authenticated 還叫得動',
         case when (select count(*) from pg_proc where proname = 'settle_session_tx') = 1
               and has_function_privilege('authenticated', 'public.settle_session_tx'::regproc, 'execute')
              then '✅' else '🔴' end
  union all
  select 4, '④ _score_settle_tx 前端叫不動（明確 ＋ PUBLIC）',
         case when not exists (select 1 from pg_proc p, aclexplode(p.proacl) a
                                where p.oid = 'public._score_settle_tx'::regproc and a.privilege_type = 'EXECUTE'
                                  and a.grantee in (0, 'anon'::regrole::oid, 'authenticated'::regrole::oid))
              then '✅' else '🔴' end
  union all
  -- 結構性：結算會發的每一個事件，都要有成就在等（不然發了也沒人收）
  select 5, '⑤ 結算會發的事件都有成就在等',
         case when not exists (select 1 from unnest(array['hand_won','hand_tsumo','hand_pattern_any','migi_hu','renzhuang']) ev
                                where not exists (select 1 from achievements a
                                                   where a.deleted_at is null and a.trigger ->> 'event' = ev))
              then '✅' else '🔴' end
) v order by n;
