-- ============================================================
-- 智慧計分板回報三件事給管理後台（2026-10-11 使用者：「123 都做」）
--   ① 離線原因：螢幕關了／網頁被關掉的那一刻先說一聲；斷網回來後補報斷了多久
--   ② 執行中的版本：每台跑哪一版、什麼時候重新載入過
--   ③ 錯誤紀錄：平板上出錯（畫面壞掉、後端回錯誤）就記下來 —— 在此之前計分板**完全沒有**錯誤上報，
--      10-10 A1「分紅之後下一局確認一律系統忙碌中」那次，就是使用者口頭說了才知道
--
-- 改了什麼：
--   · table_devices 多四欄：app_version／app_loaded_at（開機回報）、gone_reason／gone_at（最後一次離線原因）
--   · 新函式 tbl_report_tx(p_token, p_kind, p_data)：平板用憑證回報，五種 kind
--       hello        開機：記版本與載入時間，清掉離線原因
--       gone         螢幕關掉（hidden）或網頁被關（closed）的那一刻：記原因，順便記當時的電量
--       back         回到前景：清掉離線原因
--       offline_was  斷網回來後補報斷了幾秒 ⇒ app_events（table_offline），後台算近 24 小時幾次
--       error        出錯 ⇒ app_events（table_error；錯誤儀表本來就用「_error 結尾」抓，不用改儀表）
--                    🔴 每台每小時最多 30 筆，超過就不記（平板卡在錯誤迴圈時不要灌爆 app_events）
--   · list_table_devices_tx 多回：版本、載入時間、離線原因、近 24 小時錯誤次數與最後一筆、近 24 小時斷網次數與最長幾秒
--
-- 授權：tbl_report_tx 是新函式 ⇒ 預設全關（硬規則 2.7），平板用 anon 連線，所以明確 grant 給 anon, authenticated。
--   身分一律由憑證決定（_tbl_device），跟其他 tbl_* 一樣，不收「我是哪一台」的參數。
-- list_table_devices_tx：CREATE OR REPLACE，簽名不變，授權保留。
-- ============================================================

alter table public.table_devices
  add column if not exists app_version   text,
  add column if not exists app_loaded_at timestamptz,
  add column if not exists gone_reason   text,
  add column if not exists gone_at       timestamptz;

do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'table_devices_gone_reason_check') then
    alter table public.table_devices
      add constraint table_devices_gone_reason_check check (gone_reason is null or gone_reason in ('hidden', 'closed'));
  end if;
end $$;

comment on column public.table_devices.app_version   is '平板開機回報的計分板版本（vMMDD-HHmm），2026-10-11';
comment on column public.table_devices.app_loaded_at is '平板最後一次載入計分板的時間（開機或重新整理），2026-10-11';
comment on column public.table_devices.gone_reason   is '最後一次離開前景的原因：hidden 螢幕關了或切到別的程式／closed 網頁被關掉；回到前景就清掉。沒電、當機、斷網不會留下原因';
comment on column public.table_devices.gone_at       is 'gone_reason 記下的時間';

create or replace function public.tbl_report_tx(p_token text, p_kind text, p_data jsonb default '{}'::jsonb)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  d      public.table_devices;
  v_data jsonb := coalesce(p_data, '{}'::jsonb);
  v_lvl  int;
  v_test boolean;
  v_n    int;
begin
  d := public._tbl_device(p_token);   -- 驗憑證（認不得就拋錯），順便記最後上線
  v_test := coalesce((select s.is_test from stores s where s.id = d.store_id), false);

  if p_kind = 'hello' then
    update table_devices
       set app_version = left(nullif(v_data ->> 'version', ''), 40),
           app_loaded_at = now(), gone_reason = null, gone_at = null, last_seen_at = now()
     where id = d.id;
    return jsonb_build_object('ok', true);

  elsif p_kind = 'gone' then
    if coalesce(v_data ->> 'reason', '') not in ('hidden', 'closed') then
      return jsonb_build_object('ok', false, 'reason', 'bad_reason');
    end if;
    /* 電量順便記：螢幕關掉之後就不會再回報了，這是最後一個準的數字 */
    v_lvl := case when (v_data ->> 'level') ~ '^\d{1,3}$' then (v_data ->> 'level')::int end;
    update table_devices
       set gone_reason = v_data ->> 'reason', gone_at = now(), last_seen_at = now(),
           battery_level    = case when v_lvl between 0 and 100 then v_lvl else battery_level end,
           battery_charging = case when v_lvl between 0 and 100 and (v_data ->> 'charging') in ('true', 'false')
                                   then (v_data ->> 'charging')::boolean else battery_charging end,
           battery_at       = case when v_lvl between 0 and 100 then now() else battery_at end
     where id = d.id;
    return jsonb_build_object('ok', true);

  elsif p_kind = 'back' then
    update table_devices set gone_reason = null, gone_at = null, last_seen_at = now() where id = d.id;
    return jsonb_build_object('ok', true);

  elsif p_kind = 'offline_was' then
    insert into app_events (org_id, store_id, event, props, is_test)
    values (d.org_id, d.store_id, 'table_offline',
            jsonb_build_object('device_id', d.id, 'device', d.label,
                               'seconds', case when (v_data ->> 'seconds') ~ '^\d{1,9}(\.\d+)?$'
                                               then least((v_data ->> 'seconds')::numeric, 86400 * 7)::int else 0 end),
            v_test);
    return jsonb_build_object('ok', true);

  elsif p_kind = 'error' then
    /* 每台每小時最多 30 筆：卡在錯誤迴圈的平板不要灌爆 app_events */
    select count(*) into v_n from app_events
     where event = 'table_error' and created_at > now() - interval '1 hour'
       and props ->> 'device_id' = d.id::text;
    if v_n >= 30 then
      return jsonb_build_object('ok', true, 'skipped', true);
    end if;
    insert into app_events (org_id, store_id, event, props, is_test)
    values (d.org_id, d.store_id, 'table_error',
            jsonb_build_object('device_id', d.id, 'device', d.label,
                               'kind',    left(coalesce(v_data ->> 'kind', '?'), 20),
                               'msg',     left(coalesce(v_data ->> 'msg', ''), 300),
                               'fn',      left(v_data ->> 'fn', 60),
                               'version', left(v_data ->> 'version', 40)),
            v_test);
    return jsonb_build_object('ok', true);
  end if;

  return jsonb_build_object('ok', false, 'reason', 'bad_kind');
