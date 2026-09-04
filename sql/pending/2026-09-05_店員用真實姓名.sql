/* ============================================================
   `staff.name` 改成真實姓名，不再用 LINE 暱稱當預設
   2026-09-05 · MIGI · 店員登入上線後第一個回饋

   ── 問題 ──────────────────────────────────────────────
   POS 側邊欄顯示的是 **LINE 暱稱**（「咖勁凱」），而店員名牌該用真實姓名。

   🎯 **欄位本來就對，是填錯了**：
   ```
   members.display_name   客人看到的暱稱（會員 App、排行榜、牌咖）
   staff.name             🎯 員工的真實姓名（POS、稽核、交班日結）
   ```
   而 `grant_staff_tx` 拿 `display_name` 當預設值填進 `staff.name`。

   🔴 **而且它改不掉**：
   ```sql
   update staff set name = coalesce(name, v_name)   -- 已經有名字就不改
   ```
   ⇒ 「改名」這個動作在這支函式裡**做不到**。

   ── 兩個改動 ──────────────────────────────────────────
   ① `p_name` **必填**，不給就拒絕
      🔴 「店員的真實姓名」**不該有預設值** —— 用暱稱當預設正是現在的問題。
      ⚠ 沒有任何前端在呼叫它，所以改簽名是免費的。
   ② `update` 改成 `name = p_name`（真的會改名）

   ⚠ 改簽名要 `DROP FUNCTION`（硬規則 2），而 **DROP 會把 GRANT 一起丟掉**
     ⇒ 檔案結尾一定要重新 grant。

   ── 🔴 你要做的：把最後那一段的名字改成你的真實姓名 ──
   檔案結尾有一段 `grant_staff_tx(...)` 的呼叫，
   **把 `'請改成真實姓名'` 換掉再執行**。
   ⚠ 不改的話驗證段會直接告訴你（它會擋下那個字串）。
   ============================================================ */

/* ── 先把欄位的語意寫下來 ────────────────────────────
   🔴 **2026-09-05 查證：`staff.name` 從來沒有任何說明。**
   所以「它是暱稱還是真名」沒有人講過，而看到它裝著「咖勁凱」
   自然會以為那個欄位就是放暱稱的 —— **那個困惑是文件缺失造成的，不是設計問題**。

   🎯 而資料裡就有證據：總部那列是「**MIGI 總部管理員**」——
     那是**人填的員工名稱**，不是任何人的暱稱。
     只有創辦人那列被 `grant_staff_tx` 用 `display_name` 填了。

   ⚠ **不要為此加一個 `real_name` 欄位** —— 那會變成「兩個名字欄位」，
     而下一個人又要猜該用哪一個。這個專案已經記過那一族的病三次
     （`players` 一個 key 兩種形狀、`wallet_txns.type` 一欄兩義、
      `score_points` 一個名字兩個意思）。**補說明比加欄位便宜且正確。** */
comment on column public.staff.name is
  '員工的真實姓名（POS 側邊欄、稽核、交班日結會顯示）。'
  '🔴 不是 LINE 暱稱 —— 客人看到的暱稱在 members.display_name，兩者刻意分開。'
  '⚠ 總部那條路（Email 登入）的 staff 沒有 member_id，這一欄就是他唯一的名字。';

drop function if exists public.grant_staff_tx(uuid, uuid, text);

