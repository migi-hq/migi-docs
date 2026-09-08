/* ============================================================
   沖銷與作廢：收掉 anon
   2026-09-08 · 承前兩份授權收斂的收尾
   ============================================================

   ── 🔴 為什麼前兩份沒抓到這兩支 ──────────────────────────
   前兩份掃暴露面用的判準是
       「簽名含 `p_member_id` ＋ anon 叫得動 ＋ 沒查 `current_member_id()`」
   而這兩支用的**不是會員 id**：
       reverse_txn_tx(**p_original_txn_id**, ...)   沖銷一筆錢包交易
       topup_void_tx(**p_topup_id**, ...)            作廢一張儲值單
   ⇒ **整批掃描完全看不到它們。**

   🎯 **金流函式不一定用會員當鍵** —— 沖銷用交易 id、作廢用單號。
     下次掃暴露面，判準要是「**它會不會動到錢或身分**」，
     不是「簽名長什麼樣」。
   ⚠ 這是同一天第二次儀器出錯（前一次是把「函式體有 `current_staff()`」
     讀成「有擋牆」，而那多半只是稽核欄位覆寫）。**先懷疑儀器**（硬規則 3.5）。

   ── 兩支的處理方式不同，而那不是不一致 ──────────────────
   | | 是什麼 | 怎麼收 |
   |---|---|---|
   | `reverse_txn_tx` | **INVOKER**，退款沖正的底層 | `public` ＋ `anon` ＋ `authenticated` 全收 |
   | `topup_void_tx`  | **DEFINER**，簽名有 `p_staff_id` | 收 `public` ＋ `anon`，**保留 `authenticated`** |

   🎯 **`reverse_txn_tx` 就列在 `docs/01-資料庫/RPC職責與設計.md` 那份
     「INVOKER —— 前端不可直接呼叫」的清單裡**，與今天已經收掉的
     `checkout_tx` / `_charge_core` / `charge_fnb_tx` 並排。
     **它是同一張清單上漏掉的第四支。**
     ⇒ 日後做退款時的正解是**開一支 DEFINER 包裝**（同 `pos_addon_checkout_tx`
       之於 `checkout_tx`），不是讓前端直接叫它。
     ⚠ 它現在是 INVOKER ＋ anon，就算不收，POS 直接叫也會被 RLS
       **濾成什麼都沒發生而且不報錯**（硬規則 4）——
       **「叫得動」與「有用」是兩件事，而這種形狀最難查。**

   `topup_void_tx` 則是**等 UI 的 POS 操作**：DEFINER、收 `p_staff_id`
   （2026-09-04 起那個參數已改成從 `current_staff()` 覆寫）。
   ⇒ 作廢儲值的畫面做出來時，POS 會以 `authenticated` 直接叫它 ——
     保留 `authenticated` 與那 11 支 POS 函式同一個處理（也是使用者選的範圍）。
   ⚠ 它的 anon 是 **2026-08-28 為了「日後做作廢儲值」補上的**，
     而那個功能到今天還沒做 ⇒ **一支沒人叫卻對外開著的作廢函式，開了 11 天。**
     📌 順帶的教訓：**不要為了「日後會用到」提前開授權。**
       開的那一刻它就是暴露面，而「日後」可能永遠不來。

   ── 事前查證 ────────────────────────────────────────────
   · 三端呼叫點：**兩支都是 0**（用加引號的字串比對，排除註解命中）
   · 資料庫內部：**兩支都沒有任何函式呼叫它們**
   · policy / view / trigger / pg_cron：見下面 ⓪ 的 guard
   · `topup_void_tx` **沒有 PUBLIC**（只有明確授權），`reverse_txn_tx` 兩條都有
     ⇒ 兩個方向都寫（硬規則 2.6b），其中一行是刻意留著的空操作
   ============================================================ */


