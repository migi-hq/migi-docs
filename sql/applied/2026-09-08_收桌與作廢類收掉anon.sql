/* ============================================================
   收桌／取消開桌／作廢發票／贈點試算：收掉 anon
   2026-09-08 · 授權收斂第四批（換判準之後找到的）
   ============================================================

   ── 🎯 這一批是「換判準」直接換來的 ──────────────────────
   前三批掃暴露面用的是
       「簽名含 `p_member_id` ＋ anon 叫得動 ＋ 沒查 `current_member_id()`」
   而它看不見**不用會員當鍵**的金流函式（沖銷用交易 id、作廢用單號）。
   上一份把判準改成「**函式名裡有沒有動錢／動身分的動詞**」：
   ```
   topup|checkout|charge|refund|reverse|void|grant|revoke|
   rebind|merge|claim|settle|adjust|fix_wallet|reconcile
   ```
   ⇒ **當場多找出這四支**，而舊判準一支都看不到。
   📌 教訓不是「再加一個判準」，是**判準要對著「它會做什麼」，
     不是對著「它的參數長什麼樣」**。

   ── 四支各自的情況（全部查證過）────────────────────────
   | 函式 | 前端 | 資料庫內部 | 怎麼收 |
   |---|---|---|---|
   | `settle_session_tx` 收桌 | POS ×1 | — | `public`＋`anon`，**留 `authenticated`** |
   | `void_session_tx` 取消開桌 | POS ×1 | — | 同上 |
   | `void_invoice_tx` 作廢發票 | **0** | — | 全收 |
   | `calc_topup_bonus_tx` 贈點試算 | **0** | `topup_tx`／`pos_checkout_with_topup_tx` | 全收 |

   🔴 **前兩支的嚴重程度容易被低估**：它們不動錢，但
     `settle_session_tx` 會**把一桌收掉並讓在座玩家全部 `left_at`**，
     `void_session_tx` 會**作廢一張開著的場次**。
     知道一個 session id 就能讓店裡正在打的一桌消失 —— 而
     **店員看到的症狀是「系統自己把桌收了」**，查不到是誰做的
     （`p_staff_id` 現在從 `current_staff()` 覆寫，anon 呼叫時是 null）。

   🔴 **`void_invoice_tx` 是法律文件**。發票整條還沒接（`invoices` 0 筆、
     三端 0 個呼叫點），所以現在收零成本；等接上去時走 DEFINER 包裝或補授權。

   ⚠ **`calc_topup_bonus_tx` 全收是安全的，而理由要講清楚**：
     它只被 `topup_tx` 與 `pos_checkout_with_topup_tx` 呼叫，**兩支都是 DEFINER**
     ⇒ 在 DEFINER 裡呼叫時**呼叫端的權限不會被檢查**（硬規則 2.5 的反向）。
     ⇒ 收掉不影響儲值。驗證段第 ⑤ 格用**真的走一次 `topup_tx`** 來證明這件事，
       不是用推論。

   ── 🔴 刻意不動的 ──────────────────────────────────────
   · **`list_topup_plans_tx`** —— 儲值方案主檔，**會員 App 與 POS 都在讀**，
     而未登入的會員 App 是 anon。收了錢包頁的儲值方案會空掉。
   · **`trg_session_voided_release_queue` / `trg_topup_set_no`** ——
     那兩支是被上面的正則**誤抓**的觸發器函式（名字裡有 `void` / `topup`）。
     🎯 **`returns trigger` 的函式直接呼叫會被 Postgres 自己擋下**
       （`trigger functions can only be called as triggers`），
       所以那個 anon 授權**沒有任何攻擊面**。
     ⚠ 寫在這裡是為了讓下一個人看到清單時不會又去「修」它們。
   ============================================================ */


