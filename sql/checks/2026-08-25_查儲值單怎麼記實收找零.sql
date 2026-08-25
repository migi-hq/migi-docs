/* ============================================================
   查：儲值那張單的實收 / 找零記在哪
   2026-08-25 · 唯讀

   起因：
     pos_quick_checkout_tx（2026-08-25 建立）沒有
     p_topup_cash_received / p_topup_change_given，
     但 pos_checkout_with_topup_tx 有 —— 而 topup_tx 的簽名裡沒有這兩個。
     → 代表外層是自己寫進 topup_orders 的。

   為什麼一定要補：
     純儲值時 orderCash = 0 → payments = null，
     **實收與找零沒有任何一張 order_payments 可以承接**，
     全部只能記在儲值單上。不補的話「收 2000 找 500」完全不落地，
     交班日結對不起來（待辦 18）。

   ⚠ 現在補是免費的（還沒有任何東西呼叫 pos_quick_checkout_tx）；
     之後補要 DROP 重建 + 先推前端再跑 SQL 的部署順序。
   ============================================================ */

select 序, 項目, 內容 from (

  /* ① topup_orders 有哪些跟現金有關的欄位 */
  select 1 as 序, '① topup_orders 現金欄位' as 項目,
         column_name || '　' || data_type ||
         (case when is_nullable = 'YES' then '　可為 null' else '　🔴 NOT NULL' end) as 內容
    from information_schema.columns
   where table_schema = 'public' and table_name = 'topup_orders'
     and (column_name ilike '%cash%' or column_name ilike '%change%'
       or column_name ilike '%method%' or column_name ilike '%amount%')

  union all
  /* ② topup_orders 的 CHECK 約束
        order_payments 有 cash_fields_only_for_cash（change = received − amount），
        儲值單有沒有對應的規則？有的話補的時候要一起滿足。 */
  select 2, '② topup_orders CHECK',
         c.conname || '　' || pg_get_constraintdef(c.oid)
    from pg_constraint c
    join pg_class t on t.oid = c.conrelid
    join pg_namespace n on n.oid = t.relnamespace
   where n.nspname = 'public' and t.relname = 'topup_orders' and c.contype = 'c'

  union all
  /* ③ pos_checkout_with_topup_tx 裡跟這兩個欄位有關的每一行
        —— 直接照抄它的做法，不要自己發明第二種寫法。 */
  select 3, '③ 現行寫法（原始碼）', ln
    from (
      select unnest(string_to_array(pg_get_functiondef(p.oid), E'\n')) as ln
        from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.proname = 'pos_checkout_with_topup_tx'
    ) s
   where ln ~* '(cash_received|change_given|topup_orders)'

) x order by 序, 項目, 內容;
