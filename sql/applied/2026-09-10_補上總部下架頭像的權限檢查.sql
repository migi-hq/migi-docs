/* ============================================================
   `admin_remove_avatar_tx` 補上權限檢查
   2026-09-10 · 一支 CREATE OR REPLACE，簽名不變

   ── 問題 ──────────────────────────────────────────────
   這支是 SECURITY DEFINER、授權給 `authenticated`、
   而且**函式體裡完全沒有任何權限判斷**。它吃一個任意的 `p_member_id`，
   然後對那個人做三件事：
   ```
   avatar_photo_path   → null        （照片下架）
   avatar_source       → 'bear'      （強制切回圖鑑頭像）
   avatar_blocked      → true        （p_block 給 true 時：**以後不能再上傳**）
   ```
   🔴 而 `avatar_blocked` **沒有任何 RPC 可以解除** —— 全庫只有 3 支函式
     碰得到那個旗標，沒有一支是解封。也就是一旦被設成 true，
     那位客人**再也換不回自己的照片**，只能有人進資料庫手改。

   ── 為什麼今天就要修，不是「JWT 上線後才會有的洞」──────
   🔴 `authenticated` **今天已經不只有店員**。實查 `auth.users`：
   ```
   7 個帳號 = 2 個店員（admin@migi.tw · line-…@staff）
            ＋ 5 個非店員（line-…@member · test01–04）
   ```
   ⇒ **任何一個登入的會員今天就叫得動它**，而且對象是他自己填的 id。
   ⚠ CLAUDE.md 待辦 20 記的是「auth.users 1 → 2」——
     那句話停在 2026-09-04，而會員端的 session 09-05 就開始發了。
     🎯 **我原本要寫「今天只有店員叫得動」，是查了才發現不對**
       （硬規則 3.56：期望值要當場查，不可以抄文件）。

   🟢 **今天沒有實際損害**：`avatar_blocked` 目前 0 人，
     而那 5 個非店員帳號都是自己人。**但那是運氣不是設計。**

   ── 形狀：這是 2026-09-04 那批的同一族，第二次 ──────────
   那天收掉 `rebind_line_user_tx`（anon ＋ 零檢查）與 `grant_staff_tx`。
   判準當時就寫好了：**「簽名裡有一個指定對象的 id」＋「沒有權限判斷」
   ＝ 那個形狀本身就不該存在**。
   ⚠ 這一支當時沒被掃到，因為那次的判準是「簽名裡有 `p_staff_id`」——
     而它沒有 `p_staff_id`，它有的是 `p_member_id`。
   ⇒ 所以驗證段第 ⑤ 格改成掃**所有 `admin_` 開頭卻沒有權限判斷的函式**，
     讓涵蓋範圍變成結構性的，不是一份要維護的清單。

   ── 為什麼用 `member.write` ────────────────────────────
   實查現在用到的權限碼共 10 個（`ops.read` / `finance.read` /
   `product.write` / `member.read` / `order.write` / `member.lookup` /
   `staff.write` / `store.all` / `tier.write` / `staff.rebind`）。
   這支是「對會員資料做寫入」⇒ `member.write`，第 11 個。
   ⚠ 硬規則 5.7 的預算是 10–15 個，還在裡面。
   ⚠ 用動詞不用頁面名（待辦 29 ④）——「頁面會改名，動作不會」。
   📌 `can()` 今天所有碼的答案都一樣（總部才有），所以這不是新行為，
     是**讓判斷點存在**，日後換成查表時呼叫端一行都不用改。

   ── 風險：零 ──────────────────────────────────────────
   ✅ 掃過三個 repo，**沒有任何前端在呼叫它**
     （只有 `migi-pos/src/lib/avatar.jsx:87` 的一句註解提到名字）。
   ⇒ 加上擋牆不會打壞任何畫面。
   ✅ 簽名不變 ⇒ `CREATE OR REPLACE`，不用 DROP，**授權不會掉**（硬規則 2）。

   ⚠ 這份的驗證段**一個字都不准 raise**（硬規則 1.8）——
     raise 會把上面那支 replace 一起回滾，而且六格全綠。
   ============================================================ */

