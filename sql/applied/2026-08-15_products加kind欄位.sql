-- ============================================================
-- products 加上 kind 欄位（財務分類），結帳時原樣複製到 order_items
-- 產生日期：2026-08-15
--
-- 【這不是修 bug，是移除潛在脆弱性】
--   現況其實是對的：list_products_tx 已經依 category 算好 kind 回傳
--     'kind', case category when 'fnb' then 'fnb' when 'merch' then 'goods' else 'fee' end
--   目前 9 筆商品都分類正確，沒有資料被記錯。
--
--   問題在那個 `else 'fee'` 是 catch-all：
--   日後只要出現非 fnb / merch 的商品（寄物、教學、任何新增的 category），
--   就會被算進**檯費營收**，而且不會報錯 —— 這種錯誤要看報表才會發現，
--   通常是好幾個月後。
--
-- 【處置】
--   把 kind 存在商品主檔上，結帳時原樣複製，不再由 category 推導。
--
--   order_items.kind ∈ fee / fnb / goods（財務分類，報表用）
--   products.category ∈ fnb / merch / service（商品管理分類，後台分頁用）
--   兩者目的不同，本來就不該互相推導 ——
--   一個 service 商品可能是檯費（暢打），也可能是寄物（該算 goods）。
--
--   category 與 kind 各司其職，不互相推導：
--     category = 商品管理分頁（給店員找東西）
--     kind     = 財務分類（給報表）
--   例如日後有「寄物」「教學」這類 service 商品，category 是 service，
--   但 kind 應該是 goods 而不是 fee —— 用映射就會全部算進檯費營收。
--
-- 【回填 vs 映射的差別】
--   下面的回填用的規則跟前端原本要寫死的映射一樣，但性質不同：
--   這是**一次性、可檢閱、只作用於現有 9 筆商品**的資料修正；
--   映射則是每次結帳都在猜。日後新增商品由後台明確選擇。
--
-- 【NOT NULL DEFAULT 'goods' 的取捨】
--   不給預設值的話，migi-admin 現行的 createProduct（沒帶 kind）會直接失敗。
--   給了預設值則有「建檯費商品忘了改」的風險 ——
--   後台補上下拉選單之前，新增檯費類商品要記得手動改。
-- ============================================================


-- ---------- ① 欄位 ----------
alter table products
  add column if not exists kind text;

-- ---------- ② 回填現有商品 ----------
update products set kind = 'fee'   where kind is null and category = 'service';
update products set kind = 'fnb'   where kind is null and category = 'fnb';
update products set kind = 'goods' where kind is null and category = 'merch';
update products set kind = 'goods' where kind is null;   -- 保險：category 有意外值時不留 null

-- ---------- ③ 約束 ----------
alter table products
  alter column kind set default 'goods',
  alter column kind set not null;

alter table products drop constraint if exists products_kind_chk;
alter table products
  add constraint products_kind_chk check (kind in ('fee', 'fnb', 'goods'));

comment on column products.kind is
  '財務分類，結帳時原樣複製到 order_items.kind。fee=檯費類／fnb=餐飲／goods=零售。與 category（商品管理分頁）各司其職，不互相推導。';


-- ---------- ④ 驗證（單一 SELECT）----------
select p.sku as 貨號, p.name as 品名,
       p.category as 管理分類, p.kind as 財務分類
from products p
where p.deleted_at is null
order by p.kind, p.sku;

-- 跑完請確認每一筆的財務分類都對，特別是：
--   SVC-TBL-*  應為 fee
--   FNB-*      應為 fnb
-- 有錯的話直接 update products set kind='x' where sku='...';
