/* ============================================================
   把「收入桶」從函式註解裡拿掉（2026-09-08）—— 硬規則 3.5 第三次

   ── 發生了什麼 ────────────────────────────────────────
   前一份（`2026-09-08_收入桶改叫營收類別.sql`）的驗證段第 ② 格寫：
   ```sql
   ... and pg_get_functiondef(oid) like '%收入桶%'   -- 應為 0 支
   ```
   結果紅了。而唯一命中的是**我自己在同一份 SQL 裡寫的那行註解**：
   ```
   ★ 2026-09-08：話術「收入桶」→「營收類別」（見檔頭）。
   ```

   🔴 **硬規則 3.5 逐字寫著這件事：「禁字不能是自己註解裡會出現的詞」。**
   `pg_get_functiondef` 回的是**含註解的全文**，字串比對分不出
   程式碼與說明文字。CLAUDE.md 已經記過兩次
   （2026-08-23 掃 `clerk`、2026-08-25 掃 `session_id`）——
   **這是第三次，而且這次是我一邊引用那條規則一邊踩它。**

   ⚠ 而症狀是**最糟的那一種**：函式完全正確（前一份的 ③ 四格全過），
     但驗證段永遠紅。**一個永遠紅的檢查，會讓人學會忽略紅色** ——
     那比沒有檢查更危險（同硬規則 3.58 那個「把失敗訊號翻譯成通過訊號」的反面）。

   ── 修法 ──────────────────────────────────────────────
   ✅ **把那個詞從註解裡拿掉**（用描述代替引用），掃描就恢復可信。
   📌 同硬規則 3.6b 的處理方式：「要在註解裡舉 JSX 註解的例子，
     **用文字描述，不要寫真的符號**」—— 同一個道理。
   ⚠ 檔頭（`create` 之外）**可以**出現那個詞 ——
     `pg_get_functiondef` 只回函式本體，掃不到這裡。

   ── 這一份只改一行註解，簽名與行為完全不動 ────────────────
   ✅ `CREATE OR REPLACE`，不 DROP、不掉 GRANT。
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

   🎯 這一份的重點是**讓 ② 那格從「永遠紅」變回可信**，
     所以它同時保留行為測試 —— 只改註解也可能手滑改壞函式。
   ============================================================ */
do $$
declare v_uid uuid; v_r jsonb; v_msg text := ''; v_sysid uuid; v_pid uuid;
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

    v_r := public.admin_upsert_product_tx(null, 'TEST-XX-1', '測試', 'fnb', null, null,
                                          true, 10, 0, 0, true, true);
    v_msg := case when (v_r ->> 'message') = '請選營收類別'
      then '✅ ① 話術正確：' || (v_r ->> 'message')
      else '🔴 ① ' || coalesce(v_r ->> 'message', '(無)') end;
    v_msg := v_msg || E'\n' || case when (v_r ->> 'reason') = 'revenue_type_required'
      then '✅ ② reason 沒變' else '🔴 ② reason 被改動：' || (v_r ->> 'reason') end;

    select id into v_sysid from products where is_system and deleted_at is null limit 1;
    v_r := public.admin_set_product_active_tx(v_sysid, false);
    v_msg := v_msg || E'\n' || case when (v_r ->> 'reason') = 'system_cannot_disable'
      then '✅ ③ 系統商品擋牆還在' else '🔴 ③ ' || v_r::text end;

    /* 🔴 正對照：一般商品要真的改得動 —— 少了這格，
       一支永遠回錯的實作也會讓 ③ 變綠（硬規則 3.55）。 */
    select id into v_pid from products where not is_system and deleted_at is null limit 1;
    v_r := public.admin_set_product_active_tx(v_pid, false);
    v_msg := v_msg || E'\n' || case when (v_r ->> 'ok')::boolean
      then '✅ ④ 一般商品沒被誤擋' else '🔴 ④ ' || v_r::text end;

    reset role;
    raise exception 'migi_rollback';
  exception when others then
    begin reset role; exception when others then null; end;
    if sqlerrm <> 'migi_rollback' then v_msg := v_msg || E'\n🔴 中途拋錯：' || sqlerrm; end if;
    perform set_config('migi.p', v_msg, true);
  end;
end $$;

select
  /* ★ 這一格就是上一份紅掉的那一格。現在它應該綠 ——
     **而綠的原因是註解改了，不是函式改了**。 */
  case when (select count(*) from pg_proc
               where pronamespace = 'public'::regnamespace
                 and proname like 'admin_%product%'
                 and pg_get_functiondef(oid) like '%收入桶%') = 0
       then '✅ ① 函式全文（含註解）已無舊詞 —— 掃描恢復可信'
       else '🔴 ① 還有函式含舊詞：' ||
            (select string_agg(proname, ', ') from pg_proc
              where pronamespace = 'public'::regnamespace
                and proname like 'admin_%product%'
                and pg_get_functiondef(oid) like '%收入桶%') end     as "①禁字掃描",
  /* ⚠ 正對照：新詞**要**出現（不然「把舊詞刪掉」也會讓 ① 變綠）。 */
  case when (select count(*) from pg_proc
               where pronamespace = 'public'::regnamespace
                 and proname = 'admin_upsert_product_tx'
                 and pg_get_functiondef(oid) like '%請選營收類別%') = 1
       then '✅ ② 新話術確實在函式裡'
       else '🔴 ② 新話術不見了 —— ① 綠可能只是因為整段被刪掉' end   as "②正對照",
  '③ 版本數 ' || (select count(*)::text from pg_proc
     where pronamespace = 'public'::regnamespace and proname = 'admin_upsert_product_tx')
    || '（應為 1）'                                                   as "③版本",
  coalesce(nullif(current_setting('migi.p', true), ''), '🔴 沒有測試訊息')  as "④行為";
