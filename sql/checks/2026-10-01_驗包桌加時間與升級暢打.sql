/* ============================================================
   驗：包桌加時間與升級暢打（行為測試）· 2026-10-01
   搭配 sql/pending/2026-10-01_包桌加時間與升級暢打.sql，**先跑那一份再跑這一份**。
   ⚠ 故意不提交：自己造一場包桌，最後 raise 'migi_rollback' 全部退掉（訊息寫在 handler 裡）。

   樣本：包桌 2 小時、台麻、一台測試平板；A、B、D 一般，C 入座時持當日暢打
         四位都挑「今天還沒有暢打」的測試會員，不然升級前就會被當成暢打
   ============================================================ */
do $$
declare
  v_msg text := ''; v_pass int := 0; v_total int := 0;
  v_org uuid; v_store uuid; v_other uuid; v_table uuid; v_sess uuid; v_dev uuid; v_round uuid;
  m uuid[];
  v_tok text := replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '');
  v_pkg jsonb; v_r jsonb; v_q jsonb; v_amt bigint; v_exp bigint; v_pct int;
  v_p02 bigint; v_p05 bigint; v_day bigint; v_x02 bigint; v_up bigint; v_err text; v_ok boolean; v_n int;
  pay jsonb;
begin
  select t.org_id, t.store_id, t.id into v_org, v_store, v_table
    from tables t join stores s on s.id = t.store_id
   where s.is_test and t.deleted_at is null
     and not exists (select 1 from table_sessions ts where ts.table_id = t.id and ts.status = 'open' and ts.deleted_at is null)
   order by t.label limit 1;
  select array_agg(x.id order by x.created_at) into m
    from (select mm.id, mm.created_at from members mm join wallets w on w.member_id = mm.id
           where mm.is_test and mm.deleted_at is null and mm.hidden_at is null
             and not public.has_daypass_tx_core(v_org, mm.id, v_store)
           order by mm.created_at limit 4) x;
  select id into v_other from stores where org_id = v_org and id <> v_store and deleted_at is null limit 1;
  if v_table is null or coalesce(cardinality(m), 0) < 4 or v_other is null then
    v_msg := '🔴 找不到樣本（空的測試桌、四位今天沒有暢打的測試會員、另一間門市）';
    raise exception 'migi_rollback';
  end if;

  select unit_price into v_p02 from products where org_id = v_org and sku = 'SVC-TBL-P02'  and deleted_at is null;
  select unit_price into v_p05 from products where org_id = v_org and sku = 'SVC-TBL-P05'  and deleted_at is null;
  select unit_price into v_day from products where org_id = v_org and sku = 'SVC-TBL-DAY'  and deleted_at is null;
  select unit_price into v_x02 from products where org_id = v_org and sku = 'SVC-TBL-PX02' and deleted_at is null;

  insert into table_sessions (org_id, store_id, table_id, mode, status, planned_minutes, started_at, open_method, game_type, flower)
  values (v_org, v_store, v_table, 'private', 'open', 120, now(), 'manual', '台麻', '無花')
  returning id into v_sess;
  insert into session_players (org_id, session_id, member_id, join_type, status, charged_points, paid_by,
                               fee_waived_reason, fee_waived_amount, seat, joined_at)
  values (v_org, v_sess, m[1], 'opener', 'playing', 100, null, null,      0,   1, now()),
         (v_org, v_sess, m[2], 'opener', 'playing', 100, null, null,      0,   2, now()),
         (v_org, v_sess, m[3], 'opener', 'playing', 0,   null, 'daypass', 100, 3, now()),
         (v_org, v_sess, m[4], 'opener', 'playing', 100, null, null,      0,   4, now());
  insert into table_devices (org_id, store_id, table_id, label, token_hash, is_active)
  values (v_org, v_store, v_table, '加時測試平板', public._tbl_hash(v_tok), true)
  returning id into v_dev;
  update session_players set device_id = v_dev where session_id = v_sess and member_id = m[1];

  -- ⓐ 還沒定座位：A、B、D 2 小時、最早到期；C 暢打；A 升級要補 暢打價 − 2 小時價
  v_pkg := public._pkg_time(v_sess);
  v_err := (select string_agg(e ->> 'status' || ':' || coalesce(e ->> 'minutes', '-'), ',' order by (e ->> 'seat')::int)
              from jsonb_array_elements(v_pkg -> 'players') e);
  v_up := (select (e ->> 'upgrade_price')::bigint from jsonb_array_elements(v_pkg -> 'players') e where (e ->> 'seat')::int = 1);
  v_total := v_total + 1;
  v_ok := v_pkg ->> 'phase' = 'not_started' and v_err = 'owed:120,owed:120,daypass:-,owed:120' and v_up = v_day - v_p02;
  if v_ok then v_pass := v_pass + 1; end if;
  v_msg := v_msg || case when v_ok then '✅' else '🔴' end || ' ⓐ 還沒定座位：' || coalesce(v_pkg ->> 'phase', 'null')
        || '，' || coalesce(v_err, '—') || '，A 升級補 ' || coalesce(v_up::text, '?') || '（應為 owed:120,owed:120,daypass:-,owed:120、補 '
        || (v_day - v_p02) || '）' || E'\n';

  -- ⓑ 開打 140 分鐘 ⇒ 鎖定
  insert into session_rounds (org_id, session_id, round_no, first_dealer_seat, started_at)
  values (v_org, v_sess, 1, 1, now() - interval '140 minutes') returning id into v_round;
  begin
    v_r := public.tbl_submit_hand_tx(v_tok, 'draw'); v_err := coalesce(v_r ->> 'reason', 'ok');
  exception when others then v_err := '例外：' || sqlerrm;
  end;
  v_total := v_total + 1;
  v_ok := (public._pkg_time(v_sess) ->> 'phase') = 'locked' and v_err = 'pkg_locked';
  if v_ok then v_pass := v_pass + 1; end if;
  v_msg := v_msg || case when v_ok then '✅' else '🔴' end || ' ⓑ 140 分鐘鎖定，送一局：' || v_err || E'\n';

  -- ⓒ 報價：A 加 2 小時套 A 的會員折扣；A 升級暢打補 200 不打折
  select coalesce((select t.discount_pct from members mm join member_tiers t on t.code = coalesce(mm.tier_override, mm.tier) and t.is_active
                    where mm.id = m[1]), 0) into v_pct;
  v_exp := v_x02 - round(v_x02 * v_pct / 100.0);
  v_q := public.pos_pkg_quote_tx(v_sess, m[1], null, '2h');
  v_amt := (v_q ->> 'amount')::bigint;
  v_q := public.pos_pkg_quote_tx(v_sess, m[1], null, 'daypass');
  v_total := v_total + 1;
  v_ok := v_amt = v_exp and (v_q ->> 'amount')::bigint = v_day - v_p02
      and (v_q -> 'cover' -> 0 ->> 'result') = 'daypass';
  if v_ok then v_pass := v_pass + 1; end if;
  v_msg := v_msg || case when v_ok then '✅' else '🔴' end || ' ⓒ 報價：加 2 小時 $' || coalesce(v_amt::text, '?') || '（預期 $' || v_exp
        || '）、升級暢打 $' || coalesce(v_q ->> 'amount', '?') || '（預期 $' || (v_day - v_p02) || '，不打折）' || E'\n';

  -- ⓓ A 替自己和 B 各加 2 小時 ⇒ A、B 240；D 還是 120 ⇒ 仍鎖定；A 再升級只要補 100
  v_q := public.pos_pkg_quote_tx(v_sess, m[1], array[m[1], m[2]], '2h');
  v_amt := (v_q ->> 'amount')::bigint;
  pay := jsonb_build_array(jsonb_build_object('method', 'cash', 'amount', v_amt, 'cash_received', v_amt, 'change_given', 0));
  v_r := public.pos_pkg_extend_tx(v_sess, m[1], array[m[1], m[2]], '2h', 0, pay, 'test-pkg4-d-' || v_sess);
  v_pkg := public._pkg_time(v_sess);
  v_err := (select string_agg(e ->> 'status' || ':' || coalesce(e ->> 'minutes', '-'), ',' order by (e ->> 'seat')::int)
              from jsonb_array_elements(v_pkg -> 'players') e);
  v_up := (select (e ->> 'upgrade_price')::bigint from jsonb_array_elements(v_pkg -> 'players') e where (e ->> 'seat')::int = 1);
  v_total := v_total + 1;
  v_ok := coalesce((v_r ->> 'ok')::boolean, false) and v_pkg ->> 'phase' = 'locked'
      and v_err = 'paid:240,paid:240,daypass:-,owed:120' and v_up = v_day - v_p02 - v_x02;
  if v_ok then v_pass := v_pass + 1; end if;
  v_msg := v_msg || case when v_ok then '✅' else '🔴' end || ' ⓓ A 替自己和 B 加 2 小時：' || coalesce(v_r ->> 'message', v_r ->> 'reason', 'ok')
        || '，' || coalesce(v_err, '—') || '，A 再升級補 ' || coalesce(v_up::text, '?')
        || '（應為 paid:240,paid:240,daypass:-,owed:120、仍 locked、補 ' || (v_day - v_p02 - v_x02) || '）' || E'\n';

  -- ⓔ 重送：同一把鍵、同一批人再按一次 ⇒ 結帳回舊訂單 ⇒ 不再加時間（A、B 仍是 240，延長紀錄沒有多）
  --    ⚠ 這時重新報價算出來的是「再加一段」，所以只有後端那道「訂單已記過延長」擋得住
  v_r := public.pos_pkg_extend_tx(v_sess, m[1], array[m[1], m[2]], '2h', 0, pay, 'test-pkg4-d-' || v_sess);
  v_pkg := public._pkg_time(v_sess);
  select count(*) into v_n from session_extensions where session_id = v_sess;
  v_err := (select string_agg(e ->> 'status' || ':' || coalesce(e ->> 'minutes', '-'), ',' order by (e ->> 'seat')::int)
              from jsonb_array_elements(v_pkg -> 'players') e);
  v_total := v_total + 1;
  v_ok := coalesce((v_r ->> 'replayed')::boolean, false) and v_n = 2 and v_err = 'paid:240,paid:240,daypass:-,owed:120';
  if v_ok then v_pass := v_pass + 1; end if;
  v_msg := v_msg || case when v_ok then '✅' else '🔴' end || ' ⓔ 同一把鍵重送：replayed=' || coalesce(v_r ->> 'replayed', v_r ->> 'reason', 'null')
        || '，延長紀錄 ' || v_n || ' 筆，' || coalesce(v_err, '—') || '（應為 true、2 筆、沒有變）' || E'\n';

  -- ⓕ D 自己升級暢打 ⇒ D 不再計時、今天在這間店算有暢打；桌子看 A、B（240 分）⇒ 140 分鐘是 ok
  v_q := public.pos_pkg_quote_tx(v_sess, m[4], null, 'daypass');
  v_amt := (v_q ->> 'amount')::bigint;
  pay := jsonb_build_array(jsonb_build_object('method', 'cash', 'amount', v_amt, 'cash_received', v_amt, 'change_given', 0));
  v_r := public.pos_pkg_extend_tx(v_sess, m[4], null, 'daypass', 0, pay, 'test-pkg4-e-' || v_sess);
  v_pkg := public._pkg_time(v_sess);
  v_err := (select string_agg(e ->> 'status' || ':' || coalesce(e ->> 'minutes', '-'), ',' order by (e ->> 'seat')::int)
              from jsonb_array_elements(v_pkg -> 'players') e);
  v_total := v_total + 1;
  v_ok := coalesce((v_r ->> 'ok')::boolean, false) and v_amt = v_day - v_p02
      and v_pkg ->> 'phase' = 'ok' and (v_pkg ->> 'tier_minutes')::int = 240
      and v_err = 'owed:240,owed:240,daypass:-,daypass:-'
      and public.has_daypass_tx_core(v_org, m[4], v_store);
  if v_ok then v_pass := v_pass + 1; end if;
  v_msg := v_msg || case when v_ok then '✅' else '🔴' end || ' ⓕ D 升級暢打 $' || coalesce(v_amt::text, '?') || '：'
        || coalesce(v_pkg ->> 'phase', 'null') || '、桌子 ' || coalesce(v_pkg ->> 'tier_minutes', '?') || ' 分，' || coalesce(v_err, '—')
        || '，這間店今天算有暢打 ' || public.has_daypass_tx_core(v_org, m[4], v_store)::text
        || '（應為 ok、240、owed:240,owed:240,daypass:-,daypass:-、true）' || E'\n';

  -- ⓖ A 再按「加 2 小時」⇒ 累計會到暢打價 ⇒ 自動變成升級暢打，只收差額、不打折
  v_q := public.pos_pkg_quote_tx(v_sess, m[1], null, '2h');
  v_amt := (v_q ->> 'amount')::bigint;
  pay := jsonb_build_array(jsonb_build_object('method', 'cash', 'amount', v_amt, 'cash_received', v_amt, 'change_given', 0));
  v_r := public.pos_pkg_extend_tx(v_sess, m[1], null, '2h', 0, pay, 'test-pkg4-f-' || v_sess);
  v_pkg := public._pkg_time(v_sess);
  v_err := (select string_agg(e ->> 'status' || ':' || coalesce(e ->> 'minutes', '-'), ',' order by (e ->> 'seat')::int)
              from jsonb_array_elements(v_pkg -> 'players') e);
  v_total := v_total + 1;
  v_ok := coalesce((v_r ->> 'ok')::boolean, false) and (v_q -> 'cover' -> 0 ->> 'result') = 'daypass'
      and v_amt = v_day - v_p02 - v_x02 and v_err = 'daypass:-,owed:240,daypass:-,daypass:-';
  if v_ok then v_pass := v_pass + 1; end if;
  v_msg := v_msg || case when v_ok then '✅' else '🔴' end || ' ⓖ A 再加 2 小時 ⇒ ' || coalesce(v_q -> 'cover' -> 0 ->> 'result', '?')
        || ' $' || coalesce(v_amt::text, '?') || '，' || coalesce(v_err, '—')
        || '（應為 daypass、$' || (v_day - v_p02 - v_x02) || '、daypass:-,owed:240,daypass:-,daypass:-）' || E'\n';

  -- ⓗ 該擋的：C（暢打）替自己 ⇒ nothing_owed；B 替 D（已升級）⇒ not_owed；亂給種類 ⇒ bad_kind
  v_q := public.pos_pkg_quote_tx(v_sess, m[3], null, '2h');            v_err := coalesce(v_q ->> 'reason', 'ok');
  v_q := public.pos_pkg_quote_tx(v_sess, m[2], array[m[4]], '2h');    v_err := v_err || '／' || coalesce(v_q ->> 'reason', 'ok');
  v_q := public.pos_pkg_quote_tx(v_sess, m[2], null, '24h');           v_err := v_err || '／' || coalesce(v_q ->> 'reason', 'ok');
  v_total := v_total + 1;
  v_ok := v_err = 'nothing_owed／not_owed／bad_kind';
  if v_ok then v_pass := v_pass + 1; end if;
  v_msg := v_msg || case when v_ok then '✅' else '🔴' end || ' ⓗ 該擋的：' || v_err || '（應為 nothing_owed／not_owed／bad_kind）' || E'\n';

  -- ⓘ 暢打的 C 替 B 付升級 ⇒ 全部不計時 ⇒ capped，再報價也是 capped
  v_q := public.pos_pkg_quote_tx(v_sess, m[3], array[m[2]], 'daypass');
  v_amt := (v_q ->> 'amount')::bigint;
  pay := jsonb_build_array(jsonb_build_object('method', 'cash', 'amount', v_amt, 'cash_received', v_amt, 'change_given', 0));
  v_r := public.pos_pkg_extend_tx(v_sess, m[3], array[m[2]], 'daypass', 0, pay, 'test-pkg4-i-' || v_sess);
  v_pkg := public._pkg_time(v_sess);
  v_q := public.pos_pkg_quote_tx(v_sess, m[2], null, '2h');
  v_total := v_total + 1;
  v_ok := coalesce((v_r ->> 'ok')::boolean, false) and v_amt = v_day - v_p02 - v_x02
      and v_pkg ->> 'phase' = 'capped' and v_q ->> 'reason' = 'capped';
  if v_ok then v_pass := v_pass + 1; end if;
  v_msg := v_msg || case when v_ok then '✅' else '🔴' end || ' ⓘ C 替 B 升級 $' || coalesce(v_amt::text, '?') || '，全部暢打：'
        || coalesce(v_pkg ->> 'phase', 'null') || '，再報價 ' || coalesce(v_q ->> 'reason', 'ok')
        || '（應為 $' || (v_day - v_p02 - v_x02) || '、capped／capped）' || E'\n';

  -- ⓙ 升級暢打認的是被升級的人、限這間店：B 在這間店是 true、另一間店是 false；付錢的 C 本來就是入座暢打，不算
  v_total := v_total + 1;
  v_ok := public.has_daypass_tx_core(v_org, m[2], v_store) and not public.has_daypass_tx_core(v_org, m[2], v_other)
      and (select paid_by from session_extensions where session_id = v_sess and member_id = m[2] and kind = 'daypass') = m[3];
  if v_ok then v_pass := v_pass + 1; end if;
  v_msg := v_msg || case when v_ok then '✅' else '🔴' end || ' ⓙ B 今天這間店有暢打 '
        || public.has_daypass_tx_core(v_org, m[2], v_store)::text || '、別間店 ' || public.has_daypass_tx_core(v_org, m[2], v_other)::text
        || '，付錢的是 C（應為 true／false／C）' || E'\n';

  -- ⓚ 價格連動：2 小時價改了，加 2 小時跟著變、補差價單位重算成三個價的最大公因數
  update products set unit_price = v_p02 + 10 where org_id = v_org and sku = 'SVC-TBL-P02' and deleted_at is null;
  select unit_price into v_x02 from products where org_id = v_org and sku = 'SVC-TBL-PX02'  and deleted_at is null;
  select unit_price into v_up  from products where org_id = v_org and sku = 'SVC-TBL-DAYUP' and deleted_at is null;
  v_total := v_total + 1;
  v_ok := v_x02 = v_p02 + 10 and v_up = gcd(gcd(v_day, v_p02 + 10), v_p05);
  if v_ok then v_pass := v_pass + 1; end if;
  v_msg := v_msg || case when v_ok then '✅' else '🔴' end || ' ⓚ 2 小時價改了：加 2 小時 ' || v_x02 || '、補差價單位 ' || v_up
        || '（應為 ' || (v_p02 + 10) || '、' || gcd(gcd(v_day, v_p02 + 10), v_p05) || '）' || E'\n';

  -- ⓛ 開桌不收 24 小時；2 小時照樣過了時數檢查（桌子已有場次，會回別的原因）
  begin
    v_r := public.open_session_tx(p_table_id => v_table, p_mode => 'private', p_planned_minutes => 1440,
                                  p_idempotency_key => 'test-pkg4-k1-' || v_sess);
    v_err := coalesce(v_r ->> 'reason', 'ok');
  exception when others then v_err := '例外：' || sqlerrm;
  end;
  begin
    v_r := public.open_session_tx(p_table_id => v_table, p_mode => 'private', p_planned_minutes => 120,
                                  p_idempotency_key => 'test-pkg4-k2-' || v_sess);
    v_err := v_err || '／' || coalesce(v_r ->> 'reason', 'ok');
  exception when others then v_err := v_err || '／例外：' || sqlerrm;
  end;
  v_total := v_total + 1;
  v_ok := v_err like 'invalid_minutes／%' and v_err not like '%／invalid_minutes';
  if v_ok then v_pass := v_pass + 1; end if;
  v_msg := v_msg || case when v_ok then '✅' else '🔴' end || ' ⓛ 開桌 24 小時／2 小時：' || v_err
        || '（前者應為 invalid_minutes，後者不可以是）' || E'\n';

  -- ⓜ 預約不收 24 小時；5 小時不是 bad_hours
  --   🔴 預約函式先問「你是誰」才檢查時數 ⇒ 沒有身分的話兩次都停在「未登入」（第一次跑就是這樣紅的）。
  --     所以在交易裡模擬測試03 登入：LINE id 從資料庫撈，掛在 app_metadata（身分解析讀的就是那裡）
  perform set_config('request.jwt.claims',
    jsonb_build_object('role', 'authenticated',
      'app_metadata', jsonb_build_object('line_user_id',
        (select line_user_id from public.members
          where is_test and deleted_at is null and hidden_at is null and line_user_id is not null
            and display_name = '測試03' limit 1)))::text, true);
  if public.current_member_id() is null then
    v_msg := v_msg || '⚪ ⓜ 找不到能模擬登入的測試帳號，這一格測不了' || E'\n';
  end if;
  begin
    v_r := public.booking_capacity_tx(v_store, now() + interval '2 days', 24); v_err := coalesce(v_r ->> 'reason', 'ok');
  exception when others then v_err := '例外：' || sqlerrm;
  end;
  begin
    v_r := public.booking_capacity_tx(v_store, now() + interval '2 days', 5); v_err := v_err || '／' || coalesce(v_r ->> 'reason', 'ok');
  exception when others then v_err := v_err || '／例外：' || sqlerrm;
  end;
  v_total := v_total + 1;
  perform set_config('request.jwt.claims', '', true);
  -- 正對照：5 小時那一次不可以停在「未登入」—— 停在那裡就代表身分沒模擬成功，前一次的 bad_hours 也不算數
  v_ok := v_err like 'bad_hours／%' and v_err not like '%／bad_hours' and v_err not like '%not_logged_in%';
  if v_ok then v_pass := v_pass + 1; end if;
  v_msg := v_msg || case when v_ok then '✅' else '🔴' end || ' ⓜ 預約 24 小時／5 小時：' || v_err || '（前者應為 bad_hours，後者不可以是）' || E'\n';

  v_msg := v_msg || E'\n' || case when v_pass = v_total then '✅' else '🔴' end || ' 合計 ' || v_pass || '/' || v_total;
  raise exception 'migi_rollback';
exception when others then
  perform set_config('migi.pkg4test',
    v_msg || case when sqlerrm = 'migi_rollback' then '' else E'\n🔴 中途出錯：' || sqlerrm end, true);
end $$;

select coalesce(nullif(current_setting('migi.pkg4test', true), ''), '🔴 沒有測試訊息') as "包桌加時間與升級暢打（已回滾）";
