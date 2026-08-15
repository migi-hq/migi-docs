-- 【已執行】商品貨號改三段式，並建立七個檯費商品（SVC-TBL-*）。
-- ============================================================
-- 商品貨號改三段式（類別-子類-品項）
-- 依《MIGI_商品與貨號規範_v2.0》§7
-- Supabase SQL Editor 整段貼上，執行一次
--
-- 安全性：order_items 不存 sku（只存 product_id），coupons.free_product_id 綁 id
--         → 改 SKU 不影響任何歷史訂單或券
-- ============================================================

-- ① 現有商品改名
UPDATE public.products SET sku = 'SVC-TBL-M2',  name = '配桌檯費 · 2 將'
 WHERE sku = 'FEE-100' AND org_id = '11111111-1111-1111-1111-111111111111';

UPDATE public.products SET sku = 'SVC-TBL-M3',  name = '配桌檯費 · 3 將'
 WHERE sku = 'FEE-150' AND org_id = '11111111-1111-1111-1111-111111111111';

UPDATE public.products SET sku = 'SVC-TBL-DAY', name = '當日暢打 · 不限將數'
 WHERE sku = 'FEE-300' AND org_id = '11111111-1111-1111-1111-111111111111';

UPDATE public.products SET sku = 'FNB-MEAL-DUMP'
 WHERE sku = 'FNB-DUMP' AND org_id = '11111111-1111-1111-1111-111111111111';

UPDATE public.products SET sku = 'FNB-MEAL-TOAST'
 WHERE sku = 'FNB-TOAST' AND org_id = '11111111-1111-1111-1111-111111111111';

-- ② 新建缺少的檯費商品（中途加入 + 包桌三階）
--    ON CONFLICT DO NOTHING：重跑不會重複建
INSERT INTO public.products (org_id, sku, name, category, unit_price, unit_cost, stock_qty, is_active, is_available)
VALUES
  ('11111111-1111-1111-1111-111111111111', 'SVC-TBL-MID', '配桌檯費 · 中途加入', 'service', 100, 0, 0, true, true),
  ('11111111-1111-1111-1111-111111111111', 'SVC-TBL-P02', '包桌檯費 · 2 小時',   'service', 400, 0, 0, true, true),
  ('11111111-1111-1111-1111-111111111111', 'SVC-TBL-P05', '包桌檯費 · 5 小時',   'service', 600, 0, 0, true, true),
  ('11111111-1111-1111-1111-111111111111', 'SVC-TBL-P24', '包桌檯費 · 24 小時',  'service', 800, 0, 0, true, true)
ON CONFLICT DO NOTHING;

-- ③ 驗證（單一結果表）
SELECT sku, name, category, unit_price, is_active
  FROM public.products
 WHERE deleted_at IS NULL
   AND org_id = '11111111-1111-1111-1111-111111111111'
 ORDER BY category, sku;