/* ── ⓪ guard：簽名逐字對 ＋ 沒有 policy／view／觸發器／排程引用 ── */
do $$
declare v_n int; v_ref text;
begin
  select count(*) into v_n
  from pg_proc p
  where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
    and (p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')') in (
      'settle_session_tx(p_session_id uuid, p_staff_id uuid, p_keep_for_walkin boolean)',
      'void_session_tx(p_session_id uuid, p_staff_id uuid)',
      'void_invoice_tx(p_invoice_id uuid, p_reason text, p_reissue boolean, p_idempotency_key text)',
      'calc_topup_bonus_tx(p_org_id uuid, p_store_id uuid, p_amount_twd bigint)'
    );
  if v_n <> 4 then
    raise exception '簽名對不上（找到 % 支，期望 4）—— 先撈 pg_proc 確認再跑', v_n;
  end if;

  select string_agg(x.位置, ' / ') into v_ref from (
    select 'policy:' || tablename || '.' || policyname as 位置 from pg_policies
     where coalesce(qual,'') || coalesce(with_check,'') ~ '(settle_session_tx|void_session_tx|void_invoice_tx|calc_topup_bonus_tx)'
    union all
    select 'view:' || viewname from pg_views
     where schemaname = 'public' and definition ~ '(settle_session_tx|void_session_tx|void_invoice_tx|calc_topup_bonus_tx)'
    union all
    select 'cron:' || jobname from cron.job
     where command ~ '(settle_session_tx|void_session_tx|void_invoice_tx|calc_topup_bonus_tx)'
  ) x;
  if v_ref is not null then
    raise exception '有東西在引用，先看過再決定：%', v_ref;
  end if;
end $$;


/* ── ① 收桌：POS 專用，保留 authenticated ─────────────────── */
revoke execute on function public.settle_session_tx(uuid, uuid, boolean) from public;
revoke execute on function public.settle_session_tx(uuid, uuid, boolean) from anon;
grant  execute on function public.settle_session_tx(uuid, uuid, boolean) to service_role;

/* ── ② 取消開桌：POS 專用，保留 authenticated ─────────────── */
revoke execute on function public.void_session_tx(uuid, uuid) from public;
revoke execute on function public.void_session_tx(uuid, uuid) from anon;
grant  execute on function public.void_session_tx(uuid, uuid) to service_role;

/* ── ③ 作廢發票：三端 0 個呼叫點，而它是法律文件 ───────────── */
revoke execute on function public.void_invoice_tx(uuid, text, boolean, text) from public;
revoke execute on function public.void_invoice_tx(uuid, text, boolean, text) from anon, authenticated;
grant  execute on function public.void_invoice_tx(uuid, text, boolean, text) to service_role;

/* ── ④ 贈點試算：只被兩支 DEFINER 內部呼叫 ─────────────────
   ⚠ 前端要看方案是叫 `list_topup_plans_tx`（不動），不是這一支。 */
revoke execute on function public.calc_topup_bonus_tx(uuid, uuid, bigint) from public;
revoke execute on function public.calc_topup_bonus_tx(uuid, uuid, bigint) from anon, authenticated;
grant  execute on function public.calc_topup_bonus_tx(uuid, uuid, bigint) to service_role;


/* ============================================================
   驗證段
   🎯 這一份最關鍵的是第 ⑤ 格：**儲值還通嗎**。
     `calc_topup_bonus_tx` 在儲值的路徑上，收錯了會讓
     「櫃檯儲值」整條壞掉 —— 而那正是 2026-08-24 踩過的形狀
     （`topup_tx` 從上線那天起就沒成功過一次）。
   ============================================================ */
do $$
declare v1 text; v2 text; v3 text; v_fake uuid := gen_random_uuid();
        v_store uuid; v_org uuid;
