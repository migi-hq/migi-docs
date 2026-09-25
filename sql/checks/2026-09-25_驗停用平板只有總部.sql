-- ════════════════════════════════════════════════════════════════════
-- 行為測試：停用平板只有總部叫得動（2026-09-25）
--   前提：sql/pending/2026-09-25_停用平板改成總部權限.sql 已經跑過
--
-- 🔴 這份**故意不提交**：交易裡造一位一般店員（role = floor）與一台測試平板，
--   分別用那位店員與總部的身分叫一次，最後 raise 'migi_rollback' 全部退掉。
--   ⚠ 線上現在沒有一般店員（只有總部與老闆），所以只能自己造 —— 不借線上資料（硬規則 3.57）。
--   兩格缺一不可（硬規則 3.55）：只驗「店員被擋」的話，一支永遠回 forbidden 的函式也會全綠。
-- ════════════════════════════════════════════════════════════════════
do $$
declare
  v_org uuid; v_store uuid; v_table uuid; v_dev uuid; v_uid uuid := gen_random_uuid();
  r jsonb; v text := ''; act boolean;
begin
  begin
    select t.id, t.store_id, s.org_id into v_table, v_store, v_org
      from tables t join stores s on s.id = t.store_id order by s.is_test desc limit 1;
    if v_table is null then raise exception '找不到桌位可以造樣本'; end if;

    insert into staff (org_id, store_id, auth_uid, name, role)
    values (v_org, v_store, v_uid, '測試一般店員', 'floor');
    insert into table_devices (org_id, store_id, table_id, label, token_hash)
    values (v_org, v_store, v_table, '測試停用', public._tbl_hash(md5(random()::text) || md5(random()::text)))
    returning id into v_dev;

    -- ① 一般店員：要被擋，平板要還活著
    perform set_config('request.jwt.claims', json_build_object('sub', v_uid, 'role', 'authenticated')::text, true);
    r := public.revoke_table_device_tx(v_dev);
    select is_active into act from table_devices where id = v_dev;
    v := v || case when r ->> 'reason' = 'forbidden' and act then '✅' else '🔴' end
           || ' ① 一般店員停用 ⇒ ' || coalesce(r ->> 'reason', r::text) || '，平板仍是 ' || case when act then '啟用' else '已停用' end || E'\n';

    -- ② 總部（admin@migi.tw）：要停得掉（正對照）
    perform set_config('request.jwt.claims', json_build_object('sub', '2485579b-966f-4da6-8ccd-d3adb7ba084b', 'role', 'authenticated')::text, true);
    r := public.revoke_table_device_tx(v_dev);
    select is_active into act from table_devices where id = v_dev;
    v := v || case when (r ->> 'ok')::boolean and not act then '✅' else '🔴' end
           || ' ② 總部停用 ⇒ ' || coalesce(r ->> 'ok', r::text) || '，平板變成 ' || case when act then '啟用' else '已停用' end || E'\n';

    raise exception 'migi_rollback';
  exception when others then
    if sqlerrm <> 'migi_rollback' then v := v || '🔴 中途例外：' || sqlerrm || E'\n'; end if;
    perform set_config('migi.v', v || '（以上全部回滾，線上一列都沒動）', true);
  end;
end $$;

select coalesce(nullif(current_setting('migi.v', true), ''), '🔴 沒有訊息') as "驗證";
