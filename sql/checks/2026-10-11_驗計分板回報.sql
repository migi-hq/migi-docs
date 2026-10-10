-- ============================================================
-- 行為測試：tbl_report_tx 五種回報 ＋ 後台清單讀得到（2026-10-11）
-- 🔴 這份在交易裡造一台假平板，最後故意 raise 'migi_rollback' 全部回滾 —— 跑完不會在資料庫留下任何東西
--   （硬規則 1.8：這份本來就不要留下東西，所以可以 raise；訊息在 exception 處理器裡才寫，見硬規則 3.9）
-- 前提：先跑完 sql/pending/2026-10-11_計分板回報版本離線原因與錯誤.sql
-- ============================================================
do $$
declare
  v_tok  text := repeat('ab', 24);           -- 48 字元的假憑證
  v_dev  uuid := gen_random_uuid();
  v_tab  public.tables;
  r      jsonb;
  d      public.table_devices;
  v_msg  text := '';
  v_n    int;
  i      int;
begin
  select * into v_tab from public.tables t
   where exists (select 1 from public.stores s where s.id = t.store_id and s.is_test)
   order by t.label limit 1;
  if v_tab.id is null then
    v_msg := '⚪ 找不到測試門市的桌子，測不了';
    raise exception 'migi_rollback';
  end if;
  insert into public.table_devices (id, org_id, store_id, table_id, label, token_hash, is_active, created_at)
  values (v_dev, v_tab.org_id, v_tab.store_id, v_tab.id, 'ZZ-測試', public._tbl_hash(v_tok), true, now());

  -- ⓐ hello：記版本與載入時間
  r := public.tbl_report_tx(v_tok, 'hello', '{"version":"v1011-1200"}');
  select * into d from public.table_devices where id = v_dev;
  v_msg := v_msg || case when (r->>'ok')::boolean and d.app_version = 'v1011-1200' and d.app_loaded_at is not null
                         then '✅ ⓐ hello 記下版本' else '🔴 ⓐ hello：' || r::text end;

  -- ⓑ gone hidden（帶電量）：記原因與電量
  r := public.tbl_report_tx(v_tok, 'gone', '{"reason":"hidden","level":42,"charging":false}');
  select * into d from public.table_devices where id = v_dev;
  v_msg := v_msg || E'\n' || case when d.gone_reason = 'hidden' and d.gone_at is not null and d.battery_level = 42 and d.battery_charging = false
                         then '✅ ⓑ gone 記下 hidden 與電量 42%' else '🔴 ⓑ gone：' || coalesce(d.gone_reason, 'null') end;

  -- ⓒ back：清掉原因
  r := public.tbl_report_tx(v_tok, 'back', '{}');
  select * into d from public.table_devices where id = v_dev;
  v_msg := v_msg || E'\n' || case when d.gone_reason is null and d.gone_at is null then '✅ ⓒ back 清掉原因' else '🔴 ⓒ back 沒清掉' end;

  -- ⓓ 壞參數：不認得的原因、不認得的 kind 都回 ok:false，不拋錯
  v_msg := v_msg || E'\n' || case when public.tbl_report_tx(v_tok, 'gone', '{"reason":"nope"}') ->> 'reason' = 'bad_reason'
                                   and public.tbl_report_tx(v_tok, 'zzz', '{}') ->> 'reason' = 'bad_kind'
                         then '✅ ⓓ 壞參數回 bad_reason／bad_kind' else '🔴 ⓓ 壞參數沒擋' end;

  -- ⓔ offline_was 與 error 寫進 app_events；秒數是怪字串時記 0 不拋錯
  perform public.tbl_report_tx(v_tok, 'offline_was', '{"seconds":125}');
  perform public.tbl_report_tx(v_tok, 'offline_was', '{"seconds":"abc"}');
  perform public.tbl_report_tx(v_tok, 'error', '{"kind":"rpc","fn":"tbl_confirm_hand_tx","msg":"duplicate key","version":"v1011-1200"}');
  select count(*) into v_n from public.app_events where props ->> 'device_id' = v_dev::text;
  v_msg := v_msg || E'\n' || case when v_n = 3 then '✅ ⓔ 斷網 2 筆 ＋ 錯誤 1 筆寫進 app_events' else '🔴 ⓔ app_events 有 ' || v_n || ' 筆（應為 3）' end;

  -- ⓕ 後台清單讀得到（以總部身分不容易模擬，直接看清單函式回傳裡這台的欄位；用 postgres 身分跑會被擋在 not_staff ⇒ 改查同一段子查詢的結果）
  select count(*) into v_n from public.app_events
   where event = 'table_error' and created_at > now() - interval '24 hours' and props ->> 'device_id' = v_dev::text;
  v_msg := v_msg || E'\n' || case when v_n = 1 then '✅ ⓕ 近 24 小時錯誤數算得出 1' else '🔴 ⓕ 錯誤數 ' || v_n end;

  -- ⓖ 每小時上限 30：再送 40 筆，只會多 29 筆（上面已經 1 筆）
  for i in 1..40 loop
    perform public.tbl_report_tx(v_tok, 'error', jsonb_build_object('kind', 'js', 'msg', 'loop ' || i));
  end loop;
  select count(*) into v_n from public.app_events where event = 'table_error' and props ->> 'device_id' = v_dev::text;
  v_msg := v_msg || E'\n' || case when v_n = 30 then '✅ ⓖ 每小時上限 30 筆有擋住' else '🔴 ⓖ 錯誤記了 ' || v_n || ' 筆（應為 30）' end;

  -- ⓗ 憑證不對要拋 28000（跟其他 tbl_* 一樣）
  begin
    perform public.tbl_report_tx(repeat('cd', 24), 'hello', '{}');
    v_msg := v_msg || E'\n' || '🔴 ⓗ 錯的憑證沒被擋';
  exception when sqlstate '28000' then
    v_msg := v_msg || E'\n' || '✅ ⓗ 錯的憑證被擋（28000）';
  end;

  raise exception 'migi_rollback';
exception when others then
  if sqlerrm = 'migi_rollback' then
    perform set_config('migi.x', v_msg, true);
  else
    perform set_config('migi.x', '🔴 中途出錯：' || sqlstate || ' ' || sqlerrm || E'\n已跑完的：\n' || v_msg, true);
  end if;
end $$;

select coalesce(nullif(current_setting('migi.x', true), ''), '🔴 沒有訊息') as "行為測試（應為 8 行 ✅，全部回滾）";
