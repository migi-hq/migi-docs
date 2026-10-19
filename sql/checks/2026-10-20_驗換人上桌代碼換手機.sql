-- ════════════════════════════════════════════════════════════════════
-- 2026-10-20 驗「換人上桌的代碼也能換手機」（交易內自己造樣本，最後整份回滾，一列都不留）
-- 先跑 sql/pending/2026-10-20_換人上桌代碼也能換手機.sql，再跑這一份
--
-- 樣本：一張現在沒開桌的桌；測試01（B）用自己的舊手機入座、測試02（C）用平板入座、
--       測試03（D）入座沒綁裝置；測試04（A）有自己配好的手機、不在這一桌
-- ════════════════════════════════════════════════════════════════════
do $$
declare
  v_msg text := '';
  v_org uuid; v_store uuid; v_table uuid; v_sess uuid;
  v_b uuid; v_c uuid; v_d uuid; v_a uuid;
  v_tab uuid; v_old uuid; v_aph uuid; v_rowb uuid; v_rowc uuid; v_new uuid;
  c_tab constant text := repeat('t', 40);   -- 平板
  c_old constant text := repeat('o', 40);   -- B 的舊手機
  c_aph constant text := repeat('a', 40);   -- A 的手機
  r jsonb; v_code text; v_pc text; n int;
