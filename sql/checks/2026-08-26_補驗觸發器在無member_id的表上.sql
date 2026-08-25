/* ============================================================
   補驗：set_is_test_from_store() 在沒有 member_id 的表上安全嗎
   2026-08-26 · 交易內測試，會回滾，不留資料

   ── 為什麼要補這一次 ────────────────────────────────
   2026-08-26_測試標記也認會員.sql 的煙霧測試失敗了，
   但**失敗原因與改動無關**：
       null value in column "mode" of relation "table_sessions"
   —— 我的測試 insert 少給了必填欄位。

   ⚠ 那個失敗其實**反過來證明了要驗的事**：
     Postgres 的順序是「BEFORE INSERT 觸發器 → 約束檢查」。
     如果觸發器裡直接寫 NEW.member_id（table_sessions 沒有這欄），
     錯誤會是 `record "new" has no field "member_id"`，
     **由觸發器拋出，在 NOT NULL 檢查之前**。
     我們拿到的是 mode 的 NOT NULL → 觸發器已經跑完且沒拋錯。

   但那是**推論**不是直接證據，所以補一個乾淨的正向測試。
   ⚠ 同硬規則 7 的精神：看到它成功，不要靠「應該沒問題」。

   ── 這支會寫入嗎 ────────────────────────────────────
   會 insert，但**在同一個交易裡 raise 回滾**，執行完資料庫沒有變化。
   放 checks/ 而不是 pending/，因為它不改變任何 schema 或資料。

   ── 執行結果（2026-08-26）：✅ 通過，但回報是空白 ────────
   🔴 **`set_config(..., true)` 是交易內的，會被 savepoint 回滾。**
     這裡把成功訊息設在 `raise` **之前**，所以它跟 INSERT 一起被回滾掉了。
     先前幾支能正常回報，是因為 set_config 寫在 **exception 處理器裡面**
     （回滾之後才設）。

   ✅ **但那個空白本身就是證據**，三條路徑只有一條會留下空白：
     · insert 失敗（其他錯誤）→ 🔴 訊息（設在處理器裡，不會被回滾）
     · insert 成功 → raise → 回滾 → **空白**
     · DO 沒跑到 → 「🔴 DO 區塊沒執行」
     拿到空白 = 第二條 = **insert 成功 = 觸發器沒拋錯**。
     加上 ③ 場次總數 99 筆確認回滾乾淨。

   📌 **下次寫這種測試：訊息一律設在 exception 處理器裡**，
      不要設在成功路徑上再 raise。
      （成功路徑要回報的話，改用「不 raise、最後手動 rollback」——
        但 Supabase SQL Editor 沒有那個控制權，所以用處理器最實際。）
   ============================================================ */

do $$
declare
  v_store uuid;
  v_org   uuid;
  v_table uuid;
  v_test  boolean;
begin
  select s.id, s.org_id into v_store, v_org from stores s limit 1;
  select t.id into v_table from tables t where t.store_id = v_store limit 1;

  if v_table is null then
    perform set_config('migi.smoke2', '⚠ 跳過：找不到可用的桌', true);
    return;
  end if;

  begin
    /* ⚠ 這次把 mode 補上。若還有別的必填欄位，錯誤訊息會直接指出來，
       而下面第 ① 段列的清單可以對照。 */
    insert into table_sessions(org_id, store_id, table_id, status, open_method, mode)
    values (v_org, v_store, v_table, 'open', 'manual', 'matched')
    returning is_test into v_test;

    /* 走到這裡代表觸發器完整跑完了。
       七間門市目前都是 is_test = true，所以這裡應該是 true。
       ⚠ 驗的是「有沒有拋錯」，不是 true/false 對不對 ——
         table_sessions 沒有 member_id，會員那段本來就會被跳過。 */
    perform set_config('migi.smoke2',
      '✅ 插入成功、觸發器沒拋錯（is_test 算出 ' || v_test::text ||
      '，門市是測試所以應為 true）', true);

    raise exception 'rollback_on_purpose';
  exception
    when others then
      if sqlerrm = 'rollback_on_purpose' then
        null;   -- 已經在上面設好訊息了，這裡只是把資料回滾掉
      else
        perform set_config('migi.smoke2', '🔴 仍然失敗：' || sqlerrm, true);
      end if;
  end;
end $$;

select 序, 項目, 內容 from (

  /* ① table_sessions 的必填欄位（NOT NULL 且沒有預設）
        —— 這次少給 mode 就是因為沒先列出來。
        ⚠ 教訓：要 insert 一張不熟的表之前，先問它要什麼，
          不要一個一個試錯誤訊息。 */
  select 1 as 序, '① table_sessions 必填欄位' as 項目,
         string_agg(column_name || ' ' || data_type, '　' order by ordinal_position) as 內容
    from information_schema.columns
   where table_schema = 'public' and table_name = 'table_sessions'
     and is_nullable = 'NO' and column_default is null

  union all
  select 2, '② 補驗結果',
         coalesce(current_setting('migi.smoke2', true), '🔴 DO 區塊沒執行')

  union all
  /* ③ 確認真的回滾了 —— 場次數應該與跑之前一樣 */
  select 3, '③ 場次總數（應該沒變）',
         count(*)::text || ' 筆'
    from table_sessions

) x order by 序, 項目;
