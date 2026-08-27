/* ============================================================
   查：結帳時的價格到底從哪來
   2026-08-27 · 唯讀

   ── 目的（待辦 2）────────────────────────────────────
   要把「價格由前端 JSON 決定」改成「後端查主檔」。
   ⚠ 硬規則 3：`sql/applied/` 與文件都是二手傳聞，只有 `pg_proc` 算數。
     而且我要**改寫** `checkout_tx`，所以要撈**全文**不是片段
     —— CLAUDE.md 記過：同一支要改三處以上就撈全文重建，
     我在 `join_session_tx` 上就因為只看片段連續判斷錯兩次。

   ── 🔴 動手前必須先解決的矛盾 ──────────────────────
   「一律查 `products.unit_price`」聽起來對，但**檯費會被做壞**：
   檯費那筆的金額是 `calc_session_fee_tx` **逐人算出來的**
   （暢打的人 0 元、會員等級折扣、代付份數），不是主檔定價。
   一律查主檔 → **暢打的客人會被收全額**。

   → 所以真正要回答的不是「信不信 JSON」，而是
     **「誰有資格決定價格」**：
       · 商品（fnb / retail / other）→ 主檔說了算
       · 檯費（venue_fee）           → 後端的試算說了算
     而前端**兩種都不算數**。

   ── 這支查詢要確認四件事 ────────────────────────────
   ① `checkout_tx` 現在怎麼取單價、怎麼寫進 `order_items`
   ② 誰會呼叫 `checkout_tx`（＝信任邊界在哪一層）
   ③ `products` 有哪些欄位可以當「真相」
   ④ `order_items` 存了哪些快照欄位（改動不能弄丟它們）
   ============================================================ */

select 序, 項目, 內容 from (

  /* ① 全文。這是要被改寫的那支。 */
  select 1 as 序, '① checkout_tx 全文' as 項目,
         coalesce((select pg_get_functiondef(p.oid)
                     from pg_proc p
                    where p.pronamespace = 'public'::regnamespace
                      and p.prokind = 'f' and p.proname = 'checkout_tx'
                    limit 1), '🔴 不存在') as 內容

  union all
  /* ② 誰呼叫它 —— 這決定信任邊界在哪。
        CLAUDE.md 記過「前端永遠不可以直接呼叫 checkout_tx」
        （它是 INVOKER，POS 用 anon 會被 RLS 濾成什麼都沒發生而且不報錯）。
        ⚠ 如果真是這樣，那**不可信的輸入是前端送給包裝層的東西**，
          修補點可能在包裝層而不是 checkout_tx 本身。先看清楚再決定。
        ⚠ 硬規則 3.7：一定要 prokind='f'，否則聚合函式會讓整句拋 42809。
        ⚠ 硬規則 3.5：用**函式名**當關鍵字（會產生行為的東西），
          不要用欄位名 —— 欄位名會出現在註解裡。 */
  select 2, '② 呼叫 checkout_tx 的函式',
         coalesce(string_agg(p.proname || '　' ||
                  case p.prosecdef when true then 'DEFINER' else 'INVOKER' end ||
                  '　anon=' || case when has_function_privilege('anon', p.oid, 'EXECUTE')
                                    then '✅' else '無' end,
                  E'\n' order by p.proname), '（沒有函式呼叫它）')
    from pg_proc p
   where p.pronamespace = 'public'::regnamespace
     and p.prokind = 'f'
     and p.proname <> 'checkout_tx'
     and pg_get_functiondef(p.oid) ilike '%checkout_tx(%'

  union all
  /* ③ products 有哪些欄位可以當「真相」。 */
  select 3, '③ products 欄位',
         string_agg(column_name || ' ' || data_type ||
                    case is_nullable when 'NO' then ' NOT NULL' else '' end,
                    '　' order by ordinal_position)
    from information_schema.columns
   where table_schema = 'public' and table_name = 'products'

  union all
  /* ④ order_items 的快照欄位 —— 改動不能弄丟任何一個。
        訂單品項是**快照不回頭改**，所以現在存什麼，之後就要繼續存什麼。 */
  select 4, '④ order_items 欄位',
         string_agg(column_name || ' ' || data_type ||
                    case is_nullable when 'NO' then ' NOT NULL' else '' end,
                    '　' order by ordinal_position)
    from information_schema.columns
   where table_schema = 'public' and table_name = 'order_items'

  union all
  /* ⑤ 檯費那筆虛擬品項有沒有真實 SKU 可查。
        CLAUDE.md 說「檯費有真實 SKU（SVC-TBL-*），calc_session_fee_tx 已回 product_id」
        —— ⚠ 那是文件講的，這裡實際看一次。
        同時看它們的 discountable，因為暢打刻意不參與折扣。 */
  select 5, '⑤ 檯費類商品',
         coalesce(string_agg(sku || '　' || name || '　$' || unit_price::text ||
                             '　' || revenue_type ||
                             case when discountable then '' else '　⚠ 不參與折扣' end,
                             E'\n' order by sku), '🔴 找不到任何 SVC-TBL-% 商品')
    from products
   where sku like 'SVC-TBL-%'

) x order by 序, 項目;
