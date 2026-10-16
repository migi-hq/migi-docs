-- ============================================================
-- 2026-10-16 人工改手機：葉昌閔 0928822681 → 0953986943，**標成已驗證**（比照 10-15 Steven 那份）
-- 使用者：「查一下目前有沒有用 0928822681 的手機，有的話回推他上一個驗證號碼，那才是正確的」
--
-- 查到的經過（phone_otps，依他的 LINE 帳號）：
--   10-15 19:37～19:41  用 0953986943 要了 4 次驗證碼，一次都沒輸入（沒收到）
--   10-15 19:42         改用 0928822681 要碼，19:42 驗過 → 註冊完成
-- 0928822681 是現場幫忙收碼的那支號碼：用它驗過的還有「呈.」（10-14）、Steven💫（10-15，已改回他自己的號碼）、
--   今天簡訊故障時「豪」「蔡旭宏」也拿它要過碼（沒驗成）
--
-- ⚠ 已知代價（同 Steven 那份）：0953986943 當時一次都沒驗過，系統沒有簡訊證據那支在他手上。
--   手機是找回帳號的鑰匙（換 LINE 時靠它認領），那支號碼若不是他的，號碼的主人就能把整個帳號認領走。
--   ⇒ 這一筆的「已驗證」是**人工認定**，不是簡訊驗證；phone_verified_at 記的是這份 SQL 跑的時間。
--
-- 守衛：只改「id 對、而且現在的號碼還是 0928822681」的那一列 —— 他若已經自己改過，這份不會動到任何東西（驗證段會說 0 列）
-- 0953986943 目前沒有任何會員在用（uq_members_phone 不會撞），格式同其他手機
--
-- 跑法：Supabase SQL Editor 整份執行，看最後那一格
-- ============================================================

with u as (
  update public.members
     set phone = '0953986943',
         phone_verified_at = now()
   where id = 'd71ff9d3-e06c-4bc5-ba47-9aa64c174d1a'
     and phone = '0928822681'
     and deleted_at is null
  returning id
)
select set_config('migi.phone', (select count(*) from u)::text, true);

-- ============================================================
-- 驗證（單一 SELECT）
-- ============================================================
select concat_ws(E'\n',
  case when current_setting('migi.phone', true) = '1' then '✅' else '🔴' end
    || ' ① 這次改到 ' || coalesce(current_setting('migi.phone', true), '?') || ' 列（應該是 1）',
  (select case when m.phone = '0953986943' and m.phone_verified_at is not null
               then '✅ ② 葉昌閔現在是 0953986943、已驗證（' || to_char(m.phone_verified_at at time zone 'Asia/Taipei', 'MM/DD HH24:MI') || '）'
               else '🔴 ② 現在是 ' || coalesce(m.phone, 'null') || '、驗證時間 ' || coalesce(m.phone_verified_at::text, 'null') end
     from public.members m where m.id = 'd71ff9d3-e06c-4bc5-ba47-9aa64c174d1a'),
  case when (select count(*) from public.members where phone = '0953986943' and deleted_at is null) = 1
       then '✅' else '🔴' end || ' ③ 0953986943 只有他一個人在用',
  case when not exists (select 1 from public.members where phone = '0928822681' and deleted_at is null)
       then '✅' else '🔴' end || ' ④ 舊號碼 0928822681 已經沒人掛著'
) as "葉昌閔改手機 · 驗證";
