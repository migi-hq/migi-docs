/* ============================================================
   收掉三支「anon 叫得動、但沒有任何前端在叫」的會員函式
   2026-09-08 · 待辦 14 的暴露面收斂
   ============================================================

   ── 為什麼是「收掉」不是「加 JWT 檢查」──────────────────
   待辦 14 的既有做法是在函式開頭補一行：
       p_member_id := coalesce(public.current_member_id(), p_member_id);
   （21 支會員端函式已經這樣做了。）

   🎯 但那一招的前提是「**這支函式真的有前端在叫**」。
     這三支查下來三端都沒有人叫它 ⇒ 加檢查等於多維護一段沒有人走的邏輯，
     而**收掉暴露面是讓那條路不存在**。少一段會漂的東西。

   ── 三支各自的情況（全部查證過，不是推測）──────────────
   | 函式 | 前端 | 資料庫內部 | 今天的授權 |
   |---|---|---|---|
   | clear_avatar_photo_tx | ❌ 走 Edge Function（service_role） | ❌ | anon 明確 |
   | set_invoice_pref_tx   | ❌ **三端都沒有**            | ❌ | anon ＋ PUBLIC |
   | member_rank_tx        | ❌                          | ✅ 被 3 支呼叫 | anon ＋ PUBLIC |

   🔴 **其中兩個是真的洞**（今天就成立，不是理論）：
     · `clear_avatar_photo_tx(p_member_id)` —— 知道一個 member uuid
       就能**刪掉別人的頭像照片**。
       ⚠ `social.js:516` 的註解自己寫著「`avatar_delete` 只比對 bucket_id，
         **任何人可以刪掉任何會員的照片**」—— 那個洞當時搬到 Edge Function
         解決了，**但這支 RPC 的 anon 授權沒有跟著收**。
     · `set_invoice_pref_tx(p_member_id, ...)` —— 能**改掉別人的發票載具、
       捐贈碼、統編、抬頭**，而發票是法律文件（待辦 13）。
   🟡 `member_rank_tx` 只是讀某個人的段位，程度輕，但它同樣沒有消費者。

   ── ⚠ 內部呼叫不會被打壞（硬規則 2.5 的反向）────────────
   `member_rank_tx` 被 `apply_session_rounds_tx` / `get_my_rank_tx` /
   `reset_season_ratings_tx` 呼叫，而**它們都是 SECURITY DEFINER** ——
   DEFINER 裡面呼叫時**呼叫端的權限根本不會被檢查**。
   🎯 硬規則 2.5 說的是「在包裝裡跑得動不代表前端叫得動」；
     這裡是同一件事的另一面：**前端叫不動不代表包裝裡跑不動**。
   ⇒ 驗證段的第 ⑦ 格就是在證明這件事（正對照，不是推論）。

   ── 🔴 兩個方向都要收（硬規則 2.6b）──────────────────────
   anon 有兩條來源，而**收錯方向完全沒有效果也不會報錯**：
     · 舊函式 → 從 `PUBLIC` 繼承        → `revoke from public`
     · 新函式 → default privileges 明確 → `revoke from anon`
   實測這三支：`clear_avatar_photo_tx` 只有明確授權（PUBLIC 已收），
   另外兩支**兩條都有**。所以兩行都寫。
   ⚠ 驗證段**同時印「明確有沒有」與「PUBLIC 有沒有」** ——
     只看 `has_function_privilege` 的話，收錯方向的症狀跟沒收一模一樣。

   ── 也收 authenticated ──────────────────────────────────
   今天 migi-web 用 anon，所以 authenticated 那條今天沒人走。
   但待辦 14 之後會員會變成 `authenticated` ⇒ 留著等於
   「登入後的任何人都能改別人的發票設定」。**現在一起收。**
   ⏳ 待辦 13 做發票設定頁時要**同時** grant 回來 **並**補上那一行 JWT 覆寫
      —— 那時失敗會是 `permission denied`（大聲失敗），不會靜默。

   ── 事前查證（四處都沒有引用）──────────────────────────
   pg_policies / pg_views / pg_trigger / cron.job 全部掃過：0 筆。
   ============================================================ */


/* ── ⓪ guard：簽名要跟我查到的一致，不然下面 revoke 的是別的多載 ────
   ⚠ `revoke` 對不存在的簽名會直接報錯（那算好事），
     但**對「存在卻不是我以為的那一支」不會** —— 所以先擋。 */
