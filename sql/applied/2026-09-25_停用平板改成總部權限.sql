-- ════════════════════════════════════════════════════════════════════
-- 停用桌邊平板改成總部權限（2026-09-25）＋ 行為測試，一次跑完
--
-- 起因：使用者拍板「POS 不能有平板管理」—— 配對與停用都只在總部後台。
-- 🔴 光拿掉 POS 那一頁不夠：revoke_table_device_tx 原本只檢查
--   「是店員 ＋ 有這間店的權限」⇒ 任何一個店員帳號直接打 RPC 仍然停用得了。
--   畫面拿掉、後端沒收，就是「畫面上的規矩」（同 products 的 is_system 那一次）。
-- ✅ 改成與配對同一個權限碼（device.write）。
--   list_table_devices_tx 不動：它是唯讀，後台那一頁也在用。
-- CREATE OR REPLACE、簽名不變 ⇒ 授權不會掉（硬規則 2）。
--
-- 第一段會留下改動；⑤⑥ 行為測試在自己的小區塊裡造樣本、測完退回（savepoint），
--   不 raise 到最外層 ⇒ 不會連帶回滾第一段（硬規則 1.8）。
--   同一份測試也單獨存在 sql/checks/2026-09-25_驗停用平板只有總部.sql。
-- 最後一格「驗證」應該是 6 行 ✅。
-- ════════════════════════════════════════════════════════════════════

create or replace function public.revoke_table_device_tx(p_device_id uuid)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare v_staff uuid; v_store uuid;
begin
  v_staff := (select staff_id from public.current_staff());
  if v_staff is null then
    return jsonb_build_object('ok', false, 'reason', 'not_staff', 'message', '請先登入');
  end if;
  -- 配對與停用都是總部的事（2026-09-25 使用者拍板：POS 不管平板）
  if not public.can('device.write') then
    return jsonb_build_object('ok', false, 'reason', 'forbidden', 'message', '停用平板要請總部在後台處理');
  end if;
  select store_id into v_store from table_devices where id = p_device_id;
  if v_store is null then
    return jsonb_build_object('ok', false, 'reason', 'not_found', 'message', '找不到這台平板');
  end if;
  update table_devices set is_active = false, revoked_at = now(), revoked_by_staff_id = v_staff
   where id = p_device_id and is_active;
  -- 停用的平板手上還綁著人的話一起放掉
  update session_players set device_id = null where device_id = p_device_id;
  return jsonb_build_object('ok', true);
end $function$;

-- ── 驗證 ①–④：只讀線上定義 ──
do $$
declare v text := ''; d text; n int;
begin
  select count(*) into n from pg_proc where pronamespace = 'public'::regnamespace and proname = 'revoke_table_device_tx';
  v := v || case when n = 1 then '✅' else '🔴' end || ' ① 版本數 ' || n || '（應為 1，沒有長出多載）' || E'\n';

  d := pg_get_functiondef('public.revoke_table_device_tx(uuid)'::regprocedure);
  v := v || case when d ~ 'if not public\.can\(''device\.write''\) then' then '✅' else '🔴' end
         || ' ② 函式裡真的拿權限碼來判斷' || E'\n';

  v := v || case when has_function_privilege('authenticated', 'public.revoke_table_device_tx(uuid)', 'execute')
                 then '✅' else '🔴' end || ' ③ authenticated 仍然叫得動（後台那一頁沒被打壞）' || E'\n';

  v := v || case when not exists (select 1 from pg_proc p, aclexplode(p.proacl) a
                                   where p.oid = 'public.revoke_table_device_tx(uuid)'::regprocedure
                                     and a.privilege_type = 'EXECUTE'
                                     and (a.grantee = 0 or a.grantee = 'anon'::regrole::oid))
                 then '✅' else '🔴' end || ' ④ anon／PUBLIC 都沒有（跟改之前一樣）' || E'\n';

  perform set_config('migi.v', v, true);
end $$;

-- ── 行為測試 ⑤⑥：造一位一般店員與一台測試平板，測完整段退回 ──
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

    -- ⑤ 一般店員：要被擋，平板要還活著
    perform set_config('request.jwt.claims', json_build_object('sub', v_uid, 'role', 'authenticated')::text, true);
    r := public.revoke_table_device_tx(v_dev);
    select is_active into act from table_devices where id = v_dev;
    v := v || case when r ->> 'reason' = 'forbidden' and act then '✅' else '🔴' end
           || ' ⑤ 一般店員停用 ⇒ ' || coalesce(r ->> 'reason', r::text) || '，平板仍是 ' || case when act then '啟用' else '已停用' end || E'\n';

    -- ⑥ 總部（admin@migi.tw）：要停得掉（正對照）
    perform set_config('request.jwt.claims', json_build_object('sub', '2485579b-966f-4da6-8ccd-d3adb7ba084b', 'role', 'authenticated')::text, true);
    r := public.revoke_table_device_tx(v_dev);
    select is_active into act from table_devices where id = v_dev;
    v := v || case when (r ->> 'ok')::boolean and not act then '✅' else '🔴' end
           || ' ⑥ 總部停用 ⇒ ' || coalesce(r ->> 'ok', r::text) || '，平板變成 ' || case when act then '啟用' else '已停用' end || E'\n';

    raise exception 'migi_rollback';
  exception when others then
    if sqlerrm <> 'migi_rollback' then v := v || '🔴 中途例外：' || sqlerrm || E'\n'; end if;
    perform set_config('migi.w', v || '（⑤⑥ 造的樣本已全部退回）', true);
  end;
end $$;

select coalesce(nullif(current_setting('migi.v', true), ''), '🔴 ①–④ 沒有訊息') || E'\n'
    || coalesce(nullif(current_setting('migi.w', true), ''), '🔴 ⑤⑥ 沒有訊息') as "驗證";
