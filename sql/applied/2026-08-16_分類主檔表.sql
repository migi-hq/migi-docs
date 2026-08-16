-- 【待執行】建立分類主檔 product_taxonomy，收掉三端各自寫死的分類詞彙
-- ============================================================
-- 為什麼要這張表
--   同一組分類，目前有三份互不相通的定義：
--
--     資料庫          category = service / fnb / merch，SKU 前綴 SVC- / FNB- / MCH-
--     migi-admin JS   CATEGORIES = [{service,'檯費','SER-'}, {fnb,'餐飲','FNB-'}, {merch,'商品','MER-'}]
--     migi-pos JS     p.category === 'fnb' ? '餐飲' : p.category === 'merch' ? '周邊' : '服務'
--
--   後果已經發生：後台前綴寫 SER- / MER-，資料庫實際是 SVC- / MCH-，
--   在後台新增服務類商品會產出 SER-025 這種跟現有七筆完全不同體系的貨號。
--   顯示名也三套（服務／檯費、周邊／商品），店員在後台與 POS 看到不同的字。
--
--   根因不是「有人打錯」，是**顯示用的常數寫在前端**——
--   資料庫改了前端不會知道，而且不會報錯，只會慢慢歪。
--   → 唯一來源放資料庫，三端都讀它。
--
-- 為什麼三個維度合成一張表
--   category / subcategory / revenue_type 三者總共只有 11 列純顯示中介資料。
--   拆三張表就要三支 RPC、三份前端載入邏輯，維護面積比收益大。
--   用 dimension 欄位區分，一支 RPC 一次回全部。
--
-- 為什麼沒有 org_id
--   revenue_type 的值寫死在 checkout_tx 的折扣分桶邏輯裡，
--   讓某個門市自己新增一個桶會讓金流函式**無聲算錯**。
--   category 也受 products_category_check 約束，同樣不是各店可自訂的。
--   → 本表是系統層參考資料，全租戶共用。
--     若日後真的需要各店自訂子類，再加 org_id 並只對 subcategory 開放。
--
-- 為什麼不開放寫入政策
--   《商品與貨號規範》§1.2 明訂「新增子類必須先寫進本表，不得臨時自創，
--   子類是報表維度，散掉就失去意義」。
--   不給 INSERT/UPDATE policy = 只能從 SQL Editor 維護，
--   這個「不方便」正是規範要的守門，不是缺陷。
--
-- 顯示名的取捨（三套擇一，並解釋為何這樣選）
--   category   服務 / 餐飲 / 周邊
--              service 用「服務」不用「檯費」——它未來會裝教室課程、器材租借，
--              那些都不是檯費。後台 JS 現在寫「檯費」是把上位概念用下位詞命名。
--   revenue_type 檯費 / 餐飲 / 周邊 / 其他
--              這裡才用「檯費」，因為 venue_fee 桶就是檯費，範圍精確。
--              （識別碼用 venue_fee 是因為賣的是場地，桌只是計價單位；
--                且此 schema 裡 table_* 已滿場，再多一個 table_fee 讀起來會頓。）
--   merch 與 retail 都顯示「周邊」——兩者今天 1:1，標籤不同只是噪音。
-- ============================================================

create table if not exists public.product_taxonomy (
  dimension   text        not null,
  code        text        not null,
  label       text        not null,
  parent_code text,
  sku_prefix  text,
  sort        int         not null default 0,
  is_active   boolean     not null default true,
  note        text,
  created_at  timestamptz not null default now(),
  primary key (dimension, code),
  constraint product_taxonomy_dimension_check
    check (dimension in ('category', 'subcategory', 'revenue_type'))
);

comment on table public.product_taxonomy is
  '商品分類主檔（系統層，全租戶共用）。三端的分類顯示名與 SKU 前綴唯一來源，前端不得再寫死。';
comment on column public.product_taxonomy.dimension is
  'category=陳列分類 | subcategory=子類（貨號第二段、毛利維度）| revenue_type=收入桶（財務分類）';
comment on column public.product_taxonomy.parent_code is
  '僅 subcategory 使用，指向所屬 category 的 code';