create or replace function public.grant_staff_tx(
  p_member_id uuid,
  p_store_id  uuid,
  p_role      text default 'floor',
  p_name      text default null
) returns jsonb
language plpgsql security definer set search_path to 'public'
as $function$
declare v_org uuid; v_id uuid; v_name text;
begin
  /* 🔴 授予店員身分是總部級操作（2026-09-04 加）。
     在此之前 `authenticated` 就能叫且零檢查 ⇒ 任何登入的店員
     可以把自己升成 owner。 */
  if not public.can('staff.write') then
    return jsonb_build_object('ok', false, 'reason', 'forbidden',
      'message', '只有總部可以設定店員');
  end if;

  /* 🔴 **真實姓名必填**（2026-09-05）。
     在此之前這支拿 `members.display_name`（LINE 暱稱）當預設值 ——
     而那是**方便但錯的**：POS 側邊欄、稽核、交班日結要的是
     **員工的真實姓名**，不是客人看到的暱稱。
     ⚠ 不給預設值是刻意的：**「店員叫什麼」不該有一個猜出來的答案。** */
  v_name := nullif(trim(coalesce(p_name, '')), '');
  if v_name is null then
    return jsonb_build_object('ok', false, 'reason', 'name_required',
      'message', '請填店員的真實姓名');
  end if;

  if p_role not in ('floor', 'manager', 'hq', 'owner') then
    return jsonb_build_object('ok', false, 'reason', 'invalid_role',
      'message', '角色只能是 floor（一般店員）／manager（店長）／hq（總部）／owner（老闆）');
  end if;

  select org_id into v_org
    from members where id = p_member_id and deleted_at is null;
  if v_org is null then
    return jsonb_build_object('ok', false, 'reason', 'member_not_found',
      'message', '找不到這位會員');
  end if;

  -- 已有記錄則更新（含已軟刪除的復職情況）
  select id into v_id from staff
   where member_id = p_member_id and store_id is not distinct from p_store_id;
  if v_id is not null then
    /* 🔴 舊版是 `name = coalesce(name, v_name)` —— **已經有名字就不改**
       ⇒ 改名這個動作做不到。現在直接用傳進來的。 */
    update staff set role = p_role, deleted_at = null,
                     name = v_name, updated_at = now()
     where id = v_id;
    return jsonb_build_object('ok', true, 'staff_id', v_id,
      'action', 'updated', 'role', p_role, 'name', v_name);
  end if;

  insert into staff(org_id, member_id, store_id, name, role)
  values (v_org, p_member_id, p_store_id, v_name, p_role)
  returning id into v_id;

  return jsonb_build_object('ok', true, 'staff_id', v_id,
    'action', 'created', 'role', p_role, 'name', v_name);
end $function$;

comment on function public.grant_staff_tx(uuid, uuid, text, text) is
  '把會員升級成店員。p_name 是**真實姓名且必填** —— '
  '2026-09-05 之前拿 LINE 暱稱當預設值，而 POS 名牌要的是真實姓名。';

/* 🔴 DROP 把 GRANT 丟掉了，要補回來（硬規則 2）。
   ⚠ `authenticated` 要留 —— migi-admin 走的就是這個角色，
     真正的把關在函式裡的 `can('staff.write')`。 */
revoke execute on function public.grant_staff_tx(uuid, uuid, text, text) from public;
revoke execute on function public.grant_staff_tx(uuid, uuid, text, text) from anon;
grant  execute on function public.grant_staff_tx(uuid, uuid, text, text) to authenticated, service_role;


-- ══════════════════════════════════════════════════════
-- 🔴 把下面這個名字改成你的真實姓名，再執行
-- ══════════════════════════════════════════════════════
do $$
declare
  v_real_name constant text := '請改成真實姓名';   -- 🔴 改這裡
  v_out text := '';
  v_org uuid := '11111111-1111-1111-1111-111111111111';
  v_admin uuid; v_member uuid; v_r jsonb;
