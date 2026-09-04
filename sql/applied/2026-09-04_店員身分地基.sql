/* ============================================================
   店員身分地基：補 owner 的跨店權限 ＋ 創辦人的 staff 列 ＋ 查詢用 RPC
   2026-09-04 · MIGI · 待辦 20（待辦 21 的封條已於同日解除）

   ── 這一份在做什麼 ──────────────────────────────────
   ① 🔴 修 `has_store_access()` —— **`owner` 被漏掉了**
   ② `get_staff_by_line_tx` —— 給 Edge Function 問「這個 LINE 是哪位店員」
   ③ 為創辦人開一列 staff（LINE ↔ owner）

   ⚠ **這一份還沒有發任何 JWT。** JWT 換發是下一批 ——
     先把「有沒有人可以被認出來」這件事做好，
     不然發了 JWT 也是回 null（同硬規則 3.55：先確認正對照會亮）。

   ============================================================
   🔴 ① `has_store_access()` 漏了 `owner` —— 今天沒症狀，一用就爆
   ============================================================
   ```sql
   select exists (select 1 from current_staff() cs
                   where cs.role = 'hq' or cs.store_id = p_store_id);
   ```
   `staff_role_check` 允許四個值：`floor` / `manager` / `hq` / `owner`，
   而這支只認 `hq` 是跨店的。
   ⇒ **一個 `role='owner'`、`store_id=null` 的老闆，`has_store_access(任何店)`
     全部回 false —— 他什麼店都進不去。**

   🎯 **而且它跟 `can()` 對「誰是最高權限」的定義不一致**：
   ```
   can()               role in ('hq','owner')     ← 2026-09-04 建立
   has_store_access()  role = 'hq'                ← 2026-08 就在了
   ```
   🔴 **同一個概念在兩個地方各定義一份** —— 這個專案一再記錄的病
     （`member_tiers` 的折扣率原本寫在兩支函式各一份 case、
      `wallet_txns.type` 一欄兩義、`players` 一個 key 兩種形狀）。

   ✅ 正解不是「把 owner 也加進去」（那是**第三份**定義），
     而是讓它**呼叫 `can()`** —— 從此只有一份。
   📌 今天 `can()` 沒有 `case p_perm`（所有碼答案一樣），
     所以 `can('store.all')` 就等於 `role in ('hq','owner')`，行為完全吻合。
   ⚠ 這條今天**0 個 policy 在用**（待辦 21 盤點確認），所以改它零風險 ——
     **但那也正是它能錯這麼久沒被發現的原因。**

   ============================================================
   ⚠ ③ 這是授予最高權限的動作
   ============================================================
   綁下去之後，**拿到那個 LINE 帳號的人就是 owner**。
   待辦 20 原本寫「等真的要用 POS 時再做，不要現在先建」——
   ✅ 2026-09-04 使用者指定開工，所以現在做。

   🔴 **另開一列，不要動總部那一列。**
   ```
   既有  role=hq     auth_uid=2485579b-…  member_id=null   ← Email 路徑，正確
   新增  role=owner  auth_uid=null        member_id=<創辦人>  ← LINE 路徑
   ```
   · `member_id = null` **不是 bug** —— 那是 Email 路徑的 staff 列
     應該有的狀態（決策紀錄第八節：總部員工不是會員）。
   · `uq_staff_member_store (member_id, store_id)` 不衝突（既有那列 member_id 是 null）
   · `staff_auth_uid_key UNIQUE (auth_uid)` 也不衝突
     （Postgres 的唯一索引視多個 NULL 為**相異**）

   ⚠ **用 `grant_staff_tx` 不要直接 INSERT** —— 它會處理
     「已有記錄則更新角色（含復職）」與 `name` 的帶入，
     而且 2026-08-23 才修好角色值。走既有路徑，不要開第二條。
   📌 `store_id = null` 是刻意的：owner 不屬於單一門市，
     跨店權限由 `can('store.all')` 給（見 ①）。
   ============================================================ */

