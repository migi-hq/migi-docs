/* ============================================================
   後台商品改走 RPC（待辦 9 第三項 · 2026-09-08）

   ── 這不是「架構整齊」，是兩個真的洞 ────────────────────
   `migi-admin/src/lib/products.js` 直接 `supabase.from('products')` ×5，
   **是全系統唯一還在直接查表的寫入端**。查證之後真正的問題有兩個：

   ① 🔴 **改價格完全沒有稽核。**
      `products` 有 `created_by` / `updated_by` 兩欄，而
      **9 筆商品全部是 null** —— 沒有任何地方會寫它們。
      ⇒ 「這個檯費是誰改成 150 的」今天答不出來，而且**不可回溯**
        （硬規則 5.6：稽核欄位空著是「今天不填，這段歷史就永遠沒有」）。

   ② 🔴 **`is_system` 保護只在前端。**
      `Products.jsx` 有 `isSystemProduct(r)` 的 if，但資料庫端
      **沒有觸發器也沒有約束**（只有 `prevent_org_change` 與 `set_updated_at`）。
      ⇒ 停用一個系統商品 → `calc_session_fee_tx` 查不到 `SVC-TBL-P02`
        → **開桌流程回 `product_not_found`，而錯誤訊息不會指向後台**。
      📌 目前 7 個系統商品都還是啟用的 —— 那是**沒人去按**，不是擋得住。

   ── 順帶修一個潛伏的 bug ────────────────────────────────
   `revenue_type` 是 **NOT NULL**，而 `payloadOf` 送 `p.revenue_type || null`
   ⇒ 新增商品沒選收入桶會拋 **23502**，而前端把 Postgres 原文印給人看。
   → 後端改成一句話：`revenue_type_required`。

   ── ⚠ 不可以改 `list_products_tx` ───────────────────────
   那一支是 **POS** 的清單：濾掉停用與 `is_available`、排除 `SVC-TBL-%`、
   只回 7 個欄位。後台要的是**全部**（含停用、系統、成本、庫存）——
   兩個需求不同，**另開一支**，不要去加參數把它變成兩用
   （那正是這個專案一再記錄的「一個名字兩個意思」）。

   ── 這一批**不動 RLS policy** ───────────────────────────
   `products_org_write`（ALL / authenticated / `can('product.write')`）
   在前端切換過去、部署驗證過之前**必須留著** ——
   拿掉的話舊版前端會**寫不進去而且看起來像網路問題**。
   ⇒ expand → migrate → contract：這一批是 expand，
     contract（拿掉那條 policy）等前端上線後另開一份。
   ✅ 已查證**沒有任何函式在寫 `products`**，所以日後 contract 是安全的。

   ── 設計原則 ────────────────────────────────────────────
   · 🔴 **org 與操作者都不由呼叫端宣告** —— `current_org_id()` /
     `current_staff()`。同 2026-09-04 那批 14 支：收 `p_staff_id` 的話，
     登入的人可以填別人的 id 假造稽核，而**那比沒有稽核更糟**。
   · 🔴 判斷點一律 `can('product.write')`，不比對 role 字串（待辦 29 ①）。
     ⚠ 讀取那一支也用 `product.write` —— 它是**編輯用的清單**（含成本），
       而今天所有權限碼的答案都一樣（總部才有）。
       **不要為此發明 `product.read`**，那會是一個沒有分辨力的新碼。
   · `tracks_stock = false` ⇒ `stock_qty` 一律 0（商業規則從前端搬到後端）。
   ============================================================ */

/* ── ① 後台商品清單 ──────────────────────────────────── */
create or replace function public.admin_list_products_tx()
returns jsonb
language plpgsql
stable security definer
set search_path to 'public'
as $fn$
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
      'updated_at', updated_at
    ) order by category, sku)
    from products
    where org_id = v_org and deleted_at is null
  ), '[]'::jsonb));
end $fn$;

/* ── ② 新增／更新 ────────────────────────────────────────
   `p_id` 是 null ⇒ 新增；有值 ⇒ 更新。**一支不是兩支** ——
   欄位組裝只有一份，不會出現「新增有補這欄、更新忘了」的漂移
   （`products.js` 的 `payloadOf()` 本來就是為此存在的）。 */
