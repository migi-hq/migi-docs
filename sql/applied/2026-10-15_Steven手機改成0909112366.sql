-- ============================================================
-- 2026-10-15 人工改手機：Steven💫 0928822681 → 0909112366，**標成已驗證**
-- 使用者：「改 0909112366，而且改已驗證」
--
-- ⚠ 已知代價（使用者知道後拍板）：0909112366 註冊當時發了 3 次驗證碼、一次都沒輸入，
--   系統沒有簡訊證據那支在他手上。手機是找回帳號的鑰匙（換 LINE 時靠它認領），
--   那支號碼若不是他的，號碼的主人就能把整個帳號認領走。
--   ⇒ 這一筆的「已驗證」是**人工認定**，不是簡訊驗證；phone_verified_at 記的是這份 SQL 跑的時間。
--
-- 守衛：只改「id 對、而且現在的號碼還是 0928822681」的那一列 ——
--      他若已經自己改過，這份不會動到任何東西（驗證段會說 0 列）
-- 0909112366 目前沒有任何會員在用（uq_members_phone 不會撞），格式符合 members_phone_chk
--
-- 跑法：Supabase SQL Editor 整份執行，看最後那一格
-- ============================================================

with u as (
  update public.members
     set phone = '0909112366',
         phone_verified_at = now()
   where id = 'e8dbea83-9afc-4b34-8881-9907f7acbdb9'
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
  (select case when m.phone = '0909112366' and m.phone_verified_at is not null
               then '✅ ② Steven 現在是 0909112366、已驗證（' || to_char(m.phone_verified_at at time zone 'Asia/Taipei', 'MM/DD HH24:MI') || '）'
               else '🔴 ② 現在是 ' || coalesce(m.phone, 'null') || '、驗證時間 ' || coalesce(m.phone_verified_at::text, 'null') end
     from public.members m where m.id = 'e8dbea83-9afc-4b34-8881-9907f7acbdb9'),
  case when (select count(*) from public.members where phone = '0909112366' and deleted_at is null) = 1
       then '✅' else '🔴' end || ' ③ 0909112366 只有他一個人在用',
  case when not exists (select 1 from public.members where phone = '0928822681' and deleted_at is null)
       then '✅' else '🔴' end || ' ④ 舊號碼 0928822681 已經沒人掛著'
) as "Steven 改手機 · 驗證";
