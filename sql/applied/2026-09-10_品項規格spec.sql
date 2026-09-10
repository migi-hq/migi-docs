/* ============================================================
   品項規格 `spec`：products ＋ order_items 快照
   2026-09-10 · 待辦 44 第 1 步
   📄 決策與預覽：`docs/_資產/品項單位_定案.html`

   ── 做什麼 ────────────────────────────────────────────
   ```
   products.spec      「10 顆／份」，可空 —— 商品卡與購物車的副行
   order_items.spec   結帳當下蓋章，跟 name / unit_price 一樣
   ```

   ── 🔴 為什麼快照那一半是今天做，不是日後補 ──────────
   `order_items` 現在快照 `name` / `unit_price` / `revenue_type`，**沒有 spec**。
   ⇒ 雞塊從 6 個改成 10 個之後，歷史訂單只留著「2 份」，
     **那 2 份是幾個永遠算不回來** —— 而那正是進銷存第一個要問的數字
     （《首店餐飲籌備》要用「每項每日份數 × 進貨週期」算冷凍櫃容量）。
   ⚠ 這一半是**不可回溯**的（硬規則 5.6）：今天加零成本，事後補補不回來。

   ── 動到四支函式，而只有一支要 DROP ──────────────────
   | 函式 | 怎麼改 | 為什麼 |
   |---|---|---|
   | `list_products_tx` | CREATE OR REPLACE | 只是多回一個鍵，簽名沒變 |
   | `admin_list_products_tx` | CREATE OR REPLACE | 同上 |
   | `checkout_tx` | **DO 區塊換兩處** | 全文很長，而這次只動一個 INSERT |
   | `admin_upsert_product_tx` | 🔴 **DROP ＋ 重建 ＋ 補 GRANT** | 加參數 ＝ 改簽名（硬規則 2） |

   🔴 **`p_spec` 放在參數列最後而且給 default** ——
     Postgres 要求有預設值的參數排在後面，而這樣也順便是 expand-safe：
     **這份 SQL 可以在前端部署之前先跑**，舊的前端不送它照樣能用。

   ✅ **DROP 之前查過線上授權**（硬規則 2）：
     `admin_upsert_product_tx` 是 `authenticated · service_role`，
     檔尾補回去。⚠ 不補的話後台商品編輯會**當場壞掉**。

   ── ⚠ 這份檔案的 raise 分兩種，不要混淆（硬規則 1.8）──
   · **DDL 段的 guard 可以 raise** —— 那是「改到一半就整份回滾」，
     是 2026-08-19 那批救過兩次的機制，**故意要中止**。
   · **驗證段一個字都不准 raise** —— raise 會把上面的 DDL 一起丟掉，
     而且六格全綠。用 `set_config` ＋ 最後一支 SELECT。
   ============================================================ */

/* ── ① 兩個欄位 ─────────────────────────────────────── */
alter table public.products    add column if not exists spec text;
alter table public.order_items add column if not exists spec text;

/* ⚠ `COMMENT ON ... IS` 只吃**單一字面常值**，不吃運算式（`||` 會是語法錯誤），
   而「相鄰常值自動接起來」這條規則 2026-09-04 已經害一份 SQL 整份跑不起來。
   ⇒ 一律寫成一個常值，換行直接放在引號裡面。 */
comment on column public.products.spec is
'規格說明（「10 顆／份」）。可空，沒有就不畫那一行。
🔴 這是「說明」不是「選項」：同一個商品有多種份量（6 個裝／10 個裝）
要開兩個 SKU，不是在這裡塞兩個值。檯費那七支就是那種變體。';

comment on column public.order_items.spec is
'結帳當下的規格快照，跟 name / unit_price 同一個道理。
🔴 沒有它的話，商品改過份量之後「那一筆賣了幾顆」就永遠算不回來。';

/* ── ② 把規格從品名裡搬出來 ────────────────────────────
   用 sku 認，不用品名 —— 品名正是這一步要改的東西。 */
update public.products
   set name = '水餃', spec = '10 顆／份', updated_at = now()
 where sku = 'FNB-MEAL-DUMP' and deleted_at is null;

/* ── ③ POS 的商品清單多回 spec ──────────────────────── */
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
      'discountable', discountable,
      'spec', spec
    ) order by category, sku)
    from products
    where org_id = p_org_id and is_active and coalesce(is_available, true)
      and deleted_at is null
      and sku not like 'SVC-TBL-%'   -- 檯費不列入加購清單，避免店員手動點錯
  ), '[]'::jsonb);
