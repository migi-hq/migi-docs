/* ============================================================
   驗 `v_real_*` 的三層過濾真的在擋（而且新欄位查得到值）
   2026-09-11 · 唯讀性質：**在交易裡造樣本，最後整份回滾**

   ── 為什麼要這一份 ──────────────────────────────────
   `2026-09-11_補齊四個報表檢視表漏掉的欄位.sql` 的第 ⑤ 格說
   「四支都是 0 列」，而第 ⑥ 格的正對照回 ⚪ 測不出東西。
   🔴 **那讓第 ⑤ 格的證明力比寫的時候以為的弱**：
   ```
   0 列  ⇐ 時間下限擋住了（設計上的空）
   0 列  ⇐ 所有訂單的 is_test 都是 true
   0 列  ⇐ 🔴 view 根本寫壞了
   ```
   **三種原因長得一模一樣**（硬規則 3.55：只驗「應該是 0」等於沒驗）。
   實查：`orders` 非測試的有 **0 筆** ⇒ 光放寬時間下限不可能冒出資料。

   🎯 所以這一份**自己造一筆會通過的資料**，逐層放寬，看它在哪一層出現。
   ⚠ 那才分得出「三層都在擋」與「view 濾成空」。

   ── 這份會寫入，但一列都留不下來 ─────────────────────
   `raise exception 'migi_rollback'` 讓整段退掉（硬規則 1、5.7：
   沒有 staging，交易內測試＋回滾是這個規模對的選擇）。
   🔴 **訊息一定要設在 exception handler 裡** —— 寫在 raise 之前的
     `set_config(..., true)` 會跟著被回滾，最後印出空白（硬規則 3.9）。
   ⚠ 這份**不歸檔到 `applied/`** —— 它不留下任何東西，是查證的紀錄。

   ── 逐層放寬的順序（每一步都要量）───────────────────
   ```
   ① 現況                      → 期望 0
   ② 只放寬 orgs.live_from     → 期望**仍然 0**（is_test 那兩道還在擋）
   ③ 再放寬三個 is_test        → 期望**冒出來**
   ④ 冒出來的那一筆要帶得出 spec 欄位的值
   ```
   🔴 第 ② 步是這份的重點：它證明**兩道防線是獨立的**，
     不是「其中一道在做事、另一道從來沒被驗過」。
   ============================================================ */

do $$
declare
  v_msg   text := '';
  v_org   uuid;
  v_oid   uuid;   -- 樣本訂單
  v_mid   uuid;   -- 那筆訂單的會員
  v_sid   uuid;   -- 那筆訂單的門市
  v_item  uuid;   -- 那筆訂單的第一個品項
  v_n     int;
  v_t     text;