create or replace function public.admin_remove_avatar_tx(
  p_member_id uuid,
  p_reason    text    default null,
  p_block     boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_path text; v_org uuid; v_cnt int;
begin
  /* 🔴 這一行是這次唯一新增的東西。
     照 admin_search_sessions_tx / admin_update_member_tier_tx 同一個寫法，
     回傳形狀也一致（ok / reason / message）—— 不要發明第二種。 */
  if not public.can('member.write') then
    return jsonb_build_object('ok', false, 'reason', 'forbidden',
                              'message', '沒有權限下架會員頭像');
  end if;

  select avatar_photo_path, org_id, avatar_removed_count
    into v_path, v_org, v_cnt
    from members where id = p_member_id;

  if v_org is null then
    return jsonb_build_object('ok', false, 'reason', 'member_not_found');
  end if;

  update members
     set avatar_source = 'bear',           -- 強制切回圖鑑頭像
         avatar_photo_path = null,
         avatar_removed_count = avatar_removed_count + 1,
         avatar_blocked = (avatar_blocked OR p_block),
         updated_at = now()
   where id = p_member_id;

  -- 留下處理紀錄（誰的照片、第幾次、原因、是否封鎖）
  insert into app_events(org_id, member_id, event, props, created_at)
  values (v_org, p_member_id, 'avatar_removed',
          jsonb_build_object('path', v_path, 'reason', p_reason,
                             'blocked', p_block, 'times', v_cnt + 1),
          now());

  return jsonb_build_object('ok', true, 'removed_path', v_path,
    'times', v_cnt + 1, 'blocked', p_block);
end $function$;

/* 🔴 兩個方向都要收（硬規則 2.6 與 2.6b）。
   · anon 走「新建函式的 default privileges」那條（明確授權）
   · PUBLIC 走「建函式時的預設」那條（繼承）
   收一個沒被授權的角色是合法的空操作，不會報錯 —— 所以兩行都寫。
   ⚠ **不可以連 authenticated 一起收** —— 總部後台就是用那個角色進來的，
     收掉不是「擋住」是「壞掉」。 */
revoke execute on function public.admin_remove_avatar_tx(uuid, text, boolean) from public;
revoke execute on function public.admin_remove_avatar_tx(uuid, text, boolean) from anon;
grant  execute on function public.admin_remove_avatar_tx(uuid, text, boolean) to authenticated, service_role;

/* ── 驗證段（唯讀，不 raise）──────────────────────────── */
do $$
declare
  v_msg text := '';
  v_n   int;
  v_def text;
begin
  select count(*) into v_n from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
     and p.proname = 'admin_remove_avatar_tx';
  v_msg := v_msg || case when v_n = 1
    then '① ✅ 只有一個版本（沒有建出多載）'
    else '① 🔴 有 ' || v_n || ' 個版本 —— 簽名被動到了' end;

  select pg_get_functiondef(p.oid) into v_def from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
     and p.proname = 'admin_remove_avatar_tx';

  v_msg := v_msg || E'\n' || case
    when v_def like '%public.' || 'can(' || '''member.write''' || ')%'
    then '② ✅ 權限判斷進去了'
    else '② 🔴 函式體裡找不到那個判斷' end;

  v_msg := v_msg || E'\n' || case when v_def like '%SECURITY DEFINER%'
    then '③ ✅ 仍然是 DEFINER' else '③ 🔴 安全模式被改掉了' end;

  /* ④ 正對照 ＋ 負對照一起印（硬規則 3.55）。
        只驗「anon 沒有」的話，把 authenticated 一起收掉也會全綠 ——
        而那會讓總部後台當場壞掉。 */
  select count(*) into v_n from pg_proc p, aclexplode(coalesce(p.proacl,'{}')) a
   where p.pronamespace = 'public'::regnamespace and p.proname = 'admin_remove_avatar_tx'
     and a.privilege_type = 'EXECUTE' and a.grantee = 'authenticated'::regrole::oid;
  v_msg := v_msg || E'\n' || case when v_n = 1
    then '④ ✅ authenticated 還在（後台沒被打壞）'
    else '④ 🔴 authenticated 不見了 —— 總部後台會叫不動' end;

  select count(*) into v_n from pg_proc p, aclexplode(coalesce(p.proacl,'{}')) a
   where p.pronamespace = 'public'::regnamespace and p.proname = 'admin_remove_avatar_tx'
     and a.privilege_type = 'EXECUTE'
     and (a.grantee = 'anon'::regrole::oid or a.grantee = 0);
  v_msg := v_msg || E'\n' || case when v_n = 0
    then '⑤ ✅ anon 與 PUBLIC 都沒有'
    else '⑤ 🔴 還有 ' || v_n || ' 條 anon／PUBLIC 的授權' end;

  /* ⑥ 🎯 這一格才是真正的守衛：不是驗這一支，是驗「這一類」。
        掃所有 admin_ 開頭、授權給 authenticated、卻沒有權限判斷的函式。
        ⚠ 樣式要連引號一起比對（硬規則 3.5）——
          只掃三個字母的話，註解裡提到它也會命中，那會變成一格永遠紅的檢查。 */
  select count(*) into v_n
    from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
     and p.proname like 'admin\_%' escape '\'
     and exists (select 1 from aclexplode(coalesce(p.proacl,'{}')) a
                  where a.privilege_type = 'EXECUTE'
                    and a.grantee = 'authenticated'::regrole::oid)
     and pg_get_functiondef(p.oid) not like '%public.' || 'can(' || '''%';
  v_msg := v_msg || E'\n' || case when v_n = 0
    then '⑥ ✅ 沒有任何 admin_ 函式是「authenticated 叫得動但零權限判斷」'
    else '⑥ 🔴 還有 ' || v_n || ' 支 admin_ 函式沒有權限判斷 —— 逐支看過' end;

  /* ⑦ 負對照：確認 ⑥ 那個掃描真的會抓到東西，不是恆為 0。
        改跑一次「有幾支 admin_ 函式**有**權限判斷」——
        它應該 > 0，否則代表我的樣式根本沒對上任何東西。 */
  select count(*) into v_n
    from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
     and p.proname like 'admin\_%' escape '\'
     and pg_get_functiondef(p.oid) like '%public.' || 'can(' || '''%';
  v_msg := v_msg || E'\n' || case when v_n > 0
    then '⑦ ✅ 掃描器本身是活的（' || v_n || ' 支 admin_ 函式有權限判斷）'
    else '⑦ 🔴 一支都沒抓到 —— 是樣式壞了，不是資料乾淨' end;

  perform set_config('migi.chk', v_msg, true);
end $$;

select coalesce(nullif(current_setting('migi.chk', true), ''), '🔴 沒有訊息') as "驗證";