-- ── ① 跨店判斷收斂到 can() ──────────────────────────
create or replace function public.has_store_access(p_store_id uuid)
returns boolean
language sql stable security definer set search_path to 'public'
as $function$
  /* 🔴 2026-09-04：原本寫 `cs.role = 'hq'`，漏掉了 `owner`
     （`staff_role_check` 允許 floor/manager/hq/owner）。
     ⇒ 一個 role='owner'、store_id=null 的老闆什麼店都進不去。

     ✅ 修法不是「把 owner 也加進去」（那會是**第三份**「誰是最高權限」
       的定義），而是呼叫 `can()` —— 從此只有一份。
     📌 今天 `can()` 沒有 `case p_perm`，所以 `can('store.all')`
       就等於 `role in ('hq','owner')`，行為完全吻合。 */
  select public.can('store.all')
      or exists (select 1 from current_staff() cs where cs.store_id = p_store_id);
$function$;

comment on function public.has_store_access(uuid) is
  '這位店員看不看得到這間店。跨店資格由 can(store.all) 判斷（唯一來源），'
  '否則要 store_id 相符。2026-09-04 修：原本只認 hq，owner 被漏掉。';

/* ⚠ 這支會被 RLS policy 用到（雖然今天 0 條），所以 authenticated 要留。 */
revoke execute on function public.has_store_access(uuid) from public;
revoke execute on function public.has_store_access(uuid) from anon;
grant  execute on function public.has_store_access(uuid) to authenticated, service_role;


-- ── ② 這個 LINE 帳號是哪位店員 ──────────────────────
create or replace function public.get_staff_by_line_tx(
  p_org_id uuid, p_line_user_id text
) returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $function$
declare v_r jsonb;
begin
  /* 🎯 給 Edge Function 用（service_role），形狀比照 `get_member_by_line_tx`。

     🔴 **不可以用 `current_staff()` 代替** —— 那支讀的是 `auth.jwt()`，
       而 Edge Function 是拿驗過簽的 `sub` 在問，手上沒有 JWT context。
     ⚠ 兩者的判準必須一致（`members.line_user_id` → `staff.member_id`），
       不一致的話會出現「Edge Function 說你是店員，但 RLS 說你不是」
       —— 而那**不會報錯，只會什麼都看不到**（硬規則 4 那一族）。

     ⚠ 只回畫面需要的欄位。`auth_uid` **絕對不回** ——
       那是另一條登入路徑的憑據。 */
  select jsonb_build_object(
           'ok', true,
           'staff_id',    s.id,
           'member_id',   s.member_id,
           'store_id',    s.store_id,
           'role',        s.role,
           'name',        coalesce(s.name, m.display_name),
           'cross_store', s.role in ('hq', 'owner')   -- 與 can() 同一份判準
         )
    into v_r
    from staff s
    join members m on m.id = s.member_id and m.deleted_at is null
   where s.deleted_at is null
     and s.org_id = p_org_id
     and m.line_user_id = p_line_user_id
   -- 一個人可能在多店有 staff 列 → 取權限最高的，與 current_staff() 同序
   order by case s.role when 'hq' then 1 when 'owner' then 1
                        when 'manager' then 2 else 3 end
   limit 1;

  /* ⚠ 查不到**不是錯誤**，是「這個 LINE 帳號不是店員」——
     那是最常見的情況（每一個客人都是）。回 ok:false 讓呼叫端分辨。 */
  return coalesce(v_r, jsonb_build_object('ok', false, 'reason', 'not_staff'));
end;
$function$;

/* 🔴 **只給 service_role。** 這支回答「某個 LINE 帳號是不是店員、什麼角色」
   —— 那是組織內部資訊，不該讓前端問得到。
   ⚠ 兩個方向都要收（硬規則 2.6b）：新函式吃 default privileges，
     anon 是**明確**授權；而 PUBLIC 是建立時的預設。 */
revoke execute on function public.get_staff_by_line_tx(uuid, text) from public;
revoke execute on function public.get_staff_by_line_tx(uuid, text) from anon, authenticated;
grant  execute on function public.get_staff_by_line_tx(uuid, text) to service_role;


-- ── ③ 創辦人的 staff 列 ────────────────────────────
do $$
declare
  v_org uuid := '11111111-1111-1111-1111-111111111111';
  v_member uuid;
  v_r jsonb;