begin
  begin
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
    if exists (select 1 from session_players x join table_sessions ts on ts.id = x.session_id
                where x.member_id in (v_b, v_c, v_d, v_a) and x.left_at is null and ts.status = 'open') then
      raise exception '測試帳號現在有牌局，這份測不了';
    end if;
    -- 測試帳號身上原本的手機先停掉（交易內，最後會回滾），免得「一人一支」把線上的算進來
    update table_devices set is_active = false, revoked_at = now()
     where kind = 'phone' and member_id in (v_b, v_c, v_d, v_a) and is_active;

    insert into table_sessions (org_id, store_id, table_id, mode, status, planned_minutes, planned_rounds, game_type, flower, is_test)
    values (v_org, v_store, v_table, 'private', 'open', 120, 1, '台麻', '無花', true) returning id into v_sess;
    insert into table_devices (org_id, store_id, table_id, label, token_hash, kind)
    values (v_org, v_store, v_table, '測試平板', public._tbl_hash(c_tab), 'tablet') returning id into v_tab;
    insert into table_devices (org_id, label, token_hash, kind, member_id)
    values (v_org, '測試舊手機', public._tbl_hash(c_old), 'phone', v_b) returning id into v_old;
    insert into table_devices (org_id, label, token_hash, kind, member_id)
    values (v_org, '測試A手機', public._tbl_hash(c_aph), 'phone', v_a) returning id into v_aph;

    insert into session_players (org_id, session_id, member_id, seat, device_id) values (v_org, v_sess, v_b, 1, v_old) returning id into v_rowb;
    insert into session_players (org_id, session_id, member_id, seat, device_id) values (v_org, v_sess, v_c, 2, v_tab) returning id into v_rowc;
    insert into session_players (org_id, session_id, member_id, seat) values (v_org, v_sess, v_d, 3);

    -- ① B 在舊手機上按「換一支手機」拿代碼，新手機（還沒配對）輸入 ⇒ 換手機成功
    v_code := public.tbl_swap_code_tx(c_old) ->> 'code';
    r := public.tbl_phone_redeem_tx(v_code, null);
    select id into v_new from table_devices where token_hash = public._tbl_hash(r ->> 'token');
    v_msg := v_msg || case when (r ->> 'ok')::boolean and (r ->> 'changed_phone')::boolean and not (r ->> 'this_game_only')::boolean
                             and (select member_id from table_devices where id = v_new) = v_b
                             and (select bound_session_id from table_devices where id = v_new) is null
                          then '✅ ① 新手機輸入換人上桌代碼 ⇒ 變成 B 的手機計分板（永久，不限這一場）'
                          else '🔴 ① ' || r::text end;

    -- ② B 的位置交給新手機、帳號還是 B、舊手機停用
    v_msg := v_msg || E'\n' || case when (select device_id from session_players where id = v_rowb) = v_new
                                       and (select member_id from session_players where id = v_rowb) = v_b
                                       and (select not is_active and revoked_at is not null from table_devices where id = v_old)
                                     then '✅ ② 第 1 位綁到新手機、帳號仍是 B、舊手機停用'
                                     else '🔴 ② 位置或舊手機不對' end;

    -- ③ 紀錄：to ＝ from（換手機，不是換人）、指向新手機
    v_msg := v_msg || E'\n' || coalesce((select case when used_at is not null and to_member_id = v_b and from_member_id = v_b and to_device_id = v_new
                                                    then '✅ ③ 換人紀錄記成 B → B（換手機）、指向新手機' else '🔴 ③ 紀錄不對' end
                                         from session_seat_swaps where code = v_code and session_id = v_sess), '🔴 ③ 找不到紀錄');

    -- ④ 同一組代碼不能再用
    r := public.tbl_phone_redeem_tx(v_code, null);
    v_msg := v_msg || E'\n' || case when r ->> 'reason' = 'bad_code' then '✅ ④ 用過的代碼不能再用' else '🔴 ④ ' || r::text end;

    -- ⑤ 平板給的代碼（C 在平板上）也一樣：新手機輸入 ⇒ C 的位置交給新手機、平板變成沒有選人
    v_code := public.tbl_swap_code_tx(c_tab) ->> 'code';
    r := public.tbl_phone_redeem_tx(v_code, null);
    v_msg := v_msg || E'\n' || case when (r ->> 'changed_phone')::boolean
                                       and (select d.member_id from session_players sp join table_devices d on d.id = sp.device_id where sp.id = v_rowc) = v_c
                                       and (select d.kind from session_players sp join table_devices d on d.id = sp.device_id where sp.id = v_rowc) = 'phone'
                                       and not exists (select 1 from session_players where session_id = v_sess and device_id = v_tab)
                                     then '✅ ⑤ 平板給的代碼：C 的位置換到新手機，平板讓出' else '🔴 ⑤ ' || r::text end;

    -- ⑦ 一般配對碼照樣能用（回歸）：D 配一支手機（一般配對碼不綁座位 —— 座位由手機打開時自己接上，10-20 第一次跑期望值寫錯）
    v_pc := public._tbl_new_phone_code(v_org, v_d, null, null, null, now() + interval '1 hour');
    r := public.tbl_phone_redeem_tx(v_pc, null);
    v_msg := v_msg || E'\n' || case when (r ->> 'ok')::boolean and not (r ->> 'changed_phone')::boolean
                                       and (select member_id from table_devices where token_hash = public._tbl_hash(r ->> 'token')) = v_d
                                     then '✅ ⑦ 一般配對碼照樣能配，手機屬於 D（不是換手機）' else '🔴 ⑦ ' || r::text end;
    -- ⑥ 讓 D 的手機坐上他的位置、給一組代碼；別人（A）已經配好的手機在「輸入配對碼」輸入 ⇒ 不換，請他走「接手別人的位置」
    update session_players set device_id = (select id from table_devices where token_hash = public._tbl_hash(r ->> 'token'))
     where session_id = v_sess and member_id = v_d;
    v_code := public.tbl_swap_code_tx(r ->> 'token') ->> 'code';
    if v_code is null then raise exception 'D 的手機拿不到代碼，⑥ 測不了'; end if;
    r := public.tbl_phone_redeem_tx(v_code, c_aph);
    v_msg := v_msg || E'\n' || case when r ->> 'reason' = 'use_takeover'
                                       and (select member_id from table_devices where id = v_aph) = v_a
                                       and (select used_at from session_seat_swaps where code = v_code and session_id = v_sess) is null
                                     then '✅ ⑥ A 的手機在配對頁輸入 ⇒ 擋下並請他走「接手別人的位置」，代碼沒被用掉'
                                     else '🔴 ⑥ ' || r::text end;

    -- ⑧ 亂打的碼照舊算錯一次
    select count(*) into n from table_phone_code_fails;
    r := public.tbl_phone_redeem_tx('999999', null);
    v_msg := v_msg || E'\n' || case when r ->> 'reason' = 'bad_code' and (select count(*) from table_phone_code_fails) = n + 1
                                     then '✅ ⑧ 亂打的碼回「配對碼不對」並記一次錯' else '🔴 ⑧ ' || r::text end;

    raise exception 'migi_rollback';
  exception when others then
    if sqlerrm <> 'migi_rollback' then v_msg := v_msg || E'\n🔴 中途出錯：' || sqlerrm; end if;
    perform set_config('migi.phswap', v_msg, true);
  end;
end $$;
select coalesce(nullif(current_setting('migi.phswap', true), ''), '🔴 沒有訊息') as "換人上桌代碼換手機 行為測試（已回滾）";