create or replace function public.admin_upsert_product_tx(
  p_id            uuid,
  p_sku           text,
  p_name          text,
  p_category      text,
  p_subcategory   text,
  p_revenue_type  text,
  p_tracks_stock  boolean,
  p_unit_price    integer,
  p_unit_cost     integer,
  p_stock_qty     integer,
  p_is_active     boolean,
  p_is_available  boolean
) returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare
  v_org   uuid;
  v_staff uuid;
  v_sku   text := nullif(btrim(coalesce(p_sku, '')), '');
  v_name  text := nullif(btrim(coalesce(p_name, '')), '');
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

  /* ── 驗證。⚠ 每一條都回**人看得懂的一句話**，不要讓 Postgres
       的 23502 / 23514 直接冒到畫面上（那是這一批要修的病之一）。 */
  if v_sku is null  then return jsonb_build_object('ok', false, 'reason', 'sku_required',  'message', '請填貨號'); end if;
  if v_name is null then return jsonb_build_object('ok', false, 'reason', 'name_required', 'message', '請填品名'); end if;
  if p_category is null or p_category not in ('fnb', 'merch', 'service') then
    return jsonb_build_object('ok', false, 'reason', 'bad_category', 'message', '請選分類');
  end if;
  /* 🔴 `revenue_type` 是 **NOT NULL** —— 前端原本送 `|| null`，
     所以沒選收入桶會拋 23502 而畫面印出 Postgres 原文。 */
  if p_revenue_type is null or p_revenue_type not in ('venue_fee', 'fnb', 'retail', 'other') then
    return jsonb_build_object('ok', false, 'reason', 'revenue_type_required', 'message', '請選收入桶');
  end if;
  if coalesce(p_unit_price, -1) < 0 then
    return jsonb_build_object('ok', false, 'reason', 'bad_price', 'message', '價格不可以是負的');
  end if;

  /* 不盤點的商品庫存一律 0 —— 留著沒人維護的數字會誤導盤點。
     ⚠ 這條規則原本在前端 `payloadOf()`，**搬到後端**才是唯一的來源。 */
  v_stock := case when coalesce(p_tracks_stock, true) then greatest(coalesce(p_stock_qty, 0), 0) else 0 end;

  if p_id is null then
    insert into products (org_id, sku, name, category, subcategory, revenue_type,
                          tracks_stock, unit_price, unit_cost, stock_qty,
                          is_active, is_available, created_by, updated_by)
    values (v_org, v_sku, v_name, p_category, nullif(p_subcategory, ''), p_revenue_type,
            coalesce(p_tracks_stock, true), p_unit_price, coalesce(p_unit_cost, 0), v_stock,
            coalesce(p_is_active, true), coalesce(p_is_available, true), v_staff, v_staff)
    returning * into v_row;
  else
    select is_system, sku into v_sys, v_old
      from products where id = p_id and org_id = v_org and deleted_at is null;
    if not found then
      return jsonb_build_object('ok', false, 'reason', 'not_found', 'message', '找不到這個商品');
    end if;

    /* 🔴 **系統商品不可以改貨號。** 後端以固定貨號查它
       （`calc_session_fee_tx` 依 `planned_minutes` 推出 `SVC-TBL-P02` 再查
       `products`），改了開桌就會回 `product_not_found`，
       而那個錯誤訊息**完全不會指向後台**。
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
       set sku = v_sku, name = v_name, category = p_category,
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
  /* `uq_products_sku (org_id, sku) WHERE deleted_at IS NULL` */
  when unique_violation then
    return jsonb_build_object('ok', false, 'reason', 'sku_taken',
      'message', '這個貨號已經有人用了');
end $fn$;

/* ── ③ 上下架 ──────────────────────────────────────────── */
create or replace function public.admin_set_product_active_tx(p_id uuid, p_is_active boolean)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare v_org uuid; v_staff uuid; v_sys boolean;
begin
  if not public.can('product.write') then
    return jsonb_build_object('ok', false, 'reason', 'forbidden', 'message', '沒有權限編輯商品');
  end if;
  v_org   := public.current_org_id();
  v_staff := (select staff_id from public.current_staff());

  select is_system into v_sys from products
   where id = p_id and org_id = v_org and deleted_at is null;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'not_found', 'message', '找不到這個商品');
  end if;
  /* 🔴 這道牆在此之前**只存在於前端的一個 if**。 */
  if v_sys and p_is_active = false then
    return jsonb_build_object('ok', false, 'reason', 'system_cannot_disable',
      'message', '系統商品不可停用，停用後開桌會找不到它');
  end if;

  update products set is_active = p_is_active, updated_by = v_staff
   where id = p_id and org_id = v_org and deleted_at is null;
  return jsonb_build_object('ok', true);
end $fn$;

