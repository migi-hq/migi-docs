-- ════════════════════════════════════════════════════════════════════
-- 2026-10-30 驗「換機代碼：平板接手、本人換裝置」的行為（交易內自己造樣本，最後整份回滾，一列都不留）
-- 先跑 sql/pending/2026-10-30_換機代碼平板接手與本人換裝置.sql，再跑這一份
--
-- 樣本：同一間店兩張現在沒開桌的桌 T、T2；T 開一場，測試01（B）坐 1 號位、用 T 的平板；測試02、03 坐 2、3 號位
--       T2 有一台空著的平板（借出去用）；B 與測試04（A）各有一支配好的手機
-- 每一格都在交易裡自己造前提，不借線上的牌局（硬規則 3.57）
-- ════════════════════════════════════════════════════════════════════
do $$
declare
  v_msg text := '';
  v_org uuid; v_store uuid; v_t uuid; v_t2 uuid; v_sess uuid; v_sess2 uuid;
  v_b uuid; v_c uuid; v_d uuid; v_a uuid;
  v_tab uuid; v_tab2 uuid; v_phb uuid; v_pha uuid; v_row uuid; v_other_store uuid; v_other_table uuid;
  c_tab  constant text := repeat('t', 40);   -- T 的平板
  c_tab2 constant text := repeat('u', 40);   -- T2 的平板（借出去）
  c_phb  constant text := repeat('b', 40);   -- B 的手機
  c_pha  constant text := repeat('a', 40);   -- A 的手機
  c_tab3 constant text := repeat('w', 40);   -- 別間店的平板
  r jsonb; v_code text; dv public.table_devices; sp public.session_players;