end $function$;

/* ── ④ 後台的商品清單多回 spec ─────────────────────── */
create or replace function public.admin_list_products_tx()
returns jsonb
language plpgsql
stable security definer
set search_path to 'public'
as $function$
declare v_org uuid;
begin
  if not public.can('product.write') then
    return jsonb_build_object('ok', false, 'reason', 'forbidden',
                              'message', '沒有權限查看商品');
  end if;
  v_org := public.current_org_id();

  return jsonb_build_object('ok', true, 'rows', coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', id, 'sku', sku, 'name', name,
      'category', category, 'subcategory', subcategory,
      'revenue_type', revenue_type,
      'unit_price', unit_price, 'unit_cost', unit_cost,
      'tracks_stock', tracks_stock, 'stock_qty', stock_qty,
      'is_active', is_active, 'is_available', is_available,
      'is_system', is_system, 'discountable', discountable,
      'spec', spec,
      'updated_at', updated_at
    ) order by category, sku)
    from products
    where org_id = v_org and deleted_at is null
  ), '[]'::jsonb));
end $function$;

/* ── ⑤ 後台編輯：改簽名，所以要 DROP（硬規則 2）────── */
drop function if exists public.admin_upsert_product_tx(
  uuid, text, text, text, text, text, boolean, integer, integer, integer, boolean, boolean);

