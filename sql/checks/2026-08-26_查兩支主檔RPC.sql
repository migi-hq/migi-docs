/* ============================================================
   查：兩支主檔 RPC 的實際簽名與回傳
   2026-08-26 · 唯讀

   ── 起因（待辦 0：建了主檔沒人讀）──────────────────
   🔴 POS 現在有兩處寫死，而主檔早就存在：
     · `shared.jsx:42` 的 `TIER_LABEL` —— **而且少了 `chef_special`**，
       所以主廚特調的會員在 POS 上會顯示 `chef_special` 四個字。
       （使用者今天才把主廚特調改成 8 折。）
     · `OpenCheckoutPage.jsx:769,808` 的
       `category === 'fnb' ? '餐飲' : 'merch' ? '周邊' : '服務'`

   ── 要確認的 ────────────────────────────────────────
   ① `list_product_taxonomy_tx` 的**實際回傳**
      migi-admin 的註解說是 `{category:[], subcategory:[], revenue_type:[]}`，
      每筆 `{code, label, parent, prefix, defaultRevenue}` ——
      但那是**註解**，不是事實。實際呼叫一次看。
   ② `list_member_tiers_tx` **到底存不存在**
      三個 repo 都沒有人呼叫它。CLAUDE.md 說有 ——
      但那份文件今天已經錯過三次（app_events 的 is_test 來源、
      事件名白名單、staff 的唯一約束）。**只有 pg_proc 算數。**
   ============================================================ */

select 序, 項目, 內容 from (

  /* ① 兩支的簽名（存不存在、要什麼參數、DEFINER 嗎、anon 叫得動嗎） */
  select 1 as 序, '① 主檔 RPC 簽名' as 項目,
         p.proname || '(' || pg_get_function_arguments(p.oid) || ')' ||
         '　' || (case when p.prosecdef then 'DEFINER' else '🔴 INVOKER' end) ||
         '　anon ' || (case when has_function_privilege('anon', p.oid, 'EXECUTE')
                            then '✅' else '🔴 不可' end) as 內容
    from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
     and (p.proname ilike '%taxonomy%' or p.proname ilike '%member_tier%'
       or p.proname ilike '%tiers%')

  union all
  /* ② 分類主檔實際回傳什麼（呼叫一次，不要看註解） */
  select 2, '② list_product_taxonomy_tx 實際回傳',
         coalesce((select list_product_taxonomy_tx()::text), '🔴 呼叫不到')

  union all
  /* ③ member_tiers 的完整內容 —— 就算沒有 RPC，也要知道要回傳什麼欄位 */
  select 3, '③ member_tiers 全部欄位',
         coalesce((select string_agg(column_name || ' ' || data_type, '　'
                                     order by ordinal_position)
                     from information_schema.columns
                    where table_schema = 'public' and table_name = 'member_tiers'),
                  '🔴 表不存在')

  union all
  /* ④ member_tiers 有沒有 RLS —— 決定要不要包 DEFINER 的 RPC。
        ⚠ POS 用 anon 沒有 auth session，有 RLS 的話直接查表會回空陣列
          **而且不報錯**（硬規則 4）。 */
  select 4, '④ member_tiers 的 RLS 與 policy',
         (select (case when c.relrowsecurity then '🔴 有 RLS' else '✅ 沒開 RLS' end)
                 || '　policy ' ||
                 (select count(*)::text from pg_policy pol where pol.polrelid = c.oid) || ' 條'
            from pg_class c
           where c.relnamespace = 'public'::regnamespace and c.relname = 'member_tiers')

  union all
  /* ⑤ 同理，product_taxonomy 的 RLS
        CLAUDE.md 說它「無 org_id、無寫入政策」，確認一下。 */
  select 5, '⑤ product_taxonomy 的 RLS 與 policy',
         coalesce((select (case when c.relrowsecurity then '🔴 有 RLS' else '✅ 沒開 RLS' end)
                          || '　policy ' ||
                          (select count(*)::text from pg_policy pol where pol.polrelid = c.oid) || ' 條'
                     from pg_class c
                    where c.relnamespace = 'public'::regnamespace
                      and c.relname = 'product_taxonomy'), '🔴 表不存在')

) x order by 序, 項目, 內容;
