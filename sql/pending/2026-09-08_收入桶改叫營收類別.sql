/* ============================================================
   把「收入桶」這個行話從畫面上拿掉（2026-09-08）

   使用者：「收入桶 這名詞沒人看得懂 用台灣可以讀懂的名詞」——**對的**。
   🔴 `bucket`／「桶」是我在**分桶邏輯**裡用的比喻（`rem_fee` / `v_goods`
     那一族），店員與總部沒有那個脈絡，而它出現在**後台的欄位標籤**上。

   ⚠ 值本身早就是人話（檯費／餐飲／周邊／其他，存在 `product_taxonomy`）——
     **只有欄位名是行話**，所以這是一個純文案修正。

   ── 這一份只改一句訊息 ─────────────────────────────────
   `admin_upsert_product_tx` 昨天才建立，裡面有一句
   `'請選收入桶'`（沒選 `revenue_type` 時回給後台的話術）。
   ✅ 簽名不變 ⇒ `CREATE OR REPLACE`，不用 DROP、不掉 GRANT。

   📌 同批改的前端（已推）：
     `migi-admin/src/pages/Products.jsx` 欄位標籤與錯誤訊息
     `migi-pos/src/lib/api.js` 的 `products_revenue_type_check` 對照

   ⚠ **資料層的 `revenue_type` 不改** —— 英文沒有這個歧義，
     而改欄位名要動 6 支函式與三端。同 CLAUDE.md 那條
     「只改中文不改資料層」（三種『分』那一節）。
   ============================================================ */

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

  if v_sku is null  then return jsonb_build_object('ok', false, 'reason', 'sku_required',  'message', '請填貨號'); end if;
  if v_name is null then return jsonb_build_object('ok', false, 'reason', 'name_required', 'message', '請填品名'); end if;
  if p_category is null or p_category not in ('fnb', 'merch', 'service') then
    return jsonb_build_object('ok', false, 'reason', 'bad_category', 'message', '請選分類');
  end if;
  /* 🔴 `revenue_type` 是 **NOT NULL** —— 前端原本送 `|| null`，
     所以沒選會拋 23502 而畫面印出 Postgres 原文。
     ★ 2026-09-08：話術「收入桶」→「**營收類別**」（見檔頭）。 */
  if p_revenue_type is null or p_revenue_type not in ('venue_fee', 'fnb', 'retail', 'other') then
    return jsonb_build_object('ok', false, 'reason', 'revenue_type_required', 'message', '請選營收類別');
  end if;
  if coalesce(p_unit_price, -1) < 0 then
    return jsonb_build_object('ok', false, 'reason', 'bad_price', 'message', '價格不可以是負的');
  end if;

  /* 不盤點的商品庫存一律 0 —— 留著沒人維護的數字會誤導盤點。 */
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
  when unique_violation then
    return jsonb_build_object('ok', false, 'reason', 'sku_taken',
      'message', '這個貨號已經有人用了');
end $fn$;


/* ============================================================
   驗證（單一 SELECT）
   ⚠ 這一份只改文案，所以驗的是「話術換了、**行為沒變**」——
     只驗前者的話，一支把擋牆改壞的版本也會綠。
   ============================================================ */
do $$
declare v_uid uuid; v_r jsonb; v_msg text := ''; v_sysid uuid;
begin
  select s.auth_uid into v_uid from staff s
   where s.auth_uid is not null and s.deleted_at is null
     and s.role in ('hq','owner') limit 1;
  if v_uid is null then
    perform set_config('migi.p', '🔴 找不到總部 staff', true); return;
  end if;
  begin
    perform set_config('request.jwt.claims',
      json_build_object('sub', v_uid::text, 'role', 'authenticated')::text, true);
    set local role authenticated;

    -- ① 話術換了
    v_r := public.admin_upsert_product_tx(null, 'TEST-XX-1', '測試', 'fnb', null, null,
                                          true, 10, 0, 0, true, true);
    v_msg := case when (v_r ->> 'message') = '請選營收類別'
      then '✅ ① 話術已改：' || (v_r ->> 'message')
      else '🔴 ① 還是舊的：' || coalesce(v_r ->> 'message', '(無)') end;

    -- ② 🔴 正對照：`reason` **不可以跟著改**（前端與日誌認的是它，不是中文）
    v_msg := v_msg || E'\n' || case when (v_r ->> 'reason') = 'revenue_type_required'
      then '✅ ② reason 沒變（前端認的是它）' else '🔴 ② reason 被改動了：' || (v_r ->> 'reason') end;

    -- ③ 正對照：行為沒變 —— 系統商品照樣擋
    select id into v_sysid from products where is_system and deleted_at is null limit 1;
    v_r := public.admin_set_product_active_tx(v_sysid, false);
    v_msg := v_msg || E'\n' || case when (v_r ->> 'reason') = 'system_cannot_disable'
      then '✅ ③ 擋牆沒被改壞' else '🔴 ③ ' || v_r::text end;

    -- ④ 正對照：正常路徑還通（沒有把函式改壞）
    v_r := public.admin_list_products_tx();
    v_msg := v_msg || E'\n' || case when (v_r ->> 'ok')::boolean
      then '✅ ④ 清單仍讀得到 ' || jsonb_array_length(v_r -> 'rows') || ' 筆'
      else '🔴 ④ ' || v_r::text end;

    reset role;
    raise exception 'migi_rollback';
  exception when others then
    begin reset role; exception when others then null; end;
    if sqlerrm <> 'migi_rollback' then v_msg := v_msg || E'\n🔴 中途拋錯：' || sqlerrm; end if;
    perform set_config('migi.p', v_msg, true);
  end;
end $$;

select
  '① 版本數 ' || (select count(*)::text from pg_proc
     where pronamespace = 'public'::regnamespace and proname = 'admin_upsert_product_tx')
    || '（應為 1）'                                                              as "①版本",
  case when (select count(*) from pg_proc
               where pronamespace = 'public'::regnamespace
                 and proname like 'admin_%product%'
                 and pg_get_functiondef(oid) like '%收入桶%') = 0
       then '✅ ② 四支函式裡「收入桶」已歸零'
       else '🔴 ② 還有函式含「收入桶」' end                                      as "②行話清乾淨",
  coalesce(nullif(current_setting('migi.p', true), ''), '🔴 沒有測試訊息')        as "③行為";