do $$
declare v_n int;
begin
  select count(*) into v_n
  from pg_proc p
  where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
    and (p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')') in (
      'clear_avatar_photo_tx(p_member_id uuid)',
      'member_rank_tx(p_member_id uuid)',
      'set_invoice_pref_tx(p_member_id uuid, p_type text, p_carrier text, p_donate_code text, p_tax_id text, p_title text)'
    );
  if v_n <> 3 then
    raise exception '三支的簽名對不上（找到 % 支，期望 3）—— 先撈 pg_proc 確認再跑', v_n;
  end if;
end $$;


/* ── ① 頭像照片：只有 Edge Function（service_role）該叫得動 ───── */
revoke execute on function public.clear_avatar_photo_tx(uuid) from public;
revoke execute on function public.clear_avatar_photo_tx(uuid) from anon, authenticated;
grant  execute on function public.clear_avatar_photo_tx(uuid) to service_role;

/* ── ② 段位查詢：只被三支 DEFINER 內部呼叫 ─────────────────── */
revoke execute on function public.member_rank_tx(uuid) from public;
revoke execute on function public.member_rank_tx(uuid) from anon, authenticated;
grant  execute on function public.member_rank_tx(uuid) to service_role;

/* ── ③ 發票設定：三端都沒有人叫，而它改的是法律文件的欄位 ────── */
revoke execute on function public.set_invoice_pref_tx(uuid, text, text, text, text, text) from public;
revoke execute on function public.set_invoice_pref_tx(uuid, text, text, text, text, text) from anon, authenticated;
grant  execute on function public.set_invoice_pref_tx(uuid, text, text, text, text, text) to service_role;


/* ============================================================
   驗證段
   🎯 這一份的重點不是「擋住了嗎」，是**「該通的還通嗎」** ——
     只驗擋住的那一半，「整支刪掉」也會全綠（硬規則 3.55）。
   ============================================================ */
do $$
declare
  v_org  uuid;
  v_mem  uuid;
  v_blocked text;
  v_inner   text;
begin
  /* ⚠ 取樣：找一個測試會員來跑內部呼叫的正對照。
     找不到要**出聲**，不要安靜跳過（2026-09-04 那次兩格沒出現，
     而我以為全過）。 */
  select m.id, m.org_id into v_mem, v_org
  from public.members m
  where m.is_test and m.deleted_at is null
  order by m.created_at
  limit 1;

  if v_mem is null then
    perform set_config('migi.blocked', '⚪ 找不到測試會員，⑥⑦ 兩格測不了', true);
    perform set_config('migi.inner',   '⚪ 同上', true);
    return;
  end if;

  /* ── ⑥ 以 anon 身分直接叫 member_rank_tx → 應該被擋 ──────────
     🔴 這裡是**真的換身分**，不是讀 policy 定義（同硬規則 21-⑤）。 */
  begin
    set local role anon;
    perform public.member_rank_tx(v_mem);
    reset role;
    v_blocked := '🔴 anon 仍然叫得動 member_rank_tx —— 沒收到';
  exception when insufficient_privilege then
    reset role;
    v_blocked := '✅ anon 被擋（permission denied）';
  when others then
    reset role;
    v_blocked := '⚠ 被擋了但不是權限錯誤：' || coalesce(sqlerrm, '(無訊息)');
  end;

  /* ── ⑦ 🎯 正對照：以 anon 身分叫 get_my_rank_tx（它內部會呼叫
     member_rank_tx）→ 應該成功。這一格證明 DEFINER 內部呼叫沒被打壞。 */
  begin
    set local role anon;
    perform public.get_my_rank_tx(v_org, v_mem);
    reset role;
    v_inner := '✅ get_my_rank_tx 仍然叫得動（內部呼叫沒被打壞）';
  exception when others then
    reset role;
    v_inner := '🔴 get_my_rank_tx 壞了：' || coalesce(sqlerrm, '(無訊息)');
  end;

  perform set_config('migi.blocked', v_blocked, true);
  perform set_config('migi.inner',   v_inner,   true);
end $$;

