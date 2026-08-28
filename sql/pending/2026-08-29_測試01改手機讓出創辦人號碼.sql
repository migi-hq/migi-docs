/* ============================================================
   測試01 改手機，把 0910768736 讓給創辦人本人
   2026-08-29

   ── 為什麼 ──────────────────────────────────────────
   `0910768736` 是**創辦人本人的號碼**，但它目前掛在測試帳號
   `d73fdac2-…`（暱稱「測試測試測試測試測試測試」，`is_test = true`）上。

   🔴 如果不動它，創辦人用 LINE 註冊會走 `rebound` ——
     綁到那個測試帳號上，於是他的「真實會員歷史」會**繼承 70 筆測試訂單
     與 3,580 點測試餘額**。那些數字之後會出現在他的消費紀錄、
     累積消費、會員分級門檻裡。

   ⚠ 這是使用者發現的，我原本的建議是「就這樣綁，反正保住既有資料」——
     **那正好是把測試資料變成營運資料**，方向剛好相反。

   → 把測試01 的手機改成 `0910000001`（與測試02/03/04 同一個系列），
     讓 `0910768736` 空出來。創辦人註冊時就會走 `created` 建立**乾淨的新會員**。

   ── 這支不會動到什麼 ────────────────────────────────
   訂單與錢包掛的是 `member_id` **不是 phone**，所以測試01 的
   70 筆訂單與 3,580 餘額原封不動 —— 它仍然是完整的測試帳號。

   ── 查證過的約束（不猜）────────────────────────────
     uq_members_phone  UNIQUE (org_id, phone) WHERE phone IS NOT NULL AND deleted_at IS NULL
     members_phone_chk CHECK (phone IS NULL OR phone = migi_norm_phone(phone))
   `0910000001` 目前沒有人使用，且符合 `^09\d{8}$`。
   ============================================================ */

do $$
declare
  v_member uuid := 'd73fdac2-d6b9-4b8a-bcff-b19c2786056f';
  v_new    text := '0910000001';
  v_n int;
  v_msg text;
begin
  if exists (select 1 from members
              where phone = v_new and deleted_at is null and id <> v_member) then
    raise exception '% 已經被別人使用，先查 select display_name from members where phone = %',
      v_new, v_new;
  end if;

  /* ⚠ 條件寫死舊號碼：如果它已經被改過，這支應該什麼都不做，
     而不是把一個不知道現在是什麼的號碼再蓋一次。 */
  update members
     set phone = v_new,
         updated_at = now()
   where id = v_member
     and phone = '0910768736'
     and deleted_at is null;

  get diagnostics v_n = row_count;

  if v_n = 1 then
    v_msg := '✅ 測試01 的手機已改為 ' || v_new;
  else
    -- 看 row_count，不要無條件回報成功
    select '⚠ 沒有更新任何列 —— 它現在的手機是 ' || coalesce(phone, 'null')
      into v_msg from members where id = v_member;
  end if;

  perform set_config('migi.ph', v_msg, false);
end $$;


/* ── 正對照（硬規則 3.55）────────────────────────────
   只驗「手機改掉了」是不夠的 —— 真正要證明的是
   **創辦人現在用 0910768736 註冊會走 `created` 而不是 `rebound`**。
   在交易內實際呼叫一次，然後回滾。
   ⚠ 這一段不會留下任何資料。 */
do $$
declare
  v_org uuid := '11111111-1111-1111-1111-111111111111';
  r jsonb;
  v_msg text := '';
begin
  begin
    r := register_member_tx(v_org, '創辦人正對照', '0910768736');
    v_msg := '用 0910768736 註冊 → action=' || coalesce(r ->> 'action', '?')
          || case when (r ->> 'action') = 'created'
                  then '　✅ 會建立新會員（不再綁到測試01）'
                  when (r ->> 'action') = 'existing_phone'
                  then '　🔴 還是綁到既有帳號 —— 手機沒改成功'
                  else '　⚠ 非預期' end;
    raise exception 'rollback_on_purpose';
  exception
    when others then
      /* 硬規則 3.9：訊息一律設在處理器裡 ——
         set_config(..., true) 是交易內設定，寫在 raise 之前會跟著被回滾。 */
      if sqlerrm = 'rollback_on_purpose' then
        perform set_config('migi.ctrl', v_msg, true);
      else
        perform set_config('migi.ctrl', '🔴 正對照拋錯：' || sqlerrm, true);
      end if;
  end;
end $$;


/* ============================================================
   驗證（單一 SELECT）

   ── 該看到什麼 ──────────────────────────────────────
   ① ✅ 手機已改
   ② 四個測試帳號的手機變成 0910000001~0910000004（整齊的一組）
   ③ 🎯 **正對照**：用 0910768736 註冊會回 `created`
      —— 那才是「創辦人會拿到乾淨新帳號」的證據
   ④ 測試01 的訂單與餘額沒被動到（改手機不該影響它們）
   ⑤ 會員數仍是 4（正對照有回滾乾淨）
   ============================================================ */
select 序, 項目, 內容 from (

  select 1 as 序, '① 改手機的結果' as 項目,
         coalesce(current_setting('migi.ph', true), '🔴 DO 區塊沒執行') as 內容

  union all
  select 2, '② 現有會員的手機',
         (select string_agg(display_name || '　' || coalesce(phone, '無') ||
                            '　is_test=' || is_test::text, E'\n' order by phone)
            from members where deleted_at is null)

  union all
  select 3, '③ 🎯 正對照：創辦人用 0910768736 註冊會走哪條路',
         coalesce(current_setting('migi.ctrl', true), '🔴 正對照沒執行')

  union all
  select 4, '④ 測試01 的訂單與餘額（不該被動到）',
         (select '訂單 ' || (select count(*) from orders o where o.member_id = m.id)::text ||
                 ' 筆　餘額 ' || coalesce((select balance::text from wallets w where w.member_id = m.id), '無')
            from members m where m.id = 'd73fdac2-d6b9-4b8a-bcff-b19c2786056f')

  union all
  select 5, '⑤ 會員數（確認正對照回滾乾淨，應為 4）',
         (select count(*)::text || ' 位' from members where deleted_at is null)

) x order by 序;
