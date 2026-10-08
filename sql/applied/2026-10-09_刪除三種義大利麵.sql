-- ════════════════════════════════════════════════════════════════════ㄆ
-- 2026-10-09 刪除三種義大利麵
-- ════════════════════════════════════════════════════════════════════
-- 使用者：「義大利麵三種都從系統刪除」
--
--   FNB-MEAL-PSTG  青醬燻雞義大利麵
--   FNB-MEAL-PSTR  紅醬香腸義大利麵
--   FNB-MEAL-PSTW  白醬培根義大利麵
--
-- 做法跟後台「刪除商品」（admin_delete_product_tx）一樣：寫 deleted_at（軟刪除），
--   POS 點餐、後台商品清單都不再出現。
-- 2026-10-09 查過：三個都沒賣過（order_items 0 筆）、沒有任何券綁著它們、不是系統商品。
-- 用貨號找、只動還沒刪的 ⇒ 重跑一次不會出錯。
-- ════════════════════════════════════════════════════════════════════

update products
   set deleted_at = now()
 where sku in ('FNB-MEAL-PSTG', 'FNB-MEAL-PSTR', 'FNB-MEAL-PSTW')
   and deleted_at is null
   and is_system = false;

-- ── 驗證（單一 SELECT，不 raise）──────────────────────────────────────
select concat_ws(E'\n',
  -- ① 三種都刪了
  (select case when count(*) filter (where deleted_at is not null) = 3
               then '✅ ① 三種義大利麵都已刪除'
               else '🔴 ① 只刪了 ' || count(*) filter (where deleted_at is not null) || ' 種' end
     from products where sku in ('FNB-MEAL-PSTG', 'FNB-MEAL-PSTR', 'FNB-MEAL-PSTW')),
  -- ② 負對照：其他主食沒被動到（主食原本 10 種 − 這 3 種 ＝ 7：牛肉麵、水餃、鍋燒意麵、椒麻乾麵、兩種拉麵、炸醬麵）
  (select case when count(*) = 7
               then '✅ ② 其他 7 種主食還在'
               else '🔴 ② 其他主食剩 ' || count(*) || ' 種（應該是 7 種）' end
     from products where sku like 'FNB-MEAL-%' and deleted_at is null)
) as "驗證";
