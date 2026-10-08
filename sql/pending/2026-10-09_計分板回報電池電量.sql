-- ════════════════════════════════════════════════════════════════════
-- 2026-10-09 智慧計分板回報電池電量
-- ════════════════════════════════════════════════════════════════════
-- 使用者：「記分板可以顯示電池電量嗎」→ 選「平板頂條＋後台都看得到」
--
--   平板頂條   前端直接讀這台的電量（Android Chrome 的電池 API），不經過後端
--   後台       平板把電量回報上來，「智慧計分板」頁每台卡片顯示，偏低時標出來
--              ⇒ 店員不用走到桌邊就知道哪一台要充電
--
-- 欄位（table_devices）
--   battery_level     0–100，null ＝ 從沒回報過（或那台瀏覽器讀不到電量）
--   battery_charging  正在充電
--   battery_at        最後一次回報的時間 ⇒ 後台判斷這個數字是不是舊的
--
-- 回報走 tbl_report_battery_tx(p_token, …)：身分用平板憑證（同其他 tbl_* 函式），
--   不收 device id ⇒ 一台平板只能改自己的電量。
--   平板用的是 anon 金鑰 ⇒ 要明確給 anon（2026-09-29 起新函式預設全關，硬規則 2.7）。
-- list_table_devices_tx 多回三個欄位（簽名不變，create or replace 不丟權限）。
-- ════════════════════════════════════════════════════════════════════

alter table public.table_devices
  add column if not exists battery_level    smallint,
  add column if not exists battery_charging boolean,
  add column if not exists battery_at       timestamptz;

do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'table_devices_battery_level_check') then
    alter table public.table_devices
      add constraint table_devices_battery_level_check check (battery_level between 0 and 100);
  end if;
end $$;

comment on column public.table_devices.battery_level    is '平板最後回報的電量 0–100；null＝沒回報過（瀏覽器讀不到電量也是 null）';
comment on column public.table_devices.battery_charging is '平板最後回報時是否在充電';
comment on column public.table_devices.battery_at       is '平板最後一次回報電量的時間（判斷電量是不是舊的）';

create or replace function public.tbl_report_battery_tx(p_token text, p_level integer, p_charging boolean)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare d public.table_devices;
begin
  d := public._tbl_device(p_token);   -- 驗憑證（認不得就拋錯），順便記最後上線
  if p_level is null or p_level < 0 or p_level > 100 then
    return jsonb_build_object('ok', false, 'reason', 'bad_level');
  end if;
  update table_devices
     set battery_level = p_level, battery_charging = p_charging, battery_at = now()
   where id = d.id;
  return jsonb_build_object('ok', true);
end $function$;

revoke execute on function public.tbl_report_battery_tx(text, integer, boolean) from public;
grant  execute on function public.tbl_report_battery_tx(text, integer, boolean) to anon, authenticated;

create or replace function public.list_table_devices_tx(p_store_id uuid)
returns jsonb
language plpgsql
stable security definer
set search_path to 'public'
as $function$
begin
  if (select staff_id from public.current_staff()) is null then
    return jsonb_build_object('ok', false, 'reason', 'not_staff', 'message', '請先登入');
  end if;
  if not public.has_store_access(p_store_id) then
    return jsonb_build_object('ok', false, 'reason', 'forbidden', 'message', '你沒有這間店的權限');
  end if;
  return jsonb_build_object('ok', true, 'can_pair', public.can('device.write'), 'devices', coalesce((
    select jsonb_agg(jsonb_build_object(
             'device_id', dv.id, 'label', dv.label, 'table_id', dv.table_id, 'table', t.label,
             'is_active', dv.is_active, 'last_seen_at', dv.last_seen_at, 'created_at', dv.created_at,
             'battery_level', dv.battery_level, 'battery_charging', dv.battery_charging, 'battery_at', dv.battery_at,
             'in_use', exists (select 1 from session_players sp where sp.device_id = dv.id and sp.left_at is null))
           order by t.sort_order, t.label, dv.label)
      from table_devices dv join tables t on t.id = dv.table_id
     where dv.store_id = p_store_id and dv.is_active), '[]'::jsonb));
end $function$;

-- ── 驗證（單一 SELECT，不 raise）──────────────────────────────────────
select concat_ws(E'\n',
  -- ① 三個欄位都在
  case when (select count(*) from information_schema.columns
              where table_schema='public' and table_name='table_devices'
                and column_name in ('battery_level','battery_charging','battery_at')) = 3
       then '✅ ① 三個電量欄位都在' else '🔴 ① 欄位不齊' end,
  -- ② 回報函式：一個版本、平板（anon）叫得到
  (select case when count(*) = 1 and bool_and(has_function_privilege('anon', p.oid, 'execute'))
               then '✅ ② 回報函式一個版本，平板叫得到' else '🔴 ② 回報函式版本或權限不對' end
     from pg_proc p where p.pronamespace='public'::regnamespace and p.proname='tbl_report_battery_tx'),
  -- ③ 回報函式一定先驗憑證
  (select case when pg_get_functiondef(p.oid) ~ '_tbl_device\(p_token\)'
               then '✅ ③ 回報前先驗平板憑證' else '🔴 ③ 沒有驗憑證' end
     from pg_proc p where p.pronamespace='public'::regnamespace and p.proname='tbl_report_battery_tx'),
  -- ④ 後台清單有回電量、後台（authenticated）仍然叫得到、anon 叫不到
  (select case when pg_get_functiondef(p.oid) like '%''battery_level''%'
                and has_function_privilege('authenticated', p.oid, 'execute')
                and not has_function_privilege('anon', p.oid, 'execute')
               then '✅ ④ 後台清單多回電量，權限沒變' else '🔴 ④ 後台清單沒改到或權限變了' end
     from pg_proc p where p.pronamespace='public'::regnamespace and p.proname='list_table_devices_tx'),
  -- ⑤ 範圍約束在
  case when exists (select 1 from pg_constraint where conname='table_devices_battery_level_check')
       then '✅ ⑤ 電量限定 0–100' else '🔴 ⑤ 沒有範圍約束' end
) as "驗證";
