-- 【待執行】revenue_type 階段 C-2：收掉 products.kind，並把兩個 revenue_type 收緊
-- ============================================================
-- 前置：A（雙軌）、B（POS 改用 revenue_type）、C-1（order_items.kind 已 drop）皆完成並驗證。
--
-- 【products.kind 無人讀，已逐一確認】
--   盤點列出「同時提到 products 與 kind」的四支函式，逐一看過：
--     list_products_tx        每次從 category 現算 kind，不讀欄位（已於 A 改為回 revenue_type）
--     list_daypass_tx         'kind','fee' 是 JSON 字面值，不是欄位（A 已加 revenue_type）
--     join_session_tx         同上，自己組品項時寫死的字面值
--     create_invoice_draft_tx **兩處 kind 都是 invoices.kind**
--                             （一處在 exists 檢查、一處在 insert 欄位列）。
--                             它會被盤點抓到，只是因為註解裡有「不需 join products」這句話。
--   → 四支都不讀 products.kind。它從建立以來沒有任何讀者。
--
-- 【為什麼順便收緊 NOT NULL】
--   kind 有 `not null default 'goods'`，revenue_type 卻可以是 null。
--   drop 掉 kind 之後 revenue_type 是**唯一**的分類欄位 ——
--   這時候留著 null 比原本更糟：那筆錢不屬於任何收入桶，
--   而報表不會報錯，只會少一塊（正是這整件事要消滅的失敗模式）。
--
--   兩邊都已經沒有 null，而且入口都擋住了：
--     products     migi-admin 的 save() 有 `if (!f.revenue_type) 請選收入桶`
--     order_items  POS 的 doPay 會擋下沒填桶的品項；
--                  checkout_tx 對舊 bundle 送來的 kind 仍做換算
--   `set not null` 本身就是最後一道檢查 —— 有 null 就會失敗，
--   所以這行同時是動作也是驗證。
--
-- 【本檔之後 kind 還會存在的地方（都與商品分類無關，不要動）】
--   coupons.kind / invoices.kind / legal_entities.kind / member_interactions.kind
--   以及 POS 的牌規（台麻／美麻）。
-- ============================================================

alter table public.products drop constraint if exists products_kind_chk;
alter table public.products drop column if exists kind;

alter table public.products      alter column revenue_type set not null;
alter table public.order_items   alter column revenue_type set not null;

comment on column public.products.revenue_type is
  '收入桶（venue_fee / fnb / retail / other）。2026-08-19 起是唯一的營收分類欄位，舊的 kind 已移除。';

-- ============================================================
-- 驗證（單一 SELECT）
--   前三欄 true。
--   第四欄應該只列出 create_invoice_draft_tx / get_wallet_tx / void_invoice_tx
--   —— 那三支的 kind 分別是 invoices.kind 與 coupons.kind，本來就不該動。
--   若出現第四個名字，就是還有商品分類的殘留。
--   第五欄是最終的收入桶分布。
-- ============================================================
with fns as (
  select p.proname, pg_get_functiondef(p.oid) as def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.prokind = 'f'
)
select
  (select count(*) = 0 from information_schema.columns
    where table_schema = 'public' and table_name = 'products'
      and column_name = 'kind')                                           as products已無kind,
  (select count(*) = 2 from information_schema.columns
    where table_schema = 'public' and column_name = 'revenue_type'
      and table_name in ('products', 'order_items')
      and is_nullable = 'NO')                                             as 兩欄都已收緊,
  (select count(*) = 0 from information_schema.columns
    where table_schema = 'public' and column_name = 'kind'
      and table_name in ('products', 'order_items'))                      as 商品端已無kind欄位,
  (select jsonb_agg(proname order by proname)
     from fns where def ~ '\ykind\y')                                     as 仍提到kind的函式,
  (select jsonb_object_agg(revenue_type, n)
     from (select revenue_type, count(*) as n from public.order_items
            group by revenue_type) t)                                     as 收入桶分布;
