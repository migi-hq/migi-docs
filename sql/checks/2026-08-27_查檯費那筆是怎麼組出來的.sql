/* ============================================================
   查：檯費那筆品項的 unit_price 與 qty 是怎麼組出來的
   2026-08-27 · 唯讀

   ── 為什麼非查不可 ──────────────────────────────────
   待辦 2 要把 `checkout_tx` 改成「單價一律回查 `products` 主檔」。
   商品（fnb / retail / other）沒問題 —— 它們的價格本來就是主檔價。

   🔴 **檯費是唯一的例外風險**：暢打的客人檯費是 0，
     而檯費商品的主檔價是實價（SVC-TBL-M2 $100、P24 $200、DAY $300）。
     那個 0 怎麼表達，決定「一律查主檔」安不安全：

       qty = 0（那個人不算進份數）  → ✅ 單價本來就是主檔價，改了沒差
       unit_price = 0（單價改成 0） → 🔴 一律查主檔 = **暢打的客人被收全額**

   ⚠ CLAUDE.md 寫「份數逐人判斷、v_qty 從 0 起算」看起來是前者，
     但那是**文件不是線上定義**（硬規則 3）。
     猜錯的代價是收錯錢，而且結帳會成功、不報錯 —— 只有客人覺得金額怪。

   ── 順帶要確認的 ────────────────────────────────────
   · 等級折扣是不是真的沒有被寫進品項單價（它應該走 tier_discount）
   · 代付的份數怎麼算
   · 三支「純轉手」的包裝層有沒有自己動過 p_items
   ============================================================ */

select 序, 項目, 內容 from (

  /* ① 檯費試算 —— 它回什麼形狀，決定包裝層拿什麼去組品項。 */
  select 1 as 序, '① calc_session_fee_tx 全文' as 項目,
         coalesce((select pg_get_functiondef(p.oid)
                     from pg_proc p
                    where p.pronamespace = 'public'::regnamespace
                      and p.prokind = 'f' and p.proname = 'calc_session_fee_tx'
                    limit 1), '🔴 不存在') as 內容

  union all
  /* ② join_session_tx 全文 —— 它是**唯一**會自己組檯費品項的那支。
        ⚠ 撈全文不是片段：CLAUDE.md 記過我在這一支上因為只看片段
          連續判斷錯兩次，而且它同時有暢打、代付、擋牆三種邏輯。 */
  select 2, '② join_session_tx 全文',
         coalesce((select pg_get_functiondef(p.oid)
                     from pg_proc p
                    where p.pronamespace = 'public'::regnamespace
                      and p.prokind = 'f' and p.proname = 'join_session_tx'
                    limit 1), '🔴 不存在')

  union all
  /* ③ 另外三支包裝層有沒有動 p_items —— 只印出提到 items 的行，
        不要整支（那三支不是這次的重點，只要確認它們是純轉手）。
        ⚠ 硬規則 3.5：這裡是**逐行印出讓人判讀**，不是回傳是非題。 */
  select 3, '③ 另外三支怎麼處理 p_items',
         coalesce((
           select string_agg(nm || ' │ ' || trim(ln), E'\n')
             from (
               select p.proname as nm, ln
                 from pg_proc p,
                      lateral regexp_split_to_table(pg_get_functiondef(p.oid), E'\n') as ln
                where p.pronamespace = 'public'::regnamespace
                  and p.prokind = 'f'
                  and p.proname in ('pos_addon_checkout_tx','pos_quick_checkout_tx',
                                    'pos_checkout_with_topup_tx')
                  and ln ilike '%items%'
             ) s
         ), '（三支都沒提到 items）')

  union all
  /* ④ 現有訂單裡，品項單價與主檔價對得上嗎。
        🔴 這是最直接的證據：如果所有 venue_fee 品項的 unit_price
          都等於主檔價，那「一律查主檔」就是安全的（暢打靠 qty 表達）。
          有對不上的，就把它印出來看是什麼情況。
        ⚠ 用原表不用 v_real_*：這裡要看的正是測試訂單。 */
  select 4, '④ 品項單價 vs 主檔價',
         coalesce((
           select string_agg(x.txt, E'\n')
             from (
               select oi.revenue_type || '　' || coalesce(oi.name,'(無名)') ||
                      '　訂單單價=' || oi.unit_price::text ||
                      '　主檔價=' || coalesce(pr.unit_price::text,'查不到') ||
                      '　qty=' || oi.qty::text ||
                      case when pr.unit_price is distinct from oi.unit_price
                           then '　🔴 不一致' else '　✅' end as txt
                 from order_items oi
                 left join products pr on pr.id = oi.product_id
                order by (pr.unit_price is distinct from oi.unit_price) desc,
                         oi.revenue_type, oi.name
                limit 30
             ) x
         ), '（沒有訂單品項）')

  union all
  /* ⑤ 一句話結論：有幾筆對不上。
        ⚠ 這個數字**不是**「有沒有 bug」——
          不一致可能是合法的（改過售價、或後端刻意算過）。
          它只是告訴你 ④ 要不要細看。 */
  select 5, '⑤ 對不上的筆數',
         (select count(*)::text || ' / ' ||
                 (select count(*)::text from order_items)
            from order_items oi
            left join products pr on pr.id = oi.product_id
           where pr.unit_price is distinct from oi.unit_price)

) x order by 序, 項目;
