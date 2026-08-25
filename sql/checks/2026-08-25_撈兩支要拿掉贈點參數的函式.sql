/* ============================================================
   撈：兩支要拿掉贈點參數的函式（contract 第三步的材料）
   2026-08-25 · 唯讀

   ⚠ **這支可以現在跑（唯讀），但改的那批要等前端部署完。**

   要拿掉的兩個參數：
       topup_tx                   … p_bonus_points bigint default 0
       pos_checkout_with_topup_tx … p_topup_bonus  bigint default 0

   2026-08-24 起 topup_tx 自己查 topup_plans 算贈點，呼叫端送什麼都不採信。
   留著參數的代價是**下一個人會以為它有用**。

   ── 為什麼兩支要一起改 ──────────────────────────────
   pos_checkout_with_topup_tx **內部呼叫 topup_tx**。
   只改其中一支的話：
     · 先拿掉 topup_tx 的 → 包裝那支的呼叫會找不到函式
     · 先拿掉包裝的     → 它還在傳 p_bonus_points 給 topup_tx
   → 同一份 SQL、同一個交易裡一起 DROP 重建。

   🔴 **DROP 會把 GRANT 一起帶走**（硬規則 2）——
     兩支都要在檔案結尾補回 `grant execute ... to anon, authenticated`。
     ⚠ 2026-08-25 才因為 topup_tx 沒有 anon EXECUTE 讓櫃檯儲值整條不能用；
       那次的原因不同（從來沒授權過），但這次如果忘了補，會變成同一個症狀。

   ── 順帶要查的第三件事 ──────────────────────────────
   `migi-pos/src/shared.jsx:78` 的註解提到一支 `calc_topup_bonus_tx`。
   我沒見過它。它若存在且是贈點的真正來源，重建 topup_tx 時要照樣呼叫；
   若不存在，那句註解是過期的，要一併修掉。
   ============================================================ */

select 序, 項目, 內容 from (

  /* ① 兩支的完整定義 —— 硬規則 3：改既有函式一律先撈線上版，
        applied/ 只是「當時交付的版本」，不是鏡像。 */
  select 1 as 序, '① topup_tx' as 項目,
         coalesce((select pg_get_functiondef(p.oid)
                     from pg_proc p
                    where p.pronamespace = 'public'::regnamespace
                      and p.prokind = 'f' and p.proname = 'topup_tx'
                    limit 1), '🔴 不存在') as 內容

  union all
  select 2, '② pos_checkout_with_topup_tx',
         coalesce((select pg_get_functiondef(p.oid)
                     from pg_proc p
                    where p.pronamespace = 'public'::regnamespace
                      and p.prokind = 'f' and p.proname = 'pos_checkout_with_topup_tx'
                    limit 1), '🔴 不存在')

  union all
  /* ③ calc_topup_bonus_tx 到底存不存在 */
  select 3, '③ calc_topup_bonus_tx',
         coalesce((select p.proname || '(' || pg_get_function_arguments(p.oid) || ')'
                     from pg_proc p
                    where p.pronamespace = 'public'::regnamespace
                      and p.prokind = 'f' and p.proname ilike '%topup_bonus%'
                    limit 1),
                  '🔴 不存在 —— shared.jsx:78 那句註解是過期的')

  union all
  /* ④ 還有沒有別的函式在呼叫它們（改簽名會連帶影響誰）
        ⚠ prokind = 'f' 不可省（硬規則 3.7）：
          pg_get_functiondef 對聚合函式會直接拋錯。 */
  select 4, '④ 誰呼叫 topup_tx',
         coalesce((select string_agg(p.proname, '、' order by p.proname)
                     from pg_proc p
                    where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
                      and p.proname <> 'topup_tx'
                      and pg_get_functiondef(p.oid) ilike '%topup_tx(%'),
                  '（沒有其他函式呼叫它）')

  union all
  /* ⑤ 現在的授權狀態 —— DROP 之後要補回同樣的對象 */
  select 5, '⑤ 目前的 EXECUTE 授權',
         string_agg(p.proname || '：anon ' ||
                    (case when has_function_privilege('anon', p.oid, 'EXECUTE') then '✅' else '🔴' end) ||
                    '／authenticated ' ||
                    (case when has_function_privilege('authenticated', p.oid, 'EXECUTE') then '✅' else '🔴' end),
                    '　│　' order by p.proname)
    from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
     and p.proname in ('topup_tx', 'pos_checkout_with_topup_tx')

) x order by 序, 項目;
