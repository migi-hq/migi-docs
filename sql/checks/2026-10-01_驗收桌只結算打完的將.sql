/* ============================================================
   驗：收桌只結算打完的將（行為測試）· 2026-10-01
   搭配 sql/pending/2026-10-01_收桌只結算打完的將.sql，**先跑那一份再跑這一份**。
   ⚠ 故意不提交：自己造三場、各自收桌，最後 raise 'migi_rollback' 全部退掉（訊息寫在 handler 裡）。

   三場（同一張空的測試桌輪流用、同四位測試會員，座位 1–4）：
     甲  第 1 將打完 {1:+30, 2:−30}、第 2 將打完 {3:+40, 4:−40}、第 3 將打一半 {1:+100, 2:−100}
     乙  第 1 將打完 {1:+20, 2:−20}、第 2 將打一半 {3:+50, 4:−50}
     丙  第 1 將打一半 {1:+10, 2:−10}
   ============================================================ */
do $$
declare
  v_msg text := ''; v_pass int := 0; v_total int := 0;
  v_org uuid; v_store uuid; v_table uuid; m uuid[];
  v_sess uuid; v_r1 uuid; v_r2 uuid; v_r3 uuid; v_res jsonb;
  v_fs text; v_rk text; v_ra int; v_n int; v_ok boolean;
