-- 【待執行】products 加 is_system，標示「後端寫死引用、後台不可改動」的商品
-- ============================================================
-- 為什麼需要這個欄位
--   calc_session_fee_tx 是**用 SKU 字串**查檯費商品的
--   （sql/applied/07_開桌核心RPC.sql:182）：
--
--     v_sku := case when v_s.planned_minutes <= 120 then 'SVC-TBL-P02'
--                   when v_s.planned_minutes <= 300 then 'SVC-TBL-P05'
--                   else 'SVC-TBL-P24' end;
--
--   而 migi-admin 的商品編輯抽屜，貨號是一個自由輸入框
--   （Products.jsx:147）。店長把 SVC-TBL-P05 改掉一個字，
--   包桌 5 小時當場開不了，錯誤是 product_not_found ——
--   而且訊息不會告訴任何人原因出在後台。
--   停用（is_active=false）或刪除同樣會讓它查不到。
--
--   後台要擋住這件事，就得知道「哪些商品是系統在用的」。
--   把那七個貨號寫死在前端 JS 裡也做得到，但那正是 SER-/SVC- 前綴
--   對不上的成因（見 docs/01-資料庫/資料模型設計說明.md 三之二節）——
--   前端寫死的常數，資料庫改了不會知道，而且不報錯。
--   → 標記存在資料庫，前端只讀。
--
-- 為什麼不是「唯讀」而是「系統商品」
--   這個旗標的語意是「後端有程式碼依賴它的存在與貨號」，
--   不是「不可編輯」。價格與品名仍然要能改（調價是日常營運）。
--   後台要擋的是：改貨號、刪除、停用 —— 三件會讓後端查不到的事。
--
-- 安全性
--   純加欄位 + 依貨號回填，不動函式、不動既有欄位。
-- ============================================================

alter table public.products
  add column if not exists is_system boolean not null default false;

comment on column public.products.is_system is
  '系統商品：後端以固定貨號查詢它（calc_session_fee_tx 等），後台不得改貨號、刪除或停用，否則相關流程會回 product_not_found。價格與品名仍可編輯。';

-- 回填：七個檯費商品的貨號寫死在 calc_session_fee_tx 與 POS 前端裡。
-- 用 sku 比對而非 revenue_type —— 未來若新增其他 venue_fee 商品
-- （例如可加購的場地服務），那些不是系統寫死的，不該被鎖。
update public.products
   set is_system = true
 where deleted_at is null
   and sku in (
     'SVC-TBL-DAY',   -- 當日暢打（POS OpenCheckoutPage 三處寫死此貨號）
     'SVC-TBL-M2',    -- 配桌 2 將
     'SVC-TBL-M3',    -- 配桌 3 將
     'SVC-TBL-MID',   -- 配桌中途加入／代打
     'SVC-TBL-P02',   -- 包桌 ≤120 分
     'SVC-TBL-P05',   -- 包桌 ≤300 分
     'SVC-TBL-P24'    -- 包桌 ≤1440 分
   );

-- ============================================================
-- ② product_taxonomy 加 default_revenue_type
--    後台表單選了分類之後要預帶收入桶。這個對應若寫在前端 JS，
--    就是 SER-/SVC- 那個 bug 的同一種形狀 —— 前端寫死、資料庫改了不會知道。
--    只是「預設值」不是真理：使用者仍會在表單上看到並可改
--    （教室課程就是 category=service 但收入桶不是 venue_fee 的案例）。
-- ============================================================

alter table public.product_taxonomy
  add column if not exists default_revenue_type text;

comment on column public.product_taxonomy.default_revenue_type is
  '僅 category 維度使用：後台新增商品選此分類時預帶的收入桶。只是預設值，使用者可改（例如教室課程 category=service 但收入桶是 lesson）。';

update public.product_taxonomy
   set default_revenue_type = case code
                                when 'service' then 'venue_fee'
                                when 'fnb'     then 'fnb'
                                when 'merch'   then 'retail'
                              end
 where dimension = 'category';

-- 讓 RPC 一併回傳（簽名未變，不需 DROP）
create or replace function public.list_product_taxonomy_tx()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(jsonb_object_agg(d.dimension, d.rows), '{}'::jsonb)
  from (
    select t.dimension,
           jsonb_agg(
             jsonb_build_object(
               'code',           t.code,
               'label',          t.label,
               'parent',         t.parent_code,
               'prefix',         t.sku_prefix,
               'defaultRevenue', t.default_revenue_type
             ) order by t.sort, t.code
           ) as rows
      from public.product_taxonomy t
     where t.is_active
     group by t.dimension
  ) d;
$$;

grant execute on function public.list_product_taxonomy_tx() to anon, authenticated;

-- ============================================================
-- 驗證（單一 SELECT）
--   系統商品數應為 7；被停用的系統商品數應為 0
--   （被停用的系統商品 = 該收費路徑已經壞了）；
--   分類預設收入桶數應為 3。
-- ============================================================
select
  p.sku                                                        as 貨號,
  p.name                                                       as 品名,
  p.revenue_type                                               as 收入桶,
  p.is_system                                                  as 系統商品,
  p.is_active                                                  as 上架中,
  (select count(*) from public.products
    where deleted_at is null and is_system)                    as 系統商品數,
  (select count(*) from public.products
    where deleted_at is null and is_system and not is_active)  as 被停用的系統商品數,
  (select count(*) from public.product_taxonomy
    where dimension = 'category' and default_revenue_type is not null) as 分類預設收入桶數
from public.products p
where p.deleted_at is null
order by p.is_system desc, p.sku;