/* ── ⓪ guard：簽名逐字對 ＋ 確認沒有任何地方引用 ───────────── */
do $$
declare v_n int; v_ref text;
begin
  select count(*) into v_n
  from pg_proc p
  where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
    and (p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')') in (
      'reverse_txn_tx(p_original_txn_id uuid, p_idempotency_key text, p_reason text)',
      'topup_void_tx(p_topup_id uuid, p_idempotency_key text, p_staff_id uuid, p_reason text)'
    );
  if v_n <> 2 then
    raise exception '簽名對不上（找到 % 支，期望 2）—— 先撈 pg_proc 確認再跑', v_n;
  end if;

  /* ⚠ 收授權之前確認沒有 policy／view／觸發器／排程在用它們 ——
     那些地方壞掉的症狀跟前端壞掉完全不同，而且更難追。 */
  select string_agg(x.位置, ' / ') into v_ref from (
    select 'policy:' || tablename || '.' || policyname as 位置 from pg_policies
     where coalesce(qual,'') || coalesce(with_check,'') ~ '(reverse_txn_tx|topup_void_tx)'
    union all
    select 'view:' || viewname from pg_views
     where schemaname = 'public' and definition ~ '(reverse_txn_tx|topup_void_tx)'
    union all
    select 'trigger:' || t.tgname from pg_trigger t join pg_proc p2 on p2.oid = t.tgfoid
     where not t.tgisinternal and pg_get_functiondef(p2.oid) ~ '(reverse_txn_tx|topup_void_tx)'
    union all
    select 'cron:' || jobname from cron.job where command ~ '(reverse_txn_tx|topup_void_tx)'
  ) x;
  if v_ref is not null then
    raise exception '有東西在引用，先看過再決定：%', v_ref;
  end if;
end $$;


/* ── ① 沖銷：INVOKER，前端永遠不該直接叫 ───────────────────
   （同 `checkout_tx` / `_charge_core` / `charge_fnb_tx`，
     那三支 2026-09-08 已經收乾淨，這是同一張清單的第四支） */
revoke execute on function public.reverse_txn_tx(uuid, text, text) from public;
revoke execute on function public.reverse_txn_tx(uuid, text, text) from anon, authenticated;
grant  execute on function public.reverse_txn_tx(uuid, text, text) to service_role;

/* ── ② 作廢儲值單：DEFINER 的 POS 操作，保留 authenticated ──
   ⚠ 下面那行 `from public` 是**刻意的空操作** —— 這一支本來就沒有 PUBLIC。
     留著是為了讓「兩個方向都要收」在檔案裡一眼看得到（硬規則 2.6b），
     因為收錯方向的症狀跟沒收一模一樣而且不會報錯。 */
revoke execute on function public.topup_void_tx(uuid, text, uuid, text) from public;
revoke execute on function public.topup_void_tx(uuid, text, uuid, text) from anon;
grant  execute on function public.topup_void_tx(uuid, text, uuid, text) to service_role;


/* ============================================================
   驗證段
   ⚠ 這兩支都會**動到錢**，所以測「該通的還通嗎」時
     一律傳一個**不存在的 uuid** ——
     要分辨的是「permission denied」與「找不到那筆」，
     而後者證明權限是通的。整段仍然包在會回滾的子交易裡。
   ============================================================ */
