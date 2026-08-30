/* ============================================================
   補蓋創辦人的手機驗證章　　2026-08-30 · MIGI 咪吉麻將

   ── 為什麼要手動補 ──────────────────────────────────
   `members.phone_verified_at` 從今天才開始有人寫（`otp_consume_tx`），
   而創辦人的帳號是在那之前建立的 —— 所以他明明控制那支號碼，
   資料庫裡卻是 `null`。

   後果很具體：他日後換 LINE 帳號想自助認領時，
   `claim_member_by_phone_tx` 會走到「未驗 ＋ 有價值 → `staff_required`」
   那一格，而**店員工具還不存在**（待辦 20 卡在店員登入）。
   ⇒ 那時他會完全救不回來。

   ── 🔴 這一支是一次性的回填，不是一個可以重複使用的工具 ────
   手動蓋章等於**宣稱一件沒有被簡訊證明過的事**。
   它在這裡成立，只因為那支號碼是創辦人本人的、而且是他自己要求的。

   ⚠ **不要把它變成慣例。** 只要有第二個帳號用這種方式蓋章，
     「驗過的手機」這個保證就不再是保證，
     而**整個自助認領的分級是建立在那個保證上面的**。
     → 日後別人要補，正確的路是**走一次換手機流程**（驗自己的號碼），
       那會由 `otp_consume_tx` 自動蓋章。

   ── ⚠ 四個測試帳號刻意不蓋 ──────────────────────────
   `0910000001`～`0910000004` 是**沒有人收得到簡訊的號碼**。
   蓋上去就是寫一句假話，而且它們保持 `null` 反而有用 ——
   那是「未驗 ＋ 有價值 → staff_required」現成的測試資料。
   ============================================================ */

do $$
declare v_n int; v_id uuid;
begin
  /* 🔴 先數再改。`0910768736` 應該只對應一個會員 ——
     不是的話代表狀況跟我以為的不一樣，這時**不要動**。
     （`uq_members_phone` 保證同 org 內唯一，但這一行是**便宜的第二道**：
      它同時擋掉「一列都沒有」，而那才是我真正該怕的 ——
      `update ... where` 沒中會靜靜地什麼都不做，同 `register_member_tx`
      那次謊報成功。） */
  /* ⚠ **不要寫 `min(id)`** —— uuid 沒有 min 聚合，會拋
     `42883: function min(uuid) does not exist`（2026-08-30 踩到）。
     數量與取值分兩句，反而更清楚。 */
  select count(*) into v_n
    from members where phone = '0910768736' and deleted_at is null;

  if v_n <> 1 then
    raise exception '預期 1 個會員，實際 %  —— 停手', v_n;
  end if;

  select id into v_id
    from members where phone = '0910768736' and deleted_at is null;

  update members set phone_verified_at = now() where id = v_id;
  if not found then
    raise exception 'update 沒有動到任何一列';
  end if;

  /* 留稽核。⚠ `kind` 只允許 care/birthday/winback/welcome/note，用 note。
     🎯 寫清楚**是手動補的**，不是簡訊驗來的 ——
       日後有人查「這個章哪來的」，答案要在資料裡而不是在某個對話紀錄裡。 */
  insert into member_interactions (org_id, member_id, channel, kind, note)
  select org_id, id, 'system', 'note',
         '手動補蓋手機驗證章（2026-08-30）：帳號建立於 OTP 上線之前，'
         || '號碼為本人所有，由創辦人指定回填。非簡訊驗證。'
    from members where id = v_id;
end $$;

-- ── 驗證 ──────────────────────────────────────────────
/* ⚠ 一併把四個測試帳號印出來當**正對照**：
   它們必須**還是 null** —— 只驗「創辦人有了」的話，
   萬一我把 where 寫錯而全表更新，看到的畫面一模一樣。 */
select display_name as 暱稱,
       left(phone,4) || '***' || right(phone,3) as 手機,
       case when line_user_id is null then '未綁 LINE' else '已綁 LINE' end as line,
       case when phone_verified_at is null then '未驗' else '✅ 已蓋章' end as 驗證,
       case
         when phone = '0910768736' and phone_verified_at is not null then '✅ 這個該有'
         when phone <> '0910768736' and phone_verified_at is null then '✅ 這個不該有'
         else '🔴 不對'
       end as 判定
  from members
 where deleted_at is null
 order by (phone = '0910768736') desc, created_at;
