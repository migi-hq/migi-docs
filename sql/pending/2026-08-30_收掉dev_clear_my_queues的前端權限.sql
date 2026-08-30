/* ============================================================
   `dev_clear_my_queues_tx`：收掉 anon 與 PUBLIC
   2026-08-30

   ── 怎麼發現的 ──────────────────────────────────────
   在回答「上線後怎麼避免動到真實資料」時掃了一次
   dev_／void_／reset 類函式的授權，發現這一支**任何人都叫得動**。

   ── 為什麼是洞（不是「dev 工具沒關係」）────────────
   ```sql
   delete from match_queue_players where member_id = p_member;   -- 🔴 沒有 org 過濾
   ```
   · 它是 **SECURITY DEFINER**，所以繞過 RLS
   · `p_member` **是呼叫端給的**，不是從身分推出來的
   · 名字叫 `my`，但它刪的是**你指定的那個人**

   ⇒ 任何拿得到 anon key 的人（anon key 本來就會被打包進瀏覽器，
     硬規則 11.5 已經記過「它本來就是公開的」），
     **帶任何一個 member id 就能把那個人從所有房間踢出去**，
     順便刪掉因此變空的房。

   🔴 **對配桌是致命的**：客人報名了、房間湊滿了，然後被踢掉 ——
     而系統不會有任何錯誤，只會顯示「你沒有在任何房裡」。

   ── 為什麼現在收零風險 ────────────────────────────
   ```
   migi-pos    沒有呼叫
   migi-admin  沒有呼叫
   migi-web    social.js:223 `clearMyQueues()` 有包裝，
               但**整個專案沒有任何地方呼叫它** —— 死碼
   ```
   → 收掉不會弄壞任何功能。前端那個死掉的匯出同批刪除。

   ⚠ **函式本身留著**：它對測試仍然有用（清掉自己卡住的房），
     只是改成只有 `service_role` 能叫 —— 也就是只能從
     Dashboard／Edge Function 用，前端叫不動。

   ── 硬規則 2.6 ＋ 2.6b：兩個方向都要收 ────────────
   `anon` 可能從**兩條路**進來，收錯方向會是**不報錯的空操作**：
   · 舊函式 → 從 `PUBLIC` 繼承 → 要 `revoke from public`
   · 新函式 → Supabase 的 default privileges **明確授權** → 要 `revoke from anon`
   這一支**兩條都有**（`aclexplode` 查出來 anon 明確授權 ＋ PUBLIC 都在），
   所以兩行都要寫。
   ============================================================ */

revoke execute on function public.dev_clear_my_queues_tx(uuid, uuid) from public;
revoke execute on function public.dev_clear_my_queues_tx(uuid, uuid) from anon, authenticated;
grant  execute on function public.dev_clear_my_queues_tx(uuid, uuid) to service_role;


/* ============================================================
   驗證（單一 SELECT）

   🔴 **不可以只印 `has_function_privilege`** —— 它分不出
     「明確授權給 anon」與「從 PUBLIC 繼承」，所以收錯方向時
     看到的症狀跟沒收一模一樣（硬規則 2.6）。
     要用 `aclexplode` 把兩者分開印。

   🎯 **正對照**：同時印一支**應該還叫得動**的函式（`get_wallet_tx`）——
     如果連它也變成「收掉了」，那就是我下錯範圍而不是成功
     （「全部都沒有權限」與「該收的收了」長得很像，硬規則 3.55）。
   ============================================================ */
/* ⚠ 欄位別名**不要用大寫拉丁字母**（原本叫 `PUBLIC有嗎`）——
   Postgres 對沒加雙引號的識別字一律折成小寫，
   而子查詢裡若用 `"PUBLIC有嗎"` 保留了大寫，外層沒括就對不上，
   錯誤訊息會說 `column "public有嗎" does not exist`。
   → 全小寫或純中文最省事。 */
select 序, 函式, anon明確授權, 公開繼承嗎, service_role, 判定 from (

  select 1 as 序, p.proname::text as 函式,
         case when exists (select 1 from aclexplode(p.proacl) a
                where a.grantee='anon'::regrole::oid and a.privilege_type='EXECUTE')
              then '🔴 還在' else '✅ 收掉了' end as anon明確授權,
         case when p.proacl is null or exists (select 1 from aclexplode(p.proacl) a
                where a.grantee=0 and a.privilege_type='EXECUTE')
              then '🔴 還在' else '✅ 收掉了' end as 公開繼承嗎,
         case when exists (select 1 from aclexplode(p.proacl) a
                where a.grantee='service_role'::regrole::oid and a.privilege_type='EXECUTE')
              then '✅ 有' else '🔴 沒有（那就沒人叫得動了）' end as service_role,
         case when not has_function_privilege('anon', p.oid, 'execute')
              then '✅ 前端叫不動了' else '🔴 前端還是叫得動' end as 判定
    from pg_proc p
   where p.pronamespace='public'::regnamespace and p.proname='dev_clear_my_queues_tx'

  union all

  /* 🎯 正對照：這一支**必須**還是 anon 叫得動（會員 App 的錢包靠它） */
  select 2, p.proname::text || '（正對照，不該被收）',
         '—', '—', '—',
         case when has_function_privilege('anon', p.oid, 'execute')
              then '✅ 還叫得動（正確）' else '🔴 被我一起收掉了，錢包會壞' end
    from pg_proc p
   where p.pronamespace='public'::regnamespace and p.proname='get_wallet_tx'

) x order by 序;
