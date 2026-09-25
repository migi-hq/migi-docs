-- ════════════════════════════════════════════════════════════════════
-- 行為測試：「任何一人取消 ⇒ 這次操作作廢、不推進，送出的人重送」（2026-09-25）
--   T1–T4 自摸、T5 包牌、T6 放槍（含重送）
--   前提：sql/pending/2026-09-25_自摸一家取消整局作廢.sql 已經跑過
--
-- 🔴 這份**故意不提交**：在交易裡造一桌（4 台測試平板、4 位測試會員），
--   真的叫 RPC，最後 raise 'migi_rollback' 全部退掉（硬規則 1.8 的例外那一種）。
--   樣本造法與 2026-09-25_驗桌邊記分逐家確認.sql 相同（找一張空桌、100/20）。
--   座位 1 是第一個莊家，下家鏈 1→2→3→4；座位 2 自摸 ⇒ 付錢的是 1、3、4。
--   金額一律讀後端提出的 proposed_delta，不在這裡重算。
-- ════════════════════════════════════════════════════════════════════
do $$
declare
  v_org uuid; v_store uuid; v_table uuid; v_stake uuid; v_sess uuid;
  tk text[] := array[
    'a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1', 'b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2',
    'c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3', 'd4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4'];
  mem uuid[]; pl uuid[] := '{}'; i int; x uuid;
  r jsonb; st jsonb; h uuid; v text := ''; p jsonb; win int;
  tot text;
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

    -- ── T1 自摸：座位 3 先確認 ⇒ **還沒入帳**（全有或全無）──
    r := public.tbl_submit_hand_tx(tk[2], 'tsumo', null, '[]');
    h := (r ->> 'hand_id')::uuid; p := r -> 'proposed_delta';
    perform public.tbl_confirm_hand_tx(tk[3], h, true);
    st := public.tbl_state_tx(tk[1]);
    tot := coalesce(st -> 'totals' ->> '1', '0') || '/' || coalesce(st -> 'totals' ->> '2', '0') || '/'
        || coalesce(st -> 'totals' ->> '3', '0') || '/' || coalesce(st -> 'totals' ->> '4', '0');
    v := v || case when tot = '0/0/0/0' and (select status from hands where id = h) = 'pending'
                  then '✅' else '🔴' end
           || ' T1 自摸、座位 3 先確認：四家總分仍是 ' || tot || '（確認的當下不入帳），這一局還在等' || E'\n';

    -- ── T2 座位 4 取消 ⇒ 這次操作立刻作廢，不等座位 1 ──
    r := public.tbl_confirm_hand_tx(tk[4], h, false);
    st := public.tbl_state_tx(tk[1]);
    tot := coalesce(st -> 'totals' ->> '1', '0') || '/' || coalesce(st -> 'totals' ->> '2', '0') || '/'
        || coalesce(st -> 'totals' ->> '3', '0') || '/' || coalesce(st -> 'totals' ->> '4', '0');
    v := v || case when r ->> 'status' = 'rejected' and (r ->> 'voided')::boolean and tot = '0/0/0/0'
                        and (select status from hands where id = h) = 'rejected'
                  then '✅' else '🔴' end
           || ' T2 座位 4 取消 ⇒ 這次操作作廢（' || coalesce(r ->> 'status', '?') || '），先確認的座位 3 也沒扣：' || tot || E'\n';

    -- ── T3 座位 1 晚到的確認 ⇒ 已經處理過了；局數與莊家不動 ──
    r := public.tbl_confirm_hand_tx(tk[1], h, true);
    st := public.tbl_state_tx(tk[1]);
    v := v || case when r ->> 'reason' = 'not_pending'
                        and (st -> 'round' ->> 'hand_no')::int = 1
                        and (st -> 'round' ->> 'dealer_seat')::int = 1 and (st -> 'round' ->> 'renzhuang')::int = 0
                  then '✅' else '🔴' end
           || ' T3 座位 1 晚到的確認回「已經處理過了」；作廢不推進：仍是第 ' || (st -> 'round' ->> 'hand_no')
           || ' 局、莊 ' || (st -> 'round' ->> 'dealer_seat') || '、連 ' || (st -> 'round' ->> 'renzhuang') || E'\n';

    -- ── T4 正對照：重新送一次自摸，三家都確認 ⇒ 一次入帳，金額 ＝ 當初提出的 ──
    r := public.tbl_submit_hand_tx(tk[2], 'tsumo', null, '[]');
    h := (r ->> 'hand_id')::uuid; p := r -> 'proposed_delta';
    perform public.tbl_confirm_hand_tx(tk[1], h, true);
    perform public.tbl_confirm_hand_tx(tk[3], h, true);
    st := public.tbl_state_tx(tk[1]);
    v := v || case when coalesce((st -> 'totals' ->> '2')::int, 0) = 0 then '✅' else '🔴' end
           || ' T4a 重送之後兩家確認：座位 2 仍是 ' || coalesce(st -> 'totals' ->> '2', '0') || '（還差一家，不入帳）' || E'\n';
    r := public.tbl_confirm_hand_tx(tk[4], h, true);
    st := public.tbl_state_tx(tk[1]);
    win := (p ->> '2')::int;
    v := v || case when r ->> 'status' = 'confirmed'
                        and (st -> 'totals' ->> '2')::int = win
                        and (st -> 'totals' ->> '1')::int = (p ->> '1')::int
                        and (st -> 'totals' ->> '3')::int = (p ->> '3')::int
                        and (st -> 'totals' ->> '4')::int = (p ->> '4')::int
                  then '✅' else '🔴' end
           || ' T4b 第三家確認 ⇒ 一次入帳：座位 2 收 ' || coalesce(st -> 'totals' ->> '2', '?') || '（提出的是 ' || win || '），'
           || '三家各付 ' || (p ->> '1') || ' / ' || (p ->> '3') || ' / ' || (p ->> '4') || E'\n';
    /* 使用者的原話：「A 重新送出正確的、全部確認 ⇒ 莊家推進、局數推進」。
       座位 2 是閒家自摸 ⇒ 下莊，莊家輪到座位 1 的下家（座位 2），進入第 2 局 */
    v := v || case when (st -> 'round' ->> 'hand_no')::int = 2
                        and (st -> 'round' ->> 'dealer_seat')::int = 2 and (st -> 'round' ->> 'renzhuang')::int = 0
                  then '✅' else '🔴' end
           || ' T4c 全部確認之後才推進：第 ' || (st -> 'round' ->> 'hand_no') || ' 局、莊 '
           || (st -> 'round' ->> 'dealer_seat') || '、連 ' || (st -> 'round' ->> 'renzhuang') || E'\n';

    -- ── T5 包牌（三家收）：一家確認、一家取消 ⇒ 這次操作作廢，包牌的人一分都不付 ──
    st := public.tbl_state_tx(tk[1]);
    tot := coalesce(st -> 'totals' ->> '3', '0');
    r := public.tbl_submit_hand_tx(tk[3], 'bao', null, '[]');
    h := (r ->> 'hand_id')::uuid;
    perform public.tbl_confirm_hand_tx(tk[1], h, true);
    r := public.tbl_confirm_hand_tx(tk[2], h, false);
    st := public.tbl_state_tx(tk[1]);
    v := v || case when r ->> 'status' = 'rejected' and coalesce(st -> 'totals' ->> '3', '0') = tot
                  then '✅' else '🔴' end
           || ' T5 包牌一家確認、一家取消 ⇒ 這次操作作廢，包牌的座位 3 維持 ' || coalesce(st -> 'totals' ->> '3', '0')
           || '（原本 ' || tot || '）' || E'\n';

    -- ── T6 放槍：取消 ⇒ 作廢；重送一次、確認 ⇒ 入帳（送出的人重送那條路是通的）──
    r := public.tbl_submit_hand_tx(tk[3], 'ron', 4::smallint, '[]');
    h := (r ->> 'hand_id')::uuid;
    r := public.tbl_confirm_hand_tx(tk[4], h, false);
    v := v || case when r ->> 'status' = 'rejected' then '✅' else '🔴' end
           || ' T6a 放槍被取消 ⇒ 作廢（' || coalesce(r ->> 'status', '?') || '）' || E'\n';
    r := public.tbl_submit_hand_tx(tk[3], 'ron', 4::smallint, '[]');
    h := (r ->> 'hand_id')::uuid;
    r := public.tbl_confirm_hand_tx(tk[4], h, true);
    v := v || case when r ->> 'status' = 'confirmed' then '✅' else '🔴' end
           || ' T6b 重送之後確認 ⇒ 入帳（' || coalesce(r ->> 'status', '?') || '）' || E'\n';

    raise exception 'migi_rollback';
  exception when others then
    if sqlerrm <> 'migi_rollback' then v := v || '🔴 中途例外：' || sqlerrm || E'\n'; end if;
    perform set_config('migi.v', v || '（以上全部回滾，線上一列都沒動）', true);
  end;
end $$;

select coalesce(nullif(current_setting('migi.v', true), ''), '🔴 沒有訊息') as "驗證";
