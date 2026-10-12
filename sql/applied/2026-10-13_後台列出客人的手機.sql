-- ============================================================================
-- 2026-10-13 後台「智慧計分板」頁也列出客人的手機（使用者）
--
-- 手機綁人不綁桌（2026-10-13 手機計分），沒有門市 ⇒ 後台照門市列平板時看不到它。
--   ① 手機每次跟後端講話，就記下它最後在哪間店用（table_devices.store_id；桌不記，每一場都不同）
--   ② list_table_devices_tx 多回一組 phones：最近 30 天在這間店用過、而且還能用的手機
--      （只限一場的那種，那一場收了就不列）
--   ③ 平板與手機共用同一支 _tbl_device_report（版本、離線原因、近 24 小時錯誤與斷網）—— 不各寫一份
--   ④ revoke_table_device_tx 也能停用手機（手機沒有門市，原本會回「找不到」）
-- ⚠ 驗證段不用 raise 印訊息（硬規則 1.8）
-- ============================================================================

-- ① 記下手機最後在哪間店用
do $$
declare v_def text; v_new text;
begin
  v_def := pg_get_functiondef('public._tbl_device(text)'::regprocedure);
  v_new := replace(v_def,
    $s$    d.table_id := v_table;   -- 只改回傳值，不寫回資料表$s$,
    $s$    /* 後台照門市列手機（2026-10-13）：記下這支手機最後在哪間店用 —— 桌不寫回，桌每一場都不同 */
    if v_store is not null and d.store_id is distinct from v_store then
      update table_devices set store_id = v_store where id = d.id;
    end if;
    d.table_id := v_table;   -- 只改回傳值，不寫回資料表$s$);
  if v_new = v_def then raise exception '_tbl_device：找不到要插入的位置'; end if;
  execute v_new;
end $$;

-- ③ 平板與手機共用的狀態欄位（原本寫在 list_table_devices_tx 裡，原樣搬過來）
create or replace function public._tbl_device_report(dv public.table_devices)
returns jsonb
language sql stable security definer set search_path to 'public'
as $$
  select jsonb_build_object(
    'device_id', dv.id, 'label', dv.label, 'kind', dv.kind,
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
                         and e.props ->> 'device_id' = dv.id::text));
$$;
revoke execute on function public._tbl_device_report(public.table_devices) from public, anon, authenticated;

-- ② 清單：平板照舊（同一組欄位 ＋ 桌）、多一組客人的手機
create or replace function public.list_table_devices_tx(p_store_id uuid)
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $function$
begin
  if (select staff_id from public.current_staff()) is null then
    return jsonb_build_object('ok', false, 'reason', 'not_staff', 'message', '請先登入');
  end if;
  if not public.has_store_access(p_store_id) then
    return jsonb_build_object('ok', false, 'reason', 'forbidden', 'message', '你沒有這間店的權限');
  end if;
  return jsonb_build_object('ok', true, 'can_pair', public.can('device.write'),
    'devices', coalesce((
      select jsonb_agg(public._tbl_device_report(dv) || jsonb_build_object('table_id', dv.table_id, 'table', t.label)
             order by t.sort_order, t.label, dv.label)
        from table_devices dv join tables t on t.id = dv.table_id
       where dv.kind = 'tablet' and dv.store_id = p_store_id and dv.is_active), '[]'::jsonb),
    /* 📱 客人的手機（2026-10-13）：最近 30 天在這間店用過、還能用的。
       只限一場的那種（平板上發的碼），那一場收了就不列 —— 它已經叫不動任何東西 */
    'phones', coalesce((
      select jsonb_agg(x.j order by x.playing desc, x.seen desc nulls last)
        from (select public._tbl_device_report(dv) || jsonb_build_object(
                       'owner', m.display_name,
                       'this_game_only', dv.bound_session_id is not null,
                       'table', (select t.label from session_players sp
                                   join table_sessions ts on ts.id = sp.session_id
                                   join tables t on t.id = ts.table_id
                                  where sp.device_id = dv.id and sp.left_at is null
                                    and ts.status = 'open' and ts.deleted_at is null
                                  limit 1)) as j,
                     exists (select 1 from session_players sp where sp.device_id = dv.id and sp.left_at is null) as playing,
                     dv.last_seen_at as seen
                from table_devices dv join members m on m.id = dv.member_id
               where dv.kind = 'phone' and dv.is_active and dv.store_id = p_store_id
                 and dv.last_seen_at > now() - interval '30 days'
                 and (dv.bound_session_id is null or exists (
                       select 1 from table_sessions ts where ts.id = dv.bound_session_id and ts.status = 'open' and ts.deleted_at is null))) x
    ), '[]'::jsonb));
end $function$;

-- ④ 停用也能停手機（手機的 store_id 可能還沒記過 ⇒ 原本會回「找不到這台平板」）
do $$
declare v_def text; v_new text;
begin
  v_def := pg_get_functiondef('public.revoke_table_device_tx(uuid)'::regprocedure);
  v_new := replace(v_def,
    $s$if v_store is null then$s$,
    $s$if v_store is null and not exists (select 1 from table_devices where id = p_device_id and kind = 'phone') then$s$);
  if v_new = v_def then raise exception 'revoke_table_device_tx：找不到要改的位置'; end if;
  v_def := v_new;
  v_new := replace(v_def, $s$'找不到這台平板'$s$, $s$'找不到這台裝置'$s$);
  execute v_new;
end $$;

-- ============================================================================
-- 驗證（單一 SELECT）
-- ============================================================================
select concat_ws(E'\n',
  case when pg_get_functiondef('public._tbl_device(text)'::regprocedure) ~ 'update table_devices set store_id = v_store'
       then '✅ ① 手機會記下最後在哪間店用' else '🔴 ① _tbl_device 沒改到' end,
  case when to_regprocedure('public._tbl_device_report(public.table_devices)') is not null
            and not has_function_privilege('anon', 'public._tbl_device_report(public.table_devices)', 'execute')
       then '✅ ③ 共用的狀態欄位建好了、前端叫不到' else '🔴 ③ _tbl_device_report 不在或開給了前端' end,
  case when pg_get_functiondef('public.list_table_devices_tx(uuid)'::regprocedure) ~ '''phones'''
            and pg_get_functiondef('public.list_table_devices_tx(uuid)'::regprocedure) ~ 'dv\.kind = ''tablet'''
       then '✅ ② 清單多一組 phones，平板那組只列平板' else '🔴 ② 清單沒改到' end,
  case when has_function_privilege('authenticated', 'public.list_table_devices_tx(uuid)', 'execute')
            and has_function_privilege('authenticated', 'public.revoke_table_device_tx(uuid)', 'execute')
       then '✅ ②④ 後台照樣叫得到（授權沒掉）' else '🔴 ②④ 後台叫不到了' end,
  case when pg_get_functiondef('public.revoke_table_device_tx(uuid)'::regprocedure) ~ 'kind = ''phone'''
       then '✅ ④ 停用也能停手機' else '🔴 ④ 停用沒改到' end,
  '⚪ 清單的實際回傳要店員登入才叫得動 —— 推上去之後在後台實機看'
) as "驗證";
