/* ============================================================
   補驗：價格改查主檔之後，實際記下的是什麼
   2026-08-27 · 交易內測試，會回滾，不留資料

   ── 為什麼要補 ──────────────────────────────────────
   `2026-08-27_價格一律查主檔.sql` 的 ③ 失敗了，
   但**失敗原因與改動無關**：
       new row for "order_payments" violates check "cash_fields_only_for_cash"
   我的測試付款只送了 `method` 與 `amount`，沒送現金欄位。

   🎯 **而失敗的位置本身就是證據**：
     `order_payments` 的插入是 checkout_tx 的第 10 步，
     「收款金額與應付不符」的檢查是第 6 步。
     若它還在讀前端送的 unit_price = 1，第 6 步就會拋
     「收款金額 60 與尚需支付 1 不符」—— 根本走不到第 10 步。
   ⚠ 但那是**推論**。硬規則 7 要的是看到它動，所以補這一次。

   ── 這次的做法（同 2026-08-26 補驗牌咖那次）────────
   不猜約束在管什麼 —— **先把定義整條印出來**（硬規則 3.8），
   再用符合它的資料重跑。
   ============================================================ */

do $$
declare
  v_m uuid; v_st uuid; v_org uuid;
  v_pid uuid; v_price bigint; v_pname text; v_ptype text;
  v_res jsonb; v_msg text;
  r_name text; r_price bigint; r_type text;
begin
  select w.member_id into v_m
    from wallets w join members m on m.id = w.member_id
   where m.deleted_at is null
   limit 1;
  select s.id, s.org_id into v_st, v_org from stores s limit 1;
  select p.id, p.unit_price, p.name, p.revenue_type
    into v_pid, v_price, v_pname, v_ptype
    from products p
   where p.org_id = v_org and p.deleted_at is null
     and p.unit_price > 0 and p.revenue_type = 'fnb' and p.discountable
   limit 1;

  if v_m is null or v_st is null or v_pid is null then
    perform set_config('migi.px2', '⚠ 跳過：缺會員錢包／門市／可折扣的 fnb 商品', true);
    return;
  end if;

  begin
    v_res := checkout_tx(
      v_m, v_st,
      jsonb_build_array(jsonb_build_object(
        'product_id',   v_pid,
        'name',         '前端亂寫的名字',   -- ★ 故意
        'revenue_type', 'other',            -- ★ 故意送錯桶
        'qty',          1,
        'unit_price',   1)),                -- ★ 故意送 1 元
      null, 0,
      /* ★ 這次補上現金欄位：收多少、找多少。
         付款金額仍然送**主檔價** —— 舊版會在第 6 步就因
         「收款金額不符」失敗，走不到這裡。 */
      jsonb_build_array(jsonb_build_object(
        'method',        'cash',
        'amount',        v_price,
        'cash_received', v_price,
        'change_given',  0)),
      'migi-price-test2-' || gen_random_uuid()::text, null);

    select oi.name, oi.unit_price, oi.revenue_type
      into r_name, r_price, r_type
      from order_items oi
     where oi.order_id = (v_res ->> 'order_id')::uuid
     limit 1;

    v_msg := case
      when r_price = v_price and r_name = v_pname and r_type = v_ptype
        then '✅ 記下的是主檔的值：「' || r_name || '」　$' || r_price::text ||
             '　' || r_type ||
             E'\n   （前端送的是「前端亂寫的名字」／other／$1，全部被忽略）' ||
             E'\n   應付=' || (v_res ->> 'payable') ||
             '　小計=' || (v_res ->> 'subtotal')
      else '🔴 仍採信前端：name=' || coalesce(r_name,'null') ||
           '　price=' || coalesce(r_price::text,'null') ||
           '　type=' || coalesce(r_type,'null')
      end;
    raise exception 'rollback_on_purpose';
  exception
    when others then
      /* ⚠ 硬規則 3.9：訊息一律設在處理器裡。
         寫在 raise 之前的 set_config(..., true) 會跟著被回滾，印出空白。 */
      if sqlerrm = 'rollback_on_purpose' then
        perform set_config('migi.px2', v_msg, true);
      else
        perform set_config('migi.px2', '🔴 測試拋錯：' || sqlerrm, true);
      end if;
  end;
end $$;

select 序, 項目, 內容 from (

  /* ① order_payments 的每一條 CHECK 整條印出來。
        ⚠ 硬規則 3.8：錯誤訊息只給名字不給定義，
          看到 xxx_check 就推論它在管什麼，那是猜。
        ⚠ 這份留檔的價值不只這次 —— 日後要寫任何付款相關的測試都會用到。 */
  select 1 as 序, '① order_payments 的 CHECK' as 項目,
         coalesce(string_agg(c.conname || '　' || pg_get_constraintdef(c.oid), E'\n'),
                  '（沒有 CHECK）') as 內容
    from pg_constraint c
    join pg_class t on t.oid = c.conrelid
   where t.relnamespace = 'public'::regnamespace
     and t.relname = 'order_payments' and c.contype = 'c'

  union all
  /* ② 實測結果。 */
  select 2, '② 實測：故意送錯的價格/名稱/桶',
         coalesce(current_setting('migi.px2', true), '🔴 DO 區塊沒執行')

  union all
  /* ③ 確認回滾乾淨（跑之前是 153 張）。 */
  select 3, '③ 訂單數', (select count(*)::text || ' 張' from orders)

) x order by 序, 項目;
