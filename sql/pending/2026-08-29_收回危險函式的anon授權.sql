/* ============================================================
   收回 12 支管理／排程／開發函式的 PUBLIC 執行權
   2026-08-29
   🔴 v2 —— v1 寫成 `revoke ... from anon` 是**空操作**，一支都沒收到。見下。

   ── 為什麼 ──────────────────────────────────────────
   POS 與會員 App 都用 **anon key**，而那把 key 是公開的
   （它會被打包進瀏覽器拿得到的 JS）。所以「anon 叫得動」
   ＝「**任何人打開 devtools 就叫得動**」。

   🔴 有 12 支管理／排程／開發用的函式 anon 叫得動，而且**全部是
     `SECURITY DEFINER`** —— 執行時繞過 RLS。這是最糟的組合：
     **誰都叫得動 ＋ 叫了之後沒有 RLS 擋**。其中三支特別嚴重：

   | 函式 | 任何人可以做什麼 |
   |---|---|
   | `grant_staff_tx` | **把自己升成 `owner`** |
   | `cleanup_empty_sessions_tx(0)` | **把所有 open 場次清掉** |
   | `dev_set_test_balance_tx` | **改別人的錢包餘額** |

   ⚠ `grant_staff_tx` 現在踩不到，是因為**讀 `staff.role` 的 RLS policy 是 0 條**
     （待辦 21）—— 也就是「沒人讀所以沒差」。
   🔴 **但待辦 21 明講：JWT 上線那天那些 policy 就會生效**，
     而那時**已經被塞進去的 staff 列會直接生效**。
     → 那不是「以後再修」，是「**現在就會留下不可見的後門**」。

   ── 🔴 v1 為什麼一支都沒收到（這才是重點）────────────
   v1 寫 `revoke execute ... from anon;`，跑完驗證顯示 12 支全部「還在」。
   查 `proacl` 才知道 **`anon` 根本不在授權清單裡**：

   ```
   grant_staff_tx 的 ACL：
     =X/postgres            ← 🔴 grantee 空白 = PUBLIC
     postgres=X/postgres
     authenticated=X/postgres
     service_role=X/postgres
   ```

   **Postgres 建立函式時預設就把 EXECUTE 授權給 `PUBLIC`**，而 `PUBLIC`
   包含所有角色 —— `anon` 是**繼承**來的，不是被授權的。
   → **收一個沒被授權的角色，不會有任何效果，也不會報錯。**

   🎯 這正是硬規則 3.55 的形狀：`revoke` 成功、驗證回「還在」，
     兩者同時發生而且都不是 bug —— **是我下錯了指令**。
     沒有那段驗證，這份 SQL 會被當成做完了。

   ── 為什麼只收這 12 支 ────────────────────────────
   全庫 138 支裡：
     · **126 支有明確的 `anon` 授權** —— 那是刻意給的（前端要叫），不動
     · **12 支只靠 PUBLIC 進來** —— 從來沒有人「決定」要給 anon
   → 收 PUBLIC 只影響這 12 支，其餘 126 支的 anon 是明確授權，不受影響。

   ── 收回之後誰還叫得動 ────────────────────────────
   | 身分 | 影響 | 為什麼 |
   |---|---|---|
   | `postgres` | ✅ 不動 | ACL 裡有明確的 `postgres=X` |
   | `authenticated`（總部 Email） | ✅ 不動 | 明確授權 |
   | `service_role`（Edge Function） | ✅ 不動 | 明確授權 |
   | **pg_cron 排程** | ✅ **不受影響** | job 以 postgres 身分執行 |
   | anon（POS／會員 App） | 🔴 叫不動了（**本來就不該叫**） | 只剩 PUBLIC 這條路而它被收了 |

   ✅ **查證過三個前端都沒有呼叫這 12 支**
     （grep `dev_reset_test_data|dev_set_test_balance|admin_remove_avatar|
       revoke_staff|grant_staff|reconcile_wallets|fix_wallet_balance|
       cleanup_empty_sessions|sweep_|generate_recurring|daily_wallet_audit`）。

   🔴 **`dev_clear_my_queues_tx` 完全不碰** ——
     `migi-web/src/lib/social.js:225` 真的在用（會員清掉自己的配桌房），
     而且它有**明確的 anon 授權**，本來就不在這 12 支裡。
     ⚠ 它叫 `dev_` 開頭卻是給客人用的功能，**命名誤導** ——
       日後改名要走 DROP ＋ 前端同步，這次先不動。

   ── ⚠ 順帶記一筆（不在這份範圍內）────────────────
   **134/138 支的 PUBLIC 都還在**，只是其中 126 支同時有明確 anon
   授權，所以收不收 PUBLIC 對它們沒有實際差別。
   🔴 但那仍是壞習慣：`PUBLIC` 會**自動涵蓋所有未來新增的角色**。
     日後真的加了第四個角色（例如「唯讀報表」），它會**自動拿到**
     那 134 支的執行權而沒有人做過那個決定。
   → 那是另一批（連同 `alter default privileges` 一起處理），不混進這份。
   ============================================================ */

-- ── 管理用（4 支）────────────────────────────────
revoke execute on function public.grant_staff_tx(p_member_id uuid, p_store_id uuid, p_role text) from public;
revoke execute on function public.revoke_staff_tx(p_staff_id uuid) from public;
revoke execute on function public.admin_remove_avatar_tx(p_member_id uuid, p_reason text, p_block boolean) from public;
revoke execute on function public.reconcile_wallets_tx(p_org_id uuid) from public;

-- ── 錢包維運（1 支）──────────────────────────────
revoke execute on function public.fix_wallet_balance_tx(p_org_id uuid, p_member_id uuid) from public;

