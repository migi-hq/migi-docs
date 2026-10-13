-- ============================================================
-- 管理後台「智慧計分板」頁：客人的手機也列出「還沒入座過」的
-- 2026-10-13 · MIGI 咪吉麻將
--
-- 使用者：「還沒入座手機也要列出」
--   原本只列「最近 30 天在這間店用過的」—— 手機要真的坐進這間店的某一場，才會記下門市（table_devices.store_id）。
--   剛配對、還沒打過牌的手機 store_id 是 null ⇒ 哪一間店的清單都看不到，有問題時也沒地方停用。
--   （2026-10-13 實例：芙芙、Chan、Y 配好了還沒入座；創辦人中午測試配的那一支）
--
-- 改法：store_id 是 null、同一個機構的手機，每一間店的清單都列；多回一個 never_seated 標記，畫面寫「還沒入座過」。
--   其餘一個字都不改（權限判斷、平板清單、30 天、只限一場的過濾都照舊）。簽名不變 ⇒ CREATE OR REPLACE，不掉授權。
-- ============================================================

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
  return jsonb_build_object('ok', true, 'can_pair', public.can('device.write'),
    'devices', coalesce((
      select jsonb_agg(public._tbl_device_report(dv) || jsonb_build_object('table_id', dv.table_id, 'table', t.label)
             order by t.sort_order, t.label, dv.label)
        from table_devices dv join tables t on t.id = dv.table_id
       where dv.kind = 'tablet' and dv.store_id = p_store_id and dv.is_active), '[]'::jsonb),
    /* 📱 客人的手機（2026-10-13）：最近 30 天在這間店用過、還能用的。
       只限一場的那種（平板上發的碼），那一場收了就不列 —— 它已經叫不動任何東西
       🆕 同日：還沒入座過的（store_id 是 null，同一個機構）每間店都列，標 never_seated */
    'phones', coalesce((
      select jsonb_agg(x.j order by x.playing desc, x.seen desc nulls last)
        from (select public._tbl_device_report(dv) || jsonb_build_object(
                       'owner', m.display_name,
                       'this_game_only', dv.bound_session_id is not null,
                       'never_seated', dv.store_id is null,
                       'table', (select t.label from session_players sp
                                   join table_sessions ts on ts.id = sp.session_id
                                   join tables t on t.id = ts.table_id
                                  where sp.device_id = dv.id and sp.left_at is null
                                    and ts.status = 'open' and ts.deleted_at is null
                                  limit 1)) as j,
                     exists (select 1 from session_players sp where sp.device_id = dv.id and sp.left_at is null) as playing,
                     dv.last_seen_at as seen
                from table_devices dv join members m on m.id = dv.member_id
               where dv.kind = 'phone' and dv.is_active
                 and (dv.store_id = p_store_id
                      or (dv.store_id is null and dv.org_id = (select s.org_id from stores s where s.id = p_store_id)))
                 and dv.last_seen_at > now() - interval '30 days'
                 and (dv.bound_session_id is null or exists (
                       select 1 from table_sessions ts where ts.id = dv.bound_session_id and ts.status = 'open' and ts.deleted_at is null))) x
    ), '[]'::jsonb));
end $function$;


-- ============================================================
-- 驗證（單一 SELECT，不 raise）
--   ① 版本數 1、DEFINER、權限判斷都在
--   ② 會列 store_id 是 null 的手機、有 never_seated 標記
--   ③ ℹ 現在符合「還沒入座過」的手機有幾支（就是這次會多出來的）
--   ⚠ 實際回傳要店員登入才叫得到，畫面請在後台看
-- ============================================================
select concat_ws(E'\n',
  case when (select count(*) from pg_proc where proname = 'list_table_devices_tx' and pronamespace = 'public'::regnamespace) = 1
        and (select prosecdef from pg_proc where proname = 'list_table_devices_tx' and pronamespace = 'public'::regnamespace)
        and (select pg_get_functiondef('public.list_table_devices_tx'::regproc) ~ 'not_staff'
                and pg_get_functiondef('public.list_table_devices_tx'::regproc) ~ 'has_store_access')
       then '① ✅ 版本數 1、DEFINER、權限判斷都在' else '① 🔴 函式不對' end,
  case when (select pg_get_functiondef('public.list_table_devices_tx'::regproc) ~ 'dv\.store_id is null and dv\.org_id'
                and pg_get_functiondef('public.list_table_devices_tx'::regproc) ~ '''never_seated''')
       then '② ✅ 會列還沒入座過的手機' else '② 🔴 沒改到' end,
  '③ ℹ 現在還沒入座過、30 天內上線過、還能用的手機：'
    || (select count(*) from table_devices dv where dv.kind = 'phone' and dv.is_active and dv.store_id is null
          and dv.last_seen_at > now() - interval '30 days') || ' 支'
) as "驗證";