begin
  begin
    -- ── 前提 ──
    select t.store_id into v_store
      from tables t join stores st on st.id = t.store_id and not st.is_virtual
     where t.deleted_at is null and t.is_active
       and not exists (select 1 from table_sessions s where s.table_id = t.id and s.status = 'open' and s.deleted_at is null)
     group by t.store_id having count(*) >= 2
     order by count(*) desc limit 1;
    if v_store is null then raise exception '找不到有兩張空桌的店，這份測不了'; end if;
    select id, org_id into v_t, v_org from tables t
     where t.store_id = v_store and t.deleted_at is null and t.is_active
       and not exists (select 1 from table_sessions s where s.table_id = t.id and s.status = 'open' and s.deleted_at is null)
     order by t.label desc limit 1;
    select id into v_t2 from tables t
     where t.store_id = v_store and t.deleted_at is null and t.is_active and t.id <> v_t
       and not exists (select 1 from table_sessions s where s.table_id = t.id and s.status = 'open' and s.deleted_at is null)
     order by t.label desc limit 1;

    select id into v_b from members where is_test and phone = '0910000001';
    select id into v_c from members where is_test and phone = '0910000002';
    select id into v_d from members where is_test and phone = '0910000003';
    select id into v_a from members where is_test and phone = '0910000004';
    if v_b is null or v_c is null or v_d is null or v_a is null then raise exception '四個測試帳號不齊'; end if;
    if exists (select 1 from session_players x join table_sessions ts on ts.id = x.session_id
                where x.member_id in (v_b, v_c, v_d, v_a) and x.left_at is null and ts.status = 'open') then
      raise exception '測試帳號現在有牌局，這份測不了';
    end if;

    insert into table_sessions (org_id, store_id, table_id, mode, status, planned_minutes, planned_rounds, game_type, flower, is_test)
    values (v_org, v_store, v_t, 'private', 'open', 120, 1, '台麻', '無花', true) returning id into v_sess;
    insert into table_devices (org_id, store_id, table_id, label, token_hash, kind)
    values (v_org, v_store, v_t, '測試平板T', public._tbl_hash(c_tab), 'tablet') returning id into v_tab;
    insert into table_devices (org_id, store_id, table_id, label, token_hash, kind)
    values (v_org, v_store, v_t2, '測試平板T2', public._tbl_hash(c_tab2), 'tablet') returning id into v_tab2;
    insert into table_devices (org_id, label, token_hash, kind, member_id)
    values (v_org, '測試手機B', public._tbl_hash(c_phb), 'phone', v_b) returning id into v_phb;
    insert into table_devices (org_id, label, token_hash, kind, member_id)
    values (v_org, '測試手機A', public._tbl_hash(c_pha), 'phone', v_a) returning id into v_pha;

    insert into session_players (org_id, session_id, member_id, seat, device_id)
    values (v_org, v_sess, v_b, 1, v_tab) returning id into v_row;
    insert into session_players (org_id, session_id, member_id, seat) values (v_org, v_sess, v_c, 2), (v_org, v_sess, v_d, 3);

    -- ① T 的平板產生代碼；T2 的平板先看：同一個人換裝置、有頭像
    v_code := public.tbl_swap_code_tx(c_tab) ->> 'code';
    r := public.tbl_swap_redeem_tx(c_tab2, v_code, false);
    v_msg := v_msg || case when (r ->> 'preview')::boolean and (r ->> 'move')::boolean and r ? 'from_avatar'
                                 and r ->> 'from_name' is not null
                          then '✅ ① 別桌的平板預覽：換到這台平板（' || (r ->> 'from_name') || '，第 ' || (r ->> 'seat') || ' 位）、帶頭像'
                          else '🔴 ① ' || coalesce(r::text, 'null') end;

    -- ② 確認 ⇒ 位置換到 T2 的平板、帳號不變；那台記住這一場，認裝置時換成 T
    r := public.tbl_swap_redeem_tx(c_tab2, v_code, true);
    select * into sp from session_players where id = v_row;
    dv := public._tbl_device(c_tab2);
    v_msg := v_msg || E'\n' || case when (r ->> 'moved')::boolean and sp.member_id = v_b and sp.device_id = v_tab2
                                       and dv.table_id = v_t and dv.bound_session_id = v_sess
                                     then '✅ ② 位置換到借來的平板、帳號還是 B；那台平板現在算 T 這一桌'
                                     else '🔴 ② ' || coalesce(r::text, 'null') || ' / 桌 ' || coalesce(dv.table_id::text, 'null') end;

    -- ③ T 原本那台平板：還在 T、已經沒有位置；換裝置紀錄 to ＝ from
    dv := public._tbl_device(c_tab);
    v_msg := v_msg || E'\n' || case when dv.table_id = v_t
                                       and not exists (select 1 from session_players where session_id = v_sess and device_id = v_tab)
                                       and exists (select 1 from session_seat_swaps where code = v_code and used_at is not null
                                                    and to_member_id = from_member_id and to_device_id = v_tab2)
                                     then '✅ ③ 原本那台讓出位置；紀錄記成同一個人換裝置'
                                     else '🔴 ③ 原本那台或紀錄不對' end;

    -- ④ 借來的平板再產生代碼，B 自己配好的手機輸入 ⇒ 本人換到這支手機（原本會被「這就是你自己的位置」擋）
    v_code := public.tbl_swap_code_tx(c_tab2) ->> 'code';
    r := public.tbl_swap_redeem_tx(c_phb, v_code, false);
    v_msg := v_msg || E'\n' || case when (r ->> 'preview')::boolean and (r ->> 'move')::boolean
                                     then '✅ ④ 本人的手機預覽：換到這支手機' else '🔴 ④ ' || coalesce(r::text, 'null') end;
    r := public.tbl_swap_redeem_tx(c_phb, v_code, true);
    select * into sp from session_players where id = v_row;
    v_msg := v_msg || E'\n' || case when (r ->> 'moved')::boolean and sp.member_id = v_b and sp.device_id = v_phb
                                     then '✅ ④-2 確認後位置在 B 的手機上、帳號不變' else '🔴 ④-2 ' || coalesce(r::text, 'null') end;

    -- ⑤ 借來的平板不再坐在位置上 ⇒ 自動回家（T2）、綁定清掉
    dv := public._tbl_device(c_tab2);
    v_msg := v_msg || E'\n' || case when dv.table_id = v_t2 and dv.bound_session_id is null
                                       and (select bound_session_id from table_devices where id = v_tab2) is null
                                     then '✅ ⑤ 借來的平板讓出位置就回到 T2、綁定清掉'
                                     else '🔴 ⑤ 桌 ' || coalesce(dv.table_id::text, 'null') end;

    -- ⑥ 位置已經在這支手機上 ⇒ 擋
    v_code := public.tbl_swap_code_tx(c_phb) ->> 'code';
    r := public.tbl_swap_redeem_tx(c_phb, v_code, false);
    v_msg := v_msg || E'\n' || case when r ->> 'reason' = 'self' then '✅ ⑥ 位置已經在這支手機上時擋下' else '🔴 ⑥ ' || coalesce(r::text, 'null') end;

    -- ⑦ 正對照：別人（A）的手機 ⇒ 還是換人上桌，預覽有 to_name 與頭像、沒有 move
    r := public.tbl_swap_redeem_tx(c_pha, v_code, false);
    v_msg := v_msg || E'\n' || case when (r ->> 'preview')::boolean and not coalesce((r ->> 'move')::boolean, false)
                                       and r ->> 'to_name' is not null and r ? 'from_avatar'
                                     then '✅ ⑦ 正對照：別人的手機照舊是換人上桌（預覽多了頭像）'
                                     else '🔴 ⑦ ' || coalesce(r::text, 'null') end;

    -- ⑧ 平板正坐在別的牌局 ⇒ 擋（T2 開一場、A 坐那台平板）
    insert into table_sessions (org_id, store_id, table_id, mode, status, planned_minutes, planned_rounds, game_type, flower, is_test)
    values (v_org, v_store, v_t2, 'private', 'open', 120, 1, '台麻', '無花', true) returning id into v_sess2;
    insert into session_players (org_id, session_id, member_id, seat, device_id) values (v_org, v_sess2, v_a, 1, v_tab2);
    r := public.tbl_swap_redeem_tx(c_tab2, v_code, false);
    v_msg := v_msg || E'\n' || case when r ->> 'reason' = 'tablet_busy' then '✅ ⑧ 平板正在別的牌局計分時擋下' else '🔴 ⑧ ' || coalesce(r::text, 'null') end;

    -- ⑨ 別間店的平板 ⇒ 擋
    select t.id, t.store_id into v_other_table, v_other_store
      from tables t join stores st on st.id = t.store_id and not st.is_virtual
     where t.store_id <> v_store and t.deleted_at is null limit 1;
    if v_other_table is null then
      v_msg := v_msg || E'\n⚪ ⑨ 找不到別間店的桌，這一格測不了';
    else
      insert into table_devices (org_id, store_id, table_id, label, token_hash, kind)
      values (v_org, v_other_store, v_other_table, '測試平板別店', public._tbl_hash(c_tab3), 'tablet');
      r := public.tbl_swap_redeem_tx(c_tab3, v_code, false);
      v_msg := v_msg || E'\n' || case when r ->> 'reason' = 'other_store' then '✅ ⑨ 別間店的平板擋下' else '🔴 ⑨ ' || coalesce(r::text, 'null') end;
    end if;

    -- ⑩ 收桌之後借來的平板也會回家（重新借一次再收桌）
    update session_players set left_at = now(), device_id = null where session_id = v_sess2;   -- 樣本：讓 T2 的平板空出來
    update table_sessions set status = 'completed', ended_at = now() where id = v_sess2;
    v_code := public.tbl_swap_code_tx(c_phb) ->> 'code';
    r := public.tbl_swap_redeem_tx(c_tab2, v_code, true);
    update table_sessions set status = 'completed', ended_at = now() where id = v_sess;
    dv := public._tbl_device(c_tab2);
    v_msg := v_msg || E'\n' || case when (r ->> 'moved')::boolean and dv.table_id = v_t2 and dv.bound_session_id is null
                                     then '✅ ⑩ 借過去的那一場收桌，平板自己回到 T2'
                                     else '🔴 ⑩ ' || coalesce(r::text, 'null') || ' / 桌 ' || coalesce(dv.table_id::text, 'null') end;

    raise exception 'migi_rollback';
  exception when others then
    if sqlerrm <> 'migi_rollback' then v_msg := v_msg || E'\n🔴 中途出錯：' || sqlerrm; end if;
    perform set_config('migi.swap2', v_msg, true);
  end;
end $$;
select coalesce(nullif(current_setting('migi.swap2', true), ''), '🔴 沒有訊息') as "換機代碼平板接手與本人換裝置 行為測試（已回滾）";