-- ── pg_cron 排程專用（5 支）──────────────────────
--    ⚠ cron job 以 postgres 身分執行，收 PUBLIC 完全不影響排程。
revoke execute on function public.cleanup_empty_sessions_tx(p_idle_minutes integer) from public;
revoke execute on function public.sweep_expired_queues_tx(p_org_id uuid) from public;
revoke execute on function public.sweep_auto_seat_tx(p_org uuid) from public;
revoke execute on function public.generate_recurring_instances_tx(p_org_id uuid, p_days_ahead integer) from public;
revoke execute on function public.daily_wallet_audit_tx(p_org_id uuid) from public;

-- ── 開發工具（2 支）──────────────────────────────
revoke execute on function public.dev_reset_test_data_tx(p_reset_balance bigint) from public;
revoke execute on function public.dev_set_test_balance_tx(p_display_name text, p_balance bigint) from public;

-- 🔴 dev_clear_my_queues_tx 不在名單裡 —— 它有明確 anon 授權，migi-web 真的在用


/* ============================================================
   驗證（單一 SELECT）

   ── 該看到什麼 ──────────────────────────────────────
   ① 12 支的 anon 全部變成「已收」
   ② 🎯 **正對照**：`dev_clear_my_queues_tx` 的 anon **還在**
      —— 只驗「該收的收了」那一半是不夠的，
        **過度阻擋跟沒擋一樣糟，而且更難發現**（硬規則 3.55）。
        收錯的話 migi-web 的「清空我的配桌房」會靜靜壞掉。
   ③ authenticated 與 service_role **一個都沒被動到**
   ④ 其餘 126 支明確授權 anon 的函式**一支都不能少**
      —— 這一段防的是「PUBLIC 收太廣」，那會讓整個前端掛掉
   ⑤ 全庫掃一次，確認沒有漏掉別的管理函式
   ============================================================ */
select 序, 項目, 內容 from (

  select 1 as 序, '① 該收的 12 支（anon 應全部是「已收」）' as 項目,
         (select string_agg(p.proname
                 || '　anon=' || case when has_function_privilege('anon', p.oid, 'execute')
                                      then '🔴 還在' else '✅ 已收' end,
                 E'\n' order by p.proname)
            from pg_proc p
           where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
             and p.proname in ('grant_staff_tx','revoke_staff_tx','admin_remove_avatar_tx',
                               'reconcile_wallets_tx','fix_wallet_balance_tx',
                               'cleanup_empty_sessions_tx','sweep_expired_queues_tx',
                               'sweep_auto_seat_tx','generate_recurring_instances_tx',
                               'daily_wallet_audit_tx','dev_reset_test_data_tx',
                               'dev_set_test_balance_tx')) as 內容

  union all
  select 2, '② 🎯 正對照：dev_clear_my_queues_tx 的 anon 不該被收',
         (select 'anon=' || case when has_function_privilege('anon', p.oid, 'execute')
                                 then '✅ 還在（正確 —— migi-web 在用）'
                                 else '🔴 被誤收了！migi-web 的「清空我的配桌房」會壞掉' end
            from pg_proc p
           where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
             and p.proname = 'dev_clear_my_queues_tx')

  union all
  select 3, '③ authenticated 與 service_role 不該被動到',
         (select 'authenticated ' ||
                 count(*) filter (where has_function_privilege('authenticated', p.oid, 'execute'))::text ||
                 '／12　service_role ' ||
                 count(*) filter (where has_function_privilege('service_role', p.oid, 'execute'))::text || '／12'
              || case when count(*) filter (where has_function_privilege('authenticated', p.oid, 'execute')) = 12
                       and count(*) filter (where has_function_privilege('service_role', p.oid, 'execute')) = 12
                      then '　✅ 都沒動' else '　🔴 有被收到' end
            from pg_proc p
           where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
             and p.proname in ('grant_staff_tx','revoke_staff_tx','admin_remove_avatar_tx',
                               'reconcile_wallets_tx','fix_wallet_balance_tx',
                               'cleanup_empty_sessions_tx','sweep_expired_queues_tx',
                               'sweep_auto_seat_tx','generate_recurring_instances_tx',
                               'daily_wallet_audit_tx','dev_reset_test_data_tx',
                               'dev_set_test_balance_tx'))

  union all
  /* 🎯 第二個正對照：確認沒有把前端要用的那 126 支一起收掉。
        跑之前是 126，跑之後也要是 126。 */
  select 4, '④ 🎯 正對照：明確授權 anon 的函式數（跑之前 126，之後也要 126）',
         (select count(*)::text || ' 支'
              || case when count(*) = 126 then '　✅ 一支都沒少'
                      else '　🔴 數字變了 —— 前端會有東西叫不動' end
            from pg_proc p
           where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
             and exists (select 1 from aclexplode(coalesce(p.proacl,'{}')) a
                          where a.grantee = 'anon'::regrole::oid
                            and a.privilege_type = 'EXECUTE'))

  union all
  select 5, '⑤ 全庫再掃一次：還有沒有 anon 叫得動的管理／排程／開發函式',
         coalesce((select string_agg(p.proname, '、' order by p.proname)
            from pg_proc p
           where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
             and has_function_privilege('anon', p.oid, 'execute')
             and (p.proname like 'dev_%' or p.proname like 'admin_%'
               or p.proname like 'sweep_%' or p.proname like '%_audit_%'
               or p.proname in ('grant_staff_tx','revoke_staff_tx','reconcile_wallets_tx',
                                'fix_wallet_balance_tx','cleanup_empty_sessions_tx',
                                'generate_recurring_instances_tx'))),
           '（一支都沒有）')
         || E'\n  ⚠ 只該剩 dev_clear_my_queues_tx'

) x order by 序;
