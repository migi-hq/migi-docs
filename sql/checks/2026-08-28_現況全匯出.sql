/* ============================================================
   資料庫現況全匯出 —— 一次查完，之後 grep 檔案不用再問
   2026-08-28 · 唯讀

   ── 為什麼 ──────────────────────────────────────────
   `docs/01-資料庫/db-現況快照.md` 是 2026-08-14 盤點的，
   而且**連 `products` 這張表都沒有**。
   2026-08-27 一天內查到的 7 個東西，有 5 個不在裡面：
     is_available／subcategory／discountable／tracks_stock／is_system
     ＋ order_payments 的三條 CHECK

   🔴 而 CLAUDE.md 記過：**文件漂得比 `sql/applied/` 更兇**（踩坑第 29 條）。
     每次要動 schema 都得重新查一次，是因為沒有一份夠新的鏡像。

   ── 這一份要換掉什麼 ────────────────────────────────
   今晚光是餐飲文件就有三個問題只能寫成「⚠ 要先查證」：
     · `subcategory` 現在裝什麼值
     · `is_active` 與 `is_available` 的實際語意差別
     · `category` 到底有哪些值
   有了這份匯出，這類問題直接查檔案。

   ⚠ **這不是要取代逐次查證**（硬規則 3 仍然成立：改既有函式一律
     先 `pg_get_functiondef` 撈線上版）。
     它取代的是「這張表有哪些欄位」「這個約束在管什麼」這類**背景事實**。

   ── 輸出很長（估 250–300 列）────────────────────────
   每一列都很短，全選複製即可。分四段：
     ① 每張表的欄位
     ② 每一條 CHECK 約束
     ③ 每一個唯一性（**約束與索引兩邊都撈** —— 2026-08-26 的教訓：
        `CREATE UNIQUE INDEX` 建的不會出現在 `pg_constraint` 裡）
     ④ 每一支函式的簽名／DEFINER／anon 授權（硬規則 2.5）
   ============================================================ */

select 段, 名稱, 內容 from (

  /* ① 每張表的欄位。一列一張表。 */
  select '1_欄位' as 段, c.table_name as 名稱,
         string_agg(
           c.column_name || ' ' ||
           case c.data_type
             when 'timestamp with time zone' then 'timestamptz'
             when 'character varying' then 'varchar'
             when 'double precision' then 'float8'
             else c.data_type end ||
           case c.is_nullable when 'NO' then '!' else '' end ||
           case when c.column_default is not null
                then '=' || left(regexp_replace(c.column_default, '::[a-z ]+', '', 'g'), 20)
                else '' end,
           ' │ ' order by c.ordinal_position) as 內容
    from information_schema.columns c
    join information_schema.tables t
      on t.table_schema = c.table_schema and t.table_name = c.table_name
     and t.table_type = 'BASE TABLE'
   where c.table_schema = 'public'
   group by c.table_name

  union all
  /* ② 每一條 CHECK。
        🔴 硬規則 3.8：錯誤訊息只給約束名字不給定義 ——
          看到 xxx_check 就推論它在管什麼，那是猜。這裡全部展開。
        ⚠ 排除 NOT NULL 自動產生的（那些在 ① 已經用 ! 標了）。 */
  select '2_CHECK', t.relname || '.' || c.conname,
         pg_get_constraintdef(c.oid)
    from pg_constraint c
    join pg_class t on t.oid = c.conrelid
   where t.relnamespace = 'public'::regnamespace
     and c.contype = 'c'
     and pg_get_constraintdef(c.oid) not like '%IS NOT NULL)'

  union all
  /* ③ 唯一性 —— 約束那一邊。 */
  select '3_唯一', t.relname || '.' || c.conname || '（約束）',
         pg_get_constraintdef(c.oid)
    from pg_constraint c
    join pg_class t on t.oid = c.conrelid
   where t.relnamespace = 'public'::regnamespace
     and c.contype in ('u','p')

  union all
  /* ③ 唯一性 —— 索引那一邊。
        🔴 2026-08-26 的教訓：查「有沒有唯一限制」時 `pg_constraint`
          與 `pg_index` **兩邊都要看** —— `CREATE UNIQUE INDEX` 建的
          不會出現在 pg_constraint 裡。
          `uq_staff_member_store` 與 `uq_members_line_user` 都是這一類。
        ⚠ 一併看 indisvalid：INVALID 的索引會存在、看得到、
          但完全不擋，而且沒有任何症狀。 */
  select '3_唯一', t.relname || '.' || i.relname || '（索引）',
         pg_get_indexdef(x.indexrelid) ||
         case when x.indisvalid then '' else '　🔴 INVALID（不會擋！）' end
    from pg_index x
    join pg_class i on i.oid = x.indexrelid
    join pg_class t on t.oid = x.indrelid
   where t.relnamespace = 'public'::regnamespace
     and x.indisunique
     and not exists (select 1 from pg_constraint c
                      where c.conindid = x.indexrelid and c.contype in ('u','p'))

  union all
  /* ④ 每一支函式：簽名／DEFINER／anon 授權。
        🔴 硬規則 2.5：「函式在包裝裡跑得動」不代表「前端叫得動」——
          權限是在**呼叫點**檢查的，而在 DEFINER 裡呼叫端的權限根本不會被檢查。
          `topup_tx` 就是這樣：櫃檯儲值從上線那天起沒成功過一次。
        ⚠ 硬規則 3.7：一定要 prokind='f'（聚合／視窗／程序會讓某些操作拋錯）。 */
  select '4_函式', p.proname,
         '(' || pg_get_function_identity_arguments(p.oid) || ')　' ||
         case p.prosecdef when true then 'DEFINER' else 'INVOKER' end ||
         '　anon=' ||
         case when has_function_privilege('anon', p.oid, 'EXECUTE') then '✅' else '無' end ||
         '　auth=' ||
         case when has_function_privilege('authenticated', p.oid, 'EXECUTE') then '✅' else '無' end
    from pg_proc p
   where p.pronamespace = 'public'::regnamespace
     and p.prokind = 'f'

) x order by 段, 名稱;