select
  /* ── 這批三支 ────────────────────────────────────────── */
  coalesce((
    select string_agg(
      p.proname
      || '　明確給 anon：' || case when exists (
           select 1 from aclexplode(p.proacl) a
            where a.grantee = 'anon'::regrole::oid and a.privilege_type = 'EXECUTE')
         then '🔴 還在' else '✅ 沒了' end
      || '　PUBLIC：' || case when (p.proacl is null or exists (
           select 1 from aclexplode(p.proacl) a
            where a.grantee = 0 and a.privilege_type = 'EXECUTE'))
         then '🔴 還在' else '✅ 沒了' end
      || '　authenticated：' || case when exists (
           select 1 from aclexplode(p.proacl) a
            where a.grantee = 'authenticated'::regrole::oid and a.privilege_type = 'EXECUTE')
         then '🔴 還在' else '✅ 沒了' end
      || '　service_role：' || case when exists (
           select 1 from aclexplode(p.proacl) a
            where a.grantee = 'service_role'::regrole::oid and a.privilege_type = 'EXECUTE')
         then '✅ 有' else '🔴 沒有（Edge Function 會壞）' end,
      E'\n' order by p.proname)
    from pg_proc p
    where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
      and p.proname in ('clear_avatar_photo_tx', 'member_rank_tx', 'set_invoice_pref_tx')
  ), '🔴 一支都找不到') as "①②③ 這批三支（明確／PUBLIC 兩個方向都要看）",

  /* ── 全庫數量。期望值是**當場查出來的**不是憑印象（硬規則 3.56）：
       anon 明確  131 原本 − 3 這批 = 128
       PUBLIC     126 原本 − 2 這批 = 124
                  （clear_avatar_photo_tx 本來就沒有 PUBLIC，所以是 −2 不是 −3）
       public 函式總數 181，這一批不新增不刪除函式 ⇒ 不變 */
  (select
     '　anon 明確：' || count(*) filter (where exists (
        select 1 from aclexplode(p.proacl) a
         where a.grantee = 'anon'::regrole::oid and a.privilege_type = 'EXECUTE'))
     || '（期望 128，原本 131 − 3）'
     || E'\n　PUBLIC　　：' || count(*) filter (where p.proacl is null or exists (
        select 1 from aclexplode(p.proacl) a
         where a.grantee = 0 and a.privilege_type = 'EXECUTE'))
     || '（期望 124，原本 126 − 2）'
     || E'\n　函式總數　：' || count(*) || '（期望 181，不變）'
   from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
  ) as "④ 全庫數量",

  /* ── ⑤ 🎯 負對照：**還在用的**那幾支不可以被誤傷。
       過度阻擋跟沒擋一樣糟，而且更難發現（硬規則 3.55）。 */
  coalesce((
    select string_agg(
      p.proname || '：' || case when exists (
        select 1 from aclexplode(p.proacl) a
         where a.grantee = 'anon'::regrole::oid and a.privilege_type = 'EXECUTE')
      then '✅ anon 還在' else '🔴 被誤傷了' end, E'\n' order by p.proname)
    from pg_proc p
    where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
      and p.proname in ('get_wallet_tx', 'get_my_orders_tx', 'get_my_profile_tx',
                        'get_my_rank_tx', 'get_my_stats_tx', 'set_avatar_tx')
  ), '🔴 一支都找不到') as "⑤ 負對照：前端在用的沒被誤傷",

  coalesce(nullif(current_setting('migi.blocked', true), ''), '🔴 沒有訊息') as "⑥ anon 直接叫 member_rank_tx",
  coalesce(nullif(current_setting('migi.inner',   true), ''), '🔴 沒有訊息') as "⑦ 正對照：內部呼叫還通嗎",

  /* ── ⑧ 收完之後，還有沒有「anon 叫得動但沒人叫」的漏網之魚。
       ⚠ 這一格**不是通過條件**，是給下一次看的清單 ——
         它會列出所有 `p_member_id` 開頭的 anon 函式，
         人自己去比對三端有沒有在叫。 */
  coalesce((
    select string_agg(p.proname, '　' order by p.proname)
    from pg_proc p
    where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
      and pg_get_function_identity_arguments(p.oid) like '%p_member_id%'
      and exists (select 1 from aclexplode(p.proacl) a
                   where a.grantee = 'anon'::regrole::oid and a.privilege_type = 'EXECUTE')
      and pg_get_functiondef(p.oid) !~ 'current_member_id\(\)'
  ), '（沒有了）') as "⑧ 參考：仍然 anon＋只信參數的（不是通過條件）";