end $function$;

revoke execute on function public.tbl_report_tx(text, text, jsonb) from public;
grant execute on function public.tbl_report_tx(text, text, jsonb) to anon, authenticated;

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
             'in_use', exists (select 1 from session_players sp where sp.device_id = dv.id and sp.left_at is null),
             /* ★ 2026-10-11：版本、離線原因、近 24 小時錯誤與斷網 */
             'app_version', dv.app_version, 'app_loaded_at', dv.app_loaded_at,
             'gone_reason', dv.gone_reason, 'gone_at', dv.gone_at,
             'errors_24h', (select count(*) from app_events e
                             where e.event = 'table_error' and e.created_at > now() - interval '24 hours'
                               and e.props ->> 'device_id' = dv.id::text),
             'last_error', (select jsonb_build_object('at', e.created_at, 'msg', e.props ->> 'msg', 'kind', e.props ->> 'kind', 'fn', e.props ->> 'fn')
                              from app_events e
                             where e.event = 'table_error' and e.created_at > now() - interval '24 hours'
                               and e.props ->> 'device_id' = dv.id::text
                             order by e.created_at desc limit 1),
             'offline_24h', (select count(*) from app_events e
                              where e.event = 'table_offline' and e.created_at > now() - interval '24 hours'
                                and e.props ->> 'device_id' = dv.id::text),
             'offline_max_s', (select max((e.props ->> 'seconds')::int) from app_events e
                                where e.event = 'table_offline' and e.created_at > now() - interval '24 hours'
                                  and e.props ->> 'device_id' = dv.id::text))
           order by t.sort_order, t.label, dv.label)
      from table_devices dv join tables t on t.id = dv.table_id
     where dv.store_id = p_store_id and dv.is_active), '[]'::jsonb));
end $function$;

-- ── 驗證（單一 SELECT）──
-- ① 四個新欄位與 CHECK　② tbl_report_tx 存在、DEFINER、明確授權 anon 與 authenticated、PUBLIC 沒有
-- ③ 清單函式多回了新欄位、簽名沒變（仍是一個版本）
-- 行為（五種 kind、每小時上限、壞參數）另外跑 sql/checks/2026-10-11_驗計分板回報.sql（交易內造平板、最後回滾）
select
  (select case when count(*) = 4 then '✅ 四欄都在' else '🔴 只有 ' || count(*) || ' 欄' end
     from information_schema.columns
    where table_schema = 'public' and table_name = 'table_devices'
      and column_name in ('app_version', 'app_loaded_at', 'gone_reason', 'gone_at'))
  || case when exists (select 1 from pg_constraint where conname = 'table_devices_gone_reason_check')
          then ' · CHECK 在' else ' · 🔴 CHECK 不在' end                                             as "①",
  (select case when count(*) = 1 and bool_and(p.prosecdef)
                and bool_and(exists (select 1 from aclexplode(p.proacl) a where a.grantee = 'anon'::regrole::oid and a.privilege_type = 'EXECUTE'))
                and bool_and(exists (select 1 from aclexplode(p.proacl) a where a.grantee = 'authenticated'::regrole::oid and a.privilege_type = 'EXECUTE'))
                and not bool_or(exists (select 1 from aclexplode(p.proacl) a where a.grantee = 0))
               then '✅ tbl_report_tx：DEFINER、anon 與 authenticated 明確授權、PUBLIC 沒有'
               else '🔴 tbl_report_tx 的版本數／授權不對' end
     from pg_proc p where p.proname = 'tbl_report_tx' and p.pronamespace = 'public'::regnamespace)   as "②",
  (select case when count(*) = 1 and bool_and(pg_get_functiondef(p.oid) like '%errors_24h%' and pg_get_functiondef(p.oid) like '%app_version%')
               then '✅ list_table_devices_tx 多回新欄位（版本數 1）'
               else '🔴 list_table_devices_tx 不對（版本數 ' || count(*) || '）' end
     from pg_proc p where p.proname = 'list_table_devices_tx' and p.pronamespace = 'public'::regnamespace) as "③";
