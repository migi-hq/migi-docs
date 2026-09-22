-- ════════════════════════════════════════════════════════════════════
-- 2026-09-23 平板配對改成總部權限（使用者拍板）
--
-- 配對 ＝ **發出一張憑證**，拿到它的人就能對那一桌記分。
-- 那是一次性的設定（一桌四台、綁一次），不是每天的營運動作 ⇒ 總部做。
-- 而「停用」與「看狀態」留在店員：平板掉了要馬上停用（收緊不是放寬），
-- 沒電、掉線也要現場看得到。
--
--   admin_pair_table_device_tx   🔒 can('device.write')  ← 只有總部
--   list_table_devices_tx        店員 ＋ 這間店的權限
--   revoke_table_device_tx       店員 ＋ 這間店的權限
--
-- ⚠ 今天早上建的 pos_* 那三支**還沒有任何前端在用**（同一天建的），
--   所以直接改名並移除舊的，不必走 expand → migrate → contract。
-- ════════════════════════════════════════════════════════════════════

drop function if exists public.pos_pair_table_device_tx(uuid, text);
drop function if exists public.pos_list_table_devices_tx(uuid);
drop function if exists public.pos_revoke_table_device_tx(uuid);

-- ── 配對：總部 ─────────────────────────────────────────────────────
create or replace function public.admin_pair_table_device_tx(p_table_id uuid, p_label text)
returns jsonb language plpgsql security definer set search_path to 'public'
as $$
declare v_staff uuid; t record; v_token text; v_id uuid;
begin
  v_staff := (select staff_id from public.current_staff());
  if v_staff is null then
    return jsonb_build_object('ok', false, 'reason', 'not_staff', 'message', '請先登入');
  end if;
  /* 🔴 權限一律問 can()，這支不自己比對角色欄位（待辦 29 ①）——
     「誰有權限」與「怎麼判斷」分家，之後改成查表時呼叫點一行都不用動。
     ⚠ 這段註解刻意不寫出那個比對的寫法：寫了會被驗證段的全文掃描命中
       （硬規則 3.5，2026-09-23 第五次踩到，就是這一支）。 */
  if not public.can('device.write') then
    return jsonb_build_object('ok', false, 'reason', 'forbidden',
                              'message', '平板配對是總部的權限，請聯絡總部');
  end if;

  select id, org_id, store_id, label into t from tables where id = p_table_id and deleted_at is null;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'table_not_found', 'message', '找不到這張桌');
  end if;
  if nullif(btrim(coalesce(p_label, '')), '') is null then
    return jsonb_build_object('ok', false, 'reason', 'label_required', 'message', '請輸入平板編號，例如 A3-1');
  end if;

  /* 明文只在這裡回傳一次（POS／後台做成 QR，平板掃了存進自己的 localStorage）。
     資料庫只留 SHA-256。 */
  v_token := encode(extensions.gen_random_bytes(32), 'hex');
  insert into table_devices (org_id, store_id, table_id, label, token_hash, created_by_staff_id)
  values (t.org_id, t.store_id, t.id, btrim(p_label), public._tbl_hash(v_token), v_staff)
  returning id into v_id;
  return jsonb_build_object('ok', true, 'device_id', v_id, 'token', v_token, 'table', t.label);
end $$;

-- ── 查看：店員 ─────────────────────────────────────────────────────
create or replace function public.list_table_devices_tx(p_store_id uuid)
returns jsonb language plpgsql stable security definer set search_path to 'public'
as $$
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
             'in_use', exists (select 1 from session_players sp where sp.device_id = dv.id and sp.left_at is null))
           order by t.sort_order, t.label, dv.label)
      from table_devices dv join tables t on t.id = dv.table_id
     where dv.store_id = p_store_id and dv.is_active), '[]'::jsonb));
end $$;

