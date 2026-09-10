/* ============================================================
   消費明細與收據帶上品項規格
   2026-09-11 · 待辦 44 的延伸

   ── 🔴 動手前查到一件事，它改變了這份的範圍 ────────────
   有**兩支**函式各自組品項清單，而那一段是**逐字相同的**：
   ```
   _member_orders_core            ← pos_member_orders_tx ＋ get_my_orders_tx 共用
   get_session_member_orders_tx   ← POS 的桌帳收據，**沒有共用 core**
   ```
   兩邊都寫著
   `'name', i.name, 'revenue_type', i.revenue_type, 'qty', i.qty, …`
   —— **同一個東西兩份定義**，而這正是它會漂的證據：
   只改 core 的話，會員 App 看得到規格、**櫃檯的收據看不到**，
   而那不會報錯。
   ⇒ 所以這份**兩支一起改**，而且用同一個樣式跑迴圈，不是抄兩遍。

   ⏳ **真正的修法是把收據那支也改成呼叫 core**，但那是另一批：
     兩支的其他部分不同（一支吃 session、一支吃分頁游標），
     合併要逐行對照。**先讓它們不漂，再談合併。**

   ── 🔴 今天真正會顯示規格的只有一個地方：POS 的收據 ──
   查了三個呼叫點的前端才確定，而我原本以為是兩個：
   ```
   POS 收據 OrderDetail          ✅ **逐列印品項** ← 只有這裡看得到
   POS 會員查詢「最近消費」        ⚪ 摘要一行：items[0].name ＋「等 N 項」
   會員 App 消費明細              ⚪ 摘要一行，**寫法與 POS 那一支逐字相同**
   ```
   ⚠ 所以 `_member_orders_core` 這一半**今天沒有讀者**。
     那仍然要改，理由不是「日後會用到」，是**兩份定義不可以分岔**：
     只改收據的話，這兩段逐字相同的程式碼就開始不一樣了，
     而下一個人不會知道哪一份才是對的。
   🎯 判準是成本：多回一個鍵是**同一個 join、同一列資料**，
     不是建一個沒有人讀的機制。
   📌 會員 App 要真的列出品項是另一件事（那要一個展開明細的 UI），
     **不在這一批**。

   ── ⚠ 舊訂單會是 null，而那是對的 ──────────────────
   `order_items.spec` 是 2026-09-10 才建的，既有 224 筆全是 null ——
   **它們成立時這個欄位還不存在**，不是資料壞了。
   ⇒ 前端一律「有才畫」，沒有就不留空行。

   ── raise 的分工（硬規則 1.8）────────────────────────
   · **DDL 段的 guard 可以 raise** —— 有一支換不到就整份回滾，
     不要留下「一支有規格一支沒有」的半套狀態（那正是這份要修的病）。
   · **驗證段一個字都不准 raise** —— 那會把 DDL 一起丟掉而且全綠。
   ============================================================ */

/* ── ① 兩支一起換，同一個樣式 ────────────────────────
   ⚠ 兩支的全文各約 5.8KB 而這次只動一個 build_object，
     所以換字串而不是撈全文重建（CLAUDE.md：**要改三處以上才撈全文**）。
   ✅ 樣式唯一性事先查過：`'name', i.name` 在兩支的全文中**各出現 1 次**。
   🔴 **先把 oid 收進陣列再迴圈** —— 直接 `for … in select … from pg_proc`
     然後在圈內 `execute` DDL，等於一邊讀一邊改同一張系統表，
     而 plpgsql 不保證那個結果集已經物化。 */
do $mig$
declare
  v_oids oid[];
  v_oid  oid;
  v_def  text;
  v_new  text;
  v_name text;
