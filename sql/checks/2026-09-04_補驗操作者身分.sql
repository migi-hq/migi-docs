/* ============================================================
   補驗：14 支營運函式的操作者身分真的從 JWT 取了嗎
   2026-09-04 · MIGI · 寫入會回滾

   ── 為什麼要補驗 ──────────────────────────────────────
   `2026-09-04_操作者身分改從JWT取.sql` 的 ④⑤ 是紅的，
   而 **DDL 是對的，錯的是驗證段查錯欄位**：
   ```sql
   insert into table_sessions(..., opened_by_staff_id, promoted_by_staff_id, ...)
   values                    (..., p_staff_id,         p_staff_id,          ...)
   ```
   ⇒ 它寫的是 **`opened_by_staff_id`**，我卻去查 `updated_by`
     —— **那個欄位 `open_session_tx` 從來不寫**。

   🔴 **這是硬規則 3.56 的完美案例**：紅了的時候我一路懷疑
     身分解析、懷疑插入位置、甚至寫了一支診斷 SQL 去拆 `current_staff()`
     ——**而那支診斷全綠**（⑪ 印出「咖勁凱（owner）」）。
     真正的錯在**期望值**：我猜了欄位名。

   📌 順帶更正一句 CLAUDE.md 的敘述：
     「`table_sessions` 98/98 的 `updated_by` 全是 null」——**那句沒錯**，
     但它**不是 `p_staff_id` 該去的地方**。開桌的操作者一直都記在
     `opened_by_staff_id`，而它在此之前也全是 null（因為 POS 送 null）。

   ── ⚠ 不要重跑那份 SQL ──────────────────────────────
   DDL 已經生效（14 支都插入了那一行）。**重跑會再插一行**，
   而 guard ②「只能插一次」會擋下並整份回滾 —— 那是它正確運作，
   但也表示那份是**一次性**的。所以驗證獨立成這一支。
   ============================================================ */

do $$
declare
  v_out text := '';
  v_org uuid := '11111111-1111-1111-1111-111111111111';
  v_line text; v_store uuid; v_table uuid; v_table2 uuid;
  v_by uuid; v_r jsonb; v_fake constant uuid := '99999999-9999-9999-9999-999999999999';
