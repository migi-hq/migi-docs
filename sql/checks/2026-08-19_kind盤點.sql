-- 【唯讀盤點】kind → revenue_type 替換前的線上現況
-- ============================================================
-- 這不是 migration，只查不改。
--
-- 為什麼一定要先跑這支：
--   CLAUDE.md 記的是「前端 84 處、SQL 15 支」，但那個數字把所有叫 kind 的
--   識別字都算進去了。實際掃過本機三個 repo：
--     migi-pos   40 處 → 其中約 13 處是**牌規**（台麻／美麻），與商品分類無關
--     migi-web   42 處 → **一處都不是商品分類**
--                        （rewards 的收藏類型、match 的房型、
--                         data/stats 的牌局類型、main/ErrorBoundary 的錯誤類型、
--                         helpers/wallet 的 coupons.kind）
--     migi-admin  0 處
--   → 真正要改的前端只有 migi-pos 約 27 處。
--
--   同一個字在不同語意底下出現，正是「盲目全域取代」會炸掉的地方 ——
--   把 match.jsx 的 kind="live" 改成 revenue_type="live" 不會報錯，
--   只會讓配桌房型靜靜失效。
--
--   下面查的是資料庫這一半，同樣不能靠檔案或文件推測（硬規則 3）。
-- ============================================================

with kind_cols as (
  select table_name, column_name, data_type, is_nullable, column_default
    from information_schema.columns
   where table_schema = 'public'
     and column_name in ('kind', 'revenue_type')
),
fns as (
  select p.proname, pg_get_functiondef(p.oid) as def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.prokind = 'f'
)
select
  -- ① 哪些表有 kind／revenue_type（含型別與預設值）
  (select jsonb_agg(to_jsonb(k) order by k.table_name, k.column_name)
     from kind_cols k)                                                    as 欄位分布,

  -- ② 相關的 CHECK 約束（允許值寫在這裡，不是寫在文件裡）
  (select jsonb_agg(jsonb_build_object(
            'table', cl.relname, 'name', c.conname,
            'def', pg_get_constraintdef(c.oid)) order by cl.relname, c.conname)
     from pg_constraint c
     join pg_class cl on cl.oid = c.conrelid
     join pg_namespace n on n.oid = cl.relnamespace
    where n.nspname = 'public' and c.contype = 'c'
      and (pg_get_constraintdef(c.oid) ilike '%kind%'
           or pg_get_constraintdef(c.oid) ilike '%revenue_type%'))        as 相關約束,

  -- ③ 提到 kind 的函式（要逐支改的清單，數量以這裡為準）
  (select jsonb_agg(proname order by proname)
     from fns where def ~ '\ykind\y')                                     as 提到kind的函式,

  -- ④ 提到 revenue_type 的函式（已經改過的有哪些）
  (select jsonb_agg(proname order by proname)
     from fns where def like '%revenue_type%')                            as 提到revenue_type的函式,

  -- ⑤ products.kind 真的沒人讀嗎（CLAUDE.md 說它是孤兒欄位，要驗證）
  (select jsonb_agg(proname order by proname)
     from fns where def ~ '\yproducts\y' and def ~ '\ykind\y')            as 可能讀products的函式,

  -- ⑥ order_items.kind 現有的值分布（改值時的對照基準）
  (select jsonb_object_agg(coalesce(kind, '(null)'), n)
     from (select kind, count(*) as n from public.order_items
            group by kind) t)                                             as order_items值分布,

  -- ⑦ products 三個分類欄位的實際組合（推導會不會壞就看這裡）
  (select jsonb_agg(to_jsonb(t) order by t.category, t.kind, t.revenue_type)
     from (select category, kind, revenue_type, count(*) as n
             from public.products where deleted_at is null
            group by category, kind, revenue_type) t)                     as products分類組合;