do $$
declare v1 text; v2 text; v3 text; v4 text; v_fake uuid := gen_random_uuid();
begin
  /* ── ③ anon 叫 topup_void_tx → 應該被擋 ────────────────── */
  begin
    set local role anon;
    perform public.topup_void_tx(v_fake, 'migi_probe_' || v_fake::text, null, 'probe');
    reset role;
    v1 := '🔴 anon 仍然叫得動 —— 沒收到';
  exception when others then
    reset role;
    v1 := case when sqlstate = '42501' or sqlerrm ~* 'permission denied'
               then '✅ anon 被擋（permission denied）'
               else '🔴 沒被權限擋，而是：' || coalesce(sqlerrm, '(無訊息)') end;
  end;

  /* ── ④ 🎯 正對照：authenticated（＝登入後的 POS）叫同一支。
     🔴 **不可以是 permission denied** —— 可以是「找不到那筆儲值單」，
       那正好證明它穿過了權限這一關。
     少了這一格，「連 authenticated 也收掉」會全綠而日後做作廢功能時才發現。 */
  begin
    set local role authenticated;
    perform public.topup_void_tx(v_fake, 'migi_probe2_' || v_fake::text, null, 'probe');
    reset role;
    v2 := '✅ authenticated 叫得動（而且居然沒報錯 —— 假 uuid 應該找不到，值得看一眼）';
  exception when others then
    reset role;
    v2 := case when sqlstate = '42501' or sqlerrm ~* 'permission denied'
               then '🔴 authenticated 被誤收 —— 日後做作廢儲值會壞'
               else '✅ 權限通了（擋在業務邏輯：' || left(coalesce(sqlerrm, '?'), 40) || '）' end;
  end;

  /* ── ⑤ anon 叫 reverse_txn_tx → 應該被擋 ───────────────── */
  begin
    set local role anon;
    perform public.reverse_txn_tx(v_fake, 'migi_probe3_' || v_fake::text, 'probe');
    reset role;
    v3 := '🔴 anon 仍然叫得動 —— 沒收到';
  exception when others then
    reset role;
    v3 := case when sqlstate = '42501' or sqlerrm ~* 'permission denied'
               then '✅ anon 被擋（permission denied）'
               else '🔴 沒被權限擋，而是：' || coalesce(sqlerrm, '(無訊息)') end;
  end;

  /* ── ⑥ 🎯 正對照：service_role 叫 reverse_txn_tx。
     它是日後那支 DEFINER 包裝會走的路 —— 收過頭的話這一格會紅。 */
  begin
    set local role service_role;
    perform public.reverse_txn_tx(v_fake, 'migi_probe4_' || v_fake::text, 'probe');
    reset role;
    v4 := '✅ service_role 叫得動';
  exception when others then
    reset role;
    v4 := case when sqlstate = '42501' or sqlerrm ~* 'permission denied'
               then '🔴 service_role 也被收掉了 —— 收過頭'
               else '✅ 權限通了（擋在業務邏輯：' || left(coalesce(sqlerrm, '?'), 40) || '）' end;
  end;

  perform set_config('migi.v1', v1, true);
  perform set_config('migi.v2', v2, true);
  perform set_config('migi.v3', v3, true);
  perform set_config('migi.v4', v4, true);
end $$;

