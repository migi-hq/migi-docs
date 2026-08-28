/* ============================================================
   把那筆孤兒 staff 綁到創辦人的會員身上
   2026-08-29

   ── 為什麼 ──────────────────────────────────────────
   `staff` 只有一列（`role = 'hq'`，MIGI 總部管理員），而它的
   **`member_id` 是 null**。待辦 20 記著這件事：

     current_staff() 的第二條路是
       m.line_user_id = (auth.jwt() ->> 'sub')
     而 m 是從 `staff.member_id` join 過來的 ——
     🔴 `member_id` 是 null 的話那一條**永遠不會命中**。

   → 也就是「用 LINE 登入的店員／總部」這條路，
     在綁上 member_id 之前**根本走不通，而且不會報錯，只是登不進去**。

   ⚠ `auth_uid` 已經有值（總部 Email 那條路），**這支不動它**。
     兩條路是刻意並存的（決策紀錄第八節：總部員工不是會員、
     而且要有一條不依賴既有 staff 的開機路徑）。

   ── 為什麼是現在 ────────────────────────────────────
   2026-08-29 建立了 LINE Provider／channel／LIFF，創辦人即將用
   LINE 綁定自己的會員（`0910768736` → 走 `rebound`）。
   綁定完成後，`current_staff()` 的第二條路就會有東西可接。

   ⚠ **今天綁了也不會有任何立即效果** —— 讀 `staff.role` 的 RLS policy
     目前是 **0 條**（待辦 21）。這支只是把一個**已知壞掉的資料列**修好，
     不是啟用什麼新功能。

   ── 目標 ────────────────────────────────────────────
     staff 92333bb6-fff6-4118-954c-f1a8900eab43
       member_id: null → d73fdac2-d6b9-4b8a-bcff-b19c2786056f
   ============================================================ */

do $$
declare
  v_staff  uuid := '92333bb6-fff6-4118-954c-f1a8900eab43';
  v_member uuid := 'd73fdac2-d6b9-4b8a-bcff-b19c2786056f';
  v_n int;
  v_msg text;
begin
  -- 先確認兩邊都存在，錯誤訊息才看得懂（不要讓外鍵去拋 23503）
  if not exists (select 1 from staff where id = v_staff and deleted_at is null) then
    raise exception '找不到 staff %，先查 `select id, role, member_id from staff`', v_staff;
  end if;
  if not exists (select 1 from members where id = v_member and deleted_at is null) then
    raise exception '找不到 member %', v_member;
  end if;

  /* ⚠ 條件加 `member_id is null` 是刻意的：
     如果它已經被綁到**別人**身上，這支應該什麼都不做而不是覆蓋 ——
     改一個既有的身分綁定是稽核級操作，不該由一支「修資料」的 SQL 靜靜完成。 */
  update staff
     set member_id = v_member,
         updated_at = now()
   where id = v_staff
     and member_id is null;

  get diagnostics v_n = row_count;

  if v_n = 1 then
    v_msg := '✅ 綁定成功';
  else
    -- 看 row_count，不要無條件回報成功（同 register_member_tx 那個謊報的坑）
    select '⚠ 沒有更新任何列 —— 它現在的 member_id 是 '
           || coalesce(member_id::text, 'null')
      into v_msg
      from staff where id = v_staff;
  end if;

  perform set_config('migi.bind', v_msg, false);
end $$;


/* ============================================================
   驗證（單一 SELECT）

   ── 該看到什麼 ──────────────────────────────────────
   ① ✅ 綁定成功
   ② staff 兩條路都在：auth_uid 有值（總部 Email）＋ member_id 有值（LINE）
   ③ LEFT JOIN 真的接得起來（撈得到那位會員的暱稱與手機）
   ④ 🔴 **現在還不會生效**：那位會員的 line_user_id 仍是 null
      —— 要等他用 LINE 註冊（走 rebound）之後才會有值。
        這一列就是「還差什麼」的提醒。

   ⚠ **這支沒有辦法在這裡做真正的正對照**（硬規則 3.55）：
     `current_staff()` 讀的是 `auth.jwt()`，而 SQL Editor 沒有 JWT，
     它在這裡必定回 0 列 —— 那**不能**當成「綁定失敗」的證據。
     🔴 真正的驗證只有一條路：**LINE 綁定後，用那個身分實際查一次**
       （同待辦 21 第 5 點：不可以只讀定義就宣告安全）。
   ============================================================ */
select 序, 項目, 內容 from (

  select 1 as 序, '① 綁定結果' as 項目,
         coalesce(current_setting('migi.bind', true), '🔴 DO 區塊沒執行') as 內容

  union all
  select 2, '② staff 的兩條身分路徑',
         (select 'role=' || s.role
              || E'\n  ① 總部 Email：auth_uid=' || coalesce(s.auth_uid::text, '🔴 null')
              || E'\n  ② LINE：member_id=' || coalesce(s.member_id::text, '🔴 null')
            from staff s where s.id = '92333bb6-fff6-4118-954c-f1a8900eab43')

  union all
  select 3, '③ LEFT JOIN 接得起來嗎（撈得到會員資料就是通的）',
         (select coalesce('✅ ' || m.display_name || '　手機=' || coalesce(m.phone, '無'),
                          '🔴 join 不到 member')
            from staff s
            left join members m on m.id = s.member_id and m.deleted_at is null
           where s.id = '92333bb6-fff6-4118-954c-f1a8900eab43')

  union all
  select 4, '④ 還差什麼（LINE 綁定）',
         (select case
                   when m.line_user_id is null
                     then '⏳ 那位會員的 line_user_id 還是 null —— '
                       || '要等他用 LINE 走一次註冊（會走 rebound）才會有值。'
                       || E'\n  在那之前 current_staff() 的 LINE 那條路仍然不會命中。'
                   else '✅ 已綁 LINE，current_staff() 的第二條路現在有東西可比對了'
                 end
            from staff s
            join members m on m.id = s.member_id
           where s.id = '92333bb6-fff6-4118-954c-f1a8900eab43')

) x order by 序;