begin
  select t.org_id, t.store_id, t.id into v_org, v_store, v_table
    from tables t join stores s on s.id = t.store_id
   where s.is_test and t.deleted_at is null
     and not exists (select 1 from table_sessions ts where ts.table_id = t.id and ts.status = 'open' and ts.deleted_at is null)
   order by t.label limit 1;
  select array_agg(x.id order by x.created_at) into m
    from (select mm.id, mm.created_at from members mm
           where mm.is_test and mm.deleted_at is null and mm.hidden_at is null
           order by mm.created_at limit 4) x;
  if v_table is null or coalesce(cardinality(m), 0) < 4 then
    v_msg := '🔴 找不到樣本（空的測試桌或四位測試會員）';
    raise exception 'migi_rollback';
  end if;

  /* ───────────── 甲：打完 2 將 ＋ 第 3 將打一半 ───────────── */
  insert into table_sessions (org_id, store_id, table_id, mode, status, planned_rounds, started_at, open_method, game_type, flower)
  values (v_org, v_store, v_table, 'matched', 'open', 3, now(), 'manual', '台麻', '無花') returning id into v_sess;
  insert into session_players (org_id, session_id, member_id, join_type, status, seat, joined_at)
  select v_org, v_sess, m[i], 'opener', 'playing', i, now() from generate_series(1, 4) i;
  insert into session_rounds (org_id, session_id, round_no, first_dealer_seat, status, finished_at)
  values (v_org, v_sess, 1, 1, 'finished', now()) returning id into v_r1;
  insert into session_rounds (org_id, session_id, round_no, first_dealer_seat, status, finished_at)
  values (v_org, v_sess, 2, 1, 'finished', now()) returning id into v_r2;
  insert into session_rounds (org_id, session_id, round_no, first_dealer_seat, status)
  values (v_org, v_sess, 3, 1, 'playing') returning id into v_r3;
  insert into hands (org_id, session_id, round_id, hand_no, wind, dealer_seat, result, winner_seat, deal_in_seat, score_delta, status, confirmed_at)
  values (v_org, v_sess, v_r1, 1, 1, 1, 'ron', 1, 2, '{"1":30,"2":-30,"3":0,"4":0}',   'confirmed', now()),
         (v_org, v_sess, v_r2, 1, 1, 1, 'ron', 3, 4, '{"1":0,"2":0,"3":40,"4":-40}',   'confirmed', now()),
         (v_org, v_sess, v_r3, 1, 1, 1, 'ron', 1, 2, '{"1":100,"2":-100,"3":0,"4":0}', 'confirmed', now());
  v_res := public.settle_session_tx(v_sess);

  select string_agg(coalesce(final_score::text, 'null'), ',' order by seat),
         string_agg(coalesce(finish_rank::text, 'null'), ',' order by seat),
         count(rating_after)
    into v_fs, v_rk, v_ra from session_players where session_id = v_sess;
  v_total := v_total + 1;
  v_ok := v_fs = '30,-30,40,-40' and v_rk = '2,3,1,4' and v_ra = 4;
  if v_ok then v_pass := v_pass + 1; end if;
  v_msg := v_msg || case when v_ok then '✅' else '🔴' end
        || ' 甲 打完 2 將＋第 3 將一半：積分 ' || coalesce(v_fs, '—') || '（應為 30,-30,40,-40；第 3 將的 +100 不算）'
        || '，名次 ' || coalesce(v_rk, '—') || '（應為 2,3,1,4），有段位分 ' || v_ra || '/4' || E'\n';

  select count(*) into v_n from member_achievements where last_idem like 'settle:' || v_sess || '%';
  v_msg := v_msg || case when v_n > 0 then '✅' else '⚪' end
        || ' 甲 的對照：收桌發了成就 ' || v_n || ' 筆'
        || case when v_n = 0 then '（⚪ 測試會員那幾枚可能早就解鎖完，這一格測不出來）' else '' end || E'\n';

  /* ───────────── 乙：打完 1 將 ＋ 第 2 將打一半 ───────────── */
  insert into table_sessions (org_id, store_id, table_id, mode, status, planned_rounds, started_at, open_method, game_type, flower)
  values (v_org, v_store, v_table, 'matched', 'open', 3, now(), 'manual', '台麻', '無花') returning id into v_sess;
  insert into session_players (org_id, session_id, member_id, join_type, status, seat, joined_at)
  select v_org, v_sess, m[i], 'opener', 'playing', i, now() from generate_series(1, 4) i;
  insert into session_rounds (org_id, session_id, round_no, first_dealer_seat, status, finished_at)
  values (v_org, v_sess, 1, 1, 'finished', now()) returning id into v_r1;
  insert into session_rounds (org_id, session_id, round_no, first_dealer_seat, status)
  values (v_org, v_sess, 2, 1, 'playing') returning id into v_r2;
  insert into hands (org_id, session_id, round_id, hand_no, wind, dealer_seat, result, winner_seat, deal_in_seat, score_delta, status, confirmed_at)
  values (v_org, v_sess, v_r1, 1, 1, 1, 'ron', 1, 2, '{"1":20,"2":-20,"3":0,"4":0}', 'confirmed', now()),
         (v_org, v_sess, v_r2, 1, 1, 1, 'ron', 3, 4, '{"1":0,"2":0,"3":50,"4":-50}', 'confirmed', now());
  v_res := public.settle_session_tx(v_sess);

  select string_agg(coalesce(final_score::text, 'null'), ',' order by seat),
         string_agg(coalesce(finish_rank::text, 'null'), ',' order by seat),
         count(rating_after)
    into v_fs, v_rk, v_ra from session_players where session_id = v_sess;
  v_total := v_total + 1;
  v_ok := v_fs = '20,-20,0,0' and v_rk = '1,4,2,3' and v_ra = 0;
  if v_ok then v_pass := v_pass + 1; end if;
  v_msg := v_msg || case when v_ok then '✅' else '🔴' end
        || ' 乙 打完 1 將＋第 2 將一半：積分 ' || coalesce(v_fs, '—') || '（應為 20,-20,0,0）'
        || '，名次 ' || coalesce(v_rk, '—') || '（應為 1,4,2,3），有段位分 ' || v_ra || '/4（應為 0）' || E'\n';

  select count(*) into v_n from member_achievements where last_idem like 'settle:' || v_sess || '%';
  v_msg := v_msg || case when v_n > 0 then '✅' else '⚪' end
        || ' 乙 有名次 ⇒ 收桌照發成就：' || v_n || ' 筆'
        || case when v_n = 0 then '（⚪ 可能早就解鎖完）' else '' end || E'\n';

  /* ───────────── 丙：一將都沒打完 ───────────── */
  insert into table_sessions (org_id, store_id, table_id, mode, status, planned_rounds, started_at, open_method, game_type, flower)
  values (v_org, v_store, v_table, 'matched', 'open', 3, now(), 'manual', '台麻', '無花') returning id into v_sess;
  insert into session_players (org_id, session_id, member_id, join_type, status, seat, joined_at)
  select v_org, v_sess, m[i], 'opener', 'playing', i, now() from generate_series(1, 4) i;
  insert into session_rounds (org_id, session_id, round_no, first_dealer_seat, status)
  values (v_org, v_sess, 1, 1, 'playing') returning id into v_r1;
  insert into hands (org_id, session_id, round_id, hand_no, wind, dealer_seat, result, winner_seat, deal_in_seat, score_delta, status, confirmed_at)
  values (v_org, v_sess, v_r1, 1, 1, 1, 'ron', 1, 2, '{"1":10,"2":-10,"3":0,"4":0}', 'confirmed', now());
  v_res := public.settle_session_tx(v_sess);

  select count(finish_rank) + count(final_score) + count(rating_after) into v_n
    from session_players where session_id = v_sess;
  v_total := v_total + 1;
  v_ok := v_n = 0 and coalesce((v_res ->> 'ok')::boolean, false);
  if v_ok then v_pass := v_pass + 1; end if;
  v_msg := v_msg || case when v_ok then '✅' else '🔴' end
        || ' 丙 一將都沒打完：收桌 ' || coalesce(v_res ->> 'ok', '?') || '，名次／積分／段位分 合計 ' || v_n || ' 格有值（應為 0）' || E'\n';

  select count(*) into v_n from member_achievements where last_idem like 'settle:' || v_sess || '%';
  v_total := v_total + 1;
  v_ok := v_n = 0;
  if v_ok then v_pass := v_pass + 1; end if;
  v_msg := v_msg || case when v_ok then '✅' else '🔴' end
        || ' 丙 不發「完成一場牌局」這類成就：' || v_n || ' 筆（應為 0）' || E'\n';

  v_msg := v_msg || E'\n' || case when v_pass = v_total then '✅' else '🔴' end || ' 合計 ' || v_pass || '/' || v_total
        || '（⚪ 那兩格是對照，不計入）';
  raise exception 'migi_rollback';
exception when others then
  perform set_config('migi.settletest',
    v_msg || case when sqlerrm = 'migi_rollback' then '' else E'\n🔴 中途出錯：' || sqlerrm end, true);
end $$;

select coalesce(nullif(current_setting('migi.settletest', true), ''), '🔴 沒有測試訊息') as "收桌只結算打完的將（已回滾）";
