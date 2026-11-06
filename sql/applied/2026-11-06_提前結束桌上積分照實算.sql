/* ============================================================
   2026-11-06 · 提前結束（沒打完約定將數就收桌）：桌上積分照實算，段位分仍只算打完的將
     使用者：「提前結束沒有把第二將的算進去」→「段位分只顯示打完的將，但積分要照實結算」
     例：11-06 18:05 A1（Y、米血、Amy、捲毛）約 3 將，第 1 將打完（25 局）、第 2 將打到南風圈（15 局）就收桌，
         原本桌上積分只加第 1 將那 25 局

   ── 規則（取代 2026-10-01「只結算打完的將」的桌上積分那一半）──
   桌上積分  加總這一場所有已確認的局（含沒打完那一將、含咔啦碰與分紅）
   整場名次  照整場桌上積分排（同分並列，rank()）
   段位分    不變：只用打完的將的名次算（apply_session_rounds_tx 吃的 payload 只有打完的將）
   一將都沒打完  不變：沒有名次、沒有桌上積分、成績不算（使用者同日選「維持成績不算」）

   ── 這份做兩件事 ──
   ① 重建 _score_settle_tx（照 2026-11-06 線上全文，只改「整場每個座位的總分」那一段，其餘一個字不動）
   ② 回填：已收桌、打完至少 1 將、而沒打完那一將有記局的 5 場，重算桌上積分與名次（使用者同日選「重算這 5 場」）
      11-06 A1、10-31 A2、10-23 A1、10-18 A1、10-16 A1
      · 段位分不動（rating_after、score_points、members.rating 都不碰）
      · 名次本來就有值 ⇒ 結算通知與廚師熊的觸發器（只在名次從空變有值時動作）不會再跑
   ============================================================ */

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

  -- 段位分：未滿 2 將由 apply_session_rounds_tx 自己擋（too_few_rounds）
  if v_mode is distinct from 'friendly' and (v_nfin >= 2 or (v_nfin = 1 and (select planned_rounds from table_sessions where id = p_session_id) = 1)) then
    v_res := public.apply_session_rounds_tx(p_session_id, v_payload);
    v_rated := coalesce((v_res ->> 'ok')::boolean, false);
  end if;

  -- ③ 名次與桌上積分：打完 1 將就寫（2026-10-01）。段位分仍要 2 將（上面那段），
  --   所以只打完 1 將的場次會「有名次、有桌上積分、沒有段位分」—— 那是拍板的結果，不是寫壞
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

/* ② 回填那 5 場：同上面的算法（所有已確認的局加總、rank() 排名次、純娛樂寫 null），段位分不碰 */
with target as (
  select ts.id, coalesce(sl.is_hygiene, false) as hyg
    from table_sessions ts left join stake_levels sl on sl.id = ts.stake_level_id
   where ts.status = 'completed' and ts.deleted_at is null
     and exists (select 1 from session_rounds r where r.session_id = ts.id and r.status = 'finished')
     and exists (select 1 from hands h join session_rounds r on r.id = h.round_id
                  where h.session_id = ts.id and h.status = 'confirmed' and h.undone_at is null and r.status <> 'finished')
), tot as (
  select t.id as sid, t.hyg, g.seat,
         coalesce((select sum(e2.value::int) from hands h2, jsonb_each_text(h2.score_delta) e2
                    where h2.session_id = t.id and h2.status = 'confirmed' and e2.key::int = g.seat), 0) as tot
    from target t cross join generate_series(1, 4) as g(seat)
), ranked as (
  select sid, hyg, seat, tot, rank() over (partition by sid order by tot desc) as rk from tot
)
update session_players sp
   set finish_rank = r.rk, final_score = case when r.hyg then null else r.tot end
  from ranked r
 where sp.session_id = r.sid and sp.seat = r.seat;

/* ── 驗證（單一 SELECT）── */
select concat_ws(E'\n',
  case when (select count(*) from pg_proc where pronamespace = 'public'::regnamespace and proname = '_score_settle_tx') = 1
       then '✅ ① _score_settle_tx 只有一個版本' else '🔴 ① _score_settle_tx 版本數不對' end,
  /* 每一場「已收桌、有名次」的：桌上積分要等於所有已確認局的加總（純娛樂除外）—— 包含這次回填的 5 場 */
  coalesce((
    select case when count(*) filter (where bad) = 0
                then '✅ ② 有名次的已收桌場次 ' || count(distinct sid) || ' 場，桌上積分都等於所有局的加總（含沒打完那一將）'
                else '🔴 ② ' || count(distinct sid) filter (where bad) || ' 場對不上' end
      from (select sp.session_id as sid,
                   sp.final_score is distinct from coalesce((select sum(e2.value::int) from hands h2, jsonb_each_text(h2.score_delta) e2
                                                              where h2.session_id = sp.session_id and h2.status = 'confirmed' and e2.key::int = sp.seat), 0) as bad
              from session_players sp join table_sessions ts on ts.id = sp.session_id
              left join stake_levels sl on sl.id = ts.stake_level_id
             where ts.status = 'completed' and sp.finish_rank is not null and sp.seat is not null
               and not coalesce(sl.is_hygiene, false)
               and exists (select 1 from hands h where h.session_id = ts.id and h.status = 'confirmed')) z), '⚪ ② 沒有樣本'),
  /* 11-06 A1 那一場（Y、米血、Amy、捲毛）重算後的結果，給人看 */
  '③ 11-06 A1 重算後：' || coalesce((
    select string_agg('第' || sp.finish_rank || ' ' || m.display_name || ' ' || sp.final_score, '、' order by sp.finish_rank, sp.seat)
      from session_players sp join members m on m.id = sp.member_id
     where sp.session_id = 'f9fdbdeb-88ef-4466-8447-89c750c679e4'), '（找不到）'),
  /* 段位分沒被動到：那一場只打完 1 將，段位分本來就是空的 */
  case when not exists (select 1 from session_players where session_id = 'f9fdbdeb-88ef-4466-8447-89c750c679e4' and (score_points is not null or rating_after is not null))
       then '✅ ④ 11-06 A1 段位分仍然是空的（只打完 1 將，照規則不算）' else '🔴 ④ 11-06 A1 段位分被動到了' end,
  /* 一將都沒打完的 10-09 A1：仍然沒有名次 */
  case when not exists (select 1 from session_players where session_id = '279eba0d-2280-452e-9d12-cf2d6650bf66' and finish_rank is not null)
       then '✅ ⑤ 10-09 A1（一將都沒打完）仍然沒有名次' else '🔴 ⑤ 10-09 A1 被寫了名次' end
) as "驗證";
