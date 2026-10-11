-- ============================================================
-- 行為測試：計分板重選這一將的位置（2026-10-11）
-- 前提：先跑完 sql/pending/2026-10-11_計分板重選這一將的位置.sql
-- 🔴 交易內自己造一場測試牌局（測試門市一張空桌、四位測試帳號、一台測試平板），不碰任何真的牌局；
--   最後故意 raise 'migi_rollback' 全部回滾，資料庫不會留下任何東西（訊息寫在 exception 處理器裡）。
-- ============================================================
do $$
declare
  v_org uuid; v_store uuid; v_tbl uuid; v_s uuid; v_r uuid; v_m uuid[];
  v_tok text := 'migi-test-reorder-' || md5(random()::text);
  j jsonb; v_ring smallint[]; v_first smallint; st jsonb;
  v_msg text := '';
begin
  -- 測試門市裡一張現在沒開的桌
  select t.id, t.store_id, st.org_id into v_tbl, v_store, v_org
    from tables t join stores st on st.id = t.store_id
   where st.is_test and t.deleted_at is null
     and not exists (select 1 from table_sessions o where o.table_id = t.id and o.status = 'open' and o.deleted_at is null)
   limit 1;
  if v_tbl is null then v_msg := '⚪ 找不到測試門市的空桌'; raise exception 'migi_rollback'; end if;
  select array_agg(id) into v_m from (select id from members where org_id = v_org and is_test and deleted_at is null limit 4) x;
  if coalesce(array_length(v_m, 1), 0) < 4 then v_msg := '⚪ 測試帳號不到四個'; raise exception 'migi_rollback'; end if;

  insert into table_sessions (org_id, store_id, table_id, mode, status, game_type)
  values (v_org, v_store, v_tbl, 'private', 'open', '台麻') returning id into v_s;
  insert into session_players (org_id, session_id, member_id, seat)
  select v_org, v_s, v_m[i], i from generate_series(1, 4) i;
  insert into session_rounds (org_id, session_id, round_no, first_dealer_seat)
  values (v_org, v_s, 1, 1) returning id into v_r;
  insert into table_devices (org_id, store_id, table_id, label, token_hash)
  values (v_org, v_store, v_tbl, '測試平板（重選位置）', public._tbl_hash(v_tok));

  -- ① 還沒打任何一局 ⇒ 可以重選：莊家 2、下家 4、對家 3 ⇒ 順序 {2,4,3,1}
  j := public.tbl_reorder_round_tx(v_tok, 2::smallint, 4::smallint, 3::smallint);
  select seat_ring, first_dealer_seat into v_ring, v_first from session_rounds where id = v_r;
  v_msg := case when (j ->> 'ok')::boolean and v_ring = '{2,4,3,1}'::smallint[] and v_first = 2
                then '✅ ① 還沒打 ⇒ 改得動，順序變成 {2,4,3,1}、起莊 2'
                else '🔴 ① 回傳 ' || j::text || '，順序 ' || coalesce(v_ring::text, 'null') end;
  -- ② 三個人選重複 ⇒ 擋
  j := public.tbl_reorder_round_tx(v_tok, 2::smallint, 2::smallint, 3::smallint);
  v_msg := v_msg || E'\n' || case when j ->> 'reason' = 'bad_order' then '✅ ② 選重複的人 ⇒ 擋下（bad_order）'
                                   else '🔴 ② 回傳 ' || j::text end;
  -- ③ 只打過一筆咔啦碰 ⇒ 仍然可以重選（咔啦碰不是一局）
  insert into hands (org_id, session_id, round_id, hand_no, wind, dealer_seat, result, winner_seat, deal_in_seat, status, submitted_seat)
  values (v_org, v_s, v_r, 1, 1, 2, 'kala', 1, 3, 'confirmed', 3);
  j := public.tbl_reorder_round_tx(v_tok, 1::smallint, 2::smallint, 3::smallint);
  select seat_ring into v_ring from session_rounds where id = v_r;
  v_msg := v_msg || E'\n' || case when (j ->> 'ok')::boolean and v_ring = '{1,2,3,4}'::smallint[]
                                   then '✅ ③ 只有咔啦碰 ⇒ 仍然改得動（順序 {1,2,3,4}）'
                                   else '🔴 ③ 回傳 ' || j::text end;
  -- ④ 打過一局（流局）⇒ 不能再改，而且順序沒被動到（正對照：上一格同一支函式是改得動的）
  insert into hands (org_id, session_id, round_id, hand_no, wind, dealer_seat, result, status, submitted_seat)
  values (v_org, v_s, v_r, 1, 1, 1, 'draw', 'confirmed', 1);
  j := public.tbl_reorder_round_tx(v_tok, 3::smallint, 1::smallint, 2::smallint);
  select seat_ring into v_ring from session_rounds where id = v_r;
  v_msg := v_msg || E'\n' || case when j ->> 'reason' = 'already_started' and v_ring = '{1,2,3,4}'::smallint[]
                                   then '✅ ④ 打過一局 ⇒ 擋下（already_started），順序沒動'
                                   else '🔴 ④ 回傳 ' || j::text || '，順序 ' || coalesce(v_ring::text, 'null') end;
  -- ⑤ 座位號沒被動到（座位號代表人）
  v_msg := v_msg || E'\n' || case when (select array_agg(seat order by seat) from session_players where session_id = v_s) = '{1,2,3,4}'::smallint[]
                                   then '✅ ⑤ 四個人的座位號都沒動'
                                   else '🔴 ⑤ 座位號被改了' end;
  raise exception 'migi_rollback';
exception when others then
  if sqlerrm = 'migi_rollback' then
    perform set_config('migi.x', v_msg, true);
  else
    perform set_config('migi.x', '🔴 中途出錯：' || sqlstate || ' ' || sqlerrm || E'\n已跑完的：\n' || v_msg, true);
  end if;
end $$;

select coalesce(nullif(current_setting('migi.x', true), ''), '🔴 沒有訊息') as "行為測試（應為 5 行 ✅，全部回滾）";