begin
  if v_real_name = '請改成真實姓名' then
    perform set_config('migi.nm',
      '🔴 還沒填名字' || E'\t' || '把檔案最後那段的 v_real_name 改成你的真實姓名再跑一次', true);
    return;
  end if;

  /* ⚠ 用**總部身分**執行（`can('staff.write')` 擋著）。
     這裡直接借 `staff.auth_uid` —— 那是 Email 路徑的憑據。 */
  select auth_uid into v_admin from staff
   where auth_uid is not null and role in ('hq','owner') and deleted_at is null limit 1;
  perform set_config('request.jwt.claims',
    '{"sub":' || to_json(v_admin::text)::text || '}', true);

  /* 🔴 **用 line_user_id 找人，不要抄 uuid**（硬規則 3、踩坑第 29 條）。
     2026-09-01 就是照文件抄了一個 member id，結果造了三場戰績給錯的帳號。 */
  select m.id into v_member
    from members m join staff s on s.member_id = m.id
   where m.line_user_id is not null and s.role = 'owner'
     and s.deleted_at is null and m.deleted_at is null
   limit 1;

  if v_member is null then
    perform set_config('migi.nm', '🔴 找不到 owner 的會員' || E'\t' || '', true);
    return;
  end if;

  v_r := public.grant_staff_tx(v_member, null, 'owner', v_real_name);
  v_out := v_out || E'\n' || '① 更新結果' || E'\t' ||
    case when (v_r ->> 'ok')::boolean then '✅ ' || (v_r ->> 'action') || '　name = ' || (v_r ->> 'name')
         else '🔴 ' || v_r::text end;

  ---- 🎯 正對照：不給名字要被擋 ------------------------
  /* 只驗「改成功了」的話，一支**忽略 p_name** 的實作也會通過。 */
  v_r := public.grant_staff_tx(v_member, null, 'owner', null);
  v_out := v_out || E'\n' || '② 🎯 正對照：不給名字會被擋' || E'\t' ||
    case when (v_r ->> 'reason') = 'name_required' then '✅ 擋住了' else '🔴 ' || v_r::text end;

  v_r := public.grant_staff_tx(v_member, null, 'owner', '   ');
  v_out := v_out || E'\n' || '③ 🎯 正對照：只有空白也會被擋' || E'\t' ||
    case when (v_r ->> 'reason') = 'name_required' then '✅ 擋住了' else '🔴 ' || v_r::text end;

  ---- 🔴 正對照：暱稱沒有被動到 ------------------------
  /* 🎯 這一格確認**兩個名字是分開的** ——
     改店員的真實姓名**不可以**動到客人看到的暱稱。 */
  v_out := v_out || E'\n' || '④ 🎯 正對照：會員暱稱沒被動到' || E'\t' ||
    coalesce((select '✅ display_name 仍是「' || display_name || '」'
                from members where id = v_member), '🔴 查不到');

  ---- ⑤ POS 側邊欄會顯示什麼 --------------------------
  v_out := v_out || E'\n' || '⑤ POS 側邊欄會顯示' || E'\t' ||
    coalesce((select '店員：' || s.name from staff s
               where s.member_id = v_member and s.deleted_at is null limit 1), '🔴 查不到');

  ---- ⑥ 授權沒掉（DROP 會丟 GRANT）--------------------
  v_out := v_out || E'\n' || '⑥ 授權：anon❌ PUBLIC❌ authenticated✅' || E'\t' ||
    (select case when not a and not p and au then '✅'
                 else '🔴 anon=' || a || ' public=' || p || ' auth=' || au end
       from (select
               exists (select 1 from aclexplode(coalesce(pr.proacl,'{}')) x
                        where x.grantee='anon'::regrole::oid and x.privilege_type='EXECUTE') a,
               (pr.proacl is null or exists (select 1 from aclexplode(pr.proacl) x
                        where x.grantee=0 and x.privilege_type='EXECUTE')) p,
               exists (select 1 from aclexplode(coalesce(pr.proacl,'{}')) x
                        where x.grantee='authenticated'::regrole::oid and x.privilege_type='EXECUTE') au
              from pg_proc pr where pr.pronamespace='public'::regnamespace
               and pr.proname='grant_staff_tx') z);

  perform set_config('request.jwt.claims', '', true);
  perform set_config('migi.nm', v_out, true);
end $$;

select split_part(x, E'\t', 1) as 測試,
       split_part(x, E'\t', 2) as 結果
  from unnest(string_to_array(current_setting('migi.nm', true), E'\n')) as x
 where coalesce(x,'') <> '';