begin
  select o.id into v_org from public.orgs o order by o.created_at limit 1;
  select s.id into v_store from public.stores s where s.org_id = v_org order by s.created_at limit 1;

  /* ── ③ anon 叫 settle_session_tx → 應該被擋 ──────────────
     ⚠ 傳不存在的 session id：要分辨的是「permission denied」
       與「找不到那一桌」，後者代表權限是通的。 */
  begin
    set local role anon;
    perform public.settle_session_tx(v_fake, null, false);
    reset role;
    v1 := '🔴 anon 仍然叫得動 —— 沒收到';
  exception when others then
    reset role;
    v1 := case when sqlstate = '42501' or sqlerrm ~* 'permission denied'
               then '✅ anon 被擋（permission denied）'
               else '🔴 沒被權限擋，而是：' || left(coalesce(sqlerrm, '?'), 50) end;
  end;

  /* ── ④ 🎯 正對照：authenticated（登入後的 POS）叫同一支。
     🔴 不可以是 permission denied —— 「找不到那一桌」才是對的。 */
  begin
    set local role authenticated;
    perform public.settle_session_tx(v_fake, null, false);
    reset role;
    v2 := '✅ authenticated 叫得動（假 session 居然沒報錯，值得看一眼）';
  exception when others then
    reset role;
    v2 := case when sqlstate = '42501' or sqlerrm ~* 'permission denied'
               then '🔴 authenticated 被誤收 —— 收桌會壞'
               else '✅ 權限通了（擋在業務邏輯：' || left(coalesce(sqlerrm, '?'), 40) || '）' end;
  end;

  /* ── ⑤ 🎯 最關鍵的一格：儲值還通嗎。
     `topup_tx`（DEFINER）內部會呼叫剛剛被收掉的 `calc_topup_bonus_tx`。
     以 authenticated 真的走一次，用**不存在的會員** ⇒ 一定失敗，
     但要看它**失敗在哪裡**：
       · `permission denied for function calc_topup_bonus_tx` → 🔴 收壞了
       · 其他（找不到會員／外鍵）→ ✅ 內部呼叫沒被打壞
     ⚠ 整段包在會回滾的子交易裡；就算意外成功也不會留下。 */
  begin
    set local role authenticated;
    perform public.topup_tx(
      p_member_id => v_fake, p_store_id => v_store,
      p_points => 100, p_amount_twd => 100, p_pay_method => 'cash',
      p_idempotency_key => 'migi_probe_' || v_fake::text,
      p_bonus_points => null, p_external_ref => null,
      p_staff_id => null, p_note => 'probe');
    reset role;
    raise exception 'migi_rollback_topup_ok';
  exception when others then
    reset role;
    v3 := case
      when sqlerrm = 'migi_rollback_topup_ok'
        then '⚠ 假會員居然儲值成功了（已回滾）—— 權限通，但值得看一眼'
      when sqlerrm ~* 'permission denied.*calc_topup_bonus'
        then '🔴 收壞了：topup_tx 內部叫不動 calc_topup_bonus_tx'
      when sqlerrm ~* 'permission denied'
        then '🔴 權限被擋（不是 calc_topup_bonus）：' || left(sqlerrm, 50)
      else '✅ 儲值路徑通（擋在業務邏輯：' || left(coalesce(sqlerrm, '?'), 45) || '）' end;
  end;

  perform set_config('migi.v1', v1, true);
  perform set_config('migi.v2', v2, true);
  perform set_config('migi.v3', v3, true);
end $$;