begin
  begin
    select m.line_user_id into v_line
      from members m join staff s on s.member_id = m.id
     where m.line_user_id is not null and s.deleted_at is null and m.deleted_at is null
     limit 1;

    /* 🔴 **要兩張都沒有 open session 的桌**：`uq_sessions_open_table`
       是部分索引，同一張桌不能有兩個 open。 */
    select id into v_store from stores where org_id = v_org limit 1;
    select t.id into v_table from tables t
     where t.store_id = v_store
       and not exists (select 1 from table_sessions s
                        where s.table_id = t.id and s.status = 'open' and s.deleted_at is null)
     limit 1;
    select t.id into v_table2 from tables t
     where t.store_id = v_store and t.id <> v_table
       and not exists (select 1 from table_sessions s
                        where s.table_id = t.id and s.status = 'open' and s.deleted_at is null)
     limit 1;

    if v_line is null or v_table is null or v_table2 is null then
      /* ⚠ 找不到樣本要**出聲**，不要安靜跳過（上一份的 ⑦⑧ 就是這樣漏掉的）。 */
      perform set_config('migi.v', E'🔴 **沒驗到**\t找不到有 staff 的 LINE 會員，或空桌不足兩張', true);
      return;
    end if;

    ---- ① 🎯 有身分時：假的 staff_id 被忽略 --------------
    /* 🔴 **這一格才是整件事的重點**：不是「函式改了嗎」，
       是「**假造的值真的被丟掉了嗎**」。
       刻意送全 9 的假 id —— 它出現在資料裡就代表覆寫沒生效。 */
    perform set_config('request.jwt.claims',
      '{"sub":' || to_json(v_line)::text || '}', true);
    v_r := public.open_session_tx(v_table, 'matched', null, 3, null,
            v_fake, 'manual', null, '台麻', '無花');
    select opened_by_staff_id into v_by
      from table_sessions where id = (v_r ->> 'session_id')::uuid;

    v_out := v_out || E'\n' || '① 🎯 送假的 staff_id 會被忽略' || E'\t' ||
      case when v_by = v_fake then '🔴 假的被寫進去了 —— 覆寫沒生效'
           when v_by is null then '🔴 變成 null —— 身分沒解析出來'
           else '✅ 忽略了' end;

    v_out := v_out || E'\n' || '② 🎯 記到的是**解析出來的**那個人' || E'\t' ||
      coalesce((select '✅ ' || s.name || '（' || s.role || '）'
                  from staff s where s.id = v_by), '🔴 對不到 staff');

    /* ③ 兩個欄位都要對 —— `promoted_by_staff_id` 也吃同一個值。 */
    v_out := v_out || E'\n' || '③ promoted_by_staff_id 也一樣' || E'\t' ||
      (select case when promoted_by_staff_id = v_by then '✅ 一致'
                   else '🔴 ' || coalesce(promoted_by_staff_id::text, 'null') end
         from table_sessions where id = (v_r ->> 'session_id')::uuid);

    ---- ④ 🔴 正對照：沒有身分時是 null，不報錯 -----------
    /* 那 14 支裡有些**會員 App 也會叫** —— 改成「必須是店員」的話
       會員儲值會當場壞掉。這一格就是那道守衛。 */
    perform set_config('request.jwt.claims', '{"sub":"U_not_a_staff_000000000000000"}', true);
    begin
      v_r := public.open_session_tx(v_table2, 'matched', null, 3, null,
              v_fake, 'manual', null, '台麻', '無花');
      select opened_by_staff_id into v_by
        from table_sessions where id = (v_r ->> 'session_id')::uuid;
      v_out := v_out || E'\n' || '④ 🎯 正對照：沒有 staff 身分 → null，不報錯' || E'\t' ||
        case when v_by is null then '✅ null（會員 App 那條路不會壞）'
             when v_by = v_fake then '🔴 假的被寫進去了'
             else '🔴 竟然有值：' || v_by::text end;
    exception when others then
      v_out := v_out || E'\n' || '④ 🎯 正對照：沒有 staff 身分' || E'\t' ||
        '🔴 **報錯了** —— 會員 App 會壞：' || sqlerrm;
    end;

    ---- ⑤ 歷史資料（純觀察）-----------------------------
    /* 🔴 **這個數字包含「這次測試剛開的那一張」** —— 它是在交易內算的。
       2026-09-04 第一次跑印出 `1 / 110`，而回滾之後線上其實是 `0 / 110`。
       ⚠ 那不是 bug，但看到的人會以為線上已經有一筆真實紀錄了。
       🎯 所以扣掉自己造的：**只算這次交易之前就存在的**。 */
    perform set_config('request.jwt.claims', '', true);
    v_out := v_out || E'\n' || '⑤ 📌 這次之前就存在的 opened_by_staff_id' || E'\t' ||
      (select count(*) filter (where opened_by_staff_id is not null
                                 and created_at < now() - interval '1 minute')::text
              || ' / ' || count(*) filter (where created_at < now() - interval '1 minute')::text
              || '　（改之前 POS 送 null，所以歷史全是 null 是正常的）'
         from table_sessions);

    raise exception 'migi_rollback';
  exception when others then
    if sqlerrm <> 'migi_rollback' then
      v_out := v_out || E'\n' || '🔴 測試自己炸了' || E'\t' || sqlerrm;
    end if;
    perform set_config('migi.v', v_out, true);
  end;
end $$;

select split_part(x, E'\t', 1) as 測試,
       split_part(x, E'\t', 2) as 結果
  from unnest(string_to_array(current_setting('migi.v', true), E'\n')) as x
 where coalesce(x,'') <> '';