/* ── ④ 軟刪除 ──────────────────────────────────────────── */
create or replace function public.admin_delete_product_tx(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare v_org uuid; v_staff uuid; v_sys boolean;
begin
  if not public.can('product.write') then
    return jsonb_build_object('ok', false, 'reason', 'forbidden', 'message', '沒有權限刪除商品');
  end if;
  v_org   := public.current_org_id();
  v_staff := (select staff_id from public.current_staff());

  select is_system into v_sys from products
   where id = p_id and org_id = v_org and deleted_at is null;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'not_found', 'message', '找不到這個商品');
  end if;
  if v_sys then
    return jsonb_build_object('ok', false, 'reason', 'system_cannot_delete',
      'message', '系統商品不可刪除，開桌流程以貨號查詢它');
  end if;

  update products set deleted_at = now(), updated_by = v_staff
   where id = p_id and org_id = v_org and deleted_at is null;
  return jsonb_build_object('ok', true);
end $fn$;


/* ── 授權 ────────────────────────────────────────────────
   🔴 硬規則 2.6b：**兩個方向都要收**。這個專案設了
   `alter default privileges ... grant execute on functions to anon, ...`
   ⇒ 新建的函式**一建立就是 anon 明確授權**（不是 PUBLIC 繼承）。
   ⚠ 只 `revoke from public` 或只 `revoke from anon` 都會是**空操作而且不報錯**。 */
revoke execute on function public.admin_list_products_tx()                      from public;
revoke execute on function public.admin_upsert_product_tx(uuid,text,text,text,text,text,boolean,integer,integer,integer,boolean,boolean) from public;
revoke execute on function public.admin_set_product_active_tx(uuid, boolean)    from public;
revoke execute on function public.admin_delete_product_tx(uuid)                 from public;

revoke execute on function public.admin_list_products_tx()                      from anon;
revoke execute on function public.admin_upsert_product_tx(uuid,text,text,text,text,text,boolean,integer,integer,integer,boolean,boolean) from anon;
revoke execute on function public.admin_set_product_active_tx(uuid, boolean)    from anon;
revoke execute on function public.admin_delete_product_tx(uuid)                 from anon;

/* ⚠ `authenticated` **必須留著** —— migi-admin 用的是真的 Supabase Auth
   session，收掉的話後台會 permission denied（**不是擋住，是壞掉**）。 */
grant execute on function public.admin_list_products_tx()                      to authenticated;
grant execute on function public.admin_upsert_product_tx(uuid,text,text,text,text,text,boolean,integer,integer,integer,boolean,boolean) to authenticated;
grant execute on function public.admin_set_product_active_tx(uuid, boolean)    to authenticated;
grant execute on function public.admin_delete_product_tx(uuid)                 to authenticated;


/* ============================================================
   驗證（單一 SELECT）

   ⚠ 硬規則 3.55：每一道擋牆都要有**正對照** ——
     只驗「擋住了」的話，一支永遠回 `forbidden` 的實作也會全綠。
   ⚠ 硬規則 3.9：訊息一律在 **exception 處理器**裡 `set_config` ——
     寫在成功路徑上再 raise 的話會跟著回滾，最後印出空白。
   ⚠ 寫入測試包在 `begin … exception` 子交易裡並 `raise` 回滾，
     所以**一列都不會真的留下**（沒有 staging，硬規則 5.7）。
   ============================================================ */
do $$
declare
  v_hq_uid  uuid;
  v_pid     uuid;
  v_sysid   uuid;
  v_r       jsonb;
  v_msg     text := '';
  v_n       int;
