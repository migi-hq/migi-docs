-- ════════════════════════════════════════════════════════════════════
-- 2026-10-15 驗「計分板換人上桌」的行為（交易內自己造樣本，最後整份回滾，一列都不留）
-- 先跑 sql/pending/2026-10-15_計分板換人上桌.sql，再跑這一份
--
-- 樣本：一張現在沒開桌的桌、測試01（B，用平板）、測試02、測試03 入座；測試04（A，用自己的手機）不在任何牌局
-- 每一格都在交易裡自己造前提，不借線上的牌局（硬規則 3.57）
-- ════════════════════════════════════════════════════════════════════
do $$
declare
  v_msg text := '';
  v_org uuid; v_store uuid; v_table uuid; v_sess uuid; v_round uuid; v_hand uuid;
  v_b uuid; v_c uuid; v_d uuid; v_a uuid;
  v_tab uuid; v_ph uuid; v_row uuid; v_q uuid;
  c_tab constant text := repeat('t', 40);   -- 平板憑證（樣本用）
  c_ph  constant text := repeat('p', 40);   -- A 手機憑證（樣本用）
  r jsonb; r2 jsonb; v_code text; v_code1 text; n int;
  sp public.session_players;
begin
  begin
    -- ── 前提 ──
    select t.id, t.store_id, t.org_id into v_table, v_store, v_org
      from tables t
     where t.deleted_at is null and t.is_active
       and not exists (select 1 from table_sessions s where s.table_id = t.id and s.status = 'open' and s.deleted_at is null)
     order by t.label desc limit 1;
    if v_table is null then raise exception '找不到空桌，這份測不了'; end if;

    select id into v_b from members where is_test and phone = '0910000001';
    select id into v_c from members where is_test and phone = '0910000002';
    select id into v_d from members where is_test and phone = '0910000003';
    select id into v_a from members where is_test and phone = '0910000004';
    if v_b is null or v_c is null or v_d is null or v_a is null then raise exception '四個測試帳號不齊'; end if;
    -- 別名不可以叫 sp：下面有一個同名的變數，Postgres 會分不出是哪一個（10-15 第一次跑就撞到）
    if exists (select 1 from session_players x join table_sessions ts on ts.id = x.session_id
                where x.member_id in (v_b, v_c, v_d, v_a) and x.left_at is null and ts.status = 'open') then
      raise exception '測試帳號現在有牌局，這份測不了';
    end if;

    insert into table_sessions (org_id, store_id, table_id, mode, status, planned_minutes, planned_rounds, game_type, flower, is_test)
    values (v_org, v_store, v_table, 'private', 'open', 120, 1, '台麻', '無花', true) returning id into v_sess;
    insert into table_devices (org_id, store_id, table_id, label, token_hash, kind)
    values (v_org, v_store, v_table, '測試平板', public._tbl_hash(c_tab), 'tablet') returning id into v_tab;
    insert into table_devices (org_id, label, token_hash, kind, member_id)
    values (v_org, '測試手機', public._tbl_hash(c_ph), 'phone', v_a) returning id into v_ph;

    insert into session_players (org_id, session_id, member_id, seat, charged_points, fee_waived_amount, fee_waived_reason, device_id)
    values (v_org, v_sess, v_b, 1, 100, 0, null, v_tab) returning id into v_row;
    insert into session_players (org_id, session_id, member_id, seat) values (v_org, v_sess, v_c, 2), (v_org, v_sess, v_d, 3);
    -- 配桌房（10-15 補：使用者回報被換下的人報不了配桌 —— 名單沒跟著換）
    insert into match_queues (org_id, store_id, stake_level_id, play_at, status, matched_session_id, game_type)
    values (v_org, v_store, (select id from stake_levels where org_id = v_org limit 1), now(), 'seated', v_sess, '台麻')
    returning id into v_q;
    insert into match_queue_players (org_id, queue_id, member_id, join_source)
    values (v_org, v_q, v_b, 'browse'), (v_org, v_q, v_c, 'browse'), (v_org, v_q, v_d, 'browse');
    insert into session_extensions (org_id, session_id, member_id, paid_by, kind, to_minutes) values (v_org, v_sess, v_b, v_b, '2h', 240);
    insert into session_extensions (org_id, session_id, member_id, paid_by, kind, to_minutes) values (v_org, v_sess, v_b, v_b, 'daypass', null);

    -- ① B 那台產生代碼
    r := public.tbl_swap_code_tx(c_tab);
    v_code := r ->> 'code';
    v_msg := v_msg || case when (r ->> 'ok')::boolean and v_code ~ '^[0-9]{6}$'
                          then '✅ ① B 那台拿到 6 位數代碼' else '🔴 ① 產生代碼：' || r::text end;

    -- ② 再按一次 ⇒ 舊的作廢、只認新的
    v_code1 := v_code;
    r := public.tbl_swap_code_tx(c_tab);
    v_code := r ->> 'code';
    r2 := public.tbl_swap_redeem_tx(c_ph, v_code1, false);
    v_msg := v_msg || E'\n' || case when v_code1 = v_code then '⚪ ② 兩次剛好同一組（機率百萬分之一），這格測不了'
                                     when r2 ->> 'reason' = 'bad_code' then '✅ ② 重新產生後舊代碼失效'
                                     else '🔴 ② 舊代碼還能用：' || r2::text end;

    -- ③ 平板不能接手（要用接手的人自己的手機）
    r2 := public.tbl_swap_redeem_tx(c_tab, v_code, false);
    v_msg := v_msg || E'\n' || case when r2 ->> 'reason' = 'phone_only' then '✅ ③ 平板輸入代碼被擋（要用手機）' else '🔴 ③ ' || r2::text end;

    -- ④ 先看不換：回 B 的名字，位置還是 B
    r2 := public.tbl_swap_redeem_tx(c_ph, v_code, false);
    select * into sp from session_players where id = v_row;
    v_msg := v_msg || E'\n' || case when (r2 ->> 'preview')::boolean and sp.member_id = v_b
                                     then '✅ ④ 預覽回「' || (r2 ->> 'from_name') || ' 的位置、第 ' || (r2 ->> 'seat') || ' 位」，位置還沒動'
                                     else '🔴 ④ ' || r2::text end;

    -- ⑤ 有一局在等確認 ⇒ 擋
    insert into session_rounds (org_id, session_id, round_no, first_dealer_seat, status) values (v_org, v_sess, 1, 1, 'playing') returning id into v_round;
    insert into hands (org_id, session_id, round_id, hand_no, wind, dealer_seat, result, status)
    values (v_org, v_sess, v_round, 1, 1, 1, 'draw', 'pending') returning id into v_hand;
    r2 := public.tbl_swap_redeem_tx(c_ph, v_code, true);
    v_msg := v_msg || E'\n' || case when r2 ->> 'reason' = 'pending' then '✅ ⑤ 有一局在等確認時擋下' else '🔴 ⑤ ' || r2::text end;
    update hands set status = 'undone', undone_at = now() where id = v_hand;   -- 不用 delete：怕有擋刪除的觸發器

    -- ⑥ 真的換（B 那一列順便標成暢打免收，看它有沒有改成不跟著走）
    update session_players set fee_waived_reason = 'daypass', fee_waived_amount = 100 where id = v_row;
    r2 := public.tbl_swap_redeem_tx(c_ph, v_code, true);
    select * into sp from session_players where id = v_row;
    v_msg := v_msg || E'\n' || case when (r2 ->> 'swapped')::boolean and sp.member_id = v_a and sp.device_id = v_ph
                                       and sp.join_type = 'sub' and sp.seat = 1 and sp.paid_by = v_b and sp.charged_points = 0
                                     then '✅ ⑥ 換好了：第 1 位變成 A、綁 A 的手機、記成替補、檯費記 B 出的'
                                     else '🔴 ⑥ ' || r2::text || ' / ' || to_jsonb(sp)::text end;

    -- ⑦ B 在這一場一列都不剩（這一場算沒打）
    select count(*) into n from session_players where session_id = v_sess and member_id = v_b;
    v_msg := v_msg || E'\n' || case when n = 0 then '✅ ⑦ B 在這一場不留任何一列' else '🔴 ⑦ B 還有 ' || n || ' 列' end;

    -- ⑧ 加的 2 小時跟著位置走；暢打升級留在 B 身上；暢打免收改記 daypass_swapped
    v_msg := v_msg || E'\n' || case when (select count(*) from session_extensions where session_id = v_sess and member_id = v_a and kind = '2h') = 1
                                       and (select count(*) from session_extensions where session_id = v_sess and member_id = v_b and kind = 'daypass') = 1
                                       and sp.fee_waived_reason = 'daypass_swapped' and sp.fee_waived_amount = 100
                                     then '✅ ⑧ 2 小時跟著位置、暢打留給 B、免收金額照留（原因改 daypass_swapped）'
                                     else '🔴 ⑧ 加時間或暢打搬錯' end;

    -- ⑧-2 配桌名單一起換：B 標成被換下、A 補進來、房裡還是 3 人；B 報名檢查不再被這一場擋
    v_msg := v_msg || E'\n' || case
      when exists (select 1 from match_queue_players where queue_id = v_q and member_id = v_b and left_at is not null and leave_reason = 'swapped')
       and exists (select 1 from match_queue_players where queue_id = v_q and member_id = v_a and left_at is null and join_source = 'swap')
       and (select count(*) from match_queue_players where queue_id = v_q and left_at is null) = 3
      then '✅ ⑧-2 配桌名單一起換：B 標成被換下、A 補進名單、人數不變' else '🔴 ⑧-2 配桌名單沒換好' end;
    begin
      perform public._check_join_conflict(v_org, v_b, now(), 'member');
      v_msg := v_msg || E'\n✅ ⑧-3 被換下的 B 可以再報名配桌（不再被這一場擋）';
    exception when others then
      v_msg := v_msg || E'\n🔴 ⑧-3 B 還是被擋：' || sqlerrm;
    end;
    -- 正對照：還在這一場的 C 仍然被擋（沒有把整房放掉）
    begin
      perform public._check_join_conflict(v_org, v_c, now(), 'member');
      v_msg := v_msg || E'\n🔴 ⑧-4 C 沒被擋 —— 檢查失效了';
    exception when others then
      v_msg := v_msg || E'\n✅ ⑧-4 正對照：還在這一場的 C 照樣被擋';
    end;

    -- ⑨ 換人紀錄留下原樣
    v_msg := v_msg || E'\n' || coalesce((select case when used_at is not null and to_member_id = v_a and (before_row ->> 'member_id')::uuid = v_b
                                                         and (before_row ->> 'charged_points')::int = 100 and moved_extensions = 1 and moved_queue_rows = 1
                                                    then '✅ ⑨ 紀錄留下換人前的原樣（原本收 100、搬了 1 筆加時間）' else '🔴 ⑨ 紀錄不完整' end
                                         from session_seat_swaps where code = v_code), '🔴 ⑨ 找不到紀錄');

    -- ⑩ 同一組代碼不能再用
    r2 := public.tbl_swap_redeem_tx(c_ph, v_code, true);
    v_msg := v_msg || E'\n' || case when r2 ->> 'reason' = 'bad_code' then '✅ ⑩ 用過的代碼不能再用' else '🔴 ⑩ ' || r2::text end;

    -- ⑪ 平板那台現在沒有選人（位置交給 A 的手機了）⇒ 再要代碼會被擋；A 的手機自己要得到
    r := public.tbl_swap_code_tx(c_tab);
    r2 := public.tbl_swap_code_tx(c_ph);
    v_msg := v_msg || E'\n' || case when r ->> 'reason' = 'not_seated' and (r2 ->> 'ok')::boolean
                                     then '✅ ⑪ 平板已讓出位置；A 的手機可以再把位置交給別人'
                                     else '🔴 ⑪ ' || r::text || ' / ' || r2::text end;

    -- ⑫ 已經在這一桌的人不能接手（拿 A 剛產生的碼，用 A 自己的手機輸入 ⇒ 是自己的位置）
    r := public.tbl_swap_redeem_tx(c_ph, r2 ->> 'code', false);
    v_msg := v_msg || E'\n' || case when r ->> 'reason' = 'self' then '✅ ⑫ 輸入自己位置的代碼被擋' else '🔴 ⑫ ' || r::text end;

    -- ⑬ 亂猜：錯 8 次之後連對的也擋
    for n in 1..8 loop perform public.tbl_swap_redeem_tx(c_ph, '000000', false); end loop;
    r := public.tbl_swap_redeem_tx(c_ph, r2 ->> 'code', false);
    v_msg := v_msg || E'\n' || case when r ->> 'reason' = 'too_many' then '✅ ⑬ 錯 8 次之後先擋 10 分鐘' else '🔴 ⑬ ' || r::text end;

    raise exception 'migi_rollback';
  exception when others then
    if sqlerrm <> 'migi_rollback' then v_msg := v_msg || E'\n🔴 中途出錯：' || sqlerrm; end if;
    perform set_config('migi.swap', v_msg, true);
  end;
end $$;
select coalesce(nullif(current_setting('migi.swap', true), ''), '🔴 沒有訊息') as "換人上桌 行為測試（已回滾）";