begin
  /* 🔴 **用 line_user_id 找人，不要抄 uuid。**
     2026-09-01 就是照 CLAUDE.md 抄了一個 member id，
     結果造了三場戰績給錯的帳號（硬規則 3 與踩坑第 29 條）。
     ⚠ 今天只有一個會員綁了 LINE，所以這個查法是明確的；
       日後有多人時要改成指定 line_user_id。 */
  select id into v_member from members
   where org_id = v_org and line_user_id is not null and deleted_at is null
   order by created_at limit 1;

  if v_member is null then
    raise exception 'no_line_member：沒有任何會員綁了 LINE，無法建立店員列';
  end if;

  /* ⚠ 走 `grant_staff_tx` 不直接 INSERT —— 它處理「已有記錄則更新角色
     （含復職）」與 `name` 帶入，而且 2026-08-23 才修好角色值。 */
  v_r := public.grant_staff_tx(v_member, null, 'owner');
  if (v_r ->> 'ok')::boolean is not true then
    raise exception 'grant_failed: %', v_r::text;
  end if;
  raise notice '建立店員列：%', v_r::text;
end $$;


-- ══════════════════════════════════════════════════════
-- 驗證
-- ══════════════════════════════════════════════════════
do $$
declare
  v_out text := '';
  v_org uuid := '11111111-1111-1111-1111-111111111111';
  v_line text; v_store uuid; v_n int; v_r jsonb; v_b boolean;
