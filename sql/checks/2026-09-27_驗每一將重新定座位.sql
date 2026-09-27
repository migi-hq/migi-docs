-- ════════════════════════════════════════════════════════════════════
-- 行為測試：每一將重新定座位（2026-09-27）
--   前提：sql/pending/2026-09-27_每一將重新定座位.sql 已經跑過
--
-- 🔴 這份**故意不提交**：交易裡造一桌（4 台測試平板、4 位測試會員），真的叫 RPC，
--   最後 raise 'migi_rollback' 全部退掉（樣本造法同 2026-09-25_驗自摸一家取消整局作廢.sql）。
--   第一將座位 1→2→3→4、莊家 1。第一將直接標成打完，再開第二將測。
-- 最後一格應該是 6 行 ✅。
-- ════════════════════════════════════════════════════════════════════
do $$
declare
  v_org uuid; v_store uuid; v_table uuid; v_stake uuid; v_sess uuid;
  tk text[] := array[
    'a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1', 'b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2',
    'c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3', 'd4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4'];
  mem uuid[]; pl uuid[] := '{}'; i int; x uuid;
  r jsonb; st jsonb; h uuid; v text := '';
begin
  begin
    -- ── 造樣本 ──
    select t.id, t.store_id, s.org_id into v_table, v_store, v_org
      from tables t join stores s on s.id = t.store_id
     where not exists (select 1 from table_sessions ts where ts.table_id = t.id and ts.status = 'open' and ts.deleted_at is null)
     order by s.is_test desc limit 1;
    if v_table is null then raise exception '找不到空桌可以造樣本'; end if;
    select id into v_stake from stake_levels where org_id = v_org and label = '100/20' and deleted_at is null limit 1;
    if v_stake is null then raise exception '找不到 100/20 級距'; end if;
    select array_agg(id) into mem from (select id from members
      where org_id = v_org and is_test and deleted_at is null order by created_at limit 4) q;
    if cardinality(mem) < 4 then raise exception '測試會員不到 4 位（%）', cardinality(mem); end if;

    insert into table_sessions (org_id, store_id, table_id, mode, stake_level_id, game_type, flower, is_test)
    values (v_org, v_store, v_table, 'private', v_stake, '台麻', '無花', true) returning id into v_sess;
    for i in 1..4 loop
      insert into table_devices (org_id, store_id, table_id, label, token_hash)
      values (v_org, v_store, v_table, '測試平板' || i, public._tbl_hash(tk[i])) returning id into x;
      insert into session_players (org_id, session_id, member_id, device_id)
      values (v_org, v_sess, mem[i], x) returning id into x;
      pl := pl || x;
    end loop;
    r := public.tbl_set_order_tx(tk[1], pl[1], pl[2], pl[3]);
    if not (r ->> 'ok')::boolean then raise exception '定座位失敗：%', r; end if;

    -- 第一將直接標成打完，才能開第二將
    update session_rounds set status = 'finished', finished_at = now() where session_id = v_sess and round_no = 1;

    -- ── ① 擋牆：下家與莊家同一人 ⇒ 擋 ──
    r := public.tbl_start_round_tx(tk[1], 3::smallint, 3::smallint, 4::smallint);
    v := v || case when r ->> 'reason' = 'bad_order' then '✅' else '🔴' end || ' ① 下家選成莊家本人 ⇒ ' || coalesce(r ->> 'reason', r::text) || E'\n';

    -- ── ② 擋牆：只給下家不給對家 ⇒ 擋 ──
    r := public.tbl_start_round_tx(tk[1], 3::smallint, 1::smallint, null);
    v := v || case when r ->> 'reason' = 'bad_order' then '✅' else '🔴' end || ' ② 只選下家沒選對家 ⇒ ' || coalesce(r ->> 'reason', r::text) || E'\n';

    -- ── ③ 開第二將：莊 3、下家 1、對家 4 ⇒ 順序 [3,1,4,2] ──
    r := public.tbl_start_round_tx(tk[1], 3::smallint, 1::smallint, 4::smallint);
    st := public.tbl_state_tx(tk[1]);
    v := v || case when (r ->> 'ok')::boolean and st -> 'round' -> 'seat_ring' = '[3,1,4,2]'::jsonb
                        and (st -> 'round' ->> 'dealer_seat')::int = 3 and (st -> 'round' ->> 'round_no')::int = 2
                  then '✅' else '🔴' end
           || ' ③ 第二將順序 ' || coalesce(st -> 'round' ->> 'seat_ring', '?') || '、莊家 ' || coalesce(st -> 'round' ->> 'dealer_seat', '?') || E'\n';

    -- ── ④ 正對照：閒家（座位 1）胡、座位 2 放槍 ⇒ 下莊，下一任是順序裡莊家的下一位 ＝ 座位 1（不是 4）──
    r := public.tbl_submit_hand_tx(tk[1], 'ron', 2::smallint, '[]');
    h := (r ->> 'hand_id')::uuid;
    r := public.tbl_confirm_hand_tx(tk[2], h, true);
    st := public.tbl_state_tx(tk[1]);
    v := v || case when (st -> 'round' ->> 'dealer_seat')::int = 1
                  then '✅' else '🔴' end
           || ' ④ 閒家胡 ⇒ 莊家換成 ' || coalesce(st -> 'round' ->> 'dealer_seat', '?') || '（照順序應為 1；照舊的 1→2→3→4 會是 4）' || E'\n';

    -- ── ⑤ 總分沒有被換位子弄亂：座位 1 收、座位 2 付，其他兩家 0 ──
    v := v || case when (st -> 'totals' ->> '1')::int > 0 and (st -> 'totals' ->> '2')::int < 0
                        and coalesce((st -> 'totals' ->> '3')::int, 0) = 0 and coalesce((st -> 'totals' ->> '4')::int, 0) = 0
                  then '✅' else '🔴' end
           || ' ⑤ 分數記在對的人身上：' || coalesce(st ->> 'totals', '?') || E'\n';

    -- ── ⑥ 舊版平板（只送莊家）還叫得動：第三將不給順序 ⇒ seat_ring 是預設 1→2→3→4 ──
    update session_rounds set status = 'finished', finished_at = now() where session_id = v_sess and round_no = 2;
    r := public.tbl_start_round_tx(tk[1], 2::smallint);
    st := public.tbl_state_tx(tk[1]);
    v := v || case when (r ->> 'ok')::boolean and st -> 'round' -> 'seat_ring' = '[1,2,3,4]'::jsonb and (st -> 'round' ->> 'dealer_seat')::int = 2
                  then '✅' else '🔴' end
           || ' ⑥ 只送莊家（舊版）⇒ 第三將順序 ' || coalesce(st -> 'round' ->> 'seat_ring', '?') || '、莊家 ' || coalesce(st -> 'round' ->> 'dealer_seat', '?') || E'\n';

    raise exception 'migi_rollback';
  exception when others then
    if sqlerrm <> 'migi_rollback' then v := v || '🔴 中途例外：' || sqlerrm || E'\n'; end if;
    perform set_config('migi.v', v || '（以上全部回滾，線上一列都沒動）', true);
  end;
end $$;

select coalesce(nullif(current_setting('migi.v', true), ''), '🔴 沒有訊息') as "驗證";
