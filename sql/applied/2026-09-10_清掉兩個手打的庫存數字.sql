/* ============================================================
   把水餃與厚片的庫存歸零
   2026-09-10 · 待辦 44 的收尾

   ── 為什麼 ──────────────────────────────────────────
   32 項餐飲裡有 30 項是 0、2 項是 50，而那 50 是**後台手打的裝飾**：
   ```
   會扣 stock_qty 的函式        0 支
   賣掉的品項                   224 筆
   水餃與厚片的庫存             一次都沒動過
   ```
   ⇒ 它不是「還沒扣」，是**沒有任何東西會扣它**。

   🔴 留著比清掉更糟，而且不是整齊的問題：
     **一個永遠不準的數字會訓練人忽略它** —— 同硬規則 3.5 那個
     「永遠紅的檢查」的形狀。而庫存正是日後進銷存上線時，
     第一個要有人相信的數字。
   🎯 0 是誠實的：**沒有進貨紀錄就不該有結存**。
   📌 真的要有庫存要等異動流水表（`docs/07-營運商業/進銷存系統設計.md` 第四節，
     順序是流水 → 進貨 → 盤點 → 損耗 → 換算率 → 配方）。

   ⚠ 只動餐飲。檯費那七支的 `stock_qty` 本來就是 0
     而且 `tracks_stock = false`，不在範圍內。
   ============================================================ */

update public.products
   set stock_qty = 0, updated_at = now()
 where category = 'fnb' and deleted_at is null and stock_qty <> 0;

/* ── 驗證段（唯讀，一個字都不 raise —— 硬規則 1.8）────── */
do $$
declare v_msg text := ''; v_n int; v_t text;
begin
  select count(*) into v_n from products
   where category='fnb' and deleted_at is null and stock_qty <> 0;
  v_msg := v_msg || case when v_n=0
    then '① ✅ 32 項餐飲的庫存全是 0（沒有進貨紀錄就沒有結存）'
    else '① 🔴 還有 ' || v_n || ' 項不是 0' end;

  /* ② 🔴 正對照：這一份只該動 `stock_qty`。
        只驗「庫存變 0」的話，一份把整批商品刪掉的 SQL 也會全綠。 */
  select count(*) into v_n from products where category='fnb' and deleted_at is null;
  v_msg := v_msg || E'\n' || case when v_n=32
    then '② ✅ 32 項一個都沒少（正對照）' else '② 🔴 只剩 ' || v_n || ' 項' end;

  /* ③ 正對照之二：價格不可以被碰到。 */
  select string_agg(sku || ' $' || unit_price, ' · ' order by sku) into v_t
    from products where sku in ('FNB-MEAL-DUMP','FNB-DES-TOAST') and deleted_at is null;
  v_msg := v_msg || E'\n' || case when v_t = 'FNB-DES-TOAST $60 · FNB-MEAL-DUMP $80'
    then '③ ✅ 價格原封不動：' || v_t
    else '③ 🔴 價格被動到了：' || coalesce(v_t,'(找不到)') end;

  /* ④ 檯費那七支不在範圍內，確認沒有被誤傷。 */
  select count(*) into v_n from products
   where category='service' and is_system and deleted_at is null and not tracks_stock;
  v_msg := v_msg || E'\n' || case when v_n=7
    then '④ ✅ 檯費那七支沒被碰到（它們本來就不盤點）'
    else '④ 🔴 檯費變成 ' || v_n || ' 支不盤點' end;

  perform set_config('migi.chk', v_msg, true);
end $$;

select coalesce(nullif(current_setting('migi.chk', true), ''), '🔴 沒有訊息') as "驗證";