begin
  /* 取總部那張 session 的 auth_uid（**當場查，不寫死**，硬規則 3.56）。 */
  select s.auth_uid into v_hq_uid
    from staff s where s.auth_uid is not null and s.deleted_at is null
     and s.role in ('hq', 'owner') limit 1;
  if v_hq_uid is null then
    perform set_config('migi.p', '🔴 找不到有 auth_uid 的總部 staff —— 下面全部不算數', true);
    return;
  end if;

  begin
    perform set_config('request.jwt.claims',
      json_build_object('sub', v_hq_uid::text, 'role', 'authenticated')::text, true);
    set local role authenticated;

    -- ③ 正對照：總部讀得到，而且**含停用與系統商品**
    v_r := public.admin_list_products_tx();
    v_n := jsonb_array_length(v_r -> 'rows');
    v_msg := v_msg || case when (v_r ->> 'ok')::boolean and v_n > 0
      then '✅ ③ 總部讀到 ' || v_n || ' 筆'
      else '🔴 ③ 讀不到：' || coalesce(v_r ->> 'reason', '?') end;

    -- ④ 負對照：系統商品**不可停用**
    select id into v_sysid from products
     where is_system and deleted_at is null limit 1;
    v_r := public.admin_set_product_active_tx(v_sysid, false);
    v_msg := v_msg || E'\n' || case when (v_r ->> 'reason') = 'system_cannot_disable'
      then '✅ ④ 系統商品擋住了' else '🔴 ④ 竟然放行：' || v_r::text end;

    -- ⑤ 負對照：系統商品**不可刪除**
    v_r := public.admin_delete_product_tx(v_sysid);
    v_msg := v_msg || E'\n' || case when (v_r ->> 'reason') = 'system_cannot_delete'
      then '✅ ⑤ 刪除也擋住了' else '🔴 ⑤ 竟然放行：' || v_r::text end;

    -- ⑥ 🔴 **正對照**：一般商品要真的改得動（少了這格，一支永遠回錯的實作也會全綠）
    select id into v_pid from products
     where not is_system and deleted_at is null limit 1;
    v_r := public.admin_set_product_active_tx(v_pid, false);
    v_msg := v_msg || E'\n' || case when (v_r ->> 'ok')::boolean
      then '✅ ⑥ 一般商品改得動（沒有過度阻擋）' else '🔴 ⑥ 被誤擋：' || v_r::text end;

    -- ⑦ `updated_by` 真的寫進去了（這一批存在的主因）
    select updated_by into v_hq_uid from products where id = v_pid;
    v_msg := v_msg || E'\n' || case when v_hq_uid is not null
      then '✅ ⑦ updated_by 有值（在此之前 9/9 全是 null）'
      else '🔴 ⑦ updated_by 還是 null —— 稽核沒接上' end;

    -- ⑧ 沒選收入桶要回人話，不是 23502
    v_r := public.admin_upsert_product_tx(null, 'TEST-XX-1', '測試', 'fnb', null, null,
                                          true, 10, 0, 0, true, true);
    v_msg := v_msg || E'\n' || case when (v_r ->> 'reason') = 'revenue_type_required'
      then '✅ ⑧ 沒選收入桶 → 人話' else '🔴 ⑧ ' || v_r::text end;

    -- ⑨ 貨號重複要回人話，不是 23505
    v_r := public.admin_upsert_product_tx(null,
             (select sku from products where deleted_at is null limit 1),
             '撞號測試', 'fnb', null, 'fnb', true, 10, 0, 0, true, true);
    v_msg := v_msg || E'\n' || case when (v_r ->> 'reason') = 'sku_taken'
      then '✅ ⑨ 貨號重複 → 人話' else '🔴 ⑨ ' || v_r::text end;

    -- ⑩ 🔴 負對照：**非總部身分一律 forbidden**
    perform set_config('request.jwt.claims',
      json_build_object('sub', gen_random_uuid()::text, 'role', 'authenticated')::text, true);
    v_r := public.admin_list_products_tx();
    v_msg := v_msg || E'\n' || case when (v_r ->> 'reason') = 'forbidden'
      then '✅ ⑩ 非總部被擋' else '🔴 ⑩ 竟然讀得到：' || left(v_r::text, 120) end;

    reset role;
    raise exception 'migi_rollback';
  exception
    when others then
      begin reset role; exception when others then null; end;
      if sqlerrm <> 'migi_rollback' then
        v_msg := v_msg || E'\n🔴 測試中途拋錯：' || sqlerrm;
      end if;
      /* 🔴 訊息設在**這裡**不是成功路徑上 —— 硬規則 3.9：
         `set_config(..., true)` 會被子交易回滾掉。 */
      perform set_config('migi.p', v_msg, true);
  end;
end $$;

select
  '① 四支都在：' || (select count(*)::text from pg_proc
     where pronamespace = 'public'::regnamespace
       and proname in ('admin_list_products_tx','admin_upsert_product_tx',
                       'admin_set_product_active_tx','admin_delete_product_tx'))
    || ' / 4'                                                                  as "①建立",
  /* ② 授權：明確與 PUBLIC **兩個方向都印**（硬規則 2.6b）——
     只印 `has_function_privilege` 的話，收錯方向的症狀跟沒收一模一樣。 */
  (select string_agg(p.proname || '〔auth=' ||
            case when exists (select 1 from aclexplode(p.proacl) a
                   where a.grantee = 'authenticated'::regrole::oid and a.privilege_type = 'EXECUTE')
                 then '✅' else '🔴' end ||
            ' anon=' ||
            case when exists (select 1 from aclexplode(p.proacl) a
                   where a.grantee = 'anon'::regrole::oid and a.privilege_type = 'EXECUTE')
                 then '🔴有' else '✅無' end ||
            ' PUBLIC=' ||
            case when p.proacl is null or exists (select 1 from aclexplode(p.proacl) a
                   where a.grantee = 0 and a.privilege_type = 'EXECUTE')
                 then '🔴有' else '✅無' end || '〕', E'\n')
     from pg_proc p where p.pronamespace = 'public'::regnamespace
       and p.proname like 'admin_%product%')                                    as "②授權",
  coalesce(nullif(current_setting('migi.p', true), ''), '🔴 沒有測試訊息 —— DO 區塊沒跑到')
                                                                                as "③～⑩行為";