begin
  select array_agg(p.oid) into v_oids
    from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
     and p.proname in ('_member_orders_core', 'get_session_member_orders_tx');

  if coalesce(array_length(v_oids, 1), 0) <> 2 then
    raise exception '🔴 應該找到 2 支，實際 % 支 —— 先查線上有什麼再改',
      coalesce(array_length(v_oids, 1), 0);
  end if;

  foreach v_oid in array v_oids loop
    v_name := v_oid::regproc::text;
    v_def  := pg_get_functiondef(v_oid);

    v_new := replace(v_def,
      '''name'', i.name, ''revenue_type'', i.revenue_type,',
      '''name'', i.name, ''spec'', i.spec, ''revenue_type'', i.revenue_type,');

    if position('''spec'', i.spec' in v_new) = 0 then
      raise exception '🔴 % 沒換到 —— 線上版本與預期不同，先撈全文對照再改', v_name;
    end if;

    execute v_new;
  end loop;
end $mig$;

/* ── 驗證段（唯讀，一個字都不 raise）──────────────────── */
do $$
declare v_msg text := ''; v_n int; v_t text; v_j jsonb; v_mid uuid; v_sid uuid;
begin
  select count(*) into v_n from pg_proc p
   where p.pronamespace='public'::regnamespace and p.prokind='f'
     and p.proname in ('_member_orders_core','get_session_member_orders_tx')
     and position('''spec'', i.spec' in pg_get_functiondef(p.oid)) > 0;
  v_msg := v_msg || case when v_n=2
    then '① ✅ 兩支都會回 spec 了（明細用的 core ＋ 收據）'
    else '① 🔴 只有 ' || v_n || ' 支換到 —— 半套比沒做更糟' end;

  /* ② 正對照：這一份**不該**動到那兩支包裝。
        只驗「core 改了」的話，一份順手把包裝改壞的 SQL 也會變綠。 */
  select count(*) into v_n from pg_proc p
   where p.pronamespace='public'::regnamespace and p.prokind='f'
     and p.proname in ('pos_member_orders_tx','get_my_orders_tx')
     and position('_member_orders_core' in pg_get_functiondef(p.oid)) > 0;
  v_msg := v_msg || E'\n' || case when v_n=2
    then '② ✅ 兩支包裝都還在叫 core（POS 會員查詢 ＋ 會員 App）'
    else '② 🔴 只剩 ' || v_n || ' 支在叫它' end;

  /* ③ 🔴 真的執行一次看回傳（硬規則 7：跑過並看到回傳才算完成）。
        只讀函式定義的話，一支語法對但欄位名錯的函式也會讓 ① 變綠 ——
        `CREATE FUNCTION` 不檢查函式體裡的欄位存不存在。 */
  select o.member_id into v_mid
    from orders o join order_items i on i.order_id = o.id
   where o.status='paid' and o.member_id is not null
   order by o.paid_at desc nulls last limit 1;

  if v_mid is null then
    v_msg := v_msg || E'\n' || '③ ⚪ 找不到有品項的已付訂單 —— 這一格測不了（不是通過）';
  else
    v_j := public._member_orders_core(v_mid, 1, null);
    v_t := (v_j #> '{orders,0,items,0}')::text;
    v_msg := v_msg || E'\n' || case
      when v_t is null then '③ 🔴 叫得動但沒有品項回來'
      when v_t like '%"spec"%'
        then '③ ✅ 實際叫一次 core，品項裡有 spec 鍵：' || left(v_t, 100)
      else '③ 🔴 回傳裡沒有 spec 鍵：' || left(v_t, 100) end;
  end if;

  /* ④ 收據那支也真的叫一次 —— 它是**另一份定義**，不能靠 ③ 代言。 */
  select o.session_id, o.member_id into v_sid, v_mid
    from orders o join order_items i on i.order_id = o.id
   where o.status='paid' and o.session_id is not null and o.member_id is not null
   order by o.paid_at desc nulls last limit 1;

  if v_sid is null then
    v_msg := v_msg || E'\n' || '④ ⚪ 找不到有場次的已付訂單 —— 這一格測不了（不是通過）';
  else
    v_j := public.get_session_member_orders_tx(v_sid, v_mid);
    v_t := (v_j #> '{orders,0,items,0}')::text;
    v_msg := v_msg || E'\n' || case
      when v_t is null then '④ 🔴 叫得動但沒有品項回來'
      when v_t like '%"spec"%'
        then '④ ✅ 實際叫一次收據，品項裡有 spec 鍵：' || left(v_t, 100)
      else '④ 🔴 回傳裡沒有 spec 鍵：' || left(v_t, 100) end;
  end if;

  /* ⑤ 舊訂單的 spec 應該全是 null —— 它們成立時這個欄位還不存在。
        ⚠ 這一格若變紅，代表有人回填了歷史快照，那比缺資料更糟。 */
  select count(*) into v_n from order_items where spec is not null;
  v_msg := v_msg || E'\n' || case when v_n=0
    then '⑤ ✅ 既有品項的 spec 全是 null（沒有被回填汙染）'
    else '⑤ ⚠ 有 ' || v_n || ' 筆已經有 spec —— 若是這之後結的新單就是正常的' end;

  perform set_config('migi.chk', v_msg, true);
end $$;

select coalesce(nullif(current_setting('migi.chk', true), ''), '🔴 沒有訊息') as "驗證";
