-- 【待執行】kind → revenue_type 階段 A：後端雙軌（expand）
-- ============================================================
-- 這一階段的原則：**只增不改、只加不減**。
--   跑完之後舊版 POS 完全照常運作 —— 它送 kind、讀 kind，兩者都還在。
--   前端一行都不用改就能部署這支，出事也只要把函式換回去。
--
-- 三階段：
--   A（本檔）後端同時支援 kind 與 revenue_type
--   B         前端 27 處改讀／改送 revenue_type
--   C         drop products.kind、order_items.kind、以及本檔的相容邏輯
--
-- 為什麼不一次做完
--   改值失敗是**無聲的**：`if (i.kind === "fee")` 漏改一處只會變成 false，
--   不報錯，只會讓檯費不進桶、折扣算錯、報表少一塊。
--   分三段的目的是讓「前端漏改」與「後端算錯」在時間上分開，
--   出事時知道要看哪一邊。
--
-- 【2026-08-19 盤點結論，本檔依此而寫】
--   · kind 出現在六張表，其中四張與商品分類無關
--     （coupons／invoices／legal_entities／member_interactions）——
--     SQL 端做全域取代會直接改壞發票與券。本檔只碰 order_items 與 products。
--   · 提到 kind 的九支函式裡只有六支相關；
--     create_invoice_draft_tx／void_invoice_tx／get_wallet_tx 是別的 kind。
--   · order_items 現有值只有 fee 72／fnb 116，**一列 goods 都沒有**。
--   · products 只有 9 列，revenue_type 已全部填對
--     （service/fee/venue_fee ×7、fnb/fnb/fnb ×2）。
--   · list_products_tx **不讀 products.kind 也不讀 revenue_type**，
--     它每次從 category 現算 —— 兩個欄位都沒有讀者，孤兒身分確認。
--
-- 【線上定義來源】
--   list_products_tx：2026-08-19 以 pg_get_functiondef 撈出（硬規則 3）。
--   list_daypass_tx：本機 2026-08-17 交付版，此後只有 join_session_tx 被改過。
--   checkout_tx／join_session_tx：不貼整份，用 DO 區塊對線上定義做單點替換，
--     找不到錨點就 raise —— 寧可整支失敗，也不要用本機副本覆蓋線上版。
-- ============================================================

-- ① order_items 加 revenue_type
--    允許 null：舊資料與相容期都需要，階段 C 再收緊。
alter table public.order_items
  add column if not exists revenue_type text;

alter table public.order_items
  drop constraint if exists order_items_revenue_type_chk;

alter table public.order_items
  add constraint order_items_revenue_type_chk
  check (revenue_type is null
         or revenue_type in ('venue_fee', 'fnb', 'retail', 'other'));

comment on column public.order_items.revenue_type is
  '這一筆的收入桶（venue_fee / fnb / retail / other）。取代舊的 kind，值同時改名：fee→venue_fee、goods→retail。階段 C 之後 kind 會移除。';

-- ② 回填。fnb 對自己、fee → venue_fee。
--    現有資料沒有 goods，但仍寫進對照 —— 這段之後會被貼進報表，
--    少一個分支就是少一條路，日後有人抄走時會出錯。
update public.order_items
   set revenue_type = case kind
                        when 'fee'   then 'venue_fee'
                        when 'goods' then 'retail'
                        else kind
                      end
 where revenue_type is null
   and kind is not null;

-- ③ checkout_tx：寫入時兩欄都填
--    **前端送哪一個 key 都收**（revenue_type 優先，沒有就從 kind 換算）。
--    這樣階段 B 的前端部署順序就不重要了 —— 新舊 bundle 都能結帳。
--    Cloudflare 快取讓「使用者手上跑的是哪一版」無法保證，
--    所以相容不是保險，是必要條件。
do $$
declare v_old text; v_new text;
begin
  select pg_get_functiondef(p.oid) into v_old
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'checkout_tx' and p.prokind = 'f';
  if v_old is null then raise exception 'checkout_tx 不存在'; end if;

  v_new := replace(v_old,
    $src$product_id, name, kind, qty,$src$,
    $dst$product_id, name, kind, revenue_type, qty,$dst$);

  v_new := replace(v_new,
    $src$            it->>'name', it->>'kind',$src$,
    $dst$            it->>'name', it->>'kind',
            coalesce(it->>'revenue_type',
                     case it->>'kind' when 'fee'   then 'venue_fee'
                                      when 'goods' then 'retail'
                                      else it->>'kind' end),$dst$);

  if v_new = v_old then
    raise exception 'checkout_tx 找不到錨點 —— 先撈 pg_get_functiondef 確認';
  end if;

  execute v_new;