select
  /* ── ① 兩支的四個角色 ── */
  coalesce((
    select string_agg(
      rpad(p.proname, 16)
      || '　anon：'  || case when exists (select 1 from aclexplode(p.proacl) a where a.grantee='anon'::regrole::oid and a.privilege_type='EXECUTE') then '🔴 還在' else '✅ 沒了' end
      || '　PUBLIC：' || case when (p.proacl is null or exists (select 1 from aclexplode(p.proacl) a where a.grantee=0 and a.privilege_type='EXECUTE')) then '🔴 還在' else '✅ 沒了' end
      || '　auth：'  || case when exists (select 1 from aclexplode(p.proacl) a where a.grantee='authenticated'::regrole::oid and a.privilege_type='EXECUTE')
                            then (case when p.proname = 'topup_void_tx' then '✅ 還在（刻意保留）' else '🔴 還在' end)
                            else (case when p.proname = 'topup_void_tx' then '🔴 被誤收' else '✅ 沒了' end) end
      || '　service_role：' || case when exists (select 1 from aclexplode(p.proacl) a where a.grantee='service_role'::regrole::oid and a.privilege_type='EXECUTE') then '✅ 有' else '🔴 沒有' end,
      E'\n' order by p.proname)
    from pg_proc p
    where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
      and p.proname in ('reverse_txn_tx', 'topup_void_tx')
  ), '🔴 一支都找不到') as "① 兩支的四個角色",

  /* ── ② 全庫數量。期望值當場查出來的（硬規則 3.56）：
       anon 明確  114 − 2 = 112
       PUBLIC     111 − 1 = 110　（topup_void_tx 本來就沒有 PUBLIC）
       函式總數   181，不變 */
  (select
     '　anon 明確：' || count(*) filter (where exists (
        select 1 from aclexplode(p.proacl) a
         where a.grantee = 'anon'::regrole::oid and a.privilege_type = 'EXECUTE'))
     || '（期望 112 ＝ 114 − 2）'
     || E'\n　PUBLIC　　：' || count(*) filter (where p.proacl is null or exists (
        select 1 from aclexplode(p.proacl) a
         where a.grantee = 0 and a.privilege_type = 'EXECUTE'))
     || '（期望 110 ＝ 111 − 1）'
     || E'\n　函式總數　：' || count(*) || '（期望 181，不變）'
   from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
  ) as "② 全庫數量",

  /* ── ③ 🎯 負對照：前一份保留 authenticated 的 11 支 POS 函式
       不可以被這一份波及。⚠ 只要有一支掉了，收銀機就當機。 */
  coalesce((
    select case when count(*) filter (where not exists (
             select 1 from aclexplode(p.proacl) a
              where a.grantee = 'authenticated'::regrole::oid and a.privilege_type = 'EXECUTE')) = 0
           then '✅ 11 支 POS 函式的 authenticated 全部還在（收銀機沒被波及）'
           else '🔴 有 ' || count(*) filter (where not exists (
             select 1 from aclexplode(p.proacl) a
              where a.grantee = 'authenticated'::regrole::oid and a.privilege_type = 'EXECUTE'))
             || ' 支掉了：' || coalesce(string_agg(p.proname, '　') filter (where not exists (
             select 1 from aclexplode(p.proacl) a
              where a.grantee = 'authenticated'::regrole::oid and a.privilege_type = 'EXECUTE')), '?') end
    from pg_proc p
    where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
      and p.proname in ('calc_session_fee_tx','check_session_blocks_tx','get_session_member_orders_tx',
                        'has_daypass_tx','join_session_tx','pos_add_member_note_tx','pos_addon_checkout_tx',
                        'pos_checkout_with_topup_tx','pos_member_detail_tx','pos_quick_checkout_tx','topup_tx')
  ), '🔴 一支都找不到') as "③ 負對照：POS 那 11 支沒被波及",

  /* ── ④ 🎯 負對照：刻意留 anon 的兩支還在 ── */
  coalesce((
    select string_agg(p.proname || '：' || case when exists (select 1 from aclexplode(p.proacl) a
        where a.grantee = 'anon'::regrole::oid and a.privilege_type = 'EXECUTE')
      then '✅ anon 還在' else '🔴 被誤傷了' end, '　' order by p.proname)
    from pg_proc p
    where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
      and p.proname in ('log_app_event_tx', 'get_my_orders_tx')
  ), '🔴 找不到') as "④ 負對照：埋點與消費明細沒被誤傷",

  coalesce(nullif(current_setting('migi.v1', true), ''), '🔴 沒有訊息') as "⑤ anon 叫 topup_void_tx",
  coalesce(nullif(current_setting('migi.v2', true), ''), '🔴 沒有訊息') as "⑥ 🎯 正對照：authenticated 叫 topup_void_tx",
  coalesce(nullif(current_setting('migi.v3', true), ''), '🔴 沒有訊息') as "⑦ anon 叫 reverse_txn_tx",
  coalesce(nullif(current_setting('migi.v4', true), ''), '🔴 正對照：service_role 叫 reverse_txn_tx') as "⑧ 🎯 正對照：service_role 叫 reverse_txn_tx",

  /* ── ⑨ 參考清單：還有哪些「會動到錢或身分」的函式 anon 叫得動。
       ⚠ **不是通過條件。** 這一格用的是新判準（動詞在函式名裡），
         不是舊的「簽名含 p_member_id」—— 那個判準正是漏掉這兩支的原因。 */
  coalesce((
    select string_agg(p.proname, '　' order by p.proname)
    from pg_proc p
    where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
      and p.proname ~ '(topup|checkout|charge|refund|reverse|void|grant|revoke|rebind|merge|claim|settle|adjust|fix_wallet|reconcile)'
      and exists (select 1 from aclexplode(p.proacl) a
                   where a.grantee = 'anon'::regrole::oid and a.privilege_type = 'EXECUTE')
  ), '（沒有了）') as "⑨ 參考：還有哪些動錢/動身分的函式 anon 叫得動";
