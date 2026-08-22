-- 【這是什麼】唯讀盤點：現有暱稱長度分布 + 線上到底有哪些長度守衛。
-- 【何時讀】要幫 members.display_name 加 CHECK 之前。加之前不查，ALTER TABLE 會直接失敗。
-- 【為什麼要查】
--   前端寫 maxLength={12}（profile.jsx:368、App.jsx:138），
--   但 sql/applied/MA1A-補改暱稱.sql 裡的守衛寫 20 —— 兩邊對不上。
--   而且 applied/ 不是線上鏡像（硬規則 3），檔案寫 20 不代表線上是 20。
--   寫入路徑有兩條：register_member_tx（註冊）、set_my_nickname_tx（改暱稱）。
--
-- 單一 SELECT，直接整段貼進 SQL Editor 執行。

select 項目, 值
from (
  -- ── 一、現有資料 ───────────────────────────────────────────
  select 1 as ord, '會員總數（未刪除）' as 項目,
         (select count(*)::text from members where deleted_at is null) as 值

  union all select 2, '暱稱最長幾個字',
    (select coalesce(max(char_length(display_name)), 0)::text
       from members where deleted_at is null)

  union all select 3, '1～6 字',
    (select count(*)::text from members
      where deleted_at is null and char_length(display_name) between 1 and 6)

  union all select 4, '7～12 字',
    (select count(*)::text from members
      where deleted_at is null and char_length(display_name) between 7 and 12)

  union all select 5, '13～20 字（超過前端上限）',
    (select count(*)::text from members
      where deleted_at is null and char_length(display_name) between 13 and 20)

  union all select 6, '超過 20 字（兩邊都超過）',
    (select count(*)::text from members
      where deleted_at is null and char_length(display_name) > 20)

  union all select 7, '空白或 NULL',
    (select count(*)::text from members
      where deleted_at is null
        and (display_name is null or char_length(trim(display_name)) = 0))

  union all select 8, '超過 12 字的實際內容（最多 10 筆）',
    (select coalesce(string_agg('「' || display_name || '」(' || char_length(display_name) || ')', '  '), '（無）')
       from (select display_name from members
              where deleted_at is null and char_length(display_name) > 12
              order by char_length(display_name) desc limit 10) t)

  -- ⚠ 中文 3 bytes、emoji 4 bytes。octet_length > char_length*3 表示含 4 bytes 字元。
  --   這會影響上限怎麼定：char_length 算的是碼點，一個家庭 emoji 可能吃掉 7 個碼點。
  union all select 9, '含 emoji（4 bytes 字元）的暱稱數',
    (select count(*)::text from members
      where deleted_at is null and display_name is not null
        and octet_length(display_name) > char_length(display_name) * 3)

  -- ── 二、線上守衛現況（只有這些查詢算數）──────────────────
  union all select 20, 'members 上與 display_name 有關的 CHECK',
    (select coalesce(string_agg(conname || ' → ' || pg_get_constraintdef(oid), '  ｜  '), '（無，完全沒擋）')
       from pg_constraint
      where conrelid = 'members'::regclass and contype = 'c'
        and pg_get_constraintdef(oid) ilike '%display_name%')

  union all select 21, 'set_my_nickname_tx 線上守衛上限',
    (select coalesce(
              (select substring(pg_get_functiondef(p.oid) from 'length\s*\(\s*p_nickname\s*\)\s*>\s*(\d+)')
                 from pg_proc p
                where p.pronamespace = 'public'::regnamespace
                  and p.proname = 'set_my_nickname_tx' limit 1),
              '（函式不存在或沒有長度守衛）'))

  union all select 22, 'register_member_tx 有沒有長度守衛',
    (select coalesce(
              (select case when pg_get_functiondef(p.oid) ~* 'length\s*\(\s*(trim\s*\(\s*)?p_display_name'
                           then '有' else '沒有 —— 註冊可塞任意長度' end
                 from pg_proc p
                where p.pronamespace = 'public'::regnamespace
                  and p.proname = 'register_member_tx' limit 1),
              '（函式不存在）'))

  union all select 23, '還有哪些函式會寫 display_name',
    (select coalesce(string_agg(proname, '、' order by proname), '（無）')
       from pg_proc
      where pronamespace = 'public'::regnamespace
        and prokind = 'f'
        and prosrc ~* 'display_name\s*=' )
) x
order by ord;

-- ── 讀完之後怎麼判斷 ─────────────────────────────────────────
-- 項目 5、6 若為 0  → 可以直接加 CHECK (1..12)，零風險。
-- 項目 5 或 6 不為 0 → 先看項目 8 的實際內容，決定是截斷回填還是把上限訂寬一點。
--                      ⚠ 回填是改客人的名字，要先確認再做，不要順手 update。
-- 項目 20 若已有 CHECK → 不要再加一條（待辦 4 的教訓：數量不等於衝突，
--                        但兩條約束同一欄位就是重複，看定義決定要不要換掉舊的）。
-- 項目 21 若回傳 20   → 前端 12 / 後端 20 確認不一致，CHECK 要跟前端對齊成 12，
--                        同時把函式裡的 20 一起改掉，否則 CHECK 會擋出一個難懂的錯誤。
-- 項目 22 若「沒有」  → 註冊路徑是敞開的，CHECK 就是唯一防線，更該加。
-- 項目 23 若出現預期外的函式 → 那也是寫入路徑，加 CHECK 後可能會被擋，要一起看。