begin
  begin
    select line_user_id into v_line from members
     where org_id = v_org and line_user_id is not null and deleted_at is null
     order by created_at limit 1;
    select id into v_store from stores where org_id = v_org limit 1;

    ---- ① staff 列 --------------------------------------
    /* ⚠ `max(s.store_id)` 會炸 —— **Postgres 沒有 `max(uuid)`**（2026-09-04 踩到）。
       uuid 沒有定義排序用的聚合，要先 `::text`。
       📌 那不是期望值錯也不是函式錯，是**驗證段自己的語法錯** ——
         硬規則 3.56 那一族的第三種。 */
    v_out := v_out || E'\n' || '① 創辦人有了 owner 的 staff 列' || E'\t' ||
      (select case when count(*) = 1 then '✅ ' || max(s.name) || ' · ' || max(s.role) ||
                        ' · store_id ' || coalesce(max(s.store_id::text), 'null（跨店）')
                   else '🔴 ' || count(*) || ' 列' end
         from staff s join members m on m.id = s.member_id
        where s.deleted_at is null and m.line_user_id = v_line and s.role = 'owner');

    /* 🔴 **正對照**：總部那一列要**原封不動** ——
       2026-08-29 我一度建議把它綁到創辦人的會員上，那是錯的
       （`member_id = null` 是 Email 路徑應有的狀態）。 */
    v_out := v_out || E'\n' || '② 🎯 正對照：總部那列沒被動到' || E'\t' ||
      (select case when count(*) = 1 then '✅ role=hq · auth_uid 有值 · member_id=null'
                   else '🔴 ' || count(*) || ' 列 —— Email 路徑可能被打壞了' end
         from staff where role = 'hq' and auth_uid is not null
                      and member_id is null and deleted_at is null);

    ---- ③ get_staff_by_line_tx -------------------------
    v_r := public.get_staff_by_line_tx(v_org, v_line);
    v_out := v_out || E'\n' || '③ 🎯 get_staff_by_line_tx 認得出創辦人' || E'\t' ||
      case when (v_r ->> 'ok')::boolean and v_r ->> 'role' = 'owner'
                and (v_r ->> 'cross_store')::boolean
           then '✅ ' || (v_r ->> 'name') || ' · owner · 跨店'
           else '🔴 ' || v_r::text end;

    /* 🔴 **正對照**：不是店員的 LINE 帳號要回 `not_staff` ——
       只驗「認得出店員」的話，一支**永遠回 ok** 的實作也會讓 ③ 變綠。 */
    v_r := public.get_staff_by_line_tx(v_org, 'U_definitely_not_a_staff_0000');
    v_out := v_out || E'\n' || '④ 🎯 正對照：不是店員的回 not_staff' || E'\t' ||
      case when (v_r ->> 'ok')::boolean is not true and v_r ->> 'reason' = 'not_staff'
           then '✅' else '🔴 ' || v_r::text end;

    v_out := v_out || E'\n' || '⑤ 🔴 沒有回傳 auth_uid（那是另一條路的憑據）' || E'\t' ||
      case when not (public.get_staff_by_line_tx(v_org, v_line) ? 'auth_uid')
           then '✅ 沒有這個鍵' else '🔴 洩漏了' end;

    ---- ⑥⑦ has_store_access 的兩個方向 ------------------
    /* 🎯 **這才是這份 SQL 真正修掉的東西。**
       修之前：`role='owner'` ＋ `store_id=null` ⇒ **每一間店都回 false**。
       ⚠ 今天 0 條 policy 在用它，所以那個 bug **沒有任何症狀** ——
         而那正是它能錯這麼久的原因。 */
    perform set_config('request.jwt.claims',
      '{"sub":' || to_json(v_line)::text || '}', true);
    v_b := public.has_store_access(v_store);
    v_out := v_out || E'\n' || '⑥ 🎯 owner 進得去任何一間店（修之前是 false）' || E'\t' ||
      case when v_b then '✅' else '🔴 還是進不去' end;

    v_out := v_out || E'\n' || '⑦ 🎯 can(store.all) 與它同一份判準' || E'\t' ||
      case when public.can('store.all') = v_b then '✅ 一致'
           else '🔴 兩支函式對「誰是最高權限」的答案不同' end;

    /* 🔴 **正對照**：不是店員的人要進不去。
       只驗「owner 進得去」的話，一支 `select true` 也會讓 ⑥ 變綠。 */
    perform set_config('request.jwt.claims',
      '{"sub":"U_definitely_not_a_staff_0000"}', true);
    v_out := v_out || E'\n' || '⑧ 🎯 正對照：不是店員的進不去' || E'\t' ||
      case when not public.has_store_access(v_store) then '✅ false'
           else '🔴 竟然進得去' end;

    /* 🔴 而且 LINE 的 sub 不可以讓它拋錯 —— 那是今天早上修的
       `migi_jwt_uuid()`。這裡順便再驗一次（它現在真的被用到了）。 */
    v_out := v_out || E'\n' || '⑨ 🎯 LINE 的 sub 沒有讓身分函式拋錯' || E'\t' ||
      case when public.current_org_id() is null then '✅ 回 null 不拋錯'
           else '✅ 回 ' || public.current_org_id()::text end;

    perform set_config('request.jwt.claims', '', true);

    ---- ⑩ 授權 -----------------------------------------
    /* 🎯 **2026-09-04 意外得到一個更強的證據**：
       用 MCP（`supabase_read_only_user`）跑這一段時，第 ③ 格直接拋
       `permission denied for function get_staff_by_line_tx` ——
       **連唯讀的 DB user 都叫不動它。**
       ⇒ 那比讀 `proacl` 更有說服力：`aclexplode` 證明的是「授權表長怎樣」，
         這個證明的是「真的叫不動」（同硬規則 7）。
       ⚠ 所以這份 SQL **必須在 Dashboard 跑**（postgres 身分），MCP 跑不完。 */
    v_out := v_out || E'\n' || '⑩ get_staff_by_line_tx 只有 service_role' || E'\t' ||
      (select case when not a and not p and not au then '✅ anon／PUBLIC／authenticated 都收掉了'
                   else '🔴 anon=' || a || ' public=' || p || ' auth=' || au end
         from (select
                 exists (select 1 from aclexplode(coalesce(pr.proacl,'{}')) x
                          where x.grantee='anon'::regrole::oid and x.privilege_type='EXECUTE') a,
                 (pr.proacl is null or exists (select 1 from aclexplode(pr.proacl) x
                          where x.grantee=0 and x.privilege_type='EXECUTE')) p,
                 exists (select 1 from aclexplode(coalesce(pr.proacl,'{}')) x
                          where x.grantee='authenticated'::regrole::oid and x.privilege_type='EXECUTE') au
                from pg_proc pr where pr.pronamespace='public'::regnamespace
                 and pr.proname='get_staff_by_line_tx') z);

    perform set_config('migi.stf', v_out, true);
  exception when others then
    perform set_config('migi.stf', v_out || E'\n🔴 測試自己炸了\t' || sqlerrm, true);
  end;
end $$;

select split_part(x, E'\t', 1) as 測試,
       split_part(x, E'\t', 2) as 結果
  from unnest(string_to_array(current_setting('migi.stf', true), E'\n')) as x
 where coalesce(x,'') <> '';
