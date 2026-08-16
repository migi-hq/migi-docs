-- 【待執行】products 補三個欄位：revenue_type / subcategory / tracks_stock
-- ============================================================
-- 背景
--   目前 products 只有 category（service / fnb / merch）一個分類欄位，
--   而系統實際需要三個互相獨立的答案：
--
--     ① 這個商品放哪一頁？        → category      （陳列與管理）
--     ② 這筆錢算哪個收入桶？      → revenue_type  （財務、折扣、報表）★新增
--     ③ 要不要盤點？              → tracks_stock  （庫存）          ★新增
--
--   現在 ② 是從 category 即時推導的（list_products_tx 裡的
--   case category when 'fnb' then 'fnb' when 'merch' then 'goods' else 'fee' end），
--   ③ 是前端推導的（Products.jsx:61 category==='service' ? '—' : stock_qty）。
--   兩者都會在「同一個 category 但答案不同」時當場出錯：
--
--     教室課程   category=service 但不該吃檯費折扣    → ② 錯
--     器材租借   category=service 但有實體要盤點      → ③ 錯
--     預購商品   category=merch   但還沒到貨不該盤點  → ③ 錯
--
--   另外補 subcategory：三段式貨號的第二段（TBL / MEAL / DRK / GOOD）
--   目前只存在 SKU 字串裡。《商品與貨號規範》說子類的價值是
--   「餐飲底下飲料與餐點的毛利結構完全不同，必須分得開」——
--   但要做那份報表就得 parse SKU，有人手打歪一個字那筆就從報表消失且不報錯。
--   而且後台 nextSku() 要產三段式貨號，本來就需要知道子類。
--
-- 收入桶四個值（venue_fee / fnb / retail / other）
--   venue_fee  場地      本業。POS 與 App 顯示「檯費」，識別碼用 venue_fee
--                        是因為賣的是場地與服務，桌只是計價單位；
--                        而且此 schema 裡 table_* 已經滿場（tables / table_sessions /
--                        table_id），再多一個 table_fee 讀起來會頓。
--   fnb        餐飲
--   retail     商品      原本叫 goods，太含糊；retail 是場館業通用語
--                        （旅館業 USALI：Rooms / F&B / Retail / Other）
--   other      其他      派車、雜項的暫置區。
--                        ⚠ other 是候車室不是家：任何項目一有量就給它自己的桶。
--                        M8 教室上線時直接開 lesson，不要先放 other 再搬——
--                        搬家會在報表留下永久接縫（order_items 是快照，不回頭改）。
--   ⚠ 派車若是代收代付給司機，那在會計上根本不是收入而是代收款
--     （跟儲值同一類），做派車功能前先問會計師，不要直接開 ride 桶。
--
-- 為什麼 revenue_type / subcategory 這次**不設 NOT NULL**
--   後台 migi-admin 的 saveProduct() 是直接 insert products，
--   它現在不會送這兩個欄位。若立刻加 NOT NULL，後台新增商品會當場失敗。
--   → 本檔先讓它們可為 null，等後台表單改好之後再跑一支小 SQL 補上 NOT NULL。
--   驗證段會列出 null 筆數，補約束前先確認是 0。
--
-- 安全性
--   純 ALTER TABLE + UPDATE，不動任何函式、不動 SKU、不動既有欄位。
--   order_items 存的是成交當下的快照（name / kind），本檔完全不碰，
--   歷史訂單不受影響。
-- ============================================================

-- ① 收入桶（財務分類）
alter table public.products
  add column if not exists revenue_type text;

comment on column public.products.revenue_type is
  '收入桶（財務分類）：venue_fee=場地/檯費 | fnb=餐飲 | retail=商品 | other=其他。決定折扣範圍與營收報表分類，與 category（陳列分類）刻意分開。';

-- 舊值若已存在先清掉約束再重建，避免重跑時衝突
alter table public.products
  drop constraint if exists products_revenue_type_check;

alter table public.products
  add constraint products_revenue_type_check
  check (revenue_type is null or revenue_type in ('venue_fee', 'fnb', 'retail', 'other'));

-- ② 子類（三段式貨號第二段）
alter table public.products
  add column if not exists subcategory text;

comment on column public.products.subcategory is
  '三段式貨號第二段（TBL / MEAL / DRK / GOOD…），毛利分析維度。原本只存在 sku 字串裡，靠字串解析做報表會在手誤時無聲漏資料。';

-- ③ 是否盤點庫存
alter table public.products
  add column if not exists tracks_stock boolean not null default true;

comment on column public.products.tracks_stock is
  '是否納入庫存盤點。原本由 category=service 推導，但器材租借（service 卻有實體）與預購商品（merch 卻還沒到貨）都會推導錯。';

-- ④ 回填 —— 依現有 category 與 sku 推，只填 null 的（重跑安全）
update public.products
   set revenue_type = case category
                        when 'service' then 'venue_fee'
                        when 'fnb'     then 'fnb'
                        when 'merch'   then 'retail'
                        else 'other'
                      end
 where revenue_type is null
   and deleted_at is null;

-- 子類取貨號第二段。三段式貨號才有第二段；
-- 非三段式的（舊格式或手打歪的）會得到空字串，這裡轉成 null 讓驗證段抓出來。
update public.products
   set subcategory = nullif(split_part(sku, '-', 2), '')
 where subcategory is null
   and deleted_at is null;

-- 服務類不盤點（現有七筆檯費商品 stock_qty 都是 0）。
-- 未來若出現「器材租借」這種 service 卻要盤點的，在後台個別改成 true。
update public.products
   set tracks_stock = false
 where category = 'service'
   and deleted_at is null;

-- ============================================================
-- 驗證（單一 SELECT）
--   逐列看回填結果，並在每列右側帶上三個總計：
--   未分收入桶 / 未分子類 應為 0；約束數應為 1。
-- ============================================================
select
  p.sku                                        as 貨號,
  p.name                                       as 品名,
  p.category                                   as 陳列分類,
  p.subcategory                                as 子類,
  p.revenue_type                               as 收入桶,
  p.tracks_stock                               as 盤點庫存,
  (select count(*) from public.products
    where deleted_at is null and revenue_type is null)      as 未分收入桶,
  (select count(*) from public.products
    where deleted_at is null and subcategory  is null)      as 未分子類,
  (select count(*) from pg_constraint
    where conname = 'products_revenue_type_check')          as 約束數
from public.products p
where p.deleted_at is null
order by p.category, p.sku;