end $$;

-- ④ join_session_tx：自己組的檯費品項也帶上 revenue_type
--    它是唯一由後端憑空產生的品項（前端不准送 fee，會被擋）。
--    用 regexp 而不是字面比對 —— 那幾行的對齊空白是人手排的，
--    數錯一格就整支失敗。
do $$
declare v_old text; v_new text;
begin
  select pg_get_functiondef(p.oid) into v_old
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'join_session_tx' and p.prokind = 'f';
  if v_old is null then raise exception 'join_session_tx 不存在'; end if;

  -- 只會命中「組品項」那一處：要求 'kind' 後面緊跟逗號，
  -- 所以擋牆裡的 `it ->> 'kind' = 'fee'` 不會被改到。
  v_new := regexp_replace(v_old,
    $re$'kind',\s+'fee',$re$,
    $rp$'kind', 'fee', 'revenue_type', 'venue_fee',$rp$);

  if v_new = v_old then
    raise exception 'join_session_tx 找不到錨點 —— 先撈 pg_get_functiondef 確認';
  end if;

  execute v_new;
end $$;

-- ⑤ list_products_tx：回傳 revenue_type
--    kind 保留不動（階段 B 之前 POS 還在讀它）。
--    revenue_type **直接回欄位、不做 fallback** ——
--    用 category 兜底的話，沒填桶的商品會長得跟填好的一模一樣，
--    而那正是這次要消滅的推導。沒填就回 null，讓它在畫面上壞掉比較好。
create or replace function public.list_products_tx(p_org_id uuid)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'public'
as $function$
begin
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', id, 'sku', sku, 'name', name, 'category', category,
      'unit_price', unit_price,
      'revenue_type', revenue_type,
      'kind',
        case category when 'fnb' then 'fnb' when 'merch' then 'goods' else 'fee' end
    ) order by category, sku)
    from products
    where org_id = p_org_id and is_active and coalesce(is_available, true)
      and deleted_at is null
      and sku not like 'SVC-TBL-%'   -- 檯費不列入加購清單，避免店員手動點錯
  ), '[]'::jsonb);
end $function$;

-- ⑥ list_daypass_tx：同樣兩個都回
create or replace function public.list_daypass_tx(p_org_id uuid)
returns jsonb
language sql
stable
security definer
set search_path to public
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id',           p.id,
           'sku',          p.sku,
           'name',         p.name,
           'category',     p.category,
           'unit_price',   p.unit_price,
           'revenue_type', 'venue_fee',
           'kind',         'fee')), '[]'::jsonb)
    from public.products p
   where p.org_id = p_org_id
     and p.sku = 'SVC-TBL-DAY'
     and p.is_active
     and p.deleted_at is null;
$$;

comment on function public.list_daypass_tx(uuid) is
  '當日暢打商品（SVC-TBL-DAY）。list_products_tx 不回 service 類，POS 要在「檯費」分頁賣它得單獨撈。revenue_type 與 kind 並存至階段 C。';

grant execute on function public.list_daypass_tx(uuid) to anon, authenticated;

-- ============================================================
-- 驗證（單一 SELECT）
--   前五欄必須全部 true / 0。
--   最後兩欄是階段 C 的前置條件：
--     products 沒填桶的數量必須是 0，否則 drop kind 之後那些商品沒有分類；
--     order_items 的值分布應該只有 venue_fee 與 fnb（各對應原本的 fee／fnb）。
-- ============================================================
with fns as (
  select p.proname, pg_get_functiondef(p.oid) as def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.prokind = 'f'
)
select
  (select count(*) = 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'order_items'
      and column_name = 'revenue_type')                                   as 欄位已建立,
  (select count(*) from public.order_items
    where revenue_type is null and kind is not null)                      as 回填漏網,
  (select bool_or(def like '%revenue_type%') from fns
    where proname = 'checkout_tx')                                        as checkout已雙寫,
  (select bool_or(def like '%''revenue_type'', ''venue_fee''%') from fns
    where proname = 'join_session_tx')                                    as join已帶桶,
  (select count(*) from fns
    where proname in ('list_products_tx', 'list_daypass_tx')
      and def like '%revenue_type%')                                      as 兩支list已回傳,
  (select count(*) from public.products
    where deleted_at is null and revenue_type is null)                    as 商品沒填桶的數量,
  (select jsonb_object_agg(coalesce(revenue_type, '(null)'), n)
     from (select revenue_type, count(*) as n from public.order_items
            group by revenue_type) t)                                     as order_items值分布;
