-- ════════════════════════════════════════════════════════════════════
-- 2026-10-16 驗「回到第一局」（交易內自己造樣本，最後整份回滾，一列都不留）
-- 先跑 sql/pending/2026-10-16_計分板回到第一局.sql，再跑這一份
-- ════════════════════════════════════════════════════════════════════
do $$
declare
  v_msg text := '';
  v_org uuid; v_store uuid; v_table uuid; v_sess uuid; v_tab uuid; v_r1 uuid; v_r2 uuid;
  m uuid[]; i int; r jsonb; n int;
  c_tab constant text := repeat('r', 40);
begin
  begin
    select array_agg(id order by phone) into m from members where is_test and phone in ('0910000001','0910000002','0910000003','0910000004');
    if coalesce(array_length(m, 1), 0) <> 4 then raise exception '四個測試帳號不齊'; end if;
    if exists (select 1 from session_players sp join table_sessions ts on ts.id = sp.session_id
                where sp.member_id = any(m) and sp.left_at is null and ts.status = 'open') then
      raise exception '測試帳號現在有牌局，這份測不了';
    end if;
    select t.id, t.store_id, t.org_id into v_table, v_store, v_org from tables t
     where t.deleted_at is null and t.is_active
       and not exists (select 1 from table_sessions s where s.table_id = t.id and s.status = 'open' and s.deleted_at is null)
     order by t.label desc limit 1;
    if v_table is null then raise exception '找不到空桌'; end if;

    insert into table_sessions (org_id, store_id, table_id, mode, status, planned_rounds, game_type, flower, is_test)
    values (v_org, v_store, v_table, 'matched', 'open', 3, '台麻', '無花', true) returning id into v_sess;
    insert into table_devices (org_id, store_id, table_id, label, token_hash, kind)
    values (v_org, v_store, v_table, '測試平板', public._tbl_hash(c_tab), 'tablet') returning id into v_tab;
    for i in 1..4 loop
      insert into session_players (org_id, session_id, member_id, seat, device_id)
      values (v_org, v_sess, m[i], i, case when i = 1 then v_tab end);
    end loop;
    insert into session_rounds (org_id, session_id, round_no, first_dealer_seat, status, started_at)
    values (v_org, v_sess, 1, 1, 'playing', now()) returning id into v_r1;

    -- ① 還沒打任何一局 ⇒ 擋（沒東西可退）
    r := public.tbl_reset_round_tx(c_tab);
    v_msg := v_msg || case when r ->> 'reason' = 'nothing' then '✅ ① 第 1 局還沒打：擋下（沒東西可退）' else '🔴 ① ' || r::text end;

    -- ② 打了兩局（＋ 一次咔啦碰）⇒ 回到第一局成功，三筆都撤掉
    insert into hands (org_id, session_id, round_id, hand_no, wind, dealer_seat, result, winner_seat, deal_in_seat, status, score_delta, confirmed_at) values
      (v_org, v_sess, v_r1, 1, 1, 1, 'ron',  2, 4, 'confirmed', '{"2": 180, "4": -180}'::jsonb, now()),
      (v_org, v_sess, v_r1, 2, 1, 2, 'kala', 3, 1, 'confirmed', '{"3": 60, "1": -60}'::jsonb, now()),
      (v_org, v_sess, v_r1, 2, 1, 2, 'ron',  4, 2, 'confirmed', '{"4": 180, "2": -180}'::jsonb, now());
    r := public.tbl_reset_round_tx(c_tab);
    select count(*) into n from hands where session_id = v_sess and status = 'confirmed';
    v_msg := v_msg || E'\n' || case when (r ->> 'ok')::boolean and (r ->> 'undone')::int = 3 and n = 0
                                    then '✅ ② 打了 2 局（加一次咔啦碰）⇒ 回到第一局，3 筆全部撤掉、沒有算分的局'
                                    else '🔴 ② ' || r::text || ' / 剩 ' || n || ' 筆' end;

    -- ③ 打了三局（畫面是第 4 局）⇒ 擋
    insert into hands (org_id, session_id, round_id, hand_no, wind, dealer_seat, result, winner_seat, deal_in_seat, status, score_delta, confirmed_at) values
      (v_org, v_sess, v_r1, 1, 1, 1, 'draw', null, null, 'confirmed', '{}'::jsonb, now()),
      (v_org, v_sess, v_r1, 2, 1, 1, 'draw', null, null, 'confirmed', '{}'::jsonb, now()),
      (v_org, v_sess, v_r1, 3, 1, 1, 'draw', null, null, 'confirmed', '{}'::jsonb, now());
    r := public.tbl_reset_round_tx(c_tab);
    v_msg := v_msg || E'\n' || case when r ->> 'reason' = 'too_late' then '✅ ③ 打到第 4 局：擋下' else '🔴 ③ ' || r::text end;

    -- ④ 只打兩局但有一局在等確認 ⇒ 擋
    update hands set status = 'undone', undone_at = now() where session_id = v_sess and hand_no = 3 and status = 'confirmed';
    insert into hands (org_id, session_id, round_id, hand_no, wind, dealer_seat, result, winner_seat, deal_in_seat, status, score_delta)
    values (v_org, v_sess, v_r1, 3, 1, 1, 'ron', 3, 4, 'pending', '{"3": 100, "4": -100}'::jsonb);
    r := public.tbl_reset_round_tx(c_tab);
    v_msg := v_msg || E'\n' || case when r ->> 'reason' = 'pending_exists' then '✅ ④ 有一局在等確認：擋下' else '🔴 ④ ' || r::text end;
    update hands set status = 'undone', undone_at = now() where session_id = v_sess and status = 'pending';

    -- ⑤ 第 2 將 ⇒ 擋
    update session_rounds set status = 'finished', finished_at = now() where id = v_r1;
    insert into session_rounds (org_id, session_id, round_no, first_dealer_seat, status, started_at)
    values (v_org, v_sess, 2, 1, 'playing', now()) returning id into v_r2;
    insert into hands (org_id, session_id, round_id, hand_no, wind, dealer_seat, result, status, score_delta, confirmed_at)
    values (v_org, v_sess, v_r2, 1, 1, 1, 'draw', 'confirmed', '{}'::jsonb, now());
    r := public.tbl_reset_round_tx(c_tab);
    v_msg := v_msg || E'\n' || case when r ->> 'reason' = 'not_first_round' then '✅ ⑤ 第 2 將：擋下（只有第 1 將能用）' else '🔴 ⑤ ' || r::text end;

    raise exception 'migi_rollback';
  exception when others then
    if sqlerrm <> 'migi_rollback' then v_msg := v_msg || E'\n🔴 中途出錯：' || sqlerrm; end if;
    perform set_config('migi.reset', v_msg, true);
  end;
end $$;
select coalesce(nullif(current_setting('migi.reset', true), ''), '🔴 沒有訊息') as "回到第一局 行為測試（已回滾）";
