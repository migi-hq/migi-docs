-- 【已執行】products.unit_points 更名為 unit_price（元計價改制）。要了解欄位演變史時讀它。
-- ============================================================
-- 只做更名，不含會報錯的查詢
-- Supabase SQL Editor 貼上，整段執行
-- ============================================================

-- ① 欄位更名 unit_points → unit_price
ALTER TABLE public.products
  RENAME COLUMN unit_points TO unit_price;

-- ② check 約束改名（products_unit_points_check → products_unit_price_check）
ALTER TABLE public.products
  DROP CONSTRAINT IF EXISTS products_unit_points_check;
ALTER TABLE public.products
  ADD CONSTRAINT products_unit_price_check CHECK (unit_price >= 0);

-- ③ 確認結果（應只看到 unit_price、unit_cost）
SELECT column_name FROM information_schema.columns
WHERE table_schema='public' AND table_name='products' AND column_name LIKE 'unit_%';
