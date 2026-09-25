-- ════════════════════════════════════════════════════════════════════
-- 行為測試：桌邊記分「逐家確認／咔啦碰／包牌」（2026-09-25）
--   前提：sql/pending/2026-09-25_桌邊記分_逐家確認與咔啦碰包牌.sql 已經跑過
--
-- 🔴 這份**故意不提交**：在交易裡造一桌（4 台測試平板、4 位測試會員），
--   把每一種情況真的叫一次 RPC，最後 raise 'migi_rollback' 把全部退掉（硬規則 1.8 的例外那一種）。
--   訊息寫在 exception handler 裡（硬規則 3.9），最後一支 SELECT 讀出來。
--
-- 🔴 2026-09-25 同日稍晚規則改了：任何一人取消 ⇒ 整局作廢（全有或全無）。
--   這份的 B（自摸部分取消）與 E（包牌部分確認）描述的是**舊規則**，現在重跑會紅 ——
--   那是規則換了不是壞了。新規則的測試：2026-09-25_驗自摸一家取消整局作廢.sql
--
-- 級距 100/20（底 100、每台 20），座位 1 是第一個莊家，下家鏈 1→2→3→4。
-- 期望值都寫成算式（硬規則 3.56），紅了先看算式是哪一項變了。
-- ════════════════════════════════════════════════════════════════════
do $$
declare
  v_org uuid; v_store uuid; v_table uuid; v_stake uuid; v_sess uuid;
  tk text[] := array[
    'a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1', 'b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2',
    'c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3', 'd4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4'];
  mem uuid[]; dev uuid[] := '{}'; pl uuid[] := '{}'; i int; x uuid;
  r jsonb; st jsonb; h uuid; v text := ''; m text; dt text;
  -- 取整桌狀態裡某個座位的總分／這一將的莊家、連莊、局號
  tot int[];
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
      dev := dev || x;
      insert into session_players (org_id, session_id, member_id, device_id)
      values (v_org, v_sess, mem[i], x) returning id into x;
      pl := pl || x;
    end loop;
    r := public.tbl_set_order_tx(tk[1], pl[1], pl[2], pl[3]);
    if not (r ->> 'ok')::boolean then raise exception '定座位失敗：%', r; end if;
    v := v || '⚪ 樣本：一桌 4 台平板、座位 1→4，級距 100/20' || E'\n';

    -- ── A 放槍：座位 2 胡、座位 3 放槍、清一色 8 台；莊家是 1、兩人都不是莊 ⇒ 100 ＋ 20 × 8 ＝ 260 ──
    r := public.tbl_submit_hand_tx(tk[2], 'ron', 3::smallint, '[{"code":"qingyise"}]');
    h := (r ->> 'hand_id')::uuid;
    st := public.tbl_state_tx(tk[1]);
    v := v || case when (r -> 'proposed_delta' ->> '3')::int = -260 and coalesce((st -> 'totals' ->> '2')::int, 0) = 0
                  then '✅' else '🔴' end
           || ' A1 送出：放槍的人提出 −260（' || coalesce(r -> 'proposed_delta' ->> '3', '無') || '），還沒確認前總分不動（'
           || coalesce(st -> 'totals' ->> '2', '0') || '）' || E'\n';
    r := public.tbl_confirm_hand_tx(tk[3], h, true);
    st := public.tbl_state_tx(tk[1]);
    v := v || case when r ->> 'status' = 'confirmed' and (st -> 'totals' ->> '2')::int = 260 and (st -> 'totals' ->> '3')::int = -260
                        and (st -> 'round' ->> 'dealer_seat')::int = 2 and (st -> 'round' ->> 'renzhuang')::int = 0
                  then '✅' else '🔴' end
           || ' A2 確認：座位 2 ＋' || (st -> 'totals' ->> '2') || '、座位 3 ' || (st -> 'totals' ->> '3')
           || '；閒家胡 ⇒ 換莊給座位 2（莊 ' || (st -> 'round' ->> 'dealer_seat') || '，連 ' || (st -> 'round' ->> 'renzhuang') || '）' || E'\n';

    -- ── B 自摸：座位 2（莊、連 0 ⇒ 莊家台 1）沒選牌型 ⇒ 自動自摸 1 台；每家 100 ＋ 20 ×（1 ＋ 1）＝ 140 ──
    --    座位 3 確認、座位 4 取消、座位 1 確認 ⇒ 座位 2 收 140 × 2 ＝ 280
    r := public.tbl_submit_hand_tx(tk[2], 'tsumo', null, '[]');
    h := (r ->> 'hand_id')::uuid;
    perform public.tbl_confirm_hand_tx(tk[3], h, true);
    st := public.tbl_state_tx(tk[2]);
    v := v || case when (st -> 'totals' ->> '2')::int = 260 + 140 and st -> 'pending' is not null
                        and (st -> 'pending' ->> 'i_must_confirm')::boolean = false
                  then '✅' else '🔴' end
           || ' B1 逐家入帳：座位 3 一確認座位 2 就是 ' || (st -> 'totals' ->> '2') || '（260 ＋ 140），這一局還在等另外兩家' || E'\n';
    perform public.tbl_confirm_hand_tx(tk[4], h, false);
    r := public.tbl_confirm_hand_tx(tk[1], h, true);
    st := public.tbl_state_tx(tk[1]);
    tot := array[(st -> 'totals' ->> '1')::int, (st -> 'totals' ->> '2')::int, (st -> 'totals' ->> '3')::int, coalesce((st -> 'totals' ->> '4')::int, 0)];
    v := v || case when r ->> 'status' = 'confirmed' and tot = array[-140, 260 + 280, -260 - 140, 0]
                        and (st -> 'round' ->> 'dealer_seat')::int = 2 and (st -> 'round' ->> 'renzhuang')::int = 1
                  then '✅' else '🔴' end
           || ' B2 取消的那一家不扣：四家 ' || array_to_string(tot, ' / ')
           || '（應為 −140 / 540 / −400 / 0）；莊家自摸 ⇒ 連莊（連 ' || (st -> 'round' ->> 'renzhuang') || '）' || E'\n';

    -- ── C 咔啦碰：座位 4 直接付座位 1 一台 ＝ 20；不算一局 ──
    r := public.tbl_submit_hand_tx(tk[4], 'kala', 1::smallint, '[]');
    h := (r ->> 'hand_id')::uuid;
    r := public.tbl_confirm_hand_tx(tk[1], h, true);
    st := public.tbl_state_tx(tk[1]);
    v := v || case when r ->> 'status' = 'confirmed' and (st -> 'totals' ->> '1')::int = -140 + 20 and (st -> 'totals' ->> '4')::int = -20
                        and (st -> 'round' ->> 'hand_no')::int = 3 and (st -> 'round' ->> 'renzhuang')::int = 1
                  then '✅' else '🔴' end
           || ' C 咔啦碰：座位 1 ' || (st -> 'totals' ->> '1') || '（−140 ＋ 20）、座位 4 ' || (st -> 'totals' ->> '4')
           || '；局號仍是第 ' || (st -> 'round' ->> 'hand_no') || ' 局、連莊不變' || E'\n';

    -- ── D 包牌全部取消：座位 3（閒家）包；莊是 2、連 1 ⇒ 莊家台 3
    --    收的人：座位 1 ＝ 100 ＋ 20 × 3 ＝ 160、座位 2（莊）＝ 100 ＋ 20 ×（3 ＋ 3）＝ 220、座位 4 ＝ 160 ──
    r := public.tbl_submit_hand_tx(tk[3], 'bao', null, '[]');
    h := (r ->> 'hand_id')::uuid;
    v := v || case when (r -> 'proposed_delta' ->> '1')::int = 160 and (r -> 'proposed_delta' ->> '2')::int = 220
                        and (r -> 'proposed_delta' ->> '3')::int = -(160 + 220 + 160)
                  then '✅' else '🔴' end
           || ' D1 包牌金額：座位 1 ＋' || (r -> 'proposed_delta' ->> '1') || '、莊家 ＋' || (r -> 'proposed_delta' ->> '2')
           || '、包牌的人 ' || (r -> 'proposed_delta' ->> '3') || '（應為 160 / 220 / −540）' || E'\n';
    perform public.tbl_confirm_hand_tx(tk[1], h, false);
    perform public.tbl_confirm_hand_tx(tk[2], h, false);
    r := public.tbl_confirm_hand_tx(tk[4], h, false);
    st := public.tbl_state_tx(tk[1]);
    v := v || case when r ->> 'status' = 'rejected' and (st -> 'totals' ->> '3')::int = -400
                        and (st -> 'round' ->> 'hand_no')::int = 3 and (st -> 'round' ->> 'renzhuang')::int = 1
                  then '✅' else '🔴' end
           || ' D2 全部取消 ⇒ 這局不算：狀態 ' || (r ->> 'status') || '、座位 3 仍是 ' || (st -> 'totals' ->> '3')
           || '、局號仍是第 ' || (st -> 'round' ->> 'hand_no') || ' 局' || E'\n';

    -- ── E 包牌部分確認：再包一次，只有莊家（座位 2）確認 ⇒ 座位 3 付 220；閒家包 ⇒ 莊家繼續連莊 ──
    r := public.tbl_submit_hand_tx(tk[3], 'bao', null, '[]');
    h := (r ->> 'hand_id')::uuid;
    perform public.tbl_confirm_hand_tx(tk[2], h, true);
    perform public.tbl_confirm_hand_tx(tk[1], h, false);
    r := public.tbl_confirm_hand_tx(tk[4], h, false);
    st := public.tbl_state_tx(tk[1]);
    v := v || case when r ->> 'status' = 'confirmed' and (st -> 'totals' ->> '3')::int = -400 - 220 and (st -> 'totals' ->> '2')::int = 540 + 220
                        and (st -> 'round' ->> 'dealer_seat')::int = 2 and (st -> 'round' ->> 'renzhuang')::int = 2
                        and (st -> 'round' ->> 'hand_no')::int = 4
                  then '✅' else '🔴' end
           || ' E 包牌只有莊家收：座位 3 ' || (st -> 'totals' ->> '3') || '（−400 − 220）、莊家 ' || (st -> 'totals' ->> '2')
           || '（540 ＋ 220）；閒家包 ⇒ 莊家連莊（連 ' || (st -> 'round' ->> 'renzhuang') || '、第 ' || (st -> 'round' ->> 'hand_no') || ' 局）' || E'\n';

    -- ── F 還有人沒確認時，別人不能送下一局（正對照：送出之後才擋） ──
    r := public.tbl_submit_hand_tx(tk[1], 'tsumo', null, '[]');
    h := (r ->> 'hand_id')::uuid;
    r := public.tbl_submit_hand_tx(tk[4], 'draw', null, '[]');
    v := v || case when r ->> 'reason' = 'pending_exists' then '✅' else '🔴' end
           || ' F 上一局還有人沒確認 ⇒ 擋下（' || coalesce(r ->> 'message', r::text) || '）' || E'\n';
    perform public.tbl_confirm_hand_tx(tk[2], h, false);
    perform public.tbl_confirm_hand_tx(tk[3], h, false);
    perform public.tbl_confirm_hand_tx(tk[4], h, false);

    -- ── G 流局：按的人確認就生效；莊家連莊 ──
    r := public.tbl_submit_hand_tx(tk[1], 'draw', null, '[]');
    st := public.tbl_state_tx(tk[1]);
    v := v || case when r ->> 'status' = 'confirmed' and (st -> 'round' ->> 'renzhuang')::int = 3 and (st -> 'round' ->> 'hand_no')::int = 5
                  then '✅' else '🔴' end
           || ' G 流局：直接生效，連 ' || (st -> 'round' ->> 'renzhuang') || '、第 ' || (st -> 'round' ->> 'hand_no') || ' 局' || E'\n';

    -- ── H 整桌狀態：總和為 0、起始積分、紀錄筆數 ──
    --    紀錄 ＝ A、B、C、D（取消）、E、F（取消）、G ＝ 7 筆
    select sum(value::int) into i from jsonb_each_text(st -> 'totals');
    v := v || case when i = 0 and (st -> 'session' -> 'stake' ->> 'start_points')::int = 2000
                        and jsonb_array_length(st -> 'log') = 7
                  then '✅' else '🔴' end
           || ' H 四家總和 ' || i || '（應為 0）、起始積分 ' || (st -> 'session' -> 'stake' ->> 'start_points')
           || '、紀錄 ' || jsonb_array_length(st -> 'log') || ' 筆（應為 7）' || E'\n';

    -- ── I 咔啦碰不能付給自己 ──
    r := public.tbl_submit_hand_tx(tk[1], 'kala', 1::smallint, '[]');
    v := v || case when r ->> 'reason' = 'bad_target' then '✅' else '🔴' end
           || ' I 咔啦碰付給自己 ⇒ 擋下（' || coalesce(r ->> 'message', r::text) || '）' || E'\n';

    raise exception 'migi_rollback' using detail = v;
  exception when others then
    get stacked diagnostics m = message_text, dt = pg_exception_detail;
    perform set_config('migi.t',
      case when m = 'migi_rollback' then dt
           else '🔴 中途出錯：' || m || E'\n已經跑完的：\n' || v end, true);
  end;
end $$;
select coalesce(nullif(current_setting('migi.t', true), ''), '🔴 沒有訊息（上面的 DO 沒跑到）') as "結果（全部已回滾，一筆都沒留）";