comment on column public.product_taxonomy.sku_prefix is
  '三段式貨號用：category 提供第一段、subcategory 提供第二段。第三段是人取的語意縮寫，不自動產生。';

alter table public.product_taxonomy enable row level security;

-- 純參考資料，全部可讀。無寫入政策 → 只能由 SQL Editor / service role 維護。
drop policy if exists product_taxonomy_read on public.product_taxonomy;
create policy product_taxonomy_read on public.product_taxonomy
  for select using (true);

-- ① 陳列分類（對應 products.category，受 products_category_check 約束）
insert into public.product_taxonomy (dimension, code, label, sku_prefix, sort, note) values
  ('category', 'service', '服務', 'SVC', 10, '檯費、教室課程、器材租借等無實體交付的品項'),
  ('category', 'fnb',     '餐飲', 'FNB', 20, '飲料、餐點'),
  ('category', 'merch',   '周邊', 'MCH', 30, '零售商品')
on conflict (dimension, code) do nothing;

-- ② 子類（貨號第二段）。新增子類請直接在此表加列，不要在程式碼裡自創。
insert into public.product_taxonomy (dimension, code, label, parent_code, sku_prefix, sort, note) values
  ('subcategory', 'TBL',  '檯費',     'service', 'TBL',  10, '開桌場地服務費，含配桌、包桌、當日暢打'),
  ('subcategory', 'MEAL', '餐點',     'fnb',     'MEAL', 20, null),
  ('subcategory', 'DRK',  '飲料',     'fnb',     'DRK',  30, '與餐點毛利結構不同，必須分得開'),
  ('subcategory', 'GOOD', '一般周邊', 'merch',   'GOOD', 40, null)
on conflict (dimension, code) do nothing;

-- ③ 收入桶（財務分類）。值寫死在 checkout_tx 分桶邏輯裡，加值前要先改那支函式。
insert into public.product_taxonomy (dimension, code, label, sort, note) values
  ('revenue_type', 'venue_fee', '檯費', 10, '本業。場地與服務，桌是計價單位'),
  ('revenue_type', 'fnb',       '餐飲', 20, null),
  ('revenue_type', 'retail',    '周邊', 30, null),
  ('revenue_type', 'other',     '其他', 90, 'other 是候車室不是家：任何項目一有量就給它自己的桶。M8 教室上線時直接開 lesson，不要先放 other 再搬——搬家會在報表留下永久接縫。')
on conflict (dimension, code) do nothing;

-- ============================================================
-- 讀取 RPC
--   POS 用 anon key 沒有 auth session，一律走 SECURITY DEFINER 的 RPC（硬規則 4）。
--   一次回三個維度，前端載入一次就夠。
-- ============================================================
drop function if exists public.list_product_taxonomy_tx();

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
               'code',   t.code,
               'label',  t.label,
               'parent', t.parent_code,
               'prefix', t.sku_prefix
             ) order by t.sort, t.code
           ) as rows
      from public.product_taxonomy t
     where t.is_active
     group by t.dimension
  ) d;
$$;

comment on function public.list_product_taxonomy_tx() is
  '回傳商品分類主檔，格式 {category:[...], subcategory:[...], revenue_type:[...]}。三端的分類顯示名與貨號前綴唯一來源。';

grant execute on function public.list_product_taxonomy_tx() to anon, authenticated;

-- ============================================================
-- 驗證（單一 SELECT）
--   逐列看主檔內容，右側帶三個總計：
--   維度數應為 3、列數應為 11、RPC 維度數應為 3。
-- ============================================================
select
  t.dimension                                        as 維度,
  t.code                                             as 代碼,
  t.label                                            as 顯示名,
  t.parent_code                                      as 所屬分類,
  t.sku_prefix                                       as 貨號段,
  t.sort                                             as 排序,
  (select count(distinct dimension) from public.product_taxonomy) as 維度數,
  (select count(*)                  from public.product_taxonomy) as 列數,
  (select count(*)
     from jsonb_object_keys(public.list_product_taxonomy_tx()))   as RPC回傳維度數
from public.product_taxonomy t
order by t.dimension, t.sort, t.code;
