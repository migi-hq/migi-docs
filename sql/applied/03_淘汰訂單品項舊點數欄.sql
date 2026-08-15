-- 【已執行】淘汰 order_items.unit_points 舊欄，unit_price 轉正為 not null。務必在 02 之後才執行。
-- ============================================================
-- order_items: 淘汰 unit_points 欄，unit_price 轉正為主欄
-- 起因：改元計價，不再需要 unit_points/unit_price 雙欄重複
-- Supabase SQL Editor 執行
-- ★不刪任何訂單資料，只調整欄位結構 + 補資料
-- ============================================================

-- ① 把現有 4 筆的 unit_price 補齊（若為 null，用 unit_points 的值填過去）
--    確保淘汰 unit_points 前，unit_price 都有值
UPDATE public.order_items
SET unit_price = unit_points
WHERE unit_price IS NULL;

-- ② line_total 若有 null 也補（qty × unit_price）
UPDATE public.order_items
SET line_total = qty * unit_price
WHERE line_total IS NULL;

-- ③ unit_price 補 NOT NULL（現在都有值了，可以加約束）
ALTER TABLE public.order_items
  ALTER COLUMN unit_price SET NOT NULL;

-- ④ 砍掉舊的 unit_points 欄
ALTER TABLE public.order_items
  DROP COLUMN unit_points;

-- ⑤ 確認結果（應該沒有 unit_points，unit_price 是 NOT NULL）
SELECT column_name, is_nullable
FROM information_schema.columns
WHERE table_schema='public' AND table_name='order_items'
  AND column_name LIKE 'unit_%' OR column_name = 'line_total';
