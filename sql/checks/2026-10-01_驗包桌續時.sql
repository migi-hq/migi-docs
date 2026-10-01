/* ============================================================
   驗：包桌續時（行為測試）· 2026-10-01
   搭配 sql/pending/2026-10-01_包桌續時.sql，**先跑那一份再跑這一份**。

   ⚠ 這一份**故意不提交**：在交易裡自己造一場包桌，最後 raise 'migi_rollback' 全部退掉。
     訊息寫在 exception handler 裡（硬規則 3.9），所以回滾之後還讀得到。

   樣本（自己造，不借線上的場次 —— 硬規則 3.57）：
     包桌 2 小時、台麻、一台測試平板
     A 自己付 ＋ 替 B 代付（A 要補 2 份）
     C 入座時持當日暢打（不用補）
     D 自己付（要補 1 份）
   ============================================================ */
do $$
declare
  v_msg text := ''; v_pass int := 0; v_total int := 0;
  v_org uuid; v_store uuid; v_table uuid; v_sess uuid; v_dev uuid; v_round uuid;
  m uuid[];
  v_tok text := replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '');
  v_pkg jsonb; v_r jsonb; v_q jsonb; v_amt bigint; v_exp bigint; v_pct int; v_x05 bigint; v_x24 bigint;
  v_p02 bigint; v_p05 bigint; v_p24 bigint; v_err text; v_ok boolean;
