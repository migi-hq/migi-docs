/* ============================================================
   驗：包桌續時 · 各補各的（也可以替別人補）（行為測試）· 2026-10-01
   搭配 sql/pending/2026-10-01_包桌續時_各補各的.sql，**先跑那一份再跑這一份**。
   ⚠ 故意不提交：自己造一場包桌，最後 raise 'migi_rollback' 全部退掉（訊息寫在 handler 裡）。

   樣本：包桌 2 小時、台麻、一台測試平板
     A 入座時自己付並替 B 代付（續時**不管**這件事）
     C 入座時持當日暢打（續時不用補）
     D 自己付
   ============================================================ */
do $$
declare
  v_msg text := ''; v_pass int := 0; v_total int := 0;
  v_org uuid; v_store uuid; v_table uuid; v_sess uuid; v_dev uuid; v_round uuid;
  m uuid[];
  v_tok text := replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '');
  v_pkg jsonb; v_r jsonb; v_q jsonb; v_amt bigint; v_exp bigint; v_pct int; v_x05 bigint;
  v_p02 bigint; v_p05 bigint; v_p24 bigint; v_x24 bigint; v_err text; v_ok boolean; v_nameA text; v_nameC text;
begin
  select t.org_id, t.store_id, t.id into v_org, v_store, v_table
    from tables t join stores s on s.id = t.store_id
   where s.is_test and t.deleted_at is null
     and not exists (select 1 from table_sessions ts where ts.table_id = t.id and ts.status = 'open' and ts.deleted_at is null)
   order by t.label limit 1;
  select array_agg(x.id order by x.created_at) into m
    from (select mm.id, mm.created_at from members mm join wallets w on w.member_id = mm.id
           where mm.is_test and mm.deleted_at is null and mm.hidden_at is null
           order by mm.created_at limit 4) x;
  if v_table is null or coalesce(cardinality(m), 0) < 4 then
    v_msg := '🔴 找不到樣本（空的測試桌或四位測試會員）';
    raise exception 'migi_rollback';
  end if;
  select display_name into v_nameA from members where id = m[1];
  select display_name into v_nameC from members where id = m[3];

  insert into table_sessions (org_id, store_id, table_id, mode, status, planned_minutes, started_at, open_method, game_type, flower)
  values (v_org, v_store, v_table, 'private', 'open', 120, now(), 'manual', '台麻', '無花')
  returning id into v_sess;
  insert into session_players (org_id, session_id, member_id, join_type, status, charged_points, paid_by,
                               fee_waived_reason, fee_waived_amount, seat, joined_at)
  values (v_org, v_sess, m[1], 'opener', 'playing', 100, null, null,      0,   1, now()),
         (v_org, v_sess, m[2], 'opener', 'playing', 0,   m[1], null,      0,   2, now()),
         (v_org, v_sess, m[3], 'opener', 'playing', 0,   null, 'daypass', 100, 3, now()),
         (v_org, v_sess, m[4], 'opener', 'playing', 100, null, null,      0,   4, now());
  insert into table_devices (org_id, store_id, table_id, label, token_hash, is_active)
  values (v_org, v_store, v_table, '續時測試平板', public._tbl_hash(v_tok), true)
  returning id into v_dev;
  update session_players set device_id = v_dev where session_id = v_sess and member_id = m[1];

  -- ⓪ 還沒定座位：各補各的 ⇒ A、B、D 各 1 份，C 不用補；不看入座時 A 替 B 代付
  v_pkg := public._pkg_time(v_sess);
  v_err := (select string_agg(e ->> 'status', ',' order by (e ->> 'seat')::int) from jsonb_array_elements(v_pkg -> 'players') e);
  v_total := v_total + 1;
  v_ok := v_pkg ->> 'phase' = 'not_started' and (v_pkg ->> 'owed_shares')::int = 3 and v_err = 'owed,owed,daypass,owed'
      and not exists (select 1 from jsonb_array_elements(v_pkg -> 'players') e where e ->> 'payer_name' is not null);
  if v_ok then v_pass := v_pass + 1; end if;
  v_msg := v_msg || case when v_ok then '✅' else '🔴' end || ' ⓪ 還沒定座位：' || coalesce(v_pkg ->> 'phase', 'null')
        || '，' || coalesce(v_err, '—') || '，要補 ' || coalesce(v_pkg ->> 'owed_shares', '?') || ' 份（應為 owed,owed,daypass,owed、3 份，沒有代付人）' || E'\n';

  -- ⓐ 100 分鐘 ⇒ 提示；ⓑ 提示期間照樣能送一局
  insert into session_rounds (org_id, session_id, round_no, first_dealer_seat, started_at)
  values (v_org, v_sess, 1, 1, now() - interval '100 minutes') returning id into v_round;
  v_pkg := public._pkg_time(v_sess);
  v_total := v_total + 1;
  v_ok := v_pkg ->> 'phase' = 'warn';
  if v_ok then v_pass := v_pass + 1; end if;
  v_msg := v_msg || case when v_ok then '✅' else '🔴' end || ' ⓐ 100 分鐘：' || coalesce(v_pkg ->> 'phase', 'null') || '（應為 warn）' || E'\n';

  begin
    v_r := public.tbl_submit_hand_tx(v_tok, 'draw'); v_err := coalesce(v_r ->> 'reason', 'ok');
  exception when others then v_err := '例外：' || sqlerrm;
  end;
  v_total := v_total + 1;
  v_ok := v_err <> 'pkg_locked';
  if v_ok then v_pass := v_pass + 1; end if;
  v_msg := v_msg || case when v_ok then '✅' else '🔴' end || ' ⓑ 提示期間送一局：' || v_err || '（不可以是 pkg_locked）' || E'\n';

  -- ⓒ 140 分鐘 ⇒ 鎖定，送一局／開新一將都被擋
  update session_rounds set started_at = now() - interval '140 minutes' where id = v_round;
  begin
    v_r := public.tbl_submit_hand_tx(v_tok, 'draw'); v_err := coalesce(v_r ->> 'reason', 'ok');
  exception when others then v_err := '例外：' || sqlerrm;
  end;
  begin
    v_r := public.tbl_start_round_tx(v_tok, 1::smallint, 2::smallint, 3::smallint);
    v_err := v_err || '／' || coalesce(v_r ->> 'reason', 'ok');
  exception when others then v_err := v_err || '／例外：' || sqlerrm;
  end;
  v_total := v_total + 1;
  v_ok := (public._pkg_time(v_sess) ->> 'phase') = 'locked' and v_err = 'pkg_locked／pkg_locked';
  if v_ok then v_pass := v_pass + 1; end if;
  v_msg := v_msg || case when v_ok then '✅' else '🔴' end || ' ⓒ 140 分鐘鎖定，送一局／開新一將：' || v_err || E'\n';

  -- ⓓ 計分板狀態：四人名單、不含會員 id
  begin v_r := public.tbl_state_tx(v_tok); exception when others then v_r := jsonb_build_object('err', sqlerrm); end;
  v_total := v_total + 1;
  v_ok := v_r -> 'pkg' ->> 'phase' = 'locked' and jsonb_array_length(v_r -> 'pkg' -> 'players') = 4
      and not exists (select 1 from jsonb_array_elements(v_r -> 'pkg' -> 'players') e where e ? 'member_id')
      and not exists (select 1 from jsonb_array_elements(v_r -> 'pkg' -> 'payers') e where e ? 'member_id');
  if v_ok then v_pass := v_pass + 1; end if;
  v_msg := v_msg || case when v_ok then '✅' else '🔴' end || ' ⓓ 計分板狀態：' || coalesce(v_r -> 'pkg' ->> 'phase', v_r ->> 'err', 'null')
        || '，四人名單 ' || coalesce(jsonb_array_length(v_r -> 'pkg' -> 'players')::text, '?') || ' 人、不含會員 id' || E'\n';

  -- ⓔ 報價：C（暢打）替自己 ⇒ 不用補；A 替自己 ⇒ 1 份
  select unit_price into v_x05 from products where org_id = v_org and sku = 'SVC-TBL-PX05' and deleted_at is null;
  select coalesce((select t.discount_pct from members mm join member_tiers t on t.code = coalesce(mm.tier_override, mm.tier) and t.is_active
                    where mm.id = m[1]), 0) into v_pct;
  v_q := public.pos_pkg_quote_tx(v_sess, m[3]);
  v_err := coalesce(v_q ->> 'reason', 'ok');
  v_q := public.pos_pkg_quote_tx(v_sess, m[1]);
  v_exp := v_x05 - round(v_x05 * v_pct / 100.0);
  v_total := v_total + 1;
  v_ok := v_err = 'nothing_owed' and (v_q ->> 'owed')::int = 1 and (v_q ->> 'amount')::bigint = v_exp;
  if v_ok then v_pass := v_pass + 1; end if;
  v_msg := v_msg || case when v_ok then '✅' else '🔴' end || ' ⓔ 報價：C 替自己 ' || v_err || '；A 替自己 '
        || coalesce(v_q ->> 'owed', '?') || ' 份 $' || coalesce(v_q ->> 'amount', '?') || '（預期 $' || v_exp || '）' || E'\n';

  -- ⓕ A 在櫃檯替自己和 B 一起補（2 份）⇒ A、B 已補，B 寫「由 A 代付」，D 還沒補 ⇒ 仍鎖定
  v_q := public.pos_pkg_quote_tx(v_sess, m[1], array[m[1], m[2]]);
  v_amt := (v_q ->> 'amount')::bigint;
  v_r := public.pos_pkg_extend_tx(v_sess, m[1], array[m[1], m[2]], 0,
           jsonb_build_array(jsonb_build_object('method', 'cash', 'amount', v_amt, 'cash_received', v_amt, 'change_given', 0)),
           'test-pkg3-a-' || v_sess);
  v_pkg := public._pkg_time(v_sess);
  v_err := (select string_agg(e ->> 'status', ',' order by (e ->> 'seat')::int) from jsonb_array_elements(v_pkg -> 'players') e);
  v_total := v_total + 1;
  v_ok := coalesce((v_r ->> 'ok')::boolean, false) and (v_q ->> 'owed')::int = 2 and v_pkg ->> 'phase' = 'locked'
      and v_err = 'paid,paid,daypass,owed'
      and (select e ->> 'payer_name' from jsonb_array_elements(v_pkg -> 'players') e where (e ->> 'seat')::int = 2) = v_nameA
      and (select e ->> 'payer_name' from jsonb_array_elements(v_pkg -> 'players') e where (e ->> 'seat')::int = 1) is null;
  if v_ok then v_pass := v_pass + 1; end if;
  v_msg := v_msg || case when v_ok then '✅' else '🔴' end || ' ⓕ A 替自己和 B 補：' || coalesce(v_r ->> 'message', v_r ->> 'reason', 'ok')
        || '，' || coalesce(v_err, '—') || '（應為 paid,paid,daypass,owed、仍 locked、座位 2 由 A 代付）' || E'\n';

  -- ⓖ 該擋的：A 再替自己補 ⇒ nothing_owed；D 想替已經補過的 B 補 ⇒ not_owed
  v_q := public.pos_pkg_quote_tx(v_sess, m[1]);
  v_err := coalesce(v_q ->> 'reason', 'ok');
  v_q := public.pos_pkg_quote_tx(v_sess, m[4], array[m[2]]);
  v_err := v_err || '／' || coalesce(v_q ->> 'reason', 'ok');
  v_total := v_total + 1;
  v_ok := v_err = 'nothing_owed／not_owed';
  if v_ok then v_pass := v_pass + 1; end if;
  v_msg := v_msg || case when v_ok then '✅' else '🔴' end || ' ⓖ A 再補一次／D 替 B 補：' || v_err || '（應為 nothing_owed／not_owed）' || E'\n';

  -- ⓗ 持暢打的 C 替 D 付 ⇒ 全部補完，升到 5 小時，140 分鐘 ⇒ ok，計分板解鎖；座位 4 由 C 代付
  v_q := public.pos_pkg_quote_tx(v_sess, m[3], array[m[4]]);
  v_amt := (v_q ->> 'amount')::bigint;
  v_r := public.pos_pkg_extend_tx(v_sess, m[3], array[m[4]], 0,
           jsonb_build_array(jsonb_build_object('method', 'cash', 'amount', v_amt, 'cash_received', v_amt, 'change_given', 0)),
           'test-pkg3-c-' || v_sess);
  v_pkg := public._pkg_time(v_sess);
  begin
    v_q := public.tbl_start_round_tx(v_tok, 1::smallint, 2::smallint, 3::smallint); v_err := coalesce(v_q ->> 'reason', 'ok');
  exception when others then v_err := '例外：' || sqlerrm;
  end;
  v_total := v_total + 1;
  v_ok := coalesce((v_r ->> 'ok')::boolean, false) and v_pkg ->> 'phase' = 'ok'
      and (v_pkg ->> 'tier_minutes')::int = 300 and (v_pkg ->> 'next_minutes')::int = 1440 and v_err <> 'pkg_locked';
  if v_ok then v_pass := v_pass + 1; end if;
  v_msg := v_msg || case when v_ok then '✅' else '🔴' end || ' ⓗ 暢打的 C 替 D 付：' || coalesce(v_r ->> 'message', v_r ->> 'reason', 'ok')
        || '，' || coalesce(v_pkg ->> 'phase', 'null') || '、' || coalesce(v_pkg ->> 'tier_minutes', '?') || ' 分；開新一將回 ' || v_err || E'\n';

  -- ⓘ 延長紀錄：3 列，付款人 A、A、C，補到 300
  select string_agg(case e.paid_by when m[1] then 'A' when m[3] then 'C' else '?' end, ',' order by sp.seat)
    into v_err
    from session_extensions e join session_players sp on sp.session_id = e.session_id and sp.member_id = e.member_id
   where e.session_id = v_sess and e.to_minutes = 300;
  v_total := v_total + 1;
  v_ok := v_err = 'A,A,C';
  if v_ok then v_pass := v_pass + 1; end if;
  v_msg := v_msg || case when v_ok then '✅' else '🔴' end || ' ⓘ 延長紀錄（依座位的付款人）：' || coalesce(v_err, '沒有') || '（應為 A,A,C）' || E'\n';

  -- ⓙ 價格連動（同第一版，確認沒被動到）
  select unit_price into v_p02 from products where org_id = v_org and sku = 'SVC-TBL-P02' and deleted_at is null;
  select unit_price into v_p05 from products where org_id = v_org and sku = 'SVC-TBL-P05' and deleted_at is null;
  select unit_price into v_p24 from products where org_id = v_org and sku = 'SVC-TBL-P24' and deleted_at is null;
  update products set unit_price = v_p05 + 10 where org_id = v_org and sku = 'SVC-TBL-P05' and deleted_at is null;
  select unit_price into v_x05 from products where org_id = v_org and sku = 'SVC-TBL-PX05' and deleted_at is null;
  select unit_price into v_x24 from products where org_id = v_org and sku = 'SVC-TBL-PX24' and deleted_at is null;
  v_total := v_total + 1;
  v_ok := v_x05 = v_p05 + 10 - v_p02 and v_x24 = v_p24 - v_p05 - 10;
  if v_ok then v_pass := v_pass + 1; end if;
  v_msg := v_msg || case when v_ok then '✅' else '🔴' end || ' ⓙ 包桌檯費改價，延長價跟著變：' || v_x05 || '／' || v_x24 || E'\n';

  -- ⓚ 24 小時那一檔 ⇒ 封頂
  update table_sessions set planned_minutes = 1440 where id = v_sess;
  v_pkg := public._pkg_time(v_sess);
  v_total := v_total + 1;
  v_ok := v_pkg ->> 'phase' = 'capped';
  if v_ok then v_pass := v_pass + 1; end if;
  v_msg := v_msg || case when v_ok then '✅' else '🔴' end || ' ⓚ 24 小時那一檔：' || coalesce(v_pkg ->> 'phase', 'null') || '（應為 capped）' || E'\n';

  v_msg := v_msg || E'\n' || case when v_pass = v_total then '✅' else '🔴' end || ' 合計 ' || v_pass || '/' || v_total;
  raise exception 'migi_rollback';
exception when others then
  perform set_config('migi.pkg3test',
    v_msg || case when sqlerrm = 'migi_rollback' then '' else E'\n🔴 中途出錯：' || sqlerrm end, true);
end $$;

select coalesce(nullif(current_setting('migi.pkg3test', true), ''), '🔴 沒有測試訊息') as "包桌續時 · 各補各的（已回滾）";
