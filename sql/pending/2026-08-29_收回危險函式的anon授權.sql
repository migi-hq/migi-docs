/* ============================================================
   收回 12 支管理／排程／開發函式的 anon 授權
   2026-08-29

   ── 為什麼 ──────────────────────────────────────────
   POS 與會員 App 都用 **anon key**，而那把 key 是公開的
   （它會被打包進瀏覽器拿得到的 JS）。所以「授權給 anon」
   ＝「**任何人打開 devtools 就叫得動**」。

   🔴 目前有 13 支管理／排程／開發用的函式給了 anon，其中三支特別嚴重：

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

   ── 收回之後誰還叫得動 ────────────────────────────
   | 身分 | 影響 |
   |---|---|
   | `authenticated`（總部 Email 登入） | ✅ 不動 —— migi-admin 用得到 |
   | `service_role`（Edge Function） | ✅ 不動 |
   | **pg_cron 排程** | ✅ **不受影響** —— job 以 postgres 身分執行，不看 anon 的授權 |
   | anon（POS／會員 App） | 🔴 叫不動了（**本來就不該叫**） |

   ✅ **查證過三個前端都沒有呼叫這 12 支**
     （grep `dev_reset_test_data|dev_set_test_balance|admin_remove_avatar|
       revoke_staff|grant_staff|reconcile_wallets|fix_wallet_balance|
       cleanup_empty_sessions|sweep_|generate_recurring|daily_wallet_audit`）。

   🔴 **`dev_clear_my_queues_tx` 刻意保留 anon** ——
     `migi-web/src/lib/social.js:225` 真的在用（會員清掉自己的配桌房）。
     ⚠ 它叫 `dev_` 開頭卻是給客人用的功能，**命名誤導** ——
       日後改名要走 DROP ＋ 前端同步，這次先不動。
   ============================================================ */

-- ── 管理用（4 支）────────────────────────────────
revoke execute on function public.grant_staff_tx(uuid, uuid, text) from anon;
revoke execute on function public.revoke_staff_tx(uuid) from anon;
revoke execute on function public.admin_remove_avatar_tx(uuid, text, boolean) from anon;
revoke execute on function public.reconcile_wallets_tx(uuid) from anon;

-- ── 錢包維運（1 支）──────────────────────────────
revoke execute on function public.fix_wallet_balance_tx(uuid, uuid) from anon;

-- ── pg_cron 排程專用（5 支）──────────────────────
--    ⚠ cron job 以 postgres 身分執行，收 anon 完全不影響排程。
revoke execute on function public.cleanup_empty_sessions_tx(integer) from anon;
revoke execute on function public.sweep_expired_queues_tx(uuid) from anon;
revoke execute on function public.sweep_auto_seat_tx(uuid) from anon;
revoke execute on function public.generate_recurring_instances_tx(uuid, integer) from anon;
revoke execute on function public.daily_wallet_audit_tx(uuid) from anon;

-- ── 開發工具（2 支）──────────────────────────────
revoke execute on function public.dev_reset_test_data_tx(bigint) from anon;
revoke execute on function public.dev_set_test_balance_tx(text, bigint) from anon;

-- 🔴 dev_clear_my_queues_tx 不收 —— migi-web 真的在用（見檔頭）


/* ============================================================
   驗證（單一 SELECT）

   ── 該看到什麼 ──────────────────────────────────────
   ① 12 支的 anon 全部變成「無」
   ② 🎯 **正對照**：`dev_clear_my_queues_tx` 的 anon **還在**
      —— 只驗「該收的收了」那一半是不夠的，
        **過度阻擋跟沒擋一樣糟，而且更難發現**（硬規則 3.55）。
        收錯的話 migi-web 的「清空我的配桌房」會靜靜壞掉。
   ③ authenticated 與 service_role **一個都沒被動到**
   ④ 全庫掃一次，確認沒有漏掉別的管理函式
   ============================================================ */
select 序, 項目, 內容 from (

  select 1 as 序, '① 該收的 12 支（anon 應全部是「無」）' as 項目,
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
         (select 'authenticated 有權限的支數 ' ||
                 count(*) filter (where has_function_privilege('authenticated', p.oid, 'execute'))::text ||
                 '／13　service_role ' ||
                 count(*) filter (where has_function_privilege('service_role', p.oid, 'execute'))::text || '／13'
              || case when count(*) filter (where has_function_privilege('authenticated', p.oid, 'execute')) = 13
                       and count(*) filter (where has_function_privilege('service_role', p.oid, 'execute')) = 13
                      then '　✅ 都沒動' else '　🔴 有被收到' end
            from pg_proc p
           where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
             and p.proname in ('grant_staff_tx','revoke_staff_tx','admin_remove_avatar_tx',
                               'reconcile_wallets_tx','fix_wallet_balance_tx',
                               'cleanup_empty_sessions_tx','sweep_expired_queues_tx',
                               'sweep_auto_seat_tx','generate_recurring_instances_tx',
                               'daily_wallet_audit_tx','dev_reset_test_data_tx',
                               'dev_set_test_balance_tx','dev_clear_my_queues_tx'))

  union all
  select 4, '④ 全庫再掃一次：還有沒有 anon 叫得動的管理／排程函式',
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