begin
  -- ── 借：一張沒在用的測試桌、四位帶錢包的測試會員 ──
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

  -- ── 造：包桌 2 小時 ──
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

  -- ⓪ 還沒定座位：不計時，但份數已經算得出來
  v_pkg := public._pkg_time(v_sess);
  v_total := v_total + 1;
  v_ok := v_pkg ->> 'phase' = 'not_started' and (v_pkg ->> 'owed_shares')::int = 3
      and (select (e ->> 'owed')::int from jsonb_array_elements(v_pkg -> 'payers') e where (e ->> 'member_id')::uuid = m[1]) = 2
      and (select (e ->> 'owed')::int from jsonb_array_elements(v_pkg -> 'payers') e where (e ->> 'member_id')::uuid = m[4]) = 1
      and not exists (select 1 from jsonb_array_elements(v_pkg -> 'payers') e where (e ->> 'member_id')::uuid in (m[2], m[3]));
  if v_ok then v_pass := v_pass + 1; end if;
  v_msg := v_msg || case when v_ok then '✅' else '🔴' end || ' ⓪ 還沒定座位：' || coalesce(v_pkg ->> 'phase', 'null')
        || '，要補 ' || coalesce(v_pkg ->> 'owed_shares', '?') || ' 份（A 2、D 1；代付的 B 與暢打的 C 不出現）' || E'\n';

  -- ⓐ 定好座位 100 分鐘（到期前 20 分鐘）⇒ 提示
  insert into session_rounds (org_id, session_id, round_no, first_dealer_seat, started_at)
  values (v_org, v_sess, 1, 1, now() - interval '100 minutes') returning id into v_round;
  v_pkg := public._pkg_time(v_sess);
  v_total := v_total + 1;
  v_ok := v_pkg ->> 'phase' = 'warn' and (v_pkg ->> 'tier_minutes')::int = 120 and (v_pkg ->> 'next_minutes')::int = 300;
  if v_ok then v_pass := v_pass + 1; end if;
  v_msg := v_msg || case when v_ok then '✅' else '🔴' end || ' ⓐ 100 分鐘：' || coalesce(v_pkg ->> 'phase', 'null')
        || '（應為 warn；目前 ' || coalesce(v_pkg ->> 'tier_minutes', '?') || ' 分、下一檔 ' || coalesce(v_pkg ->> 'next_minutes', '?') || '）' || E'\n';

  -- ⓑ 正對照：提示期間照樣能記分（送一把流局，回的不是 pkg_locked）
  begin
    v_r := public.tbl_submit_hand_tx(v_tok, 'draw');
    v_err := coalesce(v_r ->> 'reason', 'ok');
  exception when others then v_err := '例外：' || sqlerrm;
  end;
  v_total := v_total + 1;
  v_ok := v_err <> 'pkg_locked';
  if v_ok then v_pass := v_pass + 1; end if;
  v_msg := v_msg || case when v_ok then '✅' else '🔴' end || ' ⓑ 提示期間送一局：' || v_err || '（不可以是 pkg_locked）' || E'\n';

  -- ⓒ 130 分鐘 ⇒ 寬限；140 分鐘 ⇒ 鎖定
  update session_rounds set started_at = now() - interval '130 minutes' where id = v_round;
  v_pkg := public._pkg_time(v_sess);
  v_total := v_total + 1;
  v_ok := v_pkg ->> 'phase' = 'grace';
  if v_ok then v_pass := v_pass + 1; end if;
  v_msg := v_msg || case when v_ok then '✅' else '🔴' end || ' ⓒ 130 分鐘：' || coalesce(v_pkg ->> 'phase', 'null') || '（應為 grace）' || E'\n';

  update session_rounds set started_at = now() - interval '140 minutes' where id = v_round;
  v_pkg := public._pkg_time(v_sess);
  v_total := v_total + 1;
  v_ok := v_pkg ->> 'phase' = 'locked' and (v_pkg ->> 'locked')::boolean;
  if v_ok then v_pass := v_pass + 1; end if;
  v_msg := v_msg || case when v_ok then '✅' else '🔴' end || ' ⓓ 140 分鐘：' || coalesce(v_pkg ->> 'phase', 'null') || '（應為 locked）' || E'\n';

  -- ⓔ 鎖定時：送一局、開新一將都被擋
  begin
    v_r := public.tbl_submit_hand_tx(v_tok, 'draw');
    v_err := coalesce(v_r ->> 'reason', 'ok');
  exception when others then v_err := '例外：' || sqlerrm;
  end;
  begin
    v_r := public.tbl_start_round_tx(v_tok, 1::smallint, 2::smallint, 3::smallint);
    v_err := v_err || '／' || coalesce(v_r ->> 'reason', 'ok');
  exception when others then v_err := v_err || '／例外：' || sqlerrm;
  end;
  v_total := v_total + 1;
  v_ok := v_err = 'pkg_locked／pkg_locked';
  if v_ok then v_pass := v_pass + 1; end if;
  v_msg := v_msg || case when v_ok then '✅' else '🔴' end || ' ⓔ 鎖定時送一局／開新一將：' || v_err || E'\n';

  -- ⓕ 計分板狀態帶 pkg，而且不含會員 id；POS 桌況帶 pkg_phase
  begin
    v_r := public.tbl_state_tx(v_tok);
  exception when others then v_r := jsonb_build_object('err', sqlerrm);
  end;
  v_total := v_total + 1;
  v_ok := v_r -> 'pkg' ->> 'phase' = 'locked'
      and jsonb_array_length(v_r -> 'pkg' -> 'payers') = 2
      and not exists (select 1 from jsonb_array_elements(v_r -> 'pkg' -> 'payers') e where e ? 'member_id');
  if v_ok then v_pass := v_pass + 1; end if;
  v_msg := v_msg || case when v_ok then '✅' else '🔴' end || ' ⓕ 計分板狀態：' || coalesce(v_r -> 'pkg' ->> 'phase', coalesce(v_r ->> 'err', 'null'))
        || '，名單 ' || coalesce(jsonb_array_length(v_r -> 'pkg' -> 'payers')::text, '?') || ' 人、不含會員 id' || E'\n';

  -- ⓕ2（第二版）四人名單：依座位，A 還沒補、B 還沒補且寫出代付人、C 暢打、D 還沒補
  v_total := v_total + 1;
  v_err := (select string_agg(e ->> 'status', ',' order by (e ->> 'seat')::int) from jsonb_array_elements(v_r -> 'pkg' -> 'players') e);
  v_ok := jsonb_array_length(coalesce(v_r -> 'pkg' -> 'players', '[]')) = 4
      and v_err = 'owed,owed,daypass,owed'
      and (select e ->> 'payer_name' from jsonb_array_elements(v_r -> 'pkg' -> 'players') e where (e ->> 'seat')::int = 2) is not null
      and (select e ->> 'payer_name' from jsonb_array_elements(v_r -> 'pkg' -> 'players') e where (e ->> 'seat')::int = 1) is null
      and not exists (select 1 from jsonb_array_elements(v_r -> 'pkg' -> 'players') e where e ? 'member_id');
  if v_ok then v_pass := v_pass + 1; end if;
  v_msg := v_msg || case when v_ok then '✅' else '🔴' end || ' ⓕ2 四人名單：' || coalesce(v_err, '沒有')
        || '（應為 owed,owed,daypass,owed；座位 2 寫出代付人、不含會員 id）' || E'\n';

  v_r := public.list_tables_tx(v_org, v_store);
  select e ->> 'pkg_phase' into v_err
    from jsonb_path_query(v_r, 'lax $.**') e
   where jsonb_typeof(e) = 'object' and (e ->> 'table_id' = v_table::text or e ->> 'id' = v_table::text)
     and e ? 'pkg_phase'
   limit 1;
  v_total := v_total + 1;
  v_ok := v_err = 'locked';
  if v_ok then v_pass := v_pass + 1; end if;
  v_msg := v_msg || case when v_ok then '✅' else '🔴' end || ' ⓖ POS 桌況：pkg_phase = ' || coalesce(v_err, 'null') || E'\n';

  -- ⓗ 報價：C（暢打）不用補；A 補 2 份，金額＝ 2 × 延長價 − 等級折扣
  v_q := public.pos_pkg_quote_tx(v_sess, m[3]);
  select unit_price into v_x05 from products where org_id = v_org and sku = 'SVC-TBL-PX05' and deleted_at is null;
  select coalesce((select t.discount_pct from members mm join member_tiers t on t.code = coalesce(mm.tier_override, mm.tier) and t.is_active
                    where mm.id = m[1]), 0) into v_pct;
  v_exp := 2 * v_x05 - round(2 * v_x05 * v_pct / 100.0);
  v_err := coalesce(v_q ->> 'reason', 'ok');
  v_q := public.pos_pkg_quote_tx(v_sess, m[1]);
  v_amt := (v_q ->> 'amount')::bigint;
  v_total := v_total + 1;
  v_ok := v_err = 'nothing_owed' and (v_q ->> 'owed')::int = 2 and v_amt = v_exp;
  if v_ok then v_pass := v_pass + 1; end if;
  v_msg := v_msg || case when v_ok then '✅' else '🔴' end || ' ⓗ 報價：C ' || v_err || '；A 補 ' || coalesce(v_q ->> 'owed', '?')
        || ' 份 $' || coalesce(v_amt::text, '?') || '（預期 $' || v_exp || '，延長價 ' || v_x05 || '、等級折 ' || v_pct || '%）' || E'\n';

  -- ⓘ A 先付：還是鎖著（D 還沒補）
  v_r := public.pos_pkg_extend_tx(v_sess, m[1], 0,
           jsonb_build_array(jsonb_build_object('method', 'cash', 'amount', v_amt, 'cash_received', v_amt, 'change_given', 0)),
           'test-pkg-a-' || v_sess);
  v_pkg := public._pkg_time(v_sess);
  v_total := v_total + 1;
  v_ok := coalesce((v_r ->> 'ok')::boolean, false) and v_pkg ->> 'phase' = 'locked'
      and (select (e ->> 'owed')::int from jsonb_array_elements(v_pkg -> 'payers') e where (e ->> 'member_id')::uuid = m[1]) = 0
      and (select (e ->> 'owed')::int from jsonb_array_elements(v_pkg -> 'payers') e where (e ->> 'member_id')::uuid = m[4]) = 1;
  if v_ok then v_pass := v_pass + 1; end if;
  v_msg := v_msg || case when v_ok then '✅' else '🔴' end || ' ⓘ A 付完：' || coalesce(v_r ->> 'message', v_r ->> 'reason', 'ok')
        || '，狀態 ' || coalesce(v_pkg ->> 'phase', 'null') || '（應仍 locked，A 欠 0、D 欠 1）' || E'\n';

  -- ⓘ2（第二版）A 付完：A 與他代付的 B 都變已補，D 還沒補
  v_total := v_total + 1;
  v_err := (select string_agg(e ->> 'status', ',' order by (e ->> 'seat')::int) from jsonb_array_elements(v_pkg -> 'players') e);
  v_ok := v_err = 'paid,paid,daypass,owed';
  if v_ok then v_pass := v_pass + 1; end if;
  v_msg := v_msg || case when v_ok then '✅' else '🔴' end || ' ⓘ2 A 付完後四人名單：' || coalesce(v_err, '沒有')
        || '（應為 paid,paid,daypass,owed）' || E'\n';

  -- ⓙ A 再付一次：沒有要補的了
  v_q := public.pos_pkg_quote_tx(v_sess, m[1]);
  v_total := v_total + 1;
  v_ok := v_q ->> 'reason' = 'nothing_owed';
  if v_ok then v_pass := v_pass + 1; end if;
  v_msg := v_msg || case when v_ok then '✅' else '🔴' end || ' ⓙ A 再補一次：' || coalesce(v_q ->> 'reason', 'ok') || '（應為 nothing_owed）' || E'\n';

  -- ⓚ D 也付：升到 5 小時，140 分鐘 ⇒ ok，計分板解鎖
  v_q := public.pos_pkg_quote_tx(v_sess, m[4]);
  v_amt := (v_q ->> 'amount')::bigint;
  v_r := public.pos_pkg_extend_tx(v_sess, m[4], 0,
           jsonb_build_array(jsonb_build_object('method', 'cash', 'amount', v_amt, 'cash_received', v_amt, 'change_given', 0)),
           'test-pkg-d-' || v_sess);
  v_pkg := public._pkg_time(v_sess);
  begin
    v_q := public.tbl_start_round_tx(v_tok, 1::smallint, 2::smallint, 3::smallint);
    v_err := coalesce(v_q ->> 'reason', 'ok');
  exception when others then v_err := '例外：' || sqlerrm;
  end;
  v_total := v_total + 1;
  v_ok := coalesce((v_r ->> 'ok')::boolean, false) and v_pkg ->> 'phase' = 'ok'
      and (v_pkg ->> 'tier_minutes')::int = 300 and (v_pkg ->> 'next_minutes')::int = 1440 and v_err <> 'pkg_locked';
  if v_ok then v_pass := v_pass + 1; end if;
  v_msg := v_msg || case when v_ok then '✅' else '🔴' end || ' ⓚ D 也付完：' || coalesce(v_pkg ->> 'phase', 'null') || '、'
        || coalesce(v_pkg ->> 'tier_minutes', '?') || ' 分；開新一將回 ' || v_err || '（不可以是 pkg_locked）' || E'\n';

  -- ⓛ 包桌檯費改價 ⇒ 延長價自動跟著變；直接改延長價被擋
  select unit_price into v_p02 from products where org_id = v_org and sku = 'SVC-TBL-P02' and deleted_at is null;
  select unit_price into v_p05 from products where org_id = v_org and sku = 'SVC-TBL-P05' and deleted_at is null;
  select unit_price into v_p24 from products where org_id = v_org and sku = 'SVC-TBL-P24' and deleted_at is null;
  update products set unit_price = v_p05 + 10 where org_id = v_org and sku = 'SVC-TBL-P05' and deleted_at is null;
  select unit_price into v_x05 from products where org_id = v_org and sku = 'SVC-TBL-PX05' and deleted_at is null;
  select unit_price into v_x24 from products where org_id = v_org and sku = 'SVC-TBL-PX24' and deleted_at is null;
  begin
    update products set unit_price = 999 where org_id = v_org and sku = 'SVC-TBL-PX05' and deleted_at is null;
    v_err := '沒有被擋';
  exception when others then v_err := '被擋';
  end;
  v_total := v_total + 1;
  v_ok := v_x05 = v_p05 + 10 - v_p02 and v_x24 = v_p24 - v_p05 - 10 and v_err = '被擋';
  if v_ok then v_pass := v_pass + 1; end if;
  v_msg := v_msg || case when v_ok then '✅' else '🔴' end || ' ⓛ P05 加 10：延長價變成 ' || v_x05 || '／' || v_x24
        || '（預期 ' || (v_p05 + 10 - v_p02) || '／' || (v_p24 - v_p05 - 10) || '）；直接改延長價 ' || v_err || E'\n';

  -- ⓜ 買 24 小時的包桌 ⇒ 封頂，不提示不鎖
  update table_sessions set planned_minutes = 1440 where id = v_sess;
  v_pkg := public._pkg_time(v_sess);
  v_total := v_total + 1;
  v_ok := v_pkg ->> 'phase' = 'capped' and not (v_pkg ->> 'locked')::boolean;
  if v_ok then v_pass := v_pass + 1; end if;
  v_msg := v_msg || case when v_ok then '✅' else '🔴' end || ' ⓜ 24 小時那一檔：' || coalesce(v_pkg ->> 'phase', 'null') || '（應為 capped）' || E'\n';

  v_msg := v_msg || E'\n' || case when v_pass = v_total then '✅' else '🔴' end || ' 合計 ' || v_pass || '/' || v_total;
  raise exception 'migi_rollback';
exception when others then
  perform set_config('migi.pkgtest',
    v_msg || case when sqlerrm = 'migi_rollback' then '' else E'\n🔴 中途出錯：' || sqlerrm end, true);
end $$;

select coalesce(nullif(current_setting('migi.pkgtest', true), ''), '🔴 沒有測試訊息') as "包桌續時行為測試（已回滾）";