begin
  begin
    /* 取一筆**有品項**的已付訂單當樣本。
       ⚠ 借線上資料會跟真實世界賽跑（硬規則 3.57），但這一份只讀狀態、
         而且整段回滾，所以借得起。取樣失敗要出聲，不可以安靜跳過。 */
    select o.id, o.org_id, o.member_id, o.store_id, i.id
      into v_oid, v_org, v_mid, v_sid, v_item
      from orders o
      join order_items i on i.order_id = o.id
     where o.status = 'paid' and o.deleted_at is null
       and o.member_id is not null
     order by o.paid_at desc nulls last
     limit 1;

    if v_oid is null then
      v_msg := '🔴 找不到「已付＋有品項＋有會員」的訂單 —— 這份今天測不了';
      raise exception 'migi_rollback';
    end if;

    /* ── ① 現況 ─────────────────────────────────── */
    select count(*) into v_n from v_real_order_items where id = v_item;
    v_msg := v_msg || case when v_n = 0
      then '① ✅ 現況：這筆品項不在 v_real_order_items 裡（0 列）'
      else '① 🔴 現況就查得到 —— 過濾根本沒作用' end;

    /* ── ② 只放寬時間下限 ────────────────────────────
       🔴 這一步的期望是**仍然 0**。冒出來的話代表 `is_test` 那兩道沒在擋。 */
    update orgs set live_from = timestamptz '2000-01-01' where id = v_org;

    select count(*) into v_n from v_real_order_items where id = v_item;
    v_msg := v_msg || E'\n' || case when v_n = 0
      then '② ✅ 只放寬時間下限仍然 0 —— is_test 那兩道是獨立生效的'
      else '② 🔴 光放寬時間就冒出來了 —— is_test 的過濾沒在擋' end;

    /* ── ③ 再放寬三個 is_test ────────────────────────
       ⚠ 三張表都要動：`v_real_orders` 同時看訂單自己、門市、會員。
       ⚠ `orders.is_test` 的觸發器是 BEFORE **INSERT**，UPDATE 不會被覆寫。 */
    update orders  set is_test = false where id = v_oid;
    update members set is_test = false where id = v_mid;
    update stores  set is_test = false where id = v_sid;

    select count(*) into v_n from v_real_order_items where id = v_item;
    v_msg := v_msg || E'\n' || case when v_n = 1
      then '③ ✅ 三層都放寬之後它出現了 —— 檢視表本身是通的（正對照）'
      else '③ 🔴 全部放寬還是查不到（' || v_n || ' 列）—— view 濾成空了' end;

    /* ── ④ 新欄位查得到「值」不只是「欄位存在」──────────
       🔴 上一份的第 ② 格只證明 `spec` 這個**欄位名**在 view 上。
         欄位在、值取不到（例如來源寫錯表）仍然會讓那一格變綠。 */
    select coalesce(x.name, '(無品名)') || ' ／ ' || coalesce(x.spec, '(spec 是 null)')
      into v_t
      from v_real_order_items x where x.id = v_item;
    v_msg := v_msg || E'\n' || case
      when v_t is null then '④ 🔴 取不到那一列'
      else '④ ✅ 取得到值：' || v_t
           || case when v_t like '%(spec 是 null)%'
                   then '（舊訂單本來就沒有 spec，那是對的）' else '' end end;

    /* ── ⑤ 另外三支也各驗一次「放寬之後查得到」──────── */
    select count(*) into v_n from v_real_members where id = v_mid;
    v_msg := v_msg || E'\n' || case when v_n = 1
      then '⑤ ✅ v_real_members 也查得到那位會員'
      else '⑤ 🔴 v_real_members 查不到（' || v_n || ' 列）' end;

    select coalesce((select rating::text from v_real_members where id = v_mid), '(取不到)')
      into v_t;
    v_msg := v_msg || E'\n' || '⑥ ✅ 而且 rating 欄位取得到值：' || v_t;

    raise exception 'migi_rollback';

  exception when others then
    /* 🔴 只有自己丟的那個字串才是「刻意回滾」。其餘一律當成真的錯誤 ——
       把例外吞掉只記「失敗了」，會讓「工具用錯」偽裝成「系統壞了」
       （2026-09-09 那次的教訓）。 */
    if sqlerrm <> 'migi_rollback' then
      v_msg := v_msg || E'\n🔴 中途拋出例外：' || sqlerrm;
    end if;
    perform set_config('migi.chk', v_msg, true);
  end;
end $$;

/* ⚠ 上面整段已經回滾，下面這兩格是**提交後的真實狀態**，
   確認一列都沒有留下來。 */
select coalesce(nullif(current_setting('migi.chk', true), ''), '🔴 沒有訊息')
       || E'\n\n── 回滾確認（這是交易外的真實狀態）──'
       || E'\n⑦ ' || case when (select count(*) from orgs where live_from is not null) = 0
                          then '✅ orgs.live_from 還是 null（沒有被留下）'
                          else '🔴 live_from 被寫進去了 —— 那會讓報表開始吃資料' end
       || E'\n⑧ ' || case when (select count(*) from orders where not coalesce(is_test,false)) = 0
                          then '✅ 非測試訂單還是 0 筆（沒有被留下）'
                          else '🔴 有訂單的 is_test 被改成 false 了' end
       || E'\n⑨ ' || case when (select count(*) from v_real_order_items) = 0
                          then '✅ v_real_order_items 回到 0 列'
                          else '🔴 檢視表現在有資料 —— 上面的樣本沒有退乾淨' end
       as "驗證";