create or replace function public.admin_upsert_product_tx(
  p_id uuid, p_sku text, p_name text, p_category text, p_subcategory text,
  p_revenue_type text, p_tracks_stock boolean, p_unit_price integer,
  p_unit_cost integer, p_stock_qty integer, p_is_active boolean, p_is_available boolean,
  p_spec text default null            -- 🔴 有預設值的要排最後，也讓它 expand-safe
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_org   uuid;
  v_staff uuid;
  v_sku   text := nullif(btrim(coalesce(p_sku, '')), '');
  v_name  text := nullif(btrim(coalesce(p_name, '')), '');
  v_spec  text := nullif(btrim(coalesce(p_spec, '')), '');   -- 空字串一律存 null
  v_stock integer;
  v_sys   boolean;
  v_old   text;
  v_row   products%rowtype;
begin
  if not public.can('product.write') then
    return jsonb_build_object('ok', false, 'reason', 'forbidden', 'message', '沒有權限編輯商品');
  end if;
  v_org   := public.current_org_id();
  v_staff := (select staff_id from public.current_staff());

  if v_sku is null  then return jsonb_build_object('ok', false, 'reason', 'sku_required',  'message', '請填貨號'); end if;
  if v_name is null then return jsonb_build_object('ok', false, 'reason', 'name_required', 'message', '請填品名'); end if;
  if p_category is null or p_category not in ('fnb', 'merch', 'service') then
    return jsonb_build_object('ok', false, 'reason', 'bad_category', 'message', '請選分類');
  end if;
  /* 🔴 `revenue_type` 是 **NOT NULL** —— 前端原本送 `|| null`，
     所以沒選會拋 23502 而畫面印出 Postgres 原文。
     ⚠ 話術 2026-09-08 改用「營收類別」（原本那個詞是分桶邏輯的比喻，
       店員沒有那個脈絡）。**這裡刻意不寫出舊詞** —— 寫了的話
       掃描禁字的驗證段會被自己的註解觸發（硬規則 3.5）。 */
  if p_revenue_type is null or p_revenue_type not in ('venue_fee', 'fnb', 'retail', 'other') then
    return jsonb_build_object('ok', false, 'reason', 'revenue_type_required', 'message', '請選營收類別');
  end if;
  if coalesce(p_unit_price, -1) < 0 then
    return jsonb_build_object('ok', false, 'reason', 'bad_price', 'message', '價格不可以是負的');
  end if;

  /* 不盤點的商品庫存一律 0 —— 留著沒人維護的數字會誤導盤點。 */
  v_stock := case when coalesce(p_tracks_stock, true) then greatest(coalesce(p_stock_qty, 0), 0) else 0 end;

  if p_id is null then
    insert into products (org_id, sku, name, spec, category, subcategory, revenue_type,
                          tracks_stock, unit_price, unit_cost, stock_qty,
                          is_active, is_available, created_by, updated_by)
    values (v_org, v_sku, v_name, v_spec, p_category, nullif(p_subcategory, ''), p_revenue_type,
            coalesce(p_tracks_stock, true), p_unit_price, coalesce(p_unit_cost, 0), v_stock,
            coalesce(p_is_active, true), coalesce(p_is_available, true), v_staff, v_staff)
    returning * into v_row;
  else
    select is_system, sku into v_sys, v_old
      from products where id = p_id and org_id = v_org and deleted_at is null;
    if not found then
      return jsonb_build_object('ok', false, 'reason', 'not_found', 'message', '找不到這個商品');
    end if;

    /* 🔴 系統商品不可改貨號：後端以固定貨號查它，改了開桌會回
       `product_not_found`，而那個錯誤訊息不會指向後台。
       ⚠ 品名與價格**可以改** —— 調檯費是正當的營運動作。 */
    if v_sys and v_sku is distinct from v_old then
      return jsonb_build_object('ok', false, 'reason', 'system_sku_locked',
        'message', '系統商品的貨號不可更改（後端以此貨號查詢它）');
    end if;
    if v_sys and coalesce(p_is_active, true) = false then
      return jsonb_build_object('ok', false, 'reason', 'system_cannot_disable',
        'message', '系統商品不可停用，停用後開桌會找不到它');
    end if;

    update products
       set sku = v_sku, name = v_name, spec = v_spec, category = p_category,
           subcategory = nullif(p_subcategory, ''), revenue_type = p_revenue_type,
           tracks_stock = coalesce(p_tracks_stock, true),
           unit_price = p_unit_price, unit_cost = coalesce(p_unit_cost, 0),
           stock_qty = v_stock,
           is_active = coalesce(p_is_active, true),
           is_available = coalesce(p_is_available, true),
           updated_by = v_staff
     where id = p_id and org_id = v_org and deleted_at is null
    returning * into v_row;
  end if;

  return jsonb_build_object('ok', true, 'id', v_row.id, 'sku', v_row.sku);
exception
  when unique_violation then
    return jsonb_build_object('ok', false, 'reason', 'sku_taken',
      'message', '這個貨號已經有人用了');
end $function$;

/* 🔴 DROP 把 GRANT 一起丟掉了，補回去（線上原本就是這兩個角色）。
   ⚠ 不補的話後台商品編輯會當場壞掉，而症狀是 permission denied。 */
revoke execute on function public.admin_upsert_product_tx(
  uuid, text, text, text, text, text, boolean, integer, integer, integer, boolean, boolean, text) from public;
revoke execute on function public.admin_upsert_product_tx(
  uuid, text, text, text, text, text, boolean, integer, integer, integer, boolean, boolean, text) from anon;
grant  execute on function public.admin_upsert_product_tx(
  uuid, text, text, text, text, text, boolean, integer, integer, integer, boolean, boolean, text)
  to authenticated, service_role;

/* ── ⑥ checkout_tx 蓋章：只換兩處，不重建全文 ──────────
   它的 INSERT 已經是 join 主檔取值（2026-08-27「價格一律查主檔」那批的
   成果），所以 `spec` 跟著 `pr.name` 走就好 —— **不採信前端**。
   ⚠ 這個 DO 區塊的 raise 是**故意中止**：換不到就整份回滾，
     不要留下一支「改了一半」的金流函式（2026-08-19 這個 guard 救過兩次）。 */
do $mig$
declare v_def text; v_new text;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
     and p.proname = 'checkout_tx';

  if v_def is null then
    raise exception '🔴 找不到 checkout_tx';
  end if;

  v_new := replace(v_def,
    'order_items(org_id, order_id, product_id, name, revenue_type, qty,',
    'order_items(org_id, order_id, product_id, name, spec, revenue_type, qty,');
  v_new := replace(v_new,
    'select v_org, v_order_id, pr.id, pr.name, pr.revenue_type,',
    'select v_org, v_order_id, pr.id, pr.name, pr.spec, pr.revenue_type,');

  if position('name, spec, revenue_type' in v_new) = 0 then
    raise exception '🔴 欄位清單那一處沒換到 —— 線上版本與預期不同，先撈全文對照再改';
  end if;
  if position('pr.name, pr.spec, pr.revenue_type' in v_new) = 0 then
    raise exception '🔴 select 那一處沒換到 —— 同上';
  end if;

  execute v_new;
end $mig$;

/* ── 驗證段（唯讀，一個字都不 raise）──────────────────── */
do $$
declare v_msg text := ''; v_n int; v_t text;
begin
  select count(*) into v_n from information_schema.columns
   where table_schema='public' and table_name='products' and column_name='spec';
  v_msg := v_msg || case when v_n=1 then '① ✅ products.spec 建好了' else '① 🔴 products 沒有 spec' end;

  select count(*) into v_n from information_schema.columns
   where table_schema='public' and table_name='order_items' and column_name='spec';
  v_msg := v_msg || E'\n' || case when v_n=1
    then '② ✅ order_items.spec 建好了（快照那一半）' else '② 🔴 order_items 沒有 spec' end;

  select name || ' ／ ' || coalesce(spec,'(null)') into v_t
    from products where sku='FNB-MEAL-DUMP' and deleted_at is null;
  v_msg := v_msg || E'\n' || case when v_t = '水餃 ／ 10 顆／份'
    then '③ ✅ 水餃搬好了：' || v_t
    else '③ 🔴 搬得不對：' || coalesce(v_t,'(找不到這支商品)') end;

  /* ④ 金流函式那兩處。⚠ 樣式要夠長才不會誤中註解（硬規則 3.5）。 */
  select count(*) into v_n from pg_proc p
   where p.pronamespace='public'::regnamespace and p.prokind='f' and p.proname='checkout_tx'
     and position('pr.name, pr.spec, pr.revenue_type' in pg_get_functiondef(p.oid)) > 0;
  v_msg := v_msg || E'\n' || case when v_n=1
    then '④ ✅ checkout_tx 會蓋章了（而且是查主檔，不採信前端）'
    else '④ 🔴 checkout_tx 沒換到' end;

  select count(*) into v_n from pg_proc p
   where p.pronamespace='public'::regnamespace and p.prokind='f'
     and p.proname in ('list_products_tx','admin_list_products_tx')
     and position('''spec''' in pg_get_functiondef(p.oid)) > 0;
  v_msg := v_msg || E'\n' || case when v_n=2
    then '⑤ ✅ 兩支清單函式都回 spec 了' else '⑤ 🔴 只有 ' || v_n || ' 支回 spec' end;

  /* ⑥ DROP 有沒有建出多載 —— 版本數必須是 1，參數必須是 13。 */
  select count(*) into v_n from pg_proc p
   where p.pronamespace='public'::regnamespace and p.prokind='f'
     and p.proname='admin_upsert_product_tx';
  select coalesce((select pg_get_function_identity_arguments(p.oid) from pg_proc p
                    where p.pronamespace='public'::regnamespace and p.prokind='f'
                      and p.proname='admin_upsert_product_tx' limit 1),'') into v_t;
  v_msg := v_msg || E'\n' || case
    when v_n=1 and position('p_spec text' in v_t) > 0
      then '⑥ ✅ admin_upsert_product_tx 只有一個版本，而且吃得到 p_spec'
    when v_n<>1 then '⑥ 🔴 有 ' || v_n || ' 個版本 —— DROP 沒吃掉舊的（多載）'
    else '⑥ 🔴 簽名裡沒有 p_spec' end;

  /* ⑦ 🔴 正對照：DROP 會把 GRANT 丟掉。只驗「函式在」的話，
        一支沒有人叫得動的函式也會讓上面那格變綠，而後台會當場壞掉。 */
  select count(*) into v_n
    from pg_proc p, aclexplode(coalesce(p.proacl,'{}')) a
   where p.pronamespace='public'::regnamespace and p.proname='admin_upsert_product_tx'
     and a.privilege_type='EXECUTE' and a.grantee='authenticated'::regrole::oid;
  v_msg := v_msg || E'\n' || case when v_n=1
    then '⑦ ✅ authenticated 的執行權補回來了（後台沒被打壞）'
    else '⑦ 🔴 authenticated 不見了 —— 後台商品編輯會 permission denied' end;

  /* ⑧ 負對照：既有的品項不該被填上任何 spec。
        它們是舊訂單，當時沒有這個欄位 —— 全是 null 才對。 */
  select count(*) into v_n from order_items where spec is not null;
  v_msg := v_msg || E'\n' || case when v_n=0
    then '⑧ ✅ 既有訂單的 spec 全是 null（沒有被回填汙染）'
    else '⑧ 🔴 竟然有 ' || v_n || ' 筆舊訂單被填了 spec' end;

  perform set_config('migi.chk', v_msg, true);
end $$;

select coalesce(nullif(current_setting('migi.chk', true), ''), '🔴 沒有訊息') as "驗證";