select
  /* ── ① 四支的角色。前兩支要留 authenticated，後兩支要全收。 ── */
  coalesce((
    select string_agg(
      rpad(p.proname, 21)
      || '　anon：'  || case when exists (select 1 from aclexplode(p.proacl) a where a.grantee='anon'::regrole::oid and a.privilege_type='EXECUTE') then '🔴 還在' else '✅ 沒了' end
      || '　PUBLIC：' || case when (p.proacl is null or exists (select 1 from aclexplode(p.proacl) a where a.grantee=0 and a.privilege_type='EXECUTE')) then '🔴 還在' else '✅ 沒了' end
      || '　auth：'  ||
         case when p.proname in ('settle_session_tx','void_session_tx')
              then (case when exists (select 1 from aclexplode(p.proacl) a where a.grantee='authenticated'::regrole::oid and a.privilege_type='EXECUTE')
                         then '✅ 還在（POS 要用）' else '🔴 被誤收 —— 收銀機會壞' end)
              else (case when exists (select 1 from aclexplode(p.proacl) a where a.grantee='authenticated'::regrole::oid and a.privilege_type='EXECUTE')
                         then '🔴 還在' else '✅ 沒了' end) end
      || '　service_role：' || case when exists (select 1 from aclexplode(p.proacl) a where a.grantee='service_role'::regrole::oid and a.privilege_type='EXECUTE') then '✅ 有' else '🔴 沒有' end,
      E'\n' order by p.proname)
    from pg_proc p
    where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
      and p.proname in ('settle_session_tx','void_session_tx','void_invoice_tx','calc_topup_bonus_tx')
  ), '🔴 一支都找不到') as "① 四支的角色",

  /* ── ② 全庫數量（期望值當場查出來的，硬規則 3.56）：
       anon 明確  112 − 4 = 108
       PUBLIC     110 − 4 = 106　（這四支 PUBLIC 都有）
       函式總數   181，不變 */
  (select
     '　anon 明確：' || count(*) filter (where exists (
        select 1 from aclexplode(p.proacl) a
         where a.grantee = 'anon'::regrole::oid and a.privilege_type = 'EXECUTE'))
     || '（期望 108 ＝ 112 − 4）'
     || E'\n　PUBLIC　　：' || count(*) filter (where p.proacl is null or exists (
        select 1 from aclexplode(p.proacl) a
         where a.grantee = 0 and a.privilege_type = 'EXECUTE'))
     || '（期望 106 ＝ 110 − 4）'
     || E'\n　函式總數　：' || count(*) || '（期望 181，不變）'
   from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
  ) as "② 全庫數量",

  /* ── ③ 🎯 負對照：前面幾批刻意留 anon 的，一支都不能掉。
       ⚠ `list_topup_plans_tx` 掉了 → 會員 App 的儲值方案會空掉。 */
  coalesce((
    select string_agg(p.proname || '：' || case when exists (select 1 from aclexplode(p.proacl) a
        where a.grantee = 'anon'::regrole::oid and a.privilege_type = 'EXECUTE')
      then '✅ anon 還在' else '🔴 被誤傷了' end, E'\n' order by p.proname)
    from pg_proc p
    where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
      and p.proname in ('list_topup_plans_tx', 'log_app_event_tx', 'get_my_orders_tx',
                        'get_wallet_tx', 'list_tables_tx')
  ), '🔴 找不到') as "③ 負對照：刻意留 anon 的沒被誤傷",

  /* ── ④ 🎯 負對照：POS 那 13 支的 authenticated（11 支 ＋ 這一份的 2 支） ── */
  coalesce((
    select case when count(*) filter (where not exists (
             select 1 from aclexplode(p.proacl) a
              where a.grantee = 'authenticated'::regrole::oid and a.privilege_type = 'EXECUTE')) = 0
           then '✅ 13 支 POS 函式的 authenticated 全部還在（收銀機沒被波及）'
           else '🔴 掉了：' || coalesce(string_agg(p.proname, '　') filter (where not exists (
             select 1 from aclexplode(p.proacl) a
              where a.grantee = 'authenticated'::regrole::oid and a.privilege_type = 'EXECUTE')), '?') end
    from pg_proc p
    where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
      and p.proname in ('calc_session_fee_tx','check_session_blocks_tx','get_session_member_orders_tx',
                        'has_daypass_tx','join_session_tx','pos_add_member_note_tx','pos_addon_checkout_tx',
                        'pos_checkout_with_topup_tx','pos_member_detail_tx','pos_quick_checkout_tx','topup_tx',
                        'settle_session_tx','void_session_tx')
  ), '🔴 找不到') as "④ 負對照：POS 13 支的 authenticated",

  coalesce(nullif(current_setting('migi.v1', true), ''), '🔴 沒有訊息') as "⑤ anon 叫 settle_session_tx",
  coalesce(nullif(current_setting('migi.v2', true), ''), '🔴 沒有訊息') as "⑥ 🎯 正對照：authenticated 叫 settle_session_tx",
  coalesce(nullif(current_setting('migi.v3', true), ''), '🔴 沒有訊息') as "⑦ 🎯 最關鍵：儲值路徑還通嗎（topup_tx 內部叫 calc_topup_bonus_tx）",

  /* ── ⑧ 參考清單：用同一個新判準再掃一次。
       ⚠ **不是通過條件。** 期望剩下的都是「刻意留」或「觸發器誤抓」：
         list_topup_plans_tx（會員 App 讀）
         trg_session_voided_release_queue / trg_topup_set_no
           —— `returns trigger` 直接呼叫會被 Postgres 擋下，沒有攻擊面 */
  coalesce((
    select string_agg(p.proname || case when p.prorettype = 'trigger'::regtype then '（觸發器·無攻擊面）' else '' end,
                      E'\n' order by p.proname)
    from pg_proc p
    where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
      and p.proname ~ '(topup|checkout|charge|refund|reverse|void|grant|revoke|rebind|merge|claim|settle|adjust|fix_wallet|reconcile)'
      and exists (select 1 from aclexplode(p.proacl) a
                   where a.grantee = 'anon'::regrole::oid and a.privilege_type = 'EXECUTE')
  ), '（沒有了）') as "⑧ 參考：還有哪些動錢/動身分的 anon 叫得動";