-- ── 停用：店員（平板掉了要馬上停用） ──────────────────────────────
create or replace function public.revoke_table_device_tx(p_device_id uuid)
returns jsonb language plpgsql security definer set search_path to 'public'
as $$
declare v_staff uuid; v_store uuid;
begin
  v_staff := (select staff_id from public.current_staff());
  if v_staff is null then
    return jsonb_build_object('ok', false, 'reason', 'not_staff', 'message', '請先登入');
  end if;
  select store_id into v_store from table_devices where id = p_device_id;
  if v_store is null then
    return jsonb_build_object('ok', false, 'reason', 'not_found', 'message', '找不到這台平板');
  end if;
  if not public.has_store_access(v_store) then
    return jsonb_build_object('ok', false, 'reason', 'forbidden', 'message', '你沒有這間店的權限');
  end if;
  update table_devices set is_active = false, revoked_at = now(), revoked_by_staff_id = v_staff
   where id = p_device_id and is_active;
  -- 停用的平板手上還綁著人的話一起放掉
  update session_players set device_id = null where device_id = p_device_id;
  return jsonb_build_object('ok', true);
end $$;

revoke execute on function public.admin_pair_table_device_tx(uuid, text) from public, anon;
revoke execute on function public.list_table_devices_tx(uuid)             from public, anon;
revoke execute on function public.revoke_table_device_tx(uuid)            from public, anon;
grant  execute on function public.admin_pair_table_device_tx(uuid, text)  to authenticated;
grant  execute on function public.list_table_devices_tx(uuid)             to authenticated;
grant  execute on function public.revoke_table_device_tx(uuid)            to authenticated;

-- ════════════════════════════════════════════════════════════════════
-- 驗證（單一 SELECT，不 raise —— 硬規則 1.8）
-- ════════════════════════════════════════════════════════════════════
select * from (
  select 1 as n, '① 三支新的都在、各一個版本' as 項目,
         case when (select count(*) from pg_proc where pronamespace = 'public'::regnamespace
                     and proname in ('admin_pair_table_device_tx','list_table_devices_tx','revoke_table_device_tx')) = 3
              then '✅' else '🔴' end as 結果
  union all
  select 2, '② 舊的 pos_* 三支不在了（沒有留下多載）',
         case when not exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace
                                and proname like 'pos\_%table\_device%' escape '\')
              then '✅' else '🔴' end
  union all
  /* 🔴 第一版寫成「全文不可以出現那個比對寫法」，而**命中的是我自己的註解**
     （硬規則 3.5 第五次）。掃「有沒有提到」永遠會咬到說明文字 ——
     改成問「**有沒有真的拿來判斷**」：只看會產生行為的形狀。 */
  select 3, '③ 配對問 can()，而且沒有自己比對角色欄位（待辦 29 ①）',
         case when pg_get_functiondef('public.admin_pair_table_device_tx'::regproc) ~ 'can\(''device\.write''\)'
               and pg_get_functiondef('public.admin_pair_table_device_tx'::regproc) !~ '(if|and|where|select)[^\n]{0,40}cs?\.role'
              then '✅' else '🔴' end
  union all
  select 4, '④ 查看與停用不要求總部（店員做得到）',
         case when pg_get_functiondef('public.revoke_table_device_tx'::regproc) !~ 'device\.write'
               and pg_get_functiondef('public.list_table_devices_tx'::regproc) ~ 'has_store_access'
              then '✅' else '🔴' end
  union all
  select 5, '⑤ anon 一支都叫不動、authenticated 三支都叫得動',
         case when not exists (select 1 from pg_proc p, aclexplode(p.proacl) a
                                where p.proname in ('admin_pair_table_device_tx','list_table_devices_tx','revoke_table_device_tx')
                                  and p.pronamespace = 'public'::regnamespace
                                  and a.privilege_type = 'EXECUTE' and a.grantee in (0, 'anon'::regrole::oid))
               and (select count(*) from pg_proc p where p.pronamespace = 'public'::regnamespace
                     and p.proname in ('admin_pair_table_device_tx','list_table_devices_tx','revoke_table_device_tx')
                     and has_function_privilege('authenticated', p.oid, 'execute')) = 3
              then '✅' else '🔴' end
  union all
  /* 正對照：`device.write` 是新的權限碼 —— can() 必須對「不認得的碼」
     落到總部那一支，而不是一律回 false。
     🔴 一律 false 的話，配對會變成**連總部都做不了**，
       而畫面上看起來就像「權限設定正確」（硬規則 3.55：只驗擋得住那一半等於沒驗）。 */
  select 6, '⑥ 正對照：can() 對沒列舉的碼會落到總部那一支',
         case when pg_get_functiondef('public.can'::regproc) ~ 'else exists'
               and pg_get_functiondef('public.can'::regproc) ~ 'role in \(''hq'', ''owner''\)'
              then '✅' else '🔴' end
) v order by n;
